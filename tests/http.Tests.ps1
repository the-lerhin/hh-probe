# Pester tests for critical HTTP/API logic

$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
Import-Module -Force (Join-Path $root 'modules/hh.http.psm1')
Import-Module -Force (Join-Path $root 'modules/hh.config.psm1')

Describe 'Invoke-HttpRequest' -Tag @('FR-1.3','SDD-4.5','unit') {
  Context 'Rate limit detection and backoff' {
    BeforeEach {
      Mock Invoke-RestMethod -ModuleName hh.http { throw [System.Exception]::new('429 Too Many Requests') }
      Mock Start-Sleep -ModuleName hh.http {}
    }

    It 'sets rate limit and eventually throws after retries' {
      $threw = $false
      try { Invoke-HttpRequest -Uri 'https://example.com/api' -Method 'GET' -MaxRetries 1 -TimeoutSec 1 } catch { $threw = $true }
      $threw | Should -BeTrue
      $state = Get-RateLimitState
      $state.IsRateLimited | Should -Be $true
    }
  }

  Context 'DDoS-Guard protection' {
    BeforeEach {
      Mock Invoke-RestMethod -ModuleName hh.http { throw [System.Exception]::new('DDoS-Guard: 403 Forbidden') }
      Mock Start-Sleep -ModuleName hh.http {}
    }

    It 'throws protective message without raw stack trace' {
      $threw = $false; $msg = ''
      try { Invoke-HttpRequest -Uri 'https://hh.ru/vacancy/123' -Method 'GET' -MaxRetries 2 } catch { $threw = $true; $msg = $_.Exception.Message }
      $threw | Should -BeTrue
      $msg   | Should -Match 'DDoS-Guard protection detected'
    }
  }
}

Describe 'Get-RetryAfterDelayMs' -Tag @('FR-1.3','SDD-4.5','unit') {
  It 'reads Retry-After header when available' {
    $resp = New-Object System.Net.Http.HttpResponseMessage([System.Net.HttpStatusCode]::TooManyRequests)
    $resp.Headers.RetryAfter = New-Object System.Net.Http.Headers.RetryConditionHeaderValue([TimeSpan]::FromSeconds(5))
    $ex = New-Object System.Exception('429')
    # Simulate exception with Response property
    $ex | Add-Member -MemberType NoteProperty -Name Response -Value $resp
    $ms = Get-RetryAfterDelayMs -Exception $ex
    ($ms -ge 5000) | Should -BeTrue
  }
}

Describe 'Invoke-LlmApiRequest' -Tag @('FR-5.1b','SDD-4.10','unit') {
  BeforeAll { $env:DEEPSEEK_API_KEY = 'test-key-123' }
  AfterAll { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }

  It 'adds Authorization header and calls through' {
    Mock Get-LlmApiKey -ModuleName hh.http { return 'test-key-123' }
    Mock Invoke-HttpRequest -ModuleName hh.http -MockWith {
      param([string]$Uri,[hashtable]$Headers,[string]$Method,[object]$Body)
      return @{ ok = $true; uri = $Uri; method = $Method; auth = $Headers['Authorization'] }
    }

    $res = Invoke-LlmApiRequest -Endpoint '/v1/test' -Method 'POST' -Body @{ model = 'gpt-4o-mini'; messages = @() }
    $res.auth | Should -Be 'Bearer test-key-123'
    $res.uri  | Should -Match '^https?://'
  }
}

Describe 'Invoke-HhApiRequest' -Tag @('FR-1.3','SDD-4.5','unit') {
  It 'throws when auth required and token missing' {
    Mock Get-HhToken -ModuleName hh.http { $null }
    $threw = $false; $msg = ''
    try { Invoke-HhApiRequest -Endpoint '/vacancies' -RequireAuth } catch { $threw = $true; $msg = $_.Exception.Message }
    $threw | Should -BeTrue
    $msg   | Should -Match 'token not available'
  }

  It 'builds full URL and passes through' {
    Mock Get-HhToken -ModuleName hh.http { 'token-xyz' }
    Mock Invoke-HttpRequest -ModuleName hh.http -MockWith { param([string]$Uri) return @{ uri = $Uri } }
    $out = Invoke-HhApiRequest -Endpoint '/vacancies' -Method 'GET'
    $out.uri | Should -Match 'https://api.hh.ru/'
  }
}
