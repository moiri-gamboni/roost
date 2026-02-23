#!/bin/bash
# Alert when any process exceeds 2GB RSS.
# Tracks notified PIDs to avoid repeat alerts until the process restarts.
source "$(dirname "$0")/_hook-env.sh"

THRESHOLD_KB=$((3072 * 1024))  # 3GB
GROWTH_KB=$((512 * 1024))     # re-alert if grown 512MB since last alert
STATE_FILE="$HOOK_RUNTIME_DIR/ram-monitor-notified"

touch "$STATE_FILE"

# State file format: PID LAST_ALERTED_RSS_KB
ps -eo pid,rss,comm --no-headers | while read -r pid rss comm; do
    if [ "$rss" -gt "$THRESHOLD_KB" ]; then
        prev_rss=$(awk -v p="$pid" '$1 == p {print $2}' "$STATE_FILE")
        if [ -z "$prev_rss" ]; then
            gb=$(awk "BEGIN {printf \"%.1f\", $rss/1048576}")
            ntfy_send -t "High RAM: $comm" -p "high" "PID $pid using ${gb}GB RSS"
            echo "$pid $rss" >> "$STATE_FILE"
        elif [ $((rss - prev_rss)) -gt "$GROWTH_KB" ]; then
            gb=$(awk "BEGIN {printf \"%.1f\", $rss/1048576}")
            prev_gb=$(awk "BEGIN {printf \"%.1f\", $prev_rss/1048576}")
            ntfy_send -t "RAM growing: $comm" -p "high" "PID $pid now ${gb}GB (was ${prev_gb}GB)"
            sed -i "s/^${pid} .*/${pid} ${rss}/" "$STATE_FILE"
        fi
    fi
done

# Prune PIDs that no longer exist
tmp=$(mktemp)
while read -r pid _rest; do
    [ -d "/proc/$pid" ] && grep "^${pid} " "$STATE_FILE"
done < "$STATE_FILE" > "$tmp" || true
mv "$tmp" "$STATE_FILE"
