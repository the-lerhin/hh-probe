@{
    ModuleVersion = '1.0'
    GUID = '174fc238-c649-4bba-a264-dcf1eee9fa27'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.llm.local module'
    
    RootModule = 'hh.llm.local.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-LocalLLMConfig',
        'Invoke-LocalLLMRelevance',
        'Invoke-LocalLLMSummary',
        'Invoke-OllamaRaw'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
