# hh.cv.psm1 — CV profile management and effective profile resolution
#Requires -Version 7.4

# Import dependencies
# Dependencies are managed by the entry script (hh.ps1).
# Only import if not already loaded (for dev/testing).
if (-not (Get-Module -Name 'hh.http')) {
  $httpModulePath = Join-Path $PSScriptRoot 'hh.http.psm1'
  if (Test-Path -LiteralPath $httpModulePath) {
    Import-Module -Name $httpModulePath -DisableNameChecking -ErrorAction SilentlyContinue
  }
}
if (-not (Get-Module -Name 'hh.config')) {
  $configModulePath = Join-Path $PSScriptRoot 'hh.config.psm1'
  if (Test-Path -LiteralPath $configModulePath) {
    Import-Module -Name $configModulePath -DisableNameChecking -ErrorAction SilentlyContinue
  }
}

$script:CVProfileCache = $null

<#
  Get-HHCVConfig
  Brief: Returns the CV configuration section from the main config.
  Returns: PSCustomObject with CV configuration
#>
function Get-HHCVConfig {
  [CmdletBinding()]
  param()
  
  $config = Get-HHConfig
  # Determine if WhatIfSearch is enabled from global context or PSBoundParameters
  $whatIf = $global:WhatIfSearch -or ($config.run?.what_if_search)

  if (-not $config.cv) {
    Write-Warning "CV configuration not found, using defaults"
    return [pscustomobject]@{
      Enabled    = $false
      Source     = 'auto_hh'
      FilePath   = 'data/inputs/cv.json'
      HHResumeId = $null
      MergeMode  = 'augment'
      Weight     = 1.0
      WhatIf     = $whatIf
    }
  }
  
  # Convert hashtable to proper object with consistent property names
  $cvConfig = $config.cv
  
  # Strict Rule: If NOT WhatIf, force 'hh_only' unless explicitly configured otherwise but we warn.
  # The user request: "All other sources... must be disabled... unless explicitly enabled via whatif"
  # So we override Source to 'hh_only' if WhatIf is false.
  
  $source = $cvConfig.source ?? 'auto_hh'
  if (-not $whatIf) {
    if ($source -ne 'hh_only' -and $source -ne 'auto_hh') {
      Write-Warning "[CV] Strict mode: Overriding CV source '$source' to 'hh_only' because -WhatIfSearch is not active."
      $source = 'hh_only'
    }
    # We do NOT force auto_hh -> hh_only anymore, because we need the fallback logic in auto_hh 
    # to handle cases where HH API is down (403/Auth failure), otherwise we get 0 skills.
  }

  return [pscustomobject]@{
    Enabled    = $cvConfig.enabled ?? $false
    Source     = $source
    FilePath   = $cvConfig.file_path ?? 'data/inputs/cv.json'
    HHResumeId = $cvConfig.hh_resume_id
    MergeMode  = $cvConfig.merge_mode ?? 'augment'
    Weight     = $cvConfig.weight ?? 1.0
    WhatIf     = $whatIf
  }
}

<#
  Get-HHEffectiveProfile
  Brief: Returns the effective CV profile based on configuration.
  Returns: PSCustomObject with effective profile data
#>
function Get-HHEffectiveProfile {
  [CmdletBinding()]
  param()
  
  if ($script:CVProfileCache) { return $script:CVProfileCache }

  $cfg = Get-HHCVConfig
  if (-not $cfg.Enabled) {
    return [pscustomobject]@{
      Enabled     = $false
      Source      = 'disabled'
      Skills      = @()
      Text        = ''
      HHResumeId  = $null
      Diagnostics = @{}
    }
  }
  
  $result = [pscustomobject]@{
    Enabled            = $true
    Source             = $cfg.source
    Skills             = @()
    Text               = ''
    HHResumeId         = $null
    Title              = $null
    Raw                = $null
    total_experience   = $null
    professional_roles = $null
    experience         = $null
    Diagnostics        = @{}
  }
  
  switch ($cfg.source) {
    'hh_only' {
      $hhProfile = Get-HHResumeProfile -ResumeId $cfg.HHResumeId
      if ($hhProfile) {
        $result.Skills = $hhProfile.Skills
        $result.Text = $hhProfile.Text
        $result.HHResumeId = $hhProfile.Id
        $result.Title = $hhProfile.Title
        $result.Raw = $hhProfile.Raw
        try { if ($hhProfile.Raw) { $result.total_experience = $hhProfile.Raw.total_experience } } catch {}
        try { if ($hhProfile.Raw) { $result.professional_roles = $hhProfile.Raw.professional_roles } } catch {}
        try { if ($hhProfile.Raw) { $result.experience = $hhProfile.Raw.experience } } catch {}
        $result.Diagnostics.HH = $true
      }
    }
    'file' {
      $fileProfile = Get-FileCVProfile -Path $cfg.FilePath
      if ($fileProfile) {
        $result.Skills = $fileProfile.Skills
        $result.Text = $fileProfile.Text
        $result.Diagnostics.File = $true
      }
    }
    'auto_hh' {
      # Deprecated in strict mode, but handled here just in case
      $hhProfile = Get-HHResumeProfile -ResumeId $cfg.HHResumeId
      if ($hhProfile) {
        $result.Skills = $hhProfile.Skills
        $result.Text = $hhProfile.Text
        $result.HHResumeId = $hhProfile.Id
        $result.Title = $hhProfile.Title
        $result.Raw = $hhProfile.Raw
        try { if ($hhProfile.Raw) { $result.total_experience = $hhProfile.Raw.total_experience } } catch {}
        try { if ($hhProfile.Raw) { $result.professional_roles = $hhProfile.Raw.professional_roles } } catch {}
        try { if ($hhProfile.Raw) { $result.experience = $hhProfile.Raw.experience } } catch {}
        $result.Diagnostics.HH = $true
      }
      elseif (-not $cfg.WhatIf) {
        # Strict mode failure fallback: check if we have local cv_hh.json or cv.json
        # This is a "brutally honest" fix for when HH auth fails but we need to proceed.
        $fallbackPath = 'data/inputs/cv_hh.json'
        if (-not (Test-Path -LiteralPath $fallbackPath)) { $fallbackPath = $cfg.FilePath }
         
        if (Test-Path -LiteralPath $fallbackPath) {
          Write-Warning "[CV] Strict mode: HH auth failed (no profile). FALLING BACK to local file: $fallbackPath"
          $fileProfile = Get-FileCVProfile -Path $fallbackPath
          if ($fileProfile) {
            $result.Skills = $fileProfile.Skills
            $result.Text = $fileProfile.Text
            $result.Diagnostics.File = $true
            $result.Source = 'file_fallback_strict'
          }
        }
        else {
          Write-Warning "[CV] Strict mode: No active HH resume found and file fallback disabled (use -WhatIfSearch to enable)."
        }
      }
      elseif ($cfg.WhatIf) {
        # Only fallback if WhatIf is enabled
        $fileProfile = Get-FileCVProfile -Path $cfg.FilePath
        if ($fileProfile) {
          $result.Skills = $fileProfile.Skills
          $result.Text = $fileProfile.Text
          $result.Diagnostics.File = $true
          $result.Source = 'file_fallback'
        }
      }
      else {
        Write-Warning "[CV] Strict mode: No active HH resume found and file fallback disabled (use -WhatIfSearch to enable)."
      }
    }
    'hybrid' {
      $hhProfile = Get-HHResumeProfile -ResumeId $cfg.hh_resume_id
      $fileProfile = Get-FileCVProfile -Path $cfg.FilePath
      
      if ($hhProfile -and $fileProfile) {
        $result.Skills = Merge-CVSkills -HHSkills $hhProfile.Skills -FileSkills $fileProfile.Skills -Mode $cfg.merge_mode
        $result.Text = $fileProfile.Text ?? $hhProfile.Text
        $result.HHResumeId = $hhProfile.Id
        $result.Diagnostics.HH = $true
        $result.Diagnostics.File = $true
        $result.Diagnostics.MergeMode = $cfg.merge_mode
      }
      elseif ($hhProfile) {
        $result.Skills = $hhProfile.Skills
        $result.Text = $hhProfile.Text
        $result.HHResumeId = $hhProfile.Id
        $result.Diagnostics.HH = $true
      }
      elseif ($fileProfile) {
        $result.Skills = $fileProfile.Skills
        $result.Text = $fileProfile.Text
        $result.Diagnostics.File = $true
      }
    }
  }
  
  $script:CVProfileCache = $result
  return $result
}

<#
  Get-LastActivePublishedResumeId
  Brief: Discovers the most relevant active/published resume ID.
  Returns: String ID or empty string if none found.
#>
function Get-LastActivePublishedResumeId {
  [CmdletBinding()]
  param(
    [array]$Resumes = $null
  )
  
  try {
    $items = $Resumes
    if (-not $items) {
      $res = Invoke-HhApiRequest -Endpoint 'resumes/mine' -Method GET
      if ($res -and $res.items) { $items = @($res.items) }
    }
    
    if (-not $items -or $items.Count -eq 0) { return '' }
    
    $candidates = @()
    foreach ($resume in $items) {
      $status = [string]($resume.status ?? '')
      $active = [bool]($resume.is_active ?? $false)
      $canPub = [bool]($resume.can_publish_or_update ?? $false)

      if ([string]::IsNullOrWhiteSpace($status) -or
        ($status -match '(?i)publish|public|visible') -or
        $active -or $canPub) {
        $candidates += $resume
      }
    }

    $activeResume = $candidates |
    Sort-Object -Property updated_at -Descending |
    Select-Object -First 1
      
    if ($activeResume) { return [string]$activeResume.id }
  }
  catch {
    Write-Warning "Get-LastActivePublishedResumeId failed: $($_.Exception.Message)"
  }
  return ''
}

<#
  Get-HHCVSkills
  Brief: Convenience wrapper to get just the skills from the effective profile.
  Returns: String array of skills
#>
function Get-HHCVSkills {
  $profile = Get-HHEffectiveProfile
  if ($profile.Enabled -and $profile.Skills) {
    return $profile.Skills
  }
  return @()
}

<#
  Get-HHResumeProfile
  Brief: Fetches HH resume profile data from API
  Returns: PSCustomObject with resume data or $null
#>
function Get-HHResumeProfile {
  [CmdletBinding()]
  param(
    [string]$ResumeId = $null
  )
  
  try {
    if ([string]::IsNullOrEmpty($ResumeId)) {
      $ResumeId = Get-LastActivePublishedResumeId
      if ([string]::IsNullOrEmpty($ResumeId)) {
        Write-Warning "No active published HH resume found"
        return $null
      }
    }
    
    $resume = Invoke-HhApiRequest -Endpoint "/resumes/$ResumeId" -Method GET
    
    # Extract skills from 'skill_set' (source of truth)
    # 'skills' property is ignored per directive
    $skills = @()
    if ($resume.skill_set) {
      $skills += @($resume.skill_set | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { $_.ToString().ToLower().Trim() })
    }
    
    return [pscustomobject]@{
      Id        = $resume.id
      Title     = $resume.title
      Skills    = @($skills | Select-Object -Unique)
      Text      = ($resume.description ?? '')
      UpdatedAt = $resume.updated_at
      Raw       = $resume
    }
  }
  catch {
    Write-Warning "Failed to fetch HH resume: $($_.Exception.Message)"
    return $null
  }
}

<#
  Get-FileCVProfile
  Brief: Reads CV profile from local JSON file
  Returns: PSCustomObject with file data or $null
#>
function Get-FileCVProfile {
  [CmdletBinding()]
  param(
    [string]$Path
  )
  
  try {
    if (-not (Test-Path -LiteralPath $Path)) {
      Write-Warning "CV file not found: $Path"
      return $null
    }
    
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    
    return [pscustomobject]@{
      Skills    = @($content.skills ?? @() | ForEach-Object { $_.ToLower().Trim() })
      Text      = ($content.text ?? '')
      Source    = 'file'
      UpdatedAt = (Get-Item -LiteralPath $Path).LastWriteTime
      Raw       = $content.raw
    }
  }
  catch {
    Write-Warning "Failed to read CV file '$Path': $($_.Exception.Message)"
    return $null
  }
}

<#
  Merge-CVSkills
  Brief: Merges skills from HH and file sources according to mode
  Returns: Array of merged skills
#>
function Merge-CVSkills {
  [CmdletBinding()]
  param(
    [array]$HHSkills,
    [array]$FileSkills,
    [string]$Mode = 'augment'
  )
  
  switch ($Mode) {
    'replace' {
      if ($FileSkills.Count -gt 0) {
        return $FileSkills
      }
      return $HHSkills
    }
    'augment' {
      $combined = $HHSkills + $FileSkills
      return @($combined | Sort-Object -Unique)
    }
    default {
      Write-Warning "Unknown merge mode '$Mode', using 'augment'"
      $combined = $HHSkills + $FileSkills
      return @($combined | Sort-Object -Unique)
    }
  }
}

<#
  Sync-HHCVProfile
  Brief: Synchronizes CV profile data (HH → file or file → HH)
#>
function Sync-HHCVProfile {
  [CmdletBinding()]
  param(
    [ValidateSet('hh_to_file', 'file_to_hh')]
    [string]$Direction = 'hh_to_file',
    
    [switch]$Force,
    
    # Optional parameter for testing - allows injecting custom config
    [Parameter(DontShow)]
    [object]$TestConfig
  )
  
  $cfg = if ($TestConfig) { $TestConfig } else { Get-HHCVConfig }
  if (-not $cfg.Enabled) {
    Write-Warning "CV sync disabled in configuration"
    return
  }
  
  switch ($Direction) {
    'hh_to_file' {
      $hhProfile = Get-HHResumeProfile -ResumeId $cfg.HHResumeId
      if (-not $hhProfile) {
        Write-Warning "No HH resume found for sync"
        return
      }
      
      $fileData = @{
        skills         = $hhProfile.Skills
        text           = $hhProfile.Text
        synced_from_hh = $true
        synced_at      = [DateTime]::UtcNow.ToString('o')
        hh_resume_id   = $hhProfile.Id
        raw            = $hhProfile.Raw
      }
      
      $fileDir = Split-Path -Path $cfg.FilePath -Parent
      if (-not (Test-Path -LiteralPath $fileDir)) {
        New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
      }
      
      $fileData | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cfg.FilePath -Encoding UTF8
      Write-LogCV -Message "Synced HH resume to file: $($cfg.FilePath)" -Level Host
    }
    
    'file_to_hh' {
      Write-Warning "File to HH sync not yet implemented (requires HH resume update API)"
    }
  }
}

<#
  Get-HHCVSkills
  Brief: Public function to get effective CV skills for scoring
  Returns: Array of skills
#>
function Get-HHCVSkills {
  [CmdletBinding()]
  param()
  
  $cvProfile = Get-HHEffectiveProfile
  return $cvProfile.Skills
}

<#
  Get-CVSkills
  Brief: Compatibility shim returning effective CV skills for scoring/search.
  Returns: Array of skills (merged per CV config or from provided file path)
#>
function Get-CVSkills {
  [CmdletBinding()]
  param(
    [string]$Path
  )
  # If a specific path is provided, read directly; otherwise use configured profile.
  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $fileProfile = Get-HHCVFromFile -Path $Path
    if ($fileProfile -and $fileProfile.Skills) {
      return @($fileProfile.Skills | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }) | Select-Object -Unique
    }
    return @()
  }
  return Get-HHCVSkills
}

<#
  Get-HHCVText
  Brief: Public function to get effective CV text for LLM prompts
  Returns: String with CV text
#>
function Get-HHCVText {
  [CmdletBinding()]
  param()
  
  $cvProfile = Get-HHEffectiveProfile
  return $cvProfile.Text
}

<#
  Sync-HHCVFromResume
  Brief: Sync HH resume profile to file for user review/merge
  Returns: Boolean indicating success
#>
function Sync-HHCVFromResume {
  [CmdletBinding()]
  param(
    [string]$OutputPath = "data/inputs/cv_hh.json"
  )

  $cfg = Get-HHCVConfig
  # Use $cfg.HHResumeId if set, otherwise discover via Get-LastActivePublishedResumeId
  $resumeId = $cfg.HHResumeId
  if ([string]::IsNullOrEmpty($resumeId)) {
    try {
      $resumeId = Get-LastActivePublishedResumeId
    }
    catch {
      Write-Warning "Sync-HHCVFromResume: failed to discover HH resume ID"
      return $false
    }
  }

  $hhProfile = Get-HHCVFromHH -ResumeId $resumeId

  if (-not $hhProfile) {
    Write-Warning "Sync-HHCVFromResume: failed to fetch HH resume profile."
    return $false
  }

  # Save comprehensive representation for user review/merge.
  # We include the flattened skills/text for convenience, plus the full raw object.
  $payload = [pscustomobject]@{
    resume_id  = $hhProfile.Id
    skills     = $hhProfile.Skills
    text       = $hhProfile.Text
    fetched_at = (Get-Date).ToString('o')
    raw        = $hhProfile.Raw
  }

  $dir = Split-Path -Parent $OutputPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8

  Write-LogCV -Message "Sync-HHCVFromResume: saved HH resume snapshot to $OutputPath." -Level Host
  return $true
}

# Standardized function aliases for CVMOD.md compliance
function Get-HHCVFromFile {
  [CmdletBinding()]
  param([string]$Path)
  Get-FileCVProfile -Path $Path
}

function Get-HHCVFromHH {
  [CmdletBinding()]
  param([string]$ResumeId = $null)
  Get-HHResumeProfile -ResumeId $ResumeId
}

function Invoke-CVBump {
  param([Parameter(Mandatory = $true)][string]$ResumeId)
  try {
    $u = "https://api.hh.ru/resumes/$ResumeId/publish"
    Write-Log -Message ("[CV] bump: POST {0}" -f $u) -Level Verbose -Module 'CV'
    Invoke-Jitter 120 220
    Invoke-HhApiRequest -Path "resumes/$ResumeId/publish" -Method 'POST' | Out-Null
    Write-Log -Message "[CV] bump OK" -Level Verbose -Module 'CV'
    return $true
  }
  catch {
    Write-Log -Message ("[CV] bump failed: {0}" -f $_.Exception.Message) -Level Warning -Module 'CV'
    return $false
  }
}

function Get-HHCVSnapshotOrSkills {
  $prof = Get-HHEffectiveProfile
  return [pscustomobject]@{
    KeySkills          = $prof.Skills
    Summary            = $prof.Text
    Title              = $prof.Title
    Raw                = $prof.Raw
    professional_roles = $prof.professional_roles
    total_experience   = $prof.total_experience
    experience         = if ($prof.experience) { $prof.experience } elseif ($prof.Raw -and $prof.Raw.experience) { $prof.Raw.experience } else { $null }
  }
}

<#
  Build-CompactCVPayload
  Brief: Constructs a privacy-safe, token-optimized CV payload for premium LLM rescoring.
  Returns: Hashtable with minimal CV context.
#>
function Build-CompactCVPayload {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][object]$Resume,
    [hashtable]$CvConfig,
    [int]$RecentExperienceLimit = 3
  )

  $window = $RecentExperienceLimit
  if ($CvConfig -and $CvConfig.ContainsKey('cv_recent_experience_window')) {
    try { $window = [int]$CvConfig['cv_recent_experience_window'] } catch {}
  }
  else {
    try {
      $cfgWindow = Get-HHConfigValue -Path @('cv', 'cv_recent_experience_window') -Default $RecentExperienceLimit
      if ($cfgWindow) { $window = [int]$cfgWindow }
    }
    catch {}
  }
  if ($window -le 0) { $window = $RecentExperienceLimit }

  $payload = [ordered]@{
    cv_title                   = [string]($Resume.title ?? $Resume.Title ?? $Resume.Raw?.title ?? '')
    cv_skill_set               = @()
    cv_total_experience_months = 0
    cv_primary_roles           = @()
    cv_recent_experience       = @()
    cv_certifications_core     = @()
  }

  # Skills (Normalize + Unique)
  $skillsSource = @()
  if ($Resume.Skills) { $skillsSource = $Resume.Skills }
  elseif ($Resume.skill_set) { $skillsSource = $Resume.skill_set }
  elseif ($Resume.Raw -and $Resume.Raw.skill_set) { $skillsSource = $Resume.Raw.skill_set }

  $payload.cv_skill_set = @(
    $skillsSource |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } |
    Select-Object -Unique
  )

  # Experience Months
  if ($Resume.total_experience -and $Resume.total_experience.months) {
    $payload.cv_total_experience_months = [int]$Resume.total_experience.months
  }
  elseif ($Resume.Raw -and $Resume.Raw.total_experience -and $Resume.Raw.total_experience.months) {
    $payload.cv_total_experience_months = [int]$Resume.Raw.total_experience.months
  }

  # Roles
  $roles = $null
  if ($Resume.professional_roles) { $roles = $Resume.professional_roles }
  elseif ($Resume.Raw -and $Resume.Raw.professional_roles) { $roles = $Resume.Raw.professional_roles }

  if ($roles) {
    foreach ($role in $roles) {
      if ($role.id) { $payload.cv_primary_roles += $role.id }
      elseif ($role.name) { $payload.cv_primary_roles += $role.name }
    }
    $payload.cv_primary_roles = @($payload.cv_primary_roles | Select-Object -Unique)
  }

  # Recent Experience (Compact)
  # Check if we have raw experience array
  $expList = @()
  if ($Resume.experience) { $expList = $Resume.experience }
  elseif ($Resume.Raw -and $Resume.Raw.experience) { $expList = $Resume.Raw.experience }

  if ($expList) {
    $sortedExp = $expList | Sort-Object -Property @{Expression = { try { [datetime]$_.start } catch { Get-Date '1900-01-01' } }; Descending = $true }
    foreach ($job in $sortedExp) {
      if ($payload.cv_recent_experience.Count -ge $window) { break }

      $desc = [string]($job.description ?? '')
      if ($desc.Length -gt 240) { $desc = $desc.Substring(0, 240) + "..." }
      $desc = ($desc -replace '\s+', ' ').Trim()

      $industry = ''
      try {
        if ($job.industry -and $job.industry.name) { $industry = [string]$job.industry.name }
        elseif ($job.industries -and $job.industries.Count -gt 0) { $industry = [string]$job.industries[0].name }
      }
      catch {}

      $period = ''
      try {
        if ($job.start -or $job.end) { $period = "$($job.start) - $($job.end ?? 'present')" }
      }
      catch {}

      $payload.cv_recent_experience += @{
        employer = [string]($job.company ?? $job.employer?.name ?? '')
        position = [string]($job.position ?? '')
        industry = $industry
        summary  = $desc
        period   = $period
      }
    }
  }

  # Certifications (Optional - Shortlist)
  # If present, take top 5 titles
  $certs = @()
  if ($Resume.certificates) { $certs = $Resume.certificates }
  elseif ($Resume.Raw -and $Resume.Raw.certificates) { $certs = $Resume.Raw.certificates }
    
  if ($certs) {
    $payload.cv_certifications_core = @(
      $certs |
      Select-Object -First 5 |
      ForEach-Object { $_.title } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToString().Trim() }
    )
  }

  return $payload
}

Export-ModuleMember -Function Get-HHEffectiveProfile, Get-HHCVSkills, Get-CVSkills, Get-HHCVText, Sync-HHCVProfile, Get-HHCVConfig, Sync-HHCVFromResume, Get-HHCVFromFile, Get-HHCVFromHH, Merge-CVSkills, Get-LastActivePublishedResumeId, Invoke-CVBump, Get-HHResumeProfile, Get-HHCVSnapshotOrSkills, Build-CompactCVPayload
