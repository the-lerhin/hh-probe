# Git filter driver for config/hh.config.jsonc
# Replaces secret values with empty strings on commit (clean) and restores them on checkout (smudge).
# Usage: pwsh -File scripts/filter-config.ps1 -Clean   (reads stdin, writes cleaned content to stdout)
#        pwsh -File scripts/filter-config.ps1 -Smudge (reads stdin, writes smudged content to stdout)

param(
    [switch]$Clean,
    [switch]$Smudge
)

if (-not ($Clean -xor $Smudge)) {
    Write-Error "Exactly one of -Clean or -Smudge must be specified."
    exit 1
}

# Read input content
$content = [System.Console]::In.ReadToEnd()

if ($Clean) {
    # Replace secret values with empty strings during commit
    $patterns = @(
        '"hh_token"\s*:\s*"[^"]*"',
        '"hh_xsrf"\s*:\s*"[^"]*"',
        '"llm_api_key"\s*:\s*"[^"]*"',
        '"hydra_api_key"\s*:\s*"[^"]*"',
        '"telegram_bot_token"\s*:\s*"[^"]*"',
        '"telegram_chat_id"\s*:\s*"[^"]*"',
        '"hh_client_id"\s*:\s*"[^"]*"',
        '"hh_client_secret"\s*:\s*"[^"]*"',
        '"hh_redirect_uri"\s*:\s*"[^"]*"',
        '"cookie_hhtoken"\s*:\s*"[^"]*"',
        '"_xsrf"\s*:\s*"[^"]*"',
        '"bot_token"\s*:\s*"[^"]*"',
        '"chat_id"\s*:\s*"[^"]*"'
    )
    
    foreach ($pattern in $patterns) {
        $content = $content -replace $pattern, ($pattern -replace '"[^"]*"$', '""')
    }
    
    Write-Output $content
} 
elseif ($Smudge) {
    # Restore secret values from local secrets file during checkout
    $secretsPath = Join-Path $PSScriptRoot '..' 'config' 'hh.config.secrets.json'
    $secretsPath = [System.IO.Path]::GetFullPath($secretsPath)
    $secrets = @{}
    
    if (Test-Path $secretsPath) {
        try {
            $secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json -AsHashtable
        } 
        catch {
            Write-Error "Failed to parse secrets file: $_"
        }
    }
    
    # Helper to get secret value from nested hashtable
    function Get-SecretValue {
        param([string]$key)
        
        # Direct match
        if ($secrets.ContainsKey($key)) { return $secrets[$key] }
        
        # Check under 'keys' hashtable
        if ($secrets.ContainsKey('keys') -and $secrets.keys.ContainsKey($key)) { 
            return $secrets.keys[$key] 
        }
        
        # Check under 'telegram' hashtable
        if ($secrets.ContainsKey('telegram') -and $secrets.telegram.ContainsKey($key)) { 
            return $secrets.telegram[$key] 
        }
        
        # Check under 'search.recommendations.web_scraping' hashtable
        if ($secrets.ContainsKey('search') -and $secrets.search.ContainsKey('recommendations') -and 
            $secrets.search.recommendations.ContainsKey('web_scraping') -and 
            $secrets.search.recommendations.web_scraping.ContainsKey($key)) {
            return $secrets.search.recommendations.web_scraping[$key]
        }
        
        return $null
    }
    
    # Keys to restore
    $keys = @(
        'hh_token',
        'hh_xsrf', 
        'llm_api_key',
        'hydra_api_key',
        'telegram_bot_token',
        'telegram_chat_id',
        'hh_client_id',
        'hh_client_secret',
        'hh_redirect_uri',
        'cookie_hhtoken',
        '_xsrf',
        'bot_token',
        'chat_id'
    )
    
    foreach ($key in $keys) {
        $value = Get-SecretValue -key $key
        if ($value) {
            $content = $content -replace "`"$key`"\s*:\s*`"[^`"]*`"", "`"$key`": `"$value`""
        }
    }
    
    Write-Output $content
}
