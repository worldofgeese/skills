#requires -Version 5.1
<#
.SYNOPSIS
  Log in to a Synology Router (SRM) via its WebAPI and run a read-only health
  and connectivity diagnosis (WAN/internet, WiFi radios, DNS, clock/NTP, logs).

.DESCRIPTION
  Read-only. Makes no configuration changes. Credentials are never written to
  disk or echoed. Pass them via parameters, environment variables, or secure
  prompt.

  Environment variables (optional):
    SRM_URL       e.g. http://192.168.1.1:8000   (default if unset)
    SRM_ACCOUNT   admin account name
    SRM_PASSWORD  account password

.EXAMPLE
  ./diagnose.ps1 -RouterUrl http://192.168.1.1:8000 -Account admin
  (prompts securely for the password)

.EXAMPLE
  $env:SRM_ACCOUNT='admin'; $env:SRM_PASSWORD='...'; ./diagnose.ps1
#>
[CmdletBinding()]
param(
  [string]$RouterUrl = $(if ($env:SRM_URL) { $env:SRM_URL } else { 'http://192.168.1.1:8000' }),
  [string]$Account   = $env:SRM_ACCOUNT,
  [string]$Password  = $env:SRM_PASSWORD,
  [switch]$Raw   # also dump raw JSON of each probe
)

$ErrorActionPreference = 'Stop'
$RouterUrl = $RouterUrl.TrimEnd('/')

if (-not $Account)  { $Account = Read-Host 'SRM account' }
if (-not $Password) {
  $sec = Read-Host 'SRM password' -AsSecureString
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Ok($t)      { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn($t)    { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Bad($t)     { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t)    { Write-Host "  $t" }

# ---------------------------------------------------------------------------
# API map: resolve each API's entry path/version (the entry.cgi name is
# obfuscated and can change between firmware versions, so never hardcode it).
# ---------------------------------------------------------------------------
$infoUrl = "$RouterUrl/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all"
$apiMap  = (Invoke-RestMethod -Uri $infoUrl -TimeoutSec 30).data

# ---------------------------------------------------------------------------
# Login. IMPORTANT SRM quirks learned the hard way:
#   * Must be POST with enable_syno_token=yes (a plain GET login returns 400).
#   * Subsequent calls authenticate with the _sid query param (curl/IRM does
#     not reliably persist the SRM cookie).
# ---------------------------------------------------------------------------
$loginBody = @{
  api = 'SYNO.API.Auth'; version = '3'; method = 'login'; account = $Account
  passwd = $Password; session = 'SRM'; format = 'cookie'; enable_syno_token = 'yes'
}
$login = Invoke-RestMethod -Uri "$RouterUrl/webapi/auth.cgi" -Method Post -Body $loginBody -TimeoutSec 30
if (-not $login.success) {
  $c = $login.error.code
  $hint = switch ($c) {
    400 { 'no such account or incorrect password' }
    403 { '2-factor authentication (OTP) required' }
    404 { '2-factor authentication failed' }
    default { 'see Synology auth error codes' }
  }
  throw "Login failed (error ${c}: $hint)."
}
$sid = $login.data.sid
$Password = $null  # drop from memory

function Invoke-Api {
  param([string]$Api, [string]$Version, [string]$Method, [string]$ExtraQuery)
  $path = $apiMap.$Api.path
  if (-not $path) { return @{ success = $false; error = @{ code = 'no-such-api' } } }
  $u = "$RouterUrl/webapi/$path?api=$Api&version=$Version&method=$Method&_sid=$sid"
  if ($ExtraQuery) { $u += "&$ExtraQuery" }
  try { Invoke-RestMethod -Uri $u -TimeoutSec 30 }
  catch { @{ success = $false; error = @{ code = "http:$($_.Exception.Message)" } } }
}

# ping_start takes target as a JSON string, e.g. target="8.8.8.8".
# Success => it could start (host reachable/route exists). Error 4360 => failed.
function Test-RouterPing {
  param([string]$Target)
  $enc = [uri]::EscapeDataString('"' + $Target + '"')
  $r = Invoke-Api 'SYNO.Core.Network.Tool' '1' 'ping_start' "target=$enc"
  [bool]$r.success
}

function Dump($label, $obj) { if ($Raw) { Write-Host "--- $label ---" -ForegroundColor DarkGray; ($obj | ConvertTo-Json -Depth 8) } }

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------
$findings = New-Object System.Collections.Generic.List[string]

Section 'System'
$sys = Invoke-Api 'SYNO.Core.System' '1' 'info'; Dump 'system' $sys
$now = Get-Date
if ($sys.success) {
  $d = $sys.data
  Info ("Model {0}   Firmware {1} ({2})" -f $d.model, $d.firmware_ver, $d.firmware_date)
  Info ("Uptime {0}   Timezone {1}   NTP {2} ({3})" -f $d.up_time, $d.time_zone, $d.enabled_ntp, $d.ntp_server)
  Info ("Router time: {0}   (host now: {1})" -f $d.time, $now.ToString('yyyy-MM-dd HH:mm:ss'))
  try {
    $skew = [math]::Abs(((Get-Date $d.time) - $now).TotalMinutes)
    if ($skew -gt 10) { Warn ("Clock skew ~{0:N0} min - NTP has not synced (usually a symptom of no internet)." -f $skew); $findings.Add('clock-skew') }
    else { Ok 'Clock in sync.' }
  } catch { }
}

Section 'WAN / Internet'
$net = Invoke-Api 'SYNO.Core.Network' '1' 'get'; Dump 'network' $net
$cs  = Invoke-Api 'SYNO.Core.Network.Router.ConnectionStatus' '1' 'get'; Dump 'connstatus' $cs
$wanIp = $null; $gw = $null
if ($net.success) {
  $gi = $net.data.gateway_info
  $gw = $net.data.gateway; $wanIp = $gi.ip
  Info ("WAN {0}: ip {1}/{2}  gw {3}  dhcp {4}  link {5}" -f $gi.ifname, $gi.ip, $gi.mask, $net.data.gateway, $gi.use_dhcp, $gi.status)
  Info ("DNS: primary {0}  secondary {1}  manual {2}" -f $net.data.dns_primary, $net.data.dns_secondary, $net.data.dns_manual)
  if ($wanIp -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)') {
    Warn "WAN IP is private/CGNAT -> the router sits behind another device (double-NAT / ONT in router mode)."
    $findings.Add('double-nat')
  }
}
if ($cs.success) {
  $v4 = $cs.data.ipv4.conn_status; $v6 = $cs.data.ipv6.conn_status
  if ($v4 -eq 'normal' -or $v4 -eq 'connected') { Ok "IPv4 connection: $v4" }
  else { Bad "IPv4 connection: $v4"; $findings.Add('wan-not-available') }
  Info "IPv6 connection: $v6"
}

Section 'Connectivity tests (from the router)'
if ($gw) { if (Test-RouterPing $gw) { Ok "Gateway $gw reachable" } else { Bad "Gateway $gw NOT reachable"; $findings.Add('gw-unreachable') } }
$net1 = Test-RouterPing '8.8.8.8'
$net2 = Test-RouterPing '1.1.1.1'
if ($net1) { Ok 'Public 8.8.8.8 reachable' } else { Bad 'Public 8.8.8.8 NOT reachable'; $findings.Add('internet-unreachable') }
if ($net2) { Ok 'Public 1.1.1.1 reachable' } else { Bad 'Public 1.1.1.1 NOT reachable' }

Section 'WiFi'
$wdis = Invoke-Api 'SYNO.Wifi.Network.NetworkDisabled' '1' 'get'; Dump 'wifi-disabled' $wdis
$wst  = Invoke-Api 'SYNO.Wifi.Radio.Status' '1' 'get'; Dump 'wifi-radio-status' $wst
$wset = Invoke-Api 'SYNO.Wifi.Radio.Setting' '1' 'get'; Dump 'wifi-radio-setting' $wset
if ($wdis.success) {
  if ($wdis.data.is_disabled) { Bad 'All WiFi networks are DISABLED.'; $findings.Add('wifi-disabled') }
  else { Ok 'WiFi networks enabled.' }
}
if ($wst.success) {
  foreach ($r in $wst.data.status_list) {
    $dfs = $r.channel -ge 52 -and $r.channel -le 144
    $tag = if ($r.channel -eq 0) { 'off/backhaul' } elseif ($dfs) { 'DFS - can drop on radar' } else { 'non-DFS' }
    if ($dfs) { Warn ("{0}: channel {1} ({2})" -f $r.radio_type, $r.channel, $tag); $findings.Add('dfs-channel') }
    else { Info ("{0}: channel {1} ({2})" -f $r.radio_type, $r.channel, $tag) }
  }
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
Section 'Verdict'
if ($findings -contains 'wifi-disabled') {
  Bad 'WiFi is switched off on the router. Re-enable the wireless networks.'
}
elseif (($findings -contains 'internet-unreachable') -and -not ($findings -contains 'gw-unreachable')) {
  Bad 'No internet past the upstream device. The router reaches its gateway but nothing on the public internet.'
  if ($findings -contains 'double-nat') {
    Info '-> WAN has a private IP: the ONT/modem is in router mode and its own internet session is down, OR it should be bridged.'
  }
  Info '-> This is an ISP / ONT / line-session problem, not your WiFi. Contact the ISP; ask them to verify the WAN/PPPoE session and re-provision the line.'
}
elseif ($findings -contains 'gw-unreachable') {
  Bad 'Cannot even reach the WAN gateway - check the WAN cable / ONT power / link.'
}
elseif ($findings.Count -eq 0 -or ($findings | Where-Object { $_ -notin @('dfs-channel') }).Count -eq 0) {
  Ok 'Internet and WiFi look healthy.'
  if ($findings -contains 'dfs-channel') { Warn 'A 5 GHz radio is on a DFS channel - consider pinning a non-DFS channel to avoid radar-induced dropouts.' }
}
else {
  Warn ('Mixed results: ' + ($findings -join ', '))
}

# logout (best effort)
try { Invoke-RestMethod -Uri "$RouterUrl/webapi/auth.cgi?api=SYNO.API.Auth&version=1&method=logout&session=SRM&_sid=$sid" -TimeoutSec 15 | Out-Null } catch { }
Write-Host ''
