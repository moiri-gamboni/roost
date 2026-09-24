#!/bin/bash
# Log to the journal when any process exceeds 3GB RSS, or when the processes
# sharing one command name add up to more than 6GB. The second rule exists
# because on 2026-09-20 five ripgreps at 1.4-1.8GB each swapped the box into a
# ten-minute hang without any one of them crossing the per-process line.
# Journal only, never ntfy: a large process is routine here (a browser, a
# language server), and what needs a person is a kill, which health-check.sh
# reports from earlyoom's journal. These lines say what was big beforehand.
# Logged PIDs are tracked to avoid repeat lines until the process restarts;
# logged command names until the group drops back under its line.
#
# Sourcing this file defines the functions only (tests/ram-monitor.sh); running
# it does the check.

THRESHOLD_KB=$((3072 * 1024))       # 3GB per process
GROWTH_KB=$((512 * 1024))           # log again if grown 512MB since last line
GROUP_THRESHOLD_KB=$((6144 * 1024)) # 6GB summed over one command name
GROUP_GROWTH_KB=$((1024 * 1024))    # log again if the group grew 1GB

# Sum RSS per command name from "RSS_KB COMM" lines on stdin and print the
# groups over $1 KB as "SUM_KB<TAB>COUNT<TAB>COMM", largest first. A command
# name can contain spaces ("tmux: server"), so it is everything after the
# first field.
rss_groups() {
    awk -v min="$1" '{ rss = $1; sub(/^ *[0-9]+ +/, ""); sum[$0] += rss; n[$0]++ }
        END { for (c in sum) if (sum[c] > min) printf "%d\t%d\t%s\n", sum[c], n[c], c }' |
        sort -rn
}

gb() { awk "BEGIN {printf \"%.1f\", $1/1048576}"; }

# Log the groups over the line from "RSS_KB COMM" lines on stdin.
# State file $1, one "LAST_ALERTED_SUM_KB<TAB>COMM" line per group logged;
# rewritten from the current groups each run, so a group that dropped under
# the line falls out and is logged again when it next climbs.
alert_groups() {
    local state=$1 tmp sum count comm prev
    tmp=$(mktemp)
    rss_groups "$GROUP_THRESHOLD_KB" | while IFS=$'\t' read -r sum count comm; do
        prev=$(awk -F'\t' -v c="$comm" '$2 == c {print $1}' "$state")
        if [ -z "$prev" ]; then
            logger -t "$_HOOK_TAG" "ALERT: $count x $comm using $(gb "$sum")GB RSS together"
            printf '%s\t%s\n' "$sum" "$comm" >> "$tmp"
        elif [ $((sum - prev)) -gt "$GROUP_GROWTH_KB" ]; then
            logger -t "$_HOOK_TAG" "GROWTH: $count x $comm now $(gb "$sum")GB together (was $(gb "$prev")GB)"
            printf '%s\t%s\n' "$sum" "$comm" >> "$tmp"
        else
            printf '%s\t%s\n' "$prev" "$comm" >> "$tmp"
        fi
    done
    mv "$tmp" "$state"
}

main() {
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/_hook-env.sh"
    local state_file="$HOOK_RUNTIME_DIR/ram-monitor-notified"
    local group_state="$HOOK_RUNTIME_DIR/ram-monitor-groups"
    touch "$state_file" "$group_state"

    # State file format: PID LAST_ALERTED_RSS_KB
    ps -eo pid,rss,comm --no-headers | while read -r pid rss comm; do
        if [ "$rss" -gt "$THRESHOLD_KB" ]; then
            prev_rss=$(awk -v p="$pid" '$1 == p {print $2}' "$state_file")
            if [ -z "$prev_rss" ]; then
                logger -t "$_HOOK_TAG" "ALERT: $comm (PID $pid) using $(gb "$rss")GB RSS"
                echo "$pid $rss" >> "$state_file"
            elif [ $((rss - prev_rss)) -gt "$GROWTH_KB" ]; then
                logger -t "$_HOOK_TAG" "GROWTH: $comm (PID $pid) now $(gb "$rss")GB (was $(gb "$prev_rss")GB)"
                sed -i "s/^${pid} .*/${pid} ${rss}/" "$state_file"
            fi
        fi
    done

    # Prune PIDs that no longer exist
    local tmp
    tmp=$(mktemp)
    while read -r pid _rest; do
        [ -d "/proc/$pid" ] && grep "^${pid} " "$state_file"
    done < "$state_file" > "$tmp" || true
    mv "$tmp" "$state_file"

    ps -eo rss=,comm= | alert_groups "$group_state"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
