# Troubleshooting

## Client says "sing-box.exe missing"

The client was not installed, or `bin\sing-box.exe` was deleted. Run the
installer again:

```powershell
.\install-client.ps1 -Bundle "<your bundle>"
```

## Client says "sing-box exited immediately"

Read the log it prints. The usual causes:

| Message | Cause | Fix |
|---|---|---|
| `bind: permission denied` | Port 1080 already in use | Stop the other proxy: `Get-Process sing-box \| Stop-Process -Force` |
| `address already in use` | Another instance is running | Same as above |
| `unknown field "..."` | Config was edited by hand | Re-run the installer to regenerate `config.json` |

## "Tunnel did not come up"

Work through these in order.

**1. Is the server reachable?**

```powershell
Test-NetConnection <your-server-ip> -Port 443
```

If this fails, the problem is upstream of the proxy:

- the cloud provider's **security list** may not allow TCP/443. Remember that
  the OCI/host firewall is a *separate* layer from the guest's `iptables`.
- your network may block outbound TCP/443. Try from a different network.

**2. Is the server's service running?**

```bash
sudo systemctl status sing-box
sudo journalctl -u sing-box -n 40
```

**3. Has the certificate expired?**

The certificate is a 6-day Let's Encrypt IP certificate. Check:

```bash
sudo openssl x509 -in /opt/vps/certs/server.crt -noout -dates
```

If it is close to expiry, force a renewal:

```bash
sudo /opt/vps/renew-cert.sh
```

**4. Did the client configuration drift from the server?**

The client pins the server's public key. If the certificate was reissued,
the pin changes and the pinned client will refuse the new certificate.

Compare them:

```powershell
# client side - the pin in your config
(Get-Content .\config.json -Raw | ConvertFrom-Json).outbounds |
    Where-Object { $_.tls.certificate_public_key_sha256 } |
    ForEach-Object { $_.tls.certificate_public_key_sha256 }
```

```bash
# server side - the current pin
sudo openssl x509 -in /opt/vps/certs/server.crt -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

If they differ, re-run `install-client.ps1` with the original bundle. (The
Shadowsocks transport does not use the pin, so the default transport keeps
working even when the pin is stale.)

---

## Hysteria 2 works but Shadowsocks does not (or the reverse)

They are independent transports on the same port number, so one can work while
the other does not.

| Symptom | Likely cause |
|---|---|
| Hysteria 2 fails, Shadowsocks works | UDP is blocked or dropped on your network. This is common - many corporate networks allow TCP/443 but discard UDP. Use Shadowsocks. |
| Shadowsocks fails, Hysteria 2 works | TCP/443 to that destination is filtered, or the server's firewall is missing the TCP rule. Check `sudo iptables -L INPUT -n`. |

The client's `selector` outbound controls which is used. Edit `config.json` and
change `"default"` in the `proxy` selector, then restart.

---

## The proxy works but a specific site does not

**Does DNS resolve?** If the app resolves the name locally and your local
resolver refuses it, it will fail. Make sure the app is using SOCKS5 with
**"Proxy DNS when using SOCKS v5"** enabled (Firefox), or that DNS is going
through the tunnel.

**Is it a QUIC/HTTP3 problem?** Some sites behave differently over HTTP/3.
If a site loads partially, try forcing TCP-only in the browser.

**Check the server log** while you reproduce it:

```bash
sudo journalctl -u sing-box -f
```

If you see the outbound connection and the site still fails, the problem is
between the server and the site, not in your client.

---

## "Proxy Authentication Required" (HTTP 407)

Your network uses an authenticated proxy and the application is trying to use
it directly. Either:

- configure the app with explicit proxy credentials, or
- point the app at the local SOCKS5 endpoint instead, which handles the
  upstream proxy for you.

---

## The server certificate will not issue

The ACME HTTP-01 challenge needs **inbound TCP/80** to reach the server
briefly. Check:

```bash
sudo iptables -L INPUT -n | grep 80
curl -sI http://<your-server-ip>/ | head -1
```

The `curl` must come from **outside** your server. Also make sure the cloud
provider's security list allows TCP/80.

If port 80 cannot be opened, use the DNS-01 challenge instead (this needs
control of a domain's DNS, so it is not available in the pure-IP setup).

---

## SSH to the server is blocked

Some networks block outbound TCP/22 while permitting TCP/443. Two options:

**1. Use the mobile-tether route** (Windows):

```powershell
.\vps-route.cmd          # pin the server address to the tether
```

**2. Use the tunnel itself** - since the tunnel exits at the server, you can
reach its SSH service through it:

```powershell
ssh -o ProxyCommand="ncat -X 5 -x 127.0.0.1:1080 127.0.0.1 22" ubuntu@127.0.0.1
```

---

## Checking what is actually happening

**On the client:**

```powershell
.\start-proxy.ps1 -Status
Get-Content "$env:USERPROFILE\Documents\VanChuz\logs\proxy.log" -Tail 30
```

**On the server:**

```bash
sudo journalctl -u sing-box -f
sudo ss -tulnp | grep sing-box
```

**On the wire:**

```bash
sudo tcpdump -i any -nn 'tcp port 443' | head -50
```

If you see a TLS ClientHello with a ServerName you did not expect, something
in the path is intercepting.
