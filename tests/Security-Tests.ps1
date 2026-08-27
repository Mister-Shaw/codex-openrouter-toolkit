[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceManifest = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psd1'
$commonPath = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.Common.ps1'
$installerPath = Join-Path `
    $repositoryRoot `
    'scripts\Install-CodexOpenRouter.ps1'
$uninstallerPath = Join-Path `
    $repositoryRoot `
    'scripts\Uninstall-CodexOpenRouter.ps1'
$restorePath = Join-Path `
    $repositoryRoot `
    'scripts\Restore-CodexOpenRouterBackup.ps1'
$modernFixture = Join-Path $PSScriptRoot 'fixtures\catalog-modern.json'
$securityTempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "codex-openrouter-security-tests-$([Guid]::NewGuid().ToString('N'))"

function Assert-SecurityTrue {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "SECURITY ASSERTION FAILED: $Message"
    }
}

function Assert-SecurityEqual {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "SECURITY ASSERTION FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-SecurityThrows {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "SECURITY ASSERTION FAILED: expected failure: $Message"
    }
}

function Write-SecurityText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

try {
    [void](New-Item -ItemType Directory -Path $securityTempRoot -Force)
    . $commonPath
    Import-Module -Name $sourceManifest -Force

    $syntheticKey = 'sk-' + 'or-' + ('a' * 24)
    Assert-SecurityTrue `
        -Condition (Test-ToolkitApiKeyFormat -Value $syntheticKey) `
        -Message 'generic sk-or key format accepted'
    Assert-SecurityTrue `
        -Condition (-not (Test-ToolkitModelId -Value $syntheticKey)) `
        -Message 'API-key-shaped value rejected as model ID'
    Assert-SecurityThrows -Message 'API-key-shaped reasoning effort rejected' -Action {
        Assert-ToolkitReasoningEffort -Value ('sk-' + 'or-' + ('b' * 10))
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-ToolkitApiKeyFormat -Value 'sk-or-short')) `
        -Message 'short key format rejected'
    Assert-SecurityTrue `
        -Condition (-not (Test-ToolkitApiKeyFormat -Value ($syntheticKey + "`n"))) `
        -Message 'key control character rejected'

    $atomicPath = Join-Path $securityTempRoot 'atomic\empty.txt'
    Write-ToolkitUtf8FileAtomic -Path $atomicPath -Content ''
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $atomicPath).Length `
        -Expected ([long]0) `
        -Message 'empty atomic write'
    Write-ToolkitUtf8FileAtomic -Path $atomicPath -Content 'replacement'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($atomicPath)) `
        -Expected 'replacement' `
        -Message 'existing atomic replacement'
    if ($IsWindows) {
        $aclCopyPath = Join-Path $securityTempRoot 'atomic\acl-copy.txt'
        $sourceSddl = (Get-Acl -LiteralPath $atomicPath).Sddl
        Copy-ToolkitFileAtomic -Source $atomicPath -Destination $aclCopyPath
        Assert-SecurityEqual `
            -Actual (Get-Acl -LiteralPath $aclCopyPath).Sddl `
            -Expected $sourceSddl `
            -Message 'new backup copy preserves source ACL'

        $failedAclCopyPath = Join-Path `
            $securityTempRoot `
            'atomic\failed-acl-copy.txt'
        $failedAclCopyError = $null
        function Set-Acl {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [Parameter(Mandatory = $true)][object]$AclObject
            )

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $failedAclCopyPath) {
                throw 'forced copied ACL failure'
            }
            Microsoft.PowerShell.Security\Set-Acl `
                -LiteralPath $LiteralPath `
                -AclObject $AclObject `
                -ErrorAction Stop
        }
        function Remove-Item {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [switch]$Force
            )

            if (Test-ToolkitPathEqual `
                    -Left $LiteralPath `
                    -Right $failedAclCopyPath) {
                throw 'forced failed-copy cleanup failure'
            }
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath $LiteralPath `
                -Force:$Force `
                -ErrorAction Stop
        }
        try {
            Copy-ToolkitFileAtomic `
                -Source $atomicPath `
                -Destination $failedAclCopyPath
        }
        catch {
            $failedAclCopyError = $_.Exception.Message
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Set-Acl `
                -Force `
                -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Remove-Item `
                -Force `
                -ErrorAction SilentlyContinue
        }
        Assert-SecurityTrue `
            -Condition (-not [string]::IsNullOrWhiteSpace($failedAclCopyError)) `
            -Message 'ACL copy cleanup double failure is reported'
        Assert-SecurityTrue `
            -Condition $failedAclCopyError.Contains('可能仍含来源内容') `
            -Message 'ACL copy cleanup failure reports residual content risk'
        Assert-SecurityTrue `
            -Condition $failedAclCopyError.Contains($failedAclCopyPath) `
            -Message 'ACL copy cleanup failure reports residual path'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($failedAclCopyPath)) `
            -Expected 'replacement' `
            -Message 'failed ACL copy residual remains available for manual cleanup'
        Remove-Item -LiteralPath $failedAclCopyPath -Force

        $protectedAclPath = Join-Path $securityTempRoot 'atomic\protected-acl.txt'
        Write-SecurityText -Path $protectedAclPath -Content 'before'
        $protectedAcl = Get-Acl -LiteralPath $protectedAclPath
        $protectedAcl.SetAccessRuleProtection($true, $false)
        $currentUserRule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl',
            'Allow'
        )
        $protectedAcl.SetAccessRule($currentUserRule)
        Set-Acl -LiteralPath $protectedAclPath -AclObject $protectedAcl
        $protectedSddl = (Get-Acl -LiteralPath $protectedAclPath).Sddl
        Write-ToolkitUtf8FileAtomic -Path $protectedAclPath -Content 'after'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($protectedAclPath)) `
            -Expected 'after' `
            -Message 'protected ACL atomic replacement writes content'
        Assert-SecurityEqual `
            -Actual (Get-Acl -LiteralPath $protectedAclPath).Sddl `
            -Expected $protectedSddl `
            -Message 'protected ACL atomic replacement preserves ACL'

        $rollbackFailurePath = Join-Path `
            $securityTempRoot `
            'atomic\rollback-failure.txt'
        Write-SecurityText -Path $rollbackFailurePath -Content 'before'
        $script:atomicAclCallCount = 0
        $script:atomicRollbackLock = $null
        function Get-Acl {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            $script:atomicAclCallCount++
            if ($script:atomicAclCallCount -eq 1) {
                return Microsoft.PowerShell.Security\Get-Acl `
                    -LiteralPath $LiteralPath
            }
            return [pscustomobject]@{ Sddl = 'forced-different-sddl' }
        }
        function Set-Acl {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [Parameter(Mandatory = $true)][object]$AclObject
            )

            $script:atomicRollbackLock = [IO.File]::Open(
                $LiteralPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            throw 'forced post-commit ACL failure'
        }
        $atomicRollbackError = $null
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $rollbackFailurePath `
                -Content 'after'
        }
        catch {
            $atomicRollbackError = $_.Exception.Message
        }
        finally {
            Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
            Remove-Item Function:\Set-Acl -ErrorAction SilentlyContinue
            if ($script:atomicRollbackLock) {
                $script:atomicRollbackLock.Dispose()
                $script:atomicRollbackLock = $null
            }
        }
        $retainedRollbacks = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $rollbackFailurePath) `
            -Filter '.rollback-failure.txt.rollback-*' `
            -File)
        Assert-SecurityTrue `
            -Condition (-not [string]::IsNullOrWhiteSpace($atomicRollbackError)) `
            -Message 'forced atomic rollback failure reported'
        Assert-SecurityTrue `
            -Condition $atomicRollbackError.Contains('原内容快照已保留') `
            -Message 'atomic rollback failure reports retained snapshot'
        Assert-SecurityEqual `
            -Actual $retainedRollbacks.Count `
            -Expected 1 `
            -Message 'failed atomic rollback retains one snapshot'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($retainedRollbacks[0].FullName)) `
            -Expected 'before' `
            -Message 'retained atomic rollback contains original bytes'
        Remove-Item -LiteralPath $retainedRollbacks[0].FullName -Force

        $cleanupFailurePath = Join-Path `
            $securityTempRoot `
            'atomic\cleanup-failure.txt'
        Write-SecurityText -Path $cleanupFailurePath -Content 'sensitive-before'
        $cleanupWarnings = @()
        function Remove-Item {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$LiteralPath,
                [switch]$Force
            )

            if ($LiteralPath -like '*.rollback-*') {
                throw 'forced rollback artifact cleanup failure'
            }
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath $LiteralPath `
                -Force:$Force `
                -ErrorAction Stop
        }
        try {
            Write-ToolkitUtf8FileAtomic `
                -Path $cleanupFailurePath `
                -Content 'after' `
                -WarningVariable cleanupWarnings `
                -WarningAction SilentlyContinue
        }
        finally {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath Function:\Remove-Item `
                -Force `
                -ErrorAction SilentlyContinue
        }
        $cleanupArtifacts = @(Get-ChildItem `
            -LiteralPath (Split-Path -Parent $cleanupFailurePath) `
            -Filter '.cleanup-failure.txt.rollback-*' `
            -File)
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($cleanupFailurePath)) `
            -Expected 'after' `
            -Message 'cleanup warning leaves committed target intact'
        Assert-SecurityEqual `
            -Actual $cleanupArtifacts.Count `
            -Expected 1 `
            -Message 'forced cleanup failure leaves one reported artifact'
        Assert-SecurityEqual `
            -Actual ([IO.File]::ReadAllText($cleanupArtifacts[0].FullName)) `
            -Expected 'sensitive-before' `
            -Message 'undeletable rollback artifact remains available for manual cleanup'
        Assert-SecurityTrue `
            -Condition (($cleanupWarnings | Out-String).Contains(
                $cleanupArtifacts[0].FullName
            )) `
            -Message 'cleanup warning reports residual artifact path'
        Remove-Item -LiteralPath $cleanupArtifacts[0].FullName -Force
    }

    $mutexScope = Join-Path $securityTempRoot 'mutex-scope'
    [void](New-Item -ItemType Directory -Path $mutexScope -Force)
    $heldMutex = Enter-ToolkitMutex -ScopePath $mutexScope
    try {
        $mutexStartInfo = [Diagnostics.ProcessStartInfo]::new()
        $mutexStartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $mutexStartInfo.UseShellExecute = $false
        $mutexStartInfo.CreateNoWindow = $true
        $mutexStartInfo.RedirectStandardOutput = $true
        $mutexStartInfo.RedirectStandardError = $true
        [void]$mutexStartInfo.ArgumentList.Add('-NoProfile')
        [void]$mutexStartInfo.ArgumentList.Add('-Command')
        $escapedCommonPath = $commonPath.Replace("'", "''")
        $escapedMutexScope = (
            $mutexScope + [IO.Path]::DirectorySeparatorChar
        ).Replace("'", "''")
        [void]$mutexStartInfo.ArgumentList.Add(
            ". '$escapedCommonPath'; try { " +
            "`$m = Enter-ToolkitMutex -ScopePath '$escapedMutexScope' " +
            "-TimeoutSeconds 1; 'ACQUIRED'; Exit-ToolkitMutex -Mutex `$m " +
            "} catch { 'BLOCKED' }"
        )
        $mutexProcess = [Diagnostics.Process]::new()
        $mutexProcess.StartInfo = $mutexStartInfo
        [void]$mutexProcess.Start()
        $mutexOutput = $mutexProcess.StandardOutput.ReadToEnd()
        $mutexError = $mutexProcess.StandardError.ReadToEnd()
        $mutexProcess.WaitForExit()
        $mutexProcess.Dispose()
        Assert-SecurityEqual `
            -Actual $mutexOutput.Trim() `
            -Expected 'BLOCKED' `
            -Message "mutex normalizes trailing separator; stderr=$mutexError"
    }
    finally {
        Exit-ToolkitMutex -Mutex $heldMutex
    }

    $newLine = "`r`n"
    $complexToml = @(
        "model = 'old/model'",
        'model_reasoning_effort = "high"',
        'notes = """',
        '[model_providers.openrouter]',
        'model = "inside-string"',
        '"""',
        '[[products]]',
        'name = "fixture"',
        '[model_providers."openrouter"] # retained ] comment',
        'name = "Old name"',
        'base_url = "https://old.invalid"',
        'wire_api = "chat"',
        'custom_setting = "preserve-me"',
        '[model_providers.openrouter.auth]',
        'command = "powershell"',
        'args = ["-NoProfile"]'
    ) -join $newLine
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue -Content $complexToml -Key 'model') `
        -Expected 'old/model' `
        -Message 'literal top-level TOML value'
    $mergedToml = Merge-ToolkitOpenRouterProvider -Content $complexToml
    $mergedAgain = Merge-ToolkitOpenRouterProvider -Content $mergedToml
    Assert-SecurityEqual `
        -Actual $mergedAgain `
        -Expected $mergedToml `
        -Message 'provider merge idempotence'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains('custom_setting = "preserve-me"') `
        -Message 'custom provider field preserved'
    Assert-SecurityTrue `
        -Condition (-not $mergedToml.Contains('[model_providers.openrouter.auth]')) `
        -Message 'persistent command auth table removed'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains('env_key = "OPENROUTER_API_KEY"') `
        -Message 'persistent provider uses env key'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains('# retained ] comment') `
        -Message 'table header comment bracket preserved'
    Assert-SecurityTrue `
        -Condition $mergedToml.Contains("notes = `"`"`"$newLine[model_providers.openrouter]") `
        -Message 'table-looking multiline content preserved'
    Assert-SecurityThrows -Message 'invalid mixed quoted table key rejected' -Action {
        Get-ToolkitTomlTableHeaders `
            -Content ('[model_"providers".openrouter]' + $newLine) | Out-Null
    }
    foreach ($providerConflict in @(
            'model_providers.openrouter = { name = "conflict" }',
            ("[model_providers]$newLine" +
                'openrouter = { name = "conflict" }'),
            '[[model_providers]]',
            '[[model_providers.openrouter]]'
        )) {
        Assert-SecurityThrows `
            -Message "alternate provider declaration rejected: $providerConflict" `
            -Action {
            Merge-ToolkitOpenRouterProvider -Content $providerConflict | Out-Null
        }
    }
    Assert-SecurityThrows -Message 'inline persistent auth rejected' -Action {
        Merge-ToolkitOpenRouterProvider -Content (
            "[model_providers.openrouter]$newLine" +
            'auth = { command = "powershell" }'
        ) | Out-Null
    }

    $quotedTopLevel = (
        '"mo\U00000064el" = "old/model"' + $newLine +
        "'model_provider' = 'openai'" + $newLine
    )
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue `
            -Content $quotedTopLevel `
            -Key 'model') `
        -Expected 'old/model' `
        -Message 'Unicode escaped quoted top-level key decoded'
    $quotedTopLevel = Remove-ToolkitTopLevelTomlKeys `
        -Content $quotedTopLevel `
        -Keys @('model', 'model_provider')
    Assert-SecurityTrue `
        -Condition ([string]::IsNullOrWhiteSpace($quotedTopLevel)) `
        -Message 'quoted managed top-level keys removed semantically'

    $fourQuoteToml = 'notes = """' + $newLine +
        'value""""' + $newLine +
        'model = "safe/model"' + $newLine
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue `
            -Content $fourQuoteToml `
            -Key 'model') `
        -Expected 'safe/model' `
        -Message 'four-quote multiline TOML closing delimiter'

    $nestedArrayToml = @(
        'matrix = [',
        '  [1, 2],',
        '  [3, 4]',
        ']',
        '[custom]',
        'keep = true'
    ) -join $newLine
    $nestedArrayMerged = Merge-ToolkitOpenRouterProvider `
        -Content $nestedArrayToml
    Assert-SecurityTrue `
        -Condition $nestedArrayMerged.Contains('  [1, 2],') `
        -Message 'nested multiline array is not parsed as table header'
    Assert-SecurityTrue `
        -Condition $nestedArrayMerged.Contains("[custom]$newLine" + 'keep = true') `
        -Message 'table after nested multiline array remains intact'

    $catalogPath = Join-Path $securityTempRoot 'config-tests\catalog.json'
    $configPath = Join-Path $securityTempRoot 'config-tests\config.toml'
    [void](New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $catalogPath) `
        -Force)
    Copy-Item -LiteralPath $modernFixture -Destination $catalogPath -Force
    [void](Set-OpenRouterAgentInstructions -Path $catalogPath)
    Write-SecurityText -Path $configPath -Content ($complexToml + $newLine)
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath $catalogPath `
        -ConfigPath $configPath `
        -SkipBackup | Out-Null
    $switchedToml = [IO.File]::ReadAllText($configPath)
    Assert-SecurityTrue `
        -Condition $switchedToml.Contains('model = "anthropic/claude-opus-5"') `
        -Message 'safe OpenRouter model write'
    Assert-SecurityTrue `
        -Condition $switchedToml.Contains('custom_setting = "preserve-me"') `
        -Message 'switch keeps custom provider field'

    $beforeInjection = [IO.File]::ReadAllBytes($configPath)
    Assert-SecurityThrows -Message 'model TOML injection rejected' -Action {
        Set-CodexDesktopModelConfig `
            -Model ("safe`"$newLine" + 'model_provider = "leak"') `
            -Provider openai `
            -ReasoningEffort high `
            -ConfigPath $configPath `
            -SkipBackup | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $beforeInjection,
            [IO.File]::ReadAllBytes($configPath)
        )) `
        -Message 'injection failure leaves config unchanged'

    $duplicateConfig = Join-Path $securityTempRoot 'config-tests\duplicate.toml'
    Write-SecurityText `
        -Path $duplicateConfig `
        -Content ("model = `"one`"$newLine" + "model = `"two`"$newLine")
    $duplicateBefore = [IO.File]::ReadAllBytes($duplicateConfig)
    Assert-SecurityThrows -Message 'duplicate managed key rejected' -Action {
        Set-CodexDesktopModelConfig `
            -Model 'gpt-safe' `
            -Provider openai `
            -ReasoningEffort high `
            -ConfigPath $duplicateConfig `
            -SkipBackup | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $duplicateBefore,
            [IO.File]::ReadAllBytes($duplicateConfig)
        )) `
        -Message 'duplicate-key failure leaves config unchanged'

    $multiValueConfig = Join-Path $securityTempRoot 'config-tests\multivalue.toml'
    Write-SecurityText `
        -Path $multiValueConfig `
        -Content ('model = """' + $newLine + 'unsafe' + $newLine + '"""' + $newLine)
    Assert-SecurityThrows -Message 'multiline managed value rejected' -Action {
        Set-CodexDesktopModelConfig `
            -Model 'gpt-safe' `
            -Provider openai `
            -ReasoningEffort high `
            -ConfigPath $multiValueConfig `
            -SkipBackup | Out-Null
    }

    $malformedCatalogs = @(
        [pscustomobject]@{
            Name = 'messages-string'
            Data = [pscustomobject]@{
                models = @([pscustomobject]@{
                    slug = 'valid/model'
                    model_messages = 'invalid'
                })
            }
        },
        [pscustomobject]@{
            Name = 'missing-slug'
            Data = [pscustomobject]@{
                models = @([pscustomobject]@{ base_instructions = 'prompt' })
            }
        },
        [pscustomobject]@{
            Name = 'scalar-model-object'
            Data = [pscustomobject]@{
                models = [pscustomobject]@{
                    slug = 'valid/model'
                    base_instructions = 'prompt'
                }
            }
        },
        [pscustomobject]@{
            Name = 'standard-data-shape'
            Data = [pscustomobject]@{
                data = @([pscustomobject]@{ id = 'valid/model' })
            }
        }
    )
    foreach ($case in $malformedCatalogs) {
        $casePath = Join-Path $securityTempRoot "catalog-$($case.Name).json"
        Write-SecurityText `
            -Path $casePath `
            -Content ($case.Data | ConvertTo-Json -Depth 20)
        Assert-SecurityTrue `
            -Condition (-not (Test-CodexModelCatalog `
                -Path $casePath `
                -MinimumModelCount 1)) `
            -Message "malformed catalog rejected: $($case.Name)"
    }

    $escapedSecretCatalog = Join-Path `
        $securityTempRoot `
        'catalog-escaped-secret.json'
    $escapedSecretText = '{"models":[{"slug":"valid/model","base_instructions":"prompt","diagnostic":"sk-or-\u0078xxxxxxxxxxxx"}]}'
    Write-SecurityText -Path $escapedSecretCatalog -Content $escapedSecretText
    Assert-SecurityTrue `
        -Condition (-not (Test-CodexModelCatalog `
            -Path $escapedSecretCatalog `
            -MinimumModelCount 1)) `
        -Message 'Unicode escaped secret-like catalog value rejected'
    $escapedSecretBefore = [IO.File]::ReadAllBytes($escapedSecretCatalog)
    Assert-SecurityThrows -Message 'secret-like catalog prompt rewrite rejected' -Action {
        Set-OpenRouterAgentInstructions -Path $escapedSecretCatalog | Out-Null
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $escapedSecretBefore,
            [IO.File]::ReadAllBytes($escapedSecretCatalog)
        )) `
        -Message 'rejected catalog remains byte-identical'
    $escapedSecretNameCatalog = Join-Path `
        $securityTempRoot `
        'catalog-escaped-secret-name.json'
    $escapedSecretNameText = '{"models":[{"slug":"valid/model","base_instructions":"prompt","sk-or-\u0078xxxxxxxxxxxx":"diagnostic"}]}'
    Write-SecurityText `
        -Path $escapedSecretNameCatalog `
        -Content $escapedSecretNameText
    Assert-SecurityTrue `
        -Condition (-not (Test-CodexModelCatalog `
            -Path $escapedSecretNameCatalog `
            -MinimumModelCount 1)) `
        -Message 'Unicode escaped secret-like property name rejected'

    $timestampCatalog = Join-Path $securityTempRoot 'timestamp-catalog.json'
    Copy-Item -LiteralPath $modernFixture -Destination $timestampCatalog
    $oldTimestamp = [DateTime]::UtcNow.AddDays(-3)
    [IO.File]::SetLastWriteTimeUtc($timestampCatalog, $oldTimestamp)
    [void](Set-OpenRouterAgentInstructions `
        -Path $timestampCatalog `
        -PreserveLastWriteTime)
    $actualTimestamp = (Get-Item -LiteralPath $timestampCatalog).LastWriteTimeUtc
    Assert-SecurityTrue `
        -Condition ([Math]::Abs(($actualTimestamp - $oldTimestamp).TotalSeconds) -lt 2) `
        -Message 'prompt rewrite preserves catalog freshness timestamp'

    $unexpectedUriRejected = $false
    $module = Get-Module CodexOpenRouter
    try {
        & $module {
            param($Key)
            Invoke-OpenRouterCatalogDownload `
                -Uri 'https://example.invalid/api/v1/models' `
                -ClientVersion '1.2.3' `
                -ApiKey $Key
        } $syntheticKey
    }
    catch {
        $unexpectedUriRejected = $true
    }
    Assert-SecurityTrue `
        -Condition $unexpectedUriRejected `
        -Message 'catalog downloader rejects unexpected host before network access'

    $outputLimitRejected = $false
    $module = Get-Module CodexOpenRouter
    try {
        & $module {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            [void]$startInfo.ArgumentList.Add('-NoProfile')
            [void]$startInfo.ArgumentList.Add('-Command')
            [void]$startInfo.ArgumentList.Add(
                "[Console]::Out.Write('x' * 50000)"
            )
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            try {
                Read-CodexProcessOutputLimited `
                    -Process $process `
                    -TimeoutMilliseconds 10000 `
                    -MaximumStandardOutputBytes 1024 `
                    -MaximumStandardErrorBytes 1024 `
                    -Context 'security output limit' | Out-Null
            }
            finally {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $process.WaitForExit()
                }
                $process.Dispose()
            }
        }
    }
    catch {
        $outputLimitRejected = $true
    }
    Assert-SecurityTrue `
        -Condition $outputLimitRejected `
        -Message 'streaming process output limit enforced'

    $originalPathEnvironment = $env:PATH
    $shadowRoot = Join-Path $securityTempRoot 'path-shadow'
    [void](New-Item -ItemType Directory -Path $shadowRoot -Force)
    Write-SecurityText `
        -Path (Join-Path $shadowRoot 'codex.exe') `
        -Content 'untrusted fixture'
    try {
        $env:PATH = $shadowRoot + [IO.Path]::PathSeparator + $originalPathEnvironment
        $selectedCli = $null
        try { $selectedCli = Get-CodexCliPath } catch { }
        if ($selectedCli) {
            Assert-SecurityTrue `
                -Condition (-not ([IO.Path]::GetFullPath($selectedCli).StartsWith(
                    [IO.Path]::GetFullPath($shadowRoot),
                    [StringComparison]::OrdinalIgnoreCase
                ))) `
                -Message 'PATH shadow ignored by trusted CLI discovery'
        }
    }
    finally {
        $env:PATH = $originalPathEnvironment
    }

    $invalidInstallHome = Join-Path $securityTempRoot 'invalid-install\.codex'
    $invalidInstallProfile = Join-Path $securityTempRoot 'invalid-install\profile.ps1'
    Assert-SecurityThrows -Message 'installer model injection rejected before mutation' -Action {
        & $installerPath `
            -CodexHome $invalidInstallHome `
            -ProfilePath $invalidInstallProfile `
            -OpenRouterModel ("safe`"$newLine" + 'model_provider = "leak"') `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $invalidInstallHome)) `
        -Message 'invalid installer input creates no CodexHome'

    $secretModelInstallHome = Join-Path `
        $securityTempRoot `
        'secret-model-install\.codex'
    $secretModelInstallProfile = Join-Path `
        $securityTempRoot `
        'secret-model-install\profile.ps1'
    $secretModelError = $null
    try {
        & $installerPath `
            -CodexHome $secretModelInstallHome `
            -ProfilePath $secretModelInstallProfile `
            -OpenRouterModel $syntheticKey `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    catch {
        $secretModelError = $_.Exception.Message
    }
    Assert-SecurityTrue `
        -Condition (-not [string]::IsNullOrWhiteSpace($secretModelError)) `
        -Message 'installer rejects API-key-shaped model before mutation'
    Assert-SecurityTrue `
        -Condition (-not $secretModelError.Contains($syntheticKey)) `
        -Message 'model validation error does not echo API-key-shaped input'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $secretModelInstallHome)) `
        -Message 'API-key-shaped model creates no CodexHome'

    $rollbackHome = Join-Path $securityTempRoot 'rollback-install\.codex'
    $rollbackProfile = Join-Path $securityTempRoot 'rollback-install\profile.ps1'
    $rollbackConfig = Join-Path $rollbackHome 'config.toml'
    Write-SecurityText -Path $rollbackProfile -Content 'function Broken {'
    Write-SecurityText -Path $rollbackConfig -Content ''
    $rollbackProfileBefore = [IO.File]::ReadAllBytes($rollbackProfile)
    Assert-SecurityThrows -Message 'first install failure rolls back' -Action {
        & $installerPath `
            -CodexHome $rollbackHome `
            -ProfilePath $rollbackProfile `
            -OpenAIModel 'gpt-original' `
            -OpenAIReasoningEffort low `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    Assert-SecurityTrue `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path $rollbackHome 'codex-openrouter-toolkit'))) `
        -Message 'failed first install leaves no active install root'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $rollbackProfileBefore,
            [IO.File]::ReadAllBytes($rollbackProfile)
        )) `
        -Message 'failed first install restores profile bytes'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $rollbackConfig).Length `
        -Expected ([long]0) `
        -Message 'failed first install restores empty config'

    $upgradeHome = Join-Path $securityTempRoot 'upgrade-install\.codex'
    $upgradeProfile = Join-Path $securityTempRoot 'upgrade-install\profile.ps1'
    $upgradeConfig = Join-Path $upgradeHome 'config.toml'
    Write-SecurityText -Path $upgradeProfile -Content ''
    $restoreProfileSddl = $null
    if ($IsWindows) {
        $restoreProfileAcl = Get-Acl -LiteralPath $upgradeProfile
        $restoreProfileAcl.SetAccessRuleProtection($true, $false)
        $restoreProfileRule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl',
            'Allow'
        )
        $restoreProfileAcl.SetAccessRule($restoreProfileRule)
        Set-Acl -LiteralPath $upgradeProfile -AclObject $restoreProfileAcl
        $restoreProfileSddl = (Get-Acl -LiteralPath $upgradeProfile).Sddl
    }
    Write-SecurityText `
        -Path $upgradeConfig `
        -Content ("model = `"gpt-original`"$newLine" +
            "model_reasoning_effort = `"low`"$newLine")
    $firstInstall = & $installerPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -OpenAIModel 'gpt-original' `
        -OpenAIReasoningEffort low `
        -OpenRouterModel 'anthropic/custom-model' `
        -OpenRouterReasoningEffort medium `
        -CatalogMaximumAgeHours 48 `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $firstManifest = [IO.File]::ReadAllText(
        (Join-Path $firstInstall.BackupPath 'manifest.json')
    ) | ConvertFrom-Json
    Assert-SecurityEqual -Actual ([int]$firstManifest.SchemaVersion) -Expected 2 -Message 'schema 2 install backup'
    Assert-SecurityEqual -Actual @($firstManifest.Files).Count -Expected 5 -Message 'five managed backup entries'
    $emptyProfileEntry = @($firstManifest.Files | Where-Object Name -eq 'profile')[0]
    Assert-SecurityTrue `
        -Condition ([string]$emptyProfileEntry.Sha256 -cmatch '^[A-F0-9]{64}$') `
        -Message 'empty profile backup hash recorded'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath (Join-Path $firstInstall.BackupPath 'profile.bak')).Length `
        -Expected ([long]0) `
        -Message 'empty profile backup retained'

    $secondInstall = & $installerPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $upgradedSettingsPath = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit\settings.json'
    $upgradedSettings = [IO.File]::ReadAllText($upgradedSettingsPath) | ConvertFrom-Json
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenAIModel) -Expected 'gpt-original' -Message 'upgrade preserves OpenAI model'
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenAIReasoningEffort) -Expected 'low' -Message 'upgrade preserves OpenAI effort'
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenRouterModel) -Expected 'anthropic/custom-model' -Message 'upgrade preserves OpenRouter model'
    Assert-SecurityEqual -Actual ([string]$upgradedSettings.OpenRouterReasoningEffort) -Expected 'medium' -Message 'upgrade preserves OpenRouter effort'
    Assert-SecurityEqual -Actual ([int]$upgradedSettings.CatalogMaximumAgeHours) -Expected 48 -Message 'upgrade preserves catalog age'
    $secondManifest = [IO.File]::ReadAllText(
        (Join-Path $secondInstall.BackupPath 'manifest.json')
    ) | ConvertFrom-Json
    Assert-SecurityTrue `
        -Condition (@($secondManifest.PreviousInstallFiles).Count -gt 0) `
        -Message 'upgrade backup persists previous install inventory'
    $previousModuleInBackup = Join-Path `
        $secondInstall.BackupPath `
        'previous-install\CodexOpenRouter\CodexOpenRouter.psm1'
    $previousModuleBytes = [IO.File]::ReadAllBytes($previousModuleInBackup)
    [IO.File]::WriteAllText(
        $previousModuleInBackup,
        ([IO.File]::ReadAllText($previousModuleInBackup) +
            "$newLine# tampered previous install"),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-SecurityThrows -Message 'tampered previous install inventory rejected' -Action {
        & $restorePath `
            -BackupPath $secondInstall.BackupPath `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($previousModuleInBackup, $previousModuleBytes)

    $installedManifest = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit\CodexOpenRouter\CodexOpenRouter.psd1'
    Import-Module -Name $installedManifest -Force
    [void](Get-CodexOpenRouterSettings -SettingsPath $upgradedSettingsPath)
    $validSettingsText = [IO.File]::ReadAllText($upgradedSettingsPath)
    $tamperedSettings = $validSettingsText | ConvertFrom-Json
    $tamperedSettings.ConfigPath = Join-Path $securityTempRoot 'outside-config.toml'
    Write-SecurityText `
        -Path $upgradedSettingsPath `
        -Content ($tamperedSettings | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'module rejects tampered fixed settings path' -Action {
        Get-CodexOpenRouterSettings -SettingsPath $upgradedSettingsPath | Out-Null
    }
    Write-SecurityText -Path $upgradedSettingsPath -Content $validSettingsText

    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    $partialRestoreInstallRoot = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit'
    $heldActiveInstall = Join-Path `
        $upgradeHome `
        'held-active-install-for-partial-copy-test'
    Move-Item `
        -LiteralPath $partialRestoreInstallRoot `
        -Destination $heldActiveInstall
    $partialRestoreError = $null
    function Set-Acl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [Parameter(Mandatory = $true)][object]$AclObject
        )

        if ([IO.Path]::GetFullPath($LiteralPath).StartsWith(
                [IO.Path]::GetFullPath($partialRestoreInstallRoot) +
                    [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'forced previous-install copy failure'
        }
        Microsoft.PowerShell.Security\Set-Acl `
            -LiteralPath $LiteralPath `
            -AclObject $AclObject `
            -ErrorAction Stop
    }
    try {
        & $restorePath `
            -BackupPath $secondInstall.BackupPath `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    catch {
        $partialRestoreError = $_.Exception.Message
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item `
            -LiteralPath Function:\Set-Acl `
            -Force `
            -ErrorAction SilentlyContinue
    }
    Assert-SecurityTrue `
        -Condition (-not [string]::IsNullOrWhiteSpace($partialRestoreError)) `
        -Message 'partial previous-install copy failure is reported'
    Assert-SecurityTrue `
        -Condition $partialRestoreError.Contains('已还原事务前状态') `
        -Message 'partial previous-install copy reports completed rollback'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path -LiteralPath $partialRestoreInstallRoot)) `
        -Message 'partial previous-install directory is removed during rollback'
    Move-Item `
        -LiteralPath $heldActiveInstall `
        -Destination $partialRestoreInstallRoot

    $victimPath = Join-Path $securityTempRoot 'victim.ps1'
    Write-SecurityText -Path $victimPath -Content 'victim-safe'
    $maliciousBackup = Join-Path `
        $upgradeHome `
        'codex-openrouter-toolkit-backups\malicious-fixture'
    Copy-Item `
        -LiteralPath $secondInstall.BackupPath `
        -Destination $maliciousBackup `
        -Recurse
    $maliciousManifestPath = Join-Path $maliciousBackup 'manifest.json'
    $maliciousManifest = [IO.File]::ReadAllText($maliciousManifestPath) |
        ConvertFrom-Json
    (@($maliciousManifest.Files | Where-Object Name -eq 'profile')[0]).Target =
        $victimPath
    Write-SecurityText `
        -Path $maliciousManifestPath `
        -Content ($maliciousManifest | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'restore rejects arbitrary manifest target' -Action {
        & $restorePath `
            -BackupPath $maliciousBackup `
            -CodexHome $upgradeHome `
            -ProfilePath $upgradeProfile `
            -Force | Out-Null
    }
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($victimPath)) `
        -Expected 'victim-safe' `
        -Message 'malicious restore leaves unrelated file unchanged'

    $configBeforeWhatIf = [IO.File]::ReadAllBytes($upgradeConfig)
    $whatIfResult = & $restorePath `
        -BackupPath $firstInstall.BackupPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -Force `
        -WhatIf
    Assert-SecurityTrue -Condition (-not $whatIfResult.Restored) -Message 'restore WhatIf reports no restore'
    Assert-SecurityEqual -Actual ([int]$whatIfResult.RestoredFiles) -Expected 0 -Message 'restore WhatIf file count'
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $configBeforeWhatIf,
            [IO.File]::ReadAllBytes($upgradeConfig)
        )) `
        -Message 'restore WhatIf leaves config unchanged'

    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $upgradeProfile -Force
    $restoreResult = & $restorePath `
        -BackupPath $firstInstall.BackupPath `
        -CodexHome $upgradeHome `
        -ProfilePath $upgradeProfile `
        -Force
    Assert-SecurityTrue -Condition $restoreResult.Restored -Message 'schema 2 restore succeeds'
    Assert-SecurityTrue `
        -Condition (-not (Test-Path `
            -LiteralPath (Join-Path $upgradeHome 'codex-openrouter-toolkit'))) `
        -Message 'first-install restore removes active install root'
    Assert-SecurityEqual `
        -Actual (Get-Item -LiteralPath $upgradeProfile).Length `
        -Expected ([long]0) `
        -Message 'first-install restore recovers empty profile'
    if ($IsWindows) {
        Assert-SecurityEqual `
            -Actual (Get-Acl -LiteralPath $upgradeProfile).Sddl `
            -Expected $restoreProfileSddl `
            -Message 'restore of missing profile preserves backup ACL'
    }

    $ownershipHome = Join-Path $securityTempRoot 'restore-ownership\.codex'
    $ownershipProfile = Join-Path `
        $securityTempRoot `
        'restore-ownership\profile.ps1'
    Write-SecurityText -Path $ownershipProfile -Content ''
    $ownershipInstall = & $installerPath `
        -CodexHome $ownershipHome `
        -ProfilePath $ownershipProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $ownershipInstallRoot = Join-Path `
        $ownershipHome `
        'codex-openrouter-toolkit'
    $heldOwnershipInstall = Join-Path `
        $ownershipHome `
        'held-valid-install'
    Move-Item `
        -LiteralPath $ownershipInstallRoot `
        -Destination $heldOwnershipInstall
    [void](New-Item -ItemType Directory -Path $ownershipInstallRoot)
    $ownershipCanary = Join-Path $ownershipInstallRoot 'unrelated-canary.txt'
    Write-SecurityText -Path $ownershipCanary -Content 'keep-me'
    Assert-SecurityThrows -Message 'restore refuses unrelated install directory' -Action {
        & $restorePath `
            -BackupPath $ownershipInstall.BackupPath `
            -CodexHome $ownershipHome `
            -ProfilePath $ownershipProfile `
            -Force | Out-Null
    }
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($ownershipCanary)) `
        -Expected 'keep-me' `
        -Message 'restore ownership failure preserves unrelated canary'
    Remove-Item -LiteralPath $ownershipInstallRoot -Recurse -Force
    Move-Item `
        -LiteralPath $heldOwnershipInstall `
        -Destination $ownershipInstallRoot
    & $uninstallerPath `
        -CodexHome $ownershipHome `
        -ProfilePath $ownershipProfile `
        -KeepCurrentProvider | Out-Null

    $profileSafetyHome = Join-Path $securityTempRoot 'profile-safety\.codex'
    $profileSafetyPath = Join-Path `
        $securityTempRoot `
        'profile-safety\profile.ps1'
    $profileHereString = @'
$embeddedMarkers = @"
# >>> codex-openrouter-toolkit >>>
keep-this-here-string-data
# <<< codex-openrouter-toolkit <<<
"@
'@
    Write-SecurityText -Path $profileSafetyPath -Content $profileHereString
    $profileSafetyInstall = & $installerPath `
        -CodexHome $profileSafetyHome `
        -ProfilePath $profileSafetyPath `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $installedProfileContent = [IO.File]::ReadAllText($profileSafetyPath)
    $withoutManagedBlock = Remove-ToolkitPowerShellCommentBlock `
        -Content $installedProfileContent `
        -StartMarker '# >>> codex-openrouter-toolkit >>>' `
        -EndMarker '# <<< codex-openrouter-toolkit <<<'
    Assert-SecurityEqual `
        -Actual $withoutManagedBlock.Trim() `
        -Expected $profileHereString.Trim() `
        -Message 'installer preserves marker text inside here-string'
    & $uninstallerPath `
        -CodexHome $profileSafetyHome `
        -ProfilePath $profileSafetyPath `
        -KeepCurrentProvider | Out-Null
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($profileSafetyPath)).Trim() `
        -Expected $profileHereString.Trim() `
        -Message 'uninstaller preserves marker text inside here-string'

    $tamperHome = Join-Path $securityTempRoot 'uninstall-tamper\.codex'
    $tamperProfile = Join-Path $securityTempRoot 'uninstall-tamper\profile.ps1'
    Write-SecurityText -Path $tamperProfile -Content 'function Keep-Me { 1 }'
    $tamperInstall = & $installerPath `
        -CodexHome $tamperHome `
        -ProfilePath $tamperProfile `
        -OpenAIModel 'gpt-original' `
        -OpenAIReasoningEffort low `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $tamperSettingsPath = [string]$tamperInstall.SettingsPath
    $tamperSettingsOriginal = [IO.File]::ReadAllText($tamperSettingsPath)
    $tamperSettingsObject = $tamperSettingsOriginal | ConvertFrom-Json
    $tamperSettingsObject.ProfilePath = $victimPath
    Write-SecurityText `
        -Path $tamperSettingsPath `
        -Content ($tamperSettingsObject | ConvertTo-Json -Depth 10)
    Assert-SecurityThrows -Message 'uninstaller rejects settings profile tamper' -Action {
        & $uninstallerPath `
            -CodexHome $tamperHome `
            -ProfilePath $tamperProfile `
            -KeepCurrentProvider | Out-Null
    }
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText($victimPath)) `
        -Expected 'victim-safe' `
        -Message 'uninstaller profile tamper leaves victim unchanged'
    Write-SecurityText -Path $tamperSettingsPath -Content $tamperSettingsOriginal
    & $uninstallerPath `
        -CodexHome $tamperHome `
        -ProfilePath $tamperProfile `
        -KeepCurrentProvider | Out-Null

    $switchHome = Join-Path $securityTempRoot 'switch-rollback\.codex'
    $switchProfile = Join-Path $securityTempRoot 'switch-rollback\profile.ps1'
    Write-SecurityText -Path $switchProfile -Content ''
    $switchInstall = & $installerPath `
        -CodexHome $switchHome `
        -ProfilePath $switchProfile `
        -OpenAIModel 'gpt-original' `
        -OpenAIReasoningEffort low `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $switchSettings = [IO.File]::ReadAllText($switchInstall.SettingsPath) |
        ConvertFrom-Json
    $switchCatalog = [string]$switchSettings.CatalogPath
    Copy-Item -LiteralPath $modernFixture -Destination $switchCatalog -Force
    Import-Module -Name $switchInstall.ModulePath -Force
    [void](Set-OpenRouterAgentInstructions -Path $switchCatalog)
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath $switchCatalog `
        -ConfigPath ([string]$switchSettings.ConfigPath) `
        -SkipBackup | Out-Null
    Write-SecurityText `
        -Path ([string]$switchSettings.OpenAICachePath) `
        -Content '{"models":[{"slug":"gpt-original","base_instructions":"prompt"}]}'
    $switchConfigBefore = [IO.File]::ReadAllBytes([string]$switchSettings.ConfigPath)
    if (Test-Path -LiteralPath ([string]$switchSettings.ActiveCachePath)) {
        Remove-Item -LiteralPath ([string]$switchSettings.ActiveCachePath) -Force -Recurse
    }
    [void](New-Item `
        -ItemType Directory `
        -Path ([string]$switchSettings.ActiveCachePath) `
        -Force)
    Assert-SecurityThrows -Message 'OpenAI switch failure triggers rollback' -Action {
        Switch-CodexDesktopProvider -Provider openai -NoRestart
    }
    Assert-SecurityTrue `
        -Condition ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            $switchConfigBefore,
            [IO.File]::ReadAllBytes([string]$switchSettings.ConfigPath)
        )) `
        -Message 'failed provider switch restores config bytes'
    Remove-Item `
        -LiteralPath ([string]$switchSettings.ActiveCachePath) `
        -Recurse `
        -Force
    & $uninstallerPath `
        -CodexHome $switchHome `
        -ProfilePath $switchProfile `
        -KeepCurrentProvider | Out-Null

    $cacheHome = Join-Path $securityTempRoot 'uninstall-cache\.codex'
    $cacheProfile = Join-Path $securityTempRoot 'uninstall-cache\profile.ps1'
    $cacheConfig = Join-Path $cacheHome 'config.toml'
    Write-SecurityText -Path $cacheProfile -Content ''
    Write-SecurityText `
        -Path $cacheConfig `
        -Content ("model = `"gpt-original`"$newLine" +
            "model_reasoning_effort = `"low`"$newLine")
    $cacheInstall = & $installerPath `
        -CodexHome $cacheHome `
        -ProfilePath $cacheProfile `
        -SkipCatalogRefresh `
        -SkipProfileReload
    $cacheSettings = [IO.File]::ReadAllText($cacheInstall.SettingsPath) |
        ConvertFrom-Json
    Copy-Item `
        -LiteralPath $modernFixture `
        -Destination ([string]$cacheSettings.CatalogPath) `
        -Force
    Import-Module -Name $cacheInstall.ModulePath -Force
    [void](Set-OpenRouterAgentInstructions -Path ([string]$cacheSettings.CatalogPath))
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath ([string]$cacheSettings.CatalogPath) `
        -ConfigPath ([string]$cacheSettings.ConfigPath) `
        -SkipBackup | Out-Null
    Write-SecurityText `
        -Path ([string]$cacheSettings.ActiveCachePath) `
        -Content '{"models":[{"slug":"anthropic/claude-opus-5","base_instructions":"prompt"}]}'
    $expectedOpenAICache = '{"models":[{"slug":"gpt-original","base_instructions":"prompt"}]}'
    Write-SecurityText `
        -Path ([string]$cacheSettings.OpenAICachePath) `
        -Content $expectedOpenAICache
    & $uninstallerPath `
        -CodexHome $cacheHome `
        -ProfilePath $cacheProfile | Out-Null
    $uninstalledConfig = [IO.File]::ReadAllText([string]$cacheSettings.ConfigPath)
    Assert-SecurityEqual `
        -Actual (Get-ToolkitTopLevelTomlValue `
            -Content $uninstalledConfig `
            -Key 'model') `
        -Expected 'gpt-original' `
        -Message 'uninstall restores OpenAI model config'
    Assert-SecurityEqual `
        -Actual ([IO.File]::ReadAllText([string]$cacheSettings.ActiveCachePath)) `
        -Expected $expectedOpenAICache `
        -Message 'uninstall restores OpenAI cache'

    Write-Host 'Security tests passed: TOML, catalog, key format, trusted CLI, install, restore, switch rollback, settings tamper, and uninstall cache checks succeeded.'
}
finally {
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedSecurityTemp = [IO.Path]::GetFullPath($securityTempRoot)
    if ($resolvedSecurityTemp.StartsWith(
            $systemTemp,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Test-Path -LiteralPath $resolvedSecurityTemp -PathType Container)) {
        [IO.Directory]::Delete($resolvedSecurityTemp, $true)
    }
}
