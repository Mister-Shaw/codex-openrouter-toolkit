@{
    RootModule = 'CodexOpenRouter.psm1'
    ModuleVersion = '0.1.1'
    GUID = 'be74dba0-28ed-4ba3-adff-f0fc0d107b39'
    Author = 'Mister-Shaw'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Mister-Shaw. MIT License.'
    Description = 'Windows helpers for switching Codex Desktop between its saved OpenAI configuration and OpenRouter, with a refreshed model catalog and lightweight agent prompt.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'cx',
        'cxor',
        'Get-CodexCliPath',
        'Get-CodexOpenRouterStatus',
        'Get-CodexOpenRouterSettings',
        'Initialize-CodexOpenRouterConfig',
        'Restart-CodexDesktopApp',
        'Set-CodexDesktopModelConfig',
        'Set-OpenRouterAgentInstructions',
        'Switch-CodexDesktopProvider',
        'Test-CodexModelCatalog',
        'Test-OpenRouterApiKey',
        'Update-OpenRouterModelCatalog'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Codex', 'OpenRouter', 'Windows', 'PowerShell')
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://github.com/Mister-Shaw/codex-openrouter-toolkit'
        }
    }
}
