<#
.SYNOPSIS
    Starts the proxy (Shadowsocks-2022 over TCP/443).

.DESCRIPTION
    One-click launcher for the working tunnel.

    Transport : Shadowsocks-2022 (2022-blake3-aes-128-gcm) over TCP/443.
                Its own AEAD layer means the corporate TLS-inspecting gateway
                sees only ciphertext - no URL to categorise - so URL filtering
                (Steam, category "Games*") is bypassed while the connection
                itself transits the corporate network normally.

    Requires  : the server reachable on TCP/443. On a restrictive corporate
                network that port is usually the one still permitted; the /32
                pin created by vps-route.ps1 (if present) just moves it onto
                the mobile tether.

    Exposes   : mixed SOCKS5 + HTTP proxy on 127.0.0.1:1080.

.EXAMPLE
    .\start-proxy.ps1
    .\start-proxy.ps1 -Status      # just report whether it is running
    .\start-proxy.ps1 -Stop        # stop it
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$Bin,
    [switch]$Stop,
    [switch]$Status
)

# NOTE: $PSScriptRoot is NOT reliably populated inside param() default values
# under Windows PowerShell 5.1 (it is under PowerShell 7), so the paths are
# resolved here in the script body instead.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Config) { $Config = Join-Path $ScriptDir 'config.json' }
if (-not $Bin)    { $Bin    = Join-Path $ScriptDir 'bin\sing-box.exe' }

$ErrorActionPreference = 'Continue'
$LogDir = Join-Path (Split-Path -Parent $ScriptDir) 'logs'
$Log    = Join-Path $LogDir 'proxy.log'

function Write-Banner($t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan; Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray }

# ---------------------------------------------------------------- stop mode
if ($Stop) {
    $procs = Get-Process sing-box -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Write-Host "  [ok] sing-box stopped." -ForegroundColor Green
    } else {
        Write-Host "  [i] sing-box was not running."
    }
    exit 0
}

# -------------------------------------------------------------- status mode
if ($Status) {
    $p = Get-Process sing-box -ErrorAction SilentlyContinue
    if (-not $p) {
        Write-Host "  [ ] Proxy is NOT running." -ForegroundColor Yellow
        Write-Host "      Start it with:  start-proxy.cmd"
        exit 1
    }
    Write-Host "  [ok] Proxy is running (PID $($p[0].Id))." -ForegroundColor Green
    try {
        $r = Invoke-WebRequest -Uri 'https://api.ipify.org?format=json' `
                               -Proxy 'http://127.0.0.1:1080' -UseBasicParsing -TimeoutSec 15
        Write-Host "      Egress IP: $($r.Content)" -ForegroundColor Green
    } catch {
        Write-Host "      [!] Proxy process is up but the tunnel is not passing traffic." -ForegroundColor Yellow
    }
    exit 0
}

# --------------------------------------------------------------- start mode
Write-Banner 'VanChuz proxy  -  Shadowsocks-2022 over TCP/443'

if (-not (Test-Path $Bin))    { Write-Host "  [!] sing-box.exe missing at $Bin" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Config)) { Write-Host "  [!] Config missing at $Config" -ForegroundColor Red; exit 1 }

# Stop any previous instance so we never end up with two listeners.
Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 700

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Validate the config before binding anything.
$check = & cmd /c "`"$Bin`" check -c `"$Config`" 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [!] Config validation failed:" -ForegroundColor Red
    $check | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    exit 1
}
Write-Host '  [ok] Config OK'

$p = Start-Process -FilePath $Bin `
                   -ArgumentList @('run', '-c', $Config) `
                   -PassThru -WindowStyle Hidden `
                   -RedirectStandardOutput "$LogDir\proxy.out" `
                   -RedirectStandardError  "$Log"

Start-Sleep -Seconds 4
if ($p.HasExited) {
    Write-Host '  [!] sing-box exited immediately:' -ForegroundColor Red
    Get-Content $Log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  [ok] sing-box started (PID $($p.Id))"

# Verify end-to-end.
$ok = $false
for ($i = 1; $i -le 3; $i++) {
    try {
        $r = Invoke-WebRequest -Uri 'https://api.ipify.org?format=json' `
                               -Proxy 'http://127.0.0.1:1080' -UseBasicParsing -TimeoutSec 15
        Write-Host '  [ok] Tunnel is live' -ForegroundColor Green
        Write-Host "      Egress IP : $($r.Content)" -ForegroundColor Green
        $ok = $true
        break
    } catch {
        Write-Host "      ... attempt $i failed, retrying" -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
}

if (-not $ok) {
    Write-Host '  [!] Tunnel did not come up. Last log lines:' -ForegroundColor Red
    Get-Content $Log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    exit 1
}

# Spot-check a categorised site through the tunnel.
try {
    $s = Invoke-WebRequest -Uri 'https://store.steampowered.com/' `
                           -Proxy 'http://127.0.0.1:1080' -UseBasicParsing -TimeoutSec 25
    $title = [regex]::Match($s.Content, '<title>(.*?)</title>', 'IgnoreCase').Groups[1].Value
    $blocked = $s.Content -match 'McAfee Web Gateway|Blocked by URL filtering'
    if ($blocked) {
        Write-Host '  [!] Steam came back with a corporate block page.' -ForegroundColor Red
    } else {
        Write-Host "  [ok] Steam through the tunnel: HTTP $($s.StatusCode) - $title" -ForegroundColor Green
    }
} catch {
    Write-Host "  [!] Steam check failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Point your app at:' -ForegroundColor White
Write-Host '      SOCKS5 / HTTP proxy : 127.0.0.1 : 1080' -ForegroundColor White
Write-Host '  Firefox : Settings > General > Network Settings > Manual proxy' -ForegroundColor DarkGray
Write-Host '  Steam   : Settings > Downloads > Proxy Settings > SOCKS5' -ForegroundColor DarkGray
Write-Host '  Chrome  : chrome.exe --proxy-server="socks5://127.0.0.1:1080"' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Stop it with:  stop-proxy.cmd     (or:  .\stop-proxy.ps1)' -ForegroundColor DarkGray
Write-Host "  Logs: $Log" -ForegroundColor DarkGray
