# hh.strategy.psm1 — Executive Career Strategy analysis module
#Requires -Version 7.4

# Import dependencies if not loaded
if (-not (Get-Module -Name 'hh.models')) { Import-Module (Join-Path $PSScriptRoot 'hh.models.psm1') -ErrorAction SilentlyContinue }
if (-not (Get-Module -Name 'hh.config')) { Import-Module (Join-Path $PSScriptRoot 'hh.config.psm1') -ErrorAction SilentlyContinue }
if (-not (Get-Module -Name 'hh.llm')) { Import-Module (Join-Path $PSScriptRoot 'hh.llm.psm1') -ErrorAction SilentlyContinue }
if (-not (Get-Module -Name 'hh.llm.summary')) { Import-Module (Join-Path $PSScriptRoot 'hh.llm.summary.psm1') -ErrorAction SilentlyContinue }
if (-not (Get-Module -Name 'hh.fetch')) { Import-Module (Join-Path $PSScriptRoot 'hh.fetch.psm1') -ErrorAction SilentlyContinue }
if (-not (Get-Module -Name 'hh.cv')) { Import-Module (Join-Path $PSScriptRoot 'hh.cv.psm1') -ErrorAction SilentlyContinue }

function Invoke-HHCareerStrategy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VacancyId
    )

    # 1. Fetch Vacancy
    Write-Host "[Strategy] Fetching vacancy $VacancyId..." -ForegroundColor Cyan
    $vac = Get-VacancyDetail -Id $VacancyId
    if (-not $vac) { 
        Write-Error "Vacancy $VacancyId not found or could not be fetched."
        return
    }

    # Prepare Vacancy Context
    $vacTitle = $vac.name
    # Strip HTML for cleaner context
    $vacDesc = $vac.description -replace '<[^>]+>', ' ' -replace '\s+', ' '
    $vacEmp = $vac.employer.name
    
    $vacRes = ""
    $vacResp = ""
    if ($vac.snippet) {
        if ($vac.snippet.requirement) { $vacRes = $vac.snippet.requirement }
        if ($vac.snippet.responsibility) { $vacResp = $vac.snippet.responsibility }
    }
    
    $vacContext = @"
Title: $vacTitle
Employer: $vacEmp
Requirements Snippet: $vacRes
Responsibilities Snippet: $vacResp
Full Description: $vacDesc
"@

    # 2. Fetch Candidate Profile
    Write-Host "[Strategy] Fetching candidate profile..." -ForegroundColor Cyan
    $cv = Get-HHEffectiveProfile
    if (-not $cv.Enabled) {
        Write-Error "CV profile is disabled or missing. Check 'cv' section in config."
        return
    }
    
    # Build compact payload to get structured recent experience
    $cvConfig = Get-HHConfigValue -Path @('cv')
    $compactCv = Build-CompactCVPayload -Resume $cv -CvConfig $cvConfig
    
    $candTitle = $compactCv.cv_title
    $candSkills = ($compactCv.cv_skill_set -join ", ")
    $candExp = ""
    if ($compactCv.cv_recent_experience) {
        foreach ($job in $compactCv.cv_recent_experience) {
            $candExp += "Role: $($job.position) at $($job.employer) ($($job.period)).`nSummary: $($job.summary)`n`n"
        }
    }
    
    $candContext = @"
Title: $candTitle
Key Skills: $candSkills
Recent Experience:
$candExp
"@

    # 3. Language Detection & Prompt Selection
    $lang = 'en'
    if (Get-Command -Name Resolve-SummaryLanguage -ErrorAction SilentlyContinue) {
        $langInfo = Resolve-SummaryLanguage -Text ($vacTitle + " " + $vacDesc)
        if ($langInfo.Language) { $lang = $langInfo.Language }
    }
    Write-Host "[Strategy] Detected language: $lang" -ForegroundColor Gray

    $promptKey = 'strategy_analysis'
    if ($lang -eq 'ru') {
        $checkRu = Get-HHConfigValue -Path @('llm', 'prompts', 'strategy_analysis_ru')
        if ($checkRu) { $promptKey = 'strategy_analysis_ru' }
    }

    # 4. Prepare LLM Call
    $opName = 'strategy.analysis'
    $cfg = Resolve-LlmOperationConfig -Operation $opName
    if (-not $cfg.Ready) {
        Write-Error "LLM operation '$opName' is not configured or ready. Check 'llm.operations' in config."
        return
    }

    $sysPrompt = Get-HHConfigValue -Path @('llm', 'prompts', $promptKey, 'system')
    $userTemplate = Get-HHConfigValue -Path @('llm', 'prompts', $promptKey, 'user')
    
    if (-not $sysPrompt -or -not $userTemplate) {
        Write-Error "Prompts for '$promptKey' not found in config."
        return
    }

    # Inject context into template
    $userPrompt = $userTemplate.Replace('{{vacancy_context}}', $vacContext).Replace('{{candidate_profile}}', $candContext)

    Write-Host "[Strategy] Invoking LLM ($($cfg.Model))..." -ForegroundColor Cyan
    
    $response = LLM-InvokeText -Endpoint $cfg.Endpoint -ApiKey $cfg.ApiKey -Model $cfg.Model `
        -Messages @(@{role='system'; content=$sysPrompt}, @{role='user'; content=$userPrompt}) `
        -Temperature 0.4 -TimeoutSec 120 -OperationName $opName

    if ($response) {
        Write-Host "[Strategy] Analysis generated successfully." -ForegroundColor Green
        return $response
    }
    else {
        Write-Error "[Strategy] LLM returned empty response."
    }
}

Export-ModuleMember -Function Invoke-HHCareerStrategy
