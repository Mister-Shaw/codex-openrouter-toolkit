[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexHome,

    [string]$ProfilePath,

    [string]$OpenAIModel,

    [string]$OpenAIReasoningEffort,

    [string]$OpenRouterModel = 'anthropic/claude-opus-5',

    [string]$OpenRouterReasoningEffort = 'high',

    [ValidateRange(1, 8760)]
    [int]$CatalogMaximumAgeHours = 24,

    [switch]$SkipCatalogRefresh,

    [switch]$SkipProfileReload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw '此工具包目前仅支持 Windows。'
}
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    throw "需要 PowerShell 7.4 或更高版本，当前版本为 $($PSVersionTable.PSVersion)。"
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleSource = Join-Path $repositoryRoot 'src\CodexOpenRouter'
$commonHelperPath = Join-Path `
    $moduleSource `
    'CodexOpenRouter.Common.ps1'
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

function Assert-InstallerReasoningEffort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Assert-ToolkitReasoningEffort -Value $Value -Name $Name
    $allowed = @(
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
        'ultra'
    )
    if ($allowed -cnotcontains $Value) {
        throw "$Name 的值不受支持：$Value"
    }
}

function Get-InstallerAbsolutePath {
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

function Assert-InstallerNoReparsePoint {
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
                if ($child.PSIsContainer) {
                    $pending.Push($child)
                }
            }
        }
    }
}

function Get-InstallerDirectoryInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 104857600)]
        [long]$MaximumFileBytes = 25MB,

        [ValidateRange(1, 100000)]
        [int]$MaximumEntries = 1024,

        [ValidateRange(1, 104857600)]
        [long]$MaximumTotalBytes = 64MB
    )

    $basePath = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Path)
    )
    Assert-InstallerNoReparsePoint `
        -Path $basePath `
        -Name '待备份安装目录' `
        -Recurse `
        -MaximumEntries $MaximumEntries
    [void](Get-ToolkitSafeDirectoryTreePaths `
        -Root $basePath `
        -MaximumEntries $MaximumEntries)
    $basePrefix = $basePath + [IO.Path]::DirectorySeparatorChar
    $inventory = [Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    foreach ($filePath in [IO.Directory]::EnumerateFiles(
            $basePath,
            '*',
            [IO.SearchOption]::AllDirectories
        )) {
        if ($inventory.Count -ge $MaximumEntries) {
            throw "安装目录文件数量超过 $MaximumEntries 项限制：$basePath"
        }
        $relativePath = $filePath.Substring($basePrefix.Length)
        $snapshot = Get-ToolkitFileSnapshot `
            -Path $filePath `
            -MaximumBytes $MaximumFileBytes
        $totalBytes += [long]$snapshot.Length
        if ($totalBytes -gt $MaximumTotalBytes) {
            throw "安装目录文件总大小超过 $MaximumTotalBytes 字节限制：$basePath"
        }
        $inventory.Add([pscustomobject]@{
            RelativePath = $relativePath
            Length = [long]$snapshot.Length
            Sha256 = $snapshot.Sha256.ToUpperInvariant()
        })
    }
    return @($inventory | Sort-Object RelativePath)
}

function Test-InstallerPathUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).
        TrimEnd([IO.Path]::DirectorySeparatorChar)
    return $resolvedPath.StartsWith(
        $resolvedRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-InstallerSnapshotEquivalent {
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

function Add-InstallerDirectoryProductEntry {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    Assert-ToolkitPrivateFileSystemAcl -Path $Path
    $Entries.Add([pscustomobject]@{
        Type = 'directory'
        RelativePath = $RelativePath
        Length = $null
        Sha256 = $null
        LastWriteTimeUtc = $null
        AclSddl = if ($IsWindows) {
            Get-ToolkitFileAclPolicySddl -Acl (Get-Acl `
                -LiteralPath $Path `
                -ErrorAction Stop)
        }
        else { $null }
    })
}

function Add-InstallerFileProductEntry {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    $Entries.Add([pscustomobject]@{
        Type = 'file'
        RelativePath = $RelativePath
        Length = [long]$Snapshot.Length
        Sha256 = [string]$Snapshot.Sha256
        LastWriteTimeUtc = ([DateTime]$Snapshot.LastWriteTimeUtc).ToString('o')
        AclSddl = [string]$Snapshot.AclSddl
    })
}

function New-InstallerDirectoryProductSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Entries
    )

    $ordered = @($Entries | Sort-Object RelativePath)
    if ($ordered.Count -gt 1024) {
        throw '新安装目录项目数量超过 1024 项限制。'
    }
    $totalBytes = [long](($ordered |
            Where-Object Type -ceq 'file' |
            Measure-Object -Property Length -Sum).Sum)
    if ($totalBytes -gt 64MB) {
        throw '新安装目录文件总大小超过 67108864 字节限制。'
    }
    return [pscustomobject]@{
        Entries = $ordered
        Token = ($ordered | ConvertTo-Json -Depth 5 -Compress)
        MaximumFileBytes = 25MB
        MaximumEntries = 1024
        MaximumTotalBytes = 64MB
    }
}

function Copy-InstallerDirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$ProductRelativeRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$ProductEntries
    )

    $resolvedSource = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Source)
    )
    $resolvedDestination = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Destination)
    )
    Assert-InstallerNoReparsePoint `
        -Path $resolvedSource `
        -Name '模块源目录' `
        -Recurse `
        -MaximumEntries 1024
    Assert-ToolkitPrivateDirectoryTree -Root $resolvedDestination
    $sourcePaths = @(Get-ToolkitSafeDirectoryTreePaths `
            -Root $resolvedSource `
            -MaximumEntries 1024 |
            Sort-Object `
                @{ Expression = { $_.Length } }, `
                @{ Expression = { $_ } })
    $sourcePrefix = $resolvedSource + [IO.Path]::DirectorySeparatorChar
    $totalSourceBytes = 0L

    foreach ($sourcePath in $sourcePaths) {
        if (Test-ToolkitPathEqual `
                -Left $sourcePath `
                -Right $resolvedSource) {
            continue
        }
        $sourceItem = Get-Item `
            -LiteralPath $sourcePath `
            -Force `
            -ErrorAction Stop
        if (($sourceItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "模块源目录含有不允许的重解析点：$sourcePath"
        }
        $relativePath = $sourcePath.Substring($sourcePrefix.Length)
        if ($sourceItem.PSIsContainer) {
            $targetDirectory = [IO.Path]::GetFullPath(
                (Join-Path $resolvedDestination $relativePath)
            )
            if (-not (Test-InstallerPathUnderRoot `
                    -Path $targetDirectory `
                    -Root $resolvedDestination) -or
                (Test-Path -LiteralPath $targetDirectory)) {
                throw "模块目标目录被并发占用或越界：$relativePath"
            }
            [void](New-Item `
                -ItemType Directory `
                -Path $targetDirectory `
                -ErrorAction Stop)
            Set-ToolkitPrivateFileSystemAcl -Path $targetDirectory
            Add-InstallerDirectoryProductEntry `
                -Entries $ProductEntries `
                -Path $targetDirectory `
                -RelativePath (Join-Path $ProductRelativeRoot $relativePath)
            continue
        }

        $targetFile = [IO.Path]::GetFullPath(
            (Join-Path $resolvedDestination $relativePath)
        )
        if (-not (Test-InstallerPathUnderRoot `
                -Path $targetFile `
                -Root $resolvedDestination) -or
            (Test-Path -LiteralPath $targetFile)) {
            throw "模块目标文件被并发占用或越界：$relativePath"
        }
        $sourceSnapshot = Get-ToolkitFileSnapshot `
            -Path $sourcePath `
            -MaximumBytes 25MB
        $totalSourceBytes += [long]$sourceSnapshot.Length
        if ($totalSourceBytes -gt 64MB) {
            throw '模块源目录文件总大小超过 67108864 字节限制。'
        }
        $productSnapshot = Write-ToolkitBytesAtomic `
            -Path $targetFile `
            -Bytes $sourceSnapshot.Bytes `
            -TargetLastWriteTimeUtc $sourceSnapshot.LastWriteTimeUtc `
            -MaximumBytes 25MB `
            -RequireNewTarget `
            -PassThru
        Assert-ToolkitPrivateFileSystemAcl -Path $targetFile
        Add-InstallerFileProductEntry `
            -Entries $ProductEntries `
            -RelativePath (Join-Path $ProductRelativeRoot $relativePath) `
            -Snapshot $productSnapshot
    }
}

function ConvertFrom-InstallerUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [string]$Name
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
        throw "$Name 不是有效的 UTF-8 文本：$($_.Exception.Message)"
    }
}

function Get-InstallerRequiredStringProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or
        [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "前代 settings 缺少有效字段：$Name"
    }
    return [string]$property.Value
}

function Read-InstallerPreviousSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedInstallRoot
    )

    try {
        $settingsSnapshot = Get-ToolkitFileSnapshot `
            -Path $SettingsPath `
            -MaximumBytes 5MB
        $settingsText = ConvertFrom-InstallerUtf8Bytes `
            -Bytes $settingsSnapshot.Bytes `
            -Name '前代 settings'
        $settings = $settingsText | ConvertFrom-Json
    }
    catch {
        throw "前代 settings 无法解析：$($_.Exception.Message)"
    }
    $schemaProperty = $settings.PSObject.Properties['SchemaVersion']
    if ($null -eq $schemaProperty -or
        [int]$schemaProperty.Value -notin @(1, 2)) {
        throw '前代 settings 的 SchemaVersion 不受支持。'
    }
    if ([int]$schemaProperty.Value -eq 2) {
        $toolkit = Get-InstallerRequiredStringProperty `
            -InputObject $settings `
            -Name 'Toolkit'
        if ($toolkit -cne 'codex-openrouter-toolkit') {
            throw '前代 settings 的 Toolkit 标识不匹配。'
        }
        $recordedInstallRoot = Get-InstallerAbsolutePath `
            -Path (Get-InstallerRequiredStringProperty `
                -InputObject $settings `
                -Name 'InstallRoot') `
            -Name '前代 InstallRoot'
        if (-not (Test-ToolkitPathEqual `
                -Left $recordedInstallRoot `
                -Right $ExpectedInstallRoot)) {
            throw '前代 settings 的 InstallRoot 与当前安装目录不匹配。'
        }
    }

    $recordedCodexHome = Get-InstallerAbsolutePath `
        -Path (Get-InstallerRequiredStringProperty `
            -InputObject $settings `
            -Name 'CodexHome') `
        -Name '前代 CodexHome'
    if (-not (Test-ToolkitPathEqual `
            -Left $recordedCodexHome `
            -Right $ExpectedCodexHome)) {
        throw '前代 settings 的 CodexHome 与当前目标不匹配。'
    }

    $expectedPaths = [ordered]@{
        ConfigPath = Join-Path $ExpectedCodexHome 'config.toml'
        CatalogPath = Join-Path $ExpectedCodexHome 'openrouter-model-catalog.json'
        ActiveCachePath = Join-Path $ExpectedCodexHome 'models_cache.json'
        OpenAICachePath = Join-Path $ExpectedCodexHome 'models_cache.openai.json'
    }
    foreach ($entry in $expectedPaths.GetEnumerator()) {
        $actual = Get-InstallerAbsolutePath `
            -Path (Get-InstallerRequiredStringProperty `
                -InputObject $settings `
                -Name $entry.Key) `
            -Name "前代 $($entry.Key)"
        if (-not (Test-ToolkitPathEqual -Left $actual -Right $entry.Value)) {
            throw "前代 settings 的 $($entry.Key) 超出固定路径。"
        }
    }

    $recordedProfile = Get-InstallerAbsolutePath `
        -Path (Get-InstallerRequiredStringProperty `
            -InputObject $settings `
            -Name 'ProfilePath') `
        -Name '前代 ProfilePath'
    if ([IO.Path]::GetExtension($recordedProfile) -cne '.ps1') {
        throw '前代 ProfilePath 必须指向 .ps1 文件。'
    }
    Assert-InstallerNoReparsePoint `
        -Path $recordedProfile `
        -Name '前代 ProfilePath'

    $openAIModel = Get-InstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'OpenAIModel'
    $openAIReasoning = Get-InstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'OpenAIReasoningEffort'
    $openRouterModel = Get-InstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'OpenRouterModel'
    $openRouterReasoning = Get-InstallerRequiredStringProperty `
        -InputObject $settings `
        -Name 'OpenRouterReasoningEffort'
    Assert-ToolkitModelId -Value $openAIModel -Name '前代 OpenAIModel'
    Assert-InstallerReasoningEffort `
        -Value $openAIReasoning `
        -Name '前代 OpenAIReasoningEffort'
    Assert-ToolkitModelId -Value $openRouterModel -Name '前代 OpenRouterModel'
    Assert-InstallerReasoningEffort `
        -Value $openRouterReasoning `
        -Name '前代 OpenRouterReasoningEffort'

    $ageProperty = $settings.PSObject.Properties['CatalogMaximumAgeHours']
    if ($null -eq $ageProperty -or
        [int]$ageProperty.Value -lt 1 -or
        [int]$ageProperty.Value -gt 8760) {
        throw '前代 settings 的 CatalogMaximumAgeHours 超出范围。'
    }
    return $settings
}

$openAIModelSpecified = $PSBoundParameters.ContainsKey('OpenAIModel')
$openAIReasoningSpecified =
    $PSBoundParameters.ContainsKey('OpenAIReasoningEffort')
$openRouterModelSpecified = $PSBoundParameters.ContainsKey('OpenRouterModel')
$openRouterReasoningSpecified =
    $PSBoundParameters.ContainsKey('OpenRouterReasoningEffort')
$catalogMaximumAgeSpecified =
    $PSBoundParameters.ContainsKey('CatalogMaximumAgeHours')
$codexHomeSpecified = $PSBoundParameters.ContainsKey('CodexHome')
$profilePathSpecified = $PSBoundParameters.ContainsKey('ProfilePath')

if ($codexHomeSpecified -and [string]::IsNullOrWhiteSpace($CodexHome)) {
    throw '显式传入的 CodexHome 不能为空。'
}
if ($profilePathSpecified -and [string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw '显式传入的 ProfilePath 不能为空。'
}
if ($openAIModelSpecified -and [string]::IsNullOrWhiteSpace($OpenAIModel)) {
    throw '显式传入的 OpenAIModel 不能为空。'
}
if ($openAIReasoningSpecified -and
    [string]::IsNullOrWhiteSpace($OpenAIReasoningEffort)) {
    throw '显式传入的 OpenAIReasoningEffort 不能为空。'
}

Assert-ToolkitModelId -Value $OpenRouterModel -Name 'OpenRouterModel'
Assert-InstallerReasoningEffort `
    -Value $OpenRouterReasoningEffort `
    -Name 'OpenRouterReasoningEffort'

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}
$resolvedCodexHome = Get-InstallerAbsolutePath `
    -Path $CodexHome `
    -Name 'CodexHome'
$volumeRoot = [IO.Path]::GetPathRoot($resolvedCodexHome).
    TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($resolvedCodexHome.TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq
    $volumeRoot) {
    throw 'CodexHome 不能是卷根目录。'
}
if (Test-Path -LiteralPath $resolvedCodexHome -PathType Leaf) {
    throw 'CodexHome 已存在为普通文件。'
}
Assert-InstallerNoReparsePoint -Path $resolvedCodexHome -Name 'CodexHome'

$installRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit'
$moduleTarget = Join-Path $installRoot 'CodexOpenRouter'
$settingsPath = Join-Path $installRoot 'settings.json'
$backupRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit-backups'
$configPath = Join-Path $resolvedCodexHome 'config.toml'
$catalogPath = Join-Path $resolvedCodexHome 'openrouter-model-catalog.json'
$activeCachePath = Join-Path $resolvedCodexHome 'models_cache.json'
$openAICachePath = Join-Path $resolvedCodexHome 'models_cache.openai.json'

if (-not (Test-Path -LiteralPath $moduleSource -PathType Container)) {
    throw "找不到模块源文件：$moduleSource"
}
Assert-InstallerNoReparsePoint `
    -Path $moduleSource `
    -Name '模块源目录' `
    -Recurse `
    -MaximumEntries 1024

$mutex = Enter-ToolkitMutex -ScopePath $resolvedCodexHome
try {
$installExisted = Test-Path -LiteralPath $installRoot -PathType Container
if ((Test-Path -LiteralPath $installRoot) -and -not $installExisted) {
    throw '安装目标已被普通文件占用。'
}
if ($installExisted) {
    Assert-InstallerNoReparsePoint `
        -Path $installRoot `
        -Name '前代安装目录' `
        -Recurse `
        -MaximumEntries 1024
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw "前代安装缺少 settings：$settingsPath"
    }
}

$previousSettings = if ($installExisted) {
    Read-InstallerPreviousSettings `
        -SettingsPath $settingsPath `
        -ExpectedCodexHome $resolvedCodexHome `
        -ExpectedInstallRoot $installRoot
}
else {
    $null
}
if ($installExisted) {
    $previousModuleManifestPath = Join-Path `
        $installRoot `
        'CodexOpenRouter\CodexOpenRouter.psd1'
    $previousModulePath = Join-Path `
        $installRoot `
        'CodexOpenRouter\CodexOpenRouter.psm1'
    foreach ($requiredModulePath in @(
            $previousModuleManifestPath,
            $previousModulePath
        )) {
        if (-not (Test-Path -LiteralPath $requiredModulePath -PathType Leaf)) {
            throw "前代安装缺少模块文件：$requiredModulePath"
        }
        Assert-InstallerNoReparsePoint `
            -Path $requiredModulePath `
            -Name '前代模块文件'
        if ((Get-Item `
                -LiteralPath $requiredModulePath `
                -Force `
                -ErrorAction Stop).Length -gt 25MB) {
            throw "前代模块文件超过 26214400 字节限制：$requiredModulePath"
        }
    }
    try {
        $previousModuleManifestRead = Import-ToolkitPowerShellDataFileLocked `
            -Path $previousModuleManifestPath `
            -MaximumBytes 5MB
        $previousModuleManifest = $previousModuleManifestRead.Data
    }
    catch {
        throw "前代模块清单无法解析：$($_.Exception.Message)"
    }
    if ([string]$previousModuleManifest.RootModule -cne 'CodexOpenRouter.psm1' -or
        [string]$previousModuleManifest.GUID -cne
            'be74dba0-28ed-4ba3-adff-f0fc0d107b39') {
        throw '前代模块清单身份无效。'
    }
}
$previousInstallInventory = if ($installExisted) {
    @(Get-InstallerDirectoryInventory -Path $installRoot)
}
else {
    @()
}
if ($installExisted -and $previousInstallInventory.Count -eq 0) {
    throw '前代安装目录为空，已拒绝升级。'
}

if ($previousSettings -and -not $openRouterModelSpecified) {
    $OpenRouterModel = [string]$previousSettings.OpenRouterModel
}
if ($previousSettings -and -not $openRouterReasoningSpecified) {
    $OpenRouterReasoningEffort =
        [string]$previousSettings.OpenRouterReasoningEffort
}
if ($previousSettings -and -not $catalogMaximumAgeSpecified) {
    $CatalogMaximumAgeHours = [int]$previousSettings.CatalogMaximumAgeHours
}
Assert-ToolkitModelId -Value $OpenRouterModel -Name 'OpenRouterModel'
Assert-InstallerReasoningEffort `
    -Value $OpenRouterReasoningEffort `
    -Name 'OpenRouterReasoningEffort'

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = [string]$PROFILE.CurrentUserCurrentHost
}
$resolvedProfilePath = Get-InstallerAbsolutePath `
    -Path $ProfilePath `
    -Name 'ProfilePath'
if ([IO.Path]::GetExtension($resolvedProfilePath) -cne '.ps1') {
    throw 'ProfilePath 必须指向 .ps1 文件。'
}
Assert-InstallerNoReparsePoint -Path $resolvedProfilePath -Name 'ProfilePath'
if ($previousSettings -and
    -not (Test-ToolkitPathEqual `
        -Left ([string]$previousSettings.ProfilePath) `
        -Right $resolvedProfilePath)) {
    throw '升级时不能更换受管 ProfilePath；请先卸载前代版本。'
}
if (Test-InstallerPathUnderRoot `
        -Path $resolvedProfilePath `
        -Root $installRoot) {
    throw 'ProfilePath 不能位于工具包安装目录内。'
}
if (Test-InstallerPathUnderRoot `
        -Path $resolvedProfilePath `
        -Root $backupRoot) {
    throw 'ProfilePath 不能位于工具包备份目录内。'
}

$managedTargets = @(
    $resolvedProfilePath,
    $configPath,
    $catalogPath,
    $activeCachePath,
    $openAICachePath
)
if (@($managedTargets | Sort-Object -Unique).Count -ne $managedTargets.Count) {
    throw '受管文件路径发生冲突。'
}

if ($previousSettings -and -not $openAIModelSpecified) {
    $OpenAIModel = [string]$previousSettings.OpenAIModel
}
if ($previousSettings -and -not $openAIReasoningSpecified) {
    $OpenAIReasoningEffort = [string]$previousSettings.OpenAIReasoningEffort
}

$maximumConfigBytes = 5MB
$configInitialSnapshot = $null
if (Test-Path -LiteralPath $configPath) {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'config 路径必须是普通文件。'
    }
    $configInitialSnapshot = Get-ToolkitFileSnapshot `
        -Path $configPath `
        -MaximumBytes $maximumConfigBytes
}
$configContent = if ($null -ne $configInitialSnapshot) {
    ConvertFrom-InstallerUtf8Bytes `
        -Bytes $configInitialSnapshot.Bytes `
        -Name 'config'
}
else { '' }
$currentProvider = Get-ToolkitTopLevelTomlValue `
    -Content $configContent `
    -Key 'model_provider'
$currentModel = Get-ToolkitTopLevelTomlValue `
    -Content $configContent `
    -Key 'model'
$currentReasoning = Get-ToolkitTopLevelTomlValue `
    -Content $configContent `
    -Key 'model_reasoning_effort'

if ([string]::IsNullOrWhiteSpace($OpenAIModel)) {
    $OpenAIModel = if ($currentProvider -cne 'openrouter' -and
        -not [string]::IsNullOrWhiteSpace($currentModel)) {
        $currentModel
    }
    else {
        'gpt-5.6-sol'
    }
}
if ([string]::IsNullOrWhiteSpace($OpenAIReasoningEffort)) {
    $OpenAIReasoningEffort = if ($currentProvider -cne 'openrouter' -and
        -not [string]::IsNullOrWhiteSpace($currentReasoning)) {
        $currentReasoning
    }
    else {
        'xhigh'
    }
}
Assert-ToolkitModelId -Value $OpenAIModel -Name 'OpenAIModel'
Assert-InstallerReasoningEffort `
    -Value $OpenAIReasoningEffort `
    -Name 'OpenAIReasoningEffort'

if (-not $PSCmdlet.ShouldProcess(
        "$resolvedProfilePath 和 $resolvedCodexHome",
        '安装 Codex OpenRouter Toolkit'
    )) {
    return
}

    [void](New-Item -ItemType Directory -Path $resolvedCodexHome -Force)
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    Assert-InstallerNoReparsePoint -Path $backupRoot -Name '备份根目录'
    $backupName = (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' +
        [Guid]::NewGuid().ToString('N')
    $backupPath = Join-Path $backupRoot $backupName
    [void](New-Item -ItemType Directory -Path $backupPath)
    Set-ToolkitPrivateDirectoryTree -Root $backupPath
    $originalInstallProduct = $null
    if ($installExisted) {
        Set-ToolkitPrivateDirectoryTree -Root $installRoot
        $originalInstallProduct = Get-ToolkitDirectoryStateSnapshot `
            -Root $installRoot `
            -MaximumFileBytes 25MB `
            -MaximumEntries 1024 `
            -MaximumTotalBytes 64MB
        Assert-ToolkitDirectorySnapshotContainsFileSnapshot `
            -DirectorySnapshot $originalInstallProduct `
            -RelativePath 'CodexOpenRouter\CodexOpenRouter.psd1' `
            -FileSnapshot $previousModuleManifestRead.Snapshot `
            -Label '前代模块清单'
        $previousInstallInventory =
            @(Get-InstallerDirectoryInventory `
                -Path $installRoot `
                -MaximumFileBytes 25MB)
    }

    $managedFiles = @(
        [pscustomobject]@{
            Name = 'profile'
            Target = $resolvedProfilePath
            BackupRelativePath = 'profile.bak'
            MaximumBytes = 5MB
        },
        [pscustomobject]@{
            Name = 'config'
            Target = $configPath
            BackupRelativePath = 'config.bak'
            MaximumBytes = 5MB
        },
        [pscustomobject]@{
            Name = 'catalog'
            Target = $catalogPath
            BackupRelativePath = 'catalog.bak'
            MaximumBytes = 50MB
        },
        [pscustomobject]@{
            Name = 'active-cache'
            Target = $activeCachePath
            BackupRelativePath = 'active-cache.bak'
            MaximumBytes = 50MB
        },
        [pscustomobject]@{
            Name = 'openai-cache'
            Target = $openAICachePath
            BackupRelativePath = 'openai-cache.bak'
            MaximumBytes = 50MB
        }
    )
    $manifestFiles = [Collections.Generic.List[object]]::new()
    $originalManagedSnapshots = @{}
    foreach ($managedFile in $managedFiles) {
        Assert-InstallerNoReparsePoint `
            -Path $managedFile.Target `
            -Name "受管文件 $($managedFile.Name)"
        $sourceSnapshot = $null
        if ($managedFile.Name -ceq 'config') {
            $sourceSnapshot = $configInitialSnapshot
            $exists = $null -ne $sourceSnapshot
            if (($exists -and -not (Test-ToolkitFileMatchesSnapshot `
                        -Path $managedFile.Target `
                        -Snapshot $sourceSnapshot)) -or
                (-not $exists -and
                    (Test-Path -LiteralPath $managedFile.Target))) {
                throw 'config 在冻结快照后被外部修改。'
            }
        }
        else {
            $exists = Test-Path `
                -LiteralPath $managedFile.Target `
                -PathType Leaf
            if ((Test-Path -LiteralPath $managedFile.Target) -and -not $exists) {
                throw "受管文件路径已被目录占用：$($managedFile.Target)"
            }
        }
        $sha256 = $null
        $aclSddl = $null
        $lastWriteTimeUtc = $null
        if ($exists) {
            if ($null -eq $sourceSnapshot) {
                $sourceSnapshot = Get-ToolkitFileSnapshot `
                    -Path $managedFile.Target `
                    -MaximumBytes ([long]$managedFile.MaximumBytes)
            }
            $originalManagedSnapshots[[IO.Path]::GetFullPath(
                    $managedFile.Target
                )] = $sourceSnapshot
            $aclSddl = $sourceSnapshot.AclSddl
            $backupFile = Join-Path $backupPath $managedFile.BackupRelativePath
            Write-ToolkitBytesAtomic `
                -Path $backupFile `
                -Bytes $sourceSnapshot.Bytes `
                -TargetLastWriteTimeUtc $sourceSnapshot.LastWriteTimeUtc `
                -MaximumBytes ([long]$managedFile.MaximumBytes) `
                -RequireNewTarget
            Assert-ToolkitPrivateFileSystemAcl -Path $backupFile
            $sha256 = $sourceSnapshot.Sha256.ToUpperInvariant()
            $lastWriteTimeUtc = $sourceSnapshot.LastWriteTimeUtc
        }
        else {
            $originalManagedSnapshots[[IO.Path]::GetFullPath(
                    $managedFile.Target
                )] = $null
        }
        $manifestFiles.Add([pscustomobject]@{
            Name = $managedFile.Name
            Target = [IO.Path]::GetFullPath($managedFile.Target)
            Existed = $exists
            BackupRelativePath = $managedFile.BackupRelativePath
            Sha256 = $sha256
            AclSddl = $aclSddl
            LastWriteTimeUtc = $lastWriteTimeUtc
        })
    }

    $manifest = [pscustomobject]@{
        Toolkit = 'codex-openrouter-toolkit'
        SchemaVersion = 3
        CreatedAt = [DateTimeOffset]::Now.ToString('o')
        CodexHome = $resolvedCodexHome
        ProfilePath = $resolvedProfilePath
        InstallRoot = $installRoot
        InstallExisted = [bool]$installExisted
        PreviousInstallFiles = @($previousInstallInventory)
        Files = @($manifestFiles)
    }
    Write-ToolkitUtf8FileAtomic `
        -Path (Join-Path $backupPath 'manifest.json') `
        -Content ($manifest | ConvertTo-Json -Depth 10) `
        -MaximumBytes 5MB

    $previousInstall = Join-Path $backupPath 'previous-install'
    $stagedInstall = Join-Path $backupPath 'new-install'
    $stagedModuleTarget = Join-Path $stagedInstall 'CodexOpenRouter'
    $stagedSettingsPath = Join-Path $stagedInstall 'settings.json'
    $previousInstallReady = $false
    $stagedInstallCreated = $false
    $activeInstallCreated = $false
    $previousInstallProduct = $null
    $activeInstallProduct = $null
    $previousInstallMoveState = [ordered]@{ Disposition = 'NoMove' }
    $activeInstallMoveState = [ordered]@{ Disposition = 'NoMove' }
    $transactionProducts = @{}
    try {
        if ($installExisted) {
            Move-ToolkitDirectoryIfSnapshotMatches `
                -Path $installRoot `
                -Destination $previousInstall `
                -Snapshot $originalInstallProduct `
                -State $previousInstallMoveState
            $previousInstallReady = $true
            if (Test-Path -LiteralPath $installRoot) {
                throw '安装目录在备份移动后被外部重新创建。'
            }
            Assert-ToolkitPrivateDirectoryTree -Root $previousInstall
            $previousInstallProduct = $originalInstallProduct
            $movedPreviousInventory =
                @(Get-InstallerDirectoryInventory -Path $previousInstall)
            if (($movedPreviousInventory | ConvertTo-Json -Depth 5 -Compress) -cne
                ($previousInstallInventory | ConvertTo-Json -Depth 5 -Compress)) {
                throw 'previous-install 与冻结清单不一致。'
            }
        }
        [void](New-Item -ItemType Directory -Path $stagedInstall)
        Set-ToolkitPrivateDirectoryTree -Root $stagedInstall
        $stagedInstallCreated = $true
        $stagedProductEntries = [Collections.Generic.List[object]]::new()
        Add-InstallerDirectoryProductEntry `
            -Entries $stagedProductEntries `
            -Path $stagedInstall `
            -RelativePath '.'
        [void](New-Item -ItemType Directory -Path $stagedModuleTarget)
        Set-ToolkitPrivateFileSystemAcl -Path $stagedModuleTarget
        Add-InstallerDirectoryProductEntry `
            -Entries $stagedProductEntries `
            -Path $stagedModuleTarget `
            -RelativePath 'CodexOpenRouter'
        Copy-InstallerDirectoryContents `
            -Source $moduleSource `
            -Destination $stagedModuleTarget `
            -ProductRelativeRoot 'CodexOpenRouter' `
            -ProductEntries $stagedProductEntries

        $settings = [pscustomobject]@{
            Toolkit = 'codex-openrouter-toolkit'
            SchemaVersion = 2
            InstalledVersion = '0.1.1'
            InstalledAt = [DateTimeOffset]::Now.ToString('o')
            CodexHome = $resolvedCodexHome
            InstallRoot = $installRoot
            ProfilePath = $resolvedProfilePath
            ConfigPath = $configPath
            CatalogPath = $catalogPath
            ActiveCachePath = $activeCachePath
            OpenAICachePath = $openAICachePath
            OpenAIModel = $OpenAIModel
            OpenAIReasoningEffort = $OpenAIReasoningEffort
            OpenRouterModel = $OpenRouterModel
            OpenRouterReasoningEffort = $OpenRouterReasoningEffort
            CatalogMaximumAgeHours = $CatalogMaximumAgeHours
            InstallBackupPath = $backupPath
        }
        $settingsProduct = Write-ToolkitUtf8FileAtomic `
            -Path $stagedSettingsPath `
            -Content ($settings | ConvertTo-Json -Depth 10) `
            -MaximumBytes 5MB `
            -PassThru
        Add-InstallerFileProductEntry `
            -Entries $stagedProductEntries `
            -RelativePath 'settings.json' `
            -Snapshot $settingsProduct
        $activeInstallProduct = New-InstallerDirectoryProductSnapshot `
            -Entries $stagedProductEntries
        if (-not (Test-ToolkitDirectoryMatchesSnapshot `
                -Root $stagedInstall `
                -Snapshot $activeInstallProduct)) {
            throw "新安装 staging 出现清单外变更，已保留：$stagedInstall"
        }
        Move-ToolkitDirectoryIfSnapshotMatches `
            -Path $stagedInstall `
            -Destination $installRoot `
            -Snapshot $activeInstallProduct `
            -State $activeInstallMoveState
        $activeInstallCreated = $true
        if (Test-Path -LiteralPath $stagedInstall) {
            throw "新安装发布后 staging 路径被外部重新创建：$stagedInstall"
        }

        $moduleManifest = Join-Path $moduleTarget 'CodexOpenRouter.psd1'
        Assert-ToolkitPrivateDirectoryTree -Root $installRoot
        Import-Module -Name $moduleManifest -Force
        $originalConfigSnapshot =
            $originalManagedSnapshots[[IO.Path]::GetFullPath($configPath)]
        if (($null -eq $originalConfigSnapshot -and
                (Test-Path -LiteralPath $configPath)) -or
            ($null -ne $originalConfigSnapshot -and
                -not (Test-ToolkitFileMatchesSnapshot `
                    -Path $configPath `
                    -Snapshot $originalConfigSnapshot))) {
            throw 'config 在安装事务首次写入前被外部修改。'
        }
        $initializeResult = Initialize-CodexOpenRouterConfig `
            -ConfigPath $configPath `
            -PassThruMutation
        if ($null -eq $initializeResult.Mutation -or
            -not (Test-ToolkitPathEqual `
                -Left ([string]$initializeResult.Mutation.Path) `
                -Right $configPath) -or
            -not (Test-ToolkitPathEqual `
                -Left ([string]$initializeResult.Mutation.InitialState.Path) `
                -Right $configPath) -or
            -not (Test-ToolkitPathEqual `
                -Left ([string]$initializeResult.Mutation.PostState.Path) `
                -Right $configPath) -or
            -not [bool]$initializeResult.Mutation.PostState.Existed -or
            $null -eq $initializeResult.Mutation.PostState.Snapshot) {
            throw '配置初始化没有返回可验证的事务产物。'
        }
        $transactionProducts[[IO.Path]::GetFullPath($configPath)] =
            $initializeResult.Mutation
        $initializeInitialMatches = if ($null -eq $originalConfigSnapshot) {
            -not [bool]$initializeResult.Mutation.InitialState.Existed
        }
        else {
            [bool]$initializeResult.Mutation.InitialState.Existed -and
                $null -ne $initializeResult.Mutation.InitialState.Snapshot -and
                (Test-InstallerSnapshotEquivalent `
                    -Expected $originalConfigSnapshot `
                    -Actual $initializeResult.Mutation.InitialState.Snapshot)
        }
        if (-not $initializeInitialMatches) {
            throw 'config 在配置初始化内部采样前被外部修改。'
        }

        $originalProfileSnapshot =
            $originalManagedSnapshots[[IO.Path]::GetFullPath(
                    $resolvedProfilePath
                )]
        if (($null -eq $originalProfileSnapshot -and
                (Test-Path -LiteralPath $resolvedProfilePath)) -or
            ($null -ne $originalProfileSnapshot -and
                -not (Test-ToolkitFileMatchesSnapshot `
                    -Path $resolvedProfilePath `
                    -Snapshot $originalProfileSnapshot))) {
            throw 'Profile 在安装事务首次写入前被外部修改。'
        }
        $profileContent = if ($null -ne $originalProfileSnapshot) {
            ConvertFrom-InstallerUtf8Bytes `
                -Bytes $originalProfileSnapshot.Bytes `
                -Name 'Profile'
        }
        else {
            ''
        }
        $profileContent = (Remove-ToolkitPowerShellCommentBlock `
            -Content $profileContent `
            -StartMarker '# >>> codex-openrouter-toolkit >>>' `
            -EndMarker '# <<< codex-openrouter-toolkit <<<' `
            -Context 'PowerShell Profile').TrimEnd()
        $profileContent = (Remove-ToolkitPowerShellCommentBlock `
            -Content $profileContent `
            -StartMarker '# >>> Codex desktop provider shortcuts >>>' `
            -EndMarker '# <<< Codex desktop provider shortcuts <<<' `
            -Context 'PowerShell Profile').TrimEnd()
        $escapedManifestPath = $moduleManifest.Replace("'", "''")
        $profileBlock = @"
# >>> codex-openrouter-toolkit >>>
Import-Module '$escapedManifestPath' -Force
# <<< codex-openrouter-toolkit <<<
"@
        $newProfileContent = if ([string]::IsNullOrWhiteSpace($profileContent)) {
            $profileBlock + "`r`n"
        }
        else {
            $profileContent + "`r`n`r`n" + $profileBlock + "`r`n"
        }
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseInput(
            $newProfileContent,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -ne 0) {
            throw "安装后的 PowerShell Profile 有 $($parseErrors.Count) 个语法错误。"
        }
        $profileWriteParameters = @{
            Path = $resolvedProfilePath
            Content = $newProfileContent
            PassThru = $true
            MaximumBytes = 5MB
        }
        if ($null -ne $originalProfileSnapshot) {
            $profileWriteParameters.ExpectedCurrentBytes =
                $originalProfileSnapshot.Bytes
            $profileWriteParameters.ExpectedCurrentLastWriteTimeUtc =
                $originalProfileSnapshot.LastWriteTimeUtc
            if ($IsWindows) {
                $profileWriteParameters.ExpectedCurrentAcl =
                    $originalProfileSnapshot.Acl
            }
            $profileWriteParameters.RequireExistingTarget = $true
        }
        else {
            $profileWriteParameters.RequireNewTarget = $true
        }
        $profileProduct = Write-ToolkitUtf8FileAtomic `
            @profileWriteParameters
        $transactionProducts[[IO.Path]::GetFullPath($resolvedProfilePath)] =
            [pscustomobject]@{
                Path = [IO.Path]::GetFullPath($resolvedProfilePath)
                InitialState = [pscustomobject]@{
                    Path = [IO.Path]::GetFullPath($resolvedProfilePath)
                    Existed = $null -ne $originalProfileSnapshot
                    Snapshot = $originalProfileSnapshot
                }
                PostState = [pscustomobject]@{
                    Path = [IO.Path]::GetFullPath($resolvedProfilePath)
                    Existed = $true
                    Snapshot = $profileProduct
                }
            }

        if (-not $SkipCatalogRefresh) {
            if (Test-OpenRouterApiKey) {
                $originalCatalogSnapshot =
                    $originalManagedSnapshots[[IO.Path]::GetFullPath(
                            $catalogPath
                        )]
                if (($null -eq $originalCatalogSnapshot -and
                        (Test-Path -LiteralPath $catalogPath)) -or
                    ($null -ne $originalCatalogSnapshot -and
                        -not (Test-ToolkitFileMatchesSnapshot `
                            -Path $catalogPath `
                            -Snapshot $originalCatalogSnapshot))) {
                    throw 'catalog 在安装事务首次写入前被外部修改。'
                }
                $catalogResult = Update-OpenRouterModelCatalog `
                    -CatalogPath $catalogPath `
                    -RequiredModel $OpenRouterModel `
                    -MaximumAgeHours $CatalogMaximumAgeHours `
                    -PassThruMutation
                if ($null -ne $catalogResult.Mutation) {
                    if (-not (Test-ToolkitPathEqual `
                            -Left ([string]$catalogResult.Mutation.Path) `
                            -Right $catalogPath) -or
                        -not (Test-ToolkitPathEqual `
                            -Left ([string]$catalogResult.Mutation.InitialState.Path) `
                            -Right $catalogPath) -or
                        -not (Test-ToolkitPathEqual `
                            -Left ([string]$catalogResult.Mutation.PostState.Path) `
                            -Right $catalogPath) -or
                        -not [bool]$catalogResult.Mutation.PostState.Existed -or
                        $null -eq $catalogResult.Mutation.PostState.Snapshot) {
                        throw '模型目录刷新没有返回可验证的事务产物。'
                    }
                    $transactionProducts[[IO.Path]::GetFullPath($catalogPath)] =
                        $catalogResult.Mutation
                    $catalogInitialMatches = if (
                        $null -eq $originalCatalogSnapshot
                    ) {
                        -not [bool]$catalogResult.Mutation.InitialState.Existed
                    }
                    else {
                        [bool]$catalogResult.Mutation.InitialState.Existed -and
                            $null -ne `
                                $catalogResult.Mutation.InitialState.Snapshot -and
                            (Test-InstallerSnapshotEquivalent `
                                -Expected $originalCatalogSnapshot `
                                -Actual $catalogResult.Mutation.InitialState.Snapshot)
                    }
                    if (-not $catalogInitialMatches) {
                        throw 'catalog 在模型目录内部采样前被外部修改。'
                    }
                }
            }
            else {
                Write-Warning '尚未配置有效的 OPENROUTER_API_KEY；安装已完成，模型目录将在首次运行 cxor 时准备。'
            }
        }

        if ($SkipProfileReload) {
            Write-Host 'SkipProfileReload 已保留用于命令兼容。'
        }
        Write-Host '安装器未执行完整 PowerShell Profile。请新开 PowerShell 后使用 cx 或 cxor。'

        [pscustomobject]@{
            Installed = $true
            InstalledVersion = '0.1.1'
            ModulePath = $moduleManifest
            SettingsPath = $settingsPath
            ProfilePath = $resolvedProfilePath
            ConfigPath = $configPath
            BackupPath = $backupPath
            ApiKeyAvailable = Test-OpenRouterApiKey
            ProfileReloaded = $false
            NewPowerShellRequired = $true
            NextCommand = 'cxor'
        }
    }
    catch {
        $originalError = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue

        if (-not $previousInstallReady -and
            [string]$previousInstallMoveState['Disposition'] -notin @(
                'NoMove',
                'RevertedToSource'
            )) {
            $rollbackErrors.Add(
                "前代安装目录移动状态未完成验证，候选已保留：$previousInstall"
            )
        }
        if (-not $activeInstallCreated -and
            [string]$activeInstallMoveState['Disposition'] -notin @(
                'NoMove',
                'RevertedToSource'
            )) {
            $rollbackErrors.Add(
                "新安装目录发布状态未完成验证，候选已保留：$installRoot"
            )
        }

        foreach ($entry in $manifestFiles) {
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

        try {
            if ($previousInstallReady) {
                if ($activeInstallCreated -and
                    (Test-Path -LiteralPath $installRoot -PathType Container)) {
                    $failedInstall = Join-Path $backupPath 'failed-install'
                    $failedInstallMoveState = [ordered]@{}
                    Move-ToolkitDirectoryIfSnapshotMatches `
                        -Path $installRoot `
                        -Destination $failedInstall `
                        -Snapshot $activeInstallProduct `
                        -State $failedInstallMoveState
                }
                if (-not (
                    Test-Path `
                        -LiteralPath $previousInstall `
                        -PathType Container
                )) {
                    throw 'previous-install 缺失。'
                }
                $restorePreviousMoveState = [ordered]@{}
                Move-ToolkitDirectoryIfSnapshotMatches `
                    -Path $previousInstall `
                    -Destination $installRoot `
                    -Snapshot $previousInstallProduct `
                    -State $restorePreviousMoveState
                Assert-ToolkitPrivateDirectoryTree -Root $installRoot
            }
            elseif (-not $installExisted -and
                $activeInstallCreated -and
                (Test-Path -LiteralPath $installRoot -PathType Container)) {
                Remove-ToolkitDirectoryIfSnapshotMatches `
                    -Path $installRoot `
                    -Snapshot $activeInstallProduct
            }
        }
        catch {
            $rollbackErrors.Add("安装目录：$($_.Exception.Message)")
        }
        if ($stagedInstallCreated -and
            (Test-Path -LiteralPath $stagedInstall -PathType Container)) {
            Write-Warning "未发布的新安装 staging 已安全保留：$stagedInstall"
        }

        if ($rollbackErrors.Count -gt 0) {
            $message = $originalError.Exception.Message +
                "`r`n回滚未全部完成：" +
                ($rollbackErrors -join '；')
            throw [InvalidOperationException]::new(
                $message,
                $originalError.Exception
            )
        }
        throw $originalError
    }
}
finally {
    Exit-ToolkitMutex -Mutex $mutex
}
