@{
    ModuleVersion = '1.0'
    GUID = 'f4d88dc4-5e2d-48f1-9c04-4cdf4a42d721'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.llm module'
    
    RootModule = 'hh.llm.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-LLMRuntimeConfig',
        'Set-LLMRuntimeGlobals',
        'Invoke-LLMPreclassifyBatch',
        'Invoke-VacancyPreclass',
        'Read-LLMCache',
        'Write-LLMCache',
        'Resolve-LlmOperationConfig',
        'LLM-InvokeJson',
        'LLM-InvokeText',
        'LLM-EditorsChoicePick',
        'LLM-PickLucky',
        'LLM-PickWorst',
        'LLM-GenerateText',
        'LLM-GenerateCoverLetter',
        'LLM-MeasureCultureRisk',
        'Invoke-PremiumRanking',
        'Get-ECWhyText',
        'Get-LuckyWhyText',
        'Get-WorstWhyText',
        'Get-ECWhyPath',
        'Get-LuckyWhyPath',
        'Get-WorstWhyPath',
        'Get-CoverLetterPath',
        'Read-ECWhy',
        'Read-LuckyWhy',
        'Read-WorstWhy',
        'Read-CoverLetter',
        'Write-ECWhy',
        'Write-LuckyWhy',
        'Write-WorstWhy',
        'Write-CoverLetter',
        'Get-LlmPromptForOperation',
        'Add-LlmUsage',
        'Get-LlmUsageCounters',
        'Set-LlmUsagePipelineState',
        'Get-LlmProviderBalance'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
