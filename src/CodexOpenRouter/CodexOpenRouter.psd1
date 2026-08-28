@{
    RootModule = 'CodexOpenRouter.psm1'
    ModuleVersion = '0.1.7'
    GUID = 'be74dba0-28ed-4ba3-adff-f0fc0d107b39'
    Author = 'Mister-Shaw'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Mister-Shaw. MIT License.'
    Description = 'Two commands for opening default Codex or OpenRouter Codex with a freshly synchronized model catalog.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('cx', 'cxor')
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
