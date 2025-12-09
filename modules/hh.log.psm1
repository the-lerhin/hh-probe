# hh.log.psm1 — Structured logging module using PSFramework
#Requires -Version 7.5
#Requires -Module PSFramework

<#
  Initialize-Logging
  Brief: Configures PSFramework logging providers in an idempotent manner.
  - Guards against duplicate initialization using a module-scoped flag.
  - Exposes `Get-LoggingInitialized` to query the flag for tests.
#>

# Module-scoped idempotency flag
if (-not (Get-Variable -Name HH_LoggingInitialized -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name HH_LoggingInitialized -Scope Script -Value $false
}





# Initialize PSFramework logging configuration
function Initialize-Logging {
    param(
        [string]$LogPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) "hh.log")
    )
    # Prevent double-initialization
    if ($script:HH_LoggingInitialized) { return }
    
    # Configure PSFramework logging with proper parameters
    # Use -InstanceName to create a unique instance and -Wait to ensure immediate activation
    Set-PSFLoggingProvider -Name logfile -InstanceName 'hh_main' -Enabled $true -FilePath $LogPath -Wait
    Set-PSFLoggingProvider -Name console -Enabled $true
    
    # Set log levels based on debug mode
    Set-PSFConfig -FullName 'PSFramework.Logging.Console.1.IncludeWarning' -Value $true

    if ($script:Debug -or $VerbosePreference -eq 'Continue') {
        Set-PSFConfig -FullName 'PSFramework.Logging.Console.1.IncludeVerbose' -Value $true
    }
    else {
        Set-PSFConfig -FullName 'PSFramework.Logging.Console.1.IncludeVerbose' -Value $false
    }

    if ($script:Debug) {
        Set-PSFConfig -FullName 'PSFramework.Logging.Console.1.IncludeDebug' -Value $true
    }
    else {
        Set-PSFConfig -FullName 'PSFramework.Logging.Console.1.IncludeDebug' -Value $false
    }
    
    Write-PSFMessage -Level Host -Message "Logging initialized" -Tag 'Startup'
    $script:HH_LoggingInitialized = $true
    
    # Verify the provider is enabled
    try {
        $provider = Get-PSFLoggingProvider -Name logfile
        if ($provider -and -not $provider.Enabled) {
            Write-Warning "PSFramework logfile provider failed to enable. Logs may not be written to file."
        }
    }
    catch {
        Write-Warning "Failed to verify PSFramework logfile provider status: $_"
    }
}

<#
  Get-LoggingInitialized
  Brief: Returns the module-scoped initialization flag for logging.
#>
function Get-LoggingInitialized {
    return [bool]$script:HH_LoggingInitialized
}

# Main logging function - replaces Log-Step
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [ValidateSet('Host', 'Important', 'Output', 'Warning', 'Error', 'Verbose', 'Debug')]
        [string]$Level = 'Verbose',
        
        [string]$Module = 'Main',
        
        [string]$FunctionName = $MyInvocation.InvocationName,
        
        [int]$LineNumber = $MyInvocation.ScriptLineNumber
    )
    
    # Add timestamp and module prefix
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $formattedMessage = "[$timestamp] [$Module] $Message"
    


    # Map to PSFramework levels
    switch ($Level) {
        'Host' { Write-PSFMessage -Level Host -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
        'Important' { Write-PSFMessage -Level Important -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
        'Output' { Write-PSFMessage -Level Output -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
        'Warning' { Write-PSFMessage -Level Warning -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
        'Error' { Write-PSFMessage -Level Error -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
        'Verbose' { Write-PSFMessage -Level Verbose -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
        'Debug' { Write-PSFMessage -Level Debug -Message $formattedMessage -FunctionName $FunctionName -Line $LineNumber -Tag $Module }
    }
}

# Convenience functions for different modules
function Write-LogMain {
    param([string]$Message, [string]$Level = 'Verbose')
    Write-Log -Message $Message -Level $Level -Module 'Main'
}

function Write-LogFetch {
    [CmdletBinding()]
    param([string]$Message, [string]$Level = 'Verbose')
    $msg = if ($Message -match '^\[Fetch\]') { $Message } else { "[Fetch] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Fetch'
}

function Write-LogLLM {
    param([string]$Message, [string]$Level = 'Verbose')
    $msg = if ($Message -match '^\[LLM\]') { $Message } else { "[LLM] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'LLM'
}



function Write-LogScore {
    param([string]$Message, [string]$Level = 'Host')
    Write-Log -Message $Message -Level $Level -Module 'Score'
}

function Write-LogScrape {
    param([string]$Message, [string]$Level = 'Host')
    Write-Log -Message $Message -Level $Level -Module 'Scrape'
}

function Write-LogSearch {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[Search\]') { $Message } else { "[Search] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Search'
}

function Write-LogNotify {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[Notify\]') { $Message } else { "[Notify] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Notify'
}

function Write-LogPipeline {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[Pipeline\]') { $Message } else { "[Pipeline] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Pipeline'
}

function Write-LogCache {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[Cache\]') { $Message } else { "[Cache] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Cache'
}

function Write-LogHttp {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[Http\]') { $Message } else { "[Http] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Http'
}

function Write-LogSkills {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[Skills\]') { $Message } else { "[Skills] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'Skills'
}

function Write-LogCV {
    param([string]$Message, [string]$Level = 'Host')
    $msg = if ($Message -match '^\[CV\]') { $Message } else { "[CV] $Message" }
    Write-Log -Message $msg -Level $Level -Module 'CV'
}

# Error logging with exception details
function Write-LogError {
    param(
        [string]$Message,
        [System.Exception]$Exception,
        [string]$Module = 'Main'
    )
    
    $errorMessage = if ($Exception) {
        "$Message - Exception: $($Exception.Message) - StackTrace: $($Exception.StackTrace)"
    }
    else {
        $Message
    }
    
    Write-Log -Message $errorMessage -Level Error -Module $Module
}

# Performance timing functions
function Start-Timing {
    param([string]$OperationName)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    return @{
        Stopwatch = $stopwatch
        Operation = $OperationName
        StartTime = Get-Date
    }
}

function Stop-Timing {
    param(
        [hashtable]$Timer,
        [string]$Module = 'Main'
    )
    
    if ($Timer -and $Timer.Stopwatch) {
        $Timer.Stopwatch.Stop()
        $elapsedMs = $Timer.Stopwatch.ElapsedMilliseconds
        Write-Log -Message "$($Timer.Operation) completed in $elapsedMs ms" -Level Verbose -Module $Module
        return $elapsedMs
    }
    return 0
}

# Memory usage logging
function Write-LogMemory {
    param([string]$Module = 'Main')
    
    $process = Get-Process -Id $PID
    $memoryMB = [math]::Round($process.WorkingSet64 / 1MB, 2)
    Write-Log -Message "Memory usage: $memoryMB MB" -Level Verbose -Module $Module
}

# Cache statistics logging
function Write-LogCacheStats {
    param(
        [hashtable]$Stats,
        [string]$Module = 'Main'
    )
    
    if ($Stats) {
        $statsString = ($Stats.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        Write-Log -Message "Cache stats: {$statsString}" -Level Verbose -Module $Module
    }
}

# LEGACY: temporary logging function for compatibility; prefer Write-Log* APIs
# Temporary logging function for compatibility
function Log-Step([string]$msg) {
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) {
        Write-LogMain -Message $msg -Level Verbose
    }
    else {
        Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $msg"
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-Logging',
    'Get-LoggingInitialized',
    'Write-Log',
    'Write-LogMain',
    'Write-LogFetch',
    'Write-LogSearch',
    'Write-LogLLM',
    'Write-LogNotify',
    'Write-LogPipeline',
    
    'Write-LogScore',
    'Write-LogScrape',
    'Write-LogCache',
    'Write-LogHttp',
    'Write-LogSkills',
    'Write-LogCV',
    'Write-LogError',
    'Start-Timing',
    'Stop-Timing',
    'Write-LogMemory',
    'Write-LogCacheStats',
    'Log-Step'
)
