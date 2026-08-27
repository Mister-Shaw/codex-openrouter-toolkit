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

function Get-InstallerDirectoryInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $basePath = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath($Path)
    )
    Assert-InstallerNoReparsePoint `
        -Path $basePath `
        -Name '待备份安装目录' `
        -Recurse
    $basePrefix = $basePath + [IO.Path]::DirectorySeparatorChar
    $inventory = [Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem `
        -LiteralPath $basePath `
        -File `
        -Recurse `
        -Force `
        -ErrorAction Stop | Sort-Object FullName)
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($basePrefix.Length)
        $inventory.Add([pscustomobject]@{
            RelativePath = $relativePath
            Length = [long]$file.Length
            Sha256 = (Get-FileHash `
                    -LiteralPath $file.FullName `
                    -Algorithm SHA256 `
                    -ErrorAction Stop).Hash.ToUpperInvariant()
        })
    }
    return @($inventory)
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
        $settings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
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
Assert-InstallerNoReparsePoint -Path $moduleSource -Name '模块源目录'

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
        -Recurse
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
    }
    try {
        $previousModuleManifest = Import-PowerShellDataFile `
            -LiteralPath $previousModuleManifestPath `
            -ErrorAction Stop
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

$configContent = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    [IO.File]::ReadAllText($configPath)
}
else {
    ''
}
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

    $managedFiles = @(
        [pscustomobject]@{
            Name = 'profile'
            Target = $resolvedProfilePath
            BackupRelativePath = 'profile.bak'
        },
        [pscustomobject]@{
            Name = 'config'
            Target = $configPath
            BackupRelativePath = 'config.bak'
        },
        [pscustomobject]@{
            Name = 'catalog'
            Target = $catalogPath
            BackupRelativePath = 'catalog.bak'
        },
        [pscustomobject]@{
            Name = 'active-cache'
            Target = $activeCachePath
            BackupRelativePath = 'active-cache.bak'
        },
        [pscustomobject]@{
            Name = 'openai-cache'
            Target = $openAICachePath
            BackupRelativePath = 'openai-cache.bak'
        }
    )
    $manifestFiles = [Collections.Generic.List[object]]::new()
    foreach ($managedFile in $managedFiles) {
        Assert-InstallerNoReparsePoint `
            -Path $managedFile.Target `
            -Name "受管文件 $($managedFile.Name)"
        $exists = Test-Path -LiteralPath $managedFile.Target -PathType Leaf
        if ((Test-Path -LiteralPath $managedFile.Target) -and -not $exists) {
            throw "受管文件路径已被目录占用：$($managedFile.Target)"
        }
        $sha256 = $null
        if ($exists) {
            $backupFile = Join-Path $backupPath $managedFile.BackupRelativePath
            Copy-ToolkitFileAtomic `
                -Source $managedFile.Target `
                -Destination $backupFile
            $sha256 = (Get-FileHash `
                    -LiteralPath $backupFile `
                    -Algorithm SHA256).Hash
        }
        $manifestFiles.Add([pscustomobject]@{
            Name = $managedFile.Name
            Target = [IO.Path]::GetFullPath($managedFile.Target)
            Existed = $exists
            BackupRelativePath = $managedFile.BackupRelativePath
            Sha256 = $sha256
        })
    }

    $manifest = [pscustomobject]@{
        Toolkit = 'codex-openrouter-toolkit'
        SchemaVersion = 2
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
        -Content ($manifest | ConvertTo-Json -Depth 10)

    $previousInstall = Join-Path $backupPath 'previous-install'
    $previousInstallReady = $false
    $activeInstallCreated = $false
    try {
        if ($installExisted) {
            Move-Item `
                -LiteralPath $installRoot `
                -Destination $previousInstall `
                -ErrorAction Stop
            $previousInstallReady = $true
        }
        [void](New-Item -ItemType Directory -Path $installRoot)
        $activeInstallCreated = $true
        Copy-Item `
            -LiteralPath $moduleSource `
            -Destination $moduleTarget `
            -Recurse `
            -ErrorAction Stop
        $sourcePrefix = [IO.Path]::GetFullPath($moduleSource).TrimEnd('\') + '\'
        $sourceFiles = @(Get-ChildItem `
            -LiteralPath $moduleSource `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop)
        $targetFiles = @(Get-ChildItem `
            -LiteralPath $moduleTarget `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop)
        if ($sourceFiles.Count -ne $targetFiles.Count) {
            throw '安装后的模块文件数量与源目录不一致。'
        }
        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($sourcePrefix.Length)
            $targetFile = Join-Path $moduleTarget $relativePath
            if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
                throw "安装后的模块缺少文件：$relativePath"
            }
            $sourceHash = (Get-FileHash `
                    -LiteralPath $sourceFile.FullName `
                    -Algorithm SHA256).Hash
            $targetHash = (Get-FileHash `
                    -LiteralPath $targetFile `
                    -Algorithm SHA256).Hash
            if ($sourceHash -cne $targetHash) {
                throw "安装后的模块文件校验失败：$relativePath"
            }
        }

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
        Write-ToolkitUtf8FileAtomic `
            -Path $settingsPath `
            -Content ($settings | ConvertTo-Json -Depth 10)

        $moduleManifest = Join-Path $moduleTarget 'CodexOpenRouter.psd1'
        Import-Module -Name $moduleManifest -Force
        Initialize-CodexOpenRouterConfig -ConfigPath $configPath | Out-Null

        $profileContent = if (
            Test-Path -LiteralPath $resolvedProfilePath -PathType Leaf
        ) {
            [IO.File]::ReadAllText($resolvedProfilePath)
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
        Write-ToolkitUtf8FileAtomic `
            -Path $resolvedProfilePath `
            -Content $newProfileContent

        if (-not $SkipCatalogRefresh) {
            if (Test-OpenRouterApiKey) {
                Update-OpenRouterModelCatalog `
                    -CatalogPath $catalogPath `
                    -RequiredModel $OpenRouterModel `
                    -MaximumAgeHours $CatalogMaximumAgeHours | Out-Null
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

        foreach ($entry in $manifestFiles) {
            try {
                if ($entry.Existed) {
                    $backupFile = Join-Path `
                        $backupPath `
                        $entry.BackupRelativePath
                    if (-not (
                        Test-Path -LiteralPath $backupFile -PathType Leaf
                    )) {
                        throw "缺少备份文件：$backupFile"
                    }
                    $actualHash = (Get-FileHash `
                            -LiteralPath $backupFile `
                            -Algorithm SHA256).Hash
                    if ($actualHash -cne [string]$entry.Sha256) {
                        throw "备份哈希不匹配：$backupFile"
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

        try {
            if ($previousInstallReady) {
                if (Test-Path -LiteralPath $installRoot -PathType Container) {
                    $failedInstall = Join-Path $backupPath 'failed-install'
                    Move-Item `
                        -LiteralPath $installRoot `
                        -Destination $failedInstall `
                        -ErrorAction Stop
                }
                if (-not (
                    Test-Path `
                        -LiteralPath $previousInstall `
                        -PathType Container
                )) {
                    throw 'previous-install 缺失。'
                }
                Move-Item `
                    -LiteralPath $previousInstall `
                    -Destination $installRoot `
                    -ErrorAction Stop
            }
            elseif (-not $installExisted -and
                $activeInstallCreated -and
                (Test-Path -LiteralPath $installRoot -PathType Container)) {
                Assert-InstallerNoReparsePoint `
                    -Path $installRoot `
                    -Name '失败安装目录'
                [IO.Directory]::Delete($installRoot, $true)
            }
        }
        catch {
            $rollbackErrors.Add("安装目录：$($_.Exception.Message)")
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
