param()

# Import renderer and typed models
$renderPath = Join-Path $PSScriptRoot '..' 'modules' 'hh.render.psm1' -Resolve
Import-Module -Force $renderPath
$modelsPath = Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1' -Resolve
Import-Module -Force $modelsPath

Describe 'JSON Render LLM meta smoke' {
  It 'emits meta_llm_summary with nested text/source/lang in both files' {
    # Arrange minimal typed canonical row with LLM summary meta
    Ensure-HHModelTypes; $row = [CanonicalVacancy]::new()
    $row.Id = 'json-1'
    $row.Title = 'Test Vacancy'
    $row.Url = 'https://example.com/v/1'
    $row.Employer = (New-Object -TypeName EmployerInfo -Property @{ name = 'Acme' })
    $row.Country = 'RU'
    $row.City = 'Moscow'
    $row.Salary = (New-Object -TypeName SalaryInfo -Property @{ text = '100 000 RUR' })
    $row.PublishedAtUtc = [Nullable[datetime]]::new((Get-Date).ToUniversalTime())
    $row.Score = 0.5
    $row.Meta = New-Object -TypeName MetaInfo
    $row.Meta.summary = (New-Object -TypeName SummaryInfo -Property @{ text = 'Fallback summary'; source = 'fallback'; lang = 'ru' })
    $row.Meta.llm_summary = (New-Object -TypeName SummaryInfo -Property @{ text = 'LLM says hi'; source = 'llm'; lang = 'en' })

    # Act
    $outRoot = Join-Path (Join-Path $PSScriptRoot '..') 'data/outputs'
    Render-JsonReport -Rows @($row) -OutputsRoot $outRoot

    $canonicalPath = Join-Path $outRoot 'hh_canonical.json'
    $reportPath    = Join-Path $outRoot 'hh_report.json'

    # Assert files exist
    Test-Path $canonicalPath | Should -BeTrue
    Test-Path $reportPath    | Should -BeTrue

    # Parse canonical rows
    $canonRows = Get-Content -Path $canonicalPath -Raw | ConvertFrom-Json
    $canonRows | Should -Not -BeNullOrEmpty
    $canonRows.Count | Should -BeGreaterThan 0

    $cr = $canonRows[0]
    $cr.meta_llm_summary | Should -Not -BeNullOrEmpty
    $cr.meta_llm_summary.text   | Should -Be 'LLM says hi'
    $cr.meta_llm_summary.source | Should -Be 'llm'
    $cr.meta_llm_summary.lang   | Should -Be 'en'

    # Raw key name check (ensure underscore key preserved)
    $canonRaw = Get-Content -Path $canonicalPath -Raw
    $canonRaw | Should -Match '"meta_llm_summary"'

    # Parse wrapped report
    $wrapped = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
    $wrapped | Should -Not -BeNullOrEmpty
    $wrapped.items | Should -Not -BeNullOrEmpty
    $wrapped.items.Count | Should -BeGreaterThan 0

    $wr = $wrapped.items[0]
    $wr.meta_llm_summary.text   | Should -Be 'LLM says hi'
    $wr.meta_llm_summary.source | Should -Be 'llm'
    $wr.meta_llm_summary.lang   | Should -Be 'en'
  }
}
