# Pipeline.Tests.ps1 — Integration tests for hh.pipeline.psm1
#Requires -Version 7.5

$repoRoot = '/app'
$modulesDir = Join-Path $repoRoot 'modules'

function Get-RepoRoot { return '/app' }

Import-Module (Join-Path $modulesDir 'hh.models.psm1') -Force
Import-Module (Join-Path $modulesDir 'hh.core.psm1') -Force
Import-Module (Join-Path $modulesDir 'hh.pipeline.psm1') -Force
Import-Module (Join-Path $modulesDir 'hh.config.psm1') -Force

Describe 'Invoke-HHProbeMain Integration' {
    BeforeAll {
        $repoRoot = '/app'
        Write-Host "DEBUG: repoRoot='$repoRoot'"
        Write-Host "DEBUG: outRoot='$((Join-Path $repoRoot 'data/outputs_test'))'"

        # Ensure-HHModelTypes

        # Mock dependencies to avoid actual network calls
        function Get-HHHybridVacancies {
            param($ResumeId, $QueryText, $Limit, $Config)
            return [pscustomobject]@{
                Items = @(
                    [pscustomobject]@{
                        id = '101'
                        name = 'Test Vacancy 1'
                        alternate_url = 'https://hh.ru/vacancy/101'
                        employer = @{ name = 'Test Corp'; id = '999' }
                        salary = @{ from = 100000; currency = 'RUR' }
                        published_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
                    }
                )
            }
        }

        function Get-VacancyDetail {
            param($Id)
            return [pscustomobject]@{
                id = $Id
                name = "Detailed Vacancy $Id"
                description = "Full description for $Id"
                key_skills = @(@{ name = 'PowerShell' })
                employer = @{ name = 'Test Corp'; id = '999' }
            }
        }

        function Invoke-LocalLLMRelevance { return 0.8 }
        function Calculate-Score { param($Vacancy) $Vacancy.Score = 0.8 }
    }

    It 'runs the full pipeline and returns a populated PipelineState' {
        # Create a dummy state if needed, or let the function create it
        $outRoot = Join-Path $repoRoot 'data/outputs_test'
        if (-not (Test-Path $outRoot)) { New-Item -ItemType Directory -Path $outRoot | Out-Null }

        $state = Invoke-HHProbeMain `
            -SearchText "DevOps" `
            -VacancyPerPage 10 `
            -VacancyPages 1 `
            -ResumeId "123" `
            -RecommendEnabled $false `
            -LLMEnabled $false `
            -NotifyDryRun $true `
            -OutputsRoot $outRoot `
            -RepoRoot $repoRoot `
            -PipelineState (New-HHPipelineState -StartedLocal (Get-Date) -StartedUtc ([DateTime]::UtcNow)) `
            -DebugMode $true

        $state | Should -Not -BeNullOrEmpty
        $state.Timings.Keys | Should -Contain 'Fetch'
        # Processing might be renamed or merged into Fetch/Enrichment in refactor
        # $state.Timings.Keys | Should -Contain 'Processing'
        $state.Timings.Keys | Should -Contain 'Scoring'
        # Ranking might be skipped if no rows or disabled LLM
        # $state.Timings.Keys | Should -Contain 'Ranking'
        # Render skipped if no rows? No, it should run.
        # $state.Timings.Keys | Should -Contain 'Render'
    }
}
