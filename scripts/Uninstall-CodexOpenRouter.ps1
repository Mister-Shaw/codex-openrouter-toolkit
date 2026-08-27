[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexHome,

    [switch]$KeepCurrentProvider,

    [switch]$RemoveApiKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}
$resolvedCodexHome = [IO.Path]::GetFullPath($CodexHome)
$installRoot = Join-Path $resolvedCodexHome 'codex-openrouter-toolkit'
$settingsPath = Join-Path $installRoot 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "找不到已安装的工具包设置：$settingsPath"
}
$settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
$profilePath = [IO.Path]::GetFullPath([string]$settings.ProfilePath)
$moduleManifest = Join-Path $installRoot 'CodexOpenRouter\CodexOpenRouter.psd1'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$uninstallBackup = Join-Path `
    $resolvedCodexHome `
    "codex-openrouter-toolkit-uninstalled\$timestamp"

if (-not $PSCmdlet.ShouldProcess($installRoot, '卸载 Codex OpenRouter Toolkit')) {
    return
}
[void](New-Item -ItemType Directory -Path $uninstallBackup -Force)
if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    Copy-Item `
        -LiteralPath $profilePath `
        -Destination (Join-Path $uninstallBackup 'profile-before-uninstall.bak')
}
if (Test-Path -LiteralPath ([string]$settings.ConfigPath) -PathType Leaf) {
    Copy-Item `
        -LiteralPath ([string]$settings.ConfigPath) `
        -Destination (Join-Path $uninstallBackup 'config-before-uninstall.bak')
}

if (-not $KeepCurrentProvider -and
    (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
    Import-Module -Name $moduleManifest -Force
    Set-CodexDesktopModelConfig `
        -Model ([string]$settings.OpenAIModel) `
        -Provider 'openai' `
        -ReasoningEffort ([string]$settings.OpenAIReasoningEffort) `
        -ConfigPath ([string]$settings.ConfigPath) | Out-Null
}

if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
    $profileContent = [IO.File]::ReadAllText($profilePath)
    $markerPattern = '(?ms)^[ \t]*# >>> codex-openrouter-toolkit >>>.*?^[ \t]*# <<< codex-openrouter-toolkit <<<[ \t]*(?:\r?\n|$)'
    $newProfileContent = [regex]::Replace(
        $profileContent,
        $markerPattern,
        ''
    ).TrimEnd()
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
    $temporaryProfile = "$profilePath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText(
            $temporaryProfile,
            $newProfileContent,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item `
            -LiteralPath $temporaryProfile `
            -Destination $profilePath `
            -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryProfile) {
            Remove-Item -LiteralPath $temporaryProfile -Force -ErrorAction SilentlyContinue
        }
    }
}

Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
$movedInstall = Join-Path $uninstallBackup 'installed-files'
Move-Item -LiteralPath $installRoot -Destination $movedInstall

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

[pscustomobject]@{
    Uninstalled = $true
    RestoredOpenAIProvider = -not $KeepCurrentProvider
    ApiKeyRemoved = [bool]$RemoveApiKey
    RecoveryPath = $uninstallBackup
}
