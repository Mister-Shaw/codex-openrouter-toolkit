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
        -Expected '0.1.2' `
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
        param($Content, $CatalogPath, $AuthCommand, $Model)

        $openRouter = Update-CxConfigContent `
            -Content $Content `
            -Mode OpenRouter `
            -CatalogPath $CatalogPath `
            -AuthCommand $AuthCommand `
            -Model $Model
        $openRouterAgain = Update-CxConfigContent `
            -Content $openRouter `
            -Mode OpenRouter `
            -CatalogPath $CatalogPath `
            -AuthCommand $AuthCommand `
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
    } $tomlInput $catalogPath $authCommand $openRouterModel

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
            'base_url = "https://openrouter.ai/api/v1"'
        ) `
        -Message 'OpenRouter TOML writes the current provider'
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

        $converted = Convert-CxCatalogPrompt -Content $Content
        [pscustomobject]@{
            Converted = $converted
            ConvertedAgain = Convert-CxCatalogPrompt -Content $converted
            Prompt = $script:LightweightPrompt
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
        Assert-Equal `
            -Actual ([string]$model.base_instructions) `
            -Expected $catalogResult.Prompt `
            -Message "Catalog rewrites base_instructions: $($model.slug)"
        Assert-Equal `
            -Actual ([string]$model.model_messages.instructions_template) `
            -Expected $catalogResult.Prompt `
            -Message "Catalog rewrites instructions_template: $($model.slug)"
    }
    Assert-Equal `
        -Actual $catalogResult.ConvertedAgain `
        -Expected $catalogResult.Converted `
        -Message 'Catalog prompt conversion is idempotent'

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
        $script:TestSyncShouldFail = $false
        $script:TestConfigModels = [Collections.Generic.List[string]]::new()

        function script:Assert-CxRuntime { }
        function script:Get-CxPaths {
            [pscustomobject]@{
                CodexHome = 'C:\cx-test'
                ConfigPath = 'C:\cx-test\config.toml'
                CatalogPath = 'C:\cx-test\catalog.json'
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
        function script:Sync-CxOpenRouterCatalog {
            param(
                [string]$CliPath,
                [string]$ApiKey,
                [string]$CatalogPath,
                [string]$AuthCommand
            )

            $script:TestSyncCalls++
            if ($script:TestSyncShouldFail) {
                throw 'synthetic catalog synchronization failure'
            }
            return [pscustomobject]@{
                Path = $CatalogPath
                ModelCount = 3
                DefaultModel = '~openai/gpt-latest'
            }
        }
        function script:Get-CxConfigChange {
            param(
                [string]$Path,
                [string]$Mode,
                [string]$CatalogPath,
                [string]$AuthCommand,
                [string]$Model
            )

            $script:TestConfigModels.Add($Model)
            return [pscustomobject]@{
                Path = $Path
                OriginalFingerprint = '<test>'
                Content = "mode=$Mode"
            }
        }
        function script:Get-CxDesktopProcesses {
            param($App)
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
        cxor
        $afterTwo = [pscustomobject]@{
            Sync = $script:TestSyncCalls
            Stop = $script:TestStopCalls
            Commit = $script:TestCommitCalls
            Start = $script:TestStartCalls
            Models = @($script:TestConfigModels)
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
            FinalModels = @($script:TestConfigModels)
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
        -Actual ($orchestration.AfterTwo.Models -join ',') `
        -Expected '~openai/gpt-latest,~openai/gpt-latest' `
        -Message 'cxor writes the default model returned by each synchronization'
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
        -Actual ($orchestration.FinalModels -join ',') `
        -Expected '~openai/gpt-latest,~openai/gpt-latest' `
        -Message 'Synchronization failure does not prepare a stale model config'
    Assert-True `
        -Condition ($orchestration.Failure -like '*synchronization failure*') `
        -Message 'Synchronization failure is reported to the caller'

    Write-Host (
        "All tests passed: $script:AssertionCount assertions; " +
        "$($powerShellFiles.Count) PowerShell files parsed."
    )
}
finally {
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
}
