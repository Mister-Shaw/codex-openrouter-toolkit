[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleManifest = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\CodexOpenRouter.psd1'
$installerPath = Join-Path `
    $repositoryRoot `
    'scripts\Install-CodexOpenRouter.ps1'
$changelogPath = Join-Path $repositoryRoot 'CHANGELOG.md'
$promptPath = Join-Path `
    $repositoryRoot `
    'src\CodexOpenRouter\lightweight-agent-prompt.txt'
$tempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "codex-openrouter-toolkit-tests-$([Guid]::NewGuid().ToString('N'))"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "ASSERTION FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

try {
    [void](New-Item -ItemType Directory -Path $tempRoot -Force)

    $scripts = @(Get-ChildItem -LiteralPath $repositoryRoot `
        -Recurse `
        -File `
        -Include '*.ps1', '*.psm1', '*.psd1')
    foreach ($script in $scripts) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-Equal `
            -Actual $parseErrors.Count `
            -Expected 0 `
            -Message "PowerShell parse: $($script.FullName)"
    }

    $moduleVersion = (Import-PowerShellDataFile `
        -LiteralPath $moduleManifest).ModuleVersion.ToString()
    Assert-Equal `
        -Actual $moduleVersion `
        -Expected '0.1.1' `
        -Message 'Module version'
    $installerText = [IO.File]::ReadAllText($installerPath)
    Assert-True `
        -Condition $installerText.Contains("InstalledVersion = '$moduleVersion'") `
        -Message 'Installer version matches module manifest'
    $changelogText = [IO.File]::ReadAllText($changelogPath)
    Assert-True `
        -Condition $changelogText.Contains("## $moduleVersion -") `
        -Message 'Changelog version matches module manifest'

    $textFiles = @(Get-ChildItem -LiteralPath $repositoryRoot `
        -Recurse `
        -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1', '.md', '.txt', '.json', '.yml') })
    $secretPatterns = @(
        'sk-or-[A-Za-z0-9._-]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'gh[pousr]_[A-Za-z0-9_]{20,}',
        'AKIA[0-9A-Z]{16}'
    )
    foreach ($file in $textFiles) {
        $content = [IO.File]::ReadAllText($file.FullName)
        foreach ($pattern in $secretPatterns) {
            Assert-True `
                -Condition (-not [regex]::IsMatch($content, $pattern)) `
                -Message "Secret scan: $($file.FullName)"
        }
    }
    $privacyNeedles = [Collections.Generic.List[string]]::new()
    $privacyNeedles.Add(('C:' + '\Users\'))
    $runtimeUserName = [Environment]::UserName
    if (-not [string]::IsNullOrWhiteSpace($runtimeUserName) -and
        $runtimeUserName.Length -ge 3) {
        $privacyNeedles.Add($runtimeUserName)
    }
    $runtimeUserProfile = [Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($runtimeUserProfile)) {
        $privacyNeedles.Add($runtimeUserProfile)
    }
    foreach ($file in $textFiles) {
        $content = [IO.File]::ReadAllText($file.FullName)
        foreach ($needle in $privacyNeedles) {
            Assert-True `
                -Condition (-not $content.Contains($needle)) `
                -Message "Privacy scan: $($file.FullName)"
        }
    }

    Import-Module -Name $moduleManifest -Force
    $expectedPrompt = [IO.File]::ReadAllText($promptPath).Trim()
    Assert-True `
        -Condition ($expectedPrompt.Length -ge 500 -and $expectedPrompt.Length -le 2000) `
        -Message 'Lightweight prompt length'
    Assert-True `
        -Condition (-not $expectedPrompt.Contains('Codex CLI')) `
        -Message 'Lightweight prompt identity'

    foreach ($fixtureName in @('catalog-modern.json', 'catalog-legacy.json')) {
        $fixtureSource = Join-Path $PSScriptRoot "fixtures\$fixtureName"
        $fixtureTarget = Join-Path $tempRoot $fixtureName
        Copy-Item -LiteralPath $fixtureSource -Destination $fixtureTarget
        $changed = Set-OpenRouterAgentInstructions -Path $fixtureTarget
        $changedAgain = Set-OpenRouterAgentInstructions -Path $fixtureTarget
        Assert-True -Condition $changed -Message "$fixtureName first prompt rewrite"
        Assert-True -Condition (-not $changedAgain) -Message "$fixtureName idempotence"
        Assert-True `
            -Condition (Test-CodexModelCatalog `
                -Path $fixtureTarget `
                -RequiredModel 'anthropic/claude-opus-5' `
                -MinimumModelCount 1) `
            -Message "$fixtureName catalog validation"

        $catalog = [IO.File]::ReadAllText($fixtureTarget) | ConvertFrom-Json
        foreach ($model in @($catalog.models)) {
            $actualPrompt = if ($null -ne $model.PSObject.Properties['base_instructions']) {
                [string]$model.base_instructions
            }
            else {
                [string]$model.model_messages.instructions_template
            }
            Assert-Equal `
                -Actual $actualPrompt `
                -Expected $expectedPrompt `
                -Message "$fixtureName prompt equality"
        }
    }

    $duplicateCatalog = Join-Path $tempRoot 'catalog-duplicate.json'
    $duplicate = [pscustomobject]@{
        models = @(
            [pscustomobject]@{
                slug = 'duplicate/model'
                base_instructions = 'one'
            },
            [pscustomobject]@{
                slug = 'duplicate/model'
                base_instructions = 'two'
            }
        )
    }
    [IO.File]::WriteAllText(
        $duplicateCatalog,
        ($duplicate | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-True `
        -Condition (-not (Test-CodexModelCatalog `
            -Path $duplicateCatalog `
            -MinimumModelCount 1)) `
        -Message 'Duplicate slug rejection'

    $configPath = Join-Path $tempRoot 'config.toml'
    [IO.File]::WriteAllText(
        $configPath,
        "model = `"gpt-5.6-sol`"`r`nmodel_reasoning_effort = `"xhigh`"`r`n`r`n[features]`r`nexample = true`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    Initialize-CodexOpenRouterConfig -ConfigPath $configPath | Out-Null
    Initialize-CodexOpenRouterConfig -ConfigPath $configPath | Out-Null
    $config = [IO.File]::ReadAllText($configPath)
    Assert-Equal `
        -Actual ([regex]::Matches($config, '(?m)^\[model_providers\.openrouter\]\r?$').Count) `
        -Expected 1 `
        -Message 'Provider table idempotence'
    Assert-True -Condition $config.Contains('[features]') -Message 'Unrelated TOML table preserved'

    $modernCatalog = Join-Path $tempRoot 'catalog-modern.json'
    Set-CodexDesktopModelConfig `
        -Model 'anthropic/claude-opus-5' `
        -Provider openrouter `
        -ReasoningEffort high `
        -ModelCatalogPath $modernCatalog `
        -ConfigPath $configPath `
        -SkipBackup | Out-Null
    $config = [IO.File]::ReadAllText($configPath)
    Assert-True -Condition $config.Contains('model_provider = "openrouter"') -Message 'OpenRouter switch config'
    Assert-True -Condition $config.Contains('[features]') -Message 'TOML table preserved after switch'
    Set-CodexDesktopModelConfig `
        -Model 'gpt-5.6-sol' `
        -Provider openai `
        -ReasoningEffort xhigh `
        -ConfigPath $configPath `
        -SkipBackup | Out-Null
    $config = [IO.File]::ReadAllText($configPath)
    Assert-True `
        -Condition (-not $config.Contains('model_provider = "openrouter"')) `
        -Message 'OpenAI switch removes top-level provider override'

    $installCodexHome = Join-Path $tempRoot 'portable home\.codex'
    $installProfile = Join-Path $tempRoot 'PowerShell Profile\profile.ps1'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $installCodexHome) -Force)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $installProfile) -Force)
    [void](New-Item -ItemType Directory -Path $installCodexHome -Force)
    [IO.File]::WriteAllText(
        (Join-Path $installCodexHome 'config.toml'),
        "model = `"gpt-5.6-sol`"`r`nmodel_reasoning_effort = `"xhigh`"`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $installProfile,
        "function Existing-Helper { 'preserved' }`r`n`r`n# >>> Codex desktop provider shortcuts >>>`r`nfunction cx { 'legacy' }`r`n# <<< Codex desktop provider shortcuts <<<`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $installScript = Join-Path $repositoryRoot 'scripts\Install-CodexOpenRouter.ps1'
    foreach ($attempt in 1..2) {
        & $installScript `
            -CodexHome $installCodexHome `
            -ProfilePath $installProfile `
            -SkipCatalogRefresh `
            -SkipProfileReload | Out-Null
    }
    $installedProfile = [IO.File]::ReadAllText($installProfile)
    Assert-Equal `
        -Actual ([regex]::Matches($installedProfile, '# >>> codex-openrouter-toolkit >>>').Count) `
        -Expected 1 `
        -Message 'Installer profile marker idempotence'
    Assert-True `
        -Condition $installedProfile.Contains('Existing-Helper') `
        -Message 'Installer preserves existing profile'
    Assert-True `
        -Condition (-not $installedProfile.Contains('# >>> Codex desktop provider shortcuts >>>')) `
        -Message 'Installer removes the backed-up legacy managed block'
    Assert-True `
        -Condition (Test-Path -LiteralPath (Join-Path $installCodexHome 'codex-openrouter-toolkit\settings.json')) `
        -Message 'Installer writes settings'

    $uninstallScript = Join-Path $repositoryRoot 'scripts\Uninstall-CodexOpenRouter.ps1'
    & $uninstallScript `
        -CodexHome $installCodexHome `
        -ProfilePath $installProfile `
        -KeepCurrentProvider | Out-Null
    $uninstalledProfile = [IO.File]::ReadAllText($installProfile)
    Assert-True `
        -Condition (-not $uninstalledProfile.Contains('# >>> codex-openrouter-toolkit >>>')) `
        -Message 'Uninstaller removes managed marker'
    Assert-True `
        -Condition $uninstalledProfile.Contains('Existing-Helper') `
        -Message 'Uninstaller preserves existing profile'

    & (Join-Path $PSScriptRoot 'Security-Tests.ps1')

    Write-Host "All tests passed: $($scripts.Count) PowerShell files parsed; catalog, config, security, install, restore, rollback, privacy, and uninstall checks succeeded."
}
finally {
    Remove-Module CodexOpenRouter -Force -ErrorAction SilentlyContinue
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith(
            $systemTemp,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Test-Path -LiteralPath $resolvedTempRoot -PathType Container)) {
        [IO.Directory]::Delete($resolvedTempRoot, $true)
    }
}
