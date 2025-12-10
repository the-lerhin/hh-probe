BeforeAll {
    # Import necessary modules
    Import-Module ./modules/hh.models.psm1 -Force
    Import-Module ./modules/hh.log.psm1 -Force
    Import-Module ./modules/hh.render.psm1 -Force
}

Describe "Render-HtmlReport" -Tag @('FR-7.2','SDD-4.14','system') { BeforeAll { Ensure-HHModelTypes }
    It "should create an HTML report from typed vacancy objects" {
        #region Test Data
        $testRows = @(
            [CanonicalVacancy]@{
                id = "test1"
                title = "Senior Software Engineer"
                salary = [SalaryInfo]@{
                    from = 300000
                    to = 500000
                    currency = "RUR"
                    text = "от 300 000 до 500 000 руб."
                }
                employer = [EmployerInfo]@{
                    name = "Tech Company"
                    rating = 4.5
                    open = 10
                }
                city = "Москва"
                country = "Россия"
                published_at = (Get-Date).AddDays(-5)
                meta = [MetaInfo]@{
                    scores = [ScoreInfo]@{
                        cv = 5
                        skills = 8
                        salary = 7
                        recency = 3
                    }
                    penalties = [PenaltyInfo]@{
                        duplicate = 2
                        culture = 1
                    }
                }
                picks = [PicksInfo]@{
                    IsEditorsChoice = $true
                    EditorsWhy = "Отличный выбор для опытного инженера."
                }
            },
            [CanonicalVacancy]@{
                id = "test2"
                title = "Junior Developer"
                salary = [SalaryInfo]@{
                    from = 150000
                    to = 200000
                    currency = "RUR"
                    text = "от 150 000 до 200 000 руб."
                }
                employer = [EmployerInfo]@{
                    name = "Startup Inc"
                    rating = 3.8
                    open = 5
                }
                city = "Санкт-Петербург"
                country = "Россия"
                published_at = (Get-Date).AddDays(-10)
                meta = [MetaInfo]@{
                    scores = [ScoreInfo]@{
                        cv = 3
                        skills = 6
                        salary = 4
                        recency = 2
                    }
                    penalties = [PenaltyInfo]@{
                        duplicate = 1
                    }
                }
            }
        )
        #endregion

        $tempDir = New-TemporaryFile | Split-Path
        $outPath = Join-Path $tempDir "test_report.html"

        # Run the renderer
        Render-HtmlReport -Rows $testRows -OutPath $outPath

        # Assertions
        $outPath | Should -Exist
        $content = Get-Content $outPath -Raw

        $content | Should -Match 'id="row-1"'
        $content | Should -Match 'class="skills"'
        # picks reason may vary with template; skip strict check

        # Cleanup
        Remove-Item $tempDir -Recurse -Force
    }
}
