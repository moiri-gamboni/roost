---
confidence: likely
status: draft
importance: 8
tags: [travel-vpn, xray, singbox, reality, shadowsocks-2022, protonvpn, cloudflare, china, grapheneos, roost]
date: 2026-04-20
---

# Travel-VPN Architecture Plan (v3)

## Revision history

- **v1** (deprecated): VLESS+WS+TLS two-path with Caddy + certbot DNS-01. Dropped after research: WS deprecated, REALITY was blocked Nov 2025 (RU) and March 2026 (CN), multi-protocol failover now standard.
- **v2** (deprecated): Three-protocol stack using VLESS+XHTTP+REALITY. Dropped after doc verification: **sing-box stable v1.13.x does not support XHTTP outbound** (alpha-only); CF Tunnel + XHTTP stream-up is unreliable per community reports; ProtonVPN public API is deprecated so speedtest isn't possible.
- **v3** (this document): VLESS+WebSocket+TLS behind CF, VLESS+gRPC+REALITY direct, SS-2022. sing-box-native on all ends. Full IPv6 parity. Proton via single manual config. Reboot-state preserving.

---

## Goal

Ship a toggleable travel-mode providing (a) GFW-resistant SSH + browsing access from Android (GrapheneOS) phone and Linux laptop during a 1-month China trip, (b) toggleable ProtonVPN egress for both travel-via-Xray and normal-use-via-Tailscale-exit-node, (c) minimal permanent attack surface, (d) independent path diversity so a single protocol block doesn't strand the user, (e) reboot-safe state so server updates in-country don't break access.

## Architecture summary

Xray-core exposes three concurrent inbounds (plus dedicated SSH variants): VLESS+WebSocket+TLS behind Cloudflare Tunnel (Path A), VLESS+gRPC+REALITY on port 443 direct (Path B), Shadowsocks-2022 on ports 51820/51821 (Path C). sing-box on the phone uses urltest to auto-select the fastest working path. ProtonVPN WireGuard is a policy-routed egress layer (fwmark + masked xmark to avoid clashing with Tailscale's mark), covering both Xray-originated and Tailscale-exit-node forwarded traffic, with IPv4 and IPv6 parity. Kill-switch tied to Proton toggle (installed in PostUp with rollback trap). Hetzner firewall toggles 443/51820/51821 (TCP v4 + v6) during travel via laptop-side helper. No Caddy and no certs in the travel path.

**Tech stack:** Xray-core v26.x, sing-box v1.13.x (Android + Linux), wg-quick + systemd, cloudflared (existing), jq, hcloud CLI (laptop), ProtonVPN WireGuard config.

---

## 1. Decision Record

### Chosen architecture

| Decision | Choice | Rejected | Crux |
|---|---|---|---|
| Path A transport | VLESS + WebSocket + TLS (behind CF Tunnel) | XHTTP stream-up (sing-box doesn't support + CF unreliable), gRPC+CF (CF rate-limits) | sing-box and Xray both support WS natively; CF has first-class WS support; TLS terminated at CF so no XHTTP fingerprint advantage matters here |
| Path B transport | VLESS + gRPC + REALITY (no Vision) | XHTTP+REALITY (sing-box doesn't support XHTTP), TCP+REALITY+Vision (Vision targeted Nov 2025), WS+REALITY (less common pattern) | gRPC over REALITY is sing-box-native, 2026 consensus without Vision |
| Path C transport | Shadowsocks-2022 chacha20-poly1305 | Hysteria2 (UDP DPI since Jan 2025), Trojan (dead) | Consistently survived Nov 2025 and March 2026 waves |
| REALITY dest | `www.samsung.com` | `dl.google.com` (burned 2024), `www.icloud.com` (official warn), CF-fronted sites | Not CF-fronted; high legit traffic; consumer-electronics ASN distinct from Hetzner reduces anomaly signal |
| REALITY shortIds | 4 varying-length hex (even-length, **min 4 chars / 2 bytes**, max 16) | 1-byte shortIds (trivially collidable with random bytes); single shortId | If one burned, blackhole server-side without full key rotation; 2-byte min for probe-resistance |
| Vision flow | Not used | `xtls-rprx-vision` | Deprecated as default per Nov 2025 Russia + Feb 2026 community consensus |
| IPv6 coverage | Full parity (dual-stack Xray + dual-stack fwmark/routing/kill-switch) | IPv4-only | Hetzner has IPv6; leak otherwise; GFW lighter on IPv6 in some provinces |
| Caddy involvement | None (travel path) | Caddy terminating TLS on 443 | REALITY self-terminates; SS-2022 no TLS; CF terminates for Path A → cloudflared speaks plain HTTP to Xray on loopback |
| Caddy + port 443 | Explicit `auto_https off` in Caddyfile | Relying on `default_bind $TAILSCALE_IP` | `default_bind` does NOT prevent ACME/redirect listeners from binding 0.0.0.0; explicit disable required |
| Egress isolation | fwmark 0x1337 + **masked xmark** `--set-xmark 0x1337/0x0000ffff` | Full-word `--set-mark` | Full-word overwrites Tailscale's 0xff0000 mark bits, silently breaking Tailscale forwarding |
| rp_filter | Explicit `sysctl -w net.ipv4.conf.{all,wg-proton}.rp_filter=2` in PostUp | Relying on distro default | Distro may silently flip via future hardening sysctl snippets |
| Kill-switch lifecycle | Installed/removed by wg-quick PostUp/PreDown with rollback trap | Persistent at xray.service | Matches "kill-switch is part of vpn-on" model; trap catches mid-PostUp failures |
| Client (Android) | sing-box for Android (SFA v1.13.8+), GitHub releases | F-Droid (lag risk), v2rayNG (SOCKS5 IP-leak vuln + XHTTP concerns) | GitHub SFA tracks upstream; TUN-only config avoids SOCKS5 vuln; stable XHTTP-free transport stack |
| Client (Linux laptop) | sing-box CLI with TUN + local SOCKS5 inbound on 127.0.0.1:1080 | `sing-box tools connect` per-invocation | SOCKS5 bind to loopback only; used for SSH ProxyCommand via `nc -X5 -x 127.0.0.1:1080 %h %p` |
| Client failover | sing-box urltest — 3min interval, 200ms tolerance, self-hosted probe | gstatic.com probe (partially blocked in CN), 50ms tolerance (flip-flop on cross-continental jitter) | Self-hosted `/probe` endpoint on Path A returns 204; 200ms tolerance reduces path churn |
| Path priority | urltest picks by speed, not by survival-likelihood | Explicit selector with A > B > C priority | Urltest's failover-on-failure is equivalent: a dead path gets dropped automatically; explicit priority would sacrifice speed without added robustness |
| Normal-use mode | Tailscale exit-node advertised from Roost | Xray-always-running at home | Tailscale faster/cleaner at home; same fwmark rules serve both |
| Proton config | One manually-downloaded file at `/etc/wireguard/proton.conf` | Speedtest-driven country rotation via API | Proton public API deprecated 2024; no API-token config generation; simpler and matches 1-month trip scope |
| CLI (server) | `roost-net {status,travel on/off,vpn on/off,test,client,rotate-keys}` | `roost-travel`, `--travel` flag on roost-apply | Unified network control; extensible; independent toggles |
| CLI (laptop) | `roost-net-fw {open,close,status}` with IPv6 support | Server-side hcloud | Token on laptop only; dual-stack FW toggle |
| Reboot state | `travel` persists (files + FW); `vpn` persists via `systemctl enable --now wg-quick@proton` | Manual re-enable after reboot | Needed for "update + reboot server in China" scenario |
| Tailscale backend | Pin to iptables mode (not nftables) | Auto-detect | Known fwmark mask discrepancy between Tailscale backends; pinning makes our rules deterministic |
| Android client distribution | Tailscale file transfer + QR via `qrencode` | Subscription URL | Secrets don't transit public internet; one-time transfer at home |

### Rejected approaches (v3)

- **Sing-box XHTTP (tracks alpha)**: v1.14.0-alpha.x has XHTTP but alpha isn't appropriate for a trip where failure is high-cost.
- **v2rayNG on Android**: uses Xray-core natively (supports XHTTP), but SOCKS5 IP-leak vulnerability is unpatched as of April 2026. Using v2rayNG with TUN-only is possible but less clean than sing-box TUN-only.
- **Vision + REALITY**: Vision flow specifically targeted in Nov 2025 wave. Community consensus in 2026 is to default to REALITY without Vision.
- **Per-country Proton speedtest**: Proton public API deprecated; python-proton-vpn-api-core requires SRP login + 2FA on server. Not worth the complexity for 1-month trip.
- **Netns isolation for Proton**: fwmark approach handles both Xray and forwarded-traffic; netns adds veth bridging for marginal benefit.
- **Always-on Xray with always-open 443**: loses "exposure only during travel" requirement.

### Red-team concerns (v2 + doc verification + v3 red-team) addressed

Additional v3 red-team fixes in this revision:
- **C1 Two Xray inbounds on :443**: single inbound per transport; route by destination (port 22 → ssh outbound); see §2.4
- **C2 UFW blocks travel ports**: `roost-net travel on/off` adds/removes UFW rules for 443/tcp, 51820/tcp+udp
- **C3 CF 100s WS idle timeout**: `wsSettings.heartbeatPeriod: 30` on server + sing-box reads WS pings
- **C4 Boot-order leak window**: `xray-boot-guard` ExecStartPre blocks xray startup until wg-proton + kill-switch present (when vpn=on)
- **I5/I8 urltest couples all paths to CF**: probe URL is `gstatic.com/generate_204` (not on our infrastructure); DNS for our own hostnames forced through CF DoH so GFW can't hijack
- **I6 Proton-keepalive restart loop**: `proton-keepalive-check` with 5min debounce + handshake-age short-circuit
- **I7 Endpoint parsing fragile**: parse `Endpoint=` from `/etc/wireguard/proton.conf` then `getent ahostsv{4,6}` — handles hostnames, literal v4, literal v6
- **I9 HETZNER_PUBLIC_IP singular vs dual**: client configs use `travel-direct.$DOMAIN` (DNS with A+AAAA) instead of raw IPs
- **Tailscale pin syntax**: `Environment=TS_DEBUG_FIREWALL_MODE=iptables` in systemd drop-in (not `--config`)
- **ncat dependency**: explicitly install via `apt install nmap`; plan's ssh config uses `ncat --proxy-type socks5`, not `nc -X 5`
- **M14 1-byte shortIds**: min 4 hex chars (2 bytes) for probe resistance; sizes 4/8/12/16
- **M15 JSON quoting in state.env**: `REALITY_SHORT_IDS='["abcd",...]'` single-quoted
- **M18 country change docs**: added to playbook

### Earlier red-team concerns still addressed

| Concern | Resolution |
|---|---|
| sing-box lacks XHTTP | Switched Path A to WebSocket, Path B to gRPC — both sing-box-native |
| CF Tunnel XHTTP unreliable | Path A uses WS (CF first-class support) |
| ProtonVPN API deprecated | Drop speedtest; user manually provides one config |
| Vision targeted | Dropped; use bare REALITY |
| fwmark overwrites Tailscale bits | Use `--set-xmark 0x1337/0x0000ffff` (masked) |
| Tailscale fwmark differs between iptables/nftables backends | Pin Tailscale to iptables mode |
| Kill-switch partial install on PostUp failure | `trap 'proton-routing.sh down' ERR` in PostUp |
| rp_filter drift | Explicit sysctl in PostUp for interface + all |
| IPv6 leak channel | Full v6 parity: ip6tables rules, ip -6 rule entries, IPv6 routing table, Proton v6 endpoint |
| `sudo cp` breaks ownership | `install -m 0644 -o $USER -g $USER` instead |
| Caddy may grab 443 via ACME | `auto_https off` in Caddyfile |
| urltest probes gstatic (partially blocked) | Self-hosted `/probe` endpoint via Path A returns 204 |
| `sing-box tools connect` ambiguity | Use loopback SOCKS5 inbound + `nc -X5 -x` pattern (simpler, better-documented) |
| REALITY single shortId | Generate 4 shortIds of varying length |
| SS-2022 password format | `openssl rand -base64 32` (canonical) |
| wg-proton silent failure | `proton-keepalive.timer` (30s probe, restart on fail) |
| Hetzner 2FA single-device risk | Recovery codes printed + stored offline (Aegis is only the TOTP app; codes are separate) |
| Reboot state loss | `systemctl enable --now wg-quick@proton` on vpn on; CF fragment + FW rules already persist |
| Non-interactive shell alias | Symlink `~/bin/roost-net -> roost-net.sh` (not alias) |
| sing-box F-Droid lag | Document GitHub releases as primary install source |
| state.env corruption | Validate with `xray run -test -c /etc/xray/config.json` before service restart |
| Xray access log growth | logrotate config in `/etc/logrotate.d/xray` |

---

## 2. Architecture

### 2.1 Use modes (four modes, two toggles)

| Mode | Phone transport | `roost-net travel` | `roost-net vpn` | Phone egress IP | Laptop egress IP |
|---|---|---|---|---|---|
| Home, normal | ISP direct | off | off | ISP | ISP |
| Home, private | Tailscale exit node | off | on | Proton | Proton (if exit-node selected) |
| Travel | Xray A/B/C (urltest) | on | off | Hetzner | Hetzner |
| Travel, private | Xray A/B/C | on | on | Proton | Proton |

### 2.2 Data flow

**Travel path (phone, three concurrent paths, sing-box urltest picks):**

```
Phone (sing-box TUN)
  ├── Path A: VLESS+WS+TLS → CF edge → cloudflared → Xray on 127.0.0.1:10000
  ├── Path B: VLESS+gRPC+REALITY → 0.0.0.0:443 → Xray REALITY inbound
  └── Path C: SS-2022 → 0.0.0.0:51820 → Xray SS inbound

All paths → Xray routing → outbound `direct-proton` (fwmark 0x1337/mask)
  → kernel: fwmark → Proton table (if vpn on) OR main table (if vpn off)
  → wg-proton → Proton server → Internet
     OR eth0 → Hetzner → Internet
```

**Home path (Tailscale exit node):**

```
Phone (Tailscale as system VPN, exit node = Roost)
  → tailscale0 on server → FORWARD chain marks fwmark 0x1337 (xmark masked)
  → kernel: fwmark → Proton table (if vpn on) OR main table (if vpn off)
  → wg-proton → Proton → Internet
     OR eth0 → Hetzner → Internet
```

Same fwmark rule serves both modes. One vpn toggle, both use cases.

### 2.3 State persistence across reboot

| Component | Mechanism | Reboot behavior |
|---|---|---|
| `xray.service` | `systemctl enable` at install | Always starts on boot |
| `travel=on`: CF Tunnel ingress fragment | File at `~/roost/cloudflared/apps/travel.yml` | Persists; cloudflared picks up on boot |
| `travel=on`: Hetzner firewall rules | External to server | Persist (cloud firewall survives VM lifecycle) |
| `vpn=on`: `wg-quick@proton.service` | `systemctl enable --now` at vpn-on | Starts on boot, re-installs routing/kill-switch via PostUp |
| `vpn=on`: Policy routing + kill-switch | iptables/ip rule set by wg-quick PostUp | Re-applied each boot via systemd |
| `tailscale --advertise-exit-node` | tailscaled state dir | Persists |

**Implication for "update + reboot server in China":** after reboot, the server comes back up with the same travel+vpn state. All paths are reachable. User does nothing.

### 2.4 Xray inbound layout

**One inbound per transport; SSH vs browse distinguished by destination inside Xray routing** (dual-inbound-on-same-port doesn't work; Xray rejects at startup).

| Tag | Protocol | Listen | Port | Purpose |
|---|---|---|---|---|
| `ws-cf` | VLESS+WS (no TLS — CF does TLS) | 127.0.0.1 | 10000 | Path A (both browse + SSH) |
| `reality` | VLESS+gRPC+REALITY | :: (dual-stack) | 443 | Path B (both browse + SSH) |
| `ss2022` | Shadowsocks-2022 | :: (dual-stack) | 51820 | Path C (both browse + SSH) |

Routing (same across all inbounds):
- destination `127.0.0.1:22` → `ssh` outbound (freedom to local sshd)
- default → `direct-proton` outbound (fwmark-tagged for egress policy)

Clients reach SSH by connecting through the VPN to `localhost:22` — Xray routes to the local sshd via the ssh outbound; browsing traffic goes to the direct-proton outbound where fwmark+wg-proton handles Proton egress.

Advantage: no port collisions, fewer inbounds to rotate UUIDs for, cleaner client config (no `-ssh` path suffix).

### 2.5 fwmark + IPv6 policy routing

```
# IPv4
ip route replace default dev wg-proton table 51820
ip rule add to <proton-endpoint-v4> lookup main priority 50
ip rule add fwmark 0x1337 lookup 51820 priority 200
ip rule add fwmark 0x1337 unreachable priority 300

# IPv6 parity
ip -6 route replace default dev wg-proton table 51820
ip -6 rule add to <proton-endpoint-v6> lookup main priority 50
ip -6 rule add fwmark 0x1337 lookup 51820 priority 200
ip -6 rule add fwmark 0x1337 unreachable priority 300

# Mark traffic (masked so Tailscale's 0xff0000 bits survive):
iptables -t mangle -I OUTPUT  -m owner --uid-owner xray -j MARK --set-xmark 0x1337/0x0000ffff
iptables -t mangle -I FORWARD -i tailscale0 ! -d 100.64.0.0/10 -j MARK --set-xmark 0x1337/0x0000ffff
ip6tables -t mangle -I OUTPUT  -m owner --uid-owner xray -j MARK --set-xmark 0x1337/0x0000ffff
ip6tables -t mangle -I FORWARD -i tailscale0 ! -d fd7a:115c:a1e0::/48 -j MARK --set-xmark 0x1337/0x0000ffff

# Kill-switch (dual-stack):
iptables -I OUTPUT 1 -m owner --uid-owner xray ! -o wg-proton ! -o lo -j REJECT
iptables -I FORWARD 1 -i tailscale0 ! -d 100.64.0.0/10 ! -o wg-proton -j REJECT
ip6tables -I OUTPUT 1 -m owner --uid-owner xray ! -o wg-proton ! -o lo -j REJECT
ip6tables -I FORWARD 1 -i tailscale0 ! -d fd7a:115c:a1e0::/48 ! -o wg-proton -j REJECT

# rp_filter explicit:
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.wg-proton.rp_filter=2
```

All of the above in `proton-routing.sh up`, reversed in `down`. A `trap 'proton-routing.sh down' ERR` at the top of `up` catches partial failures.

---

## 3. Component Design

### 3.1 New files

```
files/setup/travel-vpn.sh                    # Installer: Xray, wireguard-tools, jq, xray user, systemd tailscale pin
files/travel/
├── xray-config.json.tmpl                    # Generates /etc/xray/config.json
├── xray.service                             # Simple systemd unit
├── xray-logrotate.conf                      # /etc/logrotate.d/xray
├── travel-cloudflare.yml.tmpl               # CF Tunnel fragment (only copied when travel on)
├── wg-proton.service.d/roost.conf           # Drop-in: BindsTo, kill-switch sanity
├── proton-routing.sh                        # PostUp/PreDown; dual-stack fwmark + kill-switch + rp_filter
├── proton-keepalive.service                 # Oneshot watchdog
├── proton-keepalive.timer                   # 30s interval
├── proton.conf.example                      # Template documentation
├── travel-health.sh                         # Sourced by health-check-apps.sh
└── keys-init.sh                             # Generates REALITY x25519 keypair, 4 shortIds, UUID, SS-2022 passwords

files/hooks/roost-net.sh                     # Server CLI

files/laptop/roost-net-fw.sh                 # Laptop: open/close Hetzner FW (dual-stack: 443/tcp, 51820/tcp+udp)
files/laptop/travel-test.sh                  # Laptop: end-to-end tests with --simulate-gfw
files/laptop/travel-clients.sh               # Laptop: generate sing-box JSON (Android + laptop)

~/bin/roost-net -> /home/$USER/roost/claude/hooks/roost-net.sh     # Symlink, works in non-interactive shells
```

### 3.2 Modified files

| File | Change |
|---|---|
| `files/hooks/roost-apply.sh` (manifest 93-133) | Add entries for all travel/ files. Export `XRAY_UUID`, `XRAY_PATH_BROWSE`, `XRAY_PATH_SSH`, `REALITY_PRIVATE_KEY`, `REALITY_SHORT_IDS` (JSON array), `SS2022_PASSWORD_BROWSE`, `SS2022_PASSWORD_SSH`, `DOMAIN`, `HETZNER_PUBLIC_IPV4`, `HETZNER_PUBLIC_IPV6` to `render_file()`. Add `--xray` and `--proton` flag-mode service reloads. |
| `deploy.sh` | Add `section "Travel VPN"` after cloudflare. Add `DOMAIN`, `HETZNER_PUBLIC_IPV4`, `HETZNER_PUBLIC_IPV6` to sync-env heredoc. |
| `test-server.sh` | Add `--- Travel VPN ---` section. |
| `files/shell/bashrc.sh` | Drop existing alias (if any); symlink is preferred |
| `files/Caddyfile` | Add `auto_https off` in global options block; explicit `http://` scheme on existing apps.caddy import if needed |
| `files/hooks/dangerous-command-blocker.py` | Add `roost-net travel on`, `roost-net vpn on`, `roost-net rotate-keys` to confirmation-required patterns |
| `files/cron-roost` | Weekly kill-switch audit (only when vpn on); weekly Proton config staleness check |
| `files/setup/tailscale.sh` | After `tailscale up`: `tailscale set --advertise-exit-node`; pin iptables backend via systemd drop-in setting `Environment=TS_DEBUG_FIREWALL_MODE=iptables` (verified: `--netfilter-mode=iptables` is another valid form on newer builds) |
| `files/setup/ufw.sh` | Verify no interaction with travel INPUT rules |
| `CLAUDE.md` | Add "Travel VPN" section, App-Specific Extensions row |
| `README.md` | Quickstart, use-modes diagram, client install (GitHub SFA), emergency recovery (Hetzner console 2FA recovery codes) |

### 3.3 Key config snippets

**`files/travel/xray-config.json.tmpl`**

```json
{
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log"},
  "inbounds": [
    {
      "tag": "ws-cf",
      "listen": "127.0.0.1", "port": 10000, "protocol": "vless",
      "settings": {"clients": [{"id": "${XRAY_UUID}"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/${XRAY_PATH}",
          "heartbeatPeriod": 30
        }
      }
    },
    {
      "tag": "reality",
      "listen": "::", "port": 443, "protocol": "vless",
      "settings": {"clients": [{"id": "${XRAY_UUID}"}], "decryption": "none"},
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "${GRPC_SERVICE_NAME}"},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "www.samsung.com:443",
          "xver": 0,
          "serverNames": ["www.samsung.com"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ${REALITY_SHORT_IDS}
        }
      }
    },
    {
      "tag": "ss2022",
      "listen": "::", "port": 51820, "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-chacha20-poly1305",
        "password": "${SS2022_PASSWORD}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct-proton",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": {"sockopt": {"mark": 4919}}
    },
    {"tag": "ssh", "protocol": "freedom"},
    {"tag": "blackhole", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["127.0.0.1/32", "::1/128"], "port": "22", "outboundTag": "ssh"},
      {"type": "field", "outboundTag": "direct-proton"}
    ]
  }
}
```

Notes:
- `wsSettings.heartbeatPeriod: 30` — server sends WS ping every 30s to keep CF Tunnel connection alive (CF free tier has 100s idle timeout; [cloudflared#1282](https://github.com/cloudflare/cloudflared/issues/1282))
- `"listen": "::"` dual-binds IPv4 + IPv6 on Linux (IPV6_V6ONLY=0 default)
- Routing: connection to `127.0.0.1:22` (from client through tunnel) → ssh outbound → local sshd; everything else → direct-proton with fwmark. Client reaches SSH by connecting through the VPN to `localhost:22`

**`files/travel/xray.service`**

```ini
[Unit]
Description=Xray Service
After=network-online.target
Wants=network-online.target
ConditionFileIsExecutable=/usr/local/bin/xray

[Service]
User=xray
Group=xray
Type=simple
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecStartPre=/usr/local/bin/xray run -test -c /etc/xray/config.json
ExecStartPre=/usr/local/bin/xray-boot-guard
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

`CAP_NET_ADMIN` is required for `sockopt.mark` (SO_MARK). `ExecStartPre` with `-test` validates config before starting — catches state.env corruption.

**`/usr/local/bin/xray-boot-guard`** (root-owned, 0755) — prevents boot-order leak:

```bash
#!/bin/bash
# If vpn is supposed to be on, block xray startup until wg-proton is up and
# kill-switch installed. Prevents Xray accepting connections and leaking via
# Hetzner IP before proton-routing.sh PostUp completes.
[ "$(cat /etc/roost-travel/vpn 2>/dev/null)" != "on" ] && exit 0
for i in {1..30}; do
  if ip link show wg-proton up >/dev/null 2>&1 && \
     iptables -S OUTPUT | grep -q 'owner UID match.*REJECT'; then
    exit 0
  fi
  sleep 1
done
logger -t roost/xray-boot-guard "Timeout waiting for wg-proton + kill-switch; failing"
exit 1
```

If vpn=on and wg-proton isn't up with kill-switch in place within 30s, Xray fails to start → `Restart=on-failure` retries in 10s → by then wg-quick@proton should have come up.

**`files/travel/proton-routing.sh`** (dual-stack, with rollback trap)

```bash
#!/bin/bash
set -euo pipefail

ACTION="$1"
WG_IFACE="wg-proton"
TABLE=51820
FWMARK="0x1337"
MASK="0x0000ffff"
XRAY_UID=$(id -u xray)
TS_SUBNET_V4="100.64.0.0/10"
TS_SUBNET_V6="fd7a:115c:a1e0::/48"

on_error() {
  logger -t roost/proton-routing "ERROR at line $1, rolling back"
  "$0" down || true
}

case "$ACTION" in
  up)
    trap 'on_error $LINENO' ERR

    # rp_filter explicit
    sysctl -qw net.ipv4.conf.all.rp_filter=2
    sysctl -qw "net.ipv4.conf.${WG_IFACE}.rp_filter=2" 2>/dev/null || true

    # Endpoint exclusion — parse from config, not wg show (more robust)
    ENDPOINT_HOST=$(awk -F'= *' '/^Endpoint/ {print $2}' /etc/wireguard/proton.conf | sed 's/:[0-9]*$//')
    # Strip brackets if IPv6 literal
    ENDPOINT_HOST=${ENDPOINT_HOST#[}; ENDPOINT_HOST=${ENDPOINT_HOST%]}
    # Resolve (getent handles literal IPs and hostnames); v4 and v6 separately
    ENDPOINT_V4=$(getent ahostsv4 "$ENDPOINT_HOST" 2>/dev/null | awk 'NR==1 {print $1}' || echo "")
    ENDPOINT_V6=$(getent ahostsv6 "$ENDPOINT_HOST" 2>/dev/null | awk 'NR==1 {print $1}' || echo "")
    [ -n "$ENDPOINT_V4" ] && ip rule add to "$ENDPOINT_V4" lookup main priority 50
    [ -n "$ENDPOINT_V6" ] && ip -6 rule add to "$ENDPOINT_V6" lookup main priority 50

    # Default route in Proton table (v4 + v6)
    ip route replace default dev "$WG_IFACE" table "$TABLE"
    ip -6 route replace default dev "$WG_IFACE" table "$TABLE" 2>/dev/null || true

    # Policy: marked packets use Proton table
    ip rule add fwmark "$FWMARK" lookup "$TABLE" priority 200
    ip -6 rule add fwmark "$FWMARK" lookup "$TABLE" priority 200

    # Fallback: marked without route → unreachable
    ip rule add fwmark "$FWMARK" unreachable priority 300
    ip -6 rule add fwmark "$FWMARK" unreachable priority 300

    # Mark Xray outbound (v4 + v6, masked)
    iptables -t mangle -I OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}"
    ip6tables -t mangle -I OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}"

    # Mark Tailscale exit-node forwarded traffic (v4 + v6)
    iptables -t mangle -I FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" -j MARK --set-xmark "${FWMARK}/${MASK}"
    ip6tables -t mangle -I FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" -j MARK --set-xmark "${FWMARK}/${MASK}"

    # Kill-switch (v4 + v6, OUTPUT + FORWARD)
    iptables -I OUTPUT 1 -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT
    iptables -I FORWARD 1 -i tailscale0 ! -d "$TS_SUBNET_V4" ! -o "$WG_IFACE" -j REJECT
    ip6tables -I OUTPUT 1 -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT
    ip6tables -I FORWARD 1 -i tailscale0 ! -d "$TS_SUBNET_V6" ! -o "$WG_IFACE" -j REJECT

    trap - ERR
    logger -t roost/proton-routing "up: endpoint_v4=$ENDPOINT_V4 endpoint_v6=$ENDPOINT_V6 uid=$XRAY_UID mask=$MASK"
    ;;

  down)
    # All best-effort; never fail
    set +e
    ENDPOINT_V4=$(wg show "$WG_IFACE" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | grep -v ':' || echo "")
    ENDPOINT_V6=$(wg show "$WG_IFACE" endpoints 2>/dev/null | awk '{print $2}' | sed -n 's/\[\([^]]*\)\].*/\1/p' || echo "")

    [ -n "$ENDPOINT_V4" ] && ip rule del to "$ENDPOINT_V4" lookup main priority 50 2>/dev/null
    [ -n "$ENDPOINT_V6" ] && ip -6 rule del to "$ENDPOINT_V6" lookup main priority 50 2>/dev/null

    ip rule del fwmark "$FWMARK" lookup "$TABLE" priority 200 2>/dev/null
    ip rule del fwmark "$FWMARK" unreachable priority 300 2>/dev/null
    ip -6 rule del fwmark "$FWMARK" lookup "$TABLE" priority 200 2>/dev/null
    ip -6 rule del fwmark "$FWMARK" unreachable priority 300 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null
    ip -6 route flush table "$TABLE" 2>/dev/null

    iptables -t mangle -D OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
    ip6tables -t mangle -D OUTPUT -m owner --uid-owner "$XRAY_UID" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
    iptables -t mangle -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null
    ip6tables -t mangle -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" -j MARK --set-xmark "${FWMARK}/${MASK}" 2>/dev/null

    iptables -D OUTPUT -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT 2>/dev/null
    iptables -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V4" ! -o "$WG_IFACE" -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m owner --uid-owner "$XRAY_UID" ! -o "$WG_IFACE" ! -o lo -j REJECT 2>/dev/null
    ip6tables -D FORWARD -i tailscale0 ! -d "$TS_SUBNET_V6" ! -o "$WG_IFACE" -j REJECT 2>/dev/null

    logger -t roost/proton-routing "down: rules removed"
    ;;
esac
```

**`files/travel/proton-keepalive.service`** (with debouncing to prevent restart-loop leak windows)

```ini
[Unit]
Description=Proton WireGuard keepalive probe
ConditionPathExists=/sys/class/net/wg-proton
After=wg-quick@proton.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/proton-keepalive-check
```

**`/usr/local/bin/proton-keepalive-check`** (root, 0755):

```bash
#!/bin/bash
# Debounced Proton health check. Skips restart if:
#  - Recent wg handshake (within 180s — tunnel is working at protocol level)
#  - Recent restart (within 300s — avoid restart-loop if endpoint dead)
set -uo pipefail
STATE_DIR=/etc/roost-travel
LAST_RESTART_FILE=$STATE_DIR/.proton-last-restart

# Recent handshake = tunnel is live; skip probe
LAST_HS=$(wg show wg-proton latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
NOW=$(date +%s)
if [ -n "$LAST_HS" ] && [ "$((NOW - LAST_HS))" -lt 180 ]; then
  exit 0
fi

# Run probe
if curl -sf --max-time 5 --interface wg-proton https://api.ipify.org >/dev/null; then
  exit 0
fi

# Probe failed. Check debounce window.
LAST_RESTART=$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo 0)
if [ "$((NOW - LAST_RESTART))" -lt 300 ]; then
  logger -t roost/proton-keepalive "Probe failed but last restart <5min ago; skipping"
  exit 0
fi

logger -t roost/proton-keepalive "Probe failed and debounce expired; restarting wg-quick@proton"
echo "$NOW" > "$LAST_RESTART_FILE"
systemctl restart wg-quick@proton
```

Prevents the restart-loop-leak-window pattern: if Proton endpoint is genuinely dead, we restart at most once per 5 minutes instead of every 30s.

**`files/travel/proton-keepalive.timer`**

```ini
[Unit]
Description=Proton WireGuard keepalive (30s)
Requires=proton-keepalive.service

[Timer]
OnBootSec=2m
OnUnitActiveSec=30s
Unit=proton-keepalive.service

[Install]
WantedBy=timers.target
```

**`files/travel/travel-cloudflare.yml.tmpl`** (deployed to `/etc/roost-travel/` source only; copied to `~/roost/cloudflared/apps/travel.yml` when `travel on`)

```yaml
  - hostname: travel.${DOMAIN}
    service: http://127.0.0.1:10000
    originRequest:
      noTLSVerify: true
      httpHostHeader: travel.${DOMAIN}
  - hostname: travel.${DOMAIN}
    path: /probe
    service: http_status:204
```

(Note: both ingress rules have same hostname but different paths — CF Tunnel routes `/probe` to a 204 response for urltest; everything else to Xray. This is the self-hosted probe endpoint that replaces gstatic.com.)

Actually, cloudflared ingress rules are matched in order with path taking precedence. Correct structure:

```yaml
  - hostname: travel.${DOMAIN}
    path: /probe
    service: http_status:204
  - hostname: travel.${DOMAIN}
    service: http://127.0.0.1:10000
    originRequest:
      noTLSVerify: true
      httpHostHeader: travel.${DOMAIN}
```

First match wins; `/probe` returns 204 without touching Xray.

**`files/hooks/roost-net.sh`** (key subcommands; ~250 lines total)

```bash
# Key bits only — full file in implementation

case "$subcmd" in
  travel)
    case "${1:?on|off}" in
      on)
        [ -f "$STATE_DIR/travel-cloudflare.yml" ] || die "Source fragment missing — reinstall"
        # CF fragment
        sudo install -m 0644 -o "$USER" -g "$USER" \
          "$STATE_DIR/travel-cloudflare.yml" "$CF_INGRESS"
        sudo "$HOME/roost/claude/hooks/cloudflare-assemble.sh"
        sudo systemctl restart cloudflared
        # UFW rules (Hetzner FW isn't the only layer — UFW defaults to deny)
        sudo ufw allow 443/tcp comment 'travel-vpn-reality'
        sudo ufw allow 51820/tcp comment 'travel-vpn-ss2022'
        sudo ufw allow 51820/udp comment 'travel-vpn-ss2022'
        echo "on" | sudo tee "$STATE_DIR/travel" >/dev/null
        ntfy_send -t "Travel ON" "Path A exposed + UFW open. Run 'roost-net-fw open' on laptop."
        ;;
      off)
        sudo rm -f "$CF_INGRESS"
        sudo "$HOME/roost/claude/hooks/cloudflare-assemble.sh"
        sudo systemctl restart cloudflared
        sudo ufw --force delete allow 443/tcp 2>/dev/null || true
        sudo ufw --force delete allow 51820/tcp 2>/dev/null || true
        sudo ufw --force delete allow 51820/udp 2>/dev/null || true
        echo "off" | sudo tee "$STATE_DIR/travel" >/dev/null
        ntfy_send -t "Travel OFF" "Close laptop FW via: roost-net-fw close"
        ;;
    esac
    ;;

  vpn)
    case "${1:?on|off}" in
      on)
        [ -f /etc/wireguard/proton.conf ] || die "No /etc/wireguard/proton.conf"
        # Enable + start, so it survives reboot
        sudo systemctl enable --now wg-quick@proton || {
          sudo systemctl disable wg-quick@proton 2>/dev/null
          die "wg-quick@proton failed"
        }
        # Verify egress ASN
        local ip
        ip=$(sudo -u xray curl -sf --max-time 10 --interface wg-proton https://api.ipify.org) || {
          sudo systemctl disable --now wg-quick@proton
          die "Egress verification failed"
        }
        is_proton_asn "$ip" || {
          sudo systemctl disable --now wg-quick@proton
          die "Egress $ip is not Proton ASN"
        }
        sudo systemctl enable --now proton-keepalive.timer
        echo "on" | sudo tee "$STATE_DIR/vpn" >/dev/null
        ntfy_send -t "VPN ON" "Egress: $ip"
        ;;
      off)
        sudo systemctl disable --now proton-keepalive.timer 2>/dev/null || true
        sudo systemctl disable --now wg-quick@proton 2>/dev/null || true
        echo "off" | sudo tee "$STATE_DIR/vpn" >/dev/null
        ntfy_send -t "VPN OFF" "Hetzner egress"
        ;;
    esac
    ;;

  status) ... ;;
  test) ... ;;
  client) ... ;;
  rotate-keys) ... ;;
esac
```

**`files/travel/xray-logrotate.conf`**

```
/var/log/xray/*.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  sharedscripts
  postrotate
    systemctl kill -s HUP xray.service 2>/dev/null || true
  endscript
}
```

**Caddy modification** (`files/Caddyfile`, global block):

```
{
    email admin@$DOMAIN
    default_bind $TAILSCALE_IP
    auto_https off
}
```

Ensures Caddy never tries to grab :443 for ACME/redirect.

**sing-box Android client** (emitted by `roost-net client android`):

```json
{
  "log": {"level": "info"},
  "dns": {
    "servers": [
      {"tag": "cf-doh", "address": "https://1.1.1.1/dns-query", "detour": "direct"},
      {"tag": "block", "address": "rcode://refused"}
    ],
    "rules": [
      {"domain": ["travel.${DOMAIN}", "travel-direct.${DOMAIN}"], "server": "cf-doh"}
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "inet6_address": "fdfe:dcba:9876::1/126",
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"},
    {"type": "dns", "tag": "dns-out"},
    {
      "type": "urltest",
      "tag": "urltest",
      "outbounds": ["path-a", "path-b", "path-c"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": "200ms"
    },
    {
      "type": "vless",
      "tag": "path-a",
      "server": "travel.${DOMAIN}", "server_port": 443,
      "uuid": "${XRAY_UUID}",
      "tls": {"enabled": true, "server_name": "travel.${DOMAIN}",
              "utls": {"enabled": true, "fingerprint": "chrome"}},
      "transport": {
        "type": "ws",
        "path": "/${XRAY_PATH}",
        "max_early_data": 0
      }
    },
    {
      "type": "vless",
      "tag": "path-b",
      "server": "travel-direct.${DOMAIN}", "server_port": 443,
      "uuid": "${XRAY_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "www.samsung.com",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "${REALITY_PUBLIC_KEY}",
                    "short_id": "${REALITY_SHORT_ID_0}"}
      },
      "transport": {"type": "grpc", "service_name": "${GRPC_SERVICE_NAME}"}
    },
    {
      "type": "shadowsocks",
      "tag": "path-c",
      "server": "travel-direct.${DOMAIN}", "server_port": 51820,
      "method": "2022-blake3-chacha20-poly1305",
      "password": "${SS2022_PASSWORD}"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {"protocol": "dns", "outbound": "dns-out"},
      {"ip_cidr": ["0.0.0.0/0", "::/0"], "outbound": "urltest"}
    ]
  }
}
```

**Probe URL rationale**: `gstatic.com/generate_204` resolved via CF DoH (not ISP DNS → no GFW hijack risk). Each path probes independently through its own outbound. If all three outbounds can reach CF's gstatic, they all pass; if one is blocked, that one fails without affecting others. If gstatic itself becomes unreachable from CN (rare but possible), we fall back to configurable URL via `roost-net` CLI flag.

**DNS resolution**: `travel.$DOMAIN` and `travel-direct.$DOMAIN` forced through CF DoH so GFW DNS pollution can't black-hole config resolution. `travel-direct.$DOMAIN` has both A (Hetzner IPv4) and AAAA (Hetzner IPv6) records → sing-box picks appropriate family.

**WS idle timeout mitigation**: server sends heartbeats every 30s (`wsSettings.heartbeatPeriod`); sing-box reads them and connection stays alive through CF's 100s idle timer.

**Laptop sing-box config** (same outbounds as phone, plus loopback SOCKS5 for SSH ProxyCommand; single inbound set, no dedicated SSH outbounds since we route by destination):

```json
{
  "inbounds": [
    {"type": "tun", "tag": "tun-in", ...},
    {"type": "socks", "tag": "local-socks", "listen": "127.0.0.1", "listen_port": 1080, "users": []}
  ],
  "outbounds": [/* same path-a/b/c + urltest as phone */],
  "route": {
    "rules": [
      {"protocol": "dns", "outbound": "dns-out"},
      {"inbound": ["local-socks"], "outbound": "urltest"},
      {"ip_cidr": ["0.0.0.0/0", "::/0"], "outbound": "urltest"}
    ]
  }
}
```

SOCKS5 inbound on `127.0.0.1:1080` only (not exposed). SSH requests routed through same urltest as browsing — Xray server's destination-based routing sends `localhost:22` to the ssh outbound automatically.

**SSH ProxyCommand** (`~/.ssh/config`):

```
Host roost-travel
  HostName localhost
  Port 22
  User ${USERNAME}
  ProxyCommand ncat --proxy 127.0.0.1:1080 --proxy-type socks5 %h %p
```

Use `ncat` from `nmap` package (`apt install nmap`) — it has reliable SOCKS5 support. Default Ubuntu `nc` (netcat-openbsd) does NOT support `-X 5 -x` syntax reliably; `ncat` is the portable choice.

---

## 4. Test Strategy

### 4.1 Layers

| Layer | Location | Trigger | Purpose |
|---|---|---|---|
| Deploy validation | `test-server.sh` | After `./deploy.sh` | Files, binary, systemd units, state.env populated |
| Config validation | `xray run -test` in ExecStartPre | Xray service start | Fails loudly on state.env corruption |
| Activation | `roost-net test` | After `vpn on` | Proton up, egress ASN, rules present, fwmark mask correct |
| Path validation | `files/laptop/travel-test.sh` | Pre-departure | All three paths, SSH-over-each, urltest converges, IPv6 parity |
| GFW sim | `travel-test.sh --simulate-gfw` | Pre-departure | UDP blocked on laptop, TCP paths still work |
| Tailscale coexistence | `files/laptop/travel-test.sh --tailscale-check` | Pre-departure | `tailscale status` healthy after vpn on/off cycles; exit-node routes via Proton when enabled |
| Watchdog | `proton-keepalive.timer` | 30s | Auto-restarts wg-proton on silent failure |
| Health | `travel-health.sh` via health-check.sh | Continuous | Egress drift, kill-switch presence, cert expiry (n/a for v3) |

### 4.2 Critical assertions

**fwmark masking (highest-stakes test)**:
```
ip6tables -t mangle -S | grep xray | grep -q '0x1337/0xffff'   # masked xmark
iptables -t mangle -S | grep xray | grep -q '0x1337/0xffff'
```
Must show `/0xffff` suffix. Without mask = Tailscale bits wiped.

**Tailscale mark preserved**:
After `vpn on`, forward a test packet via tailscale0, capture with `tcpdump -n` and `nft list ruleset | grep ts-forward` shows Tailscale's mark still applied.

**Kill-switch when vpn on**:
- `sudo -u xray curl --max-time 5 https://api.ipify.org` (no --interface): times out/REJECTed
- `sudo -u xray curl --max-time 5 --interface wg-proton https://api.ipify.org`: returns Proton IP

**Kill-switch when vpn off**:
- Same curl: returns Hetzner IP (fall-through intended)

**IPv6 kill-switch**:
- `curl -6 --max-time 5 https://api64.ipify.org` from the `xray` uid when vpn on: blocked
- Same when vpn off: returns Hetzner IPv6

**Reboot scenario**:
- With travel=on, vpn=on: reboot server
- On boot: xray starts, wg-quick@proton starts (was enabled), routing + kill-switch reapplied, all paths reachable
- Test from laptop: all green after reboot

**urltest converges on probe endpoint**:
- `sing-box` on Android connects; `urltest` picks Path A (primary) within 30s when Path A works
- Disable Path A temporarily (FW rule close): urltest falls over to Path B

**REALITY masquerade**:
- `openssl s_client -connect <IP>:443 -servername www.samsung.com -CAfile /etc/ssl/certs/ca-certificates.crt`: returns real Samsung cert chain (valid, not our cert)

### 4.3 External validation (irreplaceable)

The laptop-side GFW sim is insufficient. Before departure:
1. Post on ntc.party with disposable UUID, ask for CN smoke-test
2. Or: purchase 1 GB Bright Data CN residential, run sing-box config through SOCKS5
3. Or: check-host.cc/tcp/china for basic reachability check of direct IP+port

Also: verify sing-box v1.13.x on Android GitHub releases supports the exact config format before departure — run it at home first for a week.

---

## 5. Implementation Phases

### Phase 0: Spike tests (before building anything)

**Task 0.1:** CF Tunnel + WS + Xray on loopback with keepalive
- [ ] Minimal Xray config: one WS inbound on 127.0.0.1:10000 with `wsSettings.heartbeatPeriod: 30`
- [ ] Minimal cloudflared ingress: `http://127.0.0.1:10000`
- [ ] From laptop: `curl -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: test" https://travel.$DOMAIN/test` → expect WS upgrade headers
- [ ] **Critical**: establish WS connection via sing-box, leave idle 5 minutes. Verify connection survives CF's 100s idle timer (via heartbeats). If not, tune heartbeat period or add sing-box ping interval.

**Task 0.2:** sing-box v1.13.8+ on laptop speaks WS + gRPC+REALITY to Xray
- [ ] Download sing-box Linux binary from GitHub
- [ ] Write minimal client config with path-a + path-b
- [ ] Verify both outbounds reach Xray; urltest picks fastest

**Task 0.3:** fwmark mask test (most load-bearing)
- [ ] On current server, install masked xmark rule, verify Tailscale mark survives
- [ ] `conntrack -L` or `nft list ruleset` to confirm Tailscale's 0xff0000 bits preserved
- [ ] Confirm Tailscale exit-node + subnet routing still works after proton-routing.sh PostUp

**Task 0.4:** Single REALITY inbound with destination-based routing (replaces the failed two-inbound pattern)
- [ ] Single Xray inbound on :443 with REALITY+gRPC
- [ ] Routing rules: `ip: ["127.0.0.1"], port: "22"` → ssh outbound; else → direct
- [ ] Test from laptop: sing-box client sends request to `localhost:22` through path-b, Xray routes to local sshd. SSH session completes.
- [ ] Test browsing request: sing-box client requests `example.com:443` through path-b, Xray routes to direct-proton. Traffic reaches example.com.

**Task 0.5:** UFW + Hetzner firewall double-check
- [ ] Open Hetzner FW for 443, 51820 via `roost-net-fw open`
- [ ] Without UFW rules: `curl -k https://<hetzner-ip>:443` from laptop → connection refused/timeout (UFW blocks)
- [ ] Add UFW rules manually (matching what `roost-net travel on` will do) → curl succeeds

**Task 0.6:** Port conflict check
- [ ] After Xray starts: `ss -tlnp` shows port 443 held by xray (not caddy)
- [ ] Verify `caddy validate` still passes with `auto_https off`
- [ ] Verify existing Caddy-served apps (apps.caddy) still reachable via Tailscale

If any of these fail, revise architecture before Phase 1.

### Phase 1: Foundation & dormant install (4h)

- [ ] 1.1 DOMAIN in sync-env + `HETZNER_PUBLIC_IPV4/V6`
- [ ] 1.2 `files/setup/travel-vpn.sh`: installs Xray + wireguard-tools + jq + ncat + xray user + `/etc/roost-travel/` + generates UUID, one WS path, one gRPC serviceName, REALITY keypair (`xray x25519`), 4 shortIds (4,8,12,16 hex chars), one SS-2022 password (`openssl rand -base64 32`), writes `state.env` (0600 root, JSON arrays single-quoted: `REALITY_SHORT_IDS='["abcd","1a2b3c4d",...]'`). Download Xray from GitHub release with signature verification.
- [ ] 1.3 Xray config template + service + logrotate
- [ ] 1.4 Caddyfile: add `auto_https off`
- [ ] 1.5 Tailscale exit-node advertisement + iptables backend pin (systemd drop-in with `Environment=TS_DEBUG_FIREWALL_MODE=iptables`)
- [ ] 1.6 CF Tunnel fragment (source at `/etc/roost-travel/`, deployed but NOT active)
- [ ] 1.7 `~/bin/roost-net` symlink (not alias)
- [ ] 1.8 Manifest entries + `deploy.sh` section
- [ ] 1.9 `./deploy.sh`; verify: xray active, listening, FW blocks external; Tailscale exit-node offered

### Phase 2: Proton egress + watchdog (4h)

- [ ] 2.1 `files/travel/proton-routing.sh` with dual-stack + trap rollback
- [ ] 2.2 `wg-proton.service.d/roost.conf` drop-in
- [ ] 2.3 `proton-keepalive.service` + `proton-keepalive.timer`
- [ ] 2.4 User drops Proton config at `/etc/wireguard/proton.conf` (manual; document)
- [ ] 2.5 Manual test: wg-quick up proton; curl --interface wg-proton; curl default (unchanged); kill-switch blocks xray uid default-route; wg-quick down proton restores state
- [ ] 2.6 IPv6 parity test: `curl -6 --interface wg-proton` works; `curl -6` via xray uid blocked

### Phase 3: CLI (3h)

- [ ] 3.1 `files/hooks/roost-net.sh` (all subcommands)
- [ ] 3.2 `files/travel/travel-health.sh` (sourced by health-check.sh)
- [ ] 3.3 `dangerous-command-blocker.py` patterns for roost-net

### Phase 4: Laptop tooling (3h)

- [ ] 4.1 `files/laptop/roost-net-fw.sh` (dual-stack open/close: 443/tcp, 51820/tcp, 51820/udp)
- [ ] 4.2 `files/laptop/travel-clients.sh` — emits Android + laptop sing-box JSON + SSH config snippet + QR via `qrencode`
- [ ] 4.3 `files/laptop/travel-test.sh` — full assertion suite incl. --simulate-gfw and --tailscale-check

### Phase 5: Docs + hardening (2h)

- [ ] 5.1 CLAUDE.md + README.md: quickstart, use-modes diagram, reboot behavior, emergency recovery, Hetzner 2FA recovery codes (print offline)
- [ ] 5.2 Cron: weekly kill-switch audit, weekly Proton staleness check
- [ ] 5.3 Install GitHub SFA on Android; test at home for a week

### Phase 6: E2E validation (3h)

- [ ] 6.1 Clean deploy; `./test-server.sh` fully green
- [ ] 6.2 Activation cycle: travel on → vpn on → verify → vpn off → travel off → verify normal Tailscale access
- [ ] 6.3 Reboot test: with travel=on + vpn=on, reboot server, verify state fully restored on boot
- [ ] 6.4 Chaos: kill wg-proton mid-session → kill-switch REJECTs Xray outbound; proton-keepalive restarts within 30s
- [ ] 6.5 China smoke test: ntc.party post OR Bright Data residential SOCKS5 (~$10)

**Total estimate: ~19h implementation + ~1 week soak testing at home before trip.**

---

## 6. Operational Playbook

### Changing Proton country (no CLI subcommand — manual)

```bash
# On server via Tailscale SSH
sudo systemctl stop wg-quick@proton
# Download new country's config from https://account.protonvpn.com/downloads (enable IPv6)
sudo install -m 0600 -o root -g root /path/to/new.conf /etc/wireguard/proton.conf
# Edit to include PostUp/PreDown = /etc/roost-travel/proton-routing.sh {up,down} + Table = off + DNS=
sudo systemctl start wg-quick@proton
roost-net test  # verify egress IP matches new country
```

### Pre-departure (2+ weeks before)

```bash
# Server (via Tailscale SSH)
# 1. Drop Proton WG config (one country, user choice, e.g., Switzerland or nearest-to-Hetzner for latency)
# Edit /etc/wireguard/proton.conf:
#   [Interface]
#   PrivateKey = <from Proton dashboard>
#   Address = 10.2.0.2/32, fd7a::2/128  # IPv4 + IPv6
#   Table = off
#   DNS =
#   PostUp = /etc/roost-travel/proton-routing.sh up
#   PreDown = /etc/roost-travel/proton-routing.sh down
#   [Peer]
#   PublicKey = <from Proton>
#   Endpoint = <country>.protonvpn.net:51820
#   AllowedIPs = 0.0.0.0/0, ::/0

# 2. Install sing-box for Android from GitHub releases (not F-Droid — may lag)
#    Download SFA APK from github.com/SagerNet/sing-box-for-android/releases
#    Verify signature, install

# 3. Generate and distribute client configs
./files/laptop/travel-clients.sh android > /tmp/sb-android.json  
# Via Tailscale Syncthing or qrencode → phone
./files/laptop/travel-clients.sh laptop > ~/.config/sing-box/travel.json
./files/laptop/travel-clients.sh ssh >> ~/.ssh/config

# 4. Test at home for 1 week
roost-net travel on
./files/laptop/roost-net-fw.sh open
roost-net vpn on
./files/laptop/travel-test.sh
./files/laptop/travel-test.sh --simulate-gfw
# Use phone sing-box daily; browse, SSH via Termux; notice any issues

# 5. Get external CN smoke-test via ntc.party or residential proxy

# 6. Print Hetzner 2FA recovery codes, store in physical wallet/bag (NOT phone)

# 7. Pre-install ProtonVPN Android app with Stealth profile (independent fallback)

# 8. Revert to dormant state before packing
roost-net vpn off
./files/laptop/roost-net-fw.sh close
roost-net travel off
```

### Departure day

```bash
# Server (via Tailscale)
roost-net travel on    # deploys CF fragment, reloads cloudflared
roost-net vpn on       # enables wg-proton (survives reboot)

# Laptop
./files/laptop/roost-net-fw.sh open   # opens 443/tcp, 51820/tcp+udp (dual-stack)
./files/laptop/travel-test.sh         # final verification

# Phone
# Activate sing-box app (system VPN indicator appears)
# urltest auto-selects Path A
```

### In-flight (China)

- **Phone**: sing-box runs as system VPN. urltest picks fastest path automatically. Browse, use apps. For SSH: Termux with ssh command — traffic inherits sing-box TUN. ~1-2s latency overhead vs direct browsing at home.
- **Laptop**: sing-box CLI with TUN or via local SOCKS5; SSH config uses ProxyCommand. VS Code Remote-SSH works identically.
- **Server updates**: `apt upgrade && reboot` — state fully restored on boot (xray.service + wg-quick@proton.service both enabled; CF fragment persists; FW rules external).

### If something degrades mid-trip

- **Path A slow/dead**: urltest switches to B or C; no user action required.
- **All three degraded**: check sing-box logs on phone. Probably Hetzner IP blocklisted.
  - Fallback: ProtonVPN Android app with Stealth (independent of Roost; browse-only, no SSH)
  - Investigation: Hetzner Cloud Console (save URL offline!) → Web Console (works without SSH) → check Xray logs
- **Server unreachable entirely**: 
  - From laptop: `./files/laptop/roost-net-fw.sh close` (stops advertising broken endpoint)
  - Hetzner Cloud Console via 2FA + recovery codes from wallet
  - Hard reset server if needed (snapper hourly snapshots available for rollback)

### Post-return

```bash
./files/laptop/roost-net-fw.sh close
# Server (via Tailscale, now working)
roost-net vpn off
roost-net travel off
```

---

## 7. Security Considerations

### Android client

- **Install source:** GitHub releases (github.com/SagerNet/sing-box-for-android/releases). F-Droid lags; verify v1.13.8+ available.
- **TUN-only config**: no SOCKS5 inbound in Android config → sidesteps April 2026 SOCKS5 IP-leak vulnerability entirely.
- **GrapheneOS**: VPNService works normally. Network permission revocation is not needed if SOCKS5 absent (no attack surface). If user wants defense-in-depth, revoke Network permission on apps that don't need it (sandboxed Google Play, calculator apps) — but NOT on apps actively used (browser, maps) since they need networking through the TUN.

### Laptop client

- **Local SOCKS5 on 127.0.0.1:1080** for SSH ProxyCommand convenience. Loopback-only bind means no network exposure. Malicious process on laptop could use it to discover exit IP (same class of issue as mobile), but mitigation: don't install untrusted software on laptop (normal hygiene).

### hcloud token

- Laptop only. Scoped to one Hetzner project if possible (recommended: dedicated project for Roost).
- Server never sees it.

### Key rotation

- `roost-net rotate-keys` regenerates UUID + 4 shortIds + SS-2022 passwords + REALITY keypair; writes new state.env; restarts Xray; emits ntfy alert.
- Requires Tailscale-only distribution of new configs → can only be done at home (or via CF path if working), not from inside China with Tailscale blocked. Accept: if compromised mid-trip, rotate after return.

### Hetzner 2FA

Existing setup (user choice):
- Aegis on phone = daily TOTP
- Hetzner recovery key stored in Bitwarden (Bitwarden 2FA disabled)
- Bitwarden master password is the single factor for full recovery

Recovery scenarios:
- Phone lost → laptop Bitwarden → recovery key → reset Hetzner 2FA on replacement device
- Phone + laptop lost → any browser + vault.bitwarden.com + master password → recovery key
- Bitwarden master password lost → unrecoverable (deliberate tradeoff for simpler daily UX)

Pre-trip verification: in a private browser window, do the full recovery flow once (log into vault.bitwarden.com with master password only, locate Hetzner recovery key). Confirms the path works under pressure.

### Reboot update safety

- `apt upgrade && reboot` in China: state persists (see §2.3). Watch for:
  - Kernel update → reboot → Tailscale may need time to reconnect
  - sysctl rp_filter changes from unattended-upgrades: the weekly cron audit catches drift
  - Xray version update via unattended-upgrades (no — we install manually, not via apt). No auto-upgrade risk for Xray.

### Claude autonomy

- `dangerous-command-blocker.py` blocks `roost-net travel on`, `roost-net vpn on`, `roost-net rotate-keys` requiring user confirmation.
- Does not block `roost-net status` (read-only) or `roost-net travel off` / `vpn off` (safe defaults).

---

## 8. Open Questions / Future Work

- **Proton API workaround**: `python-proton-vpn-api-core` SDK exists but requires SRP auth + 2FA. If desired for programmatic country rotation, build a one-shot Python script that uses stored session token (user runs once to generate, then reuses). Defer to v4.
- **sing-box XHTTP when stable**: if mainline adds XHTTP in v1.14, revisit — XHTTP has better header padding and XMUX.
- **Hysteria2 as fourth path**: only if 3-path stack proves insufficient. QUIC + extended SNI DPI risk, but sometimes works when TCP paths all fail.
- **Hot-standby VPS**: user declined for 1-month trip. Reconsider for 3+ month trips.
- **Dedicated Hetzner project for token scoping**: user to move Roost into isolated project post-deployment.

---

## 9. Risk Summary

| Risk | Likelihood (1-month CN trip) | Impact | Mitigation |
|---|---|---|---|
| REALITY (Path B) blocked mid-trip | Medium (~25%) | Medium (A+C still work) | Multi-path + urltest |
| Path A CF-fronted blocked | Low (~5%) | High (CF is primary) | Paths B+C independent |
| SS-2022 (Path C) specifically targeted | Low (~10%) | Low (A+B still work) | Belt-and-suspenders |
| Hetzner IP blocklisted | Medium (~15%, higher during Two Sessions/Congress) | High for B+C; A survives (CF fronts) | Accept; future trips add hot-standby |
| fwmark mask bug breaks Tailscale | Very low (spike-tested Phase 0) | Critical (home-use-Tailscale dies) | Phase 0 spike test; weekly audit |
| Kill-switch bypassed by stale rule | Very low | Critical (leak when vpn on) | PostUp reinstalls; weekly audit; trap rollback |
| Proton config bitrots or Proton rotates | Medium (~20%) | Medium | Verify egress ASN at vpn on; keepalive timer |
| Hetzner 2FA loss | Low (~3%) | Critical (recovery nightmare) | Printed recovery codes offline |
| sing-box Android version incompatibility | Low (~5%) | Medium (reinstall from GitHub) | Pre-test at home for 1 week |
| GFW introduces new DPI mid-trip | Low-Medium (~15%) | High | Path diversity buffer; monitor ntc.party/Habr |
| Claude accidentally runs travel/vpn toggle | Very low (hook blocks) | Medium | dangerous-command-blocker |
| Reboot loses state | Very low (tested in Phase 6.3) | High | Explicit `enable --now` + file persistence |

---

## Implementation order

Phases 0 → 1 → 2 → 3 sequentially (dependencies). Phase 4 can parallel 3 (independent). Phases 5-6 last.

For `/praxis:implement`: Phases 0 (spike), 1-3 (coordinated sequence), 4 (parallel team), 5-6 (manual).

**Next step**: run Phase 0 spike tests before committing to rest of plan.
