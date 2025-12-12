using module ./hh.models.psm1

$RepoRoot = Split-Path -Path $PSScriptRoot -Parent

if (-not (Get-Module -Name 'hh.log')) {
  Import-Module (Join-Path $RepoRoot 'modules/hh.log.psm1') -DisableNameChecking
}



# hh.render.psm1 — Render layer module (CSV/JSON/HTML)
#Requires -Version 7.5



function Convert-ToGenericModel {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  # Dictionaries
  if ($Value -is [System.Collections.IDictionary]) {
    $exp = [System.Dynamic.ExpandoObject]::new()
    $expdic = [System.Collections.Generic.IDictionary[string, object]]$exp
    foreach ($k in $Value.Keys) {
      $keyStr = [string]$k
      $expdic[$keyStr] = Convert-ToGenericModel $Value[$k]
    }
    return $exp
  }
  # Arrays/Enumerables (but not strings)
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Value) { $list.Add((Convert-ToGenericModel $item)) }
    return $list
  }
  # PSCustomObject/PSObject
  if ($Value -is [System.Management.Automation.PSObject] -or $Value -is [pscustomobject]) {
    $props = $Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' }
    $exp = [System.Dynamic.ExpandoObject]::new()
    $expdic = [System.Collections.Generic.IDictionary[string, object]]$exp
    foreach ($p in $props) { $expdic[$p.Name] = Convert-ToGenericModel $p.Value }
    return $exp
  }
  return $Value
}

<#
 .SYNOPSIS
   Recursively converts PSCustomObject, PSObject, IDictionary, and IEnumerable
   into plain PowerShell hashtables and arrays while preserving nested structure.

 .DESCRIPTION
   This function builds a deep hashtable/array representation of arbitrary
   PowerShell objects so that templating engines (Handlebars.Net) can reliably
   access properties like {{name}} and nested fields like {{this.employer.name}}.
   Strings and scalars are returned unchanged; complex objects are flattened
   into hashtables/arrays with the same property names.

 .PARAMETER Value
   The input object to convert.

 .OUTPUTS
   Hashtable, Object[] or scalar values.
#>
function Convert-ToDeepHashtable {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  # Dictionaries -> Hashtable
  if ($Value -is [System.Collections.IDictionary]) {
    $ht = @{}
    foreach ($k in $Value.Keys) { $ht[[string]$k] = Convert-ToDeepHashtable $Value[$k] }
    return $ht
  }
  # Arrays/Enumerables (but not strings) -> Object[]
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $arr = @()
    foreach ($item in $Value) { $arr += , (Convert-ToDeepHashtable $item) }
    return $arr
  }
  # PSCustomObject/PSObject -> Hashtable
  if ($Value -is [System.Management.Automation.PSObject] -or $Value -is [pscustomobject]) {
    $ht = @{}
    $props = $Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' }
    foreach ($p in $props) { $ht[$p.Name] = Convert-ToDeepHashtable $p.Value }
    return $ht
  }
  return $Value
}

function Get-FriendlyLocalTime {
  param([object]$Value)
  if (-not $Value) { return '' }
  try {
    $dt = [datetime]$Value
    return $dt.ToLocalTime().ToString('dd MMM yyyy HH:mm')
  }
  catch {
    return [string]$Value
  }
}

function Normalize-RenderRows {
  <#
  .SYNOPSIS
  Flattens nested row collections so renderers always see a simple vacancy list.

  .DESCRIPTION
  Some call paths can accidentally pass a list as a single element (e.g., a
  `[object[]]` inside another array). This helper unwraps enumerable elements
  unless they are PSCustomObject or CanonicalVacancy instances, so downstream
  renderers do not trip on `System.Object[]` when casting fields.
  #>
  param([object[]]$Rows)
  $flat = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $isRowObject = $false
    try { $isRowObject = ($r -is [CanonicalVacancy]) } catch {}
    $shouldFlatten = $false
    if (-not $isRowObject) {
      if ($r -is [System.Array]) { $shouldFlatten = $true }
      elseif (($r -is [System.Collections.IEnumerable]) -and ($r -isnot [string])) { $shouldFlatten = $true }
    }
    if ($shouldFlatten) {
      foreach ($sub in $r) { if ($null -ne $sub) { $flat.Add($sub) } }
    }
    else {
      $flat.Add($r)
    }
  }
  return $flat.ToArray()
}

function Get-HtmlRenderContext {
  param(
    [object[]]$CanonicalRows,
    [int]$RowCount,
    $PipelineState = $null
  )

  $summaryView = [ordered]@{
    started_local       = ''
    started_local_short = ''
    duration_text       = ''
    search_label        = ''
    query_text          = ''
    keywords            = @()
    keywords_text       = ''
    items_fetched       = $RowCount
    rows_rendered       = $RowCount
    views_total         = 0
    invites_total       = 0
    llm_cached          = 0
    llm_queried         = 0
    resume_hint         = ''
    flags_text          = ''
    new_vacancies       = ''
  }
  $viewsDetail = @()
  $invitesDetail = @()
  $state = $PipelineState
  if (-not $state) {
    try { $state = Get-Variable -Name PipelineState -Scope Global -ValueOnly -ErrorAction SilentlyContinue } catch {}
  }

  if ($state) {
    try {
      if (-not (Get-Module -Name 'hh.core')) {
        Import-Module (Join-Path $PSScriptRoot 'hh.core.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
      }
      if (Get-Command -Name Get-HHPipelineSummary -ErrorAction SilentlyContinue) {
        $rawSummary = Get-HHPipelineSummary -State $state
        if ($rawSummary) {
          if ($rawSummary.StartedLocal) {
            try {
              $local = [datetime]$rawSummary.StartedLocal
              $summaryView.started_local = $local.ToString('dd MMM yyyy HH:mm')
              $summaryView.started_local_short = $local.ToString('dd MMM HH:mm')
            }
            catch {}
          }
          if (-not [string]::IsNullOrWhiteSpace($rawSummary.SearchLabel)) {
            $summaryView.search_label = [string]$rawSummary.SearchLabel
          }
          if (-not [string]::IsNullOrWhiteSpace($rawSummary.SearchQuery)) {
            $summaryView.query_text = [string]$rawSummary.SearchQuery
          }
          if ($rawSummary.Keywords) {
            # Force unpack
            $kwList = @(); foreach ($k in $rawSummary.Keywords) { if ($k) { $kwList += [string]$k } }
            $summaryView.keywords = $kwList
            if ($summaryView.keywords.Count -gt 0) {
              $summaryView.keywords_text = ($summaryView.keywords -join ' · ')
            }
          }
          $itemsFetched = 0
          $rowsRendered = 0
          try { $itemsFetched = [int]$rawSummary.ItemsFetched } catch {}
          try { $rowsRendered = [int]$rawSummary.RowsRendered } catch {}
          if ($itemsFetched -gt 0) { $summaryView.items_fetched = $itemsFetched }
          if ($rowsRendered -gt 0) { $summaryView.rows_rendered = $rowsRendered }
          $summaryView.views_total = [int]$rawSummary.Views
          $summaryView.invites_total = [int]$rawSummary.Invites
          $summaryView.llm_cached = [int]$rawSummary.LlmCached
          $summaryView.llm_queried = [int]$rawSummary.LlmQueried
          if ($rawSummary.Duration -and $rawSummary.Duration -ne [timespan]::Zero) {
            try { $summaryView.duration_text = $rawSummary.Duration.ToString('hh\:mm\:ss') } catch {}
          }
          if ($rawSummary.Flags) {
            try {
              $summaryView.flags_text = ($rawSummary.Flags.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key }) -join ' · '
            }
            catch {}
          }
        }
      }
    }
    catch {}

    try {
      $meta = $state.Metadata
      if ($meta) {
        if ($meta.Views) {
          foreach ($view in @($meta.Views)) {
            if (-not $view) { continue }
            $empName = ''
            try { $empName = [string]($view.employer?.name ?? $view.employer_name ?? '') } catch {}
            if ([string]::IsNullOrWhiteSpace($empName)) { $empName = '—' }
            $dtText = ''
            try {
              if ($view.dt_utc) {
                $dt = [datetime]$view.dt_utc
                $dtText = $dt.ToLocalTime().ToString('dd MMM HH:mm')
              }
            }
            catch {}
            $viewsDetail += , ([ordered]@{
                employer = $empName
                dt       = $dtText
              })
          }
        }
        if ($meta.Invites) {
          foreach ($invite in @($meta.Invites)) {
            if (-not $invite) { continue }
            $empName = ''
            try { $empName = [string]($invite.employer?.name ?? '') } catch {}
            if ([string]::IsNullOrWhiteSpace($empName)) { $empName = '—' }
            $dtText = ''
            try {
              if ($invite.dt_utc) {
                $dt = [datetime]$invite.dt_utc
                $dtText = $dt.ToLocalTime().ToString('dd MMM HH:mm')
              }
            }
            catch {}
            $invitesDetail += , ([ordered]@{
                employer = $empName
                dt       = $dtText
              })
          }
        }
      }
    }
    catch {}
  }

  if ([string]::IsNullOrWhiteSpace($summaryView.search_label)) {
    try {
      $fallbackLabel = (Get-Variable -Name DigestLabel -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
      if ($fallbackLabel) { $summaryView.search_label = [string]$fallbackLabel }
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace($summaryView.search_label)) {
    try {
      $st = (Get-Variable -Name SearchText -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
      if ($st) {
        $stText = [string]$st
        $tokens = @()
        try { $tokens = @($stText -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } } catch {}
        if ($tokens -and $tokens.Count -gt 0) {
          # Force unpack to pure string array
          $cleanTokens = @(); foreach ($t in $tokens) { $cleanTokens += [string]$t }
          $summaryView.keywords = $cleanTokens
          $summaryView.keywords_text = ($cleanTokens -join ' · ')
          $summaryView.search_label = $summaryView.keywords_text
        }
        else {
          $summaryView.search_label = $stText
        }
      }
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace($summaryView.resume_hint)) {
    try {
      if (Get-Command -Name 'hh.cv\Get-HHEffectiveProfile' -ErrorAction SilentlyContinue) {
        $prof = hh.cv\Get-HHEffectiveProfile
        if ($prof -and $prof.Title) {
           $summaryView.resume_hint = $prof.Title
        } elseif ($prof -and $prof.HHResumeId) {
           $summaryView.resume_hint = $prof.HHResumeId
        }
      }
    }
    catch {}
    
    if ([string]::IsNullOrWhiteSpace($summaryView.resume_hint)) {
      try {
        $resumeId = (Get-Variable -Name ResumeId -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        if ($resumeId) { $summaryView.resume_hint = [string]$resumeId }
      }
      catch {}
    }
  }

  if ([string]::IsNullOrWhiteSpace($summaryView.search_label) -and -not [string]::IsNullOrWhiteSpace($summaryView.keywords_text)) {
    $summaryView.search_label = $summaryView.keywords_text
  }

  if ([string]::IsNullOrWhiteSpace($summaryView.started_local)) {
    try {
      $runLocal = (Get-Variable -Name RunStartedLocal -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
      if ($runLocal -is [datetime]) {
        $summaryView.started_local = $runLocal.ToString('dd MMM yyyy HH:mm')
        $summaryView.started_local_short = $runLocal.ToString('dd MMM HH:mm')
      }
    }
    catch {}
  }

  $skillsPopular = @()
  try {
    if (-not (Get-Module -Name 'hh.pipeline')) {
      Import-Module (Join-Path $PSScriptRoot 'hh.pipeline.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
    }
    if (Get-Command -Name Aggregate-SkillsPopularity -ErrorAction SilentlyContinue) {
      $agg = Aggregate-SkillsPopularity -Rows $CanonicalRows
      if ($agg) {
        foreach ($entry in ($agg | Select-Object -First 24)) {
          $skillsPopular += , ([ordered]@{
              skill = [string]$entry.Skill
              count = [int]$entry.Count
            })
        }
      }
    }
  }
  catch {}

  return [ordered]@{
    summary = [pscustomobject]$summaryView
    views   = $viewsDetail
    invites = $invitesDetail
    skills  = $skillsPopular
  }
}

function Build-Picks {
  param([object[]]$Rows)

  $ec = $Rows | Where-Object { $(try { [bool]($_.picks.is_editors_choice) } catch { $false }) -or $(try { [bool]($_.picks.IsEditorsChoice) } catch { $false }) } | Select-Object -First 1
  $lucky = $Rows | Where-Object { $(try { [bool]($_.picks.is_lucky) } catch { $false }) -or $(try { [bool]($_.picks.IsLucky) } catch { $false }) } | Select-Object -First 1
  $worst = $Rows | Where-Object { $(try { [bool]($_.picks.is_worst) } catch { $false }) -or $(try { [bool]($_.picks.IsWorst) } catch { $false }) } | Select-Object -First 1

  # Ensure hh.tmpl is loaded for conversion
  if (-not (Get-Command -Name Convert-ToPlainHashtable -ErrorAction SilentlyContinue)) {
    if (-not (Get-Module -Name 'hh.tmpl')) {
      try { Import-Module -Name (Join-Path $PSScriptRoot 'hh.tmpl.psm1') -DisableNameChecking } catch {}
    }
  }

  return @{
    ec    = if ($ec) { Convert-ToPlainHashtable -InputObject $ec } else { $null }
    lucky = if ($lucky) { Convert-ToPlainHashtable -InputObject $lucky } else { $null }
    worst = if ($worst) { Convert-ToPlainHashtable -InputObject $worst } else { $null }
  }
}

function Get-HoverDate {
  param([datetime]$Date)
  
  $culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
  $text = $Date.ToString('dd MMM', $culture)
  return $text.ToLowerInvariant()
}

function Format-SalaryText {
  param([Parameter(Mandatory = $true)][object]$Salary)
  $from = $null; $to = $null; $sym = ''
  try { $from = $Salary.from } catch {}
  try { $to = $Salary.to } catch {}
  try { $sym = [string]($Salary.symbol ?? '') } catch {}
  if ([string]::IsNullOrWhiteSpace($sym) -and $Salary.currency) { 
    $sym = $Salary.currency 
  }
  
  $fmtCulture = [System.Globalization.CultureInfo]::InvariantCulture.Clone()
  $fmtCulture.NumberFormat.NumberGroupSeparator = ' '
  $fmtCulture.NumberFormat.NumberDecimalDigits = 0

  $fromFormatted = if ($from) { ([double]$from).ToString('N0', $fmtCulture) } else { '' }
  $toFormatted = if ($to) { ([double]$to).ToString('N0', $fmtCulture) } else { '' }

  if ($fromFormatted -and $toFormatted) { return "$fromFormatted – $toFormatted $sym" }
  if ($fromFormatted) { return "от $fromFormatted $sym" }
  if ($toFormatted) { return "до $toFormatted $sym" }
  return ''
}

function Format-EmployerPlace {
  param([string]$Country, [string]$City)
  $c = [string]($Country ?? '')
  $city = [string]($City ?? '')
  if ($c -match '^(?i)(россия|russia|ru)$') { return $city }
  if ([string]::IsNullOrWhiteSpace($c)) { return $city }
  if ([string]::IsNullOrWhiteSpace($city)) { return $c }
  return ("{0}, {1}" -f $c, $city)
}

function Get-CanonicalSource {
  param([Parameter(Mandatory)][object]$Row)
  
  # PHASE 2 REFACTOR: Rows are now typed CanonicalVacancy objects directly
  # No wrapper to unwrap - just return the row
  return $Row
}

try {
  $null = New-Object -TypeName CanonicalVacancy -ErrorAction Stop
}
catch {
  try {
    if (-not (Get-Module -Name 'hh.models')) {
      Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/hh.models.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
    }
  }
  catch {}
}

function Build-ViewRow {
  param([Parameter(Mandatory = $true)][psobject]$Row, [datetime]$Now = $(Get-Date))
  if ($null -ne $Now) { <# Suppress unused param warning #> }
  $canon = Get-CanonicalSource $Row

  $id = ''; $title = ''; $url = ''
  try { $id = [string]($canon.Id ?? $canon.id ?? '') } catch { <# Suppress #> }
  try { $title = [string]($canon.Title ?? $canon.title ?? '') } catch { <# Suppress #> }
  try { $url = [string]($canon.Url ?? $canon.Link ?? $canon.link ?? $canon.url ?? '') } catch { <# Suppress #> }
  if ([string]::IsNullOrWhiteSpace($url) -and $id) { $url = "https://hh.ru/vacancy/$id" }

  $city = ''; $country = ''
  try { $city = [string]($canon.City ?? $canon.city ?? '') } catch { <# Suppress #> }
  try { $country = [string]($canon.Country ?? $canon.country ?? '') } catch { <# Suppress #> }

  $summary = ''
  $llm = ''
  try { $summary = [string]($canon.Summary ?? $canon.Meta?.Summary?.Text ?? $canon.meta?.summary?.text ?? '') } catch { <# Suppress #> }
  try { if ([string]::IsNullOrWhiteSpace($summary)) { $summary = [string]($Row.summary ?? $Row.meta?.summary?.text ?? '') } } catch { <# Suppress #> }
  try { $llm = [string]($canon.Meta?.llm_summary?.Text ?? $canon.meta?.llm_summary?.text ?? '') } catch { <# Suppress #> }
  try { if ([string]::IsNullOrWhiteSpace($llm)) { $llm = [string]($Row.llm_summary ?? $Row.meta?.llm_summary?.text ?? '') } } catch { <# Suppress #> }

  $metaSource = ''
  try { $metaSource = [string]($canon.Meta?.Source ?? $canon.meta?.source ?? '') } catch { <# Suppress #> }

  $picksObj = $canon.Picks
  if (-not $picksObj) { try { $picksObj = $canon.picks } catch { <# Suppress #> } }
  $isEc = $false; $isLucky = $false; $isWorst = $false
  try { $isEc = [bool]($canon.IsEditorsChoice ?? $picksObj?.IsEditorsChoice ?? $picksObj?.is_editors_choice ?? $canon.is_editors_choice) } catch { <# Suppress #> }
  try { $isLucky = [bool]($canon.IsLucky ?? $picksObj?.IsLucky ?? $picksObj?.is_lucky ?? $canon.is_lucky) } catch { <# Suppress #> }
  try { $isWorst = [bool]($canon.IsWorst ?? $picksObj?.IsWorst ?? $picksObj?.is_worst ?? $canon.is_worst) } catch { <# Suppress #> }

  $empOpen = $null; $empRating = $null
  try { $empOpen = $canon.EmployerOpenVacancies } catch {}
  if ($null -eq $empOpen) { try { $empOpen = $canon.Employer?.Open } catch {} }
  if ($null -eq $empOpen) { try { $empOpen = $Row.employer_open_vacancies } catch {} }
  if ($null -eq $empOpen) { try { $empOpen = $Row.employer?.open } catch {} }

  try { $empRating = $canon.EmployerRating } catch {}
  if ($null -eq $empRating) { try { $empRating = $canon.Employer?.Rating } catch {} }
  if ($null -eq $empRating) { try { $empRating = $Row.employer_rating } catch {} }
  if ($null -eq $empRating) { try { $empRating = $Row.employer?.rating } catch {} }

  $salaryObj = $null
  try { $salaryObj = $canon.Salary } catch {}
  if (-not $salaryObj) { try { $salaryObj = $Row.salary } catch {} }
  $salFrom = $null; $salTo = $null; $salSym = ''
  
  if ($salaryObj) {
    try { $salFrom = $salaryObj.from } catch {}
    if ($null -eq $salFrom) { try { $salFrom = $salaryObj.From } catch {} }
    
    try { $salTo = $salaryObj.to } catch {}
    if ($null -eq $salTo) { try { $salTo = $salaryObj.To } catch {} }
    
    try { $salSym = [string]($salaryObj.symbol ?? $salaryObj.Symbol ?? '') } catch {}
  }
  
  if ($null -eq $salFrom) { try { $salFrom = $Row.salary_from } catch {} }
  if ($null -eq $salTo) { try { $salTo = $Row.salary_to } catch {} }
  
  if ([string]::IsNullOrWhiteSpace($salSym)) { try { $salSym = [string]$Row.salary_symbol } catch {} }
  if ([string]::IsNullOrWhiteSpace($salSym) -and $salaryObj) { 
    try { 
      $cur = [string]($salaryObj.currency ?? $salaryObj.Currency)
      if (-not [string]::IsNullOrWhiteSpace($cur)) {
        $salSym = Get-SalarySymbol -Currency $cur 
      }
    }
    catch {} 
  }
  $st = Format-SalaryText -Salary ([pscustomobject]@{ from = $salFrom; to = $salTo; symbol = $salSym; currency = $salSym })
  if ([string]::IsNullOrWhiteSpace($st)) {
    $upper = $null
    try { $upper = $salaryObj?.UpperCap } catch {}
    if ($null -eq $upper -or [double]$upper -le 0) { try { $upper = [double]$Row.salary_upper_cap } catch { <# Suppress #> } }
    if ($null -ne $upper -and [double]$upper -gt 0) {
      $fmt = [System.Globalization.CultureInfo]::InvariantCulture
      $st = ([string]::Format($fmt, "{0:N0} {1}", [double]$upper, $salSym))
    }
    if ([string]::IsNullOrWhiteSpace($st)) {
      try {
        $stFallback = [string]($salaryObj?.Text ?? $Row.salary_text ?? '')
        if (-not [string]::IsNullOrWhiteSpace($stFallback)) { $st = $stFallback }
      }
      catch {}
    }
  }

  $result = [pscustomobject]@{
    id          = $id
    title       = $title
    link        = $url
    city        = $city
    country     = $country
    summary     = $summary
    llm_summary = $llm
    picks       = @{ is_ec = $isEc; is_lucky = $isLucky; is_worst = $isWorst }
    employer    = @{ open = $empOpen; rating = $empRating }
    salary      = @{ text = $st }
    source      = $metaSource
    ranking     = if ($canon.Meta.ranking) { $canon.Meta.ranking } else { $null }
  }
  
  return $result
}

function Escape-Attr {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return '' }
  return $Value.Replace('"', '&quot;').Replace("'", '&apos;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('&', '&amp;')
}

function Render-CSVReport {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
    [string]$OutputsRoot
  )
  Write-Log -Message "[Render/CSV] begin" -Level Verbose -Module 'Render'
  $repoRoot = Split-Path -Path $PSScriptRoot -Parent
  Ensure-HHModelTypes
  if (-not (Get-Module -Name 'hh.config')) {
    $cfgPath = Join-Path $repoRoot 'modules/hh.config.psm1'
    if (Test-Path $cfgPath) { Import-Module $cfgPath -DisableNameChecking -ErrorAction SilentlyContinue }
  }
  if (-not (Get-Module -Name 'hh.http')) {
    $httpPath = Join-Path $repoRoot 'modules/hh.http.psm1'
    if (Test-Path $httpPath) { Import-Module $httpPath -DisableNameChecking -ErrorAction SilentlyContinue }
  }
  if (-not (Get-Module -Name 'hh.report')) {
    $reportPath = Join-Path $repoRoot 'modules/hh.report.psm1'
    if (Test-Path $reportPath) { Import-Module $reportPath -DisableNameChecking -ErrorAction SilentlyContinue }
  }
  $reportCmd = Get-Command -Name Get-ReportProjection -ErrorAction SilentlyContinue
  if (-not $reportCmd) {
    throw "Render-CSVReport requires Get-ReportProjection from hh.report (typed pipeline invariant)"
  }
  $root = if (-not [string]::IsNullOrWhiteSpace($OutputsRoot)) { $OutputsRoot } else { Join-Path $repoRoot 'data/outputs' }
  try { New-Item -ItemType Directory -Force -Path $root | Out-Null } catch {}
  $csvPath = Join-Path $root 'hh.csv'
  $employerDetailMemo = @{}
  $hasApi = Get-Command -Name Invoke-HhApiRequest -ErrorAction SilentlyContinue
  $getEmployerDetailCmd = Get-Command -Name Get-EmployerDetail -ErrorAction SilentlyContinue
  if (-not $getEmployerDetailCmd) {
    $fetchPath = Join-Path $repoRoot 'modules/hh.fetch.psm1'
    if (Test-Path $fetchPath) {
      try { Import-Module $fetchPath -DisableNameChecking -ErrorAction SilentlyContinue } catch {}
      $getEmployerDetailCmd = Get-Command -Name Get-EmployerDetail -ErrorAction SilentlyContinue
    }
  }
  try {
    $Rows = Normalize-RenderRows -Rows $Rows
    $typedRows = @()
    foreach ($raw in $Rows) {
      $typed = Get-CanonicalSource -Row $raw
      if (-not ($typed -is [CanonicalVacancy])) {
        $rowType = $typed.GetType().FullName
        throw "Render-CSVReport expects CanonicalVacancy rows (received $rowType)"
      }
      $typedRows += , $typed
    }
    $projection = Get-ReportProjection -Rows $typedRows
    $projIndex = @{}
    if ($projection -and $projection.rows) {
      foreach ($projRow in $projection.rows) {
        if ($projRow -and $projRow.id) {
          $projIndex[[string]$projRow.id] = $projRow
        }
      }
    }

    $outRows = @()
    foreach ($r in $typedRows) {
      $projRow = $null
      if ($projIndex.ContainsKey([string]$r.Id)) {
        $projRow = $projIndex[[string]$r.Id]
      }
      $tipVal = if ($Debug) { [string]($r.ScoreTip ?? '') } else { $null }

      # Extract from nested canonical structure with proper null handling
      $salaryText = $null
      if ($projRow) {
        try { $val = $projRow.salary_text; if (-not [string]::IsNullOrWhiteSpace($val)) { $salaryText = [string]$val } } catch {}
      }
      if (-not $salaryText) {
        try { $val = $r.Salary.Text ?? $r.salary?.text ?? $r.salary_text; if (-not [string]::IsNullOrWhiteSpace($val)) { $salaryText = [string]$val } } catch {}
      }

      $employerName = $null
      if ($projRow) { try { $val = $projRow.employer_name; if (-not [string]::IsNullOrWhiteSpace($val)) { $employerName = [string]$val } } catch {} }
      if (-not $employerName) {
        try { $val = $r.Employer.Name ?? $r.employer?.name ?? $r.employer_name; if (-not [string]::IsNullOrWhiteSpace($val)) { $employerName = [string]$val } } catch {}
      }

      $employerRating = $null
      if ($projRow -and $projRow.employer_rating -ne $null) {
        try { $employerRating = [double]$projRow.employer_rating } catch {}
      }
      if ($null -eq $employerRating) {
        try { $val = $r.EmployerRating ?? $r.Employer.Rating ?? $r.employer?.rating ?? $r.employer_rating; if ($null -ne $val -and [double]$val -gt 0) { $employerRating = [double]$val } } catch { <# Suppress #> }
      }

      $employerOpen = $null
      if ($projRow -and $projRow.employer_open_vacancies -ne $null) {
        try { $employerOpen = [int]$projRow.employer_open_vacancies } catch {}
      }
      if ($null -eq $employerOpen) {
        try { $val = $r.EmployerOpenVacancies ?? $r.Employer.Open ?? $r.employer?.open ?? $r.employer?.open_vacancies ?? $r.employer_open_vacancies; if ($null -ne $val -and [int]$val -gt 0) { $employerOpen = [int]$val } } catch { <# Suppress #> }
      }

      $employerIndustry = $null
      if ($projRow) {
        try { $val = $projRow.employer_industry; if (-not [string]::IsNullOrWhiteSpace($val)) { $employerIndustry = [string]$val } } catch {}
      }
      if (-not $employerIndustry) {
        try { $val = $r.EmployerIndustryShort ?? $r.Employer.Industry ?? $r.employer?.industry ?? $r.employer_industry; if (-not [string]::IsNullOrWhiteSpace($val)) { $employerIndustry = [string]$val } } catch {}
      }

      # Best-effort enrichment via cached employer detail for HH rows with missing fields
      $empId = $null
      try { $empId = $r.Employer.Id ?? $r.employer?.id ?? $r.employer_id } catch {}
      $src = $null
      if ($projRow) { try { $src = [string]$projRow.source } catch {} }
      if (-not $src) {
        try { $src = $r.Meta.Source ?? $r.meta?.source } catch {}
      }
      if ($empId -and $src -ne 'getmatch' -and $getEmployerDetailCmd -and (-not $employerIndustry -or -not $employerRating -or -not $employerOpen)) {
        $cachedDetail = $null
        if ($employerDetailMemo.ContainsKey($empId)) {
          $cachedDetail = $employerDetailMemo[$empId]
        }
        else {
          # Prefer cache-only lookup before hitting HTTP
          if (Get-Command -Name Get-HHCacheItem -ErrorAction SilentlyContinue) {
            try {
              $env = Get-HHCacheItem -Collection 'employers' -Key $empId -AsEnvelope
              if ($env -and $env.Value) { $cachedDetail = $env.Value }
            }
            catch { <# Suppress #> }
          }
          if (-not $cachedDetail -and $hasApi) {
            try { $cachedDetail = Get-EmployerDetail -Id $empId } catch { $cachedDetail = $null }
          }
          $employerDetailMemo[$empId] = $cachedDetail
        }
        if ($cachedDetail) {
          if (-not $employerIndustry) {
            try {
              if ($cachedDetail.industry -and $cachedDetail.industry.name) { $employerIndustry = [string]$cachedDetail.industry.name }
              elseif ($cachedDetail.industries -and $cachedDetail.industries.Count -gt 0) { $employerIndustry = [string]$cachedDetail.industries[0].name }
            }
            catch { <# Suppress #> }
          }
          if (-not $employerRating -and $null -ne $cachedDetail.rating) {
            try { $employerRating = [double]$cachedDetail.rating } catch { <# Suppress #> }
          }
          if (-not $employerOpen -and $null -ne $cachedDetail.open_vacancies) {
            try { $employerOpen = [int]$cachedDetail.open_vacancies } catch { <# Suppress #> }
          }
        }
      }


      $publishedUtc = $null
      if ($projRow -and $projRow.published_at) {
        try {
          $val = $projRow.published_at
          if ($val -is [datetime]) { $publishedUtc = $val.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
          else { $publishedUtc = [string]$val }
        }
        catch {}
      }
      if (-not $publishedUtc) {
        try { $val = $r.PublishedAt ?? $r.published_at ?? $r.published_at_utc ?? $r.meta?.pub_utc_str; if (-not [string]::IsNullOrWhiteSpace($val)) { $publishedUtc = [string]$val } } catch { <# Suppress #> }
      }

      $relativeAge = $null
      if ($projRow) { try { $val = $projRow.relative_age; if (-not [string]::IsNullOrWhiteSpace($val)) { $relativeAge = [string]$val } } catch {} }
      if (-not $relativeAge) {
        try { $val = $r.AgeText ?? $r.relative_age ?? $r.age_text ?? $r.meta?.relative_age; if (-not [string]::IsNullOrWhiteSpace($val)) { $relativeAge = [string]$val } } catch { <# Suppress #> }
      }

      $scoreText = $null
      if ($projRow) { try { $val = $projRow.score_text ?? $projRow.score_breakdown; if (-not [string]::IsNullOrWhiteSpace($val)) { $scoreText = [string]$val } } catch {} }
      if (-not $scoreText) {
        try { $val = $r.score_text ?? $r.score_display; if (-not [string]::IsNullOrWhiteSpace($val)) { $scoreText = [string]$val } } catch { <# Suppress #> }
      }
      if (-not $scoreText -and ($null -ne ($r.Score ?? $r.score))) { try { $scoreText = ("{0:0.00}" -f ([double]($r.Score ?? $r.score))) } catch { <# Suppress #> } }

      # PHASE 2 REFACTOR: Direct property access on typed CanonicalVacancy
      $summaryText = ''
      if ($projRow) { try { $summaryText = [string]($projRow.summary ?? '') } catch {} }
      if ([string]::IsNullOrWhiteSpace($summaryText)) {
        try { $summaryText = [string]($r.Meta.Summary.text ?? '') } catch { <# Suppress #> }
      }

      # PHASE 2 REFACTOR: Direct property access
      $summarySource = ''
      if ($projRow) { try { $summarySource = [string]($projRow.summary_source ?? '') } catch {} }
      if ([string]::IsNullOrWhiteSpace($summarySource)) {
        try { $summarySource = [string]($r.Meta.Summary.source ?? '') } catch { <# Suppress #> }
      }
      # PHASE 2 REFACTOR: Direct property access
      $summaryModel = ''
      if ($projRow) { try { $summaryModel = [string]($projRow.summary_model ?? '') } catch {} }
      if ([string]::IsNullOrWhiteSpace($summaryModel)) {
        try { $summaryModel = [string]($r.Meta.Summary.model ?? '') } catch { <# Suppress #> }
      }
      # PHASE 2 REFACTOR: Direct property access
      $searchTiersText = ''
      if ($projRow) {
        try {
          $tiers = @($projRow.search_tiers_list)
          if ($tiers.Count -gt 0) { $searchTiersText = ((@($tiers) | Where-Object { $_ }) -join ',') }
          elseif ($projRow.search_tiers) { $searchTiersText = ([string]$projRow.search_tiers).Replace('|', ',') }
        }
        catch {}
      }
      if ([string]::IsNullOrWhiteSpace($searchTiersText)) {
        try {
          $val = $r.SearchTiers
          if ($val -is [System.Collections.IEnumerable] -and ($val -isnot [string])) { 
            $searchTiersText = ((@($val) | Where-Object { $_ }) -join ',')
          }
          elseif ($val -is [string]) { 
            $searchTiersText = $val 
          }
          elseif ($r.SearchStage) {
            $searchTiersText = [string]$r.SearchStage
          }
        }
        catch { <# Suppress #> }
      }

      $keySkillsJoined = $null
      try {
        $skills = $null
        if ($projRow) { $skills = $projRow.key_skills }
        if (-not $skills) { $skills = $r.KeySkills ?? $r.key_skills ?? $r.skills_matched }
        if ($skills -and $skills.Count -gt 0) { $keySkillsJoined = (@($skills) -join '|') }
      }
      catch { <# Suppress #> }

      $outRows += [PSCustomObject]@{
        id                      = [string]($r.Id ?? $r.id)
        title                   = if ($projRow -and $projRow.title) { [string]$projRow.title } else { [string]($r.Title ?? $r.title) }
        salary_text             = $salaryText
        employer                = $employerName
        employer_industry       = $employerIndustry
        city                    = if ($projRow -and $projRow.city) { [string]$projRow.city } else { [string]($r.City ?? $r.city ?? '') }
        country                 = if ($projRow -and $projRow.country) { [string]$projRow.country } else { [string]($r.Country ?? $r.country ?? '') }
        source                  = if ($projRow -and $projRow.source) { [string]$projRow.source } else { [string]($r.Meta.Source ?? $r.meta?.source ?? '') }
        score                   = if ($projRow -and $projRow.score_total -ne $null) { [double]$projRow.score_total } elseif (($r.Score ?? $r.score) -ne $null) { [double]($r.Score ?? $r.score) } else { $null }
        score_text              = $scoreText
        badges                  = if ($projRow -and $projRow.badges_text) { [string]$projRow.badges_text } else { [string]($r.BadgesText ?? $r.badges_text ?? '') }
        is_editors_choice       = if ($projRow) { [bool]$projRow.is_editors_choice } else { [bool]($r.IsEditorsChoice ?? $r.is_editors_choice) }
        is_lucky                = if ($projRow) { [bool]$projRow.is_lucky } else { [bool]($r.IsLucky ?? $r.is_lucky) }
        is_worst                = if ($projRow) { [bool]$projRow.is_worst } else { [bool]($r.IsWorst ?? $r.is_worst) }

        editors_why             = if ($projRow -and $projRow.editors_why) { [string]$projRow.editors_why } else { [string]($r.EditorsWhy ?? $r.editors_why ?? $r.picks?.editors_why ?? '') }

        lucky_why               = if ($projRow -and $projRow.lucky_why) { [string]$projRow.lucky_why } else { [string]($r.LuckyWhy ?? $r.lucky_why ?? $r.picks?.lucky_why ?? '') }

        worst_why               = if ($projRow -and $projRow.worst_why) { [string]$projRow.worst_why } else { [string]($r.WorstWhy ?? $r.worst_why ?? $r.picks?.worst_why ?? '') }

        published_utc           = $publishedUtc
        published_utc_str       = $publishedUtc
        relative_age            = $relativeAge
        employer_rating         = $employerRating

        employer_open_vacancies = $employerOpen
        url                     = if ($projRow -and $projRow.url) { [string]$projRow.url } else { [string]($r.Url ?? $r.url) }
        tip                     = $tipVal
        summary                 = $summaryText
        summary_source          = $summarySource
        summary_model           = $summaryModel
        key_skills              = $keySkillsJoined
        search_tiers            = $searchTiersText
      }
    }
    $outRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Log -Message ("[Render/CSV] written: {0}" -f $csvPath) -Level Output -Module 'Render'
  }
  catch {
    Write-Log -Message ("[Render/CSV] failed: {0}" -f $_.Exception.Message) -Level Error -Module 'Render'
    throw
  }
  finally {
    try { Export-LatestECPicksCSV } catch {}
    Write-Log -Message "[Render/CSV] end" -Level Verbose -Module 'Render'
  }
  return $csvPath
}

function Convert-CanonicalToSerializable {
  param([Parameter(Mandatory = $true)][object]$Row)
  
  # Helper to safely get nested properties
  $emp = $Row.Employer
  $sal = $Row.Salary
  $meta = $Row.Meta
  $picks = $Row.Picks
  $skills = $Row.Skills
  
  $published_str = $null
  try {
    $p = $Row.PublishedAtUtc
    if ($p) {
      if ($p -is [datetime]) { $published_str = $p.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
      else { $published_str = $p.Value.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    }
  }
  catch {}

  $searchTiers = @()
  try { $searchTiers = @($Row.SearchTiers) } catch {}

  return [ordered]@{
    id                      = $Row.Id
    title                   = $Row.Title
    url                     = $Row.Url
    search_stage            = $Row.SearchStage
    search_tiers            = $searchTiers
    score                   = $Row.score
    
    salary_top              = $Row.SalaryTop
    salary_currency         = $Row.SalaryCurrency
    salary                  = if ($sal) {
      @{
        text      = $sal.text
        from      = $sal.from
        to        = $sal.to
        currency  = $sal.currency
        upper_cap = $sal.upper_cap
      } 
    }
    else { $null }
                              
    city                    = $Row.City
    country                 = $Row.Country
    is_non_ru_country       = $Row.IsNonRuCountry
    is_remote               = $Row.IsRemote
    is_relocation           = $Row.IsRelocation
    age_text                = $Row.AgeText
    age_tooltip             = $Row.AgeTooltip
    published_at            = $published_str
    published_at_utc        = $Row.PublishedAtUtc
    
    employer_id             = $Row.EmployerId
    employer_name           = $Row.EmployerName
    employer_logo_url       = $Row.EmployerLogoUrl
    employer_rating         = $Row.EmployerRating
    employer_open_vacancies = $Row.EmployerOpenVacancies
    employer_industry       = $Row.EmployerIndustryShort
    employer_accredited_it  = $Row.EmployerAccreditedIT
    employer                = if ($emp) {
      @{
        id             = $emp.id
        name           = $emp.name
        rating         = $emp.rating
        open_vacancies = $emp.open
        industry       = $emp.industry
        logo           = $emp.logo
      } 
    }
    else { $null }
                              
    picks                   = if ($picks) {
      @{
        is_editors_choice = $picks.IsEditorsChoice
        is_lucky          = $picks.IsLucky
        is_worst          = $picks.IsWorst
        editors_why       = $picks.EditorsWhy
        lucky_why         = $picks.LuckyWhy
        worst_why         = $picks.WorstWhy
      } 
    }
    else { $null }
                              
    is_editors_choice       = $Row.IsEditorsChoice
    is_lucky                = $Row.IsLucky
    is_worst                = $Row.IsWorst
    editors_why             = $Row.EditorsWhy
    lucky_why               = $Row.LuckyWhy
    worst_why               = $Row.WorstWhy
    
    skills_matched          = $Row.SkillsMatched
    skills                  = if ($skills) {
      @{
        score           = $skills.Score
        matched_vacancy = $skills.MatchedVacancy
        in_cv           = $skills.InCV
        missing_for_cv  = $skills.MissingForCV
      } 
    }
    else { $null }
                              
    summary                 = $Row.Summary
    description             = $Row.description
    badges                  = $Row.badges
    badges_text             = $Row.badges_text
    meta_summary            = if ($meta) { $meta.summary } else { $null }
    meta_llm_summary        = if ($meta) { $meta.llm_summary } else { $null }
    
    meta                    = if ($meta) {
      @{
        scores         = $meta.scores
        penalties      = $meta.penalties
        summary        = $meta.summary
        llm_summary    = $meta.llm_summary
        summary_source = if ($meta.summary_source) { $meta.summary_source } else { $meta.summary.source }
        summary_model  = if ($meta.summary_model) { $meta.summary_model } else { $meta.summary.model }
        source         = $meta.source
        search_stage   = $meta.search_stage
        Raw            = $meta.Raw
        ranking        = $meta.ranking
      } 
    }
    else { $null }
  }
}

function Render-JsonReport {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
    [string]$OutputsRoot
  )
  Write-Log -Message "[Render/JSON] begin" -Level Verbose -Module 'Render'
  $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
  $root = if (-not [string]::IsNullOrWhiteSpace($OutputsRoot)) { $OutputsRoot } else { Join-Path $repoRoot 'data/outputs' }
  try { New-Item -ItemType Directory -Force -Path $root | Out-Null } catch {}

  $Rows = Normalize-RenderRows -Rows $Rows

  # Filter for CanonicalVacancy objects only
  $canonicalRows = @()
  foreach ($row in $Rows) {
    if ($row -is [CanonicalVacancy]) { $canonicalRows += , $row }
  }

  $jsonPath = Join-Path $root 'hh_canonical.json'
  $wrappedPath = Join-Path $root 'hh_report.json'
  $serializerUsed = 'converttojson'
  $useNewtonsoft = $false
  $jsonDll = Join-Path $repoRoot 'bin/Newtonsoft.Json.dll'
  if (-not [bool]$env:HH_DISABLE_NEWTONSOFT) {
    if (Test-Path $jsonDll) {
      try {
        Add-Type -Path $jsonDll -ErrorAction Stop
        $useNewtonsoft = $true
      }
      catch {
        Write-Log -Message ("[Render/JSON] Newtonsoft load failed, falling back: {0}" -f $_.Exception.Message) -Level Warning -Module 'Render'
      }
    }
  }

  $convertedRows = @()
  try {
    # Convert typed CanonicalVacancy objects to serializable dictionaries
    foreach ($row in $canonicalRows) {
      try {
        $convertedRows += , (Convert-CanonicalToSerializable -Row $row)
      }
      catch {
        Write-Log -Message ("[Render/JSON] conversion failed for row {0}: {1}" -f ($row.Id ?? 'unknown'), $_.Exception.Message) -Level Warning -Module 'Render'
      }
    }
    
    if ($useNewtonsoft -and ([type]::GetType("Newtonsoft.Json.JsonConvert"))) {
      $settings = New-Object 'Newtonsoft.Json.JsonSerializerSettings'
      $settings.NullValueHandling = [Newtonsoft.Json.NullValueHandling]::Include
      $settings.ReferenceLoopHandling = [Newtonsoft.Json.ReferenceLoopHandling]::Ignore
      $settings.Formatting = [Newtonsoft.Json.Formatting]::Indented
      $json = [Newtonsoft.Json.JsonConvert]::SerializeObject($convertedRows, $settings)
      [System.IO.File]::WriteAllText($jsonPath, $json, [System.Text.Encoding]::UTF8)
      $serializerUsed = 'newtonsoft'
    }
    else {
      ($convertedRows | ConvertTo-Json -Depth 8) | Out-File -FilePath $jsonPath -Encoding utf8
      $serializerUsed = 'converttojson'
    }
    Write-Log -Message ("[Render/JSON] written: {0}" -f $jsonPath) -Level Output -Module 'Render'
  }
  catch {
    Write-Log -Message ("[Render/JSON] failed: {0}" -f $_.Exception.Message) -Level Error -Module 'Render'
  }
  
  # Generate Report Wrapper (hh_report.json)
  try {
    $nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    
    # Extract fields from the first converted row
    $fields = @()
    if ($convertedRows.Count -gt 0) {
      $fields = @($convertedRows[0].Keys)
    }

    # Find picks
    $pickEc = ($convertedRows | Where-Object { $_.is_editors_choice }) | Select-Object -First 1
    $pickLucky = ($convertedRows | Where-Object { $_.is_lucky }) | Select-Object -First 1
    $pickWorst = ($convertedRows | Where-Object { $_.is_worst }) | Select-Object -First 1
    
    $picksRoot = [ordered]@{
      ec    = if ($pickEc) { @{ id = $pickEc.id; title = $pickEc.title; url = $pickEc.url; editors_why = $pickEc.editors_why } } else { $null }
      lucky = if ($pickLucky) { @{ id = $pickLucky.id; title = $pickLucky.title; url = $pickLucky.url; lucky_why = $pickLucky.lucky_why } } else { $null }
      worst = if ($pickWorst) { @{ id = $pickWorst.id; title = $pickWorst.title; url = $pickWorst.url; worst_why = $pickWorst.worst_why } } else { $null }
    }

    $wrapped = [ordered]@{
      generated_at   = $nowUtc
      schema_version = $ConfigVersion
      total_items    = $convertedRows.Count
      fields         = $fields
      picks          = $picksRoot
      items          = $convertedRows
    }
    
    # Try to add projection rows if available
    try {
      if (-not (Get-Module -Name 'hh.report')) {
        Import-Module (Join-Path $PSScriptRoot 'hh.report.psm1') -DisableNameChecking
      }
      $proj = Get-ReportProjection -Rows $canonicalRows # Pass original typed rows
      if ($proj -and $proj.rows) {
        $wrapped['rows'] = $proj.rows
      }
    }
    catch {}
    
    ($wrapped | ConvertTo-Json -Depth 8) | Out-File -FilePath $wrappedPath -Encoding utf8
    Write-Log -Message ("[Render/JSON] written: {0}" -f $wrappedPath) -Level Output -Module 'Render'
  }
  catch {
    Write-Log -Message ("[Render/JSON] wrapper failed: {0}" -f $_.Exception.Message) -Level Error -Module 'Render'
  }
  Write-Log -Message "[Render/JSON] end" -Level Verbose -Module 'Render'
  return [pscustomobject]@{
    canonical_path = $jsonPath
    report_path    = (Join-Path $root 'hh_report.json')
    serializer     = $serializerUsed
  }
}

# Helper function to convert real HH API data to expected format
function ConvertFrom-HHRealData {
  param([Parameter(Mandatory = $true)][object[]]$RealData)
  
  $converted = @()
  foreach ($item in $RealData) {
    # Handle null employer gracefully
    $employerName = ''
    $employerRating = $null
    $employerLogoUrl = ''
    $employerAccredited = $false
    $employerTrusted = $false
    if ($item.employer) {
      $employerName = $item.employer.name ?? ''
      $employerRating = $item.employer.rating ?? $null
      $employerLogoUrl = $item.employer.logo_urls.original ?? ''
      $employerAccredited = [bool]($item.employer.accredited_it_employer ?? $false)
      $employerTrusted = [bool]($item.employer.trusted ?? $false)
    }
    
    # Handle null address gracefully
    $city = $item.address.city ?? ''
    
    # Handle null area gracefully
    $country = $item.area.name ?? ''
    
    # Format salary text properly
    $salaryText = ''
    if ($item.salary) {
      if ($item.salary.from -and $item.salary.to) {
        $salaryText = "$($item.salary.from) - $($item.salary.to) $($item.salary.currency)"
      }
      elseif ($item.salary.from) {
        $salaryText = "от $($item.salary.from) $($item.salary.currency)"
      }
      elseif ($item.salary.to) {
        $salaryText = "до $($item.salary.to) $($item.salary.currency)"
      }
    }
    
    # Clean up summary
    $summary = ''
    if ($item.description) {
      $summary = ($item.description -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
      if ($summary.Length -gt 300) {
        $summary = $summary.Substring(0, 300) + '...'
      }
    }
    
    # Extract skills as array of strings
    $skills = @()
    if ($item.key_skills -and $item.key_skills.Count -gt 0) {
      $skills = @($item.key_skills | ForEach-Object { $_.name })
    }
    
    # Extract work format badges
    $badges = @()
    if ($item.work_format -and $item.work_format.Count -gt 0) {
      foreach ($format in $item.work_format) {
        switch ($format.id) {
          'REMOTE' { $badges += '🌐' }  # Remote work
          'HYBRID' { $badges += '🔄' }  # Hybrid work
          'ON_SITE' { $badges += '🏢' }  # On-site work
          default { $badges += '📋' }   # Other formats
        }
      }
    }
    
    # Build employer meta information
    $employerMeta = @()
    if ($employerAccredited) { $employerMeta += '✅ IT-аккредитация' }
    if ($employerTrusted) { $employerMeta += '✅ Доверенный' }
    
    $convertedItem = [pscustomobject]@{
      id                  = $item.id
      title               = $item.name
      url                 = $item.alternate_url
      employer_name       = $employerName
      employer_rating     = $employerRating
      employer_logo_url   = $employerLogoUrl
      employer_accredited = $employerAccredited
      employer_trusted    = $employerTrusted
      employer_meta       = $employerMeta -join ' • '
      country             = $country
      city                = $city
      salary_text         = $salaryText
      summary             = $summary
      key_skills          = $skills
      badges              = $badges
      published_at        = $item.published_at
      relative_age        = if ($item.published_at) {
        $published = [DateTime]::Parse($item.published_at)
        $age = (Get-Date) - $published
        if ($age.Days -gt 0) { "$($age.Days)d" }
        elseif ($age.Hours -gt 0) { "$($age.Hours)h" }
        else { "$($age.Minutes)m" }
      }
      else { '' }
      score               = 0.5  # Default score for real data
      score_text          = '0.50'
    }
    $converted += $convertedItem
  }
  return $converted
}


<#
.SYNOPSIS
Renders HTML report using Handlebars template with typed CanonicalVacancy input.

.DESCRIPTION
Converts typed CanonicalVacancy objects to plain hashtables, builds the model with picks,
and renders the HTML report using Handlebars.Net. This is the main entry point for
the typed pipeline renderer.

.PARAMETER Rows
The typed CanonicalVacancy array to render in the report.

.PARAMETER TemplatePath
Path to the Handlebars template file.

.PARAMETER OutPath
Output path for the generated HTML file.

.OUTPUTS
String. Path to the generated HTML file.
#>
function Render-HtmlReport {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,   # CanonicalVacancy[]
    [string]$TemplatePath = (Join-Path $PSScriptRoot '..' 'templates' 'report.hbs'),
    [string]$OutPath = (Join-Path $PSScriptRoot '..' 'data' 'outputs' 'hh.html'),
    [int]$MaxRows = 0,
    [string]$DigestLabel = '',
    $PipelineState = $null
  )
  
  Write-Log -Message "[Render/HTML] Rendering typed report using Handlebars..." -Level Verbose -Module 'Render'
  
  $Rows = Normalize-RenderRows -Rows $Rows
  if ($null -eq $Rows) { $Rows = @() }
  
  # Import config for show_summaries setting
  try {

  }
  catch {
    Write-Log -Message ("[Render/HTML] Warning: Failed to import config module: {0}" -f $_.Exception.Message) -Level Warning -Module 'Render'
  }
  try {
    if (-not (Get-Module -Name 'hh.util')) {
      Import-Module (Join-Path $PSScriptRoot 'hh.util.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
    }
  }
  catch {}
  
  # Load Handlebars.Net.dll
  try {
    $hbDll = Join-Path $PSScriptRoot '..' 'bin' 'Handlebars.Net.dll'
    if (-not ('HandlebarsDotNet.Handlebars' -as [type]) -and (Test-Path $hbDll)) {
      Add-Type -Path $hbDll
    }
  }
  catch {
    Write-Log -Message ("[Render/HTML] Failed to load Handlebars.Net: {0}" -f $_.Exception.Message) -Level Error -Module 'Render'
    throw
  }
  
  # Prefer the shared projection builder to keep HTML/TG/JSON in sync
  $projection = $null
  $projectionRows = @()
  $projectionPicks = $null
  try {
    if (-not (Get-Module -Name 'hh.report')) {
      Import-Module (Join-Path $PSScriptRoot 'hh.report.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
    }
    if (Get-Command -Name Get-ReportProjection -ErrorAction SilentlyContinue) {
      $projection = Get-ReportProjection -Rows $Rows
      if ($projection) {
        if ($projection.rows) { $projectionRows = @($projection.rows) }
        if ($projection.picks) { $projectionPicks = $projection.picks }
        if ($MaxRows -gt 0 -and $projectionRows.Count -gt $MaxRows) {
          try { $projectionRows = @($projectionRows | Select-Object -First $MaxRows) } catch {}
        }
      }
    }
  }
  catch {
    Write-Log -Message ("[Render/HTML] projection build failed: {0}" -f $_.Exception.Message) -Level Warning -Module 'Render'
  }

  $picks = $null
  if ($projectionPicks) {
      $picks = $projectionPicks
  }
  else {
      $picks = Build-Picks -Rows $Rows
  }
  
  function New-DrillItemHtml {
    param(
      [Parameter(Mandatory = $true)] [object]$EmployerObj,
      [Parameter(Mandatory = $true)] [datetime]$WhenUtc
    )
  
    # Ensure dependencies
    if (-not (Get-Command Get-EmployerInfo -ErrorAction SilentlyContinue)) {
      if (-not (Get-Module -Name 'hh.pipeline')) {
        Import-Module (Join-Path $PSScriptRoot 'hh.pipeline.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
      }
    }
    if (-not (Get-Command Get-Relative -ErrorAction SilentlyContinue)) {
      if (-not (Get-Module -Name 'hh.util')) {
        Import-Module (Join-Path $PSScriptRoot 'hh.util.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
      }
    }

    $outer = $EmployerObj
    $info = $null
    try { $info = Get-EmployerInfo $EmployerObj } catch {}
    $logo = $null
    try { $logo = $info?.Logo } catch {}
    $ratingText = ''
    try {
      if ($info -and $info.Rating) { $ratingText = ("{0:0.0}★" -f [double]$info.Rating) }
    }
    catch {}

    $metaParts = New-Object System.Collections.Generic.List[string]
    try {
      if ($info -and $info.Industry -and (-not [string]::IsNullOrWhiteSpace($info.Industry))) {
        [void]$metaParts.Add([System.Net.WebUtility]::HtmlEncode([string]$info.Industry))
      }
    }
    catch {}
    try {
      if ($info -and $info.Size -and (-not [string]::IsNullOrWhiteSpace($info.Size))) {
        [void]$metaParts.Add([System.Net.WebUtility]::HtmlEncode([string]$info.Size))
      }
    }
    catch {}
    try {
      if ($info -and $info.OpenVac -and [double]$info.OpenVac -gt 0) {
        [void]$metaParts.Add("Open " + ([string][int][double]$info.OpenVac))
      }
    }
    catch {}
    try {
      if ($info -and $info.Type -and (-not [string]::IsNullOrWhiteSpace($info.Type))) {
        [void]$metaParts.Add([System.Net.WebUtility]::HtmlEncode([string]$info.Type))
      }
    }
    catch {}
    try {
      if ($info -and $info.Area -and (-not [string]::IsNullOrWhiteSpace($info.Area))) {
        [void]$metaParts.Add([System.Net.WebUtility]::HtmlEncode([string]$info.Area))
      }
    }
    catch {}
    try {
      if ($info -and $info.Trusted -eq $true) {
        [void]$metaParts.Add("✓ Trusted")
      }
    }
    catch {}
    try {
      if ($info -and $info.Accredited -eq $true) {
        [void]$metaParts.Add("✓ IT Accredited")
      }
    }
    catch {}
    $metaCombined = ($metaParts -join " · ")

    $rel = Get-Relative -UtcTime $WhenUtc
    $hover = $WhenUtc.ToLocalTime().ToString('dd MMM')

    $logoHtml = ''
    if ($logo) { $logoHtml = "<img class='dr-logo' src='" + (Escape-Attr $logo) + "' alt=''/>" }

    $safeName = ''
    try { $safeName = [System.Net.WebUtility]::HtmlEncode(($outer.name ?? '')) } catch {}
    $urlRaw = ''
    try { $urlRaw = $outer.alternate_url } catch {}
    $nameHtml = if (-not [string]::IsNullOrWhiteSpace($urlRaw)) { "<a href='" + (Escape-Attr $urlRaw) + "' target='_blank'>" + $safeName + "</a>" } else { $safeName }

    $ratingHtml = if (-not [string]::IsNullOrWhiteSpace($ratingText)) { "<span class='dr-rating'>" + [System.Net.WebUtility]::HtmlEncode($ratingText) + "</span>" } else { "" }
    $metaHtml = if (-not [string]::IsNullOrWhiteSpace($metaCombined)) { "<div class='dr-meta'>" + $metaCombined + "</div>" } else { "" }

    $timeHtml = "<span class='tip mono' data-tip='" + (Escape-Attr $hover) + "'>" + [System.Net.WebUtility]::HtmlEncode($rel) + "</span>"

    return "<div class='dr-item'><div class='dr-left'>" + $logoHtml + "<div><div class='dr-title'>" + $nameHtml + $ratingHtml + "</div>" + $metaHtml + "</div></div><div class='dr-right'>" + $timeHtml + "</div></div>"
  }

  function Ensure-StringArray {
    param([object]$Value)
    $items = @()
    foreach ($entry in @($Value)) {
      $txt = ''
      if ($null -eq $entry) { continue }
      if ($entry -is [System.Collections.IDictionary]) {
        try { $txt = [string]($entry['name'] ?? $entry['label'] ?? $entry['text'] ?? $entry['value']) } catch {}
      }
      elseif ($entry -is [psobject]) {
        try { $txt = [string]($entry.name ?? $entry.label ?? $entry.text ?? $entry.value) } catch {}
      }
      elseif ($entry -is [System.Management.Automation.PSMemberInfo]) {
        try { $txt = [string]($entry.Value ?? $entry.Name) } catch {}
      }
      if ([string]::IsNullOrWhiteSpace($txt)) {
        try { $txt = [string]$entry } catch { $txt = '' }
      }
      if (-not [string]::IsNullOrWhiteSpace($txt)) { $items += $txt }
    }
    return $items
  }

  function Ensure-ObjectArray {
    param([object]$Value)
    $items = @()
    foreach ($entry in @($Value)) {
      if ($null -eq $entry) { continue }
      $items += $entry
    }
    return $items
  }

  $preparedRows = @()
  if ($projectionRows.Count -gt 0) {
    foreach ($projRow in $projectionRows) {
      $plainRow = Convert-ToDeepHashtable $projRow
      if (-not $plainRow) { $plainRow = @{} }
      if (-not $plainRow['age_text']) {
        $ageLabel = $plainRow['published_age_text']
        if (-not $ageLabel -and $plainRow['relative_age']) { $ageLabel = $plainRow['relative_age'] }
        $plainRow['age_text'] = if ($ageLabel) { [string]$ageLabel } else { '' }
      }
      if (-not $plainRow['published_at_hover'] -and $plainRow['published_at']) {
        try { $plainRow['published_at_hover'] = Get-HoverDate ([datetime]$plainRow['published_at']) } catch { $plainRow['published_at_hover'] = '' }
      }
      $scoreBase = $plainRow['score_total']
      if ($null -eq $scoreBase) { $scoreBase = $plainRow['score'] }
      if ($scoreBase -eq $null) { $scoreBase = 0.0 }
      $plainRow['score_display'] = if ($plainRow['score_display']) { [string]$plainRow['score_display'] } else { ("{0:0.0}" -f ([double]$scoreBase * 10.0)) }
      if (-not $plainRow['score_text']) { $plainRow['score_text'] = $plainRow['score_display'] }
      if (-not $plainRow['score_numeric']) {
        try { $plainRow['score_numeric'] = [double]$scoreBase * 10.0 } catch { $plainRow['score_numeric'] = 0.0 }
      }
      $plainRow['skills_present'] = Ensure-StringArray $plainRow['skills_present']
      $plainRow['skills_recommended'] = Ensure-StringArray $plainRow['skills_recommended']
      $plainRow['skills'] = Ensure-ObjectArray $plainRow['skills']
      $plainRow['badges'] = Ensure-ObjectArray $plainRow['badges']
      if (-not $plainRow['summary']) { $plainRow['summary'] = '' }
      if (-not $plainRow['llm_summary']) { $plainRow['llm_summary'] = '' }
      if (-not $plainRow['salary'] -and $plainRow['salary_text']) {
        $plainRow['salary'] = @{ text = [string]$plainRow['salary_text'] }
      }
      $plainRow['score_breakdown'] = [string]$plainRow['score_breakdown']
      $plainRow['score_core_tooltip'] = [string]$plainRow['score_core_tooltip']
      $preparedRows += , $plainRow
    }
  }
  else {
    $rowsInput = $Rows
    if ($MaxRows -gt 0) { try { $rowsInput = @($Rows | Select-Object -First $MaxRows) } catch {} }
    foreach ($row in $rowsInput) {
      $preparedRows += , (Build-ViewRow -Row $row)
    }
  }
  
  $contextInfo = $null
  try { $contextInfo = Get-HtmlRenderContext -CanonicalRows $Rows -RowCount $preparedRows.Count -PipelineState $PipelineState } catch { $contextInfo = $null }
  $summaryBlock = $null; $viewsBlock = @(); $invitesBlock = @(); $skillsBlock = @()
  if ($contextInfo) {
    try { $summaryBlock = $contextInfo.summary } catch {}
    try { $viewsBlock = $contextInfo.views } catch {}
    try { $invitesBlock = $contextInfo.invites } catch {}
    try { $skillsBlock = $contextInfo.skills } catch {}
  }
  if (-not $summaryBlock) { $summaryBlock = [ordered]@{ rows_rendered = $preparedRows.Count; items_fetched = $preparedRows.Count } }
  if (-not [string]::IsNullOrWhiteSpace($DigestLabel)) { try { $summaryBlock.search_label = [string]$DigestLabel } catch {} }

  # Build the model as specified in architecture direction
  # Import template conversion utilities
  try {
    if (-not (Get-Module -Name 'hh.tmpl')) {
      Import-Module (Join-Path $PSScriptRoot 'hh.tmpl.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
    }
  }
  catch {}
  # Convert picks to Handlebars-compatible format
  $plainPicks = if (Get-Command Convert-ToGenericDictionary -ErrorAction SilentlyContinue) {
    Convert-ToGenericDictionary -Obj $picks
  }
  else {
    Convert-ToDeepHashtable $picks
  }
  $cfgGet = $null
  try {
    $cfgGet = Get-Command -Name 'hh.config\Get-HHConfigValue' -ErrorAction SilentlyContinue
    if (-not $cfgGet) { $cfgGet = Get-Command -Name 'Get-HHConfigValue' -ErrorAction SilentlyContinue }
  }
  catch {}
  $picksEnabled = $true
  $showSummaries = $true
  try {
    if ($cfgGet) {
      $picksEnabled = [bool](& $cfgGet -Path @('report', 'picks_enabled') -Default $true)
      $showSummaries = [bool](& $cfgGet -Path @('report', 'show_summaries') -Default $true)
    }
  }
  catch {}
  $model = @{
    rows               = $preparedRows
    picks              = $plainPicks
    picks_enabled      = $picksEnabled
    show_summaries     = $showSummaries
    now_iso            = (Get-Date).ToString('s')
    summary            = $summaryBlock
    views_detail       = $viewsBlock
    invites_detail     = $invitesBlock
    skills_popular     = $skillsBlock
    has_views_detail   = ($viewsBlock.Count -gt 0)
    has_invites_detail = ($invitesBlock.Count -gt 0)
    has_skills_popular = ($skillsBlock.Count -gt 0)
  }
  
  # Import Handlebars helpers module
  try {
    if (-not (Get-Module -Name 'hh.tmpl')) {
      Import-Module (Join-Path $PSScriptRoot 'hh.tmpl.psm1') -DisableNameChecking
    }
    Write-Log -Message "[Render/HTML] Imported Handlebars helpers from hh.tmpl.psm1" -Level Verbose -Module 'Render'
  }
  catch {
    Write-Log -Message ("[Render/HTML] Warning: Failed to import template helpers module: {0}" -f $_.Exception.Message) -Level Warning -Module 'Render'
  }

  # Register all helpers (defined in this module)
  try {
    Register-HbsHelpers
    Write-Log -Message "[Render/HTML] Registered Handlebars helpers" -Level Verbose -Module 'Render'
  }
  catch {
    Write-Log -Message ("[Render/HTML] Failed to register helpers: {0}" -f $_.Exception.Message) -Level Error -Module 'Render'
  }
  
  # Render the template
  try {
    $templateContent = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    $template = [HandlebarsDotNet.Handlebars]::Compile($templateContent)
    $html = $template.Invoke($model)
    
    # Ensure output directory exists and write HTML to file
    $outDir = Split-Path $OutPath -Parent
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    [System.IO.File]::WriteAllText($OutPath, $html, [Text.Encoding]::UTF8)
    
    Write-Log -Message ("[Render/HTML] Report written to: {0}" -f $OutPath) -Level Output -Module 'Render'
    Write-Log -Message ("[Render/HTML] Rendered {0} rows" -f $Rows.Count) -Level Output -Module 'Render'
    
    # Update stats
    if ($PipelineState -and (Get-Command Add-HHPipelineStat -ErrorAction SilentlyContinue)) {
      Add-HHPipelineStat -State $PipelineState -Path @('Search', 'RowsRendered') -Value $Rows.Count
    }
    
    return $OutPath
  }
  catch {
    # LEGACY: Situational band-aid logging - to be retired after unification
    Write-Log -Message ("[Render/HTML] Failed to render report: {0}" -f $_.Exception.Message) -Level Error -Module 'Render'
    throw
  }
}

function Render-Template {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][object]$Model
  )

  try {
    if (-not (Get-Module -Name 'hh.tmpl')) {
      Import-Module -Name (Join-Path $PSScriptRoot 'hh.tmpl.psm1') -DisableNameChecking
    }
  }
  catch {}

  $plain = $Model
  try { $plain = Convert-ToPlain -InputObject $Model } catch {}

  # Force-convert picks to IDictionary for Handlebars truthiness and dot access
  try {
    if ($plain -is [System.Collections.IDictionary] -and $plain.ContainsKey('picks')) {
      $pk = $plain['picks']
      if ($pk -is [System.Management.Automation.PSObject] -or $pk -is [pscustomobject] -or -not ($pk -is [System.Collections.IDictionary])) {
        try {
          if (-not (Get-Module -Name 'hh.tmpl')) {
            Import-Module -Name (Join-Path $PSScriptRoot 'hh.tmpl.psm1') -DisableNameChecking
          }
          $plain['picks'] = Convert-ToPlainHashtable -InputObject $pk
          Write-Log -Message ("[DEBUG] Render-Template: picks forcibly converted to IDictionary type={0}" -f ($plain['picks'].GetType().FullName)) -Level Debug -Module 'Render'
        }
        catch {}
      }
    }
  }
  catch {}

  # Normalize picks entries: unwrap single-element arrays to a single object
  try {
    if ($plain -is [System.Collections.IDictionary] -and $plain.ContainsKey('picks')) {
      $pk = $plain['picks']
      if ($pk -is [System.Collections.IDictionary]) {
        foreach ($k in @('ec', 'lucky', 'worst')) {
          if ($pk.ContainsKey($k)) {
            $v = $pk[$k]
            if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
              # Collect elements for inspection
              $arr = @(); foreach ($e in $v) { $arr += , $e }
              if ($arr.Count -ge 2 -and $arr[0] -is [bool]) {
                # Unwrap [bool, object] tuple – take the actual object
                $pk[$k] = $arr[1]
              }
              elseif ($arr.Count -eq 1) {
                $pk[$k] = $arr[0]
              }
            }
            # Ensure entry is a plain IDictionary so Handlebars dot-notation works
            try {
              if (-not ($pk[$k] -is [System.Collections.IDictionary])) {
                if (-not (Get-Module -Name 'hh.tmpl')) {
                  Import-Module -Name (Join-Path $PSScriptRoot 'hh.tmpl.psm1') -DisableNameChecking
                }
                $pk[$k] = Convert-ToPlainHashtable -InputObject $pk[$k]
              }
            }
            catch {}
          }
        }
      }
    }
  }
  catch {}

  # Pass plain hashtable/PSObject directly; Handlebars.Net supports IDictionary
  $hbModel = $plain
  try {
    # Keep conversion optional; plain IDictionary tends to behave best with Handlebars truthiness
    # $hbModel = Convert-ToHbsModel -Obj $plain
    try {
      $pk = $hbModel['picks']
      $ec = $pk['ec']; $lk = $pk['lucky']; $wr = $pk['worst']
      Write-Log -Message ("[DEBUG] Render-Template: HbsModel picks types ec={0}, lucky={1}, worst={2}" -f ($ec?.GetType().FullName), ($lk?.GetType().FullName), ($wr?.GetType().FullName)) -Level Debug -Module 'Render'
    }
    catch {}
  }
  catch {}
  try {
    Write-Log -Message ("[DEBUG] Render-Template: Model.picks type before convert={0}" -f ($Model.picks.GetType().FullName)) -Level Debug -Module 'Render'
    Write-Log -Message ("[DEBUG] Render-Template: Plain.picks type after convert={0}" -f ($plain['picks'].GetType().FullName)) -Level Debug -Module 'Render'
    try {
      $p0 = $plain['picks']
      $ec0 = $p0['ec']
      $lk0 = $p0['lucky']
      $wr0 = $p0['worst']
      Write-Log -Message ("[DEBUG] Render-Template: picks.ec/lucky/worst types after convert: {0} | {1} | {2}" -f ($ec0?.GetType().FullName), ($lk0?.GetType().FullName), ($wr0?.GetType().FullName)) -Level Debug -Module 'Render'
      try {
        $jsonPreview = "ec=" + ($ec0 | ConvertTo-Json -Depth 4 -Compress) + "; lucky=" + ($lk0 | ConvertTo-Json -Depth 4 -Compress) + "; worst=" + ($wr0 | ConvertTo-Json -Depth 4 -Compress)
        Write-Log -Message ("[DEBUG] Render-Template: picks json preview: {0}" -f $jsonPreview) -Level Debug -Module 'Render'
      }
      catch {}
    }
    catch {}
  }
  catch {}

  return (Render-Handlebars -TemplatePath $TemplatePath -Model $hbModel)
}

function Render-Reports {
  param(
    [Parameter(Mandatory = $true)][object[]]$Rows,
    [string]$OutputsRoot,
    $PipelineState = $null
  )
  
  Write-Log -Message "[Render] Generating reports..." -Level Verbose -Module 'Render'
  
  if (-not [string]::IsNullOrWhiteSpace($OutputsRoot)) {
    if (-not (Test-Path $OutputsRoot)) { New-Item -ItemType Directory -Path $OutputsRoot -Force | Out-Null }
  }

  Render-CSVReport -Rows $Rows -OutputsRoot $OutputsRoot
  Render-JsonReport -Rows $Rows -OutputsRoot $OutputsRoot
  
  $htmlPath = if ($OutputsRoot) { Join-Path $OutputsRoot 'hh.html' } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'data/outputs/hh.html' }
  Render-HtmlReport -Rows $Rows -OutPath $htmlPath -PipelineState $PipelineState
  
  Write-Log -Message "[Render] Reports generated." -Level Verbose -Module 'Render'
}

Export-ModuleMember -Function Render-CSVReport, Render-JsonReport, ConvertFrom-HHRealData, Render-HtmlReport, Format-SalaryText, Format-EmployerPlace, Build-ViewRow, Render-Template, Get-HtmlRenderContext, Convert-ToDeepHashtable, Build-Picks, Render-Reports
