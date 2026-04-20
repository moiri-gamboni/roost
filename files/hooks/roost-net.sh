#!/bin/bash
# roost-net — unified travel-VPN control CLI.
#
# Subcommands: status, travel {on|off}, vpn {on|off}, test,
#              client {android|laptop|ssh}, rotate-keys
#
# Config sources (integration-lead: keep these in sync):
#   - _hook-env.sh (same dir): ntfy_send, logger, ROOST_DIR_NAME
#   - $HOME/$ROOST_DIR_NAME/.sync-env: USERNAME, DOMAIN, ROOST_DIR_NAME
#     (deploy.sh heredoc writes this; HETZNER_PUBLIC_IPV4/V6 also expected
#      once integration-lead adds them per plan §3.2, but client configs
#      use the DNS name `travel-direct.$DOMAIN` so they aren't required here)
#   - /etc/roost-travel/state.env (0600 root): XRAY_UUID, XRAY_PATH,
#     GRPC_SERVICE_NAME, REALITY_PRIVATE_KEY, REALITY_PUBLIC_KEY,
#     REALITY_SHORT_IDS (JSON array), SS2022_PASSWORD
#     (sourced via `sudo cat` + process substitution; `set -a` exports
#      for any child process that needs them)
#   - /etc/roost-travel/{travel,vpn}: "on" or "off" (writable by root)
#   - /etc/roost-travel/travel-cloudflare.yml: CF ingress fragment deployed
#     by integration-lead's manifest
#
# USERNAME resolution order (documented for integration-lead):
#   1. USERNAME env var from caller
#   2. USERNAME from $HOME/$ROOST_DIR_NAME/.sync-env
#   3. Fallback: `whoami` (the shell user invoking roost-net)
# No dedicated .owner file; .sync-env is the canonical source.
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

# Query IP's ASN via ipinfo.io. Returns 0 if Proton (AS62371 "Proton AG").
# Lenient on lookup failure: logs a warning and returns 0 to avoid blocking
# on transient network flakiness (e.g. ipinfo rate limit).
is_proton_asn() {
    local ip="$1" org
    if ! org=$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/org"); then
        logger -t "$_HOOK_TAG" -p user.warning "ipinfo lookup failed for $ip; treating as Proton"
        return 0
    fi
    if printf '%s\n' "$org" | grep -qiE 'proton|AS62371'; then
        return 0
    fi
    logger -t "$_HOOK_TAG" "ASN lookup for $ip: $org"
    return 1
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
        wg_status=$(systemctl is-active wg-quick@proton.service || true)
        echo "wg-quick@proton: $wg_status"
    fi

    echo
    local ip
    if ip=$(sudo -u xray curl -sf --max-time 5 https://api.ipify.org); then
        echo "Egress (default): $ip"
        if is_proton_asn "$ip"; then
            echo "  ASN: Proton"
        else
            echo "  ASN: Hetzner (or non-Proton)"
        fi
    else
        echo "Egress (default): unreachable"
    fi

    if [ "$vpn_state" = "on" ]; then
        local vpn_ip
        if vpn_ip=$(sudo -u xray curl -sf --max-time 5 --interface wg-proton https://api.ipify.org); then
            echo "Egress (wg-proton): $vpn_ip"
            if is_proton_asn "$vpn_ip"; then
                echo "  ASN: Proton"
            else
                echo "  ASN: non-Proton (unexpected — investigate)"
            fi
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
            echo "on" | sudo tee "$STATE_DIR/travel" >/dev/null
            trap - ERR
            ntfy_send -t "Travel ON" "Path A exposed + UFW open. Run 'roost-net-fw open' on laptop."
            echo "Travel mode: ON"
            ;;
        off)
            sudo rm -f "$cf_target"
            sudo "$assemble"
            sudo systemctl restart cloudflared
            sudo ufw --force delete allow 443/tcp || true
            sudo ufw --force delete allow 51820/tcp || true
            sudo ufw --force delete allow 51820/udp || true
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
            sudo test -f /etc/wireguard/proton.conf || die "No /etc/wireguard/proton.conf"
            if ! sudo systemctl enable --now wg-quick@proton; then
                sudo systemctl disable wg-quick@proton || true
                # wg-quick@ is Type=oneshot with RemainAfterExit=yes: if ExecStart
                # (wg-quick up) fails partway, ExecStop is NOT auto-invoked, so
                # PreDown (proton-routing.sh down) may not have run. Explicit
                # teardown prevents orphan fwmark/kill-switch rules.
                sudo /etc/roost-travel/proton-routing.sh down || true
                die "wg-quick@proton failed to start"
            fi
            local ip
            if ! ip=$(sudo -u xray curl -sf --max-time 10 --interface wg-proton https://api.ipify.org); then
                sudo systemctl disable --now wg-quick@proton
                die "Egress verification failed (no response via wg-proton)"
            fi
            if ! is_proton_asn "$ip"; then
                sudo systemctl disable --now wg-quick@proton
                die "Egress $ip is not a Proton ASN"
            fi
            sudo systemctl enable --now proton-keepalive.timer
            echo "on" | sudo tee "$STATE_DIR/vpn" >/dev/null
            ntfy_send -t "VPN ON" "Egress: $ip"
            echo "VPN mode: ON (egress $ip)"
            ;;
        off)
            sudo systemctl disable --now proton-keepalive.timer || true
            sudo systemctl disable --now wg-quick@proton || true
            echo "off" | sudo tee "$STATE_DIR/vpn" >/dev/null
            ntfy_send -t "VPN OFF" "Hetzner egress"
            echo "VPN mode: OFF"
            ;;
        *)
            die "Usage: roost-net vpn on|off"
            ;;
    esac
}

cmd_test() {
    local vpn_state pass=0 fail=0
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

    echo "--- fwmark masking (plan §4.2 highest-stakes) ---"
    # Match the full MARK rule emitted by proton-routing.sh: `--uid-owner <uid>
    # ... --set-xmark 0x1337/0xffff`. iptables canonicalizes the mask from
    # 0x0000ffff → 0xffff in `-S` output. UID may be symbolic or numeric.
    assert "iptables MARK for xray uid with 0xffff mask" \
        bash -c "sudo iptables -t mangle -S OUTPUT | grep -qE -- '--uid-owner [^ ]+ .*--set-xmark 0x1337/0xffff'"
    assert "ip6tables MARK for xray uid with 0xffff mask" \
        bash -c "sudo ip6tables -t mangle -S OUTPUT | grep -qE -- '--uid-owner [^ ]+ .*--set-xmark 0x1337/0xffff'"

    if [ "$vpn_state" = "on" ]; then
        echo "--- VPN on: routing, kill-switch, egress ---"
        assert "ip route table 51820 has default via wg-proton" \
            bash -c "ip route show table 51820 | grep -q 'default.*wg-proton'"
        assert "ip -6 route table 51820 has default via wg-proton" \
            bash -c "ip -6 route show table 51820 | grep -q 'default.*wg-proton'"
        assert "ip rule: fwmark 0x1337 lookup 51820" \
            bash -c "ip rule show | grep -q 'fwmark 0x1337 lookup 51820'"
        assert "ip -6 rule: fwmark 0x1337 lookup 51820" \
            bash -c "ip -6 rule show | grep -q 'fwmark 0x1337 lookup 51820'"
        # Kill-switch: xray uid without --interface wg-proton must NOT reach the internet.
        assert "kill-switch blocks xray default egress" \
            bash -c "! sudo -u xray curl -sf --max-time 5 https://api.ipify.org >/dev/null"
        # With --interface wg-proton: must succeed and be a Proton ASN.
        local vip
        if vip=$(sudo -u xray curl -sf --max-time 10 --interface wg-proton https://api.ipify.org); then
            echo "  [PASS] wg-proton egress reachable for xray ($vip)"
            pass=$((pass + 1))
            assert "wg-proton egress is Proton ASN" is_proton_asn "$vip"
        else
            echo "  [FAIL] wg-proton egress unreachable for xray"
            fail=$((fail + 1))
        fi
    else
        echo "--- VPN off: fwmark rules asserted, routing/kill-switch skipped ---"
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
    local short_id_0
    short_id_0=$(printf '%s' "$REALITY_SHORT_IDS" | jq -r '.[0]')
    jq -n \
        --arg domain "$DOMAIN" \
        --arg uuid "$XRAY_UUID" \
        --arg path "$XRAY_PATH" \
        --arg service_name "$GRPC_SERVICE_NAME" \
        --arg reality_public_key "$REALITY_PUBLIC_KEY" \
        --arg short_id "$short_id_0" \
        --arg ss_password "$SS2022_PASSWORD" \
        '{
            log: {level: "info"},
            dns: {
                servers: [
                    {tag: "cf-doh", address: "https://1.1.1.1/dns-query", detour: "direct"},
                    {tag: "block", address: "rcode://refused"}
                ],
                rules: [
                    {domain: ["travel.\($domain)", "travel-direct.\($domain)"], server: "cf-doh"}
                ]
            },
            inbounds: [
                {
                    type: "tun",
                    tag: "tun-in",
                    interface_name: "tun0",
                    inet4_address: "172.19.0.1/30",
                    inet6_address: "fdfe:dcba:9876::1/126",
                    auto_route: true,
                    strict_route: true,
                    stack: "system",
                    sniff: true
                }
            ],
            outbounds: [
                {type: "direct", tag: "direct"},
                {type: "block", tag: "block"},
                {type: "dns", tag: "dns-out"},
                {
                    type: "urltest",
                    tag: "urltest",
                    outbounds: ["path-a", "path-b", "path-c"],
                    url: "https://www.gstatic.com/generate_204",
                    interval: "3m",
                    tolerance: 200
                },
                {
                    type: "vless",
                    tag: "path-a",
                    server: "travel.\($domain)",
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
                        max_early_data: 0
                    }
                },
                {
                    type: "vless",
                    tag: "path-b",
                    server: "travel-direct.\($domain)",
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
                    tag: "path-c",
                    server: "travel-direct.\($domain)",
                    server_port: 51820,
                    method: "2022-blake3-chacha20-poly1305",
                    password: $ss_password
                }
            ],
            route: {
                auto_detect_interface: true,
                rules: [
                    {protocol: "dns", outbound: "dns-out"},
                    {ip_cidr: ["0.0.0.0/0", "::/0"], outbound: "urltest"}
                ]
            }
        }'
}

render_laptop() {
    # Laptop config = Android outbounds + local SOCKS5 inbound on 127.0.0.1:1080
    # so SSH ProxyCommand can chain through sing-box.
    render_android | jq '
        .inbounds = [
            .inbounds[0],
            {type: "socks", tag: "local-socks", listen: "127.0.0.1", listen_port: 1080, users: []}
        ]
        | .route.rules = [
            {protocol: "dns", outbound: "dns-out"},
            {inbound: ["local-socks"], outbound: "urltest"},
            {ip_cidr: ["0.0.0.0/0", "::/0"], outbound: "urltest"}
        ]
    '
}

render_ssh() {
    cat <<EOF
Host roost-travel
  HostName localhost
  Port 22
  User ${USERNAME}
  ProxyCommand ncat --proxy 127.0.0.1:1080 --proxy-type socks5 %h %p
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
    sudo test -x "$keys_init" || die "$keys_init missing or not executable"
    sudo "$keys_init" --force
    sudo systemctl restart xray.service
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
  vpn {on|off}               Toggle Proton egress (wg-quick@proton + keepalive)
  test                       Run plan §4.2 assertions (fwmark, routing, kill-switch)
  client {android|laptop|ssh}  Emit client config to stdout
  rotate-keys                Regenerate UUID + REALITY keys + SS-2022 password

See plans/travel-vpn-architecture.md for the full design.
EOF
        ;;
    *)
        echo "Unknown subcommand: $subcmd" >&2
        echo "Run 'roost-net help' for usage." >&2
        exit 1
        ;;
esac
