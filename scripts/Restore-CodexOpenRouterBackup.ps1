[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,

    [string]$CodexHome,

    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [switch]$Force
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

function Resolve-RestorePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label 不能为空。"
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "$Label 路径无效：$Path"
    }

    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $pathRoot.Length) {
        $fullPath = $fullPath.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
    }
    return $fullPath
}

function Test-RestorePathEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    return [string]::Equals(
        (Resolve-RestorePath -Path $Left -Label '路径'),
        (Resolve-RestorePath -Path $Right -Label '路径'),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-RestoreProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $property = $InputObject.PSObject.Properties |
        Where-Object { $_.Name -ceq $Name } |
        Select-Object -First 1
    if ($null -eq $property) {
        throw "$Context 缺少字段 $Name。"
    }
    return $property.Value
}

function ConvertFrom-RestoreUtcTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $timestamp = if ($Value -is [DateTime]) {
        [DateTime]$Value
    }
    elseif ($Value -is [DateTimeOffset]) {
        ([DateTimeOffset]$Value).UtcDateTime
    }
    elseif ($Value -is [string]) {
        [DateTime]$parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact(
                [string]$Value,
                'o',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsed
            )) {
            throw "$Context 必须是 round-trip 格式的 UTC 时间。"
        }
        $parsed
    }
    else {
        throw "$Context 必须是 UTC 时间。"
    }
    if ($timestamp.Kind -ne [DateTimeKind]::Utc) {
        throw "$Context 必须明确标记为 UTC 时间。"
    }
    return $timestamp
}

function Assert-RestoreLastWriteTimeUtc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [DateTime]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $actual = (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc
    if ($actual -ne $Expected) {
        throw "$Label 的 LastWriteTimeUtc 与预期不一致。"
    }
}

function Assert-RestoreNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [switch]$Recurse,

        [ValidateRange(1, 100000)]
        [int]$MaximumEntries = 4096
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $probe = $resolvedPath
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $probe) {
            break
        }
        $probe = $parent
    }
    while (Test-Path -LiteralPath $probe) {
        $probeItem = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
        if (($probeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label 含有不允许的重解析点：$($probeItem.FullName)"
        }
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $probe) {
            break
        }
        $probe = $parent
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) { return }
    $rootItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    $pending = [Collections.Generic.Stack[IO.FileSystemInfo]]::new()
    $pending.Push($rootItem)
    $visitedEntries = 1

    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label 含有不允许的重解析点：$($item.FullName)"
        }

        if ($Recurse -and $item.PSIsContainer) {
            foreach ($childPath in [IO.Directory]::EnumerateFileSystemEntries(
                    $item.FullName
                )) {
                $child = Get-Item `
                    -LiteralPath $childPath `
                    -Force `
                    -ErrorAction Stop
                $visitedEntries++
                if ($visitedEntries -gt $MaximumEntries) {
                    throw "$Label 的项目数量超过 $MaximumEntries 项限制：$resolvedPath"
                }
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "$Label 含有不允许的重解析点：$($child.FullName)"
                }
                if ($child.PSIsContainer) {
                    $pending.Push($child)
                }
            }
        }
    }
}

function Get-RestoreSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function ConvertFrom-RestoreUtf8Bytes {
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

function Assert-RestoreProfileSyntax {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $tokens = $null
    $parseErrors = $null
    $profileSnapshot = Get-ToolkitFileSnapshot `
        -Path $Path `
        -MaximumBytes 5MB
    $content = ConvertFrom-RestoreUtf8Bytes `
        -Bytes $profileSnapshot.Bytes `
        -Label $Label
    [void][Management.Automation.Language.Parser]::ParseInput(
        $content,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        $firstError = [string]$parseErrors[0].Message
        throw "$Label 有 $(@($parseErrors).Count) 个 PowerShell 语法错误。首个错误：$firstError"
    }
}

function Get-RestoreDirectoryInventory {
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

    $basePath = Resolve-RestorePath -Path $Path -Label '目录'
    [void](Get-ToolkitSafeDirectoryTreePaths `
        -Root $basePath `
        -MaximumEntries $MaximumEntries)
    $basePrefix = $basePath + [IO.Path]::DirectorySeparatorChar
    $inventory = [Collections.Generic.List[string]]::new()
    $totalBytes = 0L
    foreach ($filePath in [IO.Directory]::EnumerateFiles(
            $basePath,
            '*',
            [IO.SearchOption]::AllDirectories
        )) {
        if ($inventory.Count -ge $MaximumEntries) {
            throw "目录文件数量超过 $MaximumEntries 项限制：$basePath"
        }
        $relativePath = $filePath.Substring($basePrefix.Length)
        $snapshot = Get-ToolkitFileSnapshot `
            -Path $filePath `
            -MaximumBytes $MaximumFileBytes
        $totalBytes += [long]$snapshot.Length
        if ($totalBytes -gt $MaximumTotalBytes) {
            throw "目录文件总大小超过 $MaximumTotalBytes 字节限制：$basePath"
        }
        $inventory.Add(
            "$relativePath`t$([long]$snapshot.Length)`t$($snapshot.Sha256.ToUpperInvariant())"
        )
    }
    return @($inventory | Sort-Object)
}

function ConvertFrom-RestoreManifestInventory {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ($Entries.Count -gt 1024) {
        throw 'PreviousInstallFiles 的项目数量超过 1024 项限制。'
    }
    $resolvedBase = Resolve-RestorePath -Path $BasePath -Label 'previous-install'
    $basePrefix = $resolvedBase + [IO.Path]::DirectorySeparatorChar
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $inventory = [Collections.Generic.List[string]]::new()
    $totalDeclaredBytes = 0L
    foreach ($entry in $Entries) {
        if ($null -eq $entry) {
            throw 'PreviousInstallFiles 包含空条目。'
        }
        $relativePath = [string](Get-RestoreProperty `
                -InputObject $entry `
                -Name 'RelativePath' `
                -Context 'PreviousInstallFiles 条目')
        $lengthValue = Get-RestoreProperty `
            -InputObject $entry `
            -Name 'Length' `
            -Context "PreviousInstallFiles 条目 $relativePath"
        $sha256 = [string](Get-RestoreProperty `
                -InputObject $entry `
                -Name 'Sha256' `
                -Context "PreviousInstallFiles 条目 $relativePath")
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathFullyQualified($relativePath) -or
            $relativePath.Contains('/') -or
            $relativePath.Contains(':')) {
            throw "PreviousInstallFiles 的相对路径无效：$relativePath"
        }
        $candidate = [IO.Path]::GetFullPath((Join-Path $resolvedBase $relativePath))
        if (-not $candidate.StartsWith(
                $basePrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            [IO.Path]::GetRelativePath($resolvedBase, $candidate) -cne $relativePath) {
            throw "PreviousInstallFiles 的相对路径越界：$relativePath"
        }
        if (-not $seenPaths.Add($relativePath)) {
            throw "PreviousInstallFiles 的相对路径重复：$relativePath"
        }
        if (($lengthValue -isnot [long] -and $lengthValue -isnot [int]) -or
            [long]$lengthValue -lt 0 -or
            [long]$lengthValue -gt 25MB) {
            throw "PreviousInstallFiles 的长度无效：$relativePath"
        }
        if ($sha256 -cnotmatch '^[A-F0-9]{64}$') {
            throw "PreviousInstallFiles 的 SHA256 无效：$relativePath"
        }
        $totalDeclaredBytes += [long]$lengthValue
        if ($totalDeclaredBytes -gt 64MB) {
            throw 'PreviousInstallFiles 的声明总大小超过 67108864 字节限制。'
        }
        $inventory.Add("$relativePath`t$([long]$lengthValue)`t$sha256")
    }
    return @($inventory | Sort-Object)
}

function Assert-RestoreToolkitInstallOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedInstallRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedProfilePath,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label 必须是目录：$Path"
    }
    Assert-RestoreNoReparsePoint `
        -Path $Path `
        -Label $Label `
        -Recurse `
        -MaximumEntries 1024
    $settingsPath = Join-Path $Path 'settings.json'
    $moduleManifestPath = Join-Path `
        $Path `
        'CodexOpenRouter\CodexOpenRouter.psd1'
    $modulePath = Join-Path $Path 'CodexOpenRouter\CodexOpenRouter.psm1'
    foreach ($requiredPath in @($settingsPath, $moduleManifestPath, $modulePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "$Label 缺少工具包文件：$requiredPath"
        }
        Assert-RestoreNoReparsePoint -Path $requiredPath -Label "$Label 的工具包文件"
        $maximumRequiredBytes = if (Test-RestorePathEqual `
                -Left $requiredPath `
                -Right $settingsPath) {
            5MB
        }
        else { 25MB }
        if ((Get-Item `
                -LiteralPath $requiredPath `
                -Force `
                -ErrorAction Stop).Length -gt $maximumRequiredBytes) {
            throw "$Label 的工具包文件超过 $maximumRequiredBytes 字节限制：$requiredPath"
        }
    }
    try {
        $settingsSnapshot = Get-ToolkitFileSnapshot `
            -Path $settingsPath `
            -MaximumBytes 5MB
        $settingsText = ConvertFrom-RestoreUtf8Bytes `
            -Bytes $settingsSnapshot.Bytes `
            -Label "$Label 的 settings.json"
        $settings = $settingsText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Label 的 settings.json 无法解析：$($_.Exception.Message)"
    }
    $schemaValue = Get-RestoreProperty `
        -InputObject $settings `
        -Name 'SchemaVersion' `
        -Context "$Label 的 settings.json"
    if (($schemaValue -isnot [long] -and $schemaValue -isnot [int]) -or
        [int]$schemaValue -notin @(1, 2)) {
        throw "$Label 的 settings schema 无效。"
    }
    if ([int]$schemaValue -eq 2) {
        $toolkit = [string](Get-RestoreProperty `
                -InputObject $settings `
                -Name 'Toolkit' `
                -Context "$Label 的 settings.json")
        if ($toolkit -cne 'codex-openrouter-toolkit') {
            throw "$Label 的 Toolkit 标识无效。"
        }
        $recordedInstallRoot = [string](Get-RestoreProperty `
                -InputObject $settings `
                -Name 'InstallRoot' `
                -Context "$Label 的 settings.json")
        if (-not (Test-RestorePathEqual `
                -Left $recordedInstallRoot `
                -Right $ExpectedInstallRoot)) {
            throw "$Label 的 InstallRoot 不匹配。"
        }
    }
    $expectedSettingsPaths = [ordered]@{
        CodexHome = $ExpectedCodexHome
        ProfilePath = $ExpectedProfilePath
        ConfigPath = Join-Path $ExpectedCodexHome 'config.toml'
        CatalogPath = Join-Path $ExpectedCodexHome 'openrouter-model-catalog.json'
        ActiveCachePath = Join-Path $ExpectedCodexHome 'models_cache.json'
        OpenAICachePath = Join-Path $ExpectedCodexHome 'models_cache.openai.json'
    }
    foreach ($expectedPath in $expectedSettingsPaths.GetEnumerator()) {
        $recordedPath = [string](Get-RestoreProperty `
                -InputObject $settings `
                -Name $expectedPath.Key `
                -Context "$Label 的 settings.json")
        if (-not (Test-RestorePathEqual `
                -Left $recordedPath `
                -Right ([string]$expectedPath.Value))) {
            throw "$Label 的 $($expectedPath.Key) 不匹配。"
        }
    }
    try {
        $moduleManifestRead = Import-ToolkitPowerShellDataFileLocked `
            -Path $moduleManifestPath `
            -MaximumBytes 5MB
        $moduleManifest = $moduleManifestRead.Data
    }
    catch {
        throw "$Label 的模块清单无法解析：$($_.Exception.Message)"
    }
    if ([string]$moduleManifest.RootModule -cne 'CodexOpenRouter.psm1' -or
        [string]$moduleManifest.GUID -cne 'be74dba0-28ed-4ba3-adff-f0fc0d107b39') {
        throw "$Label 的模块清单身份无效。"
    }
    return $moduleManifestRead.Snapshot
}

function Assert-RestoreInventoryEqual {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label 的文件数量与预检结果不一致。"
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Expected[$index] -cne $Actual[$index]) {
            throw "$Label 的文件内容与预检结果不一致。"
        }
    }
}

function Copy-RestoreFileAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [AllowNull()]
        [string]$AclSddl,

        [Nullable[DateTime]]$LastWriteTimeUtc,

        [AllowNull()]
        [object]$ExpectedCurrentSnapshot,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 50MB,

        [switch]$PassThru
    )

    if (Test-Path -LiteralPath $Destination -PathType Container) {
        throw "目标路径需要是普通文件：$Destination"
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "源路径需要是普通文件：$Source"
    }
    Assert-RestoreNoReparsePoint -Path $Source -Label '源文件路径'
    Assert-RestoreNoReparsePoint -Path $Destination -Label '目标文件路径'
    $sourceSnapshot = Get-ToolkitFileSnapshot `
        -Path $Source `
        -MaximumBytes $MaximumBytes
    $restoreLastWriteTimeUtc = if ($null -ne $LastWriteTimeUtc) {
        [DateTime]$LastWriteTimeUtc
    }
    else {
        $sourceSnapshot.LastWriteTimeUtc
    }
    $writeParameters = @{
        Path = $Destination
        Bytes = $sourceSnapshot.Bytes
        TargetLastWriteTimeUtc = $restoreLastWriteTimeUtc
        MaximumBytes = $MaximumBytes
    }
    if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($AclSddl)) {
        $writeParameters.DesiredAcl = New-ToolkitFileAclFromSddl -Sddl $AclSddl
    }
    if ($null -ne $ExpectedCurrentSnapshot) {
        if (-not (Test-ToolkitFileMatchesSnapshot `
                -Path $Destination `
                -Snapshot $ExpectedCurrentSnapshot)) {
            throw "恢复写入 CAS 冲突，保留外部修改：$Destination"
        }
        $writeParameters.ExpectedCurrentBytes = $ExpectedCurrentSnapshot.Bytes
        $writeParameters.ExpectedCurrentLastWriteTimeUtc =
            $ExpectedCurrentSnapshot.LastWriteTimeUtc
        if ($IsWindows) {
            $writeParameters.ExpectedCurrentAcl = $ExpectedCurrentSnapshot.Acl
        }
        $writeParameters.RequireExistingTarget = $true
    }
    elseif (Test-Path -LiteralPath $Destination) {
        throw "恢复写入 CAS 冲突，目标被并发创建：$Destination"
    }
    else {
        $writeParameters.RequireNewTarget = $true
    }
    if ($PassThru) { $writeParameters.PassThru = $true }
    $productSnapshot = Write-ToolkitBytesAtomic @writeParameters
    if ($PassThru) { return $productSnapshot }
}

function Copy-RestoreDirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "目录复制源必须是目录：$Source"
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "目录复制目标必须是目录：$Destination"
    }
    $resolvedSource = [IO.Path]::GetFullPath($Source)
    $resolvedDestination = [IO.Path]::GetFullPath($Destination)
    Assert-RestoreNoReparsePoint `
        -Path $resolvedSource `
        -Label '目录复制源' `
        -Recurse `
        -MaximumEntries 1024
    Assert-RestoreNoReparsePoint `
        -Path $resolvedDestination `
        -Label '目录复制目标' `
        -Recurse `
        -MaximumEntries 1024
    $destinationEnumerator = [IO.Directory]::EnumerateFileSystemEntries(
        $resolvedDestination
    ).GetEnumerator()
    try {
        if ($destinationEnumerator.MoveNext()) {
            throw "目录复制目标必须为空：$resolvedDestination"
        }
    }
    finally {
        $destinationEnumerator.Dispose()
    }
    Set-ToolkitPrivateDirectoryTree -Root $resolvedDestination

    $sourcePaths = @(Get-ToolkitSafeDirectoryTreePaths `
            -Root $resolvedSource `
            -MaximumEntries 1024 |
            Sort-Object `
                @{ Expression = { $_.Length } }, `
                @{ Expression = { $_ } })
    $sourcePrefix = $resolvedSource.TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
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
            throw "目录复制源含有不允许的重解析点：$sourcePath"
        }
        $relativePath = $sourcePath.Substring($sourcePrefix.Length)
        if ($sourceItem.PSIsContainer) {
            $targetDirectory = Join-Path $resolvedDestination $relativePath
            if (Test-Path -LiteralPath $targetDirectory) {
                throw "目录复制目标被并发占用：$targetDirectory"
            }
            [void](New-Item `
                -ItemType Directory `
                -Path $targetDirectory `
                -ErrorAction Stop)
            Set-ToolkitPrivateFileSystemAcl -Path $targetDirectory
            continue
        }

        $targetFile = Join-Path $resolvedDestination $relativePath
        $sourceSnapshot = Get-ToolkitFileSnapshot `
            -Path $sourcePath `
            -MaximumBytes 25MB
        $totalSourceBytes += [long]$sourceSnapshot.Length
        if ($totalSourceBytes -gt 64MB) {
            throw '目录复制源文件总大小超过 67108864 字节限制。'
        }
        Write-ToolkitBytesAtomic `
            -Path $targetFile `
            -Bytes $sourceSnapshot.Bytes `
            -TargetLastWriteTimeUtc $sourceSnapshot.LastWriteTimeUtc `
            -MaximumBytes 25MB `
            -RequireNewTarget
    }

    Set-ToolkitPrivateDirectoryTree -Root $resolvedDestination
}

if (-not $Force) {
    throw '恢复会覆盖清单中的正式文件，请显式指定 -Force。'
}

$resolvedCodexHome = if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
    Resolve-RestorePath -Path $CodexHome -Label 'CodexHome'
}
elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Resolve-RestorePath -Path $env:CODEX_HOME -Label 'CODEX_HOME'
}
else {
    Resolve-RestorePath `
        -Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex') `
        -Label 'CodexHome'
}

$volumeRoot = [IO.Path]::GetPathRoot($resolvedCodexHome).
    TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($resolvedCodexHome.TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq
    $volumeRoot) {
    throw 'CodexHome 不能是卷根目录。'
}

$resolvedProfilePath = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    Resolve-RestorePath -Path $ProfilePath -Label 'ProfilePath'
}
else {
    Resolve-RestorePath -Path $PROFILE.CurrentUserCurrentHost -Label 'PowerShell Profile'
}

$backupRoot = Resolve-RestorePath `
    -Path (Join-Path $resolvedCodexHome 'codex-openrouter-toolkit-backups') `
    -Label '备份根目录'
$resolvedBackupPath = Resolve-RestorePath -Path $BackupPath -Label 'BackupPath'
$backupParent = Resolve-RestorePath `
    -Path (Split-Path -Parent $resolvedBackupPath) `
    -Label '备份目录的父目录'

if (-not (Test-RestorePathEqual -Left $backupParent -Right $backupRoot) -or
    (Test-RestorePathEqual -Left $resolvedBackupPath -Right $backupRoot)) {
    throw "BackupPath 必须是备份根目录的直接子目录：$backupRoot"
}
if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
    throw "找不到备份根目录：$backupRoot"
}
if (-not (Test-Path -LiteralPath $resolvedBackupPath -PathType Container)) {
    throw "找不到备份目录：$resolvedBackupPath"
}
Assert-RestoreNoReparsePoint -Path $backupRoot -Label '备份根目录'
Assert-RestoreNoReparsePoint -Path $resolvedBackupPath -Label '备份目录'

$manifestPath = Join-Path $resolvedBackupPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "找不到备份清单：$manifestPath"
}
Assert-RestoreNoReparsePoint -Path $manifestPath -Label '备份清单'

try {
    $manifestSnapshot = Get-ToolkitFileSnapshot `
        -Path $manifestPath `
        -MaximumBytes 5MB
    $manifestText = ConvertFrom-RestoreUtf8Bytes `
        -Bytes $manifestSnapshot.Bytes `
        -Label '备份清单'
    $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "无法读取备份清单：$($_.Exception.Message)"
}

$toolkitName = [string](Get-RestoreProperty `
        -InputObject $manifest `
        -Name 'Toolkit' `
        -Context '备份清单')
$schemaValue = Get-RestoreProperty `
    -InputObject $manifest `
    -Name 'SchemaVersion' `
    -Context '备份清单'
if ($toolkitName -cne 'codex-openrouter-toolkit' -or
    ($schemaValue -isnot [long] -and $schemaValue -isnot [int])) {
    throw '备份清单不属于受支持的 Codex OpenRouter Toolkit。'
}
$schemaVersion = [int]$schemaValue
if ($schemaVersion -notin @(1, 2, 3)) {
    throw "不支持备份清单 schema：$schemaVersion"
}

$installRoot = Resolve-RestorePath `
    -Path (Join-Path $resolvedCodexHome 'codex-openrouter-toolkit') `
    -Label '安装目录'
$previousInstallPath = Join-Path $resolvedBackupPath 'previous-install'
$previousInstallExists = Test-Path -LiteralPath $previousInstallPath -PathType Container
if (Test-Path -LiteralPath $previousInstallPath) {
    if (-not $previousInstallExists) {
        throw "previous-install 必须是目录：$previousInstallPath"
    }
    Assert-RestoreNoReparsePoint `
        -Path $previousInstallPath `
        -Label 'previous-install' `
        -Recurse `
        -MaximumEntries 1024
}

$installExisted = $previousInstallExists
$manifestPreviousInstallInventory = @()
if ($schemaVersion -ge 2) {
    $schemaContext = "schema $schemaVersion 备份清单"
    $manifestCodexHome = [string](Get-RestoreProperty `
            -InputObject $manifest `
            -Name 'CodexHome' `
            -Context $schemaContext)
    $manifestProfilePath = [string](Get-RestoreProperty `
            -InputObject $manifest `
            -Name 'ProfilePath' `
            -Context $schemaContext)
    $manifestInstallRoot = [string](Get-RestoreProperty `
            -InputObject $manifest `
            -Name 'InstallRoot' `
            -Context $schemaContext)
    $manifestInstallExisted = Get-RestoreProperty `
        -InputObject $manifest `
        -Name 'InstallExisted' `
        -Context $schemaContext

    if (-not (Test-RestorePathEqual -Left $manifestCodexHome -Right $resolvedCodexHome)) {
        throw "schema $schemaVersion 清单中的 CodexHome 与恢复参数不一致。"
    }
    if (-not (Test-RestorePathEqual -Left $manifestProfilePath -Right $resolvedProfilePath)) {
        throw "schema $schemaVersion 清单中的 ProfilePath 与恢复参数不一致。"
    }
    if (-not (Test-RestorePathEqual -Left $manifestInstallRoot -Right $installRoot)) {
        throw "schema $schemaVersion 清单中的 InstallRoot 与推导路径不一致。"
    }
    if ($manifestInstallExisted -isnot [bool]) {
        throw "schema $schemaVersion 清单中的 InstallExisted 必须是布尔值。"
    }
    $installExisted = [bool]$manifestInstallExisted
    if ($installExisted -ne $previousInstallExists) {
        throw "schema $schemaVersion 清单中的 InstallExisted 与 previous-install 状态不一致。"
    }
    $previousInstallFilesValue = Get-RestoreProperty `
        -InputObject $manifest `
        -Name 'PreviousInstallFiles' `
        -Context $schemaContext
    $manifestPreviousInstallInventory = @(
        ConvertFrom-RestoreManifestInventory `
            -Entries @($previousInstallFilesValue) `
            -BasePath $previousInstallPath
    )
    if ($installExisted -and $manifestPreviousInstallInventory.Count -eq 0) {
        throw "schema $schemaVersion 清单中的 PreviousInstallFiles 不能为空。"
    }
    if (-not $installExisted -and $manifestPreviousInstallInventory.Count -ne 0) {
        throw "schema $schemaVersion 首次安装清单的 PreviousInstallFiles 必须为空。"
    }
}

if ($installExisted) {
    $null = Assert-RestoreToolkitInstallOwnership `
        -Path $previousInstallPath `
        -ExpectedCodexHome $resolvedCodexHome `
        -ExpectedInstallRoot $installRoot `
        -ExpectedProfilePath $resolvedProfilePath `
        -Label 'previous-install'
    $previousInstallInventory = @(Get-RestoreDirectoryInventory `
        -Path $previousInstallPath `
        -MaximumFileBytes 25MB)
    if ($schemaVersion -ge 2) {
        Assert-RestoreInventoryEqual `
            -Expected $manifestPreviousInstallInventory `
            -Actual $previousInstallInventory `
            -Label 'previous-install 与清单'
    }
}
else {
    $previousInstallInventory = @()
}

$expectedFiles = [ordered]@{
    'profile' = [pscustomobject]@{
        Target = $resolvedProfilePath
        BackupRelativePath = 'profile.bak'
        MaximumBytes = 5MB
    }
    'config' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'config.toml'
        BackupRelativePath = 'config.bak'
        MaximumBytes = 5MB
    }
    'catalog' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'openrouter-model-catalog.json'
        BackupRelativePath = 'catalog.bak'
        MaximumBytes = 50MB
    }
    'active-cache' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'models_cache.json'
        BackupRelativePath = 'active-cache.bak'
        MaximumBytes = 50MB
    }
    'openai-cache' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'models_cache.openai.json'
        BackupRelativePath = 'openai-cache.bak'
        MaximumBytes = 50MB
    }
}

$manifestFilesValue = Get-RestoreProperty `
    -InputObject $manifest `
    -Name 'Files' `
    -Context '备份清单'
$manifestFiles = @($manifestFilesValue)
if ($manifestFiles.Count -ne $expectedFiles.Count) {
    throw "备份清单必须恰好包含 $($expectedFiles.Count) 个受管文件。"
}

$seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$validatedFilesByName = @{}
foreach ($entry in $manifestFiles) {
    if ($null -eq $entry) {
        throw '备份清单包含空文件项。'
    }

    $name = [string](Get-RestoreProperty `
            -InputObject $entry `
            -Name 'Name' `
            -Context '文件项')
    if (-not $expectedFiles.Contains($name)) {
        throw "备份清单包含不允许的文件项：$name"
    }
    if (-not $seenNames.Add($name)) {
        throw "备份清单包含重复文件项：$name"
    }

    $expected = $expectedFiles[$name]
    $target = Resolve-RestorePath `
        -Path ([string](Get-RestoreProperty `
                -InputObject $entry `
                -Name 'Target' `
                -Context "文件项 $name")) `
        -Label "文件项 $name 的 Target"
    $expectedTarget = Resolve-RestorePath -Path $expected.Target -Label "文件项 $name 的目标"
    if (-not (Test-RestorePathEqual -Left $target -Right $expectedTarget)) {
        throw "文件项 $name 的 Target 与推导路径不一致。"
    }

    $existed = Get-RestoreProperty `
        -InputObject $entry `
        -Name 'Existed' `
        -Context "文件项 $name"
    if ($existed -isnot [bool]) {
        throw "文件项 $name 的 Existed 必须是布尔值。"
    }

    $expectedBackupPath = Resolve-RestorePath `
        -Path (Join-Path $resolvedBackupPath $expected.BackupRelativePath) `
        -Label "文件项 $name 的备份文件"
    $expectedHash = $null
    $sourceAclSddl = $null
    $sourceLastWriteTimeUtc = $null
    if ($schemaVersion -eq 1) {
        $backupFileValue = Get-RestoreProperty `
            -InputObject $entry `
            -Name 'BackupFile' `
            -Context "schema 1 文件项 $name"
        if ([bool]$existed) {
            if ($null -eq $backupFileValue -or
                [string]::IsNullOrWhiteSpace([string]$backupFileValue)) {
                throw "schema 1 文件项 $name 缺少 BackupFile。"
            }
            $schemaOneBackupPath = Resolve-RestorePath `
                -Path ([string]$backupFileValue) `
                -Label "schema 1 文件项 $name 的 BackupFile"
            if (-not (Test-RestorePathEqual `
                    -Left $schemaOneBackupPath `
                    -Right $expectedBackupPath)) {
                throw "schema 1 文件项 $name 的 BackupFile 与推导路径不一致。"
            }
        }
        elseif ($null -ne $backupFileValue) {
            throw "schema 1 文件项 $name 在 Existed=false 时 BackupFile 必须为 null。"
        }
    }
    else {
        $fileSchemaContext = "schema $schemaVersion 文件项 $name"
        $relativeBackupPath = [string](Get-RestoreProperty `
                -InputObject $entry `
                -Name 'BackupRelativePath' `
                -Context $fileSchemaContext)
        if ($relativeBackupPath -cne [string]$expected.BackupRelativePath -or
            [IO.Path]::IsPathRooted($relativeBackupPath)) {
            throw "schema $schemaVersion 文件项 $name 的 BackupRelativePath 无效。"
        }

        $shaValue = Get-RestoreProperty `
            -InputObject $entry `
            -Name 'Sha256' `
            -Context $fileSchemaContext
        if ([bool]$existed) {
            $expectedHash = [string]$shaValue
            if ($expectedHash -cnotmatch '^[A-F0-9]{64}$') {
                throw "schema $schemaVersion 文件项 $name 的 Sha256 无效。"
            }
        }
        elseif ($null -ne $shaValue) {
            throw "schema $schemaVersion 文件项 $name 在 Existed=false 时 Sha256 必须为 null。"
        }

        $aclProperty = $entry.PSObject.Properties['AclSddl']
        if ($IsWindows -and [bool]$existed -and
            ($null -eq $aclProperty -or
                $null -eq $aclProperty.Value -or
                $aclProperty.Value -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$aclProperty.Value))) {
            throw "Windows schema $schemaVersion 文件项 $name 在 Existed=true 时必须包含非空 AclSddl。"
        }
        if ($null -ne $aclProperty -and $null -ne $aclProperty.Value) {
            if (-not [bool]$existed) {
                throw "schema $schemaVersion 文件项 $name 在 Existed=false 时 AclSddl 必须为 null。"
            }
            if ($aclProperty.Value -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$aclProperty.Value) -or
                ([string]$aclProperty.Value).Length -gt 32768) {
                throw "schema $schemaVersion 文件项 $name 的 AclSddl 无效。"
            }
            $sourceAclSddl = [string]$aclProperty.Value
            if ($IsWindows) {
                try {
                    $parsedAcl = New-ToolkitFileAclFromSddl `
                        -Sddl $sourceAclSddl
                }
                catch {
                    throw "schema $schemaVersion 文件项 $name 的 AclSddl 无法安全解析。"
                }
            }
        }
        if ($schemaVersion -eq 3) {
            $timestampValue = Get-RestoreProperty `
                -InputObject $entry `
                -Name 'LastWriteTimeUtc' `
                -Context $fileSchemaContext
            if ([bool]$existed) {
                if ($null -eq $timestampValue) {
                    throw "schema 3 文件项 $name 缺少 LastWriteTimeUtc。"
                }
                $sourceLastWriteTimeUtc = ConvertFrom-RestoreUtcTimestamp `
                    -Value $timestampValue `
                    -Context "schema 3 文件项 $name 的 LastWriteTimeUtc"
            }
            elseif ($null -ne $timestampValue) {
                throw "schema 3 文件项 $name 在 Existed=false 时 LastWriteTimeUtc 必须为 null。"
            }
        }
    }

    $sourceHash = $null
    $sourceBackupPath = $null
    $sourceSnapshot = $null
    if ([bool]$existed) {
        if (-not (Test-Path -LiteralPath $expectedBackupPath -PathType Leaf)) {
            throw "备份文件缺失：$expectedBackupPath"
        }
        Assert-RestoreNoReparsePoint `
            -Path $expectedBackupPath `
            -Label "文件项 $name 的备份文件"
        $sourceSnapshot = Get-ToolkitFileSnapshot `
            -Path $expectedBackupPath `
            -MaximumBytes ([long]$expected.MaximumBytes)
        $sourceHash = $sourceSnapshot.Sha256.ToUpperInvariant()
        if ($schemaVersion -ge 2 -and $sourceHash -cne $expectedHash) {
            throw "schema $schemaVersion 文件项 $name 的 SHA256 校验失败。"
        }
        if ($schemaVersion -eq 3) {
            if ($sourceSnapshot.LastWriteTimeUtc -ne $sourceLastWriteTimeUtc) {
                throw "schema 3 文件项 $name 的备份文件 LastWriteTimeUtc 与清单不一致。"
            }
        }
        $sourceBackupPath = $expectedBackupPath
    }
    elseif (Test-Path -LiteralPath $expectedBackupPath) {
        throw "文件项 $name 声明 Existed=false，但固定备份路径仍存在。"
    }

    if (Test-Path -LiteralPath $expectedTarget) {
        if (-not (Test-Path -LiteralPath $expectedTarget -PathType Leaf)) {
            throw "受管目标必须是普通文件：$expectedTarget"
        }
    }
    Assert-RestoreNoReparsePoint -Path $expectedTarget -Label "受管目标 $name"

    $validatedFilesByName[$name] = [pscustomobject]@{
        Name = $name
        Target = $expectedTarget
        Existed = [bool]$existed
        SourceBackupPath = $sourceBackupPath
        SourceSha256 = $sourceHash
        MaximumBytes = [long]$expected.MaximumBytes
        SourceAclSddl = $sourceAclSddl
        SourceLastWriteTimeUtc = $sourceLastWriteTimeUtc
        StagedPath = $null
        CurrentExisted = $false
        CurrentAclSddl = $null
        CurrentLastWriteTimeUtc = $null
        CurrentSnapshot = $null
        TransactionModified = $false
        TransactionProductExisted = $false
        TransactionProductSnapshot = $null
        SnapshotPath = $null
    }
}

foreach ($requiredName in $expectedFiles.Keys) {
    if (-not $seenNames.Contains([string]$requiredName)) {
        throw "备份清单缺少文件项：$requiredName"
    }
}

$profileEntry = $validatedFilesByName['profile']
if ($profileEntry.Existed) {
    Assert-RestoreProfileSyntax `
        -Path $profileEntry.SourceBackupPath `
        -Label '备份中的 PowerShell Profile'
}

$plannedInstallAction = if ($installExisted) {
    'RestorePreviousInstall'
}
else {
    'RemoveCurrentInstall'
}

if (-not $PSCmdlet.ShouldProcess(
        $resolvedCodexHome,
        "恢复 5 个受管文件并执行安装目录操作 $plannedInstallAction"
    )) {
    [pscustomobject]@{
        Restored = $false
        BackupPath = $resolvedBackupPath
        RestoredFiles = 0
        InstallStateRestored = $false
        PlannedFiles = $expectedFiles.Count
        PlannedInstallAction = $plannedInstallAction
    }
    return
}

$restoreMutex = Enter-ToolkitMutex -ScopePath $resolvedCodexHome
$transactionRoot = Join-Path $resolvedCodexHome (
    '.codex-openrouter-restore-transaction-{0}-{1}' -f `
        $PID,
        [guid]::NewGuid().ToString('N')
)
$snapshotFilesRoot = Join-Path $transactionRoot 'current-files'
$stagedFilesRoot = Join-Path $transactionRoot 'staged-files'
$stagedInstallRoot = Join-Path $transactionRoot 'staged-previous-install'
$currentInstallSnapshot = Join-Path $transactionRoot 'current-install'
$transactionCreated = $false
$commitStarted = $false
$currentInstallExists = $false
$currentInstallMoved = $false
$restoredInstallCreated = $false
$currentInstallProduct = $null
$currentInstallSnapshotProduct = $null
$restoredInstallProduct = $null
$stagedInstallProduct = $null
$currentInstallMoveState = [ordered]@{ Disposition = 'NoMove' }
$restoredInstallMoveState = [ordered]@{ Disposition = 'NoMove' }
$restoreSucceeded = $false
$rollbackCompleted = $false

try {
    $currentInstallExists = Test-Path -LiteralPath $installRoot -PathType Container
    if (Test-Path -LiteralPath $installRoot) {
        if (-not $currentInstallExists) {
            throw "当前安装路径必须是目录：$installRoot"
        }
        $currentInstallManifestSnapshot = Assert-RestoreToolkitInstallOwnership `
            -Path $installRoot `
            -ExpectedCodexHome $resolvedCodexHome `
            -ExpectedInstallRoot $installRoot `
            -ExpectedProfilePath $resolvedProfilePath `
            -Label '当前安装目录'
        Set-ToolkitPrivateDirectoryTree -Root $installRoot
        $currentInstallProduct = Get-ToolkitDirectoryStateSnapshot `
            -Root $installRoot `
            -MaximumFileBytes 25MB `
            -MaximumEntries 1024 `
            -MaximumTotalBytes 64MB
        Assert-ToolkitDirectorySnapshotContainsFileSnapshot `
            -DirectorySnapshot $currentInstallProduct `
            -RelativePath 'CodexOpenRouter\CodexOpenRouter.psd1' `
            -FileSnapshot $currentInstallManifestSnapshot `
            -Label '当前安装模块清单'
    }
    if (Test-Path -LiteralPath $transactionRoot) {
        throw "事务目录已存在：$transactionRoot"
    }
    [void](New-Item -ItemType Directory -Path $transactionRoot -ErrorAction Stop)
    Set-ToolkitPrivateDirectoryTree -Root $transactionRoot
    [void](New-Item -ItemType Directory -Path $snapshotFilesRoot -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path $stagedFilesRoot -ErrorAction Stop)
    Set-ToolkitPrivateDirectoryTree -Root $transactionRoot
    $transactionCreated = $true

    foreach ($name in $expectedFiles.Keys) {
        $validated = $validatedFilesByName[[string]$name]
        if ($validated.Existed) {
            Assert-RestoreNoReparsePoint `
                -Path $validated.SourceBackupPath `
                -Label "文件项 $name 的备份文件"
            $stagedPath = Join-Path $stagedFilesRoot "$name.staged"
            Copy-ToolkitFileAtomic `
                -Source $validated.SourceBackupPath `
                -Destination $stagedPath `
                -MaximumBytes ([long]$validated.MaximumBytes)
            Assert-RestoreNoReparsePoint -Path $stagedPath -Label "暂存文件 $name"
            $stagedSnapshot = Get-ToolkitFileSnapshot `
                -Path $stagedPath `
                -MaximumBytes ([long]$validated.MaximumBytes)
            if ($stagedSnapshot.Sha256.ToUpperInvariant() -cne
                $validated.SourceSha256) {
                throw "暂存文件 $name 的 SHA256 与预检结果不一致。"
            }
            if ($null -ne $validated.SourceLastWriteTimeUtc) {
                if ($stagedSnapshot.LastWriteTimeUtc -ne
                    [DateTime]$validated.SourceLastWriteTimeUtc) {
                    throw "暂存文件 $name 的 LastWriteTimeUtc 与预检结果不一致。"
                }
            }
            $validated.StagedPath = $stagedPath
        }

        if (Test-Path -LiteralPath $validated.Target -PathType Leaf) {
            Assert-RestoreNoReparsePoint -Path $validated.Target -Label "受管目标 $name"
            $snapshotPath = Join-Path $snapshotFilesRoot "$name.current"
            $currentSnapshot = Get-ToolkitFileSnapshot `
                -Path $validated.Target `
                -MaximumBytes ([long]$validated.MaximumBytes)
            Write-ToolkitBytesAtomic `
                -Path $snapshotPath `
                -Bytes $currentSnapshot.Bytes `
                -TargetLastWriteTimeUtc $currentSnapshot.LastWriteTimeUtc `
                -MaximumBytes ([long]$validated.MaximumBytes) `
                -RequireNewTarget
            if ((Get-RestoreSha256 -Path $snapshotPath) -cne
                $currentSnapshot.Sha256.ToUpperInvariant()) {
                throw "当前文件 $name 的事务快照校验失败。"
            }
            $validated.CurrentExisted = $true
            $validated.CurrentAclSddl = $currentSnapshot.AclSddl
            $validated.CurrentLastWriteTimeUtc =
                $currentSnapshot.LastWriteTimeUtc
            $validated.CurrentSnapshot = $currentSnapshot
            $validated.SnapshotPath = $snapshotPath
        }
    }

    if ($installExisted) {
        $stagedSourceManifestSnapshot = Assert-RestoreToolkitInstallOwnership `
            -Path $previousInstallPath `
            -ExpectedCodexHome $resolvedCodexHome `
            -ExpectedInstallRoot $installRoot `
            -ExpectedProfilePath $resolvedProfilePath `
            -Label 'previous-install'
        Assert-RestoreNoReparsePoint `
            -Path $previousInstallPath `
            -Label 'previous-install' `
            -Recurse `
            -MaximumEntries 1024
        [void](New-Item `
            -ItemType Directory `
            -Path $stagedInstallRoot `
            -ErrorAction Stop)
        Set-ToolkitPrivateDirectoryTree -Root $stagedInstallRoot
        Copy-RestoreDirectoryContents `
            -Source $previousInstallPath `
            -Destination $stagedInstallRoot
        Assert-RestoreNoReparsePoint `
            -Path $stagedInstallRoot `
            -Label '暂存 previous-install' `
            -Recurse `
            -MaximumEntries 1024
        $stagedInstallProduct = Get-ToolkitDirectoryStateSnapshot `
            -Root $stagedInstallRoot `
            -MaximumFileBytes 25MB `
            -MaximumEntries 1024 `
            -MaximumTotalBytes 64MB
        Assert-ToolkitDirectorySnapshotContainsFileSnapshot `
            -DirectorySnapshot $stagedInstallProduct `
            -RelativePath 'CodexOpenRouter\CodexOpenRouter.psd1' `
            -FileSnapshot $stagedSourceManifestSnapshot `
            -Label '暂存 previous-install 模块清单'
        $stagedInstallInventory = @(
            $stagedInstallProduct.Entries |
                Where-Object Type -ceq 'file' |
                ForEach-Object {
                    "$([string]$_.RelativePath)`t$([long]$_.Length)`t" +
                        ([string]$_.Sha256).ToUpperInvariant()
                }
        )
        Assert-RestoreInventoryEqual `
            -Expected $previousInstallInventory `
            -Actual $stagedInstallInventory `
            -Label '暂存 previous-install'
        Assert-ToolkitPrivateDirectoryTree -Root $stagedInstallRoot
    }

    $commitStarted = $true
    if ($currentInstallExists) {
        if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
            throw '当前安装目录在提交前发生变化。'
        }
        Assert-RestoreNoReparsePoint `
            -Path $installRoot `
            -Label '当前安装目录' `
            -Recurse `
            -MaximumEntries 1024
        Move-ToolkitDirectoryIfSnapshotMatches `
            -Path $installRoot `
            -Destination $currentInstallSnapshot `
            -Snapshot $currentInstallProduct `
            -State $currentInstallMoveState
        $currentInstallMoved = $true
        $currentInstallSnapshotProduct = $currentInstallProduct
        if (Test-Path -LiteralPath $installRoot) {
            throw '当前安装目录在事务移动后被外部重新创建。'
        }
    }
    elseif (Test-Path -LiteralPath $installRoot) {
        throw '当前安装路径在提交前发生变化。'
    }

    if ($installExisted) {
        Move-ToolkitDirectoryIfSnapshotMatches `
            -Path $stagedInstallRoot `
            -Destination $installRoot `
            -Snapshot $stagedInstallProduct `
            -State $restoredInstallMoveState
        $restoredInstallCreated = $true
        $restoredInstallProduct = $stagedInstallProduct
        if (Test-Path -LiteralPath $stagedInstallRoot) {
            throw '恢复安装目录发布后，staging 路径被外部重新创建。'
        }
        Assert-ToolkitPrivateDirectoryTree -Root $installRoot
    }

    $commitOrder = @('config', 'catalog', 'active-cache', 'openai-cache', 'profile')
    foreach ($name in $commitOrder) {
        $validated = $validatedFilesByName[$name]
        if ($validated.Existed) {
            $validated.TransactionProductSnapshot = Copy-RestoreFileAtomic `
                -Source $validated.StagedPath `
                -Destination $validated.Target `
                -AclSddl $validated.SourceAclSddl `
                -LastWriteTimeUtc $validated.SourceLastWriteTimeUtc `
                -ExpectedCurrentSnapshot $validated.CurrentSnapshot `
                -MaximumBytes ([long]$validated.MaximumBytes) `
                -PassThru
            $validated.TransactionModified = $true
            $validated.TransactionProductExisted = $true
        }
        elseif ($validated.CurrentExisted) {
            Remove-ToolkitFileIfSnapshotMatches `
                -Path $validated.Target `
                -Snapshot $validated.CurrentSnapshot
            $validated.TransactionModified = $true
            $validated.TransactionProductExisted = $false
        }
        elseif (Test-Path -LiteralPath $validated.Target) {
            throw "恢复提交 CAS 冲突，保留并发创建的目标：$($validated.Target)"
        }
    }

    foreach ($name in $expectedFiles.Keys) {
        $validated = $validatedFilesByName[[string]$name]
        if ($validated.Existed) {
            if (-not (Test-Path -LiteralPath $validated.Target -PathType Leaf)) {
                throw "恢复后的文件校验失败：$name"
            }
            $restoredSnapshot = Get-ToolkitFileSnapshot `
                -Path $validated.Target `
                -MaximumBytes ([long]$validated.MaximumBytes)
            if ($restoredSnapshot.Sha256.ToUpperInvariant() -cne
                $validated.SourceSha256) {
                throw "恢复后的文件校验失败：$name"
            }
            if ($null -ne $validated.SourceLastWriteTimeUtc) {
                if ($restoredSnapshot.LastWriteTimeUtc -ne
                    [DateTime]$validated.SourceLastWriteTimeUtc) {
                    throw "恢复后的文件 $name 的 LastWriteTimeUtc 校验失败。"
                }
            }
        }
        elseif (Test-Path -LiteralPath $validated.Target) {
            throw "恢复后的文件应当不存在：$name"
        }
    }

    if ($profileEntry.Existed) {
        Assert-RestoreProfileSyntax `
            -Path $profileEntry.Target `
            -Label '恢复后的 PowerShell Profile'
    }

    if ($installExisted) {
        if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
            throw 'previous-install 未成功恢复。'
        }
        Assert-RestoreNoReparsePoint `
            -Path $installRoot `
            -Label '恢复后的安装目录' `
            -Recurse `
            -MaximumEntries 1024
        $restoredInstallInventory = @(Get-RestoreDirectoryInventory `
            -Path $installRoot `
            -MaximumFileBytes 25MB)
        Assert-RestoreInventoryEqual `
            -Expected $previousInstallInventory `
            -Actual $restoredInstallInventory `
            -Label '恢复后的安装目录'
    }
    elseif (Test-Path -LiteralPath $installRoot) {
        throw '首次安装备份恢复后，安装目录仍然存在。'
    }

    $restoreSucceeded = $true
    [pscustomobject]@{
        Restored = $true
        BackupPath = $resolvedBackupPath
        RestoredFiles = $expectedFiles.Count
        InstallStateRestored = $true
        InstallAction = $plannedInstallAction
    }
}
catch {
    $originalError = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()

    if (-not $currentInstallMoved -and
        ([string]$currentInstallMoveState['Disposition'] -notin @(
                'NoMove',
                'RevertedToSource'
            ) -or
            (Test-Path `
                -LiteralPath $currentInstallSnapshot `
                -PathType Container))) {
        $rollbackErrors.Add(
            '当前安装目录移动状态未完成验证，候选位置：' +
                [string]$currentInstallMoveState['CurrentLocation']
        )
    }
    if (-not $restoredInstallCreated -and
        [string]$restoredInstallMoveState['Disposition'] -notin @(
            'NoMove',
            'RevertedToSource'
        )) {
        $rollbackErrors.Add(
            '恢复安装目录发布状态未完成验证，候选位置：' +
                [string]$restoredInstallMoveState['CurrentLocation']
        )
    }
    if ($restoredInstallCreated -and
        (Test-Path -LiteralPath $stagedInstallRoot)) {
        $rollbackErrors.Add(
            "恢复安装发布后 staging 路径被重新创建，外部候选已保留：$stagedInstallRoot"
        )
    }

    if ($commitStarted) {
        try {
            if ($restoredInstallCreated -and
                (Test-Path -LiteralPath $installRoot)) {
                if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
                    throw "回滚目标安装路径需要是目录：$installRoot"
                }
                Remove-ToolkitDirectoryIfSnapshotMatches `
                    -Path $installRoot `
                    -Snapshot $restoredInstallProduct `
                    -AllowInheritedPrivateChildren
                $restoredInstallCreated = $false
            }
            if ($currentInstallMoved) {
                if (Test-Path -LiteralPath $installRoot) {
                    throw '安装目录出现了非本事务创建的内容，已保留事务快照。'
                }
                if (-not (Test-Path `
                        -LiteralPath $currentInstallSnapshot `
                        -PathType Container)) {
                    throw '当前安装目录的事务快照不可用。'
                }
                $rollbackCurrentInstallMoveState = [ordered]@{}
                Move-ToolkitDirectoryIfSnapshotMatches `
                    -Path $currentInstallSnapshot `
                    -Destination $installRoot `
                    -Snapshot $currentInstallSnapshotProduct `
                    -State $rollbackCurrentInstallMoveState
                Assert-ToolkitPrivateDirectoryTree -Root $installRoot
                $currentInstallMoved = $false
                $currentInstallMoveState['CurrentLocation'] = $installRoot
                $currentInstallMoveState['Recovered'] = $true
                $currentInstallMoveState['Disposition'] = 'RevertedToSource'
            }
        }
        catch {
            $rollbackErrors.Add("安装目录回滚失败：$($_.Exception.Message)")
        }

        foreach ($name in $expectedFiles.Keys) {
            $validated = $validatedFilesByName[[string]$name]
            try {
                if (-not $validated.TransactionModified) {
                    continue
                }
                if ($validated.CurrentExisted) {
                    if (-not (Test-Path -LiteralPath $validated.SnapshotPath -PathType Leaf)) {
                        throw '事务快照缺失。'
                    }
                    Copy-RestoreFileAtomic `
                        -Source $validated.SnapshotPath `
                        -Destination $validated.Target `
                        -AclSddl $validated.CurrentAclSddl `
                        -LastWriteTimeUtc $validated.CurrentLastWriteTimeUtc `
                        -MaximumBytes ([long]$validated.MaximumBytes) `
                        -ExpectedCurrentSnapshot $(if (
                            $validated.TransactionProductExisted
                        ) {
                            $validated.TransactionProductSnapshot
                        }
                        else { $null })
                }
                elseif ($validated.TransactionProductExisted) {
                    Remove-ToolkitFileIfSnapshotMatches `
                        -Path $validated.Target `
                        -Snapshot $validated.TransactionProductSnapshot
                }
            }
            catch {
                $rollbackErrors.Add("文件 $name 回滚失败：$($_.Exception.Message)")
            }
        }
    }

    if ($rollbackErrors.Count -gt 0) {
        throw "恢复失败：$($originalError.Exception.Message) 回滚也遇到错误：$($rollbackErrors -join '；')。事务快照已保留：$transactionRoot"
    }
    $rollbackCompleted = $true
    throw "恢复失败，已还原事务前状态：$($originalError.Exception.Message)"
}
finally {
    $transactionRetainsMovedDirectory = -not $restoreSucceeded -and (
        (Test-Path `
            -LiteralPath $currentInstallSnapshot `
            -PathType Container) -or
        [string]$currentInstallMoveState['Disposition'] -notin @(
            'NoMove',
            'RevertedToSource',
            'AtDestinationValidated'
        ) -or
        [string]$restoredInstallMoveState['Disposition'] -notin @(
            'NoMove',
            'RevertedToSource',
            'AtDestinationValidated'
        )
    )
    $canCleanTransaction = $restoreSucceeded -or
        ($commitStarted -and $rollbackCompleted -and
            -not $transactionRetainsMovedDirectory)
    if ($transactionCreated -and
        $canCleanTransaction -and
        (Test-Path -LiteralPath $transactionRoot)) {
        try {
            Assert-RestoreNoReparsePoint -Path $transactionRoot -Label '事务目录' -Recurse
            Assert-ToolkitPrivateDirectoryTree -Root $transactionRoot
            $transactionProduct = Get-ToolkitDirectoryStateSnapshot `
                -Root $transactionRoot `
                -MaximumFileBytes 50MB `
                -MaximumEntries 4096 `
                -MaximumTotalBytes 512MB
            Remove-ToolkitDirectoryIfSnapshotMatches `
                -Path $transactionRoot `
                -Snapshot $transactionProduct
        }
        catch {
            if ($restoreSucceeded) {
                Write-Warning "恢复成功，但事务目录清理失败：$transactionRoot。$($_.Exception.Message)"
            }
            else {
                Write-Warning "事务目录清理失败：$transactionRoot。$($_.Exception.Message)"
            }
        }
    }
    elseif ($transactionCreated -and
        -not $canCleanTransaction -and
        (Test-Path -LiteralPath $transactionRoot)) {
        Write-Warning "回滚未完整完成，事务快照已保留：$transactionRoot"
    }
    Exit-ToolkitMutex -Mutex $restoreMutex
}
