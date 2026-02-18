#!/bin/bash
# Health check: services, disk, swap, memory, Tailscale, Syncthing, Cloudflare.
source "$(dirname "$0")/_hook-env.sh"

FAILURES=""

check() {
    local name="$1" url="$2"
    curl -sf --max-time 5 "$url" > /dev/null 2>&1 || FAILURES="$FAILURES\n- $name ($url)"
}

check "Ollama" "http://localhost:11434/api/tags"
# Phase 2 (uncomment when deployed):
# check "llama-reranker" "http://localhost:8181/health"
# check "Parakeet STT" "http://localhost:9000/v1/models"
# check "Pocket TTS" "http://localhost:8000"

# Caddy
systemctl is-active caddy &>/dev/null || FAILURES="$FAILURES\n- Caddy not running"

# ntfy
systemctl is-active ntfy &>/dev/null || FAILURES="$FAILURES\n- ntfy not running"

# Syncthing
systemctl is-active "syncthing@$(whoami)" &>/dev/null || FAILURES="$FAILURES\n- Syncthing not running"
check "Syncthing" "http://localhost:8384/rest/system/ping"

# Tailscale
tailscale status > /dev/null 2>&1 || FAILURES="$FAILURES\n- Tailscale not connected"

# Cloudflare tunnel
systemctl is-active cloudflared &>/dev/null || FAILURES="$FAILURES\n- cloudflared not running"

DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
[ "$DISK_PCT" -gt 80 ] && FAILURES="$FAILURES\n- Disk usage at ${DISK_PCT}%"

INODE_PCT=$(df -i / --output=ipcent | tail -1 | tr -d ' %')
[ "$INODE_PCT" -gt 80 ] && FAILURES="$FAILURES\n- Inode usage at ${INODE_PCT}%"

SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
[ "$SWAP_USED" -gt 2048 ] && FAILURES="$FAILURES\n- Swap usage: ${SWAP_USED}MB (>2GB)"

if [ -n "$FAILURES" ]; then
    ntfy_send -t "Service health alert" -p "high" "$(echo -e "Issues detected:$FAILURES")"
fi
