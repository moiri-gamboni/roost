# travel/ — travel VPN server pieces

Root CLAUDE.md has the overview (four paths, the mode table, the `roost-net` verbs). README has the human playbook (pre-departure, departure day, mid-trip degradation, return). `docs/runbooks/` has the procedures that get re-run: `singbox-client-deploy.md`, `path-d-vision.md`. This file is the design and state reference for editing the pieces. Full rationale: `plans/add-stealth-protocols.md`, `plans/dns-architecture.md`, `plans/singbox-dns-bootstrap-fix.md`.

## Files

- `xray.service`, `xray-boot-guard` (ExecStartPre: blocks Xray until `wg-proton` + the kill-switch REJECT rule are present, closing the boot-order leak window), `xray-logrotate.conf`, `xray-config.json.tmpl` (rendered by `roost-apply --xray` from `state.env`).
- `keys-init.sh` — generates `/etc/roost-travel/state.env` (REALITY keypair, UUID, SS-2022 password, shortIds, gRPC service name, WS path, Hetzner public v4/v6 for the Path B bind). Refuses to overwrite; `--force` rotates, `--backfill` only adds missing keys.
- `proton-routing.sh` — wg-quick PostUp/PreDown: dual-stack fwmark policy routing + kill-switch; `ensure` re-applies ip rules + the proton-table route idempotently (self-heal).
- `proton-keepalive.service`/`.timer` + `proton-keepalive-check` — debounced watchdog (30s).
- `proton-routing-ensure.service`/`.timer` — `ensure` every 5m: catches ip-rule flushes (systemd re-exec etc.) that iptables survives but ip rules don't.
- `proton-routing-after-networkd.service` — `WantedBy=systemd-networkd.service`: re-runs `ensure` after every networkd start/restart. Closes the needrestart gap: iproute2/kernel upgrades restart networkd, flushing ip rules, after the dpkg hook already ran.
- `apt-roost-travel.conf` → `/etc/apt/apt.conf.d/99-roost-travel.conf` — dpkg `Post-Invoke` running `ensure`, so unattended-upgrades re-execs don't leave a 5m outage window. Complementary to the networkd unit: the dpkg hook catches systemd-package re-execs that don't restart networkd; the networkd unit catches needrestart-driven restarts that fire after the hook.
- `wg-proton.service.d/roost.conf` — drop-in for `wg-quick@wg-proton` (ordering + kill-switch sanity).
- `proton.conf.example` — template; drop raw Proton downloads under `/etc/roost-travel/proton-profiles/<name>.conf` and activate with `roost-net vpn profile <name>` (synthesizes `/etc/wireguard/wg-proton.conf`: strips and re-injects Table/PostUp/PreDown/DNS; hot-restarts wg-quick if vpn=on).
- `travel-health.sh` → deployed as `health-check-apps.sh`, sourced by the base health check: travel-vpn checks (incl. Vision cert expiry, alarm at <30d) + PrivateBin write gate + the roughdraft-write-guard hook liveness probe (see `files/hooks/CLAUDE.md`).
- `travel-cloudflare.yml.tmpl` — CF Tunnel ingress fragment, copied to `~/roost/cloudflared/apps/travel.yml` by `roost-net travel on`.
- `vision-cert-init.sh`, `vision-cert-renew.service`/`.timer`, `ntfy-cert-renew@.service`, `vision-fallback.caddy` — Path D cert lifecycle (below).
- `_envsubst-vars.sh` — the single envsubst allowlist for rendering `xray-config.json.tmpl`, sourced by both `setup/travel-vpn.sh` and `roost-apply --xray`. A new `state.env` key (new inbound) goes here once; divergent allowlists were the "config validates, auth fails" footgun.

## Paths

- **A** — VLESS + WebSocket + TLS behind the Cloudflare Tunnel (CF terminates TLS; xray on `127.0.0.1:10000`). Multi-IP: one client outbound per CF Anycast IP (`path-a-ip1`, `path-a-ip2`, …) in the urltest pool, because Anycast prefixes have wildly different reachability per network (`104.21/16` was SYN-dropped from China while `172.67/16` worked). IP source priority at render: (1) `~/roost/travel/cf-preferred-ip` (one IP per line, pushed by the laptop's `roost-travel ips`: cfst against ~5000 CF /24 samples, top 5 by latency); (2) `getent` on `travel.$DOMAIN` (CF's BGP-nearest pair).
- **B** — VLESS + gRPC + REALITY on `:443` direct (masquerades as `www.samsung.com`). Two inbounds (`reality-v4`/`reality-v6`) bind the public addresses, not the wildcard, so the Tailscale IP's `:443` stays Caddy's (`drop.$DOMAIN`).
- **C** — Shadowsocks-2022 (`chacha20-poly1305`) on `:::51820`, TCP + UDP.
- **D** — VLESS + XTLS-Vision over plain TLS on `:::8443` (Let's Encrypt wildcard via acme.sh DNS-01; bad-key probes fall back to a Caddy canned page on `127.0.0.1:8081` so the listener doesn't RST and fingerprint as a proxy).

**Egress:** optional ProtonVPN WireGuard (`wg-proton`) as a policy-routed outbound. Traffic from the `xray` user plus Tailscale-exit-node forwarded traffic is fwmarked `0x1337` (mask `0x0000ffff`, so Tailscale's own mark bits survive); a dual-stack kill-switch REJECTs anything from those sources that would otherwise leave via `eth0`.

## State

`/etc/roost-travel/`: `travel` and `vpn` hold `on`/`off`; `path` holds the forced client path (`a`/`b`/`c`/`d`/`auto`, absent = auto; render-time only, re-fetch client configs to apply); `state.env` (`0600 root`) holds the generated keys plus `VISION_SNI` and `HETZNER_PUBLIC_IPV4`/`IPV6`. `vpn=on` is persisted via `systemctl enable --now wg-quick@wg-proton`, so an in-country update + reboot restores full state. `roost-net travel on` also opens UFW for 443/tcp, 51820/tcp+udp and (only if the Vision cert exists) 8443/tcp; the Hetzner cloud firewall side is the laptop's `roost-net-fw.sh`. `roost-net test` asserts fwmark masking, kill-switch REJECT, external egress, and the Path D chain (cert validity, `:8443` reachability, fallback responds).

## Path D provisioning (once per server or cert rotation)

The wildcard cert lives at `/etc/roost-travel/vision-cert/`, issued by `vision-cert-init.sh` and renewed weekly by `vision-cert-renew.timer` (Tue 04:00 UTC; failures ntfy via `OnFailure=ntfy-cert-renew@%n.service`). The init step needs the Cloudflare API token, which is laptop-only by design, so pass it explicitly:

```bash
sudo CF_Token=$CLOUDFLARE_API_TOKEN DOMAIN=$DOMAIN /etc/roost-travel/vision-cert-init.sh
```

acme.sh persists the token into its account config, so the timer's `--cron` renewals don't need it. Troubleshooting: `docs/runbooks/path-d-vision.md`.

## Known failure modes

- **DNS bootstrap loop** (fixed 2026-04-30, `plans/singbox-dns-bootstrap-fix.md`): sing-box's cf-doh DNS server must have `detour: "urltest"` and Path A's outbound must use a render-time-baked CF IP, otherwise sing-box's own DoH client gets captured by its tun and can't bootstrap where the underlying interface can't reach 1.1.1.1. Diagnostic: `journalctl -u roost-travel | grep "1.1.1.1:443: i/o timeout"` while raw `nc -zv 1.1.1.1 443` succeeds. Render fix lives in `render_android` (`scripts/roost-net.sh`); `laptop/travel-test.sh` has the regression assertion (`test_dns_via_tunnel`). If the symptom returns, the follow-up is a Quad9 secondary DoH.
- **All-paths-fail DNS hang:** with cf-doh detouring through urltest, if every member fails at once DNS hangs at urltest selection (sing-box's DoH server has no per-query timeout; `connect_timeout` only bounds TCP connect). Seen in normal operation it means every path is blocked simultaneously: fall back to eSIM-bypass routing or direct internet.
- **sing-box issue #3792:** some versions return `missing supported outbound` for the DoH-server-with-urltest-detour pattern. OK on 1.13.x. `roost-travel config` prints the version; sidecar-test before deploying if laptop or Android drifts to anything unfamiliar.
- **Xray-core staleness:** version-pinned (`v26.x`), updated only on `./deploy.sh` re-runs (`_xray-install.sh` resolves the version + SHA-256; `setup/travel-vpn.sh` dispatches to it). REALITY active-probing research lands periodically; when `net4people/bbs` flags new detection, re-run `./deploy.sh` within 30 days.
