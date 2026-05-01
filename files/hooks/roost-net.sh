#!/bin/bash
# roost-net — travel-VPN control CLI.
# Env sources: .sync-env (DOMAIN, USERNAME), state.env (Xray keys, 0600 root).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/_hook-env.sh"

STATE_DIR=/etc/roost-travel
SYNC_ENV="$HOME/$ROOST_DIR_NAME/.sync-env"

if [ -f "$SYNC_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$SYNC_ENV"
    set +a
fi

USERNAME="${USERNAME:-$(whoami)}"
DOMAIN="${DOMAIN:-}"
ROOST_DIR="$HOME/$ROOST_DIR_NAME"

die() {
    local msg="$1"
    logger -t "$_HOOK_TAG" -p user.err "$msg"
    ntfy_send -t "roost-net error" -p "high" "$msg"
    echo "Error: $msg" >&2
    exit 1
}

read_state_file() {
    local file="$1" default="$2"
    if sudo test -f "$file"; then
        sudo cat "$file"
    else
        echo "$default"
    fi
}

load_state_env() {
    local state_file="$STATE_DIR/state.env"
    sudo test -f "$state_file" || die "state.env missing at $state_file; run keys-init.sh"
    set -a
    # shellcheck disable=SC1090
    source <(sudo cat "$state_file")
    set +a
}

# Probe the wg-proton tunnel's egress IP, retrying while WireGuard handshakes.
# wg-quick start returns when the interface is up, but the first packet still
# has to trigger a handshake (1-2 RTTs to Proton's endpoint), and Proton can
# occasionally be sluggish on quick reconnects, so a single probe after
# `systemctl restart` races the tunnel establishment.
probe_wg_egress() {
    local attempt ip
    for attempt in 1 2 3; do
        if ip=$(sudo -u xray curl -sf --max-time 10 --interface wg-proton https://api.ipify.org); then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep 2
    done
    return 1
}

# Check that egress IP is external (not our own Hetzner server).
# Proton-affiliated egresses ride upstreams like Datacamp (AS212238) or M247,
# so allowlisting "Proton AG / AS62371" misses real Proton paths. Invert the
# check: the threat model is "xray traffic leaked out of eth0 as Hetzner",
# which IP-diff catches directly without needing to identify Proton.
# Returns 0 = external (tunnel active), 1 = matches our eth0 or Hetzner ASN.
is_external_egress() {
    local ip="$1" our_ip org
    our_ip=$(ip -4 addr show eth0 | awk '/inet / {print $2; exit}' | cut -d/ -f1)
    if [ -n "$our_ip" ] && [ "$ip" = "$our_ip" ]; then
        logger -t "$_HOOK_TAG" -p user.warning "Egress $ip matches eth0 address (leak)"
        return 1
    fi
    if org=$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/org"); then
        if printf '%s\n' "$org" | grep -qiE 'hetzner|AS24940'; then
            logger -t "$_HOOK_TAG" -p user.warning "Egress $ip reports Hetzner: $org (leak)"
            return 1
        fi
        logger -t "$_HOOK_TAG" "Egress $ip org: $org"
    else
        logger -t "$_HOOK_TAG" "ipinfo lookup failed for $ip (IP differs from eth0, trusting)"
    fi
    return 0
}

cmd_status() {
    local travel_state vpn_state
    travel_state=$(read_state_file "$STATE_DIR/travel" "off")
    vpn_state=$(read_state_file "$STATE_DIR/vpn" "off")

    echo "Travel: $travel_state"
    echo "VPN:    $vpn_state"
    echo

    local xray_status
    xray_status=$(systemctl is-active xray.service || true)
    echo "xray.service:   $xray_status"

    if [ "$vpn_state" = "on" ]; then
        local wg_status
        wg_status=$(systemctl is-active wg-quick@wg-proton.service || true)
        echo "wg-quick@wg-proton: $wg_status"
    fi

    echo
    local ip egress_rc
    if ip=$(sudo -u xray curl -sf --max-time 5 https://api.ipify.org); then
        echo "Egress (default): $ip"
        # `|| egress_rc=$?` captures non-zero without tripping `set -e`.
        egress_rc=0; is_external_egress "$ip" || egress_rc=$?
        case "$egress_rc" in
            0) echo "  Egress: external (tunnel)" ;;
            1) echo "  Egress: Hetzner (direct / leak)" ;;
        esac
    else
        echo "Egress (default): unreachable"
    fi

    if [ "$vpn_state" = "on" ]; then
        local vpn_ip
        if vpn_ip=$(sudo -u xray curl -sf --max-time 5 --interface wg-proton https://api.ipify.org); then
            echo "Egress (wg-proton): $vpn_ip"
            egress_rc=0; is_external_egress "$vpn_ip" || egress_rc=$?
            case "$egress_rc" in
                0) echo "  Egress: external (Proton)" ;;
                1) echo "  Egress: Hetzner (unexpected — investigate)" ;;
            esac
        else
            echo "Egress (wg-proton): unreachable"
        fi
    fi
}

cmd_travel() {
    local action="${1:-}"
    local cf_fragment="$STATE_DIR/travel-cloudflare.yml"
    local cf_target="$ROOST_DIR/cloudflared/apps/travel.yml"
    local assemble="$ROOST_DIR/claude/hooks/cloudflare-assemble.sh"

    # Path D (VLESS-Vision) listens on TCP 8443 only when the cert is in place;
    # the firewall rule is conditional so cert-init failures don't expose a port
    # with no listener behind it.
    local vision_cert=/etc/roost-travel/vision-cert/fullchain.cer

    case "$action" in
        on)
            sudo test -f "$cf_fragment" || die "Source fragment $cf_fragment missing; reinstall travel-vpn setup"
            # Rollback: if any step after CF fragment install fails, undo the partial
            # exposure so state=off on disk matches reality (otherwise travel-health
            # and the weekly audit skip a server that's actually publicly exposed).
            cmd_travel_rollback() {
                sudo ufw --force delete allow 443/tcp || true
                sudo ufw --force delete allow 51820/tcp || true
                sudo ufw --force delete allow 51820/udp || true
                sudo ufw --force delete allow 8443/tcp || true
                sudo rm -f "$cf_target"
                sudo "$assemble" || true
                sudo systemctl restart cloudflared || true
                logger -t "$_HOOK_TAG" "cmd_travel on: rolled back after partial failure"
            }
            trap cmd_travel_rollback ERR
            [ -d "$(dirname "$cf_target")" ] || mkdir -p "$(dirname "$cf_target")"
            sudo install -m 0644 -o "$USERNAME" -g "$USERNAME" "$cf_fragment" "$cf_target"
            sudo "$assemble"
            sudo systemctl restart cloudflared
            sudo ufw allow 443/tcp comment 'travel-vpn-reality'
            sudo ufw allow 51820/tcp comment 'travel-vpn-ss2022'
            sudo ufw allow 51820/udp comment 'travel-vpn-ss2022'
            if sudo test -f "$vision_cert"; then
                sudo ufw allow 8443/tcp comment 'travel-vpn-vision'
            else
                logger -t "$_HOOK_TAG" -p user.warning \
                    "Vision cert absent at $vision_cert; skipping ufw 8443/tcp (Path D will not be reachable until cert-init runs)"
                echo "  (Vision cert absent; Path D 8443/tcp not opened)" >&2
            fi
            echo "on" | sudo tee "$STATE_DIR/travel" >/dev/null
            trap - ERR
            ntfy_send -t "Travel ON" "Paths A/B/C/D exposed + UFW open. Run 'roost-net-fw open' on laptop."
            echo "Travel mode: ON"
            ;;
        off)
            sudo rm -f "$cf_target"
            sudo "$assemble"
            sudo systemctl restart cloudflared
            sudo ufw --force delete allow 443/tcp || true
            sudo ufw --force delete allow 51820/tcp || true
            sudo ufw --force delete allow 51820/udp || true
            sudo ufw --force delete allow 8443/tcp || true
            echo "off" | sudo tee "$STATE_DIR/travel" >/dev/null
            ntfy_send -t "Travel OFF" "Close laptop FW via: roost-net-fw close"
            echo "Travel mode: OFF"
            ;;
        *)
            die "Usage: roost-net travel on|off"
            ;;
    esac
}

cmd_vpn() {
    local action="${1:-}"

    case "$action" in
        on)
            if ! sudo test -e /etc/wireguard/wg-proton.conf; then
                # Distinguish "no symlink / no file" from "dangling symlink"
                # (e.g. user renamed the profile file). `test -f` follows symlinks
                # so both look identical without the extra -L check.
                if sudo test -L /etc/wireguard/wg-proton.conf; then
                    local tgt
                    tgt=$(sudo readlink /etc/wireguard/wg-proton.conf)
                    die "wg-proton.conf -> $tgt (target missing — profile renamed?). Fix with: roost-net vpn profile <name>"
                fi
                die "No /etc/wireguard/wg-proton.conf. Drop a profile under $STATE_DIR/proton-profiles/ and run: roost-net vpn profile <name>"
            fi
            # Heal orphan kernel state: the interface can outlive the systemd
            # unit (e.g. after manual `systemctl restart` during testing or
            # PreDown failures). wg-quick refuses to re-create an existing
            # interface, so next `enable --now` fails with "already exists".
            if ! sudo systemctl is-active --quiet wg-quick@wg-proton && ip link show wg-proton >/dev/null 2>&1; then
                logger -t "$_HOOK_TAG" "wg-proton orphaned (kernel up, unit inactive); tearing down"
                sudo wg-quick down wg-proton 2>&1 >/dev/null || true
                sudo systemctl reset-failed wg-quick@wg-proton || true
            fi
            sudo systemctl enable --now wg-quick@wg-proton
            # `enable --now` exits 0 on enable success even if --now's start
            # phase fails (bug-ish but documented behaviour). Verify with
            # is-active so we catch actual start failures.
            if ! sudo systemctl is-active --quiet wg-quick@wg-proton; then
                sudo systemctl disable wg-quick@wg-proton || true
                # wg-quick@ is Type=oneshot with RemainAfterExit=yes: if ExecStart
                # (wg-quick up) fails partway, ExecStop is NOT auto-invoked, so
                # PreDown (proton-routing.sh down) may not have run. Explicit
                # teardown prevents orphan fwmark/kill-switch rules.
                sudo /etc/roost-travel/proton-routing.sh down || true
                die "wg-quick@wg-proton failed to start (check: journalctl -u wg-quick@wg-proton -n 20)"
            fi
            local ip
            if ! ip=$(probe_wg_egress); then
                sudo systemctl disable --now wg-quick@wg-proton
                die "Egress verification failed (no response via wg-proton)"
            fi
            # IP-diff primary: if egress != eth0 IP, tunnel is working. This
            # holds even if ipinfo is down, so no fail-closed-on-lookup needed.
            is_external_egress "$ip" || {
                sudo systemctl disable --now wg-quick@wg-proton
                die "Egress $ip matches Hetzner (leak detected)"
            }
            sudo systemctl enable --now proton-keepalive.timer
            sudo systemctl enable --now proton-routing-ensure.timer
            echo "on" | sudo tee "$STATE_DIR/vpn" >/dev/null
            ntfy_send -t "VPN ON" "Egress: $ip"
            echo "VPN mode: ON (egress $ip)"
            ;;
        off)
            sudo systemctl disable --now proton-routing-ensure.timer || true
            sudo systemctl disable --now proton-keepalive.timer || true
            sudo systemctl disable --now wg-quick@wg-proton || true
            echo "off" | sudo tee "$STATE_DIR/vpn" >/dev/null
            ntfy_send -t "VPN OFF" "Hetzner egress"
            echo "VPN mode: OFF"
            ;;
        profile)
            local profile="${2:-}"
            local profiles_dir="$STATE_DIR/proton-profiles"
            local live="/etc/wireguard/wg-proton.conf"
            if [ -z "$profile" ]; then
                # List mode
                local current=""
                if sudo test -L "$live"; then
                    current=$(sudo readlink -f "$live")
                fi
                echo "Available Proton profiles (drop *.conf files under $profiles_dir):"
                local found=false
                while IFS= read -r -d '' f; do
                    found=true
                    local name marker=""
                    name=$(basename "$f" .conf)
                    [ "$f" = "$current" ] && marker=" [active]"
                    echo "  $name$marker"
                done < <(sudo find "$profiles_dir" -maxdepth 1 -name '*.conf' -type f -print0 2>/dev/null)
                $found || echo "  (none — add configs then 'roost-net vpn profile <name>')"
                return 0
            fi
            local target="$profiles_dir/$profile.conf"
            sudo test -f "$target" || die "No profile '$profile' at $target"
            sudo ln -sfT "$target" "$live"
            echo "Active Proton profile: $profile -> $target"
            # If VPN is currently on, restart wg-quick to pick up the new config.
            # Re-verify egress + ASN so a bad profile fails closed rather than
            # silently flipping the egress to an unintended country/network.
            if [ "$(read_state_file "$STATE_DIR/vpn" "off")" = "on" ]; then
                echo "Restarting wg-quick@wg-proton with new profile..."
                if ! sudo systemctl restart wg-quick@wg-proton; then
                    sudo /etc/roost-travel/proton-routing.sh down || true
                    die "wg-quick@wg-proton restart failed after profile swap to '$profile'"
                fi
                local ip
                ip=$(probe_wg_egress) \
                    || die "Egress verification failed after profile swap to '$profile'"
                is_external_egress "$ip" || die "Egress $ip matches Hetzner after profile swap"
                ntfy_send -t "VPN profile: $profile" "Egress: $ip"
                echo "Egress: $ip"
            fi
            ;;
        *)
            die "Usage: roost-net vpn {on|off|profile [name]}"
            ;;
    esac
}

cmd_test() {
    local travel_state vpn_state pass=0 fail=0
    travel_state=$(read_state_file "$STATE_DIR/travel" "off")
    vpn_state=$(read_state_file "$STATE_DIR/vpn" "off")

    assert() {
        local name="$1"
        shift
        if "$@"; then
            echo "  [PASS] $name"
            pass=$((pass + 1))
        else
            echo "  [FAIL] $name"
            fail=$((fail + 1))
        fi
    }
    skip() {
        echo "  [SKIP] $1"
    }

    # --- Path D (Vision) — runs whenever the cert exists, independent of
    # travel/vpn toggles. Skips silently in the pre-cert-init state so the
    # report doesn't shout about a deliberately-deferred operator step.
    local vision_cert=/etc/roost-travel/vision-cert/fullchain.cer
    if sudo test -r "$vision_cert"; then
        echo "--- Path D (Vision) ---"
        assert "vision cert valid >7 days" \
            sudo openssl x509 -checkend 604800 -noout -in "$vision_cert"
        # xray listens on :: so loopback connect reaches it.
        assert "Path D :8443 reachable on loopback" \
            bash -c "exec 3<>/dev/tcp/127.0.0.1/8443 2>/dev/null && exec 3>&- 3<&-"
        # Bad-key probe: send HTTP through the TLS listener; xray's fallbacks
        # block forwards to 127.0.0.1:8081 where Caddy responds with the canned
        # page. -k bypasses cert validation; --resolve points the SNI to localhost.
        local sni="${VISION_SNI:-static.$DOMAIN}"
        assert "vision fallback responds with Caddy canned page" \
            bash -c "curl -k -s --max-time 5 --resolve '$sni:8443:127.0.0.1' 'https://$sni:8443/' | grep -q 'It works'"
    else
        skip "Path D: cert not present at $vision_cert (run vision-cert-init.sh)"
    fi

    if [ "$vpn_state" = "on" ]; then
        echo "--- fwmark masking + routing ---"
        # iptables -S canonicalizes the MASK from 0x0000ffff -> 0xffff.
        assert "iptables MARK for xray uid with 0xffff mask" \
            bash -c "sudo iptables -t mangle -S OUTPUT | grep -qE -- '--uid-owner [^ ]+ .*--set-xmark 0x1337/0xffff'"
        assert "ip6tables MARK for xray uid with 0xffff mask" \
            bash -c "sudo ip6tables -t mangle -S OUTPUT | grep -qE -- '--uid-owner [^ ]+ .*--set-xmark 0x1337/0xffff'"

        echo "--- VPN on: routing, kill-switch, egress ---"
        assert "ip route table 51820 has default via wg-proton" \
            bash -c "ip route show table 51820 | grep -q 'default.*wg-proton'"
        assert "ip -6 route table 51820 has default via wg-proton" \
            bash -c "ip -6 route show table 51820 | grep -q 'default.*wg-proton'"
        # uidrange is the primary router for xray-uid OUTPUT (no reroute race).
        local xray_uid
        xray_uid=$(id -u xray)
        assert "ip rule: uidrange xray lookup 51820" \
            bash -c "ip rule show | grep -qE 'uidrange ${xray_uid}-${xray_uid} lookup 51820'"
        assert "ip -6 rule: uidrange xray lookup 51820" \
            bash -c "ip -6 rule show | grep -qE 'uidrange ${xray_uid}-${xray_uid} lookup 51820'"
        # Inbound-reply escape: new connections to public service ports are
        # connmarked, restored on OUTPUT, and routed via main (eth0/tailscale0)
        # so external clients see a SYN-ACK from the Hetzner IP they connected to.
        assert "ip rule: fwmark 0x4000/0x4000 lookup main (inbound-reply)" \
            bash -c "ip rule show | grep -q 'fwmark 0x4000/0x4000 lookup main'"
        assert "mangle PREROUTING connmarks inbound 443/51820/8443" \
            bash -c "sudo iptables -t mangle -S PREROUTING | grep -qE 'dports 443,51820,8443 .* --set-xmark 0x4000'"
        assert "mangle OUTPUT restores 0x4000 connmark to fwmark" \
            bash -c "sudo iptables -t mangle -S OUTPUT | grep -qE 'restore-mark .* 0x4000'"
        # Mask is required (Tailscale's upper bits would otherwise cause misses);
        # fwmark rule still handles Tailscale-FORWARDED traffic that has no uid.
        assert "ip rule: fwmark 0x1337/0xffff lookup 51820" \
            bash -c "ip rule show | grep -q 'fwmark 0x1337/0xffff lookup 51820'"
        assert "ip -6 rule: fwmark 0x1337/0xffff lookup 51820" \
            bash -c "ip -6 rule show | grep -q 'fwmark 0x1337/0xffff lookup 51820'"
        # Kill-switch defense-in-depth: xray uid forced onto eth0 (bypassing the
        # uidrange rule with SO_BINDTODEVICE) must be REJECTed.
        assert "kill-switch blocks xray forced-eth0 egress" \
            bash -c "! sudo -u xray curl -sf --max-time 3 --interface eth0 https://1.1.1.1/ >/dev/null"
        # With --interface wg-proton: must succeed and be external (not our Hetzner IP).
        local vip
        if vip=$(sudo -u xray curl -sf --max-time 10 --interface wg-proton https://api.ipify.org); then
            echo "  [PASS] wg-proton egress reachable for xray ($vip)"
            pass=$((pass + 1))
            assert "wg-proton egress is external (not Hetzner)" is_external_egress "$vip"
        else
            echo "  [FAIL] wg-proton egress unreachable for xray"
            fail=$((fail + 1))
        fi
    else
        echo "--- VPN off: fwmark/routing/kill-switch skipped (proton-routing.sh only installs when wg-quick@wg-proton is up) ---"
    fi

    echo
    echo "Summary: $pass pass, $fail fail"
    if [ "$fail" -ne 0 ]; then
        ntfy_send -t "roost-net test: $fail assertion(s) failed" -p "high" \
            "Inspect via 'roost-net test' + 'journalctl -t roost/roost-net'. Travel state: $travel_state, VPN state: $vpn_state."
    fi
    [ "$fail" -eq 0 ]
}

render_android() {
    local short_id_0 server_v4 server_v6
    short_id_0=$(printf '%s' "$REALITY_SHORT_IDS" | jq -r '.[0]')
    # Resolve the dual-stack A-record hostname into raw IPs. sing-box 1.13
    # deprecated outbound-level `domain_strategy` and `network_strategy` /
    # `fallback_delay` only work on Android/Apple GUI clients, so splitting
    # paths B + C into per-family urltest members with raw addresses is the
    # only portable way to get Happy-Eyeballs-style fallback on the laptop
    # CLI too. If server has no v6, v6 variants are omitted downstream.
    server_v4=$(getent ahostsv4 "travel-direct.$DOMAIN" | awk 'NR==1 {print $1}')
    server_v6=$(getent ahostsv6 "travel-direct.$DOMAIN" | awk 'NR==1 {print $1}')
    [ -n "$server_v4" ] || die "could not resolve travel-direct.$DOMAIN A record"
    # Bake Path A's CF Anycast IPs at render time so sing-box doesn't need
    # runtime DNS to dial them. Without this, cf-doh's bootstrap loop blocks
    # all DNS on networks where the underlying interface can't reach 1.1.1.1
    # (the loop: cf-doh -> tun -> urltest -> path-a [hostname] -> cf-doh).
    # SNI stays as the hostname for cert validation.
    #
    # Consequence of baking IP into `server`: sing-box's ws transport defaults
    # the HTTP Host header to serverAddr (the IP), not the SNI. CF Tunnel
    # ingress requires Host=travel.$DOMAIN to match the rule, so we MUST set
    # transport.headers.Host explicitly below — otherwise WS upgrades 403
    # (verified: empty Host = 403, IP Host = 403, hostname Host = 101).
    #
    # Multi-IP: render one path-a-ipN outbound per CF Anycast IP. urltest
    # auto-skips ones that fail (TCP SYN dropped, TLS hangs, etc.) and
    # picks the live one with lowest latency. Different CF Anycast prefixes
    # (104.21.x.x vs 172.67.x.x) can have radically different reachability
    # from a given network — observed in China where 104.21/16 was SYN-
    # dropped while 172.67/16 worked. urltest's 3m re-probe interval also
    # handles transient blocking changes.
    #
    # Override: /etc/roost-travel/cf-preferred-ip pins a single IP (still
    # supported for operator-forced selection — e.g. CloudflareSpeedTest
    # winner). When set, only that IP is rendered (no urltest selection
    # among CF IPs). Remove the file to get auto-selection.
    local _cf_pref_file=/etc/roost-travel/cf-preferred-ip
    local path_a_ips_raw=""
    if sudo test -r "$_cf_pref_file"; then
        path_a_ips_raw=$(sudo tr -d '[:space:]' < "$_cf_pref_file")
    else
        path_a_ips_raw=$(getent ahostsv4 "travel.$DOMAIN" | awk '{print $1}' | sort -u)
    fi
    if [ -z "$path_a_ips_raw" ]; then
        printf 'WARNING: getent failed for travel.%s; Path A will use hostname (DNS-bootstrap-fragile)\n' "$DOMAIN" >&2
        path_a_ips_raw="travel.$DOMAIN"
    fi
    # JSON array of strings for jq's --argjson.
    local path_a_ips_json
    path_a_ips_json=$(printf '%s\n' "$path_a_ips_raw" | jq -R . | jq -sc .)
    jq -n \
        --arg domain "$DOMAIN" \
        --arg uuid "$XRAY_UUID" \
        --arg path "$XRAY_PATH" \
        --arg service_name "$GRPC_SERVICE_NAME" \
        --arg reality_public_key "$REALITY_PUBLIC_KEY" \
        --arg short_id "$short_id_0" \
        --arg ss_password "$SS2022_PASSWORD" \
        --arg server_v4 "$server_v4" \
        --arg server_v6 "$server_v6" \
        --argjson path_a_ips "$path_a_ips_json" \
        --arg vision_sni "${VISION_SNI:-static.$DOMAIN}" \
        '
        # path-a-ipN tag list (one per CF IP); referenced by urltest pool.
        ($path_a_ips | to_entries | map("path-a-ip\(.key + 1)")) as $path_a_tags |
        # Corresponding outbound objects.
        ($path_a_ips | to_entries | map({
            type: "vless",
            tag: "path-a-ip\(.key + 1)",
            server: .value,
            server_port: 443,
            uuid: $uuid,
            tls: {
                enabled: true,
                server_name: "travel.\($domain)",
                utls: {enabled: true, fingerprint: "chrome"}
            },
            transport: {
                type: "ws",
                path: "/\($path)",
                headers: {Host: "travel.\($domain)"},
                max_early_data: 0
            }
        })) as $path_a_outbounds |
        {
            log: {level: "info"},
            dns: {
                servers: [
                    {type: "https", tag: "cf-doh", server: "1.1.1.1", detour: "urltest"}
                ],
                rules: [
                    {domain: ["travel.\($domain)", "travel-direct.\($domain)"], action: "route", server: "cf-doh"}
                ]
            },
            inbounds: [
                {
                    type: "tun",
                    tag: "tun-in",
                    interface_name: "tun0",
                    address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    auto_route: true,
                    strict_route: true,
                    stack: "system"
                }
            ],
            outbounds: (
                [
                    {
                        type: "urltest",
                        tag: "urltest",
                        outbounds: (
                            $path_a_tags
                            + ["path-b-v4", "path-c-v4", "path-d-v4"]
                            + (if ($server_v6 | length) > 0 then ["path-b-v6", "path-c-v6", "path-d-v6"] else [] end)
                        ),
                        url: "https://www.gstatic.com/generate_204",
                        interval: "3m",
                        tolerance: 200
                    }
                ]
                + $path_a_outbounds
                + [
                    {
                        type: "vless",
                        tag: "path-b-v4",
                        server: $server_v4,
                        server_port: 443,
                        uuid: $uuid,
                        tls: {
                            enabled: true,
                            server_name: "www.samsung.com",
                            utls: {enabled: true, fingerprint: "chrome"},
                            reality: {
                                enabled: true,
                                public_key: $reality_public_key,
                                short_id: $short_id
                            }
                        },
                        transport: {type: "grpc", service_name: $service_name}
                    },
                    {
                        type: "shadowsocks",
                        tag: "path-c-v4",
                        server: $server_v4,
                        server_port: 51820,
                        method: "2022-blake3-chacha20-poly1305",
                        password: $ss_password
                    },
                    {
                        type: "vless",
                        tag: "path-d-v4",
                        server: $server_v4,
                        server_port: 8443,
                        uuid: $uuid,
                        flow: "xtls-rprx-vision",
                        tls: {
                            enabled: true,
                            server_name: $vision_sni,
                            utls: {enabled: true, fingerprint: "chrome"}
                        }
                    }
                ]
                + (if ($server_v6 | length) > 0 then [
                    {
                        type: "vless",
                        tag: "path-b-v6",
                        server: $server_v6,
                        server_port: 443,
                        uuid: $uuid,
                        tls: {
                            enabled: true,
                            server_name: "www.samsung.com",
                            utls: {enabled: true, fingerprint: "chrome"},
                            reality: {
                                enabled: true,
                                public_key: $reality_public_key,
                                short_id: $short_id
                            }
                        },
                        transport: {type: "grpc", service_name: $service_name}
                    },
                    {
                        type: "shadowsocks",
                        tag: "path-c-v6",
                        server: $server_v6,
                        server_port: 51820,
                        method: "2022-blake3-chacha20-poly1305",
                        password: $ss_password
                    },
                    {
                        type: "vless",
                        tag: "path-d-v6",
                        server: $server_v6,
                        server_port: 8443,
                        uuid: $uuid,
                        flow: "xtls-rprx-vision",
                        tls: {
                            enabled: true,
                            server_name: $vision_sni,
                            utls: {enabled: true, fingerprint: "chrome"}
                        }
                    }
                ] else [] end)
            ),
            route: {
                auto_detect_interface: true,
                rules: [
                    {action: "sniff"},
                    {protocol: "dns", action: "hijack-dns"},
                    {ip_cidr: ["0.0.0.0/0", "::/0"], action: "route", outbound: "urltest"}
                ]
            },
            experimental: {
                clash_api: {
                    external_controller: "127.0.0.1:47200"
                }
            }
        }'
    # Loopback-only Clash API. Lets us query per-outbound urltest
    # probe history (the /proxies endpoint exposes each path's last
    # delay) so travel-test.sh can show what sing-box itself sees,
    # not just our external openssl probes. No secret because the
    # listener is bound to 127.0.0.1.
    #
    # Port 47200: VS Code Remote-SSH auto-forwards any port mentioned
    # in remote terminal output and binds it on the laptop. We tried
    # 9090 (canonical Clash), 19090, 49090 — all grabbed by pid "code"
    # within seconds. 47200 is even less common; if it gets grabbed
    # too, the operator's only fix is to disable VS Code's "Auto
    # Forward Ports" feature (`"remote.autoForwardPorts": "off"` in
    # settings, or remove individual entries from the Ports panel).
    # No port choice reliably wins against an opt-in port forwarder.
}

render_laptop() {
    # Laptop config = Android outbounds + local SOCKS5 inbound on 127.0.0.1:54321
    # so SSH ProxyCommand can chain through sing-box.
    render_android | jq '
        .inbounds = [
            .inbounds[0],
            {type: "socks", tag: "local-socks", listen: "127.0.0.1", listen_port: 54321, users: []}
        ]
        | .route.rules = [
            {action: "sniff"},
            {protocol: "dns", action: "hijack-dns"},
            {inbound: ["local-socks"], action: "route", outbound: "urltest"},
            {ip_cidr: ["0.0.0.0/0", "::/0"], action: "route", outbound: "urltest"}
        ]
    '
}

render_ssh() {
    cat <<EOF
Host roost-travel
  HostName localhost
  HostKeyAlias roost-travel
  Port 22
  User ${USERNAME}
  ProxyCommand ncat --proxy 127.0.0.1:54321 --proxy-type socks5 %h %p
EOF
}

cmd_client() {
    local target="${1:-}"
    [ -n "$DOMAIN" ] || die "DOMAIN not set; add it to $SYNC_ENV"

    case "$target" in
        android)
            load_state_env
            render_android
            ;;
        laptop)
            load_state_env
            render_laptop
            ;;
        ssh)
            render_ssh
            ;;
        *)
            die "Usage: roost-net client android|laptop|ssh"
            ;;
    esac
}

cmd_rotate_keys() {
    local keys_init="$STATE_DIR/keys-init.sh"
    local roost_apply="$ROOST_DIR/claude/hooks/roost-apply.sh"
    sudo test -x "$keys_init" || die "$keys_init missing or not executable"
    [ -x "$roost_apply" ] || die "$roost_apply missing; can't re-render xray config"
    sudo "$keys_init" --force
    # Restarting xray alone reloads the SAME /etc/xray/config.json, which still
    # carries the pre-rotation credentials. --xray re-renders from state.env
    # and installs with 0640 root:xray before restarting.
    "$roost_apply" --xray
    ntfy_send -t "roost-net keys rotated" -p "high" \
        "XRAY_UUID, REALITY keypair, SS-2022 password regenerated. Redistribute client configs (roost-net client {android,laptop,ssh})."
    echo "Keys rotated. Regenerate and redistribute client configs:"
    echo "  roost-net client android > /tmp/sb-android.json"
    echo "  roost-net client laptop  > ~/.config/sing-box/travel.json"
    echo "  roost-net client ssh     # append to ~/.ssh/config"
}

subcmd="${1:-status}"
shift || true

case "$subcmd" in
    status) cmd_status ;;
    travel) cmd_travel "$@" ;;
    vpn) cmd_vpn "$@" ;;
    test) cmd_test ;;
    client) cmd_client "$@" ;;
    rotate-keys) cmd_rotate_keys ;;
    -h|--help|help)
        cat <<EOF
Usage: roost-net <subcommand> [args]

Subcommands:
  status                     Show travel/vpn state, service health, egress IP+ASN
  travel {on|off}            Toggle Path A (CF Tunnel fragment + UFW 443/51820)
  vpn {on|off}               Toggle Proton egress (wg-quick@wg-proton + keepalive)
  vpn profile [name]         List or activate a Proton profile from /etc/roost-travel/proton-profiles/.
                             Swaps /etc/wireguard/wg-proton.conf symlink; restarts wg if vpn=on.
  test                       Assert fwmark, routing, kill-switch
  client {android|laptop|ssh}  Emit client config to stdout
  rotate-keys                Regenerate UUID + REALITY keys + SS-2022 password
EOF
        ;;
    *)
        echo "Unknown subcommand: $subcmd" >&2
        echo "Run 'roost-net help' for usage." >&2
        exit 1
        ;;
esac
