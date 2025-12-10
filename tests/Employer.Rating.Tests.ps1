# Employer.Rating.Tests.ps1
#Requires -Version 7.4

Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.pipeline.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.fetch.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking

Describe 'Employer Rating Logic' -Tag @('FR-6.1', 'FR-3.2', 'unit') {
    BeforeAll {
        function global:New-TestCanonEmp($id, $source) {
            $c = New-CanonicalVacancy
            $c.Id = "vac_$id"
            $c.Meta.Source = $source
            $c.Employer.Id = $id
            return $c
        }
    }

    It 'uses HTML scraped rating for HH source' {
        InModuleScope 'hh.fetch' {
            Mock Get-EmployerRatingScrape { return [pscustomobject]@{ Rating = 4.5 } }
        }

        $c = New-TestCanonEmp '123' 'hh'
        # Simulate previous API contamination
        $c.EmployerRating = 9.9 
        
        Update-EmployerRating -Vacancy $c
        
        $c.EmployerRating | Should -Be 4.5
    }

    It 'ignores API rating and clears it if scrape fails' {
        InModuleScope 'hh.fetch' {
            Mock Get-EmployerRatingScrape { return $null }
        }

        $c = New-TestCanonEmp '124' 'hh'
        $c.EmployerRating = 5.0 # Stale API data
        
        Update-EmployerRating -Vacancy $c
        
        $c.EmployerRating | Should -Be 0
    }

    It 'skips Getmatch vacancies entirely' {
        InModuleScope 'hh.fetch' {
            Mock Get-EmployerRatingScrape { return [pscustomobject]@{ Rating = 4.8 } }
        }
        
        $c = New-TestCanonEmp '999' 'getmatch'
        $c.EmployerRating = 0
        
        Update-EmployerRating -Vacancy $c
        
        # Should NOT have updated
        $c.EmployerRating | Should -Be 0
    }
}
