# hh.llm.psm1 — LLM layer module (initial wrappers)
#Requires -Version 7.5

# Cache provider bootstrap (LiteDB optional)
try {
  if (-not (Get-Command -Name Read-CacheText -ErrorAction SilentlyContinue)) {
    if (-not (Get-Module -Name 'hh.cache')) {
      $cacheModulePath = Join-Path $PSScriptRoot 'hh.cache.psm1'
      if (Test-Path -LiteralPath $cacheModulePath) { Import-Module -Name $cacheModulePath -ErrorAction SilentlyContinue }
    }
  }
}
catch {}

# Ensure config helpers are available before resolving runtime defaults
try {
  if (-not (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
    if (-not (Get-Module -Name 'hh.config')) {
      $cfgModulePath = Join-Path $PSScriptRoot 'hh.config.psm1'
      if (Test-Path -LiteralPath $cfgModulePath) { Import-Module -Name $cfgModulePath -DisableNameChecking -ErrorAction SilentlyContinue }
    }
  }
}
catch {}

# Ensure util helpers are available (language detection, time helpers)
try {
  if (-not (Get-Module -Name 'hh.util')) {
    $utilModulePath = Join-Path $PSScriptRoot 'hh.util.psm1'
    if (Test-Path -LiteralPath $utilModulePath) { Import-Module -Name $utilModulePath -DisableNameChecking -ErrorAction SilentlyContinue }
  }
}
catch {}

$script:LlmUsageCounters = @{}
$script:PipelineStateRef = $null

function Set-LlmUsagePipelineState {
  param([psobject]$State)
  $script:PipelineStateRef = $State
}

function Get-LlmUsageCounters {
  return $script:LlmUsageCounters
}

function Add-LlmUsage {
  param(
    [Parameter(Mandatory = $true)][string]$Operation,
    [int]$TokensIn = 0,
    [int]$TokensOut = 0,
    [double]$EstimatedCost = 0
  )
  if (-not $script:LlmUsageCounters) { $script:LlmUsageCounters = @{} }
  if (-not $script:LlmUsageCounters.ContainsKey($Operation)) {
    $script:LlmUsageCounters[$Operation] = [ordered]@{
      Calls              = 0
      EstimatedTokensIn  = 0
      EstimatedTokensOut = 0
      EstimatedCost      = 0
    }
  }
  $entry = $script:LlmUsageCounters[$Operation]
  $entry.Calls = [int]($entry.Calls) + 1
  if ($TokensIn -gt 0) { $entry.EstimatedTokensIn = [int]$entry.EstimatedTokensIn + [int]$TokensIn }
  if ($TokensOut -gt 0) { $entry.EstimatedTokensOut = [int]$entry.EstimatedTokensOut + [int]$TokensOut }
  if ($EstimatedCost -gt 0) { $entry.EstimatedCost = [double]$entry.EstimatedCost + [double]$EstimatedCost }

  try {
    if ($script:PipelineStateRef) {
      $state = $script:PipelineStateRef
      if (-not $state.PSObject.Properties['LlmUsage']) {
        $state | Add-Member -NotePropertyName 'LlmUsage' -NotePropertyValue ([ordered]@{}) -Force
      }
      if (-not $state.LlmUsage.Contains($Operation)) {
        $state.LlmUsage[$Operation] = [ordered]@{
          Calls              = 0
          EstimatedTokensIn  = 0
          EstimatedTokensOut = 0
          EstimatedCost      = 0
        }
      }
      $state.LlmUsage[$Operation].Calls = [int]($state.LlmUsage[$Operation].Calls) + 1
      if ($TokensIn -gt 0) { $state.LlmUsage[$Operation].EstimatedTokensIn = [int]$state.LlmUsage[$Operation].EstimatedTokensIn + [int]$TokensIn }
      if ($TokensOut -gt 0) { $state.LlmUsage[$Operation].EstimatedTokensOut = [int]$state.LlmUsage[$Operation].EstimatedTokensOut + [int]$TokensOut }
      if ($EstimatedCost -gt 0) { $state.LlmUsage[$Operation].EstimatedCost = [double]$state.LlmUsage[$Operation].EstimatedCost + [double]$EstimatedCost }
    }
  }
  catch {}
}

function Get-LLMRuntimeConfig {
  param([Nullable[bool]]$EnabledOverride)

  $endpoint = ''
  $apiKey = ''
  $model = ''
  $enabled = $null

  # Apply explicit override from caller when provided
  if ($EnabledOverride -ne $null) { $enabled = [bool]$EnabledOverride }

  # Resolve config values
  try { 
    # Try new service config first
    $endpoint = [string](Get-HHConfigValue -Path @('llm', 'service', 'base_url'))
    if (-not [string]::IsNullOrWhiteSpace($endpoint)) {
      # Ensure endpoint is chat/completions compatible if generic base_url is provided
      if ($endpoint -notmatch '/chat/completions$') {
        $endpoint = $endpoint.TrimEnd('/') + '/chat/completions'
      }
    }
    # Fallback
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
      $endpoint = [string](Get-HHConfigValue -Path @('llm', 'endpoint')) 
    }
  }
  catch {}

  try { 
    $model = [string](Get-HHConfigValue -Path @('llm', 'service', 'model'))
    if ([string]::IsNullOrWhiteSpace($model)) {
      $model = [string](Get-HHConfigValue -Path @('llm', 'model')) 
    }
  }
  catch {}

  try {
    if (Get-Command -Name Get-HHSecrets -ErrorAction SilentlyContinue) {
      $sec = Get-HHSecrets
      if ($sec -and $sec.LlmApiKey) { $apiKey = [string]$sec.LlmApiKey }
    }
  }
  catch {}
  
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    try { $apiKey = [string]$env:LLM_API_KEY } catch {}
  }

  if ($enabled -eq $null) {
    try { $enabled = [bool](Get-HHConfigValue -Path @('llm', 'enabled_default') -Default $true) } catch { $enabled = $true }
  }

  $ready = (-not [string]::IsNullOrWhiteSpace($endpoint)) -and (-not [string]::IsNullOrWhiteSpace($model))
  
  return [pscustomobject]@{
    Endpoint = $endpoint
    ApiKey   = $apiKey
    Model    = $model
    Enabled  = [bool]$enabled
    Ready    = $ready
  }
}

function Set-LLMRuntimeGlobals {
  # Deprecated: No-op. Globals are removed.
  param([Nullable[bool]]$EnabledOverride)
  return (Get-LLMRuntimeConfig -EnabledOverride $EnabledOverride)
}

# Ensure globals are populated at import time (safe no-op when already set)
Set-LLMRuntimeGlobals | Out-Null

function Get-CacheProvider {
  <#
    .SYNOPSIS
    Returns current cache provider unified with hh.cache.

    .DESCRIPTION
    Uses hh.cache's provider when available ('litedb'/'file').
    Maps 'file' → 'json' for legacy file-backed paths.
  #>
  try {
    if (Get-Command -Name Get-HHCacheProvider -ErrorAction SilentlyContinue) {
      $prov = [string](Get-HHCacheProvider)
      if ($prov.ToLowerInvariant() -eq 'litedb') { return 'litedb' }
      return 'json'
    }
  }
  catch {}
  try {
    $p = [string](Get-HHConfigValue -Path @('cache', 'provider') -Default 'json')
    if ($p -and ($p.ToLowerInvariant() -eq 'litedb')) { return 'litedb' }
  }
  catch {}
  return 'json'
}

function Get-LlmCacheRoot {
  <#
  .SYNOPSIS
  Returns the base cache root for LLM helpers.

  .DESCRIPTION
  Defaults to `data/cache` under the repo root. If config provides
  `cache.root`, that path is used (relative paths resolved against repo root).
  Ensures the directory exists.
  #>
  $repoRoot = Split-Path -Path $PSScriptRoot -Parent
  $cacheRoot = Join-Path $repoRoot 'data/cache'
  try {
    if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
      $cfgRoot = [string](Get-HHConfigValue -Path @('cache', 'root') -Default '')
      if (-not [string]::IsNullOrWhiteSpace($cfgRoot)) {
        $cacheRoot = if ([System.IO.Path]::IsPathRooted($cfgRoot)) { $cfgRoot } else { Join-Path $repoRoot $cfgRoot }
      }
    }
  }
  catch {}
  try { New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null } catch {}
  return $cacheRoot
}

# Cache helper functions for EC/Lucky/Worst why
function Get-ECWhyPath {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $ECWhyRoot = Join-Path (Get-LlmCacheRoot) 'ecwhy'
  try { New-Item -ItemType Directory -Force -Path $ECWhyRoot | Out-Null } catch {}
  Join-Path $ECWhyRoot ("ec_" + $Id + ".txt")
}

function Get-LuckyWhyPath {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $LuckyWhyRoot = Join-Path (Get-LlmCacheRoot) 'luckywhy'
  try { New-Item -ItemType Directory -Force -Path $LuckyWhyRoot | Out-Null } catch {}
  Join-Path $LuckyWhyRoot ("lucky_" + $Id + ".txt")
}

function Get-WorstWhyPath {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $WorstWhyRoot = Join-Path (Get-LlmCacheRoot) 'worstwhy'
  try { New-Item -ItemType Directory -Force -Path $WorstWhyRoot | Out-Null } catch {}
  Join-Path $WorstWhyRoot ("worst_" + $Id + ".txt")
}

function Get-CoverLetterPath {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $root = Join-Path (Get-LlmCacheRoot) 'coverletters'
  try { New-Item -ItemType Directory -Force -Path $root | Out-Null } catch {}
  Join-Path $root ("cover_" + $Id + ".txt")
}

function Read-ECWhy {
  param([string]$Id)
  if (Get-Command -Name Read-CacheText -ErrorAction SilentlyContinue) {
    return (Read-CacheText -Collection 'ECWhy' -Id $Id)
  }
  # Fallback if hh.cache not loaded (should not happen in prod)
  $p = Get-ECWhyPath -Id $Id
  if ($p -and (Test-Path -LiteralPath $p)) {
    try { return (Get-Content -LiteralPath $p -Raw) } catch { return $null }
  }
  return $null
}

function Read-LuckyWhy {
  param([string]$Id)
  if (Get-Command -Name Read-CacheText -ErrorAction SilentlyContinue) {
    return (Read-CacheText -Collection 'LuckyWhy' -Id $Id)
  }
  $p = Get-LuckyWhyPath -Id $Id
  if ($p -and (Test-Path -LiteralPath $p)) {
    try { return (Get-Content -LiteralPath $p -Raw) } catch { return $null }
  }
  return $null
}

function Read-WorstWhy {
  param([string]$Id)
  if (Get-Command -Name Read-CacheText -ErrorAction SilentlyContinue) {
    return (Read-CacheText -Collection 'WorstWhy' -Id $Id)
  }
  $p = Get-WorstWhyPath -Id $Id
  if ($p -and (Test-Path -LiteralPath $p)) {
    try { return (Get-Content -LiteralPath $p -Raw) } catch { return $null }
  }
  return $null
}

function Read-CoverLetter {
  param([string]$Id)
  if (Get-Command -Name Read-CacheText -ErrorAction SilentlyContinue) {
    return (Read-CacheText -Collection 'CoverLetters' -Id $Id)
  }
  $p = Get-CoverLetterPath -Id $Id
  if ($p -and (Test-Path -LiteralPath $p)) {
    try { return (Get-Content -LiteralPath $p -Raw) } catch { return $null }
  }
  return $null
}

function Write-ECWhy {
  param([string]$Id, [string]$Why)
  if ([string]::IsNullOrWhiteSpace($Why)) {
    if (Get-Command -Name Remove-HHCacheItem -ErrorAction SilentlyContinue) {
      Remove-HHCacheItem -Collection 'ECWhy' -Key $Id
    }
    return
  }
  if (Get-Command -Name Write-CacheText -ErrorAction SilentlyContinue) {
    Write-CacheText -Collection 'ECWhy' -Id $Id -Text $Why | Out-Null
    return
  }
  $p = Get-ECWhyPath -Id $Id
  if ($p) { try { Set-Content -LiteralPath $p -Value $Why -Encoding utf8 -NoNewline } catch {} }
}

function Write-LuckyWhy {
  param([string]$Id, [string]$Why)
  if ([string]::IsNullOrWhiteSpace($Why)) {
    if (Get-Command -Name Remove-HHCacheItem -ErrorAction SilentlyContinue) {
      Remove-HHCacheItem -Collection 'LuckyWhy' -Key $Id
    }
    return
  }
  if (Get-Command -Name Write-CacheText -ErrorAction SilentlyContinue) {
    Write-CacheText -Collection 'LuckyWhy' -Id $Id -Text $Why | Out-Null
    return
  }
  $p = Get-LuckyWhyPath -Id $Id
  if ($p) { try { Set-Content -LiteralPath $p -Value $Why -Encoding utf8 -NoNewline } catch {} }
}

function Write-WorstWhy {
  param([string]$Id, [string]$Why)
  if ([string]::IsNullOrWhiteSpace($Why)) {
    if (Get-Command -Name Remove-HHCacheItem -ErrorAction SilentlyContinue) {
      Remove-HHCacheItem -Collection 'WorstWhy' -Key $Id
    }
    return
  }
  if (Get-Command -Name Write-CacheText -ErrorAction SilentlyContinue) {
    Write-CacheText -Collection 'WorstWhy' -Id $Id -Text $Why | Out-Null
    return
  }
  $p = Get-WorstWhyPath -Id $Id
  if ($p) { try { Set-Content -LiteralPath $p -Value $Why -Encoding utf8 -NoNewline } catch {} }
}

function Write-CoverLetter {
  param([string]$Id, [string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  if (Get-Command -Name Write-CacheText -ErrorAction SilentlyContinue) {
    Write-CacheText -Collection 'CoverLetters' -Id $Id -Text $Text | Out-Null
    return
  }
  $p = Get-CoverLetterPath -Id $Id
  if ($p) { try { Set-Content -LiteralPath $p -Value $Text -Encoding utf8 -NoNewline } catch {} }
}

# Internal helpers
<#
  .SYNOPSIS
  Calls the LLM chat/completions endpoint expecting a JSON object response.

  .DESCRIPTION
  Sends system/user messages to the configured LLM and parses the first choice
  message content as JSON. Uses the unified HTTP wrapper (Invoke-LlmApiRequest)
  to ensure consistent retries, rate limiting, and clean error handling.
#>
function LLM-InvokeJson {
  param(
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $false)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][object[]]$Messages,
    [double]$Temperature = 0.0,
    [int]$TimeoutSec = 60,
    [int]$MaxTokens = 0,
    [double]$TopP = 0,
    [hashtable]$ExtraParameters,
    [string]$OperationName = ''
  )
  $usageIn = 0
  $usageOut = 0
  function __ExtractJsonObject {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $s = $Text.Trim()
    $s = ($s -replace '^```json', '')
    $s = ($s -replace '^```', '')
    $s = ($s -replace '```$', '')
    $start = -1; $depth = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
      $ch = $s[$i]
      if ($ch -eq '{') { if ($start -lt 0) { $start = $i } ; $depth++ }
      elseif ($ch -eq '}') { if ($depth -gt 0) { $depth-- ; if ($depth -eq 0 -and $start -ge 0) { $len = $i - $start + 1; return $s.Substring($start, $len) } } }
    }
    return $null
  }
  try {
    $bodyObj = @{ model = $Model; temperature = $Temperature; response_format = @{type = 'json_object' }; messages = $Messages; stream = $false }
    if ($MaxTokens -gt 0) { $bodyObj['max_tokens'] = [int]$MaxTokens }
    if ($TopP -gt 0) { $bodyObj['top_p'] = [double]$TopP }
    if ($ExtraParameters) {
      $extraTable = @{}
      if ($ExtraParameters -is [System.Collections.IDictionary]) {
        foreach ($key in $ExtraParameters.Keys) { $extraTable[$key] = $ExtraParameters[$key] }
      }
      else {
        foreach ($prop in $ExtraParameters.PSObject.Properties) { $extraTable[$prop.Name] = $prop.Value }
      }
      foreach ($key in $extraTable.Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($key -eq 'messages') { continue }
        $bodyObj[$key] = $extraTable[$key]
      }
    }
    try {
      $mc = 0; try { $mc = [int]($Messages.Count) } catch {}
      $preview = ''; try {
        $preview = ($bodyObj | ConvertTo-Json -Depth 4)
        if ($preview) { $preview = $preview.Substring(0, [Math]::Min(300, [Math]::Max(0, $preview.Length))) }
      }
      catch {}
      Write-LogLLM ("[InvokeJson] prep: endpoint={0} model={1} temp={2} messages={3} body_preview={4}" -f $Endpoint, $Model, $Temperature, $mc, $preview) -Level Verbose
    }
    catch {}
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $headers['Authorization'] = "Bearer $ApiKey" }
    $resp = Invoke-LlmApiRequest -Endpoint $Endpoint -Method 'POST' -Headers $headers -Body $bodyObj -TimeoutSec $TimeoutSec
    try {
      $usageInfo = $resp.usage
      if ($usageInfo) {
        if ($usageInfo.prompt_tokens) { $usageIn = [int]$usageInfo.prompt_tokens }
        if ($usageInfo.completion_tokens) { $usageOut = [int]$usageInfo.completion_tokens }
      }
    }
    catch {}
    $content = $null
    $content = $null
    try {
      if ($resp.choices) { $content = $resp.choices[0].message.content }
      elseif ($resp.message) { $content = $resp.message.content }
    }
    catch {}
    if (-not $content -and $resp.error) {
      try {
        $err = $resp.error
        $ep = ''
        try { $ep = ($err | ConvertTo-Json -Depth 3) } catch {}
        Write-LogLLM ("[InvokeJson] error object: {0}" -f $ep) -Level Warning
      }
      catch {}
    }
    if ($content) {
      try {
        $cPrev = $content
        if ($cPrev) { $cPrev = $cPrev.Substring(0, [Math]::Min(400, [Math]::Max(0, $cPrev.Length))) }
        Write-LogLLM ("[InvokeJson] response preview: {0}" -f $cPrev) -Level Verbose
      }
      catch {}
      try { return ($content | ConvertFrom-Json) } catch {}
      $raw = ''
      try { $raw = __ExtractJsonObject -Text $content } catch {}
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { return ($raw | ConvertFrom-Json) } catch {}
      }
      try { Write-LogLLM "[InvokeJson] non-JSON content returned; extraction failed" -Level Warning } catch {}
    }
    else {
      try { Write-LogLLM "[InvokeJson] empty content" -Level Warning } catch {}
    }
  }
  catch {
    try { Write-LogLLM ("[LLM] JSON invoke failed: " + $_.Exception.Message) } catch {}
  }
  finally {
    if ($OperationName) {
      try { Add-LlmUsage -Operation $OperationName -TokensIn $usageIn -TokensOut $usageOut } catch {}
    }
  }
  return $null
}

<#
  .SYNOPSIS
  Calls the LLM chat/completions endpoint and returns plain text.

  .DESCRIPTION
  Sends system/user messages to the configured LLM and returns the trimmed
  text of the first choice message. Uses the unified HTTP wrapper (Invoke-LlmApiRequest)
  for reliable retries, rate limiting, and error handling.
#>
function LLM-InvokeText {
  param(
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $false)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][object[]]$Messages,
    [double]$Temperature = 0.4,
    [int]$TimeoutSec = 45,
    [int]$MaxTokens = 0,
    [double]$TopP = 0,
    [hashtable]$ExtraParameters,
    [string]$OperationName = ''
  )
  $usageIn = 0
  $usageOut = 0
  try {
    $bodyObj = @{ model = $Model; temperature = $Temperature; messages = $Messages; stream = $false }
    if ($MaxTokens -gt 0) { $bodyObj['max_tokens'] = [int]$MaxTokens }
    if ($TopP -gt 0) { $bodyObj['top_p'] = [double]$TopP }
    if ($ExtraParameters) {
      $extraTable = @{}
      if ($ExtraParameters -is [System.Collections.IDictionary]) {
        foreach ($key in $ExtraParameters.Keys) { $extraTable[$key] = $ExtraParameters[$key] }
      }
      else {
        foreach ($prop in $ExtraParameters.PSObject.Properties) { $extraTable[$prop.Name] = $prop.Value }
      }
      foreach ($key in $extraTable.Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($key -eq 'messages') { continue }
        $bodyObj[$key] = $extraTable[$key]
      }
    }
    try {
      $mc = 0; try { $mc = [int]($Messages.Count) } catch {}
      $preview = ''; try {
        $preview = ($bodyObj | ConvertTo-Json -Depth 4)
        if ($preview) { $preview = $preview.Substring(0, [Math]::Min(300, [Math]::Max(0, $preview.Length))) }
      }
      catch {}
      Write-LogLLM ("[InvokeText] prep: endpoint={0} model={1} temp={2} messages={3} body_preview={4}" -f $Endpoint, $Model, $Temperature, $mc, $preview) -Level Verbose
    }
    catch {}
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $headers['Authorization'] = "Bearer $ApiKey" }
    $resp = Invoke-LlmApiRequest -Endpoint $Endpoint -Method 'POST' -Headers $headers -Body $bodyObj -TimeoutSec $TimeoutSec
    try {
      $usageInfo = $resp.usage
      if ($usageInfo) {
        if ($usageInfo.prompt_tokens) { $usageIn = [int]$usageInfo.prompt_tokens }
        if ($usageInfo.completion_tokens) { $usageOut = [int]$usageInfo.completion_tokens }
      }
    }
    catch {}
    $text = ''
    if ($resp.choices) { $text = $resp.choices[0].message.content }
    elseif ($resp.message) { $text = $resp.message.content }
    if ($text) { $text = $text.Trim() }
    try {
      $tPrev = $text
      if ($tPrev) { $tPrev = $tPrev.Substring(0, [Math]::Min(300, [Math]::Max(0, $tPrev.Length))) }
      Write-LogLLM ("[InvokeText] response preview: {0}" -f $tPrev) -Level Verbose
    }
    catch {}
    return $text
  }
  catch { try { Write-LogLLM ("[LLM] text invoke failed: " + $_.Exception.Message) } catch {} }
  finally {
    if ($OperationName) {
      try { Add-LlmUsage -Operation $OperationName -TokensIn $usageIn -TokensOut $usageOut } catch {}
    }
  }
  return ''
}

# Public wrappers
function LLM-EditorsChoicePick {
  param(
    [Parameter(Mandatory = $true)][object[]]$Items,
    [string]$CvText = '',
    [string]$PersonaSystem = '',
    [string]$UserPrefix = '',
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $false)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [double]$Temperature = 0.4,
    [int]$TimeoutSec = 60,
    [int]$MaxTokens = 0,
    [double]$TopP = 0,
    [hashtable]$ExtraParameters,
    [string]$OperationName = 'picks.ec_why'
  )
  # Ensure no null values in items to avoid "null key is not allowed in a hash literal" error
  $filteredItems = if ($null -eq $Items) { @() } else { @($Items | Where-Object { $null -ne $_ }) }
  
  # Deep filter null values from each item to prevent null keys in JSON serialization
  # Filter and map items to concise structure
  $cleanedItems = @()
  foreach ($item in $filteredItems) {
    if (-not $item) { continue }
    $desc = ''
    try { $desc = [string]($item.PlainDesc ?? $item.plain_desc ?? $item.Description ?? $item.description ?? $item.Summary ?? $item.summary ?? '') } catch {}
    
    # Fallback to Meta summary/desc if main is empty
    if ([string]::IsNullOrWhiteSpace($desc)) {
      try { $desc = [string]($item.Meta?.Summary?.Text ?? $item.Meta?.plain_desc ?? '') } catch {}
    }

    if ($desc.Length -gt 1000) { $desc = $desc.Substring(0, 1000) + "..." }
    
    $cleanObj = [ordered]@{
      id       = [string]($item.Id ?? $item.id)
      title    = [string]($item.Title ?? $item.title ?? $item.Name ?? $item.name ?? '')
      employer = [string]($item.EmployerName ?? $item.employer_name ?? $item.Employer?.Name ?? $item.employer?.name ?? '')
      desc     = $desc
    }
    
    # Add salary helper if available
    try {
      $sal = [string]($item.SalaryText ?? $item.salary_text ?? $item.Salary ?? $item.salary ?? '')
      if (-not [string]::IsNullOrWhiteSpace($sal)) { $cleanObj['salary'] = $sal }
    }
    catch {}

    $cleanedItems += $cleanObj
  }
  
  if ([string]::IsNullOrWhiteSpace($PersonaSystem) -or [string]::IsNullOrWhiteSpace($UserPrefix)) {
    $promptInfo = $null
    if (Get-Command -Name Get-LlmPromptForOperation -ErrorAction SilentlyContinue) {
      $promptInfo = Get-LlmPromptForOperation -Operation 'picks.ec_why'
    }
    if ([string]::IsNullOrWhiteSpace($PersonaSystem)) {
      if ($promptInfo -and $promptInfo.System) {
        $PersonaSystem = [string]$promptInfo.System
      }
      else {
        $PersonaSystem = @"
Return a JSON object: {"pick":"","why":"short reason"}
Pick the single vacancy that best matches the candidate's skills and seniority for a C-level/Head profile.
Prioritize leadership scope, English-friendly context, and relevance to skills.
"@
      }
    }
    if ([string]::IsNullOrWhiteSpace($UserPrefix) -and $promptInfo -and $promptInfo.User) {
      $UserPrefix = [string]$promptInfo.User
    }
  }

  $usrPayload = (@{items = $cleanedItems } | ConvertTo-Json -Depth 5)
  if (-not [string]::IsNullOrWhiteSpace($UserPrefix)) {
    $usrPayload = $UserPrefix + "`n`n" + $usrPayload
  }
  $usr = "CANDIDATE SKILLS: $CvText`nVACANCIES (JSON):`n" + $usrPayload
  $messages = @( @{role = 'system'; content = $PersonaSystem }, @{role = 'user'; content = $usr } )
  $obj = LLM-InvokeJson -Endpoint $Endpoint -ApiKey $ApiKey -Model $Model -Messages $messages -Temperature $Temperature -TimeoutSec $TimeoutSec -MaxTokens $MaxTokens -TopP $TopP -ExtraParameters $ExtraParameters -OperationName $OperationName
  if ($obj) {
    if ($obj.pick) { return [PSCustomObject]@{ id = $obj.pick; why = ([string]$obj.why) } }
    if ($obj.picks -and $obj.picks.Count -gt 0) {
      $first = $obj.picks[0]
      # Handle id/pick key in nested object
      $id = if ($first.id) { $first.id } elseif ($first.pick) { $first.pick } else { $null }
      if ($id) {
        return [PSCustomObject]@{ id = $id; why = ([string]($first.why ?? $first.reason ?? '')) }
      }
    }
  }
  return $null
}

function LLM-PickFromList {
  param(
    [Parameter(Mandatory = $true)][object[]]$Items,
    [Parameter(Mandatory = $true)][string]$Kind,
    [string]$SystemPrompt = '',
    [string]$UserPrefix = ''
  )
  
  # Map kind to operation for config resolution
  $opName = switch ($Kind) {
    'worst' { 'picks.worst_why' }
    'lucky' { 'picks.lucky_why' }
    default { 'picks.ec_why' }
  }
  
  $cfg = Resolve-LlmOperationConfig -Operation $opName
  if (-not $cfg.Ready) { return $null }

  $take = [Math]::Min(20, $Items.Count)
  $clean = @()
  for ($i = 0; $i -lt $take; $i++) {
    $r = $Items[$i]
    if (-not $r) { continue }
    $desc = ''
    try { $desc = [string]($r.plain_desc ?? $r.desc ?? $r.summary ?? '') } catch {}
    if ([string]::IsNullOrWhiteSpace($desc)) {
      try { $desc = [string]($r.meta?.plain_desc ?? $r.meta?.summary?.text ?? '') } catch {}
    }
    if ($desc.Length -gt 900) { $desc = $desc.Substring(0, 900) }
    $clean += @{
      id       = [string]$r.id
      title    = [string]($r.title ?? $r.name ?? '')
      employer = [string]($r.employer ?? $r.employer_name ?? '')
      desc     = $desc
    }
  }
  if ($clean.Count -eq 0) { return $null }
  $sys = $SystemPrompt
  if ([string]::IsNullOrWhiteSpace($sys)) {
    switch ($Kind) {
      'lucky' {
        $sys = 'Return JSON: {"pick":"","why":""}. Pick a wildcard/high-upside role (not necessarily top score). Prioritize surprising upside, variety, and adventure. One pick only.'
      }
      'worst' {
        $sys = 'Return JSON: {"pick":"","why":""}. Pick the single worst-fit role (red flags, poor match, dead-end). Be blunt.'
      }
      default {
        $sys = 'Return JSON: {"pick":"","why":""}. Pick one item.'
      }
    }
  }
  $usrPayload = @{ items = $clean } | ConvertTo-Json -Depth 5
  $usr = if ([string]::IsNullOrWhiteSpace($UserPrefix)) { $usrPayload } else { ($UserPrefix + "`n" + $usrPayload) }
  $messages = @( @{role = 'system'; content = $sys }, @{role = 'user'; content = $usr } )
  $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.0 }
  $obj = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature $temperature -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName $opName
  if ($obj -and $obj.pick) { return [PSCustomObject]@{ id = [string]$obj.pick; reason = [string]$obj.why } }
  return $null
}

function LLM-PickLucky {
  param([Parameter(Mandatory = $true)][object[]]$Items)
  
  if (-not $Items -or $Items.Count -eq 0) { return $null }

  # Since Apply-Picks already selected the random item, just use the first item in the array.
  # This function's role is now primarily to generate the "why" for the pre-selected item.
  $pick = $Items[0] 
  
  # Generate explanation
  $empName = ''
  try { $empName = $pick.EmployerName } catch { $empName = $pick.employer }
  $summ = ''
  try { $summ = $pick.Summary } catch { $summ = $pick.description }
  
  $why = Get-LuckyWhyText -Id ([string]$pick.id) -Title ([string]$pick.title) -Employer ([string]$empName) -Score ([double]$pick.score) -Summary ([string]$summ)

  # Ensure ID is string for comparison
  return [PSCustomObject]@{ id = [string]$pick.id; reason = $why }
}

function LLM-PickWorst {
  param([Parameter(Mandatory = $true)][object[]]$Items)
  $sys = ''
  try { $sys = [string](Get-HHConfigValue -Path @('llm', 'prompts', 'pick_worst', 'system') -Default '') } catch {}
  
  # LLM Selection
  $pick = LLM-PickFromList -Items $Items -Kind 'worst' -SystemPrompt $sys -UserPrefix 'Pick the single worst-fit vacancy (JSON array "items").'
  
  # Fallback: Lowest Score (SDD-6.4)
  if (-not $pick) {
    $lowest = $Items | Sort-Object Score | Select-Object -First 1
    if ($lowest) {
      return [PSCustomObject]@{ id = [string]$lowest.id; reason = "" }
    }
  }
  
  return $pick
}

function LLM-GenerateText {
  param(
    [Parameter(Mandatory = $true)][string]$Sys,
    [Parameter(Mandatory = $true)][string]$Usr,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $false)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [double]$Temperature = 0.4,
    [int]$MaxTokens = 0,
    [double]$TopP = 0,
    [hashtable]$ExtraParameters,
    [string]$OperationName = ''
  )
  $messages = @( @{role = 'system'; content = $Sys }, @{role = 'user'; content = $Usr } )
  return (LLM-InvokeText -Endpoint $Endpoint -ApiKey $ApiKey -Model $Model -Messages $messages -Temperature $Temperature -MaxTokens $MaxTokens -TopP $TopP -ExtraParameters $ExtraParameters -OperationName $OperationName)
}

function LLM-GenerateCoverLetter {
  param(
    [Parameter(Mandatory = $true)][psobject]$Vacancy,
    [string]$CvText = '',
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $false)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [double]$Temperature = 0.35
  )

  if (-not $Vacancy) { return '' }

  $sysDefault = @"
You are an executive career coach who writes concise, high-impact cover letters (<= 220 words).
Tone: confident, tailored, achievement-focused, no fluff.
Goal: sell the candidate as the obvious fit while respecting the vacancy's language (ru/en) and culture.
"@
  $sysPrompt = $sysDefault
  try {
    $cfgPrompt = [string](Get-HHConfigValue -Path @('llm', 'cover_letters', 'system_prompt') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($cfgPrompt)) { $sysPrompt = $cfgPrompt }
  }
  catch {}

  $usrSections = New-Object System.Collections.Generic.List[string]

  $title = [string]($Vacancy.title ?? $Vacancy.name ?? '')
  $employer = [string]($Vacancy.employer_name ?? $Vacancy.employer ?? $Vacancy.employer?.name ?? '')
  $city = [string]($Vacancy.city ?? $Vacancy.area ?? '')
  $salary = [string]($Vacancy.salary_text ?? $Vacancy.salary ?? '')
  $summary = [string]($Vacancy.summary ?? '')
  $skills = @()
  try { if ($Vacancy.skills_matched) { $skills = [string[]](@($Vacancy.skills_matched) | Where-Object { $_ }) } } catch {}

  $usrSections.Add("Vacancy Title: $title")
  if (-not [string]::IsNullOrWhiteSpace($employer)) { $usrSections.Add("Employer: $employer") }
  if (-not [string]::IsNullOrWhiteSpace($city)) { $usrSections.Add("Location: $city") }
  if (-not [string]::IsNullOrWhiteSpace($salary)) { $usrSections.Add("Salary: $salary") }
  $usrSections.Add("Score: " + ("{0:0.00}" -f [double]($Vacancy.score ?? 0)))

  if (-not [string]::IsNullOrWhiteSpace($summary)) {
    $usrSections.Add("Role Summary: $summary")
  }
  else {
    $usrSections.Add("Role Summary: N/A")
  }

  if ($skills -and $skills.Count -gt 0) {
    $usrSections.Add("Matched Skills: " + ($skills -join ', '))
  }

  if ($Vacancy.tip) {
    $usrSections.Add("Recommendation Tip: " + ($Vacancy.tip -replace '\s+', ' ').Trim())
  }

  if (-not [string]::IsNullOrWhiteSpace($CvText)) {
    $usrSections.Add("Candidate Profile:\n$CvText")
  }

  $usrTemplateDefault = @"
Use the information above to craft a tailored cover letter. Reference specific matched skills and align achievements to the vacancy's needs. Close with a confident call-to-action.
"@
  try {
    $cfgTemplate = [string](Get-HHConfigValue -Path @('llm', 'cover_letters', 'user_instruction') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($cfgTemplate)) {
      $usrSections.Add($cfgTemplate)
    }
    else {
      $usrSections.Add($usrTemplateDefault.Trim())
    }
  }
  catch {
    $usrSections.Add($usrTemplateDefault.Trim())
  }

  $usr = ($usrSections | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n`n"
  return LLM-GenerateText -Sys $sysPrompt -Usr $usr -Endpoint $Endpoint -ApiKey $ApiKey -Model $Model -Temperature $Temperature
}

function LLM-MeasureCultureRisk {
  param(
    [Parameter(Mandatory = $true)][string]$EmployerName,
    [Parameter(Mandatory = $true)][string]$PlainDesc,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $false)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model
  )
  $promptInfo = $null
  if (Get-Command -Name Get-LlmPromptForOperation -ErrorAction SilentlyContinue) {
    $promptInfo = Get-LlmPromptForOperation -Operation 'culture_risk'
  }
  $sys = if ($promptInfo) { [string]$promptInfo.System } else { '' }
  if ([string]::IsNullOrWhiteSpace($sys)) { $sys = 'Rate cultural/political risk on 0..1 (0=no concern, 1=high risk, e.g. state-linked, propaganda, sanctioned). Return JSON: {"risk":0..1}.' }
  $usr = "Employer: $EmployerName`nDescription: $PlainDesc"
  $messages = @( @{role = 'system'; content = $sys }, @{role = 'user'; content = $usr } )
  $obj = LLM-InvokeJson -Endpoint $Endpoint -ApiKey $ApiKey -Model $Model -Messages $messages -Temperature 0 -OperationName 'culture_risk'
  if ($obj -and $obj.risk -ne $null) { return [double]$obj.risk }
  return 0.0
}

function Invoke-LLMPreclassifyBatch {
  param([Parameter(Mandatory = $true)][object[]]$Items)
  $map = @{}
  if (-not $Items -or $Items.Count -eq 0) { return $map }
  $cfg = Set-LLMRuntimeGlobals
  if (-not $cfg.Enabled) { return $map }
  if (-not $cfg.Ready) {
    try { Write-LogLLM "[Preclass] LLM not configured (missing endpoint/model/key); skipping preclassify" -Level Warning } catch {}
    return $map
  }
  $batchSize = 20
  for ($i = 0; $i -lt $Items.Count; $i += $batchSize) {
    $j = [Math]::Min($i + $batchSize - 1, $Items.Count - 1)
    $chunk = $Items[$i..$j]
    $payload = @{ items = @(
        $chunk | ForEach-Object {
          [PSCustomObject]@{ id = [string]$_.id; title = [string]$_.title; desc = [string]$_.desc; employer = [string]$_.employer }
        }
      ) 
    } | ConvertTo-Json -Depth 6
    $sysEn = ''
    $sysRu = ''
    try { $sysEn = [string](Get-HHConfigValue -Path @('llm', 'prompts', 'preclass', 'system_en') -Default '') } catch {}
    try { $sysRu = [string](Get-HHConfigValue -Path @('llm', 'prompts', 'preclass', 'system_ru') -Default '') } catch {}
    $sys = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { $sysEn } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { $sysRu } else { 'Return a JSON object: {"results":[{"id":"...","english_ratio":0..1,"is_remote":true|false,"is_management":true|false,"seniority":"junior|mid|senior|lead|head|director|c-level"}]}' }
    $usr = "CLASSIFY THESE VACANCIES (JSON):`n$payload"
    $messages = @( @{ role = 'system'; content = $sys }, @{ role = 'user'; content = $usr } )
    $obj = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature 0
    if ($obj -and $obj.results) {
      foreach ($r in $obj.results) { try { $map[[string]$r.id] = $r } catch {} }
    }
  }
  return $map
}


function Read-LLMCache([string]$VacId, [Nullable[DateTime]]$PubUtc) {
  if ([string]::IsNullOrWhiteSpace($VacId) -or -not $PubUtc) { return $null }
  $key = ("{0}|{1:yyyyMMddHHmm}" -f $VacId, $PubUtc.ToUniversalTime())
  $cached = Get-HHCacheItem -Collection 'llm' -Key $key
  if ($cached) {
    try {
      if ($global:CacheStats) { $global:CacheStats.llm_cached++ }
    }
    catch {}
    return $cached
  }
  return $null
}

function Write-LLMCache([string]$VacId, [Nullable[DateTime]]$PubUtc, $Obj) {
  if (-not $Obj) { return }
  if ([string]::IsNullOrWhiteSpace($VacId) -or -not $PubUtc) { return }
  $key = ("{0}|{1:yyyyMMddHHmm}" -f $VacId, $PubUtc.ToUniversalTime())
  Set-HHCacheItem -Collection 'llm' -Key $key -Value $Obj -Metadata @{ vac = $VacId }
}

function Invoke-VacancyPreclass {
  param(
    [object[]]$Items,
    [string]$ActivityName = "LLM preclassify",
    [int]$Limit = 0
  )
  $map = @{}
  if (-not $Items -or $Items.Count -eq 0) { return $map }

  $toClassify = @()
  foreach ($vv in $Items) {
    $pubUtcTmp = $null
    try { $pubUtcTmp = Get-UtcDate $vv.pub_utc } catch {}
    if (-not $pubUtcTmp) { try { $pubUtcTmp = Get-UtcDate $vv.published_at } catch {} }
    
    $cached = if ($vv.id -and $pubUtcTmp -and $pubUtcTmp -is [DateTime]) { Read-LLMCache -VacId $vv.id -PubUtc $pubUtcTmp } else { $null }
    if ($cached) { 
      $map[$vv.id] = $cached
      continue 
    }
    
    $plainDesc = ''
    try { $plainDesc = $vv.plain_desc } catch {}
    if (-not $plainDesc) { try { $plainDesc = $vv.description } catch {} }
    
    $empName = ''
    try { $empName = $vv.employer.name } catch {}
    
    $toClassify += [PSCustomObject]@{ id = $vv.id; title = $vv.name; desc = $plainDesc; employer = $empName; pubUtc = $pubUtcTmp }
  }

  if ($Limit -gt 0) { $toClassify = $toClassify | Select-Object -First $Limit }
  if ($toClassify.Count -eq 0) { return $map }

  # Call the batch processor
  $batchResults = Invoke-LLMPreclassifyBatch -Items $toClassify
  
  # Merge results and update cache
  foreach ($k in $batchResults.Keys) {
    $obj = $batchResults[$k]
    if ($obj) {
      $map[$k] = $obj
      # Find the original item to get pubUtc for caching
      $orig = $toClassify | Where-Object { [string]$_.id -eq [string]$k } | Select-Object -First 1
      if ($orig -and $orig.pubUtc -and $orig.pubUtc -is [DateTime]) {
        Write-LLMCache -VacId $k -PubUtc $orig.pubUtc -Obj $obj
      }
    }
  }
  
  return $map
}

function Resolve-LlmOperationConfig {
  <#
    .SYNOPSIS
    Resolves the LLM configuration (endpoint, key, model) for a specific operation.

    .DESCRIPTION
    Maps a logical operation (e.g. 'summary.remote', 'picks.ec_why') to a provider
    configuration. Reads 'llm.operations.<op>' to find the provider/model, then
    looks up 'llm.providers.<provider>' to get connection details.
    Falls back to legacy global settings if operation/provider is not defined.

    .PARAMETER Operation
    The logical operation name (e.g., 'summary.remote').

    .OUTPUTS
    PSCustomObject { Endpoint, ApiKey, Model, Provider, Ready, TimeoutSec }
  #>
  param([string]$Operation)

  # 1. Get Operation Config
  $opConfig = $null
  try { $opConfig = Get-HHConfigValue -Path @('llm', 'operations', $Operation) } catch {}
  
  $providerName = ''
  $modelName = ''
  $opTemperature = $null
  $opMaxTokens = $null
  $opTopP = $null
  $opLanguage = ''
  $opTimeout = $null
  $opAuthPath = $null
  $opParams = $null
  
  if ($opConfig) {
    if ($opConfig -is [System.Collections.IDictionary]) {
      $providerName = [string]$opConfig['provider']
      $modelName = [string]$opConfig['model']
      if ($opConfig.Contains('temperature')) { $opTemperature = [double]$opConfig['temperature'] }
      if ($opConfig.Contains('max_tokens')) { $opMaxTokens = [int]$opConfig['max_tokens'] }
      if ($opConfig.Contains('top_p')) { $opTopP = [double]$opConfig['top_p'] }
      if ($opConfig.Contains('language')) { $opLanguage = [string]$opConfig['language'] }
      if ($opConfig.Contains('timeout_sec')) { $opTimeout = [int]$opConfig['timeout_sec'] }
      if ($opConfig.Contains('auth_key_path')) { $opAuthPath = $opConfig['auth_key_path'] }
      if ($opConfig.Contains('parameters')) { $opParams = $opConfig['parameters'] }
    }
    elseif ($opConfig.PSObject.Properties['provider']) {
      $providerName = [string]$opConfig.provider
      if ($opConfig.PSObject.Properties['model']) { $modelName = [string]$opConfig.model }
      if ($opConfig.PSObject.Properties['temperature']) { $opTemperature = [double]$opConfig.temperature }
      if ($opConfig.PSObject.Properties['max_tokens']) { $opMaxTokens = [int]$opConfig.max_tokens }
      if ($opConfig.PSObject.Properties['top_p']) { $opTopP = [double]$opConfig.top_p }
      if ($opConfig.PSObject.Properties['language']) { $opLanguage = [string]$opConfig.language }
      if ($opConfig.PSObject.Properties['timeout_sec']) { $opTimeout = [int]$opConfig.timeout_sec }
      if ($opConfig.PSObject.Properties['auth_key_path']) { $opAuthPath = $opConfig.auth_key_path }
      if ($opConfig.PSObject.Properties['parameters']) { $opParams = $opConfig.parameters }
    }
  }

  # 2. Resolve Provider
  $provConfig = $null
  if (-not [string]::IsNullOrWhiteSpace($providerName)) {
    try { $provConfig = Get-HHConfigValue -Path @('llm', 'providers', $providerName) } catch {}
  }

  # 3. Build Config Object
  $endpoint = ''
  $apiKey = ''
  $timeout = 60
  
  $baseUrl = ''
  $type = ''
  $authKeyPath = $null
  
  if ($provConfig) {
    if ($provConfig -is [System.Collections.IDictionary]) {
      $baseUrl = [string]$provConfig['base_url']
      $type = [string]$provConfig['type']
      $authKeyPath = $provConfig['auth_key_path']
      if ($provConfig['timeout_sec']) { $timeout = [int]$provConfig['timeout_sec'] }
      if ([string]::IsNullOrWhiteSpace($modelName) -and $provConfig['default_model']) { $modelName = [string]$provConfig['default_model'] }
    }
    elseif ($provConfig.PSObject.Properties['base_url']) {
      $baseUrl = [string]$provConfig.base_url
      if ($provConfig.PSObject.Properties['type']) { $type = [string]$provConfig.type }
      if ($provConfig.PSObject.Properties['auth_key_path']) { $authKeyPath = $provConfig.auth_key_path }
      if ($provConfig.PSObject.Properties['timeout_sec']) { $timeout = [int]$provConfig.timeout_sec }
      if ([string]::IsNullOrWhiteSpace($modelName) -and $provConfig.PSObject.Properties['default_model']) { $modelName = [string]$provConfig.default_model }
    }
  }

  if ($opTimeout -ne $null) { $timeout = [int]$opTimeout }

  if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
    # Resolve Endpoint
    if ($type -eq 'ollama') {
      $endpoint = "$baseUrl/api/chat" # Ollama chat endpoint
    }
    elseif ($type -eq 'openai-compatible') {
      if ($baseUrl -match '/chat/completions$') {
        $endpoint = $baseUrl
      }
      else {
        $endpoint = "$baseUrl/chat/completions"
      }
    }
    else {
      $endpoint = $baseUrl # Trust config for other types
    }

    # Resolve API Key
    $resolvedKeyPath = $authKeyPath
    if ($opAuthPath) { $resolvedKeyPath = $opAuthPath }
    if ($resolvedKeyPath) {
      if ($authKeyPath -is [Array]) {
        try { $apiKey = [string](Get-HHConfigValue -Path $resolvedKeyPath) } catch {}
      }
      elseif ($resolvedKeyPath -is [string]) {
        try { $apiKey = [string](Get-HHConfigValue -Path $resolvedKeyPath) } catch {}
      }
      elseif ($resolvedKeyPath -is [System.Collections.IEnumerable]) {
        # Handle ArrayList etc
        try { $apiKey = [string](Get-HHConfigValue -Path @($resolvedKeyPath)) } catch {}
      }
    }
  }

  # 4. Fallback to Legacy Globals if resolution failed
  if ([string]::IsNullOrWhiteSpace($endpoint)) {
    $legacy = Get-LLMRuntimeConfig
    $endpoint = $legacy.Endpoint
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $legacy.ApiKey }
    if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = $legacy.Model }
  }
  $temperatureFinal = $null
  if ($opTemperature -ne $null) { $temperatureFinal = [double]$opTemperature }
  $paramTable = $null
  if ($opParams) {
    $paramTable = @{}
    if ($opParams -is [System.Collections.IDictionary]) {
      foreach ($key in $opParams.Keys) { $paramTable[$key] = $opParams[$key] }
    }
    else {
      foreach ($prop in $opParams.PSObject.Properties) { $paramTable[$prop.Name] = $prop.Value }
    }
  }

  # Final Readiness Check
  $ready = (-not [string]::IsNullOrWhiteSpace($endpoint)) -and (-not [string]::IsNullOrWhiteSpace($modelName))
  # ApiKey is optional for local/ollama, but usually required for remote. 
  # We'll assume if endpoint is set, we proceed. The call will fail if auth is missing where needed.

  return [pscustomobject]@{
    Endpoint           = $endpoint
    ApiKey             = $apiKey
    Model              = $modelName
    Provider           = $providerName
    Ready              = $ready
    TimeoutSec         = $timeout
    Temperature        = $temperatureFinal
    MaxTokens          = if ($opMaxTokens -ne $null) { [int]$opMaxTokens } else { $null }
    TopP               = if ($opTopP -ne $null) { [double]$opTopP } else { $null }
    LanguagePreference = $opLanguage
    ProviderType       = $type
    Parameters         = $paramTable
  }
}

function Get-LlmPromptForOperation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Operation,
    [string]$VacancyTitle,
    [string]$VacancyDescription,
    [string]$PreferredLanguage = ''
  )

  function GetPromptValue {
    param([string[][]]$Paths, [string]$DefaultPrompt)
    foreach ($p in $Paths) {
      try {
        $val = [string](Get-HHConfigValue -Path $p -Default '')
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
      }
      catch {}
    }
    return $DefaultPrompt
  }

  $op = $Operation.ToLowerInvariant()
  $langInfo = $null
  $lang = ''

  if ($op -like 'summary.*') {
    $langInfo = Resolve-SummaryLanguage -VacancyTitle $VacancyTitle -VacancyDescription $VacancyDescription -Preferred $PreferredLanguage
    $lang = if ($langInfo -and $langInfo.Language -eq 'ru') { 'ru' } else { 'en' }
    $target = if ($op -eq 'summary.local') { 'local' } else { 'remote' }
    $sysDefault = if ($lang -eq 'en') { 'You are a concise job summarizer. Reply in English with 1–2 crisp sentences highlighting responsibilities, scope, and tech; skip benefits. Never repeat job title or company.' } else { 'Ты — краткий аналитик вакансий. Дай 1–2 предложения про обязанности, масштаб и стек, без соцпакета и без повторения названия должности/компании.' }
    $usrDefault = if ($lang -eq 'en') { "Summarize the vacancy (max 2 sentences, <40 words). Focus on responsibilities, scope, and domain. Text:`n{{text}}" } else { "Сформулируй краткое описание вакансии (до 2 предложений, <40 слов). Покажи обязанности, масштаб и домен. Текст:`n{{text}}" }
    $sys = GetPromptValue -Paths @(
      @('llm', 'prompts', 'summary', $target, "system_$lang"),
      @('llm', 'prompts', 'summary', "system_$lang")
    ) -DefaultPrompt $sysDefault
    $usr = GetPromptValue -Paths @(
      @('llm', 'prompts', 'summary', $target, "user_$lang"),
      @('llm', 'prompts', 'summary', "user_$lang")
    ) -DefaultPrompt $usrDefault

    return [pscustomobject]@{
      System    = $sys
      User      = $usr
      Language  = $lang
      Detection = $langInfo
    }
  }

  $pickDefaultEn = 'You are "The Aperture" — a brutally honest, darkly sarcastic executive headhunter. In 1–2 crisp sentences (around 30–50 words total), explain why THIS role is the best strategic fit for the candidate. Be incisive, specific, and a bit ruthless. No fluff. Do not repeat the job title or company name.'
  $pickLuckyDefault = 'You are "The Aperture" — a brutally honest, darkly sarcastic executive headhunter. In ~1–2 sentences, sell this as a high-upside wildcard ("I feel lucky"): identify the asymmetric upside and why it is worth a punt. No fluff. Do not repeat title/company.'
  $pickWorstDefault = 'You are "The Aperture". In ~1–2 sentences, explain with dark sarcasm why this vacancy is strategically the worst fit (deal-breakers, cul-de-sac risks, red flags). No title/company repetition.'

  switch ($op) {
    { $_ -in @('picks.ec_why', 'picks.why.ec') } {
      $sysEn = GetPromptValue -Paths (, @('llm', 'prompts', 'ec_why', 'system_en')) -DefaultPrompt ''
      $sysRu = GetPromptValue -Paths (, @('llm', 'prompts', 'ec_why', 'system_ru')) -DefaultPrompt ''
      $sys = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { $sysEn } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { $sysRu } else { $pickDefaultEn }
      $lang = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { 'en' } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { 'ru' } else { 'en' }
      return [pscustomobject]@{ System = $sys; User = ''; Language = $lang; Detection = $null }
    }
    { $_ -in @('picks.lucky_why', 'picks.why.lucky') } {
      $sysEn = GetPromptValue -Paths (, @('llm', 'prompts', 'lucky_why', 'system_en')) -DefaultPrompt ''
      $sysRu = GetPromptValue -Paths (, @('llm', 'prompts', 'lucky_why', 'system_ru')) -DefaultPrompt ''
      $sys = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { $sysEn } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { $sysRu } else { $pickLuckyDefault }
      $lang = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { 'en' } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { 'ru' } else { 'en' }
      return [pscustomobject]@{ System = $sys; User = ''; Language = $lang; Detection = $null }
    }
    { $_ -in @('picks.worst_why', 'picks.why.worst') } {
      $sysEn = GetPromptValue -Paths (, @('llm', 'prompts', 'worst_why', 'system_en')) -DefaultPrompt ''
      $sysRu = GetPromptValue -Paths (, @('llm', 'prompts', 'worst_why', 'system_ru')) -DefaultPrompt ''
      $sys = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { $sysEn } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { $sysRu } else { $pickWorstDefault }
      $lang = if (-not [string]::IsNullOrWhiteSpace($sysEn)) { 'en' } elseif (-not [string]::IsNullOrWhiteSpace($sysRu)) { 'ru' } else { 'en' }
      return [pscustomobject]@{ System = $sys; User = ''; Language = $lang; Detection = $null }
    }
    'culture_risk' {
      $sys = GetPromptValue -Paths @(
        @('llm', 'prompts', 'culture_risk', 'system_en'),
        @('llm', 'prompts', 'culture_risk', 'system_ru'),
        @('llm', 'prompts', 'culture_risk', 'system')
      ) -DefaultPrompt 'Rate cultural risk on 0..1. Return JSON: {"risk":0..1}'
      $lang = if ($sys -and $sys -like '*risk*') { 'en' } else { 'ru' }
      return [pscustomobject]@{ System = $sys; User = ''; Language = $lang; Detection = $null }
    }
    default { return [pscustomobject]@{ System = ''; User = ''; Language = $lang; Detection = $langInfo } }
  }
}

Export-ModuleMember -Function Get-LLMRuntimeConfig, Set-LLMRuntimeGlobals, Invoke-LLMPreclassifyBatch, Invoke-VacancyPreclass, Read-LLMCache, Write-LLMCache, Resolve-LlmOperationConfig -Alias *

# EC/Lucky/Worst why functions
function Get-ECWhyText {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$Title = '',
    [string]$Employer = '',
    [double]$Score = 0.0,
    [string]$Summary = ''
  )
  $existing = Read-ECWhy -Id $Id
  if (-not [string]::IsNullOrWhiteSpace($existing)) {
    $norm = $existing
    try {
      $obj = $existing | ConvertFrom-Json
      if ($obj -and $obj.why) { $norm = [string]$obj.why }
    }
    catch {}
    if ($norm -ne $existing) { Write-ECWhy -Id $Id -Why $norm }
    return $norm
  }

  # Router: EC Why
  $cfg = Resolve-LlmOperationConfig -Operation 'picks.ec_why'
  if (-not $cfg.Ready) { return '' }
  $summaryTrim = if ($Summary) { $Summary.Trim() } else { '' }
  
  $promptInfo = $null
  if (Get-Command -Name Get-LlmPromptForOperation -ErrorAction SilentlyContinue) {
    $promptInfo = Get-LlmPromptForOperation -Operation 'picks.ec_why'
  }
  $sys = if ($promptInfo) { [string]$promptInfo.System } else {
    @"
You are "The Aperture" — a brutally honest, darkly sarcastic executive headhunter.
In 1–2 crisp sentences (around 30–50 words total), explain why THIS role is the best strategic fit for the candidate.
Be incisive, specific, and a bit ruthless. No fluff. Do not repeat the job title or company name.
"@
  }

  $info = "Role title: $Title"
  if (-not [string]::IsNullOrWhiteSpace($Employer)) { $info += "`nEmployer: $Employer" }
  $info += "`nScore: " + ("{0:0.00}" -f [double]$Score)
  if (-not [string]::IsNullOrWhiteSpace($summaryTrim)) { $info += "`nRole summary: $summaryTrim" }
  $usrPrefix = ''
  if ($promptInfo -and $promptInfo.User) { $usrPrefix = [string]$promptInfo.User }
  $usrBody = $info + "`nExplain succinctly why this role is the bar-none best match."
  if (-not [string]::IsNullOrWhiteSpace($usrPrefix)) {
    $usrBody = $usrPrefix + "`n`n" + $usrBody
  }
  $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.4 }
  try {
    $messages = @( @{role = 'system'; content = $sys }, @{role = 'user'; content = $usrBody } )
    $obj = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature $temperature -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'picks.ec_why'
    
    if ($obj) {
      $whyText = ''
      if ($obj.why) { $whyText = [string]$obj.why }
      elseif ($obj.reason) { $whyText = [string]$obj.reason }
      
      if (-not [string]::IsNullOrWhiteSpace($whyText)) {
        Write-ECWhy -Id $Id -Why $whyText
        return $whyText
      }
    }
  }
  catch {}
  return ''
}

function Get-LuckyWhyText {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$Title = '',
    [string]$Employer = '',
    [double]$Score = 0.0,
    [string]$Summary = ''
  )
  $existing = Read-LuckyWhy -Id $Id
  if (-not [string]::IsNullOrWhiteSpace($existing)) {
    $norm = $existing
    try {
      $obj = $existing | ConvertFrom-Json
      if ($obj -and $obj.why) { $norm = [string]$obj.why }
    }
    catch {}
    if ($norm -ne $existing) { Write-LuckyWhy -Id $Id -Why $norm }
    return $norm
  }

  # Router: Lucky Why
  $cfg = Resolve-LlmOperationConfig -Operation 'picks.lucky_why'
  if (-not $cfg.Ready) { return '' }
  
  $promptInfo = $null
  if (Get-Command -Name Get-LlmPromptForOperation -ErrorAction SilentlyContinue) {
    $promptInfo = Get-LlmPromptForOperation -Operation 'picks.lucky_why'
  }
  $sys = ''
  if ($promptInfo) { 
    $sys = [string]$promptInfo.System 
  } 
  else {
    $sys = @"
You are "The Aperture" — a brutally honest, darkly sarcastic executive headhunter.
In ~1–2 sentences, sell this as a high-upside wildcard ("I feel lucky"): identify the asymmetric upside and why it's worth a punt. No fluff. Don't repeat title/company.
"@
  }
  $usrPrefix = ''
  if ($promptInfo -and $promptInfo.User) { $usrPrefix = [string]$promptInfo.User }
  $usrBody = "Role title: $Title`nEmployer: $Employer`nScore: " + ("{0:0.00}" -f [double]$Score)
  if ($Summary) { $usrBody += "`nRole summary: " + $Summary.Trim() }
  if (-not [string]::IsNullOrWhiteSpace($usrPrefix)) { $usrBody = $usrPrefix + "`n`n" + $usrBody }

  try {
    $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.5 }
    $messages = @( @{role = 'system'; content = $sys }, @{role = 'user'; content = $usrBody } )
    $obj = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature $temperature -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'picks.lucky_why'
    
    if ($obj) {
      $whyText = ''
      if ($obj.why) { $whyText = [string]$obj.why }
      elseif ($obj.reason) { $whyText = [string]$obj.reason }
      
      if (-not [string]::IsNullOrWhiteSpace($whyText)) {
        Write-LuckyWhy -Id $Id -Why $whyText
        return $whyText
      }
    }
  }
  catch {}
  return ''
}

function Get-WorstWhyText {
  param(
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$Title = '',
    [string]$Employer = '',
    [double]$Score = 0.0,
    [string]$Summary = ''
  )
  $existing = Read-WorstWhy -Id $Id
  if (-not [string]::IsNullOrWhiteSpace($existing)) {
    $norm = $existing
    try {
      $obj = $existing | ConvertFrom-Json
      if ($obj -and $obj.why) { $norm = [string]$obj.why }
    }
    catch {}
    if ($norm -ne $existing) { Write-WorstWhy -Id $Id -Why $norm }
    return $norm
  }

  # Router: Worst Why
  $cfg = Resolve-LlmOperationConfig -Operation 'picks.worst_why'
  if (-not $cfg.Ready) { return '' }
  
  $promptInfo = $null
  if (Get-Command -Name Get-LlmPromptForOperation -ErrorAction SilentlyContinue) {
    $promptInfo = Get-LlmPromptForOperation -Operation 'picks.worst_why'
  }
  $sys = ''
  if ($promptInfo) { 
    $sys = [string]$promptInfo.System 
  } 
  else {
    $sys = @"
You are "The Aperture".
In ~1–2 sentences, explain with dark sarcasm why this vacancy is strategically the worst fit (deal-breakers, cul-de-sac risks, red flags). No title/company repetition.
"@
  }
  $usrPrefix = ''
  if ($promptInfo -and $promptInfo.User) { $usrPrefix = [string]$promptInfo.User }
  $usrBody = "Role title: $Title`nEmployer: $Employer`nScore: " + ("{0:0.00}" -f [double]$Score)
  if ($Summary) { $usrBody += "`nRole summary: " + $Summary.Trim() }
  if (-not [string]::IsNullOrWhiteSpace($usrPrefix)) { $usrBody = $usrPrefix + "`n`n" + $usrBody }

  try {
    $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.4 }
    $messages = @( @{role = 'system'; content = $sys }, @{role = 'user'; content = $usrBody } )
    $obj = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature $temperature -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'picks.worst_why'
    
    if ($obj) {
      $whyText = ''
      if ($obj.why) { $whyText = [string]$obj.why }
      elseif ($obj.reason) { $whyText = [string]$obj.reason }
      
      if (-not [string]::IsNullOrWhiteSpace($whyText)) {
        Write-WorstWhy -Id $Id -Why $whyText
        return $whyText
      }
    }
  }
  catch {}
  return ''
}

function Invoke-PremiumRanking {
  param(
    [Parameter(Mandatory = $true)][psobject]$Vacancy,
    [Parameter(Mandatory = $true)][hashtable]$CvPayload
  )

  # Router: Premium Ranking
  $cfg = Resolve-LlmOperationConfig -Operation 'ranking.premium'
  if (-not $cfg.Ready) { 
    # Fallback to warning if not configured, but do not throw
    try { Write-LogLLM "[Invoke-PremiumRanking] Operation 'ranking.premium' not configured or ready." -Level Warning } catch {}
    return $null 
  }
  # Default System Prompt
  $sysDefault = @"
You are an expert executive recruiter.
Rank the fit of the Candidate for the Vacancy on a scale of 0-100.
Return a JSON object: {"score": <0-100>, "summary": "<short justification>"}
Criteria:
- 90-100: Perfect strategic match, must interview.
- 70-89: Strong match, minor gaps.
- 50-69: Potential fit, significant gaps or risks.
- <50: Not a fit.
"@
  
  # Configurable System Prompt
  $sys = $sysDefault
  try {
    $cfgSys = Get-HHConfigValue -Path @('llm', 'prompts', 'ranking_premium', 'system') -Default ''
    if (-not [string]::IsNullOrWhiteSpace($cfgSys)) { $sys = $cfgSys }
  }
  catch {}

  # Construct User Payload
  $desc = ''
  try { $desc = [string]($Vacancy.plain_desc ?? $Vacancy.description ?? '') } catch {}
  if ($desc.Length -gt 2000) { $desc = $desc.Substring(0, 2000) + "..." }

  $usrPayload = @{
    vacancy   = @{
      id          = [string]($Vacancy.id ?? '')
      title       = [string]($Vacancy.title ?? $Vacancy.name ?? '')
      employer    = [string]($Vacancy.employer_name ?? $Vacancy.employer?.name ?? '')
      salary      = [string]($Vacancy.salary_text ?? $Vacancy.salary ?? '')
      location    = [string]($Vacancy.area ?? '')
      url         = [string]($Vacancy.alternate_url ?? '')
      summary     = [string]($Vacancy.summary ?? '')
      description = $desc
    }
    candidate = $CvPayload
  }
  
  $usr = $usrPayload | ConvertTo-Json -Depth 5
  
  # Call LLM
  try {
    $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.0 }
    $obj = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages @(@{role = 'system'; content = $sys }, @{role = 'user'; content = $usr }) -Temperature $temperature -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'ranking.premium'
    
    if ($obj -and $obj.score -ne $null) {
      return [PSCustomObject]@{
        score   = [int]$obj.score
        summary = [string]$obj.summary
      }
    }
  }
  catch {
    try { Write-LogLLM "[Invoke-PremiumRanking] Failed: $_" -Level Warning } catch {}
  }
  
  return $null
}


function Get-LlmProviderBalance {
  param(
    [Parameter(Mandatory = $true)][string]$ProviderName
  )
  
  # Resolve Provider Config directly
  $provConfig = $null
  try { $provConfig = Get-HHConfigValue -Path @('llm', 'providers', $ProviderName) } catch {}
  
  if (-not $provConfig) { return $null }
  
  $baseUrl = ''
  $apiKey = ''
  
  if ($provConfig -is [System.Collections.IDictionary]) {
    $baseUrl = [string]$provConfig['base_url']
    $authPath = $provConfig['auth_key_path']
  }
  elseif ($provConfig.PSObject.Properties['base_url']) {
    $baseUrl = [string]$provConfig.base_url
    $authPath = $provConfig.auth_key_path
  }
  
  # Resolve Key
  if ($authPath) {
    if ($authPath -is [string]) {
      try { $apiKey = [string](Get-HHConfigValue -Path $authPath) } catch {}
    }
    elseif ($authPath -is [Array]) {
      try { $apiKey = [string](Get-HHConfigValue -Path $authPath) } catch {}
    }
  }
  
  if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) { return $null }
  
  # Clean Base URL (remove /chat/completions if present to get root API)
  $apiRoot = $baseUrl -replace '/chat/completions/?$', ''
  $apiRoot = $apiRoot -replace '/v1/?$', '' # Strip v1 for now to re-append correctly if needed
  
  $balance = $null
  $currency = '$'
  
  # Provider-specific logic
  if ($ProviderName -eq 'deepseek' -or $baseUrl -like '*deepseek*') {
    try {
      $uri = "$apiRoot/user/balance"
      $resp = $null
      # Use unified wrapper if available
      if (Get-Command -Name 'hh.http\Invoke-HttpRequest' -ErrorAction SilentlyContinue) {
        $resp = & hh.http\Invoke-HttpRequest -Uri $uri -Method 'GET' -Headers @{ Authorization = "Bearer $ApiKey"; Accept = 'application/json' } -TimeoutSec 10 -OperationName "Balance-$ProviderName" -ApplyRateLimit:$false
      }
      else {
        $r = Invoke-WebRequest -Uri $uri -Method 'GET' -Headers @{ Authorization = "Bearer $ApiKey"; Accept = 'application/json' } -TimeoutSec 10
        $resp = $r.Content
      }
      
      if ($resp) {
        $json = $null
        if ($resp -is [string]) {
            try { $json = $resp | ConvertFrom-Json } catch {}
        }
        else {
            $json = $resp
        }
        
        if ($json.balance_infos) {
          $total = 0.0
          foreach ($inf in $json.balance_infos) {
            $b = 0.0
            if ($inf.total_balance) { $b = [double]$inf.total_balance }
            elseif ($inf.balance) { $b = [double]$inf.balance }
            $total += $b
            if ($inf.currency) { $currency = $inf.currency }
          }
          $balance = $total
        }
      }
    }
    catch {
      if (Get-Command -Name Write-LogLLM -ErrorAction SilentlyContinue) { Write-LogLLM "Balance fetch failed for $ProviderName ($uri): $_" -Level Warning }
    }
  }
  elseif ($ProviderName -eq 'hydra' -or $baseUrl -like '*hydra*') {
    # HydraAI specific check
    try {
      # Correct endpoint: /v1/users/profile
      $uri = "$apiRoot/v1/users/profile" 
      $resp = $null
      
      if (Get-Command -Name 'hh.http\Invoke-HttpRequest' -ErrorAction SilentlyContinue) {
        $resp = & hh.http\Invoke-HttpRequest -Uri $uri -Method 'GET' -Headers @{ Authorization = "Bearer $ApiKey"; Accept = 'application/json' } -TimeoutSec 10 -OperationName "Balance-$ProviderName" -ApplyRateLimit:$false
      }
      else {
        $r = Invoke-WebRequest -Uri $uri -Method 'GET' -Headers @{ Authorization = "Bearer $ApiKey"; Accept = 'application/json' } -TimeoutSec 10
        $resp = $r.Content
      }

      if ($resp) {
        $json = $null
        if ($resp -is [string]) {
            try { $json = $resp | ConvertFrom-Json } catch {}
        }
        else {
            $json = $resp
        }

        # Hydra response has 'balance' field
        if ($json.balance -ne $null) { $balance = [double]$json.balance }
        
        # Hydra usually uses RUB, but let's check or assume
        $currency = '₽' 
      }
    }
    catch {
      if (Get-Command -Name Write-LogLLM -ErrorAction SilentlyContinue) { Write-LogLLM "Balance fetch failed for $ProviderName ($uri): $_" -Level Warning }
    }
  }
  
  if ($balance -ne $null) {
    return "${ProviderName}: ${currency}" + ("{0:0.0000}" -f $balance)
  }
  
  return $null
}

Export-ModuleMember -Function LLM-InvokeJson, LLM-InvokeText, LLM-EditorsChoicePick, LLM-PickLucky, LLM-PickWorst, LLM-GenerateText, LLM-GenerateCoverLetter, LLM-MeasureCultureRisk, Invoke-PremiumRanking, Get-ECWhyText, Get-LuckyWhyText, Get-WorstWhyText, Get-ECWhyPath, Get-LuckyWhyPath, Get-WorstWhyPath, Get-CoverLetterPath, Read-ECWhy, Read-LuckyWhy, Read-WorstWhy, Read-CoverLetter, Write-ECWhy, Write-LuckyWhy, Write-WorstWhy, Write-CoverLetter, Get-LlmPromptForOperation, Add-LlmUsage, Get-LlmUsageCounters, Set-LlmUsagePipelineState, Get-LlmProviderBalance
