#!/bin/bash
# Detect config changes and reload affected services.
# Run with no args to auto-detect changes, or use flags to target specific services.
#
# Usage: roost-apply [--all] [--cloudflare] [--caddy] [--ntfy] [--systemd] [--cron]
set -euo pipefail
source "$(dirname "$0")/_hook-env.sh"

CHECKSUM_DIR="$HOME/.cache/roost-apply"
CHECKSUM_FILE="$CHECKSUM_DIR/checksums"
mkdir -p "$CHECKSUM_DIR"

# --- Config file → service mapping ---
# Format: destination_path:service_action
# Service actions:
#   reload-or-restart:<unit>   - systemctl reload-or-restart
#   restart:<unit>             - systemctl restart
#   daemon-reload              - just needs daemon-reload (no restart)
#   daemon-reload+restart:<unit> - daemon-reload then restart
#   none                       - no service action needed (e.g. cron auto-reloads)
declare -A CONFIG_MAP=(
    ["/etc/caddy/Caddyfile"]="reload-or-restart:caddy"
    ["/etc/cloudflared/config.yml"]="restart:cloudflared"
    ["/etc/ntfy/server.yml"]="restart:ntfy"
    ["/etc/systemd/system/caddy.service.d/tailscale.conf"]="daemon-reload"
    ["/etc/systemd/system/syncthing@.service.d/tailscale.conf"]="daemon-reload"
    ["/etc/systemd/system/glances.service"]="daemon-reload+restart:glances"
    ["/etc/systemd/system/ram-monitor.service"]="daemon-reload"
    ["/etc/systemd/system/ram-monitor.timer"]="daemon-reload+restart:ram-monitor.timer"
)

# Cron file path depends on ROOST_DIR_NAME
CRON_FILE="/etc/cron.d/${ROOST_DIR_NAME:-roost}"
CONFIG_MAP["$CRON_FILE"]="none"

# --- Group configs by service flag ---
declare -A FLAG_MAP=(
    ["/etc/caddy/Caddyfile"]="caddy"
    ["/etc/cloudflared/config.yml"]="cloudflare"
    ["/etc/ntfy/server.yml"]="ntfy"
    ["/etc/systemd/system/caddy.service.d/tailscale.conf"]="systemd"
    ["/etc/systemd/system/syncthing@.service.d/tailscale.conf"]="systemd"
    ["/etc/systemd/system/glances.service"]="systemd"
    ["/etc/systemd/system/ram-monitor.service"]="systemd"
    ["/etc/systemd/system/ram-monitor.timer"]="systemd"
)
FLAG_MAP["$CRON_FILE"]="cron"

# --- Parse arguments ---
FLAG_ALL=false
FLAG_CLOUDFLARE=false
FLAG_CADDY=false
FLAG_NTFY=false
FLAG_SYSTEMD=false
FLAG_CRON=false
HAS_FLAGS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)        FLAG_ALL=true; HAS_FLAGS=true ;;
        --cloudflare) FLAG_CLOUDFLARE=true; HAS_FLAGS=true ;;
        --caddy)      FLAG_CADDY=true; HAS_FLAGS=true ;;
        --ntfy)       FLAG_NTFY=true; HAS_FLAGS=true ;;
        --systemd)    FLAG_SYSTEMD=true; HAS_FLAGS=true ;;
        --cron)       FLAG_CRON=true; HAS_FLAGS=true ;;
        -h|--help)
            echo "Usage: roost-apply [--all] [--cloudflare] [--caddy] [--ntfy] [--systemd] [--cron]"
            echo ""
            echo "No args: auto-detect changed files via checksum comparison"
            echo "--all:        reload everything (also saves baseline checksums)"
            echo "--cloudflare: assemble fragments and restart cloudflared"
            echo "--caddy:      reload-or-restart caddy"
            echo "--ntfy:       restart ntfy"
            echo "--systemd:    daemon-reload and restart affected systemd units"
            echo "--cron:       just update checksum (cron auto-reloads)"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# --- Helper: check if a file's flag is selected ---
flag_selected() {
    local path="$1"
    $FLAG_ALL && return 0
    local flag="${FLAG_MAP[$path]:-}"
    case "$flag" in
        caddy)      $FLAG_CADDY ;;
        cloudflare) $FLAG_CLOUDFLARE ;;
        ntfy)       $FLAG_NTFY ;;
        systemd)    $FLAG_SYSTEMD ;;
        cron)       $FLAG_CRON ;;
        *)          return 1 ;;
    esac
}

# --- Helper: compute checksum for a file ---
file_checksum() {
    if [ -f "$1" ]; then
        md5sum "$1" | awk '{print $1}'
    else
        echo "MISSING"
    fi
}

# --- Helper: get saved checksum ---
saved_checksum() {
    local path="$1"
    if [ -f "$CHECKSUM_FILE" ]; then
        grep -F "$path" "$CHECKSUM_FILE" 2>/dev/null | awk '{print $1}'
    fi
}

# --- Detect changes and collect actions ---
NEED_DAEMON_RELOAD=false
declare -A RESTARTS=()
CHANGED=()
UNCHANGED=()

if $HAS_FLAGS; then
    logger -t "$_HOOK_TAG" "Apply started (explicit flags)"
else
    logger -t "$_HOOK_TAG" "Apply started (auto-detect)"
fi

for path in "${!CONFIG_MAP[@]}"; do
    action="${CONFIG_MAP[$path]}"

    if $HAS_FLAGS; then
        # Flag mode: only process selected services
        flag_selected "$path" || continue
    else
        # Auto-detect mode: compare checksums
        current=$(file_checksum "$path")
        saved=$(saved_checksum "$path")
        if [ "$current" = "$saved" ]; then
            UNCHANGED+=("$path")
            continue
        fi
    fi

    CHANGED+=("$path")
    logger -t "$_HOOK_TAG" "Changed: $path"

    case "$action" in
        reload-or-restart:*)
            unit="${action#reload-or-restart:}"
            RESTARTS["reload-or-restart:$unit"]=1
            ;;
        restart:*)
            unit="${action#restart:}"
            RESTARTS["restart:$unit"]=1
            ;;
        daemon-reload)
            NEED_DAEMON_RELOAD=true
            ;;
        daemon-reload+restart:*)
            NEED_DAEMON_RELOAD=true
            unit="${action#daemon-reload+restart:}"
            RESTARTS["restart:$unit"]=1
            ;;
        none) ;;
    esac
done

# First run with no saved checksums: log it
if ! $HAS_FLAGS && [ ! -f "$CHECKSUM_FILE" ]; then
    logger -t "$_HOOK_TAG" "First run: all files treated as changed"
fi

# --- Run cloudflare assembly if requested or on first run ---
FIRST_RUN=false
! $HAS_FLAGS && [ ! -f "$CHECKSUM_FILE" ] && FIRST_RUN=true

if $FLAG_ALL || $FLAG_CLOUDFLARE || $FIRST_RUN; then
    HOOK_DIR="$(dirname "$0")"
    if [ -x "$HOOK_DIR/cloudflare-assemble.sh" ]; then
        logger -t "$_HOOK_TAG" "Running cloudflare assembly"
        "$HOOK_DIR/cloudflare-assemble.sh"
    fi
fi

# --- Apply: daemon-reload (once) ---
if $NEED_DAEMON_RELOAD; then
    logger -t "$_HOOK_TAG" "Running daemon-reload"
    sudo systemctl daemon-reload
fi

# --- Apply: service restarts ---
RESTARTED=()
RESTART_FAILED=()

for key in "${!RESTARTS[@]}"; do
    cmd="${key%%:*}"
    unit="${key#*:}"
    logger -t "$_HOOK_TAG" "Running: systemctl $cmd $unit"
    if sudo systemctl "$cmd" "$unit" 2>&1 | logger -t "$_HOOK_TAG"; then
        RESTARTED+=("$unit")
    else
        RESTART_FAILED+=("$unit")
        logger -t "$_HOOK_TAG" -p user.err "Failed: systemctl $cmd $unit"
    fi
done

# --- Update checksums ---
# Rebuild the entire checksum file from current state
{
    for path in "${!CONFIG_MAP[@]}"; do
        checksum=$(file_checksum "$path")
        echo "$checksum  $path"
    done
} | sort -k2 > "$CHECKSUM_FILE"

# --- Summary ---
echo ""
if [ ${#CHANGED[@]} -eq 0 ] && ! $HAS_FLAGS; then
    echo "No changes detected."
    logger -t "$_HOOK_TAG" "No changes detected"
else
    if [ ${#CHANGED[@]} -gt 0 ]; then
        echo "Changed files:"
        for f in "${CHANGED[@]}"; do
            echo "  $f"
        done
    fi

    if $NEED_DAEMON_RELOAD; then
        echo "Ran: systemctl daemon-reload"
    fi

    if [ ${#RESTARTED[@]} -gt 0 ]; then
        echo "Restarted:"
        for u in "${RESTARTED[@]}"; do
            echo "  $u"
        done
    fi

    if [ ${#RESTART_FAILED[@]} -gt 0 ]; then
        echo "FAILED to restart:"
        for u in "${RESTART_FAILED[@]}"; do
            echo "  $u"
        done
    fi
fi

# Notify on failures
if [ ${#RESTART_FAILED[@]} -gt 0 ]; then
    ntfy_send -t "roost-apply: restart failures" -p "high" \
        "Failed to restart: ${RESTART_FAILED[*]}"
fi

logger -t "$_HOOK_TAG" "Apply finished: ${#CHANGED[@]} changed, ${#RESTARTED[@]} restarted, ${#RESTART_FAILED[@]} failed"
