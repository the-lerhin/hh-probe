@{
    ModuleVersion = '1.0'
    GUID = 'b2c3d4e5-f6a7-8901-bcde-f23456789012'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Scoring and ranking module for HH Probe vacancies'
    
    RootModule = 'hh.scoring.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    RequiredModules = @('hh.config')
    
    FunctionsToExport = @(
        'Get-HHScoringConfig',
        'Calculate-Score',
        'Get-BaselineScore',
        'Get-LLMRelevanceScore',
        'Normalize-Score',
        'Invoke-PipelineStageBaselineScoring'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}