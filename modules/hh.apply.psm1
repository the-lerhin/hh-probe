# hh.apply.psm1 — Advanced Apply Module (CV Tuning + AI Cover Letter + One-Click Apply)
#Requires -Version 7.4

using module ./hh.models.psm1

# Ensure models are available
if (-not (Get-Command -Name Ensure-HHModelTypes -ErrorAction SilentlyContinue)) {
    $modelsPath = Join-Path $PSScriptRoot 'hh.models.psm1'
    if (Test-Path $modelsPath) { Import-Module $modelsPath -DisableNameChecking }
}
try { Ensure-HHModelTypes } catch {}

# Ensure LLM module is available
if (-not (Get-Module -Name 'hh.llm')) {
    $llmPath = Join-Path $PSScriptRoot 'hh.llm.psm1'
    if (Test-Path $llmPath) { Import-Module $llmPath -DisableNameChecking }
}

# Ensure Config module is available
if (-not (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
    $cfgPath = Join-Path $PSScriptRoot 'hh.config.psm1'
    if (Test-Path $cfgPath) { Import-Module $cfgPath -DisableNameChecking }
}

function Select-ApplyVacancy {
    [CmdletBinding()]
    param(
        [string]$VacancyId
    )
    # Placeholder
    Write-Host "Select-ApplyVacancy called for $VacancyId"
    return $null
}

function Get-HHPainPoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Vacancy
    )
    # Placeholder
    Write-Host "Get-HHPainPoints called"
    return $null
}

function Get-HHCVRewritePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Vacancy,
        [Parameter(Mandatory = $true)]$PainPoints
    )
    # Placeholder
    Write-Host "Get-HHCVRewritePlan called"
    return $null
}

function Get-HHPremiumCoverLetter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Vacancy,
        [Parameter(Mandatory = $true)]$RewritePlan
    )
    # Placeholder
    Write-Host "Get-HHPremiumCoverLetter called"
    return $null
}

function Invoke-HHApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$VacancyId,
        [Parameter(Mandatory = $true)]$CoverLetter,
        [string]$ResumeId
    )
    # Placeholder
    Write-Host "Invoke-HHApplication called for $VacancyId"
    return $null
}

Export-ModuleMember -Function Select-ApplyVacancy, Get-HHPainPoints, Get-HHCVRewritePlan, Get-HHPremiumCoverLetter, Invoke-HHApplication
