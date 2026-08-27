#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$CodexHome,

    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Codex OpenRouter Toolkit 仅支持 Windows。'
}

$script:ToolkitGuid = 'be74dba0-28ed-4ba3-adff-f0fc0d107b39'
$script:ToolkitVersion = [version]'0.1.2'
$script:ProfileStartMarkers = @(
    '# >>> codex-openrouter-toolkit >>>',
    '# >>> Codex desktop provider shortcuts >>>'
)
$script:ProfileEndMarkers = @(
    '# <<< codex-openrouter-toolkit <<<',
    '# <<< Codex desktop provider shortcuts <<<'
)

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label 必须是完整绝对路径。"
    }
    try { return [IO.Path]::GetFullPath($Path) }
    catch { throw "$Label 无法规范化：$($_.Exception.Message)" }
}

function Test-PathEqual {
    param(
        [Parameter(Mandatory = $true)] [string]$Left,
        [Parameter(Mandatory = $true)] [string]$Right
    )

    return [string]::Equals(
        [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Left)),
        [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Right)),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-RegularFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Label,
        [long]$MaximumBytes = 5MB
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 不存在或不是普通文件：$Path"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label 不能是重解析点：$Path"
    }
    if ($item.Length -gt $MaximumBytes) {
        throw "$Label 超过 $MaximumBytes 字节限制：$Path"
    }
}

function Assert-SafeDirectoryTree {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Label,
        [int]$MaximumEntries = 64
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label 不存在或不是目录：$Path"
    }
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label 不能是重解析点：$Path"
    }
    $count = 1
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
        $count++
        if ($count -gt $MaximumEntries) {
            throw "$Label 超过 $MaximumEntries 项限制：$Path"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label 包含重解析点：$($item.FullName)"
        }
    }
}

function Get-ValidatedModulePackage {
    param(
        [Parameter(Mandatory = $true)] [string]$Root,
        [switch]$RequireRelease
    )

    Assert-SafeDirectoryTree -Path $Root -Label 'PowerShell 模块目录'
    $manifestPath = Join-Path $Root 'CodexOpenRouter.psd1'
    $modulePath = Join-Path $Root 'CodexOpenRouter.psm1'
    Assert-RegularFile -Path $manifestPath -Label '模块清单' -MaximumBytes 1MB
    Assert-RegularFile -Path $modulePath -Label '模块文件' -MaximumBytes 5MB

    $files = @(Get-ChildItem -LiteralPath $Root -Force -File)
    $directories = @(Get-ChildItem -LiteralPath $Root -Force -Directory)
    if ($directories.Count -ne 0 -or $files.Count -ne 2 -or
        @($files.Name | Where-Object {
                $_ -cnotin @('CodexOpenRouter.psd1', 'CodexOpenRouter.psm1')
            }).Count -ne 0) {
        throw "模块目录只能包含 CodexOpenRouter.psd1 与 CodexOpenRouter.psm1：$Root"
    }

    try { $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath }
    catch { throw "模块清单无法解析：$($_.Exception.Message)" }
    if ([string]$manifest.RootModule -cne 'CodexOpenRouter.psm1' -or
        [string]$manifest.GUID -cne $script:ToolkitGuid) {
        throw "模块身份校验失败：$Root"
    }
    if ($RequireRelease) {
        $exports = @($manifest.FunctionsToExport)
        if ([version]$manifest.ModuleVersion -ne $script:ToolkitVersion -or
            $exports.Count -ne 2 -or
            $exports -cnotcontains 'cx' -or
            $exports -cnotcontains 'cxor') {
            throw '待安装模块必须是 0.1.2，且只能导出 cx 与 cxor。'
        }
    }

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $modulePath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        throw "模块文件包含 $(@($parseErrors).Count) 个 PowerShell 语法错误。"
    }

    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root)
        ManifestPath = $manifestPath
        ModulePath = $modulePath
        ManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        ModuleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
        Version = [version]$manifest.ModuleVersion
    }
}

function Remove-ProfileCommentBlock {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content,
        [Parameter(Mandatory = $true)] [string]$StartMarker,
        [Parameter(Mandatory = $true)] [string]$EndMarker,
        [Parameter(Mandatory = $true)] [string]$Label
    )

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        throw "$Label 含有 PowerShell 语法错误，未修改。"
    }
    $comments = @($tokens | Where-Object {
            $_.Kind -eq [Management.Automation.Language.TokenKind]::Comment
        })
    $starts = @($comments | Where-Object { $_.Text.Trim() -ceq $StartMarker })
    $ends = @($comments | Where-Object { $_.Text.Trim() -ceq $EndMarker })
    if ($starts.Count -eq 0 -and $ends.Count -eq 0) { return $Content }
    if ($starts.Count -ne 1 -or $ends.Count -ne 1 -or
        $starts[0].Extent.StartOffset -ge $ends[0].Extent.StartOffset) {
        throw "$Label 的旧工具包标记不完整或重复，未修改。"
    }

    foreach ($token in @($starts[0], $ends[0])) {
        $lineStart = $Content.LastIndexOf(
            "`n",
            [Math]::Max(0, $token.Extent.StartOffset - 1)
        )
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
        $prefix = $Content.Substring(
            $lineStart,
            $token.Extent.StartOffset - $lineStart
        )
        if ($prefix -cnotmatch '\A[ \t]*\z') {
            throw "$Label 的旧工具包标记必须独占一行，未修改。"
        }
    }

    $removeStart = $Content.LastIndexOf(
        "`n",
        [Math]::Max(0, $starts[0].Extent.StartOffset - 1)
    )
    if ($removeStart -lt 0) { $removeStart = 0 } else { $removeStart++ }
    $nextNewline = $Content.IndexOf("`n", $ends[0].Extent.EndOffset)
    $removeEnd = if ($nextNewline -lt 0) {
        $Content.Length
    }
    else {
        $nextNewline + 1
    }
    return $Content.Remove($removeStart, $removeEnd - $removeStart)
}

function Get-ProfilePlan {
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Assert-RegularFile -Path $Path -Label 'PowerShell Profile' -MaximumBytes 5MB
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) { 3 } else { 0 }
    try {
        $content = [Text.UTF8Encoding]::new($false, $true).GetString(
            $bytes,
            $offset,
            $bytes.Length - $offset
        )
    }
    catch { throw "PowerShell Profile 不是有效 UTF-8：$Path" }

    $updated = $content
    for ($index = 0; $index -lt $script:ProfileStartMarkers.Count; $index++) {
        $updated = Remove-ProfileCommentBlock `
            -Content $updated `
            -StartMarker $script:ProfileStartMarkers[$index] `
            -EndMarker $script:ProfileEndMarkers[$index] `
            -Label $Path
    }
    if ($updated -ceq $content) { return $null }
    return [pscustomobject]@{
        Path = $Path
        InitialHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)
        )
        Content = $updated
    }
}

function Get-LegacyInstallInfo {
    param(
        [Parameter(Mandatory = $true)] [string]$InstallRoot,
        [Parameter(Mandatory = $true)] [string]$ExpectedCodexHome
    )

    if (-not (Test-Path -LiteralPath $InstallRoot)) { return $null }
    Assert-SafeDirectoryTree -Path $InstallRoot -Label '旧版工具包安装' -MaximumEntries 64
    $settingsPath = Join-Path $InstallRoot 'settings.json'
    $manifestPath = Join-Path $InstallRoot 'CodexOpenRouter\CodexOpenRouter.psd1'
    Assert-RegularFile -Path $settingsPath -Label '旧版 settings' -MaximumBytes 1MB
    Assert-RegularFile -Path $manifestPath -Label '旧版模块清单' -MaximumBytes 1MB
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
        $settings = [IO.File]::ReadAllText(
            $settingsPath,
            [Text.UTF8Encoding]::new($false, $true)
        ) | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "旧版安装无法验证：$($_.Exception.Message)" }
    if ([string]$manifest.RootModule -cne 'CodexOpenRouter.psm1' -or
        [string]$manifest.GUID -cne $script:ToolkitGuid) {
        throw '旧版安装的模块身份无效，已拒绝自动删除。'
    }
    if ($settings.PSObject.Properties['Toolkit'] -and
        [string]$settings.Toolkit -cne 'codex-openrouter-toolkit') {
        throw '旧版安装的 Toolkit 标识无效，已拒绝自动删除。'
    }
    $recordedHome = Resolve-AbsolutePath `
        -Path ([string]$settings.CodexHome) `
        -Label '旧版 settings.CodexHome'
    if (-not (Test-PathEqual -Left $recordedHome -Right $ExpectedCodexHome)) {
        throw '旧版安装记录的 CodexHome 与当前目标不一致。'
    }
    $recordedProfile = Resolve-AbsolutePath `
        -Path ([string]$settings.ProfilePath) `
        -Label '旧版 settings.ProfilePath'
    if ([IO.Path]::GetExtension($recordedProfile) -cne '.ps1') {
        throw '旧版安装记录的 ProfilePath 无效。'
    }
    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($InstallRoot)
        ProfilePath = $recordedProfile
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $repositoryRoot 'src\CodexOpenRouter'
$sourcePackage = Get-ValidatedModulePackage -Root $sourceRoot -RequireRelease

$documents = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::MyDocuments
)
if ([string]::IsNullOrWhiteSpace($documents)) {
    throw '无法定位当前用户的 Documents 目录。'
}
$moduleParent = [IO.Path]::GetFullPath((Join-Path $documents 'PowerShell\Modules'))
$moduleRoot = Join-Path $moduleParent 'CodexOpenRouter'
$moduleSearchPaths = @($env:PSModulePath -split [IO.Path]::PathSeparator |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) })
if (-not ($moduleSearchPaths | Where-Object {
            Test-PathEqual -Left $_ -Right $moduleParent
        })) {
    throw "当前用户模块目录不在 PSModulePath 中，无法保证自动加载：$moduleParent"
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $userCodexHome = [Environment]::GetEnvironmentVariable(
        'CODEX_HOME',
        [EnvironmentVariableTarget]::User
    )
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($userCodexHome)) {
        $userCodexHome
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}
$resolvedCodexHome = Resolve-AbsolutePath -Path $CodexHome -Label 'CodexHome'
$volumeRoot = [IO.Path]::GetPathRoot($resolvedCodexHome)
if (Test-PathEqual -Left $resolvedCodexHome -Right $volumeRoot) {
    throw 'CodexHome 不能是卷根目录。'
}
$legacyRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit'
$legacyInfo = Get-LegacyInstallInfo `
    -InstallRoot $legacyRoot `
    -ExpectedCodexHome $resolvedCodexHome

$defaultProfile = Resolve-AbsolutePath `
    -Path ([string]$PROFILE.CurrentUserCurrentHost) `
    -Label 'PowerShell Profile'
$requestedProfile = if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $null
}
else {
    $resolved = Resolve-AbsolutePath -Path $ProfilePath -Label 'ProfilePath'
    if ([IO.Path]::GetExtension($resolved) -cne '.ps1') {
        throw 'ProfilePath 必须指向 .ps1 文件。'
    }
    $resolved
}
if ($legacyInfo -and
    -not (Test-PathEqual -Left $legacyInfo.ProfilePath -Right $defaultProfile) -and
    ($null -eq $requestedProfile -or
        -not (Test-PathEqual `
            -Left $legacyInfo.ProfilePath `
            -Right $requestedProfile))) {
    throw "旧版使用了自定义 ProfilePath；请重新运行并传入 -ProfilePath '$($legacyInfo.ProfilePath)'。"
}

$profilePaths = [Collections.Generic.List[string]]::new()
foreach ($candidate in @(
        $defaultProfile,
        $requestedProfile,
        $(if ($legacyInfo) { $legacyInfo.ProfilePath } else { $null })
    )) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (-not ($profilePaths | Where-Object {
                Test-PathEqual -Left $_ -Right $candidate
            })) {
        $profilePaths.Add($candidate)
    }
}
$profilePlans = @($profilePaths | ForEach-Object { Get-ProfilePlan -Path $_ } |
        Where-Object { $null -ne $_ })

$existingPackage = if (Test-Path -LiteralPath $moduleRoot) {
    Get-ValidatedModulePackage -Root $moduleRoot
}
else { $null }
$packageCurrent = $existingPackage -and
    $existingPackage.ManifestHash -ceq $sourcePackage.ManifestHash -and
    $existingPackage.ModuleHash -ceq $sourcePackage.ModuleHash

$allowedCommandModulePaths = [Collections.Generic.List[string]]::new()
if ($existingPackage) { $allowedCommandModulePaths.Add($existingPackage.ModulePath) }
if ($legacyInfo) {
    $allowedCommandModulePaths.Add((Join-Path `
            $legacyInfo.Root `
            'CodexOpenRouter\CodexOpenRouter.psm1'))
}
foreach ($commandName in @('cx', 'cxor')) {
    foreach ($command in @(Get-Command -Name $commandName -All -ErrorAction SilentlyContinue)) {
        $commandModulePath = if ($command.Module) {
            [string]$command.Module.Path
        }
        else { '' }
        $isOwnedCommand = -not [string]::IsNullOrWhiteSpace($commandModulePath) -and
            [bool]($allowedCommandModulePaths | Where-Object {
                    Test-PathEqual -Left $_ -Right $commandModulePath
                })
        if (-not $isOwnedCommand) {
            throw "命令 $commandName 已被其他函数、别名或程序占用。请先处理 Get-Command $commandName -All 显示的冲突。"
        }
    }
}

if (-not $PSCmdlet.ShouldProcess(
        "$moduleRoot、旧版 Profile 标记与 $legacyRoot",
        '安装 Codex OpenRouter Toolkit 0.1.2'
    )) {
    return
}

[void](New-Item -ItemType Directory -Path $moduleParent -Force)
$previousRoot = $null
if (-not $packageCurrent) {
    $stagingRoot = Join-Path $moduleParent (
        '.CodexOpenRouter.install-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N')
    )
    [void](New-Item -ItemType Directory -Path $stagingRoot -ErrorAction Stop)
    try {
        [IO.File]::Copy(
            $sourcePackage.ManifestPath,
            (Join-Path $stagingRoot 'CodexOpenRouter.psd1'),
            $false
        )
        [IO.File]::Copy(
            $sourcePackage.ModulePath,
            (Join-Path $stagingRoot 'CodexOpenRouter.psm1'),
            $false
        )
        $stagedPackage = Get-ValidatedModulePackage -Root $stagingRoot -RequireRelease
        if ($stagedPackage.ManifestHash -cne $sourcePackage.ManifestHash -or
            $stagedPackage.ModuleHash -cne $sourcePackage.ModuleHash) {
            throw '暂存模块与源模块摘要不一致。'
        }

        Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
        if ($existingPackage) {
            $previousRoot = Join-Path $moduleParent (
                '.CodexOpenRouter.previous-{0}-{1}' -f `
                    $PID, [guid]::NewGuid().ToString('N')
            )
            [IO.Directory]::Move($moduleRoot, $previousRoot)
        }
        try {
            [IO.Directory]::Move($stagingRoot, $moduleRoot)
            $installedPackage = Get-ValidatedModulePackage `
                -Root $moduleRoot `
                -RequireRelease
        }
        catch {
            if (Test-Path -LiteralPath $moduleRoot -PathType Container) {
                Remove-Item -LiteralPath $moduleRoot -Recurse -Force
            }
            if ($previousRoot -and
                (Test-Path -LiteralPath $previousRoot -PathType Container) -and
                -not (Test-Path -LiteralPath $moduleRoot)) {
                [IO.Directory]::Move($previousRoot, $moduleRoot)
                $previousRoot = $null
            }
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}
else {
    $installedPackage = $existingPackage
}

$module = Import-Module `
    -Name $installedPackage.ManifestPath `
    -Force `
    -PassThru `
    -ErrorAction Stop
try {
    foreach ($plan in $profilePlans) {
        $currentBytes = [IO.File]::ReadAllBytes($plan.Path)
        $currentHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($currentBytes)
        )
        if ($currentHash -cne $plan.InitialHash) {
            throw "PowerShell Profile 在安装期间被外部修改：$($plan.Path)"
        }
        & $module {
            param($TargetPath, $TargetContent)
            Write-CxTextFileAtomic -Path $TargetPath -Content $TargetContent
        } $plan.Path $plan.Content
    }
}
catch {
    throw "模块已安装，但旧 Profile 标记清理失败：$($_.Exception.Message)"
}

$legacyRemoved = $false
if ($legacyInfo -and (Test-Path -LiteralPath $legacyInfo.Root -PathType Container)) {
    $legacyQuarantine = Join-Path $resolvedCodexHome (
        '.codex-openrouter-toolkit.remove-{0}-{1}' -f `
            $PID, [guid]::NewGuid().ToString('N')
    )
    try {
        Assert-SafeDirectoryTree `
            -Path $legacyInfo.Root `
            -Label '旧版工具包安装' `
            -MaximumEntries 64
        [IO.Directory]::Move($legacyInfo.Root, $legacyQuarantine)
        Remove-Item -LiteralPath $legacyQuarantine -Recurse -Force
        $legacyRemoved = $true
    }
    catch {
        Write-Warning "0.1.2 已安装，但旧版安装未能完全清理：$($_.Exception.Message)"
    }
}

if ($previousRoot -and (Test-Path -LiteralPath $previousRoot -PathType Container)) {
    try { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
    catch { Write-Warning "旧模块副本未能删除：$previousRoot。$($_.Exception.Message)" }
}

[pscustomobject]@{
    Installed = $true
    InstalledVersion = '0.1.2'
    ModulePath = $installedPackage.ManifestPath
    AutoLoadEnabled = $true
    ProfileMarkersRemoved = $profilePlans.Count
    LegacyInstallRemoved = $legacyRemoved
    NextCommand = 'cxor -SetKey'
}
