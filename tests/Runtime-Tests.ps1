[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleManifest = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psd1'
$moduleSource = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psm1'
$commonSource = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.Common.ps1'
$setKeySource = Join-Path `
    $repositoryRoot `
    'scripts\Set-CodexOpenRouterKey.ps1'
$uninstallerSource = Join-Path `
    $repositoryRoot `
    'scripts\Uninstall-CodexOpenRouter.ps1'
$tempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "codex-openrouter-runtime-tests-$([Guid]::NewGuid().ToString('N'))"

function Assert-RuntimeTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "RUNTIME ASSERTION FAILED: $Message" }
}

function Assert-RuntimeEqual {
    param([AllowNull()]$Actual, [AllowNull()]$Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "RUNTIME ASSERTION FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-RuntimeBytesEqual {
    param([byte[]]$Actual, [byte[]]$Expected, [string]$Message)
    Assert-RuntimeTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $Actual,
                $Expected
            )) `
        -Message $Message
}

function Assert-RuntimeThrowsLike {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = $null
    try { & $Action }
    catch { $caught = $_ }
    Assert-RuntimeTrue -Condition ($null -ne $caught) -Message $Message
    Assert-RuntimeTrue `
        -Condition ($caught.Exception.Message -like $Pattern) `
        -Message "$Message error text: $($caught.Exception.Message)"
}

function Write-RuntimeBytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-RuntimeCacheBytes {
    param([string[]]$Models)
    $value = [pscustomobject]@{
        models = @($Models | ForEach-Object {
            [pscustomobject]@{ slug = $_ }
        })
    }
    return [Text.UTF8Encoding]::new($false).GetBytes(
        ($value | ConvertTo-Json -Depth 5 -Compress)
    )
}

try {
    [void](New-Item -ItemType Directory -Path $tempRoot -Force)
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $module = Get-Module CodexOpenRouter -ErrorAction Stop

    $validKey = 'sk-or-' + ('r' * 48)
    $otherKey = 'sk-or-' + ('s' * 48)
    $resolved = & $module {
        param($UserValue, $ProcessValue)
        Resolve-OpenRouterDesktopApiKey `
            -UserValue $UserValue `
            -ProcessValue $ProcessValue `
            -ProcessOverride $false
    } $validKey $null
    Assert-RuntimeEqual $resolved $validKey 'Desktop key accepts a valid User value'
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($ProcessValue)
            Resolve-OpenRouterDesktopApiKey `
                -UserValue $null `
                -ProcessValue $ProcessValue `
                -ProcessOverride $false
        } $validKey
    } -Pattern '*User*OPENROUTER_API_KEY*' -Message 'Desktop key rejects Process-only value'
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($UserValue, $ProcessValue)
            Resolve-OpenRouterDesktopApiKey `
                -UserValue $UserValue `
                -ProcessValue $ProcessValue `
                -ProcessOverride $true
        } $validKey $otherKey
    }.GetNewClosure() -Pattern '*Process override*User*' -Message 'Desktop key rejects mismatched override'

    $packageRoot = Join-Path $tempRoot 'package'
    [void](New-Item -ItemType Directory -Path $packageRoot -Force)
    $manifest = [pscustomobject]@{
        Package = [pscustomobject]@{
            Applications = [pscustomobject]@{
                Application = @(
                    [pscustomobject]@{ Id = 'App'; Executable = 'ChatGPT.exe' }
                )
            }
        }
    }
    $packages = @([pscustomobject]@{
            PackageFamilyName = 'OpenAI.Codex_abc123'
            InstallLocation = $packageRoot
            Version = [version]'1.2.3.4'
            Manifest = $manifest
        })
    $appInfo = & $module {
        param($Packages)
        Resolve-CodexDesktopAppFromInventory `
            -Packages $Packages `
            -ManifestResolver { param($Package) $Package.Manifest }
    } $packages
    Assert-RuntimeEqual `
        $appInfo.AppUserModelId `
        'OpenAI.Codex_abc123!App' `
        'AUMID comes from the exact package family and manifest application id'
    Assert-RuntimeThrowsLike -Action {
        & $module {
            Resolve-CodexDesktopAppFromInventory `
                -Packages @([pscustomobject]@{
                        PackageFamilyName = 'OpenAI.Other_abc123'
                        InstallLocation = 'C:\spoof'
                    }) `
                -ManifestResolver { throw 'must not run' }
        }
    } -Pattern '*Codex Desktop*' -Message 'Friendly package spoof is rejected'
    Assert-RuntimeThrowsLike -Action {
        & $module {
            Resolve-CodexDesktopAppFromInventory `
                -Packages @() `
                -ManifestResolver { throw 'must not run' }
        }
    } -Pattern '*找不到*Codex Desktop*' -Message 'Empty package inventory uses the friendly diagnostic'

    $trustedExecutable = Join-Path $packageRoot 'ChatGPT.exe'
    $trustedProcess = [pscustomobject]@{
        Path = $trustedExecutable
        SessionId = 9
    }
    $evilProcess = [pscustomobject]@{
        Path = "${packageRoot}-evil\ChatGPT.exe"
        SessionId = 9
    }
    $matched = & $module {
        param($Processes, $Root)
        Resolve-CodexDesktopProcessSet `
            -Processes $Processes `
            -InstallLocations @($Root) `
            -CurrentSessionId 9
    } @($trustedProcess, $evilProcess) $packageRoot
    Assert-RuntimeEqual @($matched).Count 1 'Process path matching enforces a directory boundary'
    $emptyMatched = & $module {
        param($Root)
        @(Resolve-CodexDesktopProcessSet `
                -Processes @() `
                -InstallLocations @($Root) `
                -CurrentSessionId 9).Count
    } $packageRoot
    Assert-RuntimeEqual $emptyMatched 0 'A closed Desktop produces an empty trusted process set'
    & $module { Restore-CodexFileMutations -Mutations @() }

    $oversizedLocalFile = Join-Path $tempRoot 'oversized-local-input.txt'
    [IO.File]::WriteAllBytes($oversizedLocalFile, [byte[]]::new(1MB + 1))
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($Path)
            $originalPath = $script:DefaultPromptPath
            try {
                $script:DefaultPromptPath = $Path
                Get-DefaultAgentInstruction
            }
            finally { $script:DefaultPromptPath = $originalPath }
        } $oversizedLocalFile
    }.GetNewClosure() -Pattern '*超过*' -Message 'Agent prompt input has a bounded size'
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($Path)
            Get-CodexOpenRouterSettings -SettingsPath $Path
        } $oversizedLocalFile
    }.GetNewClosure() -Pattern '*超过*' -Message 'Toolkit settings input has a bounded size'

    $expansionCatalogPath = Join-Path $tempRoot 'prompt-expansion-catalog.json'
    $expansionModels = @(0..1099 | ForEach-Object {
        [ordered]@{
            slug = "vendor/model-$_"
            display_name = "Model $_"
            base_instructions = 'short'
            model_messages = [ordered]@{ instructions_template = 'short' }
            context_window = 8192
        }
    })
    [IO.File]::WriteAllText(
        $expansionCatalogPath,
        ([ordered]@{ models = $expansionModels } |
            ConvertTo-Json -Depth 8 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $escapedExpansionInstruction = ([char]1).ToString() * 4096
    Assert-RuntimeThrowsLike -Action {
        Set-OpenRouterAgentInstructions `
            -Path $expansionCatalogPath `
            -Instruction $escapedExpansionInstruction
    }.GetNewClosure() -Pattern '*可能超过*' -Message 'Prompt expansion is rejected before catalog serialization'

    $statusHome = Join-Path $tempRoot 'status-home'
    $statusInstall = Join-Path $statusHome 'codex-openrouter-toolkit'
    [void](New-Item -ItemType Directory -Path $statusInstall -Force)
    $statusConfig = Join-Path $statusHome 'config.toml'
    [IO.File]::WriteAllText(
        $statusConfig,
        "model = `"gpt-5.6-sol`"`r`nmodel = `"conflict`"`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $statusSettingsPath = Join-Path $statusInstall 'settings.json'
    $statusSettings = [ordered]@{
        SchemaVersion = 2
        Toolkit = 'codex-openrouter-toolkit'
        CodexHome = $statusHome
        ProfilePath = (Join-Path $tempRoot 'status-profile.ps1')
        ConfigPath = $statusConfig
        CatalogPath = (Join-Path $statusHome 'openrouter-model-catalog.json')
        ActiveCachePath = (Join-Path $statusHome 'models_cache.json')
        OpenAICachePath = (Join-Path $statusHome 'models_cache.openai.json')
        OpenAIModel = 'gpt-5.6-sol'
        OpenAIReasoningEffort = 'xhigh'
        OpenRouterModel = 'anthropic/claude-opus-5'
        OpenRouterReasoningEffort = 'high'
        CatalogMaximumAgeHours = 24
    }
    [IO.File]::WriteAllText(
        $statusSettingsPath,
        ($statusSettings | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
    $malformedStatus = & $module {
        param($SettingsPath)
        $originalPath = $script:DefaultSettingsPath
        try {
            $script:DefaultSettingsPath = $SettingsPath
            Get-CodexOpenRouterStatus
        }
        finally { $script:DefaultSettingsPath = $originalPath }
    } $statusSettingsPath
    Assert-RuntimeTrue `
        -Condition (-not [string]::IsNullOrWhiteSpace(
                [string]$malformedStatus.ConfigReadError
            )) `
        -Message 'Status reports malformed TOML through ConfigReadError'
    Assert-RuntimeTrue `
        -Condition ([string]::IsNullOrWhiteSpace([string]$malformedStatus.Model)) `
        -Message 'Status does not report a model from malformed TOML'
    $unreadableProcess = [pscustomobject]@{ SessionId = 9 }
    $unreadableProcess | Add-Member `
        -MemberType ScriptProperty `
        -Name Path `
        -Value { throw 'access denied' }
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($Process, $Root)
            Resolve-CodexDesktopProcessSet `
                -Processes @($Process) `
                -InstallLocations @($Root) `
                -CurrentSessionId 9
        } $unreadableProcess $packageRoot
    }.GetNewClosure() -Pattern '*无法验证*路径*' -Message 'Unreadable current-session process path fails closed'

    $startInfo = & $module {
        param($AppInfo, $ApiKey)
        New-CodexDesktopActivationStartInfo `
            -AppInfo $AppInfo `
            -ApiKey $ApiKey
    } $appInfo $validKey
    Assert-RuntimeEqual `
        $startInfo.Environment['OPENROUTER_API_KEY'] `
        $validKey `
        'Activation environment contains the validated User key'
    Assert-RuntimeTrue `
        -Condition (-not $startInfo.Environment.ContainsKey(
                'CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE'
            )) `
        -Message 'Activation removes the Process override marker'
    $argumentText = [string]::Join(' ', @($startInfo.ArgumentList))
    Assert-RuntimeTrue `
        -Condition (-not $argumentText.Contains($validKey)) `
        -Message 'Activation command line contains no API key'
    Assert-RuntimeTrue `
        -Condition $argumentText.Contains($appInfo.AppUserModelId) `
        -Message 'Activation uses the exact AUMID'

    $existingPath = Join-Path $tempRoot 'cas-existing.txt'
    $initialBytes = [Text.Encoding]::UTF8.GetBytes('initial')
    $postBytes = [Text.Encoding]::UTF8.GetBytes('transaction')
    Write-RuntimeBytes $existingPath $initialBytes
    $existingMutation = & $module {
        param($Path, $Bytes)
        $initial = Get-CodexManagedFileState -Path $Path -MaximumBytes 1MB
        $post = Write-CodexManagedFileState `
            -ExpectedState $initial `
            -Bytes $Bytes `
            -MaximumBytes 1MB
        New-CodexFileMutation `
            -InitialState $initial `
            -PostState $post `
            -MaximumBytes 1MB
    } $existingPath $postBytes
    & $module {
        param($Mutation)
        Restore-CodexFileMutations -Mutations @($Mutation)
    } $existingMutation
    Assert-RuntimeBytesEqual `
        ([IO.File]::ReadAllBytes($existingPath)) `
        $initialBytes `
        'Rollback restores an existing file'

    $createdPath = Join-Path $tempRoot 'cas-created.txt'
    $createdMutation = & $module {
        param($Path, $Bytes)
        $initial = Get-CodexManagedFileState -Path $Path -MaximumBytes 1MB
        $post = Write-CodexManagedFileState `
            -ExpectedState $initial `
            -Bytes $Bytes `
            -MaximumBytes 1MB
        New-CodexFileMutation `
            -InitialState $initial `
            -PostState $post `
            -MaximumBytes 1MB
    } $createdPath $postBytes
    & $module {
        param($Mutation)
        Restore-CodexFileMutations -Mutations @($Mutation)
    } $createdMutation
    Assert-RuntimeTrue `
        -Condition (-not (Test-Path -LiteralPath $createdPath)) `
        -Message 'Rollback removes a transaction-created file'

    $conflictPath = Join-Path $tempRoot 'cas-conflict.txt'
    Write-RuntimeBytes $conflictPath $initialBytes
    $conflictMutation = & $module {
        param($Path, $Bytes)
        $initial = Get-CodexManagedFileState -Path $Path -MaximumBytes 1MB
        $post = Write-CodexManagedFileState `
            -ExpectedState $initial `
            -Bytes $Bytes `
            -MaximumBytes 1MB
        New-CodexFileMutation `
            -InitialState $initial `
            -PostState $post `
            -MaximumBytes 1MB
    } $conflictPath $postBytes
    $externalBytes = [Text.Encoding]::UTF8.GetBytes('external-owner-change')
    Write-RuntimeBytes $conflictPath $externalBytes
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($Mutation)
            Restore-CodexFileMutations -Mutations @($Mutation)
        } $conflictMutation
    }.GetNewClosure() -Pattern '*回滚 CAS 冲突*' -Message 'Rollback preserves an external modification'
    Assert-RuntimeBytesEqual `
        ([IO.File]::ReadAllBytes($conflictPath)) `
        $externalBytes `
        'External bytes survive rollback conflict'

    $oversizePath = Join-Path $tempRoot 'oversize.bin'
    Write-RuntimeBytes $oversizePath ([byte[]]::new(11))
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($Path)
            Get-CodexManagedFileState -Path $Path -MaximumBytes 10
        } $oversizePath
    }.GetNewClosure() -Pattern '*超过*10*' -Message 'Managed file size limit is enforced'

    $activeCache = Join-Path $tempRoot 'active-cache.json'
    $savedCache = Join-Path $tempRoot 'saved-cache.json'
    $openAIModel = 'gpt-5.6-sol'
    $openRouterModel = 'anthropic/claude-opus-5'
    $openAIBytes = New-RuntimeCacheBytes @($openAIModel, 'gpt-5.5')
    Write-RuntimeBytes $activeCache $openAIBytes
    $cacheMutation = & $module {
        param($Active, $Saved, $OpenAIModel, $OpenRouterModel)
        $activeState = Get-CodexManagedFileState -Path $Active -MaximumBytes 50MB
        $savedState = Get-CodexManagedFileState -Path $Saved -MaximumBytes 50MB
        Save-CodexDefaultModelCache `
            -ActiveCachePath $Active `
            -OpenAICachePath $Saved `
            -OpenAIModel $OpenAIModel `
            -OpenRouterModel $OpenRouterModel `
            -ExpectedActiveState $activeState `
            -ExpectedOpenAIState $savedState
    } $activeCache $savedCache $openAIModel $openRouterModel
    Assert-RuntimeBytesEqual `
        ([IO.File]::ReadAllBytes($savedCache)) `
        $openAIBytes `
        'Cache backup writes the validated snapshot bytes'
    Assert-RuntimeTrue ($null -ne $cacheMutation) 'Cache backup returns a rollback mutation'

    $staleActive = Join-Path $tempRoot 'stale-active.json'
    $staleSaved = Join-Path $tempRoot 'stale-saved.json'
    Write-RuntimeBytes $staleActive $openAIBytes
    $staleState = & $module {
        param($Path)
        Get-CodexManagedFileState -Path $Path -MaximumBytes 50MB
    } $staleActive
    Write-RuntimeBytes $staleActive (New-RuntimeCacheBytes @('gpt-5.4'))
    Assert-RuntimeThrowsLike -Action {
        & $module {
            param($Active, $Saved, $OpenAIModel, $OpenRouterModel, $State)
            Save-CodexDefaultModelCache `
                -ActiveCachePath $Active `
                -OpenAICachePath $Saved `
                -OpenAIModel $OpenAIModel `
                -OpenRouterModel $OpenRouterModel `
                -ExpectedActiveState $State
        } $staleActive $staleSaved $openAIModel $openRouterModel $staleState
    }.GetNewClosure() -Pattern '*备份前发生变化*' -Message 'Stale active cache snapshot is rejected'
    Assert-RuntimeTrue `
        -Condition (-not (Test-Path -LiteralPath $staleSaved)) `
        -Message 'Stale cache backup creates no destination'

    $orActive = Join-Path $tempRoot 'openrouter-active.json'
    $missingSaved = Join-Path $tempRoot 'missing-openai.json'
    $orBytes = New-RuntimeCacheBytes @($openRouterModel)
    Write-RuntimeBytes $orActive $orBytes
    $removeMutation = & $module {
        param($Active, $Saved, $OpenAIModel, $OpenRouterModel)
        $activeState = Get-CodexManagedFileState -Path $Active -MaximumBytes 50MB
        $savedState = Get-CodexManagedFileState -Path $Saved -MaximumBytes 50MB
        Restore-CodexDefaultModelCache `
            -ActiveCachePath $Active `
            -OpenAICachePath $Saved `
            -OpenAIModel $OpenAIModel `
            -OpenRouterModel $OpenRouterModel `
            -ExpectedActiveState $activeState `
            -ExpectedOpenAIState $savedState
    } $orActive $missingSaved $openAIModel $openRouterModel
    Assert-RuntimeTrue `
        -Condition (-not (Test-Path -LiteralPath $orActive)) `
        -Message 'Missing OpenAI cache removes a verified OpenRouter active cache'
    Assert-RuntimeTrue `
        -Condition (-not [bool]$removeMutation.PostState.Existed) `
        -Message 'Cache removal records the internal missing post-state'
    & $module {
        param($Mutation)
        Restore-CodexFileMutations -Mutations @($Mutation)
    } $removeMutation
    Assert-RuntimeBytesEqual `
        ([IO.File]::ReadAllBytes($orActive)) `
        $orBytes `
        'Rollback restores a cache removed for desktop regeneration'

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $pwshPath
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    [void]$processInfo.ArgumentList.Add('-NoLogo')
    [void]$processInfo.ArgumentList.Add('-NoProfile')
    [void]$processInfo.ArgumentList.Add('-Command')
    [void]$processInfo.ArgumentList.Add("[Console]::Out.Write('ready'); Start-Sleep -Seconds 30")
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    [void]$process.Start()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        Assert-RuntimeThrowsLike -Action {
            & $module {
                param($Process)
                Read-CodexProcessOutputLimited `
                    -Process $Process `
                    -TimeoutMilliseconds 250 `
                    -MaximumStandardOutputBytes 4096 `
                    -MaximumStandardErrorBytes 4096 `
                    -Context 'runtime timeout probe'
            } $process
        }.GetNewClosure() -Pattern '*超过*' -Message 'Process output read has a bounded timeout'
        Assert-RuntimeTrue `
            -Condition ($timer.Elapsed.TotalSeconds -lt 8) `
            -Message 'Timed-out child cleanup remains bounded'
        Assert-RuntimeTrue -Condition $process.HasExited -Message 'Timed-out child is terminated'
    }
    finally {
        $timer.Stop()
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
        $process.Dispose()
    }

    $commonProcess = [Diagnostics.Process]::new()
    $commonProcess.StartInfo = $processInfo
    [void]$commonProcess.Start()
    $commonTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        Assert-RuntimeThrowsLike -Action {
            & $module {
                param($Process)
                Read-ToolkitProcessOutputLimited `
                    -Process $Process `
                    -TimeoutMilliseconds 250 `
                    -MaximumStandardOutputBytes 4096 `
                    -MaximumStandardErrorBytes 4096 `
                    -Context 'common timeout probe'
            } $commonProcess
        }.GetNewClosure() -Pattern '*超过*' -Message 'Common process output read has a bounded timeout'
        Assert-RuntimeTrue `
            -Condition ($commonTimer.Elapsed.TotalSeconds -lt 8) `
            -Message 'Common timed-out child cleanup remains bounded'
        Assert-RuntimeTrue `
            -Condition $commonProcess.HasExited `
            -Message 'Common timed-out child is terminated'
    }
    finally {
        $commonTimer.Stop()
        try { if (-not $commonProcess.HasExited) { $commonProcess.Kill($true) } } catch { }
        $commonProcess.Dispose()
    }

    $initializePath = Join-Path $tempRoot 'initialize-pass-thru.toml'
    Write-RuntimeBytes `
        $initializePath `
        ([Text.UTF8Encoding]::new($false).GetBytes("model = `"gpt-5.6-sol`"`r`n"))
    $initializeResult = Initialize-CodexOpenRouterConfig `
        -ConfigPath $initializePath `
        -PassThruMutation
    Assert-RuntimeEqual $initializeResult.Path $initializePath 'Initialize pass-through reports the managed path'
    Assert-RuntimeTrue ($null -ne $initializeResult.State) 'Initialize pass-through reports the committed state'
    Assert-RuntimeTrue ($null -ne $initializeResult.Mutation) 'Initialize pass-through reports its mutation'
    Assert-RuntimeEqual `
        $initializeResult.Mutation.PostState.Snapshot.Sha256 `
        $initializeResult.State.Snapshot.Sha256 `
        'Initialize mutation uses the internal committed snapshot'

    $catalogProbe = Join-Path $tempRoot 'catalog-lock-probe.json'
    $catalogMutexResult = & $module {
        param($CatalogPath)
        $script:runtimeCatalogCoreCalls = 0
        function Update-OpenRouterModelCatalogCore {
            param(
                [string]$CatalogPath,
                [string]$RequiredModel,
                [int]$MaximumAgeHours,
                [switch]$Force,
                [switch]$PassThruMutation
            )
            $script:runtimeCatalogCoreCalls++
            return [pscustomobject]@{
                Path = $CatalogPath
                State = [pscustomobject]@{ Path = $CatalogPath; Existed = $false }
                Mutation = $null
            }
        }
        $direct = Update-OpenRouterModelCatalog `
            -CatalogPath $CatalogPath `
            -RequiredModel 'anthropic/claude-opus-5'
        $passThru = Update-OpenRouterModelCatalog `
            -CatalogPath $CatalogPath `
            -RequiredModel 'anthropic/claude-opus-5' `
            -PassThruMutation
        $outerMutex = Enter-ToolkitMutex -ScopePath (Split-Path -Parent $CatalogPath)
        try {
            $nested = Update-OpenRouterModelCatalog `
                -CatalogPath $CatalogPath `
                -RequiredModel 'anthropic/claude-opus-5'
        }
        finally { Exit-ToolkitMutex -Mutex $outerMutex }
        [pscustomobject]@{
            Direct = $direct
            PassThru = $passThru
            Nested = $nested
            Calls = $script:runtimeCatalogCoreCalls
        }
    } $catalogProbe
    Assert-RuntimeEqual $catalogMutexResult.Calls 3 'Catalog mutex supports direct and same-thread nested calls'
    Assert-RuntimeEqual $catalogMutexResult.Direct $catalogProbe 'Direct catalog call returns through the locked core'
    Assert-RuntimeEqual $catalogMutexResult.PassThru.Path $catalogProbe 'Catalog pass-through returns the core operation result'
    Assert-RuntimeEqual $catalogMutexResult.Nested $catalogProbe 'Nested catalog call releases its own mutex recursion level'

    $moduleText = [IO.File]::ReadAllText($moduleSource)
    $restoreCacheStart = $moduleText.IndexOf('function Restore-CodexDefaultModelCache')
    $desktopResolverStart = $moduleText.IndexOf(
        'function Resolve-CodexDesktopAppFromInventory',
        $restoreCacheStart
    )
    $restoreCacheText = $moduleText.Substring(
        $restoreCacheStart,
        $desktopResolverStart - $restoreCacheStart
    )
    Assert-RuntimeTrue `
        -Condition (-not $restoreCacheText.Contains(
                '$postState = Get-CodexManagedFileState'
            ) -and $restoreCacheText.Contains('Snapshot = $null')) `
        -Message 'Cache removal does not resample an external post-delete state'
    $writeStateStart = $moduleText.IndexOf('function Write-CodexManagedFileState')
    $mutationStart = $moduleText.IndexOf('function New-CodexFileMutation', $writeStateStart)
    $writeStateText = $moduleText.Substring(
        $writeStateStart,
        $mutationStart - $writeStateStart
    )
    Assert-RuntimeTrue `
        -Condition ($writeStateText.Contains('PassThru = $true') -and
            -not $writeStateText.Contains('Get-CodexManagedFileState')) `
        -Message 'Managed writes use the Common commit snapshot without post-commit resampling'
    $catalogCoreStart = $moduleText.IndexOf('function Update-OpenRouterModelCatalogCore')
    $switchStart = $moduleText.IndexOf('function Switch-CodexDesktopProvider')
    $catalogCoreText = $moduleText.Substring(
        $catalogCoreStart,
        $switchStart - $catalogCoreStart
    )
    Assert-RuntimeTrue `
        -Condition ($catalogCoreText.Contains('$catalogCommitState') -and
            $catalogCoreText.Contains('Write-CodexManagedFileState')) `
        -Message 'Catalog publication uses a captured state and CAS write'
    $statusStart = $moduleText.IndexOf('function Get-CodexOpenRouterStatus', $switchStart)
    $switchText = $moduleText.Substring($switchStart, $statusStart - $switchStart)
    Assert-RuntimeTrue `
        -Condition (-not $switchText.Contains('Get-ToolkitFileSnapshots')) `
        -Message 'Switch contains no legacy bulk snapshot call'
    Assert-RuntimeTrue `
        -Condition (-not $switchText.Contains('Restore-ToolkitFileSnapshots')) `
        -Message 'Switch contains no unconditional legacy rollback call'
    Assert-RuntimeTrue `
        -Condition ($switchText.Contains('$PassThruMutations') -and
            $switchText.Contains('Mutations = @($mutations)')) `
        -Message 'Switch can return its internally captured transaction mutations'
    Assert-RuntimeTrue `
        -Condition ($switchText.IndexOf('Get-OpenRouterDesktopApiKey') -lt
            $switchText.IndexOf('Update-OpenRouterModelCatalog')) `
        -Message 'Desktop User key validation precedes catalog refresh'
    Assert-RuntimeTrue `
        -Condition ($switchText.IndexOf('Stop-CodexDesktopApp') -lt
            $switchText.IndexOf('$configState = Get-CodexManagedFileState')) `
        -Message 'Desktop stop precedes managed file snapshots'
    Assert-RuntimeTrue `
        -Condition ($moduleText.Contains('父进程已退出，但输出管道仍被后代占用')) `
        -Message 'Descendant-held output pipes have an early-failure guard'
    Assert-RuntimeTrue `
        -Condition (-not $moduleText.Contains('.WaitForExit()')) `
        -Message 'Module contains no unbounded WaitForExit call'
    $statusEnd = $moduleText.IndexOf('function cx', $statusStart)
    $statusText = $moduleText.Substring($statusStart, $statusEnd - $statusStart)
    Assert-RuntimeTrue `
        -Condition (-not $statusText.Contains('[IO.File]::ReadAllText')) `
        -Message 'Status reads config and catalog from coherent snapshots'
    Assert-RuntimeTrue `
        -Condition ($statusText.Contains('DesktopApiKeyAvailable') -and
            $statusText.Contains('CatalogApiKeyAvailable')) `
        -Message 'Status distinguishes desktop and catalog key availability'

    $commonText = [IO.File]::ReadAllText($commonSource)
    $setKeyText = [IO.File]::ReadAllText($setKeySource)
    $uninstallerText = [IO.File]::ReadAllText($uninstallerSource)
    Assert-RuntimeTrue `
        -Condition ($commonText.Contains('SendMessageTimeout') -and
            $commonText.Contains("'Environment'") -and
            $setKeyText.Contains('Publish-ToolkitEnvironmentChange')) `
        -Message 'User key changes use the shared bounded environment broadcast'
    Assert-RuntimeTrue `
        -Condition ($setKeyText.Contains('ReparsePoint') -and
            $setKeyText.Contains('25MB')) `
        -Message 'Key setup rejects a linked or oversized shared helper before loading it'
    Assert-RuntimeTrue `
        -Condition ($uninstallerText.Contains('Publish-ToolkitEnvironmentChange')) `
        -Message 'User key removal broadcasts the environment setting category'
    Assert-RuntimeTrue `
        -Condition (-not $commonText.Contains('.WaitForExit()')) `
        -Message 'Common process cleanup contains no unbounded WaitForExit call'
    Assert-RuntimeTrue `
        -Condition (-not $moduleText.Contains('[IO.File]::ReadAllText') -and
            -not $moduleText.Contains('[IO.File]::ReadAllBytes')) `
        -Message 'Runtime module reads local managed files through bounded snapshots'
    Assert-RuntimeTrue `
        -Condition ($moduleText.Contains('Remove-ToolkitDirectoryIfSnapshotMatches') -and
            $moduleText.Contains('可能仍含目录刷新认证材料')) `
        -Message 'Isolated catalog homes use identity-checked cleanup with an actionable residual warning'

    Write-Host 'Runtime tests passed: desktop identity, key scope, process bounds, CAS rollback, cache coherence, and switch ordering.'
}
finally {
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith(
            $systemTemp,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Test-Path -LiteralPath $resolvedTempRoot -PathType Container)) {
        [IO.Directory]::Delete($resolvedTempRoot, $true)
    }
}
