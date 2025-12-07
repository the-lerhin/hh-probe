
Import-Module "$PSScriptRoot/../modules/hh.models.psm1" -Force
Import-Module "$PSScriptRoot/../modules/hh.fetch.psm1" -Force
Import-Module "$PSScriptRoot/../modules/hh.http.psm1" -Force

Describe "Employer Rating Scraping" {
    Context "Parse-EmployerRatingHtml" {
        It "Parses rating correctly" {
            $html = '<div data-qa="employer-review-small-widget-total-rating">4.5</div>'
            $result = Parse-EmployerRatingHtml -Html $html
            $result.Rating | Should -Be 4.5
        }

        It "Ignores vote counts" {
            $html = '<div data-qa="employer-review-small-widget-total-rating">4.5</div> <div>100 отзывов</div>'
            $result = Parse-EmployerRatingHtml -Html $html
            $result.PSObject.Properties.Name | Should -Not -Contain "Votes"
        }

        It "Returns null for empty HTML" {
            $result = Parse-EmployerRatingHtml -Html "   "
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Get-EmployerRatingScrape" {
        It "Parses string responses from Invoke-HttpRequest" {
            Mock Invoke-HttpRequest { return '<div data-qa="employer-review-small-widget-total-rating">3.9</div>' } -ModuleName hh.fetch
            $rating = Get-EmployerRatingScrape -EmployerId "123"
            $rating.Rating | Should -Be 3.9
        }
    }

    Context "Update-EmployerRating" {
        It "Updates CanonicalVacancy rating" {
            # Mock Get-EmployerRatingScrape inside the module
            Mock Get-EmployerRatingScrape { return [PSCustomObject]@{ Rating = 4.8 } } -ModuleName hh.fetch

            $row = New-CanonicalVacancy
            $row.EmployerId = "123"
            $row.Employer = [EmployerInfo]::new()
            $row.Employer.Id = "123"
            $row.Meta.Source = 'hh'
            
            Update-EmployerRating -Vacancy $row

            $row.EmployerRating | Should -Be 4.8
            $row.Employer.Rating | Should -Be 4.8
        }
    }
}
