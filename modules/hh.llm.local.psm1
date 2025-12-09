param()

if (-not (Get-Module -Name 'hh.util')) {
  try { Import-Module -Name (Join-Path $PSScriptRoot 'hh.util.psm1') -DisableNameChecking } catch {}
}

function Get-LocalLLMConfig {
  $enabled = [bool](Get-HHConfigValue -Path @('llm', 'local', 'enabled') -Default $false)
  $model = [string](Get-HHConfigValue -Path @('llm', 'local', 'model') -Default 'gemma3:1b')
  $url = [string](Get-HHConfigValue -Path @('llm', 'local', 'url') -Default 'http://127.0.0.1:11434')
  $timeoutMs = [int](Get-HHConfigValue -Path @('llm', 'local', 'timeout_ms') -Default 15000)
  return @{ enabled = $enabled; model = $model; url = $url; timeout_ms = $timeoutMs }
}

function Invoke-OllamaRaw {
  param([Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$System = '',
    [int]$MaxTokens = 0)
  $cfg = Get-LocalLLMConfig
  $url = ($cfg.url.TrimEnd('/')) + '/api/generate'
  $bodyObj = @{ model = $Model; prompt = $Prompt; stream = $false }
  if (-not [string]::IsNullOrWhiteSpace($System)) { $bodyObj['system'] = $System }
  if ($MaxTokens -gt 0) { $bodyObj['options'] = @{ num_predict = $MaxTokens } }
  $body = $bodyObj | ConvertTo-Json -Depth 6
  try {
    $timeoutSec = [int][Math]::Ceiling([double]($cfg.timeout_ms) / 1000.0)
    if ($timeoutSec -le 0) { $timeoutSec = 15 }
    $resp = Invoke-RestMethod -Method POST -Uri $url -Body $body -ContentType 'application/json' -TimeoutSec $timeoutSec
    
    # Track Usage
    if ($resp -and (Get-Command -Name 'Add-LlmUsage' -ErrorAction SilentlyContinue)) {
        try {
            $tIn = 0; $tOut = 0
            try { $tIn = [int]($resp.prompt_eval_count ?? 0) } catch {}
            try { $tOut = [int]($resp.eval_count ?? 0) } catch {}
            if ($tIn -gt 0 -or $tOut -gt 0) {
                Add-LlmUsage -Operation "ollama:$Model" -TokensIn $tIn -TokensOut $tOut
            }
        }
        catch {
            Write-Verbose "Invoke-OllamaRaw: Usage tracking failed: $_"
        }
    }

    if ($resp -and $resp.PSObject.Properties['response']) { return [string]$resp.response }
    if ($resp) { return [string]($resp | ConvertTo-Json -Compress) }
  }
  catch { Write-Warning "Invoke-OllamaRaw failed: $_" }
  return ''
}

function Invoke-LocalLLMRelevance {
  param([Parameter(Mandatory = $true)][string]$VacancyText,
    [Parameter(Mandatory = $true)][string]$ProfileHint)
  $cfg = Get-LocalLLMConfig
  if (-not $cfg.enabled) { return 0 }
  $sys = [string](Get-HHConfigValue -Path @('llm', 'local', 'prompts', 'relevance', 'system') -Default 'Ты — ассистент подбора. Оцени релевантность вакансии профилю кандидата по шкале 0–5. Ответь только числом.')
  $usrT = [string](Get-HHConfigValue -Path @('llm', 'local', 'prompts', 'relevance', 'user') -Default 'Профиль: {{profile}}\n\nВакансия: {{title}}\n\nОписание: {{desc}}\n\nОтветь только числом 0–5')
  $prompt = ($usrT -replace '{{profile}}', [regex]::Escape($ProfileHint))
  $prompt = ($prompt -replace '{{title}}', '')
  $prompt = ($prompt -replace '{{desc}}', [regex]::Escape($VacancyText))
  $raw = Invoke-OllamaRaw -Model $cfg.model -Prompt $prompt
  try {
    $m = [regex]::Match([string]$raw, '(?<n>\b[0-5](?:\.\d+)?\b)')
    if ($m.Success) { return [double]$m.Groups['n'].Value }
  }
  catch {}
  return 0
}



function Invoke-LocalLLMSummary {
  param([Parameter(Mandatory = $true)][string]$VacancyText,
    [int]$MaxTokens = 128,
    [string]$StyleHint = '')
  $cfg = Get-LocalLLMConfig
  if (-not $cfg.enabled) { return '' }
  $langInfo = Resolve-SummaryLanguage -VacancyDescription $VacancyText
  $langKey = if ($langInfo.Language -eq 'en') { 'en' } else { 'ru' }
  $sysDefault = if ($langKey -eq 'en') { 'You are a concise job summarizer. Reply in English with 1–2 crisp sentences highlighting responsibilities, scope, and tech; skip benefits. Never repeat job title or company.' } else { 'Ты — краткий аналитик вакансий. Дай 1–2 предложения про обязанности, масштаб и стек, без соцпакета и без повторения названия должности/компании.' }
  $usrDefault = if ($langKey -eq 'en') { 'Summarize in <=2 sentences (<40 words) focusing on responsibilities, scope, and domain; skip perks/benefits. Text: {{desc}}' } else { 'Сформулируй <=2 предложения (<40 слов) про обязанности, масштаб и домен, без соцпакета и воды. Текст: {{desc}}' }
  $sys = [string](Get-HHConfigValue -Path @('llm', 'local', 'prompts', 'summary', "system_$langKey") -Default $sysDefault)
  $usrT = [string](Get-HHConfigValue -Path @('llm', 'local', 'prompts', 'summary', "user_$langKey") -Default $usrDefault)
  $alignHint = ''
  try { $alignHint = [string](Get-HHConfigValue -Path @('llm', 'local', 'prompts', 'summary', 'alignment_hint') -Default '') } catch {}
  if ([string]::IsNullOrWhiteSpace($alignHint) -and -not [string]::IsNullOrWhiteSpace($StyleHint)) {
    $alignHint = "Match tone/conciseness of this example: $StyleHint"
  }
  $prompt = ($usrT -replace '{{desc}}', [regex]::Escape($VacancyText))
  if (-not [string]::IsNullOrWhiteSpace($alignHint)) {
    $prompt = $alignHint + "`n---`n" + $prompt
  }
  $raw = Invoke-OllamaRaw -Model $cfg.model -Prompt $prompt -System $sys -MaxTokens $MaxTokens
  return ([string]$raw).Trim()
}

Export-ModuleMember -Function Get-LocalLLMConfig, Invoke-LocalLLMRelevance, Invoke-LocalLLMSummary, Invoke-OllamaRaw
