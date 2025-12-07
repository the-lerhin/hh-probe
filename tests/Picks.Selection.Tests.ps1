# Picks.Selection.Tests.ps1 — integration-style tests for EC/Worst/Lucky selection using mocks
#Requires -Version 7.5
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.pipeline.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.llm.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.util.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.config.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking

Describe 'Picks selection via Apply-Picks' -Tag @('FR-5.2', 'FR-5.4', 'SDD-6.1', 'unit') {
  BeforeAll {
    function global:New-TestRow($id, $score) {
      $r = New-CanonicalVacancy
      $r.Id = $id
      $r.Score = $score
      $r.Meta.plain_desc = "Desc for $id"
      return $r
    }
  }

  BeforeEach {
    InModuleScope 'hh.pipeline' {
      Mock Resolve-LlmOperationConfig {
        [pscustomobject]@{
          Endpoint    = 'https://llm.example'
          ApiKey      = 'test-key'
          Model       = 'mock-model'
          Ready       = $true
          Temperature = 0.2
          TimeoutSec  = 30
          MaxTokens   = $null
          TopP        = $null
          Parameters  = $null
        }
      } -ModuleName 'hh.pipeline'
      Mock LLM-EditorsChoicePick {
        param($Items, $CvText, $PersonaSystem, $Endpoint, $ApiKey, $Model, $Temperature, $TimeoutSec, $MaxTokens, $TopP, $ExtraParameters, $OperationName)
        @{ id = 'v1'; why = 'default ec' }
      } -ModuleName 'hh.pipeline'
      Mock LLM-PickWorst { @{ id = 'v3'; reason = 'default worst' } } -ModuleName 'hh.pipeline'
      Mock Get-ECWhyText { 'default ec why' } -ModuleName 'hh.pipeline'
      Mock Get-WorstWhyText { 'default worst why' } -ModuleName 'hh.pipeline'
      Mock Get-LuckyWhyText { 'default lucky why' } -ModuleName 'hh.pipeline'
    }
  }

  It 'marks EC and Worst from LLM helpers and sets why' {
    InModuleScope 'hh.pipeline' {
      Mock LLM-EditorsChoicePick { param($Items, $CvText, $PersonaSystem, $Endpoint, $ApiKey, $Model, $Temperature, $TimeoutSec, $MaxTokens, $TopP, $ExtraParameters, $OperationName) @{ id = 'v1'; why = 'top match' } } -ModuleName 'hh.pipeline'
      Mock LLM-PickWorst { @{ id = 'v3'; reason = 'least relevant' } } -ModuleName 'hh.pipeline'
      Mock Get-ECWhyText { 'top match' } -ModuleName 'hh.pipeline'
      Mock Get-WorstWhyText { 'least relevant' } -ModuleName 'hh.pipeline'
    }
    InModuleScope 'hh.pipeline' {
      $rows = @(
        (New-TestRow 'v1' 9.5),
        (New-TestRow 'v2' 8.0),
        (New-TestRow 'v3' 7.0)
      )
      $out = Apply-Picks -Rows $rows -LLMEnabled:$true
      $ec = $out | Where-Object { $_.Id -eq 'v1' }
      $ec.IsEditorsChoice | Should -BeTrue
      $ec.EditorsWhy | Should -Be 'top match'
      $ec.Picks.IsEditorsChoice | Should -BeTrue
      $ec.Picks.EditorsWhy | Should -Be 'top match'
      
      $worst = $out | Where-Object { $_.Id -eq 'v3' }
      $worst.IsWorst | Should -BeTrue
      $worst.WorstWhy | Should -Be 'least relevant'
      $worst.Picks.IsWorst | Should -BeTrue
      $worst.Picks.WorstWhy | Should -Be 'least relevant'
    }
  }

  It 'marks Lucky using random.org helper when available' {
    InModuleScope 'hh.pipeline' {
      Mock Get-TrueRandomIndex { param($MaxExclusive, $ForceRemote) return 1 } -ModuleName 'hh.pipeline'
      Mock LLM-EditorsChoicePick { $null } -ModuleName 'hh.pipeline'
      Mock LLM-PickWorst { $null } -ModuleName 'hh.pipeline'
      # Ensure scope sees the command for mocking
      if (-not (Get-Command 'LLM-PickLucky' -ErrorAction SilentlyContinue)) {
        function LLM-PickLucky { param($Items) return @{ id = 'v2'; why = 'lucky match' } }
      }
      Mock LLM-PickLucky { @{ id = 'v2'; why = 'lucky match' } } -ModuleName 'hh.pipeline'
    }
    InModuleScope 'hh.pipeline' {
      $rows = @(
        (New-TestRow 'v1' 9.5),
        (New-TestRow 'v2' 8.0),
        (New-TestRow 'v3' 7.0)
      )
      $out = Apply-Picks -Rows $rows -LLMEnabled:$true
      
      $lucky = $out | Where-Object { $_.IsLucky }
      $lucky.Count | Should -Be 1
      $lucky.Id | Should -Be 'v2'
      $lucky.Picks.IsLucky | Should -BeTrue
      $lucky.Picks.LuckyWhy | Should -Be 'lucky match'
    }
  }

  It 'skips Lucky when random.org unavailable' {
    InModuleScope 'hh.pipeline' {
      Mock Get-TrueRandomIndex { param($MaxExclusive, $ForceRemote) return -1 } -ModuleName 'hh.pipeline'
      Mock LLM-EditorsChoicePick { $null } -ModuleName 'hh.pipeline'
      Mock LLM-PickWorst { $null } -ModuleName 'hh.pipeline'
    }
    InModuleScope 'hh.pipeline' {
      $rows = @(
        (New-TestRow 'v1' 9.5),
        (New-TestRow 'v2' 8.0)
      )
      $out = Apply-Picks -Rows $rows -LLMEnabled:$true
      # remote RNG failure means Lucky is skipped entirely
      ($out | Where-Object { $_.IsLucky }).Count | Should -Be 0
    }
  }
  
  It 'falls back to deterministic Worst (lowest score) when LLM disabled or fails' {
    InModuleScope 'hh.pipeline' {
      # No mocks need return anything, LLM disabled
    }
    InModuleScope 'hh.pipeline' {
      $rows = @(
        (New-TestRow 'v1' 9.5),
        (New-TestRow 'v2' 8.0),
        (New-TestRow 'v3' 2.0)
      )
          
      # TEST 1: LLM Disabled
      $out = Apply-Picks -Rows $rows -LLMEnabled:$false
          
      # EC/Lucky should be $false
      ($out | Where-Object { $_.IsEditorsChoice }).Count | Should -Be 0
      ($out | Where-Object { $_.IsLucky }).Count | Should -Be 0
          
      # Worst should be v3 (lowest score)
      $worst = $out | Where-Object { $_.IsWorst }
      $worst.Count | Should -Be 1
      $worst.Id | Should -Be 'v3'
      $worst.WorstWhy | Should -BeExactly ''
      $worst.Picks.WorstWhy | Should -BeExactly ''
          
      # TEST 2: LLM Enabled but fails returns null
      Mock LLM-EditorsChoicePick { $null } -ModuleName 'hh.pipeline'
      Mock LLM-PickWorst { $null } -ModuleName 'hh.pipeline'
          
      $out2 = Apply-Picks -Rows $rows -LLMEnabled:$true
      $worst2 = $out2 | Where-Object { $_.IsWorst }
      $worst2.Count | Should -Be 1
      $worst2.Id | Should -Be 'v3'
      $worst2.WorstWhy | Should -BeExactly ''
    }
  }
}
