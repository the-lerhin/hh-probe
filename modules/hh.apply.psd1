@{
    ModuleVersion = '1.0'
    GUID = '1407864e-4ed6-4d50-99b6-bd9541d4e9e4'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.apply module'
    
    RootModule = 'hh.apply.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Select-ApplyVacancy',
        'Get-HHPainPoints',
        'Get-HHCVRewritePlan',
        'Get-HHPremiumCoverLetter',
        'Invoke-HHApplication'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
