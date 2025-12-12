@{
    ModuleVersion = '1.0'
    GUID = '4ace7b6c-13f1-42b4-aedf-746145cb0305'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.llm.summary module'
    
    RootModule = 'hh.llm.summary.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-RemoteSummaryForVacancy',
        'Get-LocalSummaryForVacancy',
        'Read-SummaryCache',
        'Write-SummaryCache',
        'Read-RankingCache',
        'Write-RankingCache',
        'Get-RemoteSummaryContext',
        'Get-SummaryPromptSet',
        'Expand-SummaryUserPrompt',
        'Get-HHLocalVacancySummary',
        'Get-HHQwenFitScore',
        'Get-HHPremiumVacancySummary',
        'Invoke-LLMSummaries',
        'Get-HHRemoteFitScore',
        'Invoke-CanonicalSummaryWithCache',
        'Clean-SummaryText',
        'Get-HHRemoteVacancySummary',
        'Invoke-BatchLocalSummaries',
        'Invoke-BatchRemoteRanking'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
