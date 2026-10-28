<p align="center">
  <b>VanChuz</b><br>
  <i>A self-contained, per-app proxy that tunnels past TLS-inspecting corporate firewalls</i>
</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue.svg">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey.svg">
  <img alt="Transport" src="https://img.shields.io/badge/transport-Shadowsocks--2022%20%2F%20Hysteria%202-informational.svg">
</p>

---

## What is this?

VanChuz is a **personal proxy** you run on your own machine, pointed at a server
you own. It gives you a local `SOCKS5`/`HTTP` endpoint that individual
applications can use.

It was built to answer one question:

> *My company intercepts TLS and blocks sites by URL category.
> Can I still reach them - and can I do it per-application instead of
> re-routing my whole machine?*

**Yes.** VanChuz works by putting a second layer of encryption *inside* the
TLS session. An inspecting middlebox terminates the TLS and sees only
ciphertext - there is no URL left for it to categorise or block.

```
   app  --SOCKS5-->  127.0.0.1:1080  --Shadowsocks-2022-->  your server  -->  internet
                      (sing-box)         (own AEAD)          (TLS+pin)
                                                    ^
                                          the middlebox sees
                                          ciphertext only
```

Nothing about your machine's global networking is changed. Applications opt
in one at a time.

---

## Highlights

| | |
|---|---|
| **Per-application** | Point Firefox, Steam, a game launcher - or a single command - at `127.0.0.1:1080`. Nothing else is touched. |
| **No domain needed** | The server gets a publicly trusted certificate issued directly for its **IP address**. |
| **Auto-renewing** | The certificate renews itself twice a day. |
| **Two transports** | `Shadowsocks-2022` over TCP/443 works on restrictive networks; `Hysteria 2` over QUIC/UDP/443 is faster where UDP is allowed. |
| **Pinned** | The client pins the server's public key, so a substituted certificate fails the handshake instead of silently decrypting you. |
| **Hardened server** | Runs as an unprivileged user, `NoNewPrivileges`, `ProtectSystem=strict`, minimal capability set. |
| **One command** | A single installer script sets up the server; a single installer sets up the client. |

---

## Quick start

### 1. Server

You need a Linux VPS with a public IP. Any small instance works.

```bash
git clone https://github.com/mato200/VanChuz.git
cd VanChuz
sudo bash server/install-server.sh
```

The installer will:

1. install `sing-box` and `lego`;
2. generate a fresh Shadowsocks key and Hysteria passwords **on the server**;
3. request a Let's Encrypt certificate for your **IP address**;
4. install a hardened `systemd` service and a renewal timer;
5. print a **client bundle** (base64) containing your credentials.

> **Your cloud provider must allow inbound TCP/443, UDP/443 and TCP/80.**
> TCP/80 is needed briefly for the ACME HTTP challenge during renewal.

### 2. Client (Windows)

```powershell
git clone https://github.com/mato200/VanChuz.git
cd VanChuz\client
.\install-client.ps1 -Bundle "<paste the bundle from step 1>"
```

This downloads `sing-box`, writes the configuration, and creates three Desktop
shortcuts:

| Shortcut | What it does |
|---|---|
| **VanChuz Proxy - START** | Starts the proxy and verifies it works |
| **VanChuz Proxy - STOP** | Stops it |
| **VanChuz Proxy - STATUS** | Shows whether it is running and your current egress IP |

### 3. Point an app at it

The local proxy is `127.0.0.1:1080` (SOCKS5 **and** HTTP).

| Application | How |
|---|---|
| **Firefox** | Settings &rarr; General &rarr; Network Settings &rarr; *Manual proxy configuration* &rarr; SOCKS Host `127.0.0.1`, Port `1080`, tick **"Proxy DNS when using SOCKS v5"** |
| **Steam** | Settings &rarr; Downloads &rarr; *Proxy Settings* &rarr; SOCKS5, `127.0.0.1`, `1080` |
| **Chrome / Edge** | Launch with `--proxy-server="socks5://127.0.0.1:1080"` |
| **VS Code** | Settings &rarr; `http.proxySupport` &rarr; `override` and `http.proxy` &rarr; `socks5://127.0.0.1:1080` |
| **git** | `git config --global http.proxy socks5://127.0.0.1:1080` |
| **curl / python / npm** | `export ALL_PROXY=socks5://127.0.0.1:1080` |

---

## Repository layout

```
server/
  install-server.sh      one-shot server installer
client/
  install-client.ps1     one-shot client installer
  start-proxy.ps1        start / stop / status
  vps-route.ps1          optional: pin the server to a mobile tether
docs/
  how-it-works.md        the design, in detail
  troubleshooting.md     when things do not work
  assessment.md          what an inspecting proxy can and cannot see
```

---

## How the bypass works

A TLS-inspecting firewall works like this: it terminates your HTTPS session,
reads the URL, decides whether to allow it, and re-encrypts. If the corporate
root certificate is installed on your machine, your browser accepts the
substituted certificate without complaint.

VanChuz defeats that in three independent ways:

1. **A second crypto layer.** Shadowsocks-2022 and Hysteria 2 each encrypt the
   payload themselves. The middlebox decrypts the outer TLS and finds only
   ciphertext. There is no URL, so there is nothing to categorise.
2. **Certificate pinning.** The client pins the server's public key. If the
   middlebox substitutes its own certificate, the handshake **fails** instead
   of quietly decrypting your traffic.
3. **Transport choice.** `Hysteria 2` speaks QUIC, which many inspecting
   firewalls do not parse at all.

See [`docs/how-it-works.md`](docs/how-it-works.md) for the full picture.

---

## Ethics and scope

VanChuz is a **dual-use** tool. It exists because restrictive corporate
networks are a real thing, and because network administrators deserve to know
exactly where their inspection stops working.

- Use it on networks you are authorised to use, and only where you have
  permission to.
- Prefer the **per-app** configuration over a system-wide VPN. The whole point
  of this project is to minimise the blast radius.
- If you are the administrator: the interesting content is in
  [`docs/assessment.md`](docs/assessment.md) - it describes what an inspecting
  proxy can and cannot see, and what you can do about it.

---

## License

MIT - see [LICENSE](LICENSE).