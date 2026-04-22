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

# Fetch sing-box config via ssh; write to $CONFIG. 0 = success, 1 = failure
# (no target, ssh blocked, roost-net missing). ssh -q suppresses handshake
# chatter so cmd_on stays quiet on the best-effort path; cmd_config prints
# its own actionable error.
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
    ( umask 077 && printf '%s\n' "$new_config" > "$CONFIG" )
    chmod 0600 "$CONFIG"
}

cmd_status() {
    local state egress
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        state="ON"
    else
        state="OFF"
    fi
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
    elif [ "$was_active" = 0 ]; then
        sudo systemctl start "$UNIT"
    fi
    sleep 1
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
        sleep 1
        cmd_status
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
