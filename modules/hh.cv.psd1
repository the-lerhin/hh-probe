@{
    ModuleVersion = '1.0'
    GUID = '960a0780-61e6-4d65-9570-42d2618075ec'
    Author = 'HH Probe Team'
    CompanyName = 'HH Probe'
    Copyright = '(c) 2025 HH Probe. All rights reserved.'
    Description = 'Auto-generated manifest for hh.cv module'
    
    RootModule = 'hh.cv.psm1'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    
    FunctionsToExport = @(
        'Get-HHEffectiveProfile',
        'Get-HHCVSkills',
        'Get-CVSkills',
        'Get-HHCVText',
        'Sync-HHCVProfile',
        'Get-HHCVConfig',
        'Sync-HHCVFromResume',
        'Get-HHCVFromFile',
        'Get-HHCVFromHH',
        'Merge-CVSkills',
        'Get-LastActivePublishedResumeId',
        'Invoke-CVBump',
        'Get-HHResumeProfile',
        'Get-HHCVSnapshotOrSkills',
        'Build-CompactCVPayload'
    )
    
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()
}
