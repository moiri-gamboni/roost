#!/bin/bash
# Behavior spec for files/scripts/rodney.sh (the ~/bin/rodney wrapper) and
# files/scheduled/rodney-reap.sh. Drives real headless Chromes (~1.5 s each)
# under fake session ids, with a fake presence registry for the reaper.
#   tests/rodney.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
W="$here/files/scripts/rodney.sh"
R="$here/files/scheduled/rodney-reap.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/rodney-test.XXXX")
export RODNEY_SESSIONS_DIR="$T/sessions"
export RODNEY_GLOBAL_HOME="$T/global"
export CLAUDE_CONFIG_DIR="$T/config"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
unset RODNEY_HOME
# shellcheck disable=SC2317   # trap-invoked
cleanup() {
    local f
    while read -r f; do RODNEY_HOME="$(dirname "$f")" "$HOME/go/bin/rodney" stop >/dev/null || true; done < <(find "$T" -name state.json)
    for _ in $(seq 50); do pgrep -f -- "--user-data-dir=$T/" >/dev/null || break; sleep 0.1; done
    rm -rf "$T"
}
trap cleanup EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
chrome_pid() { jq -r .chrome_pid "$1/state.json"; }
chromes_for() { pgrep -f -- "--user-data-dir=$1/chrome-data " | wc -l; }
# pgrep matches every Chrome process of that profile (zygotes included); zero means gone
register() { printf '{"pid":%s,"sessionId":"%s"}' "$2" "$1" > "$CLAUDE_CONFIG_DIR/sessions/$2.json"; }
export -f chrome_pid chromes_for
reap() { "$R" 2>"$T/reap.err" || { bad "reap exited $?"; cat "$T/reap.err"; }; }

echo "== session A: first verb auto-starts a private browser"
A="$RODNEY_SESSIONS_DIR/sid-A"
out=$(CLAUDE_CODE_SESSION_ID=sid-A "$W" open https://example.com 2>"$T/a.err")
check "open printed only the page title on stdout" [ "$out" = "Example Domain" ]
check "the start banner went to stderr" grep -q 'Chrome started' "$T/a.err"
check "state lives under the session dir" [ -f "$A/state.json" ]
check "last-used stamped" [ -f "$A/last-used" ]
check "no global state written" [ ! -e "$T/.rodney" ]
apid=$(chrome_pid "$A")

echo "== session B: its own browser, its own tab list"
B="$RODNEY_SESSIONS_DIR/sid-B"
CLAUDE_CODE_SESSION_ID=sid-B "$W" open https://example.org >/dev/null 2>&1
check "B has one page, not A's" bash -c "CLAUDE_CODE_SESSION_ID=sid-B '$W' pages | grep -c '^' | grep -qx 1"
check "A still shows example.com" bash -c "CLAUDE_CODE_SESSION_ID=sid-A '$W' url | grep -q example.com"
check "two distinct Chromes" [ "$apid" != "$(chrome_pid "$B")" ]

echo "== explicit RODNEY_HOME wins over the session"
CLAUDE_CODE_SESSION_ID=sid-A RODNEY_HOME="$T/custom" "$W" open https://example.net >/dev/null 2>&1
check "custom home used" [ -f "$T/custom/state.json" ]
check "A's page untouched" bash -c "CLAUDE_CODE_SESSION_ID=sid-A '$W' url | grep -q example.com"

echo "== --local resolves to ./.rodney, as upstream does"
mkdir -p "$T/proj"; ( cd "$T/proj" && CLAUDE_CODE_SESSION_ID=sid-A "$W" --local open https://example.com >/dev/null 2>&1 )
check "local state in cwd" [ -f "$T/proj/.rodney/state.json" ]
check "auto-detected on the next call" bash -c "cd '$T/proj' && CLAUDE_CODE_SESSION_ID=sid-A '$W' url | grep -q example.com && [ -f '$T/proj/.rodney/last-used' ]"

echo "== a dead Chrome is replaced, a stale pid is never signalled"
kill "$apid"; sleep 1
check "A's chrome gone" [ "$(chromes_for "$A")" = 0 ]
CLAUDE_CODE_SESSION_ID=sid-A "$W" open https://example.com >/dev/null 2>"$T/a2.err"
check "restarted transparently" bash -c "[ \"\$(chrome_pid '$A')\" != '$apid' ] && grep -q 'Chrome started' '$T/a2.err'"
apid=$(chrome_pid "$A")

echo "== concurrent first use starts exactly one Chrome"
C="$RODNEY_SESSIONS_DIR/sid-C"
CLAUDE_CODE_SESSION_ID=sid-C "$W" url >/dev/null 2>&1 &
CLAUDE_CODE_SESSION_ID=sid-C "$W" url >/dev/null 2>&1 &
CLAUDE_CODE_SESSION_ID=sid-C "$W" url >/dev/null 2>&1 &
wait
check "one main Chrome for C" bash -c "pgrep -f -- '--user-data-dir=$C/chrome-data ' | while read -r p; do [ \"\$(ps -o ppid= -p \"\$p\" | tr -d ' ')\" = 1 ] && echo \"\$p\"; done | wc -l | grep -qx 1"

echo "== lifecycle verbs pass straight through"
check "status reports the session browser" bash -c "CLAUDE_CODE_SESSION_ID=sid-A '$W' status | grep -q 'PID $apid'"
check "stop with no browser is upstream's error, no auto-start" bash -c "! CLAUDE_CODE_SESSION_ID=sid-Z '$W' stop 2>&1 | grep -q 'Chrome started' && [ ! -e '$RODNEY_SESSIONS_DIR/sid-Z/state.json' ]"
check "help never starts anything" bash -c "CLAUDE_CODE_SESSION_ID=sid-Y '$W' --help | grep -q 'rodney - Chrome' && [ ! -e '$RODNEY_SESSIONS_DIR/sid-Y' ]"

echo "== reaper: dead session torn down, live one kept"
register sid-B $$          # B's session is this test process: alive
register sid-C 999999      # C's owner pid is gone
mkdir -p "$A/sub"; RODNEY_HOME="$A/sub" "$HOME/go/bin/rodney" start >/dev/null    # a subagent-scoped browser under A
subpid=$(chrome_pid "$A/sub")
reap
check "A (unregistered) removed, both its browsers stopped" bash -c "[ ! -e '$A' ] && [ \"\$(chromes_for '$A')\" = 0 ] && [ ! -d /proc/$subpid ]"
check "C (dead pid) removed" [ ! -e "$C" ]
check "B kept and still serving" bash -c "CLAUDE_CODE_SESSION_ID=sid-B '$W' url | grep -q example.org"
check "custom home (outside the tree) untouched" [ -f "$T/custom/state.json" ]

echo "== reaper: idle browser stopped, state cleared, next verb restarts it"
bpid=$(chrome_pid "$B")
touch -d '2 hours ago' "$B/last-used"
reap
check "B's idle chrome stopped" bash -c "[ ! -e '$B/state.json' ] && [ \"\$(chromes_for '$B')\" = 0 ]"
check "B's dir kept (session alive)" [ -d "$B" ]
check "B restarts on the next verb" bash -c "CLAUDE_CODE_SESSION_ID=sid-B '$W' open https://example.com 2>/dev/null | grep -q Example && [ \"\$(chrome_pid '$B')\" != '$bpid' ]"

echo "== reaper: --dry-run reports, changes nothing"
touch -d '2 hours ago' "$B/last-used"
out=$("$R" --dry-run 2>&1)
check "dry-run names the idle browser" grep -q "idle.*$B" <<<"$out"
check "dry-run left it running" [ -f "$B/state.json" ]

exit $fail
