#!/bin/bash
# Health check: services, disk, swap, memory, Tailscale, Cloudflare.
HOOK_DROP_TO_SUDO_USER=1
source "$(dirname "$0")/../lib/_hook-env.sh"

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

# earlyoom stands between a swap thrash and the kernel's OOM killer (files/
# earlyoom.default). It logs each kill to its own journal and nothing else
# reports it, so replay the kills since the last run here. The window is kept
# in a state file rather than "-5min" so a delayed run misses nothing.
check_service "earlyoom"
OOM_STATE="$HOOK_RUNTIME_DIR/earlyoom-since"
OOM_SINCE=$(date -d '-5 min' +%s)
[ -f "$OOM_STATE" ] && read -r OOM_SINCE < "$OOM_STATE"
date +%s > "$OOM_STATE"
# A kill line: sending SIGTERM to process 381164 uid 1000 "rg": badness 950, VmRSS 1613 MiB
# (the startup banner also starts with "sending SIGTERM", hence "to process").
# An unreadable journal (unparseable state file, sudo refused) must not read
# as "no kills": that is the one outcome this block exists to prevent.
if ! OOM_JOURNAL=$(sudo -n journalctl -u earlyoom --since "@$OOM_SINCE" -o cat --no-pager); then
    FAILURES="$FAILURES\n- earlyoom journal unreadable (since @$OOM_SINCE)"
else
    OOM_KILLS=$(grep -E '^sending SIG(TERM|KILL) to process' <<<"$OOM_JOURNAL" | sed -E 's/ uid [0-9]+//; s/: badness [0-9]+,//')
    if [ -n "$OOM_KILLS" ]; then
        logger -t "$_HOOK_TAG" "earlyoom killed: $OOM_KILLS"
        ntfy_send -t "earlyoom killed a process" -p "high" "$OOM_KILLS"
    fi
fi

DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
logger -t "$_HOOK_TAG" "Disk: ${DISK_PCT}%"
# Alert on the trend, not the level. A disk parked above 80% is a known state,
# and re-reporting it every 5 minutes trains the alert to be ignored. Above
# DISK_CRIT it is reported regardless: the growth rule alone would silently
# swallow a jump straight from healthy to nearly full, which is the one case
# that most needs a page.
DISK_WARN=80
DISK_CRIT=90
DISK_STATE="$HOOK_RUNTIME_DIR/disk-alert-pct"
if [ "$DISK_PCT" -ge "$DISK_CRIT" ]; then
    FAILURES="$FAILURES\n- Disk usage at ${DISK_PCT}% (critical)"
    echo "$DISK_PCT" > "$DISK_STATE"
elif [ "$DISK_PCT" -gt "$DISK_WARN" ]; then
    # Fire only once usage climbs 3 points past the level last reported, and
    # track it back down as it recovers, so a genuine climb after a cleanup
    # still alerts rather than hiding under a stale high-water mark.
    DISK_LAST=""
    [ -f "$DISK_STATE" ] && DISK_LAST=$(cat "$DISK_STATE" 2>/dev/null)
    if [ -z "$DISK_LAST" ]; then
        # First observation in the warn band: record it, do not alert.
        echo "$DISK_PCT" > "$DISK_STATE"
    elif [ "$DISK_PCT" -ge $((DISK_LAST + 3)) ]; then
        FAILURES="$FAILURES\n- Disk usage at ${DISK_PCT}% (up from ${DISK_LAST}%)"
        echo "$DISK_PCT" > "$DISK_STATE"
    elif [ "$DISK_PCT" -lt "$DISK_LAST" ]; then
        echo "$DISK_PCT" > "$DISK_STATE"
    fi
else
    rm -f "$DISK_STATE"
fi

# Btrfs allocation headroom — the failure df can't see: once chunk allocation
# reaches the device edge the metadata pool can't grow, and the next metadata
# spike force-flips the fs read-only (2026-08-19: root went RO at df=75%).
# Below 5GiB the balance runs from here (at most once a day; the Sunday job is
# the steady-state pass) and the alert says what it reclaimed. A balance only
# returns slack from part-empty data chunks; when it reclaims nothing the
# chunks are full of live extents — in practice files that snapshots still
# pin — and the remedy is pruning snapshots or moving data off the filesystem,
# and the remedy is pruning history: the oldest timeline snapshots go, three
# per hour at most, until headroom is back. Never the off-site backup's pinned
# parent (its cleanup algorithm is empty) and never number/important ones —
# those are the rollback points, and a fs that needs more than this is a
# runaway writer, which the alert is for.
unalloc_gib() {
    sudo -n btrfs filesystem usage -b "$1" 2>/dev/null |
        awk '/Device unallocated:/ {printf "%d", $3 / 1024^3}'
}
declare -A UNALLOC_LOW=()
for mnt in / /mnt/roost-data; do
    mountpoint -q "$mnt" || continue
    UNALLOC_GIB=$(unalloc_gib "$mnt")
    logger -t "$_HOOK_TAG" "Btrfs unallocated $mnt: ${UNALLOC_GIB:-?}GiB"
    if [ -z "$UNALLOC_GIB" ]; then
        FAILURES="$FAILURES\n- btrfs unallocated unreadable on $mnt"
    elif [ "$UNALLOC_GIB" -lt 5 ]; then
        UNALLOC_LOW[$mnt]=$UNALLOC_GIB
    fi
done
if [ "${#UNALLOC_LOW[@]}" -gt 0 ]; then
    BALANCE_NOTE="balance already ran within 24h"
    if cooldown_ok "btrfs-balance-auto" 86400; then
        # Same lock as the cron line, so this never overlaps the Sunday run.
        if flock -n "$HOME/.locks/btrfs-balance" "$(dirname "$0")/btrfs-balance.sh"; then
            BALANCE_NOTE="balance ran now"
        else
            BALANCE_NOTE="balance failed or already running"
        fi
    fi
    for mnt in "${!UNALLOC_LOW[@]}"; do
        AFTER=$(unalloc_gib "$mnt")
        PRUNED=""
        case $mnt in /) cfg=root ;; *) cfg=$(basename "$mnt") ;; esac
        if [ "${AFTER:-0}" -lt 5 ] && cooldown_ok "btrfs-prune-$cfg" 3600; then
            for n in $(sudo -n snapper -c "$cfg" --csvout --no-headers list --columns number,cleanup 2>/dev/null |
                awk -F, '$2 == "timeline" {print $1}' | sort -n | awk 'NR <= 3'); do
                sudo -n snapper -c "$cfg" delete --sync "$n" 2>&1 | logger -t "$_HOOK_TAG"
                PRUNED="$PRUNED #$n"
            done
            # A deleted snapshot frees extents inside chunks; only a balance
            # turns part-empty chunks back into unallocated space.
            [ -n "$PRUNED" ] && flock -n "$HOME/.locks/btrfs-balance" "$(dirname "$0")/btrfs-balance.sh"
            AFTER=$(unalloc_gib "$mnt")
            logger -t "$_HOOK_TAG" "Pruned snapshots on $mnt:${PRUNED:- none} (unallocated ${UNALLOC_LOW[$mnt]}GiB -> ${AFTER:-?}GiB)"
        fi
        if [ "${AFTER:-0}" -lt 5 ]; then
            FAILURES="$FAILURES\n- btrfs unallocated ${AFTER:-?}GiB on $mnt, was ${UNALLOC_LOW[$mnt]}GiB (read-only-flip risk; $BALANCE_NOTE; pruned snapshots:${PRUNED:- none this hour}; what remains is held by live files or the pinned/number snapshots: snapper list, or move data off)"
        elif [ -n "$PRUNED" ]; then
            ntfy_send -t "btrfs headroom restored" -p "default" "$mnt: unallocated ${UNALLOC_LOW[$mnt]}GiB -> ${AFTER}GiB after pruning snapshots$PRUNED ($BALANCE_NOTE)"
        fi
    done
fi

# Swap must exist: swap-swapfile.swap can fail silently at boot (2026-08-26: a
# week at 0MB swap ended in an OOM kill of the whole user slice).
SWAP_TOTAL_MB=$(free -m | awk '/Swap:/ {print $2; exit}')
if [ "${SWAP_TOTAL_MB:-0}" -eq 0 ]; then
    FAILURES="$FAILURES\n- no active swap (systemctl restart swap-swapfile.swap)"
fi

# Source app-specific health checks if present
if [ -f "$(dirname "$0")/health-check-apps.sh" ]; then
    source "$(dirname "$0")/health-check-apps.sh"
fi

# Source private app-specific health checks if present (kept out of the public repo)
if [ -f "$(dirname "$0")/health-check-apps-private.sh" ]; then
    source "$(dirname "$0")/health-check-apps-private.sh"
fi

# --- tasksync dead-man: hourly rows refresh + tasksync conflict ageing -------
# The hourly rows job never ntfys — losing the race with the nightly is its
# designed outcome, 2-4 times a night. It records every attempt in a marker
# instead, and this is the only thing that reads it. Keyed on the age of the
# last SUCCESS, not on exit status: a wedged nightly holds the lock
# indefinitely and every tick behind it exits 1 from flock -n, so
# alert-on-failure would never fire. The check composes the mirror's marker
# alarms with the tasks-side ones, so one listener covers both.
TASKS_DEADMAN="$HOME/roost/apart-research/tasksync"
if [ -f "$TASKS_DEADMAN/tasksync/deadman.py" ]; then
    if ! ALARMS="$(cd "$TASKS_DEADMAN" && python3 -m tasksync.deadman --check 2>&1)"; then
        # 6h cooldown matches the staleness threshold, so a real outage nags
        # ~4x a day rather than 24, and a recovery is visible within one cycle.
        if cooldown_ok "notion-rows-deadman" 21600; then
            ntfy_send -t "tasksync dead-man" -p "high" "$ALARMS"
        fi
    fi
else
    FAILURES="$FAILURES\n- tasksync deadman.py missing ($TASKS_DEADMAN/tasksync/deadman.py)"
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

# Memory: alert on headroom and on stall, never on swap used. With swappiness
# 10 the kernel parks the idle pages of long-lived sessions in swap and leaves
# them there, so several GB of swap in use with most of RAM available and no
# stall is this box's steady state, and a fixed "swap > N" rule pages on it
# hourly. Headroom is what is left before the OOM killer: MemAvailable (page
# cache included, the kernel reclaims it) plus free swap, as a share of RAM +
# swap, so the rule follows the swap file's size. Reported once under
# MEM_WARN, then only every further 5 points down; the baseline clears 5
# points above the line so a value hovering at it does not flap.
MEM_WARN=20
MEM_STATE="$HOOK_RUNTIME_DIR/mem-alert-pct"
read -r MEM_TOTAL MEM_AVAIL SWAP_TOTAL SWAP_FREE < <(awk '
    /^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2}
    /^SwapTotal:/ {st = $2} /^SwapFree:/ {sf = $2}
    END {printf "%d %d %d %d", t / 1024, a / 1024, st / 1024, sf / 1024}' /proc/meminfo)
HEADROOM_PCT=$(( (MEM_AVAIL + SWAP_FREE) * 100 / (MEM_TOTAL + SWAP_TOTAL) ))
# PSI "full": share of the last 5 minutes during which every runnable task was
# stalled on memory, the kernel's own thrash measure. A working set larger than
# RAM but smaller than RAM + swap thrashes with headroom still on paper.
PSI_FULL=$(awk '/^full/ {sub("avg300=", "", $4); printf "%d", $4}' /proc/pressure/memory)
MEM_SUMMARY="RAM ${MEM_AVAIL}MB available of ${MEM_TOTAL}MB, swap ${SWAP_FREE}MB free of ${SWAP_TOTAL}MB, stall ${PSI_FULL:-0}%"
logger -t "$_HOOK_TAG" "Memory: headroom ${HEADROOM_PCT}% ($MEM_SUMMARY)"
if [ "$HEADROOM_PCT" -lt "$MEM_WARN" ]; then
    MEM_LAST=""
    [ -f "$MEM_STATE" ] && read -r MEM_LAST < "$MEM_STATE"
    if [ -z "$MEM_LAST" ] || [ "$HEADROOM_PCT" -le $((MEM_LAST - 5)) ]; then
        # RSS summed per command name, so a dozen 400MB sessions read as one line.
        TOP=$(ps -eo rss,comm --no-headers | awk '{rss[$2] += $1; n[$2]++}
            END {for (c in rss) printf "%d %s %d\n", rss[c], c, n[c]}' | sort -rn |
            awk 'NR <= 3 {printf "%s%s x%d %dMB", sep, $2, $3, $1 / 1024; sep = ", "}')
        ntfy_send -t "Memory headroom ${HEADROOM_PCT}%" -p "high" "$MEM_SUMMARY. Largest: $TOP"
        echo "$HEADROOM_PCT" > "$MEM_STATE"
    fi
elif [ "$HEADROOM_PCT" -ge $((MEM_WARN + 5)) ]; then
    rm -f "$MEM_STATE"
fi
if [ "${PSI_FULL:-0}" -ge 10 ] && cooldown_ok "mem-thrash" 3600; then
    ntfy_send -t "Memory thrashing" -p "high" "Every task stalled on memory ${PSI_FULL}% of the last 5 min. $MEM_SUMMARY"
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
