<#
Utility functions for HH Probe project
#>

# Suppress PSScriptAnalyzer warnings for the entire file where appropriate

function Get-VacancyPublishedUtc {
  param([object]$Vacancy, [Nullable[datetime]]$Fallback = $null)
    
  # Use compatible syntax instead of ?? operator
  $dt1 = Get-UtcDate $Vacancy.published_at
  $dt2 = Get-UtcDate $Vacancy.created_at
    
  if ($dt1) { return $dt1 }
  if ($dt2) { return $dt2 }
    
  # Always return a valid DateTime object, never $null
  if ($Fallback -ne $null) { return $Fallback }
  return (Get-Date).AddDays(-365).ToUniversalTime()
}

function Get-UtcDate {
  param($DateString)
  if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }
  try {
    # Handle ISO 8601 format with timezone offsets (e.g., "2025-11-09T21:47:39+10:00")
    if ($DateString -match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}') {
      return [DateTimeOffset]::Parse($DateString).UtcDateTime
    }
    return [DateTime]::Parse($DateString)
  }
  catch {
    return $null
  }
}

function Get-RepoRoot {
  param([string]$HintPath = $PSScriptRoot)
  $base = [string]$HintPath
  if ([string]::IsNullOrWhiteSpace($base)) { throw "Repo root hint path is empty." }
  try {
    # Try to find the project root by looking for key project files
    $current = $base
    while ($current -and (Split-Path $current -Parent) -ne $current) {
      # Check if this directory contains key project files
      $hasConfig = Test-Path -LiteralPath (Join-Path $current 'config/hh.config.jsonc') -PathType Leaf
      $hasModules = Test-Path -LiteralPath (Join-Path $current 'modules/hh.pipeline.psm1') -PathType Leaf
      $hasData = Test-Path -LiteralPath (Join-Path $current 'data') -PathType Container
      
      if ($hasConfig -and $hasModules -and $hasData) {
        return $current
      }
      
      # Move up one level
      $parent = Split-Path $current -Parent
      if ($parent -eq $current) { break } # Reached filesystem root
      $current = $parent
    }
    
    # Fallback: use the directory containing the modules folder
    $fallback = Split-Path $base -Parent
    if (Test-Path -LiteralPath $fallback) {
      return $fallback
    }
    
    throw "Repo root not resolved from: $base"
  }
  catch {
    # Final fallback: use the directory containing the modules folder
    $fallback = Split-Path $base -Parent
    if (Test-Path -LiteralPath $fallback) {
      return $fallback
    }
    throw "Repo root not resolved from: $base"
  }
}

function Get-HHSafePropertyValue {
  param(
    $InputObject,
    [string]$PropertyName,
    $Default = $null
  )
  if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($PropertyName)) { return $Default }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($PropertyName)) { return $InputObject[$PropertyName] }
    if ($InputObject.ContainsKey($PropertyName)) { return $InputObject[$PropertyName] }
    return $Default
  }
  if ($InputObject -is [psobject]) {
    $prop = $InputObject.PSObject.Properties[$PropertyName]
    if ($prop) { return $prop.Value }
  }
  try { return $InputObject.$PropertyName } catch { return $Default }
}

<#
.SYNOPSIS
Joins base and child paths with validation to prevent empty child path.

.DESCRIPTION
Validates that `Child` is non-empty and then joins using `Join-Path`.
Ensures no accidental single-argument `Join-Path` usage.

.PARAMETER Base
Base directory path.

.PARAMETER Child
Child path segment to append; must be non-empty.

.OUTPUTS
String combined path.
#>
function Join-RepoPath {
  param(
    [Parameter(Mandatory)] [string]$Base,
    [Parameter(Mandatory)] [string]$Child
  )
  if ([string]::IsNullOrWhiteSpace($Child)) { throw "Join-RepoPath: Child path is empty." }
  return (Join-Path -Path $Base -ChildPath $Child)
}

# Add other functions that were working
function Test-Interactive { return $Host.UI.RawUI.KeyAvailable }
function Show-Progress {
  param($Activity, $Status, $Id = 'default')
  $hid = 0
  try { $h = [int]($Id.GetHashCode()); if ($h -eq [int]($hid = 0)) { $hid = 0 } else { $hid = [math]::Abs($h) } } catch { $hid = 0 }
  Write-Progress -Activity $Activity -Status $Status -Id $hid
}
function Show-ProgressWithPercent {
  param($Activity, $Index, $Total, $Status, $Id = 'default')
  $hid = 0
  try { $h = [int]($Id.GetHashCode()); if ($h -eq [int]($hid = 0)) { $hid = 0 } else { $hid = [math]::Abs($h) } } catch { $hid = 0 }
  $percent = if ($Total -gt 0) { [int](($Index / $Total) * 100) } else { 0 }
  Write-Progress -Activity $Activity -Status $Status -PercentComplete $percent -Id $hid
}
function Show-ProgressIndeterminate {
  param($Activity, $Status, $Id = 'default')
  $hid = 0
  try { $h = [int]($Id.GetHashCode()); if ($h -eq [int]($hid = 0)) { $hid = 0 } else { $hid = [math]::Abs($h) } } catch { $hid = 0 }
  Write-Progress -Activity $Activity -Status $Status -Id $hid -PercentComplete -1
}
function Complete-Progress { 
  param($Id = 'default') 
  $hid = 0
  try { $h = [int]($Id.GetHashCode()); if ($h -eq [int]($hid = 0)) { $hid = 0 } else { $hid = [math]::Abs($h) } } catch { $hid = 0 }
  Write-Progress -Activity 'Complete' -Id $hid -Completed 
}
function Invoke-Quietly {
  param(
    [Parameter(Mandatory = $true)][ScriptBlock]$ScriptBlock,
    $Default = $null
  )
  try {
    return (& $ScriptBlock 2>$null)
  }
  catch {
    return $Default
  }
}
function Get-PlainDesc { param($Text) if ([string]::IsNullOrWhiteSpace($Text)) { return '' } return ($Text -replace '<[^>]+>', '' -replace '\s+', ' ').Trim() }


function Get-HHDoubleOrDefault {
  param($Value, [double]$Default = 0.0)
  if ($null -eq $Value) { return $Default }
  if ($Value -is [double]) { return $Value }
  if ($Value -is [int]) { return [double]$Value }
  if ($Value -is [int64]) { return [double]$Value }
  if ($Value -is [decimal]) { return [double]$Value }
  if ($Value -is [float]) { return [double]$Value }
  if ($Value -is [string]) {
    $parsed = 0.0
    if ([double]::TryParse(
        $Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
      )) {
      return $parsed
    }
  }
  return $Default
}

function Get-HHNullableDouble {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [double]) { return $Value }
  if ($Value -is [int]) { return [double]$Value }
  if ($Value -is [int64]) { return [double]$Value }
  if ($Value -is [decimal]) { return [double]$Value }
  if ($Value -is [float]) { return [double]$Value }
  if ($Value -is [string]) {
    $parsed = 0.0
    if ([double]::TryParse(
        $Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
      )) {
      return $parsed
    }
  }
  return $null
}

function Get-Relative {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$From,
        
    [Parameter(Mandatory = $true)]
    [datetime]$To
  )
    
  $span = $To - $From
  if ($span.TotalDays -ge 1) {
    return "$([math]::Round($span.TotalDays, 1))d"
  }
  elseif ($span.TotalHours -ge 1) {
    return "$([math]::Round($span.TotalHours, 1))h"
  }
  else {
    return "$([math]::Round($span.TotalMinutes, 1))m"
  }
}

function Get-HHCanonicalSummary {
  param(
    [string]$VacancyId,
    [datetime]$PublishedUtc,
    [hashtable]$LLMMap
  )

  $summary = ''
  if ($VacancyId -and $PublishedUtc) {
    $summary = Invoke-Quietly { Read-SummaryCache -VacId $VacancyId -PubUtc $PublishedUtc } ''
  }
  if (-not $summary -and $VacancyId -and $LLMMap -and $LLMMap.ContainsKey($VacancyId)) {
    try { $summary = [string]($LLMMap[$VacancyId]?.summary ?? '') } catch { $summary = '' }
  }
  return $summary ?? ''
}

<#
.SYNOPSIS
Builds a concise, plain summary from vacancy snippet/description.

.DESCRIPTION
Uses `snippet.requirement` and `snippet.responsibility` when available,
falling back to `description`. Produces a single-line, trimmed text capped
to ~300 chars. No external API calls. Designed as a friendly fallback when
LLM summaries are unavailable.

.PARAMETER Vacancy
Raw vacancy object from HH API.

.OUTPUTS
String summary (may be empty when no textual inputs exist).
#>
function Get-HHPlainSummary {
  param([Parameter(Mandatory = $true)][psobject]$Vacancy)
  try {
    $req = ''
    $resp = ''
    $desc = ''
    try { $req = [string]($Vacancy.snippet?.requirement ?? '') } catch { <# Suppress #> }
    try { $resp = [string]($Vacancy.snippet?.responsibility ?? '') } catch { <# Suppress #> }
    try { $desc = [string]($Vacancy.description ?? '') } catch { <# Suppress #> }
    
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
      Write-Log ("Get-HHPlainSummary: req len={0}, resp len={1}, desc len={2}" -f $req.Length, $resp.Length, $desc.Length)
    }

    $parts = @()
    foreach ($p in @($req, $resp)) { if (-not [string]::IsNullOrWhiteSpace($p)) { $parts += $p } }
    if ($parts.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($desc)) { $parts += $desc }
    if ($parts.Count -eq 0) { return '' }

    $txt = ($parts -join ' ') -replace '\s+', ' '
    $txt = $txt.Trim()
    if ($txt.Length -gt 300) { $txt = $txt.Substring(0, 300).Trim() + '…' }
    return $txt
  }
  catch {
    # Clean error handling: never emit raw stack traces
    return ''
  }
}

function Clean-SummaryText {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [int]$MaxLength = 220
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

  $clean = $Text
  $clean = $clean -replace '<[^>]+>', ' '
  $clean = $clean -replace '[\*••\-–—]+', ' '
  $clean = $clean -replace '\s+', ' '
  $clean = $clean.Trim()

  # Try to capture the first sentence
  $match = [regex]::Match($clean, '^(.*?[\.!\?])\s')
  if (-not $match.Success) {
    $match = [regex]::Match($clean, '^(.*?[\.!\?])$')
  }
  $result = if ($match.Success) { $match.Groups[1].Value.Trim() } else { $clean }

  if ($result.Length -gt $MaxLength) {
    $result = $result.Substring(0, $MaxLength).TrimEnd(' ', '.', ',', ';') + '.'
  }

  return $result.Trim()
}

function Normalize-HHSummaryText {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $clean = Clean-SummaryText -Text $Text -MaxLength 220
  try {
    $prefixMatch = [regex]::Match($clean, '(?i)^(.*?(?:описание(?:\s+вакансии)?|краткое\s+описание|summary))\s*[:\-–—]+\s*(.+)$')
    if ($prefixMatch.Success -and ($prefixMatch.Groups.Count -gt 2)) {
      $candidate = $prefixMatch.Groups[2].Value.Trim()
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $clean = Clean-SummaryText -Text $candidate -MaxLength 220
      }
    }
  }
  catch {}

  return $clean
}

function Normalize-HHSummarySource {
  param(
    [string]$Source,
    [string]$Fallback = 'local'
  )

  $value = [string]$Source
  if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
  $value = $value.ToLowerInvariant()

  switch ($value) {
    'cache' { return $Fallback }
    'none'  { return $Fallback }
    default { return $value }
  }
}

<#
.SYNOPSIS
Detects text language as 'ru' or 'en'.

.DESCRIPTION
Uses simple character class heuristics: counts Cyrillic vs Latin letters.
Returns 'ru' when Cyrillic dominates, 'en' when Latin dominates, else 'auto'.

.PARAMETER Text
Input text to analyze.

.OUTPUTS
String: 'ru' | 'en' | 'auto'
#>
function Get-TextLanguage {
  param([string]$Text)
  try {
    $t = [string]$Text
    if ([string]::IsNullOrWhiteSpace($t)) { return 'ru' } # default to ru for HH
    $cyr = ([regex]::Matches($t, '[\p{IsCyrillic}]')).Count
    $lat = ([regex]::Matches($t, '[A-Za-z]')).Count
    if ($cyr -ge $lat) { return 'ru' }
    return 'en'
  }
  catch { return 'ru' }
}

<#
.SYNOPSIS
Returns a structured summary object with text and source.

.DESCRIPTION
Checks summary cache by VacancyId/PublishedUtc, then LLMMap, then
falls back to a plain summary built from vacancy snippet/description.
Always returns an object: @{ text, source, lang }.

.PARAMETER Vacancy
Raw vacancy object from HH API (for plain fallback).

.PARAMETER VacancyId
HH vacancy id.

.PARAMETER PublishedUtc
Publication datetime (UTC) for cache lookup.

.PARAMETER LLMMap
Optional map of precomputed summaries (e.g., from LLM helpers).

.OUTPUTS
PSCustomObject with properties: text (string), source (cache|llm|fallback), lang (auto).
#>
function Get-HHCanonicalSummaryEx {
  param(
    [psobject]$Vacancy,
    [string]$VacancyId,
    [datetime]$PublishedUtc,
    [hashtable]$LLMMap
  )
  $text = ''
  $source = ''
  $lang = 'auto'
  try {
    if ($VacancyId -and $PublishedUtc) {
      $text = Invoke-Quietly { Read-SummaryCache -VacId $VacancyId -PubUtc $PublishedUtc } ''
      if (-not [string]::IsNullOrWhiteSpace($text)) { $source = 'remote' }
    }
  }
  catch { <# Suppress #> }

  if ([string]::IsNullOrWhiteSpace($text) -and $VacancyId -and $LLMMap -and $LLMMap.ContainsKey($VacancyId)) {
    try {
      $text = [string]($LLMMap[$VacancyId]?.summary ?? '')
      if (-not [string]::IsNullOrWhiteSpace($text)) { $source = 'remote' }
    }
    catch { $text = '' }
  }

  if ([string]::IsNullOrWhiteSpace($text)) {
    try { $text = Get-HHPlainSummary -Vacancy $Vacancy } catch { $text = '' }
    if (-not [string]::IsNullOrWhiteSpace($text)) { $source = 'local' }
  }
  # Language preference: report.summary_lang -> llm.summary_language -> llm.summary_lang -> auto-detect
  try {
    $pref = [string](Get-HHConfigValue -Path @('report', 'summary_lang') -Default '')
    if ([string]::IsNullOrWhiteSpace($pref)) { $pref = [string](Get-HHConfigValue -Path @('llm', 'summary_language') -Default '') }
    if ([string]::IsNullOrWhiteSpace($pref)) { $pref = [string](Get-HHConfigValue -Path @('llm', 'summary_lang') -Default '') }
    $p = ([string]$pref).ToLowerInvariant()
    if ($p -eq 'ru' -or $p -eq 'en') { $lang = $p }
    else { $lang = Get-TextLanguage -Text $text }
  }
  catch { $lang = Get-TextLanguage -Text $text }

  $clean = Clean-SummaryText -Text ($text ?? '')
  $finalSource = if (-not [string]::IsNullOrWhiteSpace($clean)) {
    if ($source) { $source } else { if ($Operation -eq 'summary.local') { 'local' } else { 'remote' } }
  } else {
    'local'
  }
  return [PSCustomObject]@{
    text = $clean
    source = $finalSource
    lang = [string]$lang
  }
}

<#
.SYNOPSIS
Creates a file lock to prevent parallel script execution.

.DESCRIPTION
Creates a lock file with process ID to prevent multiple instances of the script
from running simultaneously. This helps avoid 429 errors from HH API.

.PARAMETER LockFilePath
Path to the lock file to create.

.PARAMETER TimeoutSeconds
Maximum time to wait for lock to be released (default: 30 seconds).

.OUTPUTS
Boolean: $true if lock acquired successfully, $false if another instance is running.
#>
function New-FileLock {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$LockFilePath,
    [int]$TimeoutSeconds = 30
  )
    
  $startTime = Get-Date
  $lockAcquired = $false
    
  while (((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
    if (Test-Path $LockFilePath) {
      try {
        $lockContent = Get-Content $LockFilePath -ErrorAction Stop
        $pidFromFile = [int]($lockContent -split ':')[0]
                
        # Check if process with that PID is still running
        $processRunning = Get-Process -Id $pidFromFile -ErrorAction SilentlyContinue
        if (-not $processRunning) {
          # Process is not running, remove stale lock
          Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
          Start-Sleep -Milliseconds 100
          continue
        }
                
        if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
          Write-LogMain -Message "Another instance is running (PID: $pidFromFile). Waiting for lock release..." -Level Warning
        } else {
          Write-Warning "Another instance is running (PID: $pidFromFile). Waiting for lock release..."
        }
        Start-Sleep -Seconds 2
        continue
      }
      catch {
        # Lock file exists but can't read it, assume stale
        Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 100
        continue
      }
    }
        
    # Try to create lock file
    try {
      if ($PSCmdlet.ShouldProcess($LockFilePath, "Create lock file")) {
        $pidInfo = "$($PID):$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')"
        Set-Content -Path $LockFilePath -Value $pidInfo -NoNewline -ErrorAction Stop
            
        # Verify lock was created successfully
        if (Test-Path $LockFilePath) {
          $verifyContent = Get-Content $LockFilePath -ErrorAction Stop
          if ($verifyContent -eq $pidInfo) {
            $lockAcquired = $true
            break
          }
        }
      }
    }
    catch {
      # Another process might have created the lock simultaneously
      Start-Sleep -Milliseconds 100
    }
  }
    
  return $lockAcquired
}

<#
.SYNOPSIS
Releases a file lock created by New-FileLock.

.DESCRIPTION
Removes the lock file if it belongs to the current process.

.PARAMETER LockFilePath
Path to the lock file to remove.
#>
function Remove-FileLock {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$LockFilePath
  )
    
  if (Test-Path $LockFilePath) {
    try {
      $lockContent = Get-Content $LockFilePath -ErrorAction Stop
      $pidFromFile = [int]($lockContent -split ':')[0]
            
      if ($pidFromFile -eq $PID) {
        if ($PSCmdlet.ShouldProcess($LockFilePath, "Remove lock file")) {
          Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
        }
      }
    }
    catch {
      # If we can't read the lock file, just try to remove it
      Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
    }
  }
}

<#
.SYNOPSIS
Checks if another instance of the script is currently running.

.DESCRIPTION
Checks for existence of lock file and verifies if the process is still active.

.PARAMETER LockFilePath
Path to the lock file to check.

.OUTPUTS
Boolean: $true if another instance is running, $false otherwise.
#>
function Test-AnotherInstanceRunning {
  param(
    [Parameter(Mandatory = $true)]
    [string]$LockFilePath
  )
    
  if (-not (Test-Path $LockFilePath)) {
    return $false
  }
    
  try {
    $lockContent = Get-Content $LockFilePath -ErrorAction Stop
    $pidFromFile = [int]($lockContent -split ':')[0]
        
    $processRunning = Get-Process -Id $pidFromFile -ErrorAction SilentlyContinue
    return ($null -ne $processRunning)
  }
  catch {
    return $false
  }
}

<#
.SYNOPSIS
Builds a normalized HH search query string from raw search text.

.DESCRIPTION
Takes raw `SearchText` (multiline tokens or explicit boolean expression) and
produces a query string for the HH `text` parameter, a human-friendly label,
and a de-duplicated keyword list. When `SearchText` is a simple list (lines),
it joins using the provided mode (`OR`/`AND`) and caps by `MaxKeywords` if set.
Explicit queries containing boolean operators or parentheses are respected as-is.

.PARAMETER SearchText
Raw search text. May be multiline or an explicit expression using `OR`/`AND`.

.PARAMETER FallbackKeyword
Fallback single keyword if `SearchText` is empty.

.PARAMETER Mode
Join mode for simple lists: `OR` (default) or `AND`.

.PARAMETER Max
Maximum number of keywords to include for simple lists. `0` means unlimited.

.OUTPUTS
Hashtable: @{ Query = [string]; Label = [string]; Keywords = [string[]] }

.NOTES
English/Russian: Handles both simple lists and explicit boolean queries.
#>
function Build-SearchQueryText {
  param(
    [string]$SearchText,
    [string]$FallbackKeyword,
    [string]$Mode = 'OR',
    [int]$Max = 0
  )

  # Normalize inputs
  $st = [string]$SearchText
  $fb = [string]$FallbackKeyword
  $modeNorm = ([string]$Mode).ToUpperInvariant()
  if ($modeNorm -ne 'AND' -and $modeNorm -ne 'OR') { $modeNorm = 'OR' }
  $maxCount = [int][math]::Max(0, $Max)
  if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
      Write-LogFetch -Message "DEBUG: Build-SearchQueryText called with st='$st' fb='$fb' mode='$modeNorm' max='$maxCount'" -Level Debug
    } else {
      Write-Verbose "DEBUG: Build-SearchQueryText called with st='$st' fb='$fb' mode='$modeNorm' max='$maxCount'"
    }

  # Detect explicit query (contains operators or parentheses/quotes)
  $isExplicit = $false
  try {
    if ($st -match '\b(OR|AND)\b' -or $st -match '[\(\)"\"]') { $isExplicit = $true }
  }
  catch { $isExplicit = $false }

  # Build tokens from simple list (lines)
  $tokens = @()
  if (-not $isExplicit) {
    try {
      $tokens = @($st -split "\r?\n") |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
    }
    catch { $tokens = @() }
    if ($maxCount -gt 0 -and $tokens.Count -gt $maxCount) {
      $tokens = $tokens | Select-Object -First $maxCount
    }
  }
  else {
    # Extract keywords for explicit queries (best-effort split on operators)
    try {
      $tokens = @($st -split '\s+(?:OR|AND)\s+') |
      ForEach-Object { $_ -replace '[\(\)"\"]', '' } |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
    }
    catch { $tokens = @() }
  }

  # Compose query
  $query = ''
  if ($isExplicit) {
    $query = $st.Trim()
  }
  elseif ($tokens -and $tokens.Count -gt 0) {
    $sep = " $modeNorm "
    $query = ($tokens -join $sep)
  }
  else {
    $query = if (-not [string]::IsNullOrWhiteSpace($fb)) { $fb.Trim() } else { '' }
  }

  # Build digest label (human-friendly)
  $label = ($query -replace '"', '')
  try {
    $label = $label -replace '\)\s+AND\s+\(', ' · '
    $label = $label -replace '\s+AND\s+', ' · '
    $label = $label -replace '\s+OR\s+', ' · '
    $label = $label -replace '[\(\)]', ''
    if ($label.Length -gt 60) { $label = $label.Substring(0, 57) + '…' }
  }
  catch { <# Suppress #> }

  return @{ Query = $query; Label = $label; Keywords = $tokens }
}

<#
.SYNOPSIS
Extracts and normalizes salary information from HH vacancy detail object.

.DESCRIPTION
Parses salary data from various locations in the vacancy object and returns
a standardized salary object with text representation, numeric values,
currency, and other metadata.

.PARAMETER Detail
Vacancy detail object from HH API response.

.OUTPUTS
PSCustomObject with standardized salary properties.

.NOTES
Чистая функция: не делает сетевых вызовов, аккуратно обрабатывает отсутствующие поля.
#>
function Get-HHCanonicalSalary {
  param([object]$Detail)

  # Empty detail → empty salary object
  if ($null -eq $Detail) {
    return [PSCustomObject]@{
      text      = ''
      from      = $null
      to        = $null
      currency  = ''
      gross     = $false
      frequency = ''
      mode      = ''
      symbol    = ''
      upper_cap = $null
      node      = $null
    }
  }

  # Resolve salary node from common locations without null-propagation quirks
  $salary = $null
  try {
    if ($Detail.PSObject.Properties['salary'] -and $Detail.salary) {
      $salary = $Detail.salary
    }
    elseif ($Detail.PSObject.Properties['salary_range'] -and $Detail.salary_range) {
      $salary = $Detail.salary_range
    }
    elseif ($Detail.PSObject.Properties['raw'] -and $Detail.raw) {
      if ($Detail.raw.PSObject.Properties['salary'] -and $Detail.raw.salary) {
        $salary = $Detail.raw.salary
      }
      elseif ($Detail.raw.PSObject.Properties['salary_range'] -and $Detail.raw.salary_range) {
        $salary = $Detail.raw.salary_range
      }
    }
  }
  catch { $salary = $null }

  # Extract values safely - use nullable functions to preserve null values
  $from = $null
  try { if ($salary -and $salary.PSObject.Properties['from']) { $from = Get-HHNullableDouble -Value $salary.from } } catch { $from = $null }
  $to = $null
  try { if ($salary -and $salary.PSObject.Properties['to']) { $to = Get-HHNullableDouble -Value $salary.to } }   catch { $to = $null }
  $currency = ''
  try { if ($salary -and $salary.PSObject.Properties['currency']) { $currency = [string]$salary.currency } } catch { $currency = '' }
  $gross = $false
  try { if ($salary -and $salary.PSObject.Properties['gross']) { $gross = [bool]$salary.gross } } catch { $gross = $false }
  $mode = ''
  try { if ($salary -and $salary.PSObject.Properties['mode'] -and $salary.mode.PSObject.Properties['name']) { $mode = [string]$salary.mode.name } } catch { $mode = '' }
  $frequency = ''
  try { if ($salary -and $salary.PSObject.Properties['frequency']) { $frequency = [string]$salary.frequency } } catch { $frequency = '' }

  # Determine frequency from mode if not explicitly set
  if ([string]::IsNullOrWhiteSpace($frequency)) {
    switch -Regex ($mode) {
      '(?i)month' { $frequency = 'monthly' }
      '(?i)year' { $frequency = 'yearly' }
      '(?i)week' { $frequency = 'weekly' }
      '(?i)day' { $frequency = 'daily' }
      '(?i)hour' { $frequency = 'hourly' }
      default { $frequency = 'monthly' }
    }
  }

  # Generate salary text and symbol - handle null values properly
  $text = ''
  $symbol = ''
  if (($null -ne $from -and $from -gt 0) -or ($null -ne $to -and $to -gt 0)) {
    if ($null -ne $from -and $from -gt 0 -and $null -ne $to -and $to -gt 0) {
      $text = "{0:0}–{1:0}" -f $from, $to
    }
    elseif ($null -ne $from -and $from -gt 0) {
      $text = "от {0:0}" -f $from
    }
    elseif ($null -ne $to -and $to -gt 0) {
      $text = "до {0:0}" -f $to
    }

    switch -Regex ($currency) {
      'RUB|RUR' { $symbol = '₽' }
      'USD' { $symbol = '$' }
      'EUR' { $symbol = '€' }
      'GBP' { $symbol = '£' }
      'KZT' { $symbol = '₸' }
      'BYN' { $symbol = 'Br' }
      'UAH' { $symbol = '₴' }
      default { $symbol = $currency }
    }

    if (-not [string]::IsNullOrWhiteSpace($symbol)) { $text = "$symbol $text" }
  }

  # Calculate upper cap for salary display - handle null values properly
  $upperCap = $null
  if ($null -ne $to -and $to -gt 0) { $upperCap = $to }
  elseif ($null -ne $from -and $from -gt 0) { $upperCap = $from }

  return [PSCustomObject]@{
    text      = $text
    from      = $from
    to        = $to
    currency  = $currency
    gross     = $gross
    frequency = $frequency
    mode      = $mode
    symbol    = $symbol
    upper_cap = $upperCap
    node      = $salary
  }
}

# ===== Stat Tracking Helpers =====
# Global counters for HTTP and scrape operations
if (-not (Get-Variable -Name HttpCount -Scope Global -ErrorAction SilentlyContinue)) {
  $Global:HttpCount = 0
}
if (-not (Get-Variable -Name ScrapeCount -Scope Global -ErrorAction SilentlyContinue)) {
  $Global:ScrapeCount = 0
}

function Bump-Http {
  <#
  .SYNOPSIS
  Increments the global HTTP request counter.
  #>
  $Global:HttpCount++
}

function Bump-Scrape {
  <#
  .SYNOPSIS
  Increments the global scrape operation counter.
  #>
  $Global:ScrapeCount++
}

function Log-CacheSummary {
  <#
  .SYNOPSIS
  Logs a summary of cache statistics.
  #>
  try {
    $stats = if ($global:CacheStats) { $global:CacheStats } else { $script:CacheStats }
    $json = ($stats | ConvertTo-Json -Depth 3 -Compress)
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
      Write-LogMain -Message "[Cache] stats: $json" -Level Verbose
    }
    else {
      if (Get-Command -Name Write-LogCache -ErrorAction SilentlyContinue) { Write-LogCache -Message "stats: $json" -Level Verbose }
    }
  }
  catch {
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
      Write-LogMain -Message "[Cache] stats: <unavailable>" -Level Warning
    }
  }
}

function Log-ScrapeSummary {
  <#
  .SYNOPSIS
  Logs a summary of scrape operation statistics.
  #>
  try {
    $att = [int]($script:ScrapeStats.attempted ?? 0)
    $ok = [int]($script:ScrapeStats.success ?? 0)
    $pf = [int]($script:ScrapeStats.parse_fail ?? 0)
    $fl = [int]($script:ScrapeStats.fail ?? 0)
    $ms = [int]($script:ScrapeStats.total_ms ?? 0)
    $avg = if ($ok -gt 0) { [int]($ms / $ok) } else { 0 }
    $http = [int]$Global:HttpCount
    $scrape = [int]$Global:ScrapeCount
    
    $summary = [ordered]@{
      attempted  = $att
      success    = $ok
      parse_fail = $pf
      fail       = $fl
      total_ms   = $ms
      avg_ms     = $avg
      http       = $http
      scrape     = $scrape
    }
    $json = ($summary | ConvertTo-Json -Depth 3 -Compress)
    
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
      Write-LogMain -Message "[Scrape] stats: $json" -Level Verbose
    }
    else {
      if (Get-Command -Name Write-LogScrape -ErrorAction SilentlyContinue) { Write-LogScrape -Message "stats: $json" -Level Verbose }
    }
  }
  catch {
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
      Write-LogMain -Message "[Scrape] stats: <unavailable>" -Level Warning
    }
  }
}

function Get-OrDefault {
  <#
  .SYNOPSIS
  Safely retrieves a nested property value from an object with a default fallback.
  
  .DESCRIPTION
  Traverses an object path and returns the value if found, otherwise returns the default.
  Supports both hashtables and PSObjects.
  #>
  param(
    $Object,
    [string[]]$Path,
    $Default
  )
  if (-not $Path -or ($Path.Count -eq 0)) { return $Object ?? $Default }
  if ($Object -eq $Cfg -and (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
    return (Get-HHConfigValue -Path $Path -Default $Default)
  }
  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) { return $Default }
    if ($current -is [System.Collections.IDictionary]) {
      if (-not $current.Contains($segment)) { return $Default }
      $current = $current[$segment]
      continue
    }
    $prop = $current.PSObject.Properties[$segment]
    if (-not $prop) { return $Default }
    $current = $prop.Value
  }
  return $current ?? $Default
}

function Get-TrueRandomIndex {
  <#
  .SYNOPSIS
  Gets a random index using either local RNG or random.org.
  
  .DESCRIPTION
  Returns a random integer in [0, MaxExclusive). Can use random.org for true randomness.
  #>
  param(
    [int]$MaxExclusive,
    [switch]$ForceRemote
  )
  if ($MaxExclusive -le 0) { return -1 }
  $useRemote = $script:UseTrueRandom -or $ForceRemote
  if (-not $useRemote) {
    return (Get-Random -Maximum $MaxExclusive)
  }
  $urlRnd = "https://www.random.org/integers/?num=1&min=0&max={0}&col=1&base=10&format=plain&rnd=new" -f ($MaxExclusive - 1)
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'hh-probe/2025 (PowerShell)'
    $wc.Encoding = [Text.Encoding]::UTF8
    $task = $wc.DownloadStringTaskAsync($urlRnd)
    $timeoutSec = if ($script:RandomOrgTimeoutSec) { $script:RandomOrgTimeoutSec } else { 5 }
    $ok = $task.Wait([TimeSpan]::FromSeconds([double]$timeoutSec))
    if (-not $ok) { throw "random.org timeout" }
    $txt = $task.Result.Trim()
    [int]$val = 0
    if (-not [int]::TryParse($txt, [ref]$val)) { throw "random.org parse" }
    if ($val -lt 0 -or $val -ge $MaxExclusive) { throw "random.org out of range" }
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
      Write-LogMain -Message "[Random] source=random.org; value=$val/$MaxExclusive" -Level Verbose
    }
    return $val
  }
  catch {
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
      Write-LogMain -Message "[Random] unavailable: $($_.Exception.Message)" -Level Warning
    }
    return -1
  }
}



function Invoke-Jitter {
  <#
  .SYNOPSIS
  Sleeps for a random duration to simulate human jitter.
  #>
  param(
    [int]$BaseMs = 100,
    [int]$RandomMs = 200
  )
  $ms = $BaseMs + (Get-Random -Maximum ($RandomMs + 1))
  Start-Sleep -Milliseconds $ms
}

function Initialize-HHGlobalCacheStats {
  <#
  .SYNOPSIS
  Initializes the global cache statistics hashtable to track cache performance metrics.
  #>
  if (-not $global:CacheStats) {
    $global:CacheStats = [ordered]@{
      vac_cached        = 0
      vac_fetched       = 0
      emp_cached        = 0
      emp_fetched       = 0
      emp_rating_cached = 0
      sum_cached        = 0
      llm_cached        = 0
      llm_queried       = 0
      llm_local_queried = 0
      cache_hits        = 0
      cache_misses      = 0
      litedb_hits       = 0
      litedb_misses     = 0
      file_hits         = 0
      file_misses       = 0
    }
  }
  return $global:CacheStats
}

function Detect-Language {
  <#
  .SYNOPSIS
  Detects dominant language by counting Cyrillic vs Latin characters.

  .DESCRIPTION
  Counts Cyrillic/Latin letters (ignoring whitespace/digits) and computes ratios.
  Applies a 0.6 dominance threshold; defaults to 'en' when mixed/unknown.
  #>
  [CmdletBinding()]
  param([string]$Text)

  $text = [string]$Text
  $cyrCount = 0
  $latCount = 0
  try {
    $cyrCount = ([regex]::Matches($text, '[\p{IsCyrillic}]')).Count
    $latCount = ([regex]::Matches($text, '[A-Za-z]')).Count
  }
  catch { $cyrCount = 0; $latCount = 0 }

  $total = $cyrCount + $latCount
  $cyrRatio = if ($total -gt 0) { [double]$cyrCount / [double]$total } else { 0.0 }
  $latRatio = if ($total -gt 0) { [double]$latCount / [double]$total } else { 0.0 }

  $lang = 'en'
  if ($cyrRatio -gt 0.6) { $lang = 'ru' }
  elseif ($latRatio -gt 0.6) { $lang = 'en' }

  return [pscustomobject]@{
    Language      = $lang
    CyrillicCount = $cyrCount
    LatinCount    = $latCount
    CyrillicRatio = $cyrRatio
    LatinRatio    = $latRatio
  }
}


<#
.SYNOPSIS
Resolves summary language using character distribution with optional config override.

.DESCRIPTION
Concatenates vacancy title/description, detects dominant alphabet via Detect-Language,
respects explicit preferences from report/llm config, and returns detection detail.

.OUTPUTS
PSCustomObject with Language, counts, and ratios.
#>
function Resolve-SummaryLanguage {
  [CmdletBinding()]
  param(
    [string]$VacancyTitle,
    [string]$VacancyDescription,
    [string]$Text,
    [string]$Preferred = ''
  )

  $configPref = $Preferred
  if ([string]::IsNullOrWhiteSpace($configPref)) {
    try { $configPref = [string](Get-HHConfigValue -Path @('report', 'summary_lang') -Default '') } catch {}
    if ([string]::IsNullOrWhiteSpace($configPref)) {
      try { $configPref = [string](Get-HHConfigValue -Path @('llm', 'summary_language') -Default '') } catch {}
    }
  }
  $prefNorm = ''
  try { $prefNorm = $configPref.ToLowerInvariant().Trim() } catch {}

  $combined = ''
  if (-not [string]::IsNullOrWhiteSpace($VacancyTitle)) { $combined += "$VacancyTitle`n" }
  if (-not [string]::IsNullOrWhiteSpace($VacancyDescription)) { $combined += $VacancyDescription }
  if ([string]::IsNullOrWhiteSpace($combined)) { $combined = $Text }

  $detected = Detect-Language -Text $combined

  $language = $detected.Language
  if ($prefNorm -in @('ru', 'en')) { $language = $prefNorm }

  if (Get-Command -Name Write-LogLLM -ErrorAction SilentlyContinue) {
    Write-LogLLM -Message ("[LangDetect] lang={0}; cyr_ratio={1:N2}; lat_ratio={2:N2}" -f $language, $detected.CyrillicRatio, $detected.LatinRatio) -Level Verbose
  }

  return [pscustomobject]@{
    Language      = $language
    CyrillicCount = $detected.CyrillicCount
    LatinCount    = $detected.LatinCount
    CyrillicRatio = $detected.CyrillicRatio
    LatinRatio    = $detected.LatinRatio
  }
}

function Normalize-SkillToken {
  param([string]$Token)
    
  if ([string]::IsNullOrWhiteSpace($Token)) { return '' }
    
  # Lowercase and basic strip
  $t = $Token.ToLowerInvariant().Trim()
    
  # Common mappings (minimal but explicit)
  if ($t -eq 'node.js') { return 'nodejs' }
  if ($t -eq 'c#') { return 'csharp' }
  if ($t -eq 'c++') { return 'cpp' }
  if ($t -eq '.net') { return 'dotnet' }
  if ($t -eq 'react.js') { return 'react' }
  if ($t -eq 'vue.js') { return 'vue' }
    
  # Strip punctuation: ., ,, ;, /, -, +, # (except inside mapped tokens if any remained, but we mapped main ones)
  $t = $t -replace '[\.\,;/\-\+#]', ''
  $t = $t -replace '\s+', ''
    
  return $t
}

function Get-SalarySymbol {
  param([string]$Currency)
  
  switch ($Currency.ToUpper()) {
    'RUR' { return '₽' }
    'RUB' { return '₽' }
    'USD' { return '$' }
    'EUR' { return '€' }
    'KZT' { return '₸' }
    'BYN' { return 'Br' }
    'UAH' { return '₴' }
    default { return $Currency }
  }
}

Export-ModuleMember -Function Get-VacancyPublishedUtc, Test-Interactive, Show-ProgressWithPercent, Show-ProgressIndeterminate, Complete-Progress, Invoke-Quietly, Get-PlainDesc, Get-UtcDate, Get-RepoRoot, Join-RepoPath, Get-HHDoubleOrDefault, Get-HHNullableDouble, Get-Relative, Get-HHCanonicalSummary, Get-HHPlainSummary, Get-TextLanguage, Get-HHCanonicalSummaryEx, Normalize-HHSummaryText, Normalize-HHSummarySource, New-FileLock, Remove-FileLock, Test-AnotherInstanceRunning, Build-SearchQueryText, Get-HHCanonicalSalary, Get-HHSafePropertyValue, Bump-Http, Bump-Scrape, Log-CacheSummary, Log-ScrapeSummary, Get-OrDefault, Get-TrueRandomIndex, Invoke-Jitter, Initialize-HHGlobalCacheStats, Detect-Language, Resolve-SummaryLanguage, Normalize-SkillToken, Get-SalarySymbol
