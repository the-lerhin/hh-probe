# hh.cache.psm1 — Optional LiteDB-backed cache adapter with JSON fallback
# Load config module if available so tests can Mock Get-HHConfigValue

if (-not (Get-Command -Name Get-HHConfigValue -ErrorAction SilentlyContinue)) {
  function Get-HHConfigValue { param([string[]]$Path, $Default = $null) return $Default }
  Export-ModuleMember -Function Get-HHConfigValue
}

#Requires -Version 7.5

<#
  Initialize-LiteDbCache
  Brief: Attempts to initialize LiteDB-backed cache and store a module-scoped handle.
  - Loads LiteDB from modules/lib/LiteDB.dll if present, else tries GAC.
  - Creates/opens `data/cache/hhCache.db` under repo root.
  - Returns $true on success, $false otherwise. Safe to call multiple times.
#>
function Initialize-LiteDbCache {
  [CmdletBinding()] param()
  try {
    if ($script:LiteDbInited) { return $true }
    $repo = Split-Path -Parent $PSScriptRoot
    $dllPath = Join-Path $repo 'bin' | Join-Path -ChildPath 'LiteDB.dll'
    $loaded = $false
    
    if (Test-Path -LiteralPath $dllPath) {
      try { [Reflection.Assembly]::LoadFrom($dllPath) | Out-Null; $loaded = $true } catch {}
    }
    
    if (-not $loaded) {
      try { [Type]::GetType('LiteDB.LiteDatabase, LiteDB') | Out-Null; $loaded = $true } catch {}
    }
    if (-not $loaded) { return $false }

    $cacheDir = if ($script:HHCacheRoot) { $script:HHCacheRoot } else { Join-Path (Join-Path $repo 'data') 'cache' }
    try { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null } catch {}
    $dbPath = Join-Path $cacheDir 'hhCache.db'

    $script:LiteDb = New-Object LiteDB.LiteDatabase("Filename=$dbPath;Connection=shared")
    $script:LiteDbInited = $true
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message ("[Cache] LiteDB backend initialized at {0}" -f $dbPath) -Level Verbose }
    return $true
  }
  catch { if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message ("[Cache] LiteDB init failed: {0}" -f $_.Exception.Message) -Level Warning }; return $false }
}

<#
  Get-LiteDbReady
  Brief: Returns $true when LiteDB is initialized and usable.
#>
function Get-LiteDbReady { return [bool]$script:LiteDbInited }

<#
  Read-CacheText
  Brief: Reads a text value from LiteDB collection by Id. Returns $null if not available.
  - Parameters: Collection (e.g., 'LuckyWhy'), Id (vacancy id)
  - Uses a simple document schema: { _id: string, text: string, updated_utc: DateTime }
#>
function Read-CacheText {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Id
  )
  try {
    if (-not (Get-LiteDbReady)) { return $null }
    $col = $script:LiteDb.GetCollection($Collection)
    $doc = $col.FindById([LiteDB.BsonValue]::new($Id))
    if (-not $doc) { return $null }
    $node = $doc['text']
    if ($node -and $node.IsString) { return $node.AsString }
    return $null
  }
  catch { return $null }
}

<#
  Write-CacheText
  Brief: Writes a text value into LiteDB collection by Id. Returns $true on success.
#>
function Write-CacheText {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Text
  )
  try {
    if (-not (Get-LiteDbReady)) { if (-not (Initialize-LiteDbCache)) { return $false } }
    $col = $script:LiteDb.GetCollection($Collection)
    $ts = (Get-Date).ToUniversalTime()
    $bdoc = New-Object LiteDB.BsonDocument
    $bdoc['_id'] = [LiteDB.BsonValue]::new($Id)
    $bdoc['text'] = [LiteDB.BsonValue]::new($Text)
    $bdoc['updated_utc'] = [LiteDB.BsonValue]::new($ts)
    $null = $col.Upsert($bdoc)
    return $true
  }
  catch { return $false }
}

<#
  Close-LiteDbCache
  Brief: Disposes the LiteDB connection if initialized.
#>
function Close-LiteDbCache {
  [CmdletBinding()] param()
  try { if ($script:LiteDb) { $script:LiteDb.Dispose(); $script:LiteDb = $null; $script:LiteDbInited = $false } } catch {}
}

<#
  Initialize-HHCache
  Brief: Initializes the unified cache backend (LiteDB or File) and sets root.
  - Honors config `cache.provider` when available; defaults to File.
  - If LiteDB is selected and assembly is available, uses LiteDB backend.
#>
function Initialize-HHCache {
  [CmdletBinding()] param(
    [string]$Root = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/cache')
  )
  try { New-Item -ItemType Directory -Force -Path $Root | Out-Null } catch {}
  $script:HHCacheRoot = $Root
  
  $provider = Get-HHCacheProvider
  $script:HHCacheConfigured = $provider
  $script:HHCacheBackend = $provider

  if ($provider -eq 'litedb') {
    if (Initialize-LiteDbCache) { 
      return $true 
    }
    # Strict mode: no fallback
    throw "LiteDB cache initialization failed and fallback is disabled (cache.provider=litedb)."
  }
  
  # File backend
  if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message ("[Cache] File cache backend at {0}" -f $Root) -Level Verbose }
  return $true
}

<#
  Get-HHCacheBackend
  Brief: Returns current cache backend: 'LiteDB' or 'File'.
#>
function Get-HHCacheBackend { if ($script:HHCacheConfigured) { return $script:HHCacheConfigured } elseif ($script:HHCacheBackend) { return $script:HHCacheBackend } else { return 'File' } }

<#
  Close-HHCache
  Brief: Disposes cache resources.
#>
function Close-HHCache { try { Close-LiteDbCache } catch {} }

<#
  Get-HHCacheFilePath
  Brief: Returns path for file-backed cache item.
#>
function Get-HHCacheFilePath {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Key
  )
  $base = $script:HHCacheRoot
  if (-not $base -or [string]::IsNullOrWhiteSpace($base)) {
    $repo = Split-Path -Parent $PSScriptRoot
    $base = Join-Path (Join-Path $repo 'data') 'cache'
  }
  $dir = Join-Path $base $Collection
  try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {}
  return (Join-Path $dir ("$Key.json"))
}

<#
  Set-HHCacheItem
  Brief: Writes/deletes a cache item. Accepts optional metadata.
#>
function Set-HHCacheItem {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Key,
    $Value,
    [hashtable]$Metadata
  )
  $backend = Get-HHCacheBackend
  if ($backend -eq 'LiteDB' -and (Get-LiteDbReady)) {
    try {
      if ($null -eq $Value) { 
        Write-LogCache -Message ("delete kind={0} key={1}" -f $Collection, $Key) -Level Verbose
        $col = $script:LiteDb.GetCollection($Collection); $null = $col.Delete([LiteDB.BsonValue]::new($Key)); return 
      }
      $col = $script:LiteDb.GetCollection($Collection)
      $ts = (Get-Date).ToUniversalTime()
      $valJson = ($Value | ConvertTo-Json -Depth 6)
      $metaJson = ($Metadata | ConvertTo-Json -Depth 6)
      $bdoc = New-Object LiteDB.BsonDocument
      $bdoc['_id'] = [LiteDB.BsonValue]::new($Key)
      if ($null -ne $valJson) { $bdoc['value_json'] = [LiteDB.BsonValue]::new($valJson) }
      if ($null -ne $metaJson) { $bdoc['meta_json'] = [LiteDB.BsonValue]::new($metaJson) }
      $bdoc['updated_utc'] = [LiteDB.BsonValue]::new($ts)
      $null = $col.Upsert($bdoc)
      $ttlValue = $null
      try {
        if ($Metadata -is [System.Collections.IDictionary]) { $ttlValue = $Metadata['ttl_days'] }
        elseif ($Metadata) { $ttlValue = $Metadata.ttl_days }
      }
      catch {}
      Write-LogCache -Message ("set kind={0} key={1} created={2:yyyy-MM-ddTHH:mm:ssZ} ttl={3}" -f $Collection, $Key, $ts, ($ttlValue ?? 'none')) -Level Verbose
      return
    }
    catch { return }
  }
  # File backend
  $path = Get-HHCacheFilePath -Collection $Collection -Key $Key
  try {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  }
  catch {}
  if ($null -eq $Value) { try { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } catch {}; return }
  $envelope = @{ Value = $Value; Metadata = $Metadata; UpdatedUtc = (Get-Date).ToUniversalTime() }
  try { $envelope | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding utf8 } catch {}
}

<#
  Get-HHCacheItem
  Brief: Reads a cache item. With -AsEnvelope returns {Value, Metadata, UpdatedUtc}.
#>
function Get-HHCacheItem {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Key,
    [switch]$AsEnvelope
  )
  $backend = Get-HHCacheBackend
  if ($backend -eq 'LiteDB' -and (Get-LiteDbReady)) {
    try {
      $col = $script:LiteDb.GetCollection($Collection)
      $doc = $col.FindById([LiteDB.BsonValue]::new($Key))
      if (-not $doc) { 
        Write-LogCache -Message ("get miss kind={0} key={1} reason=not_found" -f $Collection, $Key) -Level Verbose
        try { 
          if ($global:CacheStats) { 
            $global:CacheStats["${Collection}_miss"] = [int]($global:CacheStats["${Collection}_miss"] ?? 0) + 1
            $global:CacheStats['litedb_misses'] = [int]($global:CacheStats['litedb_misses'] ?? 0) + 1
          } 
        } catch {}
        return $null 
      }
      $valNode = $doc['value_json']
      $metaNode = $doc['meta_json']
      $updatedNode = $doc['updated_utc']
      $val = $null
      if ($valNode -and $valNode.IsString) { $val = $valNode.AsString | ConvertFrom-Json }
      $meta = $null
      if ($metaNode -and $metaNode.IsString) { $meta = $metaNode.AsString | ConvertFrom-Json }
      $updated = $null
      if ($updatedNode -and $updatedNode.IsDateTime) { $updated = $updatedNode.AsDateTime }
      if ($updated) {
        try {
          if ($updated.Kind -eq [System.DateTimeKind]::Utc) { $updated = $updated }
          else { $updated = $updated.ToUniversalTime() }
        }
        catch {}
      }
      
      # Check TTL if present (including TTL=0 as immediate expiry)
      $hasTtl = $false
      try { if ($meta -is [System.Collections.IDictionary]) { $hasTtl = $meta.ContainsKey('ttl_days') } else { $hasTtl = ($meta.PSObject.Properties['ttl_days'] -ne $null) } } catch {}
      if ($meta -and $hasTtl -and $updated) {
        $ttlDays = [double]$meta.ttl_days
        $created = [datetime]$updated
        $now = (Get-Date).ToUniversalTime()
        if ($created.AddDays($ttlDays) -le $now) {
          Write-LogCache -Message ("get miss kind={0} key={1} reason=expired created={2:yyyy-MM-ddTHH:mm:ssZ} now={3:yyyy-MM-ddTHH:mm:ssZ} ttl={4}" -f $Collection, $Key, $created, $now, $ttlDays) -Level Verbose
          try { if ($global:CacheStats) { $global:CacheStats["${Collection}_expired"] = [int]($global:CacheStats["${Collection}_expired"] ?? 0) + 1 } } catch {}
          return $null
        }
      }
      
      Write-LogCache -Message ("get hit kind={0} key={1} updated={2:yyyy-MM-ddTHH:mm:ssZ}" -f $Collection, $Key, $updated) -Level Verbose
      try { 
        if ($global:CacheStats) { 
          $global:CacheStats["${Collection}_hit"] = [int]($global:CacheStats["${Collection}_hit"] ?? 0) + 1
          $global:CacheStats['litedb_hits'] = [int]($global:CacheStats['litedb_hits'] ?? 0) + 1
        } 
      } catch {}
      if ($AsEnvelope) { return @{ Value = $val; Metadata = $meta; UpdatedUtc = $updated } }
      return $val
    }
    catch { return $null }
  }
  # File backend
  $path = Get-HHCacheFilePath -Collection $Collection -Key $Key
  if (-not (Test-Path -LiteralPath $path)) { 
    try { if ($global:CacheStats) { $global:CacheStats['file_misses'] = [int]($global:CacheStats['file_misses'] ?? 0) + 1 } } catch {}
    return $null 
  }
  try {
    $env = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $hasTtl = $false
    try { if ($env.Metadata -is [System.Collections.IDictionary]) { $hasTtl = $env.Metadata.ContainsKey('ttl_days') } else { $hasTtl = ($env.Metadata.PSObject.Properties['ttl_days'] -ne $null) } } catch {}
    if ($env.Metadata -and $hasTtl) {
      $ttlDays = [double]$env.Metadata.ttl_days
      $created = [datetime]$env.UpdatedUtc
      $now = (Get-Date).ToUniversalTime()
      if ($created.AddDays($ttlDays) -le $now) { return $null }
    }
    try { if ($global:CacheStats) { $global:CacheStats['file_hits'] = [int]($global:CacheStats['file_hits'] ?? 0) + 1 } } catch {}
    if ($AsEnvelope) { return $env } else { return $env.Value }
  }
  catch { return $null }
}

<#
  Remove-HHCacheOlderThanDays
  Brief: Removes items older than given days (best-effort per backend).
#>
function Remove-HHCacheOlderThanDays {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][int]$Days
  )
  $backend = Get-HHCacheBackend
  $deleted = 0
  if ($Days -le 0) { return @{ backend = $backend; deleted = 0 } }
  if ($backend -eq 'LiteDB') {
    try {
      $col = $script:LiteDb.GetCollection($Collection)
      $cut = (Get-Date).ToUniversalTime().AddDays( - [double]$Days)
      foreach ($doc in $col.FindAll()) {
        $tsNode = $doc['updated_utc']
        $idNode = $doc['_id']
        $ts = $null
        if ($tsNode -and $tsNode.IsDateTime) { $ts = $tsNode.AsDateTime }
        if ($ts -and ($ts -lt $cut)) { if ($idNode) { if ($col.Delete($idNode)) { $deleted++ } } }
      }
      return @{ backend = 'LiteDB'; deleted = $deleted }
    }
    catch { return @{ backend = 'LiteDB'; deleted = 0 } }
  }
  # File backend
  $dir = Join-Path $script:HHCacheRoot $Collection
  if (-not (Test-Path -LiteralPath $dir)) { return @{ backend = 'File'; deleted = 0 } }
  $cut = (Get-Date).AddDays( - [double]$Days)
  Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.LastWriteTime -lt $cut) { try { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue; $deleted++ } catch {} }
  }
  return @{ backend = 'File'; deleted = $deleted }
}


# Internal helper to remove cache item (LiteDB or File)
function Remove-HHCacheItem {
  [CmdletBinding()] param(
    [Parameter(Mandatory = $true)][string]$Collection,
    [Parameter(Mandatory = $true)][string]$Key
  )
  $provider = Get-HHCacheProvider
  if ($provider -eq 'litedb') {
    if (-not (Get-LiteDbReady)) { Initialize-LiteDbCache | Out-Null }
    if (Get-LiteDbReady) {
      try { $col = $script:LiteDb.GetCollection($Collection); $null = $col.Delete([LiteDB.BsonValue]::new($Key)); return $true } catch { return $false }
    }
  }
  $path = Get-HHCacheFilePath -Collection $Collection -Key $Key
  try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } return $true } catch { return $false }
}

function Get-HHCacheProvider {
  if ($script:CacheProvider) { return $script:CacheProvider }
  $prov = [string](Get-HHConfigValue -Path @('cache', 'provider') -Default 'litedb')
  if ([string]::IsNullOrWhiteSpace($prov)) { $prov = 'litedb' }
  $prov = $prov.ToLowerInvariant()
  if ($prov -notin @('litedb', 'file')) {
    if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message ("[Cache] Unknown cache provider '{0}', falling back to 'litedb'" -f $prov) -Level Warning }
    $prov = 'litedb'
  }
  $script:CacheProvider = $prov
  return $prov
}

function Get-HHCacheCollections {
  $provider = Get-HHCacheProvider
  if ($provider -eq 'litedb' -and (Get-LiteDbReady)) {
    return $script:LiteDb.GetCollectionNames()
  }
  if (Test-Path $script:HHCacheRoot) {
    return (Get-ChildItem $script:HHCacheRoot -Directory).Name
  }
  return @()
}

function Get-HHCacheStats {
  [CmdletBinding()]
  param()
  $provider = Get-HHCacheProvider
  return [PSCustomObject]@{
    provider    = $provider
    path        = $script:HHCacheRoot
    litedb_path = if ($provider -eq 'litedb' -and $script:LiteDb) { $script:LiteDb.ConnectionString.Filename } else { $null }
    collections = @(Get-HHCacheCollections) 
  }
}

function Clear-HHCache {
  [CmdletBinding()]
  param(
    [string]$Collection,
    [switch]$Force
  )
  $provider = Get-HHCacheProvider
  if (-not $Force -and -not $env:HH_TEST) {
    throw "Refusing to clear cache without -Force (or HH_TEST=1)"
  }

  if ($provider -eq 'litedb') {
    if (-not (Get-LiteDbReady)) { Initialize-LiteDbCache | Out-Null }
    if (Get-LiteDbReady) {
      if ([string]::IsNullOrWhiteSpace($Collection)) {
        $cols = $script:LiteDb.GetCollectionNames()
        foreach ($c in $cols) { $script:LiteDb.DropCollection($c) | Out-Null }
        if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message "[Cache] Cleared ALL collections in LiteDB" -Level Verbose }
      }
      else {
        $script:LiteDb.DropCollection($Collection) | Out-Null
        if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message ("[Cache] Cleared collection='{0}' in LiteDB" -f $Collection) -Level Verbose }
      }
    }
  }
  else {
    # File
    if ([string]::IsNullOrWhiteSpace($Collection)) {
      Get-ChildItem $script:HHCacheRoot -Directory | Remove-Item -Recurse -Force
      if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message "[Cache] Cleared ALL collections in File backend" -Level Verbose }
    }
    else {
      $path = Join-Path $script:HHCacheRoot $Collection
      if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        if (Get-Command -Name Write-LogMain -ErrorAction SilentlyContinue) { Write-LogMain -Message ("[Cache] Cleared collection='{0}' in File backend" -f $Collection) -Level Verbose }
      }
    }
  }
}


function Run-GarbageCollection {
  param([switch]$Force)
    
  $gcEnabled = [bool](Get-HHConfigValue -Path @('cache', 'gc_enabled') -Default $false)
  if (-not $gcEnabled -and -not $Force) { return }
    
  if (Get-Command -Name 'Log-Step' -ErrorAction SilentlyContinue) { Log-Step "[GC] begin" }
    
  $vacDays = [int](Get-HHConfigValue -Path @('cache', 'ttl_days', 'vacancies') -Default 7)
  try {
    $r = Remove-HHCacheOlderThanDays -Collection 'vacancies' -Days $vacDays
    if (Get-Command -Name 'Log-Step' -ErrorAction SilentlyContinue) { Log-Step ("[GC] vacancies ({0}) deleted={1} ttl={2}d" -f $r.backend, $r.deleted, $vacDays) }
  }
  catch {}

  $llmDays = [int](Get-HHConfigValue -Path @('cache', 'ttl_days', 'llm') -Default 14)
  try {
    $r = Remove-HHCacheOlderThanDays -Collection 'llm' -Days $llmDays
    if (Get-Command -Name 'Log-Step' -ErrorAction SilentlyContinue) { Log-Step ("[GC] llm ({0}) deleted={1} ttl={2}d" -f $r.backend, $r.deleted, $llmDays) }
  }
  catch {}

  $skillsDays = [int](Get-HHConfigValue -Path @('cache', 'ttl_days', 'skills') -Default 30)
  try {
    $r = Remove-HHCacheOlderThanDays -Collection 'skills' -Days $skillsDays
    if (Get-Command -Name 'Log-Step' -ErrorAction SilentlyContinue) { Log-Step ("[GC] skills ({0}) deleted={1} ttl={2}d" -f $r.backend, $r.deleted, $skillsDays) }
  }
  catch {}

  $empDays = [int](Get-HHConfigValue -Path @('cache', 'ttl_days', 'employers') -Default 30)
  try {
    $r = Remove-HHCacheOlderThanDays -Collection 'employers' -Days $empDays
    if (Get-Command -Name 'Log-Step' -ErrorAction SilentlyContinue) { Log-Step ("[GC] employers ({0}) deleted={1} ttl={2}d" -f $r.backend, $r.deleted, $empDays) }
  }
  catch {}
    
  if (Get-Command -Name 'Log-Step' -ErrorAction SilentlyContinue) { Log-Step "[GC] done" }
}

Export-ModuleMember -Function Initialize-LiteDbCache, Get-LiteDbReady, Read-CacheText, Write-CacheText, Close-LiteDbCache, Initialize-HHCache, Get-HHCacheBackend, Close-HHCache, Get-HHCacheFilePath, Set-HHCacheItem, Get-HHCacheItem, Remove-HHCacheOlderThanDays, Remove-HHCacheItem, Get-HHCacheProvider, Get-HHCacheStats, Clear-HHCache, Run-GarbageCollection
