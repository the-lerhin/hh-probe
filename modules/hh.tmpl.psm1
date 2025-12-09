using namespace System.IO
# modules/hh.tmpl.psm1
$ErrorActionPreference = 'Stop'

# Suppress PSScriptAnalyzer warnings for the entire file where appropriate

function Import-Handlebars {
  [CmdletBinding()]
  param (
    [string]$DllPath = (Join-Path $PSScriptRoot '..' 'bin' 'Handlebars.Net.dll')
  )

  Write-Verbose "[DEBUG] Attempting to load Handlebars.Net.dll from: $DllPath"
  Write-Verbose "[DEBUG] PowerShell .NET version: $([System.Environment]::Version)"

  try {
    $assembly = [System.Reflection.Assembly]::LoadFrom($DllPath)
    Write-Verbose "[DEBUG] Successfully loaded assembly: $($assembly.FullName)"
    Write-Verbose "[DEBUG] Assembly location: $($assembly.Location)"
        
    $handlebarsType = [Type]::GetType('HandlebarsDotNet.Handlebars, Handlebars')
    if ($handlebarsType) {
      Write-Verbose "[DEBUG] Found Handlebars.Net.Handlebars type successfully"
    }
    else {
      Write-Warning "[DEBUG] Handlebars.Net.Handlebars type not found in loaded assembly"
      Write-Verbose "[DEBUG] Available types in assembly:"
      try {
        $assembly.GetTypes() | ForEach-Object { Write-Verbose "[DEBUG]     $($_.FullName)" }
      }
      catch {
        Write-Error "[ERROR] Failed to get types from assembly: $($_.Exception.Message)"
      }
    }
  }
  catch {
    Write-Error "[ERROR] Failed to load Handlebars.Net.dll: $_"
  }
}

# LEGACY: situational plain conversion wrapper; overlaps with hh.render:To-PlainObject; candidate for consolidation
function Convert-ToPlainHashtable {
  param(
    [object]$InputObject,
    [System.Collections.Generic.HashSet[object]]$Visited = (New-Object System.Collections.Generic.HashSet[object])
  )
  if ($null -eq $InputObject) { return $null }
  Write-Verbose "[DEBUG] Convert-ToPlainHashtable: InputObject type: $($InputObject.GetType().FullName)"
  if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) { return $InputObject }
  if ($InputObject -is [datetime]) { return $InputObject }

  # Detect circular references
  if ($Visited.Contains($InputObject)) { return $null }
  [void]$Visited.Add($InputObject)

  # Treat PSCustomObject/PSObject and IDictionary as property bags BEFORE IEnumerable
  $psobj = [System.Management.Automation.PSObject]$InputObject
  $propList = @()
  try { $propList = $psobj.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') } } catch {}
  # Treat PSObject as a property bag ONLY when it's not an IEnumerable (arrays/collections)
  if (
    $propList.Count -gt 0 -and 
    -not ($InputObject -is [System.Collections.IDictionary]) -and 
    -not (
      $InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])
    )
  ) {
    Write-Verbose "[DEBUG] Convert-ToPlainHashtable: Enter PSObject branch"
    $hash = @{}
    try { Write-Verbose ("[DEBUG] PSObject properties: {0}" -f (@($propList | ForEach-Object Name) -join ', ')) } catch { <# Suppress #> }
    foreach ($p in $propList) { $hash[$p.Name] = Convert-ToPlainHashtable -InputObject $p.Value -Visited $Visited }
    Write-Verbose "[DEBUG] Convert-ToPlainHashtable: Returning type (PSObject branch): $($hash.GetType().Name)"
    return $hash
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    $h = @{}
    foreach ($k in $InputObject.Keys) { $h[$k] = Convert-ToPlainHashtable -InputObject $InputObject[$k] -Visited $Visited }
    Write-Verbose "[DEBUG] Convert-ToPlainHashtable: Returning type (IDictionary branch): $($h.GetType().Name)"
    return $h
  }

  # LEGACY: special-case unwrap [bool, object] enumerables; review necessity
  # Unwrap [bool, object] pair specifically when an enumerable of exactly two elements with bool first is seen
  try {
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
      $tmpArr = @(); foreach ($i in $InputObject) { $tmpArr += , $i }
      if ($tmpArr.Count -eq 2 -and $tmpArr[0] -is [bool]) {
        return (Convert-ToPlainHashtable -InputObject $tmpArr[1] -Visited $Visited)
      }
    }
  }
  catch {}

  # Arrays/Enumerables
  if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
    Write-Verbose "[DEBUG] Convert-ToPlainHashtable: Enter IEnumerable branch"
    $arr = New-Object System.Collections.ArrayList
    foreach ($i in $InputObject) { [void]$arr.Add((Convert-ToPlainHashtable -InputObject $i -Visited $Visited)) }
    Write-Verbose "[DEBUG] Convert-ToPlainHashtable: Returning type (IEnumerable branch): $($arr.GetType().Name)"
    return $arr
  }

  return $InputObject
}

function Convert-ToPlain {
  <#
    .SYNOPSIS
    Flattens typed canonical objects into plain hashtables expected by Handlebars templates.

    .DESCRIPTION
    Wraps Convert-ToPlainHashtable, then normalizes key shapes:
    - employer.logo -> employer.logo_url
    - meta_summary -> meta.summary
    - meta_llm_summary -> meta.llm_summary
    - meta.badges -> badges (and badges_text)
    - meta.key_skills -> key_skills/skills
    - meta.summary.text -> summary (string) and llm_summary (string)
  #>
  param([object]$InputObject)
  $plain = Convert-ToPlainHashtable -InputObject $InputObject
  if ($plain -isnot [System.Collections.IDictionary]) { return $plain }

  # Ensure nested meta exists when meta_summary is present
  if (-not $plain.Contains('meta')) { $plain['meta'] = @{} }
  $meta = $plain['meta']
  if ($meta -isnot [System.Collections.IDictionary]) { $meta = @{}; $plain['meta'] = $meta }

  # employer.logo -> employer.logo_url
  try {
    if ($plain.Contains('employer') -and $plain['employer'] -is [System.Collections.IDictionary]) {
      $emp = $plain['employer']
      if (-not $emp.Contains('logo_url') -and $emp.Contains('logo')) { $emp['logo_url'] = $emp['logo'] }
    }
  }
  catch {}

  # meta_summary -> meta.summary; meta_llm_summary -> meta.llm_summary
  try {
    if ($plain.Contains('meta_summary') -and $plain['meta_summary'] -is [System.Collections.IDictionary]) {
      $meta['summary'] = $plain['meta_summary']
      # Also expose top-level summary string for template convenience
      try { $plain['summary'] = [string]($plain['meta_summary']['text']) } catch {}
      try { if (-not $plain.Contains('summary_lang')) { $plain['summary_lang'] = [string]($plain['meta_summary']['lang']) } } catch {}
    }
    if ($plain.Contains('meta_llm_summary')) {
      $meta['llm_summary'] = $plain['meta_llm_summary']
      # Expose top-level llm_summary string
      try {
        if ($plain['meta_llm_summary'] -is [System.Collections.IDictionary]) { $plain['llm_summary'] = [string]($plain['meta_llm_summary']['text']) }
        else { $plain['llm_summary'] = [string]$plain['meta_llm_summary'] }
      }
      catch {}
    }
  }
  catch {}

  # badges and key skills normalization
  try {
    if ($meta.Contains('badges')) {
      $plain['badges'] = $meta['badges']
      if ($meta.Contains('badges_text')) { $plain['badges_text'] = [string]$meta['badges_text'] }
    }
    if ($meta.Contains('key_skills')) {
      $plain['key_skills'] = $meta['key_skills']
      $plain['skills'] = $meta['key_skills']
      if ($meta.Contains('key_skills_text')) { $plain['key_skills_text'] = [string]$meta['key_skills_text'] }
    }
  }
  catch {}

  # Ensure picks is a plain IDictionary (PSCustomObject -> hashtable)
  try {
    if ($plain.Contains('picks') -and $null -ne $plain['picks'] -and -not ($plain['picks'] -is [System.Collections.IDictionary])) {
      $pObj = $plain['picks']
      $pHash = @{}
      try {
        foreach ($prop in $pObj.PSObject.Properties) {
          if ($prop.MemberType -in @('NoteProperty', 'Property')) { $pHash[[string]$prop.Name] = $prop.Value }
        }
      }
      catch {}
      $plain['picks'] = $pHash
    }
  }
  catch {}

  return $plain
}

function Convert-ToHbsModel {
  <#
    .SYNOPSIS
    Converts PowerShell Hashtables/Arrays into Handlebars-friendly dynamic objects.

    .DESCRIPTION
    Recursively transforms IDictionary into ExpandoObject and IEnumerable into object[]
    so that Handlebars.Net can access properties reliably via dot-notation.
  #>
  param([object]$Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Dynamic.ExpandoObject]) { return $Obj }
  if ($Obj -is [System.Collections.IDictionary] -or $Obj -is [System.Collections.Generic.IDictionary[string, object]]) {
    $result = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $srcGeneric = $null
    try { $srcGeneric = [System.Collections.Generic.IDictionary[string, object]]$Obj } catch { $srcGeneric = $null }
    if ($srcGeneric -ne $null) {
      foreach ($k in $srcGeneric.Keys) { $result.Add([string]$k, (Convert-ToHbsModel -Obj $srcGeneric[$k])) }
    }
    else {
      foreach ($k in $Obj.Keys) { $result.Add([string]$k, (Convert-ToHbsModel -Obj $Obj[$k])) }
    }
    return $result
  }
  if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Obj) { $list.Add((Convert-ToHbsModel -Obj $i)) }
    return $list.ToArray()
  }
  return $Obj
}

function Convert-ToGenericDictionary {
  <#
    .SYNOPSIS
    Converts PS hashtables/objects/arrays to generic Dictionary<string,object> and object[] recursively.

    .DESCRIPTION
    This produces a strongly-typed model that Handlebars.Net can traverse reliably.
  #>
  param([object]$Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.Generic.IDictionary[string, object]]) { return $Obj }
  if ($Obj -is [System.Collections.IDictionary]) {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    foreach ($k in $Obj.Keys) { $dict.Add([string]$k, (Convert-ToGenericDictionary -Obj $Obj[$k])) }
    return $dict
  }
  # Treat PSCustomObject as a property bag
  if ($Obj -is [psobject]) {
    $props = @()
    try { $props = $Obj.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' } } catch {}
    if ($props.Count -gt 0) {
      $dict = New-Object 'System.Collections.Generic.Dictionary[string,object]'
      foreach ($p in $props) { $dict.Add([string]$p.Name, (Convert-ToGenericDictionary -Obj $p.Value)) }
      return $dict
    }
  }
  if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
    $list = New-Object System.Collections.Generic.List[object]
    try { Write-Host ("[DEBUG] Convert-ToGenericDictionary: IEnumerable type={0}" -f ($Obj.GetType().FullName)) } catch {}
    $cnt = 0
    foreach ($i in $Obj) { $cnt++; $list.Add((Convert-ToGenericDictionary -Obj $i)) }
    try { Write-Host ("[DEBUG] Convert-ToGenericDictionary: IEnumerable enumerated count={0}" -f $cnt) } catch {}
    return $list.ToArray()
  }
  return $Obj
}

function Register-HbsHelpers {
  <#
    .SYNOPSIS
    Registers Handlebars helpers used by the HTML report templates.

    .DESCRIPTION
    Adds helpers for age formatting, date tooltip, salary text, numeric star rating,
    and array joining. These helpers keep templates simple while supporting both
    typed canonical rows and real HH API data structures.
  #>
  [HandlebarsDotNet.Handlebars]::RegisterHelper('age', ([HandlebarsDotNet.HandlebarsHelper] {
        param($writer, $context, $arguments)
        if ($arguments.Count -lt 1 -or $null -eq $arguments[0]) { return }
        $raw = $arguments[0]
        $dt = $null
        try {
          if ($raw -is [datetime]) { $dt = $raw }
          elseif ($raw -is [string]) { $dt = [datetime]::Parse($raw) }
          else { $dt = [datetime]$raw }
        }
        catch { return }
        $span = (Get-Date) - $dt
        $text = if ($span.TotalDays -ge 1) { "{0:n0}d" -f [math]::Floor($span.TotalDays) } else { "{0:n0}h" -f [math]::Floor($span.TotalHours) }
        $writer.Write($text)
      }))
  [HandlebarsDotNet.Handlebars]::RegisterHelper('date_hint', ([HandlebarsDotNet.HandlebarsHelper] {
        param($writer, $ctx, $pars)
        if ($pars.Count -lt 1 -or $null -eq $pars[0]) { return }
        $raw = $pars[0]
        $dt = $null
        try {
          if ($raw -is [datetime]) { $dt = $raw }
          elseif ($raw -is [string]) { $dt = [datetime]::Parse($raw) }
          else { $dt = [datetime]$raw }
        }
        catch { return }
        if ($null -eq $dt) { return }
        $writer.Write($dt.ToString('dd MMM', [System.Globalization.CultureInfo]::GetCultureInfo('ru-RU')))
      }))
  [HandlebarsDotNet.Handlebars]::RegisterHelper('salary_text', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 1 -or $null -eq $p[0]) { return }
        $s = $p[0]
        $txt = $s.text
        if ([string]::IsNullOrWhiteSpace($txt)) {
          $from = $s.from; $to = $s.to; $cur = $s.currency
          # RUR -> ₽
          if ($cur) { $cur = $cur.Replace('RUR', '₽').Replace('RUB', '₽') }
          
          if ($from -and $to) { $txt = "{0:N0}–{1:N0} {2}" -f $from, $to, $cur }
          elseif ($from) { $txt = "от {0:N0} {1}" -f $from, $cur }
          elseif ($to) { $txt = "до {0:N0} {1}" -f $to, $cur }
          elseif ($s.upper_cap) {
            try {
              $cur2 = $s.symbol
              if ([string]::IsNullOrWhiteSpace($cur2)) { $cur2 = $cur }
              if ($cur2) { $cur2 = $cur2.Replace('RUR', '₽').Replace('RUB', '₽') }
              $txt = ("{0:N0} {1}" -f [double]$s.upper_cap, [string]$cur2)
            }
            catch {
              $txt = [string]$s.upper_cap
            }
          }
        } else {
            # Fix pre-formatted text if it contains RUR
            $txt = $txt.Replace('RUR', '₽').Replace('RUB', '₽')
        }
        if ([string]::IsNullOrWhiteSpace($txt)) { $txt = '—' }
        $w.Write($txt)
      }))
  [HandlebarsDotNet.Handlebars]::RegisterHelper('stars', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        # Write rating as one-decimal number followed by a star, e.g. "4.3★"
        $r = 0.0
        try { if ($p.Count -ge 1 -and $p[0]) { $r = [double]$p[0] } } catch {}
        $w.Write(([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.0}★", $r)))
      }))
  [HandlebarsDotNet.Handlebars]::RegisterHelper('join', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        # Joins an IEnumerable into a string with a separator. If input is a string, writes as-is.
        $seq = if ($p.Count -ge 1) { $p[0] } else { $null }
        $sep = if ($p.Count -ge 2 -and $p[1]) { [string]$p[1] } else { ' ' }
        if ($null -eq $seq) { return }
        if ($seq -is [string]) { $w.Write($seq); return }
        if ($seq -is [System.Collections.IEnumerable]) {
          $sb = New-Object System.Text.StringBuilder
          $first = $true
          foreach ($x in $seq) {
            if (-not $first) { [void]$sb.Append($sep) } else { $first = $false }
            [void]$sb.Append([string]$x)
          }
          $w.Write($sb.ToString()); return
        }
        $w.Write([string]$seq)
      }))
  # country_city — formats location according to user preference
  # If country is Russia, show only city; otherwise show "Country, City".
  [HandlebarsDotNet.Handlebars]::RegisterHelper('country_city', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        $country = $null; $city = $null
        try { if ($p.Count -ge 1) { $country = [string]$p[0] } } catch {}
        try { if ($p.Count -ge 2) { $city = [string]$p[1] } } catch {}
        $isRu = $false
        try {
          if ($country) {
            $isRu = ($country -match '(?i)^(россия|russia|российская федерация)$')
          }
        }
        catch {}
        if ($isRu) {
          if ($city) { $w.Write($city); return } else { $w.Write($country); return }
        }
        if ($country -and $city) { $w.Write(("{0}, {1}" -f $country, $city)); return }
        if ($country) { $w.Write($country); return }
        if ($city) { $w.Write($city); return }
        $w.Write('')
      }))

  # Logical OR helper: writes 'true' when either operand is truthy
  [HandlebarsDotNet.Handlebars]::RegisterHelper('or', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        $a = $null; $b = $null
        try { if ($p.Count -ge 1) { $a = $p[0] } } catch {}
        try { if ($p.Count -ge 2) { $b = $p[1] } } catch {}
        if ($a -or $b) { $w.Write('true') }
      }))

  # eq helper: strict equality for simple values
  [HandlebarsDotNet.Handlebars]::RegisterHelper('eq', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 2) { return }
        $a = $p[0]; $b = $p[1]
        if ([string]::Equals([string]$a, [string]$b, [System.StringComparison]::OrdinalIgnoreCase)) { 
          $w.Write('true')
        }
      }))

  # ne helper: strict inequality
  [HandlebarsDotNet.Handlebars]::RegisterHelper('ne', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 2) { return }
        $a = $p[0]; $b = $p[1]
        if (-not [string]::Equals([string]$a, [string]$b, [System.StringComparison]::OrdinalIgnoreCase)) { 
          $w.Write('true')
        }
      }))

  # fmt_location: if country is Russia, write city; otherwise "Country, City"
  [HandlebarsDotNet.Handlebars]::RegisterHelper('fmt_location', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        $country = $null; $city = $null
        try { if ($p.Count -ge 1) { $country = [string]$p[0] } } catch {}
        try { if ($p.Count -ge 2) { $city = [string]$p[1] } } catch {}
        $isRu = $false
        try { if ($country) { $isRu = ($country -match '(?i)^(россия|russia|российская федерация)$') } } catch {}
        if ($isRu) { if ($city) { $w.Write($city); return } else { $w.Write($country); return } }
        if ($country -and $city) { $w.Write(('{0}, {1}' -f $country, $city)); return }
        if ($country) { $w.Write($country); return }
        if ($city) { $w.Write($city); return }
        $w.Write('')
      }))

  # fmt_rating: writes a star-prefixed rating rounded to one decimal, e.g., "★ 4.3"
  [HandlebarsDotNet.Handlebars]::RegisterHelper('fmt_rating', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        $r = $null
        try { if ($p.Count -ge 1) { $r = [double]$p[0] } } catch {}
        try { if ($r -gt 0) { $w.Write(('★ {0:0.0}' -f $r)); return } } catch {}
      }))

  [HandlebarsDotNet.Handlebars]::RegisterHelper('has_value', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 1) { return }
        $val = $p[0]
        if ($null -ne $val) { $w.Write('true') }
      }))

  [HandlebarsDotNet.Handlebars]::RegisterHelper('has_positive', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 1) { return }
        try { if ([double]$p[0] -gt 0) { $w.Write('true') } } catch {}
      }))

  [HandlebarsDotNet.Handlebars]::RegisterHelper('has_any_positive', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 1) { return }
        foreach ($arg in $p) {
          try { if ([double]$arg -gt 0) { $w.Write('true'); return } } catch {}
        }
      }))

  [HandlebarsDotNet.Handlebars]::RegisterHelper('has_any', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        foreach ($arg in $p) {
          if ($null -ne $arg) { $w.Write('true'); return }
        }
      }))

  [HandlebarsDotNet.Handlebars]::RegisterHelper('render_skills', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        $items = @()
        if ($p.Count -ge 1 -and $p[0]) { $items = @($p[0]) }
        $class = ''
        try { if ($p.Count -ge 2) { $class = [string]$p[1] } } catch {}
        $rendered = $false
        foreach ($entry in $items) {
          if ($null -eq $entry) { continue }
          $label = ''
          if ($entry -is [System.Collections.IDictionary]) {
            try { $label = [string]($entry['name'] ?? $entry['label'] ?? $entry['text'] ?? $entry['value']) } catch {}
          }
          elseif ($entry -is [psobject]) {
            try { $label = [string]($entry.name ?? $entry.label ?? $entry.text ?? $entry.value) } catch {}
          }
          elseif ($entry -is [System.Management.Automation.PSMemberInfo]) {
            try { $label = [string]($entry.Value ?? $entry.Name) } catch {}
          }
          if ([string]::IsNullOrWhiteSpace($label)) {
            try { $label = [string]$entry } catch { $label = '' }
          }
          if (-not [string]::IsNullOrWhiteSpace($label)) {
            $rendered = $true
            $safe = [System.Net.WebUtility]::HtmlEncode($label)
            if ([string]::IsNullOrWhiteSpace($class)) {
              $w.Write(("<span class=""skill-pill"">{0}</span>" -f $safe))
            }
            else {
              $w.Write(("<span class=""skill-pill {0}"">{1}</span>" -f $class, $safe))
            }
          }
        }
        if (-not $rendered) {
          $w.Write('<span class="skill-pill">—</span>')
        }
      }))

  # sanitize_summary: strips highlighttext tags from summaries
  [HandlebarsDotNet.Handlebars]::RegisterHelper('sanitize_summary', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 1 -or $null -eq $p[0]) { return }
        $text = [string]$p[0]
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        # Remove highlighttext tags (both raw HTML and escaped entities)
        $text = $text -replace '<highlighttext>', '' -replace '</highlighttext>', ''
        $text = $text -replace '&lt;highlighttext&gt;', '' -replace '&lt;/highlighttext&gt;', ''
        $w.Write($text)
      }))
  [HandlebarsDotNet.Handlebars]::RegisterHelper('hl', ([HandlebarsDotNet.HandlebarsHelper] {
        param($w, $c, $p)
        if ($p.Count -lt 1 -or $null -eq $p[0]) { return }
        $text = [string]$p[0]
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        $text = $text -replace '&lt;highlighttext&gt;', '<mark class="hl">'
        $text = $text -replace '&lt;/highlighttext&gt;', '</mark>'
        $text = $text -replace '<highlighttext>', '<mark class="hl">'
        $text = $text -replace '</highlighttext>', '</mark>'
        $w.Write($text)
      }))
}

function Render-Handlebars {
  param(
    [Parameter(Mandatory)][string]$TemplatePath,
    [Parameter(Mandatory)][object]$Model
  )
  Import-Handlebars
  Register-HbsHelpers
  $src = [IO.File]::ReadAllText($TemplatePath)
  Write-Verbose ("[DEBUG] Render-Handlebars: template length={0}" -f $src.Length)
  $tpl = [HandlebarsDotNet.Handlebars]::Compile($src)
  Write-Verbose ("[DEBUG] Render-Handlebars: compiled ok")
  try {
    $rowsCount = 0
    try { if ($Model.rows) { $rowsCount = ($Model.rows | Measure-Object).Count } } catch { <# Suppress #> }
    Write-Verbose ("[DEBUG] Render-Handlebars: model rows={0}, picks? {1}" -f $rowsCount, ([bool]$Model.picks))
    # Extra diagnostics for picks structure
    try {
      if ($Model.picks) {
        $p = $Model.picks
        $hasEc = $false; $hasLucky = $false; $hasWorst = $false
        try { $hasEc = ($null -ne $p.ec) } catch { try { $hasEc = ($null -ne $p['ec']) } catch { <# Suppress #> } }
        try { $hasLucky = ($null -ne $p.lucky) } catch { try { $hasLucky = ($null -ne $p['lucky']) } catch { <# Suppress #> } }
        try { $hasWorst = ($null -ne $p.worst) } catch { try { $hasWorst = ($null -ne $p['worst']) } catch { <# Suppress #> } }
        Write-Verbose ("[DEBUG] Render-Handlebars: picks.ec={0}, lucky={1}, worst={2}" -f $hasEc, $hasLucky, $hasWorst)
        try {
          $ecType = $null; $lkType = $null; $wrType = $null
          try { if ($null -ne $p['ec']) { $ecType = ($p['ec']).GetType().FullName } } catch { <# Suppress #> }
          try { if ($null -ne $p['lucky']) { $lkType = ($p['lucky']).GetType().FullName } } catch { <# Suppress #> }
          try { if ($null -ne $p['worst']) { $wrType = ($p['worst']).GetType().FullName } } catch { <# Suppress #> }
          Write-Verbose ("[DEBUG] Render-Handlebars: picks types ec={0}, lucky={1}, worst={2}" -f $ecType, $lkType, $wrType)
          try {
            $ecLen = $lkLen = $wrLen = $null
            if ($p.ec -is [System.Collections.IEnumerable] -and -not ($p.ec -is [string])) { $ecLen = 0; foreach ($x in $p.ec) { $ecLen++ } }
            if ($p.lucky -is [System.Collections.IEnumerable] -and -not ($p.lucky -is [string])) { $lkLen = 0; foreach ($x in $p.lucky) { $lkLen++ } }
            if ($p.worst -is [System.Collections.IEnumerable] -and -not ($p.worst -is [string])) { $wrLen = 0; foreach ($x in $p.worst) { $wrLen++ } }
            Write-Host ("[DEBUG] Render-Handlebars: picks lengths ec={0}, lucky={1}, worst={2}" -f $ecLen, $lkLen, $wrLen)
          }
          catch {}
        }
        catch {}
      }
    }
    catch {}
    try {
      Write-Host ("[DEBUG] Model.rows type pre-convert: {0}" -f ($Model.rows.GetType().FullName))
      $preCnt = 0; foreach ($z in $Model.rows) { $preCnt++ }
      Write-Host ("[DEBUG] Model.rows enumerable count pre-convert: {0}" -f $preCnt)
    }
    catch {}
    # Pass plain hashtable/PSObject directly to Handlebars; IDictionary is supported
    $hbModel = $Model
    try {
      $rowsObj = $hbModel['rows']
      Write-Host ("[DEBUG] hbModel.rows type: {0}" -f ($rowsObj.GetType().FullName))
      if ($rowsObj -is [System.Collections.IEnumerable]) {
        $cnt = 0; foreach ($x in $rowsObj) { $cnt++ }
        Write-Host ("[DEBUG] hbModel.rows enumerable count: {0}" -f $cnt)
        try {
          $first = $rowsObj[0]
          try {
            Write-Host ("[DEBUG] hbModel.rows[0] employer.name={0}, salary.text={1}" -f ($first['employer']['name']), ($first['salary']['text']))
          }
          catch {
            # Try as dictionary with string keys
            $firstDict = [System.Collections.Generic.IDictionary[string, object]]$first
            Write-Host ("[DEBUG] hbModel.rows[0] employer={0}, salary={1}" -f ($firstDict['employer']), ($firstDict['salary']))
          }
        }
        catch {}
      }
    }
    catch {}
    try {
      $keys = @($hbModel.Keys)
      Write-Host ("[DEBUG] hbModel keys: {0}" -f ($keys -join ', '))
      try {
        if ($hbModel.Contains('picks')) {
          $pk = $hbModel['picks']
          $pkKeys = @()
          try { $pkKeys = @($pk.Keys) } catch {}
          Write-Host ("[DEBUG] hbModel.picks keys: {0}" -f ($pkKeys -join ', '))
        }
      }
      catch {}
      # Normalize picks entries to unwrap [bool, object] tuples for template access
      try {
        if ($hbModel -is [System.Collections.IDictionary] -and $hbModel.Contains('picks')) {
          $pk = $hbModel['picks']
          if ($pk -is [System.Collections.IDictionary]) {
            foreach ($k in @('ec', 'lucky', 'worst')) {
              if ($pk.Contains($k)) {
                $v = $pk[$k]
                if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                  $arr = @(); foreach ($e in $v) { $arr += , $e }
                  if ($arr.Count -ge 2 -and $arr[0] -is [bool]) { $pk[$k] = $arr[1] }
                  elseif ($arr.Count -eq 1) { $pk[$k] = $arr[0] }
                }
                try {
                  if (-not ($pk[$k] -is [System.Collections.IDictionary])) {
                    # Removed recursive Import-Module
                    # Recursive import removed
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
    }
    catch {}
    return $tpl.Invoke($hbModel)
  }
  catch {
    Write-Host ("[ERROR] Render-Handlebars: invoke failed: {0}" -f $_.Exception.Message)
    throw $_
  }
}

Export-ModuleMember -Function * -Alias *
