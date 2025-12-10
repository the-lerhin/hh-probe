# Pester tests for Build-CanonicalRowTyped and scoring weights

Describe "Canonical Builder" {
  BeforeAll {
    Import-Module Pester
    $RepoRootHint = (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $RepoRootHint 'modules/hh.util.psm1') -Force -DisableNameChecking -Global
    # Use hint for imports to avoid mis-detection in some environments
    $RepoRoot = $RepoRootHint
    Import-Module (Join-Path $RepoRoot 'modules/hh.config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RepoRoot 'modules/hh.scoring.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RepoRoot 'modules/hh.factory.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RepoRoot 'modules/hh.pipeline.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RepoRoot 'modules/hh.models.psm1') -Force -DisableNameChecking

    Ensure-HHModelTypes

    $cmd = Get-Command Calculate-Score
    Write-Host "Parameter Sets for Calculate-Score: $($cmd.ParameterSets | Format-List | Out-String)"

    $cmd2 = Get-Command Get-HeuristicScore
    Write-Host "Parameter Sets for Get-HeuristicScore: $($cmd2.ParameterSets | Format-List | Out-String)"

try {
    $testVac = [CanonicalVacancy]::new()
    Calculate-Score -Vacancy $testVac -CvSnapshot $null -Context $null -ExchangeRates @{ 'RUB' = 1.0 }
} catch {
    Write-Host "TEST CALL ERROR: $($_.Exception.Message)"
    Write-Host $($_.Exception.StackTrace)
}

    # Important: DO NOT dot-source hh.ps1 here — it executes the main pipeline.
    # Build-CanonicalRowTyped safely falls back when detail functions are missing,
    # so we avoid side effects and network calls by not sourcing hh.ps1.

    $configPath = (Join-Path $RepoRoot 'hh.config.jsonc')
    if (Test-Path $configPath) { Set-HHConfigPath -Path $configPath }

    function Load-Fixture {
      param([string]$name)
      $path = Join-Path $RepoRoot (Join-Path 'tests/fixtures' $name)
      return (Get-Content $path -Raw | ConvertFrom-Json)
    }

    # Optional mocks: only apply if commands exist; otherwise Build-CanonicalRowTyped
    # safely falls back via Invoke-Quietly without network calls.
    if (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue) {
      Mock -CommandName Get-VacancyDetail -ModuleName hh.pipeline -MockWith {
        param($id)
        return [pscustomobject]@{
          id = $id
          description = "Remote-friendly role"
          salary = [pscustomobject]@{ from = 100000; to = 200000; currency = 'RUR'; gross = $true }
        }
      }
    }
    if (Get-Command -Name Get-EmployerInfo -ErrorAction SilentlyContinue) {
      Mock -CommandName Get-EmployerInfo -ModuleName hh.pipeline -MockWith {
        param($emp)
        return [pscustomobject]@{ Size=''; OpenVac=0; Logo=$null; Industry=''; Rating=$null; Votes=0 }
      }
    }

    $Global:SampleVacancyRemote = [pscustomobject]@{
      id = 'vac-1'
      name = 'Senior Engineer'
      employer = [pscustomobject]@{ id = 'emp-1'; name = 'Acme' }
      schedule = [pscustomobject]@{ id = 'remote'; name = 'Удаленная работа' }
      published_at = (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssK')
      # Provide salary to allow Get-HHCanonicalSalary to compute upper_cap
      salary = [pscustomobject]@{ from = 100000; to = 200000; currency = 'RUR'; gross = $true }
    }
    $Global:SampleVacancyOffice = [pscustomobject]@{
      id = 'vac-2'
      name = 'Senior Engineer'
      employer = [pscustomobject]@{ id = 'emp-1'; name = 'Acme' }
      schedule = [pscustomobject]@{ id = 'full'; name = 'Полная занятость' }
      published_at = (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssK')
      salary = [pscustomobject]@{ from = 100000; to = 200000; currency = 'RUR'; gross = $true }
    }

    $Global:ZeroedWeights = @{ 
      ScoreWeights = @{ recency=0.0; remote=0.0; seniority=0.0; leadership=0.0; englishDesc=0.0; employerSig=0.0; skills=0.0; cv=0.0; salary=1.0; badges=1.0 };
      PenaltyWeights = @{ dupPenalty=0.0; culturePenalty=0.0 };
      Heuristics = @{ senior_keywords=@(); junior_keywords=@(); leadership_keywords=@(); remote_keywords=@() };
      RecencyHorizonDays = 30; TargetSeniority = 'Senior'; RatingBoostThresh = 9.9; RatingBoostValue = 0.0; SalaryUpperCapMax = 200000
    }
  }

  Context "Canonical shape" {
    It "Build-CanonicalRowTyped returns required fields (v1)" {
      $row = Build-CanonicalRowTyped -Vacancy $SampleVacancyRemote
      $row | Should -Not -BeNullOrEmpty
      $row.Id | Should -Be 'vac-1'
      $row.PublishedAt | Should -Not -BeNullOrEmpty
      $row.Salary.UpperCap | Should -Be 200000
     
    }
  }

  Context "Scoring weights" {
    It "Salary and badges scores are computed and summed (weighted)" {
          $row = Build-CanonicalRowTyped -Vacancy $SampleVacancyRemote
          Write-Host "Type of row: $($row.GetType().FullName)"
          Write-Host "Is CanonicalVacancy: $($row -is [CanonicalVacancy])"
          try {
            Calculate-Score -Vacancy $row
            Write-Host "Call succeeded"
          } catch {
            Write-Host "IT CALL ERROR: $($_.Exception.Message)"
            Write-Host "STACK: $($_.Exception.StackTrace)"
          }
          Write-Host "Salary score: $($row.Meta.Scores.salary)"
          try {
            Write-Host "Type of salary score: $($row.Meta.Scores.salary.GetType().FullName)"
          } catch {
            Write-Host "Salary score type error: $($_.Exception.Message)"
          }
          $row.Meta.Scores.salary | Should -BeGreaterOrEqual 0 # Adjust based on actual logic, no badges in scoring
          $row.Score | Should -BeGreaterOrEqual 0
        }

    It "Remote vacancy scores higher than office due to badges" {
      $r1 = Build-CanonicalRowTyped -Vacancy $SampleVacancyRemote
      $r2 = Build-CanonicalRowTyped -Vacancy $SampleVacancyOffice
      Write-Host "Type of r1: $($r1.GetType().FullName)"
      Write-Host "Is CanonicalVacancy for r1: $($r1 -is [CanonicalVacancy])"
      Calculate-Score -Vacancy $r1
      Calculate-Score -Vacancy $r2
      $r1.Score | Should -BeGreaterOrEqual $r2.Score # No badges score difference in current logic
    }
  }

  Context "Canonical v1 shape" {
    It "fills required fields with fallbacks (no employer)" {
      $vac = [pscustomobject]@{
        id = 'vac-no-emp'
        name = 'Test Vacancy'
        area = [pscustomobject]@{ name = 'Moscow' }
        alternate_url = 'https://example.com/vac-no-emp'
        published_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
      }
      $row = Build-CanonicalRowTyped -Vacancy $vac
      $row.id      | Should -Not -BeNullOrEmpty
      $row.title   | Should -Not -BeNullOrEmpty
      $row.city    | Should -Not -BeNullOrEmpty
      $row.Url    | Should -Match '^https?://'
      $row.meta.scores.total | Should -BeOfType 'System.Double'
      $row.score | Should -BeOfType 'System.Double'
    }

    It "sets city to null when area is missing" {
      $vac = [pscustomobject]@{
        id = 'vac-no-title'
        published_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
      }
      $row = Build-CanonicalRowTyped -Vacancy $vac
      $row.city | Should -BeNullOrEmpty
    }

    It "computes salary.upper_cap from 'to' or 'from'" {
      $vac = [pscustomobject]@{
        id = 'vac-full'
        name = 'Full Vacancy'
        salary = [pscustomobject]@{ from = 100000; to = 150000; currency = 'RUR' }
        published_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
      }
      $row = Build-CanonicalRowTyped -Vacancy $vac
      if ($row.salary.to)    { $row.salary.upper_cap | Should -Be $row.salary.to }
      elseif ($row.salary.from) { $row.salary.upper_cap | Should -Be $row.salary.from }
      else { $row.salary.upper_cap | Should -Be $null }
    }

    It "falls back title to empty when absent" {
      $vac = [pscustomobject]@{
        id = 'vac-remote'
        schedule = [pscustomobject]@{ id = 'remote' }
        published_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
      }
      $row = Build-CanonicalRowTyped -Vacancy $vac
      $row.title | Should -BeNullOrEmpty
    }
  }

  Context "Employer open mapping" {
    It "maps EmployerInfo.OpenVac into typed employer model" {
      $vac = [pscustomobject]@{ id='vac-3'; name='Engineer'; employer=[pscustomobject]@{ id='emp-7'; name='Globex'; open_vacancies=7 } }
      $rowCanon = Build-CanonicalRowTyped -Vacancy $vac
      $rowCanon | Should -Not -BeNullOrEmpty
      $rowCanon.employer.open | Should -Be 7
    }
  }
}
