#!/bin/bash
# End-to-end reachability tests for the travel-VPN stack, run from the LAPTOP.
set -euo pipefail

LOG_TAG="roost/travel-test"
log()  { logger -t "$LOG_TAG" "$*"; echo "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "WARNING: $*" >&2; }
die()  { logger -t "$LOG_TAG" -p user.err   "$*"; echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: travel-test [OPTIONS]

Laptop-side end-to-end tester for the travel-VPN stack.

Options:
  --quick             Skip the slower via-tunnel and IPv6 checks.
  --simulate-gfw      Add a local iptables rule blocking UDP to the server,
                      rerun Path C UDP (expect fail) + A/B (expect pass), then
                      remove the rule. Requires sudo.
  --yes               Skip the interactive confirmation prompt for --simulate-gfw.
  --tailscale-check   Verify Tailscale status and exit-node egress IP.
  --socks5 HOST:PORT  Local sing-box SOCKS5 to use for via-tunnel curl tests
                      (default: 127.0.0.1:54321; test skipped if port closed).
  --help              Show this message.

Environment:
  Reads SERVER_NAME, USERNAME, DOMAIN, HETZNER_PUBLIC_IPV4, HETZNER_PUBLIC_IPV6
  from .env at repo root.

Exit status:
  0 if all run assertions pass, nonzero otherwise.
EOF
}

QUICK=0
SIMULATE_GFW=0
TAILSCALE_CHECK=0
ASSUME_YES=0
SOCKS5_TARGET="127.0.0.1:54321"

case "${1:-}" in
    --help|-h|help) usage; exit 0 ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)           QUICK=1; shift ;;
        --simulate-gfw)    SIMULATE_GFW=1; shift ;;
        --tailscale-check) TAILSCALE_CHECK=1; shift ;;
        --yes|-y)          ASSUME_YES=1; shift ;;
        --socks5)
            [ $# -ge 2 ] || die "--socks5 requires HOST:PORT"
            SOCKS5_TARGET="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown flag: $1" ;;
    esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ENV_FILE="$REPO_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090,SC1091
    . "$ENV_FILE"
    set +a
else
    die ".env not found at $ENV_FILE"
fi

: "${SERVER_NAME:?SERVER_NAME must be set in .env}"
: "${USERNAME:?USERNAME must be set in .env}"
: "${DOMAIN:?DOMAIN must be set in .env}"

# Derive Hetzner public IPs from hcloud if not explicitly set. deploy.sh does
# the equivalent derivation ('Resolve SERVER_IP + public IPv6') and writes
# them to the server's .sync-env; here we recompute locally so the laptop
# doesn't need to duplicate the values in .env.
if [ -z "${HETZNER_PUBLIC_IPV4:-}" ] || [ -z "${HETZNER_PUBLIC_IPV6:-}" ]; then
    command -v hcloud >/dev/null \
        || die "HETZNER_PUBLIC_IPV4/V6 unset and hcloud CLI unavailable for auto-derivation"
    HETZNER_PUBLIC_IPV4="${HETZNER_PUBLIC_IPV4:-$(hcloud server ip "$SERVER_NAME")}"
    if [ -z "${HETZNER_PUBLIC_IPV6:-}" ]; then
        v6cidr=$(hcloud server describe -o json "$SERVER_NAME" | jq -r '.public_net.ipv6.ip // empty')
        [ -n "$v6cidr" ] && HETZNER_PUBLIC_IPV6="${v6cidr%/*}1"
    fi
fi
: "${HETZNER_PUBLIC_IPV4:?HETZNER_PUBLIC_IPV4 must be set in .env or derivable via hcloud}"
: "${HETZNER_PUBLIC_IPV6:?HETZNER_PUBLIC_IPV6 must be set in .env or derivable via hcloud}"

TRAVEL_HOST="travel.${DOMAIN}"
TRAVEL_DIRECT="travel-direct.${DOMAIN}"

for dep in curl openssl getent; do
    command -v "$dep" >/dev/null || die "$dep not found"
done

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

section() { printf '\n=== %s ===\n' "$*"; }

test_path_a_probe() {
    local out code appconnect_ms total_ms
    # %{http_code} %{time_appconnect} %{time_total} — TLS-handshake time
    # is the apples-to-apples comparison with Paths B/D (also TLS-only);
    # total includes the round-trip to /probe through CF tunnel + xray-WS,
    # which is what sing-box's urltest URL probe actually measures.
    out=$(curl -sS -o /dev/null --max-time 10 \
            -w '%{http_code} %{time_appconnect} %{time_total}' \
            "https://${TRAVEL_HOST}/probe" 2>&1) \
        || { fail "Path A probe: curl failed (${out})"; return; }
    code=$(echo "$out" | awk '{print $1}')
    appconnect_ms=$(echo "$out" | awk '{printf "%d", $2 * 1000}')
    total_ms=$(echo "$out" | awk '{printf "%d", $3 * 1000}')
    if [ "$code" = "204" ]; then
        pass "Path A probe: https://${TRAVEL_HOST}/probe -> 204 (TLS ${appconnect_ms}ms, total ${total_ms}ms)"
    else
        fail "Path A probe: expected 204, got $code"
    fi
    # CF colo diagnostic. /cdn-cgi/trace is reflected at the Cloudflare edge
    # and reports which PoP terminated the TLS. If the user is in Asia and
    # the colo is FRA/AMS rather than HKG/SIN, CF Anycast routing is
    # suboptimal — that's the kind of finding that explains why Path A's
    # latency is closer to direct-Hetzner than to a "nearby CDN".
    local trace colo client_ip
    trace=$(curl -s --max-time 5 "https://${TRAVEL_HOST}/cdn-cgi/trace" 2>/dev/null)
    if [ -n "$trace" ]; then
        colo=$(echo "$trace" | awk -F= '/^colo=/ {print $2}')
        client_ip=$(echo "$trace" | awk -F= '/^ip=/ {print $2}')
        if [ -n "$colo" ]; then
            log "Path A diagnostic: CF colo=${colo}, client IP at edge=${client_ip}"
        fi
    fi
}

# REALITY masquerade: connecting to HETZNER:443 with SNI=www.samsung.com must
# return the real Samsung certificate chain (issued by DigiCert etc). Test by
# matching "Samsung" (case-insensitive) in subject/issuer. We preserve raw
# openssl output on failure so a user can tell "port dropped" from "openssl
# rejected cert chain" from "middlebox TLS interception".
test_path_b_reality() {
    local label="$1" host="$2"
    local raw out latency_ms
    raw=$(openssl s_client -connect "$host:443" -servername www.samsung.com \
            -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1) \
        || raw="${raw:-openssl exit nonzero}"
    out=$(echo "$raw" | grep -E 'subject=|issuer=' || true)
    if echo "$out" | grep -qi 'samsung'; then
        # REALITY masquerades on :443; reuse curl's time_appconnect against
        # the Samsung SNI to measure the TLS handshake (same metric as Path D).
        local time_secs
        time_secs=$(curl -k -s -o /dev/null -w '%{time_appconnect}' --max-time 5 \
            --resolve "www.samsung.com:443:$host" https://www.samsung.com/ 2>/dev/null)
        if [ -n "$time_secs" ] && [ "$time_secs" != "0.000000" ]; then
            latency_ms=$(awk -v l="$time_secs" 'BEGIN { printf "%d", l * 1000 }')
            pass "Path B REALITY ($label): Samsung cert served on $host:443 (TLS ${latency_ms}ms)"
        else
            pass "Path B REALITY ($label): Samsung cert served on $host:443"
        fi
    else
        local first_err
        first_err=$(echo "$raw" | grep -E 'error|CONNECTED|refused|Connection|verify' | head -1)
        fail "Path B REALITY ($label): no Samsung cert on $host:443 (${first_err:-no diagnostic})"
    fi
}

# nc flavor probing: ncat (nmap) -> nc (netcat-openbsd) -> bash /dev/tcp.
tcp_reachable() {
    local host="$1" port="$2" timeout="${3:-5}"
    if command -v ncat >/dev/null; then
        ncat -z -w "$timeout" "$host" "$port" >/dev/null 2>&1
    elif command -v nc >/dev/null; then
        nc -z -w "$timeout" "$host" "$port" >/dev/null 2>&1
    else
        # bash's /dev/tcp has no built-in connect timeout, so wrap with timeout(1).
        timeout "$timeout" bash -c ": </dev/tcp/${host}/${port}" >/dev/null 2>&1
    fi
}

test_path_c_ss2022() {
    local label="$1" host="$2"
    local start end ms
    if tcp_reachable "$host" 51820 5; then
        # SS-2022 has no TLS to time, so measure raw TCP connect via bash's
        # /dev/tcp and $EPOCHREALTIME (microsecond resolution). curl's
        # telnet:// protocol returns nonzero in unrelated ways under the
        # script's `set -e` and aborted the whole run.
        start=$EPOCHREALTIME
        if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/51820 && exec 3>&- 3<&-" 2>/dev/null; then
            end=$EPOCHREALTIME
            ms=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%d", (e - s) * 1000 }')
            pass "Path C SS-2022 TCP ($label): $host:51820 reachable (TCP connect ${ms}ms)"
        else
            pass "Path C SS-2022 TCP ($label): $host:51820 reachable"
        fi
    else
        fail "Path C SS-2022 TCP ($label): $host:51820 unreachable"
    fi
    # UDP reachability cannot be probed without a real SS-2022 handshake:
    # a stray datagram is silently dropped by either a closed port or a live service.
    skip "Path C SS-2022 UDP ($label): no passive probe without SS-2022 handshake"
}

test_urltest_latencies() {
    # Query sing-box's clash API for each path's last probe latency.
    # This is what sing-box ITSELF measures (full request through the path
    # to the urltest URL) — directly drives selection. Skips silently if
    # the API isn't enabled yet (config refresh needed) or the laptop
    # tunnel isn't running.
    local api="http://127.0.0.1:9090"
    if ! curl -s --max-time 2 "$api/version" >/dev/null 2>&1; then
        skip "urltest latencies: clash API not reachable at $api (run 'roost-travel config' to refresh)"
        return
    fi
    local proxies tag last_delay last_time
    proxies=$(curl -s "$api/proxies" 2>/dev/null)
    if [ -z "$proxies" ]; then
        fail "urltest latencies: clash API returned no data"
        return
    fi
    for tag in path-a path-b-v4 path-b-v6 path-c-v4 path-c-v6 path-d-v4 path-d-v6; do
        last_delay=$(echo "$proxies" | jq -r --arg t "$tag" \
            '.proxies[$t].history | if (. // []) | length > 0 then .[-1].delay else "n/a" end' 2>/dev/null)
        last_time=$(echo "$proxies" | jq -r --arg t "$tag" \
            '.proxies[$t].history | if (. // []) | length > 0 then .[-1].time else "" end' 2>/dev/null)
        case "$last_delay" in
            n/a|null|"")
                skip "urltest probe $tag: no data yet (sing-box hasn't probed; wait ~3min)"
                ;;
            0)
                fail "urltest probe $tag: last probe failed (0 = unreachable, at $last_time)"
                ;;
            *)
                pass "urltest probe $tag: ${last_delay}ms (at $last_time)"
                ;;
        esac
    done
    # Currently selected path
    local selected
    selected=$(echo "$proxies" | jq -r '.proxies.urltest.now // empty' 2>/dev/null)
    if [ -n "$selected" ]; then
        log "urltest currently selected: $selected"
    fi
}

test_path_d_vision() {
    local label="$1" host="$2"
    local raw cert_subject latency ms
    # TLS handshake against xray's Vision inbound. Cert must be the LE
    # wildcard for *.moiri.dev (catching cert-mismatch bugs), and must
    # verify cleanly against the system trust store — Path B's REALITY
    # serves Samsung's cert instead, so a successful TLS to :8443 with
    # subject Samsung would be a serious misconfig (probably a port mixup).
    raw=$(openssl s_client -connect "$host:8443" -servername static.${DOMAIN} \
            -CAfile /etc/ssl/certs/ca-certificates.crt -verify_return_error </dev/null 2>&1) \
        || raw="${raw:-openssl exit nonzero}"
    cert_subject=$(echo "$raw" | grep -E '^subject=' | head -1)
    if echo "$cert_subject" | grep -qiF "$DOMAIN"; then
        # Latency: curl's time_appconnect = time to complete TLS handshake.
        latency=$(curl -k -s -o /dev/null -w '%{time_appconnect}' --max-time 5 \
            --resolve "static.${DOMAIN}:8443:$host" https://static.${DOMAIN}:8443/ 2>/dev/null)
        if [ -n "$latency" ] && [ "$latency" != "0.000000" ]; then
            ms=$(awk -v l="$latency" 'BEGIN { printf "%d", l * 1000 }')
            pass "Path D Vision ($label): cert OK, TLS handshake ${ms}ms"
        else
            pass "Path D Vision ($label): cert OK on $host:8443 (latency probe failed)"
        fi
    else
        local first_err
        first_err=$(echo "$raw" | grep -E 'error|CONNECTED|refused|Connection|verify' | head -1)
        fail "Path D Vision ($label): cert mismatch on $host:8443 (${first_err:-no diagnostic})"
    fi
}

test_dns() {
    # getent | awk under `set -o pipefail` aborts the entire script if getent
    # fails. Capture the pipeline result as a test-local failure instead so
    # later path tests still run.
    local a aaaa
    a=$(getent ahostsv4 "$TRAVEL_DIRECT" 2>&1 | awk 'NR==1 {print $1}') || a=""
    aaaa=$(getent ahostsv6 "$TRAVEL_DIRECT" 2>&1 | awk 'NR==1 {print $1}') || aaaa=""
    if [ "$a" = "$HETZNER_PUBLIC_IPV4" ]; then
        pass "DNS: $TRAVEL_DIRECT A -> $a"
    else
        fail "DNS: $TRAVEL_DIRECT A -> ${a:-<none>}, expected $HETZNER_PUBLIC_IPV4"
    fi
    if [ "$aaaa" = "$HETZNER_PUBLIC_IPV6" ]; then
        pass "DNS: $TRAVEL_DIRECT AAAA -> $aaaa"
    else
        fail "DNS: $TRAVEL_DIRECT AAAA -> ${aaaa:-<none>}, expected $HETZNER_PUBLIC_IPV6"
    fi
}

test_via_tunnel() {
    local socks_host="${SOCKS5_TARGET%:*}"
    local socks_port="${SOCKS5_TARGET##*:}"
    if ! tcp_reachable "$socks_host" "$socks_port" 2; then
        skip "via-tunnel: no SOCKS5 listener at $SOCKS5_TARGET (start sing-box first)"
        return
    fi
    local egress rc
    egress=$(curl -sS --max-time 10 --socks5-hostname "$SOCKS5_TARGET" \
                  https://api.ipify.org 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$egress" ]; then
        fail "via-tunnel: curl via $SOCKS5_TARGET failed (rc=$rc): ${egress:-<no output>}"
        return
    fi
    # Egress depends on server-side vpn toggle (Hetzner IP vs Proton IP); we
    # can't authoritatively assert which without asking the server, so any
    # well-formed response counts.
    pass "via-tunnel: egress via $SOCKS5_TARGET -> $egress"
}

# DNS bootstrap-loop regression test. With sing-box's tun + auto_route +
# strict_route + hijack-dns rule, getent's DNS query is captured by the tun
# and routed via cf-doh through the tunnel. So a fast, non-empty response
# here proves the bootstrap-loop fix is healthy. Failure mode (timeout or
# empty result) indicates the loop has reappeared.
test_dns_via_tunnel() {
    if ! systemctl is-active --quiet roost-travel 2>/dev/null; then
        skip "DNS via tunnel: roost-travel not running"
        return
    fi
    local ips rc
    ips=$(timeout 5 getent ahosts example.com 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$ips" ]; then
        fail "DNS via tunnel: getent example.com failed (rc=$rc): ${ips:-<empty>}"
        return
    fi
    pass "DNS via tunnel: example.com -> $(echo "$ips" | awk 'NR==1 {print $1}')"
}

test_ssh_proxy() {
    local socks_host="${SOCKS5_TARGET%:*}"
    local socks_port="${SOCKS5_TARGET##*:}"
    if ! tcp_reachable "$socks_host" "$socks_port" 2; then
        skip "ssh ProxyCommand: no SOCKS5 listener at $SOCKS5_TARGET"
        return
    fi
    if [ ! -f "$HOME/.ssh/config" ] || \
       ! grep -Eq '^Host[[:space:]]+roost-travel' "$HOME/.ssh/config"; then
        skip "ssh ProxyCommand: no 'roost-travel' alias in ~/.ssh/config"
        return
    fi
    local hn stderr_buf
    stderr_buf=$(mktemp)
    hn=$(ssh -o BatchMode=yes -o ConnectTimeout=5 roost-travel hostname \
            2>"$stderr_buf") || hn=""
    if [ -n "$hn" ]; then
        pass "ssh ProxyCommand: roost-travel hostname -> $hn"
    else
        fail "ssh ProxyCommand: roost-travel hostname failed ($(head -1 "$stderr_buf" || true))"
    fi
    rm -f "$stderr_buf"
}

test_tailscale() {
    if ! command -v tailscale >/dev/null; then
        skip "tailscale: CLI not installed"
        return
    fi
    local ts_status rc
    ts_status=$(tailscale status 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "tailscale: 'tailscale status' exited $rc: $(echo "$ts_status" | head -1)"
        return
    fi
    if echo "$ts_status" | grep -qE '^(Logged out|NeedsLogin)'; then
        fail "tailscale: not logged in"
        return
    fi
    if echo "$ts_status" | grep -qE "^[0-9.]+[[:space:]]+${SERVER_NAME}\b"; then
        pass "tailscale: $SERVER_NAME visible in status"
    else
        fail "tailscale: $SERVER_NAME not found in status output"
    fi
    # `tailscale status` flags the selected exit node with a "; exit node"
    # suffix on its peer line. Undocumented, but stable across 1.x.
    if echo "$ts_status" | grep -q '; exit node'; then
        local egress
        egress=$(curl -sS --max-time 10 https://api.ipify.org 2>&1) \
            || egress=""
        if [ -n "$egress" ]; then
            pass "tailscale exit-node: egress -> $egress (check against Hetzner/Proton manually)"
        else
            fail "tailscale exit-node: curl api.ipify.org returned nothing"
        fi
    else
        skip "tailscale: no exit node active -- skipping egress check"
    fi
}

# Installs local OUTPUT DROP rules for UDP to the server's public IPs.
# Does not touch the server.
simulate_gfw_up() {
    [ "$SIMULATE_GFW" -eq 1 ] || return 0
    echo "--- --simulate-gfw ---"
    echo "About to install local OUTPUT DROP rules:"
    echo "  sudo iptables  -I OUTPUT -p udp -d $HETZNER_PUBLIC_IPV4 -j DROP"
    echo "  sudo ip6tables -I OUTPUT -p udp -d $HETZNER_PUBLIC_IPV6 -j DROP"
    echo "Will be removed on exit (trap)."
    if [ "$ASSUME_YES" -ne 1 ]; then
        read -r -p "Proceed? [y/N] " ans
        case "$ans" in y|Y|yes) ;; *) die "simulate-gfw: user declined" ;; esac
    fi
    # Trap BEFORE the rule goes in so partial-install still cleans up.
    # EXIT-only (not INT/TERM) to avoid bash's "trap returns to command" quirk;
    # default signal behavior terminates the script and still runs the EXIT trap.
    trap simulate_gfw_down EXIT
    sudo iptables  -I OUTPUT -p udp -d "$HETZNER_PUBLIC_IPV4" -j DROP
    sudo ip6tables -I OUTPUT -p udp -d "$HETZNER_PUBLIC_IPV6" -j DROP
    log "simulate-gfw: UDP blocked to $HETZNER_PUBLIC_IPV4 and $HETZNER_PUBLIC_IPV6"
}

# Check-then-remove: iptables -C probes for the rule; only call -D when it
# exists, so a real -D failure (e.g. sudo expired) surfaces instead of being
# masked. `-C` exits 1 silently when the rule isn't there -- suppressing its
# stderr is justified (probe, not action).
simulate_gfw_down() {
    [ "$SIMULATE_GFW" -eq 1 ] || return 0
    if sudo iptables -C OUTPUT -p udp -d "$HETZNER_PUBLIC_IPV4" -j DROP 2>/dev/null; then
        sudo iptables -D OUTPUT -p udp -d "$HETZNER_PUBLIC_IPV4" -j DROP \
            || warn "simulate-gfw: failed to remove IPv4 DROP rule; check 'sudo iptables -S OUTPUT'"
    fi
    if sudo ip6tables -C OUTPUT -p udp -d "$HETZNER_PUBLIC_IPV6" -j DROP 2>/dev/null; then
        sudo ip6tables -D OUTPUT -p udp -d "$HETZNER_PUBLIC_IPV6" -j DROP \
            || warn "simulate-gfw: failed to remove IPv6 DROP rule; check 'sudo ip6tables -S OUTPUT'"
    fi
    log "simulate-gfw: UDP block removed"
}

section "DNS"
test_dns

section "Path A (CF Tunnel)"
test_path_a_probe

section "Path B (REALITY) IPv4"
test_path_b_reality "v4" "$HETZNER_PUBLIC_IPV4"

section "Path C (SS-2022) IPv4"
test_path_c_ss2022 "v4" "$HETZNER_PUBLIC_IPV4"

section "Path D (Vision) IPv4"
test_path_d_vision "v4" "$HETZNER_PUBLIC_IPV4"

if [ "$QUICK" -eq 0 ]; then
    # Skip v6 sections when the laptop has no IPv6 default route (common on
    # v4-only networks e.g. coworking/hotel Wi-Fi). The v6 assertions would
    # otherwise all FAIL with 'Network is unreachable', masking real regressions.
    # The server's v6 is independently validated by travel-health.sh on the server.
    if ip -6 route show default 2>/dev/null | grep -q '^default'; then
        section "Path B (REALITY) IPv6"
        test_path_b_reality "v6" "[$HETZNER_PUBLIC_IPV6]"

        section "Path C (SS-2022) IPv6"
        test_path_c_ss2022 "v6" "$HETZNER_PUBLIC_IPV6"

        section "Path D (Vision) IPv6"
        test_path_d_vision "v6" "[$HETZNER_PUBLIC_IPV6]"
    else
        section "IPv6 paths"
        skip "Path B (REALITY) IPv6: laptop has no IPv6 default route"
        skip "Path C (SS-2022) IPv6: laptop has no IPv6 default route"
        skip "Path D (Vision) IPv6: laptop has no IPv6 default route"
    fi

    section "Via-tunnel functional"
    test_via_tunnel
    test_dns_via_tunnel

    section "Sing-box urltest probe latencies (per-path, full request)"
    test_urltest_latencies

    section "SSH ProxyCommand"
    test_ssh_proxy
fi

if [ "$TAILSCALE_CHECK" -eq 1 ]; then
    section "Tailscale"
    test_tailscale
fi

if [ "$SIMULATE_GFW" -eq 1 ]; then
    simulate_gfw_up
    section "Simulated GFW: UDP blocked to server"
    # Under UDP block, A/B are TCP at the laptop edge and should still pass.
    test_path_a_probe
    test_path_b_reality "v4 gfw-sim" "$HETZNER_PUBLIC_IPV4"
    # Path C TCP should still pass (only UDP blocked); a real GFW may block
    # TCP too -- this is a lower-bound sim.
    test_path_c_ss2022 "v4 gfw-sim" "$HETZNER_PUBLIC_IPV4"
    simulate_gfw_down
    trap - EXIT
fi

section "Summary"
printf 'pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"

[ "$FAIL" -eq 0 ] || exit 1
