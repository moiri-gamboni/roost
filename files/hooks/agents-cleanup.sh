#!/bin/bash
# Cleanup terminal-state agent sessions you've moved on from.
#
# Policy: a session is deleted iff ALL of
#   (1) state ∈ {done, stopped, failed, crashed}
#   (2) tempo == "idle" (not actively responding mid-turn)
#   (3) supervisor roster entry's pid is not actually alive
#       (roster presence alone isn't enough — stale entries with pid=0 or
#       dead pids happen when the supervisor's bookkeeping desyncs)
#   (4) worktree (if any) has no unpushed commits — `claude rm` would
#       otherwise force-delete the branch via `git branch -D`, leaving
#       commits only in reflog
#   (5) the session has been idle for ≥ AGENTS_CLEANUP_IDLE_HOURS weekday
#       hours since updatedAt (weekend hours are NOT counted; default: 48)
#   (6) the connection-activity marker mtime is ≤ AGENTS_CLEANUP_ACTIVITY_HOURS
#       calendar hours old — i.e. an SSH or ET connection was alive recently
#       (default: 24). Marker is touched once a minute by track-ssh-activity.sh.
#
# (6) is a run-level gate: if it fails, no sessions are evaluated.
#
# Usage:
#   agents-cleanup.sh                # delete eligible, log to journald
#   agents-cleanup.sh --dry-run      # print decisions, no actions
#   agents-cleanup.sh --marker FILE  # override the activity-marker path
#
# Env:
#   AGENTS_CLEANUP_IDLE_HOURS      override 48h weekday-idle threshold
#   AGENTS_CLEANUP_ACTIVITY_HOURS  override 24h connection-marker threshold

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/_hook-env.sh"

DRY_RUN=0
MARKER="$CLAUDE_CONFIG_DIR/last-connection-activity"
IDLE_THRESHOLD_HOURS="${AGENTS_CLEANUP_IDLE_HOURS:-48}"
ACTIVITY_THRESHOLD_HOURS="${AGENTS_CLEANUP_ACTIVITY_HOURS:-24}"

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        --marker)     MARKER="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

JOBS_DIR="$CLAUDE_CONFIG_DIR/jobs"
ROSTER="$CLAUDE_CONFIG_DIR/daemon/roster.json"

if [ ! -d "$JOBS_DIR" ]; then
    logger -t "$_HOOK_TAG" "no jobs dir at $JOBS_DIR"
    exit 0
fi

now=$(date +%s)
idle_threshold_s=$(( IDLE_THRESHOLD_HOURS * 3600 ))
activity_threshold_s=$(( ACTIVITY_THRESHOLD_HOURS * 3600 ))

# Sum of weekday (Mon-Fri) seconds between start and end. Weekend hours skipped.
weekday_seconds() {
    local start=$1 end=$2
    [ "$start" -ge "$end" ] && { echo 0; return; }
    local s=$start total=0 dow day_str next chunk
    while [ "$s" -lt "$end" ]; do
        dow=$(date -d "@$s" +%u)
        day_str=$(date -d "@$s" '+%Y-%m-%d')
        next=$(date -d "$day_str +1 day" +%s)
        [ "$next" -gt "$end" ] && next=$end
        chunk=$((next - s))
        [ "$dow" -lt 6 ] && total=$((total + chunk))
        s=$next
    done
    echo "$total"
}

# Run-level gate
marker_mtime=0
[ -f "$MARKER" ] && marker_mtime=$(stat -c %Y "$MARKER")
activity_age=$(( now - marker_mtime ))
if [ "$activity_age" -gt "$activity_threshold_s" ]; then
    age_h=$(( activity_age / 3600 ))
    msg="marker ${age_h}h old (>${ACTIVITY_THRESHOLD_HOURS}h), user away — no deletes"
    [ "$DRY_RUN" = 1 ] && echo "$msg"
    logger -t "$_HOOK_TAG" "$msg"
    exit 0
fi

deleted=0; kept=0; skipped=0

for d in "$JOBS_DIR"/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d")
    state_file="$d/state.json"
    [ -f "$state_file" ] || continue

    state=$(jq -r '.state // ""' "$state_file" 2>/dev/null || echo "")
    tempo=$(jq -r '.tempo // ""' "$state_file" 2>/dev/null || echo "")
    updated_at=$(jq -r '.updatedAt // ""' "$state_file" 2>/dev/null || echo "")
    worktree_path=$(jq -r '.worktreePath // ""' "$state_file" 2>/dev/null || echo "")
    worktree_branch=$(jq -r '.worktreeBranch // ""' "$state_file" 2>/dev/null || echo "")

    case "$state" in
        done|stopped|failed|crashed) ;;
        *)
            skipped=$((skipped + 1))
            [ "$DRY_RUN" = 1 ] && printf 'SKIP   %s  state=%-8s non-terminal\n' "$id" "${state:-empty}"
            continue ;;
    esac

    if [ "$tempo" != "idle" ]; then
        skipped=$((skipped + 1))
        [ "$DRY_RUN" = 1 ] && printf 'SKIP   %s  state=%-8s tempo=%s (not idle)\n' "$id" "$state" "$tempo"
        continue
    fi

    # Roster presence alone isn't enough — the supervisor sometimes leaves
    # stale entries (e.g. pid=0, or pid for a process that's since died).
    # Verify the worker pid is actually alive.
    worker_pid=$(jq -r --arg id "$id" '.workers[$id].pid // 0' "$ROSTER" 2>/dev/null || echo 0)
    if [ "$worker_pid" -gt 0 ] && kill -0 "$worker_pid" 2>/dev/null; then
        skipped=$((skipped + 1))
        [ "$DRY_RUN" = 1 ] && printf 'SKIP   %s  state=%-8s in roster (pid=%d live)\n' "$id" "$state" "$worker_pid"
        continue
    fi

    if [ -z "$updated_at" ]; then
        skipped=$((skipped + 1))
        [ "$DRY_RUN" = 1 ] && printf 'SKIP   %s  state=%-8s no updatedAt\n' "$id" "$state"
        continue
    fi

    stop_time=$(date -d "$updated_at" +%s 2>/dev/null || echo "")
    if [ -z "$stop_time" ]; then
        skipped=$((skipped + 1))
        [ "$DRY_RUN" = 1 ] && printf 'SKIP   %s  state=%-8s bad updatedAt: %s\n' "$id" "$state" "$updated_at"
        continue
    fi

    idle_s=$(weekday_seconds "$stop_time" "$now")
    idle_h=$(( idle_s / 3600 ))

    if [ "$idle_s" -lt "$idle_threshold_s" ]; then
        kept=$((kept + 1))
        [ "$DRY_RUN" = 1 ] && printf 'KEEP   %s  state=%-8s idle=%-3dh (weekday) too-recent\n' "$id" "$state" "$idle_h"
        continue
    fi

    if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
        remote_has_head=$(git -C "$worktree_path" branch -r --contains HEAD 2>/dev/null | head -1 || true)
        if [ -z "$remote_has_head" ]; then
            kept=$((kept + 1))
            [ "$DRY_RUN" = 1 ] && printf 'KEEP   %s  state=%-8s unpushed on %s\n' "$id" "$state" "${worktree_branch:-detached}"
            continue
        fi
    fi

    if [ "$DRY_RUN" = 1 ]; then
        deleted=$((deleted + 1))
        printf 'DELETE %s  state=%-8s idle=%-3dh worktree=%s\n' "$id" "$state" "$idle_h" "${worktree_path:-none}"
    else
        if claude rm "$id" >/dev/null 2>&1; then
            deleted=$((deleted + 1))
            logger -t "$_HOOK_TAG" "deleted $id state=$state idle=${idle_h}h"
        else
            kept=$((kept + 1))
            logger -t "$_HOOK_TAG" "claude rm $id failed"
        fi
    fi
done

if [ "$DRY_RUN" = 1 ]; then
    age_h=$(( activity_age / 3600 ))
    printf '\nsummary: would delete %d, keep %d, skip %d  |  marker age=%dh\n' \
        "$deleted" "$kept" "$skipped" "$age_h"
else
    logger -t "$_HOOK_TAG" "summary deleted=$deleted kept=$kept skipped=$skipped"
fi
