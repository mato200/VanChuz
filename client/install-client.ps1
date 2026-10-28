<#
.SYNOPSIS
    VanChuz - Windows client installer.

.DESCRIPTION
    Downloads sing-box, writes the client configuration from the bundle
    produced by the server installer, and creates Desktop shortcuts for
    starting, stopping and checking the proxy.

.PARAMETER Bundle
    The base64 blob printed at the end of the server installation.

.PARAMETER Dir
    Where to install the client. Defaults to the parent of this script.

.EXAMPLE
    .\install-client.ps1 -Bundle "aW0xLjIuMy40LjE6Ci4uLg=="
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Bundle,
    [string]$Dir
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Dir) { $Dir = $ScriptDir }

$BOLD  = "`e[1m"; $GREEN = "`e[32m"; $RED = "`e[31m"; $YELLOW = "`e[33m"; $NC = "`e[0m"
function Step($m) { Write-Host "${GREEN}[+]${NC} $m" }
function Warn($m) { Write-Host "${YELLOW}[!]${NC} $m" }
function Fail($m) { Write-Host "${RED}[x]${NC} $m"; exit 1 }

Write-Host ''
Write-Host "${BOLD}  VanChuz - client installer${NC}"
Write-Host '  ----------------------------------------------'

# --- 1. Decode the bundle ---------------------------------------------------
try {
    $raw = [Convert]::FromBase64String($Bundle.Trim())
    $lines = ([Text.Encoding]::UTF8.GetString($raw)) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} catch {
    Fail "The bundle is not valid base64: $($_.Exception.Message)"
}
if ($lines.Count -lt 5) { Fail "The bundle is malformed (expected 5 lines, got $($lines.Count))." }

$ServerIp  = $lines[0]
$SsKey     = $lines[1]
$Hy2Pass   = $lines[2]
$Hy2Obfs   = $lines[3]
$SpkiPin   = $lines[4]

if ($ServerIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Fail "Invalid server IP in bundle: '$ServerIp'." }
Step "Server: $ServerIp"

# --- 2. Create the directory layout -----------------------------------------
$BinDir = Join-Path $Dir 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

# --- 3. Download sing-box ----------------------------------------------------
$SingBoxVersion = '1.14.4'
$Exe = Join-Path $BinDir 'sing-box.exe'

if (Test-Path $Exe) {
    Step "sing-box already present."
} else {
    $url = "https://github.com/SagerNet/sing-box/releases/download/v$SingBoxVersion/sing-box-$SingBoxVersion-windows-amd64.zip"
    $zip = Join-Path $env:TEMP "sing-box-$SingBoxVersion.zip"
    Step "Downloading sing-box $SingBoxVersion..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    } catch {
        Fail "Download failed: $($_.Exception.Message)`nIf your network blocks GitHub releases, download the file manually and place it at:`n  $Exe"
    }
    $tmp = Join-Path $env:TEMP "sbx-$SingBoxVersion"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1
    if (-not $found) { Fail "sing-box.exe not found inside the downloaded archive." }
    Copy-Item $found.FullName $Exe -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Step "sing-box installed."
}

# --- 4. Write the client configuration --------------------------------------
$Config = @{
    log = @{ level = 'info'; timestamp = $true }
    inbounds = @(
        @{ type = 'mixed'; tag = 'mixed-in'; listen = '127.0.0.1'; listen_port = 1080 }
    )
    outbounds = @(
        @{
            type = 'shadowsocks'; tag = 'ss-out'
            server = $ServerIp; server_port = 443
            method = '2022-blake3-aes-128-gcm'; password = $SsKey
        },
        @{
            type = 'hysteria2'; tag = 'hy2-out'
            server = $ServerIp; server_port = 443
            up_mbps = 100; down_mbps = 500
            obfs = @{ type = 'salamander'; password = $Hy2Obfs }
            password = $Hy2Pass
            tls = @{
                enabled = $true
                server_name = $ServerIp
                alpn = @('h3')
                certificate_public_key_sha256 = @($SpkiPin)
            }
        },
        @{ type = 'direct'; tag = 'direct' },
        @{
            type = 'selector'; tag = 'proxy'
            outbounds = @('ss-out', 'hy2-out', 'direct')
            default = 'ss-out'
            interrupt_exist_connections = $true
        }
    )
    route = @{
        rules = @(@{ protocol = 'dns'; action = 'hijack-dns' })
        final = 'proxy'
        auto_detect_interface = $true
        default_domain_resolver = @{ server = 'local' }
    }
    dns = @{
        servers = @(
            @{ tag = 'remote-dns'; type = 'https'; server = '1.1.1.1'; domain_resolver = @{ server = 'local' } },
            @{ tag = 'local'; type = 'local' }
        )
        final = 'remote-dns'
        strategy = 'prefer_ipv4'
    }
}

$ConfigPath = Join-Path $Dir 'config.json'
$Config | ConvertTo-Json -Depth 12 | Set-Content -Path $ConfigPath -Encoding UTF8
Step "Configuration written to $ConfigPath"

# --- 5. Validate the config -------------------------------------------------
& cmd /c "`"$Exe`" check -c `"$ConfigPath`" > `"$env:TEMP\vanchuz-check.txt`" 2>&1"
if ($LASTEXITCODE -ne 0) {
    Fail "Generated config failed validation:`n$(Get-Content "$env:TEMP\vanchuz-check.txt" -ErrorAction SilentlyContinue | Out-String)"
}
Step 'Configuration validated.'

# --- 6. Create Desktop shortcuts --------------------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$ps1 = Join-Path $Dir 'start-proxy.ps1'
if (Test-Path $ps1) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($pair in @(@('VanChuz Proxy - START', ''), @('VanChuz Proxy - STOP', '-Stop'), @('VanChuz Proxy - STATUS', '-Status'))) {
        $link = Join-Path $desktop ($pair[0] + '.lnk')
        $sc = $shell.CreateShortcut($link)
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`" $($pair[1])"
        $sc.WorkingDirectory = $Dir
        $sc.Description = 'VanChuz proxy'
        $sc.IconLocation = "$Exe,0"
        $sc.Save()
    }
    Step 'Desktop shortcuts created.'
}

Write-Host ''
Write-Host "${BOLD}  Installation complete${NC}"
Write-Host '  ----------------------------------------------'
Write-Host '  Start the proxy  : VanChuz Proxy - START (Desktop shortcut)'
Write-Host '  Local proxy      : socks5://127.0.0.1:1080  (also HTTP)'
Write-Host '  Default transport: Shadowsocks-2022 over TCP/443'
Write-Host ''
Write-Host '  Point an app at it:'
Write-Host '    Firefox : Settings > General > Network Settings > Manual proxy'
Write-Host '               (SOCKS5 127.0.0.1 / 1080, tick "Proxy DNS when using SOCKS v5")'
Write-Host '    Steam   : Settings > Downloads > Proxy Settings > SOCKS5'
Write-Host '    Chrome  : chrome.exe --proxy-server="socks5://127.0.0.1:1080"'
Write-Host ''
