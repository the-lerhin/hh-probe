Describe 'Getmatch Detail Isolation' {

    BeforeAll {
        # Import necessary modules
        Import-Module -Name (Join-Path $PSScriptRoot '../modules/hh.pipeline.psm1') -Force
        Import-Module -Name (Join-Path $PSScriptRoot '../modules/hh.fetch.psm1') -Force
        # Add any other required imports
        $script:calledIds = @()
        $script:calledEmployerIds = @()
        $script:calledScrapeIds = @()
    }

    BeforeEach {
        $script:calledIds = @()
        $script:calledEmployerIds = @()
        $script:calledScrapeIds = @()
    }

    It 'Calls HH detail only for HH rows (Test Case 1)' -Tag 'FR-1.5','SDD-4.6','Getmatch-Isolation' {
        # Arrange
        $rowHh = [pscustomobject]@{
            Source = 'hh'
            Id = '123456'
            Meta = [pscustomobject]@{ Source = 'hh' }
            Detail = $null
        }

        $rowGetmatch = [pscustomobject]@{
            Source = 'getmatch'
            Id = 'gm_abcdef'
            Meta = [pscustomobject]@{ Source = 'getmatch' }
            Detail = $null
        }

        $rows = @($rowHh, $rowGetmatch)

        # Mock Get-VacancyDetail
        Mock Get-VacancyDetail {
            param($Id)
            $script:calledIds += $Id
            return [pscustomobject]@{ }
        } 

        # Mock Write-LogFetch to avoid errors if not defined
        Mock Write-LogFetch {} 

        # Act
        $enriched = $rows | ForEach-Object {
            if (-not $_.Id) { return $_ }
            if (($_.Source -ne 'hh') -and ($_.Meta.Source -ne 'hh') -and ($_.Meta.Source -ne 'hh_web_recommendation') -and ($_.Meta.Source -ne 'hh_recommendation') -and ($_.Meta.Source -ne 'hh_general')) {
                Write-LogFetch -Level 'Verbose' -Message "Skipping HH detail fetch for non-HH vacancy Id=$($_.Id) Source=$($_.Source) Meta.Source=$($_.Meta.Source)"
                return $_
            }
            if ($_.Id -notmatch '^\d+$') {
                Write-LogFetch -Level 'Verbose' -Message "Skipping HH detail fetch for invalid ID format Id=$($_.Id) Source=$($_.Source) Meta.Source=$($_.Meta.Source)"
                return $_
            }
            $detail = Get-VacancyDetail -Id $_.Id
            $_.Detail = $detail
            $_
        }

        # Assert
        Should -Invoke -CommandName 'Get-VacancyDetail'  -Times 1 -Exactly -Scope It
$script:calledIds | Should -Contain '123456'
        $script:calledIds | Should -Not -Contain 'gm_abcdef'
        $enriched.Count | Should -Be 2
        $enriched[1].Source | Should -Be 'getmatch'
    }

    It 'Enforces ID pattern safety (Test Case 2)' -Tag 'FR-1.5','SDD-4.6','Getmatch-Isolation' {
        # Arrange
        $rowInvalid = [pscustomobject]@{
            Source = 'hh'
            Id = 'invalid_id'
            Meta = [pscustomobject]@{ Source = 'hh' }
            Detail = $null
        }

        $rowValid = [pscustomobject]@{
            Source = 'hh'
            Id = '789012'
            Meta = [pscustomobject]@{ Source = 'hh' }
            Detail = $null
        }

        $rows = @($rowInvalid, $rowValid)

        # Mock Get-VacancyDetail
        Mock Get-VacancyDetail {
            param($Id)
            $script:calledIds += $Id
            return [pscustomobject]@{ }
        } 

        # Mock Write-LogFetch
        Mock Write-LogFetch {} 

        # Act
        $enriched = $rows | ForEach-Object {
            if (-not $_.Id) { return $_ }
            if (($_.Source -ne 'hh') -and ($_.Meta.Source -ne 'hh') -and ($_.Meta.Source -ne 'hh_web_recommendation') -and ($_.Meta.Source -ne 'hh_recommendation') -and ($_.Meta.Source -ne 'hh_general')) {
                Write-LogFetch -Level 'Verbose' -Message "Skipping HH detail fetch for non-HH vacancy Id=$($_.Id) Source=$($_.Source) Meta.Source=$($_.Meta.Source)"
                return $_
            }
            if ($_.Id -notmatch '^\d+$') {
                Write-LogFetch -Level 'Verbose' -Message "Skipping HH detail fetch for invalid ID format Id=$($_.Id) Source=$($_.Source) Meta.Source=$($_.Meta.Source)"
                return $_
            }
            $detail = Get-VacancyDetail -Id $_.Id
            $_.Detail = $detail
            $_
        }

        # Assert
        Should -Invoke -CommandName 'Get-VacancyDetail'  -Times 1 -Exactly -Scope It
$script:calledIds | Should -Not -Contain 'invalid_id'
        $script:calledIds | Should -Contain '789012'
        $enriched.Count | Should -Be 2
        $enriched[0].Id | Should -Be 'invalid_id'
    }

    It 'Blocks employer calls for Getmatch rows (Test Case 3)' -Tag 'FR-3.5','SDD-4.6','Getmatch-Isolation' {
        # Arrange
        $rowHh = [pscustomobject]@{
            Source = 'hh'
            Id = '123456'
            Meta = [pscustomobject]@{ Source = 'hh' }
            Employer = [pscustomobject]@{ Id = '111'; Detail = $null; Scrape = $null }
        }

        $rowGetmatch = [pscustomobject]@{
            Source = 'getmatch'
            Id = 'gm_abcdef'
            Meta = [pscustomobject]@{ Source = 'getmatch' }
            Employer = [pscustomobject]@{ Id = 'gm_emp'; Detail = $null; Scrape = $null }
        }

        $rows = @($rowHh, $rowGetmatch)

        # Mock employer functions
        Mock Get-EmployerDetail {
            param($Id)
            $script:calledEmployerIds += $Id
            return [pscustomobject]@{ }
        } 

        Mock Get-EmployerRatingScrape {
            param($EmployerId)
            $script:calledScrapeIds += $EmployerId
            return [pscustomobject]@{ }
        } 

        # Mock Write-LogFetch
        Mock Write-LogFetch {} 

        # Act
        $enriched = $rows | ForEach-Object {
            if (-not $_.Employer -or -not $_.Employer.Id) { return $_ }
            if (($_.Source -ne 'hh') -and ($_.Meta.Source -ne 'hh') -and ($_.Meta.Source -ne 'hh_web_recommendation') -and ($_.Meta.Source -ne 'hh_recommendation') -and ($_.Meta.Source -ne 'hh_general')) {
                Write-LogFetch -Level 'Verbose' -Message "Skipping HH employer enrichment for non-HH vacancy Id=$($_.Id) Source=$($_.Source) Meta.Source=$($_.Meta.Source)"
                return $_
            }
            if ($_.Employer.Id -notmatch '^\d+$') {
                Write-LogFetch -Level 'Verbose' -Message "Skipping HH employer enrichment for invalid employer ID format EmployerId=$($_.Employer.Id) VacancyId=$($_.Id)"
                return $_
            }
            $empDetail = Get-EmployerDetail -Id $_.Employer.Id
            $empScrape = Get-EmployerRatingScrape -EmployerId $_.Employer.Id
            $_.Employer.Detail = $empDetail
            $_.Employer.Scrape = $empScrape
            $_
        }

        # Assert
        Should -Invoke -CommandName 'Get-EmployerDetail'  -Times 1 -Exactly -Scope It
Should -Invoke -CommandName 'Get-EmployerRatingScrape'  -Times 1 -Exactly -Scope It
        $script:calledEmployerIds | Should -Contain '111'
        $script:calledEmployerIds | Should -Not -Contain 'gm_emp'
        $script:calledScrapeIds | Should -Contain '111'
        $script:calledScrapeIds | Should -Not -Contain 'gm_emp'
        $enriched.Count | Should -Be 2
        $enriched[1].Source | Should -Be 'getmatch'
    }
}
