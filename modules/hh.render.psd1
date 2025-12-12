@{
    ModuleVersion = '1.0'
    GUID = '5d289f28-6092-4e02-9d7d-0fbeb84b46ab'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.render module'
    
    RootModule = 'hh.render.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Render-CSVReport',
        'Render-JsonReport',
        'ConvertFrom-HHRealData',
        'Render-HtmlReport',
        'Format-SalaryText',
        'Format-EmployerPlace',
        'Build-ViewRow',
        'Render-Template',
        'Get-HtmlRenderContext',
        'Convert-ToDeepHashtable',
        'Build-Picks',
        'Render-Reports'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
