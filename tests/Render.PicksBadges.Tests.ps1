Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.log.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.config.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.render.psm1') -Force -DisableNameChecking

Describe 'Render picks badges' {
  It 'HTML contains LUCKY and WORST pills' {
    Ensure-HHModelTypes
$row = [CanonicalVacancy]::new()
$row.id='p1'; $row.title='One'; $row.url='https://hh.ru/vacancy/p1'; $row.published_at=(Get-Date).ToUniversalTime();
$row.employer_name='Acme'; $row.employer_logo_url=''; $row.employer_rating=0.0; $row.employer_open_vacancies=0; $row.employer_industry='';
$row.score_total=0.5; $row.score_breakdown=''; $row.score_core_tooltip='';
$row.is_lucky=$true; $row.lucky_why='why'; $row.is_worst=$true; $row.worst_why='bad'; $row.is_editors_choice=$false;
$row.skills=@(); $row.skills_score=0; $row.skills_present=@(); $row.skills_recommended=@(); $row.skills_matched_count=0;
$row.summary='S'; $row.summary_lang='ru'; $row.summary_source='fallback'; $row.local_llm=0.0; $row.city=''; $row.country=''; $row.employer_place='';
$rows = @($row)
    $out = Join-Path $PSScriptRoot 'temp_render_picks.html'
    Render-HtmlReport -Rows $rows -OutPath $out | Out-Null
    $html = Get-Content -LiteralPath $out -Raw
    $html | Should -Match 'pick-lucky'
    $html | Should -Match 'pick-worst'
  }
}
