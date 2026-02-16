#!/bin/bash
INPUT=$(cat)
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Input needed"')
TITLE=$(echo "$INPUT" | jq -r '.title // empty')
TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')
PROJECT=$(basename "$PWD")
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")

# Flood protection: suppress if >20 notifications in 5 seconds
RATE_FILE="/tmp/ntfy-rate.log"
NOW=$(date +%s)
if [ -f "$RATE_FILE" ]; then
    RECENT=$(awk -v cutoff=$((NOW - 5)) '$1 >= cutoff' "$RATE_FILE" 2>/dev/null | wc -l)
    [ "$RECENT" -ge 20 ] && exit 0
fi
echo "$NOW" >> "$RATE_FILE"
[ "$(wc -l < "$RATE_FILE" 2>/dev/null || echo 0)" -gt 200 ] && \
    tail -50 "$RATE_FILE" > "$RATE_FILE.tmp" && mv "$RATE_FILE.tmp" "$RATE_FILE"

PRIORITY="default"
[ "$TYPE" = "permission_prompt" ] && PRIORITY="urgent"

curl -s -X POST "http://localhost:2586/claude-$(whoami)" \
    -H "Title: ${TITLE:-$PROJECT}" \
    -H "Priority: $PRIORITY" \
    -H "Actions: view, Open terminal, http://${TAILSCALE_IP}:8080, clear=true" \
    --data-urlencode "message=$MESSAGE"
