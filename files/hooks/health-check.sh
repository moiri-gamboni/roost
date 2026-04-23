#!/bin/bash
# Health check: services, disk, swap, memory, Tailscale, Cloudflare.
source "$(dirname "$0")/_hook-env.sh"

FAILURES=""

check() {
    local name="$1" url="$2"
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        logger -t "$_HOOK_TAG" "OK: $name"
    else
        logger -t "$_HOOK_TAG" "FAIL: $name ($url)"
        FAILURES="$FAILURES\n- $name ($url)"
    fi
}

check_service() {
    local name="$1"
    if systemctl is-active "$name" &>/dev/null; then
        logger -t "$_HOOK_TAG" "OK: $name"
    else
        logger -t "$_HOOK_TAG" "FAIL: $name not running"
        FAILURES="$FAILURES\n- $name not running"
    fi
}

check "Ollama" "http://localhost:11434/api/tags"
# Phase 2 (uncomment when deployed):
# check "llama-reranker" "http://localhost:8181/health"
# check "Parakeet STT" "http://localhost:9000/v1/models"
# check "Pocket TTS" "http://localhost:8000"

check_service "caddy"
check_service "ntfy"

if tailscale status > /dev/null 2>&1; then
    logger -t "$_HOOK_TAG" "OK: Tailscale"
else
    logger -t "$_HOOK_TAG" "FAIL: Tailscale not connected"
    FAILURES="$FAILURES\n- Tailscale not connected"
fi

check_service "cloudflared"

DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
logger -t "$_HOOK_TAG" "Disk: ${DISK_PCT}%"
[ "$DISK_PCT" -gt 80 ] && FAILURES="$FAILURES\n- Disk usage at ${DISK_PCT}%"

# Source app-specific health checks if present
if [ -f "$(dirname "$0")/health-check-apps.sh" ]; then
    source "$(dirname "$0")/health-check-apps.sh"
fi

if [ -n "$FAILURES" ]; then
    logger -t "$_HOOK_TAG" "Health check FAILED"
    # Key the cooldown by the failure set so escalations / partial recoveries
    # notify immediately; unchanged outages re-notify at most once per hour.
    failures_hash=$(printf '%s' "$FAILURES" | sha256sum | cut -c1-16)
    if cooldown_ok "health-$failures_hash" 3600; then
        ntfy_send -t "Service health alert" -p "high" "$(echo -e "Issues detected:$FAILURES")"
    fi
else
    logger -t "$_HOOK_TAG" "Health check passed"
fi

# --- Cooldown-gated notifications ---

# Swap: alert only on sustained pressure, at most once per hour.
read -r SWAP_TOTAL SWAP_USED < <(free -m | awk '/Swap:/ {print $2, $3; exit}')
logger -t "$_HOOK_TAG" "Swap: ${SWAP_USED}MB / ${SWAP_TOTAL}MB"
if [ "${SWAP_TOTAL:-0}" -gt 0 ] && [ "$SWAP_USED" -gt 3072 ] && cooldown_ok "swap-high" 3600; then
    ntfy_send -t "High swap usage" -p "high" "Swap: ${SWAP_USED}MB / ${SWAP_TOTAL}MB"
fi

# Pending reboot: notify once per distinct event (keyed by mtime), remind every 7d.
REBOOT_FILE=/var/run/reboot-required
REBOOT_STATE="$HOOK_RUNTIME_DIR/reboot-notified"
if [ -f "$REBOOT_FILE" ]; then
    reboot_mtime=$(stat -c %Y "$REBOOT_FILE")
    last_notified=0
    notified_for=0
    [ -f "$REBOOT_STATE" ] && read -r last_notified notified_for < "$REBOOT_STATE"
    now=$(date +%s)
    if [ "${notified_for:-0}" != "$reboot_mtime" ] || [ $((now - ${last_notified:-0})) -gt $((7 * 86400)) ]; then
        pkgs=""
        [ -f "${REBOOT_FILE}.pkgs" ] && pkgs=$(sort -u "${REBOOT_FILE}.pkgs" | tr '\n' ' ')
        age_days=$(( (now - reboot_mtime) / 86400 ))
        msg="Pending since ${age_days}d"
        [ -n "$pkgs" ] && msg="$msg. Packages: $pkgs"
        logger -t "$_HOOK_TAG" "Reboot required: $msg"
        ntfy_send -t "Reboot required" -p "default" "$msg"
        echo "$now $reboot_mtime" > "$REBOOT_STATE"
    fi
elif [ -f "$REBOOT_STATE" ]; then
    rm -f "$REBOOT_STATE"
fi
