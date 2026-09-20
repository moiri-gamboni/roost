#!/bin/bash
# rodney — one headless Chrome per Claude Code session, started on first use.
#
# Wraps simonw/rodney (~/go/bin/rodney), whose "active tab" is a bare index in
# one shared state file: two sessions on the same browser renumber each other's
# tabs with every newpage/closepage, and tabs nobody closes pile up in a Chrome
# that lives for weeks. This wrapper gives each session its own browser and
# leaves closing to rodney-reap.sh (session gone, or idle > 1 h).
#
# Home resolution, first match wins (upstream's own order, with one step added):
#   RODNEY_HOME set              honored as is (a subagent wanting its own
#                                browser: RODNEY_HOME=<session home>/<name>,
#                                so the reaper tears it down with the session)
#   --local / --global in args   ./.rodney or ~/.rodney, as upstream
#   ./.rodney/state.json exists  ./.rodney, as upstream
#   CLAUDE_CODE_SESSION_ID set   $RODNEY_SESSIONS_DIR/<session id>   ← added
#   otherwise                    ~/.rodney
# The resolved home is passed to the real binary as RODNEY_HOME, which is its
# highest-precedence setting, so the two resolutions cannot disagree.
#
# Every browser-needing verb first makes sure a Chrome is up: no state file, or
# a state file whose pid is not a Chrome on that profile (reboot, OOM kill) →
# `rodney start` under a per-home lock, banner to stderr so stdout stays the
# verb's own output, and stamps <home>/last-used, the reaper's idle clock.
# start/stop/status/connect/help pass straight through and stamp nothing.
set -euo pipefail

real="$HOME/go/bin/rodney"
sessions_dir="${RODNEY_SESSIONS_DIR:-$HOME/.cache/rodney/sessions}"

local_flag=0; global_flag=0; verb=""
for a in "$@"; do
    case "$a" in
        --local)  local_flag=1; global_flag=0 ;;   # last one wins, as upstream
        --global) global_flag=1; local_flag=0 ;;
        *) [ -n "$verb" ] || verb="$a" ;;
    esac
done

if [ -n "${RODNEY_HOME:-}" ]; then home="$RODNEY_HOME"
elif [ "$local_flag" = 1 ]; then home="$PWD/.rodney"
elif [ "$global_flag" = 1 ]; then home="$HOME/.rodney"
elif [ -f "$PWD/.rodney/state.json" ]; then home="$PWD/.rodney"
elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then home="$sessions_dir/$CLAUDE_CODE_SESSION_ID"
else home="$HOME/.rodney"
fi
home=$(realpath -sm "$home")   # lexically clean, like rodney's own filepath.Join: "/x/y/" must match the "/x/y/chrome-data" it launches with
export RODNEY_HOME="$home"

case "$verb" in
    ""|start|stop|status|connect|help|-h|--help|--version|_proxy) exec "$real" "$@" ;;
esac

# True when the state file's pid is a live Chrome running on this home's profile
# (a recycled pid after a reboot must not count as "running").
chrome_alive() {
    [ -f "$home/state.json" ] || return 1
    local pid; pid=$(jq -r '.chrome_pid // 0' "$home/state.json")
    [ "$pid" != 0 ] || return 0            # `rodney connect`: an external browser we never manage
    [ -r "/proc/$pid/cmdline" ] || return 1
    local cmd; cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    [[ "$cmd" == *"--user-data-dir=$home/chrome-data "* ]]
}

mkdir -p "$home"
exec 9>"$home/.lock"
flock 9
if ! chrome_alive; then
    # A Chrome still holding this profile with no usable state file (a start whose
    # state write failed, a truncated file) is ours and unreachable: `start` would
    # only die on its SingletonLock, every call, so clear it first.
    pkill -9 -f -- "--user-data-dir=$home/chrome-data " || true
    rm -f "$home/state.json"
    "$real" start 9>&- >&2     # fd 9 closed for Chrome: an inherited lock fd would never unlock
fi
exec 9>&-
touch "$home/last-used"
exec "$real" "$@"
