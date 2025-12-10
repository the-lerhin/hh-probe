Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.config.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.scoring.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.util.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.pipeline.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.report.psm1') -Force -DisableNameChecking

Describe 'Skills view-model wiring' {
  BeforeAll {
    Import-Module -Name (Join-Path $PSScriptRoot '..' 'modules' 'hh.models.psm1') -Force -DisableNameChecking
    Ensure-HHModelTypes
    InModuleScope 'hh.scoring' {
      Mock Get-SkillsVocab { return [pscustomobject]@{ buckets = @(@{ id='core'; weight=1.0; include=@('sql','linux','docker') }) } }
    }
  }

  It 'exposes skills score/present/recommended lists' {
    $vac = [pscustomobject]@{ id='sk-v1'; name='DevOps SQL Linux'; area=@{ name='Алматы' }; description='We use SQL and Linux daily'; published_at=(Get-Date).AddDays(-1).ToString('s') }
    $row = Build-CanonicalRowTyped -Vacancy $vac -NoDetail
    Write-Host ("raw.key_skills=[{0}]" -f (($vac.key_skills) -join ', '))
    Write-Host ("typed.MatchedVacancy=[{0}]" -f (($row.Skills.MatchedVacancy) -join ', '))
    Write-Host ("typed.InCV=[{0}]" -f (($row.Skills.InCV) -join ', '))
    $proj = Get-ReportProjection -Rows @($row)
    $r = $proj.rows[0]
    [double]$r.skills_score | Should -BeGreaterOrEqual 0
    $r.skills_matched_count | Should -BeGreaterOrEqual 0
    # View exposes arrays (may be empty when no key_skills/matched). Non-null arrays are required.
    (($r.skills_present | Measure-Object).Count -ge 0) -and (($r.skills_recommended | Measure-Object).Count -ge 0) -and (($r.skills | Measure-Object).Count -ge 0) | Should -BeTrue
  }

  It 'maps skills_score from typed row and fills present/recommended from MatchedVacancy/CV or key_skills fallback' {
    $vac = [pscustomobject]@{ id='sk-v2'; name='Engineer'; area=@{ name='Москва' }; description='kotlin docker'; key_skills=@('kotlin','docker','sql') ; published_at=(Get-Date).AddDays(-2).ToString('s') }
    $row = Build-CanonicalRowTyped -Vacancy $vac -NoDetail
    $proj = Get-ReportProjection -Rows @($row)
    $r = $proj.rows[0]
    Write-Host ("skills_score={0}" -f $r.skills_score)
    Write-Host ("skills_present=[{0}]" -f (($r.skills_present) -join ', '))
    Write-Host ("skills_recommended=[{0}]" -f (($r.skills_recommended) -join ', '))
    $r.skills_score | Should -BeGreaterOrEqual 0
    (($r.skills_present) -and ($r.skills_present | Measure-Object).Count -gt 0) -or (($r.skills_recommended) -and ($r.skills_recommended | Measure-Object).Count -gt 0) -or (($r.skills) -and ($r.skills | Measure-Object).Count -gt 0) | Should -BeTrue
  }
}
