@{
    ModuleVersion = '1.0'
    GUID = 'bae3dbe6-0d56-4e6a-b53c-31c71402a9ab'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.fetch module'
    
    RootModule = 'hh.fetch.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Write-LogFetch',
        'Get-HHEffectiveSearchFilters',
        'Search-Vacancies',
        'Get-HHSimilarVacancies',
        'Get-HHWebRecommendations',
        'Get-HHHybridVacancies',
        'Get-VacancyDetail',
        'Get-EmployerDetail',
        'Get-SkillsVocab',
        'Get-GetmatchConfig',
        'Get-GetmatchQueryUrl',
        'Get-GetmatchQueryUrls',
        'Get-GetmatchVacanciesRaw',
        'Resolve-HHAreaIdByName',
        'Resolve-HHRoleIdByName',
        'Resolve-HHAreaCountry',
        'Get-HHAreaDetail',
        'Get-HHAreaCacheKey',
        'Get-EmployerRatingScrape',
        'Parse-EmployerRatingHtml',
        'Update-EmployerRating',
        'Get-ExchangeRates',
        'Convert-PSCustomObjectToHashtable'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
