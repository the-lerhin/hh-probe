@{
    ModuleVersion = '1.0'
    GUID = 'bb6c414a-b7a0-4340-9646-a5dac9bdfc82'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.dictionaries module'
    
    RootModule = 'hh.dictionaries.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-HHDictionary',
        'Get-HHAllDictionaries',
        'Resolve-HHAreaIdByName',
        'Resolve-HHRoleIdByName',
        'Clear-HHDictionaryCache'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
