#!/bin/bash
# Test for the Beeper send-gate probe in files/travel/travel-health.sh: the deployed hook must
# still answer "ask" to a send, and settings.json must still run it on Bash. Each case sources
# the app checks against a temporary config directory holding the real hook (or a broken
# stand-in) and the settings shape captured from the live file, with the other checks' commands
# stubbed to fail, and asserts on what lands in $FAILURES and the journal.
#   tests/beeper-gate-probe.sh      # from the repo root
# shellcheck disable=SC2317  # the helpers are called through check
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/beeper-probe.XXXX")
trap 'rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

mkdir -p "$T/bin"
for cmd in ss sudo curl; do printf '#!/bin/bash\nexit 1\n' > "$T/bin/$cmd"; done
cat > "$T/bin/logger" <<'EOF'
#!/bin/bash
printf '%s\n' "${*: -1}" >> "$LOG"
EOF
chmod +x "$T/bin/"*

wired='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/roost/claude/hooks/beeper-send-guard.sh","timeout":15}]}]}}'

# A config directory with the real hook and settings that wire it; each case then breaks one thing.
new_cfg() {
    cfg=$T/$1
    mkdir -p "$cfg/hooks"
    cp "$here/files/hooks/beeper-send-guard.sh" "$cfg/hooks/"
    chmod +x "$cfg/hooks/beeper-send-guard.sh"
    printf '%s\n' "$wired" > "$cfg/settings.json"
}
replace_hook() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$cfg/hooks/beeper-send-guard.sh"; }

# Runs the app checks; leaves the failure list in $T/failures, the journal lines in $T/log and
# anything the checks wrote to stderr in $T/stderr.
run_checks() {
    export LOG=$T/log
    : > "$LOG"
    PATH="$T/bin:$PATH" CLAUDE_CONFIG_DIR=$cfg bash -c '
        set -uo pipefail
        check() { :; }; check_service() { :; }
        FAILURES=""; _HOOK_TAG=test
        source "$1"
        printf "%b" "$FAILURES"' _ "$here/files/travel/travel-health.sh" > "$T/failures" 2> "$T/stderr"
}
not_reported() { ! grep -q "beeper-send-guard" "$T/failures"; }
reported_as() { grep "beeper-send-guard" "$T/failures" | grep -q -- "$1"; }

echo "healthy:"
new_cfg healthy; run_checks
check "no failure reported"        not_reported
check "journal says OK"            grep -q "OK: beeper-send-guard" "$T/log"
check "nothing on stderr"          test ! -s "$T/stderr"

echo "hook gone:"
new_cfg missing; rm "$cfg/hooks/beeper-send-guard.sh"; run_checks
check "reported as missing"        reported_as "missing"
new_cfg not-executable; chmod -x "$cfg/hooks/beeper-send-guard.sh"; run_checks
check "reported as missing when not executable"  reported_as "missing"

echo "hook no longer asks:"
new_cfg silent; replace_hook 'exit 0'; run_checks
check "no output is reported"      reported_as "did not ask"
new_cfg allows; replace_hook 'echo "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}"'; run_checks
check "an allow is reported"       reported_as "did not ask"
new_cfg garbled; replace_hook 'echo "not json"'; run_checks
check "non-JSON output is reported"  reported_as "did not ask"
check "the raw answer is in the journal"  grep -q "not json" "$T/log"

echo "hook not wired:"
new_cfg no-entry; printf '{"hooks":{"PreToolUse":[]}}\n' > "$cfg/settings.json"; run_checks
check "an empty PreToolUse is reported"  reported_as "not wired"
new_cfg wrong-matcher; printf '%s\n' "${wired/\"Bash\"/\"Write|Edit\"}" > "$cfg/settings.json"; run_checks
check "an entry that does not match Bash is reported"  reported_as "not wired"
new_cfg no-settings; rm "$cfg/settings.json"; run_checks
check "a missing settings.json is reported"  reported_as "not wired"

exit "$fail"
