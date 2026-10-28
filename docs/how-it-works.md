# How VanChuz works

This document explains the design, the crypto, and *why* each piece is there.
It is written so you can reason about it rather than just trust it.

---

## 1. The problem

A corporate web gateway typically works in one of two ways:

**Explicit proxy.** A PAC file tells the browser to send everything to a proxy
pool. The proxy decides, from the URL, whether to allow the request.

**Transparent interception.** Traffic is redirected into the gateway's port 443
and the TLS session is terminated there. The gateway re-signs the certificate
with its own CA and forwards the request.

Both approaches depend on one thing: **being able to read the URL.** That is
the whole basis of category filtering - "Games", "Social Media", "Adult", and
so on.

If the gateway can terminate TLS, it can also see everything else in the
session: which sites you visit, what you upload, what you type into forms.
This is why TLS interception is controversial even when the policy is benign.

---

## 2. The three defences

### 2.1 An inner crypto layer

This is the primary mechanism.

```
  plaintext  --AEAD-->  ciphertext  --TLS-->  ciphertext  --TLS-->  plaintext
              (Shadowsocks)            (to your server)    (from your server)
```

The outer TLS is terminated by the gateway, which recovers the
**Shadowsocks ciphertext**. It cannot read it: Shadowsocks-2022 uses
`2022-blake3-aes-128-gcm`, a per-session key derived from a PSK with
BLAKE3, and every message carries an authentication tag.

The gateway's options are all bad for it:

- **Block it** - you lose the proxy, but it has to block *all* of TCP/443 to
  your server, which means blocking a large amount of unrelated traffic.
- **Pass it** - and it has no idea what is inside. No URL, no hostname, no
  category to match. It is now a blind pipe.
- **Throttle it** - visible as an anomaly, but not a policy decision it can
  justify.

The point is not that the gateway is *stupid*. The point is that **a filter
which can only reason about URLs has nothing to reason about.**

### 2.2 Certificate pinning

Pinning is the second line of defence, and it protects you against a gateway
that decides to be cleverer.

The client is configured with the server's **SubjectPublicKeyInfo** hash:

```json
"tls": {
  "certificate_public_key_sha256": ["<base64 SHA-256 of the server public key>"]
}
```

If the gateway substitutes a certificate of its own, the public key does not
match the pin, and the handshake fails. You get a connection error rather than
a quietly decrypted session.

Note that pinning only protects the **TLS** layer. The Shadowsocks layer is
already independently encrypted, so even a gateway that *could* read the
outer TLS would learn nothing. The two layers are independent - that is the
point.

### 2.3 Transport choice

| Transport | Wire format | Use when |
|---|---|---|
| `Shadowsocks-2022` | TCP/443 | The default. Works anywhere TCP/443 is permitted, including restrictive networks that block or drop UDP. |
| `Hysteria 2` | QUIC over UDP/443 | Faster, and the QUIC handshake is often not inspected at all. Needs UDP to be permitted. |

Hysteria 2 additionally **parrots Chrome's QUIC handshake** (the sing-box
client does this by default), so the QUIC fingerprint looks like a browser's
rather than an unusual client's. It also supports Salamander obfuscation,
which pads packets to defeat simple traffic-shape analysis.

The client exposes both through a `selector` outbound, so you can switch at
runtime without restarting anything.

---

## 3. No domain required

Normally you would need a domain name to get a TLS certificate. You do not
have to.

**Let's Encrypt now issues certificates for bare IP addresses**, under a
6-day "shortlived" profile:

```bash
lego run --accept-tos --path ./acme --email you@example.com \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --domains 203.0.113.10 \
  --key-type EC256 --profile shortlived \
  --http --http.address :80
```

The result is a publicly trusted certificate whose SAN is an `IP Address`.
No domain purchase, no DNS configuration, no email on a domain you own.

The profile is short-lived by design (maximum 7 days), so **renewal has to be
automated**. VanChuz installs a `systemd` timer that checks twice a day and
re-issues only when the certificate is close to expiry. `lego` reuses the
existing authorisation, so this is cheap and quiet.

> Use **ECDSA (EC256)**, not Ed25519. The Chrome-parroting QUIC mode used by
> Hysteria 2 does not advertise Ed25519 support, so a server presenting an
> Ed25519 certificate will fail to handshake with a Chrome-parroting client.


---

## 4. The server

```
/opt/vps/
  bin/            sing-box, lego
  certs/          server.crt, server.key   (root:vpssvc, key mode 640)
  config/         config.json              (root:vpssvc, mode 640)
  lego/           ACME account + issued certificates
  renew-cert.sh   renewal script
```

The service runs as the unprivileged `vpssvc` user with a deliberately narrow
sandbox:

| Setting | Why |
|---|---|
| `NoNewPrivileges=true` | The service cannot gain privileges. |
| `ProtectSystem=strict` | The whole filesystem is read-only except explicit paths. |
| `PrivateTmp=true` | No shared `/tmp`. |
| `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` | The only capability is binding port 443. |
| `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK` | Only the address families actually needed. (`AF_NETLINK` is required by sing-box for interface auto-detection.) |

The private key is `root:vpssvc` mode `640` - the service can read it, nothing
else can.

---

## 5. The client

```
client/
  bin/sing-box.exe
  config.json        generated by install-client.ps1 (git-ignored)
  start-proxy.ps1    start / stop / status
```

`config.json` is generated locally and **never committed** - it contains your
credentials. The `.gitignore` excludes it.

The client exposes a **mixed** inbound on `127.0.0.1:1080`, which speaks both
SOCKS5 and HTTP proxy on the same port. Most applications understand one or
the other; you do not need to care which.

DNS is handled by sing-box: queries from tunnelled applications are resolved
through the tunnel (`1.1.1.1` over DoH) rather than locally, so a domain that
your local resolver refuses to answer still works.

---

## 6. Optional: the mobile-tether route

Some networks block outbound TCP/22 while permitting TCP/443. If you need SSH
to your server from such a network, `vps-route.ps1` adds a single `/32` host
route so that **only** the server address uses your phone's USB tether:

```powershell
.\client\vps-route.cmd          # pin (needs Administrator)
.\client\vps-route.cmd -Remove  # unpin
```

Windows prefers the longest matching prefix, so a `/32` always beats the
default route regardless of interface metrics. Everything else keeps using
the normal network.

The tether adapter is a phone USB-NDIS device whose address is assigned by
DHCP and changes on every replug, so the script re-detects the adapter and its
current gateway each time it runs.

This is a convenience for administration. **The proxy itself does not need it** -
Shadowsocks over TCP/443 works on the normal network.

---

## 7. What this does *not* protect you from

Being honest about limits:

- **Traffic volume and timing are visible.** The gateway still sees how many
  bytes you move and when. There is no padding in Shadowsocks-2022.
- **The endpoint is still yours.** A managed device with an EDR agent reports
  what the agent can see, regardless of the tunnel.
- **The server operator can see your traffic.** It is their server. Do not use
  a server you do not control for anything you would not put in the clear on
  a hostile network.
- **Blocking the server IP is trivial.** If the gateway is configured to block
  your server's address, the tunnel stops working. VanChuz does not rotate
  endpoints.
- **This does not defeat a device-management policy.** It evades network
  inspection, not an agent on the host.

---

## 8. Related reading

- [`assessment.md`](assessment.md) - what an inspecting proxy can and cannot
  see, written for the administrators who have to defend the network.
- [`troubleshooting.md`](troubleshooting.md) - the common failure modes and
  what to check.
