@{
    ModuleVersion = '1.0'
    GUID = 'd5c665d2-7991-47b5-97f5-4417df3ee206'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.util module'
    
    RootModule = 'hh.util.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-VacancyPublishedUtc',
        'Test-Interactive',
        'Show-ProgressWithPercent',
        'Show-ProgressIndeterminate',
        'Complete-Progress',
        'Invoke-Quietly',
        'Get-PlainDesc',
        'Get-UtcDate',
        'Get-RepoRoot',
        'Join-RepoPath',
        'Get-HHDoubleOrDefault',
        'Get-HHNullableDouble',
        'Get-Relative',
        'Get-HHCanonicalSummary',
        'Get-HHPlainSummary',
        'Get-TextLanguage',
        'Get-HHCanonicalSummaryEx',
        'Normalize-HHSummaryText',
        'Normalize-HHSummarySource',
        'New-FileLock',
        'Remove-FileLock',
        'Test-AnotherInstanceRunning',
        'Build-SearchQueryText',
        'Get-HHCanonicalSalary',
        'Get-HHSafePropertyValue',
        'Bump-Http',
        'Bump-Scrape',
        'Log-CacheSummary',
        'Log-ScrapeSummary',
        'Get-OrDefault',
        'Get-TrueRandomIndex',
        'Invoke-Jitter',
        'Initialize-HHGlobalCacheStats',
        'Detect-Language',
        'Resolve-SummaryLanguage',
        'Normalize-SkillToken',
        'Get-SalarySymbol'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
