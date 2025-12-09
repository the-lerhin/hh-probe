$loc = Get-Location
if (Test-Path (Join-Path $loc 'modules')) { $modRoot = Join-Path $loc 'modules' }
elseif (Test-Path (Join-Path $loc '../modules')) { $modRoot = Join-Path $loc '../modules' }
else { throw "Cannot find modules directory" }

Import-Module (Join-Path $modRoot 'hh.models.psm1') -Force
Import-Module (Join-Path $modRoot 'hh.fetch.psm1') -Force
Import-Module (Join-Path $modRoot 'hh.http.psm1') -Force

Describe 'HH Hybrid Search' {
    Context 'Get-HHSimilarVacancies' {
        It 'Returns similar vacancies with tier info' {
            Mock Invoke-HhApiRequest {
                return [pscustomobject]@{
                    items = @(
                        [pscustomobject]@{ id = '100'; name = 'Sim1' }
                        [pscustomobject]@{ id = '101'; name = 'Sim2' }
                    )
                    page = 0
                    pages = 1
                }
            } -ModuleName 'hh.fetch'

            $res = Get-HHSimilarVacancies -ResumeId 'RES123'
            $res.Count | Should -Be 2
            $res[0].search_tiers | Should -Contain 'similar'
            $res[0].search_stage | Should -Be 'similar'
        }
    }

    Context 'Get-HHHybridVacancies' {
        It 'Merges Similar and General with Dedup (Similar priority)' {
             # Mock Similar
             Mock Get-HHSimilarVacancies {
                 return @(
                     [pscustomobject]@{ id = '1'; name = 'Similar1'; search_tiers = @('similar') }
                     [pscustomobject]@{ id = '2'; name = 'Common'; search_tiers = @('similar') }
                 )
             } -ModuleName 'hh.fetch'
             
             # Mock General
             Mock Search-Vacancies {
                 return @(
                     [pscustomobject]@{ id = '2'; name = 'Common'; search_tiers = @('general') }
                     [pscustomobject]@{ id = '3'; name = 'General1'; search_tiers = @('general') }
                 )
             } -ModuleName 'hh.fetch'
             
             $res = Get-HHHybridVacancies -ResumeId 'R1' -QueryText 'java'
             $items = $res.Items
             
             $items.Count | Should -Be 3
             $items[0].id | Should -Be '1'
             $items[1].id | Should -Be '2' # From similar
             $items[2].id | Should -Be '3'
        }
    }
}
