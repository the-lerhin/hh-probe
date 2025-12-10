# Module for LLM vacancy summarization and caching
# Requires hh.util.psm1 for cache utilities and hh.llm.psm1 for LLM-GenerateText

Import-Module (Join-Path $PSScriptRoot 'hh.models.psm1') -Force

# Ensure model types are available
Ensure-HHModelTypes

if (-not (Get-Module -Name 'hh.util')) {
  $modUtil = Join-Path $PSScriptRoot 'hh.util.psm1'
  if (Test-Path -LiteralPath $modUtil) { Import-Module $modUtil -DisableNameChecking -ErrorAction Stop }
}

if (-not (Get-Module -Name 'hh.llm')) {
  $modLLM = Join-Path $PSScriptRoot 'hh.llm.psm1'
  if (Test-Path -LiteralPath $modLLM) { Import-Module $modLLM -DisableNameChecking -ErrorAction Stop }
}

# LEGACY: routing shim to support both module-qualified and plain LLM helpers; unify call sites
function Invoke-LlmHelper {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [hashtable]$Arguments
  )
  $invokeArgs = if ($Arguments) { $Arguments } else { @{} }
  $qualified = Get-Command -Name ("hh.llm\{0}" -f $Name) -ErrorAction SilentlyContinue
  if ($qualified) { return & $qualified @invokeArgs }
  $plain = Get-Command -Name $Name -ErrorAction SilentlyContinue
  if ($plain) { return & $plain @invokeArgs }
  throw "LLM helper '$Name' unavailable"
}

function Clean-SummaryText {
  param(
    [Parameter(Mandatory = $false)][string]$Text,
    [int]$MaxLength = 300
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

  # 1. Normalize whitespace (newlines -> spaces, collapse multiple spaces)
  $clean = $Text -replace '[\r\n]+', ' ' -replace '\s+', ' '
  $clean = $clean.Trim()

  # 2. Strip Markdown bullets/headings at start
  # Matches: - * • # > (and combinations like ##, ###) followed by space
  $clean = $clean -replace '^[\-\*\•\#\>]+ ', ''

  # 3. Strip surrounding quotes or backticks
  # e.g. "text", 'text', `text`, **text**
  if ($clean.Length -gt 1) {
    if ($clean.StartsWith('"') -and $clean.EndsWith('"')) { $clean = $clean.Substring(1, $clean.Length - 2) }
    elseif ($clean.StartsWith("'") -and $clean.EndsWith("'")) { $clean = $clean.Substring(1, $clean.Length - 2) }
    elseif ($clean.StartsWith('`') -and $clean.EndsWith('`')) { $clean = $clean.Substring(1, $clean.Length - 2) }
    elseif ($clean.StartsWith('**') -and $clean.EndsWith('**')) { $clean = $clean.Substring(2, $clean.Length - 4) }
  }
  
  $clean = $clean.Trim()

  # 4. Enforce MaxLength
  if ($clean.Length -gt $MaxLength) {
    # Cut at last space before limit
    $sub = $clean.Substring(0, $MaxLength)
    $lastSpace = $sub.LastIndexOf(' ')
    if ($lastSpace -gt ($MaxLength * 0.8)) {
      $clean = $sub.Substring(0, $lastSpace) + '…'
    }
    else {
      $clean = $sub + '…'
    }
  }

  return $clean
}

$script:CacheStats = @{ sum_built = 0; llm_cached = 0; sum_cached = 0 }
$script:RemoteSummaryConfig = $null

function Add-SummaryCacheStats {
  param([string]$Field)
  foreach ($scope in @('Global', 'Script')) {
    try {
      $var = Get-Variable -Name 'CacheStats' -Scope $scope -ErrorAction SilentlyContinue
      if ($var -and $var.Value -and ($var.Value -is [System.Collections.IDictionary])) {
        $var.Value[$Field] = [int]($var.Value[$Field] ?? 0) + 1
      }
    }
    catch {}
  }
  try {
    $script:CacheStats[$Field] = [int]($script:CacheStats[$Field] ?? 0) + 1
  }
  catch {}
}

function Get-RemoteSummaryContext {
  if ($script:RemoteSummaryConfig) { return $script:RemoteSummaryConfig }

  # Resolve configuration for the 'summary.remote' operation
  return Resolve-LlmOperationConfig -Operation 'summary.remote'
}

function Get-HHRemoteVacancySummary {
  param(
    [Parameter(Mandatory = $true)][object]$Vacancy,
    [Parameter(Mandatory = $false)][hashtable]$CvPayload
  )
    
  # 1. Resolve Config (Tier 3 remote)
  $cfg = Get-RemoteSummaryContext
  if (-not $cfg.Ready) { return $null }
    
  # 2. Add Candidate Info to Prompt Context if available
  $cvText = ''
  if ($CvPayload -and $CvPayload.ContainsKey('cv_summary')) {
    $cvText = [string]$CvPayload['cv_summary']
  }

  # 3. Detect Language (FR-5.8)
  $lang = 'ru'
  if (Get-Command -Name Resolve-SummaryLanguage -ErrorAction SilentlyContinue) {
    $lang = Resolve-SummaryLanguage -Item $Vacancy
  }

  # 4. Invoke Summary with Cache
  # We pass 'summary.remote' as operation to ensure correct caching key namespace if needed,
  # or rely on Invoke-CanonicalSummaryWithCache to handle it.
  # Note: Invoke-CanonicalSummaryWithCache uses 'summary.remote' config internally if passed.
    
  $result = Invoke-CanonicalSummaryWithCache -Operation 'summary.remote' -Vacancy $Vacancy -CvText $cvText -ForceLanguage $lang
    
  if ($result -and $result.summary) {
    return [pscustomobject]@{
      Summary  = $result.summary
      Language = $result.language
      Model    = $result.model
      Source   = 'remote'
    }
  }
    
  return $null
}
  


function Resolve-SummaryLanguage {
  param(
    [string]$Text,
    [string]$Preferred = 'auto',
    [string]$VacancyTitle,
    [string]$VacancyDescription
  )
  $utilCmd = Get-Command -Name 'hh.util\Resolve-SummaryLanguage' -ErrorAction SilentlyContinue
  if ($utilCmd) {
    return & $utilCmd -VacancyTitle $VacancyTitle -VacancyDescription $VacancyDescription -Text $Text -Preferred $Preferred
  }

  # Fallback to legacy heuristic if util import failed
  if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
    try {
      $norm = $Preferred.ToLowerInvariant()
      if ($norm -in @('ru', 'en')) { return [pscustomobject]@{ Language = $norm; CyrillicRatio = 0; LatinRatio = 0; CyrillicCount = 0; LatinCount = 0 } }
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{ Language = 'ru'; CyrillicRatio = 0; LatinRatio = 0; CyrillicCount = 0; LatinCount = 0 } }
  try {
    $latin = ([regex]::Matches($Text, '[A-Za-z]')).Count
    $cyr = ([regex]::Matches($Text, '[\p{IsCyrillic}]')).Count
    $langFallback = if ($latin -gt ($cyr * 1.2)) { 'en' } else { 'ru' }
    return [pscustomobject]@{ Language = $langFallback; CyrillicRatio = 0; LatinRatio = 0; CyrillicCount = $cyr; LatinCount = $latin }
  }
  catch {}
  return [pscustomobject]@{ Language = 'ru'; CyrillicRatio = 0; LatinRatio = 0; CyrillicCount = 0; LatinCount = 0 }
}

function Get-SummaryPromptSet {
  param(
    [string]$Lang = 'ru',
    [string]$Operation = 'summary.remote'
  )
  $langKey = if (($Lang ?? '').ToLowerInvariant() -eq 'en') { 'en' } else { 'ru' }
  $target = ''
  if ($Operation -match '\.') {
    $parts = $Operation.Split('.')
    if ($parts.Count -gt 1) { $target = $parts[1] }
  }
  $defaultSys = if ($langKey -eq 'en') {
    'You are a concise job summarizer. Reply in English with 1–2 crisp sentences highlighting responsibilities, scope, and tech; skip benefits. Never repeat job title or company.'
  }
  else {
    'Ты — краткий аналитик вакансий. Дай 1–2 предложения про обязанности, масштаб и стек, без соцпакета и без повторения названия должности/компании.'
  }
  $sys = Invoke-LlmPromptValue -Paths @(
    @('llm', 'prompts', 'summary', $target, ("system_{0}" -f $langKey)),
    @('llm', 'prompts', 'summary', ("system_{0}" -f $langKey))
  ) -DefaultPrompt $defaultSys

  $defaultUser = if ($langKey -eq 'en') {
    "Summarize the vacancy (max 2 sentences, <40 words). Focus on responsibilities, scope, and domain. Text:`n{{text}}"
  }
  else {
    "Сформулируй краткое описание вакансии (до 2 предложений, <40 слов). Покажи обязанности, масштаб и домен. Текст:`n{{text}}"
  }
  $usr = Invoke-LlmPromptValue -Paths @(
    @('llm', 'prompts', 'summary', $target, ("user_{0}" -f $langKey)),
    @('llm', 'prompts', 'summary', ("user_{0}" -f $langKey))
  ) -DefaultPrompt $defaultUser
  return [pscustomobject]@{ system = $sys; user = $usr }
}

function Expand-SummaryUserPrompt {
  param(
    [string]$Template,
    [string]$Body,
    [string]$Avoid = ''
  )
  if ([string]::IsNullOrWhiteSpace($Template)) { return $Body }
  $result = $Template
  if ($result.Contains('{{text}}')) { $result = $result.Replace('{{text}}', $Body) } else { $result = $result + "`n`n" + $Body }
  if ($result.Contains('{{avoid}}')) { $result = $result.Replace('{{avoid}}', $Avoid) }
  return $result
}

function Invoke-LlmPromptValue {
  param(
    [string[][]]$Paths,
    [string]$DefaultPrompt = ''
  )
  foreach ($p in @($Paths)) {
    if (-not $p) { continue }
    try {
      $val = [string](Get-HHConfigValue -Path $p -Default '')
      if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    }
    catch {}
  }
  return $DefaultPrompt
}

function Invoke-CanonicalSummaryOperation {
  param(
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][string]$BodyText,
    [string]$VacancyTitle = '',
    [string]$PreferredLanguage = 'auto',
    [int]$MaxTokens = 256
  )

  $cfg = Resolve-LlmOperationConfig -Operation $Operation
  if (-not $cfg.Ready) { return $null }

  $text = $BodyText
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  if ($text.Length -gt 2200) { $text = $text.Substring(0, 2200) }

  $langPref = if ([string]::IsNullOrWhiteSpace($PreferredLanguage)) { 'auto' } else { $PreferredLanguage }
  $langInfo = Resolve-SummaryLanguage -VacancyTitle $VacancyTitle -VacancyDescription $text -Preferred $langPref
  $lang = if ($langInfo -and $langInfo.Language) { $langInfo.Language } else { 'ru' }

  $promptSet = Get-SummaryPromptSet -Lang $lang -Operation $Operation
  $userPrompt = Expand-SummaryUserPrompt -Template $promptSet.user -Body $text -Avoid $VacancyTitle

  $messages = @(
    @{ role = 'system'; content = $promptSet.system },
    @{ role = 'user'; content = $userPrompt }
  )

  $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { if ($Operation -eq 'summary.local') { 0.1 } else { 0.2 } }
  $maxTokensFinal = $MaxTokens
  if ($cfg.MaxTokens -ne $null -and [int]$cfg.MaxTokens -gt 0) { $maxTokensFinal = [int]$cfg.MaxTokens }
  $topPFinal = if ($cfg.TopP -ne $null -and [double]$cfg.TopP -gt 0) { [double]$cfg.TopP } else { 0 }

  $summaryText = LLM-InvokeText -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature $temperature -TimeoutSec $cfg.TimeoutSec -MaxTokens $maxTokensFinal -TopP $topPFinal -ExtraParameters $cfg.Parameters -OperationName $Operation
  if ([string]::IsNullOrWhiteSpace($summaryText)) { return $null }

  try {
    Write-LogLLM ("[Summary] op={0} lang={1} len={2} cyr_ratio={3} lat_ratio={4}" -f $Operation, $lang, $summaryText.Length, $langInfo?.CyrillicRatio, $langInfo?.LatinRatio) -Level Verbose
  }
  catch {}

  return [pscustomobject]@{
    summary   = $summaryText.Trim()
    language  = $lang
    detection = $langInfo
    model     = $cfg.Model
    source    = if ($Operation -eq 'summary.local') { 'local' } else { 'remote' }
  }
}

function Invoke-CanonicalSummaryWithCache {
  param(
    [Parameter(Mandatory = $true)][string]$Operation,
    [CanonicalVacancy]$Vacancy,
    [string]$BodyText = '',
    [string]$CvText = '',
    [string]$ForceLanguage = '',
    [int]$MaxTokens = 256
  )

  $text = $BodyText
  if ([string]::IsNullOrWhiteSpace($text) -and $Vacancy) {
    $desc = ''
    try { $desc = [string]($Vacancy.Description ?? $Vacancy.description ?? '') } catch {}
    if (-not $desc) {
      try { $desc = [string]($Vacancy.Meta?.summary?.text ?? '') } catch {}
    }
    if (-not $desc) {
      $desc = ("{0} {1}" -f ($Vacancy.Title ?? ''), ($Vacancy.EmployerName ?? ''))
    }
    $text = $desc
  }
  
  # Append CV Text if provided
  if (-not [string]::IsNullOrWhiteSpace($CvText)) {
    $text += "`n`nCANDIDATE CONTEXT:`n$CvText"
  }

  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  if ($Operation -eq 'summary.remote' -and $Vacancy -and $Vacancy.Id) {
    $cached = Read-SummaryCache -VacId $Vacancy.Id -PubUtc $Vacancy.PublishedAtUtc
    if ($cached) {
      $cleanCached = Clean-SummaryText -Text ([string]$cached)
      $cfgCache = Resolve-LlmOperationConfig -Operation $Operation
      return [pscustomobject]@{
        summary   = $cleanCached
        language  = ''
        detection = $null
        model     = $cfgCache.Model
        source    = 'remote'
      }
    }
  }

  $preferredLang = ''
  if (-not [string]::IsNullOrWhiteSpace($ForceLanguage)) {
    $preferredLang = $ForceLanguage
  }
  else {
    try { $preferredLang = [string](Get-HHConfigValue -Path @('llm', 'summary_language') -Default 'auto') } catch { $preferredLang = 'auto' }
  }

  $result = Invoke-CanonicalSummaryOperation -Operation $Operation -BodyText $text -VacancyTitle ($Vacancy?.Title ?? '') -PreferredLanguage $preferredLang -MaxTokens $MaxTokens
  if ($result -and $result.summary -and $Operation -eq 'summary.remote' -and $Vacancy -and $Vacancy.Id) {
    Write-SummaryCache -VacId $Vacancy.Id -PubUtc $Vacancy.PublishedAtUtc -Summary $result.summary
  }
  return $result
}

# Ensure CacheRoot is set to a sane default
if (-not $CacheRoot) {
  try {
    $v = $ExecutionContext.SessionState.PSVariable.Get('CacheRoot')
    if ($v -and $v.Value) { $CacheRoot = [string]$v.Value } else {
      $base = Get-LlmCacheRoot
      $CacheRoot = Join-Path $base 'llm'
    }
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
  }
  catch {
    $repo = Split-Path -Parent $PSScriptRoot
    $CacheRoot = Join-Path (Join-Path $repo 'data') 'cache/llm'
    try { New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null } catch {}
  }
}

function Get-SummaryCachePath([string]$VacId, [Nullable[DateTime]]$PubUtc) {
  if ([string]::IsNullOrWhiteSpace($VacId) -or -not ($PubUtc -is [DateTime])) { return $null }
  try { if (-not (Test-Path -LiteralPath $CacheRoot)) { New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null } } catch {}
  $tag = "{0:yyyyMMddHHmm}" -f $PubUtc.ToUniversalTime()
  return Join-Path $CacheRoot ("sum_" + $VacId + "_" + $tag + ".txt")
}

function Read-SummaryCache([string]$VacId, [Nullable[DateTime]]$PubUtc) {
  $p = Get-SummaryCachePath -VacId $VacId -PubUtc $PubUtc
  if ($p -and (Test-Path -LiteralPath $p)) {
    # TTL check for summary cache
    $ttlDays = 0
    try { $ttlDays = [int](Get-HHConfigValue -Path @('llm', 'summary', 'ttl_days') -Default 14) } catch { $ttlDays = 14 }
    if ($ttlDays -gt 0) {
      try {
        $fi = Get-Item -LiteralPath $p
        $now = (Get-Date).ToUniversalTime()
        if ($fi.LastWriteTime.ToUniversalTime().AddDays($ttlDays) -le $now) { return $null }
      }
      catch {}
    }
    try {
      Add-SummaryCacheStats -Field 'sum_cached'
      Add-SummaryCacheStats -Field 'llm_cached'
    }
    catch {}
    try { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } catch { return $null }
  }
  # fallback: latest summary for this vacancy id
  try {
    $pattern = "sum_${VacId}_*.txt"
    if (-not (Test-Path -LiteralPath $CacheRoot)) { return $null }
    $cand = Get-ChildItem -LiteralPath $CacheRoot -Filter $pattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($cand) {
      try {
        Add-SummaryCacheStats -Field 'sum_cached'
        Add-SummaryCacheStats -Field 'llm_cached'
      }
      catch {}
      try { return [System.IO.File]::ReadAllText($cand.FullName, [System.Text.Encoding]::UTF8) } catch { return $null }
    }
  }
  catch {}
  return $null
}

function Write-SummaryCache([string]$VacId, [Nullable[DateTime]]$PubUtc, [string]$Summary) {
  if ([string]::IsNullOrWhiteSpace($Summary)) { return }
  $p = Get-SummaryCachePath -VacId $VacId -PubUtc $PubUtc
  if ($p) {
    try { $Summary | Out-File -FilePath $p -Encoding utf8 } catch {}
  }
}

# Remote/local summary helpers (mockable in tests)
function Get-RemoteSummaryForVacancy {
  param(
    [Parameter(Mandatory = $true)][string]$VacancyText,
    [int]$MaxTokens = 256,
    [CanonicalVacancy]$Vacancy = $null,
    [switch]$AsObject
  )
  if ($env:HH_TEST -eq '1') {
    $mock = [pscustomobject]@{ summary = 'remote summary'; language = 'ru'; model = 'test-model'; source = 'test' }
    return (if ($AsObject) { $mock } else { [string]$mock.summary })
  }
  if ([string]::IsNullOrWhiteSpace($VacancyText) -and -not $Vacancy) { return (if ($AsObject) { $null } else { '' }) }
  $result = Invoke-CanonicalSummaryWithCache -Operation 'summary.remote' -Vacancy $Vacancy -BodyText $VacancyText -MaxTokens $MaxTokens
  if (-not $result) { return (if ($AsObject) { $null } else { '' }) }
  if ($AsObject) { return $result }
  return [string]$result.summary
}

function Get-LocalSummaryForVacancy {
  param(
    [Parameter(Mandatory = $true)][string]$VacancyText,
    [int]$MaxTokens = 128,
    [string]$StyleHint = '',
    [CanonicalVacancy]$Vacancy = $null,
    [switch]$AsObject
  )
  if ($env:HH_TEST -eq '1') {
    $mock = [pscustomobject]@{ summary = 'local summary'; language = 'ru'; model = 'local-test'; source = 'local' }
    if ($AsObject) { return $mock } else { return [string]$mock.summary }
  }
  if ([string]::IsNullOrWhiteSpace($VacancyText) -and -not $Vacancy) {
    if ($AsObject) { return $null } else { return '' }
  }
  $result = Invoke-CanonicalSummaryOperation -Operation 'summary.local' -BodyText ($VacancyText ?? '') -VacancyTitle ($Vacancy?.Title ?? '') -MaxTokens $MaxTokens
  if (-not $result) {
    if ($AsObject) { return $null } else { return '' }
  }
  if ($AsObject) { return $result }
  return [string]$result.summary
}

function Get-HHLocalVacancySummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject] $Vacancy,
    [Parameter(Mandatory)][psobject] $CvSnapshot
  )
    
  $body = ''
  try { $body = [string]($Vacancy.Description ?? $Vacancy.description ?? '') } catch {}
  if (-not $body) {
    try { $body = [string]($Vacancy.Meta?.summary?.text ?? '') } catch {}
  }
  if (-not $body -and $Vacancy.Title) {
    $body = "$($Vacancy.Title) $($Vacancy.EmployerName)"
  }
  $result = Get-LocalSummaryForVacancy -VacancyText $body -Vacancy $Vacancy -AsObject
  if ($result -and $result.summary) {
    $result.summary = Clean-SummaryText -Text $result.summary
    return $result
  }

  $fallback = ''
  try { $fallback = Get-HHPlainSummary -Vacancy $Vacancy } catch {}
  if (-not [string]::IsNullOrWhiteSpace($fallback)) {
    $clean = Clean-SummaryText -Text $fallback
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
    return [pscustomobject]@{
      summary  = $clean
      language = Get-TextLanguage -Text $clean
      source   = 'local'
      model    = 'plain'
    }
  }
  return $null
}

function Get-HHRemoteFitScore {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject] $Vacancy,
    [Parameter()][psobject] $CvSnapshot,
    [hashtable]$CvPayload,
    [Parameter()][psobject] $LocalSummary
  )
    
  $cfg = Resolve-LlmOperationConfig -Operation 'ranking.remote'
  if (-not $cfg.Ready) {
    if ($env:HH_DEBUG) { Write-Host "[LLM][RemoteRanking] not ready" -ForegroundColor DarkGray }
    return $null 
  }

  $desc = ''
  try { $desc = [string]$Vacancy.Description } catch {}
  if (-not $desc) { try { $desc = [string]$Vacancy.description } catch {} }
  $descPlain = $desc -replace '<[^>]+>', ' ' -replace '\s+', ' '
  if ($descPlain.Length -gt 3000) { $descPlain = $descPlain.Substring(0, 3000) }

  $summaryText = ''
  if ($LocalSummary -and $LocalSummary.summary) { $summaryText = [string]$LocalSummary.summary }
  elseif ($Vacancy.Summary) { $summaryText = [string]$Vacancy.Summary }

  $vacPayload = @{
    id            = [string]($Vacancy.Id ?? $Vacancy.id ?? '')
    title         = [string]($Vacancy.Title ?? $Vacancy.name ?? '')
    employer      = [string]($Vacancy.EmployerName ?? $Vacancy.employer_name ?? $Vacancy.employer?.name ?? '')
    city          = [string]($Vacancy.City ?? '')
    country       = [string]($Vacancy.Country ?? '')
    salary_text   = [string]($Vacancy.Salary?.Text ?? $Vacancy.salary_text ?? '')
    search_tiers  = @($Vacancy.SearchTiers ?? @())
    key_skills    = @($Vacancy.KeySkills ?? @())
    url           = [string]($Vacancy.Url ?? '')
    description   = $descPlain
    summary_local = $summaryText
  }

  $candidatePayload = $null
  if ($CvPayload) {
    $candidatePayload = @{}
    foreach ($key in $CvPayload.Keys) { $candidatePayload[$key] = $CvPayload[$key] }
  }
  else {
    $skills = @()
    try {
      if ($CvSnapshot -and $CvSnapshot.KeySkills) { $skills = @($CvSnapshot.KeySkills | Where-Object { $_ }) }
    }
    catch {}
    $cvTitle = ''
    $cvSummaryText = ''
    if ($CvSnapshot) {
      try { $cvTitle = [string]($CvSnapshot.title ?? $CvSnapshot.Title ?? '') } catch {}
      try { $cvSummaryText = [string]($CvSnapshot.summary ?? '') } catch {}
    }
    $candidatePayload = @{
      cv_title                   = $cvTitle
      cv_skill_set               = @($skills)
      cv_summary                 = $cvSummaryText
      cv_total_experience_months = 0
    }
  }

  $payload = @{
    vacancy       = $vacPayload
    candidate     = $candidatePayload
    local_summary = @{
      text     = $summaryText
      language = if ($LocalSummary -and $LocalSummary.language) { [string]$LocalSummary.language } else { '' }
      tags     = if ($LocalSummary -and $LocalSummary.tags) { @($LocalSummary.tags) } else { @() }
    }
  }
    
  $sys = "You are an expert Recruiter AI. Evaluate job fit for the candidate. Return JSON with fit_score (0-10 float), confidence (0-1), reason (string)."
  $usr = "CANDIDATE AND VACANCY INPUT:`n" + ($payload | ConvertTo-Json -Depth 6)

  try {
    $messages = @(
      @{ role = 'system'; content = $sys }
      @{ role = 'user'; content = $usr }
    )
    $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.0 }
    $data = LLM-InvokeJson -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model -Messages $messages -Temperature $temperature -TimeoutSec $cfg.TimeoutSec -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'ranking.remote'
    if (-not $data) { return $null }
    $score = $null
    try { $score = [double]$data.fit_score } catch { $score = $null }
    return [pscustomobject]@{
      fit_score  = $score
      confidence = if ($data.confidence -ne $null) { [double]$data.confidence } else { $null }
      reason     = [string]($data.reason ?? '')
    }
  }
  catch {
    if ($env:HH_DEBUG) { Write-Host "[LLM][RemoteRanking] failed: $_" -ForegroundColor Red }
    return $null
  }
}

function Get-HHPremiumVacancySummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject] $Vacancy,
    [Parameter(Mandatory)][psobject] $CvSnapshot,
    [Parameter()][psobject] $LocalSummary
  )

  $cfg = Resolve-LlmOperationConfig -Operation 'summary.premium'
  if (-not $cfg.Ready) { return $null }

  $desc = [string]$Vacancy.Description
  if (-not $desc) { $desc = [string]$Vacancy.description }
  $descPlain = $desc -replace '<[^>]+>', ' ' -replace '\s+', ' '
  if ($descPlain.Length -gt 3000) { $descPlain = $descPlain.Substring(0, 3000) }

  $localContext = ""
  if ($LocalSummary) {
    $localContext = "Draft Summary: $($LocalSummary.summary)"
  }

  $sys = "You are an elite executive career coach. Write a high-signal, concise summary for a Senior candidate."
  $usr = @"
Job: $($Vacancy.Title) at $($Vacancy.EmployerName)
Description:
$descPlain

$localContext

Task:
Write a premium summary (max 3 sentences).
Focus on strategic scope, tech stack, and team topology.
No fluff. No "We are looking for". Start directly with the role's core value.
Output plain text only.
"@

  try {
    $messages = @(
      @{ role = 'system'; content = $sys }
      @{ role = 'user'; content = $usr }
    )
        
    $text = Invoke-LlmHelper -Name 'LLM-InvokeText' -Arguments @{
      Endpoint    = $cfg.Endpoint
      ApiKey      = $cfg.ApiKey
      Model       = $cfg.Model
      Messages    = $messages
      Temperature = $cfg.Temperature
      TimeoutSec  = $cfg.TimeoutSec
    }
    return $text
  }
  catch {
    return $null
  }
}

Export-ModuleMember -Function Get-HHPremiumVacancySummary

function LLM-BuildSummary {
  param($Vacancy)

  if (-not $Vacancy) { return $null }
  $vacId = ''
  try { $vacId = [string]$Vacancy.id } catch {}
  $pubUtc = Get-UtcDate $Vacancy.pub_utc
  if (-not $pubUtc) { $pubUtc = Get-UtcDate $Vacancy.pub_utc_str }
  try {
    if ($vacId -and $pubUtc -and $pubUtc -is [DateTime]) {
      $hit = Read-SummaryCache -VacId $vacId -PubUtc $pubUtc
      if ($hit) { return [string]$hit }
    }
  }
  catch {}

  if ([string]::IsNullOrWhiteSpace($LLMApiKey)) { return $null }
  $plain = ''
  try { $plain = [string]($Vacancy.plain_desc ?? '') } catch {}
  if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
  if ($plain.Length -gt 1800) { $plain = $plain.Substring(0, 1800) }

  $lang = 'ru'
  try {
    $cyr = ([regex]::Matches($plain, '[\p{IsCyrillic}]')).Count
    $lat = ([regex]::Matches($plain, '[A-Za-z]')).Count
    if ($lat -gt ($cyr * 1.5)) { $lang = 'en' }
  }
  catch {}

  $avoid = @()
  try { if ($Vacancy.name) { $avoid += [string]$Vacancy.name } } catch {}
  try { if ($Vacancy.employer -and $Vacancy.employer.name) { $avoid += [string]$Vacancy.employer.name } } catch {}
  foreach ($a in $avoid) {
    if ([string]::IsNullOrWhiteSpace($a)) { continue }
    $esc = [regex]::Escape($a)
    try { $plain = [regex]::Replace($plain, $esc, '', 'IgnoreCase') } catch {}
  }
  $avoidQuoted = $avoid | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { '"' + ($_ -replace '"', '') + '"' }

  $avoidList = if ($avoidQuoted -and $avoidQuoted.Count -gt 0) { ($avoidQuoted -join ', ') } else { '—' }
  $promptSet = Get-SummaryPromptSet -Lang $lang
  $sys = $promptSet.system
  $usr = Expand-SummaryUserPrompt -Template ([string]$promptSet.user) -Body $plain -Avoid $avoidList

  try {
    $text = Invoke-LlmHelper -Name 'LLM-GenerateText' -Arguments @{ Sys = $sys; Usr = $usr; Endpoint = $LLMEndpoint; ApiKey = $LLMApiKey; Model = $LLMModel; Temperature = 0.0 }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      if ($text.Length -gt 400) { $text = $text.Substring(0, 400) }
      if ($vacId -and $pubUtc -and $pubUtc -is [DateTime]) {
        try { Write-SummaryCache -VacId $vacId -PubUtc $pubUtc -Summary $text } catch {}
      }
      return $text
    }
  }
  catch {}
  return $null
}

function Get-VacancySummary {
  param([string]$VacId, [string]$Title, [string]$Desc)
  if (-not $LLMEnabled -or [string]::IsNullOrWhiteSpace($Desc)) { return "" }

  $lang = 'ru'
  try {
    $combined = ($Title + " " + $Desc)
    $latin = ([regex]::Matches($combined, '[A-Za-z]')).Count
    $cyr = ([regex]::Matches($combined, '[А-Яа-яЁё]')).Count
    if ($latin -gt $cyr) { $lang = 'en' }
  }
  catch {}

  if (-not [string]::IsNullOrWhiteSpace($SummaryLanguage)) {
    try { if ($SummaryLanguage.ToLowerInvariant() -in @('en', 'ru')) { $lang = $SummaryLanguage.ToLowerInvariant() } } catch {}
  }
  $promptSet2 = Get-SummaryPromptSet -Lang $lang
  $sys = $promptSet2.system
  $usr = Expand-SummaryUserPrompt -Template ([string]$promptSet2.user) -Body ("TITLE: $Title`nDESCRIPTION:`n$Desc")
  if ($Debug) { Log-Step ("[LLM] summary lang={0}" -f $lang) }

  try {
    $text = Invoke-LlmHelper -Name 'LLM-GenerateText' -Arguments @{ Sys = $sys; Usr = $usr; Endpoint = $LLMEndpoint; ApiKey = $LLMApiKey; Model = $LLMModel; Temperature = 0.25 }
    try {
      $t = if ($text) { $text.Trim() } else { "" }
      $tt = if ($Title) { $Title.Trim() } else { "" }

      if ($t -and $tt) {
        $pat = '^(?i)' + [regex]::Escape($tt) + '\s*[:\-–—|]\s*'
        if ([regex]::IsMatch($t, $pat)) { $t = [regex]::Replace($t, $pat, '') }
        if ($t.Trim().ToLowerInvariant().StartsWith($tt.ToLowerInvariant())) {
          $t = $t.Substring([Math]::Min($t.Length, $tt.Length)).TrimStart(' ', ':', '-', '–', '—', '|')
        }
      }
      if ([string]::IsNullOrWhiteSpace($t)) { $t = $text }
      $text = $t
    }
    catch {}
    if (-not [string]::IsNullOrWhiteSpace($text)) { $script:CacheStats.sum_built++ }
    return ($text.Trim())
  }
  catch { return "" }
}

function Invoke-LLMSummaries {
  param([Parameter(Mandatory = $true)][object[]]$Items)
  if (-not $Items -or $Items.Count -eq 0) { return @() }
  $results = @()
  foreach ($row in $Items) {
    $id = ''; try { $id = [string]$row.id } catch {}
    $title = ''; try { $title = [string]$row.title } catch {}
    $plain = ''; try { $plain = [string]$row.plain_desc } catch {}
    $pubUtc = $row.pub_utc
    $res = [PSCustomObject]@{ id = $id; pub_utc = $pubUtc; text = ''; ms = 0; error = '' }
    try {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $text = Get-VacancySummary -VacId $id -Title $title -Desc $plain
      $sw.Stop(); $res.ms = [int]$sw.Elapsed.TotalMilliseconds
      if ($text) { $res.text = [string]$text } else { $res.text = '' }
    }
    catch { $res.error = $_.Exception.Message }
    $results += $res
  }
  return $results
}

Export-ModuleMember -Function Get-RemoteSummaryForVacancy, Get-LocalSummaryForVacancy, Get-SummaryCachePath, Read-SummaryCache, Write-SummaryCache, Get-RemoteSummaryContext, Get-SummaryPromptSet, Expand-SummaryUserPrompt, Get-HHLocalVacancySummary, Get-HHQwenFitScore, Get-HHPremiumVacancySummary, Invoke-LLMSummaries, Get-HHRemoteFitScore, Invoke-CanonicalSummaryWithCache, Clean-SummaryText, Get-HHRemoteVacancySummary
