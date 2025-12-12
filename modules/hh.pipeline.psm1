# hh.pipeline.psm1 — main processing pipeline
#Requires -Version 7.5

using module ./hh.models.psm1

# ==============================================================================
# Initialization & Capabilities
# ==============================================================================

function Initialize-HHPipelineEnvironment {
    param(
        $RepoRoot,
        [bool]$LLMEnabled
    )

    $caps = @{
        CanFetchDetails   = $false
        CanCalculateScore = $false
        CanUseLocalLLM    = $false
        CanUseRemoteLLM   = $false
        CanCache          = $false
        CanRender         = $false
        CanNotify         = $false
        CanConfig         = $false
        CanGetPlainDesc   = $false
        CanGetEmployerDetail = $false
        CanUpdateRating      = $false
        CanGetExchangeRates  = $false
    }

    # Helper to safe load
    function Import-HHModuleSafe ($Name, $Path) {
        if (-not (Get-Module -Name $Name)) {
            if (Test-Path $Path) { Import-Module $Path -DisableNameChecking -ErrorAction SilentlyContinue }
        }
        return [bool](Get-Module -Name $Name)
    }

    if ($RepoRoot) {
        # Load Core Dependencies
        Import-HHModuleSafe 'hh.util' (Join-Path $RepoRoot 'modules/hh.util.psm1') | Out-Null
        Import-HHModuleSafe 'hh.models' (Join-Path $RepoRoot 'modules/hh.models.psm1') | Out-Null
        Import-HHModuleSafe 'hh.config' (Join-Path $RepoRoot 'modules/hh.config.psm1') | Out-Null
        Import-HHModuleSafe 'hh.factory' (Join-Path $RepoRoot 'modules/hh.factory.psm1') | Out-Null
        
        # Load Functional Modules
        Import-HHModuleSafe 'hh.fetch' (Join-Path $RepoRoot 'modules/hh.fetch.psm1') | Out-Null
        Import-HHModuleSafe 'hh.scoring' (Join-Path $RepoRoot 'modules/hh.scoring.psm1') | Out-Null
        Import-HHModuleSafe 'hh.cache' (Join-Path $RepoRoot 'modules/hh.cache.psm1') | Out-Null
        Import-HHModuleSafe 'hh.render' (Join-Path $RepoRoot 'modules/hh.render.psm1') | Out-Null

        if ($LLMEnabled) {
            Import-HHModuleSafe 'hh.llm' (Join-Path $RepoRoot 'modules/hh.llm.psm1') | Out-Null
            Import-HHModuleSafe 'hh.llm.local' (Join-Path $RepoRoot 'modules/hh.llm.local.psm1') | Out-Null
            Import-HHModuleSafe 'hh.llm.summary' (Join-Path $RepoRoot 'modules/hh.llm.summary.psm1') | Out-Null
        }
    } else {
        # Fallback: Rely on existing paths relative to PSScriptRoot (handled by Import-Module logic in main usually, but here we assume RepoRoot)
        # If RepoRoot is missing, we try to load from current PSScriptRoot context if available in callers scope, 
        # but param is required for clarity.
        # However, for robustness, we check if modules are already loaded.
    }

    # Determine Capabilities
    $caps.CanFetchDetails   = [bool](Get-Command -Name 'Get-VacancyDetail' -ErrorAction SilentlyContinue)
    $caps.CanCalculateScore = [bool](Get-Command -Name 'Calculate-Score' -ErrorAction SilentlyContinue)
    $caps.CanUseLocalLLM    = [bool](Get-Command -Name 'Invoke-LocalLLMRelevance' -ErrorAction SilentlyContinue)
    $caps.CanUseRemoteLLM   = $LLMEnabled -and [bool](Get-Command -Name 'Get-HHRemoteFitScore' -ErrorAction SilentlyContinue)
    $caps.CanCache          = [bool](Get-Command -Name 'Get-HHCacheItem' -ErrorAction SilentlyContinue)
    $caps.CanRender         = [bool](Get-Command -Name 'Render-Reports' -ErrorAction SilentlyContinue)
    $caps.CanNotify         = [bool](Get-Command -Name 'Send-TelegramDigest' -ErrorAction SilentlyContinue)
    $caps.CanConfig         = [bool](Get-Command -Name 'Get-HHConfigValue' -ErrorAction SilentlyContinue)
    
    # Granular
    $caps.CanGetPlainDesc      = [bool](Get-Command -Name 'Get-PlainDesc' -ErrorAction SilentlyContinue)
    $caps.CanGetEmployerDetail = [bool](Get-Command -Name 'Get-EmployerDetail' -ErrorAction SilentlyContinue)
    $caps.CanUpdateRating      = [bool](Get-Command -Name 'Update-EmployerRating' -ErrorAction SilentlyContinue)
    $caps.CanGetExchangeRates  = [bool](Get-Command -Name 'Get-ExchangeRates' -ErrorAction SilentlyContinue)
    
    return $caps
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
        [bool]$RecommendEnabled,
        $RecommendPerPage,
        $RecommendTopTake,
        $GetmatchConfig,
        $PSScriptRoot,
        $State
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Ensure factory module is loaded for canonical vacancy creation
    if (-not (Get-Command -Name 'New-CanonicalVacancyFromHH' -ErrorAction SilentlyContinue)) {
        $factoryPath = Join-Path $PSScriptRoot 'hh.factory.psm1'
        if (Test-Path $factoryPath) { Import-Module $factoryPath -DisableNameChecking -Force -ErrorAction SilentlyContinue }
    }
    
    # Use Get-HHProbeVacancies (unified fetcher)
    $allRawItems = Get-HHProbeVacancies -SearchText $SearchText `
        -VacancyPerPage $VacancyPerPage `
        -VacancyPages $VacancyPages `
        -ResumeId $ResumeId `
        -SearchFilters $SearchFilters `
        -RecommendEnabled $RecommendEnabled `
        -RecommendPerPage $RecommendPerPage `
        -RecommendTopTake $RecommendTopTake

    # Canonicalize only - dedup is already handled by Get-HHProbeVacancies
    $allRows = @()
    $countHH = 0
    $countGM = 0

    foreach ($item in $allRawItems) {
        $c = $null
        if ($item.Source -eq 'getmatch') {
            $c = New-CanonicalVacancyFromGetmatch -RawItem $item
            $countGM++
        }
        else {
            $c = New-CanonicalVacancyFromHH -Vacancy $item
            $countHH++
        }
        
        if ($c -is [CanonicalVacancy]) {
            # Update source label for HH items
            if ($c.Meta.Source -ne 'getmatch') {
                $label = Get-HHSourceLabelFromStage -Stage $c.SearchStage -Tiers $c.SearchTiers
                $c.Meta.Source = $label
            }
            $allRows += $c
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
        $Capabilities
    )
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "[Pipeline] Stage 3.1: Pre-enriching synthetic items..." -ForegroundColor Cyan
    
    # Guard clause
    if (-not $Capabilities.CanFetchDetails) {
        Write-Warning "[PreEnrich] fetch module missing, skipping enrichment."
        return
    }

    $syntheticEnriched = 0
    foreach ($row in $Rows) {
        $isHh = ($row.Meta.Source -eq 'hh' -or $row.Meta.Source -eq 'hh_web_recommendation')
        $isWebRec = ($row.SearchTiers -contains 'web_recommendation')
        $isSynthetic = ($row.PSObject.Properties['needs_enrichment'] -and $row.needs_enrichment) -or ($row.Title -like "WebSearch Vacancy*") -or (-not $row.EmployerId)
        
        if ($isHh -and $isWebRec -and $isSynthetic) {
            if ($row.Id -notmatch '^\d+$') { continue }
            try {
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
                    if ($Capabilities.CanGetPlainDesc) {
                        $row.Meta.plain_desc = Get-PlainDesc -Text $fresh.Description
                    }
                    $syntheticEnriched++
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
        $Capabilities,
        [string]$RootConfigPath
    )
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "[Pipeline] Scoring $($Rows.Count) candidates (Baseline)..." -ForegroundColor Cyan
    
    # Load fresh CVProfile for accurate scoring
    $cvProfile = $null
    if ($Capabilities.CanCalculateScore) {
        try {
            if (Get-Command -Name 'Get-HHCVProfile' -ErrorAction SilentlyContinue) {
                $cvProfile = Get-HHCVProfile
                Write-Host "[Pipeline] Loaded fresh CVProfile for scoring" -ForegroundColor Green
            }
        } catch {
            Write-Warning "[Pipeline] Failed to load CVProfile: $($_.Exception.Message)"
        }
    }
    
    # Local LLM Relevance (optional)
    if ($Capabilities.CanUseLocalLLM) {
        Write-Host "[Pipeline] Calculating Local LLM Relevance..." -ForegroundColor Cyan
        $hint = "Candidate"
        if ($cvProfile -and $cvProfile.Title) { $hint = $cvProfile.Title }
        elseif ($cvProfile -and $cvProfile.KeySkills) { $hint = ($cvProfile.KeySkills -join ", ") }
        
        $counter = 0
        foreach ($row in $Rows) {
            $counter++
            if ($counter % 20 -eq 0) { Write-Progress -Activity "Local LLM Scoring" -Status "$counter / $($Rows.Count)" -PercentComplete (($counter / $Rows.Count) * 100) }
            
            $desc = if ($row.Description) { $row.Description } else { $row.Title }
            $desc = $desc -replace '<[^>]+>', ' '
            try {
                $cacheKey = "locrel_" + $row.Id + "_" + $hint.GetHashCode()
                $cachedRel = $null
                if ($Capabilities.CanCache) {
                    try { $cachedRel = Get-HHCacheItem -Collection 'llm_relevance' -Key $cacheKey } catch {}
                }
                
                $rel = 0
                if ($cachedRel -ne $null) {
                    $rel = [double]$cachedRel
                }
                else {
                    $rel = Invoke-LocalLLMRelevance -VacancyText $desc -ProfileHint $hint
                    if ($Capabilities.CanCache) {
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
    if ($Capabilities.CanGetExchangeRates) {
        try { $rates = Get-ExchangeRates } catch {}
    }
    
    if ($Capabilities.CanCalculateScore) {
        foreach ($row in $Rows) {
            Calculate-Score -Vacancy $row -CvSnapshot $cvProfile -ExchangeRates $rates
            $row.Meta.ranking.BaselineScore = $row.Score
            $row.Meta.ranking.FinalScore = $row.Score
        }
    }
    
    $sw.Stop()
    if ($State) { $State.Timings['Scoring'] = $sw.Elapsed }
}

function Invoke-PipelineStageDeepEnrich {
    param(
        [CanonicalVacancy[]]$Rows,
        $State,
        $Capabilities
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
            if ($Capabilities.CanFetchDetails) {
                $detail = Get-VacancyDetail -Id $row.Id
            }
            
            if ($detail) {
                # Merge details back
                if ($detail.description) {
                    $row.Description = $detail.description
                    if ($Capabilities.CanGetPlainDesc) {
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
                if ($Capabilities.CanGetEmployerDetail) {
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
                        if ($Capabilities.CanUpdateRating) {
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
        $Capabilities,
        $TopNRemote = 10
    )
    
    if (-not $Rows) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Tier 1: Local Summaries
    Write-Host "[Pipeline] Tier 1: Local summaries (Batch/Single)..." -ForegroundColor Cyan
    
    if (Get-Command -Name Invoke-BatchLocalSummaries -ErrorAction SilentlyContinue) {
        # Use new batch implementation
        Invoke-BatchLocalSummaries -Rows $Rows -CvSnapshot $CvSnapshot
    }
    else {
        # Fallback to legacy loop
        foreach ($row in $Rows) {
            if (-not $row.Meta.local_summary) {
                $localPlan = Get-HHLocalVacancySummary -Vacancy $row -CvSnapshot $CvSnapshot
                if ($localPlan) { $row.Meta.local_summary = $localPlan }
            }
        }
    }

    # Normalize meta after batch/single processing
    foreach ($row in $Rows) {
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
    if ($Capabilities.CanUseRemoteLLM) {
        Write-Host "[Pipeline] Tier 2: Remote rescoring (Batch/Single)..." -ForegroundColor Cyan
        
        if (Get-Command -Name Invoke-BatchRemoteRanking -ErrorAction SilentlyContinue) {
            Invoke-BatchRemoteRanking -Vacancies $Rows -CvSnapshot $CvSnapshot -CvPayload $CompactCvPayload
        }
        else {
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
        }
        
        # Sort by new score
        $Rows = $Rows | Sort-Object -Property Score -Descending
        
        # Tier 3: Remote Summaries for Top N
        Write-Host "[Pipeline] Tier 3: Remote summaries for top $TopNRemote..." -ForegroundColor Cyan
        $remoteTargets = $Rows | Select-Object -First $TopNRemote
        foreach ($row in $remoteTargets) {
            $remoteRes = $null
            # For Tier 3, use Get-HHRemoteVacancySummary.
            # We assume it is available if CanUseRemoteLLM is true, or verify it specifically.
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
    
    # Ensure LLM module loaded (might be lazy loaded if not enabled globally, but here we assume caller handles it or we check)
    if (-not (Get-Command -Name LLM-EditorsChoicePick -ErrorAction SilentlyContinue)) {
        if (Get-Module -Name 'hh.llm') { Import-Module -Name 'hh.llm' }
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
        if (Get-Module -Name 'hh.config') { Import-Module -Name 'hh.config' }
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
                    if (Get-Module -Name 'hh.llm') { Import-Module -Name 'hh.llm' }
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
            if (Get-Module -Name 'hh.llm') { Import-Module -Name 'hh.llm' }
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

    # Determine absolute path to hh.config.jsonc
    $rootConfigPath = Join-Path $PSScriptRoot 'config/hh.config.jsonc'
    if (-not (Test-Path $rootConfigPath)) {
        # Fallback if PSScriptRoot is not the repo root
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $rootConfigPath = Join-Path $repoRoot 'config/hh.config.jsonc'
    }

    # Resolve Getmatch config early
    # Import hh.fetch for Get-GetmatchConfig if not already loaded (e.g. in parallel runspace)
    if (-not (Get-Command -Name Get-GetmatchConfig -ErrorAction SilentlyContinue)) {
        $modPath = Join-Path $PSScriptRoot 'hh.fetch.psm1'
        if (Test-Path $modPath) { Import-Module $modPath -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    $getmatchConfig = Get-GetmatchConfig
    
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
        RootConfigPath   = $rootConfigPath # Pass the resolved config path
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
                    Import-HHModulesForParallel -ModulesPath $ctx.PSScriptRoot -RootConfigPath $ctx.RootConfigPath # Pass RootConfigPath
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
    if ($getmatchConfig.enabled) {
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
                        Import-HHModulesForParallel -ModulesPath $ctx.PSScriptRoot -RootConfigPath $ctx.RootConfigPath # Pass RootConfigPath
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
                        $value = $prop.Value
                        # Handle arrays properly - convert back to array if needed
                        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                            $gmCfgHash[$prop.Name] = @($value)
                        }
                        else {
                            $gmCfgHash[$prop.Name] = $value
                        }
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
    
    # Execute Sequential (temporary fix for ScriptBlock + error)
    $allResults = @()
    foreach ($job in $fetchJobs) {
        $res = & $job.Script -ctx $fetchContext
        if ($res) { $allResults += $res }
    }
    
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
        [bool]$RecommendEnabled,
        $RecommendPerPage,
        $RecommendTopTake,
        [bool]$LLMEnabled,
        $LLMPickTopN,
        $LlmGateScoreMin,
        $SummaryTopN,
        $SummaryForPicks,
        $ReportStats,
        [bool]$Digest,
        [bool]$Ping,
        [bool]$NotifyDryRun,
        [bool]$NotifyStrict,
        $ReportUrl,
        $RunStartedLocal,
        $LearnSkills,
        $OutputsRoot,
        $RepoRoot,
        $PipelineState,
        [bool]$DebugMode
    )
    
    # Determine absolute path to hh.config.jsonc early in Invoke-HHProbeMain
    $rootConfigPath = Join-Path $PSScriptRoot 'config/hh.config.jsonc'
    if (-not (Test-Path $rootConfigPath)) {
        # Fallback if PSScriptRoot is not the repo root
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $rootConfigPath = Join-Path $repoRoot 'config/hh.config.jsonc'
    }

    # 1. Initialize Modules & Capabilities
    $Caps = Initialize-HHPipelineEnvironment -RepoRoot $RepoRoot -LLMEnabled $LLMEnabled

    # 2. Initialize State
    if (-not $PipelineState) {
        $PipelineState = New-HHPipelineState -StartedLocal $RunStartedLocal -StartedUtc ($RunStartedLocal.ToUniversalTime()) -Flags @{
            Digest = $Digest
            Ping   = $Ping
            LLM    = $LLMEnabled
            Debug  = $DebugMode
        }
    }

    if (Get-Command -Name Set-LlmUsagePipelineState -ErrorAction SilentlyContinue) {
        Set-LlmUsagePipelineState -State $PipelineState
    }
    
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Load Getmatch config if needed
    $getmatchConfig = $null
    try {
        if ($Caps.CanConfig) {
            $getmatchConfig = Get-HHConfigValue -Path @('getmatch')
        }
    } catch {}

    # 3. Fetch & Canonicalize (Stage 1)
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
        -State $PipelineState `
        -RootConfigPath $rootConfigPath # Pass RootConfigPath

    Write-Host "[DEBUG] After StageSearch: allRows.Count = $($allRows.Count)" -ForegroundColor Yellow

    # 4. Pre-enrichment (Stage 2)
    Invoke-PipelineStagePreEnrich -Rows $allRows -State $PipelineState -Capabilities $Caps

    # 5. CV Loading (Prepare)
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

    # 6. Baseline Scoring (Stage 3)
    Invoke-PipelineStageBaselineScoring -Rows $allRows -State $PipelineState -Capabilities $Caps -RootConfigPath $rootConfigPath # Pass RootConfigPath

    # 7. Candidate Selection (Base Set)
    $displayRows = 30
    try { $displayRows = [int](Get-HHConfigValue -Path @('report', 'max_display_rows') -Default 30) } catch {}
    $candidateMult = 1.5
    try { $candidateMult = [double](Get-HHConfigValue -Path @('ranking', 'candidate_multiplier') -Default 1.5) } catch {}
    
    if (-not $allRows) { $allRows = @() }
    Write-Host "[DEBUG] Before Get-BaseSet: allRows.Count = $($allRows.Count)" -ForegroundColor Yellow
    $baseSetInfo = Get-BaseSet -Rows $allRows -MaxDisplayRows $displayRows -CandidateMultiplier $candidateMult
    $candidateRows = @($baseSetInfo.Items)
    if (-not $candidateRows) { $candidateRows = @() }
    Set-HHPipelineValue -State $PipelineState -Path @('BaseSize') -Value $baseSetInfo.BaseSize
    Set-HHPipelineValue -State $PipelineState -Path @('BaseSetCount') -Value $baseSetInfo.BaseCount
    Write-Host "[Pipeline] BASE_SET size=$($baseSetInfo.BaseSize); selected=$($baseSetInfo.BaseCount)" -ForegroundColor Cyan
    Write-Host "[DEBUG] After Get-BaseSet: candidateRows.Count = $($candidateRows.Count)" -ForegroundColor Yellow

    # 8. Deep Enrichment (Stage 4)
    Invoke-PipelineStageDeepEnrich -Rows $candidateRows -State $PipelineState -Capabilities $Caps

    # 9. Advanced Scoring / LLM (Stage 5)
    $tierTop = 10
    try { $tierTop = [int](Get-HHConfigValue -Path @('llm', 'tiered', 'top_n_remote') -Default 10) } catch {}
    if ($candidateRows -and $candidateRows.Count -gt 0) {
        $candidateRows = Invoke-PipelineStageLLMScoring -Rows $candidateRows -State $PipelineState -CvSnapshot $cvSnapshot -CompactCvPayload $compactCvPayload -Capabilities $Caps -TopNRemote $tierTop
    }

    # 10. Fallback Summaries
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
    
    # 11. Picks
    Write-Host "[Pipeline] Selecting picks..." -ForegroundColor Cyan
    if ($candidateRows -and $candidateRows.Count -gt 0) {
        $candidateRows = Apply-Picks -Rows $candidateRows -LLMEnabled:$LLMEnabled -CvPayload $compactCvPayload
    }
    if (-not $candidateRows) { $candidateRows = @() }
    
    $swTotal.Stop()
    $PipelineState.Timings['Total'] = $swTotal.Elapsed
    $PipelineState.Run.Duration = $swTotal.Elapsed

    # 12. Render
    Write-Host "[Pipeline] Rendering reports..."
    if ($Caps.CanRender) {
        if (-not $candidateRows) { $candidateRows = @() }
        Render-Reports -Rows $candidateRows -OutputsRoot $OutputsRoot -PipelineState $PipelineState
    }
    
    # 13. Notify
    if ($Digest) {
        Write-Host "[Pipeline] Sending Telegram digest..."
        if ($Caps.CanNotify) {
            Send-TelegramDigest -RowsTop $candidateRows -PublicUrl $ReportUrl -SearchLabel $SearchText -DryRun:$NotifyDryRun
        }
    }
    if ($Ping) {
        Write-Host "[Pipeline] Sending Telegram ping..."
        if ($Caps.CanNotify) {
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
    
    # 14. Summary
    Show-HHPipelineSummary -State $PipelineState -ReportUrl $ReportUrl
    
    return $PipelineState
}

Export-ModuleMember -Function Get-HHSearchMode, ConvertTo-HHSearchText, Get-CanonicalKeySkills, Get-BaseSet, Invoke-HHProbeMain, Apply-Picks, Invoke-EditorsChoice, Test-HHPipelineHealth, Initialize-HHPipelineEnvironment