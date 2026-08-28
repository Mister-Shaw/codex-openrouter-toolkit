[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AssertionCount = 0
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleManifest = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psd1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:AssertionCount++
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Assert-True `
        -Condition ($Actual -ceq $Expected) `
        -Message "$Message. Expected=[$Expected] Actual=[$Actual]"
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $caught = $null
    try { & $Action }
    catch { $caught = $_ }
    Assert-True `
        -Condition ($null -ne $caught) `
        -Message "$Message should throw"
    Assert-True `
        -Condition ($caught.Exception.Message -like $Pattern) `
        -Message "$Message error text: $($caught.Exception.Message)"
}

try {
    $powerShellFiles = @(Get-ChildItem `
        -LiteralPath $repositoryRoot `
        -Recurse `
        -File `
        -Include '*.ps1', '*.psm1', '*.psd1')
    foreach ($file in $powerShellFiles) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-Equal `
            -Actual $parseErrors.Count `
            -Expected 0 `
            -Message "PowerShell AST parse: $($file.FullName)"
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $moduleManifest
    Assert-Equal `
        -Actual $manifest.ModuleVersion.ToString() `
        -Expected '0.1.8' `
        -Message 'Module version'
    $manifestExports = @($manifest.FunctionsToExport | Sort-Object)
    Assert-Equal `
        -Actual $manifestExports.Count `
        -Expected 2 `
        -Message 'Manifest export count'
    Assert-Equal `
        -Actual ($manifestExports -join ',') `
        -Expected 'cx,cxor' `
        -Message 'Manifest exports only cx and cxor'

    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $module = Get-Module CodexOpenRouter -ErrorAction Stop
    $runtimeExports = @(Get-Command `
        -Module CodexOpenRouter `
        -CommandType Function | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-Equal `
        -Actual $runtimeExports.Count `
        -Expected 2 `
        -Message 'Runtime export count'
    Assert-Equal `
        -Actual ($runtimeExports -join ',') `
        -Expected 'cx,cxor' `
        -Message 'Runtime exports only cx and cxor'

    $moduleSource = Get-Content -LiteralPath (
        Join-Path $repositoryRoot 'src\CodexOpenRouter\CodexOpenRouter.psm1'
    ) -Raw
    Assert-True `
        -Condition ($moduleSource.Contains('$startInfo.StandardOutputEncoding = $utf8')) `
        -Message 'CLI stdout decoding is pinned to UTF-8'
    Assert-True `
        -Condition ($moduleSource.Contains('$startInfo.StandardErrorEncoding = $utf8')) `
        -Message 'CLI stderr decoding is pinned to UTF-8'
    Assert-True `
        -Condition ($moduleSource.Contains('HttpCompletionOption.ResponseHeadersRead')) `
        -Message 'Proxy starts forwarding after upstream response headers arrive'
    Assert-True `
        -Condition ($moduleSource.Contains('ReadAsStreamAsync')) `
        -Message 'Proxy reads the upstream response as a stream'
    Assert-True `
        -Condition ($moduleSource.Contains('FlushAsync')) `
        -Message 'Proxy flushes streamed response chunks'
    Assert-True `
        -Condition ($moduleSource.Contains('outgoing.ContentType = string.Join')) `
        -Message 'Proxy preserves the restricted SSE content-type header'

    $proxyRewrite = & $module {
        Initialize-CxProxyType
        $claudeInput = '{"model":"anthropic/claude-opus-5","input":[{"role":"user","content":"hello"}],"prompt_cache_key":"task-123","stream":true}'
        $tildeInput = '{"model":"~Anthropic/Claude-Opus-Latest","input":"hello"}'
        $existingInput = '{"model":"anthropic/claude-opus-5","cache_control":{"type":"ephemeral","ttl":"1h"},"input":"hello","prompt_cache_key":"task-existing","stream":true}'
        $nullInput = '{"model":"anthropic/claude-opus-5","cache_control":null,"input":"hello"}'
        $passThroughInputs = [ordered]@{
            OpenAI = ' { "model" : "openai/gpt-5.6-sol", "input" : "\u4f60\u597d", "prompt_cache_key" : "task-openai", "prompt_cache_retention" : "24h", "stream" : true } '
            Gemini = "{`n  `"model`": `"google/gemini-2.5-pro`",`n  `"input`": `"hello`",`n  `"prompt_cache_key`": `"task-gemini`"`n}"
            DeepSeek = '{"model":"deepseek/deepseek-chat","input":"hello","prompt_cache_key":"task-deepseek"}'
            Unknown = '{"model":"meta-llama/llama-3.3-70b-instruct","input":"hello","prompt_cache_key":"task-unknown"}'
            MissingModel = '{ "input": "hello", "prompt_cache_key": "task-missing" }'
            NumericModel = '{ "model": 42, "input": "hello", "prompt_cache_key": "task-numeric" }'
        }
        $passThrough = foreach ($entry in $passThroughInputs.GetEnumerator()) {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$entry.Value)
            $rewrittenBytes = [CodexOpenRouter.OpenRouterCacheProxyV1]::RewriteRequestBody(
                $bytes
            )
            [pscustomobject]@{
                Label = [string]$entry.Key
                Original = [Convert]::ToBase64String($bytes)
                Rewritten = [Convert]::ToBase64String($rewrittenBytes)
                Json = [Text.Encoding]::UTF8.GetString($rewrittenBytes)
            }
        }
        [pscustomobject]@{
            ClaudeInput = $claudeInput
            Claude = [CodexOpenRouter.OpenRouterCacheProxyV1]::RewriteRequestJson(
                $claudeInput
            )
            Tilde = [CodexOpenRouter.OpenRouterCacheProxyV1]::RewriteRequestJson(
                $tildeInput
            )
            ExistingInput = $existingInput
            Existing = [CodexOpenRouter.OpenRouterCacheProxyV1]::RewriteRequestJson(
                $existingInput
            )
            NullInput = $nullInput
            Null = [CodexOpenRouter.OpenRouterCacheProxyV1]::RewriteRequestJson(
                $nullInput
            )
            PassThrough = @($passThrough)
        }
    }
    $rewrittenClaude = $proxyRewrite.Claude | ConvertFrom-Json
    $rewrittenTilde = $proxyRewrite.Tilde | ConvertFrom-Json
    Assert-Equal `
        -Actual ([string]$rewrittenClaude.cache_control.type) `
        -Expected 'ephemeral' `
        -Message 'Claude Responses request receives five-minute prompt caching'
    Assert-Equal `
        -Actual ([string]$rewrittenClaude.prompt_cache_key) `
        -Expected 'task-123' `
        -Message 'Claude request preserves the Codex prompt cache key'
    Assert-True `
        -Condition ($null -eq $rewrittenClaude.PSObject.Properties['session_id']) `
        -Message 'Proxy does not create a cross-task session id'
    Assert-Equal `
        -Actual ([string]$rewrittenClaude.input[0].content) `
        -Expected 'hello' `
        -Message 'Claude request preserves input content'
    Assert-Equal `
        -Actual ([bool]$rewrittenClaude.stream) `
        -Expected $true `
        -Message 'Claude request preserves streaming mode'
    Assert-Equal `
        -Actual ([string]$rewrittenTilde.cache_control.type) `
        -Expected 'ephemeral' `
        -Message 'Tilde Claude alias receives prompt caching case-insensitively'
    Assert-Equal `
        -Actual ([string]$proxyRewrite.Existing) `
        -Expected ([string]$proxyRewrite.ExistingInput) `
        -Message 'Existing cache control including TTL is preserved byte-for-byte'
    Assert-Equal `
        -Actual ([string]$proxyRewrite.Null) `
        -Expected ([string]$proxyRewrite.NullInput) `
        -Message 'Explicit null cache control is preserved byte-for-byte'
    $rewrittenExisting = $proxyRewrite.Existing | ConvertFrom-Json
    Assert-Equal `
        -Actual ([string]$rewrittenExisting.cache_control.ttl) `
        -Expected '1h' `
        -Message 'Existing Claude cache TTL remains unchanged'
    Assert-Equal `
        -Actual ([string]$rewrittenExisting.prompt_cache_key) `
        -Expected 'task-existing' `
        -Message 'Existing Claude cache control preserves the prompt cache key'
    Assert-Equal `
        -Actual ([bool]$rewrittenExisting.stream) `
        -Expected $true `
        -Message 'Existing Claude cache control preserves streaming mode'
    foreach ($case in $proxyRewrite.PassThrough) {
        Assert-Equal `
            -Actual ([string]$case.Rewritten) `
            -Expected ([string]$case.Original) `
            -Message "$($case.Label) request remains byte-for-byte unchanged"
        $parsed = [string]$case.Json | ConvertFrom-Json
        Assert-True `
            -Condition ($null -eq $parsed.PSObject.Properties['cache_control']) `
            -Message "$($case.Label) receives no incompatible Claude cache control"
        Assert-True `
            -Condition ($null -eq $parsed.PSObject.Properties['session_id']) `
            -Message "$($case.Label) receives no synthetic session id"
    }
    $openAiCase = $proxyRewrite.PassThrough |
        Where-Object Label -CEQ 'OpenAI' |
        Select-Object -First 1
    $rewrittenOpenAi = [string]$openAiCase.Json | ConvertFrom-Json
    Assert-Equal `
        -Actual ([string]$rewrittenOpenAi.prompt_cache_key) `
        -Expected 'task-openai' `
        -Message 'OpenAI automatic caching keeps the Codex prompt cache key'
    Assert-Equal `
        -Actual ([string]$rewrittenOpenAi.prompt_cache_retention) `
        -Expected '24h' `
        -Message 'OpenAI provider-specific prompt cache settings remain intact'
    Assert-Equal `
        -Actual ([bool]$rewrittenOpenAi.stream) `
        -Expected $true `
        -Message 'OpenAI automatic caching preserves streaming mode'
    Assert-ThrowsLike `
        -Action {
            & $module {
                Initialize-CxProxyType
                [void][CodexOpenRouter.OpenRouterCacheProxyV1]::RewriteRequestJson('{')
            }
        } `
        -Pattern '*' `
        -Message 'Malformed proxy JSON is rejected'

    $requestKey = 'sk-' + 'or-' + ('q' * 24)
    $requestResult = & $module {
        param($ApiKey)

        $request = New-CxOpenRouterCatalogRequest -ApiKey $ApiKey `
            -ClientVersion '0.150.0'
        try {
            [pscustomobject]@{
                Method = $request.Method.Method
                Uri = $request.RequestUri.AbsoluteUri
                AuthScheme = $request.Headers.Authorization.Scheme
                AuthParameter = $request.Headers.Authorization.Parameter
                Originator = @($request.Headers.GetValues('originator')) -join ','
            }
        }
        finally { $request.Dispose() }
    } $requestKey
    Assert-Equal `
        -Actual ([string]$requestResult.Method) `
        -Expected 'GET' `
        -Message 'OpenRouter catalog request uses GET'
    Assert-Equal `
        -Actual ([string]$requestResult.Uri) `
        -Expected 'https://openrouter.ai/api/v1/models?client_version=0.150.0' `
        -Message 'OpenRouter catalog request targets the versioned Codex endpoint'
    Assert-Equal `
        -Actual ([string]$requestResult.AuthScheme) `
        -Expected 'Bearer' `
        -Message 'OpenRouter catalog request uses bearer authentication'
    Assert-Equal `
        -Actual ([string]$requestResult.AuthParameter) `
        -Expected $requestKey `
        -Message 'OpenRouter catalog request carries the supplied key'
    Assert-Equal `
        -Actual ([string]$requestResult.Originator) `
        -Expected 'Codex Desktop' `
        -Message 'OpenRouter catalog request asks for the Codex-native schema'

    $originalVersionInvoke = & $module {
        (Get-Item -LiteralPath Function:\Invoke-CxProcess).ScriptBlock
    }
    try {
        & $module {
            function script:Invoke-CxProcess {
                param(
                    [string]$FilePath,
                    [string[]]$ArgumentList,
                    [hashtable]$Environment,
                    [int]$TimeoutMilliseconds = 90000
                )
                [pscustomobject]@{
                    ExitCode = 0
                    StandardOutput = "codex-cli 0.150.0-alpha.12.2`r`n"
                    StandardError = ''
                }
            }
        }
        $clientVersion = & $module {
            Get-CxCodexClientVersion -CliPath 'C:\cx-test\codex.exe'
        }
        Assert-Equal `
            -Actual ([string]$clientVersion) `
            -Expected '0.150.0' `
            -Message 'Codex client version uses the three-part catalog version'
    }
    finally {
        & $module {
            param($Original)
            Set-Item -LiteralPath Function:\Invoke-CxProcess -Value $Original
        } $originalVersionInvoke
    }

    $tomlStringResult = & $module {
        $controlCharacters = -join @(
            [char]8,
            [char]9,
            [char]10,
            [char]12,
            [char]13,
            [char]34,
            [char]92,
            [char]0,
            [char]127
        )
        [pscustomobject]@{
            WindowsPath = ConvertTo-CxTomlString `
                'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            Controls = ConvertTo-CxTomlString $controlCharacters
        }
    }
    Assert-Equal `
        -Actual $tomlStringResult.WindowsPath `
        -Expected '"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"' `
        -Message 'TOML string escapes Windows path separators exactly once'
    Assert-Equal `
        -Actual $tomlStringResult.Controls `
        -Expected '"\b\t\n\f\r\"\\\u0000\u007F"' `
        -Message 'TOML string escapes special characters exactly once'

    $catalogPath = Join-Path `
        ([IO.Path]::GetTempPath()) `
        'cx-tests\openrouter-model-catalog.json'
    $authCommand = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $proxyBaseUrl = 'http://127.0.0.1:43127/api/v1'
    $proxyToken = 'A' * 64
    $proxyStatePath = Join-Path `
        ([IO.Path]::GetTempPath()) `
        'cx-tests\openrouter-cache-proxy.json'
    $tomlInput = @'
model = "old/default"
model_reasoning_effort = "high"
custom_root = "keep-root"

[features]
keep_feature = true

[model_providers.other]
name = "Keep Other"
base_url = "https://keep.example"

["model_providers"."openrouter"]
name = "Old OpenRouter"
base_url = "https://old-provider.example"
old_only = "remove-me"

["model_providers"."openrouter".auth]
command = "old-auth.exe"
args = ["old-secret-source"]

[[array.table]]
name = "keep-array-item"

[tooling]
keep_tooling = "yes"
'@
    $openRouterModel = '~openai/gpt-latest'
    $tomlResult = & $module {
        param(
            $Content,
            $CatalogPath,
            $AuthCommand,
            $Model,
            $ProxyBaseUrl,
            $ProxyToken,
            $ProxyStatePath
        )

        $openRouter = Update-CxConfigContent `
            -Content $Content `
            -Mode OpenRouter `
            -CatalogPath $CatalogPath `
            -AuthCommand $AuthCommand `
            -ProxyBaseUrl $ProxyBaseUrl `
            -ProxyToken $ProxyToken `
            -ProxyStatePath $ProxyStatePath `
            -Model $Model
        $openRouterAgain = Update-CxConfigContent `
            -Content $openRouter `
            -Mode OpenRouter `
            -CatalogPath $CatalogPath `
            -AuthCommand $AuthCommand `
            -ProxyBaseUrl $ProxyBaseUrl `
            -ProxyToken $ProxyToken `
            -ProxyStatePath $ProxyStatePath `
            -Model $Model
        $default = Update-CxConfigContent `
            -Content $openRouter `
            -Mode Default
        [pscustomobject]@{
            OpenRouter = $openRouter
            OpenRouterAgain = $openRouterAgain
            Default = $default
            CatalogLiteral = ConvertTo-CxTomlString `
                ([IO.Path]::GetFullPath($CatalogPath))
        }
    } $tomlInput $catalogPath $authCommand $openRouterModel `
        $proxyBaseUrl $proxyToken $proxyStatePath

    foreach ($needle in @(
            'custom_root = "keep-root"',
            '[features]',
            'keep_feature = true',
            '[model_providers.other]',
            'base_url = "https://keep.example"',
            '[[array.table]]',
            'name = "keep-array-item"',
            '[tooling]',
            'keep_tooling = "yes"'
        )) {
        Assert-True `
            -Condition $tomlResult.OpenRouter.Contains($needle) `
            -Message "OpenRouter TOML preserves unrelated content: $needle"
        Assert-True `
            -Condition $tomlResult.Default.Contains($needle) `
            -Message "Default TOML preserves unrelated content: $needle"
    }
    foreach ($removed in @(
            'old/default',
            'https://old-provider.example',
            'old_only = "remove-me"',
            'old-auth.exe',
            'old-secret-source'
        )) {
        Assert-True `
            -Condition (-not $tomlResult.OpenRouter.Contains($removed)) `
            -Message "OpenRouter TOML removes old managed value: $removed"
        Assert-True `
            -Condition (-not $tomlResult.Default.Contains($removed)) `
            -Message "Default TOML removes old managed value: $removed"
    }
    Assert-Equal `
        -Actual ([regex]::Matches(
                $tomlResult.OpenRouter,
                '(?m)^\[model_providers\.openrouter\]\r?$'
            ).Count) `
        -Expected 1 `
        -Message 'OpenRouter TOML has one provider table'
    Assert-Equal `
        -Actual ([regex]::Matches(
                $tomlResult.OpenRouter,
                '(?m)^\[model_providers\.openrouter\.auth\]\r?$'
            ).Count) `
        -Expected 1 `
        -Message 'OpenRouter TOML has one provider auth table'
    Assert-True `
        -Condition (-not $tomlResult.OpenRouter.Contains(
            '["model_providers"."openrouter"]'
        )) `
        -Message 'OpenRouter TOML removes the quoted legacy provider table'
    Assert-True `
        -Condition (-not $tomlResult.OpenRouter.Contains(
            '["model_providers"."openrouter".auth]'
        )) `
        -Message 'OpenRouter TOML removes the quoted legacy auth table'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            "base_url = `"$proxyBaseUrl`""
        ) `
        -Message 'OpenRouter TOML writes the loopback cache proxy'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            '[model_providers.openrouter.http_headers]'
        ) `
        -Message 'OpenRouter TOML writes the proxy header table'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            "`"x-cxor-proxy-token`" = `"$proxyToken`""
        ) `
        -Message 'OpenRouter TOML writes the proxy authentication token'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            'supports_websockets = false'
        ) `
        -Message 'OpenRouter TOML keeps the proxy on SSE transport'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            "command = $($tomlStringResult.WindowsPath)"
        ) `
        -Message 'OpenRouter TOML writes a valid Windows auth command path'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            "model = `"$openRouterModel`""
        ) `
        -Message 'OpenRouter TOML writes the synchronized default model'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            'model_provider = "openrouter"'
        ) `
        -Message 'OpenRouter TOML writes the provider selector'
    Assert-True `
        -Condition $tomlResult.OpenRouter.Contains(
            "model_catalog_json = $($tomlResult.CatalogLiteral)"
        ) `
        -Message 'OpenRouter TOML writes the synchronized catalog path'
    Assert-Equal `
        -Actual $tomlResult.OpenRouterAgain `
        -Expected $tomlResult.OpenRouter `
        -Message 'OpenRouter TOML conversion is idempotent'
    Assert-True `
        -Condition (-not $tomlResult.Default.Contains(
            '[model_providers.openrouter]'
        )) `
        -Message 'Default TOML removes the OpenRouter provider'

    $catalogObject = [ordered]@{
        source = 'keep-root'
        metadata = [ordered]@{ revision = 7; keep = $true }
        models = @(
            [ordered]@{
                slug = 'vendor/model-a'
                display_name = 'Model A'
                base_instructions = 'old-a'
                unknown_model_field = 'keep-a'
            },
            [ordered]@{
                slug = '~openai/gpt-latest'
                model_messages = [ordered]@{
                    instructions_template = 'old-b'
                    unknown_message_field = 'keep-b'
                }
                modalities = @('text')
            },
            [ordered]@{
                slug = 'vendor/model-c'
                vendor_data = [ordered]@{ tier = 'preview' }
            }
        )
    }
    $catalogInput = $catalogObject | ConvertTo-Json -Depth 20 -Compress
    $catalogResult = & $module {
        param($Content)

        $converted = Convert-CxCatalogPrompt -Content $Content -AllModels
        [pscustomobject]@{
            Converted = $converted
            ConvertedAgain = Convert-CxCatalogPrompt -Content $converted -AllModels
            Instructions = $script:EmptyInstructions
        }
    } $catalogInput
    $convertedCatalog = $catalogResult.Converted | ConvertFrom-Json
    Assert-Equal `
        -Actual ([string]$convertedCatalog.source) `
        -Expected 'keep-root' `
        -Message 'Catalog preserves an unknown root field'
    Assert-Equal `
        -Actual ([int]$convertedCatalog.metadata.revision) `
        -Expected 7 `
        -Message 'Catalog preserves unknown root metadata'
    Assert-Equal `
        -Actual ([string]$convertedCatalog.models[0].unknown_model_field) `
        -Expected 'keep-a' `
        -Message 'Catalog preserves an unknown model field'
    Assert-Equal `
        -Actual ([string]$convertedCatalog.models[1].model_messages.unknown_message_field) `
        -Expected 'keep-b' `
        -Message 'Catalog preserves an unknown model_messages field'
    Assert-Equal `
        -Actual ([string]$convertedCatalog.models[2].vendor_data.tier) `
        -Expected 'preview' `
        -Message 'Catalog preserves unknown nested model data'
    foreach ($model in @($convertedCatalog.models)) {
        Assert-True `
            -Condition ($null -ne $model.PSObject.Properties['base_instructions']) `
            -Message "Catalog keeps base_instructions present: $($model.slug)"
        Assert-True `
            -Condition ($model.base_instructions -is [string]) `
            -Message "Catalog keeps base_instructions as a string: $($model.slug)"
        Assert-Equal `
            -Actual ([string]$model.base_instructions) `
            -Expected $catalogResult.Instructions `
            -Message "Catalog clears base_instructions: $($model.slug)"
        Assert-True `
            -Condition ($null -ne $model.model_messages.PSObject.Properties['instructions_template']) `
            -Message "Catalog keeps instructions_template present: $($model.slug)"
        Assert-True `
            -Condition ($model.model_messages.instructions_template -is [string]) `
            -Message "Catalog keeps instructions_template as a string: $($model.slug)"
        Assert-Equal `
            -Actual ([string]$model.model_messages.instructions_template) `
            -Expected $catalogResult.Instructions `
            -Message "Catalog clears instructions_template: $($model.slug)"
    }
    Assert-Equal `
        -Actual $catalogResult.Instructions `
        -Expected '' `
        -Message 'Catalog replacement instructions are empty'
    Assert-Equal `
        -Actual $catalogResult.ConvertedAgain `
        -Expected $catalogResult.Converted `
        -Message 'Catalog prompt conversion is idempotent'

    $selectionCatalog = [ordered]@{
        source = 'selection-test'
        models = @(
            [ordered]@{
                slug = 'vendor/other-model'
                display_name = 'Other Model'
                visibility = 'list'
            },
            [ordered]@{
                slug = 'anthropic/claude-sonnet-5'
                display_name = 'Old Sonnet Name'
                visibility = 'hide'
            },
            [ordered]@{
                slug = 'OPENAI/GPT-5.6-SOL'
                display_name = 'Old Sol Name'
            },
            [ordered]@{
                slug = '~anthropic/claude-opus-latest'
                display_name = 'Old Opus Alias'
                visibility = 'hide'
            },
            [ordered]@{
                slug = '~openai/gpt-latest'
                display_name = 'Old GPT Alias'
                visibility = 'hide'
            },
            [ordered]@{
                slug = 'openai/gpt-5.3-codex'
                display_name = 'Old Codex Name'
                visibility = 'list'
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    $selectionResult = & $module {
        param($Content)

        $curated = Convert-CxCatalogPrompt -Content $Content
        [pscustomobject]@{
            Curated = $curated
            CuratedAgain = Convert-CxCatalogPrompt -Content $curated
            AllModels = Convert-CxCatalogPrompt -Content $Content -AllModels
        }
    } $selectionCatalog
    $curatedCatalog = $selectionResult.Curated | ConvertFrom-Json
    $curatedModels = @($curatedCatalog.models)
    $curatedVisible = @($curatedModels | Where-Object { $_.visibility -ceq 'list' })
    Assert-Equal `
        -Actual ($curatedVisible.slug -join ',') `
        -Expected '~openai/gpt-latest,OPENAI/GPT-5.6-SOL,openai/gpt-5.3-codex,~anthropic/claude-opus-latest,anthropic/claude-sonnet-5' `
        -Message 'Curated catalog lists only featured models in configured order'
    Assert-Equal `
        -Actual ([string]$curatedVisible[1].display_name) `
        -Expected 'GPT-5.6 Sol' `
        -Message 'Curated catalog normalizes featured display names case-insensitively'
    Assert-Equal `
        -Actual ([int]$curatedVisible[1].priority) `
        -Expected 3 `
        -Message 'Curated catalog assigns stable featured priority'
    $curatedHidden = @($curatedModels | Where-Object { $_.visibility -ceq 'hide' })
    Assert-Equal `
        -Actual ($curatedHidden.slug -join ',') `
        -Expected 'vendor/other-model' `
        -Message 'Curated catalog hides non-featured models'
    Assert-Equal `
        -Actual $selectionResult.CuratedAgain `
        -Expected $selectionResult.Curated `
        -Message 'Curated catalog conversion is idempotent'

    $allCatalog = $selectionResult.AllModels | ConvertFrom-Json
    $allModels = @($allCatalog.models)
    Assert-Equal `
        -Actual ([string]$allModels[0].visibility) `
        -Expected 'list' `
        -Message 'All-model catalog keeps listed models visible'
    Assert-Equal `
        -Actual ([string]$allModels[1].visibility) `
        -Expected 'list' `
        -Message 'All-model catalog reveals previously hidden models'
    Assert-Equal `
        -Actual ([string]$allModels[2].visibility) `
        -Expected 'list' `
        -Message 'All-model catalog adds missing list visibility'
    Assert-Equal `
        -Actual ([string]$allModels[2].display_name) `
        -Expected 'Old Sol Name' `
        -Message 'All-model catalog preserves upstream display names'

    Assert-ThrowsLike `
        -Action {
            & $module {
                Convert-CxCatalogPrompt -Content '' | Out-Null
            }
        }.GetNewClosure() `
        -Pattern '*模型目录内容为空*' `
        -Message 'Catalog conversion reports empty content explicitly'

    $resolverKey = 'sk-' + 'or-' + ('r' * 24)
    $resolverResult = & $module {
        param($ValidCatalog, $ApiKey)

        Resolve-CxCatalogCandidate -Candidates @(
            [pscustomobject]@{
                Label = 'stdout'
                Content = '{invalid-json'
                IsPrevious = $false
            },
            [pscustomobject]@{
                Label = 'provider cache'
                Content = ''
                IsPrevious = $false
            },
            [pscustomobject]@{
                Label = 'previous catalog'
                Content = $ValidCatalog
                IsPrevious = $true
            }
        ) -ApiKey $ApiKey -StandardError ''
    } $selectionCatalog $resolverKey
    Assert-Equal `
        -Actual ([string]$resolverResult.Source) `
        -Expected 'previous catalog' `
        -Message 'Catalog resolver skips invalid and empty candidates'
    Assert-True `
        -Condition ([bool]$resolverResult.UsedPreviousCatalog) `
        -Message 'Catalog resolver reports previous-catalog fallback'
    Assert-Equal `
        -Actual @($resolverResult.Models).Count `
        -Expected 6 `
        -Message 'Catalog resolver returns the selected models'

    $resolverFailure = $null
    try {
        & $module {
            param($ApiKey)

            Resolve-CxCatalogCandidate -Candidates @(
                [pscustomobject]@{ Label = 'stdout'; Content = '' },
                [pscustomobject]@{ Label = 'cache'; Content = ' ' }
            ) -ApiKey $ApiKey -StandardError "upstream rejected $ApiKey"
        } $resolverKey | Out-Null
    }
    catch { $resolverFailure = $_.Exception.Message }
    Assert-True `
        -Condition (-not [string]::IsNullOrWhiteSpace($resolverFailure)) `
        -Message 'Catalog resolver throws when every candidate is empty'
    Assert-True `
        -Condition ($resolverFailure -like '*stdout：空或不存在*cache：空或不存在*') `
        -Message 'Catalog resolver summarizes empty candidates'
    Assert-True `
        -Condition ($resolverFailure -notlike '*Cannot bind argument*') `
        -Message 'Catalog resolver avoids the raw parameter binding error'
    Assert-True `
        -Condition (-not $resolverFailure.Contains($resolverKey)) `
        -Message 'Catalog resolver redacts API keys from diagnostics'
    Assert-True `
        -Condition ($resolverFailure -like '*<redacted>*') `
        -Message 'Catalog resolver marks redacted stderr content'

    $syncTestRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'cx-sync-tests-' + [Guid]::NewGuid().ToString('N')
    )
    [void](New-Item -ItemType Directory -Path $syncTestRoot -ErrorAction Stop)
    $originalInvokeCxProcess = & $module {
        (Get-Item -LiteralPath Function:\Invoke-CxProcess).ScriptBlock
    }
    $originalGetCxCodexClientVersion = & $module {
        (Get-Item -LiteralPath Function:\Get-CxCodexClientVersion).ScriptBlock
    }
    $originalInvokeCxOpenRouterCatalogRequest = & $module {
        (Get-Item -LiteralPath Function:\Invoke-CxOpenRouterCatalogRequest).ScriptBlock
    }
    try {
        & $module {
            function script:Invoke-CxProcess {
                param(
                    [string]$FilePath,
                    [string[]]$ArgumentList,
                    [hashtable]$Environment,
                    [int]$TimeoutMilliseconds = 90000
                )

                $script:SyncTestProcessCalls++
                if (-not [string]::IsNullOrWhiteSpace($script:SyncTestCacheContent)) {
                    Write-CxTextFileAtomic `
                        -Path (Join-Path $Environment.CODEX_HOME $script:SyncTestCacheName) `
                        -Content $script:SyncTestCacheContent
                }
                return [pscustomobject]@{
                    ExitCode = $script:SyncTestExitCode
                    StandardOutput = $script:SyncTestStandardOutput
                    StandardError = $script:SyncTestStandardError
                }
            }
            function script:Get-CxCodexClientVersion {
                param([string]$CliPath)

                $script:SyncTestVersionCalls++
                return '0.150.0'
            }
            function script:Invoke-CxOpenRouterCatalogRequest {
                param([string]$ApiKey, [string]$ClientVersion)

                $script:SyncTestDirectCalls++
                $script:SyncTestDirectVersion = $ClientVersion
                if ($script:SyncTestDirectShouldFail) {
                    throw "direct catalog unavailable $ApiKey"
                }
                return $script:SyncTestDirectContent
            }
        }

        & $module {
            param($DirectContent)
            $script:SyncTestCacheName = 'models_cache.openrouter.json'
            $script:SyncTestCacheContent = ''
            $script:SyncTestExitCode = 0
            $script:SyncTestStandardOutput = ''
            $script:SyncTestStandardError = ''
            $script:SyncTestProcessCalls = 0
            $script:SyncTestVersionCalls = 0
            $script:SyncTestDirectCalls = 0
            $script:SyncTestDirectVersion = ''
            $script:SyncTestDirectShouldFail = $false
            $script:SyncTestDirectContent = $DirectContent
        } $selectionCatalog
        $directCatalogPath = Join-Path $syncTestRoot 'direct-catalog.json'
        $directSync = & $module {
            param($CatalogPath, $ApiKey)
            Sync-CxOpenRouterCatalog `
                -CliPath 'C:\cx-test\codex.exe' `
                -ApiKey $ApiKey `
                -CatalogPath $CatalogPath `
                -AuthCommand 'C:\cx-test\powershell.exe'
        } $directCatalogPath $resolverKey
        $directCounters = & $module {
            [pscustomobject]@{
                Process = $script:SyncTestProcessCalls
                Version = $script:SyncTestVersionCalls
                Direct = $script:SyncTestDirectCalls
                DirectVersion = $script:SyncTestDirectVersion
            }
        }
        Assert-True `
            -Condition (-not [bool]$directSync.UsedPreviousCatalog) `
            -Message 'Synchronization publishes a fresh direct OpenRouter catalog'
        Assert-Equal `
            -Actual ([string]$directSync.CatalogSource) `
            -Expected 'OpenRouter Codex API' `
            -Message 'Synchronization reports the direct OpenRouter catalog source'
        Assert-Equal `
            -Actual ([int]$directCounters.Version) `
            -Expected 1 `
            -Message 'Direct synchronization resolves the CLI catalog version once'
        Assert-Equal `
            -Actual ([int]$directCounters.Direct) `
            -Expected 1 `
            -Message 'Direct synchronization calls the OpenRouter catalog once'
        Assert-Equal `
            -Actual ([string]$directCounters.DirectVersion) `
            -Expected '0.150.0' `
            -Message 'Direct synchronization sends the parsed client version'
        Assert-Equal `
            -Actual ([int]$directCounters.Process) `
            -Expected 0 `
            -Message 'Valid direct synchronization skips the CLI catalog fallback'

        $providerCatalogPath = Join-Path $syncTestRoot 'provider-catalog.json'
        & $module {
            param($CacheContent)
            $script:SyncTestCacheName = 'models_cache.openrouter.json'
            $script:SyncTestCacheContent = $CacheContent
            $script:SyncTestExitCode = 0
            $script:SyncTestStandardOutput = ''
            $script:SyncTestStandardError = ''
            $script:SyncTestDirectShouldFail = $true
            $script:SyncTestDirectContent = ''
        } $selectionCatalog
        $providerSync = & $module {
            param($CatalogPath, $ApiKey)
            Sync-CxOpenRouterCatalog `
                -CliPath 'C:\cx-test\codex.exe' `
                -ApiKey $ApiKey `
                -CatalogPath $CatalogPath `
                -AuthCommand 'C:\cx-test\powershell.exe'
        } $providerCatalogPath $resolverKey
        Assert-True `
            -Condition (-not [bool]$providerSync.UsedPreviousCatalog) `
            -Message 'Synchronization uses a valid provider-specific temporary cache'
        Assert-Equal `
            -Actual ([string]$providerSync.CatalogSource) `
            -Expected '临时缓存 models_cache.openrouter.json' `
            -Message 'Synchronization reports the provider-specific cache source'
        Assert-Equal `
            -Actual ([int]$providerSync.VisibleModelCount) `
            -Expected 5 `
            -Message 'Provider-cache synchronization applies curated visibility'
        Assert-Equal `
            -Actual @(Get-ChildItem -LiteralPath $syncTestRoot -Directory `
                -Filter '.cxor-*' -ErrorAction SilentlyContinue).Count `
            -Expected 0 `
            -Message 'Synchronization removes its temporary CLI home'

        $previousCatalogPath = Join-Path $syncTestRoot 'previous-catalog.json'
        [IO.File]::WriteAllText(
            $previousCatalogPath,
            $selectionCatalog,
            [Text.UTF8Encoding]::new($false)
        )
        & $module {
            $script:SyncTestCacheContent = ''
            $script:SyncTestExitCode = 0
            $script:SyncTestStandardOutput = ''
            $script:SyncTestStandardError = 'remote catalog unavailable'
        }
        $previousSync = & $module {
            param($CatalogPath, $ApiKey)
            Sync-CxOpenRouterCatalog `
                -CliPath 'C:\cx-test\codex.exe' `
                -ApiKey $ApiKey `
                -CatalogPath $CatalogPath `
                -AuthCommand 'C:\cx-test\powershell.exe'
        } $previousCatalogPath $resolverKey
        Assert-True `
            -Condition ([bool]$previousSync.UsedPreviousCatalog) `
            -Message 'Synchronization can reuse the last valid OpenRouter catalog'
        Assert-Equal `
            -Actual ([string]$previousSync.CatalogSource) `
            -Expected '上次有效 OpenRouter 目录' `
            -Message 'Synchronization reports the previous-catalog source'

        $previousAllSync = & $module {
            param($CatalogPath, $ApiKey)
            Sync-CxOpenRouterCatalog `
                -CliPath 'C:\cx-test\codex.exe' `
                -ApiKey $ApiKey `
                -CatalogPath $CatalogPath `
                -AuthCommand 'C:\cx-test\powershell.exe' `
                -AllModels
        } $previousCatalogPath $resolverKey
        Assert-True `
            -Condition ([bool]$previousAllSync.UsedPreviousCatalog) `
            -Message 'All-model synchronization can reuse the last valid catalog'
        Assert-Equal `
            -Actual ([int]$previousAllSync.VisibleModelCount) `
            -Expected 6 `
            -Message 'All-model fallback reveals every model in the previous catalog'
        $publishedAllCatalog = Get-Content -Raw -LiteralPath $previousCatalogPath |
            ConvertFrom-Json -ErrorAction Stop
        Assert-Equal `
            -Actual @($publishedAllCatalog.models | Where-Object {
                    $_.visibility -ceq 'list'
                }).Count `
            -Expected 6 `
            -Message 'All-model fallback publishes every model as visible'

        $emptyCatalogPath = Join-Path $syncTestRoot 'missing-catalog.json'
        $emptySyncFailure = $null
        try {
            & $module {
                param($CatalogPath, $ApiKey)
                Sync-CxOpenRouterCatalog `
                    -CliPath 'C:\cx-test\codex.exe' `
                    -ApiKey $ApiKey `
                    -CatalogPath $CatalogPath `
                    -AuthCommand 'C:\cx-test\powershell.exe'
            } $emptyCatalogPath $resolverKey | Out-Null
        }
        catch { $emptySyncFailure = $_.Exception.Message }
        Assert-True `
            -Condition ($emptySyncFailure -like '*未返回可用模型目录*') `
            -Message 'Synchronization reports all-empty catalog sources explicitly'
        Assert-True `
            -Condition ($emptySyncFailure -notlike '*Cannot bind argument*') `
            -Message 'Synchronization never exposes the empty Content binding error'
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath $emptyCatalogPath)) `
            -Message 'Failed synchronization does not publish an empty catalog'

        & $module {
            param($CacheContent)
            $script:SyncTestCacheContent = $CacheContent
            $script:SyncTestExitCode = 23
            $script:SyncTestStandardOutput = ''
            $script:SyncTestStandardError = 'upstream unavailable'
        } $selectionCatalog
        $nonzeroCacheSync = & $module {
            param($CatalogPath, $ApiKey)
            Sync-CxOpenRouterCatalog `
                -CliPath 'C:\cx-test\codex.exe' `
                -ApiKey $ApiKey `
                -CatalogPath $CatalogPath `
                -AuthCommand 'C:\cx-test\powershell.exe'
        } $emptyCatalogPath $resolverKey
        Assert-Equal `
            -Actual ([string]$nonzeroCacheSync.CatalogSource) `
            -Expected '临时缓存 models_cache.openrouter.json' `
            -Message 'Nonzero CLI exits still allow a validated temporary cache'
        Assert-True `
            -Condition (-not [bool]$nonzeroCacheSync.UsedPreviousCatalog) `
            -Message 'Temporary cache after a nonzero CLI exit is fresh data'

        & $module {
            $script:SyncTestCacheContent = ''
        }
        $nonzeroPreviousSync = & $module {
            param($CatalogPath, $ApiKey)
            Sync-CxOpenRouterCatalog `
                -CliPath 'C:\cx-test\codex.exe' `
                -ApiKey $ApiKey `
                -CatalogPath $CatalogPath `
                -AuthCommand 'C:\cx-test\powershell.exe'
        } $previousCatalogPath $resolverKey
        Assert-True `
            -Condition ([bool]$nonzeroPreviousSync.UsedPreviousCatalog) `
            -Message 'Nonzero CLI exits still allow the last valid catalog'

        $nonzeroMissingPath = Join-Path $syncTestRoot 'nonzero-missing-catalog.json'
        $nonzeroFailure = $null
        try {
            & $module {
                param($CatalogPath, $ApiKey)
                Sync-CxOpenRouterCatalog `
                    -CliPath 'C:\cx-test\codex.exe' `
                    -ApiKey $ApiKey `
                    -CatalogPath $CatalogPath `
                    -AuthCommand 'C:\cx-test\powershell.exe'
            } $nonzeroMissingPath $resolverKey | Out-Null
        }
        catch { $nonzeroFailure = $_.Exception.Message }
        Assert-True `
            -Condition ($nonzeroFailure -like '*退出码 23*upstream unavailable*') `
            -Message 'Nonzero CLI exits remain visible when every fallback is invalid'
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath $nonzeroMissingPath)) `
            -Message 'Failed nonzero synchronization does not publish a catalog'
    }
    finally {
        & $module {
            param($Original)
            Set-Item -LiteralPath Function:\Invoke-CxProcess -Value $Original
        } $originalInvokeCxProcess
        & $module {
            param($Original)
            Set-Item -LiteralPath Function:\Get-CxCodexClientVersion -Value $Original
        } $originalGetCxCodexClientVersion
        & $module {
            param($Original)
            Set-Item -LiteralPath Function:\Invoke-CxOpenRouterCatalogRequest `
                -Value $Original
            Remove-Variable -Scope Script -Name 'SyncTest*' -ErrorAction SilentlyContinue
        } $originalInvokeCxOpenRouterCatalogRequest
        $resolvedSyncTestRoot = [IO.Path]::GetFullPath($syncTestRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
            [IO.Path]::DirectorySeparatorChar
        if ($resolvedSyncTestRoot.StartsWith(
                $resolvedTempRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            [IO.Path]::GetFileName($resolvedSyncTestRoot) -match '^cx-sync-tests-[0-9a-f]{32}$' -and
            (Test-Path -LiteralPath $resolvedSyncTestRoot -PathType Container)) {
            Remove-Item -LiteralPath $resolvedSyncTestRoot -Recurse -Force
        }
    }

    $duplicateCatalog = [ordered]@{
        models = @(
            [ordered]@{ slug = 'vendor/duplicate' },
            [ordered]@{ slug = 'VENDOR/DUPLICATE' }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    Assert-ThrowsLike `
        -Action {
            & $module {
                param($Content)
                Convert-CxCatalogPrompt -Content $Content | Out-Null
            } $duplicateCatalog
        }.GetNewClosure() `
        -Pattern '*重复 slug*' `
        -Message 'Catalog rejects duplicate slugs case-insensitively'

    $syntheticSecret = 'sk-' + 'or-' + ('x' * 24)
    $secretCatalog = [ordered]@{
        models = @(
            [ordered]@{
                slug = 'vendor/safe-model'
                diagnostic = $syntheticSecret
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    Assert-ThrowsLike `
        -Action {
            & $module {
                param($Content)
                Convert-CxCatalogPrompt -Content $Content | Out-Null
            } $secretCatalog
        }.GetNewClosure() `
        -Pattern '*密钥*' `
        -Message 'Catalog rejects API-key-shaped content'

    $validKey = 'sk-' + 'or-' + ('a' * 32)
    $keyValidation = & $module {
        param($ValidKey)

        [pscustomobject]@{
            Valid = Test-CxApiKey -Value $ValidKey
            Null = Test-CxApiKey -Value $null
            WrongPrefix = Test-CxApiKey -Value ('sk-' + ('a' * 32))
            Short = Test-CxApiKey -Value ('sk-' + 'or-short')
            Whitespace = Test-CxApiKey -Value ($ValidKey + ' ')
            Control = Test-CxApiKey -Value ($ValidKey + "`n")
        }
    } $validKey
    Assert-True -Condition $keyValidation.Valid -Message 'API key accepts a valid value'
    foreach ($property in @('Null', 'WrongPrefix', 'Short', 'Whitespace', 'Control')) {
        Assert-True `
            -Condition (-not [bool]$keyValidation.$property) `
            -Message "API key rejects invalid case: $property"
    }

    $orchestration = & $module {
        $script:TestSyncCalls = 0
        $script:TestStopCalls = 0
        $script:TestStartCalls = 0
        $script:TestCommitCalls = 0
        $script:TestProxyEnsureCalls = 0
        $script:TestProxyStopCalls = 0
        $script:TestSyncShouldFail = $false
        $script:TestConfigShouldFail = $false
        $script:TestProcessDiscoveryShouldFail = $false
        $script:TestProxyCreated = $false
        $script:TestConfigModels = [Collections.Generic.List[string]]::new()
        $script:TestAllModels = [Collections.Generic.List[bool]]::new()

        function script:Assert-CxRuntime { }
        function script:Get-CxPaths {
            [pscustomobject]@{
                CodexHome = 'C:\cx-test'
                ConfigPath = 'C:\cx-test\config.toml'
                CatalogPath = 'C:\cx-test\catalog.json'
                ProxyStatePath = 'C:\cx-test\openrouter-cache-proxy.json'
            }
        }
        function script:Enter-CxMutex {
            param([string]$ScopePath)
            return [pscustomobject]@{ ScopePath = $ScopePath }
        }
        function script:Exit-CxMutex { param($Mutex) }
        function script:Resolve-CxDesktopApp {
            return [pscustomobject]@{
                AppUserModelId = 'OpenAI.Codex_test!App'
                InstallRoot = 'C:\cx-test\app\'
            }
        }
        function script:Get-CxUserApiKey {
            param([switch]$Prompt)
            return 'sk-' + 'or-' + ('m' * 32)
        }
        function script:Get-CxAuthPowerShell { return 'C:\cx-test\powershell.exe' }
        function script:Get-CxCodexCliPath { return 'C:\cx-test\codex.exe' }
        function script:Ensure-CxOpenRouterProxy {
            param([string]$StatePath)
            $script:TestProxyEnsureCalls++
            return [pscustomobject]@{
                BaseUrl = 'http://127.0.0.1:43127/api/v1'
                Token = 'A' * 64
                Created = $script:TestProxyCreated
            }
        }
        function script:Stop-CxOpenRouterProxy {
            param([string]$StatePath)
            $script:TestProxyStopCalls++
            return $true
        }
        function script:Sync-CxOpenRouterCatalog {
            param(
                [string]$CliPath,
                [string]$ApiKey,
                [string]$CatalogPath,
                [string]$AuthCommand,
                [switch]$AllModels
            )

            $script:TestSyncCalls++
            $script:TestAllModels.Add([bool]$AllModels)
            if ($script:TestSyncShouldFail) {
                throw 'synthetic catalog synchronization failure'
            }
            return [pscustomobject]@{
                Path = $CatalogPath
                ModelCount = 3
                VisibleModelCount = if ($AllModels) { 3 } else { 2 }
                DefaultModel = '~openai/gpt-latest'
                CatalogSource = 'test catalog'
                UsedPreviousCatalog = $false
            }
        }
        function script:Get-CxConfigChange {
            param(
                [string]$Path,
                [string]$Mode,
                [string]$CatalogPath,
                [string]$AuthCommand,
                [string]$ProxyBaseUrl,
                [string]$ProxyToken,
                [string]$ProxyStatePath,
                [string]$Model
            )

            $script:TestConfigModels.Add($Model)
            if ($script:TestConfigShouldFail) {
                throw 'synthetic config preparation failure'
            }
            return [pscustomobject]@{
                Path = $Path
                OriginalFingerprint = '<test>'
                Content = "mode=$Mode"
            }
        }
        function script:Get-CxDesktopProcesses {
            param($App)
            if ($script:TestProcessDiscoveryShouldFail) {
                throw 'synthetic desktop discovery failure'
            }
            return @()
        }
        function script:Stop-CxDesktopApp {
            param([AllowEmptyCollection()][object[]]$Processes)
            $script:TestStopCalls++
        }
        function script:Commit-CxConfigChange {
            param($Change)
            $script:TestCommitCalls++
        }
        function script:Start-CxDesktopApp {
            param($App)
            $script:TestStartCalls++
        }

        cxor
        cxor -AllModels
        $afterTwo = [pscustomobject]@{
            Sync = $script:TestSyncCalls
            Stop = $script:TestStopCalls
            Commit = $script:TestCommitCalls
            Start = $script:TestStartCalls
            ProxyEnsure = $script:TestProxyEnsureCalls
            Models = @($script:TestConfigModels)
            AllModels = @($script:TestAllModels)
        }

        $script:TestSyncShouldFail = $true
        $failure = $null
        try { cxor }
        catch { $failure = $_.Exception.Message }
        [pscustomobject]@{
            AfterTwo = $afterTwo
            FinalSync = $script:TestSyncCalls
            FinalStop = $script:TestStopCalls
            FinalCommit = $script:TestCommitCalls
            FinalStart = $script:TestStartCalls
            FinalProxyEnsure = $script:TestProxyEnsureCalls
            FinalModels = @($script:TestConfigModels)
            FinalAllModels = @($script:TestAllModels)
            Failure = $failure
        }
    }
    Assert-Equal `
        -Actual $orchestration.AfterTwo.Sync `
        -Expected 2 `
        -Message 'Two consecutive cxor calls synchronize twice'
    Assert-Equal `
        -Actual $orchestration.AfterTwo.Stop `
        -Expected 2 `
        -Message 'Two successful cxor calls stop the desktop twice'
    Assert-Equal `
        -Actual $orchestration.AfterTwo.Commit `
        -Expected 2 `
        -Message 'Two successful cxor calls commit twice'
    Assert-Equal `
        -Actual $orchestration.AfterTwo.Start `
        -Expected 2 `
        -Message 'Two successful cxor calls start the desktop twice'
    Assert-Equal `
        -Actual $orchestration.AfterTwo.ProxyEnsure `
        -Expected 2 `
        -Message 'Two successful cxor calls ensure the cache proxy twice'
    Assert-Equal `
        -Actual ($orchestration.AfterTwo.Models -join ',') `
        -Expected '~openai/gpt-latest,~openai/gpt-latest' `
        -Message 'cxor writes the default model returned by each synchronization'
    Assert-Equal `
        -Actual ($orchestration.AfterTwo.AllModels -join ',') `
        -Expected 'False,True' `
        -Message 'cxor passes curated and all-model modes to synchronization'
    Assert-Equal `
        -Actual $orchestration.FinalSync `
        -Expected 3 `
        -Message 'A third cxor call attempts synchronization'
    Assert-Equal `
        -Actual $orchestration.FinalStop `
        -Expected 2 `
        -Message 'Synchronization failure does not stop the desktop'
    Assert-Equal `
        -Actual $orchestration.FinalCommit `
        -Expected 2 `
        -Message 'Synchronization failure does not commit configuration'
    Assert-Equal `
        -Actual $orchestration.FinalStart `
        -Expected 2 `
        -Message 'Synchronization failure does not relaunch the running desktop'
    Assert-Equal `
        -Actual $orchestration.FinalProxyEnsure `
        -Expected 2 `
        -Message 'Synchronization failure does not start the cache proxy'
    Assert-Equal `
        -Actual ($orchestration.FinalModels -join ',') `
        -Expected '~openai/gpt-latest,~openai/gpt-latest' `
        -Message 'Synchronization failure does not prepare a stale model config'
    Assert-Equal `
        -Actual ($orchestration.FinalAllModels -join ',') `
        -Expected 'False,True,False' `
        -Message 'Failed synchronization still records the requested catalog mode'
    Assert-True `
        -Condition ($orchestration.Failure -like '*synchronization failure*') `
        -Message 'Synchronization failure is reported to the caller'

    $preparationCleanup = & $module {
        $script:TestSyncShouldFail = $false
        $script:TestProxyCreated = $true
        $script:TestConfigShouldFail = $true
        $beforeConfigStop = $script:TestProxyStopCalls
        $beforeDesktopStop = $script:TestStopCalls
        $configFailure = $null
        try { cxor }
        catch { $configFailure = $_.Exception.Message }
        $afterConfigStop = $script:TestProxyStopCalls

        $script:TestConfigShouldFail = $false
        $script:TestProcessDiscoveryShouldFail = $true
        $processFailure = $null
        try { cxor }
        catch { $processFailure = $_.Exception.Message }

        [pscustomobject]@{
            BeforeConfigProxyStop = $beforeConfigStop
            AfterConfigProxyStop = $afterConfigStop
            FinalProxyStop = $script:TestProxyStopCalls
            BeforeDesktopStop = $beforeDesktopStop
            FinalDesktopStop = $script:TestStopCalls
            ConfigFailure = $configFailure
            ProcessFailure = $processFailure
        }
    }
    Assert-Equal `
        -Actual ($preparationCleanup.AfterConfigProxyStop -
            $preparationCleanup.BeforeConfigProxyStop) `
        -Expected 1 `
        -Message 'Config preparation failure stops a newly created cache proxy'
    Assert-Equal `
        -Actual ($preparationCleanup.FinalProxyStop -
            $preparationCleanup.AfterConfigProxyStop) `
        -Expected 1 `
        -Message 'Desktop discovery failure stops a newly created cache proxy'
    Assert-Equal `
        -Actual $preparationCleanup.FinalDesktopStop `
        -Expected $preparationCleanup.BeforeDesktopStop `
        -Message 'Preparation failures leave the running desktop untouched'
    Assert-True `
        -Condition ($preparationCleanup.ConfigFailure -like '*config preparation failure*') `
        -Message 'Config preparation failure is reported to the caller'
    Assert-True `
        -Condition ($preparationCleanup.ProcessFailure -like '*desktop discovery failure*') `
        -Message 'Desktop discovery failure is reported to the caller'

    Write-Host (
        "All tests passed: $script:AssertionCount assertions; " +
        "$($powerShellFiles.Count) PowerShell files parsed."
    )
}
finally {
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
}
