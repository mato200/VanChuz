# What an inspecting proxy can and cannot see

**Written for the administrators.**

This document describes the limits of TLS inspection, based on how the
mechanism actually works. It is here because the most useful thing a security
team can do is know precisely where their controls stop - and there is no
shame in a boundary being a boundary.

Everything below is a property of the *technique*, not of any particular
vendor or network. Replace "gateway" with your appliance.

---

## 1. The one-sentence version

> A TLS-inspecting gateway can categorise traffic **only** when it can read
> the URL. Any protocol that carries its own encryption inside the TLS session
> removes that ability entirely, and the traffic becomes opaque.

---

## 2. What inspection does give you

When TLS interception is working correctly, the gateway can see:

- the **full URL** of every HTTPS request, including path and query string;
- the **hostname** of every connection, and therefore the category;
- the **size and timing** of every transfer;
- uploads and form posts, since it re-encrypts the whole stream;
- the **client certificate** and TLS metadata, if your endpoints use them.

With an explicit proxy it also sees the `CONNECT` target and the proxy
authentication identity of the user.

This is genuinely valuable and is why TLS inspection is deployed at all. The
findings below are about the *edges*, not the core.

---

## 3. Boundary 1 - encrypted protocols are opaque

A protocol with its own encryption layer (Shadowsocks-2022, Hysteria 2,
WireGuard, VLESS, Trojan with its own cipher, ...) presents the gateway with
ciphertext after it terminates TLS.

**What the gateway sees:** connection metadata and byte counts.

**What it does not see:** URLs, hostnames, content, or category.

**Consequence:** category filtering, reputation scoring and block-lists do not
apply. A category filter is a filter over URLs; if there are no URLs, there is
nothing to filter.

**Mitigations, in rough order of cost:**

1. **Block the protocols themselves.** Detect known handshake patterns at the
   gateway and block them. This works but is a moving target - the handshake
   can be made to look like random noise.
2. **Treat "opaque" as a category.** Anything that decrypts to something that
   is not a recognisable protocol is suspicious by construction. The cost is
   false positives on legitimate traffic that is not TLS.
3. **Allow-list destinations.** Permit only the categories you need and
   default-deny everything else. Far more effective than block-listing, and
   it removes the dependence on being able to classify.

Option 3 is the real answer. Any inspection scheme is a bet that you will
always be able to read what passes through it, and that bet is not safe.

---

## 4. Boundary 2 - certificate pinning

If a client pins the expected public key, a substituted certificate is
rejected at the handshake. The session fails rather than being decrypted.

**What the gateway sees:** a failed handshake. No content, and a TLS error
rather than a clean block page.

**Consequence:** pinned traffic is invisible to inspection. But pinning is
rare in general-purpose software, so in practice this affects a small
fraction of traffic - mostly browsers and applications with their own update
mechanisms.

**Mitigation:** you cannot unpin traffic from the gateway side without
breaking the pinned application. Manage the trust store instead:

- keep the corporate CA in a store that is **not** the system store, so
  applications that pin are not silently broken by a stray root certificate;
- ensure the endpoints you manage do not accept arbitrary user-installed
  roots;
- on managed endpoints, prefer **client certificates** and network
  authentication over relying solely on interception.

---

## 5. Boundary 3 - QUIC and UDP

HTTP/3 runs over QUIC, which carries its own TLS 1.3 handshake. A gateway that
only understands TLS over TCP has two options:

- **pass the UDP through** - the QUIC session is never inspected, and it
  looks exactly like the browser traffic it is;
- **drop the UDP** - the client falls back to TCP/443 and is then inspected
  normally.

Both outcomes are common. The dangerous one is the first. Note that QUIC
encryption is *not* weaker than TLS - it is a different, well-specified
handshake. The problem is purely that the gateway does not parse it.

**Mitigation:** either drop UDP egress, or implement QUIC inspection with the
same category and SSL-inspection policy you apply to TCP/443. Modern
gateways can do this; many deployments have simply not turned it on.

This is the single highest-value item on the list, because it is a
configuration switch rather than a research project.

---

## 6. Boundary 4 - the `DIRECT` fallback

A very common flaw in PAC files is a trailing fallback:

```javascript
return "PROXY proxy1.example:9090 ; PROXY proxy2.example:9090 ; DIRECT";
```

If the proxy pool is unreachable, slow, or a hostname fails to resolve, the
client silently connects **directly**, with no inspection and no user
indication.

**Consequence:** enforcement is not reliable. Whether a site is blocked
depends on transient infrastructure state, which is both a security gap and a
support nightmare - users will report "the internet is broken sometimes".

**Mitigation:** remove the `DIRECT` fallback, or replace it with an explicit
`PROXY` that fails closed. Log proxy failures and surface them.


---

## 7. Boundary 5 - multiple egress paths

A workstation that can reach the internet over more than one path - a wired
LAN, a VPN, a phone tether, a home connection - will be inspected
differently on each, if they are inspected at all.

**Consequence:** the policy that applies is the policy of whichever path the
routing table happens to select for that destination, which is not something
the user chose and is often not something they can see.

**Mitigation:** apply identical policy across every egress path, and treat
unmanaged egress (tethering, personal hotspots) as a policy bypass. On
managed endpoints, this usually means extending the same PAC and the same
inspection configuration to the VPN concentrator and any sanctioned mobile
access path.

---

## 8. Boundary 6 - endpoint agents are not network inspection

An EDR agent or a managed browser extension reports on the **host**. A tunnel
does not change what an agent running on the host can see.

If your control objective is "this device must not access this category",
network inspection is one layer and the endpoint agent is another. Assess them
separately. A user who can install an agent or a browser extension can
usually bypass an agent-based control anyway, which is why network-layer
enforcement remains relevant - but the two should not be confused with each
other.

---

## 9. Summary

| Control | Survives a well-implemented tunnel? |
|---|---|
| URL category filtering | **No** - there is no URL to categorise |
| Block-lists / reputation | **No** - same reason |
| Traffic volume / timing analysis | **Yes** - metadata is still visible |
| TLS interception / content visibility | **No** - only ciphertext is exposed |
| Certificate pinning | **No** - the substituted cert is rejected |
| QUIC inspection (if not enabled) | **No** - the handshake is not parsed |
| Endpoint agent / EDR | **Yes** - it runs on the host, not the network |
| Blocking the server address | **Yes** - trivially effective |

---

## 10. Recommendations

1. **Fail closed.** Remove `DIRECT` fallbacks from PAC files. Cheapest fix,
   largest immediate effect.
2. **Police UDP or inspect QUIC.** One configuration switch, closes a whole
   transport class.
3. **Treat opaque traffic as a category**, and default-deny rather than
   block-list.
4. **Unify policy across every egress path**, including tethering and VPN.
5. **Move the corporate CA out of the system trust store** so that pinned
   applications fail visibly rather than being silently intercepted.
6. **Instrument your own blind spots.** Log connections to unknown ports and
   long-lived opaque tunnels. You cannot filter what you cannot identify.
7. **Prefer allow-listing over block-listing**, and treat the inspection
   capability as one signal among several rather than a guarantee.

---

## 11. Reproducing these findings yourself

Every boundary above can be verified without special tooling:

- **Encrypted-protocol opacity:** run a tunnel to a host you control, then
  look at what the gateway logs. The URL will be absent.
- **Pinning:** open a TLS connection to a host with a pinned key through the
  gateway. The handshake fails.
- **QUIC:** send a UDP datagram to an arbitrary internet destination and
  check whether it arrives. Then compare with the same test over TCP.
- **`DIRECT` fallback:** request the same URL repeatedly while the proxy pool
  is degraded, and observe whether the block page appears consistently.

A `tcpdump` on your own server is enough to show exactly what the middlebox
forwarded.
