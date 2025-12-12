@{
    ModuleVersion = '1.0'
    GUID = '8f5a3580-267d-4bc6-b018-5512553302f1'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.notify module'
    
    RootModule = 'hh.notify.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Test-TelegramConfig',
        'Send-Telegram',
        'Send-TelegramMessage',
        'Send-TelegramDigest',
        'Send-TelegramPing',
        'ConvertTo-TelegramPlainText'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
