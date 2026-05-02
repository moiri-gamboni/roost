#!/bin/bash
# Laptop-side CLI for the roost-travel sing-box tunnel.
# Thin systemctl wrapper + config-refresh helpers.
set -euo pipefail

UNIT=roost-travel.service
CONFIG="$HOME/.config/sing-box/travel.json"
ENV_FILE="$HOME/.config/roost-travel/env"

# ROOST_SSH_TARGET + DOMAIN are written by install-travel.sh from .env.
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$ENV_FILE"
fi

# Hetzner public IPv4: derive from `travel-direct.$DOMAIN` at runtime so the
# code is fork-portable. HETZNER_PUBLIC_IPV4 env var (or .env override sourced
# above) wins if explicitly set; otherwise resolve via DNS. Used by `status`
# to flag "egress is going through the tunnel" vs Proton; missing/empty just
# means the annotation falls through to the generic "external" message.
HETZNER_IPV4="${HETZNER_PUBLIC_IPV4:-$(getent ahostsv4 "travel-direct.${DOMAIN:-}" 2>/dev/null | awk 'NR==1 {print $1}')}"

usage() {
    cat <<EOF
Usage: roost-travel {on|off|status|logs|config|ips}

  on       Start the tunnel (systemd). Best-effort config refresh first:
           falls back to the existing config if the server is unreachable.
  off      Stop the tunnel.
  status   Show tunnel state + current egress IP.
  logs     Tail journald output for the service.
  config   Explicit config refresh from the server; restarts the tunnel if
           it's already running. Fails loudly if the server is unreachable.
  ips      Probe CF Anycast IPs from the laptop's network with cfst, push
           the top N (latency-ranked) to the server's cf-preferred-ip, then
           refresh sing-box config. Run when CF reachability changes (new
           network, IPs blocked, etc.). Takes 1-3 minutes.
EOF
}

# Fetch sing-box config via ssh; validate with `sing-box check`; atomic-swap
# into $CONFIG. 0 = success, 1 = failure (no target, ssh blocked, roost-net
# missing, or rendered config fails sing-box check). ssh -q suppresses
# handshake chatter so cmd_on stays quiet on the best-effort path; cmd_config
# prints its own actionable error.
#
# The validate-then-swap pattern protects against a render bug shipping a
# broken config that the systemd unit then loops on with Restart=on-failure.
# It must live in fetch_config (not in cmd_config) so cmd_on gets the same
# protection — otherwise cmd_on's invocation would leave orphan .new files.
fetch_config() {
    local target="${ROOST_SSH_TARGET:-}" new_config
    [ -n "$target" ] || return 1
    # -n detaches stdin so capture doesn't deadlock on prompts.
    # BatchMode=yes fails fast instead of prompting for a password.
    # ConnectTimeout=10 refuses to hang on flaky hotel networks.
    # bash -lc so ~/bin lands on PATH (login shell sources .profile on Ubuntu).
    new_config=$(ssh -q -n -o BatchMode=yes -o ConnectTimeout=10 "$target" \
        "bash -lc 'roost-net client laptop'") || return 1
    [ -n "$new_config" ] || return 1
    install -d -m 0700 "$(dirname "$CONFIG")"
    # Write to .new with mode 0600 — umask 077 in the subshell sets it; the
    # SS-2022 password and UUID baked into the config are sensitive.
    ( umask 077 && printf '%s\n' "$new_config" > "${CONFIG}.new" )
    # Inject tun.exclude_uid so cfst-probe's traffic bypasses the tun and
    # exits via the underlying interface — needed by 'roost-travel ips' to
    # measure laptop->CF latency directly. Sing-box's exclude_uid rules
    # outrank strict_route's blocking rules, so the bypass works under
    # strict_route. No-op for legacy installs pre-dating install-travel.sh
    # adding the cfst-probe user.
    if getent passwd cfst-probe >/dev/null && command -v jq >/dev/null; then
        local cfst_uid
        cfst_uid=$(id -u cfst-probe)
        if ( umask 077 && jq --argjson uid "$cfst_uid" \
                '.inbounds[0].exclude_uid = [$uid]' \
                "${CONFIG}.new" > "${CONFIG}.new.tmp" ); then
            mv "${CONFIG}.new.tmp" "${CONFIG}.new"
        else
            rm -f "${CONFIG}.new.tmp"
            echo "WARNING: jq exclude_uid injection failed; 'roost-travel ips' will refuse until config is regenerated." >&2
        fi
    fi
    # Validate before swap. Failure = leave old config alone, no orphan.
    if ! sing-box check -c "${CONFIG}.new" >&2; then
        echo "Rendered config failed sing-box check; keeping previous config." >&2
        rm -f "${CONFIG}.new"
        return 1
    fi
    # Atomic swap.
    mv "${CONFIG}.new" "$CONFIG"
}

# Wait for the tunnel to come up post-restart: poll api.ipify.org through
# the system network (which sing-box's tun captures) until DNS bootstrap
# completes and the egress is actually reachable. Used by cmd_config /
# cmd_on after a sing-box restart so the subsequent cmd_status print
# isn't a misleading "unreachable" snapshot of the cold-start window.
wait_for_tunnel() {
    local timeout="${1:-30}"
    local deadline=$(( $(date +%s) + timeout ))
    printf 'Waiting for tunnel...'
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -s --max-time 3 https://api.ipify.org >/dev/null 2>&1; then
            printf ' ready\n'
            return 0
        fi
        printf '.'
        sleep 1
    done
    printf ' timed out (%ds)\n' "$timeout" >&2
    return 1
}

cmd_status() {
    local state egress
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        state="ON"
    else
        state="OFF"
    fi
    # Single attempt — fast for standalone `roost-travel status`. Callers
    # that want to wait for the tunnel to come up after restart use
    # wait_for_tunnel before invoking cmd_status.
    egress=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo unreachable)
    echo "Tunnel: $state"
    # Selected urltest path + its last-probe latency, when tunnel is up.
    # Pulled from sing-box's clash API at 127.0.0.1:47200; fails silently if
    # the API isn't bound (e.g. config without `experimental.clash_api`).
    # Latency is the most recent /proxies/<tag>/history entry (urltest writes
    # one per 3-min re-probe), so it can be up to 3min stale — accurate
    # enough for a status line, no need to force a fresh probe here.
    if [ "$state" = "ON" ]; then
        local proxies selected latency
        proxies=$(curl -s --max-time 2 'http://127.0.0.1:47200/proxies' 2>/dev/null || true)
        if [ -n "$proxies" ]; then
            selected=$(printf '%s' "$proxies" | jq -r '.proxies.urltest.now // empty' 2>/dev/null || true)
            if [ -n "$selected" ]; then
                latency=$(printf '%s' "$proxies" \
                    | jq -r --arg s "$selected" '.proxies[$s].history[-1].delay // empty' 2>/dev/null || true)
                if [ -n "$latency" ] && [ "$latency" != "0" ]; then
                    echo "Path:   $selected (${latency}ms)"
                else
                    echo "Path:   $selected (latency unknown — startup probe pending?)"
                fi
            fi
        fi
    fi
    echo "Egress: $egress"
    # Server vpn=off → egress is our Hetzner IP. Server vpn=on → egress is
    # whatever Proton profile is active (varies per location). Anything else
    # reachable is almost certainly Proton; a real leak would bypass sing-box
    # entirely and show the laptop's ISP IP, which we can't pre-enumerate.
    if [ "$state" = "ON" ] && [ "$egress" = "$HETZNER_IPV4" ]; then
        echo "  (Hetzner — roost direct, server vpn=off)"
    elif [ "$state" = "ON" ] && [ "$egress" != "unreachable" ]; then
        echo "  (external — via roost + Proton, server vpn=on)"
    fi
}

cmd_on() {
    local was_active=0 fetched=0
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        was_active=1
    fi

    if fetch_config; then
        fetched=1
        echo "Config refreshed from server."
    elif [ -f "$CONFIG" ]; then
        echo "Couldn't reach server to refresh config; using existing $CONFIG." >&2
    else
        echo "Config missing at $CONFIG and can't fetch from server." >&2
        echo "Checks: Tailscale up? ROOST_SSH_TARGET set in $ENV_FILE?" >&2
        exit 1
    fi

    # enable for reboot persistence (idempotent; matches server-side `roost-net
    # vpn on` where toggling on also persists).
    sudo systemctl enable "$UNIT"
    if [ "$was_active" = 1 ] && [ "$fetched" = 1 ]; then
        echo "Restarting to load new config..."
        sudo systemctl restart "$UNIT"
        wait_for_tunnel 30 || true
    elif [ "$was_active" = 0 ]; then
        sudo systemctl start "$UNIT"
        wait_for_tunnel 30 || true
    fi
    cmd_status
}

cmd_off() {
    # disable --now = stop + disable. Both toggled in lockstep.
    if ! sudo systemctl disable --now "$UNIT"; then
        echo "Service failed to stop cleanly. Inspect with: sudo journalctl -u $UNIT -n 30" >&2
        exit 1
    fi
    sleep 1
    cmd_status
}

cmd_logs() {
    sudo journalctl -u "$UNIT" -f -n 50
}

cmd_config() {
    local sb_version
    sb_version=$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || echo unknown)
    echo "[sing-box ${sb_version} on laptop]"
    if ! fetch_config; then
        echo "Failed to fetch config from '${ROOST_SSH_TARGET:-<unset>}'." >&2
        echo "Checks: Tailscale up? roost-net installed on server? $ENV_FILE present?" >&2
        exit 1
    fi
    echo "Config written to $CONFIG."
    # If the tunnel is currently running, the service is holding the old config
    # in memory — restart to pick up changes.
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        echo "Service is running; restarting to load new config..."
        sudo systemctl restart "$UNIT"
        wait_for_tunnel 30 || true
        cmd_status
    else
        echo "Service is not running; not starting automatically (use 'roost-travel on' to start)."
    fi
}

# Probe CF Anycast IPs from the laptop's actual network (cfst's TCP-443 ping
# against ~5000 sampled /24s in CF's published prefixes), pick the top N by
# latency, push to the server's cf-preferred-ip. The server's render then
# bakes those IPs as path-a-ipN outbounds and sing-box's urltest auto-selects
# the live one with lowest latency. Re-run when reachability changes (new
# network, IPs blocked, etc.).
cmd_ips() {
    local target="${ROOST_SSH_TARGET:-}"
    [ -n "$target" ] || { echo "ROOST_SSH_TARGET not set in $ENV_FILE" >&2; exit 1; }
    command -v cfst >/dev/null \
        || { echo "cfst not installed; rerun install-travel.sh" >&2; exit 1; }
    command -v jq >/dev/null \
        || { echo "jq not installed; rerun install-travel.sh" >&2; exit 1; }
    getent passwd cfst-probe >/dev/null \
        || { echo "cfst-probe user missing; rerun install-travel.sh" >&2; exit 1; }

    # cfst-probe's UID is in tun.exclude_uid (injected by fetch_config), so
    # `sudo -u cfst-probe cfst` probes the underlying network directly.
    # Without the bypass, all CF IPs would report uniform tunnel latency.
    local cfst_uid
    cfst_uid=$(id -u cfst-probe)

    # Confirm the live config carries the bypass — guards the case where
    # fetch_config ran before cfst-probe existed (or jq injection failed).
    if ! jq -e --argjson uid "$cfst_uid" \
            '(.inbounds[0].exclude_uid // []) | index($uid) != null' \
            "$CONFIG" >/dev/null; then
        echo "Config $CONFIG doesn't exclude cfst-probe (uid $cfst_uid) from tun." >&2
        echo "Run 'roost-travel config' to refresh, then retry." >&2
        exit 1
    fi

    local n_top=5
    local ip_list=/usr/local/share/cfst/ip.txt
    [ -r "$ip_list" ] || { echo "$ip_list missing; rerun install-travel.sh" >&2; exit 1; }
    # Per-run unique name avoids racing a stale cfst-probe-owned file in
    # sticky /tmp. cfst creates the file with the system-default umask
    # (0644 from /etc/login.defs); we read it then leave it for
    # systemd-tmpfiles to clean (the laptop user can't unlink files owned
    # by cfst-probe in /tmp's sticky dir).
    local out
    out=$(mktemp -u --suffix=.csv /tmp/cfst-result-XXXXXX)

    echo "Probing CF Anycast IPs via underlying network (1-3 min, tunnel stays up)..."
    # cfst writes log files (ip.txt cache, debug) to CWD; cd to /tmp.
    # -dd disables download speed test (latency-only is enough for proxy use).
    # -p 0 suppresses cfst's own stdout summary; we parse the CSV ourselves.
    # -dn keeps top N by latency.
    if ! ( cd /tmp && sudo -u cfst-probe cfst -tp 443 -dd -p 0 -dn "$n_top" -f "$ip_list" -o "$out" ); then
        echo "cfst probe failed (binary error or interrupt)." >&2
        exit 1
    fi

    if [ ! -s "$out" ]; then
        # Hostile-network case: cfst couldn't reach any CF IP. Existing
        # cf-preferred-ip stays in place; urltest already routes around
        # dead IPs at 1m granularity. Exit 0 so the timer's OnFailure
        # doesn't fire for an expected condition.
        echo "cfst returned no working IPs (full CF block on this network?); keeping existing cf-preferred-ip." >&2
        exit 0
    fi

    # CSV header: 'IP 地址,已发送,...'; data rows start at line 2. Column 1 = IP.
    # Single awk pass instead of `tail | cut | head -N` — head closes its stdin
    # after N lines, which SIGPIPEs the upstream `cut`; with `set -o pipefail`
    # that kills the script. awk reads to EOF, no broken-pipe failures.
    local top_ips
    top_ips=$(awk -F, -v n="$n_top" 'NR > 1 && NR <= n+1 {print $1}' "$out")
    [ -n "$top_ips" ] || { echo "cfst CSV had header but no rows" >&2; exit 1; }

    echo
    echo "Top $n_top CF IPs by latency:"
    awk -F, -v n="$n_top" 'NR > 1 && NR <= n+1 {printf "  %-15s  %s ms (loss %s)\n", $1, $5, $4}' "$out"

    echo
    echo "Pushing to $target:~/roost/travel/cf-preferred-ip..."
    printf '%s\n' "$top_ips" \
        | ssh -q "$target" 'mkdir -p ~/roost/travel && tee ~/roost/travel/cf-preferred-ip > /dev/null' \
        || { echo "ssh push failed" >&2; exit 1; }
    echo "Pushed."

    echo
    echo "Fetching updated sing-box config..."
    if ! fetch_config; then
        echo "Config fetch failed; cf-preferred-ip on server is updated but laptop config is stale." >&2
        exit 1
    fi
    echo "Config written to $CONFIG."

    # sing-box has no in-process config reload, so a brief restart (~3-15s)
    # is needed to pick up the new path-a-ipN outbounds. Passwordless via
    # /etc/sudoers.d/roost-travel-cfst.
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        echo "Restarting tunnel to load new IPs..."
        sudo systemctl restart "$UNIT"
        wait_for_tunnel 30 || true
    else
        echo "Tunnel was off; new config saved for next 'roost-travel on'."
    fi
    cmd_status
}

case "${1:-}" in
    on|up|start)       cmd_on ;;
    off|down|stop)     cmd_off ;;
    status)            cmd_status ;;
    logs)              cmd_logs ;;
    config)            cmd_config ;;
    ips)               cmd_ips ;;
    help|-h|--help|'') usage ;;
    *)                 usage; exit 2 ;;
esac
