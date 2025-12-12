@{
    ModuleVersion = '1.0'
    GUID = 'a3bf8059-7991-410e-a48b-0a4d46cdfd1a'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.factory module'
    
    RootModule = 'hh.factory.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'New-CanonicalVacancyFromHH',
        'New-CanonicalVacancyFromGetmatch',
        'Build-CanonicalRowTyped',
        'Build-CanonicalFromGetmatchVacancy',
        'Build-BadgesPack',
        'Get-CanonicalKeySkills'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
