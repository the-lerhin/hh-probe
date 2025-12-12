@{
    ModuleVersion = '1.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Configuration management module for HH Probe'
    
    RootModule = 'hh.config.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-HHConfig',
        'Get-HHConfigValue', 
        'Reset-HHConfigCache',
        'Get-HHSecrets',
        'Get-HHConfigPath',
        'Set-HHConfigPath',
        'Read-HHJsonFile'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}