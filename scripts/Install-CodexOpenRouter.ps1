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

function Get-InstallerTopLevelValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $firstTable = [regex]::Match($Content, '(?m)^[ \t]*\[')
    $topLevel = if ($firstTable.Success) {
        $Content.Substring(0, $firstTable.Index)
    }
    else {
        $Content
    }
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Key) +
        '[ \t]*=[ \t]*"([^"]*)"[ \t]*(?:#.*)?$'
    $match = [regex]::Match($topLevel, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

function Write-InstallerFileAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $temporaryPath = "$resolvedPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $Content,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $resolvedPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}
if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = [string]$PROFILE.CurrentUserCurrentHost
}

$resolvedCodexHome = [IO.Path]::GetFullPath($CodexHome)
$resolvedProfilePath = [IO.Path]::GetFullPath($ProfilePath)
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleSource = Join-Path $repositoryRoot 'src\CodexOpenRouter'
$installRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit'
$moduleTarget = Join-Path $installRoot 'CodexOpenRouter'
$settingsPath = Join-Path $installRoot 'settings.json'
$backupRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit-backups'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$backupPath = Join-Path $backupRoot $timestamp
$configPath = Join-Path $resolvedCodexHome 'config.toml'
$catalogPath = Join-Path $resolvedCodexHome 'openrouter-model-catalog.json'
$activeCachePath = Join-Path $resolvedCodexHome 'models_cache.json'
$openAICachePath = Join-Path $resolvedCodexHome 'models_cache.openai.json'

if (-not (Test-Path -LiteralPath $moduleSource -PathType Container)) {
    throw "找不到模块源文件：$moduleSource"
}
if (-not $PSCmdlet.ShouldProcess(
        "$resolvedProfilePath 和 $resolvedCodexHome",
        '安装 Codex OpenRouter Toolkit'
    )) {
    return
}

[void](New-Item -ItemType Directory -Path $resolvedCodexHome -Force)
[void](New-Item -ItemType Directory -Path $backupPath -Force)

$managedFiles = @(
    [pscustomobject]@{ Name = 'profile'; Target = $resolvedProfilePath },
    [pscustomobject]@{ Name = 'config'; Target = $configPath },
    [pscustomobject]@{ Name = 'catalog'; Target = $catalogPath },
    [pscustomobject]@{ Name = 'active-cache'; Target = $activeCachePath },
    [pscustomobject]@{ Name = 'openai-cache'; Target = $openAICachePath }
)
$manifestFiles = [Collections.Generic.List[object]]::new()
foreach ($managedFile in $managedFiles) {
    $exists = Test-Path -LiteralPath $managedFile.Target -PathType Leaf
    $backupFile = $null
    if ($exists) {
        $backupFile = Join-Path $backupPath "$($managedFile.Name).bak"
        Copy-Item -LiteralPath $managedFile.Target -Destination $backupFile
    }
    $manifestFiles.Add([pscustomobject]@{
        Name = $managedFile.Name
        Target = [IO.Path]::GetFullPath($managedFile.Target)
        Existed = $exists
        BackupFile = $backupFile
    })
}

$manifest = [pscustomobject]@{
    Toolkit = 'codex-openrouter-toolkit'
    SchemaVersion = 1
    CreatedAt = [DateTimeOffset]::Now.ToString('o')
    Files = @($manifestFiles)
}
Write-InstallerFileAtomic `
    -Path (Join-Path $backupPath 'manifest.json') `
    -Content ($manifest | ConvertTo-Json -Depth 10)

$previousInstall = $null
try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-InstallerFileAtomic -Path $configPath -Content ''
    }
    $configContent = [IO.File]::ReadAllText($configPath)
    $currentProvider = Get-InstallerTopLevelValue `
        -Content $configContent `
        -Key 'model_provider'
    $currentModel = Get-InstallerTopLevelValue -Content $configContent -Key 'model'
    $currentReasoning = Get-InstallerTopLevelValue `
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

    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        $previousInstall = Join-Path $backupPath 'previous-install'
        Move-Item -LiteralPath $installRoot -Destination $previousInstall
    }
    [void](New-Item -ItemType Directory -Path $installRoot -Force)
    Copy-Item -LiteralPath $moduleSource -Destination $moduleTarget -Recurse

    $settings = [pscustomobject]@{
        SchemaVersion = 1
        InstalledVersion = '0.1.0'
        InstalledAt = [DateTimeOffset]::Now.ToString('o')
        CodexHome = $resolvedCodexHome
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
    Write-InstallerFileAtomic `
        -Path $settingsPath `
        -Content ($settings | ConvertTo-Json -Depth 10)

    $manifestPath = Join-Path $moduleTarget 'CodexOpenRouter.psd1'
    Import-Module -Name $manifestPath -Force
    Initialize-CodexOpenRouterConfig -ConfigPath $configPath | Out-Null

    $profileContent = if (Test-Path -LiteralPath $resolvedProfilePath -PathType Leaf) {
        [IO.File]::ReadAllText($resolvedProfilePath)
    }
    else {
        ''
    }
    $markerPattern = '(?ms)^[ \t]*# >>> codex-openrouter-toolkit >>>.*?^[ \t]*# <<< codex-openrouter-toolkit <<<[ \t]*(?:\r?\n|$)'
    $profileContent = [regex]::Replace($profileContent, $markerPattern, '').TrimEnd()
    $legacyMarkerPattern = '(?ms)^[ \t]*# >>> Codex desktop provider shortcuts >>>.*?^[ \t]*# <<< Codex desktop provider shortcuts <<<[ \t]*(?:\r?\n|$)'
    $profileContent = [regex]::Replace(
        $profileContent,
        $legacyMarkerPattern,
        ''
    ).TrimEnd()
    $escapedManifestPath = $manifestPath.Replace("'", "''")
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
    Write-InstallerFileAtomic `
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

    if (-not $SkipProfileReload) {
        . $resolvedProfilePath
    }

    [pscustomobject]@{
        Installed = $true
        ModulePath = $manifestPath
        SettingsPath = $settingsPath
        ProfilePath = $resolvedProfilePath
        ConfigPath = $configPath
        BackupPath = $backupPath
        ApiKeyAvailable = Test-OpenRouterApiKey
        NextCommand = 'cxor'
    }
}
catch {
    foreach ($entry in $manifestFiles) {
        if ($entry.Existed -and
            (Test-Path -LiteralPath $entry.BackupFile -PathType Leaf)) {
            Copy-Item `
                -LiteralPath $entry.BackupFile `
                -Destination $entry.Target `
                -Force `
                -ErrorAction SilentlyContinue
        }
        elseif (-not $entry.Existed -and
            (Test-Path -LiteralPath $entry.Target -PathType Leaf)) {
            Remove-Item `
                -LiteralPath $entry.Target `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    if ($previousInstall -and
        (Test-Path -LiteralPath $previousInstall -PathType Container)) {
        if (Test-Path -LiteralPath $installRoot -PathType Container) {
            $failedInstall = Join-Path $backupPath 'failed-install'
            Move-Item `
                -LiteralPath $installRoot `
                -Destination $failedInstall `
                -ErrorAction SilentlyContinue
        }
        Move-Item `
            -LiteralPath $previousInstall `
            -Destination $installRoot `
            -ErrorAction SilentlyContinue
    }
    throw
}
