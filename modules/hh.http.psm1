# hh.http.psm1 — HTTP client module with enhanced error handling and logging
#Requires -Version 7.5

# HTTP request statistics
$script:HttpStats = @{
    TotalRequests   = 0
    FailedRequests  = 0
    TotalBytes      = 0
    LastRequestTime = $null
}

# Rate limiting state
$script:RateLimitState = @{
    LastRequestTime = $null
    RequestCount    = 0
    WindowStart     = [datetime]::UtcNow
    IsRateLimited   = $false
    RateLimitReset  = $null
}

# Deterministic per-request pacing state (per-process)
if (-not $script:RateTsQueue) { $script:RateTsQueue = New-Object 'System.Collections.Generic.Queue[datetime]' }
if (-not $script:RateLock) { $script:RateLock = New-Object object }

# DDoS-Guard detection
$script:DdosGuardDetected = $false

# Concurrency limiter (shared across requests)
$script:HttpConcurrencyLimit = $null
$script:HttpSemaphore = $null
$script:HttpSemaphoreNamed = $null
$script:HttpSemaphoreName = 'Global\\hh_probe_http_semaphore'

<#
  .SYNOPSIS
  Returns configured HTTP concurrency limit.

  .DESCRIPTION
  Reads `api.rate_limit.concurrent_requests` from config, defaulting to 3.
  This controls how many HTTP requests may run simultaneously across the app.
#>
function Get-HttpConcurrencyLimit {
    try {
        return (Get-RateLimitSetting -Key 'concurrent_requests' -Default 3 -Type 'int')
    }
    catch { return 3 }
}

<#
  .SYNOPSIS
  Returns the global SemaphoreSlim used to limit HTTP concurrency.

  .DESCRIPTION
  Lazily initializes a semaphore sized to `Get-HttpConcurrencyLimit()`.
  Subsequent calls reuse the same semaphore to coordinate parallel requests.
#>
function Get-HttpSemaphore {
    if ($null -eq $script:HttpSemaphoreNamed -and $null -eq $script:HttpSemaphore) {
        try {
            $script:HttpConcurrencyLimit = Get-HttpConcurrencyLimit
            $createdNew = $false
            try {
                $script:HttpSemaphoreNamed = New-Object System.Threading.Semaphore( $script:HttpConcurrencyLimit, $script:HttpConcurrencyLimit, $script:HttpSemaphoreName, [ref]$createdNew )
            }
            catch {
                $script:HttpSemaphoreNamed = $null
            }
            if ($null -eq $script:HttpSemaphoreNamed) {
                $script:HttpSemaphore = New-Object System.Threading.SemaphoreSlim($script:HttpConcurrencyLimit, $script:HttpConcurrencyLimit)
            }
        }
        catch {}
    }
    if ($script:HttpSemaphoreNamed) { return $script:HttpSemaphoreNamed }
    return $script:HttpSemaphore
}

<#
  .SYNOPSIS
  Updates the HTTP concurrency limit at runtime.

  .DESCRIPTION
  Recreates the semaphore with the provided limit. Use with care when
  parallel jobs may be running; prefer setting via config before run start.
#>
function Set-HttpConcurrencyLimit {
    param([ValidateRange(1, 64)][int]$Limit)
    try {
        $script:HttpConcurrencyLimit = $Limit
        if ($script:HttpSemaphore) { try { $script:HttpSemaphore.Dispose() } catch {} }
        if ($script:HttpSemaphoreNamed) { try { $script:HttpSemaphoreNamed.Dispose() } catch {} }
        $script:HttpSemaphore = $null
        $script:HttpSemaphoreNamed = $null
        $createdNew = $false
        try {
            $script:HttpSemaphoreNamed = New-Object System.Threading.Semaphore($Limit, $Limit, $script:HttpSemaphoreName, [ref]$createdNew)
        }
        catch {
            $script:HttpSemaphoreNamed = $null
        }
        if ($null -eq $script:HttpSemaphoreNamed) {
            $script:HttpSemaphore = New-Object System.Threading.SemaphoreSlim($Limit, $Limit)
        }
        if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
            Write-LogFetch -Message "HTTP concurrency limit set to $Limit" -Level Verbose
        }
    }
    catch {}
}

function Wait-HttpSemaphore {
    param(
        [Parameter(Mandatory = $true)]$Semaphore,
        [int]$TimeoutMs = 60000
    )
    try {
        if ($Semaphore -is [System.Threading.Semaphore]) { return $Semaphore.WaitOne([int]$TimeoutMs) }
        if ($Semaphore -is [System.Threading.SemaphoreSlim]) { return $Semaphore.Wait([int]$TimeoutMs) }
    }
    catch {}
    return $true
}

function Release-HttpSemaphore {
    param([Parameter(Mandatory = $true)]$Semaphore)
    try {
        if ($Semaphore -is [System.Threading.Semaphore]) { $null = $Semaphore.Release(); return }
        if ($Semaphore -is [System.Threading.SemaphoreSlim]) { $null = $Semaphore.Release(); return }
    }
    catch {}
}

function Get-RateLimitSetting {
    param(
        [string]$Key,
        $Default,
        [ValidateSet('int', 'double')]$Type = 'int'
    )
    try {
        if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
            $value = Get-HHConfigValue -Path @('api', 'rate_limit', $Key) -Default $null
            if ($null -ne $value -and $value -ne '') {
                switch ($Type) {
                    'double' { return [double]$value }
                    default { return [int]$value }
                }
            }
        }
    }
    catch {}
    return $Default
}

$script:RateLimitConfig = @{
    RequestsPerMinute = Get-RateLimitSetting -Key 'requests_per_minute' -Default 40
    BaseDelayMs       = Get-RateLimitSetting -Key 'base_delay_ms' -Default 350
    MaxDelayMs        = Get-RateLimitSetting -Key 'max_delay_ms' -Default 6000
    JitterMinMs       = Get-RateLimitSetting -Key 'jitter_min_ms' -Default 300
    JitterMaxMs       = Get-RateLimitSetting -Key 'jitter_max_ms' -Default 600
}

function Get-RateLimitConfig {
    return $script:RateLimitConfig.Clone()
}

# LEGACY: external random.org dependency; situational utility — prefer local RNG or optional integration
function Get-TrueRandomIndex {
    param([Parameter(Mandatory = $true)][int]$MaxExclusive, [int]$TimeoutSec = 3)
    if ($MaxExclusive -le 1) { return 0 }
    $max = [int]($MaxExclusive - 1)
    $url = "https://www.random.org/integers/?num=1&min=0&max=$max&col=1&base=10&format=plain&rnd=new"
    try {
        $txt = Invoke-HttpRequest -Uri $url -Method 'GET' -Headers @{ 'User-Agent' = Get-HhUserAgent } -TimeoutSec $TimeoutSec -ApplyRateLimit -OperationName 'random.org'
        $s = [string]$txt
        if (-not [string]::IsNullOrWhiteSpace($s)) {
            $s = $s.Trim()
            $n = 0
            if ([int]::TryParse($s, [ref]$n)) {
                if ($n -ge 0 -and $n -lt $MaxExclusive) { return [int]$n }
            }
        }
    }
    catch {
        try { if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log -Message ("[Random] random.org failed: " + $_.Exception.Message) -Level Warning -Module 'Random' } } catch {}
    }
    return (Get-Random -Minimum 0 -Maximum $MaxExclusive)
}

<#
  .SYNOPSIS
  Extracts Retry-After delay from an HTTP exception if present.

  .DESCRIPTION
  Checks HttpResponseMessage headers for Retry-After (delta seconds or date),
  falling back to string header parsing. Returns milliseconds to wait.
#>
#
# Get-RetryAfterDelayMs
# Synopsis: Derives a retry delay from an HTTP exception, honoring standard
# Retry-After semantics (delta seconds or HTTP date) across HttpResponseMessage
# and HttpWebResponse, falling back to DefaultMs when unavailable.
function Get-RetryAfterDelayMs {
    param([object]$Exception, [int]$DefaultMs = 60000)
    try {
        $resp = $null
        try { $resp = $Exception.Response } catch {}
        if ($resp) {
            # PowerShell 7 typically wraps HttpResponseMessage
            if ($resp -is [System.Net.Http.HttpResponseMessage]) {
                $ra = $resp.Headers.RetryAfter
                if ($ra) {
                    if ($ra.Delta) { return [int][math]::Ceiling($ra.Delta.TotalMilliseconds) }
                    if ($ra.Date) {
                        $now = [datetime]::UtcNow
                        $dt = [datetime]$ra.Date
                        return [int][math]::Max(0, [math]::Ceiling(($dt - $now).TotalMilliseconds))
                    }
                }
                $values = $null
                if ($resp.Headers.TryGetValues('Retry-After', [ref]$values)) {
                    $v = (@($values) | Select-Object -First 1)
                    if ($v -match '^[0-9]+$') { return ([int]$v * 1000) }
                    $dt = $null
                    if ([datetime]::TryParse($v, [ref]$dt)) {
                        $now = [datetime]::UtcNow
                        return [int][math]::Max(0, [math]::Ceiling(($dt.ToUniversalTime() - $now).TotalMilliseconds))
                    }
                }
            }
            elseif ($resp -is [System.Net.HttpWebResponse]) {
                $h = $resp.Headers
                $v = $h['Retry-After']
                if ($v) {
                    if ($v -match '^[0-9]+$') { return ([int]$v * 1000) }
                    $dt = $null
                    if ([datetime]::TryParse($v, [ref]$dt)) {
                        $now = [datetime]::UtcNow
                        return [int][math]::Max(0, [math]::Ceiling(($dt.ToUniversalTime() - $now).TotalMilliseconds))
                    }
                }
            }
        }
    }
    catch {}
    return $DefaultMs
}

#
# Invoke-HttpRequest
# Synopsis: Robust HTTP wrapper with concurrency limiting, rate limiting,
# retries with backoff and jitter, and friendly error reporting.
# Description:
# - Applies a semaphore for concurrency control when available.
# - Honors external rate-limit settings and injects delays before requests.
# - Retries on transient failures, using Retry-After when provided.
# - Detects DDoS-Guard and 429 rate-limits, throws clean messages.
# - Emits concise operation timing and logs without raw stack traces.
function Invoke-HttpRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        
        [hashtable]$Headers = @{},
        
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH')]
        [string]$Method = 'GET',
        
        [object]$Body = $null,
        
        [int]$TimeoutSec = 30,
        
        [int]$MaxRetries = 2,
        
        [int]$RetryDelayMs = 500,
        
        [string]$OperationName = 'HTTP Request',
        
        [switch]$LogRequest = $true,
        
        [switch]$ApplyRateLimit = $true
    )
    
    # Start timing with a safe fallback if logging helpers are unavailable
    if (Get-Command -Name Start-Timing -ErrorAction SilentlyContinue) {
        $timer = Start-Timing -OperationName "$OperationName to $Uri"
    }
    else {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $attempt = 0
    $lastException = $null
    $effMaxRetries = $MaxRetries
    $effDelayMs = $RetryDelayMs
    try {
        if (-not $PSBoundParameters.ContainsKey('MaxRetries') -and (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
            $effMaxRetries = [int](Get-HHConfigValue -Path @('api', 'retry', 'max_attempts') -Default 3)
        }
    }
    catch {}
    try {
        if (-not $PSBoundParameters.ContainsKey('RetryDelayMs') -and (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
            $effDelayMs = [int](Get-HHConfigValue -Path @('api', 'retry', 'base_delay_ms') -Default 500)
        }
    }
    catch {}
    
    do {
        $attempt++
        try {
            # Concurrency limiting: acquire slot
            $sem = $null
            if (Get-Command -Name Get-HttpSemaphore -ErrorAction SilentlyContinue) { $sem = Get-HttpSemaphore }
            if ($sem) { $null = (Wait-HttpSemaphore -Semaphore $sem -TimeoutMs ([int]([math]::Max(5, $TimeoutSec) * 1000))) }
            try {
                # Apply rate limiting before request
                if ($ApplyRateLimit -and (Get-Command -Name Invoke-RateLimitDelay -ErrorAction SilentlyContinue)) {
                    $rl = Get-RateLimitConfig
                    $null = Invoke-RateLimitDelay -BaseDelayMs $rl.BaseDelayMs -MaxDelayMs $rl.MaxDelayMs -RequestsPerMinute $rl.RequestsPerMinute -JitterMinMs $rl.JitterMinMs -JitterMaxMs $rl.JitterMaxMs
                }
            
                # Prepare request parameters
                $params = @{
                    Uri         = $Uri
                    Method      = $Method
                    Headers     = $Headers
                    TimeoutSec  = $TimeoutSec
                    ErrorAction = 'Stop'
                }
                if (-not $params.Headers.ContainsKey('HH-User-Agent')) { $params.Headers['HH-User-Agent'] = 'hh_probe (local dev)' }
            
                # Add body if provided
                if ($Body) {
                    if ($Body -is [string]) {
                        $params.Body = $Body
                    }
                    else {
                        $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
                        if (-not $params.Headers.ContainsKey('Content-Type')) {
                            $params.Headers['Content-Type'] = 'application/json'
                        }
                    }
                }
            
                # Log request if enabled
                if ($LogRequest -and (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue)) {
                    Write-LogFetch -Message "$Method $Uri (attempt $attempt/$($effMaxRetries + 1))" -Level Verbose
                }
            
                # Execute request
                $response = Invoke-RestMethod @params

                # Update statistics
                $script:HttpStats.TotalRequests++
                $script:HttpStats.LastRequestTime = Get-Date
            
                # Log successful request
                if ($LogRequest -and (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue)) {
                    $elapsedMs = $null
                    if (Get-Command -Name Stop-Timing -ErrorAction SilentlyContinue) {
                        $elapsedMs = Stop-Timing -Timer $timer
                    }
                    elseif ($timer -is [System.Diagnostics.Stopwatch]) {
                        $timer.Stop(); $elapsedMs = [int]$timer.ElapsedMilliseconds
                    }
                    Write-LogFetch -Message "$Method $Uri completed in $elapsedMs ms" -Level Verbose
                }
            
                return $response
            }
            finally {
                if ($sem) { try { Release-HttpSemaphore -Semaphore $sem } catch {} }
            }
            
        }
        catch {
            $lastException = $_
            $script:HttpStats.FailedRequests++
            
            # Check for DDoS-Guard protection only on hh.ru (web) pages, not api.hh.ru
            $uriStr = try { [string]$Uri } catch { '' }
            $isWebHh = ($uriStr -match '^https?://(www\.)?hh\.ru/') -and -not ($uriStr -match '^https?://api\.hh\.ru/')
            $isDdosGuard = $false
            if ($isWebHh) {
                $isDdosGuard = $_.Exception.Message -match 'DDoS-Guard' -or $_.Exception.Message -match '403.*Forbidden'
            }
            
            # Check for rate limiting (429)
            $isRateLimit = $false
            try {
                $resp = $_.Exception.Response
                if ($resp -is [System.Net.Http.HttpResponseMessage]) {
                    $isRateLimit = ([int]$resp.StatusCode -eq 429)
                }
                elseif ($resp -is [System.Net.HttpWebResponse]) {
                    $isRateLimit = ([int]$resp.StatusCode -eq 429)
                }
            }
            catch {}
            if (-not $isRateLimit) {
                $isRateLimit = $_.Exception.Message -like '*429*' -or $_.Exception.Message -like '*Too Many Requests*'
            }

            $status = -1
            try {
                $resp = $_.Exception.Response
                if ($resp -is [System.Net.Http.HttpResponseMessage]) { $status = [int]$resp.StatusCode }
                elseif ($resp -is [System.Net.HttpWebResponse]) { $status = [int]$resp.StatusCode }
            }
            catch {}
            if ($status -lt 0) {
                $m = [string]$_.Exception.Message
                if ($m -match '(\d{3})') { try { $status = [int]$Matches[1] } catch {} }
            }
            $isAuth = ($status -eq 401) -or ($_.Exception.Message -like '*401*')
            $isTransient = ($status -ge 500 -and $status -lt 600) -or $isRateLimit -or ($_.Exception.Message -like '*timeout*')
            $isPermanent = ($status -ge 400 -and $status -lt 500 -and -not $isRateLimit -and -not $isAuth)
            
            # Log error
            if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                $level = if ($isRateLimit) { 'Warning' } else { 'Warning' }
                $errMsg = "Unknown error"
                try {
                    if ($_ -and $_.Exception) { $errMsg = $_.Exception.Message }
                    elseif ($_ -and $_.Message) { $errMsg = $_.Message }
                    elseif ($_) { $errMsg = [string]$_ }
                }
                catch { $errMsg = "Error processing exception: $($_.Exception.Message)" }
                
                Write-LogFetch -Message "$Method $Uri failed (attempt $attempt/$($MaxRetries + 1)): $errMsg" -Level $level
                
                # Debug: log full error record if possible
                if ($DebugPreference -ne 'SilentlyContinue') {
                    Write-LogFetch -Message "DEBUG: ErrorRecord type: $($_.GetType().FullName)" -Level Debug
                    Write-LogFetch -Message "DEBUG: Exception type: $($_.Exception.GetType().FullName)" -Level Debug
                }
            }
            
            # Handle DDoS-Guard protection
            if ($isDdosGuard) {
                Set-DdosGuardDetected
                throw "DDoS-Guard protection detected - stopping all scraping attempts"
            }
            
            # Handle rate limiting
            if ($isRateLimit) {
                $delayMs = Get-RetryAfterDelayMs -Exception $_.Exception -DefaultMs 60000
                $resetTime = [datetime]::UtcNow.AddMilliseconds([double]$delayMs)
                Set-RateLimited -ResetTime $resetTime
                # Respect server guidance; add jitter 20-40%
                $jitFactor = Get-Random -Minimum 0.2 -Maximum 0.4
                $effDelayMs = [int][math]::Ceiling($delayMs * (1.0 + $jitFactor))
            }
            
            if ($isAuth -or $isPermanent) { throw }
            if ($isTransient -and ($attempt -le $effMaxRetries)) {
                if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                    Write-LogFetch -Message "Retrying in $([math]::Ceiling($effDelayMs/1000)) seconds..." -Level Verbose
                }
                Start-Sleep -Milliseconds $effDelayMs
                $effDelayMs = [math]::Min([int]([double]$effDelayMs * 2.0), 120000)
            }
        }
    } while ($attempt -le $effMaxRetries)
    
    # All retries failed
    if (Get-Command -Name Write-LogError -ErrorAction SilentlyContinue) {
        $exToLog = $lastException
        if ($lastException -and $lastException.PSObject.Properties['Exception']) { $exToLog = $lastException.Exception }
        Write-LogError -Message "HTTP request failed after $attempt attempts: $Method $Uri" -Exception $exToLog -Module 'HTTP'
    }
    
    throw $lastException
}

# HH API specific functions
# Base URL and header helpers
function Get-HhApiBaseUrl {
    $base = $null
    if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
        $base = [string](Get-HHConfigValue -Path @('api', 'base_url'))
    }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'https://api.hh.ru' }
    return $base.TrimEnd('/')
}

function Get-HhUserAgent {
    $ua = $null
    if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
        $ua = [string](Get-HHConfigValue -Path @('scrape', 'user_agent'))
    }
    if ([string]::IsNullOrWhiteSpace($ua)) {
        # Use common browser User-Agent to appear as regular user
        $platform = if ($IsWindows) {
            "Windows NT 10.0; Win64; x64"
        }
        elseif ($IsLinux) {
            "X11; Linux x86_64"
        }
        elseif ($IsMacOS) {
            "Macintosh; Intel Mac OS X 10_15_7"
        }
        else {
            "Windows NT 10.0; Win64; x64"
        }
        $ua = "Mozilla/5.0 ($platform) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    }
    return $ua
}

function Get-HhDefaultHeaders {
    param([switch]$IncludeAuth)
    $headers = @{}
    $headers['User-Agent'] = Get-HhUserAgent
    if ($IncludeAuth) {
        $token = $null
        if (Get-Command -Name Get-HhToken -ErrorAction SilentlyContinue) { $token = Get-HhToken }
        
        $xsrf = $null
        if (Get-Command -Name Get-HhXsrf -ErrorAction SilentlyContinue) { $xsrf = Get-HhXsrf }
        
        if ([string]::IsNullOrWhiteSpace($token)) {
            try { $token = [string](Get-HHConfigValue -Path @('keys', 'hh_token')) } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($token)) { try { $token = [string]$env:HH_TOKEN } catch {} }

        if (-not [string]::IsNullOrWhiteSpace($token)) { 
            if (-not [string]::IsNullOrWhiteSpace($xsrf)) {
                $headers['Cookie'] = "hhtoken=$token; _xsrf=$xsrf"
                $headers['X-Xsrftoken'] = $xsrf
                $headers['X-Requested-With'] = 'XMLHttpRequest'
            }
            else {
                $headers['Authorization'] = "Bearer $token" 
            }
        }
    }
    # Add Referer if Cookie is present (implicit check via logic above or explicit)
    if ($headers.ContainsKey('Cookie') -and -not $headers.ContainsKey('Referer')) {
        $headers['Referer'] = 'https://hh.ru/'
    }
    return $headers
}

#
# Invoke-HhApiRequest
# Synopsis: Convenience wrapper for HH API calls.
# Description:
# - Builds full HH API URL when given a relative endpoint.
# - Adds Authorization and User-Agent headers when required/missing.
# - Delegates execution to Invoke-HttpRequest with optional rate limiting.
# Notes: Throws a clear error if a token is required but not available.
# HH API specific functions
function Invoke-HhApiRequest {
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Path')]
        [string]$Endpoint,
        
        [hashtable]$Headers = @{},
        
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method = 'GET',
        
        [object]$Body = $null,
        
        [int]$TimeoutSec = 30,
        
        [switch]$RequireAuth = $true,
        
        [switch]$ApplyRateLimit = $true
    )
    
    # Add HH API base URL
    $uri = $Endpoint
    if ($uri -notmatch '^https?://') {
        $baseUrl = Get-HhApiBaseUrl
        $path = if ($Endpoint.StartsWith('/')) { $Endpoint } else { "/$Endpoint" }
        $uri = "$baseUrl$path"
    }
    
    # Ensure authentication headers if required
    if ($RequireAuth -and -not $Headers.ContainsKey('Authorization') -and -not $Headers.ContainsKey('Cookie')) {
        $hhToken = Get-HhToken
        $hhXsrf = Get-HhXsrf

        if ($hhToken) {
            # Prefer standard OAuth Bearer auth as it is more reliable for API calls
            $Headers['Authorization'] = "Bearer $hhToken"
            
            # Only add Cookie/XSRF if specifically needed (legacy behavior preserved but deprioritized)
            # If we find endpoints that strict require cookies, we can add logic here.
            # For now, we rely on Bearer auth which is confirmed working for /me.
        }
        elseif ($hhToken -and $hhXsrf) {
            # Fallback to Cookie-based auth (hhtoken + _xsrf) if for some reason we only want to use this path
            # (This block is currently unreachable due to the if above, but keeping structure for clarity if we change logic)
            $Headers['Cookie'] = "hhtoken=$hhToken; _xsrf=$hhXsrf"
            $Headers['X-Xsrftoken'] = $hhXsrf
            if (-not $Headers.ContainsKey('X-Requested-With')) { $Headers['X-Requested-With'] = 'XMLHttpRequest' }
        }
        else {
            throw "HH API token not available for authenticated request to $Endpoint"
        }
    }
    
    # Add User-Agent if not present
    if (-not $Headers.ContainsKey('User-Agent')) {
        $Headers['User-Agent'] = Get-HhUserAgent
    }
    
    # Add Referer for cookie-based auth
    if ($Headers.ContainsKey('Cookie') -and -not $Headers.ContainsKey('Referer')) {
        $Headers['Referer'] = 'https://hh.ru/'
    }
    
    # Track HTTP stats
    if (Get-Command -Name Bump-Http -ErrorAction SilentlyContinue) {
        Bump-Http
    }
    
    return Invoke-HttpRequest -Uri $uri -Headers $Headers -Method $Method -Body $Body -TimeoutSec $TimeoutSec -OperationName "HH API $Method" -ApplyRateLimit:$ApplyRateLimit
}

#
# Invoke-LlmApiRequest
# Synopsis: Convenience wrapper for LLM provider API calls.
# Description:
# - Resolves base URL from config (`llm.endpoint_base` or `llm.endpoint`),
#   defaulting to `https://api.deepseek.com`.
# - Adds Authorization header from configured LLM API key.
# - Ensures `Content-Type: application/json` for POST requests.
# - Delegates execution to Invoke-HttpRequest and surfaces clean errors.
# LLM API specific functions
function Invoke-LlmApiRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [hashtable]$Headers = @{},
        
        [ValidateSet('GET', 'POST')]
        [string]$Method = 'POST',
        
        [object]$Body = $null,
        
        [int]$TimeoutSec = 90
    )
    
    # Add LLM API base URL
    $uri = $Endpoint
    if ($uri -notmatch '^https?://') {
        $base = $null
        if (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue) {
            # Try new generic service config first
            $base = [string](Get-HHConfigValue -Path @('llm', 'service', 'base_url'))
            
            # Fallback to legacy config
            if ([string]::IsNullOrWhiteSpace($base)) {
                $base = [string](Get-HHConfigValue -Path @('llm', 'endpoint_base'))
            }
            if ([string]::IsNullOrWhiteSpace($base)) {
                $base = [string](Get-HHConfigValue -Path @('llm', 'endpoint'))
            }
        }
        if ([string]::IsNullOrWhiteSpace($base)) {
            # No fallback: require explicit configuration
            return $null
        }
        $uri = ($base.TrimEnd('/')) + '/' + ($Endpoint.TrimStart('/'))
    }
    
    # Ensure authentication headers
    if (-not $Headers.ContainsKey('Authorization')) {
        $llmApiKey = Get-LlmApiKey
        if ($llmApiKey) {
            $Headers['Authorization'] = "Bearer $llmApiKey"
        }
        else {
            # If no key, we can't proceed unless the endpoint allows anon (unlikely for LLM)
            # But maybe it's localhost? Ollama doesn't need key usually.
            # Let's throw if we are not on localhost and have no key.
            if ($uri -notmatch 'localhost' -and $uri -notmatch '127.0.0.1') {
                throw "LLM API key not available for request to $Endpoint"
            }
        }
    }
    
    # Add Content-Type for POST requests
    if ($Method -eq 'POST' -and -not $Headers.ContainsKey('Content-Type')) {
        $Headers['Content-Type'] = 'application/json'
    }
    
    try {
        $hdrKeys = @()
        try { $hdrKeys = @($Headers.Keys) } catch {}
        $bodyLen = 0
        try {
            if ($Body) {
                if ($Body -is [string]) { $bodyLen = [int]$Body.Length }
                else {
                    $preview = ($Body | ConvertTo-Json -Depth 4 -Compress)
                    if ($preview) { $bodyLen = [int]$preview.Length }
                }
            }
        }
        catch {}
        if (Get-Command -Name Write-LogLLM -ErrorAction SilentlyContinue) {
            Write-LogLLM ("[LLM HTTP] prep: {0} {1} timeout={2}s headers={3} body_len={4}" -f $Method, $uri, $TimeoutSec, ([string]($hdrKeys -join ',')), $bodyLen) -Level Verbose
        }
    }
    catch {}
    
    try {
        $resp = Invoke-HttpRequest -Uri $uri -Headers $Headers -Method $Method -Body $Body -TimeoutSec $TimeoutSec -OperationName "LLM API $Method"
        try {
            $typeName = ''
            try { $typeName = $resp.GetType().FullName } catch {}
            $rPrev = ''
            try {
                if ($resp -is [string]) { $rPrev = $resp }
                else { $rPrev = ($resp | ConvertTo-Json -Depth 4 -Compress) }
                if ($rPrev) { $rPrev = $rPrev.Substring(0, [Math]::Min(300, [Math]::Max(0, $rPrev.Length))) }
            }
            catch {}
            if (Get-Command -Name Write-LogLLM -ErrorAction SilentlyContinue) {
                Write-LogLLM ("[LLM HTTP] ok: {0} {1} type={2} preview={3}" -f $Method, $uri, $typeName, $rPrev) -Level Verbose
            }
        }
        catch {}
        return $resp
    }
    catch {
        try {
            if (Get-Command -Name Write-LogLLM -ErrorAction SilentlyContinue) {
                Write-LogLLM ("[LLM HTTP] fail: {0} {1} error={2}" -f $Method, $uri, $_.Exception.Message) -Level Warning
            }
        }
        catch {}
        throw
    }
}

# Token management functions
function Get-HhToken {
    if (-not (Get-Command -Name Get-HHSecrets -ErrorAction SilentlyContinue)) { return $null }
    $secrets = Get-HHSecrets
    if (-not $secrets) { return $null }
    $token = [string]$secrets.HHToken
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    return $token
}

function Get-HhXsrf {
    if (-not (Get-Command -Name Get-HHSecrets -ErrorAction SilentlyContinue)) { return $null }
    $secrets = Get-HHSecrets
    if (-not $secrets) { return $null }
    if (-not $secrets.PSObject.Properties['HHXsrf']) { return $null }
    $xsrf = [string]$secrets.HHXsrf
    if ([string]::IsNullOrWhiteSpace($xsrf)) { return $null }
    return $xsrf
}

function Get-LlmApiKey {
    # Resolve LLM API key from secrets or environment
    $apiKey = ''
    try {
        if (Get-Command -Name Get-HHSecrets -ErrorAction SilentlyContinue) {
            $secrets = Get-HHSecrets
            if ($secrets -and -not [string]::IsNullOrWhiteSpace([string]$secrets.LlmApiKey)) {
                $apiKey = [string]$secrets.LlmApiKey
            }
        }
    }
    catch {}

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        # Environment fallback for tests and simple setups
        $apiKey = $env:LLM_API_KEY
    }

    if ([string]::IsNullOrWhiteSpace($apiKey)) { return $null }
    return [string]$apiKey
}

# HTTP statistics functions
function Get-HttpStats {
    return $script:HttpStats.Clone()
}

function Reset-HttpStats {
    $script:HttpStats = @{
        TotalRequests   = 0
        FailedRequests  = 0
        TotalBytes      = 0
        LastRequestTime = $null
    }
}

function Write-HttpStats {
    param([string]$Module = 'Main')
    
    $stats = Get-HttpStats
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "HTTP Stats: Total=$($stats.TotalRequests) Failed=$($stats.FailedRequests) Last=$($stats.LastRequestTime)" -Level Verbose -Module $Module
    }
}

# Rate limiting helpers
function Invoke-Jitter {
    param(
        [int]$MinMs = 100,
        [int]$MaxMs = 300
    )
    
    # In debug mode, bypass jitter to keep profiling faster and deterministic
    if ($Debug) { return }
    
    $delay = Get-Random -Minimum $MinMs -Maximum $MaxMs
    Start-Sleep -Milliseconds $delay
}

function Invoke-RateLimitDelay {
    param(
        [int]$BaseDelayMs = 140,
        [int]$MaxDelayMs = 2000,
        [int]$RequestsPerMinute = 20,
        [int]$JitterMinMs = 140,
        [int]$JitterMaxMs = 240,
        [datetime]$Now,
        [switch]$NoSleep
    )
    
    $now = if ($PSBoundParameters.ContainsKey('Now')) { $Now.ToUniversalTime() } else { [datetime]::UtcNow }
    
    # Honor server-enforced cooldown window first
    if ($script:RateLimitState.IsRateLimited -and $script:RateLimitState.RateLimitReset) {
        $resetTime = $script:RateLimitState.RateLimitReset
        if ($now -lt $resetTime) {
            $waitMs = [int][math]::Ceiling(($resetTime - $now).TotalMilliseconds)
            if ($waitMs -gt 0 -and -not $NoSleep) {
                if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
                    Write-LogFetch -Message "Rate limited, waiting $([math]::Ceiling($waitMs/1000)) seconds until reset" -Level Warning
                }
                Start-Sleep -Milliseconds $waitMs
            }
        }
    }
    
    $rpm = [int][math]::Max(1, $RequestsPerMinute)
    $perRequestMs = [int][math]::Max(0, [math]::Floor(60000 / $rpm))
    $delayMs = 0
    $targetTime = $now
    
    [bool]$taken = $false
    try {
        if ($null -eq $script:RateLock) { throw "RateLock is NULL" }
        [System.Threading.Monitor]::Enter($script:RateLock, [ref]$taken) | Out-Null
        
        if ($null -eq $script:RateTsQueue) { throw "RateTsQueue is NULL" }
        # Trim old stamps
        $cutoff = $now.AddSeconds(-60)
        while ($script:RateTsQueue.Count -gt 0 -and $script:RateTsQueue.Peek() -lt $cutoff) { $null = $script:RateTsQueue.Dequeue() }
        
        # Calculate delay
        if ($script:RateTsQueue.Count -ge $rpm) {
            $oldest = $script:RateTsQueue.Peek()
            $targetTime = $oldest.AddMinutes(1)
        }
        
        # Ensure minimum spacing
        if ($script:RateLimitState.LastRequestTime) {
            $minNext = $script:RateLimitState.LastRequestTime.AddMilliseconds($BaseDelayMs)
            if ($targetTime -lt $minNext) { $targetTime = $minNext }
        }
        
        $delayMs = [int][math]::Max(0, [math]::Ceiling(($targetTime - $now).TotalMilliseconds))
        
        $jitMin = [math]::Max(0, $JitterMinMs)
        $jitMax = [math]::Max($jitMin, $JitterMaxMs)
        $jitter = 0
        if ($jitMax -gt 0) { $jitter = Get-Random -Minimum $jitMin -Maximum ($jitMax + 1) }
        $delayTotal = $delayMs + $jitter
        
        if ($NoSleep) {
            $script:RateTsQueue.Enqueue($targetTime)
            return $delayTotal
        }
        else {
            if ($delayTotal -gt 0) { Start-Sleep -Milliseconds $delayTotal }
            $stamp = [datetime]::UtcNow
            $script:RateTsQueue.Enqueue($stamp)
            if ($delayTotal -gt 0 -and (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue)) {
                Write-LogFetch -Message "[RateLimit] pacing: sleep $delayTotal ms (rpm=$rpm)" -Level Verbose
            }
            return $delayTotal
        }
    }
    finally {
        if ($taken) {
            if ($null -eq $script:RateLock) { throw "RateLock is NULL in FINALLY" }
            [System.Threading.Monitor]::Exit($script:RateLock)
        }
    }
}

function Set-RateLimited {
    param(
        [datetime]$ResetTime
    )
    
    $script:RateLimitState.IsRateLimited = $true
    $script:RateLimitState.RateLimitReset = $ResetTime
    
    if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
        $waitSeconds = [math]::Ceiling(($ResetTime - [datetime]::UtcNow).TotalSeconds)
        Write-LogFetch -Message "Rate limit enforced: waiting $waitSeconds seconds until reset" -Level Warning
    }
}

function Get-RateLimitState {
    return $script:RateLimitState.Clone()
}

# DDoS-Guard detection functions
function Reset-DdosGuardDetection {
    $script:DdosGuardDetected = $false
}

function Test-DdosGuardDetected {
    return $script:DdosGuardDetected
}

function Set-DdosGuardDetected {
    $script:DdosGuardDetected = $true
    if (Get-Command -Name Write-LogFetch -ErrorAction SilentlyContinue) {
        Write-LogFetch -Message "DDoS-Guard protection detected - stopping all scraping attempts" -Level Warning
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Invoke-HttpRequest',
    'Invoke-HhApiRequest',
    'Invoke-LlmApiRequest',
    'Get-RetryAfterDelayMs',
    'Get-HttpConcurrencyLimit',
    'Set-HttpConcurrencyLimit',
    'Get-HhToken',
    'Get-HhXsrf',
    'Get-LlmApiKey',
    'Get-HhApiBaseUrl',
    'Get-HhUserAgent',
    'Get-HhDefaultHeaders',
    'Get-HttpStats',
    'Reset-HttpStats',
    'Write-HttpStats',
    'Invoke-Jitter',
    'Invoke-RateLimitDelay',
    'Wait-HttpSemaphore',
    'Release-HttpSemaphore',
    'Set-RateLimited',
    'Get-RateLimitState',
    'Get-RateLimitConfig',
    'Reset-DdosGuardDetection',
    'Test-DdosGuardDetected',
    'Set-DdosGuardDetected'
)
