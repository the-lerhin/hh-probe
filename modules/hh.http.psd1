@{
    ModuleVersion = '1.0'
    GUID = '09b0df4a-7b21-4174-926a-de71646b6664'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.http module'
    
    RootModule = 'hh.http.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Invoke-HttpRequest',
        'Invoke-HhApiRequest',
        'Invoke-LlmApiRequest',
        'Get-RetryAfterDelayMs',
        'Get-HttpConcurrencyLimit',
        'Get-HttpSemaphore',
        'Set-HttpConcurrencyLimit',
        'Wait-HttpSemaphore',
        'Release-HttpSemaphore',
        'Get-RateLimitSetting',
        'Get-RateLimitConfig',
        'Get-TrueRandomIndex'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
