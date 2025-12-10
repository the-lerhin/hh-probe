Import-Module ./modules/hh.tmpl.psm1   -Force
Import-Module ./modules/hh.render.psm1 -Force
Import-Module ./modules/hh.core.psm1   -Force

Describe 'Render-HtmlReport smoke' {
  BeforeAll {
    $script:RunStartedLocal = Get-Date
    $script:RunStartedUtc   = (Get-Date).ToUniversalTime()
    $global:RunStartedLocal = $script:RunStartedLocal
    $global:RunStartedUtc   = $script:RunStartedUtc
    $global:DigestLabel     = 'demo search'

    $pipelineFlags = @{ Digest = $true }
    $global:PipelineState = New-HHPipelineState -StartedLocal $script:RunStartedLocal -StartedUtc $script:RunStartedUtc -Flags $pipelineFlags
    Set-HHPipelineValue -State $global:PipelineState -Path @('Search','Label') -Value 'demo search · remote'
    Set-HHPipelineValue -State $global:PipelineState -Path @('Search','ItemsFetched') -Value 1
    Set-HHPipelineValue -State $global:PipelineState -Path @('Search','RowsRendered') -Value 1
    Set-HHPipelineValue -State $global:PipelineState -Path @('Search','Keywords') -Value @('kotlin','cto')
    Set-HHPipelineValue -State $global:PipelineState -Path @('Stats','Views') -Value 2
    Set-HHPipelineValue -State $global:PipelineState -Path @('Stats','Invites') -Value 1
    Set-HHPipelineValue -State $global:PipelineState -Path @('Cache','LlmCached') -Value 1
    Set-HHPipelineValue -State $global:PipelineState -Path @('Cache','LlmQueried') -Value 2
    Set-HHPipelineValue -State $global:PipelineState -Path @('Metadata','Views') -Value @([pscustomobject]@{ employer = [pscustomobject]@{ name='Acme Corp' }; dt_utc = (Get-Date).ToUniversalTime() })
    Set-HHPipelineValue -State $global:PipelineState -Path @('Metadata','Invites') -Value @([pscustomobject]@{ employer = [pscustomobject]@{ name='Globex' }; dt_utc = (Get-Date).ToUniversalTime() })

    $script:TestRow = @{
      id = 'test-1'
      title = 'Senior Developer'
      link = 'https://hh.ru/vacancy/test-1'
      city = 'Moscow'
      employer = @{ name = 'TechCorp'; rating = 4.8; open = 3 }
      salary = @{ text = 'от 300 000 ₽' }
      summary = 'Excellent opportunity for senior developers with cloud experience'
      summary_source = 'cache'
      published_at = (Get-Date).AddHours(-6)
      skills = @{
        MatchedVacancy = @('Azure','C#','Terraform')
        InCV           = @('Azure','Python')
        Score          = 3
      }
      meta = @{
        scores = @{ cv = 2; skills = 3; salary = 1; recency = 1 }
        penalties = @{ duplicate = 0 }
      }
      skills_present = @('Azure','C#')
      skills_recommended = @('Go','Kubernetes')
      picks = @{ is_editors_choice = $true; editors_why = 'Best overall package and growth opportunities' }
    }
    $script:OutPath = Join-Path 'data/outputs' 'smoke_test.html'
  }

  It 'renders run summary, picks, and summary text' {
    if (Test-Path $script:OutPath) { Remove-Item $script:OutPath -Force }
    $oldErr = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
      Render-HtmlReport -Rows @($script:TestRow) -OutPath $script:OutPath | Out-Null
    } finally {
      $ErrorActionPreference = $oldErr
    }
    Test-Path $script:OutPath | Should -BeTrue
    $content = Get-Content $script:OutPath -Raw
    $content | Should -Match 'Vacancies'
    $content | Should -Match "Editor's Choice"
    $content | Should -Match 'Excellent opportunity'
  }
}
