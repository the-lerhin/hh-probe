Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.log.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.config.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.render.psm1') -Force -DisableNameChecking

Describe 'Render picks badges' {
  It 'HTML contains LUCKY and WORST pills' {
    # Ensure-HHModelTypes
$row = [CanonicalVacancy]::new()
$row.id='p1'; $row.title='One'; $row.url='https://hh.ru/vacancy/p1'; $row.published_at=(Get-Date).ToUniversalTime();
$row.EmployerName='Acme'; $row.EmployerLogoUrl=''; $row.EmployerRating=0.0; $row.EmployerOpenVacancies=0; $row.EmployerIndustryShort='';
$row.Score=0.5; $row.ScoreTip='';
$row.IsLucky=$true; $row.LuckyWhy='why'; $row.IsWorst=$true; $row.WorstWhy='bad'; $row.IsEditorsChoice=$false;
$row.skills=New-Object SkillsInfo; $row.skills.Score=0;
$row.Summary='S'; $row.meta.summary.lang='ru'; $row.meta.summary.source='fallback'; $row.meta.local_llm_relevance=0.0; $row.city=''; $row.country='';
$rows = @($row)
    $out = Join-Path $PSScriptRoot 'temp_render_picks.html'
    Render-HtmlReport -Rows $rows -OutPath $out | Out-Null
    $html = Get-Content -LiteralPath $out -Raw
    $html | Should -Match 'pill-lucky'
    $html | Should -Match 'pill-worst'
  }
}
