# hh.pipeline.psm1 — main processing pipeline
#Requires -Version 7.5

using module ./hh.models.psm1

# Import dependencies
if (-not (Get-Command -Name 'hh.util\Normalize-HHSummaryText' -ErrorAction SilentlyContinue)) {
    $utilPath = Join-Path $PSScriptRoot 'hh.util.psm1'
    if (Test-Path $utilPath) { Import-Module -Name $utilPath -DisableNameChecking -Force -ErrorAction SilentlyContinue }
}

if (-not (Get-Module -Name 'hh.llm')) {
    $llmPath = Join-Path $PSScriptRoot 'hh.llm.psm1'
    if (Test-Path $llmPath) { Import-Module -Name $llmPath -DisableNameChecking -ErrorAction SilentlyContinue }
}

if (-not (Get-Module -Name 'hh.llm.summary')) {
    $llmSumPath = Join-Path $PSScriptRoot 'hh.llm.summary.psm1'
    if (Test-Path $llmSumPath) { Import-Module -Name $llmSumPath -DisableNameChecking -ErrorAction SilentlyContinue }
}

if (-not (Get-Module -Name 'hh.factory')) {
    $factoryPath = Join-Path $PSScriptRoot 'hh.factory.psm1'
    if (Test-Path $factoryPath) { Import-Module -Name $factoryPath -DisableNameChecking -ErrorAction SilentlyContinue }
}

# ==============================================================================
# Pipeline Stages
# ==============================================================================

function Invoke-PipelineStageSearch {
    param(
        $SearchText,
        $VacancyPerPage,
        $VacancyPages,
        $ResumeId,
        $SearchFilters,
        $RecommendEnabled,
        $RecommendPerPage,
        $RecommendTopTake,
        $GetmatchConfig,
        $PSScriptRoot,
        $State
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Use Get-HHProbeVacancies (unified fetcher)
    $allRawItems = Get-HHProbeVacancies -SearchText $SearchText `
        -VacancyPerPage $VacancyPerPage `
        -VacancyPages $VacancyPages `
        -ResumeId $ResumeId `
        -SearchFilters $SearchFilters `
        -RecommendEnabled $RecommendEnabled `
        -RecommendPerPage $RecommendPerPage `
        -RecommendTopTake $RecommendTopTake

    # Canonicalize & Dedup
    $allRows = @()
    $tempRows = @()
    $seenUrls = @{}
    $countHH = 0
    $countGM = 0

    foreach ($item in $allRawItems) {
        $c = $null
        if ($item.Source -eq 'getmatch') {
            $c = New-CanonicalVacancyFromGetmatch -RawItem $item
        }
        else {
            $c = New-CanonicalVacancyFromHH -Vacancy $item
        }

        if ($c -is [CanonicalVacancy]) {
            # Update source label for HH items
            if ($c.Meta.Source -ne 'getmatch') {
                $label = Get-HHSourceLabelFromStage -Stage $c.SearchStage -Tiers $c.SearchTiers
                $c.Meta.Source = $label
            }
            $tempRows += $c
        }
    }

    # Dedup logic: Prefer HH, then Getmatch
    # Pass 1: HH
    foreach ($r in $tempRows) {
        if ($r.Meta.Source -ne 'getmatch') {
            $u = $r.Url; if (-not $u) { $u = "id:" + $r.Id }
            if (-not $seenUrls.ContainsKey($u)) {
                $seenUrls[$u] = $true; $allRows += $r; $countHH++
            }
        }
    }
    # Pass 2: Getmatch
    foreach ($r in $tempRows) {
        if ($r.Meta.Source -eq 'getmatch') {
            $u = $r.Url; if (-not $u) { $u = "id:" + $r.Id }
            if (-not $seenUrls.ContainsKey($u)) {
                $seenUrls[$u] = $true; $allRows += $r; $countGM++
            }
        }
    }

    $sw.Stop()
    if ($State) {
        $State.Timings['Fetch'] = $sw.Elapsed # Just fetch+process time approx
        Add-HHPipelineStat -State $State -Path @('Search', 'ItemsFetched') -Value $allRows.Count
    }
    
    Write-Host "[Search] canonical rows after dedup:  $($allRows.Count) (HH: $countHH, GM: $countGM)"
    return $allRows
}

function Invoke-PipelineStagePreEnrich {
    param(
        [CanonicalVacancy[]]$Rows,
        $State,
        $RepoRoot
    )
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "[Pipeline] Stage 3.1: Pre-enriching synthetic items..." -ForegroundColor Cyan
    
    # Ensure fetch module
    if (-not (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -Name 'hh.fetch')) {
            $fetchPath = Join-Path $RepoRoot 'modules/hh.fetch.psm1'
            if (Test-Path $fetchPath) { Import-Module $fetchPath -DisableNameChecking -ErrorAction SilentlyContinue }
        }
    }

    $syntheticEnriched = 0
    foreach ($row in $Rows) {
        $isHh = ($row.Meta.Source -eq 'hh' -or $row.Meta.Source -eq 'hh_web_recommendation')
        $isWebRec = ($row.SearchTiers -contains 'web_recommendation')
        $isSynthetic = ($row.PSObject.Properties['needs_enrichment'] -and $row.needs_enrichment) -or ($row.Title -like "WebSearch Vacancy*") -or (-not $row.EmployerId)
        
        if ($isHh -and $isWebRec -and $isSynthetic) {
            if ($row.Id -notmatch '^\d+$') { continue }
            try {
                if (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue) {
                    $detail = Get-VacancyDetail -Id $row.Id
                    if ($detail) {
                        $fresh = New-CanonicalVacancyFromHH -Vacancy $detail -NoDetail
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

                        if ($row.PSObject.Properties['needs_enrichment']) { $row.needs_enrichment = $false }
                        if (Get-Command -Name Get-PlainDesc -ErrorAction SilentlyContinue) {
                            $row.Meta.plain_desc = Get-PlainDesc -Text $fresh.Description
                        }
                        $syntheticEnriched++
                    }
                }
            }
            catch {}
        }
    }
    Write-Host "[Pipeline] Pre-enriched $syntheticEnriched synthetic items" -ForegroundColor Cyan
    
    $sw.Stop()
    if ($State) { $State.Timings['Enrichment'] = $sw.Elapsed }
}

function Invoke-PipelineStageBaselineScoring {
    param(
        [CanonicalVacancy[]]$Rows,
        $State,
        $RepoRoot,
        $CvSnapshot
    )
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "[Pipeline] Scoring $($Rows.Count) candidates (Baseline)..." -ForegroundColor Cyan
    
    # Ensure scoring module
    if (-not (Get-Command -Name Calculate-Score -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -Name 'hh.scoring')) {
            $sPath = Join-Path $RepoRoot 'modules/hh.scoring.psm1'
            if (Test-Path $sPath) { Import-Module $sPath }
        }
    }
    
    # Local LLM Relevance (optional)
    if (-not (Get-Module -Name 'hh.llm.local')) {
        $localPath = Join-Path $RepoRoot 'modules/hh.llm.local.psm1'
        if (Test-Path $localPath) { Import-Module $localPath -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    
    if (Get-Command -Name Invoke-LocalLLMRelevance -ErrorAction SilentlyContinue) {
        Write-Host "[Pipeline] Calculating Local LLM Relevance..." -ForegroundColor Cyan
        $hint = "Candidate"
        if ($CvSnapshot -and $CvSnapshot.Title) { $hint = $CvSnapshot.Title }
        elseif ($CvSnapshot -and $CvSnapshot.KeySkills) { $hint = ($CvSnapshot.KeySkills -join ", ") }
        
        $counter = 0
        foreach ($row in $Rows) {
            $counter++
            if ($counter % 20 -eq 0) { Write-Progress -Activity "Local LLM Scoring" -Status "$counter / $($Rows.Count)" -PercentComplete (($counter / $Rows.Count) * 100) }

            $desc = if ($row.Description) { $row.Description } else { $row.Title }
            $desc = $desc -replace '<[^>]+>', ' '
            try {
                $cacheKey = "locrel_" + $row.Id + "_" + $hint.GetHashCode()
                $cachedRel = $null
                if (Get-Command -Name Get-HHCacheItem -ErrorAction SilentlyContinue) {
                    try { $cachedRel = Get-HHCacheItem -Collection 'llm_relevance' -Key $cacheKey } catch {}
                }

                $rel = 0
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
            catch {}
        }
        Write-Progress -Activity "Local LLM Scoring" -Completed
    }
    
    # Baseline Score
    $rates = @{ 'RUB' = 1.0 }
    if (Get-Command -Name Get-ExchangeRates -ErrorAction SilentlyContinue) {
        try { $rates = Get-ExchangeRates } catch {}
    }
    
    foreach ($row in $Rows) {
        if (Get-Command -Name Calculate-Score -ErrorAction SilentlyContinue) {
            Calculate-Score -Vacancy $row -CvSnapshot $CvSnapshot -ExchangeRates $rates
        }
        $row.Meta.ranking.BaselineScore = $row.Score
        $row.Meta.ranking.FinalScore = $row.Score
    }
    
    $sw.Stop()
    if ($State) { $State.Timings['Scoring'] = $sw.Elapsed }
}

function Invoke-PipelineStageDeepEnrich {
    param(
        [CanonicalVacancy[]]$Rows,
        $State
    )
    
    Write-Host "[Pipeline] Stage 1.5 & 3.5: Deep Enriching $($Rows.Count) items..." -ForegroundColor Cyan
    $detailsEnriched = 0
    $employersEnriched = 0
    $ratingsScraped = 0
    $scrapedRatings = @{} # cache
    
    foreach ($row in $Rows) {
        if (-not $row.Id) { continue }

        # Source guard: Only HH items support deep detail fetch
        $isHH = ($row.Source -eq 'hh' -or $row.Meta.Source -like 'hh*')
        if (-not $isHH) { continue }
        if ($row.Id -notmatch '^\d+$') { continue }
        
        # 1. Vacancy Detail
        try {
            $detail = $null
            if (Get-Command -Name Get-VacancyDetail -ErrorAction SilentlyContinue) {
                $detail = Get-VacancyDetail -Id $row.Id
            }
            
            if ($detail) {
                # Merge details back
                if ($detail.description) {
                    $row.Description = $detail.description
                    if (Get-Command -Name Get-PlainDesc -ErrorAction SilentlyContinue) {
                        $row.Meta.plain_desc = Get-PlainDesc -Text $detail.description
                    }
                }
                if ($detail.key_skills) {
                    $ks = Get-CanonicalKeySkills -Detail $detail
                    $row.KeySkills = $ks.List
                }
                if ($detail.employer -and $detail.employer.industries -and $detail.employer.industries.Count -gt 0) {
                    $row.EmployerIndustryShort = [string]$detail.employer.industries[0].name
                }
                $detailsEnriched++
            }
        }
        catch {}

        # 2. Employer Detail & Rating
        if ($row.EmployerId -match '^\d+$') {
            try {
                $empDetail = $null
                if (Get-Command -Name Get-EmployerDetail -ErrorAction SilentlyContinue) {
                    $empDetail = Get-EmployerDetail -Id $row.EmployerId
                }
                if ($empDetail) {
                    if ($null -ne $empDetail.open_vacancies) { $row.EmployerOpenVacancies = [int]$empDetail.open_vacancies }
                    if ([string]::IsNullOrWhiteSpace($row.EmployerIndustryShort)) {
                        if ($empDetail.industry -and $empDetail.industry.name) { $row.EmployerIndustryShort = [string]$empDetail.industry.name }
                        elseif ($empDetail.industries -and $empDetail.industries.Count -gt 0) { $row.EmployerIndustryShort = [string]$empDetail.industries[0].name }
                    }
                    $employersEnriched++
                }

                # Scrape Rating
                $empKey = $row.EmployerId
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
                    $row.EmployerRating = $scrapedRatings[$empKey]
                }
            }
            catch {}
        }
    }
    
    Write-Host "[Pipeline] Deep enriched $detailsEnriched vacancies, $employersEnriched employers, $ratingsScraped ratings" -ForegroundColor Cyan
}

function Invoke-PipelineStageLLMScoring {
    param(
        [CanonicalVacancy[]]$Rows,
        $State,
        $CvSnapshot,
        $CompactCvPayload,
        $LLMEnabled,
        $TopNRemote = 10
    )

    if (-not $Rows) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Tier 1: Local Summaries
    Write-Host "[Pipeline] Tier 1: Local summaries..." -ForegroundColor Cyan
    foreach ($row in $Rows) {
        if (-not $row.Meta.local_summary) {
            $localPlan = Get-HHLocalVacancySummary -Vacancy $row -CvSnapshot $CvSnapshot
            if ($localPlan) { $row.Meta.local_summary = $localPlan }
        }
        $localSummary = $row.Meta.local_summary
        if ($localSummary -and $localSummary.summary) {
            $clean = hh.util\Normalize-HHSummaryText -Text $localSummary.summary
            $row.Summary = $clean
            $row.Meta.summary.text = $clean
            $row.Meta.summary.lang = $localSummary.language
            $localSource = hh.util\Normalize-HHSummarySource -Source $localSummary.source -Fallback 'local'
            $row.Meta.summary.source = $localSource
            $row.Meta.summary_source = $localSource
            $row.Meta.summary_model = $localSummary.model
        }
    }

    # Tier 2: Remote Rescoring
    if ($LLMEnabled) {
        Write-Host "[Pipeline] Tier 2: Remote rescoring..." -ForegroundColor Cyan
        foreach ($row in $Rows) {
            $localSummary = $row.Meta.local_summary
            $fitResult = Get-HHRemoteFitScore -Vacancy $row -CvSnapshot $CvSnapshot -CvPayload $CompactCvPayload -LocalSummary $localSummary
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

        # Sort by new score
        $Rows = $Rows | Sort-Object -Property Score -Descending

        # Tier 3: Remote Summaries for Top N
        Write-Host "[Pipeline] Tier 3: Remote summaries for top $TopNRemote..." -ForegroundColor Cyan
        $remoteTargets = $Rows | Select-Object -First $TopNRemote
        foreach ($row in $remoteTargets) {
            $remoteRes = $null
            if (Get-Command -Name Get-HHRemoteVacancySummary -ErrorAction SilentlyContinue) {
                $remoteRes = Get-HHRemoteVacancySummary -Vacancy $row -CvPayload $CompactCvPayload
            }
            if ($remoteRes -and $remoteRes.Summary) {
                $clean = hh.util\Normalize-HHSummaryText -Text $remoteRes.Summary
                $row.Summary = $clean
                $row.Meta.summary.text = $clean
                $row.Meta.summary.lang = [string]$remoteRes.Language
                $row.Meta.summary.model = [string]$remoteRes.Model
                $row.Meta.summary.source = 'remote'
                $row.Meta.summary_source = 'remote'
                $row.Meta.summary_model = [string]$remoteRes.Model
                $row.Meta.ranking.SummarySource = 'remote'
                $row.Meta.Summary.RemoteText = $clean
            }
        }
    }
    else {
        Write-Host "[Pipeline] Tier 2/3 skipped (LLM disabled)" -ForegroundColor Yellow
    }

    $sw.Stop()
    if ($State) { $State.Timings['Ranking'] = $sw.Elapsed }
    return $Rows
}

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
        [Parameter(Mandatory = $false)][CanonicalVacancy[]]$Rows,
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

    # Prepare items for LLM (no explicit limit here, use full BASE_SET)
    $candidates = $Rows
    
    $temperature = if ($cfg.Temperature -ne $null) { [double]$cfg.Temperature } else { 0.2 }
    $pick = LLM-EditorsChoicePick -Items $candidates -CvText ($CvSkills -join ", ") -Endpoint $endpoint -ApiKey $apiKey -Model $model -Temperature $temperature -TimeoutSec $cfg.TimeoutSec -MaxTokens ($cfg.MaxTokens ?? 0) -TopP ($cfg.TopP ?? 0) -ExtraParameters $cfg.Parameters -OperationName 'picks.ec_why'
    return $pick
}

function Apply-Picks {
    param(
        [Parameter(Mandatory = $false)][CanonicalVacancy[]]$Rows,
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
            
            # Fallback: Try Title match if ID failed
            if (-not $r) {
                $r = $Rows | Where-Object { $_.Title -eq $ecPick.id } | Select-Object -First 1
                if ($r) {
                    Write-Warning "[Picks] EC pick matched by Title instead of Id: '$($ecPick.id)'"
                }
            }

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
        Write-Host "[DEBUG] LuckyIdx: $luckyIdx Rows: $($Rows.Count)" -ForegroundColor Magenta
        
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
            
            # Fallback: Try Title match if ID failed
            if (-not $r) {
                $r = $Rows | Where-Object { $_.Title -eq $worstPick.id } | Select-Object -First 1
                if ($r) {
                    Write-Warning "[Picks] Worst pick matched by Title instead of Id: '$($worstPick.id)'"
                }
            }

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

    # Prepare unified fetch context to pass safely to parallel runspaces
    $fetchContext = @{
        ResumeId         = $ResumeId
        SearchText       = $SearchText
        VacancyPerPage   = $VacancyPerPage
        VacancyPages     = $VacancyPages
        RecommendEnabled = $RecommendEnabled
        RecommendPerPage = $RecommendPerPage
        SearchFilters    = $SearchFilters
        GetmatchConfig   = $getmatchConfig
        PSScriptRoot     = $PSScriptRoot
    }

    # Build parallel jobs
    $fetchJobs = @()
    
    # Job 1: HH Hybrid
    $fetchJobs += [PSCustomObject]@{
        Name = 'HH'
        Script = {
            param($ctx)
            Write-Host "[Fetch-Parallel] Starting HH fetch..." -ForegroundColor Cyan
            
            # Bootstrap parallel environment
            if ($ctx.PSScriptRoot) {
                $hPath = Join-Path $ctx.PSScriptRoot 'hh.helpers.psm1'
                if (Test-Path $hPath) { Import-Module $hPath -DisableNameChecking -Force -ErrorAction SilentlyContinue }
                if (Get-Command -Name 'Import-HHModulesForParallel' -ErrorAction SilentlyContinue) {
                    Import-HHModulesForParallel -ModulesPath $ctx.PSScriptRoot
                }
                
                # Task specific
                $fetchPath = Join-Path $ctx.PSScriptRoot 'hh.fetch.psm1'
                if (Test-Path $fetchPath) { Import-Module $fetchPath -DisableNameChecking -Force -ErrorAction SilentlyContinue }
            }

            $hhRes = Get-HHHybridVacancies -ResumeId $ctx.ResumeId -QueryText $ctx.SearchText -Limit ($ctx.VacancyPerPage * $ctx.VacancyPages) -Config @{
                PerPage          = $ctx.VacancyPerPage
                RecommendEnabled = $ctx.RecommendEnabled
                RecommendPerPage = $ctx.RecommendPerPage
                Filters          = $ctx.SearchFilters
            }
            $items = @()
            if ($hhRes.Items) { $items = $hhRes.Items }
            Write-Host "[Fetch-Parallel] HH fetch completed: $($items.Count) items" -ForegroundColor Cyan
            return $items
        }
    }
    
    # Job 2: Getmatch
    if ($gmEnabled) {
        $fetchJobs += [PSCustomObject]@{
            Name = 'Getmatch'
            Script = {
                param($ctx)
                Write-Host "[Fetch-Parallel] Starting Getmatch fetch..." -ForegroundColor Cyan
                
                # Bootstrap parallel environment
                if ($ctx.PSScriptRoot) {
                    $hPath = Join-Path $ctx.PSScriptRoot 'hh.helpers.psm1'
                    if (Test-Path $hPath) { Import-Module $hPath -DisableNameChecking -Force -ErrorAction SilentlyContinue }
                    if (Get-Command -Name 'Import-HHModulesForParallel' -ErrorAction SilentlyContinue) {
                        Import-HHModulesForParallel -ModulesPath $ctx.PSScriptRoot
                    }
                    
                    # Task specific
                    $fetchPath = Join-Path $ctx.PSScriptRoot 'hh.fetch.psm1'
                    if (Test-Path $fetchPath) { Import-Module $fetchPath -DisableNameChecking -Force -ErrorAction SilentlyContinue }
                }
                
                # Convert GM config back to hashtable if needed
                $gmCfgHash = @{}
                if ($ctx.GetmatchConfig -is [System.Collections.IDictionary]) {
                    $gmCfgHash = $ctx.GetmatchConfig
                }
                else {
                    foreach ($prop in $ctx.GetmatchConfig.PSObject.Properties) {
                        $gmCfgHash[$prop.Name] = $prop.Value
                    }
                }

                $gmItems = @()
                if (Get-Command -Name 'Get-GetmatchVacanciesRaw' -ErrorAction SilentlyContinue) {
                    $gmItems = Get-GetmatchVacanciesRaw -GetmatchConfig $gmCfgHash
                }
                Write-Host "[Fetch-Parallel] Getmatch fetch completed: $($gmItems.Count) items" -ForegroundColor Cyan
                return $gmItems
            }
        }
    }
    
    # Execute Parallel
    $allResults = $fetchJobs | ForEach-Object -Parallel {
        $ctx = $using:fetchContext
        $res = & $_.Script -ctx $ctx
        return $res
    } -ThrottleLimit 5
    
    # Flatten results
    $finalItems = @()
    foreach ($res in $allResults) {
        if ($res) { $finalItems += $res }
    }
    
    return $finalItems
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
    
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Load Getmatch config if needed
    $getmatchConfig = $null
    try {
        if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
            $getmatchConfig = Get-HHConfigValue -Path @('getmatch')
        }
    } catch {}

    # 2. Fetch & Canonicalize (Stage 1)
    $allRows = Invoke-PipelineStageSearch -SearchText $SearchText `
        -VacancyPerPage $VacancyPerPage `
        -VacancyPages $VacancyPages `
        -ResumeId $ResumeId `
        -SearchFilters @{} `
        -RecommendEnabled $RecommendEnabled `
        -RecommendPerPage $RecommendPerPage `
        -RecommendTopTake $RecommendTopTake `
        -GetmatchConfig $getmatchConfig `
        -PSScriptRoot $PSScriptRoot `
        -State $PipelineState

    # 3. Pre-enrichment (Stage 2)
    Invoke-PipelineStagePreEnrich -Rows $allRows -State $PipelineState -RepoRoot $RepoRoot

    # 4. CV Loading (Prepare)
    $cvSnapshot = $null
    if (Get-Command -Name Get-HHCVSnapshotOrSkills -ErrorAction SilentlyContinue) {
        $cvSnapshot = Get-HHCVSnapshotOrSkills
    }
    $compactCvPayload = $null
    if ($cvSnapshot -and (Get-Command -Name Build-CompactCVPayload -ErrorAction SilentlyContinue)) {
        try {
            $cvConfig = Get-HHConfigValue -Path @('cv')
            $compactCvPayload = Build-CompactCVPayload -Resume $cvSnapshot -CvConfig $cvConfig
            Set-HHPipelineValue -State $PipelineState -Path @('CompactCVPayload') -Value $compactCvPayload
        } catch {}
    }

    # 5. Baseline Scoring (Stage 3)
    Invoke-PipelineStageBaselineScoring -Rows $allRows -State $PipelineState -RepoRoot $RepoRoot -CvSnapshot $cvSnapshot

    # 6. Candidate Selection (Base Set)
    $displayRows = 30
    try { $displayRows = [int](Get-HHConfigValue -Path @('report', 'max_display_rows') -Default 30) } catch {}
    $candidateMult = 1.5
    try { $candidateMult = [double](Get-HHConfigValue -Path @('ranking', 'candidate_multiplier') -Default 1.5) } catch {}
    
    if (-not $allRows) { $allRows = @() }
    $baseSetInfo = Get-BaseSet -Rows $allRows -MaxDisplayRows $displayRows -CandidateMultiplier $candidateMult
    $candidateRows = @($baseSetInfo.Items)
    if (-not $candidateRows) { $candidateRows = @() }
    Set-HHPipelineValue -State $PipelineState -Path @('BaseSize') -Value $baseSetInfo.BaseSize
    Set-HHPipelineValue -State $PipelineState -Path @('BaseSetCount') -Value $baseSetInfo.BaseCount
    Write-Host "[Pipeline] BASE_SET size=$($baseSetInfo.BaseSize); selected=$($baseSetInfo.BaseCount)" -ForegroundColor Cyan

    # 7. Deep Enrichment (Stage 4)
    Invoke-PipelineStageDeepEnrich -Rows $candidateRows -State $PipelineState

    # 8. Advanced Scoring / LLM (Stage 5)
    $tierTop = 10
    try { $tierTop = [int](Get-HHConfigValue -Path @('llm', 'tiered', 'top_n_remote') -Default 10) } catch {}
    $candidateRows = Invoke-PipelineStageLLMScoring -Rows $candidateRows -State $PipelineState -CvSnapshot $cvSnapshot -CompactCvPayload $compactCvPayload -LLMEnabled $LLMEnabled -TopNRemote $tierTop

    # 9. Fallback Summaries
    $finalTopRows = $candidateRows | Select-Object -First $displayRows
    if ($finalTopRows) {
        Write-Host "[Pipeline] Stage 4: Fallback Summaries (Top $($finalTopRows.Count))..." -ForegroundColor Cyan
        foreach ($row in $finalTopRows) {
            if ($row.Meta.summary_source -and $row.Meta.summary_source -ne 'local') { continue }
            $localPlan = $row.Meta.local_summary
            if ($localPlan -and $localPlan.summary) {
                $clean = hh.util\Normalize-HHSummaryText -Text $localPlan.summary
                $row.Summary = $clean
                $row.Meta.summary.text = $clean
                $row.Meta.summary.lang = $localPlan.language
                $row.Meta.summary.source = 'local'
                $row.Meta.summary_source = 'local'
                $row.Meta.ranking.SummarySource = 'local'
            }
        }
    }
    
    # 10. Picks
    Write-Host "[Pipeline] Selecting picks..." -ForegroundColor Cyan
    $candidateRows = Apply-Picks -Rows $candidateRows -LLMEnabled:$LLMEnabled -CvPayload $compactCvPayload
    
    $swTotal.Stop()
    $PipelineState.Timings['Total'] = $swTotal.Elapsed
    $PipelineState.Run.Duration = $swTotal.Elapsed

    # 11. Render
    Write-Host "[Pipeline] Rendering reports..."
    if (Get-Command -Name Render-Reports -ErrorAction SilentlyContinue) {
        Render-Reports -Rows $candidateRows -OutputsRoot $OutputsRoot -PipelineState $PipelineState
    }
    
    # 12. Notify
    if ($Digest) {
        Write-Host "[Pipeline] Sending Telegram digest..."
        if (Get-Command -Name Send-TelegramDigest -ErrorAction SilentlyContinue) {
            Send-TelegramDigest -RowsTop $candidateRows -PublicUrl $ReportUrl -SearchLabel $SearchText -DryRun:$NotifyDryRun
        }
    }
    if ($Ping) {
        Write-Host "[Pipeline] Sending Telegram ping..."
        if (Get-Command -Name Send-TelegramPing -ErrorAction SilentlyContinue) {
            Send-TelegramPing -ViewsCount 0 -InvitesCount 0 -RowsCount ($candidateRows.Count) -PublicUrl $ReportUrl -RunStats $PipelineState -CacheStats $global:CacheStats -PipelineState $PipelineState -DryRun:$NotifyDryRun
        }
    }

    if ($PipelineState -and $PipelineState.LlmUsage) {
        Write-Host "[Pipeline] LLM usage summary:" -ForegroundColor Cyan
        foreach ($key in $PipelineState.LlmUsage.Keys) {
            $e = $PipelineState.LlmUsage[$key]
            Write-Host ("  - {0}: calls={1}, tokens_in={2}, tokens_out={3}" -f $key, $e.Calls, $e.EstimatedTokensIn, $e.EstimatedTokensOut) -ForegroundColor DarkGray
        }
    }
    
    # 13. Summary
    Show-HHPipelineSummary -State $PipelineState -ReportUrl $ReportUrl
    
    return $PipelineState
}

Export-ModuleMember -Function Get-HHSearchMode, ConvertTo-HHSearchText, Get-CanonicalKeySkills, Get-BaseSet, Invoke-HHProbeMain, Apply-Picks, Invoke-EditorsChoice, Test-HHPipelineHealth
