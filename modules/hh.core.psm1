# hh.core.psm1 — shared pipeline helpers
#Requires -Version 7.5

function New-HHPipelineState {
  param(
    [Parameter(Mandatory = $true)][datetime]$StartedLocal,
    [Parameter(Mandatory = $true)][datetime]$StartedUtc,
    [hashtable]$Flags = @{}
  )

  $state = [ordered]@{
    Run      = [ordered]@{
      StartedLocal = $StartedLocal
      StartedUtc   = $StartedUtc
      Duration     = [timespan]::Zero
      Flags        = $Flags
    }
    Search   = [ordered]@{
      Text         = ''
      Query        = ''
      Label        = ''
      ItemsFetched = 0
      RowsRendered = 0
      Keywords     = @()
    }
    Stats    = [ordered]@{
      Views           = 0
      Invites         = 0
      SummariesBuilt  = 0
      SummariesCached = 0
    }
    Cache    = [ordered]@{
      LlmQueried = 0
      LlmCached  = 0
    }
    LlmUsage = [ordered]@{}
    Metadata = [ordered]@{}
    Timings  = [ordered]@{}
  }

  return [PSCustomObject]$state
}

function Set-HHPipelineValue {
  param(
    [Parameter(Mandatory = $true)][PSCustomObject]$State,
    [Parameter(Mandatory = $true)][string[]]$Path,
    $Value
  )
  if (-not $State -or -not $Path -or $Path.Count -eq 0) { return }
  $cursor = $State
  for ($i = 0; $i -lt $Path.Count - 1; $i++) {
    $segment = $Path[$i]
    if (-not $cursor.PSObject.Properties[$segment]) {
      $cursor | Add-Member -NotePropertyName $segment -NotePropertyValue ([ordered]@{}) -Force
    }
    $cursor = $cursor.$segment
  }
  $leaf = $Path[-1]
  if ($cursor -is [System.Collections.IDictionary]) {
    $cursor[$leaf] = $Value
  }
  else {
    $cursor | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force
  }
}

function Add-HHPipelineStat {
  param(
    [Parameter(Mandatory = $true)][PSCustomObject]$State,
    [Parameter(Mandatory = $true)][string[]]$Path,
    [double]$Value = 1
  )
  if (-not $State -or -not $Path -or $Path.Count -eq 0) { return }
  $cursor = $State
  for ($i = 0; $i -lt $Path.Count - 1; $i++) {
    $segment = $Path[$i]
    if (-not $cursor.PSObject.Properties[$segment]) {
      $cursor | Add-Member -NotePropertyName $segment -NotePropertyValue ([ordered]@{}) -Force
    }
    $cursor = $cursor.$segment
  }
  $leaf = $Path[-1]
  $current = 0
  if ($cursor -is [System.Collections.IDictionary]) {
    if ($cursor.Contains($leaf)) { $current = [double]$cursor[$leaf] }
    $cursor[$leaf] = $current + $Value
  }
  else {
    if ($cursor.PSObject.Properties[$leaf]) {
      $current = [double]$cursor.$leaf
      $cursor.$leaf = $current + $Value
    }
    else {
      $cursor | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force
    }
  }
}

function Get-OrAddHCacheValue {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Cache,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][scriptblock]$Factory
  )
  if ($Cache.ContainsKey($Key)) { return $Cache[$Key] }
  $value = $null
  try { $value = & $Factory } catch { $value = $null }
  $Cache[$Key] = $value
  return $value
}

function Get-HHPipelineSummary {
  param([PSCustomObject]$State)
  if (-not $State) { return $null }

  $run = $State.Run
  $search = $State.Search
  $stats = $State.Stats
  $cache = $State.Cache

  $duration = $run?.Duration
  if (-not $duration -or $duration -eq [timespan]::Zero) {
    if ($run?.StartedLocal) {
      try { $duration = (Get-Date) - [datetime]$run.StartedLocal } catch {}
    }
  }
  if (-not $duration) { $duration = [timespan]::Zero }

  return [PSCustomObject]@{
    StartedLocal    = $run?.StartedLocal
    StartedUtc      = $run?.StartedUtc
    CompletedUtc    = $run?.CompletedUtc
    Duration        = $duration
    Flags           = $run?.Flags
    ReportUrl       = $run?.ReportUrl
    SearchText      = $search?.Text
    SearchQuery     = $search?.Query
    SearchLabel     = $search?.Label
    ItemsFetched    = if ($search -and $search.Contains('ItemsFetched')) { [int]$search.ItemsFetched } else { 0 }
    RowsRendered    = if ($search -and $search.Contains('RowsRendered')) { [int]$search.RowsRendered } else { 0 }
    Keywords        = $search?.Keywords
    Views           = if ($stats -and $stats.Contains('Views')) { [int]$stats.Views } else { 0 }
    Invites         = if ($stats -and $stats.Contains('Invites')) { [int]$stats.Invites } else { 0 }
    SummariesBuilt  = if ($stats -and $stats.Contains('SummariesBuilt')) { [int]$stats.SummariesBuilt } else { 0 }
    SummariesCached = if ($stats -and $stats.Contains('SummariesCached')) { [int]$stats.SummariesCached } else { 0 }
    LlmQueried      = if ($cache -and $cache.Contains('LlmQueried')) { [int]$cache.LlmQueried } else { 0 }
    LlmCached       = if ($cache -and $cache.Contains('LlmCached')) { [int]$cache.LlmCached } else { 0 }
  }
}

function Show-HHPipelineSummary {
  param(
    [PSCustomObject]$State,
    [string]$ReportUrl
  )

  $summary = Get-HHPipelineSummary -State $State
  if (-not $summary) { return }
  if (-not [string]::IsNullOrWhiteSpace($ReportUrl)) { $summary.ReportUrl = $ReportUrl }

  $durationText = if ($summary.Duration -and $summary.Duration -ne [timespan]::Zero) {
    $summary.Duration.ToString('hh\:mm\:ss')
  }
  else { 'n/a' }

  $startedText = ''
  try { if ($summary.StartedLocal) { $startedText = [datetime]$summary.StartedLocal } } catch {}

  $flagsText = ''
  if ($summary.Flags) {
    $flagsText = ($summary.Flags.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key }) -join ', '
  }

  $keywordsText = ''
  if ($summary.Keywords) {
    $keywordsText = ($summary.Keywords | Select-Object -Unique | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' · '
  }

  Write-Host ''
  Write-Host ("[Summary] hh_probe completed in {0}" -f $durationText) -ForegroundColor Cyan
  if ($startedText) { Write-Host ("  Started : {0}" -f $startedText) }
  if ($flagsText) { Write-Host ("  Flags   : {0}" -f $flagsText) }
  if ($summary.SearchLabel) {
    Write-Host ("  Search  : {0}" -f $summary.SearchLabel)
  }
  elseif ($summary.SearchQuery) {
    Write-Host ("  Search  : {0}" -f $summary.SearchQuery)
  }
  if ($keywordsText) { Write-Host ("  Keywords: {0}" -f $keywordsText) }
  Write-Host ("  Fetched : {0}" -f $summary.ItemsFetched)
  Write-Host ("  Rendered: {0}" -f $summary.RowsRendered)
  Write-Host ("  Views   : {0}   Invites: {1}" -f $summary.Views, $summary.Invites)
  $cs = $global:CacheStats
  if ($cs) {
    try {
      # Summaries built/LLM queried removed to avoid conflict with new LLM usage summary

      $vc = [int]($cs['vac_cached'] ?? 0)
      $vf = [int]($cs['vac_fetched'] ?? 0)
      $ec = [int]($cs['emp_cached'] ?? 0)
      $ef = [int]($cs['emp_fetched'] ?? 0)
      if ($vc -gt 0 -or $vf -gt 0 -or $ec -gt 0 -or $ef -gt 0) {
        Write-Host ("  Vac cache hits {0}, fetched {1}; Emp cache hits {2}, fetched {3}" -f $vc, $vf, $ec, $ef)
      }
    }
    catch {}
  }
  if ($summary.ReportUrl) { Write-Host ("  Report  : {0}" -f $summary.ReportUrl) }
  
  # Display timings if available
  if ($State -and $State.Timings -and $State.Timings.Count -gt 0) {
      $parts = @()
      foreach ($k in $State.Timings.Keys) {
          $ts = $State.Timings[$k]
          if ($ts -is [TimeSpan]) {
             $parts += ("{0}:{1:N1}s" -f $k, $ts.TotalSeconds)
          }
      }
      if ($parts.Count -gt 0) {
          Write-Host ("  Timings : {0}" -f ($parts -join '  '))
      }
  }
  
  Write-Host ''
}

function Should-BumpCV {
  param(
    [Nullable[datetime]]$LastUpdatedUtc,
    [int]$MinHours = 4,
    [Nullable[datetime]]$NowUtc = $null
  )
  try {
    if (-not $NowUtc) { $NowUtc = (Get-Date).ToUniversalTime() }
    $isWeekendLast = $false
    try {
      if ($LastUpdatedUtc) {
        $lastUtc = [datetime]$LastUpdatedUtc
        try { $lastUtc = $lastUtc.ToUniversalTime() } catch {}
        $lastDow = $lastUtc.DayOfWeek
        $isWeekendLast = ($lastDow -in @([System.DayOfWeek]::Saturday, [System.DayOfWeek]::Sunday))
      }
    }
    catch {}
    if ($isWeekendLast) { return $false }
    if (-not $LastUpdatedUtc) { return $true }
    $elapsed = ($NowUtc - $LastUpdatedUtc).TotalHours
    return ([double]$elapsed -ge [double]$MinHours)
  }
  catch { return $false }
}

Export-ModuleMember -Function New-HHPipelineState, Set-HHPipelineValue, Add-HHPipelineStat, Get-OrAddHCacheValue, Get-HHPipelineSummary, Show-HHPipelineSummary, Should-BumpCV
