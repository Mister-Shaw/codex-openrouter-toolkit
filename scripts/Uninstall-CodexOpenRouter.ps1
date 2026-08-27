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
$commonHelperItem = Get-Item `
    -LiteralPath $commonHelperPath `
    -Force `
    -ErrorAction Stop
if (($commonHelperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $commonHelperItem.Length -gt 25MB) {
    throw "共同安全 helper 不是受支持的普通文件或超过 26214400 字节限制：$commonHelperPath"
}
. $commonHelperPath

function ConvertFrom-UninstallerUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $offset = if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF) {
        3
    }
    else { 0 }
    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString(
            $Bytes,
            $offset,
            $Bytes.Length - $offset
        )
    }
    catch {
        throw "$Label 不是有效的 UTF-8 文本：$($_.Exception.Message)"
    }
}

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

        [switch]$Recurse,

        [ValidateRange(1, 100000)]
        [int]$MaximumEntries = 4096
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
    $visitedEntries = 1
    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name 的现有路径包含重解析点：$($item.FullName)"
        }
        if ($item.PSIsContainer) {
            foreach ($childPath in [IO.Directory]::EnumerateFileSystemEntries(
                    $item.FullName
                )) {
                $child = Get-Item `
                    -LiteralPath $childPath `
                    -Force `
                    -ErrorAction Stop
                $visitedEntries++
                if ($visitedEntries -gt $MaximumEntries) {
                    throw "$Name 的项目数量超过 $MaximumEntries 项限制：$resolvedPath"
                }
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

function Test-UninstallerSnapshotEquivalent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [object]$Actual
    )

    if ([DateTime]$Expected.CreationTimeUtc -ne
            [DateTime]$Actual.CreationTimeUtc -or
        [DateTime]$Expected.LastWriteTimeUtc -ne
            [DateTime]$Actual.LastWriteTimeUtc -or
        -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
            [byte[]]$Expected.Bytes,
            [byte[]]$Actual.Bytes
        )) {
        return $false
    }
    if ($IsWindows) {
        return (Test-ToolkitAclPolicyEquivalent `
                -ExpectedAcl $Expected.Acl `
                -ActualAcl $Actual.Acl) -and
            (Test-ToolkitEffectiveFileAclEquivalent `
                -SourceAcl $Expected.Acl `
                -DestinationAcl $Actual.Acl)
    }
    return $true
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
    -Recurse `
    -MaximumEntries 1024
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "找不到已安装的工具包设置：$settingsPath"
}
Assert-UninstallerNoReparsePoint -Path $settingsPath -Name 'settings'

try {
    $settingsSnapshot = Get-ToolkitFileSnapshot `
        -Path $settingsPath `
        -MaximumBytes 5MB
    $settingsText = ConvertFrom-UninstallerUtf8Bytes `
        -Bytes $settingsSnapshot.Bytes `
        -Label 'settings'
    $settings = $settingsText | ConvertFrom-Json
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

if (-not $KeepCurrentProvider) {
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
}

if (-not (Test-Path -LiteralPath $installedModuleManifest -PathType Leaf)) {
    throw "找不到已安装模块：$installedModuleManifest"
}
Assert-UninstallerNoReparsePoint `
    -Path $installedModuleManifest `
    -Name '已安装模块'
if ((Get-Item `
        -LiteralPath $installedModuleManifest `
        -Force `
        -ErrorAction Stop).Length -gt 25MB) {
    throw "已安装模块清单超过 26214400 字节限制：$installedModuleManifest"
}
try {
    $installedModuleRead = Import-ToolkitPowerShellDataFileLocked `
        -Path $installedModuleManifest `
        -MaximumBytes 5MB
    $installedModuleData = $installedModuleRead.Data
}
catch {
    throw "已安装模块清单无法解析：$($_.Exception.Message)"
}
if ([string]$installedModuleData.RootModule -cne 'CodexOpenRouter.psm1' -or
    [string]$installedModuleData.GUID -cne
        'be74dba0-28ed-4ba3-adff-f0fc0d107b39') {
    throw '已安装模块清单身份无效。'
}
if (-not $KeepCurrentProvider) {
    if (-not (Test-Path -LiteralPath $sourceModuleManifest -PathType Leaf)) {
        throw "找不到卸载器随附模块：$sourceModuleManifest"
    }
    Assert-UninstallerNoReparsePoint `
        -Path $sourceModuleManifest `
        -Name '卸载器随附模块'
    Assert-UninstallerNoReparsePoint `
        -Path (Split-Path -Parent $sourceModuleManifest) `
        -Name '卸载器随附模块目录' `
        -Recurse `
        -MaximumEntries 1024
    $sourceModuleRoot = Split-Path -Parent $sourceModuleManifest
    $sourceModuleTotalBytes = 0L
    foreach ($sourceModulePath in @(Get-ToolkitSafeDirectoryTreePaths `
            -Root $sourceModuleRoot `
            -MaximumEntries 1024)) {
        $sourceModuleItem = Get-Item `
            -LiteralPath $sourceModulePath `
            -Force `
            -ErrorAction Stop
        if ($sourceModuleItem.PSIsContainer) { continue }
        $sourceModuleSnapshot = Get-ToolkitFileSnapshot `
            -Path $sourceModulePath `
            -MaximumBytes 25MB
        $sourceModuleTotalBytes += [long]$sourceModuleSnapshot.Length
        if ($sourceModuleTotalBytes -gt 64MB) {
            throw '卸载器随附模块目录文件总大小超过 67108864 字节限制。'
        }
    }
}

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
    Set-ToolkitPrivateDirectoryTree -Root $uninstallBackup
    Set-ToolkitPrivateDirectoryTree -Root $installRoot
    $installProduct = Get-ToolkitDirectoryStateSnapshot `
        -Root $installRoot `
        -MaximumFileBytes 25MB `
        -MaximumEntries 1024 `
        -MaximumTotalBytes 64MB
    Assert-ToolkitDirectorySnapshotContainsFileSnapshot `
        -DirectorySnapshot $installProduct `
        -RelativePath 'CodexOpenRouter\CodexOpenRouter.psd1' `
        -FileSnapshot $installedModuleRead.Snapshot `
        -Label '已安装模块清单'

    $recoveryFiles = @(
        [pscustomobject]@{
            Name = 'profile'
            Target = $profilePath
            BackupRelativePath = 'profile-before-uninstall.bak'
            MaximumBytes = 5MB
        },
        [pscustomobject]@{
            Name = 'config'
            Target = [string]$fixedPaths.ConfigPath
            BackupRelativePath = 'config-before-uninstall.bak'
            MaximumBytes = 5MB
        },
        [pscustomobject]@{
            Name = 'active-cache'
            Target = [string]$fixedPaths.ActiveCachePath
            BackupRelativePath = 'active-cache-before-uninstall.bak'
            MaximumBytes = 50MB
        },
        [pscustomobject]@{
            Name = 'openai-cache'
            Target = [string]$fixedPaths.OpenAICachePath
            BackupRelativePath = 'openai-cache-before-uninstall.bak'
            MaximumBytes = 50MB
        }
    )
    $recoveryEntries = [Collections.Generic.List[object]]::new()
    $originalRecoverySnapshots = @{}
    foreach ($file in $recoveryFiles) {
        $existed = Test-Path -LiteralPath $file.Target -PathType Leaf
        $sha256 = $null
        $aclSddl = $null
        $lastWriteTimeUtc = $null
        if ($existed) {
            $sourceSnapshot = Get-ToolkitFileSnapshot `
                -Path $file.Target `
                -MaximumBytes ([long]$file.MaximumBytes)
            $originalRecoverySnapshots[[IO.Path]::GetFullPath(
                    $file.Target
                )] = $sourceSnapshot
            $aclSddl = $sourceSnapshot.AclSddl
            $backupFile = Join-Path `
                $uninstallBackup `
                $file.BackupRelativePath
            Write-ToolkitBytesAtomic `
                -Path $backupFile `
                -Bytes $sourceSnapshot.Bytes `
                -TargetLastWriteTimeUtc $sourceSnapshot.LastWriteTimeUtc `
                -MaximumBytes ([long]$file.MaximumBytes) `
                -RequireNewTarget
            Assert-ToolkitPrivateFileSystemAcl -Path $backupFile
            $sha256 = $sourceSnapshot.Sha256.ToUpperInvariant()
            $lastWriteTimeUtc = $sourceSnapshot.LastWriteTimeUtc
        }
        else {
            $originalRecoverySnapshots[[IO.Path]::GetFullPath(
                    $file.Target
                )] = $null
        }
        $recoveryEntries.Add([pscustomobject]@{
            Name = $file.Name
            Target = $file.Target
            Existed = $existed
            BackupRelativePath = $file.BackupRelativePath
            Sha256 = $sha256
            AclSddl = $aclSddl
            LastWriteTimeUtc = $lastWriteTimeUtc
        })
    }
    Write-ToolkitUtf8FileAtomic `
        -Path (Join-Path $uninstallBackup 'recovery.json') `
        -Content ([pscustomobject]@{
            Toolkit = 'codex-openrouter-toolkit'
            SchemaVersion = 2
            CreatedAt = [DateTimeOffset]::Now.ToString('o')
            CodexHome = $resolvedCodexHome
            ProfilePath = $profilePath
            Files = @($recoveryEntries)
        } | ConvertTo-Json -Depth 10) `
        -MaximumBytes 5MB

    $installMoved = $false
    $movedInstallProduct = $null
    $installMoveState = [ordered]@{ Disposition = 'NoMove' }
    $transactionProducts = @{}
    try {
        Assert-ToolkitPrivateDirectoryTree -Root $installRoot
        if (-not $KeepCurrentProvider) {
            Import-Module -Name $sourceModuleManifest -Force
            foreach ($transactionPath in @(
                    [string]$fixedPaths.ConfigPath,
                    [string]$fixedPaths.ActiveCachePath,
                    [string]$fixedPaths.OpenAICachePath
                )) {
                $originalSnapshot =
                    $originalRecoverySnapshots[[IO.Path]::GetFullPath(
                            $transactionPath
                        )]
                if (($null -eq $originalSnapshot -and
                        (Test-Path -LiteralPath $transactionPath)) -or
                    ($null -ne $originalSnapshot -and
                        -not (Test-ToolkitFileMatchesSnapshot `
                            -Path $transactionPath `
                            -Snapshot $originalSnapshot))) {
                    throw "受管文件在卸载事务首次写入前被外部修改：$transactionPath"
                }
            }
            $switchResult = Switch-CodexDesktopProvider `
                -Provider openai `
                -NoRestart `
                -SettingsPath $settingsPath `
                -PassThruMutations
            $allowedSwitchPaths = @{}
            foreach ($transactionPath in @(
                    [string]$fixedPaths.ConfigPath,
                    [string]$fixedPaths.ActiveCachePath,
                    [string]$fixedPaths.OpenAICachePath
                )) {
                $allowedSwitchPaths[[IO.Path]::GetFullPath($transactionPath)] =
                    $true
            }
            foreach ($mutation in @($switchResult.Mutations)) {
                $transactionPath = [IO.Path]::GetFullPath(
                    [string]$mutation.Path
                )
                if (-not $allowedSwitchPaths.ContainsKey($transactionPath) -or
                    -not (Test-ToolkitPathEqual `
                        -Left ([string]$mutation.InitialState.Path) `
                        -Right $transactionPath) -or
                    -not (Test-ToolkitPathEqual `
                        -Left ([string]$mutation.PostState.Path) `
                        -Right $transactionPath)) {
                    throw "供应商切换返回了越界事务路径：$transactionPath"
                }
                $transactionProducts[$transactionPath] = $mutation
            }
            foreach ($mutation in @($switchResult.Mutations)) {
                $transactionPath = [IO.Path]::GetFullPath(
                    [string]$mutation.Path
                )
                $originalSnapshot =
                    $originalRecoverySnapshots[$transactionPath]
                $initialMatches = if ($null -eq $originalSnapshot) {
                    -not [bool]$mutation.InitialState.Existed
                }
                else {
                    [bool]$mutation.InitialState.Existed -and
                        $null -ne $mutation.InitialState.Snapshot -and
                        (Test-UninstallerSnapshotEquivalent `
                            -Expected $originalSnapshot `
                            -Actual $mutation.InitialState.Snapshot)
                }
                if (-not $initialMatches) {
                    throw "受管文件在卸载事务内部采样前被外部修改：$transactionPath"
                }
            }
        }

        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            $originalProfileSnapshot =
                $originalRecoverySnapshots[[IO.Path]::GetFullPath($profilePath)]
            if ($null -eq $originalProfileSnapshot -or
                -not (Test-ToolkitFileMatchesSnapshot `
                    -Path $profilePath `
                    -Snapshot $originalProfileSnapshot)) {
                throw 'Profile 在卸载事务首次写入前被外部修改。'
            }
            $profileContent = ConvertFrom-UninstallerUtf8Bytes `
                -Bytes $originalProfileSnapshot.Bytes `
                -Label 'Profile'
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
            $profileWriteParameters = @{
                Path = $profilePath
                Content = $newProfileContent
                ExpectedCurrentBytes = $originalProfileSnapshot.Bytes
                ExpectedCurrentLastWriteTimeUtc =
                    $originalProfileSnapshot.LastWriteTimeUtc
                RequireExistingTarget = $true
                PassThru = $true
                MaximumBytes = 5MB
            }
            if ($IsWindows) {
                $profileWriteParameters.ExpectedCurrentAcl =
                    $originalProfileSnapshot.Acl
            }
            $profileProduct = Write-ToolkitUtf8FileAtomic `
                @profileWriteParameters
            $transactionProducts[[IO.Path]::GetFullPath($profilePath)] =
                [pscustomobject]@{
                    Path = [IO.Path]::GetFullPath($profilePath)
                    InitialState = [pscustomobject]@{
                        Path = [IO.Path]::GetFullPath($profilePath)
                        Existed = $true
                        Snapshot = $originalProfileSnapshot
                    }
                    PostState = [pscustomobject]@{
                        Path = [IO.Path]::GetFullPath($profilePath)
                        Existed = $true
                        Snapshot = $profileProduct
                    }
                }
        }

        Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
        Assert-UninstallerNoReparsePoint `
            -Path $installRoot `
            -Name '待移走安装目录'
        $movedInstall = Join-Path $uninstallBackup 'installed-files'
        if (Test-Path -LiteralPath $movedInstall) {
            throw "卸载恢复目录已被占用：$movedInstall"
        }
        Move-ToolkitDirectoryIfSnapshotMatches `
            -Path $installRoot `
            -Destination $movedInstall `
            -Snapshot $installProduct `
            -State $installMoveState
        $installMoved = $true
        $movedInstallProduct = $installProduct
        if (Test-Path -LiteralPath $installRoot) {
            throw '安装目录在卸载移动后被外部重新创建。'
        }
    }
    catch {
        $originalError = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue

        if (-not $installMoved -and
            [string]$installMoveState['Disposition'] -notin @(
                'NoMove',
                'RevertedToSource'
            )) {
            $rollbackErrors.Add(
                "安装目录移动状态未完成验证，恢复候选已保留：$movedInstall"
            )
        }

        if ($installMoved) {
            try {
                $movedInstall = Join-Path $uninstallBackup 'installed-files'
                $rollbackInstallMoveState = [ordered]@{}
                Move-ToolkitDirectoryIfSnapshotMatches `
                    -Path $movedInstall `
                    -Destination $installRoot `
                    -Snapshot $movedInstallProduct `
                    -State $rollbackInstallMoveState
                Assert-ToolkitPrivateDirectoryTree -Root $installRoot
            }
            catch {
                $rollbackErrors.Add("安装目录：$($_.Exception.Message)")
            }
        }
        foreach ($entry in $recoveryEntries) {
            try {
                $transactionTarget = [IO.Path]::GetFullPath($entry.Target)
                if (-not $transactionProducts.ContainsKey($transactionTarget)) {
                    continue
                }
                $transactionProduct = $transactionProducts[$transactionTarget]
                $postState = $transactionProduct.PostState
                if ([bool]$postState.Existed) {
                    if ($null -eq $postState.Snapshot -or
                        -not (Test-ToolkitFileMatchesSnapshot `
                            -Path $entry.Target `
                            -Snapshot $postState.Snapshot)) {
                        throw "回滚 CAS 冲突，保留外部修改：$($entry.Target)"
                    }
                }
                elseif (Test-Path -LiteralPath $entry.Target) {
                    throw "回滚 CAS 冲突，保留外部新建：$($entry.Target)"
                }
                $initialState = $transactionProduct.InitialState
                if ([bool]$initialState.Existed) {
                    if ($null -eq $initialState.Snapshot) {
                        throw "事务初始快照缺失：$($entry.Target)"
                    }
                    $rollbackParameters = @{
                        Path = $entry.Target
                        Bytes = $initialState.Snapshot.Bytes
                        TargetLastWriteTimeUtc =
                            [DateTime]$initialState.Snapshot.LastWriteTimeUtc
                        MaximumBytes = if ($null -ne
                            $initialState.Snapshot.PSObject.Properties[
                                'MaximumBytes'
                            ]) {
                            [long]$initialState.Snapshot.MaximumBytes
                        }
                        else {
                            [Math]::Max(
                                1,
                                [long]$initialState.Snapshot.Bytes.LongLength
                            )
                        }
                    }
                    if ([bool]$postState.Existed) {
                        $rollbackParameters.ExpectedCurrentBytes =
                            $postState.Snapshot.Bytes
                        $rollbackParameters.ExpectedCurrentLastWriteTimeUtc =
                            $postState.Snapshot.LastWriteTimeUtc
                        $rollbackParameters.RequireExistingTarget = $true
                    }
                    else {
                        $rollbackParameters.RequireNewTarget = $true
                    }
                    if ($IsWindows) {
                        if ([bool]$postState.Existed) {
                            $rollbackParameters.ExpectedCurrentAcl =
                                $postState.Snapshot.Acl
                        }
                        $rollbackParameters.DesiredAcl =
                            $initialState.Snapshot.Acl
                    }
                    Write-ToolkitBytesAtomic @rollbackParameters
                    if ((Get-Item `
                            -LiteralPath $entry.Target `
                            -ErrorAction Stop).LastWriteTimeUtc -ne
                        [DateTime]$initialState.Snapshot.LastWriteTimeUtc) {
                        throw "回滚后的 LastWriteTimeUtc 校验失败：$($entry.Target)"
                    }
                }
                elseif ([bool]$postState.Existed) {
                    Remove-ToolkitFileIfSnapshotMatches `
                        -Path $entry.Target `
                        -Snapshot $postState.Snapshot
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
        Publish-ToolkitEnvironmentChange
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
