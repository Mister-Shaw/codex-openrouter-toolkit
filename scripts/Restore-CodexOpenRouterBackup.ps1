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

function Assert-RestoreNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [switch]$Recurse
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

    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label 含有不允许的重解析点：$($item.FullName)"
        }

        if ($Recurse -and $item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
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

function Assert-RestoreProfileSyntax {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $tokens = $null
    $parseErrors = $null
    $content = [IO.File]::ReadAllText($Path)
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
        [string]$Path
    )

    $basePath = Resolve-RestorePath -Path $Path -Label '目录'
    $basePrefix = $basePath + [IO.Path]::DirectorySeparatorChar
    $inventory = [Collections.Generic.List[string]]::new()
    $files = @(Get-ChildItem -LiteralPath $basePath -File -Recurse -Force -ErrorAction Stop |
            Sort-Object -Property FullName)
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($basePrefix.Length)
        $inventory.Add(
            "$relativePath`t$([long]$file.Length)`t$(Get-RestoreSha256 -Path $file.FullName)"
        )
    }
    return @($inventory)
}

function ConvertFrom-RestoreManifestInventory {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $resolvedBase = Resolve-RestorePath -Path $BasePath -Label 'previous-install'
    $basePrefix = $resolvedBase + [IO.Path]::DirectorySeparatorChar
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $inventory = [Collections.Generic.List[string]]::new()
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
            [long]$lengthValue -lt 0) {
            throw "PreviousInstallFiles 的长度无效：$relativePath"
        }
        if ($sha256 -cnotmatch '^[A-F0-9]{64}$') {
            throw "PreviousInstallFiles 的 SHA256 无效：$relativePath"
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
    Assert-RestoreNoReparsePoint -Path $Path -Label $Label -Recurse
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
    }
    try {
        $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -ErrorAction Stop
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
        $moduleManifest = Import-PowerShellDataFile `
            -LiteralPath $moduleManifestPath `
            -ErrorAction Stop
    }
    catch {
        throw "$Label 的模块清单无法解析：$($_.Exception.Message)"
    }
    if ([string]$moduleManifest.RootModule -cne 'CodexOpenRouter.psm1' -or
        [string]$moduleManifest.GUID -cne 'be74dba0-28ed-4ba3-adff-f0fc0d107b39') {
        throw "$Label 的模块清单身份无效。"
    }
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
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination -PathType Container) {
        throw "目标路径需要是普通文件：$Destination"
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "源路径需要是普通文件：$Source"
    }
    Assert-RestoreNoReparsePoint -Path $Source -Label '源文件路径'
    Assert-RestoreNoReparsePoint -Path $Destination -Label '目标文件路径'
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Write-ToolkitBytesAtomic `
            -Path $Destination `
            -Bytes ([IO.File]::ReadAllBytes($Source))
    }
    else {
        Copy-ToolkitFileAtomic `
            -Source $Source `
            -Destination $Destination
    }
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
    Assert-RestoreNoReparsePoint -Path $Source -Label '目录复制源' -Recurse
    Assert-RestoreNoReparsePoint -Path $Destination -Label '目录复制目标' -Recurse
    if (@(Get-ChildItem `
            -LiteralPath $Destination `
            -Force `
            -ErrorAction Stop).Count -ne 0) {
        throw "目录复制目标必须为空：$Destination"
    }

    $resolvedSource = [IO.Path]::GetFullPath($Source)
    $resolvedDestination = [IO.Path]::GetFullPath($Destination)
    $sourcePrefix = $resolvedSource.TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    $directoryPairs = [Collections.Generic.List[object]]::new()
    $filePairs = [Collections.Generic.List[object]]::new()
    $directoryPairs.Add([pscustomobject]@{
        Source = $resolvedSource
        Destination = $resolvedDestination
    })

    foreach ($sourceDirectory in @(Get-ChildItem `
            -LiteralPath $resolvedSource `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction Stop | Sort-Object FullName)) {
        $relativePath = $sourceDirectory.FullName.Substring($sourcePrefix.Length)
        $targetDirectory = Join-Path $resolvedDestination $relativePath
        [void](New-Item `
            -ItemType Directory `
            -Path $targetDirectory `
            -ErrorAction Stop)
        $directoryPairs.Add([pscustomobject]@{
            Source = $sourceDirectory.FullName
            Destination = $targetDirectory
        })
    }

    foreach ($sourceFile in @(Get-ChildItem `
            -LiteralPath $resolvedSource `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop | Sort-Object FullName)) {
        $relativePath = $sourceFile.FullName.Substring($sourcePrefix.Length)
        $targetFile = Join-Path $resolvedDestination $relativePath
        Copy-ToolkitFileAtomic `
            -Source $sourceFile.FullName `
            -Destination $targetFile
        $filePairs.Add([pscustomobject]@{
            Source = $sourceFile.FullName
            Destination = $targetFile
        })
    }

    if ($IsWindows) {
        foreach ($pair in @($directoryPairs | Sort-Object {
                    $_.Destination.Length
                } -Descending)) {
            $sourceAcl = Get-Acl -LiteralPath $pair.Source -ErrorAction Stop
            Set-Acl `
                -LiteralPath $pair.Destination `
                -AclObject $sourceAcl `
                -ErrorAction Stop
            $targetAcl = Get-Acl `
                -LiteralPath $pair.Destination `
                -ErrorAction Stop
            if ($targetAcl.Sddl -cne $sourceAcl.Sddl) {
                throw "目录 ACL 复读校验失败：$($pair.Destination)"
            }
        }
        foreach ($pair in $filePairs) {
            $sourceAcl = Get-Acl -LiteralPath $pair.Source -ErrorAction Stop
            $targetAcl = Get-Acl -LiteralPath $pair.Destination -ErrorAction Stop
            if ($targetAcl.Sddl -cne $sourceAcl.Sddl) {
                throw "目录复制后的文件 ACL 校验失败：$($pair.Destination)"
            }
        }
    }
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
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -ErrorAction Stop
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
if ($schemaVersion -notin @(1, 2)) {
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
        -Recurse
}

$installExisted = $previousInstallExists
$manifestPreviousInstallInventory = @()
if ($schemaVersion -eq 2) {
    $manifestCodexHome = [string](Get-RestoreProperty `
            -InputObject $manifest `
            -Name 'CodexHome' `
            -Context 'schema 2 备份清单')
    $manifestProfilePath = [string](Get-RestoreProperty `
            -InputObject $manifest `
            -Name 'ProfilePath' `
            -Context 'schema 2 备份清单')
    $manifestInstallRoot = [string](Get-RestoreProperty `
            -InputObject $manifest `
            -Name 'InstallRoot' `
            -Context 'schema 2 备份清单')
    $manifestInstallExisted = Get-RestoreProperty `
        -InputObject $manifest `
        -Name 'InstallExisted' `
        -Context 'schema 2 备份清单'

    if (-not (Test-RestorePathEqual -Left $manifestCodexHome -Right $resolvedCodexHome)) {
        throw 'schema 2 清单中的 CodexHome 与恢复参数不一致。'
    }
    if (-not (Test-RestorePathEqual -Left $manifestProfilePath -Right $resolvedProfilePath)) {
        throw 'schema 2 清单中的 ProfilePath 与恢复参数不一致。'
    }
    if (-not (Test-RestorePathEqual -Left $manifestInstallRoot -Right $installRoot)) {
        throw 'schema 2 清单中的 InstallRoot 与推导路径不一致。'
    }
    if ($manifestInstallExisted -isnot [bool]) {
        throw 'schema 2 清单中的 InstallExisted 必须是布尔值。'
    }
    $installExisted = [bool]$manifestInstallExisted
    if ($installExisted -ne $previousInstallExists) {
        throw 'schema 2 清单中的 InstallExisted 与 previous-install 状态不一致。'
    }
    $previousInstallFilesValue = Get-RestoreProperty `
        -InputObject $manifest `
        -Name 'PreviousInstallFiles' `
        -Context 'schema 2 备份清单'
    $manifestPreviousInstallInventory = @(
        ConvertFrom-RestoreManifestInventory `
            -Entries @($previousInstallFilesValue) `
            -BasePath $previousInstallPath
    )
    if ($installExisted -and $manifestPreviousInstallInventory.Count -eq 0) {
        throw 'schema 2 清单中的 PreviousInstallFiles 不能为空。'
    }
    if (-not $installExisted -and $manifestPreviousInstallInventory.Count -ne 0) {
        throw 'schema 2 首次安装清单的 PreviousInstallFiles 必须为空。'
    }
}

if ($installExisted) {
    Assert-RestoreToolkitInstallOwnership `
        -Path $previousInstallPath `
        -ExpectedCodexHome $resolvedCodexHome `
        -ExpectedInstallRoot $installRoot `
        -ExpectedProfilePath $resolvedProfilePath `
        -Label 'previous-install'
    $previousInstallInventory = @(Get-RestoreDirectoryInventory -Path $previousInstallPath)
    if ($schemaVersion -eq 2) {
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
    }
    'config' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'config.toml'
        BackupRelativePath = 'config.bak'
    }
    'catalog' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'openrouter-model-catalog.json'
        BackupRelativePath = 'catalog.bak'
    }
    'active-cache' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'models_cache.json'
        BackupRelativePath = 'active-cache.bak'
    }
    'openai-cache' = [pscustomobject]@{
        Target = Join-Path $resolvedCodexHome 'models_cache.openai.json'
        BackupRelativePath = 'openai-cache.bak'
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
        $relativeBackupPath = [string](Get-RestoreProperty `
                -InputObject $entry `
                -Name 'BackupRelativePath' `
                -Context "schema 2 文件项 $name")
        if ($relativeBackupPath -cne [string]$expected.BackupRelativePath -or
            [IO.Path]::IsPathRooted($relativeBackupPath)) {
            throw "schema 2 文件项 $name 的 BackupRelativePath 无效。"
        }

        $shaValue = Get-RestoreProperty `
            -InputObject $entry `
            -Name 'Sha256' `
            -Context "schema 2 文件项 $name"
        if ([bool]$existed) {
            $expectedHash = [string]$shaValue
            if ($expectedHash -cnotmatch '^[A-F0-9]{64}$') {
                throw "schema 2 文件项 $name 的 Sha256 无效。"
            }
        }
        elseif ($null -ne $shaValue) {
            throw "schema 2 文件项 $name 在 Existed=false 时 Sha256 必须为 null。"
        }
    }

    $sourceHash = $null
    $sourceBackupPath = $null
    if ([bool]$existed) {
        if (-not (Test-Path -LiteralPath $expectedBackupPath -PathType Leaf)) {
            throw "备份文件缺失：$expectedBackupPath"
        }
        Assert-RestoreNoReparsePoint `
            -Path $expectedBackupPath `
            -Label "文件项 $name 的备份文件"
        $sourceHash = Get-RestoreSha256 -Path $expectedBackupPath
        if ($schemaVersion -eq 2 -and $sourceHash -cne $expectedHash) {
            throw "schema 2 文件项 $name 的 SHA256 校验失败。"
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
        StagedPath = $null
        CurrentExisted = $false
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
$restoreSucceeded = $false
$rollbackCompleted = $false

try {
    $currentInstallExists = Test-Path -LiteralPath $installRoot -PathType Container
    if (Test-Path -LiteralPath $installRoot) {
        if (-not $currentInstallExists) {
            throw "当前安装路径必须是目录：$installRoot"
        }
        Assert-RestoreToolkitInstallOwnership `
            -Path $installRoot `
            -ExpectedCodexHome $resolvedCodexHome `
            -ExpectedInstallRoot $installRoot `
            -ExpectedProfilePath $resolvedProfilePath `
            -Label '当前安装目录'
    }
    if (Test-Path -LiteralPath $transactionRoot) {
        throw "事务目录已存在：$transactionRoot"
    }
    [void](New-Item -ItemType Directory -Path $snapshotFilesRoot -Force -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path $stagedFilesRoot -Force -ErrorAction Stop)
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
                -Destination $stagedPath
            Assert-RestoreNoReparsePoint -Path $stagedPath -Label "暂存文件 $name"
            if ((Get-RestoreSha256 -Path $stagedPath) -cne $validated.SourceSha256) {
                throw "暂存文件 $name 的 SHA256 与预检结果不一致。"
            }
            $validated.StagedPath = $stagedPath
        }

        if (Test-Path -LiteralPath $validated.Target -PathType Leaf) {
            Assert-RestoreNoReparsePoint -Path $validated.Target -Label "受管目标 $name"
            $snapshotPath = Join-Path $snapshotFilesRoot "$name.current"
            $currentHash = Get-RestoreSha256 -Path $validated.Target
            Copy-ToolkitFileAtomic `
                -Source $validated.Target `
                -Destination $snapshotPath
            if ((Get-RestoreSha256 -Path $snapshotPath) -cne $currentHash) {
                throw "当前文件 $name 的事务快照校验失败。"
            }
            $validated.CurrentExisted = $true
            $validated.SnapshotPath = $snapshotPath
        }
    }

    if ($installExisted) {
        Assert-RestoreToolkitInstallOwnership `
            -Path $previousInstallPath `
            -ExpectedCodexHome $resolvedCodexHome `
            -ExpectedInstallRoot $installRoot `
            -ExpectedProfilePath $resolvedProfilePath `
            -Label 'previous-install'
        Assert-RestoreNoReparsePoint `
            -Path $previousInstallPath `
            -Label 'previous-install' `
            -Recurse
        [void](New-Item `
            -ItemType Directory `
            -Path $stagedInstallRoot `
            -ErrorAction Stop)
        Copy-RestoreDirectoryContents `
            -Source $previousInstallPath `
            -Destination $stagedInstallRoot
        Assert-RestoreNoReparsePoint `
            -Path $stagedInstallRoot `
            -Label '暂存 previous-install' `
            -Recurse
        $stagedInstallInventory = @(Get-RestoreDirectoryInventory -Path $stagedInstallRoot)
        Assert-RestoreInventoryEqual `
            -Expected $previousInstallInventory `
            -Actual $stagedInstallInventory `
            -Label '暂存 previous-install'
    }

    $commitStarted = $true
    if ($currentInstallExists) {
        if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
            throw '当前安装目录在提交前发生变化。'
        }
        Assert-RestoreNoReparsePoint -Path $installRoot -Label '当前安装目录' -Recurse
        Move-Item `
            -LiteralPath $installRoot `
            -Destination $currentInstallSnapshot `
            -Force `
            -ErrorAction Stop
        $currentInstallMoved = $true
    }
    elseif (Test-Path -LiteralPath $installRoot) {
        throw '当前安装路径在提交前发生变化。'
    }

    if ($installExisted) {
        [void](New-Item `
            -ItemType Directory `
            -Path $installRoot `
            -ErrorAction Stop)
        $restoredInstallCreated = $true
        Copy-RestoreDirectoryContents `
            -Source $stagedInstallRoot `
            -Destination $installRoot
    }

    $commitOrder = @('config', 'catalog', 'active-cache', 'openai-cache', 'profile')
    foreach ($name in $commitOrder) {
        $validated = $validatedFilesByName[$name]
        if ($validated.Existed) {
            Copy-RestoreFileAtomic `
                -Source $validated.StagedPath `
                -Destination $validated.Target
        }
        elseif (Test-Path -LiteralPath $validated.Target) {
            if (-not (Test-Path -LiteralPath $validated.Target -PathType Leaf)) {
                throw "受管目标在提交期间发生变化：$($validated.Target)"
            }
            Assert-RestoreNoReparsePoint `
                -Path $validated.Target `
                -Label "受管目标 $name"
            Remove-Item -LiteralPath $validated.Target -Force -ErrorAction Stop
        }
    }

    foreach ($name in $expectedFiles.Keys) {
        $validated = $validatedFilesByName[[string]$name]
        if ($validated.Existed) {
            if (-not (Test-Path -LiteralPath $validated.Target -PathType Leaf) -or
                (Get-RestoreSha256 -Path $validated.Target) -cne $validated.SourceSha256) {
                throw "恢复后的文件校验失败：$name"
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
        Assert-RestoreNoReparsePoint -Path $installRoot -Label '恢复后的安装目录' -Recurse
        $restoredInstallInventory = @(Get-RestoreDirectoryInventory -Path $installRoot)
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

    if ($commitStarted) {
        try {
            if ($restoredInstallCreated -and
                (Test-Path -LiteralPath $installRoot)) {
                if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
                    throw "回滚目标安装路径需要是目录：$installRoot"
                }
                Assert-RestoreNoReparsePoint `
                    -Path $installRoot `
                    -Label '回滚目标安装目录' `
                    -Recurse
                Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
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
                Move-Item `
                    -LiteralPath $currentInstallSnapshot `
                    -Destination $installRoot `
                    -Force `
                    -ErrorAction Stop
                $currentInstallMoved = $false
            }
        }
        catch {
            $rollbackErrors.Add("安装目录回滚失败：$($_.Exception.Message)")
        }

        foreach ($name in $expectedFiles.Keys) {
            $validated = $validatedFilesByName[[string]$name]
            try {
                if ($validated.CurrentExisted) {
                    if (-not (Test-Path -LiteralPath $validated.SnapshotPath -PathType Leaf)) {
                        throw '事务快照缺失。'
                    }
                    Copy-RestoreFileAtomic `
                        -Source $validated.SnapshotPath `
                        -Destination $validated.Target
                }
                elseif (Test-Path -LiteralPath $validated.Target) {
                    if (-not (Test-Path -LiteralPath $validated.Target -PathType Leaf)) {
                        throw '回滚目标已变成目录。'
                    }
                    Assert-RestoreNoReparsePoint `
                        -Path $validated.Target `
                        -Label "回滚目标 $name"
                    Remove-Item -LiteralPath $validated.Target -Force -ErrorAction Stop
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
    $canCleanTransaction = $restoreSucceeded -or
        -not $commitStarted -or
        $rollbackCompleted
    if ($transactionCreated -and
        $canCleanTransaction -and
        (Test-Path -LiteralPath $transactionRoot)) {
        try {
            Assert-RestoreNoReparsePoint -Path $transactionRoot -Label '事务目录' -Recurse
            Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction Stop
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
