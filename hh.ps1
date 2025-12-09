#!/usr/bin/env pwsh
#Requires -PSEdition Core
#Requires -Version 7.5

<#
.SYNOPSIS
  HeadHunter Probe - Automated Job Search & Analysis Tool
.DESCRIPTION
  Orchestrates the job search pipeline:
  1. Fetches vacancies from HH.ru
  2. Scores them against resume/skills
  3. Generates HTML reports and Telegram notifications
.PARAMETER Limit
  Override number of vacancies to fetch (default: config limit).
.PARAMETER Digest
  Send Telegram digest after run.
.PARAMETER Ping
  Send Telegram status ping after run.
.PARAMETER LLM
  Enable LLM-based analysis (summary/ranking).
.PARAMETER SyncCV
  Synchronize local CV JSON from HH resume (standalone action).
.PARAMETER Debug
  Enable debug logging.
.PARAMETER Parallel
  Enable parallel fetching (experimental).
.PARAMETER LearnSkills
  Update skills vocabulary from found vacancies.
.PARAMETER GC
  Run garbage collection on cache.
.PARAMETER WhatIfSearch
  Dry run for search query generation (shows query and exits).
.PARAMETER Config
  Path to custom configuration file.
.PARAMETER NotifyDryRun
  Simulate notifications without sending.
.PARAMETER NotifyStrict
  Fail if notifications cannot be sent.
#>
# Suppress PSScriptAnalyzer warnings for global vars (CLI switches)
[CmdletBinding()]
param(
    [int]$Limit = 0,
    [switch]$Digest,
    [switch]$Ping,
    [switch]$LLM,
    [switch]$SyncCV,
    [switch]$DebugMode,
    [switch]$Parallel,
    [switch]$LearnSkills,
    [switch]$GC,
    [switch]$WhatIfSearch,
    [string]$Config,
    [switch]$NotifyDryRun,
    [switch]$NotifyStrict,
    [string]$Strategy
)

# --- Bootstrap ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = if ($Host -and $Host.UI -and $Host.UI.RawUI) { 'Continue' } else { 'SilentlyContinue' }
$global:Debug = ($DebugMode.IsPresent -or $PSBoundParameters.ContainsKey('Debug'))

# Load Utility Module First
$modUtil = Join-Path $PSScriptRoot 'modules/hh.util.psm1'
if (-not (Test-Path -LiteralPath $modUtil)) { 
    Write-Error "Critical: modules/hh.util.psm1 not found at $modUtil"
    exit 1
}
Import-Module $modUtil -Force -DisableNameChecking -ErrorAction Stop -Global

# Load External Assemblies (Newtonsoft.Json)
$jsonDll = Join-Path $PSScriptRoot 'bin/Newtonsoft.Json.dll'
if (Test-Path $jsonDll) {
    try {
        Add-Type -Path $jsonDll
    }
    catch {
        Write-Warning "Failed to load Newtonsoft.Json.dll: $_"
    }
}

# Identify Repo Root
$RepoRoot = $PSScriptRoot
if (-not (Test-Path (Join-Path $RepoRoot 'config/hh.config.jsonc'))) {
    try {
        $RepoRoot = Get-RepoRoot -HintPath $PSScriptRoot
    }
    catch {
        Write-Error "Could not determine repository root: $_"
        exit 1
    }
}


# --- Module Loading ---
$Modules = @(
    'hh.models.psm1',
    'hh.config.psm1',
    'hh.log.psm1',
    'hh.core.psm1',
    'hh.cache.psm1',
    'hh.dictionaries.psm1',
    'hh.http.psm1',
    'hh.fetch.psm1',
    'hh.llm.psm1',
    'hh.llm.summary.psm1',
    'hh.llm.local.psm1',
    'hh.cv.psm1',
    'hh.scoring.psm1',
    'hh.pipeline.psm1',
    'hh.render.psm1',
    'hh.tmpl.psm1',
    'hh.notify.psm1',
    'hh.helpers.psm1'
)

foreach ($m in $Modules) {
    $path = Join-Path $RepoRoot "modules/$m"
    if (Test-Path -LiteralPath $path) {
        Import-Module $path -Force -DisableNameChecking -ErrorAction Stop
        
        # Initialize logging immediately after loading
        if ($m -eq 'hh.log.psm1') {
            $LogsRoot = Join-Path $RepoRoot 'data/logs'
            if (-not (Test-Path -LiteralPath $LogsRoot)) { New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null }
            Initialize-Logging -LogPath (Join-Path $LogsRoot 'hh.log')
        }
    }
    else {
        Write-Warning "Module not found: $path"
    }
}

# --- Configuration ---
if ($Config) {
    Set-HHConfigPath -Path (Resolve-Path -LiteralPath $Config).Path
}
else {
    $defConfig = Join-Path $RepoRoot 'config/hh.config.jsonc'
    if (Test-Path $defConfig) { Set-HHConfigPath -Path $defConfig }
}


# Set Globals
hh.llm\Set-LLMRuntimeGlobals -EnabledOverride:$LLM | Out-Null
$global:WhatIfSearch = ($WhatIfSearch.IsPresent -or $PSBoundParameters.ContainsKey('WhatIfSearch'))

Write-LogMain -Message "Modules loaded. Flags: Digest=$Digest Ping=$Ping LLM=$LLM SyncCV=$SyncCV Debug=$global:Debug" -Level Host

# --- File Lock ---
$LockFilePath = Join-Path $RepoRoot 'data/hh.lock'
$lockAcquired = $false
try {
    if (Get-Command -Name New-FileLock -ErrorAction SilentlyContinue) {
        $lockAcquired = New-FileLock -LockFilePath $LockFilePath -TimeoutSeconds 30
    }
    else {
        Write-Warning "New-FileLock not found; skipping concurrency check."
        $lockAcquired = $true
    }
}
catch {
    Write-Warning "File lock failed: $_"
    exit 1
}

if (-not $lockAcquired) {
    Write-LogMain -Message "Another instance is running (Lock: $LockFilePath). Exiting." -Level Error
    exit 1
}

# Register cleanup
try {
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        if (Get-Command -Name Remove-FileLock -ErrorAction SilentlyContinue) {
            Remove-FileLock -LockFilePath $LockFilePath
        }
    } -SupportEvent
}
catch {
    Write-LogMain -Message "Warning: Could not register lock cleanup handler" -Level Warning
}

# --- Main Execution ---
try {
    # Ensure Directories
    $DataRoot = Join-Path $RepoRoot 'data'
    $CacheRoot = Join-Path $DataRoot 'cache'
    $OutputsRoot = Join-Path $DataRoot 'outputs'
    foreach ($dir in @($DataRoot, $CacheRoot, $OutputsRoot)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }

    # Initialize Cache (Needed for vacancy/CV fetch)
    Initialize-HHCache -Root $CacheRoot
    $global:CacheStats = Initialize-HHGlobalCacheStats
    $global:CacheStats.cache_backend = Get-HHCacheBackend

    # Strategy Analysis Action
    if ($Strategy) {
        $stratPath = Join-Path $RepoRoot 'modules/hh.strategy.psm1'
        if (Test-Path $stratPath) { 
            Import-Module $stratPath -Force -DisableNameChecking 
        }
        else { 
            Write-Error "Strategy module not found at $stratPath"
            exit 1 
        }
        
        $analysis = Invoke-HHCareerStrategy -VacancyId $Strategy
        if ($analysis) {
            Write-Host "`n=== CAREER STRATEGY ANALYSIS ($Strategy) ===`n" -ForegroundColor Green
            Write-Host $analysis
            
            # Save to file
            $outFile = Join-Path $OutputsRoot "strategy_$Strategy.md"
            $analysis | Set-Content -Path $outFile -Encoding UTF8
            Write-Host "`nSaved to: $outFile" -ForegroundColor Gray
        }
        exit 0
    }
    
    # Config Debug
    if ($global:Debug) {
        $r = @{
            ReportRoot = $OutputsRoot
            Skills     = (Get-HHConfigValue -Path @('skills', 'enabled') -Default $true)
            CV         = (Get-HHConfigValue -Path @('cv', 'enabled') -Default $true)
        }
        Write-LogMain "Config: $($r | ConvertTo-Json -Compress)" -Level Debug
    }

    # SyncCV Action
    if ($SyncCV) {
        $outPath = Get-HHConfigValue -Path @('cv', 'sync_output_path') -Default 'data/inputs/cv_hh.json'
        if (Sync-HHCVFromResume -OutputPath $outPath) {
            Write-LogMain -Message "SyncCV completed. Snapshot: $outPath" -Level Host
            exit 0
        }
        else {
            Write-LogMain -Message "SyncCV failed." -Level Error
            exit 1
        }
    }

    # Check AutoRun
    $autoRun = $true
    if ($env:HH_AUTORUN -match '^(0|false|no|off)$') { $autoRun = $false }

    if ($autoRun) {
        # Search Config
        $rawSearchText = [string](Get-HHConfigValue -Path @('search', 'text') -Default '')
        if ([string]::IsNullOrWhiteSpace($rawSearchText)) { $rawSearchText = [string](Get-HHConfigValue -Path @('search', 'keyword_text') -Default '') }
        
        # CV Profile Resolution
        $cvProfile = $null
        if (Get-Command -Name 'hh.cv\Get-HHEffectiveProfile' -ErrorAction SilentlyContinue) {
            try { $cvProfile = hh.cv\Get-HHEffectiveProfile } catch { Write-LogMain "Get-HHEffectiveProfile error: $_" -Level Debug }
        }
        
            # CV Bumping (Maintenance)
            # if ($cvProfile -and $cvProfile.HHResumeId) {
            #     $lastUpd = $null
            #     try { 
            #         if ($cvProfile.UpdatedAt) { $lastUpd = [DateTime]$cvProfile.UpdatedAt }
            #     }
            #     catch { <# Suppress #> }
            
            #     if (Get-Command -Name 'Should-BumpCV' -ErrorAction SilentlyContinue) {
            #         if (Should-BumpCV -LastUpdatedUtc $lastUpd) {
            #             if (Get-Command -Name 'Invoke-CVBump' -ErrorAction SilentlyContinue) {
            #                 Invoke-CVBump -ResumeId $cvProfile.HHResumeId
            #             }
            #         }
            #         else {
            #             Write-LogMain "[CV] Bump not needed (recent or weekend)." -Level Host
            #         }
            #     }
            # }
        
        $cvEnabled = ($cvProfile -and $cvProfile.Enabled)
        $searchMode = Get-HHSearchMode -WhatIfSearch $WhatIfSearch -CvEnabled $cvEnabled
        
        # ResumeSkills Mode
        if ($searchMode -eq 'ResumeSkills' -and $cvProfile.Skills) {
            $cleanSkills = $cvProfile.Skills | Where-Object { $_.Length -lt 50 -and $_ -notmatch '[\r\n]' } | Select-Object -First 20
            $rawSearchText = ($cleanSkills -join ' OR ')
            Write-LogMain -Message "[Search] Using CV skills ($($cleanSkills.Count))" -Level Host
            
            if ($cvProfile.HHResumeId) {
                $ResumeId = $cvProfile.HHResumeId
                Write-LogMain -Message "[Search] Using ResumeId: $ResumeId" -Level Host
            }
        }

        # Keywords File
        $keywordsFile = [string](Get-HHConfigValue -Path @('search', 'keywords_file') -Default '')
        if ($keywordsFile -and (Test-Path $keywordsFile)) {
            $fc = (Get-Content $keywordsFile -Raw).Trim()
            if ($fc) { $rawSearchText = if ($rawSearchText) { "$rawSearchText`n$fc" } else { $fc } }
        }

        # Build Query
        $searchText = $rawSearchText
        try {
            $fallback = [string](Get-HHConfigValue -Path @('search', 'fallback_keyword') -Default 'CISA')
            $mode = [string](Get-HHConfigValue -Path @('search', 'keywords_mode') -Default 'OR')
            $max = [int](Get-HHConfigValue -Path @('search', 'max_keywords') -Default 0)
            
            $qb = Build-SearchQueryText -SearchText $rawSearchText -FallbackKeyword $fallback -Mode $mode -Max $max
            if ($qb.Query) { $searchText = $qb.Query }
            elseif (-not $searchText) { $searchText = $fallback }
        }
        catch {
            Write-LogMain "Build-SearchQueryText failed: $_" -Level Warning
        }
        
        # Limits & Config
        $vacancyPerPage = if ($Limit -gt 0) { $Limit } else { [int](Get-HHConfigValue -Path @('limits', 'VacancyPerPage') -Default 20) }
        $vacancyPages = if ($Limit -gt 0) { 1 } else { [int](Get-HHConfigValue -Path @('limits', 'VacancyPages') -Default 5) }
        
        $pipelineParams = @{
            SearchText       = $searchText
            VacancyKeyword   = (Get-HHConfigValue -Path @('search', 'keyword') -Default '')
            VacancyPerPage   = $vacancyPerPage
            VacancyPages     = $vacancyPages
            ResumeId         = $ResumeId
            WindowDays       = [int](Get-HHConfigValue -Path @('views', 'window_days') -Default 7)
            RecommendEnabled = [bool](Get-HHConfigValue -Path @('search', 'recommendations', 'enabled') -Default $true)
            RecommendPerPage = [int](Get-HHConfigValue -Path @('search', 'recommendations', 'per_page') -Default 20)
            RecommendTopTake = [int](Get-HHConfigValue -Path @('search', 'recommendations', 'top_take') -Default 100)
            LLMEnabled       = $LLM
            LLMPickTopN      = if ($Limit -gt 0) { [Math]::Min([int](Get-HHConfigValue -Path @('llm', 'pick_top_n') -Default 10), $Limit) } else { [int](Get-HHConfigValue -Path @('llm', 'pick_top_n') -Default 10) }
            LlmGateScoreMin  = [double](Get-HHConfigValue -Path @('llm', 'gate_score_min') -Default 1.0)
            SummaryTopN      = if ($Limit -gt 0) { [Math]::Min([int](Get-HHConfigValue -Path @('llm', 'summary_top_n') -Default 20), $Limit) } else { [int](Get-HHConfigValue -Path @('llm', 'summary_top_n') -Default 20) }
            SummaryForPicks  = [bool](Get-HHConfigValue -Path @('llm', 'summary_for_picks') -Default $true)
            ReportStats      = @{}
            Digest           = $Digest
            Ping             = $Ping
            NotifyDryRun     = $NotifyDryRun
            NotifyStrict     = $NotifyStrict
            ReportUrl        = [string](Get-HHConfigValue -Path @('report', 'url') -Default '')
            RunStartedLocal  = Get-Date
            LearnSkills      = $LearnSkills
            OutputsRoot      = $OutputsRoot
            RepoRoot         = $RepoRoot
            PipelineState    = $null
            DebugMode        = $global:Debug
        }

        # Execute Pipeline
        [void](Invoke-HHProbeMain @pipelineParams)
        
        if ($GC -and (Get-Command -Name Run-GarbageCollection -ErrorAction SilentlyContinue)) {
            Run-GarbageCollection
        }
    }
}
catch {
    Write-LogMain -Message "Fatal Error: $_" -Level Error
    Write-LogMain -Message "Stack Trace: $($_.ScriptStackTrace)" -Level Debug
    exit 1
}
finally {
    if ($lockAcquired) {
        try { Remove-FileLock -LockFilePath $LockFilePath } catch { <# Suppress #> }
        try { if (Test-Path $LockFilePath) { Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue } } catch { <# Suppress #> }
    }
}
