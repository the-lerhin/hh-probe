# hh.factory.psm1 — Canonical vacancy factories
#Requires -Version 7.5

using module ./hh.models.psm1

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

function New-CanonicalVacancyFromHH {
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

    if ($Vacancy.experience) {
        try {
            $cv.Experience.Id = [string]$Vacancy.experience.id
            $cv.Experience.Name = [string]$Vacancy.experience.name
        } catch {}
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
        # Check if normalize function is available
        $cleanSummary = ''
        if (Get-Command -Name 'hh.util\Normalize-HHSummaryText' -ErrorAction SilentlyContinue) {
            $cleanSummary = hh.util\Normalize-HHSummaryText -Text ([string]($summaryResult.text ?? ''))
        } else {
            $cleanSummary = [string]($summaryResult.text ?? '')
        }

        $sourceNormalized = 'local'
        if (Get-Command -Name 'hh.util\Normalize-HHSummarySource' -ErrorAction SilentlyContinue) {
            $sourceNormalized = hh.util\Normalize-HHSummarySource -Source $summaryResult.source -Fallback 'local'
        }

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

function New-CanonicalVacancyFromGetmatch {
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

    if ($RawItem.EmployerLogo) {
        $emp.LogoUrl = $RawItem.EmployerLogo
        $cv.EmployerLogoUrl = $RawItem.EmployerLogo
    }
    if ($RawItem.EmployerUrl) {
        $emp.Url = $RawItem.EmployerUrl
    }

    $cv.Employer = $emp
    $cv.EmployerName = $emp.Name

    # Salary
    if ($RawItem.RawObject -and ($RawItem.RawObject.salary_display_from -or $RawItem.RawObject.salary_display_to)) {
        $sal = New-Object SalaryInfo
        if ($RawItem.RawObject.salary_display_from) { $sal.From = [double]$RawItem.RawObject.salary_display_from }
        if ($RawItem.RawObject.salary_display_to) { $sal.To = [double]$RawItem.RawObject.salary_display_to }
        if ($RawItem.RawObject.salary_currency) { $sal.Currency = $RawItem.RawObject.salary_currency }
        $sal.Text = $RawItem.SalaryText

        # Calculate UpperCap
        if ($sal.To -gt 0) { $sal.UpperCap = $sal.To }
        elseif ($sal.From -gt 0) { $sal.UpperCap = $sal.From }

        $cv.Salary = $sal
    }
    elseif ($RawItem.SalaryText) {
        $sal = New-Object SalaryInfo
        $sal.Text = $RawItem.SalaryText

        # Basic parsing from text
        try {
            # Extract numbers
            $nums = [regex]::Matches($RawItem.SalaryText, '\d[\d\s]*')
            $vals = @()
            foreach ($m in $nums) {
                $v = $m.Value -replace '\s', ''
                if ($v.Length -gt 0) { $vals += [double]$v }
            }

            if ($vals.Count -ge 2) {
                $sal.From = $vals[0]
                $sal.To = $vals[1]
            }
            elseif ($vals.Count -eq 1) {
                if ($RawItem.SalaryText -match 'от|from') { $sal.From = $vals[0] }
                else { $sal.To = $vals[0] }
            }

            # Detect currency
            if ($RawItem.SalaryText -match '₽|rub|руб') { $sal.Currency = 'RUR' }
            elseif ($RawItem.SalaryText -match '\$|usd|dollar') { $sal.Currency = 'USD' }
            elseif ($RawItem.SalaryText -match '€|eur|euro') { $sal.Currency = 'EUR' }

            # Calculate UpperCap
            if ($sal.To -gt 0) { $sal.UpperCap = $sal.To }
            elseif ($sal.From -gt 0) { $sal.UpperCap = $sal.From }
        }
        catch {}

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

    $rawMap = @{}
    if ($RawItem.Skills) {
        $cv.KeySkills = $RawItem.Skills
        $rawMap['key_skills'] = $RawItem.Skills
    }

    if ($RawItem.EnglishLevel) {
        $rawMap['english_level'] = $RawItem.EnglishLevel
    }
    $meta.Raw = $rawMap

    # Basic scoring placeholder
    $cv.Score = 0.5 # Default middle score

    return $cv
}

# Aliases for compatibility
function Build-CanonicalRowTyped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Vacancy,
        [switch]$NoDetail,
        [scriptblock]$ResolveDetail
    )
    return New-CanonicalVacancyFromHH -Vacancy $Vacancy -NoDetail:$NoDetail -ResolveDetail $ResolveDetail
}

function Build-CanonicalFromGetmatchVacancy {
    param([object]$RawItem)
    return New-CanonicalVacancyFromGetmatch -RawItem $RawItem
}

Export-ModuleMember -Function New-CanonicalVacancyFromHH, New-CanonicalVacancyFromGetmatch, Build-CanonicalRowTyped, Build-CanonicalFromGetmatchVacancy, Build-BadgesPack, Get-CanonicalKeySkills
