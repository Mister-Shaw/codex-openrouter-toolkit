#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$CodexHome,

    [string]$ProfilePath,

    [switch]$RemoveApiKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Codex OpenRouter Toolkit 仅支持 Windows。'
}

$script:ToolkitGuid = 'be74dba0-28ed-4ba3-adff-f0fc0d107b39'
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
    param([Parameter(Mandatory = $true)] [string]$Root)

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
        throw "模块目录含有未知内容，已拒绝自动删除：$Root"
    }
    try { $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath }
    catch { throw "模块清单无法解析：$($_.Exception.Message)" }
    if ([string]$manifest.RootModule -cne 'CodexOpenRouter.psm1' -or
        [string]$manifest.GUID -cne $script:ToolkitGuid) {
        throw "模块身份校验失败，已拒绝自动删除：$Root"
    }
    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root)
        ManifestPath = $manifestPath
        ManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        ModuleHash = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
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
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] [string]$ExpectedCodexHome
    )

    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    Assert-SafeDirectoryTree -Path $Root -Label '旧版工具包安装' -MaximumEntries 64
    $settingsPath = Join-Path $Root 'settings.json'
    $manifestPath = Join-Path $Root 'CodexOpenRouter\CodexOpenRouter.psd1'
    Assert-RegularFile -Path $settingsPath -Label '旧版 settings' -MaximumBytes 1MB
    Assert-RegularFile -Path $manifestPath -Label '旧版模块清单' -MaximumBytes 1MB
    try {
        $settings = [IO.File]::ReadAllText(
            $settingsPath,
            [Text.UTF8Encoding]::new($false, $true)
        ) | ConvertFrom-Json -ErrorAction Stop
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    }
    catch { throw "旧版安装无法验证：$($_.Exception.Message)" }
    if ([string]$manifest.GUID -cne $script:ToolkitGuid -or
        [string]$manifest.RootModule -cne 'CodexOpenRouter.psm1') {
        throw '旧版安装身份无效，已拒绝自动删除。'
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
    $digestLines = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Sort-Object FullName | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($Root, $_.FullName)
            "$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        })
    $digestBytes = [Text.Encoding]::UTF8.GetBytes($digestLines -join "`n")
    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root)
        ProfilePath = $recordedProfile
        Digest = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($digestBytes)
        )
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$documents = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::MyDocuments
)
if ([string]::IsNullOrWhiteSpace($documents)) {
    throw '无法定位当前用户的 Documents 目录。'
}
$moduleRoot = Join-Path $documents 'PowerShell\Modules\CodexOpenRouter'
$installedPackage = if (Test-Path -LiteralPath $moduleRoot) {
    Get-ValidatedModulePackage -Root $moduleRoot
}
else { $null }

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
$configPath = Join-Path $resolvedCodexHome 'config.toml'
$catalogPath = Join-Path $resolvedCodexHome 'openrouter-model-catalog.json'
$proxyStatePath = Join-Path $resolvedCodexHome 'openrouter-cache-proxy.json'
foreach ($managedFile in @($configPath, $catalogPath)) {
    if (Test-Path -LiteralPath $managedFile) {
        Assert-RegularFile -Path $managedFile -Label '受管 Codex 文件' -MaximumBytes 50MB
    }
}
if (Test-Path -LiteralPath $proxyStatePath) {
    Assert-RegularFile -Path $proxyStatePath `
        -Label '缓存代理状态文件' -MaximumBytes 16KB
}

$legacyRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit'
$legacyInfo = Get-LegacyInstallInfo `
    -Root $legacyRoot `
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

$sourceRoot = Join-Path $repositoryRoot 'src\CodexOpenRouter'
$sourcePackage = if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
    Get-ValidatedModulePackage -Root $sourceRoot
}
else { $null }
if (-not $sourcePackage) {
    throw '找不到可用于安全清理配置的 CodexOpenRouter 0.1.10 模块。'
}
$sourceData = Import-PowerShellDataFile -LiteralPath $sourcePackage.ManifestPath
$sourceExports = @($sourceData.FunctionsToExport)
if ([version]$sourceData.ModuleVersion -ne [version]'0.1.10' -or
    $sourceExports.Count -ne 2 -or
    $sourceExports -cnotcontains 'cx' -or
    $sourceExports -cnotcontains 'cxor') {
    throw '配置清理模块必须是 0.1.10，且只能导出 cx 与 cxor。'
}
$moduleManifest = $sourcePackage.ManifestPath

if (-not $PSCmdlet.ShouldProcess(
        "$moduleRoot、$configPath、$catalogPath 与 $proxyStatePath",
        '卸载 Codex OpenRouter Toolkit'
    )) {
    return
}

$module = Import-Module -Name $moduleManifest -Force -PassThru -ErrorAction Stop
$configChanged = $false
$mutex = $null
try {
    $mutex = & $module { param($TargetPath) Enter-CxMutex $TargetPath } $configPath
    $configChange = & $module {
        param($TargetPath)
        Get-CxConfigChange -Path $TargetPath -Mode Default
    } $configPath
    $configChanged = [string]$configChange.Content -cne
        [string]$configChange.OriginalContent

    foreach ($plan in $profilePlans) {
        $currentBytes = [IO.File]::ReadAllBytes($plan.Path)
        $currentHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($currentBytes)
        )
        if ($currentHash -cne $plan.InitialHash) {
            throw "PowerShell Profile 在卸载期间被外部修改：$($plan.Path)"
        }
        & $module {
            param($TargetPath, $TargetContent)
            Write-CxTextFileAtomic -Path $TargetPath -Content $TargetContent
        } $plan.Path $plan.Content
    }
    & $module { param($Change) Commit-CxConfigChange $Change } $configChange
    $proxyStopped = & $module {
        param($StatePath)
        Stop-CxOpenRouterProxy -StatePath $StatePath
    } $proxyStatePath
    $proxyStateRemoved = -not (Test-Path -LiteralPath $proxyStatePath)
    $catalogRemoved = $false
    if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
        $catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
        $catalogQuarantine = Join-Path $resolvedCodexHome (
            '.openrouter-model-catalog.remove-{0}-{1}.json' -f `
                $PID, [guid]::NewGuid().ToString('N')
        )
        try {
            [IO.File]::Move($catalogPath, $catalogQuarantine)
            if ((Get-FileHash -LiteralPath $catalogQuarantine -Algorithm SHA256).Hash -cne
                $catalogHash) {
                throw '模型目录在卸载移动期间发生变化。'
            }
            Remove-Item -LiteralPath $catalogQuarantine -Force
            $catalogRemoved = $true
        }
        catch {
            if ((Test-Path -LiteralPath $catalogQuarantine -PathType Leaf) -and
                -not (Test-Path -LiteralPath $catalogPath) -and
                (Get-FileHash -LiteralPath $catalogQuarantine -Algorithm SHA256).Hash -ceq
                    $catalogHash) {
                try { [IO.File]::Move($catalogQuarantine, $catalogPath) } catch { }
            }
            throw
        }
    }

    $moduleRemoved = $false
    if ($installedPackage -and (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
        $moduleQuarantine = Join-Path (Split-Path -Parent $moduleRoot) (
            '.CodexOpenRouter.remove-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N')
        )
        try {
            [IO.Directory]::Move($moduleRoot, $moduleQuarantine)
            $movedPackage = Get-ValidatedModulePackage -Root $moduleQuarantine
            if ($movedPackage.ManifestHash -cne $installedPackage.ManifestHash -or
                $movedPackage.ModuleHash -cne $installedPackage.ModuleHash) {
                throw '模块在卸载移动期间发生变化。'
            }
            Remove-Item -LiteralPath $moduleQuarantine -Recurse -Force
            $moduleRemoved = $true
        }
        catch {
            $failure = $_.Exception.Message
            $restored = $false
            if ((Test-Path -LiteralPath $moduleQuarantine -PathType Container) -and
                -not (Test-Path -LiteralPath $moduleRoot)) {
                try {
                    $remaining = Get-ValidatedModulePackage -Root $moduleQuarantine
                    if ($remaining.ManifestHash -ceq $installedPackage.ManifestHash -and
                        $remaining.ModuleHash -ceq $installedPackage.ModuleHash) {
                        [IO.Directory]::Move($moduleQuarantine, $moduleRoot)
                        $restored = $true
                    }
                }
                catch { $restored = $false }
            }
            if (-not $restored -and
                (Test-Path -LiteralPath $moduleQuarantine -PathType Container)) {
                throw "模块删除未完成；残留保留在 $moduleQuarantine。$failure"
            }
            throw
        }
    }

    $legacyRemoved = $false
    if ($legacyInfo -and (Test-Path -LiteralPath $legacyInfo.Root -PathType Container)) {
        $legacyQuarantine = Join-Path $resolvedCodexHome (
            '.codex-openrouter-toolkit.remove-{0}-{1}' -f `
                $PID, [guid]::NewGuid().ToString('N')
        )
        try {
            [IO.Directory]::Move($legacyInfo.Root, $legacyQuarantine)
            $movedLegacy = Get-LegacyInstallInfo `
                -Root $legacyQuarantine `
                -ExpectedCodexHome $resolvedCodexHome
            if ($movedLegacy.Digest -cne $legacyInfo.Digest) {
                throw '旧版安装在卸载移动期间发生变化。'
            }
            Remove-Item -LiteralPath $legacyQuarantine -Recurse -Force
            $legacyRemoved = $true
        }
        catch {
            $failure = $_.Exception.Message
            $restored = $false
            if ((Test-Path -LiteralPath $legacyQuarantine -PathType Container) -and
                -not (Test-Path -LiteralPath $legacyInfo.Root)) {
                try {
                    $remainingLegacy = Get-LegacyInstallInfo `
                        -Root $legacyQuarantine `
                        -ExpectedCodexHome $resolvedCodexHome
                    if ($remainingLegacy.Digest -ceq $legacyInfo.Digest) {
                        [IO.Directory]::Move($legacyQuarantine, $legacyInfo.Root)
                        $restored = $true
                    }
                }
                catch { $restored = $false }
            }
            if (-not $restored -and
                (Test-Path -LiteralPath $legacyQuarantine -PathType Container)) {
                throw "旧版安装删除未完成；残留保留在 $legacyQuarantine。$failure"
            }
            throw
        }
    }

    if ($RemoveApiKey) {
        [Environment]::SetEnvironmentVariable(
            'OPENROUTER_API_KEY',
            $null,
            [EnvironmentVariableTarget]::User
        )
        [Environment]::SetEnvironmentVariable(
            'OPENROUTER_API_KEY',
            $null,
            [EnvironmentVariableTarget]::Process
        )
    }

    $result = [pscustomobject]@{
        Uninstalled = $true
        ModuleRemoved = $moduleRemoved
        ConfigCleaned = $configChanged
        CatalogRemoved = $catalogRemoved
        ProxyStopped = [bool]$proxyStopped
        ProxyStateRemoved = $proxyStateRemoved
        ProfileMarkersRemoved = $profilePlans.Count
        LegacyInstallRemoved = $legacyRemoved
        ApiKeyRemoved = [bool]$RemoveApiKey
    }
}
finally {
    if ($null -ne $mutex) {
        & $module { param($Value) Exit-CxMutex $Value } $mutex
    }
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
}
$result
