# hh.helpers.psm1
# This module contains helper functions for data manipulation and canonicalization.

function Get-HHSimpleString {
  param($Value)
  if ($null -eq $Value) { return '' }
  if ($Value -is [string]) { return ([string]$Value).Trim() }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($candidate in @('name','Name','id','Id','value','Value')) {
      if ($Value.Contains($candidate) -and $Value[$candidate]) { return [string]$Value[$candidate] }
    }
    $first = $Value.Values | Where-Object { $_ } | Select-Object -First 1
    return Get-HHSimpleString -Value $first
  }
  if ($Value -is [psobject]) {
    foreach ($candidate in @('name','Name','id','Id','value','Value')) {
      $prop = $Value.PSObject.Properties[$candidate]
      if ($prop -and $prop.Value) { return ([string]$prop.Value).Trim() }
    }
    try { return ([string]$Value) } catch { return '' }
  }
  try { return ([string]$Value).Trim() } catch { return '' }
}

function Get-HHNullableDouble {
  param($Value)
  if ($null -eq $Value) { return $null }
  $tmp = 0.0
  if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)) {
    return $tmp
  }
  try { return [double]$Value } catch { return $null }
}

function Get-HHDoubleOrDefault {
  param($Value, [double]$Default = 0.0)
  $converted = Get-HHNullableDouble -Value $Value
  if ($converted -ne $null) { return $converted }
  return $Default
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

function Get-HHNullableInt {
  param($Value)
  if ($null -eq $Value) { return $null }
  $tmp = 0
  if ([int]::TryParse([string]$Value, [ref]$tmp)) { return $tmp }
  try { return [int]$Value } catch { return $null }
}

function Get-HHCanonicalSalary {
    param([object]$Detail)
    
    # DEBUG: Log what we're receiving
    Write-Host "[DEBUG] Get-HHCanonicalSalary called with Detail: $($Detail | ConvertTo-Json -Compress)" -ForegroundColor Yellow
    
    # Access salary data from both salary and salary_range properties
    # Use explicit property access instead of null-conditional operator
    $source = $null
    if ($Detail.salary -ne $null) {
        Write-Host "[DEBUG] Using salary property" -ForegroundColor Green
        $source = $Detail.salary
    } elseif ($Detail.salary_range -ne $null) {
        Write-Host "[DEBUG] Using salary_range property" -ForegroundColor Cyan
        $source = $Detail.salary_range
    }
    
    Write-Host "[DEBUG] Source object: $($source | ConvertTo-Json -Compress)" -ForegroundColor Yellow

  # Use explicit property access instead of null-conditional operator
  $fromVal = $null
  $toVal   = $null
  $currency = ''
  $gross = $null
  $frequency = ''
  $mode      = ''

  if ($source) {
    # Extract values explicitly
    if ($source.PSObject.Properties['from'] -and $source.from -ne $null) {
      $fromVal = Get-HHNullableDouble -Value $source.from
    }
    if ($source.PSObject.Properties['to'] -and $source.to -ne $null) {
      $toVal = Get-HHNullableDouble -Value $source.to
    }
    if ($source.PSObject.Properties['currency'] -and $source.currency) {
      $currency = [string]$source.currency
    }
    if ($source.PSObject.Properties['gross']) {
      try { $gross = [bool]$source.gross } catch { $gross = $null }
    }
    if ($source.PSObject.Properties['frequency']) {
      $frequency = Get-HHSimpleString -Value $source.frequency
    }
    if ($source.PSObject.Properties['mode']) {
      $mode = Get-HHSimpleString -Value $source.mode
    }
  }

  if ($currency) { $currency = $currency.ToUpperInvariant() } else { $currency = '' }
  Write-Host "[DEBUG] Extracted values - from: $fromVal, to: $toVal, currency: $currency, gross: $gross" -ForegroundColor Magenta

  $symbol = switch ($currency) {
    'RUR' { '₽' }
    'RUB' { '₽' }
    'USD' { '$' }
    'EUR' { '€' }
    'KZT' { '₸' }
    'UZS' { 'soʻm' }
    'BYR' { 'BYR' }
    'BYN' { 'BYN' }
    'UAH' { '₴' }
    'KGS' { '⃀' }
    'GEL' { '₾' }
    'AMD' { '֏' }
    'AZN' { '₼' }
    'AED' { 'د.إ' }
    'PLN' { 'zł' }
    'CZK' { 'Kč' }
    'HUF' { 'Ft' }
    'TRY' { '₺' }
    'TJS' { 'ЅМ' }
    'TMT' { 'T' }
    default { if ($currency) { $currency } else { '' } }
  }

  function Format-HHThousands {
    param([double]$Value)
    if ($null -eq $Value) { return '' }
    $rounded = [math]::Round($Value / 1000.0)
    return ("{0}k" -f $rounded)
  }

  $rangeText = ''
  if ($fromVal -ne $null -and $toVal -ne $null) {
    $rangeText = (Format-HHThousands $fromVal) + '–' + (Format-HHThousands $toVal)
  } elseif ($fromVal -ne $null) {
    $rangeText = (Format-HHThousands $fromVal) + '+'
  } elseif ($toVal -ne $null) {
    $rangeText = 'up to ' + (Format-HHThousands $toVal)
  }

  $freqText = if ($frequency) { $frequency } else { 'month' }
  $grossText = if ($gross -or ($mode -and $mode -eq 'gross')) { ' gross' } else { '' }
  $text = if ($rangeText) { ("{0} {1} / {2}{3}" -f $symbol, $rangeText, $freqText, $grossText).Trim() } else { '' }

  $upperCap = if ($toVal -ne $null) { $toVal } elseif ($fromVal -ne $null) { $fromVal } else { $null }

  $node = $null
  if ($source) {
    $node = [PSCustomObject]@{
      from      = $fromVal
      to        = $toVal
      currency  = $currency
      gross     = $gross
      frequency = if ($frequency) { $frequency } else { $null }
      mode      = if ($mode) { $mode } else { $null }
    }
  }

  return [PSCustomObject]@{
    text       = $text
    from       = $fromVal
    to         = $toVal
    currency   = $currency
    gross      = $gross
    frequency  = $frequency
    mode       = $mode
    symbol     = $symbol
    upper_cap  = $upperCap
    node       = $node
  }
}

function Import-HHModulesForParallel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModulesPath
    )
    
    $modules = @('hh.models.psm1', 'hh.util.psm1', 'hh.config.psm1', 'hh.log.psm1', 'hh.cache.psm1', 'hh.http.psm1')
    
    foreach ($m in $modules) {
        $path = Join-Path $ModulesPath $m
        if (Test-Path $path) {
            Import-Module -Name $path -DisableNameChecking -Force -ErrorAction SilentlyContinue
        }
    }
    
    if (Get-Command -Name 'Ensure-HHModelTypes' -ErrorAction SilentlyContinue) {
        Ensure-HHModelTypes
    }
}