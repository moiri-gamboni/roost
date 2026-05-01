#!/bin/bash
# Laptop-side CLI for the roost-travel sing-box tunnel.
# Thin systemctl wrapper + config-refresh helpers.
set -euo pipefail

UNIT=roost-travel.service
CONFIG="$HOME/.config/sing-box/travel.json"
ENV_FILE="$HOME/.config/roost-travel/env"
# HETZNER_PUBLIC_IPV4 from the env file flags whether `status` shows
# "egress is going through the tunnel". Set HETZNER_PUBLIC_IPV4 (env file or shell).
HETZNER_IPV4="${HETZNER_PUBLIC_IPV4:-}"

# ROOST_SSH_TARGET is written by install-travel.sh from .env. Env var overrides.
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$ENV_FILE"
fi

usage() {
    cat <<EOF
Usage: roost-travel {on|off|status|logs|config}

  on       Start the tunnel (systemd). Best-effort config refresh first:
           falls back to the existing config if the server is unreachable.
  off      Stop the tunnel.
  status   Show tunnel state + current egress IP.
  logs     Tail journald output for the service.
  config   Explicit config refresh from the server; restarts the tunnel if
           it's already running. Fails loudly if the server is unreachable.
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
    # Write to .new with mode 0600 (preserves the secrecy of the SS-2022
    # password and UUID baked into the config).
    ( umask 077 && printf '%s\n' "$new_config" > "${CONFIG}.new" )
    chmod 0600 "${CONFIG}.new"
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
    local timeout="${1:-30}" deadline=$(( $(date +%s) + timeout ))
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

case "${1:-}" in
    on|up|start)       cmd_on ;;
    off|down|stop)     cmd_off ;;
    status)            cmd_status ;;
    logs)              cmd_logs ;;
    config)            cmd_config ;;
    help|-h|--help|'') usage ;;
    *)                 usage; exit 2 ;;
esac
