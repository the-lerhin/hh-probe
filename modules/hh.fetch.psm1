# hh.fetch.psm1 — vacancy retrieval & API interactions
#Requires -Version 7.5

# Imports (ensure dependencies are available)
# Note: Modules are usually loaded by hh.ps1, but we declare dependencies here for clarity
using module ./hh.models.psm1
# Ensure config module is available for Get-HHConfigValue
if (Get-Module -Name hh.config -ErrorAction SilentlyContinue) {
    # Already loaded
}
else {
    # Try to load relative to this file
    $cfgPath = Join-Path $PSScriptRoot 'hh.config.psm1'
    if (Test-Path $cfgPath) { Import-Module $cfgPath -ErrorAction SilentlyContinue }
}


function Write-LogFetch {
    param([string]$Message, [string]$Level = 'Verbose')
    if (Get-Command -Name 'hh.log\Write-Log' -ErrorAction SilentlyContinue) {
        hh.log\Write-Log -Message $Message -Level $Level -Module 'Fetch'
    }
    elseif (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message $Message -Level $Level -Module 'Fetch'
    }
    else {
        Write-Host "[Fetch] $Message"
    }
}

if (-not $script:HHAreaCountryCache) { $script:HHAreaCountryCache = @{} }

# ==============================================================================
# Helpers
# ==============================================================================

function Get-HHEffectiveSearchFilters {
    [CmdletBinding()]
    param()
    
    $filters = @{}
    
    # 1. Areas
    $areaIds = Get-HHConfigValue -Path @('search', 'area_ids')
    if (-not $areaIds) { $areaIds = Get-HHConfigValue -Path @('search', 'area') } # legacy
    
    if (-not $areaIds) {
        $areaNames = Get-HHConfigValue -Path @('search', 'area_names')
        if ($areaNames) {
            if ($areaNames -is [string]) { $areaNames = @($areaNames) }
            $ids = @()
            foreach ($name in $areaNames) {
                $id = Resolve-HHAreaIdByName -Name $name
                if ($id) { $ids += $id }
                else { Write-LogFetch -Message "Unknown area name: $name" -Level Warning }
            }
            if ($ids.Count -gt 0) { $areaIds = $ids }
        }
    }
    if ($areaIds) { 
        if ($areaIds -is [string] -or $areaIds -is [int]) { $areaIds = @($areaIds) }
        $filters['AreaIds'] = $areaIds 
    }
    
    # 2. Professional Roles
    $roleIds = Get-HHConfigValue -Path @('search', 'professional_role_ids')
    if (-not $roleIds) { $roleIds = Get-HHConfigValue -Path @('search', 'professional_roles') } # legacy
    
    if (-not $roleIds) {
        $roleNames = Get-HHConfigValue -Path @('search', 'role_names')
        if ($roleNames) {
            if ($roleNames -is [string]) { $roleNames = @($roleNames) }
            $ids = @()
            foreach ($name in $roleNames) {
                $id = Resolve-HHRoleIdByName -Name $name
                if ($id) { $ids += $id }
                else { Write-LogFetch -Message "Unknown role name: $name" -Level Warning }
            }
            if ($ids.Count -gt 0) { $roleIds = $ids }
        }
    }
    if ($roleIds) {
        if ($roleIds -is [string] -or $roleIds -is [int]) { $roleIds = @($roleIds) }
        $filters['RoleIds'] = $roleIds
    }
    
    # 3. Other filters
    $filters['Remote'] = [bool](Get-HHConfigValue -Path @('search', 'only_remote') -Default $false)
    $filters['Relocate'] = [bool](Get-HHConfigValue -Path @('search', 'only_relocation') -Default $false)
    
    return $filters
}

function Get-HHAreaCacheKey {
    param([Parameter(Mandatory = $true)][string]$AreaId)
    return "area_$AreaId"
}

function Get-HHAreaDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AreaId)

    if (-not $AreaId) { return $null }
    $key = Get-HHAreaCacheKey -AreaId $AreaId

    $env = $null
    try { $env = Get-HHCacheItem -Collection 'areas' -Key $key -AsEnvelope } catch {}
    if ($env -and $env.Value) {
        return $env.Value
    }

    try {
        $res = Invoke-HhApiRequest -Endpoint "areas/$AreaId" -Method 'GET'
        if ($res) {
            try { Set-HHCacheItem -Collection 'areas' -Key $key -Value $res -Metadata @{ ttl_days = 90 } } catch {}
            return $res
        }
    }
    catch {
        Write-LogFetch -Message "[AREA] failed to load ${AreaId}: $_" -Level Warning
    }

    if ($env -and $env.Value) {
        return $env.Value
    }
    return $null
}

function Resolve-HHAreaCountry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AreaId)

    if (-not $AreaId) { return '' }

    if ($script:HHAreaCountryCache.ContainsKey($AreaId)) {
        return $script:HHAreaCountryCache[$AreaId]
    }

    $current = $AreaId
    $country = ''
    while ($current) {
        $area = Get-HHAreaDetail -AreaId $current
        if (-not $area) { break }
        $name = ''
        $parent = ''
        try { $name = [string]$area.name } catch {}
        try { $parent = [string]$area.parent_id } catch {}

        if (-not $parent) {
            # Reached top-level area (country)
            if ($name) {
                $country = $name
            }
            break
        }
        $current = $parent
    }

    if (-not $country) { $country = '' }
    $script:HHAreaCountryCache[$AreaId] = $country
    return $country
}

# ==============================================================================
# Main Fetch Functions
# ==============================================================================

function Search-Vacancies {
    [CmdletBinding()]
    param(
        [string]$QueryText,
        [int]$PerPage = 20,
        [int]$MaxPages = 5
    )
    
    $filters = Get-HHEffectiveSearchFilters
    $results = @()
    
    for ($p = 0; $p -lt $MaxPages; $p++) {
        # Build URL params
        $params = @{
            text     = $QueryText
            per_page = $PerPage
            page     = $p
        }
        
        if ($filters['AreaIds']) { $params['area'] = $filters['AreaIds'] }
        if ($filters['RoleIds']) { $params['professional_role'] = $filters['RoleIds'] }
        
        # Add other config-driven params
        $mapping = @{
            'specialization'   = 'specialization'
            'schedule'         = 'schedule'
            'employment'       = 'employment'
            'experience'       = 'experience'
            'only_with_salary' = 'only_with_salary'
            'salary'           = 'salary'
            'currency'         = 'currency'
            'period'           = 'period'
            'order_by'         = 'order_by'
        }
        
        foreach ($k in $mapping.Keys) {
            $val = Get-HHConfigValue -Path @('search', $k)
            if ($val) { $params[$mapping[$k]] = $val }
        }
        
        if ($filters['Remote']) { $params['schedule'] = 'remote' } # Simplify for now, could be additive
        if ($filters['Relocate']) { $params['relocation'] = 'living_or_relocation' }
        # Note: relocation is tricky in search api, usually handled by label or separate param?
        # HH API: label=only_with_salary, etc.
        
        # Construct Query String
        $qs = @()
        foreach ($k in $params.Keys) {
            $v = $params[$k]
            if ($v -is [array]) {
                foreach ($item in $v) { $qs += "$k=$item" }
            }
            else {
                $qs += "$k=$v"
            }
        }
        $endpoint = "vacancies?" + ($qs -join '&')
        
        Write-Host "DEBUG: Search-Vacancies calling $endpoint" -ForegroundColor Magenta
        Write-LogFetch -Message ("Searching page {0}/{1}: {2}" -f ($p + 1), $MaxPages, $endpoint) -Level Host
        
        try {
            $resp = Invoke-HhApiRequest -Endpoint $endpoint -Method 'GET'
            Write-Host "DEBUG: Search-Vacancies response items: $(if ($resp.items) { $resp.items.Count } else { 'null' })" -ForegroundColor Magenta
            if ($resp.items) {
                Write-LogFetch -Message ("Found {0} items on page {1}" -f $resp.items.Count, ($p + 1)) -Level Host
                foreach ($item in $resp.items) {
                    if (-not $item.search_stage) {
                        $item | Add-Member -NotePropertyName 'search_stage' -NotePropertyValue 'general' -Force
                    }
                    $item | Add-Member -NotePropertyName 'search_tiers' -NotePropertyValue @('general') -Force
                    $results += $item
                }
            }
            if (($resp.page + 1) -ge $resp.pages) { break }
        }
        catch {
            $isAuthError = ($_.Exception.Message -match '401|403') -or 
            ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in 401, 403)
            
            if ($isAuthError) {
                Write-LogFetch -Message "Search failed with Auth (401/403), retrying anonymously..." -Level Host
                try {
                    $reqArgs = @{ RequireAuth = $false }
                    $resp = Invoke-HhApiRequest -Endpoint $endpoint -Method 'GET' @reqArgs
                    if ($resp.items) {
                        Write-LogFetch -Message ("Found {0} items (Anonymous) on page {1}" -f $resp.items.Count, ($p + 1)) -Level Host
                        foreach ($item in $resp.items) {
                            if (-not $item.search_stage) {
                                $item | Add-Member -NotePropertyName 'search_stage' -NotePropertyValue 'general' -Force
                            }
                            $item | Add-Member -NotePropertyName 'search_tiers' -NotePropertyValue @('general') -Force
                            $results += $item
                        }
                    }
                    if (($resp.page + 1) -ge $resp.pages) { break }
                }
                catch {
                    Write-LogFetch -Message ("Anonymous search failed on page {0}: {1}" -f $p, $_) -Level Warning
                }
            }
            else {
                Write-LogFetch -Message ("Search failed on page {0}: {1}" -f $p, $_) -Level Warning
            }
        }
    }
    
    return $results
}

function Get-HHSimilarVacancies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResumeId,
        [int]$PerPage = 50,
        [int]$Pages = 1
    )
    
    if (-not $ResumeId) {
        Write-LogFetch -Level Warning -Message "[Search][HH] skipping similar: no resume id."
        return @()
    }

    $results = @()
    for ($p = 0; $p -lt $Pages; $p++) {
        # endpoint: /resumes/{resume_id}/similar_vacancies
        $endpoint = "resumes/$ResumeId/similar_vacancies?per_page=$PerPage&page=$p"
        
        try {
            Write-LogFetch -Message "Fetching similar vacancies page $($p+1)/$Pages" -Level Verbose
            $resp = Invoke-HhApiRequest -Endpoint $endpoint -Method 'GET'
            if ($resp.items) {
                foreach ($item in $resp.items) {
                    if (-not $item.search_stage) {
                        $item | Add-Member -NotePropertyName 'search_stage' -NotePropertyValue 'similar' -Force
                    }
                    # Add tier info
                    $item | Add-Member -NotePropertyName 'search_tiers' -NotePropertyValue @('similar') -Force
                    $results += $item
                }
            }
            if (($resp.page + 1) -ge $resp.pages) { break }
        }
        catch {
            Write-LogFetch -Message ("Similar search failed on page {0}: {1}" -f $p, $_) -Level Warning
        }
    }
    return $results
}

function Get-HHWebRecommendations {
    [CmdletBinding()]
    param(
        [int]$PerPage = 20,
        [int]$MaxPages = 5,
        [string]$ResumeId = ''
    )
    
    # Check config for web scraping
    $scrapeCfg = $null
    if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
        $scrapeCfg = Get-HHConfigValue -Path @('search', 'recommendations', 'web_scraping') -Default $null
    }
    
    $results = @()
    
    # 1. Try API First - DISABLED/REMOVED to strictly follow FRD-1.1/SDD-4.6 scraping requirement
    # The API endpoint /recommendations/vacancies is not part of the spec and should not be used.
    # If needed in future, update SDD first.
    # -------------------------------------------------------------------------------------------
    
    # 2. Web Scraping (Primary Method per FRD-1.1)
    if ($scrapeCfg -and $scrapeCfg.enabled) {
        Write-LogFetch -Message "Attempting Web Scraping for Recommendations..." -Level Host
        
        $baseUrl = "https://hh.ru/vacancies/recommendations"
        if (-not [string]::IsNullOrWhiteSpace($ResumeId)) {
            $baseUrl = "https://hh.ru/search/vacancy?resume=$ResumeId"
        }
        # Cookie is critical here
        $cookie = $scrapeCfg.cookie_hhtoken
        $xsrf = $scrapeCfg._xsrf
        $ua = $scrapeCfg.user_agent
        
        if (-not $cookie) {
            Write-LogFetch -Message "Web Scraping skipped: 'cookie_hhtoken' not set in config" -Level Warning
            return $results
        }

        # Use configured pages if available
        $scrapePages = $MaxPages
        if ($scrapeCfg.pages) { $scrapePages = [int]$scrapeCfg.pages }
        
        # We can't page easily without knowing the cursor, but let's try page=0,1...
        for ($p = 0; $p -lt $scrapePages; $p++) {
            # FIX: Do not use per_page parameter for scraping, only page (0-indexed)
            $url = if ($baseUrl -match '\?') { "$baseUrl&page=$p" } else { "$baseUrl?page=$p" }
            try {
                $cookieVal = "hhtoken=$cookie"
                if ($xsrf) { $cookieVal += "; _xsrf=$xsrf" }
                
                $headers = @{
                    'User-Agent' = $ua
                    'Cookie'     = $cookieVal
                }
                 
                $html = Invoke-HttpRequest -Uri $url -Method 'GET' -Headers $headers -TimeoutSec 15 -OperationName 'ScrapeRecs'
                $content = $null
                if ($html) {
                    if ($html.PSObject.Properties['Content']) {
                        $content = $html.Content
                    }
                    else {
                        $content = [string]$html
                    }
                }
                
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    # Improved regex to handle relative URLs (e.g. /vacancy/123) and absolute ones
                    $matches = [regex]::Matches($content, 'href="([^"]*\/vacancy\/(\d+)[^"]*)"')
                    $cnt = 0
                    foreach ($m in $matches) {
                        $vid = $m.Groups[2].Value
                        if ($vid -in $results.id) { continue } # Dedup
                         
                        # Create a stub vacancy object
                        $obj = [pscustomobject]@{
                            id               = $vid
                            name             = "WebSearch Vacancy $vid" # Placeholder title, will be enriched later
                            alternate_url    = "https://hh.ru/vacancy/$vid"
                            search_stage     = 'web_recommendation'
                            search_tiers     = @('web_recommendation')
                            needs_enrichment = $true
                            published_at     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz") # Placeholder to avoid warnings before enrichment
                            employer         = @{ id = "0"; name = "Loading..." } # Placeholder
                        }
                        $results += $obj
                        $cnt++
                        if ($results.Count -ge $PerPage) { break }
                    }
                    Write-LogFetch -Message "Scraped $cnt vacancies from page $p" -Level Verbose
                    if ($cnt -eq 0) { break }
                }
            }
            catch {
                Write-LogFetch -Message "Web Scraping failed on page ${p}: $_" -Level Warning
                break
            }
        }
    }
    
    return $results
}

function Get-HHHybridVacancies {
    [CmdletBinding()]
    param(
        [string]$ResumeId,
        [string]$QueryText,
        [int]$Limit = 20,
        [hashtable]$Config
    )
    
    $itemsSimilar = @()
    $itemsGeneral = @()
    $itemsRec = @()
    
    $perPage = 20
    if ($Config -and $Config.ContainsKey('PerPage')) { $perPage = $Config['PerPage'] }
    elseif ($Config -and $Config.ContainsKey('RecommendPerPage')) { $perPage = $Config['RecommendPerPage'] }
    
    # Re-calculate pages based on Limit
    $pages = [Math]::Ceiling($Limit / $perPage)
    if ($pages -lt 1) { $pages = 1 }

    # 1. Run Fetch Tasks in Parallel
    $results = @()
    
    # Define fetch jobs
    $jobs = @()
    
    # HH Similar
    if ($ResumeId) {
        # IMPORTANT: Use @(...) to force array wrapping for args, ensuring splatting works correctly in scriptblock
        $jobs += [pscustomobject]@{ Name = 'HH_Similar'; Script = { Get-HHSimilarVacancies -ResumeId $args[0] -PerPage $args[1] -Pages $args[2] }; Args = @($ResumeId, $perPage, $pages) }
    }
    
    # HH Recs
    if ($Config -and $Config['RecommendEnabled']) {
        $jobs += [pscustomobject]@{ Name = 'HH_Recs'; Script = { Get-HHWebRecommendations -PerPage $args[0] -MaxPages $args[1] -ResumeId $args[2] }; Args = @($perPage, $pages, $ResumeId) }
    }
    
    # HH General
    if ($QueryText) {
        $jobs += [pscustomobject]@{ Name = 'HH_General'; Script = { Search-Vacancies -QueryText $args[0] -PerPage $args[1] -MaxPages $args[2] }; Args = @($QueryText, $perPage, $pages) }
    }
    
    # Execute jobs (sequential for now to simulate parallel structure until PoshRSJob/ThreadJob is standardized)
    # TODO: Replace with real parallel execution when infrastructure allows (SDD-6.3)
    foreach ($job in $jobs) {
        try {
            Write-LogFetch -Message "Starting fetch job: $($job.Name)" -Level Verbose
            # Ensure Args is an array before splatting
            $jobArgs = @($job.Args)
            $res = & $job.Script @jobArgs
            
            if ($job.Name -eq 'HH_Similar') { $itemsSimilar = $res }
            elseif ($job.Name -eq 'HH_Recs') { $itemsRec = $res }
            elseif ($job.Name -eq 'HH_General') { $itemsGeneral = $res }
        }
        catch {
            Write-LogFetch -Message "Job $($job.Name) failed: $_" -Level Error
        }
    }
    
    # 4. Dedup
    # Priority: similar > recommendation > general.
    $dedup = @{}
    $finalList = @()
    
    # Helper to add
    $AddList = {
        param($list, $tierName)
        foreach ($i in $list) {
            $id = $i.id
            if (-not $dedup.ContainsKey($id)) {
                $dedup[$id] = $i
                # Ensure search_tiers tracks all sources if we merged (but here we pick first winner)
                # Actually, we might want to merge tiers if same item found in multiple?
                # For now, first wins.
                $finalList += $i
            }
            else {
                # Merge tier info
                if ($dedup[$id].search_tiers -notcontains $tierName) {
                    $dedup[$id].search_tiers += $tierName
                }
            }
        }
    }
    
    # Apply in priority order
    . $AddList $itemsSimilar 'similar'
    . $AddList $itemsRec 'web_recommendation'
    . $AddList $itemsGeneral 'general'
    
    # Return wrapped result
    return [PSCustomObject]@{
        Items   = $finalList
        Count   = $finalList.Count
        Sources = @{
            Similar         = $itemsSimilar.Count
            Recommendations = $itemsRec.Count
            General         = $itemsGeneral.Count
        }
    }
}

function Get-VacancyDetail {
    <#
    .SYNOPSIS
    Fetches full vacancy details from HH API with caching.
    
    .DESCRIPTION
    Retrieves complete vacancy information including description, key_skills, and employer details.
    Uses LiteDB caching with 3-day TTL. Includes country enrichment from area hierarchy.
    
    .PARAMETER Id
    Vacancy ID
    
    .OUTPUTS
    Vacancy object with full details or $null if not found
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)
    
    $key = [string]$Id
    
    # Try cache first
    $env = $null
    try { $env = Get-HHCacheItem -Collection 'vacancies' -Key $key -AsEnvelope } catch {}
    if ($env -and $env.Value) {
        try { if ($global:CacheStats) { $global:CacheStats['vac_cached'] = [int]($global:CacheStats['vac_cached'] ?? 0) + 1 } } catch {}
        return $env.Value
    }
    
    # Fetch from API
    try {
        $res = Invoke-HhApiRequest -Endpoint "vacancies/$Id" -Method 'GET'
        if ($res) {
            # Log key_skills count
            $ks = 0
            try { if ($res.key_skills) { $ks = (@($res.key_skills)).Count } } catch {}
            try { Write-LogFetch -Message "[DETAIL] fetched $Id, key_skills=$ks" -Level Verbose } catch {}
            
            # Cache with 3-day TTL
            try { Set-HHCacheItem -Collection 'vacancies' -Key $key -Value $res -Metadata @{ ttl_days = 3 } } catch {}
            try { if ($global:CacheStats) { $global:CacheStats['vac_fetched'] = [int]($global:CacheStats['vac_fetched'] ?? 0) + 1 } } catch {}
            
            return $res
        }
    }
    catch {
        Write-LogFetch -Message "[DETAIL] failed $Id : $_" -Level Warning
    }
    
    return $null
}

function Get-EmployerDetail {
    <#
    .SYNOPSIS
    Fetches employer details from HH API with caching.
    
    .DESCRIPTION
    Retrieves employer information including rating, open_vacancies, and industry.
    Uses LiteDB caching with 30-day TTL. Refreshes cache if empty data is found.
    
    .PARAMETER Id
    Employer ID
    
    .PARAMETER RefreshWhenEmpty
    If true, refetches when cached data has no meaningful content
    
    .OUTPUTS
    Employer object or $null if not found
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [bool]$RefreshWhenEmpty = $true
    )
    
    $key = [string]$Id
    
    # Try cache first
    $env = $null
    try { $env = Get-HHCacheItem -Collection 'employers' -Key $key -AsEnvelope } catch {}
    if ($env -and $env.Value) {
        $cached = $env.Value
        
        # Check if cached data has meaningful content
        $cachedOpen = 0
        $cachedIndustry = ''
        try { $cachedOpen = [int]($cached.open_vacancies ?? $cached.open ?? 0) } catch {}
        try {
            if ($cached.industry -and $cached.industry.name) {
                $cachedIndustry = [string]$cached.industry.name
            }
            elseif ($cached.industries -and $cached.industries.Count -gt 0 -and $cached.industries[0].name) {
                $cachedIndustry = [string]$cached.industries[0].name
            }
        }
        catch {}
        
        $hasMeaningful = ($cachedOpen -gt 0) -or (-not [string]::IsNullOrWhiteSpace($cachedIndustry))
        if ($hasMeaningful -or (-not $RefreshWhenEmpty)) {
            try { if ($global:CacheStats) { $global:CacheStats['emp_cached'] = [int]($global:CacheStats['emp_cached'] ?? 0) + 1 } } catch {}
            return $cached
        }
    }
    
    # Fetch from API
    try {
        $res = Invoke-HhApiRequest -Endpoint "employers/$Id" -Method 'GET'
        if ($res) {
            $open = 0
            try { $open = [int]($res.open_vacancies ?? $res.open ?? 0) } catch {}
            try { Write-LogFetch -Message "[EMP] employer $Id → open=$open" -Level Verbose } catch {}

            # Remove any rating information to avoid relying on HH API for employer scores
            try { $null = $res.PSObject.Properties.Remove('rating') } catch {}

            # Cache with 30-day TTL
            try { Set-HHCacheItem -Collection 'employers' -Key $key -Value $res -Metadata @{ ttl_days = 30 } } catch {}
            try { if ($global:CacheStats) { $global:CacheStats['emp_fetched'] = [int]($global:CacheStats['emp_fetched'] ?? 0) + 1 } } catch {}
            
            return $res
        }
    }
    catch {
        Write-LogFetch -Message "[EMP] employer $Id failed: $_" -Level Warning
    }
    
    # Return cached stub as last resort
    if ($env -and $env.Value) { return $env.Value }
    return $null
}

function Parse-EmployerRatingHtml {
    param([string]$Html)
    
    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }
    
    # <div data-qa="employer-review-small-widget-total-rating" class="...">4.5</div>
    $rating = 0.0
    # Regex improved to allow attributes (like class) after data-qa before the closing >
    $match = [regex]::Match($Html, 'data-qa="employer-review-small-widget-total-rating"[^>]*>([\d\.,]+)<')
    if ($match.Success) {
        $val = $match.Groups[1].Value.Replace(',', '.')
        try { $rating = [double]$val } catch {}
    }
    
    if ($rating -gt 0) {
        return [PSCustomObject]@{ Rating = $rating }
    }
    return $null
}

function Get-EmployerRatingScrape {
    [CmdletBinding()]
    param([string]$EmployerId)
    
    if (-not $EmployerId) { return $null }
    
    # Scrape https://hh.ru/employer/{id}
    # We need to be careful with scraping. 
    # Use a gentle timeout.
    
    $url = "https://hh.ru/employer/$EmployerId"
    try {
        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        $resp = Invoke-HttpRequest -Uri $url -Method 'GET' -Headers @{ 'User-Agent' = $ua } -TimeoutSec 10 -OperationName 'ScrapeEmployer'

        $htmlContent = ''
        if ($resp) {
            if ($resp -is [string]) {
                $htmlContent = $resp
            }
            elseif ($resp.PSObject.Properties['Content']) {
                $htmlContent = $resp.Content
            }
            elseif ($resp.Content) {
                $htmlContent = $resp.Content
            }
            else {
                try { $htmlContent = ($resp | Out-String) } catch {}
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($htmlContent)) {
            return Parse-EmployerRatingHtml -Html $htmlContent
        }
    }
    catch {
        Write-LogFetch -Message "Failed to scrape employer ${EmployerId}: $_" -Level Debug
    }
    return $null
}

function Update-EmployerRating {
    param([Parameter(Mandatory)][object]$Vacancy)
    
    # Ensure strict source check: Only HH vacancies get HH ratings
    if ($Vacancy.Meta -and $Vacancy.Meta.Source -and ($Vacancy.Meta.Source -notmatch '^hh')) { return }
    if (-not $Vacancy.Employer.Id) { return }
    
    # FR-6.1: Canonical rating must come ONLY from scrape.
    # Previous API ratings are cleared if scrape fails.
    
    try {
        $ratingObj = Get-EmployerRatingScrape -EmployerId $Vacancy.Employer.Id
        if ($ratingObj -and $ratingObj.Rating -gt 0) {
            $Vacancy.EmployerRating = $ratingObj.Rating
            $Vacancy.Employer.Rating = $ratingObj.Rating
        }
        else {
            # Scrape failed or no rating found.
            # Ensure we don't keep any stale API rating.
            # If the field was populated from API, clear it.
            $Vacancy.EmployerRating = $null
            if ($Vacancy.Employer) { $Vacancy.Employer.Rating = $null }
            
            Write-LogFetch -Message "Employer $($Vacancy.Employer.Id) scrape returned no rating (setting to `$null`)" -Level Debug
        }
    }
    catch {
        # On error, also ensure $null
        $Vacancy.EmployerRating = $null
        if ($Vacancy.Employer) { $Vacancy.Employer.Rating = $null }
    }
}

function Get-SkillsVocab {
    return @{}
}

# ==============================================================================
# Getmatch.ru Integration (Phase 1)
# ==============================================================================

function Get-GetmatchConfig {
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-HHConfigValue' -ErrorAction SilentlyContinue) {
        $cfg = Get-HHConfigValue -Path @('getmatch') -Default @{}
        if (-not $cfg) { return @{} }
        return $cfg
    }
    return @{}
}

function Get-GetmatchQueryUrl {
    [CmdletBinding()]
    param(
        [hashtable]$GetmatchConfig,
        [int]$Page = 1
    )

    $baseUrl = $GetmatchConfig['base_url']
    if (-not $baseUrl) { $baseUrl = 'https://getmatch.ru/vacancies' }

    # Start with base params
    $p = New-Object System.Collections.Generic.List[string]
  
    # Page (API usually 1-based)
    $p.Add("p=$Page")

    if ($GetmatchConfig['params']) {
        $params = $GetmatchConfig['params']
        foreach ($key in $params.Keys) {
            $val = $params[$key]
            if ($val -is [array] -or $val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                foreach ($v in $val) {
                    $p.Add("$key=$v")
                }
            }
            else {
                $p.Add("$key=$val")
            }
        }
    }

    $queryString = $p -join '&'
    if ($baseUrl -match '\?') {
        return $baseUrl + "&" + $queryString
    }
    return $baseUrl + "?" + $queryString
}

function Get-GetmatchQueryUrls {
    [CmdletBinding()]
    param(
        [hashtable]$GetmatchConfig
    )
    
    $urls = @()
    $pages = 1
    if ($GetmatchConfig.ContainsKey('pages')) { $pages = [int]$GetmatchConfig['pages'] }
    if ($pages -lt 1) { $pages = 1 }
    
    for ($i = 1; $i -le $pages; $i++) {
        $urls += Get-GetmatchQueryUrl -GetmatchConfig $GetmatchConfig -Page $i
    }
    return $urls
}

function Get-GetmatchVacanciesRaw {
    [CmdletBinding()]
    param(
        [hashtable]$GetmatchConfig
    )

    $results = @()
  
    $urls = Get-GetmatchQueryUrls -GetmatchConfig $GetmatchConfig
  
    $i = 0
    foreach ($url in $urls) {
        $i++
        if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
            Write-LogFetch -Message ("[Getmatch] Fetching URL {0}/{1}: {2}" -f $i, $urls.Count, $url) -Level Verbose
        }

        try {
            # Use generic HTTP invoker with rate limiting
            $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
      
            $response = Invoke-HttpRequest -Uri $url -Method 'GET' -Headers @{
                'User-Agent' = $ua
            } -TimeoutSec 30 -ApplyRateLimit -OperationName 'Getmatch'

            if ($response) {
                $content = $response
                if ($content.Content) { $content = $content.Content }
                $content = [string]$content
        
                # Try to parse JSON from <script id="serverApp-state">
                $jsonMatch = [regex]::Match($content, '<script id="serverApp-state" type="application/json">(.+?)</script>', 'Singleline')
        
                $foundJson = $false
                if ($jsonMatch.Success) {
                    try {
                        $jsonStr = $jsonMatch.Groups[1].Value
                        $data = $jsonStr | ConvertFrom-Json
                
                        # Find the key for vacancies/offers
                        # Key format: G.json.https://getmatch.ru/api/offers?....
                        $offersKey = $null
                        foreach ($k in $data.PSObject.Properties.Name) {
                            if ($k -match 'api/offers' -or $k -match 'api/vacancies') {
                                $offersKey = $k
                                break
                            }
                        }
                
                        if ($offersKey) {
                            $body = $data.$offersKey.body
                            $items = @()
                            if ($body.offers) { $items = $body.offers }
                            elseif ($body.vacancies) { $items = $body.vacancies }
                    
                            foreach ($offer in $items) {
                                $fullUrl = ""
                                if ($offer.url) { $fullUrl = "https://getmatch.ru$($offer.url)" }
                        
                                # Locations
                                $locs = @()
                                if ($offer.display_locations) {
                                    foreach ($l in $offer.display_locations) {
                                        if ($l.city) { $locs += $l.city }
                                        elseif ($l.country) { $locs += $l.country }
                                    }
                                }
                                if ($offer.remote_options) { $locs += $offer.remote_options }
                                $locText = $locs -join ', '
                        
                                # Salary
                                $salText = $null
                                if ($offer.salary_display_from -or $offer.salary_display_to) {
                                    $curr = $offer.salary_currency
                                    if (-not $curr) { $curr = "" }
                                    if ($offer.salary_display_from -and $offer.salary_display_to) {
                                        $salText = "$($offer.salary_display_from) - $($offer.salary_display_to) $curr"
                                    }
                                    elseif ($offer.salary_display_from) {
                                        $salText = "from $($offer.salary_display_from) $curr"
                                    }
                                    else {
                                        $salText = "up to $($offer.salary_display_to) $curr"
                                    }
                                }
                        
                                # Employer Logo & URL
                                $logo = $null
                                if ($offer.company) {
                                    if ($offer.company.logo) { $logo = $offer.company.logo }
                                    elseif ($offer.company.logotype) { 
                                        $logo = "https://getmatch.ru/uploads/companies_logos/" + $offer.company.logotype 
                                    }
                                }
                                
                                $empUrl = $null
                                if ($offer.company -and $offer.company.url) {
                                    $empUrl = "https://getmatch.ru" + $offer.company.url
                                }

                                # Description & Stack
                                $desc = $offer.offer_description
                                $stack = @()
                                if ($offer.stack) { $stack = $offer.stack }
                        
                                # Try to find stack in one_day_offer_content_v3 if empty
                                if (($null -eq $stack -or $stack.Count -eq 0) -and $offer.one_day_offer_content_v3 -and $offer.one_day_offer_content_v3.block_two -and $offer.one_day_offer_content_v3.block_two.stack) {
                                    $stack = $offer.one_day_offer_content_v3.block_two.stack
                                }
                        
                                $obj = [pscustomobject]@{
                                    Source       = 'getmatch'
                                    Title        = $offer.position
                                    EmployerName = $offer.company?.name
                                    EmployerLogo = $logo
                                    EmployerUrl  = $empUrl
                                    SalaryText   = $salText
                                    LocationText = $locText
                                    Url          = $fullUrl
                                    PostedAtText = $offer.published_at
                                    Description  = $desc
                                    Skills       = $stack
                                    EnglishLevel = $offer.english_level
                                    RawObject    = $offer
                                    search_tiers = @('getmatch')
                                }
                                $results += $obj
                            }
                            $foundJson = $true
                        }
                    }
                    catch {
                        if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                            Write-LogFetch -Message "[Getmatch] JSON parse error on $($url): $_" -Level Warning
                        }
                    }
                }
        
                if (-not $foundJson) {
                    if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                        Write-LogFetch -Message "[Getmatch] Falling back to HTML scraping for $url" -Level Verbose
                    }
                    # Fallback to regex scraping (Improved logic)
                    $linkPattern = '<a\s+(?:[^>]*?\s+)?href="(/vacancies/\d+[^\"]*)"[^>]*>(.*?)</a>'
                    $linkMatches = [regex]::Matches($content, $linkPattern, 'IgnoreCase')
            
                    for ($i = 0; $i -lt $linkMatches.Count; $i++) {
                        $m = $linkMatches[$i]
                        $relUrl = $m.Groups[1].Value
                        $titleRaw = $m.Groups[2].Value -replace '<[^>]+>', '' -replace '\s+', ' '
                        $titleRaw = $titleRaw.Trim()
                
                        if (-not $relUrl -or -not $titleRaw) { continue }
                
                        $fullUrl = "https://getmatch.ru$relUrl"
                
                        # Determine boundaries to isolate this vacancy card
                        $prevMatchEnd = 0
                        if ($i -gt 0) { $prevMatchEnd = $linkMatches[$i - 1].Index + $linkMatches[$i - 1].Length }
                
                        $nextMatchStart = $content.Length
                        if ($i -lt $linkMatches.Count - 1) { $nextMatchStart = $linkMatches[$i + 1].Index }
                
                        # 1. Find Employer Name
                        $employer = $null
                        
                        # Look in 'After' segment (Title -> Company structure)
                        # Structure: <div class="b-vacancy-card-company"><span>Name</span></div>
                        $companyRegex = '<div[^>]*class="[^"]*b-vacancy-card-company[^"]*"[^>]*>[\s\S]*?<span[^>]*>(.*?)</span>'
                        $cMatch = [regex]::Match($afterSegment, $companyRegex, 'IgnoreCase')
                        
                        if ($cMatch.Success) {
                            $employer = $cMatch.Groups[1].Value -replace '<[^>]+>', ''
                            $employer = $employer.Trim()
                        }
                        
                        # Fallback: Check 'Before' segment (unlikely but safe)
                        if (-not $employer -and $preLinkLen -gt 0) {
                            $cMatchBefore = [regex]::Match($beforeSegment, $companyRegex, 'RightToLeft, IgnoreCase')
                            if ($cMatchBefore.Success) {
                                $employer = $cMatchBefore.Groups[1].Value -replace '<[^>]+>', ''
                                $employer = $employer.Trim()
                            }
                        }
                
                        # 2. Find Logo (Closest Before or After)
                        $logoUrl = $null
                        $logoRegex = '<img[^>]+src="([^"]*getmatch\.ru/uploads/companies_logos/[^"]*)"'
                
                        # Segments
                        $beforeSegment = ""
                        if ($preLinkLen -gt 0) { $beforeSegment = $content.Substring($prevMatchEnd, $preLinkLen) }
                
                        $afterLen = $nextMatchStart - ($m.Index + $m.Length)
                        if ($afterLen -lt 0) { $afterLen = 0 }
                        $afterSegment = $content.Substring($m.Index + $m.Length, $afterLen)
                
                        $bestDist = 100000
                
                        # Check Before (RightToLeft)
                        $logoMatchBefore = [regex]::Match($beforeSegment, $logoRegex, 'RightToLeft, IgnoreCase')
                        if ($logoMatchBefore.Success) {
                            $d = $beforeSegment.Length - ($logoMatchBefore.Index + $logoMatchBefore.Length)
                            if ($d -lt $bestDist) {
                                $bestDist = $d
                                $logoUrl = $logoMatchBefore.Groups[1].Value
                            }
                        }
                
                        # Check After (LeftToRight)
                        $logoMatchAfter = [regex]::Match($afterSegment, $logoRegex, 'IgnoreCase')
                        if ($logoMatchAfter.Success) {
                            $d = $logoMatchAfter.Index
                            if ($d -lt $bestDist) {
                                $bestDist = $d
                                $logoUrl = $logoMatchAfter.Groups[1].Value
                            }
                        }

                        # Context for Salary/Location
                        # We prioritize the 'After' segment as details are usually below title/link.
                        # We also check 'Before' segment but only close to the link to avoid previous card's footer.
                
                        $textAfter = $afterSegment -replace '<[^>]+>', ' ' -replace '\s+', ' '
                        $textBefore = $beforeSegment -replace '<[^>]+>', ' ' -replace '\s+', ' '
                
                        $salary = $null
                        $location = $null
                
                        # Salary
                        $salMatchAfter = [regex]::Match($textAfter, '(?:от\s+)?\d[\d\s]*000\s*(?:₽|rub|€|\$|eur|usd)', 'IgnoreCase')
                        if ($salMatchAfter.Success) {
                            $salary = $salMatchAfter.Value.Trim()
                        }
                        else {
                            # Check Before (last 200 chars)
                            $textBeforeClose = $textBefore
                            if ($textBefore.Length -gt 200) {
                                $textBeforeClose = $textBefore.Substring($textBefore.Length - 200)
                            }
                            $salMatchBefore = [regex]::Match($textBeforeClose, '(?:от\s+)?\d[\d\s]*000\s*(?:₽|rub|€|\$|eur|usd)', 'IgnoreCase')
                            if ($salMatchBefore.Success) {
                                $salary = $salMatchBefore.Value.Trim()
                            }
                        }
                
                        # Location
                        $locs = @()
                        # Check After
                        if ($textAfter -match 'Москва') { $locs += 'Москва' }
                        if ($textAfter -match 'Удалённо|Remote') { $locs += 'Remote' }
                        if ($textAfter -match 'Relocate|Переезд') { $locs += 'Relocate' }
                
                        # If nothing found After, check Before (close)
                        if ($locs.Count -eq 0) {
                            $textBeforeClose = $textBefore
                            if ($textBefore.Length -gt 200) {
                                $textBeforeClose = $textBefore.Substring($textBefore.Length - 200)
                            }
                            if ($textBeforeClose -match 'Москва') { $locs += 'Москва' }
                            if ($textBeforeClose -match 'Удалённо|Remote') { $locs += 'Remote' }
                            if ($textBeforeClose -match 'Relocate|Переезд') { $locs += 'Relocate' }
                        }
                
                        if ($locs.Count -gt 0) { $location = $locs -join ', ' }
                
                        # Use textAfter as RawContext for display/debug as it likely contains the desc
                        $textOnly = $textAfter
                
                        $obj = [pscustomobject]@{
                            Source       = 'getmatch'
                            Title        = $titleRaw
                            EmployerName = $employer
                            EmployerLogo = $logoUrl
                            SalaryText   = $salary
                            LocationText = $location
                            Url          = $fullUrl
                            PostedAtText = (Get-Date -Format "yyyy-MM-dd") 
                            RawContext   = $textOnly 
                            search_tiers = @('getmatch')
                        }
                        $results += $obj
                    }
                }
            }
        }
        catch {
            if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                Write-LogFetch -Message ("[Getmatch] Failed to fetch URL {0}: {1}" -f $url, $_) -Level Warning
            }
        }
    
        Start-Sleep -Milliseconds 500
    }

    return $results
}

function Get-ExchangeRates {
    [CmdletBinding()]
    param()

    $cacheKey = "currency_rates"
    
    # 1. Try Cache
    if (Get-Command -Name Get-HHCacheItem -ErrorAction SilentlyContinue) {
        try {
            $cached = Get-HHCacheItem -Collection 'currency' -Key $cacheKey
            if ($cached -and $cached -is [hashtable]) {
                return $cached
            }
        } catch {
            if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                Write-LogFetch -Message "Failed to read currency cache: $_" -Level Warning
            }
        }
    }

    # 2. Fetch
    # Base rates (RUB relative)
    $rates = @{ 'RUB' = 1.0; 'RUR' = 1.0 } 
    
    try {
        $url = "https://www.cbr-xml-daily.ru/daily_json.js"
        
        $resp = $null
        if (Get-Command -Name Invoke-HttpRequest -ErrorAction SilentlyContinue) {
            $resp = Invoke-HttpRequest -Uri $url -Method 'GET' -TimeoutSec 10 -OperationName 'CurrencyFetch'
        } else {
            $resp = Invoke-RestMethod -Uri $url -Method 'GET' -ErrorAction Stop
        }

        $json = $null
        if ($resp -is [string]) { $json = $resp | ConvertFrom-Json }
        elseif ($resp.PSObject.Properties['Content']) { $json = $resp.Content | ConvertFrom-Json }
        else { $json = $resp }

        if ($json -and $json.Valute) {
            $parse = {
                param($code)
                if ($json.Valute.$code) {
                    $val = 0.0
                    try { $val = [double]$json.Valute.$code.Value } catch {}
                    $nom = 1.0
                    try { if ($json.Valute.$code.Nominal) { $nom = [double]$json.Valute.$code.Nominal } } catch {}
                    if ($nom -eq 0) { $nom = 1.0 }
                    return ($val / $nom)
                }
                return $null
            }

            $usd = & $parse 'USD'
            if ($usd) { $rates['USD'] = $usd }
            
            $eur = & $parse 'EUR'
            if ($eur) { $rates['EUR'] = $eur }
            
            $kzt = & $parse 'KZT'
            if ($kzt) { $rates['KZT'] = $kzt }
            
            $cny = & $parse 'CNY'
            if ($cny) { $rates['CNY'] = $cny }
            
            $byn = & $parse 'BYN'
            if ($byn) { $rates['BYN'] = $byn }

            # Cache (24h = 1440 min)
            if (Get-Command -Name Set-HHCacheItem -ErrorAction SilentlyContinue) {
                try {
                    Set-HHCacheItem -Collection 'currency' -Key $cacheKey -Value $rates -Metadata @{ ttl_minutes = 1440 } 
                } catch {
                    if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                        Write-LogFetch -Message "Failed to write currency cache: $_" -Level Warning
                    }
                }
            }
            
            if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                Write-LogFetch -Message "Fetched currency rates: USD=$($rates['USD']) EUR=$($rates['EUR'])" -Level Verbose
            }
        }
    }
    catch {
        if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
            Write-LogFetch -Message "Currency fetch failed (using default RUB=1.0): $_" -Level Warning
        }
    }

    return $rates
}

Export-ModuleMember -Function Write-LogFetch, Get-HHEffectiveSearchFilters, Search-Vacancies, Get-HHSimilarVacancies, Get-HHWebRecommendations, Get-HHHybridVacancies, Get-VacancyDetail, Get-EmployerDetail, Get-SkillsVocab, Get-GetmatchConfig, Get-GetmatchQueryUrl, Get-GetmatchQueryUrls, Get-GetmatchVacanciesRaw, Resolve-HHAreaIdByName, Resolve-HHRoleIdByName, Resolve-HHAreaCountry, Get-HHAreaDetail, Get-HHAreaCacheKey, Get-EmployerRatingScrape, Parse-EmployerRatingHtml, Update-EmployerRating, Get-ExchangeRates
