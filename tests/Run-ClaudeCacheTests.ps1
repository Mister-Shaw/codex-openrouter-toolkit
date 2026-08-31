#requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pure request/response fixtures only. No listener, user credential, or paid API
# is used by this suite. Token and cost values are synthetic accounting fixtures.
$script:AssertionCount = 0
$script:TestCaseCount = 0
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleManifest = Join-Path $repositoryRoot 'src\CodexOpenRouter\CodexOpenRouter.psd1'
$module = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:AssertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [string]$Message)
    Assert-True ($Actual -ceq $Expected) "$Message. Expected=[$Expected] Actual=[$Actual]"
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Action)
    $script:TestCaseCount++
    & $Action
    Write-Host "PASS: $Name"
}

function Convert-FixtureJson {
    param([object]$Value)
    return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

function Rewrite-Fixture {
    param([string]$Json)
    return [CodexOpenRouter.OpenRouterCacheProxyV4]::RewriteRequestJson($Json)
}

function Get-FixtureKey {
    param([string]$Json, [string]$Secret = 'offline-secret-never-valid')
    return [CodexOpenRouter.OpenRouterCacheProxyV4]::GetClaudeRoutingKey($Json, $Secret)
}

function Get-FixtureUsage {
    param(
        [AllowEmptyString()][string]$Text,
        [bool]$EventStream = $true,
        [int]$ChunkSize = 7,
        [switch]$WithoutComplete
    )
    $observer = [CodexOpenRouter.OpenRouterCacheProxyV4+CacheUsageObserver]::new($EventStream)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    for ($offset = 0; $offset -lt $bytes.Length; $offset += $ChunkSize) {
        $count = [Math]::Min($ChunkSize, $bytes.Length - $offset)
        # A non-zero buffer offset catches parsers that ignore the supplied slice.
        $padded = [byte[]]::new($count + 4)
        [Array]::Copy($bytes, $offset, $padded, 2, $count)
        $observer.Append($padded, 2, $count)
    }
    if (-not $WithoutComplete) { $observer.Complete() }
    return $observer.SnapshotJson() | ConvertFrom-Json
}

function New-UsageSse {
    param([object]$Usage, [string]$Type = 'response.completed', [string]$NewLine = "`n")
    $terminal = [ordered]@{
        type = $Type
        response = [ordered]@{ id = 'offline-response'; usage = $Usage }
    }
    return "event: $Type${NewLine}data: $(Convert-FixtureJson $terminal)$NewLine$NewLine"
}

function Assert-UnknownUsage {
    param([object]$Usage, [string]$Label)
    Assert-Equal $Usage.status 'unknown' "$Label status"
}

try {
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $module = Get-Module CodexOpenRouter -ErrorAction Stop
    & $module { Initialize-CxProxyType }

    Invoke-TestCase 'Leading system prefix gets stable first and last breakpoints' {
        $original = [ordered]@{
            model = 'anthropic/claude-opus-5'
            instructions = "fixed instruction`nwith Unicode 你好"
            tools = @([ordered]@{ type = 'function'; name = 'lookup'; parameters = @{ type = 'object' } })
            input = @(
                [ordered]@{ type = 'message'; role = 'system'; content = 'stable base' },
                [ordered]@{ role = 'developer'; content = @(@{ type = 'input_text'; text = 'middle' }) },
                [ordered]@{ role = 'developer'; content = @(
                    @{ type = 'input_text'; text = 'last text'; annotation = 'preserve' },
                    @{ type = 'input_image'; image_url = 'https://example.invalid/image.png' }
                ) },
                [ordered]@{ role = 'user'; content = 'question one' },
                [ordered]@{ role = 'developer'; content = 'later dynamic rule' }
            )
            stream = $true
        }
        $rewritten = Rewrite-Fixture (Convert-FixtureJson $original) | ConvertFrom-Json
        Assert-Equal $rewritten.cache_control.type 'ephemeral' 'Claude enables ephemeral automatic caching'
        Assert-True ($null -eq $rewritten.cache_control.PSObject.Properties['ttl'] -or
            $rewritten.cache_control.ttl -ceq '5m') 'Automatic caching keeps the five-minute default'
        Assert-Equal $rewritten.instructions $original.instructions 'Instructions stay in the original field'
        Assert-Equal (Convert-FixtureJson $rewritten.tools) (Convert-FixtureJson $original.tools) 'Tools stay unchanged'
        Assert-Equal $rewritten.input.Count 5 'Message count is preserved'
        Assert-Equal (($rewritten.input | ForEach-Object role) -join ',') `
            'system,developer,developer,user,developer' 'All roles remain in original order'
        Assert-Equal $rewritten.input[0].content[0].type 'input_text' 'String content gets an equivalent text block'
        Assert-Equal $rewritten.input[0].content[0].text 'stable base' 'String text is preserved'
        Assert-Equal $rewritten.input[0].content[0].prompt_cache_breakpoint.mode 'explicit' 'First prefix text is marked'
        Assert-True ($null -eq $rewritten.input[1].content[0].PSObject.Properties['prompt_cache_breakpoint']) `
            'Middle prefix text consumes no extra explicit breakpoint'
        Assert-Equal $rewritten.input[2].content[0].prompt_cache_breakpoint.mode 'explicit' 'Last prefix text is marked'
        Assert-Equal $rewritten.input[2].content[0].annotation 'preserve' 'Text-block extension fields survive'
        Assert-Equal $rewritten.input[2].content[1].image_url 'https://example.invalid/image.png' 'Non-text blocks survive'
        Assert-Equal $rewritten.input[3].content 'question one' 'User content stays in its original representation'
        Assert-Equal $rewritten.input[4].content 'later dynamic rule' 'Later developer messages are untouched'
        Assert-Equal $rewritten.stream $true 'Streaming setting is preserved'
    }

    Invoke-TestCase 'One eligible prefix message has one breakpoint and rewriting is idempotent' {
        $json = '{"model":"~Anthropic/Claude-Sonnet-Latest","input":[{"role":"developer","content":[{"type":"input_text","text":"a"},{"type":"input_text","text":"b"}]},{"role":"user","content":"hi"}]}'
        $once = Rewrite-Fixture $json
        $parsed = $once | ConvertFrom-Json
        Assert-True ($null -eq $parsed.input[0].content[0].PSObject.Properties['prompt_cache_breakpoint']) `
            'Only the last text block receives the marker'
        Assert-Equal $parsed.input[0].content[1].prompt_cache_breakpoint.mode 'explicit' 'Last text is marked'
        Assert-Equal (Rewrite-Fixture $once) $once 'A second rewrite is byte-for-byte stable'
    }

    Invoke-TestCase 'Only markable messages in the continuous leading prefix are selected' {
        $json = '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":[{"type":"input_image","image_url":"x"}]},{"role":"developer","content":"text"},{"role":"developer","content":[]},{"role":"user","content":"hi"}]}'
        $parsed = Rewrite-Fixture $json | ConvertFrom-Json
        Assert-Equal $parsed.input[0].content[0].image_url 'x' 'Image-only system message survives'
        Assert-Equal $parsed.input[1].content[0].prompt_cache_breakpoint.mode 'explicit' 'The available text prefix is marked'
        Assert-Equal $parsed.input[2].content.Count 0 'Empty content is preserved'
    }

    Invoke-TestCase 'User, function, and item reference boundaries stop prefix marking' {
        foreach ($boundary in @(
            '{"role":"user","content":"hi"}',
            '{"type":"function_call","call_id":"call-1","name":"tool","arguments":"{}"}',
            '{"type":"function_call_output","call_id":"call-1","output":"ok"}',
            '{"type":"item_reference","id":"offline-item"}',
            '{"role":"assistant","content":"previous response"}'
        )) {
            $json = '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":"base"},' +
                $boundary + ',{"role":"developer","content":"dynamic tail"}]}'
            $parsed = Rewrite-Fixture $json | ConvertFrom-Json
            Assert-Equal $parsed.input[0].content[0].prompt_cache_breakpoint.mode 'explicit' 'Leading system remains marked'
            Assert-Equal $parsed.input[2].content 'dynamic tail' 'No marker is added beyond a boundary'
            Assert-Equal (Convert-FixtureJson $parsed.input[1]) (Convert-FixtureJson ($boundary | ConvertFrom-Json)) `
                'Boundary item is unchanged'
        }
    }

    Invoke-TestCase 'Instructions-only and user-first requests retain automatic caching without rearrangement' {
        foreach ($json in @(
            '{"model":"anthropic/claude-opus-5","instructions":"system instruction","input":"hello"}',
            '{"model":"anthropic/claude-opus-5","instructions":"system instruction","input":[{"role":"user","content":"hello"},{"role":"developer","content":"later"}]}',
            '{"model":"anthropic/claude-opus-5","instructions":"system instruction","input":[]}'
        )) {
            $original = $json | ConvertFrom-Json
            $parsed = Rewrite-Fixture $json | ConvertFrom-Json
            Assert-Equal $parsed.instructions $original.instructions 'Instructions remain unchanged'
            Assert-Equal (Convert-FixtureJson $parsed.input) (Convert-FixtureJson $original.input) 'Input remains unchanged'
            Assert-Equal $parsed.cache_control.type 'ephemeral' 'Automatic cache hint remains available'
        }
    }

    Invoke-TestCase 'Explicit caller cache policies are preserved byte-for-byte' {
        foreach ($json in @(
            ' { "model" : "anthropic/claude-opus-5", "cache_control" : null, "input" : [{"role":"system","content":"base"}] } ',
            '{"model":"anthropic/claude-opus-5","cache_control":{"type":"ephemeral","ttl":"1h"},"input":[{"role":"system","content":"base"}]}',
            '{"model":"anthropic/claude-opus-5","prompt_cache_options":null,"input":[{"role":"system","content":"base"}]}',
            '{"model":"anthropic/claude-opus-5","prompt_cache_options":{"mode":"disabled"},"input":[{"role":"system","content":"base"}]}',
            '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":[{"type":"input_text","text":"base","prompt_cache_breakpoint":{"mode":"explicit"}}]}]}',
            '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":[{"type":"input_text","text":"base","cache_control":{"type":"ephemeral","ttl":"1h"}}]}]}',
            '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":"base"},{"role":"user","content":[{"type":"input_text","text":"query","prompt_cache_breakpoint":null}]}]}',
            '{"model":"anthropic/claude-opus-5","tools":[{"type":"function","name":"lookup","cache_control":{"type":"ephemeral"}}],"input":[{"role":"system","content":"base"}]}',
            '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":"base","prompt_cache_breakpoint":null}]}',
            '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":"base"},{"type":"function_call_output","call_id":"one","output":[{"type":"input_text","text":"result","cache_control":{"type":"ephemeral"}}]}]}'
        )) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $rewritten = [CodexOpenRouter.OpenRouterCacheProxyV4]::RewriteRequestBody($bytes)
            Assert-Equal ([Convert]::ToBase64String($rewritten)) ([Convert]::ToBase64String($bytes)) `
                'Caller-supplied cache settings prevent automatic policy changes'
        }
    }

    Invoke-TestCase 'Business schema properties named like cache controls do not disable Claude caching' {
        foreach ($marker in @('cache_control', 'prompt_cache_breakpoint')) {
            $json = '{"model":"anthropic/claude-opus-5","tools":[{"type":"function","name":"lookup","parameters":{"type":"object","properties":{"' +
                $marker + '":{"type":"string","description":"a business property"}}}}],"input":[{"role":"system","content":"base"},{"role":"user","content":"hello"}]}'
            $original = $json | ConvertFrom-Json
            $parsed = Rewrite-Fixture $json | ConvertFrom-Json
            Assert-Equal $parsed.cache_control.type 'ephemeral' 'Tool parameter names cannot suppress cache injection'
            Assert-Equal $parsed.input[0].content[0].prompt_cache_breakpoint.mode 'explicit' 'System prefix is still explicitly marked'
            Assert-Equal (Convert-FixtureJson $parsed.tools) (Convert-FixtureJson $original.tools) 'Business tool schema is unchanged'
        }
        $json = '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":"base"},{"type":"function_call_output","call_id":"one","output":"{\"cache_control\":\"business-data\"}"}]}'
        $parsed = Rewrite-Fixture $json | ConvertFrom-Json
        Assert-Equal $parsed.cache_control.type 'ephemeral' 'Cache-like content inside tool-output text is ordinary data'
    }

    Invoke-TestCase 'All non-Claude model request bytes and routing remain unchanged' {
        foreach ($model in @('openai/gpt-5.6-sol', 'google/gemini-2.5-pro', 'deepseek/deepseek-chat', 'vendor/claude-looking-name')) {
            $json = ' { "model" : "' + $model + '", "instructions" : "base", "input" : [{"role":"system","content":"base"},{"role":"user","content":"hello"}] } '
            Assert-Equal (Rewrite-Fixture $json) $json 'Other providers receive no Claude rewrite'
            Assert-True ($null -eq (Get-FixtureKey $json)) 'Other providers receive no Claude routing fallback'
        }
    }

    Invoke-TestCase 'Existing routing keys keep caller identity and precedence' {
        $both = '{"model":"anthropic/claude-opus-5","session_id":"session-original","prompt_cache_key":"cache-original","input":"hello"}'
        Assert-Equal (Get-FixtureKey $both) 'session-original' 'Session ID takes precedence'
        Assert-Equal (Get-FixtureKey '{"model":"anthropic/claude-opus-5","prompt_cache_key":"cache-original","input":"hello"}') `
            'cache-original' 'Existing Codex prompt cache key remains authoritative'
        $rewritten = Rewrite-Fixture $both | ConvertFrom-Json
        Assert-Equal $rewritten.session_id 'session-original' 'Request session ID is preserved'
        Assert-Equal $rewritten.prompt_cache_key 'cache-original' 'Request cache key is preserved'
        foreach ($invalid in @('null', '""', '32', '{}', '[]', '"line\r\nbreak"', ('"' + ('x' * 1025) + '"'))) {
            $json = '{"model":"anthropic/claude-opus-5","session_id":' + $invalid +
                ',"prompt_cache_key":"other-key","input":[{"role":"system","content":"base"}]}'
            Assert-True ([string]::IsNullOrEmpty((Get-FixtureKey $json))) 'Invalid or empty caller routing identity is not replaced'
        }
    }

    Invoke-TestCase 'Fallback routing key is stable for the model and system prefix' {
        $base = '{"model":"anthropic/claude-opus-5","instructions":"fixed","tools":[{"type":"function","name":"lookup","parameters":{"type":"object","properties":{"a":{"type":"string"}}}}],"input":[{"role":"system","content":"base"},{"role":"developer","content":"rules"},{"role":"user","content":"question one"}]}'
        $reordered = '{"input":[{"content":"base","role":"system"},{"content":"rules","role":"developer"},{"content":"question two","role":"user"}],"tools":[{"parameters":{"properties":{"a":{"type":"string"}},"type":"object"},"name":"lookup","type":"function"}],"instructions":"fixed","model":"anthropic/claude-opus-5"}'
        $key = Get-FixtureKey $base
        Assert-True ($key -cmatch '^cxor-claude-[0-9a-f]+$') 'Fallback is an opaque Claude-specific hexadecimal key'
        Assert-Equal (Get-FixtureKey $reordered) $key 'Canonical object order and user text do not perturb system identity'
        Assert-Equal (Get-FixtureKey (Rewrite-Fixture $base)) $key 'Injected cache annotations do not perturb routing identity'
        Assert-True ($key -cne (Get-FixtureKey $base 'different-offline-secret')) 'HMAC secret changes routing identity'
        foreach ($replacement in @(
            $base.Replace('anthropic/claude-opus-5', 'anthropic/claude-sonnet-5'),
            $base.Replace('"fixed"', '"changed instruction"'),
            $base.Replace('"base"', '"changed base"'),
            $base.Replace('"lookup"', '"different_tool"')
        )) {
            Assert-True ($key -cne (Get-FixtureKey $replacement)) 'Changes in cacheable model/system/tools change routing identity'
        }
        Assert-Equal $key (Get-FixtureKey ($base.Replace('"rules"', '"changed rules"'))) `
            'Later dynamic developer messages do not affect stable routing identity'
        foreach ($sentinel in @('fixed', 'lookup', 'question', 'offline-secret-never-valid')) {
            Assert-True (-not $key.Contains($sentinel)) 'Routing key excludes plaintext prompt and secret'
        }
    }

    Invoke-TestCase 'Fallback key excludes post-user developer history and needs a system prefix' {
        $json = '{"model":"anthropic/claude-opus-5","input":[{"role":"system","content":"base"},{"role":"user","content":"question"},{"role":"developer","content":"late instruction one"}]}'
        Assert-Equal (Get-FixtureKey $json) (Get-FixtureKey ($json.Replace('late instruction one', 'late instruction two'))) `
            'Dynamic developer history does not influence fallback routing'
        Assert-True ($null -eq (Get-FixtureKey '{"model":"anthropic/claude-opus-5","input":"hello"}')) `
            'A user-only request has no synthetic shared identity'
        Assert-True ($null -eq (Get-FixtureKey '{"model":"anthropic/claude-opus-5","input":[{"role":"user","content":"hello"},{"role":"developer","content":"late"}]}')) `
            'Late developer content alone cannot create a system identity'
        Assert-True (-not [string]::IsNullOrEmpty((Get-FixtureKey '{"model":"anthropic/claude-opus-5","instructions":"fixed base","input":"hello"}'))) `
            'A stable instructions field provides a cacheable system prefix'
    }

    Invoke-TestCase 'Completed SSE usage reports an actual hit without altering counters' {
        $usage = [ordered]@{
            input_tokens = 10000
            input_tokens_details = @{ cached_tokens = 9000; cache_write_tokens = 500 }
            output_tokens = 20
            cost = 0.012345
        }
        $result = Get-FixtureUsage (New-UsageSse $usage)
        Assert-Equal $result.status 'hit' 'Positive cached input proves a hit'
        Assert-Equal $result.completion_status 'completed' 'Completed terminal status is retained'
        Assert-Equal $result.usage_known $true 'Hit accounting is known'
        Assert-Equal $result.input_tokens 10000 'Input tokens are retained'
        Assert-Equal $result.cached_tokens 9000 'Cached reads are retained'
        Assert-Equal $result.cache_write_tokens 500 'Mixed cache writes are retained separately'
        Assert-Equal $result.output_tokens 20 'Output tokens are retained'
        Assert-Equal $result.cost 0.012345 'Reported cost is retained without recomputation'
    }

    Invoke-TestCase 'Cache writes and confirmed misses have distinct states' {
        foreach ($case in @(
            @{ Write = 4096; Status = 'write' },
            @{ Write = 0; Status = 'miss' }
        )) {
            $usage = @{ input_tokens = 5000; input_tokens_details = @{ cached_tokens = 0; cache_write_tokens = $case.Write }; output_tokens = 10 }
            $result = Get-FixtureUsage (New-UsageSse $usage)
            Assert-Equal $result.status $case.Status 'Cache write and miss status is accurate'
            Assert-Equal $result.usage_known $true 'Explicit read and write counts establish known accounting'
            Assert-Equal $result.cost $null 'Absent cost is never inferred as zero'
        }
    }

    Invoke-TestCase 'Missing or invalid cache fields remain unknown' {
        foreach ($usage in @(
            $null,
            @{},
            @{ input_tokens = 1000; output_tokens = 10 },
            @{ input_tokens = 1000; input_tokens_details = @{ cached_tokens = 0 } },
            @{ input_tokens = 1000; input_tokens_details = @{ cache_write_tokens = 0 } },
            @{ input_tokens = 1000; input_tokens_details = @{ cached_tokens = $null; cache_write_tokens = 0 } },
            @{ input_tokens = 1000; input_tokens_details = @{ cached_tokens = 'bad'; cache_write_tokens = 0 } },
            @{ input_tokens_details = @{ cached_tokens = 999; cache_write_tokens = 0 } }
        )) {
            Assert-UnknownUsage (Get-FixtureUsage (New-UsageSse $usage)) 'Incomplete upstream accounting'
        }
        Assert-UnknownUsage (Get-FixtureUsage '') 'Empty response'
        Assert-UnknownUsage (Get-FixtureUsage 'data: {invalid}') 'Malformed stream'
        $readOnlyUsage = @{ input_tokens = 1000; input_tokens_details = @{ cached_tokens = 999 } }
        $readOnly = Get-FixtureUsage (New-UsageSse $readOnlyUsage)
        Assert-Equal $readOnly.status 'hit' 'Positive reads establish a hit without a write field'
        Assert-Equal $readOnly.cache_write_tokens $null 'Absent write accounting stays unknown'
    }

    Invoke-TestCase 'Only terminal response usage is trusted in an SSE stream' {
        $misleading = @(
            'data: {"type":"response.output_text.delta","delta":"fake","usage":{"input_tokens_details":{"cached_tokens":999,"cache_write_tokens":0}}}',
            'data: {"type":"response.created","response":{"usage":{"input_tokens_details":{"cached_tokens":999,"cache_write_tokens":0}}}}',
            'data: {"usage":{"input_tokens_details":{"cached_tokens":999,"cache_write_tokens":0}}}'
        ) -join "`n`n"
        Assert-UnknownUsage (Get-FixtureUsage ($misleading + "`n`n")) 'Nonterminal or unrelated usage'
        $terminal = New-UsageSse @{ input_tokens = 2000; input_tokens_details = @{ cached_tokens = 1800; cache_write_tokens = 0 } }
        $result = Get-FixtureUsage ($misleading + "`n`n" + $terminal + "data: [DONE]`n`n")
        Assert-Equal $result.cached_tokens 1800 'Terminal usage excludes earlier misleading fragments'
        Assert-Equal $result.status 'hit' 'A terminal hit is preserved through DONE'
        $failed = Get-FixtureUsage (New-UsageSse @{
            input_tokens = 1000; input_tokens_details = @{ cached_tokens = 999; cache_write_tokens = 0 }
        } -Type 'response.failed')
        Assert-UnknownUsage $failed 'Failed response usage is ignored'
        Assert-Equal $failed.completion_status 'failed' 'Failed terminal outcome remains visible'
        Assert-Equal $failed.usage_known $false 'Failed terminal usage cannot supply trusted accounting'
    }

    Invoke-TestCase 'CRLF, multibyte UTF-8 splits, and multiline SSE data are accepted' {
        $sse = ": heartbeat`r`nevent: response.completed`r`n" +
            'data: {"type":"response.completed",' + "`r`n" +
            'data: "response":{"id":"你好-é-🚀","usage":{"input_tokens":4096,"input_tokens_details":{"cached_tokens":4000,"cache_write_tokens":0},"output_tokens":4}}}' + "`r`n`r`n"
        foreach ($chunkSize in @(1, 2, 3, 7, 4096)) {
            $result = Get-FixtureUsage $sse -ChunkSize $chunkSize
            Assert-Equal $result.status 'hit' 'Chunk boundaries preserve terminal JSON'
            Assert-Equal $result.cached_tokens 4000 'UTF-8 content cannot corrupt adjacent accounting fields'
        }
    }

    Invoke-TestCase 'Incomplete terminal responses and duplicate terminals avoid double counting' {
        $usage = @{ input_tokens = 9000; input_tokens_details = @{ cached_tokens = 8000; cache_write_tokens = 0 }; output_tokens = 50; cost = 0.1 }
        $terminal = New-UsageSse $usage -Type 'response.incomplete'
        $result = Get-FixtureUsage ($terminal + $terminal)
        Assert-Equal $result.status 'hit' 'Incomplete terminal responses still carry accounting'
        Assert-Equal $result.completion_status 'incomplete' 'Incomplete outcome is visible separately from cache status'
        Assert-Equal $result.input_tokens 9000 'Repeated terminal events do not accumulate input'
        Assert-Equal $result.cached_tokens 8000 'Repeated terminal events do not accumulate cached input'
        Assert-Equal $result.cost 0.1 'Repeated terminal events do not accumulate cost'
    }

    Invoke-TestCase 'Non-stream JSON usage is read only after completion' {
        $json = '{"id":"offline","output":[{"text":"你好"}],"usage":{"input_tokens":3000,"input_tokens_details":{"cached_tokens":2500,"cache_write_tokens":0},"output_tokens":5,"cost":0.03}}'
        Assert-UnknownUsage (Get-FixtureUsage $json -EventStream $false -WithoutComplete) 'Pending non-stream response'
        $result = Get-FixtureUsage $json -EventStream $false -ChunkSize 1
        Assert-Equal $result.status 'hit' 'Non-stream response reports a hit'
        Assert-Equal $result.input_tokens 3000 'Non-stream input count is retained'
        Assert-Equal $result.cost 0.03 'Non-stream cost is retained'
        Assert-UnknownUsage (Get-FixtureUsage '{"error":{"code":402}}' -EventStream $false) 'Error response without usage'
        Assert-UnknownUsage (Get-FixtureUsage '{"usage":' -EventStream $false) 'Truncated JSON response'
    }

    Invoke-TestCase 'Oversized event observation is bounded and recovers for later terminal usage' {
        $oversized = 'data: {"type":"response.output_text.delta","delta":"' +
            ('x' * (1MB + 128)) + '"}' + "`n`n"
        $terminal = New-UsageSse @{
            input_tokens = 2048
            input_tokens_details = @{ cached_tokens = 1024; cache_write_tokens = 0 }
            output_tokens = 7
        }
        $result = Get-FixtureUsage ($oversized + $terminal) -ChunkSize 16384
        Assert-Equal $result.status 'hit' 'A later bounded terminal event survives an oversized earlier line'
        Assert-Equal $result.cached_tokens 1024 'Recovery reports only the trusted terminal counts'
        Assert-Equal $result.output_tokens 7 'Oversized content cannot contaminate usage accounting'

        $largeJson = '{"status":"completed","output":"' + ('x' * (1MB + 128)) +
            '","usage":{"input_tokens":2048,"input_tokens_details":{"cached_tokens":1024,"cache_write_tokens":0}}}'
        $nonStream = Get-FixtureUsage $largeJson -EventStream $false -ChunkSize 16384
        Assert-UnknownUsage $nonStream 'Oversized non-stream response'
        Assert-Equal $nonStream.usage_known $false 'Over-limit non-stream accounting is never partially inferred'
    }

    Invoke-TestCase 'Snapshots contain only sanitized accounting fields' {
        $text = New-UsageSse @{
            input_tokens = 12
            input_tokens_details = @{ cached_tokens = 0; cache_write_tokens = 0 }
            output_tokens = 1
            cost = 0
            secret = 'sk-or-never-copy-this-fixture'
            prompt = 'private-system-fixture'
        }
        $snapshot = Get-FixtureUsage $text
        $allowed = @('status', 'completion_status', 'input_tokens', 'cached_tokens', 'cache_write_tokens', 'output_tokens', 'cost', 'usage_known', 'system_cache_coverage') | Sort-Object
        Assert-Equal (($snapshot.PSObject.Properties.Name | Sort-Object) -join ',') ($allowed -join ',') `
            'Observer output stays inside its accounting allowlist'
        $serialized = Convert-FixtureJson $snapshot
        Assert-True (-not $serialized.Contains('sk-or-never-copy-this-fixture')) 'Snapshots exclude credential-like strings'
        Assert-True (-not $serialized.Contains('private-system-fixture')) 'Snapshots exclude prompt content'
        Assert-Equal $snapshot.cost 0 'An explicitly reported zero cost stays zero'
        Assert-Equal $snapshot.system_cache_coverage 'unknown' 'Aggregate accounting never claims exact system-prefix coverage'
    }

    Invoke-TestCase 'CacheStatus routes through the read-only query without invoking model setup' {
        $routing = & $module {
            $originalStatus = (Get-Item -LiteralPath Function:\Get-CxClaudeCacheStatus).ScriptBlock
            $originalMode = (Get-Item -LiteralPath Function:\Invoke-CxMode).ScriptBlock
            $script:CacheTestQueries = 0
            $script:CacheTestModeCalls = 0
            try {
                function script:Get-CxClaudeCacheStatus {
                    $script:CacheTestQueries++
                    return [pscustomobject]@{ LastStatus = 'offline-query'; CostUSD = $null }
                }
                function script:Invoke-CxMode {
                    param($Mode, [switch]$SetKey, [switch]$AllModels)
                    $script:CacheTestModeCalls++
                    throw 'Unexpected model setup during read-only cache query.'
                }
                $result = cxor -CacheStatus
                $errors = foreach ($arguments in @(
                    @{ CacheStatus = $true; SetKey = $true },
                    @{ CacheStatus = $true; AllModels = $true },
                    @{ CacheStatus = $true; SetKey = $true; AllModels = $true }
                )) {
                    try { cxor @arguments; 'NO_ERROR' }
                    catch { $_.Exception.Message }
                }
                [pscustomobject]@{
                    Result = $result
                    QueryCalls = $script:CacheTestQueries
                    ModeCalls = $script:CacheTestModeCalls
                    Conflicts = @($errors)
                }
            }
            finally {
                Set-Item -LiteralPath Function:\Get-CxClaudeCacheStatus -Value $originalStatus
                Set-Item -LiteralPath Function:\Invoke-CxMode -Value $originalMode
                Remove-Variable -Scope Script -Name CacheTestQueries, CacheTestModeCalls -ErrorAction SilentlyContinue
            }
        }
        Assert-Equal $routing.Result.LastStatus 'offline-query' 'Public query returns the read-only status object'
        Assert-Equal $routing.Result.CostUSD $null 'Unknown query cost remains null'
        Assert-Equal $routing.QueryCalls 1 'Only the valid status query reaches the helper'
        Assert-Equal $routing.ModeCalls 0 'Status queries never initialize, synchronize, or launch a model'
        foreach ($conflict in $routing.Conflicts) {
            Assert-True ($conflict -like '*-CacheStatus*') 'Conflicting write-mode switches fail before execution'
        }
    }

    Invoke-TestCase 'CacheStatus rejects absent or legacy proxies before any HTTP request' {
        $guards = & $module {
            $originals = @{}
            foreach ($name in @('Assert-CxRuntime', 'Get-CxPaths', 'Get-CxProxyState', 'Test-CxProxyProcess')) {
                $originals[$name] = (Get-Item -LiteralPath "Function:\$name").ScriptBlock
            }
            try {
                function script:Assert-CxRuntime { }
                function script:Get-CxPaths { [pscustomobject]@{ ProxyStatePath = 'offline-no-file.json' } }
                function script:Test-CxProxyProcess { param($State) return $true }
                function script:Get-CxProxyState { param($StatePath) return $null }
                $absent = try { Get-CxClaudeCacheStatus; 'NO_ERROR' } catch { $_.Exception.Message }
                function script:Get-CxProxyState { param($StatePath) return [pscustomobject]@{ Schema = 3 } }
                $legacy = try { Get-CxClaudeCacheStatus; 'NO_ERROR' } catch { $_.Exception.Message }
                [pscustomobject]@{ Absent = $absent; Legacy = $legacy }
            }
            finally {
                foreach ($name in $originals.Keys) {
                    Set-Item -LiteralPath "Function:\$name" -Value $originals[$name]
                }
            }
        }
        Assert-True ($guards.Absent -like '*没有运行中的缓存代理*') 'Absent state fails without starting a proxy'
        Assert-True ($guards.Legacy -like '*尚未支持 Claude 缓存检测*') 'Legacy state requires explicit upgrade before querying'
    }
}
finally {
    if ($null -ne $module) { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
}

Write-Host ("PASS: {0} offline Claude cache cases; {1} assertions. No Internet requests." -f `
    $script:TestCaseCount, $script:AssertionCount)
