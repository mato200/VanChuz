<#
.SYNOPSIS
    Pins a specific destination IP to the mobile-tether adapter so it bypasses the
    corporate LAN (which blocks outbound TCP/22), while all other traffic keeps
    using the corporate LAN as normal.

.DESCRIPTION
    Windows picks an egress interface by prefix length first, then by metric.
    A /32 host route always beats the 0.0.0.0/0 default route, so adding
    <Target>/32 bound to the tether interface forces just that destination
    through the tether - everything else is untouched.

    The tether is a phone USB-NDIS adapter whose IPv4 address is assigned by DHCP
    and therefore changes on every replug. This script re-detects the adapter and
    its current gateway each time it runs, removes any stale route, and installs a
    fresh one.

.PARAMETER Target
    Destination IPv4 to pin. Defaults to the Oracle VPS.

.PARAMETER TetherPattern
    Regex matched against adapter Name/InterfaceDescription to find the tether.
    The default matches the 'Remote NDIS Compatible Device' (phone USB tether)
    driver and common phone-tether naming.

.PARAMETER Remove
    Remove the pinned route instead of adding it.

.EXAMPLE
    .\vps-route.ps1
    .\vps-route.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Target,
    [string]$TetherPattern = 'Remote NDIS|NDIS Compatible|Android.*USB|Phone.*Link|iPhone|Phone Link|Tether',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# NOTE: $PSScriptRoot is not reliably populated in param() defaults under
# Windows PowerShell 5.1, so paths are resolved in the body.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Resolve the server address from the generated client config so the same
# scripts work for anyone, not just the machine that was set up first.
function Get-ServerIp {
    $cfg = Join-Path $ScriptDir 'config.json'
    if (Test-Path $cfg) {
        try {
            $j = Get-Content $cfg -Raw | ConvertFrom-Json
            $first = $j.outbounds | Where-Object { $_.server } | Select-Object -First 1
            if ($first -and $first.server -match '^\d{1,3}(\.\d{1,3}){3}$') { return $first.server }
        } catch { }
    }
    return $null
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TetherAdapter {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and
                       ($_.InterfaceDescription -match $TetherPattern -or $_.Name -match $TetherPattern) }
    if (-not $adapters) { return $null }
    foreach ($a in $adapters) {
        $cfg = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        $ip = $cfg.IPv4Address | Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        $gw = $cfg.IPv4DefaultGateway.NextHop
        if ($ip -and $gw) {
            return [pscustomobject]@{
                Name = $a.Name; Index = $a.ifIndex; Description = $a.InterfaceDescription
                IPAddress = $ip.IPAddress; Gateway = $gw
            }
        }
    }
    return $null
}

function Remove-PinnedRoute {
    param([string]$Target)
    $existing = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "$Target/32" }
    foreach ($r in $existing) {
        try {
            Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex `
                            -NextHop $r.NextHop -Confirm:$false -ErrorAction Stop
            Write-Host "[+] Removed stale route $($r.DestinationPrefix) via ifIndex $($r.InterfaceIndex)"
        } catch {
            Write-Warning "[!] Could not remove route via ifIndex $($r.InterfaceIndex): $($_.Exception.Message)"
        }
    }
}

if (-not $Target) { $Target = Get-ServerIp }
if (-not $Target) { Write-Error 'Could not determine the server IP. Run install-client.ps1 first, or pass -Target.'; exit 1 }

Write-Host "=== Tether route manager ===" -ForegroundColor Cyan

if (-not (Test-Elevated)) {
    Write-Error "This script must run elevated (Administrator). Right-click PowerShell -> Run as administrator, or use the provided .cmd launcher."
    exit 1
}

if ($Remove) {
    Remove-PinnedRoute -Target $Target
    Write-Host "[+] $Target is no longer pinned. Traffic to it now follows the normal corporate route." -ForegroundColor Green
    exit 0
}

# --- Add mode --------------------------------------------------------------
$tether = Get-TetherAdapter
if (-not $tether) {
    Write-Warning "Could not find an active tether adapter (pattern: '$TetherPattern'). Plug in the phone tether and retry. Adapters seen:"
    Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object ifIndex, Name, InterfaceDescription | Format-Table -AutoSize | Out-String | Write-Host
    exit 1
}

Write-Host "[i] Tether   : $($tether.Name) (ifIndex $($tether.Index)) - $($tether.Description)"
Write-Host "[i] Tether IP: $($tether.IPAddress)  gateway: $($tether.Gateway)"

Remove-PinnedRoute -Target $Target

try {
    New-NetRoute -DestinationPrefix "$Target/32" `
                  -InterfaceIndex $tether.Index `
                  -NextHop $tether.Gateway `
                  -RouteMetric 1 `
                  -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    Write-Host "[+] Added $Target/32 -> $($tether.Name) (metric 1). Only this destination uses the tether." -ForegroundColor Green
} catch {
    Write-Error "Failed to add route: $($_.Exception.Message)"
    exit 1
}

# --- Verify ----------------------------------------------------------------
Write-Host "`n[i] Effective route for $Target :" -ForegroundColor Cyan
try {
    $eff = Find-NetRoute -RemoteIPAddress $Target -ErrorAction Stop | Select-Object -First 1
    Write-Host ("    Interface : {0} (ifIndex {1})" -f $eff.InterfaceAlias, $eff.InterfaceIndex)
    Write-Host ("    Source IP : {0}" -f $eff.IPAddress)
    Write-Host ("    Next hop  : {0}" -f $eff.NextHop)
    if ($eff.InterfaceIndex -ne $tether.Index) {
        Write-Warning "[!] Traffic is NOT using the tether - check for a conflicting route."
    } else {
        Write-Host "[ok] Traffic to $Target now egresses via the tether." -ForegroundColor Green
    }
} catch {
    Write-Warning "[!] Could not resolve effective route: $($_.Exception.Message)"
}

Write-Host "`n[i] TCP reachability to $Target :" -ForegroundColor Cyan
foreach ($p in 22, 443) {
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($Target, $p, $null, $null)
    $ok = $ar.AsyncWaitHandle.WaitOne(5000)
    if ($ok -and $c.Connected) { $c.EndConnect($ar); Write-Host "    TCP $p : OPEN" -ForegroundColor Green }
    else { Write-Host "    TCP $p : BLOCKED/TIMEOUT" -ForegroundColor Yellow }
    $c.Close()
}
