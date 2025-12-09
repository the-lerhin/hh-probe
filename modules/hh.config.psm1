# hh.config.psm1 — shared configuration helpers
#Requires -Version 7.5

$script:ConfigCache = $null
$script:ConfigPath = $null

function Set-HHConfigPath {
  param([string]$Path)
  Reset-HHConfigCache
  if ([string]::IsNullOrWhiteSpace($Path)) {
    $script:ConfigPath = $null
    return
  }
  try {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $script:ConfigPath = $resolved
  }
  catch {
    throw "Configuration file '$Path' not found."
  }
}

<#
  Get-HHConfigPath
  Brief: Determines the active configuration file path.
  - Respects explicit overrides via Set-HHConfigPath() and env `HH_CONFIG_FILE`.
  - Prefers `config/hh.config.jsonc` when present.
  - Falls back to `config/hh.config.minimal.jsonc` ONLY in tests (`$env:HH_TEST=1`).
#>
function Get-HHConfigPath {
  if ($script:ConfigPath) {
    if (Test-Path -LiteralPath $script:ConfigPath) { return $script:ConfigPath }
    $script:ConfigPath = $null
  }

  $envConfig = $env:HH_CONFIG_FILE
  if (-not [string]::IsNullOrWhiteSpace($envConfig) -and (Test-Path -LiteralPath $envConfig)) {
    $script:ConfigPath = (Resolve-Path -LiteralPath $envConfig).Path
    return $script:ConfigPath
  }

  $root = Split-Path -Path $PSScriptRoot -Parent
  $defaultConfig = (Join-Path $root 'config/hh.config.jsonc')
  if (Test-Path -LiteralPath $defaultConfig) {
    $script:ConfigPath = $defaultConfig
    return $script:ConfigPath
  }

  # Minimal fallback is a test-only template; do not auto-load in production.
  $isTest = $false
  try { if ([string]::IsNullOrWhiteSpace($env:HH_TEST) -eq $false -and $env:HH_TEST -eq '1') { $isTest = $true } } catch {}
  if ($isTest) {
    $minimalConfig = (Join-Path $root 'config/hh.config.minimal.jsonc')
    if (Test-Path -LiteralPath $minimalConfig) {
      $script:ConfigPath = $minimalConfig
      return $script:ConfigPath
    }
  }
  return $null
}

function Reset-HHConfigCache {
  $script:ConfigCache = $null
}

function Get-HHConfig {
  if ($script:ConfigCache) { return $script:ConfigCache }
  $path = Get-HHConfigPath
  if (-not $path) { return $null }

  $jsonRaw = $null
  try { $jsonRaw = [System.IO.File]::ReadAllText($path) } catch { return $null }

  $cfg = $null
  try {
    $options = [System.Text.Json.JsonDocumentOptions]@{
      CommentHandling     = [System.Text.Json.JsonCommentHandling]::Skip
      AllowTrailingCommas = $true
    }
    $doc = [System.Text.Json.JsonDocument]::Parse($jsonRaw, $options)
    $raw = $doc.RootElement.GetRawText()
    $doc.Dispose()
    $cfg = $raw | ConvertFrom-Json
  }
  catch {
    try {
      $clean = ($jsonRaw -replace '(?m)^\s*//.*$', '')
      $clean = [regex]::Replace($clean, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
      $cfg = $clean | ConvertFrom-Json
    }
    catch {
      return $null
    }
  }

  $script:ConfigCache = $cfg
  return $cfg
}

function Get-HHConfigValue {
  param(
    [string[]]$Path,
    $Default = $null
  )

  if (-not $Path -or $Path.Count -eq 0) {
    $cfg = Get-HHConfig
    return $cfg ?? $Default
  }

  $segments = $Path
  if ($segments.Count -eq 1) {
    $one = [string]$segments[0]
    if (-not [string]::IsNullOrWhiteSpace($one) -and $one.Contains('.')) {
      $segments = $one.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
    }
  }

  $current = Get-HHConfig
  foreach ($segment in $segments) {
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
  if ($null -eq $current) { return $Default }
  return $current
}



<#
  Get-HHSecrets
  Brief: Resolves tokens and API keys from config/environment.
  - Prefer config `keys.*` over environment variables.
  - For LLM: uses unified `keys.llm_api_key` or env `LLM_API_KEY`.
  - Returns individual keys plus `LlmApiKey` and `LlmKeySource`.
#>
function Get-HHSecrets {
  $hhToken = [string](Get-HHConfigValue -Path @('keys', 'hh_token'))
  $hhTokenSource = 'config:keys.hh_token'
  if ([string]::IsNullOrWhiteSpace($hhToken)) {
    $hhToken = $env:HH_TOKEN
    $hhTokenSource = if ([string]::IsNullOrWhiteSpace($hhToken)) { 'none' } else { 'env:HH_TOKEN' }
  }
  if (-not [string]::IsNullOrWhiteSpace($hhToken)) { $hhToken = $hhToken.Trim() }

  $hhXsrf = [string](Get-HHConfigValue -Path @('keys', 'hh_xsrf'))
  if ([string]::IsNullOrWhiteSpace($hhXsrf)) {
    $hhXsrf = $env:HH_XSRF
  }
  if (-not [string]::IsNullOrWhiteSpace($hhXsrf)) { $hhXsrf = $hhXsrf.Trim() }

  # Generic LLM API Key (Primary)
  $llmKey = [string](Get-HHConfigValue -Path @('keys', 'llm_api_key'))
  $llmKeySource = 'config:keys.llm_api_key'
  if ([string]::IsNullOrWhiteSpace($llmKey)) {
    $llmKey = $env:LLM_API_KEY
    $llmKeySource = if ([string]::IsNullOrWhiteSpace($llmKey)) { 'none' } else { 'env:LLM_API_KEY' }
  }

  if (-not [string]::IsNullOrWhiteSpace($llmKey)) { $llmKey = $llmKey.Trim() }

  $telegramToken = [string](Get-HHConfigValue -Path @('keys', 'telegram_bot_token'))
  $telegramTokenSource = 'config:keys.telegram_bot_token'
  if ([string]::IsNullOrWhiteSpace($telegramToken)) {
    $telegramToken = [string](Get-HHConfigValue -Path @('telegram', 'bot_token'))
    if (-not [string]::IsNullOrWhiteSpace($telegramToken)) {
      $telegramTokenSource = 'config:telegram.bot_token'
    }
    else {
      # Environment fallbacks (multiple common variable names)
      foreach ($envName in @('TELEGRAM_BOT_TOKEN', 'TELEGRAM_TOKEN', 'TG_BOT_TOKEN', 'BOT_TOKEN')) {
        $candidate = [string](Get-Item -LiteralPath Env:\$envName -ErrorAction SilentlyContinue).Value
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $telegramToken = $candidate; $telegramTokenSource = "env:$envName"; break }
      }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($telegramToken)) { $telegramToken = $telegramToken.Trim() }

  $telegramChat = [string](Get-HHConfigValue -Path @('keys', 'telegram_chat_id'))
  $telegramChatSource = 'config:keys.telegram_chat_id'
  if ([string]::IsNullOrWhiteSpace($telegramChat)) {
    $telegramChat = [string](Get-HHConfigValue -Path @('telegram', 'chat_id'))
    if (-not [string]::IsNullOrWhiteSpace($telegramChat)) {
      $telegramChatSource = 'config:telegram.chat_id'
    }
    else {
      # Environment fallbacks for chat id
      foreach ($envName in @('TELEGRAM_CHAT_ID', 'TG_CHAT_ID', 'BOT_CHAT_ID', 'TELEGRAM_TO')) {
        $candidate = [string](Get-Item -LiteralPath Env:\$envName -ErrorAction SilentlyContinue).Value
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $telegramChat = $candidate; $telegramChatSource = "env:$envName"; break }
      }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($telegramChat)) { $telegramChat = $telegramChat.Trim() }

  return [PSCustomObject]@{
    HHToken             = if ([string]::IsNullOrWhiteSpace($hhToken)) { $null } else { $hhToken }
    HHTokenSource       = $hhTokenSource
    HHXsrf              = if ([string]::IsNullOrWhiteSpace($hhXsrf)) { $null } else { $hhXsrf }
    LlmApiKey           = if ([string]::IsNullOrWhiteSpace($llmKey)) { $null } else { $llmKey }
    LlmKeySource        = $llmKeySource
    LlmProvider         = 'generic'
    TelegramToken       = if ([string]::IsNullOrWhiteSpace($telegramToken)) { $null } else { $telegramToken }
    TelegramTokenSource = $telegramTokenSource
    TelegramChat        = if ([string]::IsNullOrWhiteSpace($telegramChat)) { $null } else { $telegramChat }
    TelegramChatSource  = $telegramChatSource
  }
}

<#
  Read-HHJsonFile
  Brief: Safely reads a JSON/JSONC file, skipping comments and trailing commas. Returns $null on errors.
#>
function Read-HHJsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  $jsonRaw = $null
  try { $jsonRaw = [System.IO.File]::ReadAllText($Path) } catch { return $null }

  try {
    $options = [System.Text.Json.JsonDocumentOptions]@{
      CommentHandling     = [System.Text.Json.JsonCommentHandling]::Skip
      AllowTrailingCommas = $true
    }
    $doc = [System.Text.Json.JsonDocument]::Parse($jsonRaw, $options)
    $raw = $doc.RootElement.GetRawText()
    $doc.Dispose()
    return ($raw | ConvertFrom-Json)
  }
  catch {
    try {
      $clean = ($jsonRaw -replace '(?m)^\s*//.*$', '')
      $clean = [regex]::Replace($clean, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
      return ($clean | ConvertFrom-Json)
    }
    catch { return $null }
  }
}

Export-ModuleMember -Function Get-HHConfig, Get-HHConfigValue, Reset-HHConfigCache, Get-HHSecrets, Get-HHConfigPath, Set-HHConfigPath, Read-HHJsonFile
