# ReportProjection.Tests.ps1 — Tests for Get-ReportProjection
#Requires -Version 7.5
using module ../modules/hh.report.psm1
using module ../modules/hh.models.psm1

BeforeAll {
    Import-Module "$PSScriptRoot/../modules/hh.report.psm1" -Force
    Ensure-HHModelTypes
}

Describe "Get-ReportProjection - Picks mapping" {
    It "Maps picks flags from canonical rows to projection" {
        # Arrange: Create three typed rows with different pick flags
        $row1 = [CanonicalVacancy]@{
            Id       = '1001'
            Title    = 'EC Vacancy'
            Url      = 'https://hh.ru/vacancy/1001'
            Picks    = [PicksInfo]@{
                IsEditorsChoice = $true
                EditorsWhy      = 'Best match for skills and culture'
            }
            Score    = 9.5
            EmployerName = 'Top Corp'
        }
    
        $row2 = [CanonicalVacancy]@{
            Id       = '1002'
            Title    = 'Lucky Vacancy'
            Url      = 'https://hh.ru/vacancy/1002'
            Picks    = [PicksInfo]@{
                IsLucky  = $true
                LuckyWhy = 'Unexpected gem found via broader search'
            }
            Score    = 7.0
            EmployerName = 'Good Corp'
        }
    
        $row3 = [CanonicalVacancy]@{
            Id       = '1003'
            Title    = 'Worst Vacancy'
            Url      = 'https://hh.ru/vacancy/1003'
            Picks    = [PicksInfo]@{
                IsWorst  = $true
                WorstWhy = 'Red flags in requirements'
            }
            Score    = 2.0
            EmployerName = 'Bad Corp'
        }

        # Act
        $projection = Get-ReportProjection -Rows @($row1, $row2, $row3)

        # Assert: Verify picks object is populated
        $projection.picks | Should -Not -BeNullOrEmpty
    
        # Verify EC pick
        $projection.picks.ec | Should -Not -BeNullOrEmpty
        $projection.picks.ec.id | Should -Be '1001'
        $projection.picks.ec.title | Should -Be 'EC Vacancy'
        $projection.picks.ec.editors_why | Should -Be 'Best match for skills and culture'
    
        # Verify Lucky pick
        $projection.picks.lucky | Should -Not -BeNullOrEmpty
        $projection.picks.lucky.id | Should -Be '1002'
        $projection.picks.lucky.title | Should -Be 'Lucky Vacancy'
        $projection.picks.lucky.lucky_why | Should -Be 'Unexpected gem found via broader search'
    
        # Verify Worst pick
        $projection.picks.worst | Should -Not -BeNullOrEmpty
        $projection.picks.worst.id | Should -Be '1003'
        $projection.picks.worst.title | Should -Be 'Worst Vacancy'
        $projection.picks.worst.worst_why | Should -Be 'Red flags in requirements'

        # Verify row flags are set correctly
        $ecRow = $projection.rows | Where-Object { $_.id -eq '1001' }
        $ecRow | Should -Not -BeNullOrEmpty
        $ecRow.is_editors_choice | Should -Be $true
        $ecRow.is_lucky | Should -Be $false
        $ecRow.is_worst | Should -Be $false
    
        $luckyRow = $projection.rows | Where-Object { $_.id -eq '1002' }
        $luckyRow | Should -Not -BeNullOrEmpty
        $luckyRow.is_lucky | Should -Be $true
        $luckyRow.is_editors_choice | Should -Be $false
        $luckyRow.is_worst | Should -Be $false
    
        $worstRow = $projection.rows | Where-Object { $_.id -eq '1003' }
        $worstRow | Should -Not -BeNullOrEmpty
        $worstRow.is_worst | Should -Be $true
        $worstRow.is_editors_choice | Should -Be $false
        $worstRow.is_lucky | Should -Be $false
    }

    It "Handles rows with no picks gracefully" {
        # Arrange
        $row1 = [CanonicalVacancy]@{
            Id    = '2001'
            Title = 'Normal Vacancy'
            Url  = 'https://hh.ru/vacancy/2001'
            Score = 5.0
        }

        # Act
        $projection = Get-ReportProjection -Rows @($row1)

        # Assert
        $projection.picks | Should -Not -BeNullOrEmpty
        $projection.picks.ec | Should -BeNullOrEmpty
        $projection.picks.lucky | Should -BeNullOrEmpty
        
        # FRD requirement: Worst must be selected deterministically if no flags
        $projection.picks.worst | Should -Not -BeNullOrEmpty
        $projection.picks.worst.id | Should -Be '2001'
    
        $row = $projection.rows[0]
        $row.is_editors_choice | Should -Be $false
        $row.is_lucky | Should -Be $false
        $row.is_worst | Should -Be $false
    }

    It "Reads picks from typed CanonicalVacancy.Picks property" {
        # Arrange: Use typed PicksInfo object
        $picksInfo = [PicksInfo]@{
            IsEditorsChoice = $true
            EditorsWhy      = 'Typed pick'
        }
    
        $row = [CanonicalVacancy]@{
            Id    = '3001'
            Title = 'Typed Vacancy'
            Url  = 'https://hh.ru/vacancy/3001'
            Picks = $picksInfo
            Score = 8.0
        }

        # Act
        $projection = Get-ReportProjection -Rows @($row)

        # Assert
        $projection.picks.ec | Should -Not -BeNullOrEmpty
        $projection.picks.ec.id | Should -Be '3001'
        $projection.picks.ec.editors_why | Should -Be 'Typed pick'
    
        $projRow = $projection.rows[0]
        $projRow.is_editors_choice | Should -Be $true
    }

    It "Projects EmployerOpenVacancies to employer_open_vacancies with fallback to Employer.open" {
        # Arrange: Row with EmployerOpenVacancies set
        $row1 = [CanonicalVacancy]@{
            Id                    = '4001'
            EmployerOpenVacancies = 15
            Employer              = [EmployerInfo]@{ Name = 'Test Corp'; open = 10 }
        }

        # Row without EmployerOpenVacancies, but with Employer.open
        $row2 = [CanonicalVacancy]@{
            Id       = '4002'
            Employer = [EmployerInfo]@{ Name = 'Fallback Corp'; open = 8 }
        }

        # Act
        $projection = Get-ReportProjection -Rows @($row1, $row2)

        # Assert for row1
        $projRow1 = $projection.rows | Where-Object { $_.id -eq '4001' }
        $projRow1 | Should -Not -BeNullOrEmpty
        $projRow1.employer_open_vacancies | Should -Be 15

        # Assert for row2 (fallback)
        $projRow2 = $projection.rows | Where-Object { $_.id -eq '4002' }
        $projRow2 | Should -Not -BeNullOrEmpty
        $projRow2.employer_open_vacancies | Should -Be 8
    }
}
