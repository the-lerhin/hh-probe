@{
    ModuleVersion = '1.0'
    GUID = 'e53bdc83-ce2e-4409-a6e1-15a12c9cf5c9'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.pipeline module'
    
    RootModule = 'hh.pipeline.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-HHSearchMode',
        'ConvertTo-HHSearchText',
        'Get-CanonicalKeySkills',
        'Get-BaseSet',
        'Invoke-HHProbeMain',
        'Apply-Picks',
        'Invoke-EditorsChoice',
        'Test-HHPipelineHealth',
        'Initialize-HHPipelineEnvironment'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
