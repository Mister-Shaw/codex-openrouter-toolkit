#requires -Version 7.4

[CmdletBinding()]
param(
    [ValidateRange(6, 30)]
    [int]$TimeoutSeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This suite never reads user credentials or contacts the Internet. The production
# HTTPS target stays unchanged; an in-memory HttpMessageHandler handles every
# upstream request. The client-to-proxy leg uses real loopback HTTP sockets.
$script:AssertionCount = 0
$script:TestCaseCount = 0
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleManifest = Join-Path $repositoryRoot 'src\CodexOpenRouter\CodexOpenRouter.psd1'
$server = $null
$serverTask = $null
$upstreamHandler = $null
$downstreamClient = $null
$downstreamHandler = $null
$module = $null

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    $script:AssertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True -Condition ($Actual -ceq $Expected) -Message $Message
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $script:TestCaseCount++
    & $Action
    Write-Host "PASS: $Name"
}

function Get-ResponseHeader {
    param(
        [Parameter(Mandatory)][Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Response.Headers.Contains($Name)) { return '' }
    return [string]::Join(',', $Response.Headers.GetValues($Name))
}

function New-ProxyRequest {
    param(
        [string]$Method = 'POST',
        [string]$Path = '/api/v1/responses',
        [AllowNull()][string]$Body,
        [AllowNull()][string]$Token = $script:LocalTestToken
    )

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::new($Method),
        "$script:ProxyBaseUrl$Path"
    )
    if (-not [string]::IsNullOrEmpty($Token)) {
        [void]$request.Headers.TryAddWithoutValidation('x-cxor-proxy-token', $Token)
    }
    if ($Method -ceq 'POST') {
        [void]$request.Headers.TryAddWithoutValidation(
            'Authorization',
            "Bearer $script:SyntheticApiKey"
        )
        [void]$request.Headers.TryAddWithoutValidation('Accept-Encoding', 'gzip')
        $request.Content = [Net.Http.StringContent]::new(
            [string]$Body,
            [Text.Encoding]::UTF8,
            'application/json'
        )
    }
    return $request
}

function Invoke-BufferedProxyRequest {
    param(
        [string]$Method = 'POST',
        [string]$Path = $script:ResponsePath,
        [AllowNull()][string]$Body = $script:ValidRequestBody,
        [AllowNull()][string]$Token = $script:LocalTestToken
    )

    $request = New-ProxyRequest -Method $Method -Path $Path -Body $Body -Token $Token
    $response = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($TimeoutSeconds)
    )
    try {
        $response = $script:DownstreamClient.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $deadline.Token
        ).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync($deadline.Token).GetAwaiter().GetResult()
        return [pscustomobject]@{
            Response = $response
            Text = $text
            ElapsedMilliseconds = $clock.ElapsedMilliseconds
        }
    }
    catch {
        if ($null -ne $response) { $response.Dispose() }
        throw
    }
    finally {
        $deadline.Dispose()
        $request.Dispose()
    }
}

function Assert-JsonError {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][int]$Status,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$HeaderCode,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$BodyCode
    )

    Assert-Equal ([int]$Result.Response.StatusCode) $Status 'HTTP error status is preserved'
    Assert-Equal $Result.Response.Content.Headers.ContentType.MediaType `
        'application/json' 'Error response has a JSON content type'
    Assert-Equal (Get-ResponseHeader $Result.Response 'x-cxor-error-source') `
        $Source 'Error source header is trustworthy'
    Assert-Equal (Get-ResponseHeader $Result.Response 'x-cxor-error-code') `
        $HeaderCode 'Error code header is stable'
    $json = $Result.Text | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal $json.error.message $Message 'Error JSON contains the expected message'
    Assert-Equal $json.error.code $BodyCode 'Error JSON contains the expected code'
}

try {
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $module = Get-Module CodexOpenRouter -ErrorAction Stop
    & $module { Initialize-CxProxyType }

    if (-not ('CodexOpenRouter.IntegrationTests.OfflineUpstreamHandlerV3' -as [type])) {
        Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CodexOpenRouter.IntegrationTests
{
    public static class FixturesV3
    {
        public const string PromptSentinel = "OFFLINE_PROMPT_SENTINEL";
        public const string QuerySentinel = "OFFLINE_QUERY_SENTINEL";
        public const string UpstreamBodySentinel = "OFFLINE_UPSTREAM_BODY_SENTINEL";
        public const string ExceptionSentinel = "OFFLINE_EXCEPTION_SENTINEL";
        public const string Known401Message = "Synthetic authentication rejection.";
        public const string Unknown401Message = "Synthetic chunked rejection.";
        public const string NormalSse =
            "event: response.created\ndata: {\"type\":\"response.created\"}\n\n" +
            "event: response.output_text.delta\ndata: {\"delta\":\"offline ok\"}\n\n" +
            "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n";
        public const string FailingSsePrefix =
            "event: response.output_text.delta\ndata: {\"delta\":\"partial\"}\n\n";
    }

    public sealed class ObservedRequestV3
    {
        public string Method { get; set; }
        public string Scheme { get; set; }
        public string Host { get; set; }
        public string Path { get; set; }
        public string Query { get; set; }
        public string Authorization { get; set; }
        public string AcceptEncoding { get; set; }
        public string ContentType { get; set; }
        public bool HasLocalTokenHeader { get; set; }
        public bool ContainsLocalToken { get; set; }
    }

    public sealed class BodyProbeV3
    {
        private int reads;
        private int cancellations;
        public int ReadCalls { get { return Volatile.Read(ref reads); } }
        public int CancelledReads { get { return Volatile.Read(ref cancellations); } }
        internal void ReadAttempt() { Interlocked.Increment(ref reads); }
        internal void Cancelled() { Interlocked.Increment(ref cancellations); }
    }

    public sealed class FixtureBodyStreamV3 : Stream
    {
        private readonly byte[] bytes;
        private readonly string mode;
        private readonly BodyProbeV3 probe;
        private readonly TaskCompletionSource<bool> failureGate =
            new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        private int position;

        public FixtureBodyStreamV3(byte[] bytes, string mode, BodyProbeV3 probe)
        {
            this.bytes = bytes;
            this.mode = mode;
            this.probe = probe;
        }

        public void ReleaseFailure() { failureGate.TrySetResult(true); }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position
        {
            get { return position; }
            set { throw new NotSupportedException(); }
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            return ReadAsync(buffer, offset, count, CancellationToken.None)
                .GetAwaiter().GetResult();
        }

        public override async Task<int> ReadAsync(
            byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            probe.ReadAttempt();
            if (mode == "hang")
            {
                try { await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { probe.Cancelled(); throw; }
            }
            if (position < bytes.Length)
            {
                int chunkSize = mode == "fail_after_prefix" ? bytes.Length : 23;
                int length = Math.Min(count, Math.Min(chunkSize, bytes.Length - position));
                Array.Copy(bytes, position, buffer, offset, length);
                position += length;
                return length;
            }
            if (mode == "fail_after_prefix")
            {
                await failureGate.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                throw new IOException(FixturesV3.ExceptionSentinel);
            }
            return 0;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) ReleaseFailure();
            base.Dispose(disposing);
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }

    public sealed class FixtureContentV3 : HttpContent
    {
        private readonly byte[] bytes;
        private readonly bool knownLength;
        private readonly FixtureBodyStreamV3 bodyStream;
        public BodyProbeV3 Probe { get; private set; }

        public FixtureContentV3(string body, string mediaType, bool knownLength, string mode)
        {
            bytes = Encoding.UTF8.GetBytes(body);
            this.knownLength = knownLength;
            Probe = new BodyProbeV3();
            bodyStream = new FixtureBodyStreamV3(bytes, mode, Probe);
            Headers.ContentType = new MediaTypeHeaderValue(mediaType);
        }

        public void ReleaseFailure() { bodyStream.ReleaseFailure(); }
        protected override bool TryComputeLength(out long length)
        {
            length = bytes.Length;
            return knownLength;
        }
        protected override Task<Stream> CreateContentReadStreamAsync()
        {
            return Task.FromResult<Stream>(bodyStream);
        }
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext context)
        {
            return bodyStream.CopyToAsync(stream);
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) bodyStream.Dispose();
            base.Dispose(disposing);
        }
    }

    public sealed class OfflineUpstreamHandlerV3 : HttpMessageHandler
    {
        private readonly string localToken;
        private readonly ConcurrentQueue<string> scenarios = new ConcurrentQueue<string>();
        private readonly ConcurrentQueue<ObservedRequestV3> observations =
            new ConcurrentQueue<ObservedRequestV3>();
        private int requestCount;
        public int RequestCount { get { return Volatile.Read(ref requestCount); } }
        public int PendingScenarioCount { get { return scenarios.Count; } }
        public FixtureContentV3 LastContent { get; private set; }

        public OfflineUpstreamHandlerV3(string localToken) { this.localToken = localToken; }
        public void Enqueue(string scenario) { scenarios.Enqueue(scenario); }
        public ObservedRequestV3[] GetObservations() { return observations.ToArray(); }
        public void ReleaseStreamFailure()
        {
            FixtureContentV3 content = LastContent;
            if (content != null) content.ReleaseFailure();
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref requestCount);
            string body = request.Content == null ? string.Empty :
                await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            string allHeaders = request.Headers.ToString() +
                (request.Content == null ? string.Empty : request.Content.Headers.ToString());
            observations.Enqueue(new ObservedRequestV3
            {
                Method = request.Method.Method,
                Scheme = request.RequestUri.Scheme,
                Host = request.RequestUri.Host,
                Path = request.RequestUri.AbsolutePath,
                Query = request.RequestUri.Query,
                Authorization = request.Headers.Authorization == null ? string.Empty :
                    request.Headers.Authorization.ToString(),
                AcceptEncoding = request.Headers.AcceptEncoding.ToString(),
                ContentType = request.Content == null ? string.Empty :
                    request.Content.Headers.ContentType.MediaType,
                HasLocalTokenHeader = request.Headers.Contains("x-cxor-proxy-token") ||
                    (request.Content != null && request.Content.Headers.Contains("x-cxor-proxy-token")),
                ContainsLocalToken = allHeaders.Contains(localToken) || body.Contains(localToken) ||
                    request.RequestUri.AbsoluteUri.Contains(localToken)
            });

            // A strict fake makes any unexpected production request fail offline.
            if (request.RequestUri.Scheme != "https" ||
                request.RequestUri.Host != "openrouter.ai" ||
                request.RequestUri.AbsolutePath != "/api/v1/responses")
                throw new InvalidOperationException("Unexpected offline upstream target.");
            string scenario;
            if (!scenarios.TryDequeue(out scenario))
                throw new InvalidOperationException("No offline response fixture was queued.");
            LastContent = null;
            if (scenario == "send_failure")
                throw new HttpRequestException(FixturesV3.ExceptionSentinel);

            int status = 200;
            string text = string.Empty;
            string mediaType = "application/json";
            string mode = "normal";
            bool knownLength = true;
            switch (scenario)
            {
                case "empty502":
                    status = 502;
                    break;
                case "json502":
                    status = 502;
                    text = "{\"error\":{\"message\":\"" +
                        FixturesV3.UpstreamBodySentinel + "\"}}";
                    break;
                case "known401":
                    status = 401;
                    text = "{\"error\":{\"message\":\"" + FixturesV3.Known401Message +
                        "\",\"type\":\"authentication_error\",\"code\":\"invalid_api_key\"}}";
                    break;
                case "unknown401":
                    status = 401;
                    knownLength = false;
                    text = "{\"error\":{\"message\":\"" + FixturesV3.Unknown401Message +
                        "\",\"type\":\"authentication_error\",\"code\":\"chunked_test\"}}";
                    break;
                case "hanging429":
                    status = 429;
                    knownLength = false;
                    mode = "hang";
                    break;
                case "sse":
                    knownLength = false;
                    mediaType = "text/event-stream";
                    text = FixturesV3.NormalSse;
                    break;
                case "sse_failure":
                    knownLength = false;
                    mediaType = "text/event-stream";
                    text = FixturesV3.FailingSsePrefix;
                    mode = "fail_after_prefix";
                    break;
                default:
                    throw new InvalidOperationException("Unknown offline response fixture.");
            }
            LastContent = new FixtureContentV3(text, mediaType, knownLength, mode);
            var response = new HttpResponseMessage((HttpStatusCode)status)
            {
                Content = LastContent,
                RequestMessage = request
            };
            response.Headers.TryAddWithoutValidation("x-request-id", "offline-request-id");
            response.Headers.TryAddWithoutValidation("Set-Cookie", "offline-cookie=hidden");
            response.Headers.TryAddWithoutValidation("x-cxor-error-source", "untrusted-fixture");
            response.Headers.TryAddWithoutValidation("x-cxor-error-code", "untrusted-fixture");
            return response;
        }
    }
}
'@
    }

    $script:LocalTestToken = 'A' * 64
    $script:SyntheticApiKey = 'offline-api-key-fixture-never-valid'
    $script:ResponsePath = '/api/v1/responses?fixture=' +
        [CodexOpenRouter.IntegrationTests.FixturesV3]::QuerySentinel
    $script:ValidRequestBody = [ordered]@{
        model = 'openai/offline-integration-test'
        input = [CodexOpenRouter.IntegrationTests.FixturesV3]::PromptSentinel
        stream = $true
    } | ConvertTo-Json -Compress

    $portReservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $portReservation.Start()
        $port = ([Net.IPEndPoint]$portReservation.LocalEndpoint).Port
    }
    finally { $portReservation.Stop() }
    $script:ProxyBaseUrl = "http://127.0.0.1:$port"

    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $proxyType = [CodexOpenRouter.OpenRouterCacheProxyV3]
    $serverType = $proxyType.GetNestedType('ProxyServer', [Reflection.BindingFlags]::NonPublic)
    if ($null -eq $serverType) { throw 'The V3 private ProxyServer test seam is unavailable.' }
    $server = [Activator]::CreateInstance(
        $serverType,
        $flags,
        $null,
        [object[]]@([int]$port, [string]$script:LocalTestToken),
        [Globalization.CultureInfo]::InvariantCulture
    )
    $clientField = $serverType.GetField('client', $flags)
    $originalClient = $clientField.GetValue($server)
    $upstreamHandler = [CodexOpenRouter.IntegrationTests.OfflineUpstreamHandlerV3]::new(
        $script:LocalTestToken
    )
    $offlineClient = [Net.Http.HttpClient]::new($upstreamHandler)
    $offlineClient.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    try { $clientField.SetValue($server, $offlineClient) }
    catch { $offlineClient.Dispose(); throw }
    finally { $originalClient.Dispose() }

    # Invoke only the listener loop. The public entry point performs a real
    # upstream preflight, so it is deliberately excluded from this offline suite.
    $serverTask = [Threading.Tasks.Task]$serverType.GetMethod('RunAsync', $flags).Invoke(
        $server,
        [object[]]@()
    )
    if ($serverTask.IsFaulted) { $serverTask.GetAwaiter().GetResult() }
    $downstreamHandler = [Net.Http.HttpClientHandler]::new()
    $downstreamHandler.UseProxy = $false
    $downstreamHandler.AllowAutoRedirect = $false
    $downstreamClient = [Net.Http.HttpClient]::new($downstreamHandler)
    $downstreamClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $script:DownstreamClient = $downstreamClient

    Invoke-TestCase 'Initial health uses the V3 schema without an upstream request' {
        $result = Invoke-BufferedProxyRequest -Method GET -Path '/__cxor/health' -Body $null
        try {
            $health = $result.Text | ConvertFrom-Json
            Assert-Equal ([int]$result.Response.StatusCode) 200 'Initial health is reachable'
            Assert-Equal $health.status 'ok' 'Initial health status'
            Assert-Equal $health.schema 3 'Initial health schema'
            Assert-Equal $health.pid $PID 'Health identifies the in-process test server'
            Assert-Equal $health.total_requests 0 'Health does not count as inference traffic'
            Assert-Equal $health.total_failures 0 'Initial failure counter'
            Assert-Equal $upstreamHandler.RequestCount 0 'Health stays on loopback'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Empty upstream 502 completes as structured JSON' {
        $upstreamHandler.Enqueue('empty502')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-JsonError $result 502 'upstream' 'upstream_http_502' `
                'OpenRouter returned HTTP 502.' 'upstream_http_502'
            Assert-Equal $upstreamHandler.LastContent.Probe.ReadCalls 0 `
                'An empty 5xx body is skipped'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'JSON upstream 502 is synthesized without reading its body' {
        $upstreamHandler.Enqueue('json502')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-JsonError $result 502 'upstream' 'upstream_http_502' `
                'OpenRouter returned HTTP 502.' 'upstream_http_502'
            Assert-Equal $upstreamHandler.LastContent.Probe.ReadCalls 0 `
                'A populated 5xx body is skipped'
            Assert-True (-not $result.Text.Contains(
                [CodexOpenRouter.IntegrationTests.FixturesV3]::UpstreamBodySentinel
            )) 'The unreliable 5xx body is absent from the response'
            Assert-Equal (Get-ResponseHeader $result.Response 'x-request-id') `
                'offline-request-id' 'A safe upstream request identifier is preserved'
            Assert-Equal (Get-ResponseHeader $result.Response 'Set-Cookie') '' `
                'Upstream cookies are filtered'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Known small 401 preserves its structured message' {
        $upstreamHandler.Enqueue('known401')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-JsonError $result 401 'upstream' 'upstream_http_401' `
                ([CodexOpenRouter.IntegrationTests.FixturesV3]::Known401Message) `
                'invalid_api_key'
            Assert-True ($upstreamHandler.LastContent.Probe.ReadCalls -gt 0) `
                'The known small 4xx body is read'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Unknown-length 401 preserves its structured message' {
        $upstreamHandler.Enqueue('unknown401')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-JsonError $result 401 'upstream' 'upstream_http_401' `
                ([CodexOpenRouter.IntegrationTests.FixturesV3]::Unknown401Message) `
                'chunked_test'
            Assert-True ($null -eq $upstreamHandler.LastContent.Headers.ContentLength) `
                'The fixture has no upstream Content-Length'
            Assert-True ($upstreamHandler.LastContent.Probe.ReadCalls -gt 0) `
                'The unknown-length 4xx body is read'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'A hanging 4xx read falls back after the bounded read timeout' {
        $upstreamHandler.Enqueue('hanging429')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-JsonError $result 429 'upstream' 'upstream_http_429' `
                'OpenRouter returned HTTP 429.' 'upstream_http_429'
            Assert-True ($result.ElapsedMilliseconds -ge 2500) `
                'The cancellable hanging body reaches the three-second read deadline'
            Assert-True ($result.ElapsedMilliseconds -lt ($TimeoutSeconds * 1000)) `
                'The fallback response arrives before the client deadline'
            Assert-True ($upstreamHandler.LastContent.Probe.CancelledReads -gt 0) `
                'The body read observed cancellation'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Malformed request JSON is rejected before forwarding' {
        $before = $upstreamHandler.RequestCount
        $result = Invoke-BufferedProxyRequest -Body '{"input":'
        try {
            Assert-JsonError $result 400 'local' 'invalid_json' `
                'Invalid JSON request.' 'invalid_json'
            Assert-Equal $upstreamHandler.RequestCount $before `
                'Malformed JSON never reaches the fake upstream'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Missing and incorrect local tokens are rejected' {
        $before = $upstreamHandler.RequestCount
        foreach ($token in @('', ('B' * 64))) {
            $result = Invoke-BufferedProxyRequest -Token $token
            try {
                Assert-JsonError $result 403 'local' 'proxy_token_invalid' `
                    'Forbidden.' 'proxy_token_invalid'
            }
            finally { $result.Response.Dispose() }
        }
        Assert-Equal $upstreamHandler.RequestCount $before `
            'Rejected local authentication never reaches the fake upstream'
    }

    Invoke-TestCase 'An upstream transport exception reports its local phase' {
        $upstreamHandler.Enqueue('send_failure')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-JsonError $result 502 'local' 'send_upstream' `
                'Local OpenRouter proxy failed at send_upstream.' 'send_upstream'
            Assert-True (-not $result.Text.Contains(
                [CodexOpenRouter.IntegrationTests.FixturesV3]::ExceptionSentinel
            )) 'A local exception detail is absent from the error body'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Normal SSE is forwarded byte-for-byte with its content type' {
        $upstreamHandler.Enqueue('sse')
        $result = Invoke-BufferedProxyRequest
        try {
            Assert-Equal ([int]$result.Response.StatusCode) 200 'SSE HTTP status'
            Assert-Equal $result.Response.Content.Headers.ContentType.MediaType `
                'text/event-stream' 'SSE content type survives restricted-header handling'
            Assert-Equal $result.Text ([CodexOpenRouter.IntegrationTests.FixturesV3]::NormalSse) `
                'All SSE bytes arrive unchanged'
            Assert-True ($result.Response.Headers.TransferEncodingChunked -eq $true) `
                'The downstream SSE response is chunked'
            Assert-Equal (Get-ResponseHeader $result.Response 'x-cxor-error-source') '' `
                'An upstream fixture cannot spoof local diagnostic headers'
            Assert-Equal (Get-ResponseHeader $result.Response 'Set-Cookie') '' `
                'SSE response cookies are filtered'
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'A mid-SSE upstream read failure aborts the downstream connection' {
        $upstreamHandler.Enqueue('sse_failure')
        $request = New-ProxyRequest -Path $script:ResponsePath -Body $script:ValidRequestBody
        $response = $null
        $stream = $null
        $readDeadline = [Threading.CancellationTokenSource]::new(
            [TimeSpan]::FromSeconds($TimeoutSeconds)
        )
        try {
            $response = $downstreamClient.SendAsync(
                $request,
                [Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
            Assert-Equal ([int]$response.StatusCode) 200 'The SSE response starts successfully'
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $expected = [Text.Encoding]::UTF8.GetBytes(
                [CodexOpenRouter.IntegrationTests.FixturesV3]::FailingSsePrefix
            )
            $received = [byte[]]::new($expected.Length)
            $offset = 0
            while ($offset -lt $received.Length) {
                $read = $stream.ReadAsync(
                    $received,
                    $offset,
                    $received.Length - $offset,
                    $readDeadline.Token
                ).GetAwaiter().GetResult()
                if ($read -eq 0) { throw 'SSE ended before the controlled failure prefix arrived.' }
                $offset += $read
            }
            Assert-Equal ([Text.Encoding]::UTF8.GetString($received)) `
                ([CodexOpenRouter.IntegrationTests.FixturesV3]::FailingSsePrefix) `
                'The first SSE event is visible before the failure is released'
            $upstreamHandler.ReleaseStreamFailure()
            $streamFailure = $null
            $nextRead = -1
            try {
                $nextRead = $stream.ReadAsync(
                    [byte[]]::new(4096), 0, 4096, $readDeadline.Token
                ).GetAwaiter().GetResult()
            }
            catch { $streamFailure = $_.Exception }
            Assert-True ($null -ne $streamFailure) `
                'A truncated chunked SSE stream raises a client read error'
            Assert-True (-not $readDeadline.IsCancellationRequested) `
                'Connection abort is observed before the client read deadline'
            Assert-True ($nextRead -ne 0) 'A failed SSE stream is never reported as clean EOF'
        }
        finally {
            $upstreamHandler.ReleaseStreamFailure()
            $readDeadline.Dispose()
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            $request.Dispose()
        }
    }

    Invoke-TestCase 'Health diagnostics expose only the safe operational allowlist' {
        $result = Invoke-BufferedProxyRequest -Method GET -Path '/__cxor/health' -Body $null
        try {
            $health = $result.Text | ConvertFrom-Json
            $allowed = @(
                'status', 'schema', 'pid', 'total_requests', 'total_failures',
                'last_error_source', 'last_error_code', 'last_error_phase',
                'last_upstream_status', 'last_request_bytes', 'last_error_utc'
            ) | Sort-Object
            $actual = @($health.PSObject.Properties.Name | Sort-Object)
            Assert-Equal ($actual -join ',') ($allowed -join ',') `
                'Health fields exactly match the safe allowlist'
            Assert-Equal $health.schema 3 'Diagnostics retain the V3 schema'
            Assert-Equal $health.total_requests 9 'Only authenticated Responses requests are counted'
            Assert-Equal $health.total_failures 8 'Each failed request is counted once'
            Assert-Equal $health.last_error_source 'local' 'Latest failure source is local'
            Assert-Equal $health.last_error_code 'read_upstream' 'Latest failure code is the read phase'
            Assert-Equal $health.last_error_phase 'read_upstream' 'Latest failure phase is stable'
            Assert-Equal $health.last_upstream_status 200 `
                'A stream failure retains the successful upstream HTTP status'
            Assert-Equal $health.last_request_bytes `
                ([Text.Encoding]::UTF8.GetByteCount($script:ValidRequestBody)) `
                'Diagnostics retain only the request byte count'
            Assert-True (-not [string]::IsNullOrWhiteSpace($health.last_error_utc)) `
                'Diagnostics include the failure timestamp'
            foreach ($sentinel in @(
                $script:LocalTestToken,
                $script:SyntheticApiKey,
                [CodexOpenRouter.IntegrationTests.FixturesV3]::PromptSentinel,
                [CodexOpenRouter.IntegrationTests.FixturesV3]::QuerySentinel,
                [CodexOpenRouter.IntegrationTests.FixturesV3]::UpstreamBodySentinel,
                [CodexOpenRouter.IntegrationTests.FixturesV3]::ExceptionSentinel
            )) {
                Assert-True (-not $result.Text.Contains($sentinel)) `
                    'Health excludes credential, prompt, query, body, and exception sentinels'
            }
        }
        finally { $result.Response.Dispose() }
    }

    Invoke-TestCase 'Every upstream request keeps the fixed HTTPS target and strips the local token' {
        $observations = @($upstreamHandler.GetObservations())
        Assert-Equal $observations.Count 8 'Only the expected eight requests reached the fake upstream'
        Assert-Equal $upstreamHandler.PendingScenarioCount 0 'Every offline fixture was consumed'
        foreach ($observed in $observations) {
            Assert-Equal $observed.Method 'POST' 'Upstream method remains POST'
            Assert-Equal $observed.Scheme 'https' 'Production upstream scheme remains HTTPS'
            Assert-Equal $observed.Host 'openrouter.ai' 'Production upstream host remains fixed'
            Assert-Equal $observed.Path '/api/v1/responses' 'Production upstream path remains fixed'
            Assert-Equal $observed.Query ('?fixture=' +
                [CodexOpenRouter.IntegrationTests.FixturesV3]::QuerySentinel) `
                'The synthetic query is forwarded without changing the target'
            Assert-True (-not $observed.HasLocalTokenHeader) 'The local-token header is stripped'
            Assert-True (-not $observed.ContainsLocalToken) 'The local token never reaches upstream data'
            Assert-Equal $observed.Authorization "Bearer $script:SyntheticApiKey" `
                'Only the synthetic upstream authorization fixture is forwarded'
            Assert-Equal $observed.AcceptEncoding 'identity' 'Upstream compression is pinned to identity'
            Assert-Equal $observed.ContentType 'application/json' 'Upstream content type remains JSON'
        }
    }

}
finally {
    if ($null -ne $upstreamHandler) { $upstreamHandler.ReleaseStreamFailure() }
    if ($null -ne $downstreamClient) { $downstreamClient.Dispose() }
    if ($null -ne $downstreamHandler) { $downstreamHandler.Dispose() }
    if ($null -ne $server) { ([IDisposable]$server).Dispose() }
    if ($null -ne $serverTask) {
        $finished = [Threading.Tasks.Task]::WhenAny(
            $serverTask,
            [Threading.Tasks.Task]::Delay(3000)
        ).GetAwaiter().GetResult()
        if (-not [object]::ReferenceEquals($finished, $serverTask)) {
            throw 'The offline proxy listener task did not stop within three seconds.'
        }
        # Stopping HttpListener faults its pending GetContextAsync. Observe that
        # expected shutdown exception so no background task is left unobserved.
        try { $serverTask.GetAwaiter().GetResult() }
        catch {
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -isnot [Net.HttpListenerException] -and
                $cause -isnot [ObjectDisposedException] -and
                $cause -isnot [OperationCanceledException]) {
                throw
            }
        }
    }
    if ($null -ne $upstreamHandler) { $upstreamHandler.Dispose() }
    if ($null -ne $module) { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
}

Write-Host ("PASS: {0} offline proxy integration cases; {1} assertions. No Internet requests." -f `
    $script:TestCaseCount, $script:AssertionCount)
