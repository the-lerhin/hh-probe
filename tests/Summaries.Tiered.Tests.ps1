# Summaries.Tiered.Tests.ps1
#Requires -Version 7.5

Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.pipeline.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.llm.summary.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.report.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking

Describe 'Tiered Summaries Projection' -Tag @('FR-5.1', 'FR-5.8', 'SDD-6.2', 'unit') {
    BeforeAll {
        function global:New-TestCanon($id) {
            $c = New-CanonicalVacancy
            $c.Id = $id
            $c.Title = "Title $id"
            return $c
        }
    }

    It 'projects local summary when remote is missing' {
        $c = New-TestCanon 'v1'
        $c.Meta.summary.text = 'local summary'
        $c.Meta.summary.source = 'local'
        $c.Meta.summary_source = 'local'
        $c.Meta.local_summary = @{ model = 'gemma' }
        
        # Simulate projection
        $p = Get-ReportProjection -Rows @($c)
        
        $row = $p.rows[0]
        
        $row.summary | Should -Be 'local summary'
        $row.summary_source | Should -Be 'local'
        # local_llm might be projected if standard, but summary_model is typically for remote
        $row.summary_model | Should -BeNullOrEmpty
    }

    It 'projects remote summary when available' {
        $c = New-TestCanon 'v2'
        $c.Meta.summary.text = 'remote summary text'
        $c.Meta.summary.source = 'remote'
        $c.Meta.summary_source = 'remote'
        $c.Meta.summary_model = 'gpt-4o'
        
        $p = Get-ReportProjection -Rows @($c)
        $row = $p.rows[0]
        
        $row.summary | Should -Be 'remote summary text'
        $row.summary_source | Should -Be 'remote'
        $row.summary_model | Should -Be 'gpt-4o'
    }
}
