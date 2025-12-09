# hh.report.psm1 — ReportProjection builder (typed-only CanonicalVacancy)
using module ./hh.models.psm1
#Requires -Version 7.5

<#
.SYNOPSIS
Builds a renderer-ready ReportProjection object from typed CanonicalVacancy rows.

.DESCRIPTION
Consumes only CanonicalVacancy instances and projects them into a flat shape used
by CSV/JSON/HTML renderers. No PSCustomObject wrappers are accepted; callers must
pass typed rows produced by the pipeline.
#>
function Get-ReportProjection {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [CanonicalVacancy[]]$Rows,
    $Context = $null
  )

  Ensure-HHModelTypes

  # Field mapping (FRD/SDD):
  #  - source: CanonicalVacancy.Meta.Source (hh_general, hh_recommendation, hh_web_recommendation, getmatch, etc.)
  #  - search_tiers: CanonicalVacancy.SearchTiers (comma-separated tier origins)
  #  - summary_source/summary_model: canonical Meta.summary_source and Meta.summary_model (local/remote)
  #  - picks flags: based on CanonicalVacancy.IsEditorsChoice/IsLucky/IsWorst with EditorsWhy/LuckyWhy/WorstWhy

  $rowsArr = @($Rows | Where-Object { $_ -is [CanonicalVacancy] })
  $rowsTotal = $rowsArr.Count

  function _S($v) { if ($null -eq $v) { return '' } return [string]$v }
  function _Arr([object]$value) {
    $arr = @()
    foreach ($item in @($value)) {
      if ($null -ne $item) { $arr += $item }
    }
    return $arr
  }
  function _Coalesce($a, $b) {
      if (-not [string]::IsNullOrWhiteSpace($a)) { return [string]$a }
      if (-not [string]::IsNullOrWhiteSpace($b)) { return [string]$b }
      return ''
  }

  # Resolve meta
  $runStartedUtc = ''
  try {
    $rsu = (Get-Variable -Name RunStartedUtc -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    if ($rsu) { $runStartedUtc = $rsu.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
  }
  catch {}
  if ([string]::IsNullOrWhiteSpace($runStartedUtc)) {
    $runStartedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }

  $runDurationSec = 0
  try {
    $rsl = (Get-Variable -Name RunStartedLocal -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    if ($rsl) { $runDurationSec = [int]((Get-Date) - $rsl).TotalSeconds }
  }
  catch {}

  $queryText = ''
  try {
    $pl = (Get-Variable -Name PipelineState -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    if ($pl -and $pl.Search -and $pl.Search.Text) {
      $queryText = [string]$pl.Search.Text
    }
  }
  catch {}
  if ([string]::IsNullOrWhiteSpace($queryText)) {
    try {
      $dl = (Get-Variable -Name DigestLabel -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
      if (-not [string]::IsNullOrWhiteSpace($dl)) { $queryText = [string]$dl }
    }
    catch {}
  }

  $projRows = New-Object System.Collections.Generic.List[object]

  foreach ($canon in $rowsArr) {
    if (-not $canon) { continue }

    $id = _Coalesce $canon.Id $canon.id
    $title = _Coalesce $canon.Title $canon.title
    $url = _Coalesce $canon.Url $canon.link
    if ([string]::IsNullOrWhiteSpace($url) -and $id) { $url = "https://hh.ru/vacancy/$id" }

    $emp = $canon.Employer
    $empName = $canon.EmployerName
    if ([string]::IsNullOrWhiteSpace($empName) -and $emp) { $empName = $emp.name }
    
    $empLogo = $canon.EmployerLogoUrl
    if ([string]::IsNullOrWhiteSpace($empLogo) -and $emp) { $empLogo = $emp.logo }
    
    $empUrl = $null
    if ($emp) { $empUrl = $emp.Url }
    
    $empRating = $canon.EmployerRating
    $empOpen = $canon.EmployerOpenVacancies
    
    $empIndustry = $canon.EmployerIndustryShort
    if ([string]::IsNullOrWhiteSpace($empIndustry) -and $emp) { $empIndustry = $emp.industry }

    $sal = $canon.Salary
    $salaryFrom = $sal?.from
    $salaryTo = $sal?.to
    $salaryCur = _Coalesce $sal?.currency $sal?.Currency
    $salaryUpperCap = $sal?.UpperCap
    if ($salaryUpperCap -eq $null) { $salaryUpperCap = $sal?.upper_cap }

    $salaryText = ''
    if ($sal) {
      $fmtCulture = [System.Globalization.CultureInfo]::InvariantCulture.Clone()
      $fmtCulture.NumberFormat.NumberGroupSeparator = ' ' # Use space for thousands
      $fmtCulture.NumberFormat.NumberDecimalDigits = 0    # No decimal digits
      
      $sym = ''
      if ($sal.currency) {
        if (Get-Command -Name 'hh.util\Get-SalarySymbol' -ErrorAction SilentlyContinue) {
          $sym = hh.util\Get-SalarySymbol -Currency $salaryCur
        }
        if ([string]::IsNullOrWhiteSpace($sym)) { $sym = $salaryCur } # Fallback to code if helper not available
      }

      $fromFormatted = ''
      if ($salaryFrom) { $fromFormatted = ([double]$salaryFrom).ToString('N0', $fmtCulture) }
      $toFormatted = ''
      if ($salaryTo) { $toFormatted = ([double]$salaryTo).ToString('N0', $fmtCulture) }

      if ($fromFormatted -and $toFormatted) {
          $salaryText = "$fromFormatted – $toFormatted $sym"
      }
      elseif ($fromFormatted) {
          $salaryText = "от $fromFormatted $sym"
      }
      elseif ($toFormatted) {
          $salaryText = "до $toFormatted $sym"
      }
    }

    $city = _Coalesce $canon.City $canon.city
    $country = _Coalesce $canon.Country $canon.country
    $publishedAge = _Coalesce $canon.AgeText $canon.age_text
    if (-not $publishedAge) { $publishedAge = _S($canon.AgeTooltip) }
    $publishedAt = $canon.PublishedAtUtc ?? $canon.published_at
    
    if (-not $publishedAge -and $publishedAt) {
      $span = (Get-Date).ToUniversalTime() - $publishedAt
      if ($span.TotalDays -ge 1) { $publishedAge = "{0:0}d" -f $span.TotalDays }
      elseif ($span.TotalHours -ge 1) { $publishedAge = "{0:0}h" -f $span.TotalHours }
      else { $publishedAge = "new" }
    }
    
    $publishedHover = ''
    if ($publishedAt) {
       $publishedHover = $publishedAt.ToLocalTime().ToString('dd MMMM', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    # Score and tooltip
    $scoreTotal = 0.0
    try { $scoreTotal = [double]($canon.Score ?? $canon.score ?? 0) } catch {}
    $scoresObj = $canon.Meta?.scores
    $penObj = $canon.Meta?.penalties
    $scoreBreak = ''
    $scoreCoreTip = ''
    if ($scoresObj) {
      $labelMap = @{
        total       = 'Итого'
        skills      = 'Навыки'
        salary      = 'Зарплата'
        recency     = 'Свежесть'
        seniority   = 'Опыт'
      }
      $fmt = {
        param($k, $v)
        try {
          $label = if ($labelMap.ContainsKey($k)) { $labelMap[$k] } else { [string]$k }
          $val = [double]$v
          $sign = if ($val -ge 0) { '+' } else { '-' }
          $abs = [math]::Round([math]::Abs($val * 10.0), 1)
          return "$label $sign$abs"
        }
        catch { return "$k $v" }
      }
      $parts = @()
      foreach ($key in @('skills', 'salary', 'seniority', 'recency')) {
        $vv = $scoresObj.$key
        if ($vv -ne $null) { $parts += (& $fmt $key $vv) }
      }
      $coreParts = @()
      foreach ($key in @('skills', 'salary', 'seniority', 'recency')) {
        $vv = $scoresObj.$key
        if ($vv -ne $null) { $coreParts += (& $fmt $key $vv) }
      }
      $totalTxt = ''
      if ($scoresObj.total -ne $null) { $totalTxt = "Total: " + ([math]::Round(([double]$scoresObj.total * 10.0), 1)) }
      elseif ($scoreTotal -ne $null) { $totalTxt = "Total: " + ([math]::Round(([double]$scoreTotal * 10.0), 1)) }

      $penTxt = ''
      if ($penObj) {
        $penParts = @()
        foreach ($pkey in @('dup', 'culture', 'rating_boost')) {
          $pv = $penObj.$pkey
          if ($pv -ne $null) {
            $sign = if ($pkey -eq 'rating_boost') { '+' } else { '-' }
            $valAbs = [math]::Round([math]::Abs([double]$pv * 10.0), 1)
            $label = switch ($pkey) { 'dup' { 'дубликаты' } 'culture' { 'культура' } 'rating_boost' { 'рейтинг' } default { $pkey } }
            $penParts += ("$label $sign$valAbs")
          }
        }
        if ($penParts.Count -gt 0) { $penTxt = ' | penalties: ' + ($penParts -join '; ') }
      }

      $scoreBreak = ($totalTxt + ': ' + ($parts -join '; ') + $penTxt).Trim()
      $scoreCoreTip = (($coreParts -join '; ') + $penTxt).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($scoreBreak)) { $scoreBreak = ('Total: ' + [math]::Round(([double]$scoreTotal * 10.0))) }

    # badges
    $badgesNorm = @()
    foreach ($bx in @($canon.badges)) {
      if (-not $bx) { continue }
      $k = [string]$bx.kind
      $l = [string]$bx.label
      if ([string]::IsNullOrWhiteSpace($l) -and $k) { $l = $k }
      if ($k) {
        $isRemote = ($k -eq 'remote')
        $badgesNorm += ([pscustomobject]@{ kind = $k; label = $l; is_remote = $isRemote })
      }
    }
    $badgesText = if ($badgesNorm.Count -gt 0) { (@($badgesNorm | ForEach-Object { $_.label }) -join ' ') } else { _S($canon.badges_text) }
    $hasRemoteBadge = ($badgesNorm | Where-Object { $_.is_remote }).Count -gt 0

    # skills
    if (-not (Get-Command -Name 'hh.util\Normalize-SkillToken' -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -Name 'hh.util')) { Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/hh.util.psm1') -DisableNameChecking }
    }

    $skillsObj = $canon.Skills
    $skillsScore = 0.0
    $skillsPresent = @()
    $skillsRecommended = @()
    if ($skillsObj) {
      try { $skillsScore = [double]$skillsObj.Score } catch {}
      $skillsPresent = _Arr($skillsObj.MatchedVacancy)
      $skillsRecommended = _Arr($skillsObj.MissingForCV)
    }
    $skillsMatchedCount = (_Arr($skillsObj.MatchedVacancy)).Count
    $keySkills = _Arr($canon.KeySkills)
    
    # Enrich skills with status
    $skillsRich = @()
    $presentSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in $skillsPresent) { if ($s) { [void]$presentSet.Add($s) } }
    
    foreach ($ks in $keySkills) {
        $n = $ks
        if (Get-Command -Name 'hh.util\Normalize-SkillToken' -ErrorAction SilentlyContinue) {
            $n = hh.util\Normalize-SkillToken -Token $ks
        }
        $stat = if ($presentSet.Contains($n)) { 'matched' } else { 'missing' }
        $skillsRich += [pscustomobject]@{ name = $ks; status = $stat }
    }

    $searchTiersList = _Arr($canon.SearchTiers)
    $searchTiersText = ($searchTiersList -join '|')

    $summarySource = _Coalesce $canon.Meta.summary_source $canon.Meta.summary.source
    $summaryModel = _Coalesce $canon.Meta.summary_model $canon.Meta.summary.model
    
    # Priority: Canonical Summary (Surface) > Meta.Summary.Text
    # Note: Pipeline already overwrites these with Remote text when available
    $summaryText = _Coalesce $canon.Summary $canon.Meta.summary.text
    
    if ($summaryText) {
      $summaryText = $summaryText -replace '<highlighttext>', '' -replace '</highlighttext>', ''
    }

    $isEc = [bool]($canon.Picks?.IsEditorsChoice ?? $canon.IsEditorsChoice)
    $isLucky = [bool]($canon.Picks?.IsLucky ?? $canon.IsLucky)
    $isWorst = [bool]($canon.Picks?.IsWorst ?? $canon.IsWorst)
    
    # Prefer nested picks text, fallback to root
    $ecWhy = _Coalesce $canon.Picks?.EditorsWhy $canon.EditorsWhy
    $lWhy = _Coalesce $canon.Picks?.LuckyWhy $canon.LuckyWhy
    $wWhy = _Coalesce $canon.Picks?.WorstWhy $canon.WorstWhy

    # Search Tiers mapping
    $searchTiersRaw = _Arr($canon.SearchTiers)
    $searchTiersFriendly = @()
    foreach ($t in $searchTiersRaw) {
      switch -Regex ($t) {
        'web_recommendation' { $searchTiersFriendly += 'Web Rec' }
        'similar'            { $searchTiersFriendly += 'Similar' }
        'general'            { $searchTiersFriendly += 'General' }
        'getmatch'           { $searchTiersFriendly += 'Getmatch' }
        default              { $searchTiersFriendly += $t }
      }
    }
    $searchTiersText = ($searchTiersFriendly -join ', ')

    # Employer URL enrichment for HH
    if ([string]::IsNullOrWhiteSpace($empUrl) -and ($canon.Meta?.Source -eq 'hh')) {
        $eId = $canon.Employer?.Id
        if (-not [string]::IsNullOrWhiteSpace($eId)) {
            $empUrl = "https://hh.ru/employer/$eId"
        }
    }

    $projRows.Add([pscustomobject]@{
        id                      = $id
        title                   = $title
        url                     = $url
        published_age_text      = $publishedAge
        published_at_hover      = $publishedHover
        published_at            = $publishedAt
        relative_age            = $publishedAge
        employer_name           = $empName
        employer_logo_url       = $empLogo
        employer_url            = $empUrl # Add employer_url to projection
        employer_rating         = $empRating
        employer_open_vacancies = $empOpen
        employer_industry       = $empIndustry
        salary_text             = $salaryText
        seniority_level         = 0
        seniority_label         = ''
        salary_from             = $salaryFrom
        salary_to               = $salaryTo
        salary_currency         = $salaryCur
        salary_upper_cap        = if ($salaryUpperCap) { [double]$salaryUpperCap } else { 0 }
        salary                  = [pscustomobject]@{ text = $salaryText; from = $salaryFrom; to = $salaryTo; currency = $salaryCur; upper_cap = $salaryUpperCap }
        score                   = [double]$scoreTotal
        score_total             = [double]$scoreTotal
        score_display           = ("{0:0.0}" -f ([double]$scoreTotal * 10.0))
        score_text              = $scoreBreak
        score_breakdown         = $scoreBreak
        score_core_tooltip      = $scoreCoreTip
        badges                  = @($badgesNorm)
        has_remote_badge        = $hasRemoteBadge
        badges_text             = $badgesText
        skills                  = @($skillsRich)
        skills_score            = $skillsScore
        skills_present          = @($skillsPresent)
        skills_recommended      = @($skillsRecommended)
        skills_matched_count    = $skillsMatchedCount
        key_skills              = $keySkills
        summary                 = $summaryText
        summary_lang            = _S($canon.Meta.summary.lang)
        llm_summary             = _S($canon.Meta.llm_summary.text)
        summary_source          = $summarySource
        summary_model           = $summaryModel
        local_llm               = $canon.Meta.local_llm_relevance
        city                    = $city
        country                 = $country
        employer_place          = if ($country -and ($country -ne 'Россия') -and ($country -ne 'Russia')) { if ($city) { "$city, $country" } else { $country } } else { $city }
        is_editors_choice       = $isEc
        is_lucky                = $isLucky
        is_worst                = $isWorst
        editors_why             = $ecWhy
        lucky_why               = $lWhy
        worst_why               = $wWhy
        search_tiers            = $searchTiersText
        search_tiers_list       = $searchTiersRaw
        source                  = _S($canon.Meta.Source)
        meta                    = $canon.Meta
        picks                   = $canon.Picks
      })
  }

  # Picks selection: find the row that has the flag set
  $pickEc = $rowsArr | Where-Object { ($_.Picks?.IsEditorsChoice -eq $true) -or ($_.IsEditorsChoice -eq $true) } | Select-Object -First 1
  $pickLucky = $rowsArr | Where-Object { ($_.Picks?.IsLucky -eq $true) -or ($_.IsLucky -eq $true) } | Select-Object -First 1
  $pickWorst = $rowsArr | Where-Object { ($_.Picks?.IsWorst -eq $true) -or ($_.IsWorst -eq $true) } | Select-Object -First 1
  
  # Remove redundant fallback for pickWorst here, because Apply-Picks guarantees one is selected if rows exist.
  # If pickWorst is null here, it means Apply-Picks didn't select one (e.g. no rows), or data is inconsistent.
  # We trust Apply-Picks.

  $picks = [ordered]@{
    ec    = if ($pickEc) { @{ id = $pickEc.Id; title = $pickEc.Title; employer = $pickEc.EmployerName; score_total = $pickEc.Score; editors_why = _Coalesce $pickEc.Picks?.EditorsWhy $pickEc.EditorsWhy } } else { $null }
    lucky = if ($pickLucky) { @{ id = $pickLucky.Id; title = $pickLucky.Title; employer = $pickLucky.EmployerName; score_total = $pickLucky.Score; lucky_why = _Coalesce $pickLucky.Picks?.LuckyWhy $pickLucky.LuckyWhy } } else { $null }
    worst = if ($pickWorst) { @{ id = $pickWorst.Id; title = $pickWorst.Title; employer = $pickWorst.EmployerName; score_total = $pickWorst.Score; worst_why = _Coalesce $pickWorst.Picks?.WorstWhy $pickWorst.WorstWhy } } else { $null }
  }

  # User Requirement: No synthesized text for picks (especially Worst).
  # We leave them empty if not provided by LLM.

  # Sort rows by score descending before returning
  $sortedRows = $projRows | Sort-Object -Property score -Descending

  $meta = [ordered]@{
    run_started_utc  = $runStartedUtc
    run_duration_sec = $runDurationSec
    query_text       = $queryText
    rows_total       = $rowsTotal
    show_summaries   = ($projRows.Count -gt 0)
  }

  return [pscustomobject]@{
    meta  = $meta
    picks = $picks
    rows  = $sortedRows
  }
}

Export-ModuleMember -Function Get-ReportProjection
