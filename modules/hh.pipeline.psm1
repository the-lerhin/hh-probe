# hh.pipeline.psm1 — main processing pipeline
#Requires -Version 7.5

using module ./hh.models.psm1

if (-not (Get-Command -Name 'hh.util\Normalize-HHSummaryText' -ErrorAction SilentlyContinue)) {
    $utilPath = Join-Path $PSScriptRoot 'hh.util.psm1'
    if (Test-Path $utilPath) {
        Import-Module -Name $utilPath -DisableNameChecking -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Module -Name 'hh.llm')) {
    $llmPath = Join-Path $PSScriptRoot 'hh.llm.psm1'
    if (Test-Path $llmPath) {
        Import-Module -Name $llmPath -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

$script:HHLLM_PickLuckyCmd = Get-Command -Name 'LLM-PickLucky' -Module 'hh.llm' -ErrorAction SilentlyContinue
$script:HHLLM_PickWorstCmd = Get-Command -Name 'LLM-PickWorst' -Module 'hh.llm' -ErrorAction SilentlyContinue

# ==============================================================================
# Helpers
# ==============================================================================

function Get-HHSearchMode {
    param(
        [bool]$WhatIfSearch,
        [bool]$CvEnabled
    )
    if ($WhatIfSearch) { return 'ConfigKeywords' }
    if ($CvEnabled) { return 'ResumeSkills' }
    return 'ConfigKeywords'
}

function ConvertTo-HHSearchText {
    param(
        [string[]]$Keywords
    )
    if (-not $Keywords -or $Keywords.Count -eq 0) { return '' }
    return ($Keywords -join "`n")
}

function Get-BaseSet {
    <#
    .SYNOPSIS
    Computes BASE_SET size and selection based on config.

    .DESCRIPTION
    Sorts rows by Score descending, computes BASE_SIZE = max_display_rows × candidate_multiplier,
    and returns the top BASE_SIZE rows along with metadata.
    #>
    param(
        [Parameter(Mandatory = $true)][CanonicalVacancy[]]$Rows,
        [int]$MaxDisplayRows = 30,
        [double]$CandidateMultiplier = 1.5
    )

    $sorted = @()
    if ($Rows) { $sorted = $Rows | Sort-Object -Property Score -Descending }

    $baseSize = [int]([Math]::Ceiling($MaxDisplayRows * $CandidateMultiplier))
    $selectedCount = [Math]::Min($sorted.Count, $baseSize)
    $selected = @()
    if ($selectedCount -gt 0) {
        $selected = $sorted | Select-Object -First $selectedCount
    }

    return [pscustomobject]@{
        BaseSize  = $baseSize
        BaseCount = $selectedCount
        Items     = $selected
        Total     = $sorted.Count
    }
}

function Get-HHSourceLabelFromStage {
    param(
        [string]$Stage,
        [string[]]$Tiers
    )
    $effective = $Stage
    if (-not $effective -and $Tiers -and $Tiers.Count -gt 0) {
        $effective = $Tiers[0]
    }

    switch ($effective) {
        'web_recommendation' { return 'hh_web_recommendation' }
        'similar' { return 'hh_recommendation' }
        'recommendation' { return 'hh_recommendation' }
        'general' { return 'hh_general' }
        default { return 'hh' }
    }
}

function Get-CanonicalKeySkills {
    param([object]$Detail)
    if (-not $Detail -or -not $Detail.key_skills) { 
        return [pscustomobject]@{ List = @(); Text = '' }
    }
    
    $list = @()
    foreach ($s in $Detail.key_skills) {
        if ($s.name) { $list += $s.name }
    }
    return [pscustomobject]@{
        List = $list
        Text = ($list -join '|')
    }
}

function Build-BadgesPack {
    <#
    .SYNOPSIS
    Builds badges collection and text for a vacancy.
    
    .DESCRIPTION
    Aggregates remote badges into a list and space-joined string.
    Detects remote work from schedule.id, address.remote, and work_format fields.
    
    .PARAMETER Vacancy
    Vacancy object from HH API
    
    .OUTPUTS
    Hashtable with List (BadgeInfo[]) and Text (string) properties
    #>
    param([object]$Vacancy)
    
    $badges = @()
    $remoteDetected = $false
    
    try {
        # Check schedule.id for 'remote'
        $sid = ''
        if ($Vacancy.schedule) {
            try { $sid = [string]$Vacancy.schedule.id } catch {}
        }
        if ($sid -eq 'remote') { $remoteDetected = $true }
        
        # Check address.remote
        if ($Vacancy.address) {
            try {
                if ($Vacancy.address.remote) { $remoteDetected = $true }
            }
            catch {}
        }
        
        # Check work_format for remote keywords
        if ($Vacancy.work_format) {
            try {
                $wf = @($Vacancy.work_format)
                foreach ($w in $wf) {
                    $txt = [string]$w
                    if ($txt -match '(?i)remote|удал') { $remoteDetected = $true; break }
                }
            }
            catch {}
        }
        
        if ($remoteDetected) {
            $badges += ([BadgeInfo]@{ kind = 'remote'; label = 'remote' })
        }
    }
    catch {}
    
    $text = ''
    try {
        if ($badges -and $badges.Count -gt 0) {
            $text = (@($badges | ForEach-Object { [string]$_.label }) -join ' ')
        }
    }
    catch {}
    
    return @{ List = $badges; Text = $text }
}

function Build-CanonicalRowTyped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Vacancy,
        [switch]$NoDetail,
        [scriptblock]$ResolveDetail
    )
    
    Ensure-HHModelTypes
    
    $cv = New-Object CanonicalVacancy
    $cv.Id = [string]$Vacancy.id
    $cv.Title = [string]$Vacancy.name
    if ($Vacancy.alternate_url) { $cv.Url = $Vacancy.alternate_url }
    
    if ($Vacancy.published_at) {
        try { $cv.PublishedAt = [DateTime]::Parse($Vacancy.published_at).ToUniversalTime() } catch {}
    }
    
    $emp = New-Object EmployerInfo
    if ($Vacancy.employer) {
        $emp.Id = [string]$Vacancy.employer.id
        $emp.Name = [string]$Vacancy.employer.name
        if ($Vacancy.employer.url) { $emp.Url = $Vacancy.employer.url }
        if ($Vacancy.employer.logo_urls) {
            # Prefer 240 or original
            if ($Vacancy.employer.logo_urls.'240') { $emp.LogoUrl = $Vacancy.employer.logo_urls.'240' }
            elseif ($Vacancy.employer.logo_urls.original) { $emp.LogoUrl = $Vacancy.employer.logo_urls.original }
            elseif ($Vacancy.employer.logo_urls.'90') { $emp.LogoUrl = $Vacancy.employer.logo_urls.'90' }
        }
        $emp.Trusted = $Vacancy.employer.trusted -eq $true
        if ($Vacancy.employer.open_vacancies) { $emp.Open = [int]$Vacancy.employer.open_vacancies }
    }
    $cv.Employer = $emp
    $cv.EmployerId = $emp.Id
    $cv.EmployerName = $emp.Name
    if ($emp.logo_urls -and $emp.logo_urls.'90') { $cv.EmployerLogoUrl = [string]$emp.logo_urls.'90' }
    
    # FR-6.1: Do NOT populate EmployerRating from API ($emp.rating).
    # It must come strictly from legacy HTML scraping (Update-EmployerRating).
    $cv.EmployerRating = 0
    
    if ($emp.vacancies_url) {
        try { $cv.EmployerOpenVacancies = [int]$emp.open } catch {}
    }
    if ($Vacancy.employer -and $Vacancy.employer.industry) {
        try {
            $industryName = [string]($Vacancy.employer.industry.name ?? $Vacancy.employer.industry)
            if (-not [string]::IsNullOrWhiteSpace($industryName)) {
                $cv.EmployerIndustryShort = $industryName
            }
        }
        catch {}
    }
    
    if ($Vacancy.salary) {
        $sal = New-Object SalaryInfo
        if ($Vacancy.salary.from) { $sal.From = [int]$Vacancy.salary.from }
        if ($Vacancy.salary.to) { $sal.To = [int]$Vacancy.salary.to }
        if ($Vacancy.salary.currency) { $sal.Currency = $Vacancy.salary.currency }
        $sal.Gross = $Vacancy.salary.gross -eq $true
        
        # Calculate UpperCap for sorting/ranking
        if ($sal.To -gt 0) { $sal.UpperCap = $sal.To }
        elseif ($sal.From -gt 0) { $sal.UpperCap = $sal.From }

        # Construct text representation
        $parts = @()
        if ($sal.From) { $parts += "ot $($sal.From)" }
        if ($sal.To) { $parts += "do $($sal.To)" }
        if ($sal.Currency) { $parts += $sal.Currency }
        $sal.Text = $parts -join ' '
        
        $cv.Salary = $sal
    }
    
    if ($Vacancy.area) {
        $cv.AreaId = [string]$Vacancy.area.id
        $cv.AreaName = [string]$Vacancy.area.name
        $cv.City = [string]$Vacancy.area.name
        if (Get-Command -Name Resolve-HHAreaCountry -ErrorAction SilentlyContinue) {
            try {
                $countryName = Resolve-HHAreaCountry -AreaId ([string]$Vacancy.area.id)
                if (-not [string]::IsNullOrWhiteSpace($countryName)) {
                    $cv.Country = $countryName
                    $cv.country = $countryName
                }
            }
            catch {}
        }
    }
    
    # Build badges
    try {
        $badgePack = Build-BadgesPack -Vacancy $Vacancy
        $cv.badges = @($badgePack.List)
        $cv.badges_text = [string]$badgePack.Text
        $cv.IsRemote = ($badgePack.List | Where-Object { $_.kind -eq 'remote' }).Count -gt 0
    }
    catch {
        $cv.badges = @()
        $cv.badges_text = ''
        $cv.IsRemote = $false
    }
    
    $meta = New-Object MetaInfo
    $stage = ''
    if ($Vacancy.search_stage) {
        $stage = $Vacancy.search_stage
    }
    elseif ($Vacancy.search_tiers -and $Vacancy.search_tiers.Count -gt 0) {
        $stage = $Vacancy.search_tiers[0]
    }

    switch ($stage) {
        'web_recommendation' { $meta.Source = 'hh_web_recommendation' }
        'similar' { $meta.Source = 'hh_recommendation' }
        'recommendation' { $meta.Source = 'hh_recommendation' }
        'general' { $meta.Source = 'hh_general' }
        default { $meta.Source = 'hh' }
    }
    $meta.search_stage = $stage
    $cv.SearchStage = $stage
    if ($Vacancy.search_tiers) {
        $cv.SearchTiers = $Vacancy.search_tiers
    }
    
    # Snippet/Description
    if ($Vacancy.snippet) {
        $desc = ""
        if ($Vacancy.snippet.requirement) { $desc += $Vacancy.snippet.requirement + " " }
        if ($Vacancy.snippet.responsibility) { $desc += $Vacancy.snippet.responsibility }
        $cv.Description = $desc.Trim()
    }
    
    # Detailed Info (optional)
    if (-not $NoDetail) {
        $detail = $null
        if ($ResolveDetail) {
            $detail = & $ResolveDetail -id $Vacancy.id
        }
        else {
            if (Get-Command -Name Get-EmployerDetail -ErrorAction SilentlyContinue) {
                # This is actually fetching vacancy detail, function name in tests was generic
                # We use Get-HHVacancyDetail logic here if needed, but usually it's separate
                # For now, we'll assume simple fetch if Get-HHVacancyDetail exists
                # Actually, let's look at tests, it mocks Get-EmployerDetail but that's for employer?
                # Tests use -ResolveDetail param.
            }
        }
        
        if ($detail) {
            if ($detail.description) { $cv.Description = $detail.description }
            if ($detail.key_skills) {
                $ks = Get-CanonicalKeySkills -Detail $detail
                $meta.Raw = @{ key_skills = $detail.key_skills }
                $cv.KeySkills = $ks.List
            }
            
            # Map Employer Metadata
            if ($detail.employer) {
                # Industry
                if ($detail.employer.industries -and $detail.employer.industries.Count -gt 0) {
                    $cv.EmployerIndustryShort = $detail.employer.industries[0].name
                }
                
                # Open Vacancies (if available in detail, sometimes it's not, but let's check)
                if ($detail.employer.open_vacancies) {
                    $cv.EmployerOpenVacancies = [int]$detail.employer.open_vacancies
                }
            }
            
            # Scrape Rating if needed
            if ($cv.Employer.Id -and (Get-Command -Name Update-EmployerRating -ErrorAction SilentlyContinue)) {
                Update-EmployerRating -Vacancy $cv
            }
        }
    }
    
    $cv.Meta = $meta
    
    # Summary metadata population
    $summaryResult = $null
    $publishedUtc = $cv.PublishedAtUtc
    if (-not $publishedUtc -and $Vacancy.published_at) {
        try { $publishedUtc = [DateTime]::Parse($Vacancy.published_at).ToUniversalTime() } catch {}
    }
    if (-not $publishedUtc) { $publishedUtc = (Get-Date).ToUniversalTime() }
    $summaryCmd = (Get-Command -Name 'hh.util\Get-HHCanonicalSummaryEx' -ErrorAction SilentlyContinue)
    if ($summaryCmd) {
        try {
            $summaryResult = & $summaryCmd -Vacancy $Vacancy -VacancyId $cv.Id -PublishedUtc $publishedUtc -LLMMap $null
        }
        catch {}
    }
    elseif (Get-Command -Name 'Get-HHCanonicalSummaryEx' -ErrorAction SilentlyContinue) {
        try {
            $summaryResult = Get-HHCanonicalSummaryEx -Vacancy $Vacancy -VacancyId $cv.Id -PublishedUtc $publishedUtc -LLMMap $null
        }
        catch {}
    }

    if ($summaryResult) {
        $cleanSummary = hh.util\Normalize-HHSummaryText -Text ([string]($summaryResult.text ?? ''))
        $sourceNormalized = hh.util\Normalize-HHSummarySource -Source $summaryResult.source -Fallback 'local'
        try { $cv.Meta.summary.text = $cleanSummary } catch {}
        try { $cv.Meta.summary.lang = [string]($summaryResult.lang ?? '') } catch {}
        try { $cv.Meta.summary.model = [string]($summaryResult.model ?? '') } catch {}
        try { $cv.Meta.summary.source = $sourceNormalized } catch {}
        try { $cv.Meta.summary_source = $sourceNormalized } catch {}
        try { if (-not [string]::IsNullOrWhiteSpace([string]$summaryResult.model)) { $cv.Meta.summary_model = [string]$summaryResult.model } } catch {}
        try { $cv.Summary = $cleanSummary } catch {}
    }

    return $cv
}

function Build-CanonicalFromGetmatchVacancy {
    param(
        [Parameter(Mandatory = $true)][object]$RawItem
    )
  
    Ensure-HHModelTypes
  
    $id = "gm_" + (Get-Random)
    try {
        if ($RawItem.Url) {
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($RawItem.Url)
            $hash = $md5.ComputeHash($bytes)
            $id = "gm_" + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 12).ToLower())
        }
    }
    catch {}

    $cv = New-Object CanonicalVacancy
    $cv.Id = $id
    $cv.Title = $RawItem.Title
    $cv.Url = $RawItem.Url
    $cv.PublishedAtUtc = (Get-Date).ToUniversalTime() 
  
    if ($RawItem.PostedAtText) {
        try { $cv.PublishedAtUtc = [DateTime]::Parse($RawItem.PostedAtText).ToUniversalTime() } catch {}
    }

    $emp = New-Object EmployerInfo
    $emp.Name = if ($RawItem.EmployerName) { $RawItem.EmployerName } else { "Getmatch Employer" }
    $cv.Employer = $emp

    # Salary
    if ($RawItem.RawObject -and ($RawItem.RawObject.salary_display_from -or $RawItem.RawObject.salary_display_to)) {
        $sal = New-Object SalaryInfo
        if ($RawItem.RawObject.salary_display_from) { $sal.From = [double]$RawItem.RawObject.salary_display_from }
        if ($RawItem.RawObject.salary_display_to) { $sal.To = [double]$RawItem.RawObject.salary_display_to }
        if ($RawItem.RawObject.salary_currency) { $sal.Currency = $RawItem.RawObject.salary_currency }
        $sal.Text = $RawItem.SalaryText
        $cv.Salary = $sal
    }
    elseif ($RawItem.SalaryText) {
        $sal = New-Object SalaryInfo
        $sal.Text = $RawItem.SalaryText
        $cv.Salary = $sal
    }

    $cv.city = if ($RawItem.LocationText) { $RawItem.LocationText } else { "Unknown" }
    $cv.AreaName = $cv.city
  
    # Remote / Relocation flags
    if ($RawItem.RawObject) {
        if ($RawItem.RawObject.remote_options -in 'anywhere', 'full') { $cv.IsRemote = $true }
        if ($RawItem.RawObject.relocation_options) { $cv.IsRelocation = $true }
      
        # Country check
        if ($RawItem.RawObject.display_locations) {
            foreach ($l in $RawItem.RawObject.display_locations) {
                if ($l.country -and $l.country -ne 'Россия') { $cv.IsNonRuCountry = $true }
            }
        }
    }
    elseif ($RawItem.LocationText) {
        if ($RawItem.LocationText -match 'Remote|Удаленно') { $cv.IsRemote = $true }
        if ($RawItem.LocationText -match 'Relocate|Переезд') { $cv.IsRelocation = $true }
    }

    $meta = New-Object MetaInfo
    $meta.Source = 'getmatch'
    $cv.Meta = $meta
  
    if ($RawItem.search_tiers) {
        $cv.SearchTiers = $RawItem.search_tiers
    }
  
    if ($RawItem.Description) {
        $cv.Description = $RawItem.Description
    }
    else {
        $cv.Description = $RawItem.RawContext
    }
  
    if ($RawItem.Skills) {
        $cv.KeySkills = $RawItem.Skills
        $meta.Raw = @{ key_skills = $RawItem.Skills }
    }

    # Basic scoring placeholder
    $cv.Score = 0.5 # Default middle score

    return $cv
}

function Invoke-EditorsChoice {
    param(
        [Parameter(Mandatory = $true)][CanonicalVacancy[]]$Rows,
        [string[]]$CvSkills = @()
    )
    
    # Ensure LLM module loaded
    if (-not (Get-Command -Name LLM-EditorsChoicePick -ErrorAction SilentlyContinue)) {
        if (Get-Module -Name 'hh.llm') { Import-Module -Name 'hh.llm' -Force }
        else {
            $llmPath = Join-Path $PSScriptRoot 'hh.llm.psm1'
            if (Test-Path $llmPath) { Import-Module $llmPath -DisableNameChecking }
        }
        if (-not (Get-Command -Name LLM-EditorsChoicePick -ErrorAction SilentlyContinue)) { return $null }
    }
    
    # Resolve Config
    $endpoint = $null
    $apiKey = $null
    $model = $null
    
    if (-not (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
        if (Get-Module -Name 'hh.config') { Import-Module -Name 'hh.config' -Force }
        else {
            $cfgPath = Join-Path $PSScriptRoot 'hh.config.psm1'
            if (Test-Path $cfgPath) { Import-Module $cfgPath -DisableNameChecking }
        }
    }
    
    # Router: Editors Choice
    $cfg = Resolve-LlmOperationConfig -Operation 'picks.ec_why'
    if (-not $cfg.Ready) { return $null }
    
    $endpoint = $cfg.Endpoint
    $apiKey = $cfg.ApiKey
    $model = $cfg.Model

    # Prepare items for LLM (limit to top 30 to save tokens)
    $candidates = $Rows | Select-Object -First 30
    
    $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.2 }
    $pick = LLM-EditorsChoicePick -Items $candidates -CvText ($CvSkills -join ", ") -Endpoint $endpoint -ApiKey $apiKey -Model $model -Temperature $temperature -TimeoutSec $cfg.TimeoutSec -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'picks.ec_why'
    return $pick
}

function Apply-Picks {
    param(
        [Parameter(Mandatory = $true)][CanonicalVacancy[]]$Rows,
        [bool]$LLMEnabled = $true,
        [hashtable]$CvPayload = $null
    )
    
    if (-not $Rows -or $Rows.Count -eq 0) { return $Rows }

    # Prepare for picks
    $cvSkills = @()
    if ($CvPayload -and $CvPayload.ContainsKey('cv_skill_set')) {
        try { $cvSkills = @($CvPayload['cv_skill_set'] | Where-Object { $_ }) } catch {}
    }

    # Helper to init Picks object if missing
    $ensurePicks = {
        param($Row)
        if (-not $Row.Picks) { $Row.Picks = [PicksInfo]::new() }
    }
    
    # 1. Editor's Choice
    $ecDone = $false
    if ($LLMEnabled) {
        $ecPick = Invoke-EditorsChoice -Rows $Rows -CvSkills $cvSkills
        
        if ($ecPick -and $ecPick.id) {
            $r = $Rows | Where-Object { $_.Id -eq $ecPick.id } | Select-Object -First 1
            if ($r) {
                # Determine 'why' text
                $whyText = ''
                if ($ecPick.why) { $whyText = $ecPick.why }
                elseif ($ecPick.reason) { $whyText = $ecPick.reason }
                
                # Set Canonical Properties
                $r.IsEditorsChoice = $true
                $r.EditorsWhy = if ($whyText) { $whyText } else { '' }
                
                # Set Nested Picks Properties
                & $ensurePicks -Row $r
                $r.Picks.IsEditorsChoice = $true
                $r.Picks.EditorsWhy = if ($whyText) { $whyText } else { '' }
                
                $ecDone = $true
            }
        }
    }
    
    # 2. Lucky
    # Only if LLM is enabled (user requirement: "No EC/Lucky in LLM-off mode")
    if ($LLMEnabled) {
        $luckyIdx = -1
        # Use remote random if available
        if (Get-Command -Name Get-TrueRandomIndex -ErrorAction SilentlyContinue) {
            try { $luckyIdx = Get-TrueRandomIndex -MaxExclusive $Rows.Count } catch { $luckyIdx = -1 }
        }
        
        if ($luckyIdx -ge 0 -and $luckyIdx -lt $Rows.Count) {
            $r = $Rows[$luckyIdx]
            # Ensure we don't pick the same row as EC or (future) Worst, although Worst isn't picked yet.
            if (-not $r.IsEditorsChoice -and -not $r.Picks?.IsEditorsChoice) {
                # Ensure LLM-PickLucky is available
                if (-not (Get-Command -Name LLM-PickLucky -ErrorAction SilentlyContinue)) {
                    if (Get-Module -Name 'hh.llm') { Import-Module -Name 'hh.llm' -Force }
                    else {
                        $llmPath = Join-Path $PSScriptRoot 'hh.llm.psm1'
                        if (Test-Path $llmPath) { Import-Module $llmPath -DisableNameChecking }
                    }
                }

                $luckyPick = $null
                if (Get-Command -Name LLM-PickLucky -ErrorAction SilentlyContinue) {
                    $luckyPick = LLM-PickLucky -Items @($r)
                }

                if ($luckyPick) {
                    # Determine 'why' text
                    $luckyWhy = ''
                    if ($luckyPick.why) { $luckyWhy = $luckyPick.why }
                    elseif ($luckyPick.reason) { $luckyWhy = $luckyPick.reason }
                    
                    # Set Canonical Properties
                    $r.IsLucky = $true
                    $r.LuckyWhy = if ($luckyWhy) { $luckyWhy } else { '' }
                    
                    # Set Nested Picks Properties
                    & $ensurePicks -Row $r
                    $r.Picks.IsLucky = $true
                    $r.Picks.LuckyWhy = if ($luckyWhy) { $luckyWhy } else { '' }
                }
            }
        }
    }

    # 3. Worst
    $worstDone = $false
    if ($LLMEnabled) {
        # Ensure LLM-PickWorst is available
        if (-not (Get-Command -Name LLM-PickWorst -ErrorAction SilentlyContinue)) {
            if (Get-Module -Name 'hh.llm') { Import-Module -Name 'hh.llm' -Force }
            else {
                $llmPath = Join-Path $PSScriptRoot 'hh.llm.psm1'
                if (Test-Path $llmPath) { Import-Module $llmPath -DisableNameChecking }
            }
        }
        
        $worstPick = $null
        if (Get-Command -Name LLM-PickWorst -ErrorAction SilentlyContinue) {
            $worstPick = LLM-PickWorst -Items $Rows
        }
        if ($worstPick -and $worstPick.id) {
            $r = $Rows | Where-Object { $_.Id -eq $worstPick.id } | Select-Object -First 1
            if ($r) {
                # Determine 'why' text
                $worstWhy = ''
                if ($worstPick.why) { $worstWhy = $worstPick.why }
                elseif ($worstPick.reason) { $worstWhy = $worstPick.reason }

                # Set Canonical
                $r.IsWorst = $true
                $r.WorstWhy = if ($worstWhy) { $worstWhy } else { '' }
                
                # Set Nested
                & $ensurePicks -Row $r
                $r.Picks.IsWorst = $true
                $r.Picks.WorstWhy = if ($worstWhy) { $worstWhy } else { '' }
                
                $worstDone = $true
            }
        }
    }
    
    # Fallback for Worst (Deterministic: Lowest Score)
    # Applies if LLM disabled OR if LLM failed to pick a worst vacancy
    if (-not $worstDone) {
        $worst = $Rows | Sort-Object Score | Select-Object -First 1
        if ($worst) {
            # Set Canonical
            $worst.IsWorst = $true
            $worst.WorstWhy = '' # Empty why
            
            # Set Nested
            & $ensurePicks -Row $worst
            $worst.Picks.IsWorst = $true
            $worst.Picks.WorstWhy = '' # Empty why
        }
    }
    
    return $Rows
}

function Test-HHPipelineHealth {
    [CmdletBinding()]
    param()
    
    $status = [ordered]@{
        Modules  = @{}
        Config   = @{ Valid = $false; Issues = @() }
        Services = @{ LLM = $false; Cache = $false }
    }
    
    # Check Modules
    foreach ($m in @('hh.config', 'hh.models', 'hh.fetch', 'hh.llm', 'hh.cache', 'hh.render')) {
        $status.Modules[$m] = [bool](Get-Module -Name $m)
    }
    
    # Check Config
    if (Get-Command -Name 'Get-HHConfigValue' -ErrorAction SilentlyContinue) {
        $status.Config.Valid = $true
    }
    else {
        $status.Config.Issues += "Get-HHConfigValue not found"
    }
    
    # Check Services
    if (Get-Command -Name 'Get-LiteDbReady' -ErrorAction SilentlyContinue) {
        $status.Services.Cache = Get-LiteDbReady
    }
    
    return [PSCustomObject]$status
}

# ==============================================================================
# Main Pipeline Orchestrator
# ==============================================================================

function Get-HHProbeVacancies {
    [CmdletBinding()]
    param(
        [string]$SearchText,
        [int]$VacancyPerPage,
        [int]$VacancyPages,
        [string]$ResumeId,
        [hashtable]$SearchFilters,
        [bool]$RecommendEnabled,
        [int]$RecommendPerPage,
        [int]$RecommendTopTake
    )

    # 1. Fetch Vacancies (HH)
    Write-Host "[Pipeline] Fetching HH vacancies..." -ForegroundColor Cyan
    Write-Host "[Pipeline] SearchText: '$SearchText' ResumeId: '$ResumeId'" -ForegroundColor Gray
    $hhResult = Get-HHHybridVacancies -ResumeId $ResumeId -QueryText $SearchText -Limit ($VacancyPerPage * $VacancyPages) -Config @{
        PerPage          = $VacancyPerPage
        RecommendEnabled = $RecommendEnabled
        RecommendPerPage = $RecommendPerPage
        Filters          = $SearchFilters
    }
    $hhItems = @()
    if ($hhResult.Items) { $hhItems = $hhResult.Items }
    Write-Host "[Pipeline] Fetched $($hhItems.Count) vacancies from HH"

    # 2. Fetch Vacancies (Getmatch)
    $gmItems = @()
    $getmatchConfig = Get-HHConfigValue -Path 'getmatch'
    
    $gmEnabled = $false
    if ($getmatchConfig) {
        if ($getmatchConfig -is [System.Collections.IDictionary]) { $gmEnabled = [bool]$getmatchConfig['enabled'] }
        elseif ($getmatchConfig.PSObject.Properties['enabled']) { $gmEnabled = [bool]$getmatchConfig.enabled }
    }
    
    if ($gmEnabled) {
        Write-Host "[Pipeline] Fetching Getmatch vacancies..." -ForegroundColor Cyan
        
        # Convert to hashtable if needed
        $gmCfgHash = @{}
        if ($getmatchConfig -is [System.Collections.IDictionary]) {
            $gmCfgHash = $getmatchConfig
        }
        else {
            foreach ($prop in $getmatchConfig.PSObject.Properties) {
                $gmCfgHash[$prop.Name] = $prop.Value
            }
        }
        
        # Call helper from hh.fetch
        if (Get-Command -Name 'Get-GetmatchVacanciesRaw' -ErrorAction SilentlyContinue) {
            $gmItems = Get-GetmatchVacanciesRaw -GetmatchConfig $gmCfgHash
        }
        Write-Host "[Pipeline] Fetched $($gmItems.Count) vacancies from Getmatch"
    }

    return @($hhItems + $gmItems)
}

function Invoke-HHProbeMain {
    param(
        $SearchText,
        $VacancyKeyword,
        $VacancyPerPage,
        $VacancyPages,
        $ResumeId,
        $WindowDays,
        $RecommendEnabled,
        $RecommendPerPage,
        $RecommendTopTake,
        $LLMEnabled,
        $LLMPickTopN,
        $LlmGateScoreMin,
        $SummaryTopN,
        $SummaryForPicks,
        $ReportStats,
        $Digest,
        $Ping,
        $NotifyDryRun,
        $NotifyStrict,
        $ReportUrl,
        $RunStartedLocal,
        $LearnSkills,
        $OutputsRoot,
        $RepoRoot,
        $PipelineState,
        $DebugMode
    )

    # 1. Initialize State
    if (-not $PipelineState) {
        $PipelineState = New-HHPipelineState -StartedLocal $RunStartedLocal -StartedUtc ($RunStartedLocal.ToUniversalTime()) -Flags @{
            Digest = $Digest
            Ping   = $Ping
            LLM    = $LLMEnabled
            Debug  = $DebugMode
        }
    }
    $llmModulePath = Join-Path $RepoRoot 'modules/hh.llm.psm1'
    if (-not (Get-Module -Name 'hh.llm')) {
        if (Test-Path $llmModulePath) { Import-Module $llmModulePath -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    if (Get-Command -Name Set-LlmUsagePipelineState -ErrorAction SilentlyContinue) {
        Set-LlmUsagePipelineState -State $PipelineState
    }
    
    # 2. Fetch All Vacancies (Unified)
    # Build filters
    $filters = @{}
    # (We could pass specific filters here if we had them separate from config, but hh.fetch handles config reading)
    
    $allRawItems = Get-HHProbeVacancies -SearchText $SearchText `
        -VacancyPerPage $VacancyPerPage `
        -VacancyPages $VacancyPages `
        -ResumeId $ResumeId `
        -SearchFilters $filters `
        -RecommendEnabled $RecommendEnabled `
        -RecommendPerPage $RecommendPerPage `
        -RecommendTopTake $RecommendTopTake
    
    # 3. Canonicalization & Merging
    $allRows = @()
    $tempRows = @()
    
    foreach ($item in $allRawItems) {
        $c = $null
        # Dispatch based on Source or Shape
        if ($item.Source -eq 'getmatch') {
            $c = Build-CanonicalFromGetmatchVacancy -RawItem $item
        }
        else {
            # Assume HH
            $c = Build-CanonicalRowTyped -Vacancy $item
        }
        
        if ($c -is [CanonicalVacancy]) {
            $tempRows += $c
        }
        elseif ($c) {
            Write-Warning "[Pipeline] Skipping non-typed canonical row for item $($item.id ?? 'unknown')"
        }
    }
    
    foreach ($row in $tempRows) {
        if (-not $row -or -not $row.Meta) { continue }
        if ($row.Meta.Source -eq 'getmatch') { continue }
        $label = Get-HHSourceLabelFromStage -Stage $row.SearchStage -Tiers $row.SearchTiers
        $row.Meta.Source = $label
    }
    
    # Dedup
    $seenUrls = @{}
    $countHH = 0
    $countGM = 0
    
    # Pass 1: Add HH rows first (priority)
    foreach ($r in $tempRows) {
        if ($r.Meta.Source -ne 'getmatch') {
            $u = $r.Url
            if (-not $u) { $u = "id:" + $r.Id }
             
            if (-not $seenUrls.ContainsKey($u)) {
                $seenUrls[$u] = $true
                $allRows += $r
                $countHH++
            }
        }
    }
    
    # Pass 2: Add Getmatch rows if URL not seen
    foreach ($r in $tempRows) {
        if ($r.Meta.Source -eq 'getmatch') {
            $u = $r.Url
            if (-not $u) { $u = "id:" + $r.Id }
             
            if (-not $seenUrls.ContainsKey($u)) {
                $seenUrls[$u] = $true
                $allRows += $r
                $countGM++
            }
        }
    }
    
    Write-Host "[Search] canonical rows before dedup: $($tempRows.Count)"
    Write-Host "[Search] canonical rows after dedup:  $($allRows.Count) (HH: $countHH, GM: $countGM)"
    
    Add-HHPipelineStat -State $PipelineState -Path @('Search', 'ItemsFetched') -Value $allRows.Count

    # 3.1 Pre-enrichment for Synthetic Items (Web Recommendations)
    # We must enrich these BEFORE scoring, otherwise they have 0 score and get dropped from BASE_SET.
    Write-Host "[Pipeline] Stage 3.1: Pre-enriching synthetic items..." -ForegroundColor Cyan
    
    # Ensure fetch module is available for enrichment
    if (-not (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -Name 'hh.fetch')) {
            $fetchPath = Join-Path $RepoRoot 'modules/hh.fetch.psm1'
            if (Test-Path $fetchPath) { Import-Module $fetchPath -DisableNameChecking -ErrorAction SilentlyContinue }
        }
    }

    $syntheticEnriched = 0
    foreach ($row in $allRows) {
        # Guard: Only enrich HH web recommendations that are synthetic
        $isHh = ($row.Meta.Source -eq 'hh' -or $row.Meta.Source -eq 'hh_web_recommendation')
        $isWebRec = ($row.SearchTiers -contains 'web_recommendation')
        $isSynthetic = ($row.PSObject.Properties['needs_enrichment'] -and $row.needs_enrichment) -or ($row.Title -like "WebSearch Vacancy*") -or (-not $row.EmployerId)
        
        if ($isHh -and $isWebRec -and $isSynthetic) {
            # Guard: Numeric ID only
            if ($row.Id -notmatch '^\d+$') {
                Write-Warning "[Pipeline] Skipping synthetic enrichment for non-numeric ID: $($row.Id)"
                continue
            }

            try {
                if (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue) {
                    $detail = Get-VacancyDetail -Id $row.Id
                    if ($detail) {
                        $fresh = Build-CanonicalRowTyped -Vacancy $detail -NoDetail
                        
                        # Copy core fields (Title, Employer, Salary, Area, etc.)
                        $row.Title = $fresh.Title
                        $row.Employer = $fresh.Employer
                        $row.EmployerId = $fresh.EmployerId
                        $row.EmployerName = $fresh.EmployerName
                        $row.EmployerLogoUrl = $fresh.EmployerLogoUrl
                        $row.EmployerRating = $fresh.EmployerRating
                        $row.EmployerOpenVacancies = $fresh.EmployerOpenVacancies
                        $row.EmployerIndustryShort = $fresh.EmployerIndustryShort
                        
                        $row.Salary = $fresh.Salary
                        
                        $row.AreaId = $fresh.AreaId
                        $row.AreaName = $fresh.AreaName
                        $row.City = $fresh.City
                        $row.Country = $fresh.Country
                        $row.country = $fresh.country
                        
                        $row.PublishedAt = $fresh.PublishedAt
                        $row.Url = $fresh.Url
                        $row.Description = $fresh.Description
                        $row.KeySkills = $fresh.KeySkills
                        
                        # Remove the synthetic flag
                        if ($row.PSObject.Properties['needs_enrichment']) {
                            $row.needs_enrichment = $false
                        }

                        if (Get-Command -Name Get-PlainDesc -ErrorAction SilentlyContinue) {
                            $row.Meta.plain_desc = Get-PlainDesc -Text $fresh.Description
                        }
                        
                        $syntheticEnriched++
                        Write-Host "[Debug] Pre-enriched synthetic item $($row.Id) ($($row.Title))" -ForegroundColor Green
                    }
                    else {
                        Write-Warning "[Pipeline] Failed to fetch details for synthetic item $($row.Id)"
                    }
                }
                else {
                    Write-Warning "[Pipeline] Get-VacancyDetail command not found, cannot enrich synthetic item $($row.Id)"
                }
            }
            catch {
                Write-Warning "Failed to pre-enrich synthetic item $($row.Id): $_"
            }
        }
    }
    Write-Host "[Pipeline] Pre-enriched $syntheticEnriched synthetic items" -ForegroundColor Cyan

    # 4. Scoring (Baseline)
    Write-Host "[Pipeline] Scoring $($allRows.Count) candidates (Baseline)..." -ForegroundColor Cyan
    
    # Ensure scoring module loaded
    if (-not (Get-Command -Name Calculate-Score -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -Name 'hh.scoring')) {
            if (Test-Path "$RepoRoot/modules/hh.scoring.psm1") { Import-Module "$RepoRoot/modules/hh.scoring.psm1" }
        }
    }

    # Load CV Snapshot for scoring and later stages
    $cvSnapshot = $null
    if (Get-Command -Name Get-HHCVSnapshotOrSkills -ErrorAction SilentlyContinue) {
        $cvSnapshot = Get-HHCVSnapshotOrSkills
    }
    $compactCvPayload = $null
    if ($cvSnapshot -and (Get-Command -Name Build-CompactCVPayload -ErrorAction SilentlyContinue)) {
        $cvConfig = $null
        try { $cvConfig = Get-HHConfigValue -Path @('cv') } catch {}
        try {
            $compact = Build-CompactCVPayload -Resume $cvSnapshot -CvConfig $cvConfig
            if ($compact) {
                $compactCvPayload = $compact
                Set-HHPipelineValue -State $PipelineState -Path @('CompactCVPayload') -Value $compact
                if (Get-Command -Name Write-LogPipeline -ErrorAction SilentlyContinue) {
                    Write-LogPipeline ("[CV] Compact payload built once; skills={0}; experience={1}" -f ($compact.cv_skill_set.Count), ($compact.cv_recent_experience.Count)) -Level Verbose
                }
            }
        }
        catch {}
    }
    
    # 4.1 Local LLM Relevance (for ALL rows, if enabled)
    # Attempt to load Local LLM module if available
    if (-not (Get-Module -Name 'hh.llm.local')) {
        $localPath = Join-Path $RepoRoot 'modules/hh.llm.local.psm1'
        if (Test-Path $localPath) { Import-Module $localPath -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    
    if (Get-Command -Name Invoke-LocalLLMRelevance -ErrorAction SilentlyContinue) {
        Write-Host "[Pipeline] Calculating Local LLM Relevance for $($allRows.Count) candidates..." -ForegroundColor Cyan
        $hint = "Candidate"
        if ($cvSnapshot -and $cvSnapshot.Title) { $hint = $cvSnapshot.Title }
        elseif ($cvSnapshot -and $cvSnapshot.KeySkills) { $hint = ($cvSnapshot.KeySkills -join ", ") }
        
        $counter = 0
        foreach ($row in $allRows) {
            $counter++
            if ($counter % 10 -eq 0) { Write-Progress -Activity "Local LLM Scoring" -Status "$counter / $($allRows.Count)" -PercentComplete (($counter / $allRows.Count) * 100) }
            
            $desc = if ($row.Description) { $row.Description } else { $row.Title }
            # Strip HTML for cleaner prompt
            $desc = $desc -replace '<[^>]+>', ' '
            
            try {
                $rel = 0
                $cacheKey = "locrel_" + $row.Id + "_" + $hint.GetHashCode()
                $cachedRel = $null
                    
                if (Get-Command -Name Get-HHCacheItem -ErrorAction SilentlyContinue) {
                    try { $cachedRel = Get-HHCacheItem -Collection 'llm_relevance' -Key $cacheKey } catch {}
                }
                    
                if ($cachedRel -ne $null) {
                    $rel = [double]$cachedRel
                }
                else {
                    $rel = Invoke-LocalLLMRelevance -VacancyText $desc -ProfileHint $hint
                    if (Get-Command -Name Set-HHCacheItem -ErrorAction SilentlyContinue) {
                        try { Set-HHCacheItem -Collection 'llm_relevance' -Key $cacheKey -Value $rel } catch {}
                    }
                }
                    
                if ($rel -gt 0) {
                    if (-not $row.Meta) { $row.Meta = New-Object MetaInfo }
                    $row.Meta.local_llm_relevance = $rel
                }
            }
            catch {
                Write-Warning "Local LLM failed for $($row.Id): $_"
            }
        }
        Write-Progress -Activity "Local LLM Scoring" -Completed
    }
    
    foreach ($row in $allRows) {
        # Calculate baseline score
        if (Get-Command -Name Calculate-Score -ErrorAction SilentlyContinue) {
            Calculate-Score -Vacancy $row -CvSnapshot $cvSnapshot
        }
        # Store baseline in ranking meta
        $row.Meta.ranking.BaselineScore = $row.Score
        $row.Meta.ranking.FinalScore = $row.Score # Init final with baseline
    }
    
    # 5. Ranking V3 Pipeline
    # Read Config
    $displayRows = 30
    try { $displayRows = [int](Get-HHConfigValue -Path @('report', 'max_display_rows') -Default 30) } catch {}
    
    $candidateMult = 1.5
    try { $candidateMult = [double](Get-HHConfigValue -Path @('ranking', 'candidate_multiplier') -Default 1.5) } catch {}
    
    # Candidate Selection (Stage 1) / BASE_SET scaffolding
    $baseSetInfo = Get-BaseSet -Rows $allRows -MaxDisplayRows $displayRows -CandidateMultiplier $candidateMult
    $candidateRows = @($baseSetInfo.Items)
    $candidateCount = $candidateRows.Count
    Set-HHPipelineValue -State $PipelineState -Path @('BaseSize') -Value $baseSetInfo.BaseSize
    Set-HHPipelineValue -State $PipelineState -Path @('BaseSetCount') -Value $baseSetInfo.BaseCount
    if (Get-Command -Name Write-LogPipeline -ErrorAction SilentlyContinue) {
        Write-LogPipeline ("BASE_SET: ingested={0}; base_size={1}; selected={2}" -f $allRows.Count, $baseSetInfo.BaseSize, $baseSetInfo.BaseCount) -Level Verbose
    }
    Write-Host "[Pipeline] BASE_SET size=$($baseSetInfo.BaseSize); selected=$($baseSetInfo.BaseCount) (DisplayRows=$displayRows, Mult=$candidateMult)" -ForegroundColor Cyan
    
    # Stage 1.5: Enrich BASE_SET with vacancy details (FR-1.3, FR-6.1)
    Write-Host "[Pipeline] Stage 1.5: Enriching BASE_SET with vacancy details..." -ForegroundColor Cyan
    $detailsEnriched = 0
    foreach ($row in $candidateRows) {
        if (-not $row.Id) { continue }
        
        # Source guard
        if (($row.Source -ne 'hh') -and ($row.Meta.Source -ne 'hh') -and ($row.Meta.Source -ne 'hh_web_recommendation') -and ($row.Meta.Source -ne 'hh_recommendation') -and ($row.Meta.Source -ne 'hh_general')) {
            continue
        }

        # ID pattern guard
        if ($row.Id -notmatch '^\d+$') {
            continue
        }
        
        try {
            # Fetch vacancy detail (uses hh.fetch, has caching)
            $detail = $null
            if (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue) {
                $detail = Get-VacancyDetail -Id $row.Id
            }
            
            if ($detail) {
                # Check if this was a synthetic/placeholder item (missing employer ID is a good signal)
                $isSynthetic = (-not $row.EmployerId) -or ($row.Title -like "WebSearch Vacancy*")

                if ($isSynthetic) {
                    # Fully rebuild the canonical row from the detail object
                    try {
                        $fresh = Build-CanonicalRowTyped -Vacancy $detail -NoDetail
                        
                        # Copy core fields
                        $row.Title = $fresh.Title
                        $row.Employer = $fresh.Employer
                        $row.EmployerId = $fresh.EmployerId
                        $row.EmployerName = $fresh.EmployerName
                        $row.EmployerLogoUrl = $fresh.EmployerLogoUrl
                        $row.EmployerRating = $fresh.EmployerRating
                        $row.EmployerOpenVacancies = $fresh.EmployerOpenVacancies
                        $row.EmployerIndustryShort = $fresh.EmployerIndustryShort
                        
                        $row.Salary = $fresh.Salary
                        
                        $row.AreaId = $fresh.AreaId
                        $row.AreaName = $fresh.AreaName
                        $row.City = $fresh.City
                        $row.Country = $fresh.Country
                        $row.country = $fresh.country
                        
                        $row.PublishedAt = $fresh.PublishedAt
                        $row.Url = $fresh.Url
                        $row.Description = $fresh.Description
                        $row.KeySkills = $fresh.KeySkills
                        
                        # Ensure plain description is updated in Meta
                        if (Get-Command -Name Get-PlainDesc -ErrorAction SilentlyContinue) {
                            $row.Meta.plain_desc = Get-PlainDesc -Text $fresh.Description
                        }
                        
                        Write-Host "[Debug] Fully enriched synthetic item $($row.Id)" -ForegroundColor Green
                    }
                    catch {
                        Write-Warning "Failed to rebuild synthetic item $($row.Id): $_"
                    }
                }
                else {
                    # Regular enrichment for existing items (just update details)
                    # Update description
                    if ($detail.description) {
                        try {
                            $row.Description = $detail.description
                            if (Get-Command -Name Get-PlainDesc -ErrorAction SilentlyContinue) {
                                $row.Meta.plain_desc = Get-PlainDesc -Text $detail.description
                            }
                        }
                        catch {}
                    }
                    
                    # Update key skills
                    if ($detail.key_skills) {
                        try {
                            $ks = Get-CanonicalKeySkills -Detail $detail
                            $row.KeySkills = $ks.List
                        }
                        catch {}
                    }
                    
                    # Update employer industry from detail
                    if ($detail.employer -and $detail.employer.industries) {
                        try {
                            if ($detail.employer.industries.Count -gt 0) {
                                $row.EmployerIndustryShort = [string]$detail.employer.industries[0].name
                            }
                        }
                        catch {}
                    }
                    
                    # Update country from area
                    if ($detail.area) {
                        try {
                            if ($detail.area.country -and $detail.area.country.name) {
                                $row.country = [string]$detail.area.country.name
                                $row.Country = [string]$detail.area.country.name
                            }
                            else {
                                # Try to resolve country from area ID
                                if (Get-Command -Name Resolve-HHAreaCountry -ErrorAction SilentlyContinue) {
                                    $countryName = Resolve-HHAreaCountry -AreaId ([string]$detail.area.id)
                                    if ($countryName) {
                                        $row.country = $countryName
                                        $row.Country = $countryName
                                    }
                                }
                            }
                        }
                        catch {}
                    }
                }
                
                $detailsEnriched++
            }
        }
        catch {
            Write-Host "[Pipeline] Detail fetch failed for $($row.Id): $_" -ForegroundColor Yellow
        }
    }
    Write-Host "[Pipeline] Enriched $detailsEnriched/$candidateCount vacancies with details" -ForegroundColor Cyan
    
    # LLM Stages
    if ($candidateCount -gt 0) {
        Write-Host "[Pipeline] Tier 1: Building local summaries for BASE_SET..." -ForegroundColor Cyan
        foreach ($row in $candidateRows) {
            if (-not $row.Meta.local_summary) {
                $localPlan = Get-HHLocalVacancySummary -Vacancy $row -CvSnapshot $cvSnapshot
                if ($localPlan) { $row.Meta.local_summary = $localPlan }
            }
            $localSummary = $row.Meta.local_summary
            if ($localSummary -and $localSummary.summary) {
                $cleanLocal = hh.util\Normalize-HHSummaryText -Text $localSummary.summary
                $row.Summary = $cleanLocal
                if (-not $row.Meta.summary) { $row.Meta.summary = New-Object SummaryInfo }
                $row.Meta.summary.text = $cleanLocal
                $row.Meta.summary.lang = $localSummary.language
                $localSource = hh.util\Normalize-HHSummarySource -Source $localSummary.source -Fallback 'local'
                $row.Meta.summary.source = $localSource
                $row.Meta.summary_source = $localSource
                $row.Meta.summary_model = $localSummary.model
            }
        }

        Write-Host "[Pipeline] Tier 1: Local relevance scoring..." -ForegroundColor Cyan
        $hint = "Candidate"
        if ($cvSnapshot -and $cvSnapshot.Title) { $hint = $cvSnapshot.Title }
        elseif ($cvSnapshot -and $cvSnapshot.KeySkills) { $hint = ($cvSnapshot.KeySkills -join ", ") }
        $counter = 0
        foreach ($row in $candidateRows) {
            $counter++
            $desc = if ($row.Description) { $row.Description } else { $row.Title }
            $desc = $desc -replace '<[^>]+>', ' '
            try {
                $rel = Invoke-LocalLLMRelevance -VacancyText $desc -ProfileHint $hint
                if ($rel -gt 0) {
                    if (-not $row.Meta) { $row.Meta = New-Object MetaInfo }
                    $row.Meta.local_llm_relevance = $rel
                    if (-not $row.Meta.scores) { $row.Meta.scores = New-Object ScoreInfo }
                    try { $row.Meta.scores.local_llm = [Math]::Min(1.0, [double]$rel / 5.0) } catch {}
                }
            }
            catch {
                Write-Warning "Local LLM relevance failed for $($row.Id): $_"
            }
        }

        if ($LLMEnabled) {
            Write-Host "[Pipeline] Tier 2: Remote rescoring..." -ForegroundColor Cyan
            foreach ($row in $candidateRows) {
                $localSummary = $row.Meta.local_summary
                $fitResult = Get-HHRemoteFitScore -Vacancy $row -CvSnapshot $cvSnapshot -CvPayload $compactCvPayload -LocalSummary $localSummary
                if ($fitResult -and $fitResult.fit_score -ne $null) {
                    $row.Meta.ranking.RemoteFitScore = [double]$fitResult.fit_score
                    if ($fitResult.reason) {
                        if (-not $row.Meta.ranking.PSObject.Properties['RemoteFitReason']) {
                            $row.Meta.ranking | Add-Member -MemberType NoteProperty -Name 'RemoteFitReason' -Value $null -Force
                        }
                        $row.Meta.ranking.RemoteFitReason = [string]$fitResult.reason
                    }
                    $normalized = [double]$fitResult.fit_score / 10.0
                    if (-not $row.Meta.scores) { $row.Meta.scores = New-Object ScoreInfo }
                    $row.Meta.scores.total = $normalized
                    $row.Meta.ranking.FinalScore = [double]$fitResult.fit_score
                    $row.Score = $normalized
                }
            }

            $candidateRows = $candidateRows | Sort-Object -Property Score -Descending

            $tierTop = 10
            try {
                $tierTop = [int](Get-HHConfigValue -Path @('llm', 'tiered', 'top_n_remote') -Default (Get-HHConfigValue -Path @('llm', 'tiered', 'top_n_external') -Default 10))
            }
            catch {}
            Write-Host "[Pipeline] Tier 3: Remote summaries for top $tierTop..." -ForegroundColor Cyan
            $remoteTargets = $candidateRows | Select-Object -First $tierTop
            foreach ($row in $remoteTargets) {
                # Use new helper for standardized remote summary
                $remoteRes = $null
                if (Get-Command -Name Get-HHRemoteVacancySummary -ErrorAction SilentlyContinue) {
                    $remoteRes = Get-HHRemoteVacancySummary -Vacancy $row -CvPayload $compactCvPayload
                }
                
                if ($remoteRes -and $remoteRes.Summary) {
                    $cleanRemote = hh.util\Normalize-HHSummaryText -Text $remoteRes.Summary
                    
                    # Update Canoncial Summary (Surface level)
                    $row.Summary = $cleanRemote
                    
                    # Update Meta.Summary (Canonical Truth)
                    if (-not $row.Meta.summary) { $row.Meta.summary = New-Object SummaryInfo }
                    $row.Meta.summary.text = $cleanRemote
                    # Map properties from PSCustomObject to SummaryInfo
                    $row.Meta.summary.lang = [string]$remoteRes.Language
                    $row.Meta.summary.model = [string]$remoteRes.Model
                    $row.Meta.summary.source = 'remote'
                    
                    # Legacy/Duplicate meta fields (for backward compatibility)
                    $row.Meta.summary_source = 'remote'
                    $row.Meta.summary_model = [string]$remoteRes.Model
                    
                    # Explicitly mark as remote for other consumers
                    $remoteSource = 'remote'
                    
                    # Update Ranking info
                    $row.Meta.ranking.SummarySource = $remoteSource
                    
                    # Store specifically as remote text if we want to preserve local separately?
                    # Start with overwriting as per plan (Part 2: Expose External LLM Summaries)
                    $row.Meta.Summary.RemoteText = $cleanRemote
                }
            }
        }
        else {
            Write-Host "[Pipeline] Tier 2/3 skipped (LLM disabled)" -ForegroundColor Yellow
        }
    }
    
    # Select Final Top N
    $finalTopRows = $candidateRows | Select-Object -First $displayRows
    
    # Stage 3.5: Enrich BASE_SET with employer details + rating scraping (FR-6.1a)
    Write-Host "[Debug] Final Top Rows Count: $($finalTopRows.Count)" -ForegroundColor Magenta
    Write-Host "[Pipeline] Stage 3.5: Enriching base set $($candidateRows.Count) with employer details..." -ForegroundColor Cyan
    $employersEnriched = 0
    $ratingsScraped = 0
    $scrapedRatings = @{}
    
    foreach ($row in $candidateRows) {
        if (-not $row.Employer -or -not $row.Employer.Id) { continue }
        # Source guard for employer enrichment
        if (($row.Source -ne 'hh') -and ($row.Meta.Source -ne 'hh') -and ($row.Meta.Source -ne 'hh_web_recommendation') -and ($row.Meta.Source -ne 'hh_recommendation') -and ($row.Meta.Source -ne 'hh_general')) {
            continue
        }

        # Employer ID pattern guard
        if ($row.Employer.Id -notmatch '^\d+$') {
            continue
        }
        
        try {
            # Fetch employer detail (cached)
            $empDetail = $null
            if (Get-Command -Name Get-EmployerDetail -ErrorAction SilentlyContinue) {
                $empDetail = Get-EmployerDetail -Id $row.Employer.Id
            }
            
            if ($empDetail) {
                # Extract open vacancies
                # Check for $null instead of truthy to allow 0 values
                if ($null -ne $empDetail.open_vacancies) {
                    try {
                        $row.EmployerOpenVacancies = [int]$empDetail.open_vacancies
                    }
                    catch {}
                }
                
                # Extract industry (if not already set)
                if ([string]::IsNullOrWhiteSpace($row.EmployerIndustryShort)) {
                    try {
                        if ($empDetail.industry -and $empDetail.industry.name) {
                            $row.EmployerIndustryShort = [string]$empDetail.industry.name
                        }
                        elseif ($empDetail.industries -and $empDetail.industries.Count -gt 0) {
                            $row.EmployerIndustryShort = [string]$empDetail.industries[0].name
                        }
                    }
                    catch {}
                }
                Write-Host "[Debug] Enriched Emp $($row.Employer.Id): Ind=$($row.EmployerIndustryShort)" -ForegroundColor DarkGray
                $employersEnriched++
            }
            
            # Ensure rating always originates from the HTML scraper (cache per employer)
            $empKey = $null
            try {
                if ($row.EmployerId) { $empKey = [string]$row.EmployerId }
                elseif ($row.Employer -and $row.Employer.Id) { $empKey = [string]$row.Employer.Id }
            }
            catch {}
            
            # FR-6.1: Only scrape rating for HH source vacancies. Never Getmatch.
            $isHH = ($row.Source -eq 'hh') -or ($row.Meta.Source -like 'hh*')
            
            if ($empKey -and $isHH) {
                if (-not $scrapedRatings.ContainsKey($empKey)) {
                    if ($row.EmployerRating -le 0) {
                        if (Get-Command -Name Update-EmployerRating -ErrorAction SilentlyContinue) {
                            Update-EmployerRating -Vacancy $row
                            if ($row.EmployerRating -gt 0) { $ratingsScraped++ }
                        }
                    }
                    $scrapedRatings[$empKey] = [double]($row.EmployerRating ?? 0)
                }
                else {
                    $cached = [double]$scrapedRatings[$empKey]
                    $row.EmployerRating = $cached
                    if ($row.Employer) { $row.Employer.Rating = $cached }
                }
            }
        }
        catch {
            Write-Host "[Pipeline] Employer enrichment failed for $($row.Employer.Id): $_" -ForegroundColor Yellow
        }
    }
    Write-Host "[Pipeline] Enriched $employersEnriched employers, scraped $ratingsScraped ratings" -ForegroundColor Cyan
    
    # Stage 4: Fallback Summaries (for Top N items that didn't get premium summary)
    if ($finalTopRows) {
        Write-Host "[Pipeline] Stage 4: Fallback Summaries (Top $($finalTopRows.Count))..." -ForegroundColor Cyan
        foreach ($row in $finalTopRows) {
            # Fix: Do not overwrite existing remote summaries (anything not local/empty)
            if ($row.Meta.summary_source -and $row.Meta.summary_source -ne 'local') { continue }
            
            $localPlan = $row.Meta.local_summary
            if ($localPlan -and $localPlan.summary) {
                $cleanLocalPlan = hh.util\Normalize-HHSummaryText -Text $localPlan.summary
                $row.Summary = $cleanLocalPlan
                if (-not $row.Meta.summary) { $row.Meta.summary = New-Object SummaryInfo }
                $row.Meta.summary.text = $cleanLocalPlan
                $row.Meta.summary.lang = $localPlan.language
                $fallbackSource = hh.util\Normalize-HHSummarySource -Source $localPlan.source -Fallback 'local'
                $row.Meta.summary.source = $fallbackSource
                $row.Meta.summary_source = $fallbackSource
                $row.Meta.summary_model = $localPlan.model
                $row.Meta.ranking.SummarySource = $fallbackSource
            }
        }
    }
    
    # Replace the original list's top items with processed ones (if we want to preserve all rows)
    # Or just pass $allRows. Since we updated objects by reference, $allRows should reflect changes.
    # However, we need to make sure sorting is applied to $allRows if we want correct report order.
    
    $allRows = $allRows | Sort-Object -Property Score -Descending
    
    # 5.5 Picks
    Write-Host "[Pipeline] Selecting picks (EC, Lucky, Worst)..." -ForegroundColor Cyan
    $allRows = Apply-Picks -Rows $allRows -LLMEnabled:$LLMEnabled -CvPayload $compactCvPayload
    
    # 6. Render
    Write-Host "[Pipeline] Rendering reports..."
    if (Get-Command -Name Render-Reports -ErrorAction SilentlyContinue) {
        Render-Reports -Rows $allRows -OutputsRoot $OutputsRoot -PipelineState $PipelineState
    }
    
    # 9. Notify
    if ($Digest) {
        Write-Host "[Pipeline] Sending Telegram digest..."
        if (Get-Command -Name Send-TelegramDigest -ErrorAction SilentlyContinue) {
            Send-TelegramDigest -RowsTop $allRows -PublicUrl $ReportUrl -SearchLabel $SearchText -DryRun:$NotifyDryRun
        }
    }
    if ($Ping) {
        Write-Host "[Pipeline] Sending Telegram ping..."
        if (Get-Command -Name Send-TelegramPing -ErrorAction SilentlyContinue) {
            Send-TelegramPing -ViewsCount 0 -InvitesCount 0 -RowsCount ($allRows.Count) -PublicUrl $ReportUrl -RunStats $PipelineState -CacheStats $global:CacheStats -PipelineState $PipelineState -DryRun:$NotifyDryRun
        }
    }

    if ($PipelineState -and $PipelineState.PSObject.Properties['LlmUsage'] -and $PipelineState.LlmUsage.Keys.Count -gt 0) {
        Write-Host "[Pipeline] LLM usage summary:" -ForegroundColor Cyan
        foreach ($key in $PipelineState.LlmUsage.Keys) {
            $entry = $PipelineState.LlmUsage[$key]
            $calls = [int]($entry.Calls ?? 0)
            $inTokens = [int]($entry.EstimatedTokensIn ?? 0)
            $outTokens = [int]($entry.EstimatedTokensOut ?? 0)
            Write-Host ("  - {0}: calls={1}, tokens_in={2}, tokens_out={3}" -f $key, $calls, $inTokens, $outTokens) -ForegroundColor DarkGray
        }
    }
    
    # 10. Summary
    Show-HHPipelineSummary -State $PipelineState -ReportUrl $ReportUrl
    
    return $PipelineState
}

Export-ModuleMember -Function Get-HHSearchMode, ConvertTo-HHSearchText, Get-CanonicalKeySkills, Get-BaseSet, Build-CanonicalRowTyped, Build-CanonicalFromGetmatchVacancy, Invoke-HHProbeMain, Apply-Picks, Invoke-EditorsChoice, Invoke-HHPipelineLuckyPick, Invoke-HHPipelineWorstPick, Ensure-HHLLMCommands, Test-HHPipelineHealth
