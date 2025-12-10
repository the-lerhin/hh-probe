param()

# Import renderer
Import-Module -Force (Join-Path $PSScriptRoot '../modules/hh.render.psm1')

Describe 'Quick HTML report rendering' {
  It 'renders 3 pick cards and shows summaries and open text' {
    # Build minimal canonical rows
    $now = Get-Date
    $rows = @(
      [pscustomobject]@{
        id = '1'
        title = 'Senior Backend Engineer'
        link = 'https://hh.ru/vacancy/1'
        employer = [pscustomobject]@{ name = 'Acme Corp'; open = 12; size = '1000+'; rating = 4.5 }
        country = 'Russia'
        city = 'Moscow'
        salary = [pscustomobject]@{ text = 'от 250 000 ₽' }
        meta = [pscustomobject]@{ summary = [pscustomobject]@{ text = 'High-impact backend work, modern stack.' } }
        picks = [pscustomobject]@{ is_editors_choice = $true; editors_why = 'Best overall.' }
        published_at = $now.AddDays(-2)
        age_text = '2d'
        score = 0.9
      },
      [pscustomobject]@{
        id = '2'
        title = 'Data Scientist'
        link = 'https://hh.ru/vacancy/2'
        employer = [pscustomobject]@{ name = 'Beta Analytics'; open = 5; size = '200-500'; rating = 4.2 }
        country = 'Kazakhstan'
        city = 'Almaty'
        salary = [pscustomobject]@{ text = 'до 600 000 ₸' }
        meta = [pscustomobject]@{ summary = [pscustomobject]@{ text = 'Research-heavy role, NLP focus.' } }
        picks = [pscustomobject]@{ is_lucky = $true; lucky_why = 'Feels promising.' }
        published_at = $now.AddHours(-10)
        age_text = '10h'
        score = 0.7
      },
      [pscustomobject]@{
        id = '3'
        title = 'QA Engineer'
        link = 'https://hh.ru/vacancy/3'
        employer = [pscustomobject]@{ name = 'Gamma Testers'; open = 2; size = '50-100'; rating = 3.8 }
        country = 'Russia'
        city = 'Saint Petersburg'
        salary = [pscustomobject]@{ text = '60 000–90 000 ₽' }
        meta = [pscustomobject]@{ summary = [pscustomobject]@{ text = 'Solid QA process, room to grow.' } }
        picks = [pscustomobject]@{ is_worst = $true; worst_why = 'Outdated tooling.' }
        published_at = $now.AddDays(-7)
        age_text = '1w'
        score = 0.2
      }
    )

    # Build model with derived picks
    $mkPick = {
      param($row, [string]$kind)
      if (-not $row) { return $null }
      $p = [pscustomobject]@{
        title = $row.title
        link = $row.link
        employer = [pscustomobject]@{ name = $row.employer.name }
        city = $row.city
      }
      switch ($kind) {
        'ec'    { $p | Add-Member -NotePropertyName 'editors_why' -NotePropertyValue ($row.picks.editors_why) }
        'lucky' { $p | Add-Member -NotePropertyName 'lucky_why'   -NotePropertyValue ($row.picks.lucky_why) }
        'worst' { $p | Add-Member -NotePropertyName 'worst_why'   -NotePropertyValue ($row.picks.worst_why) }
      }
      return $p
    }
    $model = [pscustomobject]@{
      rows = $rows
      picks_enabled = $true
      show_summaries = $true
      picks = [pscustomobject]@{
        ec    = & $mkPick ($rows | Where-Object { $_.picks.is_editors_choice }) 'ec'
        lucky = & $mkPick ($rows | Where-Object { $_.picks.is_lucky }) 'lucky'
        worst = & $mkPick ($rows | Where-Object { $_.picks.is_worst }) 'worst'
      }
    }

    $html = Render-Template -TemplatePath (Join-Path $PSScriptRoot '../templates/report.hbs') -Model $model
    $html | Should -Not -BeNullOrEmpty

    # Cards count == 3 (look for specific card variants)
    $ec = ([regex]::Matches($html, 'class="card card-ec')).Count + ([regex]::Matches($html, "class='card card-ec")).Count
    $lk = ([regex]::Matches($html, 'class="card card-lucky')).Count + ([regex]::Matches($html, "class='card card-lucky")).Count
    $wr = ([regex]::Matches($html, 'class="card card-worst')).Count + ([regex]::Matches($html, "class='card card-worst")).Count
    $cards = $ec + $lk + $wr
    $cards | Should -Be 3

    # HTML contains summary and open text
    # Handlebars might use single quotes or double quotes depending on context/helper output
    $hasSummary = $html -match '<div class="summary">' -or $html -match "<div class='summary'>"
    $hasOpen = $html -match 'Open' -or $html -match 'open'

    # Debug output if failed
    if (-not $hasSummary) { Write-Host "HTML content dump (partial):" ($html.Substring(0, [Math]::Min($html.Length, 1000))) }

    $hasSummary | Should -BeTrue
    $hasOpen | Should -BeTrue
  }
}
