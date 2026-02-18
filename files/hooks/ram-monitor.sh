#!/bin/bash
# Alert when any process exceeds 2GB RSS.
# Tracks notified PIDs to avoid repeat alerts until the process restarts.
source "$(dirname "$0")/_hook-env.sh"

THRESHOLD_KB=$((2048 * 1024))
STATE_FILE="$HOOK_RUNTIME_DIR/ram-monitor-notified"

touch "$STATE_FILE"

ps -eo pid,rss,comm --no-headers | while read -r pid rss comm; do
    if [ "$rss" -gt "$THRESHOLD_KB" ]; then
        if ! grep -q "^${pid}$" "$STATE_FILE"; then
            gb=$(awk "BEGIN {printf \"%.1f\", $rss/1048576}")
            ntfy_send -t "High RAM: $comm" -p "high" "PID $pid using ${gb}GB RSS"
            echo "$pid" >> "$STATE_FILE"
        fi
    fi
done

# Prune PIDs that no longer exist
tmp=$(mktemp)
while read -r pid; do
    [ -d "/proc/$pid" ] && echo "$pid"
done < "$STATE_FILE" > "$tmp" || true
mv "$tmp" "$STATE_FILE"
