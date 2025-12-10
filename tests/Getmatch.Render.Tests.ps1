
$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$ModRender = Join-Path $RepoRoot 'modules/hh.render.psm1'
$ModModels = Join-Path $RepoRoot 'modules/hh.models.psm1'

Import-Module $ModRender -Force
Import-Module $ModModels -Force

Describe "Getmatch Rendering Integration" {
    BeforeAll {
        Ensure-HHModelTypes
        $DebugPreference = 'Continue'
    }

    Context "Normalize-RenderRows" {
        InModuleScope "hh.render" {
            It "Should preserve CanonicalVacancy objects" {
                # Create a CanonicalVacancy mimicking Getmatch
                $cv = New-Object CanonicalVacancy
                $cv.Id = "gm_123"
                $cv.Title = "Test Vacancy"
                $cv.Url = "https://getmatch.ru/vacancy/123"
                $cv.Description = "Test Description"
                
                $meta = New-Object MetaInfo
                $meta.Source = "getmatch"
                $cv.Meta = $meta

                # Wrap in array as the pipeline does
                $rows = @($cv)

                $DebugPreference = 'Continue'
                $result = Normalize-RenderRows -Rows $rows
                
                $result.Count | Should -Be 1
                $result[0] | Should -BeOfType [CanonicalVacancy]
                $result[0].Id | Should -Be "gm_123"
            }

            It "Should handle mixed collections" {
                $cv1 = New-Object CanonicalVacancy
                $cv1.Id = "hh_1"
                
                $cv2 = New-Object CanonicalVacancy
                $cv2.Id = "gm_2"

                $rows = @($cv1, $cv2)

                $result = Normalize-RenderRows -Rows $rows
                $result.Count | Should -Be 2
                $result[1].Id | Should -Be "gm_2"
            }
        }
    }

    Context "Render-CSVReport  # Desired: proper Encoding object handling (e.g., [System.Text.Encoding]::UTF8), but code treats 'UTF8' as string - test should stay red until fixed" {
        InModuleScope "hh.render" {
            It "Should process Getmatch vacancies without error" {
                $cv = New-Object CanonicalVacancy
                $cv.Id = "gm_render_test"
                $cv.Title = "Render Test"
                $cv.city = "Moscow"
                
                $tempDir = Join-Path $TestDrive "outputs"
                $rows = @($cv)

                # Mock dependencies inside the module scope
                Mock Export-Csv {} 
                Mock Write-Log {}

                # Call the function
                Render-CSVReport -Rows $rows -OutputsRoot $tempDir
            }
        }
    }
    
    Context "Render-Reports" {
        InModuleScope "hh.render" {
             It "Should call all render functions" {
                $cv = New-Object CanonicalVacancy
                $cv.Id = "gm_rep_1"
                
                $rows = @($cv)
                $outRoot = Join-Path $TestDrive "reports"
                
                Mock Render-CSVReport {}
                Mock Render-JsonReport {}
                Mock Render-HtmlReport {}
                Mock Write-Log {}
                
                Render-Reports -Rows $rows -OutputsRoot $outRoot
                
                Should -Invoke Render-CSVReport -Times 1
                Should -Invoke Render-JsonReport -Times 1
                Should -Invoke Render-HtmlReport -Times 1
             }
        }
    }
}
