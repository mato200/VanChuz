#!/usr/bin/env bash
# =============================================================================
#  VanChuz - server installer
#
#  Installs sing-box + lego on a Debian/Ubuntu host, obtains a publicly
#  trusted TLS certificate for the server's IP address, and starts a proxy
#  service with two transports:
#
#    * Shadowsocks-2022 over TCP/443  (works on restrictive corporate networks
#      that only permit web ports)
#    * Hysteria 2 over QUIC/UDP/443   (where UDP is permitted)
#
#  All secrets are generated on the host and never leave it.
#
#  Usage:  sudo bash install-server.sh
# =============================================================================
set -euo pipefail

SINGBOX_VERSION="1.14.4"
LEGO_VERSION="5.5.2"

INSTALL_DIR="/opt/vps"
CERT_DIR="$INSTALL_DIR/certs"
CONFIG_DIR="$INSTALL_DIR/config"
ACME_DIR="$INSTALL_DIR/lego"
SERVICE_USER="vpssvc"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info()  { echo "${GREEN}[+]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }
err()   { echo "${RED}[x]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install-server.sh"

# --- 1. Detect the public IP ------------------------------------------------
PUBIP="$(curl -fsS -m 15 https://api.ipify.org || true)"
if [[ -z "$PUBIP" ]]; then
    PUBIP="$(curl -fsS -m 15 https://ifconfig.me || true)"
fi
[[ -n "$PUBIP" ]] || die "Could not determine the public IP address."
info "Detected public IP: ${BOLD}${PUBIP}${NC}"

# --- 2. Install dependencies ------------------------------------------------
info "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar gzip iptables-persistent >/dev/null

# --- 3. Install sing-box ----------------------------------------------------
if ! command -v sing-box >/dev/null 2>&1; then
    info "Installing sing-box ${SINGBOX_VERSION}..."
    cd /tmp
    curl -fsSL -o sb.tgz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
    tar xzf sb.tgz
    install -m 755 sing-box-${SINGBOX_VERSION}-linux-amd64/sing-box /usr/local/bin/sing-box
    rm -rf sb.tgz sing-box-${SINGBOX_VERSION}-linux-amd64
fi
info "sing-box: $(sing-box version | head -1)"

# --- 4. Install lego (ACME client) -----------------------------------------
if ! command -v lego >/dev/null 2>&1; then
    info "Installing lego ${LEGO_VERSION}..."
    cd /tmp
    curl -fsSL -o lego.tgz "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_amd64.tar.gz"
    tar xzf lego.tgz lego
    install -m 755 lego /usr/local/bin/lego
    rm -rf lego.tgz lego
fi
info "lego: $(lego --version)"

# --- 5. Create the service user and directories -----------------------------
id -u "$SERVICE_USER" >/dev/null 2>&1 || \
    useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR" "$SERVICE_USER"
install -d -m 755 "$INSTALL_DIR" "$CERT_DIR" "$CONFIG_DIR" "$ACME_DIR"
chown root:"$SERVICE_USER" "$CERT_DIR" "$CONFIG_DIR"

# --- 6. Generate secrets ----------------------------------------------------
info "Generating secrets..."
SS_KEY="$(sing-box generate rand --base64 16)"
HY2_PASSWORD="$(openssl rand -hex 16)"
HY2_OBFS="$(openssl rand -hex 16)"
# --- 7. Write the server config --------------------------------------------
info "Writing configuration..."
cat > "$CONFIG_DIR/config.json" <<JSON
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "up_mbps": 200,
      "down_mbps": 1000,
      "obfs": { "type": "salamander", "password": "${HY2_OBFS}" },
      "users": [ { "name": "vanchuz", "password": "${HY2_PASSWORD}" } ],
      "masquerade": { "type": "proxy", "url": "https://www.microsoft.com" },
      "tls": {
        "enabled": true,
        "server_name": "${PUBIP}",
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key",
        "alpn": ["h3"]
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": 443,
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_KEY}",
      "network": "tcp"
    },
    {
      "type": "mixed",
      "tag": "local-mixed",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "inbound": ["local-mixed"], "action": "route", "outbound": "direct" }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
JSON
chown root:"$SERVICE_USER" "$CONFIG_DIR/config.json"
chmod 640 "$CONFIG_DIR/config.json"

# --- 8. Open the firewall ---------------------------------------------------
info "Opening TCP/443 and UDP/443..."
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -p udp --dport 443 -j ACCEPT
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
fi

# --- 9. Obtain a certificate for the IP address ------------------------------
# Let's Encrypt now issues publicly trusted certificates for bare IP addresses
# (6-day "shortlived" profile), so no domain name is required.
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
info "Requesting a Let's Encrypt certificate for ${PUBIP}..."
if ! lego run \
      --accept-tos \
      --path "$ACME_DIR" \
      --email "$ACME_EMAIL" \
      --server https://acme-v02.api.letsencrypt.org/directory \
      --domains "$PUBIP" \
      --key-type EC256 \
      --profile shortlived \
      --http \
      --http.address :80 \
      --http.delay 3s \
      --cert.timeout 120; then
    die "ACME issuance failed. Ensure inbound TCP/80 is reachable from the internet."
fi

install -m 644 "$ACME_DIR/certificates/${PUBIP}.crt" "$CERT_DIR/server.crt"
install -m 640 "$ACME_DIR/certificates/${PUBIP}.key" "$CERT_DIR/server.key"
chown root:"$SERVICE_USER" "$CERT_DIR/server.crt" "$CERT_DIR/server.key"

SPKI_PIN="$(openssl x509 -in "$CERT_DIR/server.crt" -pubkey -noout \
          | openssl pkey -pubin -outform der \
          | openssl dgst -sha256 -binary | base64)"
# --- 10. Install the systemd service ----------------------------------------
info "Installing systemd units..."
cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=VanChuz proxy server (Shadowsocks-2022 + Hysteria 2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vpssvc
Group=vpssvc
ExecStart=/usr/local/bin/sing-box run -c /opt/vps/config/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

# Bind privileged ports (<1024).
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
# AF_NETLINK is required by sing-box for interface auto-detection.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
ReadOnlyPaths=/opt/vps

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 3

if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 20 --no-pager
    die "sing-box failed to start."
fi
info "sing-box is running"

# --- 11. Install certificate auto-renewal -----------------------------------
cat > "$INSTALL_DIR/renew-cert.sh" <<'RENEW'
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="$(cat /opt/vps/.pubip)"
CERT_DIR="/opt/vps/certs"
ACME_DIR="/opt/vps/lego"
ACME_EMAIL="$(cat /opt/vps/.acme-email)"
exec 9>/opt/vps/.renew.lock
flock -n 9 || exit 0
lego run --accept-tos --path "$ACME_DIR" --email "$ACME_EMAIL" \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --domains "$DOMAIN" --key-type EC256 --profile shortlived \
  --http --http.address :80 --http.delay 3s --cert.timeout 120
install -m 644 "$ACME_DIR/certificates/${DOMAIN}.crt" "$CERT_DIR/server.crt"
install -m 640 "$ACME_DIR/certificates/${DOMAIN}.key" "$CERT_DIR/server.key"
chown root:vpssvc "$CERT_DIR/server.crt" "$CERT_DIR/server.key"
systemctl restart sing-box
openssl x509 -in "$CERT_DIR/server.crt" -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
RENEW
chmod 755 "$INSTALL_DIR/renew-cert.sh"
echo "$PUBIP"      > "$INSTALL_DIR/.pubip"
echo "$ACME_EMAIL" > "$INSTALL_DIR/.acme-email"

cat > /etc/systemd/system/renew-cert.service <<'UNIT'
[Unit]
Description=Renew the Let's Encrypt IP certificate and reload sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/vps/renew-cert.sh
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
UNIT

cat > /etc/systemd/system/renew-cert.timer <<'UNIT'
[Unit]
Description=Twice-daily check for Let's Encrypt IP certificate renewal

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now renew-cert.timer >/dev/null 2>&1 || true
# --- 12. Produce the client bundle -----------------------------------------
# A single base64 blob the user pastes into the Windows client installer.
BUNDLE=$(printf '%s\n%s\n%s\n%s\n%s' "$PUBIP" "$SS_KEY" "$HY2_PASSWORD" "$HY2_OBFS" "$SPKI_PIN" | base64 -w0)

cat <<EOF

${BOLD}=====================================================${NC}
${GREEN}  VanChuz server installed successfully${NC}
${BOLD}=====================================================${NC}

  Server IP     : ${BOLD}${PUBIP}${NC}
  Transports    : Shadowsocks-2022 / TCP/443
                  Hysteria 2      / UDP/443
  Certificate   : Let's Encrypt (IP address, 6-day profile)
  Auto-renewal  : enabled (twice daily)

${BOLD}  Next step${NC} - on your Windows machine run:

    .\\install-client.ps1 -Bundle <paste the bundle below>

${BOLD}  Client bundle (base64):${NC}

$BUNDLE

${BOLD}  IMPORTANT${NC} Save this bundle somewhere safe. It contains
  your proxy credentials. Anyone holding it can use your server.

${BOLD}  NOTE${NC} Your cloud provider must allow inbound TCP/443,
  UDP/443 and (briefly, during renewal) TCP/80.

EOF