<#
.SYNOPSIS
    Re-homes NinjaOne MANAGED endpoints to the correct Organization + Location based on the
    device's IP address, using a subnet (CIDR) mapping table.

.DESCRIPTION
    Reads a site map (subnet -> Org/Location), pulls every managed device from the NinjaOne API,
    works out which site each device is sitting in from its IP, and PATCHes any device that has
    drifted into the wrong Org/Location.

    Runs in DRY-RUN by default. Nothing moves until you pass -Execute (or tick the Execute
    script variable).

    Two ways to run it:
      1. Scheduled task on an automation server  -> pass parameters on the command line.
      2. NinjaOne automation (script)            -> configure Script Variables in the NinjaOne
                                                    script editor; no command line needed.
    Command-line parameters always win over Script Variables.

    This is an external API client. Only read + PATCH /device/{id} are used.

    Verified mechanic (2026-07-14, ca.ninjarmm.com): PATCH /device/{id} with
    {organizationId, locationId} moves a managed agent between orgs. nodeRoleId / policyId are
    left untouched, so the device inherits the destination org's role-policy mapping.

.MATCHING
    -MatchOn LocalIP   (default) Device's own IPv4 from the bulk device record. FREE - no extra
                       API calls. This is what you want when each site owns distinct internal
                       subnets (the usual case, and what mirrors Entra dynamic-group rules).
    -MatchOn Gateway   Device's active default gateway. Costs ONE extra API call per device.
                       Use only when sites share internal subnet ranges but differ by gateway.
    -MatchOn PublicIP  Device's public egress IP. FREE. Only works if each site egresses on a
                       distinct public IP.
    -MatchOn Auto      Try LocalIP; if no rule matches, fall back to PublicIP. FREE.

.SITE MAP
    CSV with columns: Subnet,OrgID,LocationID,Org,Location
      Subnet     - what to match. Accepts any of:
                     10.10.1.0/24              CIDR
                     10.10.1.50                single IP (= /32)
                     10.10.1.*                 wildcard  (= /24)
                     10.10.*.*                 wildcard  (= /16)
                     10.10.1.20-10.10.1.40     explicit range
                     10.10.1.20-40             short range (last octet)
                     0.0.0.0/0                 catch-all fallback row
      OrgID      - destination NinjaOne organization ID
      LocationID - destination location ID (must belong to OrgID)
      Org        - friendly label, reporting only
      Location   - friendly label, reporting only

    MOST SPECIFIC RULE WINS. A /32 beats a /24 beats a /16 beats the 0.0.0.0/0 catch-all, so you
    can carve exceptions out of a site range without reordering the file.

.CREDENTIALS
    Resolved in this order, first hit wins:
      1. -NinjaUrl / -ClientId / -ClientSecret on the command line
      2. ninjaUrl / clientId / clientSecret Script Variables
      3. NinjaOne CUSTOM FIELDS (only when running as a NinjaOne automation):
             ninjaoneInstance       Text      e.g. ca.ninjarmm.com
             ninjaoneClientId       Secure
             ninjaoneClientSecret   Secure
         "Secure" is the field type in the console dropdown - it is a distinct type,
         not Text (TEXT_ENCRYPTED if you create it through the API instead).
         Read with Ninja-Property-Get. Set both secret fields to Script permission
         Read/Write and API permission None, so a script on an agent can read them
         but the public API cannot read them back out. This is the recommended way to
         share the credentials - nothing sensitive lives in the script or the task
         command line.
         Override the field names with -CfClientId / -CfClientSecret / -CfInstance.
      4. NINJA_URL / NINJA_CLIENT_ID / NINJA_CLIENT_SECRET environment variables
         (the route for a plain scheduled task, where Ninja-Property-Get does not exist)

.NINJAONE SCRIPT VARIABLES
    Add these in the NinjaOne script editor (Script Variables tab). All optional. Names are
    matched case-insensitively.

      Name              Type        Notes
      ----------------  ----------  ----------------------------------------------------------
      clientId          String      API client ID
      clientSecret      String      API client secret
      ninjaUrl          Dropdown    https://ca.ninjarmm.com etc. Default https://app.ninjarmm.com
      matchOn           Dropdown    LocalIP | Gateway | PublicIP | Auto
      mapUrl            String      HTTPS URL to the site-map CSV (easiest for Ninja runs)
      mapPath           String      Local path to the site-map CSV
      mapInline         String      CSV on one line, rows separated by a literal \n (no multi-line type exists)
      orgId             Integer     Restrict to one source org
      excludeTags       String      Comma-separated tags to never move (e.g. Pinned,Roaming)
      excludeNames      String      Comma-separated device-name wildcards to never move
      skipOffline       Checkbox    Ignore offline devices (their IP may be stale)
      staleDays         Integer     Ignore devices not seen in N days. 0 = off
      maxMoves          Integer     Safety cap on moves per run. Default 250. 0 = unlimited
      execute           Checkbox    UNTICKED = dry run. Tick to actually move devices.

.PARAMETER Execute
    Actually perform the moves. Omit for a dry run (plan only, nothing changes).

.PARAMETER SelfTest
    Run the built-in subnet-matching assertions and exit. No API calls, no credentials needed.

.EXAMPLE
    # Prove the matching logic works, offline, before you trust it with anything
    .\Move-NinjaDevices.ps1 -SelfTest

.EXAMPLE
    # Dry run against one org
    .\Move-NinjaDevices.ps1 -MapPath .\ninja-location-map.csv -OrgId 101

.EXAMPLE
    # Live run, whole fleet, pinning anything tagged Roaming
    .\Move-NinjaDevices.ps1 -MapPath .\ninja-location-map.csv -ExcludeTags Roaming -Execute

.NOTES
    Exit codes: 0 = clean, 1 = fatal (config/auth/map), 2 = completed with failures.
#>

[CmdletBinding()]
param(
    [string]$Dir = $PSScriptRoot,

    # --- site map (pick one) ---
    [string]$MapPath,
    [string]$MapUrl,
    [string]$MapInline,

    # --- matching ---
    [ValidateSet('LocalIP', 'Gateway', 'PublicIP', 'Auto')]
    [string]$MatchOn = 'LocalIP',

    # --- scoping / safety ---
    [int]$OrgId,
    [string[]]$ExcludeTags,
    [string[]]$ExcludeNames,
    [switch]$SkipOffline,
    [int]$StaleDays = 0,
    [int]$MaxMoves = 250,
    [switch]$SkipMapValidation,

    # --- connection ---
    [string]$NinjaUrl,
    [string]$ClientId,
    [string]$ClientSecret,

    # --- custom fields holding the credentials (NinjaOne automation runs) ---
    [string]$CfClientId = 'ninjaoneClientId',
    [string]$CfClientSecret = 'ninjaoneClientSecret',
    [string]$CfInstance = 'ninjaoneInstance',

    # --- behaviour ---
    [switch]$Execute,
    [switch]$SelfTest,
    [switch]$Discover,
    [ValidateRange(8, 32)]
    [int]$DiscoverPrefix = 24
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
# SCRIPT VARIABLE OVERLAY
# NinjaOne exposes Script Variables to the script as environment variables.
# Command-line parameters win; Script Variables fill in the rest.
# ===========================================================================
function Get-ScriptVar {
    param([string]$Name)
    $hit = Get-ChildItem Env: | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($hit -and -not [string]::IsNullOrWhiteSpace($hit.Value)) { return $hit.Value.Trim() }
    return $null
}

function Get-ScriptBool {
    param([string]$Name)
    $v = Get-ScriptVar $Name
    if ($null -eq $v) { return $null }
    return ($v -in @('true', '1', 'yes', 'y', 'on', 'checked'))
}

function Get-ScriptList {
    param([string]$Name)
    $v = Get-ScriptVar $Name
    if ($null -eq $v) { return $null }
    return @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$BoundParams = $PSBoundParameters

# Apply Script Variables to any parameter the caller did not pass explicitly.
function Apply-ScriptVars {
    # String settings
    foreach ($pair in @(
            @('MapPath', 'mapPath'), @('MapUrl', 'mapUrl'), @('MapInline', 'mapInline'),
            @('MatchOn', 'matchOn'), @('NinjaUrl', 'ninjaUrl'),
            @('ClientId', 'clientId'), @('ClientSecret', 'clientSecret')
        )) {
        if ($BoundParams.ContainsKey($pair[0])) { continue }
        $v = Get-ScriptVar $pair[1]
        if ($v) { Set-Variable -Name $pair[0] -Value $v -Scope Script }
    }
    # Integers
    foreach ($pair in @(@('OrgId', 'orgId'), @('StaleDays', 'staleDays'), @('MaxMoves', 'maxMoves'))) {
        if ($BoundParams.ContainsKey($pair[0])) { continue }
        $v = Get-ScriptVar $pair[1]
        if ($v) { $n = 0; if ([int]::TryParse($v, [ref]$n)) { Set-Variable -Name $pair[0] -Value $n -Scope Script } }
    }
    # Lists
    foreach ($pair in @(@('ExcludeTags', 'excludeTags'), @('ExcludeNames', 'excludeNames'))) {
        if ($BoundParams.ContainsKey($pair[0])) { continue }
        $v = Get-ScriptList $pair[1]
        if ($v) { Set-Variable -Name $pair[0] -Value $v -Scope Script }
    }
    # Switches
    foreach ($pair in @(@('Execute', 'execute'), @('SkipOffline', 'skipOffline'), @('SkipMapValidation', 'skipMapValidation'))) {
        if ($BoundParams.ContainsKey($pair[0])) { continue }
        $v = Get-ScriptBool $pair[1]
        if ($null -ne $v) { Set-Variable -Name $pair[0] -Value ([switch]$v) -Scope Script }
    }
}

# ===========================================================================
# SUBNET MATCHING
# Every rule normalises to a numeric [start..end] span. Smallest span wins,
# which gives longest-prefix-match for free and also handles ranges.
# ===========================================================================
function ConvertTo-IPNum {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $null }
    $o = $Ip.Trim().Split('.')
    if ($o.Count -ne 4) { return $null }
    [uint64]$v = 0
    foreach ($p in $o) {
        [int]$n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { return $null }
        if ($n -lt 0 -or $n -gt 255) { return $null }
        $v = ($v * 256) + $n
    }
    return $v
}

function ConvertFrom-IPNum {
    param([uint64]$N)
    return "{0}.{1}.{2}.{3}" -f (($N -shr 24) -band 255), (($N -shr 16) -band 255), (($N -shr 8) -band 255), ($N -band 255)
}

# Turn a Subnet cell into @{Start;End;Span;Text} or $null if unparseable.
function ConvertTo-SubnetRule {
    param([string]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $null }
    $s = $Spec.Trim()

    # CIDR: a.b.c.d/nn
    if ($s -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})\s*$') {
        $base = ConvertTo-IPNum $Matches[1]
        [int]$prefix = $Matches[2]
        if ($null -eq $base -or $prefix -lt 0 -or $prefix -gt 32) { return $null }
        [uint64]$size = [uint64][math]::Pow(2, 32 - $prefix)
        [uint64]$mask = [uint64]4294967296 - $size          # 2^32 - size
        [uint64]$start = $base -band $mask
        return @{ Start = $start; End = $start + $size - 1; Span = $size; Text = $s }
    }

    # Wildcard: 10.10.1.* / 10.10.*.* / 10.*.*.*
    if ($s -match '^\s*[\d\*]{1,3}(?:\.[\d\*]{1,3}){3}\s*$' -and $s.Contains('*')) {
        $o = $s.Split('.')
        $solid = 0
        foreach ($p in $o) { if ($p -eq '*') { break }; $solid++ }
        # every octet after the first '*' must also be '*'
        for ($i = $solid; $i -lt 4; $i++) { if ($o[$i] -ne '*') { return $null } }
        $baseIp = (@($o[0..($solid - 1)]) + @(0) * (4 - $solid)) -join '.'
        if ($solid -eq 0) { $baseIp = '0.0.0.0' }
        $base = ConvertTo-IPNum $baseIp
        if ($null -eq $base) { return $null }
        [uint64]$size = [uint64][math]::Pow(2, 32 - ($solid * 8))
        return @{ Start = $base; End = $base + $size - 1; Span = $size; Text = $s }
    }

    # Range: a.b.c.d-e.f.g.h  or  a.b.c.d-h  (short form, last octet)
    if ($s -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*-\s*(\d{1,3}(?:\.\d{1,3}){3}|\d{1,3})\s*$') {
        $start = ConvertTo-IPNum $Matches[1]
        $rhs = $Matches[2]
        if ($rhs -notmatch '\.') {
            $o = $Matches[1].Split('.')
            $rhs = "$($o[0]).$($o[1]).$($o[2]).$rhs"
        }
        $end = ConvertTo-IPNum $rhs
        if ($null -eq $start -or $null -eq $end -or $end -lt $start) { return $null }
        return @{ Start = $start; End = $end; Span = ($end - $start + 1); Text = $s }
    }

    # Single IP
    $one = ConvertTo-IPNum $s
    if ($null -ne $one) { return @{ Start = $one; End = $one; Span = [uint64]1; Text = $s } }

    return $null
}

# Most specific (smallest span) matching rule, or $null.
function Find-SubnetMatch {
    param([string]$Ip, $Rules)
    $n = ConvertTo-IPNum $Ip
    if ($null -eq $n) { return $null }
    $best = $null
    foreach ($r in $Rules) {
        if ($n -ge $r.Start -and $n -le $r.End) {
            if ($null -eq $best -or $r.Span -lt $best.Span) { $best = $r }
        }
    }
    return $best
}

# ===========================================================================
# SELF TEST  (no credentials, no network)
# ===========================================================================
function Invoke-SelfTest {
    $fails = 0
    $n = 0
    function Assert-Eq {
        param($Actual, $Expected, [string]$Label)
        $script:n++
        if ("$Actual" -eq "$Expected") {
            Write-Host ("  PASS  {0}" -f $Label) -ForegroundColor Green
        }
        else {
            Write-Host ("  FAIL  {0}  (got '{1}', expected '{2}')" -f $Label, $Actual, $Expected) -ForegroundColor Red
            $script:fails++
        }
    }
    $script:fails = 0; $script:n = 0

    Write-Host 'Subnet parsing' -ForegroundColor Cyan
    Assert-Eq (ConvertTo-IPNum '0.0.0.0')          0                    'IP 0.0.0.0 -> 0'
    Assert-Eq (ConvertTo-IPNum '255.255.255.255')  4294967295           'IP 255.255.255.255'
    Assert-Eq (ConvertTo-IPNum '10.10.1.1')        168427777            'IP 10.10.1.1'
    Assert-Eq (ConvertTo-IPNum '10.10.1.256')      ''                   'IP octet > 255 rejected'
    Assert-Eq (ConvertTo-IPNum '10.10.1')          ''                   'IP with 3 octets rejected'
    Assert-Eq (ConvertTo-IPNum 'not-an-ip')        ''                   'garbage rejected'
    Assert-Eq (ConvertFrom-IPNum 168427777)        '10.10.1.1'          'round-trip back to text'

    Write-Host 'Rule spans' -ForegroundColor Cyan
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.0/24').Span   256          '/24 span 256'
    Assert-Eq (ConvertTo-SubnetRule '10.10.0.0/16').Span   65536        '/16 span 65536'
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.5/32').Span   1            '/32 span 1'
    Assert-Eq (ConvertTo-SubnetRule '0.0.0.0/0').Span      4294967296   '/0 span whole space'
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.*').Span      256          'wildcard .* = /24'
    Assert-Eq (ConvertTo-SubnetRule '10.10.*.*').Span      65536        'wildcard .*.* = /16'
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.50').Span     1            'bare IP = /32'
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.20-10.10.1.40').Span 21    'explicit range span'
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.20-40').Span  21           'short range span'
    Assert-Eq (ConvertTo-SubnetRule '10.10.1.40-10.10.1.20') ''         'backwards range rejected'
    Assert-Eq (ConvertTo-SubnetRule 'garbage')             ''           'garbage rule rejected'

    Write-Host 'CIDR host-bit normalisation' -ForegroundColor Cyan
    $r = ConvertTo-SubnetRule '10.10.1.77/24'
    Assert-Eq (ConvertFrom-IPNum $r.Start) '10.10.1.0'   'host bits masked off'
    Assert-Eq (ConvertFrom-IPNum $r.End)   '10.10.1.255' '/24 end address'

    Write-Host 'Most-specific-wins matching' -ForegroundColor Cyan
    $rules = @(
        (ConvertTo-SubnetRule '0.0.0.0/0')     + @{ Label = 'catchall' }
        (ConvertTo-SubnetRule '10.0.0.0/8')    + @{ Label = 'corp' }
        (ConvertTo-SubnetRule '10.10.0.0/16')  + @{ Label = 'brewster' }
        (ConvertTo-SubnetRule '10.10.5.0/24')  + @{ Label = 'brewster-floor2' }
        (ConvertTo-SubnetRule '10.10.5.99')    + @{ Label = 'the-one-server' }
    )
    Assert-Eq (Find-SubnetMatch '10.10.5.99'  $rules).Label 'the-one-server'   '/32 beats /24'
    Assert-Eq (Find-SubnetMatch '10.10.5.40'  $rules).Label 'brewster-floor2'  '/24 beats /16'
    Assert-Eq (Find-SubnetMatch '10.10.9.7'   $rules).Label 'brewster'         '/16 beats /8'
    Assert-Eq (Find-SubnetMatch '10.99.9.7'   $rules).Label 'corp'             '/8 beats catch-all'
    Assert-Eq (Find-SubnetMatch '172.16.4.4'  $rules).Label 'catchall'         'catch-all sweeps rest'
    Assert-Eq (Find-SubnetMatch 'fe80::1'     $rules)       ''                 'IPv6 never matches'
    Assert-Eq (Find-SubnetMatch ''            $rules)       ''                 'empty IP never matches'

    Write-Host 'Boundaries' -ForegroundColor Cyan
    $b = @((ConvertTo-SubnetRule '10.10.1.0/24') + @{ Label = 'in' })
    Assert-Eq (Find-SubnetMatch '10.10.1.0'   $b).Label 'in'  'network address matches'
    Assert-Eq (Find-SubnetMatch '10.10.1.255' $b).Label 'in'  'broadcast address matches'
    Assert-Eq (Find-SubnetMatch '10.10.0.255' $b)       ''    'one below is out'
    Assert-Eq (Find-SubnetMatch '10.10.2.0'   $b)       ''    'one above is out'

    Write-Host 'IP selection from a device record' -ForegroundColor Cyan
    Assert-Eq (Select-DeviceIPv4 @('fe80::d1af:3376:2618:ee0b', '10.103.156.164')) '10.103.156.164' 'skips IPv6, takes IPv4'
    Assert-Eq (Select-DeviceIPv4 @('fd97::1|fe80::2'))                             ''               'pipe-joined IPv6 blob ignored'
    Assert-Eq (Select-DeviceIPv4 @('169.254.9.9', '192.168.1.42'))                 '192.168.1.42'   'skips APIPA link-local'
    Assert-Eq (Select-DeviceIPv4 @('127.0.0.1', '10.1.1.5'))                       '10.1.1.5'       'skips loopback'
    Assert-Eq (Select-DeviceIPv4 @())                                              ''               'empty list'

    Write-Host ''
    if ($script:fails -eq 0) {
        Write-Host ("SELF TEST PASSED - {0}/{0} assertions." -f $script:n) -ForegroundColor Green
        return 0
    }
    Write-Host ("SELF TEST FAILED - {0} of {1} assertions failed." -f $script:fails, $script:n) -ForegroundColor Red
    return 1
}

# Pick the usable IPv4 out of a device's ipAddresses array.
# Ninja returns IPv6 entries too, sometimes several pipe-joined into one string.
# Loopback and 169.254.x APIPA are useless for site matching, so they are skipped.
function Select-DeviceIPv4 {
    param([string[]]$Addresses)
    if (-not $Addresses) { return $null }
    foreach ($raw in $Addresses) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        foreach ($a in ($raw -split '\|')) {
            $a = $a.Trim()
            if ($a -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
            if ($a.StartsWith('127.') -or $a.StartsWith('169.254.')) { continue }
            if ($null -ne (ConvertTo-IPNum $a)) { return $a }
        }
    }
    return $null
}

# ===========================================================================
if ($SelfTest) { exit (Invoke-SelfTest) }
# ===========================================================================

Apply-ScriptVars

# ===========================================================================
# OUTPUT DIRECTORY
# $PSScriptRoot comes back EMPTY under the NinjaOne agent's invocation mode, so
# the -Dir default is blank and every Join-Path at the end of the run throws
# "Cannot bind argument to parameter 'Path'" - after all the work is already done,
# which marks an otherwise successful run as failed. Resolve a usable directory
# rather than trusting $PSScriptRoot.
# ===========================================================================
if ([string]::IsNullOrWhiteSpace($Dir)) { $Dir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Dir) -and $MyInvocation.MyCommand.Path) {
    $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($Dir)) { $Dir = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($Dir)) { $Dir = $env:TEMP }

# ===========================================================================
# CREDENTIALS FROM NINJAONE CUSTOM FIELDS
# When this runs as a NinjaOne automation the agent exposes Ninja-Property-Get,
# so the credentials live in custom fields instead of being pasted into the
# script body or a scheduled task's command line. The two secret fields are type
# "Secure" with API permission None, which means a script on an agent can read
# them but the public API cannot read them back out.
#
# Outside a NinjaOne automation the cmdlet does not exist; the lookup returns
# null and resolution falls through to the environment variables.
# ===========================================================================
function Get-NinjaCustomField {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    # Call it directly rather than probing with Get-Command first. The agent injects
    # Ninja-Property-Get into the runspace and Get-Command does not always resolve it,
    # which would silently skip the lookup and fall through to the env vars. If the
    # command genuinely is not there (scheduled task, local shell) the call throws
    # CommandNotFoundException and we return null, which is the same outcome.
    try {
        $v = & 'Ninja-Property-Get' $Name 2>$null
        if ($v -is [array]) { $v = ($v -join '') }
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return ([string]$v).Trim()
    }
    catch { return $null }
}

# Precedence: command line  >  Script Variables  >  custom fields  >  env vars.
if (-not $NinjaUrl) { $NinjaUrl = Get-NinjaCustomField $CfInstance }
if (-not $ClientId) { $ClientId = Get-NinjaCustomField $CfClientId }
if (-not $ClientSecret) { $ClientSecret = Get-NinjaCustomField $CfClientSecret }

if (-not $NinjaUrl) { $NinjaUrl = if ($env:NINJA_URL) { $env:NINJA_URL } else { 'https://app.ninjarmm.com' } }
if (-not $ClientId) { $ClientId = $env:NINJA_CLIENT_ID }
if (-not $ClientSecret) { $ClientSecret = $env:NINJA_CLIENT_SECRET }
$NinjaUrl = $NinjaUrl.TrimEnd('/')
if ($NinjaUrl -notmatch '^https?://') { $NinjaUrl = "https://$NinjaUrl" }

# ---------------------------------------------------------------------------
# AUTH + API (token cached; 429/5xx retried)
# ---------------------------------------------------------------------------
$Script:Token = $null
$Script:TokenExpiry = [datetime]::MinValue

# Windows PowerShell 5.1 on Server 2012 R2 / 2016 still negotiates TLS 1.0 by default,
# which NinjaOne refuses - auth dies before the first call. No-op on PowerShell 7.
try {
    [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }

function Get-NinjaToken {
    if ($Script:Token -and (Get-Date) -lt $Script:TokenExpiry) { return $Script:Token }
    if (-not $ClientId -or -not $ClientSecret) {
        throw ("Missing credentials. Use one of: the ninjaoneClientId / ninjaoneClientSecret custom fields " +
            "(NinjaOne automation runs), the clientId / clientSecret Script Variables, the " +
            "NINJA_CLIENT_ID / NINJA_CLIENT_SECRET environment variables, or -ClientId / -ClientSecret.")
    }
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'monitoring management'
    }
    $resp = Invoke-RestMethod -Uri "$NinjaUrl/ws/oauth/token" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
    $Script:Token = $resp.access_token
    $Script:TokenExpiry = (Get-Date).AddSeconds([int]$resp.expires_in - 60)
    return $Script:Token
}

function Invoke-Ninja {
    param([string]$Method, [string]$Path, $Body, [int]$MaxRetry = 4)
    for ($attempt = 1; ; $attempt++) {
        try {
            $splat = @{
                Uri     = "$NinjaUrl/api/v2/$Path"
                Method  = $Method
                Headers = @{ Authorization = "Bearer $(Get-NinjaToken)" }
            }
            if ($Body) {
                $splat.Body = ($Body | ConvertTo-Json -Depth 6)
                $splat.ContentType = 'application/json; charset=utf-8'
            }
            return Invoke-RestMethod @splat
        }
        catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 401 -and $attempt -eq 1) { $Script:Token = $null; continue }   # token died, re-auth once
            if (($code -eq 429 -or $code -ge 500) -and $attempt -le $MaxRetry) {
                Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $attempt)))
                continue
            }
            throw
        }
    }
}

# Invoke-RestMethod does not reliably enumerate a JSON array back through the pipeline,
# so every list call goes through here and always hands back a real array.
function Invoke-NinjaList {
    param([string]$Path)
    $r = Invoke-Ninja -Method GET -Path $Path
    if ($null -eq $r) { return @() }
    return @($r)
}

# /devices-detailed is cursor-paginated on device id. A single flat pageSize= call
# SILENTLY TRUNCATES at the page boundary, which would quietly leave part of a large
# fleet un-reconciled, so always walk the cursor to the end.
function Invoke-NinjaDeviceList {
    param([string]$Path = 'devices-detailed', [int]$PageSize = 1000)
    $all = @()
    [int]$after = 0
    while ($true) {
        $sep = if ($Path.Contains('?')) { '&' } else { '?' }
        $resp = Invoke-Ninja -Method GET -Path "${Path}${sep}pageSize=${PageSize}&after=${after}"
        # Invoke-RestMethod hands a JSON array back as a SINGLE object, so @() alone gives
        # Count = 1 and the loop would stop after page one. Push it through the pipeline to
        # get a genuinely flat array before counting. Same trap as Invoke-NinjaList.
        $batch = @($resp | ForEach-Object { $_ })
        if (-not $batch.Count) { break }
        $all += $batch
        if ($batch.Count -lt $PageSize) { break }
        $after = [int]$batch[-1].id
    }
    return $all
}

# ---------------------------------------------------------------------------
# DISCOVER MODE
# Groups the live fleet by subnet so you can see which networks actually exist
# before writing the map. Emits a starter CSV with the Org/Location left blank.
# ---------------------------------------------------------------------------
function Invoke-Discover {
    Write-Host "INFO: Discovering subnets in use (grouping by /$DiscoverPrefix)..."
    $devs = Invoke-NinjaDeviceList
    if ($OrgId) { $devs = @($devs | Where-Object { [int]$_.organizationId -eq $OrgId }) }
    $devs = @($devs | Where-Object {
            $_.nodeClass -notlike '*UNMANAGED*' -and $_.nodeClass -ne 'NMS_NETWORK_MANAGEMENT_AGENT' -and $_.deviceType -ne 'UnmanagedDevice'
        })

    [uint64]$size = [uint64][math]::Pow(2, 32 - $DiscoverPrefix)
    [uint64]$mask = [uint64]4294967296 - $size

    $buckets = @{}
    $noIp = 0
    foreach ($d in $devs) {
        $ip = if ($MatchOn -eq 'PublicIP') { $d.publicIP } else { Select-DeviceIPv4 $d.ipAddresses }
        $n = ConvertTo-IPNum $ip
        if ($null -eq $n) { $noIp++; continue }
        $net = "$(ConvertFrom-IPNum ($n -band $mask))/$DiscoverPrefix"
        if (-not $buckets.ContainsKey($net)) {
            $buckets[$net] = [pscustomobject]@{ Subnet = $net; Devices = 0; Orgs = @{}; Sample = $ip }
        }
        $buckets[$net].Devices++
        $buckets[$net].Orgs[[int]$d.organizationId] = $true
    }

    $orgNames = @{}
    try {
        foreach ($o in (Invoke-NinjaList 'organizations?pageSize=1000')) { $orgNames[[int]$o.id] = $o.name }
    }
    catch { Write-Host "WARN: could not load org names: $($_.Exception.Message)" -ForegroundColor Yellow }

    $report = foreach ($b in ($buckets.Values | Sort-Object -Property Devices -Descending)) {
        $labels = foreach ($id in ($b.Orgs.Keys | Sort-Object)) {
            $nm = $orgNames[[int]$id]
            if ($nm) { "$id ($nm)" } else { "$id" }
        }
        [pscustomobject]@{
            Subnet      = $b.Subnet
            Devices     = $b.Devices
            SampleIP    = $b.Sample
            CurrentOrgs = ($labels -join '; ')
        }
    }

    Write-Host ''
    Write-Host "==== Subnets in use ($($report.Count) networks, $($devs.Count) devices, $noIp with no usable IPv4) ====" -ForegroundColor Cyan
    $report | Format-Table -AutoSize

    $out = Join-Path $Dir 'discovered-subnets.csv'
    $report | ForEach-Object {
        [pscustomobject]@{ Subnet = $_.Subnet; OrgID = ''; LocationID = ''; Org = ''; Location = ''; _Devices = $_.Devices; _CurrentOrgs = $_.CurrentOrgs }
    } | Export-Csv $out -NoTypeInformation
    Write-Host "Starter map written to $out - fill in OrgID / LocationID / Org / Location, delete the _ columns, save as your site map." -ForegroundColor Cyan
}

if ($Discover) { Invoke-Discover; exit 0 }

# ---------------------------------------------------------------------------
# LOAD SITE MAP
# ---------------------------------------------------------------------------
function Get-MapText {
    if ($MapInline) { return $MapInline }
    if ($MapUrl) {
        Write-Host "INFO: Downloading site map from $MapUrl"
        return (Invoke-RestMethod -Uri $MapUrl -Method GET)
    }
    $path = if ($MapPath) { $MapPath } else { Join-Path $Dir 'ninja-location-map.csv' }
    if (-not (Test-Path $path)) { throw "Site map not found: $path. Pass -MapPath / -MapUrl / -MapInline, or set the mapPath / mapUrl / mapInline Script Variable." }
    Write-Host "INFO: Loading site map from $path"
    return (Get-Content -Path $path -Raw)
}

try { $mapText = Get-MapText }
catch { Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

# Multi-line Script Variables can arrive with literal \n or CR-only line endings.
$mapText = $mapText -replace '\\r\\n', "`n" -replace '\\n', "`n" -replace "`r`n", "`n" -replace "`r", "`n"
$rows = $mapText | ConvertFrom-Csv

$Rules = @()
$badRows = @()
$rowNum = 1
foreach ($row in $rows) {
    $rowNum++
    $spec = $row.Subnet
    if (-not $spec) { $spec = $row.Key }         # back-compat with the old gateway-keyed CSV
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }

    $rule = ConvertTo-SubnetRule $spec
    if (-not $rule) { $badRows += "row $rowNum : unparseable Subnet '$spec'"; continue }

    [int]$oid = 0; [int]$lid = 0
    if (-not [int]::TryParse($row.OrgID, [ref]$oid) -or $oid -le 0) { $badRows += "row $rowNum ($spec): bad OrgID '$($row.OrgID)'"; continue }
    if (-not [int]::TryParse($row.LocationID, [ref]$lid) -or $lid -le 0) { $badRows += "row $rowNum ($spec): bad LocationID '$($row.LocationID)'"; continue }

    # Store rules as PSCustomObject, NOT as a hashtable. Windows PowerShell 5.1 -
    # which is what the NinjaOne agent runs - will not resolve a hashtable key
    # through -Property on Group-Object or through member enumeration, so
    # `Group-Object OrgID` silently yields a null Name that casts to 0 and the map
    # validation then reports "OrgID 0 does not exist". PowerShell 7 resolves it
    # fine, so this only shows up on the agent. PSCustomObject behaves the same on
    # both.
    $Rules += [pscustomobject]@{
        Start      = $rule.Start
        End        = $rule.End
        Span       = $rule.Span
        Text       = $rule.Text
        OrgID      = $oid
        LocationID = $lid
        Label      = "$($row.Org) / $($row.Location)".Trim(' /')
        Row        = $rowNum
    }
}

if ($badRows.Count) {
    Write-Host 'FAIL: site map has invalid rows:' -ForegroundColor Red
    $badRows | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
if (-not $Rules.Count) { Write-Host 'FAIL: site map contains no usable rows.' -ForegroundColor Red; exit 1 }

# Identical spans covering identical ranges are genuinely ambiguous - warn, do not guess silently.
foreach ($g in ($Rules | Group-Object { "$($_.Start)-$($_.End)" } | Where-Object { $_.Count -gt 1 })) {
    Write-Host "WARN: rows $($g.Group.Row -join ', ') cover the same range ($($g.Group[0].Text)). First one wins." -ForegroundColor Yellow
}

Write-Host "INFO: Loaded $($Rules.Count) site rules (match on: $MatchOn)."

# ---------------------------------------------------------------------------
# VALIDATE MAP AGAINST LIVE ORGS / LOCATIONS
# Catches the #1 real-world failure: a typo'd LocationID that 400s on every PATCH.
# ---------------------------------------------------------------------------
if (-not $SkipMapValidation) {
    try {
        $orgs = @{}
        foreach ($o in (Invoke-NinjaList 'organizations?pageSize=1000')) { $orgs[[int]$o.id] = $o.name }

        $badMap = @()
        foreach ($g in ($Rules | Group-Object OrgID)) {
            $oid = [int]$g.Name
            if (-not $orgs.ContainsKey($oid)) {
                $badMap += "OrgID $oid does not exist (rows $($g.Group.Row -join ', '))"
                continue
            }
            $locs = @{}
            foreach ($l in (Invoke-NinjaList "organization/$oid/locations")) { $locs[[int]$l.id] = $l.name }
            foreach ($r in $g.Group) {
                if (-not $locs.ContainsKey([int]$r.LocationID)) {
                    $badMap += "LocationID $($r.LocationID) is not in org $oid '$($orgs[$oid])' (row $($r.Row), $($r.Text))"
                }
            }
        }
        if ($badMap.Count) {
            Write-Host 'FAIL: site map does not match the live instance:' -ForegroundColor Red
            $badMap | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            Write-Host 'Fix the CSV (or pass -SkipMapValidation to bypass).' -ForegroundColor Red
            exit 1
        }
        Write-Host "INFO: Site map validated - all $($Rules.Count) destinations exist."
    }
    catch {
        Write-Host "FAIL: could not validate site map: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# PULL DEVICES
# ---------------------------------------------------------------------------
Write-Host 'INFO: Fetching devices...'
try { $Devices = Invoke-NinjaDeviceList }
catch { Write-Host "FAIL: could not fetch devices: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

if ($OrgId) { $Devices = @($Devices | Where-Object { [int]$_.organizationId -eq $OrgId }) }

# Managed agents only. ITAM / unmanaged records do not have a real IP to match on.
$Devices = @($Devices | Where-Object {
        $_.nodeClass -notlike '*UNMANAGED*' -and $_.nodeClass -ne 'NMS_NETWORK_MANAGEMENT_AGENT' -and $_.deviceType -ne 'UnmanagedDevice'
    })

$Skipped = @()
if ($SkipOffline) {
    $off = @($Devices | Where-Object { $_.offline })
    $off | ForEach-Object { $Skipped += [pscustomobject]@{ Device = $_.systemName; DeviceId = $_.id; Reason = 'offline' } }
    $Devices = @($Devices | Where-Object { -not $_.offline })
}
if ($StaleDays -gt 0) {
    $cutoff = [datetimeoffset]::UtcNow.AddDays(-$StaleDays).ToUnixTimeSeconds()
    $stale = @($Devices | Where-Object { $_.lastContact -and [double]$_.lastContact -lt $cutoff })
    $stale | ForEach-Object { $Skipped += [pscustomobject]@{ Device = $_.systemName; DeviceId = $_.id; Reason = "not seen in $StaleDays days" } }
    $Devices = @($Devices | Where-Object { -not ($_.lastContact -and [double]$_.lastContact -lt $cutoff) })
}
if ($ExcludeTags) {
    $ex = @($Devices | Where-Object { $_.tags -and (@($_.tags) | Where-Object { $_ -in $ExcludeTags }) })
    $ex | ForEach-Object { $Skipped += [pscustomobject]@{ Device = $_.systemName; DeviceId = $_.id; Reason = 'excluded tag' } }
    $Devices = @($Devices | Where-Object { -not ($_.tags -and (@($_.tags) | Where-Object { $_ -in $ExcludeTags })) })
}
if ($ExcludeNames) {
    $matchesName = {
        param($name)
        foreach ($pat in $ExcludeNames) { if ($name -like $pat) { return $true } }
        return $false
    }
    $ex = @($Devices | Where-Object { & $matchesName $_.systemName })
    $ex | ForEach-Object { $Skipped += [pscustomobject]@{ Device = $_.systemName; DeviceId = $_.id; Reason = 'excluded name' } }
    $Devices = @($Devices | Where-Object { -not (& $matchesName $_.systemName) })
}

Write-Host "INFO: $($Devices.Count) managed devices in scope ($($Skipped.Count) skipped by filters)."
if ($MatchOn -eq 'Gateway') { Write-Host "INFO: Gateway mode - this makes one extra API call per device." -ForegroundColor Yellow }

function Get-DeviceGateway {
    param([int]$DeviceId)
    try {
        $nics = Invoke-NinjaList "device/$DeviceId/network-interfaces"
        return ($nics |
            Where-Object { $_.status -eq 'Up' -and $_.defaultGateway -and $_.defaultGateway -ne '0.0.0.0' } |
            Select-Object -First 1).defaultGateway
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# RECONCILE
# ---------------------------------------------------------------------------
$Moved = @(); $Unmatched = @(); $Failed = @(); $Correct = 0
$capped = 0
$i = 0

foreach ($d in $Devices) {
    $i++
    Write-Progress -Activity 'Reconciling devices' -Status "$i/$($Devices.Count)  $($d.systemName)" -PercentComplete ([math]::Round($i / [math]::Max($Devices.Count, 1) * 100))

    $key = $null; $target = $null; $via = $MatchOn
    switch ($MatchOn) {
        'Gateway' { $key = Get-DeviceGateway -DeviceId $d.id }
        'PublicIP' { $key = $d.publicIP }
        'LocalIP' { $key = Select-DeviceIPv4 $d.ipAddresses }
        'Auto' {
            $key = Select-DeviceIPv4 $d.ipAddresses
            $target = if ($key) { Find-SubnetMatch $key $Rules } else { $null }
            if (-not $target) { $key = $d.publicIP; $via = 'PublicIP' } else { $via = 'LocalIP' }
        }
    }
    if (-not $target) { $target = if ($key) { Find-SubnetMatch $key $Rules } else { $null } }

    if (-not $target) {
        $Unmatched += [pscustomobject]@{
            Device = $d.systemName; DeviceId = $d.id
            CurrentOrg = $d.organizationId; CurrentLoc = $d.locationId
            MatchKey = $key; Via = $via
        }
        continue
    }

    if ([int]$d.organizationId -eq [int]$target.OrgID -and [int]$d.locationId -eq [int]$target.LocationID) {
        $Correct++
        continue
    }

    $row = [pscustomobject]@{
        Device  = $d.systemName; DeviceId = $d.id
        MatchKey = $key; Via = $via; Rule = $target.Text
        FromOrg = $d.organizationId; FromLoc = $d.locationId
        ToOrg   = $target.OrgID; ToLoc = $target.LocationID; ToLabel = $target.Label
    }

    if ($MaxMoves -gt 0 -and ($Moved.Count + $capped) -ge $MaxMoves) { $capped++; continue }
    if (-not $Execute) { $Moved += $row; continue }         # dry run: record as planned

    try {
        Invoke-Ninja -Method PATCH -Path "device/$($d.id)" -Body @{ organizationId = [int]$target.OrgID; locationId = [int]$target.LocationID } | Out-Null
        $Moved += $row
    }
    catch {
        # Capture the message FIRST. Inside a Select-Object calculated property $_ is the
        # piped $row, not the exception, so reading $_.Exception.Message there yields null
        # and mover-failed.csv lands with an empty Error column - exactly when you need it.
        $msg = $_.Exception.Message
        $Failed += ($row | Select-Object *, @{n = 'Error'; e = { $msg } })
    }
}
Write-Progress -Activity 'Reconciling devices' -Completed

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
$verb = if ($Execute) { 'Moved' } else { 'Would move (DRY RUN)' }
Write-Host ''
Write-Host '==== NinjaOne Device Mover ====' -ForegroundColor Cyan
Write-Host "Mode            : $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })"
Write-Host "In scope        : $($Devices.Count)"
Write-Host "Already correct : $Correct"
Write-Host "$verb : $($Moved.Count)" -ForegroundColor Green
Write-Host "Unmatched       : $($Unmatched.Count)" -ForegroundColor Yellow
Write-Host "Skipped         : $($Skipped.Count)"
Write-Host "Failed          : $($Failed.Count)" -ForegroundColor Red
if ($capped) { Write-Host "Held by MaxMoves: $capped  (raise -MaxMoves once the plan looks right)" -ForegroundColor Yellow }

if ($Moved.Count) {
    # Out-String -Width keeps the table readable in narrow consoles and in the NinjaOne
    # activity pane; without it Format-Table shreds the headers into vertical confetti.
    $Moved | Sort-Object ToOrg, ToLoc |
        Format-Table Device, MatchKey, Rule, FromOrg, FromLoc, ToOrg, ToLoc, ToLabel -AutoSize |
            Out-String -Width 220 | Write-Host
    $Moved | Export-Csv (Join-Path $Dir 'mover-moved.csv') -NoTypeInformation
}
if ($Unmatched.Count) {
    $Unmatched | Sort-Object CurrentOrg | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $Unmatched | Export-Csv (Join-Path $Dir 'mover-unmatched.csv') -NoTypeInformation
}
if ($Skipped.Count) { $Skipped | Export-Csv (Join-Path $Dir 'mover-skipped.csv') -NoTypeInformation }
if ($Failed.Count) {
    $Failed | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $Failed | Export-Csv (Join-Path $Dir 'mover-failed.csv') -NoTypeInformation
}

Write-Host ''
Write-Host "Reports written to: $Dir" -ForegroundColor Cyan
Write-Host 'On a NinjaOne automation run this is a temp folder that gets cleaned up - the tables above are the record. Set the Dir parameter to keep the CSVs.'

if (-not $Execute -and $Moved.Count) {
    Write-Host ''
    Write-Host 'Dry run only. Re-run with -Execute (or tick the execute Script Variable) to apply.' -ForegroundColor Cyan
}

if ($Failed.Count) { exit 2 }
exit 0
