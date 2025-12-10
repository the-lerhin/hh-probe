# hh.scoring.psm1 — V2.5 Heuristic Scoring Engine
#
# Implements deterministic, currency-aware, source-aware scoring for gating.
# Pure functions only: no HTTP, no side effects.
#
# Reference: FR-3.1, FR-3.2, FR-3.3, SDD-4.9
#Requires -Version 7.5

# Imports
if (-not (Get-Module -Name 'hh.models')) {
    $modModels = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/hh.models.psm1'
    if (Test-Path -LiteralPath $modModels) { Import-Module $modModels -DisableNameChecking -ErrorAction SilentlyContinue }
}
if (-not (Get-Module -Name 'hh.util')) {
    $modUtil = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/hh.util.psm1'
    if (Test-Path -LiteralPath $modUtil) { Import-Module $modUtil -DisableNameChecking -ErrorAction SilentlyContinue }
}
if (-not (Get-Module -Name 'hh.config')) {
    $modConfig = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/hh.config.psm1'
    if (Test-Path -LiteralPath $modConfig) { Import-Module $modConfig -DisableNameChecking -ErrorAction SilentlyContinue }
}

# ==============================================================================
# Configuration
# ==============================================================================

function Get-HHScoringConfig {
    # Reads config/hh.config.jsonc via Get-HHConfigValue
    # Returns a standardized config object for scoring
    
    $baseCurrency = [string](Get-HHConfigValue -Path @('scoring', 'base_currency') -Default 'RUB')
    
    # Weights
    $w = @{
        skills     = [double](Get-HHConfigValue -Path @('scoring', 'weights', 'skills') -Default 0.4)
        salary     = [double](Get-HHConfigValue -Path @('scoring', 'weights', 'salary') -Default 0.3)
        experience = [double](Get-HHConfigValue -Path @('scoring', 'weights', 'experience') -Default 0.2)
        recency    = [double](Get-HHConfigValue -Path @('scoring', 'weights', 'recency') -Default 0.1)
    }
    
    # Recency params
    $tau = [double](Get-HHConfigValue -Path @('scoring', 'recency', 'tau_days') -Default 7.0)
    
    # Filters
    $blacklist = @(Get-HHConfigValue -Path @('scoring', 'filters', 'blacklist_employers') -Default @())
    $remotePref = [bool](Get-HHConfigValue -Path @('scoring', 'filters', 'enforce_remote_if_preferred') -Default $true)
    
    return [pscustomobject]@{
        BaseCurrency = $baseCurrency
        Weights      = $w
        RecencyTau   = $tau
        Blacklist    = $blacklist
        RemoteOnly   = $remotePref
    }
}

# ==============================================================================
# Helper Components (Pure)
# ==============================================================================

function Get-SkillsComponent {
    param($CvSkills, $VacSkills)
    
    # Normalize sets and keep map to original
    $cvSet = New-Object System.Collections.Generic.HashSet[string]
    if ($CvSkills) {
        foreach ($s in $CvSkills) {
            $n = hh.util\Normalize-SkillToken -Token $s
            if ($n) { $cvSet.Add($n) | Out-Null }
        }
    }
    
    $vacSet = New-Object System.Collections.Generic.HashSet[string]
    $vacOriginals = @{}
    if ($VacSkills) {
        foreach ($s in $VacSkills) {
            $n = hh.util\Normalize-SkillToken -Token $s
            if ($n) { 
                $vacSet.Add($n) | Out-Null 
                if (-not $vacOriginals.ContainsKey($n)) { $vacOriginals[$n] = $s }
            }
        }
    }
    
    if ($cvSet.Count -eq 0 -or $vacSet.Count -eq 0) { 
        return [PSCustomObject]@{ Score = 0.0; Matched = @(); InCV = @() } 
    }
    
    # Intersection
    $intersect = 0
    $matchedOriginals = @()
    $matchedNormalized = @()
    
    foreach ($s in $cvSet) {
        if ($vacSet.Contains($s)) { 
            $intersect++ 
            $matchedNormalized += $s
            if ($vacOriginals.ContainsKey($s)) { $matchedOriginals += $vacOriginals[$s] }
        }
    }
    
    # Formula: 0.7 * (|I| / |CV|) + 0.3 * (|I| / |VAC|)
    $cvCov = $intersect / $cvSet.Count
    $vacCov = $intersect / $vacSet.Count
    
    $score = (0.7 * $cvCov) + (0.3 * $vacCov)
    
    return [PSCustomObject]@{
        Score = $score
        Matched = $matchedOriginals
        InCV = $matchedNormalized
    }
}

function Get-SalaryComponent {
    param($Vacancy, $UserMin, $BaseCurrency, $ExchangeRates)
    
    $source = $Vacancy.Meta.Source
    $expId = if ($Vacancy.Experience) { $Vacancy.Experience.Id } else { '' }
    
    # 1. Check if salary exists
    $hasSalary = ($Vacancy.Salary -and ($Vacancy.Salary.From -gt 0 -or $Vacancy.Salary.To -gt 0))
    
    if (-not $hasSalary) {
        # Hidden Salary Logic
        if ($source -eq 'getmatch') { return 0.9 }
        if ($source -eq 'hh' -or $source -match '^hh_') {
            if ($expId -eq 'moreThan6') { return 0.8 } # Senior
            return 0.5 # Default hidden
        }
        return 0.5
    }
    
    # Explicit Salary Logic
    $from = 0.0
    $to = 0.0
    $curr = $Vacancy.Salary.Currency
    
    if ($Vacancy.Salary.From) { $from = [double]$Vacancy.Salary.From }
    if ($Vacancy.Salary.To) { $to = [double]$Vacancy.Salary.To }
    
    # Normalize
    $rate = 1.0
    if ($ExchangeRates) {
        $val = $ExchangeRates[$curr]
        if ($val) { $rate = [double]$val }
    }
    
    # Convert to Base (RUB)
    # Rates are relative to RUB (e.g. USD=100). If Base is RUB, multiply.
    # If Base is USD, we need to divide by USD rate.
    # Assuming BaseCurrency is RUB for now as per default config.
    # If Rates map is { RUB=1, USD=95 }, implies 1 USD = 95 RUB.
    # So 100 USD = 100 * 95 = 9500 RUB.
    
    $normFrom = $from * $rate
    $normTo = $to * $rate
    if ($normTo -eq 0) { $normTo = $normFrom }
    if ($normFrom -eq 0) { $normFrom = $normTo }
    
    # Check against UserMin
    if ($UserMin -le 0) { return 0.8 } # No preference -> neutral positive
    
    if ($normTo -lt $UserMin) { return 0.0 } # Lowball
    if ($UserMin -ge $normFrom -and $UserMin -le $normTo) { return 1.0 } # In range
    if ($normFrom -ge $UserMin) { return 1.0 } # Above range
    
    return 0.8 # Fallback (e.g. range overlaps partially or fuzzy)
}

function Get-ExperienceComponent {
    param($Vacancy, $CvMonths)
    
    $source = $Vacancy.Meta.Source
    if ($source -eq 'getmatch') { return 1.0 }
    
    $vacExpId = if ($Vacancy.Experience) { $Vacancy.Experience.Id } else { '' }
    if (-not $vacExpId) { return 0.5 }
    
    # Map CV months to bucket
    $cvBucket = 'noExperience'
    if ($CvMonths -ge 72) { $cvBucket = 'moreThan6' }
    elseif ($CvMonths -ge 36) { $cvBucket = 'between3And6' }
    elseif ($CvMonths -ge 12) { $cvBucket = 'between1And3' }
    
    # Map buckets to numeric index for distance
    $indices = @{
        'noExperience' = 0
        'between1And3' = 1
        'between3And6' = 2
        'moreThan6'    = 3
    }
    
    if (-not $indices.ContainsKey($vacExpId)) { return 0.0 }
    
    $vIdx = $indices[$vacExpId]
    $cIdx = $indices[$cvBucket]
    
    $diff = [Math]::Abs($vIdx - $cIdx)
    
    if ($diff -eq 0) { return 1.0 }
    if ($diff -eq 1) { return 0.5 }
    return 0.0
}

function Get-RecencyComponent {
    param($Vacancy, $Tau)
    
    if (-not $Vacancy.PublishedAtUtc) { return 0.5 }
    
    $age = ((Get-Date).ToUniversalTime() - $Vacancy.PublishedAtUtc).TotalDays
    if ($age -lt 0) { $age = 0 }
    
    # exp(-t / tau)
    return [Math]::Exp(-1 * $age / $Tau)
}

# ==============================================================================
# Main API
# ==============================================================================

function Test-IsHardFiltered {
    param(
        [Parameter(Mandatory)][object]$Vacancy,
        [object]$Preferences, # { remote_only = bool }
        [object]$Config       # result of Get-HHScoringConfig
    )
    
    # 1. Employer Blacklist
    if ($Config.Blacklist -and $Vacancy.EmployerId) {
        if ($Config.Blacklist -contains $Vacancy.EmployerId) { return $true }
    }
    
    # 2. Remote Preference
    # Only if enabled in config AND requested by user preferences
    if ($Config.RemoteOnly) {
        $reqRemote = $false
        if ($Preferences -is [System.Collections.IDictionary]) {
            if ($Preferences.Contains('remote_only')) { $reqRemote = [bool]$Preferences['remote_only'] }
        } elseif ($Preferences) {
            try { $reqRemote = [bool]$Preferences.remote_only } catch {}
        }
        
        if ($reqRemote -and -not $Vacancy.IsRemote) { return $true }
    }
    
    return $false
}

function Get-HeuristicScore {
    param(
        [Parameter(Mandatory)][object]$Vacancy,
        [object]$CVProfile, # { skill_set=[], min_salary=double, total_experience_months=int }
        [object]$Config,
        [object]$ExchangeRates
    )
    
    # Components
    $skillsObj   = Get-SkillsComponent -CvSkills $CVProfile.skill_set -VacSkills $Vacancy.KeySkills
    $skillsScore = [double]$skillsObj.Score
    
    $salaryScore = Get-SalaryComponent -Vacancy $Vacancy -UserMin $CVProfile.min_salary -BaseCurrency $Config.BaseCurrency -ExchangeRates $ExchangeRates
    $expScore    = Get-ExperienceComponent -Vacancy $Vacancy -CvMonths $CVProfile.total_experience_months
    $recScore    = Get-RecencyComponent -Vacancy $Vacancy -Tau $Config.RecencyTau
    
    # DEBUG
    # Write-Host "DEBUG: Scores: Sk=$skillsScore Sal=$salaryScore Exp=$expScore Rec=$recScore"
    # Write-Host "DEBUG: Weights: Sk=$($w.skills) Sal=$($w.salary) Exp=$($w.experience) Rec=$($w.recency)"
    
    # Total
    $w = $Config.Weights
    $total = ($w.skills * $skillsScore) + 
             ($w.salary * $salaryScore) + 
             ($w.experience * $expScore) + 
             ($w.recency * $recScore)
             
    # Clamp
    if ($total -gt 1.0) { $total = 1.0 }
    if ($total -lt 0.0) { $total = 0.0 }
    
    return [pscustomobject]@{
        cv        = $skillsScore # map skills to cv for compatibility/display
        skills    = $skillsScore
        salary    = $salaryScore
        seniority = $expScore
        recency   = $recScore
        local_llm = 0.0
        total     = $total
        skills_info = $skillsObj
    }
}

function Build-ScoreTip {
    param([object]$Scores)
    
    $fmt = "{0,-12}{1,6:0.00}"
    $rows = @()
    $rows += ($fmt -f 'навыки', $Scores.skills)
    $rows += ($fmt -f 'зарплата', $Scores.salary)
    $rows += ($fmt -f 'опыт', $Scores.seniority)
    $rows += ($fmt -f 'свежесть', $Scores.recency)

    return ($rows -join "`n")
}

# ==============================================================================
# Legacy / Pipeline Wrappers (kept for backward compatibility; migrate callers to
# Get-HeuristicScore + caller-owned mutation and remove these in a follow-up)
# ==============================================================================

function Calculate-Score {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Vacancy,
        [object]$CvSnapshot = $null,
        [object]$Context = $null,
        [hashtable]$ExchangeRates = @{ 'RUB' = 1.0 }
    )

    if (-not $Context) { $Context = Get-HHScoringConfig }

    # Adapt CvSnapshot to CVProfile
    $skillSet = @()
    if ($CvSnapshot) {
        if ($CvSnapshot.SkillSet) { $skillSet = $CvSnapshot.SkillSet }
        elseif ($CvSnapshot.KeySkills) { $skillSet = $CvSnapshot.KeySkills }
    }

    $minSal = 0
    if ($CvSnapshot -and $CvSnapshot.Salary -and $CvSnapshot.Salary.Amount) {
        $minSal = [double]$CvSnapshot.Salary.Amount
    }

    $expMonths = 0
    if ($CvSnapshot -and $CvSnapshot.TotalExperienceMonths) {
        $expMonths = [int]$CvSnapshot.TotalExperienceMonths
    }

    $cvProfile = [pscustomobject]@{
        skill_set = $skillSet
        min_salary = $minSal
        total_experience_months = $expMonths
    }

    $scores = Get-HeuristicScore -Vacancy $Vacancy -CVProfile $cvProfile -Config $Context -ExchangeRates $ExchangeRates

    $Vacancy.Score = $scores.total

    if ($scores.skills_info) {
        $si = $scores.skills_info
        $Vacancy.Skills.Score = [double]$si.Score
        $Vacancy.Skills.MatchedVacancy = [string[]]$si.Matched
        $Vacancy.Skills.InCV = [string[]]$si.InCV
    }

    if (-not $Vacancy.Meta) { $Vacancy.Meta = New-Object MetaInfo }
    if (-not $Vacancy.Meta.scores) { $Vacancy.Meta.scores = New-Object ScoreInfo }

    $Vacancy.Meta.scores.cv = $scores.cv
    $Vacancy.Meta.scores.skills = $scores.skills
    $Vacancy.Meta.scores.salary = $scores.salary
    $Vacancy.Meta.scores.recency = $scores.recency
    $Vacancy.Meta.scores.seniority = $scores.seniority
    $Vacancy.Meta.scores.local_llm = $scores.local_llm
    $Vacancy.Meta.scores.total = $scores.total

    $Vacancy.ScoreTip = Build-ScoreTip -Scores $scores

    return $scores.total
}

# Keep legacy utilities if needed by other modules (e.g. tests or render)
function Get-SeniorityClassification {
    param([object]$Vacancy)
    $lvl = 0; $label = ''

    $expId = if ($Vacancy.Experience) { $Vacancy.Experience.Id } else { '' }
    if (-not $expId -and $Vacancy.experience -and $Vacancy.experience.id) { $expId = $Vacancy.experience.id }

    switch ($expId) {
        'noExperience' { $lvl = 1; $label = 'Junior' }
        'between1And3' { $lvl = 2; $label = 'Middle' }
        'between3And6' { $lvl = 3; $label = 'Senior' }
        'moreThan6'    { $lvl = 4; $label = 'Lead' }
    }

    return [pscustomobject]@{ level = $lvl; label = $label }
}

function Get-HHCVSkills {
    if (Get-Command -Name 'hh.cv\Get-HHCVSkills' -ErrorAction SilentlyContinue) {
        return (hh.cv\Get-HHCVSkills)
    }
    return @()
}

function Get-SkillsVocab { return @{} }

Export-ModuleMember -Function Get-HHScoringConfig, Test-IsHardFiltered, Get-HeuristicScore, Calculate-Score, Build-ScoreTip, Get-SeniorityClassification, Get-HHCVSkills, Get-SkillsVocab
