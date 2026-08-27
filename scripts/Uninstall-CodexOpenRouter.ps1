[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexHome,

    [string]$ProfilePath,

    [switch]$KeepCurrentProvider,

    [switch]$RemoveApiKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$commonHelperPath = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.Common.ps1'
if (-not (Test-Path -LiteralPath $commonHelperPath -PathType Leaf)) {
    throw "找不到共同安全 helper：$commonHelperPath"
}
. $commonHelperPath

function Get-UninstallerAbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Name 必须是完整绝对路径。"
    }
    try {
        return [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "$Name 无法规范化：$($_.Exception.Message)"
    }
}

function Assert-UninstallerNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$Recurse
    )

    $probe = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $probe) {
            break
        }
        $probe = $parent
    }
    while (Test-Path -LiteralPath $probe) {
        $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name 的现有路径包含重解析点：$($item.FullName)"
        }
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $probe) {
            break
        }
        $probe = $parent
    }

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $Recurse -or -not (Test-Path -LiteralPath $resolvedPath)) {
        return
    }
    $rootItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    $pending = [Collections.Generic.Stack[IO.FileSystemInfo]]::new()
    $pending.Push($rootItem)
    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name 的现有路径包含重解析点：$($item.FullName)"
        }
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem `
                    -LiteralPath $item.FullName `
                    -Force `
                    -ErrorAction Stop)) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "$Name 的现有路径包含重解析点：$($child.FullName)"
                }
                if ($child.PSIsContainer) { $pending.Push($child) }
            }
        }
    }
}

function Get-UninstallerRequiredStringProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or
        [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "settings 缺少有效字段：$Name"
    }
    return [string]$property.Value
}

function Assert-UninstallerReasoningEffort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Assert-ToolkitReasoningEffort -Value $Value -Name $Name
    if (@(
            'none',
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
            'ultra'
        ) -cnotcontains $Value) {
        throw "$Name 的值不受支持：$Value"
    }
}

function Remove-UninstallerEnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [EnvironmentVariableTarget]$Target
    )

    $method = [Environment].GetMethod(
        'SetEnvironmentVariable',
        [type[]]@([string], [string], [EnvironmentVariableTarget])
    )
    $arguments = [object[]]::new(3)
    $arguments[0] = $Name
    $arguments[1] = $null
    $arguments[2] = $Target
    try {
        [void]$method.Invoke($null, $arguments)
    }
    catch {
        $message = if ($_.Exception.InnerException) {
            $_.Exception.InnerException.Message
        }
        else {
            $_.Exception.Message
        }
        throw "无法删除环境变量 $Name（$Target）：$message"
    }
}

$codexHomeSpecified = $PSBoundParameters.ContainsKey('CodexHome')
$profilePathSpecified = $PSBoundParameters.ContainsKey('ProfilePath')
if ($codexHomeSpecified -and [string]::IsNullOrWhiteSpace($CodexHome)) {
    throw '显式传入的 CodexHome 不能为空。'
}
if ($profilePathSpecified -and [string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw '显式传入的 ProfilePath 不能为空。'
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}
$resolvedCodexHome = Get-UninstallerAbsolutePath `
    -Path $CodexHome `
    -Name 'CodexHome'
$volumeRoot = [IO.Path]::GetPathRoot($resolvedCodexHome).
    TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($resolvedCodexHome.TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq
    $volumeRoot) {
    throw 'CodexHome 不能是卷根目录。'
}
if (-not (Test-Path -LiteralPath $resolvedCodexHome -PathType Container)) {
    throw "找不到 CodexHome：$resolvedCodexHome"
}
Assert-UninstallerNoReparsePoint -Path $resolvedCodexHome -Name 'CodexHome'

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = [string]$PROFILE.CurrentUserCurrentHost
}
$requestedProfilePath = Get-UninstallerAbsolutePath `
    -Path $ProfilePath `
    -Name 'ProfilePath'
if ([IO.Path]::GetExtension($requestedProfilePath) -cne '.ps1') {
    throw 'ProfilePath 必须指向 .ps1 文件。'
}
Assert-UninstallerNoReparsePoint `
    -Path $requestedProfilePath `
    -Name 'ProfilePath'

$installRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit'
$settingsPath = Join-Path $installRoot 'settings.json'
$installedModuleManifest = Join-Path `
    $installRoot `
    'CodexOpenRouter\CodexOpenRouter.psd1'
$sourceModuleManifest = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psd1'
$mutex = Enter-ToolkitMutex -ScopePath $resolvedCodexHome
try {
if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
    throw "找不到工具包安装目录：$installRoot"
}
Assert-UninstallerNoReparsePoint `
    -Path $installRoot `
    -Name '工具包安装目录' `
    -Recurse
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "找不到已安装的工具包设置：$settingsPath"
}
Assert-UninstallerNoReparsePoint -Path $settingsPath -Name 'settings'

try {
    $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
}
catch {
    throw "settings 无法解析：$($_.Exception.Message)"
}
$schemaProperty = $settings.PSObject.Properties['SchemaVersion']
if ($null -eq $schemaProperty -or
    [int]$schemaProperty.Value -notin @(1, 2)) {
    throw 'settings 的 SchemaVersion 不受支持。'
}
if ([int]$schemaProperty.Value -eq 2) {
    $toolkit = Get-UninstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'Toolkit'
    if ($toolkit -cne 'codex-openrouter-toolkit') {
        throw 'settings 的 Toolkit 标识不匹配。'
    }
    $recordedInstallRoot = Get-UninstallerAbsolutePath `
        -Path (Get-UninstallerRequiredStringProperty `
            -InputObject $settings `
            -Name 'InstallRoot') `
        -Name 'settings.InstallRoot'
    if (-not (Test-ToolkitPathEqual `
            -Left $recordedInstallRoot `
            -Right $installRoot)) {
        throw 'settings 的 InstallRoot 与固定安装目录不匹配。'
    }
}

$recordedCodexHome = Get-UninstallerAbsolutePath `
    -Path (Get-UninstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'CodexHome') `
    -Name 'settings.CodexHome'
if (-not (Test-ToolkitPathEqual `
        -Left $recordedCodexHome `
        -Right $resolvedCodexHome)) {
    throw 'settings 的 CodexHome 与卸载目标不匹配。'
}

$fixedPaths = [ordered]@{
    ConfigPath = Join-Path $resolvedCodexHome 'config.toml'
    CatalogPath = Join-Path $resolvedCodexHome 'openrouter-model-catalog.json'
    ActiveCachePath = Join-Path $resolvedCodexHome 'models_cache.json'
    OpenAICachePath = Join-Path $resolvedCodexHome 'models_cache.openai.json'
}
foreach ($entry in $fixedPaths.GetEnumerator()) {
    $actual = Get-UninstallerAbsolutePath `
        -Path (Get-UninstallerRequiredStringProperty `
            -InputObject $settings `
            -Name $entry.Key) `
        -Name "settings.$($entry.Key)"
    if (-not (Test-ToolkitPathEqual -Left $actual -Right $entry.Value)) {
        throw "settings 的 $($entry.Key) 超出固定路径。"
    }
    Assert-UninstallerNoReparsePoint `
        -Path $actual `
        -Name "settings.$($entry.Key)"
}

$recordedProfilePath = Get-UninstallerAbsolutePath `
    -Path (Get-UninstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'ProfilePath') `
    -Name 'settings.ProfilePath'
if ([IO.Path]::GetExtension($recordedProfilePath) -cne '.ps1') {
    throw 'settings.ProfilePath 必须指向 .ps1 文件。'
}
Assert-UninstallerNoReparsePoint `
    -Path $recordedProfilePath `
    -Name 'settings.ProfilePath'
if (-not (Test-ToolkitPathEqual `
        -Left $recordedProfilePath `
        -Right $requestedProfilePath)) {
    throw 'settings.ProfilePath 与本次卸载指定的 ProfilePath 不匹配。'
}
$profilePath = $requestedProfilePath

$openAIModel = Get-UninstallerRequiredStringProperty `
    -InputObject $settings `
    -Name 'OpenAIModel'
$openAIReasoning = Get-UninstallerRequiredStringProperty `
    -InputObject $settings `
    -Name 'OpenAIReasoningEffort'
$openRouterModel = Get-UninstallerRequiredStringProperty `
    -InputObject $settings `
    -Name 'OpenRouterModel'
$openRouterReasoning = Get-UninstallerRequiredStringProperty `
    -InputObject $settings `
    -Name 'OpenRouterReasoningEffort'
Assert-ToolkitModelId -Value $openAIModel -Name 'settings.OpenAIModel'
Assert-UninstallerReasoningEffort `
    -Value $openAIReasoning `
    -Name 'settings.OpenAIReasoningEffort'
Assert-ToolkitModelId -Value $openRouterModel -Name 'settings.OpenRouterModel'
Assert-UninstallerReasoningEffort `
    -Value $openRouterReasoning `
    -Name 'settings.OpenRouterReasoningEffort'
$catalogAgeProperty =
    $settings.PSObject.Properties['CatalogMaximumAgeHours']
if ($null -eq $catalogAgeProperty -or
    [int]$catalogAgeProperty.Value -lt 1 -or
    [int]$catalogAgeProperty.Value -gt 8760) {
    throw 'settings.CatalogMaximumAgeHours 超出范围。'
}

if (-not (Test-Path -LiteralPath $installedModuleManifest -PathType Leaf)) {
    throw "找不到已安装模块：$installedModuleManifest"
}
Assert-UninstallerNoReparsePoint `
    -Path $installedModuleManifest `
    -Name '已安装模块'
try {
    $installedModuleData = Import-PowerShellDataFile `
        -LiteralPath $installedModuleManifest `
        -ErrorAction Stop
}
catch {
    throw "已安装模块清单无法解析：$($_.Exception.Message)"
}
if ([string]$installedModuleData.RootModule -cne 'CodexOpenRouter.psm1' -or
    [string]$installedModuleData.GUID -cne
        'be74dba0-28ed-4ba3-adff-f0fc0d107b39') {
    throw '已安装模块清单身份无效。'
}
if (-not (Test-Path -LiteralPath $sourceModuleManifest -PathType Leaf)) {
    throw "找不到卸载器随附模块：$sourceModuleManifest"
}
Assert-UninstallerNoReparsePoint `
    -Path $sourceModuleManifest `
    -Name '卸载器随附模块'

if (-not $PSCmdlet.ShouldProcess(
        "$installRoot、$profilePath 和 $($fixedPaths.ConfigPath)",
        '卸载 Codex OpenRouter Toolkit'
    )) {
    return
}

    $timestamp = (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' +
        [Guid]::NewGuid().ToString('N')
    $uninstallRoot = Join-Path `
        $resolvedCodexHome `
        'codex-openrouter-toolkit-uninstalled'
    [void](New-Item -ItemType Directory -Path $uninstallRoot -Force)
    Assert-UninstallerNoReparsePoint `
        -Path $uninstallRoot `
        -Name '卸载恢复根目录'
    $uninstallBackup = Join-Path $uninstallRoot $timestamp
    [void](New-Item -ItemType Directory -Path $uninstallBackup)

    $recoveryFiles = @(
        [pscustomobject]@{
            Name = 'profile'
            Target = $profilePath
            BackupRelativePath = 'profile-before-uninstall.bak'
        },
        [pscustomobject]@{
            Name = 'config'
            Target = [string]$fixedPaths.ConfigPath
            BackupRelativePath = 'config-before-uninstall.bak'
        },
        [pscustomobject]@{
            Name = 'active-cache'
            Target = [string]$fixedPaths.ActiveCachePath
            BackupRelativePath = 'active-cache-before-uninstall.bak'
        },
        [pscustomobject]@{
            Name = 'openai-cache'
            Target = [string]$fixedPaths.OpenAICachePath
            BackupRelativePath = 'openai-cache-before-uninstall.bak'
        }
    )
    $recoveryEntries = [Collections.Generic.List[object]]::new()
    foreach ($file in $recoveryFiles) {
        $existed = Test-Path -LiteralPath $file.Target -PathType Leaf
        $sha256 = $null
        if ($existed) {
            $backupFile = Join-Path `
                $uninstallBackup `
                $file.BackupRelativePath
            Copy-ToolkitFileAtomic `
                -Source $file.Target `
                -Destination $backupFile
            $sha256 = (Get-FileHash `
                    -LiteralPath $backupFile `
                    -Algorithm SHA256).Hash
        }
        $recoveryEntries.Add([pscustomobject]@{
            Name = $file.Name
            Target = $file.Target
            Existed = $existed
            BackupRelativePath = $file.BackupRelativePath
            Sha256 = $sha256
        })
    }
    Write-ToolkitUtf8FileAtomic `
        -Path (Join-Path $uninstallBackup 'recovery.json') `
        -Content ([pscustomobject]@{
            Toolkit = 'codex-openrouter-toolkit'
            SchemaVersion = 1
            CreatedAt = [DateTimeOffset]::Now.ToString('o')
            CodexHome = $resolvedCodexHome
            ProfilePath = $profilePath
            Files = @($recoveryEntries)
        } | ConvertTo-Json -Depth 10)

    $installMoved = $false
    try {
        Import-Module -Name $sourceModuleManifest -Force
        if (-not $KeepCurrentProvider) {
            Switch-CodexDesktopProvider `
                -Provider openai `
                -NoRestart `
                -SettingsPath $settingsPath
        }

        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            $profileContent = [IO.File]::ReadAllText($profilePath)
            $newProfileContent = (Remove-ToolkitPowerShellCommentBlock `
                -Content $profileContent `
                -StartMarker '# >>> codex-openrouter-toolkit >>>' `
                -EndMarker '# <<< codex-openrouter-toolkit <<<' `
                -Context 'PowerShell Profile').TrimEnd()
            if (-not [string]::IsNullOrEmpty($newProfileContent)) {
                $newProfileContent += "`r`n"
            }
            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseInput(
                $newProfileContent,
                [ref]$tokens,
                [ref]$parseErrors
            )
            if ($parseErrors.Count -ne 0) {
                throw "卸载后的 PowerShell Profile 有 $($parseErrors.Count) 个语法错误。"
            }
            Write-ToolkitUtf8FileAtomic `
                -Path $profilePath `
                -Content $newProfileContent
        }

        Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
        Assert-UninstallerNoReparsePoint `
            -Path $installRoot `
            -Name '待移走安装目录'
        $movedInstall = Join-Path $uninstallBackup 'installed-files'
        if (Test-Path -LiteralPath $movedInstall) {
            throw "卸载恢复目录已被占用：$movedInstall"
        }
        Move-Item `
            -LiteralPath $installRoot `
            -Destination $movedInstall `
            -ErrorAction Stop
        $installMoved = $true
    }
    catch {
        $originalError = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue

        if ($installMoved) {
            try {
                $movedInstall = Join-Path $uninstallBackup 'installed-files'
                Move-Item `
                    -LiteralPath $movedInstall `
                    -Destination $installRoot `
                    -ErrorAction Stop
            }
            catch {
                $rollbackErrors.Add("安装目录：$($_.Exception.Message)")
            }
        }
        foreach ($entry in $recoveryEntries) {
            try {
                if ($entry.Existed) {
                    $backupFile = Join-Path `
                        $uninstallBackup `
                        $entry.BackupRelativePath
                    $actualHash = (Get-FileHash `
                            -LiteralPath $backupFile `
                            -Algorithm SHA256).Hash
                    if ($actualHash -cne [string]$entry.Sha256) {
                        throw "恢复文件哈希不匹配：$backupFile"
                    }
                    Write-ToolkitBytesAtomic `
                        -Path $entry.Target `
                        -Bytes ([IO.File]::ReadAllBytes($backupFile))
                }
                elseif (Test-Path -LiteralPath $entry.Target -PathType Leaf) {
                    Remove-Item `
                        -LiteralPath $entry.Target `
                        -Force `
                        -ErrorAction Stop
                }
            }
            catch {
                $rollbackErrors.Add(
                    "$($entry.Name)：$($_.Exception.Message)"
                )
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw [InvalidOperationException]::new(
                $originalError.Exception.Message +
                    "`r`n回滚未全部完成：" +
                    ($rollbackErrors -join '；'),
                $originalError.Exception
            )
        }
        throw $originalError
    }

    if ($RemoveApiKey) {
        Remove-UninstallerEnvironmentVariable `
            -Name 'OPENROUTER_API_KEY' `
            -Target ([EnvironmentVariableTarget]::User)
        Remove-UninstallerEnvironmentVariable `
            -Name 'OPENROUTER_API_KEY' `
            -Target ([EnvironmentVariableTarget]::Process)
        Remove-UninstallerEnvironmentVariable `
            -Name 'CODEX_OPENROUTER_PROCESS_KEY_OVERRIDE' `
            -Target ([EnvironmentVariableTarget]::Process)
    }

    [pscustomobject]@{
        Uninstalled = $true
        RestoredOpenAIProvider = -not $KeepCurrentProvider
        ApiKeyRemoved = [bool]$RemoveApiKey
        RecoveryPath = $uninstallBackup
    }
}
finally {
    Exit-ToolkitMutex -Mutex $mutex
}
