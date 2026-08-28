Set-StrictMode -Version Latest

$script:MaximumConfigBytes = 5MB
$script:MaximumCatalogBytes = 50MB
$script:MaximumProxyStateBytes = 16KB
$script:ManagedBlockBegin = '# BEGIN CodexOpenRouter managed provider'
$script:ManagedBlockEnd = '# END CodexOpenRouter managed provider'
$script:ProxyHeaderName = 'x-cxor-proxy-token'
$script:EmptyInstructions = ''
$script:FeaturedModels = @(
    [pscustomobject]@{ Slug = '~openai/gpt-latest'; DisplayName = 'GPT Latest' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.6-sol-pro'; DisplayName = 'GPT-5.6 Sol Pro' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.6-sol'; DisplayName = 'GPT-5.6 Sol' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.6-terra'; DisplayName = 'GPT-5.6 Terra' }
    [pscustomobject]@{ Slug = 'openai/gpt-5.3-codex'; DisplayName = 'GPT-5.3 Codex' }
    [pscustomobject]@{ Slug = '~anthropic/claude-opus-latest'; DisplayName = 'Claude Opus Latest' }
    [pscustomobject]@{ Slug = 'anthropic/claude-opus-5'; DisplayName = 'Claude Opus 5' }
    [pscustomobject]@{ Slug = '~anthropic/claude-sonnet-latest'; DisplayName = 'Claude Sonnet Latest' }
    [pscustomobject]@{ Slug = 'anthropic/claude-sonnet-5'; DisplayName = 'Claude Sonnet 5' }
)

function Assert-CxRuntime {
    if (-not $IsWindows) {
        throw 'CodexOpenRouter 仅支持 Windows。'
    }
    if ($PSVersionTable.PSEdition -ne 'Core' -or
        $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'CodexOpenRouter 需要 PowerShell 7.4 或更高版本。'
    }
}

function Get-CxCodexHome {
    $configured = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            throw '无法确定当前用户目录。'
        }
        $configured = Join-Path $userProfile '.codex'
    }
    if (-not [IO.Path]::IsPathFullyQualified($configured)) {
        throw '用户级 CODEX_HOME 必须是绝对路径。'
    }
    return [IO.Path]::GetFullPath($configured)
}

function Get-CxPaths {
    $codexHome = Get-CxCodexHome
    [pscustomobject]@{
        CodexHome = $codexHome
        ConfigPath = Join-Path $codexHome 'config.toml'
        CatalogPath = Join-Path $codexHome 'openrouter-model-catalog.json'
        ProxyStatePath = Join-Path $codexHome 'openrouter-cache-proxy.json'
    }
}

function Test-CxProxyBaseUrl {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try { $uri = [Uri]$Value }
    catch { return $false }
    return $uri.IsAbsoluteUri -and
        $uri.Scheme -ceq 'http' -and
        $uri.Host -ceq '127.0.0.1' -and
        $uri.Port -ge 1024 -and $uri.Port -le 65535 -and
        $uri.AbsolutePath -ceq '/api/v1' -and
        [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and
        [string]::IsNullOrEmpty($uri.UserInfo)
}

function ConvertTo-CxTomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        switch ($code) {
            8 { [void]$builder.Append('\b') }
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            12 { [void]$builder.Append('\f') }
            13 { [void]$builder.Append('\r') }
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            default {
                if ($code -lt 32 -or $code -eq 127) {
                    [void]$builder.Append(('\u{0:X4}' -f $code))
                }
                else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-CxTomlCodeMask {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $characters = $Content.ToCharArray()
    $mask = $Content.ToCharArray()
    $state = 'normal'
    $index = 0
    while ($index -lt $characters.Length) {
        $character = $characters[$index]
        $isNewLine = $character -eq "`r" -or $character -eq "`n"
        switch ($state) {
            'normal' {
                if ($character -eq '#') {
                    $mask[$index] = ' '
                    $state = 'comment'
                }
                elseif ($character -eq '"') {
                    $isTriple = $index + 2 -lt $characters.Length -and
                        $characters[$index + 1] -eq '"' -and
                        $characters[$index + 2] -eq '"'
                    $mask[$index] = ' '
                    if ($isTriple) {
                        $mask[$index + 1] = ' '
                        $mask[$index + 2] = ' '
                        $index += 2
                        $state = 'multi-basic'
                    }
                    else { $state = 'basic' }
                }
                elseif ($character -eq "'") {
                    $isTriple = $index + 2 -lt $characters.Length -and
                        $characters[$index + 1] -eq "'" -and
                        $characters[$index + 2] -eq "'"
                    $mask[$index] = ' '
                    if ($isTriple) {
                        $mask[$index + 1] = ' '
                        $mask[$index + 2] = ' '
                        $index += 2
                        $state = 'multi-literal'
                    }
                    else { $state = 'literal' }
                }
            }
            'comment' {
                if ($isNewLine) { $state = 'normal' }
                else { $mask[$index] = ' ' }
            }
            'basic' {
                if ($isNewLine) { throw 'TOML 基本字符串跨越了物理行。' }
                $mask[$index] = ' '
                if ($character -eq '\') {
                    if ($index + 1 -lt $characters.Length) {
                        $index++
                        if ($characters[$index] -ne "`r" -and
                            $characters[$index] -ne "`n") {
                            $mask[$index] = ' '
                        }
                    }
                }
                elseif ($character -eq '"') { $state = 'normal' }
            }
            'literal' {
                if ($isNewLine) { throw 'TOML 字面字符串跨越了物理行。' }
                $mask[$index] = ' '
                if ($character -eq "'") { $state = 'normal' }
            }
            'multi-basic' {
                if (-not $isNewLine) { $mask[$index] = ' ' }
                if ($character -eq '\') {
                    if ($index + 1 -lt $characters.Length) {
                        $index++
                        if ($characters[$index] -ne "`r" -and
                            $characters[$index] -ne "`n") {
                            $mask[$index] = ' '
                        }
                    }
                }
                elseif ($character -eq '"') {
                    $quoteRun = 1
                    while ($index + $quoteRun -lt $characters.Length -and
                        $characters[$index + $quoteRun] -eq '"') {
                        $quoteRun++
                    }
                    if ($quoteRun -ge 3) {
                        if ($quoteRun -gt 5) { throw 'TOML 多行基本字符串的结束引号数量无效。' }
                        for ($offset = 1; $offset -lt $quoteRun; $offset++) {
                            $mask[$index + $offset] = ' '
                        }
                        $index += $quoteRun - 1
                        $state = 'normal'
                    }
                }
            }
            'multi-literal' {
                if (-not $isNewLine) { $mask[$index] = ' ' }
                if ($character -eq "'") {
                    $quoteRun = 1
                    while ($index + $quoteRun -lt $characters.Length -and
                        $characters[$index + $quoteRun] -eq "'") {
                        $quoteRun++
                    }
                    if ($quoteRun -ge 3) {
                        if ($quoteRun -gt 5) { throw 'TOML 多行字面字符串的结束引号数量无效。' }
                        for ($offset = 1; $offset -lt $quoteRun; $offset++) {
                            $mask[$index + $offset] = ' '
                        }
                        $index += $quoteRun - 1
                        $state = 'normal'
                    }
                }
            }
        }
        $index++
    }
    if ($state -in @('basic', 'literal', 'multi-basic', 'multi-literal')) {
        throw 'TOML 中存在未闭合的字符串。'
    }
    return -join $mask
}

function Get-CxAuthPowerShell {
    $path = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '找不到当前 PowerShell 7，无法读取 OpenRouter 密钥。'
    }
    return [IO.Path]::GetFullPath($path)
}

function New-CxProviderBlock {
    param(
        [Parameter(Mandatory)][string]$AuthCommand,
        [string]$ProxyBaseUrl,
        [string]$ProxyToken,
        [string]$ProxyStatePath,
        [switch]$Direct,
        [switch]$ReadProcessEnvironment
    )

    if (-not $Direct -and
        (-not (Test-CxProxyBaseUrl $ProxyBaseUrl) -or
         $ProxyToken -notmatch '\A[A-F0-9]{64}\z')) {
        throw 'OpenRouter provider 缺少有效的本地缓存代理。'
    }
    if (-not $Direct -and
        ([string]::IsNullOrWhiteSpace($ProxyStatePath) -or
         -not [IO.Path]::IsPathFullyQualified($ProxyStatePath))) {
        throw 'OpenRouter provider 缺少有效的缓存代理状态路径。'
    }

    $tokenCommand = if ($Direct -and $ReadProcessEnvironment) {
        '[Console]::Out.Write($env:OPENROUTER_API_KEY)'
    }
    elseif ($Direct) {
        "[Console]::Out.Write([Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY',[EnvironmentVariableTarget]::User))"
    }
    else {
        $moduleValue = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($PSCommandPath))
        )
        $stateValue = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ProxyStatePath))
        )
        $proxyUri = [Uri]$ProxyBaseUrl
        @(
            "`$d=[Text.Encoding]::UTF8"
            "`$m=`$d.GetString([Convert]::FromBase64String('$moduleValue'))"
            "`$s=`$d.GetString([Convert]::FromBase64String('$stateValue'))"
            "`$x=Import-Module -Name `$m -Force -PassThru"
            "& `$x { param(`$p,`$q,`$t) [void](Ensure-CxOpenRouterProxy -StatePath `$p -Port `$q -Token `$t); `$k=[Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY',[EnvironmentVariableTarget]::User); if (-not (Test-CxApiKey `$k)) { throw 'OpenRouter API Key 无效。' }; [Console]::Out.Write(`$k) } `$s $($proxyUri.Port) '$ProxyToken'"
        ) -join ';'
    }
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $tokenCommand) |
        ForEach-Object { ConvertTo-CxTomlString $_ }
    $providerLines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
        $script:ManagedBlockBegin
        '[model_providers.openrouter]'
        'name = "OpenRouter"'
        $(if ($Direct) {
                'base_url = "https://openrouter.ai/api/v1"'
            }
            else {
                "base_url = $(ConvertTo-CxTomlString $ProxyBaseUrl)"
        })
        'wire_api = "responses"'
        'supports_websockets = false'
    )) { $providerLines.Add($line) }
    if (-not $Direct) {
        $providerLines.Add('')
        $providerLines.Add('[model_providers.openrouter.http_headers]')
        $providerLines.Add(
            "$(ConvertTo-CxTomlString $script:ProxyHeaderName) = " +
            (ConvertTo-CxTomlString $ProxyToken)
        )
    }
    foreach ($line in @(
        ''
        '[model_providers.openrouter.auth]'
        "command = $(ConvertTo-CxTomlString $AuthCommand)"
        "args = [$($args -join ', ')]"
        'timeout_ms = 15000'
        'refresh_interval_ms = 0'
        $script:ManagedBlockEnd
    )) { $providerLines.Add($line) }
    return $providerLines -join "`r`n"
}

function Update-CxConfigContent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][ValidateSet('Default', 'OpenRouter')][string]$Mode,
        [string]$CatalogPath,
        [string]$AuthCommand,
        [string]$ProxyBaseUrl,
        [string]$ProxyToken,
        [string]$ProxyStatePath,
        [string]$Model = '~openai/gpt-latest'
    )

    if ($Mode -eq 'OpenRouter' -and
        ([string]::IsNullOrWhiteSpace($CatalogPath) -or
         [string]::IsNullOrWhiteSpace($AuthCommand) -or
         -not (Test-CxProxyBaseUrl $ProxyBaseUrl) -or
         $ProxyToken -notmatch '\A[A-F0-9]{64}\z' -or
         [string]::IsNullOrWhiteSpace($ProxyStatePath) -or
         -not [IO.Path]::IsPathFullyQualified($ProxyStatePath) -or
         $Model -notmatch '^[^\s\x00-\x1F]{1,256}$')) {
        throw 'OpenRouter 配置缺少有效的模型、目录、认证命令或缓存代理。'
    }

    $mask = New-CxTomlCodeMask $Content
    $matches = [regex]::Matches($Content, '.*?(?:\r\n|\n|\r|$)', 'Singleline') |
        Where-Object { $_.Length -gt 0 }
    $kept = [Collections.Generic.List[string]]::new()
    $inRoot = $true
    $inProviderParent = $false
    $skipProvider = $false
    $providersKey = '(?:model_providers|"model_providers"|''model_providers'')'
    $openRouterKey = '(?:openrouter|"openrouter"|''openrouter'')'

    foreach ($match in $matches) {
        $line = $match.Value
        $code = $mask.Substring($match.Index, $match.Length)
        $trimmed = $line.Trim()
        if ($trimmed -ceq $script:ManagedBlockBegin -or
            $trimmed -ceq $script:ManagedBlockEnd) {
            continue
        }

        $isArrayHeader = $code -match '^\s*\[\['
        $isHeader = $code -match '^\s*\[[^\[\]]+\]\s*$'
        $isOpenRouterHeader = $line -match (
            '^\s*\[\s*' + $providersKey + '\s*\.\s*' +
            $openRouterKey +
            '(?:\s*\.|\s*\])'
        )
        if ($isArrayHeader -and $line -match (
                '^\s*\[\[\s*' + $providersKey + '\s*\.\s*' + $openRouterKey
            )) {
            throw 'OpenRouter provider 不能声明为 TOML 数组表。'
        }
        if ($isHeader -or $isArrayHeader) {
            $inRoot = $false
            $inProviderParent = $isHeader -and
                $line -match ('^\s*\[\s*' + $providersKey + '\s*\]\s*(?:#.*)?$')
            if ($isOpenRouterHeader) {
                $skipProvider = $true
                continue
            }
            $skipProvider = $false
            $kept.Add($line)
            continue
        }
        if ($skipProvider) { continue }

        if ($inRoot -and $code -match '=' -and $line -match (
                '^\s*(?:model|model_provider|model_reasoning_effort|model_catalog_json|' +
                '"(?:model|model_provider|model_reasoning_effort|model_catalog_json)"|' +
                '''(?:model|model_provider|model_reasoning_effort|model_catalog_json)'')\s*='
            )) {
            continue
        }
        if ($inRoot -and $code -match '=' -and
            $line -match ('^\s*' + $providersKey + '\s*=')) {
            throw '不支持 inline model_providers；请改为标准 TOML 表。'
        }
        if ($inRoot -and $code -match '=' -and $line -match (
                '^\s*' + $providersKey + '\s*\.\s*' +
                $openRouterKey +
                '(?:\s*\.|\s*=)'
            )) {
            continue
        }
        if ($inProviderParent -and $code -match '=' -and
            $line -match '^\s*(?:openrouter|"openrouter"|''openrouter'')(?:\s*\.|\s*=)') {
            continue
        }
        $kept.Add($line)
    }

    $preserved = (-join $kept).Trim()
    $blocks = [Collections.Generic.List[string]]::new()
    if ($Mode -eq 'OpenRouter') {
        $blocks.Add((@(
            "model = $(ConvertTo-CxTomlString $Model)"
            'model_provider = "openrouter"'
            "model_catalog_json = $(ConvertTo-CxTomlString ([IO.Path]::GetFullPath($CatalogPath)))"
        ) -join "`r`n"))
    }
    if (-not [string]::IsNullOrWhiteSpace($preserved)) { $blocks.Add($preserved) }
    if ($Mode -eq 'OpenRouter') {
        $blocks.Add((New-CxProviderBlock -AuthCommand $AuthCommand `
                -ProxyBaseUrl $ProxyBaseUrl -ProxyToken $ProxyToken `
                -ProxyStatePath $ProxyStatePath))
    }
    if ($blocks.Count -eq 0) { return '' }
    return ($blocks -join "`r`n`r`n") + "`r`n"
}

function Read-CxTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "路径不是普通文件：$Path"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝读取重解析点：$Path"
    }
    if ($item.Length -gt $MaximumBytes) { throw "文件超过大小限制：$Path" }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { return $text.Substring(1) }
    return $text
}

function Write-CxTextFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($resolved)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw '目标文件缺少父目录。' }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
    }
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝写入重解析目录：$directory"
    }
    if ((Test-Path -LiteralPath $resolved) -and
        -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "目标不是普通文件：$resolved"
    }
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $targetItem = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "拒绝替换重解析点：$resolved"
        }
    }
    $temporary = Join-Path $directory ('.cx-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $resolved, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CxFileFingerprint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 104857600)][long]$MaximumBytes = 5MB
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt $MaximumBytes) {
        throw "文件无法安全计算摘要：$Path"
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-CxConfigChange {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Default', 'OpenRouter')][string]$Mode,
        [string]$CatalogPath,
        [string]$AuthCommand,
        [string]$ProxyBaseUrl,
        [string]$ProxyToken,
        [string]$ProxyStatePath,
        [string]$Model = '~openai/gpt-latest'
    )

    $fingerprintBefore = Get-CxFileFingerprint $Path
    $content = Read-CxTextFile -Path $Path -MaximumBytes $script:MaximumConfigBytes
    $fingerprintAfter = Get-CxFileFingerprint $Path
    if ($fingerprintBefore -cne $fingerprintAfter) {
        throw 'config.toml 在读取期间被其他程序修改，已取消切换。'
    }
    [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($Path)
        OriginalFingerprint = $fingerprintAfter
        OriginalContent = $content
        Content = Update-CxConfigContent -Content $content -Mode $Mode `
            -CatalogPath $CatalogPath -AuthCommand $AuthCommand `
            -ProxyBaseUrl $ProxyBaseUrl -ProxyToken $ProxyToken `
            -ProxyStatePath $ProxyStatePath -Model $Model
    }
}

function Commit-CxConfigChange {
    param([Parameter(Mandatory)][object]$Change)

    $fingerprintBefore = Get-CxFileFingerprint $Change.Path
    $current = Read-CxTextFile -Path $Change.Path -MaximumBytes $script:MaximumConfigBytes
    $fingerprintAfter = Get-CxFileFingerprint $Change.Path
    if ($fingerprintBefore -cne $Change.OriginalFingerprint -or
        $fingerprintAfter -cne $Change.OriginalFingerprint -or
        $current -cne [string]$Change.OriginalContent) {
        throw 'config.toml 在切换期间被其他程序修改，已取消写入。'
    }
    if ($current -cne [string]$Change.Content) {
        Write-CxTextFileAtomic -Path $Change.Path -Content ([string]$Change.Content)
    }
}

function Initialize-CxProxyType {
    if ('CodexOpenRouter.OpenRouterCacheProxyV1' -as [type]) { return }

    $source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace CodexOpenRouter
{
    public static class OpenRouterCacheProxyV1
    {
        private const int MaximumRequestBytes = 64 * 1024 * 1024;
        private const string TokenHeader = "x-cxor-proxy-token";

        private static readonly HashSet<string> HopByHopHeaders =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "Connection",
                "Content-Length",
                "Host",
                "Keep-Alive",
                "Proxy-Authenticate",
                "Proxy-Authorization",
                "TE",
                "Trailer",
                "Transfer-Encoding",
                "Upgrade"
            };

        public static string RewriteRequestJson(string json)
        {
            if (json == null) throw new ArgumentNullException(nameof(json));
            byte[] original = new UTF8Encoding(false, true).GetBytes(json);
            byte[] rewritten = RewriteRequestBody(original);
            return new UTF8Encoding(false, true).GetString(rewritten);
        }

        public static byte[] RewriteRequestBody(byte[] body)
        {
            if (body == null) throw new ArgumentNullException(nameof(body));
            string json = new UTF8Encoding(false, true).GetString(body);
            JsonNode root = JsonNode.Parse(
                json,
                null,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 128
                });
            JsonObject request = root as JsonObject;
            if (request == null)
                throw new JsonException("The Responses request must be a JSON object.");

            JsonNode modelNode;
            if (!request.TryGetPropertyValue("model", out modelNode) || modelNode == null)
                return body;

            string model;
            try { model = modelNode.GetValue<string>(); }
            catch (InvalidOperationException) { return body; }

            if (!IsClaudeModel(model) || request.ContainsKey("cache_control"))
                return body;

            request.Add(
                "cache_control",
                new JsonObject { ["type"] = "ephemeral" });
            return new UTF8Encoding(false).GetBytes(
                root.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        }

        public static async Task RunAsync(int port, string token)
        {
            if (port < 1024 || port > 65535)
                throw new ArgumentOutOfRangeException(nameof(port));
            if (string.IsNullOrWhiteSpace(token))
                throw new ArgumentException("Proxy token is required.", nameof(token));

            using (var server = new ProxyServer(port, token))
            {
                await server.RunAsync().ConfigureAwait(false);
            }
        }

        private static bool IsClaudeModel(string model)
        {
            if (string.IsNullOrWhiteSpace(model)) return false;
            return model.StartsWith("anthropic/claude-", StringComparison.OrdinalIgnoreCase) ||
                model.StartsWith("~anthropic/claude-", StringComparison.OrdinalIgnoreCase);
        }

        private sealed class ProxyServer : IDisposable
        {
            private readonly HttpListener listener;
            private readonly HttpClient client;
            private readonly string token;

            internal ProxyServer(int port, string token)
            {
                this.token = token;
                listener = new HttpListener();
                listener.Prefixes.Add("http://127.0.0.1:" + port + "/");

                var handler = new HttpClientHandler
                {
                    AllowAutoRedirect = false,
                    AutomaticDecompression = DecompressionMethods.None,
                    UseCookies = false
                };
                client = new HttpClient(handler)
                {
                    Timeout = Timeout.InfiniteTimeSpan
                };
            }

            internal async Task RunAsync()
            {
                listener.Start();
                while (listener.IsListening)
                {
                    HttpListenerContext context = await listener.GetContextAsync()
                        .ConfigureAwait(false);
                    _ = HandleSafeAsync(context);
                }
            }

            private async Task HandleSafeAsync(HttpListenerContext context)
            {
                try
                {
                    await HandleAsync(context).ConfigureAwait(false);
                }
                catch (JsonException)
                {
                    await WriteErrorAsync(context.Response, 400, "Invalid JSON request.")
                        .ConfigureAwait(false);
                }
                catch (DecoderFallbackException)
                {
                    await WriteErrorAsync(context.Response, 400, "Request body must be UTF-8.")
                        .ConfigureAwait(false);
                }
                catch (RequestTooLargeException)
                {
                    await WriteErrorAsync(context.Response, 413, "Request body is too large.")
                        .ConfigureAwait(false);
                }
                catch (Exception)
                {
                    await WriteErrorAsync(context.Response, 502, "OpenRouter request failed.")
                        .ConfigureAwait(false);
                }
                finally
                {
                    try { context.Response.Close(); } catch { }
                }
            }

            private async Task HandleAsync(HttpListenerContext context)
            {
                HttpListenerRequest incoming = context.Request;
                HttpListenerResponse outgoing = context.Response;

                if (!TokenMatches(incoming.Headers[TokenHeader], token))
                {
                    await WriteErrorAsync(outgoing, 403, "Forbidden.").ConfigureAwait(false);
                    return;
                }

                string path = incoming.Url == null ? string.Empty : incoming.Url.AbsolutePath;
                if (string.Equals(path, "/__cxor/health", StringComparison.Ordinal) &&
                    string.Equals(incoming.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase))
                {
                    byte[] health = Encoding.UTF8.GetBytes(
                        "{\"status\":\"ok\",\"schema\":1,\"pid\":" +
                        Environment.ProcessId.ToString() + "}");
                    outgoing.StatusCode = 200;
                    outgoing.ContentType = "application/json; charset=utf-8";
                    outgoing.ContentLength64 = health.Length;
                    await outgoing.OutputStream.WriteAsync(health, 0, health.Length)
                        .ConfigureAwait(false);
                    return;
                }

                if (!string.Equals(path, "/api/v1/responses", StringComparison.Ordinal) ||
                    !string.Equals(incoming.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
                {
                    await WriteErrorAsync(outgoing, 404, "Endpoint not found.")
                        .ConfigureAwait(false);
                    return;
                }

                if (incoming.ContentType == null ||
                    !incoming.ContentType.StartsWith(
                        "application/json",
                        StringComparison.OrdinalIgnoreCase))
                {
                    await WriteErrorAsync(outgoing, 415, "Content-Type must be application/json.")
                        .ConfigureAwait(false);
                    return;
                }

                byte[] requestBody = await ReadBodyAsync(incoming).ConfigureAwait(false);
                byte[] upstreamBody = RewriteRequestBody(requestBody);
                string query = incoming.Url == null ? string.Empty : incoming.Url.Query;
                var upstreamUri = new Uri(
                    "https://openrouter.ai/api/v1/responses" + query,
                    UriKind.Absolute);

                using (var upstreamRequest = new HttpRequestMessage(HttpMethod.Post, upstreamUri))
                using (var content = new ByteArrayContent(upstreamBody))
                using (var cancellation = new CancellationTokenSource())
                {
                    upstreamRequest.Content = content;
                    CopyRequestHeaders(incoming, upstreamRequest);
                    upstreamRequest.Headers.Remove("Accept-Encoding");
                    upstreamRequest.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");
                    content.Headers.Remove("Content-Type");
                    content.Headers.TryAddWithoutValidation("Content-Type", "application/json");

                    using (HttpResponseMessage upstream = await client.SendAsync(
                        upstreamRequest,
                        HttpCompletionOption.ResponseHeadersRead,
                        cancellation.Token).ConfigureAwait(false))
                    {
                        outgoing.StatusCode = (int)upstream.StatusCode;
                        outgoing.SendChunked = true;
                        outgoing.KeepAlive = false;
                        CopyResponseHeaders(upstream, outgoing);

                        using (Stream source = await upstream.Content.ReadAsStreamAsync()
                            .ConfigureAwait(false))
                        {
                            byte[] buffer = new byte[16384];
                            try
                            {
                                while (true)
                                {
                                    int read = await source.ReadAsync(buffer, 0, buffer.Length)
                                        .ConfigureAwait(false);
                                    if (read == 0) break;
                                    await outgoing.OutputStream.WriteAsync(buffer, 0, read)
                                        .ConfigureAwait(false);
                                    await outgoing.OutputStream.FlushAsync().ConfigureAwait(false);
                                }
                            }
                            catch
                            {
                                cancellation.Cancel();
                                throw;
                            }
                        }
                    }
                }
            }

            private static async Task<byte[]> ReadBodyAsync(HttpListenerRequest request)
            {
                if (request.ContentLength64 > MaximumRequestBytes)
                    throw new RequestTooLargeException();

                using (var memory = new MemoryStream())
                {
                    byte[] buffer = new byte[16384];
                    int total = 0;
                    while (true)
                    {
                        int read = await request.InputStream.ReadAsync(buffer, 0, buffer.Length)
                            .ConfigureAwait(false);
                        if (read == 0) break;
                        total += read;
                        if (total > MaximumRequestBytes)
                            throw new RequestTooLargeException();
                        memory.Write(buffer, 0, read);
                    }
                    return memory.ToArray();
                }
            }

            private static void CopyRequestHeaders(
                HttpListenerRequest incoming,
                HttpRequestMessage upstream)
            {
                foreach (string name in incoming.Headers.AllKeys)
                {
                    if (string.IsNullOrEmpty(name) ||
                        HopByHopHeaders.Contains(name) ||
                        string.Equals(name, TokenHeader, StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(name, "Accept-Encoding", StringComparison.OrdinalIgnoreCase))
                        continue;

                    string[] values = incoming.Headers.GetValues(name);
                    if (values == null) continue;
                    if (!upstream.Headers.TryAddWithoutValidation(name, values))
                        upstream.Content.Headers.TryAddWithoutValidation(name, values);
                }
            }

            private static void CopyResponseHeaders(
                HttpResponseMessage upstream,
                HttpListenerResponse outgoing)
            {
                foreach (var header in upstream.Headers)
                    CopyResponseHeader(header.Key, header.Value, outgoing);
                foreach (var header in upstream.Content.Headers)
                    CopyResponseHeader(header.Key, header.Value, outgoing);
            }

            private static void CopyResponseHeader(
                string name,
                IEnumerable<string> values,
                HttpListenerResponse outgoing)
            {
                if (HopByHopHeaders.Contains(name)) return;
                if (string.Equals(name, "Content-Type", StringComparison.OrdinalIgnoreCase))
                {
                    outgoing.ContentType = string.Join(", ", values);
                    return;
                }
                try { outgoing.Headers[name] = string.Join(", ", values); }
                catch (ArgumentException) { }
                catch (InvalidOperationException) { }
            }

            private static bool TokenMatches(string supplied, string expected)
            {
                if (supplied == null || expected == null) return false;
                byte[] left = Encoding.UTF8.GetBytes(supplied);
                byte[] right = Encoding.UTF8.GetBytes(expected);
                return left.Length == right.Length &&
                    CryptographicOperations.FixedTimeEquals(left, right);
            }

            private static async Task WriteErrorAsync(
                HttpListenerResponse response,
                int statusCode,
                string message)
            {
                try
                {
                    if (response.OutputStream == null) return;
                    byte[] body = Encoding.UTF8.GetBytes(
                        "{\"error\":\"" + message.Replace("\"", "") + "\"}");
                    response.StatusCode = statusCode;
                    response.ContentType = "application/json; charset=utf-8";
                    response.ContentLength64 = body.Length;
                    await response.OutputStream.WriteAsync(body, 0, body.Length)
                        .ConfigureAwait(false);
                }
                catch { }
            }

            public void Dispose()
            {
                try { if (listener.IsListening) listener.Stop(); } catch { }
                listener.Close();
                client.Dispose();
            }

            private sealed class RequestTooLargeException : Exception { }
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Start-CxProxyServer {
    param([Parameter(Mandatory)][ValidateRange(1024, 65535)][int]$Port)

    $token = [Environment]::GetEnvironmentVariable('CXOR_PROXY_TOKEN', 'Process')
    if ($token -notmatch '\A[A-F0-9]{64}\z') {
        throw '缓存代理缺少有效的启动令牌。'
    }
    Initialize-CxProxyType
    [CodexOpenRouter.OpenRouterCacheProxyV1]::RunAsync($Port, $token).
        GetAwaiter().GetResult()
}

function Get-CxProxyPowerShellPath {
    $path = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '找不到当前 PowerShell 7 可执行文件，无法启动缓存代理。'
    }
    return [IO.Path]::GetFullPath($path)
}

function Get-CxFreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally { $listener.Stop() }
}

function Get-CxProxyState {
    param([Parameter(Mandatory)][string]$StatePath)

    $content = Read-CxTextFile -Path $StatePath `
        -MaximumBytes $script:MaximumProxyStateBytes
    if ([string]::IsNullOrWhiteSpace($content)) { return $null }
    try { $data = $content | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }

    foreach ($name in @('schema', 'pid', 'port', 'token', 'started_utc', 'module_path')) {
        if (-not $data.PSObject.Properties[$name]) { return $null }
    }
    try {
        $schema = [int]$data.schema
        $processId = [int]$data.pid
        $port = [int]$data.port
    }
    catch { return $null }
    $started = [DateTimeOffset]::MinValue
    if ($schema -ne 1 -or
        $processId -le 0 -or
        $port -lt 1024 -or $port -gt 65535 -or
        [string]$data.token -notmatch '\A[A-F0-9]{64}\z' -or
        -not [DateTimeOffset]::TryParse(
            [string]$data.started_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$started
        ) -or
        [string]::IsNullOrWhiteSpace([string]$data.module_path)) {
        return $null
    }
    try { $modulePath = [IO.Path]::GetFullPath([string]$data.module_path) }
    catch { return $null }

    return [pscustomobject]@{
        Schema = 1
        ProcessId = $processId
        Port = $port
        Token = [string]$data.token
        StartedUtc = $started.ToUniversalTime()
        ModulePath = $modulePath
        BaseUrl = "http://127.0.0.1:$port/api/v1"
    }
}

function Test-CxProxyProcess {
    param([Parameter(Mandatory)][object]$State)

    try {
        $process = Get-Process -Id $State.ProcessId -ErrorAction Stop
        $expectedPath = Get-CxProxyPowerShellPath
        $actualPath = [IO.Path]::GetFullPath($process.Path)
        $started = [DateTimeOffset]$process.StartTime.ToUniversalTime()
        return [string]::Equals(
            $actualPath,
            $expectedPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -and [Math]::Abs(($started - $State.StartedUtc).TotalSeconds) -lt 1
    }
    catch { return $false }
}

function Test-CxProxyHealth {
    param([Parameter(Mandatory)][object]$State)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds(750)
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get,
        "http://127.0.0.1:$($State.Port)/__cxor/health"
    )
    try {
        [void]$request.Headers.TryAddWithoutValidation(
            $script:ProxyHeaderName,
            [string]$State.Token
        )
        $response = $client.Send($request)
        try {
            if (-not $response.IsSuccessStatusCode) { return $false }
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 1024) { return $false }
            $health = $body | ConvertFrom-Json -ErrorAction Stop
            return [string]$health.status -ceq 'ok' -and
                [int]$health.schema -eq 1 -and
                [int]$health.pid -eq [int]$State.ProcessId
        }
        finally { $response.Dispose() }
    }
    catch { return $false }
    finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Remove-CxProxyStateFile {
    param([Parameter(Mandatory)][string]$StatePath)

    if (-not (Test-Path -LiteralPath $StatePath)) { return }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "缓存代理状态路径必须指向普通文件：$StatePath"
    }
    $item = Get-Item -LiteralPath $StatePath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -gt $script:MaximumProxyStateBytes) {
        throw "缓存代理状态文件无法安全删除：$StatePath"
    }
    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
}

function Start-CxOpenRouterProxy {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][ValidateRange(1024, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidatePattern('\A[A-F0-9]{64}\z')][string]$Token
    )

    $modulePath = [IO.Path]::GetFullPath($PSCommandPath)
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw '缓存代理无法定位当前模块。'
    }
    $command = @'
$ErrorActionPreference = 'Stop'
$module = Import-Module -Name $env:CXOR_PROXY_MODULE_PATH -Force -PassThru
& $module { Start-CxProxyServer -Port ([int]$env:CXOR_PROXY_PORT) }
'@
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CxProxyPowerShellPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-EncodedCommand', $encodedCommand
        )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['CXOR_PROXY_MODULE_PATH'] = $modulePath
    $startInfo.Environment['CXOR_PROXY_PORT'] = [string]$Port
    $startInfo.Environment['CXOR_PROXY_TOKEN'] = $Token
    [void]$startInfo.Environment.Remove('OPENROUTER_API_KEY')

    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw '缓存代理进程未能启动。' }
        $startedUtc = [DateTimeOffset]$process.StartTime.ToUniversalTime()
        $probeState = [pscustomobject]@{
            ProcessId = $process.Id
            Port = $Port
            Token = $Token
            StartedUtc = $startedUtc
        }
        $healthy = $false
        foreach ($attempt in 1..50) {
            if ($process.HasExited) { break }
            if (Test-CxProxyHealth $probeState) { $healthy = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $healthy) {
            $diagnostic = if ($process.HasExited) {
                ($process.StandardError.ReadToEnd() + ' ' +
                    $process.StandardOutput.ReadToEnd()).Trim()
            }
            else { '健康检查超时。' }
            if (-not $process.HasExited) {
                try { $process.Kill($true) } catch { }
                [void]$process.WaitForExit(2000)
            }
            throw "缓存代理启动失败：$diagnostic"
        }

        $stateContent = [ordered]@{
            schema = 1
            pid = $process.Id
            port = $Port
            token = $Token
            started_utc = $startedUtc.ToString('O')
            module_path = $modulePath
        } | ConvertTo-Json -Compress
        try {
            Write-CxTextFileAtomic -Path $StatePath -Content $stateContent
            $state = Get-CxProxyState -StatePath $StatePath
            if ($null -eq $state) { throw '缓存代理状态写入后无法验证。' }
        }
        catch {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(2000)
            try { Remove-CxProxyStateFile -StatePath $StatePath } catch { }
            throw
        }
        $state | Add-Member -NotePropertyName Created -NotePropertyValue $true
        return $state
    }
    finally { $process.Dispose() }
}

function Ensure-CxOpenRouterProxy {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$Token
    )

    $mutex = Enter-CxMutex $StatePath
    try {
        $stateFileExists = Test-Path -LiteralPath $StatePath
        $state = Get-CxProxyState -StatePath $StatePath
        $processMatches = $null -ne $state -and (Test-CxProxyProcess $state)
        if ($processMatches -and (Test-CxProxyHealth $state)) {
            if (($Port -eq 0 -or $state.Port -eq $Port) -and
                ([string]::IsNullOrWhiteSpace($Token) -or $state.Token -ceq $Token)) {
                $state | Add-Member -NotePropertyName Created -NotePropertyValue $false
                return $state
            }
            throw '缓存代理正在运行，但与当前 Codex 配置不一致；请重新运行 cxor。'
        }
        if ($processMatches) {
            $staleProcess = Get-Process -Id $state.ProcessId -ErrorAction Stop
            try {
                Stop-Process -Id $state.ProcessId -Force -ErrorAction Stop
                [void]$staleProcess.WaitForExit(3000)
            }
            catch { throw '缓存代理失去响应，且无法安全结束原进程。' }
            finally { $staleProcess.Dispose() }
        }
        if ($stateFileExists) { Remove-CxProxyStateFile -StatePath $StatePath }

        $fixedPort = $Port -ne 0
        if (-not $fixedPort) { $Port = Get-CxFreeLoopbackPort }
        if ([string]::IsNullOrWhiteSpace($Token)) {
            $Token = [Convert]::ToHexString(
                [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            )
        }
        $attempts = if ($fixedPort) { 1 } else { 5 }
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            try {
                return Start-CxOpenRouterProxy -StatePath $StatePath `
                    -Port $Port -Token $Token
            }
            catch {
                if ($attempt -eq $attempts) { throw }
                $Port = Get-CxFreeLoopbackPort
            }
        }
    }
    finally { Exit-CxMutex $mutex }
}

function Stop-CxOpenRouterProxy {
    param([Parameter(Mandatory)][string]$StatePath)

    $mutex = Enter-CxMutex $StatePath
    try {
        $state = Get-CxProxyState -StatePath $StatePath
        if ($null -eq $state) {
            if (Test-Path -LiteralPath $StatePath) {
                Remove-CxProxyStateFile -StatePath $StatePath
            }
            return $false
        }
        if (-not (Test-CxProxyProcess $state)) {
            Remove-CxProxyStateFile -StatePath $StatePath
            return $false
        }
        $process = Get-Process -Id $state.ProcessId -ErrorAction Stop
        try {
            Stop-Process -Id $state.ProcessId -Force -ErrorAction Stop
            [void]$process.WaitForExit(3000)
        }
        finally { $process.Dispose() }
        Remove-CxProxyStateFile -StatePath $StatePath
        return $true
    }
    finally { Exit-CxMutex $mutex }
}

function Test-CxApiKey {
    param([AllowNull()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -cmatch '\Ask-or-[A-Za-z0-9._-]{16,}\z'
}

function Protect-CxText {
    param([AllowNull()][string]$Text, [AllowNull()][string]$ApiKey)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $protected = $Text
    if (-not [string]::IsNullOrEmpty($ApiKey)) {
        $protected = $protected.Replace($ApiKey, '<redacted>')
    }
    return [regex]::Replace($protected, 'sk-or-[A-Za-z0-9._-]{8,}', '<redacted>')
}

function Set-CxUserApiKey {
    $secure = Read-Host 'OpenRouter API Key' -AsSecureString
    $pointer = [IntPtr]::Zero
    $plain = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if (-not (Test-CxApiKey $plain)) {
            throw 'OpenRouter API Key 格式无效。'
        }
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $plain, 'User')
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $plain, 'Process')
        return $plain
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        $secure.Dispose()
    }
}

function Get-CxUserApiKey {
    param([switch]$Prompt)

    $key = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
    if (Test-CxApiKey $key) {
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $key, 'Process')
        return $key
    }
    if ($Prompt) { return Set-CxUserApiKey }
    throw '尚未设置有效的用户级 OPENROUTER_API_KEY。请运行 cxor -SetKey。'
}

function Get-CxCodexCliPath {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $binRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
        throw '找不到 Codex Desktop 内置 CLI。请安装或更新 Codex Desktop。'
    }
    $root = [IO.Path]::GetFullPath($binRoot).TrimEnd('\') + '\'
    $candidates = @(Get-ChildItem -LiteralPath $binRoot -Recurse -File `
        -Filter 'codex.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($candidate in $candidates) {
        try {
            $path = [IO.Path]::GetFullPath($candidate.FullName)
            if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            if ($signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
                $null -ne $signature.SignerCertificate -and
                $signature.SignerCertificate.Subject -like '*OpenAI OpCo, LLC*') {
                return $path
            }
        }
        catch { continue }
    }
    throw '找不到由 OpenAI 有效签名的 Codex Desktop 内置 CLI。'
}

function Invoke-CxProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][hashtable]$Environment,
        [ValidateRange(1000, 300000)][int]$TimeoutMilliseconds = 90000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Codex CLI 未能启动。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(5000)
            throw 'Codex CLI 刷新模型目录超时。'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt $script:MaximumCatalogBytes -or
            [Text.Encoding]::UTF8.GetByteCount($stderr) -gt 1MB) {
            throw 'Codex CLI 输出超过大小限制。'
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; StandardOutput = $stdout; StandardError = $stderr }
    }
    finally { $process.Dispose() }
}

function Get-CxCodexClientVersion {
    param([Parameter(Mandatory)][string]$CliPath)

    $result = Invoke-CxProcess -FilePath $CliPath -ArgumentList @('--version') `
        -Environment @{} -TimeoutMilliseconds 10000
    if ($result.ExitCode -ne 0) {
        throw "Codex CLI 版本查询返回退出码 $($result.ExitCode)：$($result.StandardError)"
    }
    $match = [regex]::Match(
        [string]$result.StandardOutput,
        '(?m)^\s*codex-cli\s+(?<version>\d+\.\d+\.\d+)(?:[-+][^\s]+)?\s*$'
    )
    if (-not $match.Success) {
        throw 'Codex CLI 未返回可识别的三段版本号。'
    }
    return $match.Groups['version'].Value
}

function New-CxOpenRouterCatalogRequest {
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ClientVersion
    )

    if (-not (Test-CxApiKey $ApiKey)) { throw 'OpenRouter API Key 格式无效。' }
    if ($ClientVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Codex CLI 客户端版本无效。'
    }
    $encodedVersion = [Uri]::EscapeDataString($ClientVersion)
    $uri = [Uri]::new(
        "https://openrouter.ai/api/v1/models?client_version=$encodedVersion"
    )
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $uri)
    try {
        $request.Headers.Authorization =
            [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $ApiKey)
        if (-not $request.Headers.TryAddWithoutValidation('originator', 'Codex Desktop')) {
            throw '无法设置 OpenRouter 模型目录请求头。'
        }
        return $request
    }
    catch {
        $request.Dispose()
        throw
    }
}

function Invoke-CxOpenRouterCatalogRequest {
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ClientVersion
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $client = $null
    $request = $null
    $response = $null
    try {
        $handler.AllowAutoRedirect = $false
        $handler.AutomaticDecompression =
            [Net.DecompressionMethods]::GZip -bor
            [Net.DecompressionMethods]::Deflate -bor
            [Net.DecompressionMethods]::Brotli
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $client.MaxResponseContentBufferSize = $script:MaximumCatalogBytes
        $request = New-CxOpenRouterCatalogRequest -ApiKey $ApiKey `
            -ClientVersion $ClientVersion
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "OpenRouter 模型目录请求返回 HTTP $statusCode。"
        }
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and $contentLength -gt $script:MaximumCatalogBytes) {
            throw 'OpenRouter 模型目录响应超过大小限制。'
        }
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ($bytes.Length -gt $script:MaximumCatalogBytes) {
            throw 'OpenRouter 模型目录响应超过大小限制。'
        }
        try { $content = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
        catch { throw 'OpenRouter 模型目录响应不是有效 UTF-8。' }
        if ($content.Contains($ApiKey)) {
            throw 'OpenRouter 模型目录响应包含 API Key。'
        }
        return $content
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        else { $handler.Dispose() }
    }
}

function Set-CxObjectProperty {
    param([Parameter(Mandatory)][object]$Object, [Parameter(Mandatory)][string]$Name, [AllowNull()]$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function Convert-CxCatalogPrompt {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$AllModels
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw '模型目录内容为空。'
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Content) -gt $script:MaximumCatalogBytes) {
        throw '模型目录超过大小限制。'
    }
    if ($Content -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
        throw '模型目录包含疑似密钥。'
    }
    try { $catalog = $Content | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "模型目录不是有效 JSON：$($_.Exception.Message)" }
    $modelsProperty = $catalog.PSObject.Properties['models']
    if ($null -eq $modelsProperty -or $modelsProperty.Value -isnot [array]) {
        throw '模型目录缺少 models 数组。'
    }
    $models = @($modelsProperty.Value)
    if ($models.Count -lt 1 -or $models.Count -gt 5000) {
        throw '模型目录的模型数量无效。'
    }
    $slugs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($model in $models) {
        if ($null -eq $model) { throw '模型目录包含空模型。' }
        $slugProperty = $model.PSObject.Properties['slug']
        $slug = if ($null -eq $slugProperty) { '' } else { [string]$slugProperty.Value }
        if ($slug -notmatch '^[^\s\x00-\x1F]{1,256}$') { throw '模型目录包含无效 slug。' }
        if (-not $slugs.Add($slug)) { throw "模型目录包含重复 slug：$slug" }

        Set-CxObjectProperty -Object $model -Name 'base_instructions' -Value $script:EmptyInstructions
        $messagesProperty = $model.PSObject.Properties['model_messages']
        if ($null -eq $messagesProperty -or $null -eq $messagesProperty.Value -or
            $messagesProperty.Value -isnot [pscustomobject]) {
            $messages = [pscustomobject]@{}
            Set-CxObjectProperty -Object $model -Name 'model_messages' -Value $messages
        }
        else { $messages = $messagesProperty.Value }
        Set-CxObjectProperty -Object $messages -Name 'instructions_template' -Value $script:EmptyInstructions
    }

    if ($AllModels) {
        foreach ($model in $models) {
            Set-CxObjectProperty -Object $model -Name 'visibility' -Value 'list'
        }
    }
    else {
        $featuredBySlug = @{}
        for ($index = 0; $index -lt $script:FeaturedModels.Count; $index++) {
            $definition = $script:FeaturedModels[$index]
            $featuredBySlug[[string]$definition.Slug] = [pscustomobject]@{
                DisplayName = [string]$definition.DisplayName
                Priority = $index + 1
            }
        }

        $featured = [Collections.Generic.List[object]]::new()
        $hidden = [Collections.Generic.List[object]]::new()
        foreach ($model in $models) {
            $slug = [string]$model.slug
            if ($featuredBySlug.ContainsKey($slug)) {
                $definition = $featuredBySlug[$slug]
                Set-CxObjectProperty -Object $model -Name 'display_name' -Value $definition.DisplayName
                Set-CxObjectProperty -Object $model -Name 'priority' -Value $definition.Priority
                Set-CxObjectProperty -Object $model -Name 'visibility' -Value 'list'
                $featured.Add($model)
            }
            else {
                Set-CxObjectProperty -Object $model -Name 'visibility' -Value 'hide'
                $hidden.Add($model)
            }
        }

        $orderedModels = @(
            foreach ($definition in $script:FeaturedModels) {
                foreach ($model in $featured) {
                    if ([string]$model.slug -ieq [string]$definition.Slug) { $model }
                }
            }
            foreach ($model in $hidden) { $model }
        )
        $modelsProperty.Value = $orderedModels
        $models = $orderedModels
    }

    $json = $catalog | ConvertTo-Json -Depth 100 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaximumCatalogBytes -or
        $json -cmatch 'sk-or-[A-Za-z0-9._-]{8,}') {
        throw '改写后的模型目录无效。'
    }
    $verified = $json | ConvertFrom-Json -ErrorAction Stop
    $verifiedModels = @($verified.models)
    $invalidModels = @($verifiedModels | Where-Object {
        $baseProperty = $_.PSObject.Properties['base_instructions']
        $messagesProperty = $_.PSObject.Properties['model_messages']
        $templateProperty = if ($null -eq $messagesProperty -or
            $null -eq $messagesProperty.Value) {
            $null
        }
        else {
            $messagesProperty.Value.PSObject.Properties['instructions_template']
        }
        $null -eq $baseProperty -or
        $baseProperty.Value -isnot [string] -or
        $baseProperty.Value -cne $script:EmptyInstructions -or
        $null -eq $templateProperty -or
        $templateProperty.Value -isnot [string] -or
        $templateProperty.Value -cne $script:EmptyInstructions
    })
    if ($verifiedModels.Count -ne $models.Count -or $invalidModels.Count -ne 0) {
        throw '模型基础指令清空校验失败。'
    }
    return $json
}

function Resolve-CxCatalogCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [switch]$AllModels,
        [AllowNull()][string]$ApiKey,
        [AllowEmptyString()][string]$StandardError = ''
    )

    $failures = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $Candidates) {
        $labelProperty = if ($null -eq $candidate) {
            $null
        }
        else { $candidate.PSObject.Properties['Label'] }
        $label = if ($null -eq $labelProperty -or
            [string]::IsNullOrWhiteSpace([string]$labelProperty.Value)) {
            '未命名候选'
        }
        else { [string]$labelProperty.Value }
        $contentProperty = if ($null -eq $candidate) {
            $null
        }
        else { $candidate.PSObject.Properties['Content'] }
        $candidateContent = if ($null -eq $contentProperty -or
            $null -eq $contentProperty.Value) {
            ''
        }
        else { [string]$contentProperty.Value }

        if ([string]::IsNullOrWhiteSpace($candidateContent)) {
            $failureProperty = if ($null -eq $candidate) {
                $null
            }
            else { $candidate.PSObject.Properties['Failure'] }
            $failure = if ($null -eq $failureProperty -or
                [string]::IsNullOrWhiteSpace([string]$failureProperty.Value)) {
                '空或不存在'
            }
            else {
                Protect-CxText ([string]$failureProperty.Value) $ApiKey
            }
            if ($failure.Length -gt 300) { $failure = $failure.Substring(0, 300) + '…' }
            $failures.Add("$label：$failure")
            continue
        }
        try {
            $converted = Convert-CxCatalogPrompt -Content $candidateContent `
                -AllModels:$AllModels
            $convertedModels = @(($converted | ConvertFrom-Json -ErrorAction Stop).models)
            if (@($convertedModels | Where-Object {
                        $_.slug -ceq '~openai/gpt-latest'
                    }).Count -ne 1) {
                throw '缺少官方默认入口 ~openai/gpt-latest。'
            }
            $previousProperty = $candidate.PSObject.Properties['IsPrevious']
            return [pscustomobject]@{
                Content = $converted
                Models = $convertedModels
                Source = $label
                UsedPreviousCatalog = $null -ne $previousProperty -and
                    [bool]$previousProperty.Value
            }
        }
        catch {
            $safeMessage = Protect-CxText $_.Exception.Message $ApiKey
            if ($safeMessage.Length -gt 300) {
                $safeMessage = $safeMessage.Substring(0, 300) + '…'
            }
            $failures.Add("$label：$safeMessage")
        }
    }

    $candidateDetail = if ($failures.Count -eq 0) {
        '没有候选来源'
    }
    else { $failures -join '；' }
    $safeError = Protect-CxText $StandardError $ApiKey
    if ($safeError.Length -gt 1000) { $safeError = $safeError.Substring(0, 1000) + '…' }
    $errorDetail = if ([string]::IsNullOrWhiteSpace($safeError)) { '无' } else { $safeError.Trim() }
    throw "OpenRouter 与 Codex CLI 未返回可用模型目录。候选检查：$candidateDetail。Codex CLI stderr：$errorDetail"
}

function Sync-CxOpenRouterCatalog {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$AuthCommand,
        [switch]$AllModels
    )

    $temporaryHome = ''
    try {
        $candidates = [Collections.Generic.List[object]]::new()
        $directContent = ''
        $directFailure = ''
        try {
            $clientVersion = Get-CxCodexClientVersion -CliPath $CliPath
            $directContent = Invoke-CxOpenRouterCatalogRequest -ApiKey $ApiKey `
                -ClientVersion $clientVersion
        }
        catch { $directFailure = Protect-CxText $_.Exception.Message $ApiKey }
        $directCandidate = [pscustomobject]@{
            Label = 'OpenRouter Codex API'
            Content = $directContent
            Failure = $directFailure
            IsPrevious = $false
        }
        $candidates.Add($directCandidate)

        $resolvedCatalog = $null
        if (-not [string]::IsNullOrWhiteSpace($directContent)) {
            try {
                $resolvedCatalog = Resolve-CxCatalogCandidate `
                    -Candidates @($directCandidate) -AllModels:$AllModels -ApiKey $ApiKey
            }
            catch { $directFailure = Protect-CxText $_.Exception.Message $ApiKey }
        }

        if ($null -eq $resolvedCatalog) {
            $catalogDirectory = [IO.Path]::GetDirectoryName(
                [IO.Path]::GetFullPath($CatalogPath)
            )
            if ([string]::IsNullOrWhiteSpace($catalogDirectory) -or
                -not (Test-Path -LiteralPath $catalogDirectory -PathType Container)) {
                throw 'OpenRouter 模型目录的父目录不存在。'
            }
            $temporaryHome = Join-Path $catalogDirectory (
                '.cxor-' + [Guid]::NewGuid().ToString('N')
            )
            [void](New-Item -ItemType Directory -Path $temporaryHome -ErrorAction Stop)

            $provider = New-CxProviderBlock -AuthCommand $AuthCommand `
                -Direct -ReadProcessEnvironment
            $temporaryConfig = @(
                'model = "~openai/gpt-latest"'
                'model_provider = "openrouter"'
                ''
                $provider
                ''
            ) -join "`r`n"
            Write-CxTextFileAtomic -Path (Join-Path $temporaryHome 'config.toml') `
                -Content $temporaryConfig

            $result = Invoke-CxProcess -FilePath $CliPath `
                -ArgumentList @('debug', 'models') -Environment @{
                    CODEX_HOME = $temporaryHome
                    OPENROUTER_API_KEY = $ApiKey
                }
            $standardOutput = [string]$result.StandardOutput
            $standardError = [string]$result.StandardError
            if ($standardOutput.Contains($ApiKey) -or $standardError.Contains($ApiKey)) {
                throw 'Codex CLI 输出包含 API Key。'
            }
            $cliDiagnostic = if ($result.ExitCode -eq 0) {
                $standardError
            }
            else {
                "Codex CLI 返回退出码 $($result.ExitCode)：$standardError"
            }

            $candidates.Add([pscustomobject]@{
                    Label = 'Codex CLI stdout'
                    Content = $standardOutput
                    Failure = if ($result.ExitCode -eq 0) {
                        ''
                    }
                    else { "Codex CLI 返回退出码 $($result.ExitCode)" }
                    IsPrevious = $false
                })

            $seenCachePaths = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            $cachePaths = [Collections.Generic.List[string]]::new()
            foreach ($cacheName in @('models_cache.openrouter.json', 'models_cache.json')) {
                $cachePath = [IO.Path]::GetFullPath((Join-Path $temporaryHome $cacheName))
                if ($seenCachePaths.Add($cachePath)) { $cachePaths.Add($cachePath) }
            }
            foreach ($cacheFile in @(Get-ChildItem -LiteralPath $temporaryHome -File `
                        -Filter 'models_cache*.json' -ErrorAction SilentlyContinue |
                    Sort-Object Name)) {
                $cachePath = [IO.Path]::GetFullPath($cacheFile.FullName)
                if ($seenCachePaths.Add($cachePath)) { $cachePaths.Add($cachePath) }
            }
            foreach ($cachePath in $cachePaths) {
                $candidates.Add([pscustomobject]@{
                        Label = "临时缓存 $([IO.Path]::GetFileName($cachePath))"
                        Content = Read-CxTextFile -Path $cachePath `
                            -MaximumBytes $script:MaximumCatalogBytes
                        IsPrevious = $false
                    })
            }
            $candidates.Add([pscustomobject]@{
                    Label = '上次有效 OpenRouter 目录'
                    Content = Read-CxTextFile -Path $CatalogPath `
                        -MaximumBytes $script:MaximumCatalogBytes
                    IsPrevious = $true
                })

            $resolvedCatalog = Resolve-CxCatalogCandidate -Candidates @($candidates) `
                -AllModels:$AllModels -ApiKey $ApiKey -StandardError $cliDiagnostic
        }
        $catalog = [string]$resolvedCatalog.Content
        $writtenModels = @($resolvedCatalog.Models)
        Write-CxTextFileAtomic -Path $CatalogPath -Content ($catalog + "`r`n")
        return [pscustomobject]@{
            Path = [IO.Path]::GetFullPath($CatalogPath)
            ModelCount = $writtenModels.Count
            VisibleModelCount = @($writtenModels | Where-Object {
                $_.PSObject.Properties['visibility'] -and $_.visibility -ceq 'list'
            }).Count
            DefaultModel = '~openai/gpt-latest'
            CatalogSource = [string]$resolvedCatalog.Source
            UsedPreviousCatalog = [bool]$resolvedCatalog.UsedPreviousCatalog
        }
    }
    catch {
        throw "OpenRouter 模型目录同步失败：$(Protect-CxText $_.Exception.Message $ApiKey)"
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryHome)) {
            $resolvedTemp = [IO.Path]::GetFullPath($temporaryHome)
            $catalogRoot = [IO.Path]::GetFullPath(
                [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CatalogPath))
            ).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if ($resolvedTemp.StartsWith(
                    $catalogRoot,
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                [IO.Path]::GetFileName($resolvedTemp) -match '^\.cxor-[0-9a-f]{32}$' -and
                (Test-Path -LiteralPath $resolvedTemp -PathType Container)) {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}

function Resolve-CxDesktopApp {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
        Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending)
    foreach ($package in $packages) {
        try {
            $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
            $applications = @($manifest.Package.Applications.Application | Where-Object {
                [string]$_.Id -match '^[A-Za-z0-9._-]+$' -and
                [IO.Path]::GetFileName([string]$_.Executable) -ceq 'ChatGPT.exe'
            })
            if ($applications.Count -ne 1) { continue }
            $family = [string]$package.PackageFamilyName
            if ($family -notmatch '^OpenAI\.Codex_[A-Za-z0-9]+$') { continue }
            $roots = @($packages | Where-Object {
                    [string]$_.PackageFamilyName -ceq $family
                } | ForEach-Object {
                    [IO.Path]::GetFullPath([string]$_.InstallLocation).TrimEnd('\') + '\'
                } | Sort-Object -Unique)
            return [pscustomobject]@{
                AppUserModelId = "$family!$([string]$applications[0].Id)"
                InstallRoots = $roots
            }
        }
        catch { continue }
    }
    throw '找不到 Codex Desktop 启动入口。'
}

function Get-CxDesktopProcesses {
    param([Parameter(Mandatory)][object]$App)
    $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    $matched = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $sessionId) { continue }
            $path = [IO.Path]::GetFullPath([string]$process.Path)
            $insidePackage = @($App.InstallRoots | Where-Object {
                    $path.StartsWith([string]$_, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            if ([IO.Path]::GetFileName($path) -ceq 'ChatGPT.exe' -and $insidePackage) {
                $matched.Add($process)
            }
        }
        catch { throw '无法验证当前 Codex Desktop 进程，已取消切换。' }
    }
    return @($matched)
}

function Stop-CxDesktopApp {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes)
    foreach ($process in $Processes) {
        if (-not $process.HasExited) { [void]$process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    foreach ($process in $Processes) {
        if ($process.HasExited) { continue }
        $remaining = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -gt 0) { [void]$process.WaitForExit($remaining) }
        if (-not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { throw 'Codex Desktop 未能停止。' }
        }
    }
}

function Start-CxDesktopApp {
    param([Parameter(Mandatory)][object]$App)
    if ([string]$App.AppUserModelId -notmatch '^OpenAI\.Codex_[A-Za-z0-9]+![A-Za-z0-9._-]+$') {
        throw 'Codex Desktop AUMID 无效。'
    }
    $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $explorer = Join-Path $windows 'explorer.exe'
    if (-not (Test-Path -LiteralPath $explorer -PathType Leaf)) { throw '找不到 Windows Explorer。' }
    $process = Start-Process -FilePath $explorer -ArgumentList "shell:AppsFolder\$($App.AppUserModelId)" -PassThru
    if ($null -eq $process) { throw 'Codex Desktop 未能启动。' }
}

function Enter-CxMutex {
    param([Parameter(Mandatory)][string]$ScopePath)
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ScopePath).ToUpperInvariant())
    $name = 'Local\CodexOpenRouter-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        try { $acquired = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '等待另一个 cx/cxor 操作超时。' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-CxMutex {
    param([AllowNull()][Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Invoke-CxMode {
    param(
        [Parameter(Mandatory)][ValidateSet('Default', 'OpenRouter')][string]$Mode,
        [switch]$SetKey,
        [switch]$AllModels
    )

    Assert-CxRuntime
    $paths = Get-CxPaths
    $mutex = Enter-CxMutex $paths.ConfigPath
    try {
        if (-not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
            throw 'CodexOpenRouter 已被卸载或替换；请重新打开 PowerShell。'
        }
        $app = Resolve-CxDesktopApp
        $catalogResult = $null
        $proxy = $null
        try {
            if ($Mode -eq 'OpenRouter') {
                $key = if ($SetKey) { Set-CxUserApiKey } else { Get-CxUserApiKey -Prompt }
                $authCommand = Get-CxAuthPowerShell
                $cli = Get-CxCodexCliPath
                $catalogResult = Sync-CxOpenRouterCatalog -CliPath $cli -ApiKey $key `
                    -CatalogPath $paths.CatalogPath -AuthCommand $authCommand `
                    -AllModels:$AllModels
                if ($catalogResult.UsedPreviousCatalog) {
                    Write-Warning 'OpenRouter 与 Codex CLI 未返回可用的新目录，已使用上次有效 OpenRouter 目录。'
                }
                $proxy = Ensure-CxOpenRouterProxy -StatePath $paths.ProxyStatePath
                $change = Get-CxConfigChange -Path $paths.ConfigPath -Mode OpenRouter `
                    -CatalogPath $paths.CatalogPath -AuthCommand $authCommand `
                    -ProxyBaseUrl $proxy.BaseUrl -ProxyToken $proxy.Token `
                    -ProxyStatePath $paths.ProxyStatePath `
                    -Model $catalogResult.DefaultModel
            }
            else {
                $change = Get-CxConfigChange -Path $paths.ConfigPath -Mode Default
            }
            $processes = @(Get-CxDesktopProcesses $app)
        }
        catch {
            if ($null -ne $proxy -and $proxy.Created) {
                try { [void](Stop-CxOpenRouterProxy -StatePath $paths.ProxyStatePath) }
                catch { }
            }
            throw
        }

        try { Stop-CxDesktopApp $processes }
        catch {
            if ($null -ne $proxy -and $proxy.Created) {
                try { [void](Stop-CxOpenRouterProxy -StatePath $paths.ProxyStatePath) }
                catch { }
            }
            try { Start-CxDesktopApp $app } catch { }
            throw
        }
        $committed = $false
        try {
            Commit-CxConfigChange $change
            $committed = $true
            if ($Mode -eq 'Default') {
                try { [void](Stop-CxOpenRouterProxy -StatePath $paths.ProxyStatePath) }
                catch {
                    Write-Warning "默认配置已恢复，但缓存代理清理失败：$($_.Exception.Message)"
                }
            }
            Start-CxDesktopApp $app
        }
        catch {
            if (-not $committed) {
                if ($null -ne $proxy -and $proxy.Created) {
                    try { [void](Stop-CxOpenRouterProxy -StatePath $paths.ProxyStatePath) }
                    catch { }
                }
                try { Start-CxDesktopApp $app } catch { }
                throw
            }
            throw "配置已更新，但 Codex Desktop 未能自动启动；请手动启动。$($_.Exception.Message)"
        }

        if ($Mode -eq 'OpenRouter') {
            Write-Host (
                "cxor：已同步 $($catalogResult.ModelCount) 个模型，" +
                "选择器显示 $($catalogResult.VisibleModelCount) 个模型，" +
                "全模型缓存感知代理已就绪，并请求打开 OpenRouter Codex。"
            )
        }
        else { Write-Host 'cx：已请求打开默认 Codex。' }
    }
    finally { Exit-CxMutex $mutex }
}

function cx {
    [CmdletBinding()]
    param()
    Invoke-CxMode -Mode Default
}

function cxor {
    [CmdletBinding()]
    param(
        [switch]$SetKey,
        [switch]$AllModels
    )
    Invoke-CxMode -Mode OpenRouter -SetKey:$SetKey -AllModels:$AllModels
}

Export-ModuleMember -Function @('cx', 'cxor')
