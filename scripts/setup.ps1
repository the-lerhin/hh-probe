#!/usr/bin/env pwsh
#Requires -PSEdition Core
#Requires -Version 7.5

<#
.SYNOPSIS
    Bootstraps hh_probe so hh.ps1 and the test suite run after a fresh clone.
.DESCRIPTION
    - Validates PowerShell 7.5+ per repo contract.
    - Installs the required PowerShell modules (PSFramework, Pester, PSScriptAnalyzer).
    - Downloads the .NET assemblies (Newtonsoft.Json, LiteDB, Handlebars.Net) from NuGet and parks them under bin/.
    - Skips Ollama/local LLM provisioning on purpose; those runtimes stay manual.
.PARAMETER SkipModules
    Skip installing PowerShell modules (useful inside offline build containers).
.PARAMETER SkipBinaries
    Skip downloading DLLs into bin/.
.PARAMETER Force
    Reinstall/download assets even if matching versions already exist.
#>
[CmdletBinding()]
param(
    [switch]$SkipModules,
    [switch]$SkipBinaries,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'hh.ps1'))) {
    throw "Run this script from within the hh_probe repo (hh.ps1 not found next to scripts/)."
}

$minPwshVersion = [Version]'7.5.0'
if ($PSVersionTable.PSVersion -lt $minPwshVersion) {
    throw "PowerShell $minPwshVersion or newer is required. Current: $($PSVersionTable.PSVersion)"
}

$binDir = Join-Path $repoRoot 'bin'
if (-not (Test-Path -LiteralPath $binDir)) {
    $null = New-Item -ItemType Directory -Force -Path $binDir
}

$moduleRequirements = @(
    [pscustomobject]@{
        Name           = 'PSFramework'
        MinimumVersion = [Version]'1.13.416'
        Reason         = 'Logging (hh.log.psm1 / PSFramework routing)'
    }
    [pscustomobject]@{
        Name           = 'Pester'
        MinimumVersion = [Version]'5.7.1'
        Reason         = 'Pester suites mapped to FRD/SDD tags'
    }
    [pscustomobject]@{
        Name           = 'PSScriptAnalyzer'
        MinimumVersion = [Version]'1.24.0'
        Reason         = 'ScriptAnalyzer tests enforce lint gates'
    }
)

$assemblyRequirements = @(
    [pscustomobject]@{
        Name   = 'Newtonsoft.Json.dll'
        Package = 'Newtonsoft.Json'
        Version = '13.0.3'
        Sha256  = '8C1DD5C184B4E2E7EAD06971FF3EBCB46783BE972292D1DEB1061744369B4D80'
        Reason  = 'FR-16.2 typed JSON serialization for hh_canonical.json'
    }
    [pscustomobject]@{
        Name   = 'LiteDB.dll'
        Package = 'LiteDB'
        Version = '5.0.21'
        Sha256  = 'AE31AC6A93549217B9E8B81497D1EE831658ADE6DF9E1EE20F2838F22DE5E218'
        Reason  = 'Primary LiteDB cache backend (FR-2.1 / SDD §4.7)'
    }
    [pscustomobject]@{
        Name   = 'Handlebars.Net.dll'
        Package = 'Handlebars.Net'
        Version = '2.0.9'
        Sha256  = '8D7994BA08EA93E01A7584C47DC62825EB0343EA5D1A6DE5F154202DE9BC4A2E'
        Reason  = 'HTML/Scriban-equivalent rendering path'
    }
)

$preferredTfms = @(
    'net8.0',
    'net7.0',
    'net6.0',
    'netstandard2.1',
    'netstandard2.0',
    'net5.0',
    'netcoreapp3.1',
    'net48',
    'net472',
    'net471',
    'net47',
    'net462',
    'net461',
    'net45'
)

function Test-FileHashMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        return ($hash -eq $ExpectedHash)
    }
    catch {
        Write-Warning ("Failed to compute hash for {0}: {1}" -f $Path, $_)
        return $false
    }
}

function Ensure-Module {
    param(
        [Parameter(Mandatory = $true)]$Requirement
    )
    $existing = Get-Module -ListAvailable -Name $Requirement.Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($existing -and -not $Force -and ($existing.Version -ge $Requirement.MinimumVersion)) {
        Write-Output "[OK] $($Requirement.Name) $($existing.Version) already available ($($Requirement.Reason))."
        return
    }

    Write-Output "[*] Installing $($Requirement.Name) (reason: $($Requirement.Reason))..."
    try {
        Install-Module -Name $Requirement.Name `
                       -Scope CurrentUser `
                       -Force `
                       -AllowClobber `
                       -MinimumVersion $Requirement.MinimumVersion
    }
    catch {
        throw "Failed to install module $($Requirement.Name): $_"
    }
}

function Resolve-NuGetDllPath {
    param(
        [Parameter(Mandatory = $true)][string]$ExtractedRoot,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    $libRoot = Join-Path $ExtractedRoot 'lib'
    foreach ($tfm in $preferredTfms) {
        $candidate = Join-Path $libRoot $tfm
        $dllPath = Join-Path $candidate $FileName
        if (Test-Path -LiteralPath $dllPath) {
            return $dllPath
        }
    }

    $fallback = Get-ChildItem -Path $libRoot -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) { return $fallback.FullName }
    throw "Could not locate $FileName inside $libRoot"
}

function Ensure-Assembly {
    param(
        [Parameter(Mandatory = $true)]$Requirement
    )

    $destination = Join-Path $binDir $Requirement.Name
    if (-not $Force -and $Requirement.Sha256 -and (Test-FileHashMatches -Path $destination -ExpectedHash $Requirement.Sha256)) {
        Write-Output "[OK] $($Requirement.Name) already matches expected hash ($($Requirement.Reason))."
        return
    }

    $packageUri = "https://www.nuget.org/api/v2/package/$($Requirement.Package)/$($Requirement.Version)"
    $tempName = "{0}.{1}.{2}" -f $Requirement.Package, $Requirement.Version, ([guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path ([IO.Path]::GetTempPath()) "$tempName.nupkg"
    $extractPath = Join-Path ([IO.Path]::GetTempPath()) "$tempName.extracted"

    Write-Output "[*] Downloading $($Requirement.Package) $($Requirement.Version) for $($Requirement.Name)..."
    try {
        Invoke-WebRequest -Uri $packageUri -OutFile $archivePath
    }
    catch {
        throw "Failed to download $($Requirement.Package) $($Requirement.Version) from NuGet: $_"
    }

    try {
        if (Test-Path -LiteralPath $extractPath) {
            Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        $sourceDll = Resolve-NuGetDllPath -ExtractedRoot $extractPath -FileName $Requirement.Name
        Copy-Item -LiteralPath $sourceDll -Destination $destination -Force
    }
    catch {
        throw "Failed to unpack $($Requirement.Name): $_"
    }
    finally {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($Requirement.Sha256 -and -not (Test-FileHashMatches -Path $destination -ExpectedHash $Requirement.Sha256)) {
        throw "$($Requirement.Name) hash mismatch after download."
    }

    Write-Output "[OK] Installed $($Requirement.Name) into bin/ ($($Requirement.Reason))."
}

Write-Output "hh_probe setup started (repo: $repoRoot)"

if ($SkipModules) {
    Write-Output "[SKIP] Module installation suppressed by -SkipModules."
}
else {
    foreach ($req in $moduleRequirements) {
        Ensure-Module -Requirement $req
    }
}

if ($SkipBinaries) {
    Write-Output "[SKIP] Binary download suppressed by -SkipBinaries."
}
else {
    foreach ($assembly in $assemblyRequirements) {
        Ensure-Assembly -Requirement $assembly
    }
}

Write-Output "Setup completed. You can now run hh.ps1 or Invoke-Pester."
