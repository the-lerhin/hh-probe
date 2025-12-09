using module ./hh.models.psm1
# hh.notify.psm1 — Telegram notification helpers
#Requires -Version 7.5

try {
  if (-not (Get-Module -Name 'hh.config')) {
    $cfgModule = Join-Path $PSScriptRoot 'hh.config.psm1'
    if (Test-Path -LiteralPath $cfgModule) {
      Import-Module $cfgModule -DisableNameChecking -ErrorAction SilentlyContinue
    }
  }
  if (-not (Get-Module -Name 'hh.http')) {
    $httpModule = Join-Path $PSScriptRoot 'hh.http.psm1'
    if (Test-Path -LiteralPath $httpModule) {
      Import-Module $httpModule -DisableNameChecking -ErrorAction SilentlyContinue
    }
  }
}
catch {}


function Invoke-NotifyLog {
  param(
    [string]$Message,
    [string]$Level = 'Host'
  )
  if (Get-Command -Name Write-LogNotify -ErrorAction SilentlyContinue) {
    try { Write-LogNotify -Message $Message -Level $Level } catch {}
    return
  }
  if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
    try { Write-Log -Message $Message -Level $Level -Module 'Notify' } catch {}
    return
  }
  if (Get-Command -Name Log-Step -ErrorAction SilentlyContinue) {
    try { Log-Step $Message } catch {}
    return
  }
  Write-Host $Message
}

function Invoke-NotifyEscape {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return '' }
  $esc = Get-Command -Name Escape-Attr -ErrorAction SilentlyContinue
  if ($esc) {
    try { return & $esc -Value $Value } catch {}
  }
  return [System.Net.WebUtility]::HtmlEncode($Value)
}

function ConvertTo-TelegramPlainText {
  param(
    [string]$Html,
    [int]$MaxLen = 300
  )
  if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
  $decoded = ''
  try { $decoded = [System.Net.WebUtility]::HtmlDecode($Html) } catch { $decoded = $Html }
  $noTags = $decoded -replace '<[^>]+>', ' '
  $collapsed = ($noTags -replace '\s+', ' ').Trim()
  if ($collapsed.Length -le $MaxLen) { return $collapsed }
  $take = [Math]::Max(0, [Math]::Min($collapsed.Length, $MaxLen - 1))
  return ($collapsed.Substring(0, $take).TrimEnd() + '…')
}

function Get-CanonicalSource {
  param([object]$Row)
  if ($Row -is [CanonicalVacancy]) { return $Row }
  Write-Warning "Get-CanonicalSource received non-typed row; skipping."
  return $null
}

function Get-GlobalVariableValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    $Default = $null
  )
  try {
    $val = Get-Variable -Name $Name -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($val -ne $null) { return $val }
  }
  catch {}
  return $Default
}

function Get-TelegramSecretsInternal {
  $token = ''
  $chat = ''
  $tokenSource = 'none'
  $chatSource = 'none'
  try {
    if (Get-Command -Name 'hh.config\Get-HHSecrets' -ErrorAction SilentlyContinue) {
      $srv = & hh.config\Get-HHSecrets
    }
    elseif (Get-Command -Name 'Get-HHSecrets' -ErrorAction SilentlyContinue) {
      $srv = Get-HHSecrets
    }
    else {
      $srv = $null
    }
    if ($srv) {
      if (-not [string]::IsNullOrWhiteSpace($srv.TelegramToken)) {
        $token = [string]$srv.TelegramToken
        $tokenSource = [string]($srv.TelegramTokenSource ?? 'hh.config')
      }
      if (-not [string]::IsNullOrWhiteSpace($srv.TelegramChat)) {
        $chat = [string]$srv.TelegramChat
        $chatSource = [string]($srv.TelegramChatSource ?? 'hh.config')
      }
    }
  }
  catch {}

  if ([string]::IsNullOrWhiteSpace($token)) {
    try {
      $tkCfg = [string](Get-HHConfigValue -Path @('keys', 'telegram_bot_token'))
      if (-not [string]::IsNullOrWhiteSpace($tkCfg)) {
        $token = $tkCfg.Trim()
        $tokenSource = 'config:keys.telegram_bot_token'
      }
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace($token)) {
    try {
      $tkCfg = [string](Get-HHConfigValue -Path @('telegram', 'bot_token'))
      if (-not [string]::IsNullOrWhiteSpace($tkCfg)) {
        $token = $tkCfg.Trim()
        $tokenSource = 'config:telegram.bot_token'
      }
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace($chat)) {
    try {
      $cidCfg = [string](Get-HHConfigValue -Path @('keys', 'telegram_chat_id'))
      if (-not [string]::IsNullOrWhiteSpace($cidCfg)) {
        $chat = $cidCfg.Trim()
        $chatSource = 'config:keys.telegram_chat_id'
      }
    }
    catch {}
  }
  if ([string]::IsNullOrWhiteSpace($chat)) {
    try {
      $cidCfg = [string](Get-HHConfigValue -Path @('telegram', 'chat_id'))
      if (-not [string]::IsNullOrWhiteSpace($cidCfg)) {
        $chat = $cidCfg.Trim()
        $chatSource = 'config:telegram.chat_id'
      }
    }
    catch {}
  }

  if ([string]::IsNullOrWhiteSpace($token)) {
    foreach ($envName in @('TELEGRAM_BOT_TOKEN', 'TELEGRAM_TOKEN', 'TG_BOT_TOKEN', 'BOT_TOKEN')) {
      $candidate = [string](Get-Item -LiteralPath Env:\$envName -ErrorAction SilentlyContinue).Value
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $token = $candidate.Trim()
        $tokenSource = "env:$envName"
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($chat)) {
    foreach ($envName in @('TELEGRAM_CHAT_ID', 'TG_CHAT_ID', 'BOT_CHAT_ID', 'TELEGRAM_TO')) {
      $candidate = [string](Get-Item -LiteralPath Env:\$envName -ErrorAction SilentlyContinue).Value
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $chat = $candidate.Trim()
        $chatSource = "env:$envName"
        break
      }
    }
  }

  return [pscustomobject]@{
    Token       = $token
    Chat        = $chat
    TokenSource = $tokenSource
    ChatSource  = $chatSource
  }
}

<#
  .SYNOPSIS
  Validates Telegram configuration (token and chat_id must be non-empty).

  .DESCRIPTION
  Returns $true only when both token and chat_id are non-empty strings.
  Logs a WARNING when invalid and returns $false.
#>
function Test-TelegramConfig {
  try {
    $secrets = Get-TelegramSecretsInternal
    if ([string]::IsNullOrWhiteSpace($secrets.Token) -or [string]::IsNullOrWhiteSpace($secrets.Chat)) {
      Invoke-NotifyLog '[Telegram] WARNING: config invalid (token or chat_id missing)' -Level Warning
      return $false
    }
    return $true
  }
  catch {
    Invoke-NotifyLog ('[Telegram] WARNING: config check failed: ' + $_.Exception.Message) -Level Warning
    return $false
  }
}

<#
  .SYNOPSIS
  Sends a formatted message to Telegram using the Bot API.

  .DESCRIPTION
  Builds a request to Telegram Bot API and sends an HTML-formatted message.
  Uses the unified HTTP wrapper to benefit from retries, rate-limiting, and
  clean error handling.
#>
function Send-Telegram {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [switch]$DisablePreview,
    [switch]$Strict,
    [switch]$DryRun
  )
  try {
    $textLen = 0
    try { $textLen = ([string]$Text).Length } catch { $textLen = 0 }
    if ($textLen -le 0) {
      Invoke-NotifyLog '[Telegram] WARNING: message text is empty; skipping send' -Level Warning
      return [PSCustomObject]@{ ok = $false; status = 0; message = 'empty text' }
    }

    # DryRun-first: allow building and previewing without requiring config
    if ($DryRun) {
      $previewLen = 512
      Invoke-NotifyLog ("[TG] DRY-RUN → would send: {0}" -f ($Text.Substring(0, [Math]::Min($textLen, $previewLen)))) -Level Verbose
      return [PSCustomObject]@{ ok = $true; status = 0; message = 'dry-run' }
    }

    $valid = Test-TelegramConfig
    $tk = ''; $cid = ''; $srcTk = ''; $srcCid = ''
    if ($valid) {
      $resolved = Get-TelegramSecretsInternal
      $tk = [string]$resolved.Token
      $cid = [string]$resolved.Chat
      $srcTk = [string]$resolved.TokenSource
      $srcCid = [string]$resolved.ChatSource
    }
    else {
      if ($Strict) { throw 'Telegram config invalid' }
      Invoke-NotifyLog '[Telegram] WARNING: skipped send (token or chat_id missing)' -Level Warning
      return [PSCustomObject]@{ ok = $false; status = 0; message = 'config invalid' }
    }
    Invoke-NotifyLog ("[Config] Telegram token source: {0}; chat source: {1}" -f $srcTk, $srcCid) -Level Verbose

    $uri = "https://api.telegram.org/bot$tk/sendMessage"
    $body = @{
      chat_id                  = $cid
      text                     = $Text
      disable_web_page_preview = [bool]$DisablePreview.IsPresent
      parse_mode               = 'HTML'
    }
    Invoke-NotifyLog ("[TG] sending to chat {0}; len={1}" -f $cid, $textLen) -Level Output
    # Prefer module-qualified HTTP wrapper to improve test reliability
    $resp = $null
    if (Get-Command -Name 'hh.http\Invoke-HttpRequest' -ErrorAction SilentlyContinue) {
      $resp = & hh.http\Invoke-HttpRequest -Uri $uri -Method 'POST' -Body $body -TimeoutSec 20 -OperationName 'Telegram POST' -ApplyRateLimit:$false
    }
    else {
      $resp = Invoke-WebRequest -Uri $uri -Method 'POST' -Body ($body | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 20
      $resp = $resp.Content | ConvertFrom-Json
    }
    Invoke-NotifyLog '[TG] sent ok' -Level Output
    return [PSCustomObject]@{ ok = $true; status = 200; message = 'ok' }
  }
  catch {
    $em = $_.Exception.Message
    $statusInt = $null
    $statusText = ''
    $bodyTxt = ''
    try { $statusInt = [int]$_.Exception.Response.StatusCode } catch {}
    try { $statusText = [string]$_.Exception.Response.StatusDescription } catch {}
    try {
      $rs = $_.Exception.Response.GetResponseStream()
      if ($rs) {
        $reader = New-Object System.IO.StreamReader($rs)
        $raw = $reader.ReadToEnd()
        if ($raw) { $bodyTxt = $raw.Substring(0, [Math]::Min(400, [Math]::Max(0, $raw.Length))) }
      }
    }
    catch {}
    Invoke-NotifyLog ("[Telegram] ERROR: send failed; status={0} {1}; msg={2}; body={3}" -f $statusInt, $statusText, $em, $bodyTxt) -Level Error
    return [PSCustomObject]@{ ok = $false; status = $statusInt; message = $em }
  }
}

function Send-TelegramDigest {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$RowsTop,
    [string]$PublicUrl = $null,
    [int]$Top = 10,
    [string]$SearchLabel = $null,
    [int]$Views = 0,
    [int]$Invites = 0,
    [switch]$Strict,
    [switch]$DryRun
  )
  try {
    $cfgValid = Test-TelegramConfig
    if (-not $SearchLabel) {
      $fallback = Get-GlobalVariableValue -Name 'DigestLabel'
      if (-not [string]::IsNullOrWhiteSpace($fallback)) { $SearchLabel = $fallback }
    }
    $label = if (-not [string]::IsNullOrWhiteSpace($SearchLabel)) { $SearchLabel } else { 'подборка' }
    if ([string]::IsNullOrWhiteSpace($PublicUrl)) {
      $PublicUrl = [string](Get-GlobalVariableValue -Name 'ReportUrl')
    }
    $ts = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

    $header = ("Топ-{0} по запросу: <b>{1}</b>" -f [int]$Top, [System.Net.WebUtility]::HtmlEncode([string]$label))

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add($header)
    $skillsNonZero = 0
    try { $skillsNonZero = (@($RowsTop) | Where-Object { $_.skills_score -and [int]$_.skills_score -gt 0 } | Measure-Object).Count } catch {}
    if ($Views -gt 0 -or $Invites -gt 0 -or $skillsNonZero -gt 0) { [void]$lines.Add(("Просмотры за сутки: {0} · Новых приглашений: {1} · Вакансий со skills>0: {2}" -f ([int]$Views), ([int]$Invites), ([int]$skillsNonZero))) }

    try {
      $psState = Get-GlobalVariableValue -Name 'PipelineState'
      if ($psState -and $psState.PSObject.Properties['Search']) {
        $sb = $psState.Search
        $itemsFetched = 0
        $sim = 0; $gen = 0; $rec = 0
        try { if ($sb.PSObject.Properties['ItemsFetched']) { $itemsFetched = [int]$sb.ItemsFetched } } catch {}
        try { $sim = [int]($sb.Similar ?? 0) } catch {}
        try { $gen = [int]($sb.General ?? 0) } catch {}
        try { $rec = [int]($sb.Recommendations ?? 0) } catch {}
        $rowsCount = 0
        try { $rowsCount = (@($RowsTop) | Measure-Object).Count } catch {}
        $foundTxt = ("Найдено: {0}" -f $itemsFetched)
        if ($sim -gt 0 -or $gen -gt 0 -or $rec -gt 0) {
          $foundTxt += (" (Sim: {0}, Gen: {1}, Rec: {2})" -f $sim, $gen, $rec)
        }
        $foundTxt += (" · Отбрано: {0}" -f $rowsCount)
        [void]$lines.Add($foundTxt)
      }
    }
    catch {}

    $rows = @($RowsTop) | Select-Object -First $Top
    if (-not $rows -or $rows.Count -eq 0) {
      Invoke-NotifyLog '[Telegram] digest skipped (no rows provided)' -Level Warning
      return $false
    }
    else {
      $i = 0
      foreach ($r in $rows) {
        $src = Get-CanonicalSource $r
        $i++
        $title = ''
        try { $title = [string]($src.Title ?? $src.name ?? $r.title ?? $r.name ?? 'Без названия') } catch {}
        if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Без названия' }
        
        # Add Source Badge for Telegram
        try {
             $source = [string]($src.Meta.Source ?? $src.meta?.source ?? $r.source ?? '')
             if ($source -eq 'getmatch') { $title += " (Getmatch)" }
        } catch {}

        if ($title.Length -gt 96) { $title = $title.Substring(0, 93) + '…' }

        $url = ''
        foreach ($cand in @($src.Url, $src.Link, $src.alt_url, $src.alternate_url, $src.url)) { if (-not [string]::IsNullOrWhiteSpace($cand)) { $url = [string]$cand; break } }
        if ([string]::IsNullOrWhiteSpace($url)) { try { $rid = [string]($src.Id ?? $r.id); if ($rid) { $url = "https://hh.ru/vacancy/" + $rid } } catch {} }

        $empName = ''
        try { $empName = [string]($src.EmployerName ?? $src.Employer?.Name ?? $r.employer_name ?? $r.employer ?? '') } catch { $empName = [string]($r.employer_name ?? $r.employer ?? '') }
        $city = ''
        try { $city = [string]($src.City ?? $r.city ?? '') } catch {}
        $age = ''
        try { $age = [string]($src.AgeText ?? $r.rel_age ?? '') } catch {}
        $badges = ''
        try { $badges = [string]($src.badges_text ?? $r.badges ?? '') } catch {}

        $scoreTxt = ''
        try {
          $scoreBase = $src.Score
          if ($null -eq $scoreBase) { $scoreBase = $src.meta?.scores?.total }
          if ($null -eq $scoreBase) { $scoreBase = $r.score_total }
          if ($null -eq $scoreBase) { $scoreBase = $r.score }
          if ($null -ne $scoreBase) {
            $scoreTxt = ("{0:0.0}" -f ([double]$scoreBase * 10.0))
          }
          elseif (-not [string]::IsNullOrWhiteSpace($r.score_display)) {
            $scoreTxt = [string]$r.score_display
          }
          elseif (-not [string]::IsNullOrWhiteSpace($r.score_text)) {
            $scoreTxt = [string]$r.score_text
          }
        }
        catch {
          $scoreTxt = [string]($r.score_text ?? '')
        }
        if ([string]::IsNullOrWhiteSpace($scoreTxt)) { $scoreTxt = '—' }

        $rank = ("{0,2}" -f $i).Trim()
        $labelPick = ''
        try {
          if ($src.IsEditorsChoice -or $r.is_editors_choice -or $r.picks?.is_editors_choice) { $labelPick = 'EC' }
          elseif ($src.IsLucky -or $r.is_lucky -or $r.picks?.is_lucky) { $labelPick = 'LUCKY' }
          elseif ($src.IsWorst -or $r.is_worst -or $r.picks?.is_worst) { $labelPick = 'WORST' }
        }
        catch {}
        $bad = [System.Net.WebUtility]::HtmlEncode($badges)
        $tEnc = [System.Net.WebUtility]::HtmlEncode($title)
        $metaParts = @()
        if (-not [string]::IsNullOrWhiteSpace($empName)) { $metaParts += [System.Net.WebUtility]::HtmlEncode($empName) }
        if (-not [string]::IsNullOrWhiteSpace($city)) { $metaParts += [System.Net.WebUtility]::HtmlEncode($city) }
        if (-not [string]::IsNullOrWhiteSpace($age)) { $metaParts += [System.Net.WebUtility]::HtmlEncode($age) }
        $metaTxt = ($metaParts -join ' · ')

        $line = "$rank) <b>" + $scoreTxt + "</b> $bad<a href=""" + (Invoke-NotifyEscape $url) + """>" + $tEnc + "</a>"
        if (-not [string]::IsNullOrWhiteSpace($labelPick)) { $line += ' <i>(' + $labelPick + ')</i>' }
        if (-not [string]::IsNullOrWhiteSpace($metaTxt)) { $line += ' — ' + $metaTxt }
        [void]$lines.Add($line)

        $summaryTxt = ''
        try { $summaryTxt = [string]($src.Summary ?? $src.meta?.summary?.text ?? $r.summary ?? '') } catch {}
        if (-not [string]::IsNullOrWhiteSpace($summaryTxt)) {
          $summaryTrim = ConvertTo-TelegramPlainText -Html $summaryTxt -MaxLen 180
          [void]$lines.Add('    ' + [System.Net.WebUtility]::HtmlEncode($summaryTrim))
        }

        $present = @(); $recom = @()
        try { if ($r.skills_present) { $present = @($r.skills_present) } } catch {}
        try { if ($r.skills_recommended) { $recom = @($r.skills_recommended) } } catch {}
        $present = @($present | Where-Object { $_ } | Select-Object -First 2)
        $recom = @($recom | Where-Object { $_ -notin $present } | Select-Object -First 2)
        if ($present.Count -gt 0 -or $recom.Count -gt 0) {
          $scoreText = ''
          try { if ($r.skills_score -ne $null -and [int]$r.skills_score -gt 0) { $scoreText = (' +' + [string]$r.skills_score) } } catch {}
          $presentTxt = ([System.Net.WebUtility]::HtmlEncode(($present -join ' · ')))
          $recomTxt = ([System.Net.WebUtility]::HtmlEncode(($recom -join ' · ')))
          $lineSkills = '    ' + '🛠 Навыки' + $scoreText + ':'
          if ($present.Count -gt 0) { $lineSkills += (' ✔ ' + $presentTxt) }
          if ($recom.Count -gt 0) { $lineSkills += ('; ↗ ' + $recomTxt) }
          [void]$lines.Add($lineSkills)
        }
        try {
          $lvl = $null
          $lbl = ''
          try { $lvl = [int]($src.meta?.seniority_level) } catch {}
          if ($null -eq $lvl -or $lvl -eq 0) { try { $lvl = [int]($r.seniority_level) } catch {} }
          try { $lbl = [string]($src.meta?.seniority ?? '') } catch {}
          if ([string]::IsNullOrWhiteSpace($lbl)) { try { $lbl = [string]($r.seniority_label) } catch {} }
          if ($lvl -gt 0 -or $lbl) {
            $expMap = @{ 1 = '0–1'; 2 = '1–3'; 3 = '3–6'; 4 = '6+' }
            $rng = $expMap[[string]$lvl]
            $t = '    ' + 'Уровень: ' + ([System.Net.WebUtility]::HtmlEncode($lbl))
            if ($rng) { $t += (' (exp ' + $rng + ')') }
            [void]$lines.Add($t)
          }
        }
        catch {}
      }
    }

    # Picks section (if available)
    $picks = @($rows | Where-Object { ($_ -is [CanonicalVacancy]) -and ($_.IsEditorsChoice -or $_.IsLucky -or $_.IsWorst) })
    if ($picks -and $picks.Count -gt 0) {
      [void]$lines.Add('')
      [void]$lines.Add('<b>Пики</b>')
      foreach ($p in $picks) {
        $pSrc = Get-CanonicalSource $p
        $label = if ($pSrc.IsEditorsChoice -or $p.is_editors_choice) { 'EC' } elseif ($pSrc.IsLucky -or $p.is_lucky) { 'LUCKY' } elseif ($pSrc.IsWorst -or $p.is_worst) { 'WORST' } else { '' }
        $title = [string]($pSrc.Title ?? $p.title ?? $p.name ?? 'Без названия')
        if ($title.Length -gt 96) { $title = $title.Substring(0, 93) + '…' }
        $url = ''
        foreach ($cand in @($pSrc.Url, $pSrc.Link, $p.alt_url, $p.alternate_url, $p.url)) { if (-not [string]::IsNullOrWhiteSpace($cand)) { $url = [string]$cand; break } }
        if ([string]::IsNullOrWhiteSpace($url)) { try { $rid = [string]($pSrc.Id ?? $p.id); if ($rid) { $url = "https://hh.ru/vacancy/" + $rid } } catch {} }
        $tEnc = [System.Net.WebUtility]::HtmlEncode($title)
        $pickLine = "• <i>" + $label + "</i> — <a href=""" + (Invoke-NotifyEscape $url) + """>" + $tEnc + "</a>"
        [void]$lines.Add($pickLine)

        $whyTxt = ''
        if ($pSrc.IsEditorsChoice -or $p.is_editors_choice) {
          try { $whyTxt = [string]($pSrc.EditorsWhy ?? $p.editors_why ?? '') } catch {}
        }
        elseif ($pSrc.IsLucky -or $p.is_lucky) {
          try { $whyTxt = [string]($pSrc.LuckyWhy ?? $p.lucky_why ?? '') } catch {}
        }
        elseif ($pSrc.IsWorst -or $p.is_worst) {
          try { $whyTxt = [string]($pSrc.WorstWhy ?? $p.worst_why ?? '') } catch {}
        }
        if (-not [string]::IsNullOrWhiteSpace($whyTxt)) {
          $whyTrim = $whyTxt.Trim()
          if ($whyTrim.Length -gt 220) { $whyTrim = $whyTrim.Substring(0, 217) + '…' }
          [void]$lines.Add('    ' + [System.Net.WebUtility]::HtmlEncode($whyTrim))
        }
      }
    }

    # Link at the end
    if (-not [string]::IsNullOrWhiteSpace($PublicUrl)) {
      $u = $PublicUrl
      if ($u -notmatch '\?') { $u = $u + "?ts=$ts" } else { $u = $u + "&ts=$ts" }
      [void]$lines.Add('')
      [void]$lines.Add("<i>Отчёт:</i> <a href=""" + (Invoke-NotifyEscape $u) + """>hh.html</a>")
    }

    $text = [string]::Join("`n", $lines)
    if ($text.Length -gt 3500) { $text = $text.Substring(0, 3480) + '… (полный отчёт в ссылке)' }
    # Test-only preview surface; not for production logic.
    # Only set/clear LastTelegramDigestText when -DryRun OR $env:HH_TEST=1
    $isTestPreview = $false
    try { if ($DryRun) { $isTestPreview = $true } } catch {}
    try { if ([string]::IsNullOrWhiteSpace($env:HH_TEST) -eq $false -and $env:HH_TEST -eq '1') { $isTestPreview = $true } } catch {}
    if ($DryRun) {
      # Show a larger preview to ensure picks are visible in tests
      Invoke-NotifyLog ("[TG] DRY-RUN digest preview: {0}" -f ($text.Substring(0, [Math]::Min($text.Length, 512)))) -Level Verbose
      [void](Send-Telegram -Text $text -DryRun:$true)
      if ($isTestPreview) { Set-Variable -Name 'LastTelegramDigestText' -Scope Global -Value $text -Force }
      Invoke-NotifyLog '[Telegram] digest dry-run ok' -Level Output
      return $true
    }
    else {
      if ($isTestPreview) {
        # Allow tests to inspect composed text even in non-dry runs
        Set-Variable -Name 'LastTelegramDigestText' -Scope Global -Value $text -Force
      }
      else {
        # Clear any previous test-only global to avoid polluting normal runs
        try {
          if (Get-Variable -Name 'LastTelegramDigestText' -Scope Global -ErrorAction SilentlyContinue) {
            Set-Variable -Name 'LastTelegramDigestText' -Scope Global -Value $null -Force
          }
        }
        catch {}
      }
    }
    if (-not $cfgValid) {
      if ($Strict) { throw 'Telegram config invalid' }
      Invoke-NotifyLog '[Telegram] WARNING: digest skipped (invalid config)' -Level Warning
      return $false
    }
    
    # Defensive guard: prevent sending empty Telegram messages
    if ([string]::IsNullOrWhiteSpace($text)) {
      Invoke-NotifyLog '[Telegram] WARNING: digest text is empty; skipping send' -Level Warning
      return $false
    }
    
    $sendRes = Send-Telegram -Text $text -Strict:$Strict
    if ($sendRes -and ($sendRes.ok -or $sendRes -eq $true)) {
      Invoke-NotifyLog '[Telegram] digest sent' -Level Output
      return $true
    }
    else {
      Invoke-NotifyLog '[Telegram] digest skipped (token/chat missing or failed)' -Level Warning
      return $false
    }
  }
  catch {
    Invoke-NotifyLog ("[Telegram] digest error: {0}" -f $_.Exception.Message) -Level Error
    if ($Strict) { throw $_.Exception }
    return $false
  }
}

<#
  .SYNOPSIS
  Sends a detailed status ping to Telegram including cache and cost stats.

  .DESCRIPTION
  Composes a rich status message and sends via Send-Telegram. If DeepSeek is
  enabled, attempts to query `user/balance` via the LLM HTTP wrapper.
#>
<#
  Send-TelegramPing
  Brief: Builds and sends a status digest to Telegram, including cache metrics,
  estimated cost savings, and DeepSeek balance (via HTTP wrappers when
  configured). Provides clean, user-facing errors without raw stack traces.
#>
function Send-TelegramPing {
  param(
    [int]$ViewsCount = 0,
    [int]$InvitesCount = 0,
    [int]$RowsCount = 0,
    [string]$PublicUrl = $null,
    $RunStats = $null,
    $RunStartedLocal = $null,
    $CacheStats = $null,
    $PipelineState = $null,
    [switch]$Strict,
    [switch]$DryRun
  )
  try {
    $cfgValid = Test-TelegramConfig
    if (-not $RunStats -and -not $PipelineState) {
      $PipelineState = Get-GlobalVariableValue -Name 'PipelineState'
    }
    if (-not $RunStats -and $PipelineState) { $RunStats = $PipelineState }

    if ([string]::IsNullOrWhiteSpace($PublicUrl)) {
      $PublicUrl = [string](Get-GlobalVariableValue -Name 'ReportUrl')
    }
    $ts = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

    $u = $PublicUrl
    if (-not [string]::IsNullOrWhiteSpace($u)) {
      if ($u -notmatch '\?') { $u = $u + "?ts=$ts" } else { $u = $u + "&ts=$ts" }
    }

    # Try to resolve StartedLocal from RunStats.Run if available
    if (-not $RunStartedLocal -and $RunStats -and $RunStats.PSObject.Properties['Run'] -and $RunStats.Run.StartedLocal) {
        try { $RunStartedLocal = $RunStats.Run.StartedLocal } catch {}
    }
    # Fallback to legacy property if flattened
    if (-not $RunStartedLocal -and $RunStats -and $RunStats.PSObject.Properties['StartedLocal']) {
        try { $RunStartedLocal = $RunStats.StartedLocal } catch {}
    }

    if (-not $RunStartedLocal) {
      $RunStartedLocal = Get-GlobalVariableValue -Name 'RunStartedLocal'
    }
    # Log if missing to debug
    if (-not $RunStartedLocal) { 
        if (Get-Command -Name Write-LogNotify -ErrorAction SilentlyContinue) { Write-LogNotify -Message "[TG] Warning: RunStartedLocal missing, using Get-Date" -Level Warning }
        $RunStartedLocal = Get-Date 
    }

    $now = Get-Date
    $duration = $now - $RunStartedLocal
    $durationStr = ''
    try { 
        # Standard TimeSpan format hh:mm:ss
        $durationStr = $duration.ToString("hh\:mm\:ss") 
    } 
    catch {
        $durationStr = $duration.ToString()
    }
    $startStr = ''
    try { $startStr = $RunStartedLocal.ToString('dd.MM HH:mm') } catch {}

    # Timings
    $timingsTxt = ''
    if ($RunStats -and $RunStats.PSObject.Properties['Timings']) {
        $t = $RunStats.Timings
        $parts = @()
        if ($t.Fetch) { $parts += ("Fetch {0}s" -f [math]::Round($t.Fetch.TotalSeconds, 1)) }
        if ($t.Scoring) { $parts += ("Score {0}s" -f [math]::Round($t.Scoring.TotalSeconds, 1)) }
        if ($t.Ranking) { $parts += ("LLM {0}s" -f [math]::Round($t.Ranking.TotalSeconds, 1)) }
        if ($t.Render) { $parts += ("Render {0}s" -f [math]::Round($t.Render.TotalSeconds, 1)) }
        if ($parts.Count -gt 0) { $timingsTxt = ($parts -join ' · ') }
    }

    if (-not $CacheStats) {
      $CacheStats = Get-GlobalVariableValue -Name 'CacheStats'
    }
    $cs = $CacheStats
    $cached = 0; $queried = 0
    try { if ($cs.llm_cached -ne $null) { $cached = [int]$cs.llm_cached } } catch {}
    try { if ($cs.llm_queried -ne $null) { $queried = [int]$cs.llm_queried } } catch {}
    if ($RunStats -and $RunStats.PSObject.Properties['Cache']) {
      $cacheBlock = $RunStats.Cache
      if ($cacheBlock.PSObject.Properties['LlmCached']) { $cached = [int]$cacheBlock.LlmCached }
      if ($cacheBlock.PSObject.Properties['LlmQueried']) { $queried = [int]$cacheBlock.LlmQueried }
    }
    $totalLLM = [math]::Max(1, $cached + $queried)
    $hitPct = [math]::Min(100, [math]::Round(100.0 * $cached / $totalLLM, 1))
    $hitTxt = ("Кэш LLM: {0}% ({1}/{2})" -f $hitPct, $cached, $totalLLM)
    
    # Add vacancy and employer cache statistics
    $vacCached = 0; $vacFetched = 0
    try { if ($cs.vac_cached -ne $null) { $vacCached = [int]$cs.vac_cached } } catch {}
    try { if ($cs.vac_fetched -ne $null) { $vacFetched = [int]$cs.vac_fetched } } catch {}
    $totalVac = [math]::Max(1, $vacCached + $vacFetched)
    $vacHitPct = [math]::Min(100, [math]::Round(100.0 * $vacCached / $totalVac, 1))
    
    $empCached = 0; $empFetched = 0
    try { if ($cs.emp_cached -ne $null) { $empCached = [int]$cs.emp_cached } } catch {}
    try { if ($cs.emp_fetched -ne $null) { $empFetched = [int]$cs.emp_fetched } } catch {}
    $totalEmp = [math]::Max(1, $empCached + $empFetched)
    $empHitPct = [math]::Min(100, [math]::Round(100.0 * $empCached / $totalEmp, 1))
    
    $cacheStatsTxt = ("LLM {0}% · vac {1}% · emp {2}%" -f $hitPct, $vacHitPct, $empHitPct)
    
    # Add LiteDB/File breakdown
    $ldbHits = 0; $fileHits = 0
    try { $ldbHits = [int]($cs.litedb_hits ?? 0) } catch {}
    try { $fileHits = [int]($cs.file_hits ?? 0) } catch {}
    $totalHits = $ldbHits + $fileHits
    if ($totalHits -gt 0) {
        $ldbPct = [math]::Round(100.0 * $ldbHits / $totalHits, 0)
        $cacheStatsTxt += (" (DB {0}%)" -f $ldbPct)
    }

    $cfgFn = Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue
    $LLMPerCallCost = 0.0
    if ($cfgFn) {
      $LLMPerCallCost = [double](& $cfgFn -Path @('pricing', 'LLMPerCallCost') -Default 0.0)
    }
    $runCost = [math]::Round($LLMPerCallCost * $queried, 4)
    $saved = [math]::Round($LLMPerCallCost * $cached, 4)
    $costTxt = ("Стоимость (оценка): ${0} · экономия: ${1}" -f $runCost, $saved)

    $balLines = New-Object System.Collections.Generic.List[string]
    $LLMEnabled = $false
    if ($cfgFn) {
      $LLMEnabled = [bool](& $cfgFn -Path @('flags', 'LLM') -Default $false)
    }
    # Check pipeline flags if config didn't return true
    if (-not $LLMEnabled -and $RunStats -and $RunStats.PSObject.Properties['Run'] -and $RunStats.Run.Flags) {
        if ($RunStats.Run.Flags.ContainsKey('LLM') -and $RunStats.Run.Flags['LLM']) {
            $LLMEnabled = $true
        }
    }
    
    if ($LLMEnabled) {
      if (Get-Command -Name 'hh.llm\Get-LlmProviderBalance' -ErrorAction SilentlyContinue) {
        foreach ($prov in @('deepseek', 'hydra')) {
          try {
            $b = hh.llm\Get-LlmProviderBalance -ProviderName $prov
            if (-not [string]::IsNullOrWhiteSpace($b)) { [void]$balLines.Add($b) }
          }
          catch {}
        }
      }
    }

    $itemsFetched = $RowsCount
    if ($RunStats -and $RunStats.PSObject.Properties['Search']) {
      $searchBlock = $RunStats.Search
      if ($searchBlock.PSObject.Properties['ItemsFetched']) { $itemsFetched = [int]$searchBlock.ItemsFetched }
    }
    $queryRaw = ''
    if ($RunStats -and $RunStats.PSObject.Properties['Search']) {
      $searchBlock = $RunStats.Search
      $sqCandidate = $searchBlock.PSObject.Properties['Query']?.Value
      if (-not [string]::IsNullOrWhiteSpace($sqCandidate)) {
        $queryRaw = [string]$sqCandidate
      }
      elseif (-not [string]::IsNullOrWhiteSpace($searchBlock.Text)) {
        $queryRaw = [string]$searchBlock.Text
      }
    }
    $digestRaw = ''
    if ($RunStats -and $RunStats.PSObject.Properties['Search']) {
      $digestRaw = [string]$RunStats.Search.PSObject.Properties['Label']?.Value
    }
    else {
      $fallbackLabel = Get-GlobalVariableValue -Name 'DigestLabel'
      if (-not [string]::IsNullOrWhiteSpace($fallbackLabel)) { $digestRaw = $fallbackLabel }
    }

    if ($queryRaw.Length -gt 140) { $queryRaw = $queryRaw.Substring(0, 137) + '…' }
    $queryDisplay = if ([string]::IsNullOrWhiteSpace($queryRaw)) { '' } else { [System.Net.WebUtility]::HtmlEncode($queryRaw) }
    $digestDisplay = if ([string]::IsNullOrWhiteSpace($digestRaw)) { '' } else { [System.Net.WebUtility]::HtmlEncode($digestRaw) }

    $keywordsLine = $null
    if ($RunStats -and $RunStats.PSObject.Properties['Search']) {
      $kw = $RunStats.Search.PSObject.Properties['Keywords']?.Value
      if ($kw -and $kw.Count -gt 0) {
        $kwText = ($kw | Select-Object -Unique | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' · '
        if ($kwText.Length -gt 160) { $kwText = $kwText.Substring(0, 157) + '…' }
        $keywordsLine = ("🧲 Ключи: <code>{0}</code>" -f ([System.Net.WebUtility]::HtmlEncode($kwText)))
      }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('<b>hh_probe · обновление</b>')

    # Check Auth Status
    try {
        $hhToken = $null
        if (Get-Command -Name 'hh.http\Get-HhToken' -ErrorAction SilentlyContinue) { $hhToken = hh.http\Get-HhToken }
        elseif (Get-Command -Name 'Get-HhToken' -ErrorAction SilentlyContinue) { $hhToken = Get-HhToken }
        
        if ([string]::IsNullOrWhiteSpace($hhToken)) {
             [void]$lines.Add("⚠️ <b>HH Auth Failed</b>: Token missing.")
        }
        else {
             # Token exists, check if it works (especially if we suspect fallback)
             $suspectAuthIssue = $false
             if (Get-Command -Name 'hh.cv\Get-HHEffectiveProfile' -ErrorAction SilentlyContinue) {
                $cv = hh.cv\Get-HHEffectiveProfile
                if ($cv.Source -like '*fallback*') { $suspectAuthIssue = $true }
             }
             
             if ($suspectAuthIssue) {
                 try {
                     if (Get-Command -Name 'hh.http\Invoke-HhApiRequest' -ErrorAction SilentlyContinue) {
                         # Try a quick check to /me to see why auth failed
                         $null = hh.http\Invoke-HhApiRequest -Endpoint '/me' -Method 'GET' -ErrorAction Stop -TimeoutSec 5
                     }
                 } catch {
                     $err = $_.Exception.Message
                     if ($err -match '403') {
                         [void]$lines.Add("⛔ <b>Auth Error</b>: Token rejected (403 Forbidden).")
                     } elseif ($err -match '401') {
                         [void]$lines.Add("⛔ <b>Auth Error</b>: Token invalid (401 Unauthorized).")
                     } else {
                         [void]$lines.Add("⚠️ <b>Auth Warning</b>: API check failed ($err).")
                     }
                 }
             }
        }
    } catch {}

    # Check CV Fallback
    try {
        if (Get-Command -Name 'hh.cv\Get-HHEffectiveProfile' -ErrorAction SilentlyContinue) {
            $cv = hh.cv\Get-HHEffectiveProfile
            if ($cv.Source -like '*fallback*') {
                 [void]$lines.Add("⚠️ <b>CV Fallback</b>: Using local file (HH offline).")
            }
        }
    } catch {}

    if ($startStr -and $durationStr) {
      [void]$lines.Add(("⏱ {0} · Δ {1}" -f $startStr, $durationStr))
    }
    if ($timingsTxt) { [void]$lines.Add("⏳ $timingsTxt") }
    if (-not [string]::IsNullOrWhiteSpace($queryDisplay)) {
      [void]$lines.Add(("🔎 <code>{0}</code>" -f $queryDisplay))
    }
    if (-not [string]::IsNullOrWhiteSpace($digestDisplay)) {
      [void]$lines.Add(("📌 {0}" -f $digestDisplay))
    }
    if ($keywordsLine) { [void]$lines.Add($keywordsLine) }
    
    $foundTxt = ("📦 Найдено: {0}" -f $itemsFetched)
    
    # DEBUG: Log RunStats structure to diagnose missing tier breakdown
    try {
      if (Get-Command -Name Write-LogNotify -ErrorAction SilentlyContinue) {
        Write-LogNotify -Message ("[TG] DEBUG RunStats: Search=$($RunStats.Search | ConvertTo-Json -Compress)") -Level Verbose
      }
    }
    catch {}
    
    if ($RunStats -and $RunStats.PSObject.Properties['Search']) {
      $sb = $RunStats.Search
      $sim = 0; $gen = 0; $rec = 0
      try { $sim = [int]($sb.Similar ?? 0) } catch {}
      try { $gen = [int]($sb.General ?? 0) } catch {}
      try { $rec = [int]($sb.Recommendations ?? 0) } catch {}
      
      # DEBUG: Log extracted values
      try {
        if (Get-Command -Name Write-LogNotify -ErrorAction SilentlyContinue) {
          Write-LogNotify -Message ("[TG] DEBUG Extracted: Sim=$sim Gen=$gen Rec=$rec") -Level Verbose
        }
      }
      catch {}
      
      if ($sim -gt 0 -or $gen -gt 0 -or $rec -gt 0) {
        $foundTxt += (" (Sim: {0}, Gen: {1}, Rec: {2})" -f $sim, $gen, $rec)
      }
    }
    $foundTxt += (" · Отбрано: {0}" -f $RowsCount)
    [void]$lines.Add($foundTxt)
    [void]$lines.Add(("👁 Просмотры: {0} · 🤝 Приглашения: {1}" -f ([int]$ViewsCount), ([int]$InvitesCount)))

    if ($RunStats -and $RunStats.PSObject.Properties['Stats']) {
      $statsBlock = $RunStats.Stats
      $sb = if ($statsBlock.PSObject.Properties['SummariesBuilt']) { [int]$statsBlock.SummariesBuilt } else { 0 }
      $sc = if ($statsBlock.PSObject.Properties['SummariesCached']) { [int]$statsBlock.SummariesCached } else { 0 }
      if ($sb -gt 0 -or $sc -gt 0) {
        [void]$lines.Add(("📝 Саммари: +{0} · кеш {1}" -f $sb, $sc))
      }
    }

    [void]$lines.Add("🤖 $cacheStatsTxt")
    if ($LLMPerCallCost -gt 0 -or $runCost -gt 0 -or $saved -gt 0) {
      [void]$lines.Add("💵 $costTxt")
    }
    
    # LLM Usage Details
    if ($RunStats -and $RunStats.PSObject.Properties['LlmUsage'] -and $RunStats.LlmUsage) {
      $usageLines = New-Object System.Collections.Generic.List[string]
      foreach ($k in $RunStats.LlmUsage.Keys) {
        $v = $RunStats.LlmUsage[$k]
        $c = [int]($v.Calls ?? 0)
        $in = [int]($v.EstimatedTokensIn ?? 0)
                  $out = [int]($v.EstimatedTokensOut ?? 0)
                if ($c -gt 0) {
                  $usageLines.Add(("${k}: {0} calls, {1}/{2} tok" -f $c, $in, $out))
                }
              }      if ($usageLines.Count -gt 0) {
        [void]$lines.Add("<pre>" + ([string]::Join("`n", $usageLines)) + "</pre>")
      }
    }

    if ($balLines -and $balLines.Count -gt 0) {
      foreach ($bl in $balLines) { [void]$lines.Add("💰 $bl") }
    }

    if (-not [string]::IsNullOrWhiteSpace($u)) {
      $linkText = "<a href='" + (Invoke-NotifyEscape $u) + "'>Открыть отчёт</a>"
      [void]$lines.Add("📄 $linkText")
    }

    $text = [string]::Join("`n", $lines)
    if ($text.Length -gt 3900) { $text = $text.Substring(0, 3880) + '…' }

    # Test-only preview surface; not for production logic.
    # Only set/clear LastTelegramPingText when -DryRun OR $env:HH_TEST=1
    $isTestPreview = $false
    try { if ($DryRun) { $isTestPreview = $true } } catch {}
    try { if ([string]::IsNullOrWhiteSpace($env:HH_TEST) -eq $false -and $env:HH_TEST -eq '1') { $isTestPreview = $true } } catch {}
    if ($isTestPreview) {
      Invoke-NotifyLog ("[TG] DRY-RUN ping preview: {0}" -f ($text.Substring(0, [Math]::Min($text.Length, 512)))) -Level Verbose
      [void](Send-Telegram -Text $text -DryRun:$true)
      if ($isTestPreview) { Set-Variable -Name 'LastTelegramPingText' -Scope Global -Value $text -Force }
      Invoke-NotifyLog '[Telegram] ping dry-run ok' -Level Output
      return $true
    }
    else {
      if ($isTestPreview) {
        Set-Variable -Name 'LastTelegramPingText' -Scope Global -Value $text -Force
      }
      else {
        try {
          if (Get-Variable -Name 'LastTelegramPingText' -Scope Global -ErrorAction SilentlyContinue) {
            Set-Variable -Name 'LastTelegramPingText' -Scope Global -Value $null -Force
          }
        }
        catch {}
      }
    }
    if (-not $cfgValid) {
      if ($Strict) { throw 'Telegram config invalid' }
      Invoke-NotifyLog '[Telegram] WARNING: ping skipped (invalid config)' -Level Warning
      return $false
    }
    
    # Defensive guard: prevent sending empty Telegram messages
    if ([string]::IsNullOrWhiteSpace($text)) {
      Invoke-NotifyLog '[Telegram] WARNING: ping text is empty; skipping send' -Level Warning
      return $false
    }
    
    $sendRes = Send-Telegram -Text $text -Strict:$Strict
    if ($sendRes -and ($sendRes.ok -or $sendRes -eq $true)) {
      Invoke-NotifyLog '[Telegram] ping sent' -Level Output
      return $true
    }
    else {
      Invoke-NotifyLog '[Telegram] ping skipped (token/chat missing or failed)' -Level Warning
      return $false
    }
  }
  catch {
    Invoke-NotifyLog ("[Telegram] ping error: {0}" -f $_.Exception.Message) -Level Error
    if ($Strict) { throw $_.Exception }
    return $false
  }
}

<#
  .SYNOPSIS
  Convenience alias for Send-Telegram.

  .DESCRIPTION
  For compatibility with tests or external scripts, exposes a simple alias
  that forwards parameters to Send-Telegram.
#>
function Send-TelegramMessage {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [switch]$DisablePreview,
    [switch]$Strict,
    [switch]$DryRun
  )
  return (Send-Telegram -Text $Text -DisablePreview:$DisablePreview -Strict:$Strict -DryRun:$DryRun)
}

Export-ModuleMember -Function Test-TelegramConfig, Send-Telegram, Send-TelegramMessage, Send-TelegramDigest, Send-TelegramPing, ConvertTo-TelegramPlainText
