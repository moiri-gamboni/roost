#!/bin/bash
# Health check: services, disk, swap, memory, Tailscale, Syncthing, Cloudflare.
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
check_service "syncthing@$(whoami)"

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

INODE_PCT=$(df -i / --output=ipcent | tail -1 | tr -d ' %')
logger -t "$_HOOK_TAG" "Inodes: ${INODE_PCT}%"
[ "$INODE_PCT" -gt 80 ] && FAILURES="$FAILURES\n- Inode usage at ${INODE_PCT}%"

SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
logger -t "$_HOOK_TAG" "Swap: ${SWAP_USED}MB"
[ "$SWAP_USED" -gt 2048 ] && FAILURES="$FAILURES\n- Swap usage: ${SWAP_USED}MB (>2GB)"

# Source app-specific health checks if present
if [ -f "$(dirname "$0")/health-check-apps.sh" ]; then
    source "$(dirname "$0")/health-check-apps.sh"
fi

if [ -n "$FAILURES" ]; then
    logger -t "$_HOOK_TAG" "Health check FAILED"
    ntfy_send -t "Service health alert" -p "high" "$(echo -e "Issues detected:$FAILURES")"
else
    logger -t "$_HOOK_TAG" "Health check passed"
fi
