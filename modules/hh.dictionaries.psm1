param()

$script:HH_DictCache = @{}

function Fetch-HHDictionary {
  param([Parameter(Mandatory=$true)][string]$Name)
  $data = @()
  try {
    # Placeholder: rely on tests to Mock this function; otherwise return empty
    $data = @()
  } catch {}
  return $data
}

function Get-HHDictionary {
  param([Parameter(Mandatory=$true)][string]$Name)
  if ($script:HH_DictCache.ContainsKey($Name)) { return $script:HH_DictCache[$Name] }
  $d = Fetch-HHDictionary -Name $Name
  $script:HH_DictCache[$Name] = $d
  return $d
}

function Get-HHAllDictionaries {
  param()
  $names = @('areas','industries','professional_roles','employment','schedule','experience')
  $result = @{}
  foreach ($n in $names) { $result[$n] = Get-HHDictionary -Name $n }
  return $result
}

function Resolve-HHAreaIdByName {
  param([Parameter(Mandatory=$true)][string]$Name)
  $areas = Get-HHDictionary -Name 'areas'
  foreach ($a in @($areas)) {
    try {
      $n = ''
      if ($a -is [System.Collections.IDictionary]) { $n = [string]$a['name']; $id = [string]$a['id'] }
      else { $n = [string]$a.name; $id = [string]$a.id }
      if ([string]::Equals($n, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $id }
    } catch {}
  }
  return ''
}

function Resolve-HHRoleIdByName {
  param([Parameter(Mandatory=$true)][string]$Name)
  $roles = Get-HHDictionary -Name 'professional_roles'
  foreach ($r in @($roles)) {
    try {
      $n = ''
      if ($r -is [System.Collections.IDictionary]) { $n = [string]$r['name']; $id = [string]$r['id'] }
      else { $n = [string]$r.name; $id = [string]$r.id }
      if ([string]::Equals($n, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $id }
    } catch {}
  }
  return ''
}

function Clear-HHDictionaryCache {
  param()
  try { $script:HH_DictCache.Clear() } catch { $script:HH_DictCache = @{} }
}

Export-ModuleMember -Function Get-HHDictionary, Get-HHAllDictionaries, Resolve-HHAreaIdByName, Resolve-HHRoleIdByName, Clear-HHDictionaryCache
