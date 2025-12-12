@{
    ModuleVersion = '1.0'
    GUID = '99c4845d-6b9f-41b6-ae7f-e972d0a33e63'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.core module'
    
    RootModule = 'hh.core.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'New-HHPipelineState',
        'Set-HHPipelineValue',
        'Add-HHPipelineStat',
        'Get-OrAddHCacheValue',
        'Get-HHPipelineSummary',
        'Show-HHPipelineSummary',
        'Should-BumpCV'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
