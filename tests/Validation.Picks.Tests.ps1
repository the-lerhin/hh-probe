# Validation.Picks.Tests.ps1 — Verify Picks Logic per SDD-6.4
#Requires -Version 7.5

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'hh.llm.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'hh.config.psm1') -Force -DisableNameChecking
}

Describe 'Picks Logic Validation' -Tag 'SDD-6.4' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'hh.pipeline.psm1') -Force -DisableNameChecking
    }

    It 'LLM-PickLucky generates a non-empty why for a single item' {
        $item = [PSCustomObject]@{ id = '1'; title = 'Role A'; employer = 'Company A'; score = 8.5; description = 'Test desc A' }
        
        Mock Get-LuckyWhyText { "Test why reason" } -ModuleName 'hh.llm'
        
        $res = LLM-PickLucky -Items @($item)
        
        $res | Should -Not -BeNullOrEmpty
        $res.id | Should -Be '1'
        $res.reason | Should -Be "Test why reason"
    }

    It 'LLM-PickLucky throws on empty input due to validation' {
        { LLM-PickLucky -Items @() } | Should -Throw -ErrorId 'ParameterArgumentValidationErrorEmptyArrayNotAllowed,LLM-PickLucky'
    }

    It 'Apply-Picks skips Lucky pick strictly if Random.org unavailable (SDD-6.4 enforcement)' {
        # Ensure models are loaded
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking
        
        # Create typed CanonicalVacancy items
        $item1 = [CanonicalVacancy]::new()
        $item1.Id = '1'
        $item1.Score = 8.5
        
        $item2 = [CanonicalVacancy]::new()
        $item2.Id = '2'
        $item2.Score = 7.0
        
        $typedItems = @($item1, $item2)
        
        # Mock Random.org to fail (throw to simulate unavailability)
        Mock Get-TrueRandomIndex { throw "Random.org unavailable" } -ModuleName 'hh.pipeline'
        
        # Call Apply-Picks with LLM enabled
        $result = Apply-Picks -Rows $typedItems -LLMEnabled $true
        
        # Assert no Lucky pick was set
        $luckySet = $result | Where-Object { $_.IsLucky -eq $true }
        $luckySet | Should -BeNullOrEmpty
        
        # Verify mock was called
        Assert-MockCalled Get-TrueRandomIndex -ModuleName 'hh.pipeline' -Times 1 -Exactly
    }

    It 'LLM-PickWorst falls back to lowest score if LLM fails' {
        $items = @(
            [PSCustomObject]@{ id = '1'; score = 8.0 },
            [PSCustomObject]@{ id = '2'; score = 3.0 }, # Lowest
            [PSCustomObject]@{ id = '3'; score = 5.0 }
        )
        
 # Mock LLM failure (returns null)
        Mock LLM-PickFromList { return $null } -ModuleName 'hh.llm'
        
        $res = LLM-PickWorst -Items $items
        
        $res | Should -Not -BeNullOrEmpty
        $res.id | Should -Be '2'
    }
    
    It 'LLM-PickWorst uses LLM result if successful' {
        $items = @(
            [PSCustomObject]@{ id = '1'; score = 8.0 }
        )
        
        # Mock LLM success
        Mock LLM-PickFromList { return [PSCustomObject]@{ id = '1'; reason = 'Bad' } } -ModuleName 'hh.llm'
        
        $res = LLM-PickWorst -Items $items
        
        $res | Should -Not -BeNullOrEmpty
        $res.id | Should -Be '1'
    }

    It 'Apply-Picks worst fallback selects lowest score on LLM failure, matching deterministic logic' {
        # Ensure models are loaded
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking
        
        # Create typed CanonicalVacancy items
        $item1 = [CanonicalVacancy]::new()
        $item1.Id = '1'
        $item1.Score = 8.0
        
        $item2 = [CanonicalVacancy]::new()
        $item2.Id = '2'
        $item2.Score = 3.0  # Lowest
        
        $item3 = [CanonicalVacancy]::new()
        $item3.Id = '3'
        $item3.Score = 5.0
        
        $typedItems = @($item1, $item2, $item3)
        
        # Mock LLM-PickWorst to fail (return null)
        Mock LLM-PickWorst { return $null } -ModuleName 'hh.llm'
        
        # Call Apply-Picks with LLM enabled
        $result = Apply-Picks -Rows $typedItems -LLMEnabled $true
        
        # Find the worst pick
        $worst = $result | Where-Object { $_.IsWorst -eq $true } | Select-Object -First 1
        
        $worst | Should -Not -BeNullOrEmpty
        $worst.Id | Should -Be '2'  # Lowest score
    }
}
