#!/bin/bash
# Close the headless Chromes that rodney sessions leave behind.
#
# The ~/bin/rodney wrapper (files/scripts/rodney.sh) gives every Claude Code
# session its own browser under $RODNEY_SESSIONS_DIR/<session id>/ and stamps
# <home>/last-used on each browser-needing verb. Nothing closes those browsers on its own —
# SessionEnd is not guaranteed to fire (OOM, reboot, kill) — so this runs from
# cron every 10 minutes and applies two rules:
#
#   session gone   the session id has no live entry in Claude Code's presence
#                  registry ($CLAUDE_CONFIG_DIR/sessions/<pid>.json with that
#                  sessionId and a pid that is alive) → stop every browser
#                  under its dir (subagent-scoped ones included) and remove it.
#   idle           last-used older than RODNEY_IDLE_MIN minutes (default 60;
#                  state.json's mtime stands in when there is no stamp) →
#                  stop the browser and drop its state; the wrapper starts a
#                  fresh one on the session's next verb. Applies to the
#                  session tree and to the global ~/.rodney home alike.
#
# A browser is stopped through `rodney stop` only when its recorded pid is a
# Chrome on that profile; otherwise the stale state file is just removed, so a
# pid recycled since a reboot is never signalled. Browsers under other homes
# (--local, ad-hoc RODNEY_HOME) are deliberate and untouched.
#
# Usage:
#   rodney-reap.sh              # act, log to journald as roost/rodney-reap
#   rodney-reap.sh --dry-run    # print what would happen, change nothing
# Env: RODNEY_SESSIONS_DIR (~/.cache/rodney/sessions), RODNEY_GLOBAL_HOME
#      (~/.rodney), RODNEY_IDLE_MIN (60), CLAUDE_CONFIG_DIR (the registry).

set -euo pipefail

real="$HOME/go/bin/rodney"
sessions_dir="${RODNEY_SESSIONS_DIR:-$HOME/.cache/rodney/sessions}"
global_home="${RODNEY_GLOBAL_HOME:-$HOME/.rodney}"
idle_s=$(( ${RODNEY_IDLE_MIN:-60} * 60 ))
registry="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
dry=0
case "${1:-}" in
    -n|--dry-run) dry=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
esac

log() { if [ "$dry" = 1 ]; then echo "$*"; else logger -t roost/rodney-reap -- "$*"; fi; }

chrome_pid_of() {   # prints the state file's pid when it is a live Chrome on this home, else nothing
    local home=$1 pid cmd
    [ -f "$home/state.json" ] || return 0
    pid=$(jq -r '.chrome_pid // 0' "$home/state.json")
    [ "$pid" != 0 ] && [ -r "/proc/$pid/cmdline" ] || return 0
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    [[ "$cmd" == *"--user-data-dir=$home/chrome-data "* ]] && echo "$pid"
    return 0
}

stop_home() {       # $1 = home, $2 = reason
    local home=$1 pid
    pid=$(chrome_pid_of "$home")
    if [ "$dry" = 1 ]; then log "$2: would stop $home (chrome pid ${pid:-none})"; return; fi
    if [ -n "$pid" ]; then
        # bounded: a Chrome that accepts the DevTools socket but never answers would otherwise hang every later run on the cron flock
        timeout 30 env RODNEY_HOME="$home" "$real" stop >/dev/null || kill "$pid" || true
        for _ in $(seq 50); do [ -d "/proc/$pid" ] || break; sleep 0.1; done   # `stop` returns before Chrome has finished writing its profile
        [ ! -d "/proc/$pid" ] || { kill -9 "$pid" || true; sleep 0.2; }       # a controller-less headless Chrome shrugs off SIGTERM
    fi
    rm -f "$home/state.json"
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then log "$2: FAILED to stop $home (chrome pid $pid still alive)"
    else log "$2: stopped $home (chrome pid ${pid:-none})"; fi
}

session_alive() {   # $1 = session id: registered with a live pid
    local f pid
    for f in "$registry"/*.json; do
        [ -f "$f" ] || continue
        pid=$(jq -r --arg sid "$1" 'select(.sessionId == $sid) | .pid // empty' "$f")
        [ -n "$pid" ] && [ -d "/proc/$pid" ] && return 0
    done
    return 1
}

idle() {            # $1 = home: no use for idle_s seconds
    local ref=$1/last-used
    [ -f "$ref" ] || ref=$1/state.json
    [ -f "$ref" ] || return 1
    [ $(( $(date +%s) - $(stat -c %Y "$ref") )) -gt "$idle_s" ]
}

for d in "$sessions_dir"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}; sid=$(basename "$d")
    if ! session_alive "$sid"; then
        while read -r sf; do stop_home "$(dirname "$sf")" "session $sid gone"; done < <(find "$d" -name state.json)
        if [ "$dry" = 1 ]; then log "session $sid gone: would remove $d"; continue; fi
        pkill -9 -f -- "--user-data-dir=$d/" || true     # a Chrome with no state file beside it: unreachable through rodney, ours all the same
        rm -rf "$d"
        log "session $sid gone: removed $d"
        continue
    fi
    while read -r sf; do
        h=$(dirname "$sf")
        [ "$(jq -r '.chrome_pid // 0' "$sf")" != 0 ] || continue   # `rodney connect`: an external browser is never idle-stopped
        idle "$h" && stop_home "$h" "idle"
    done < <(find "$d" -name state.json)
done

if [ -f "$global_home/state.json" ] && [ "$(jq -r '.chrome_pid // 0' "$global_home/state.json")" != 0 ] && idle "$global_home"; then
    stop_home "$global_home" "idle"
fi
