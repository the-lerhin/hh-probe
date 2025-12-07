$moduleRoot = Join-Path $PSScriptRoot '..' 'modules'
Import-Module -Name (Join-Path $moduleRoot 'hh.models.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $moduleRoot 'hh.report.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $moduleRoot 'hh.render.psm1') -Force -DisableNameChecking

Ensure-HHModelTypes

function global:New-CsvContractRow {
  param(
    [string]$Id,
    [string]$Source,
    [string[]]$Tiers
  )
  $row = [CanonicalVacancy]::new()
  $row.Id = $Id
  $row.Title = "Role $Id"
  $row.Url = "https://example.com/v/$Id"
  $row.EmployerName = "Employer $Id"
  $row.City = "City $Id"
  $row.Country = "Country $Id"
  $row.Summary = "Summary for $Id"
  $row.Score = 0.8
  $row.ScoreTip = 'Total: 8.0: cv +1.0; skills +1.0'
  $row.Meta.Source = $Source
  $row.Meta.summary = [SummaryInfo]::new()
  $row.Meta.summary.text = "Summary for $Id"
  $row.Meta.summary.source = 'local'
  $row.Meta.summary.model = 'test-model'
  $row.Meta.summary_source = 'local'
  $row.Meta.summary_model = 'test-model'
  $row.Meta.scores = [ScoreInfo]::new()
  $row.Meta.scores.cv = 0.2
  $row.Meta.scores.skills = 0.4
  $row.Meta.scores.total = 0.8
  $row.PublishedAtUtc = (Get-Date).ToUniversalTime()
  $row.SearchTiers = $Tiers
  $row.SearchStage = if ($Tiers -and $Tiers.Count -gt 0) { $Tiers[0] } else { 'base' }
  $row.KeySkills = @('skill-a','skill-b')
  $row.Salary = [SalaryInfo]::new()
  $row.Salary.Text = "$Id salary"
  $row.EmployerRating = 4.2
  $row.EmployerOpenVacancies = 12
  $row.EmployerIndustryShort = 'IT'
  $row.IsEditorsChoice = ($Id -eq 'row-ec')
  $row.EditorsWhy = if ($row.IsEditorsChoice) { 'Editors pick' } else { '' }
  $row.IsLucky = ($Id -eq 'row-lucky')
  $row.LuckyWhy = if ($row.IsLucky) { 'Random pick' } else { '' }
  $row.IsWorst = ($Id -eq 'row-worst')
  $row.WorstWhy = if ($row.IsWorst) { 'Worst pick' } else { '' }
  return $row
}

Describe 'Canonical CSV export contract' -Tag @('FR-7.4','FR-7.5','SDD-4.14','FR-16.1') {
  It 'writes hh.csv and no legacy CSV artifacts' {
    $rows = @(
      (New-CsvContractRow -Id 'row-ec' -Source 'hh' -Tiers @('base','tier1')),
      (New-CsvContractRow -Id 'row-lucky' -Source 'getmatch' -Tiers @('gm'))
    )
    $outDir = Join-Path $TestDrive 'csv-only'
    $csvPath = Render-CSVReport -Rows $rows -OutputsRoot $outDir
    $csvPath | Should -Be (Join-Path $outDir 'hh.csv')
    Test-Path -LiteralPath $csvPath | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $outDir 'hh_report.csv') | Should -BeFalse
    $csvFiles = Get-ChildItem -Path $outDir -Filter '*.csv'
    $csvFiles.Count | Should -Be 1
    $csvFiles[0].Name | Should -Be 'hh.csv'
  }

  It 'exposes expected CSV schema and typed values' {
    $rows = @(
      (New-CsvContractRow -Id 'row-1' -Source 'hh' -Tiers @('base','tier1')),
      (New-CsvContractRow -Id 'row-2' -Source 'getmatch' -Tiers @('gm','tier2'))
    )
    $outDir = Join-Path $TestDrive 'csv-schema'
    $csvPath = Render-CSVReport -Rows $rows -OutputsRoot $outDir
    $lines = Get-Content -LiteralPath $csvPath
    $header = ($lines[0].Split(',') | ForEach-Object { $_.Trim('"') })
    $expected = @('id','title','salary_text','employer','employer_industry','city','country','source','score','score_text','badges','is_editors_choice','is_lucky','is_worst','editors_why','lucky_why','worst_why','published_utc','published_utc_str','relative_age','employer_rating','employer_open_vacancies','url','tip','summary','summary_source','summary_model','key_skills','search_tiers')
    $header.Length | Should -Be $expected.Count
    for ($i = 0; $i -lt $expected.Count; $i++) {
      $header[$i] | Should -Be $expected[$i]
    }
    $csvRows = Import-Csv -LiteralPath $csvPath
    $csvRows.Count | Should -Be 2
    $csvRows[0].search_tiers | Should -Be 'base,tier1'
    $csvRows[0].summary_source | Should -Be 'local'
    $csvRows[0].summary_model | Should -Be 'test-model'
    $csvRows[0].source | Should -Be 'hh'
    $csvRows[1].source | Should -Be 'getmatch'
    $csvRows[0].key_skills | Should -Match 'skill-a'
  }

  It 'rejects PSCustomObject wrappers to enforce typed pipeline' {
    $threw = $false
    $message = ''
    try {
      Render-CSVReport -Rows @([pscustomobject]@{ id = 'legacy' }) -OutputsRoot (Join-Path $TestDrive 'csv-bad')
    }
    catch {
      $threw = $true
      $message = $_.Exception.Message
    }
    $threw | Should -BeTrue
    $message | Should -Match 'CanonicalVacancy'
  }
}
