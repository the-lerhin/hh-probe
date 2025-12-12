@{
    ModuleVersion = '1.0'
    GUID = '3ff42174-987a-4ec4-8f36-a5366f9266bf'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.cache module'
    
    RootModule = 'hh.cache.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Initialize-LiteDbCache',
        'Get-LiteDbReady',
        'Read-CacheText',
        'Write-CacheText',
        'Close-LiteDbCache',
        'Initialize-HHCache',
        'Get-HHCacheBackend',
        'Close-HHCache',
        'Get-HHCacheFilePath',
        'Set-HHCacheItem',
        'Get-HHCacheItem',
        'Remove-HHCacheOlderThanDays',
        'Remove-HHCacheItem',
        'Get-HHCacheProvider',
        'Get-HHCacheStats',
        'Clear-HHCache',
        'Run-GarbageCollection'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
