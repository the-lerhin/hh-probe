# tests/E2E.Smoke.Tests.ps1
#Requires -Version 7.5

$loc = Get-Location
# $repoRoot = $PSScriptRoot | Split-Path -Parent # This fails in Pester 5 scope
$script:HHScript = Join-Path ($PSScriptRoot | Split-Path -Parent) 'hh.ps1'

Describe 'E2E Smoke Test' -Tag @('Smoke', 'E2E', 'Phase1') {
    BeforeAll {
        # Setup temporary directories
        $testRunId = [Guid]::NewGuid().ToString()
        $script:TestDir = Join-Path ([IO.Path]::GetTempPath()) "hh_smoke_$testRunId"
        New-Item -ItemType Directory -Force -Path $script:TestDir | Out-Null

        $script:ConfigPath = Join-Path $script:TestDir 'hh.config.jsonc'
        $script:OutputsDir = Join-Path $script:TestDir 'data/outputs'
        $script:CacheDir = Join-Path $script:TestDir 'data/cache'
        $script:LogsDir = Join-Path $script:TestDir 'data/logs'

        # Create minimal valid config
        $configContent = @{
            search = @{
                area = 113
                text = "test query"
            }
            report = @{
                max_display_rows = 5
            }
            llm = @{
                enabled = $false
            }
        } | ConvertTo-Json
        $configContent | Set-Content -Path $script:ConfigPath
    }

    AfterAll {
        # Cleanup
        if (Test-Path $script:TestDir) { Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue }
    }

    It 'runs hh.ps1 completely with mocks' {
        # Define RepoRoot inside It block to ensure correct path resolution
        $repoRoot = $PSScriptRoot | Split-Path -Parent

        Import-Module (Join-Path $repoRoot 'modules/hh.pipeline.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'modules/hh.fetch.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'modules/hh.config.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'modules/hh.core.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'modules/hh.render.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'modules/hh.cv.psm1') -Force -DisableNameChecking

        # Mock Fetch
        Mock Get-HHProbeVacancies {
            return @(
                [pscustomobject]@{
                    id = '1001'
                    name = 'Test Vacancy 1'
                    published_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
                    employer = @{ id = '55'; name = 'Test Corp' }
                    salary = @{ from = 100000; currency = 'RUR' }
                    alternate_url = 'http://example.com/1'
                    search_stage = 'general'
                }
            )
        } -ModuleName 'hh.pipeline'

        # Mock Exchange Rates (called in pipeline)
        Mock Get-ExchangeRates { return @{ 'RUB' = 1.0; 'RUR' = 1.0 } } -ModuleName 'hh.fetch'

        # Mock Detail Fetch (called in pipeline enrichment)
        # Mock in both modules to be safe
        Mock Get-VacancyDetail { return $null } -ModuleName 'hh.pipeline'
        Mock Get-VacancyDetail { return $null } -ModuleName 'hh.fetch'

        # Mock CV Snapshot
        Mock Get-HHCVSnapshotOrSkills {
            return [pscustomobject]@{
                Title = "DevOps Engineer"
                KeySkills = @("PowerShell", "CI/CD")
            }
        } -ModuleName 'hh.pipeline'

        # Mock Render (we just want to know it was called)
        Mock Render-Reports {
            param($Rows, $OutputsRoot, $PipelineState)
            # Just verify call
            return $true
        } -ModuleName 'hh.pipeline'

        # Invoke
        $state = Invoke-HHProbeMain `
            -SearchText 'test' `
            -VacancyPerPage 5 `
            -VacancyPages 1 `
            -ResumeId 'RES1' `
            -WindowDays 7 `
            -RecommendEnabled $false `
            -RecommendPerPage 0 `
            -RecommendTopTake 0 `
            -LLMEnabled $false `
            -ReportStats @{} `
            -Digest $false `
            -Ping $false `
            -NotifyDryRun $true `
            -NotifyStrict $false `
            -ReportUrl '' `
            -RunStartedLocal (Get-Date) `
            -LearnSkills $false `
            -OutputsRoot $script:OutputsDir `
            -RepoRoot $repoRoot `
            -PipelineState $null `
            -DebugMode $true

        # Assert
        $state | Should -Not -BeNullOrEmpty
        Assert-MockCalled 'Render-Reports' -ModuleName 'hh.pipeline' -Times 1
    }
}
