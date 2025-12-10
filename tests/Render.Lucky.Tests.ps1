Import-Module ./modules/hh.log.psm1 -Force
Import-Module ./modules/hh.config.psm1 -Force
Import-Module ./modules/hh.tmpl.psm1 -Force
Import-Module ./modules/hh.models.psm1 -Force
Import-Module ./modules/hh.render.psm1 -Force

Describe 'Lucky rendering when is_lucky present' {
  It 'renders card-lucky and pill-lucky' {
    Ensure-HHModelTypes; $rowLucky = [CanonicalVacancy]::new()
    $rowLucky.id = 'r1'
    $rowLucky.title = 'Lucky Vacancy'
    $rowLucky.url = 'https://hh.ru/vacancy/r1'
    $rowLucky.city = 'Алматы'
    $rowLucky.country = 'KZ'
    $rowLucky.EmployerName = 'Acme'
    $rowLucky.IsLucky = $true
    $rowLucky.LuckyWhy = 'Promising remote fit'
    $picks = @{ lucky = @{ title = 'Lucky Vacancy'; link = 'https://hh.ru/vacancy/r1'; employer = @{ name = 'Acme' }; city = 'Алматы'; lucky_why = 'Promising remote fit' } }
    $outPath = Join-Path 'data/outputs' 'test_lucky.html'
    $null = Render-HtmlReport -Rows @($rowLucky) -OutPath $outPath
    $content = Get-Content $outPath -Raw
    $content | Should -Match 'card-lucky'
    $content | Should -Match 'pill-lucky'
  }
}
