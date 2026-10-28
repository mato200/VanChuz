<#
.SYNOPSIS
    Removes the pinned tether route installed by vps-route.ps1.

.DESCRIPTION
    Convenience wrapper so you can undo the routing change without remembering
    the parameters. Requires elevation.

.EXAMPLE
    .\vps-route-off.ps1
#>
[CmdletBinding()]
param(
    [string]$Target
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

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Must run elevated (Administrator)."
    exit 1
}

$existing = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -eq "$Target/32" }

if (-not $existing) {
    Write-Host "[i] No $Target/32 route present - nothing to do."
    exit 0
}

foreach ($r in $existing) {
    Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex `
                    -NextHop $r.NextHop -Confirm:$false
    Write-Host "[+] Removed $($r.DestinationPrefix) via ifIndex $($r.InterfaceIndex)"
}

Write-Host "[ok] $Target now follows the normal corporate route." -ForegroundColor Green
