#!/usr/bin/env bash
# Case table for permission-summary.sh and the way notify.sh uses what it stores. Not deployed
# (deliberately absent from the roost-apply manifest) — run it from the repo:
#   bash files/hooks/permission-summary.test.sh
#
# Payloads come from permission-summary.fixtures/, captured on Claude Code 2.1.301 from a
# throwaway interactive session (session id, prompt id and transcript path replaced by
# placeholders); the long-text cases edit one field of a capture. ntfy is a stub `curl` on
# PATH that records what would have been pushed, so no push leaves the box.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fx="$here/permission-summary.fixtures"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

mkdir -p "$tmp/bin" "$tmp/run" "$tmp/home"
# What notify.sh pushes, as `title<TAB>body` per line.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
title=""
while [ $# -gt 0 ]; do
    case "$1" in
        -H) case "$2" in "Title: "*) title="${2#Title: }" ;; esac; shift 2 ;;
        -d) printf '%s\t%s\n' "$title" "$2" >> "$STUB_DIR/pushes"; shift 2 ;;
        *) shift ;;
    esac
done
EOF
cat > "$tmp/bin/session" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_SESSION_NAME-probe-session}"
EOF
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/logger"
printf '#!/bin/bash\necho 100.64.0.1\n' > "$tmp/bin/tailscale"
chmod +x "$tmp/bin/"*

sid=00000000-0000-0000-0000-000000000001
stash="$tmp/run/perm-summary-$sid"

run() { # run SCRIPT < payload; the hook's stdout is the first line of the output
    env PATH="$tmp/bin:$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" STUB_DIR="$tmp" \
        bash "$here/$1" 2>> "$tmp/hook-stderr"
}
notify() { run notify.sh < "$1" >/dev/null; }

ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n      wanted: %s\n      got:    %s\n' "$1" "$2" "$3"; }
expect() { # expect LABEL WANT GOT
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# summary_of PAYLOAD_FILE -> the text stored for the session ("" when nothing is stored);
# also checks that the hook stays silent, since any stdout could be read as a decision.
summary_of() {
    rm -f "$stash"
    local out rc
    out=$(run permission-summary.sh < "$1"); rc=$?
    if [ -n "$out" ] || [ "$rc" -ne 0 ]; then
        bad "silent exit 0 for $(basename "$1")" "no stdout, rc 0" "rc=$rc stdout=$out"
    fi
    if [ -f "$stash" ]; then cat "$stash"; fi
}
with() { # with FIXTURE JQ_FILTER -> path of an edited copy of a capture
    jq "$2" "$fx/$1" > "$tmp/edited.json"; echo "$tmp/edited.json"
}
rep() { head -c "$1" < /dev/zero | tr '\0' "$2"; }

# --- what the summary says ---
expect 'question with its options' \
    'Which colour for the probe? [Red / Blue]' "$(summary_of "$fx/permission-request-askuserquestion.json")"
expect 'several questions: the first, the options, how many more' \
    'Pick a fruit [Apple / Pear] (+1 more)' "$(summary_of "$fx/permission-request-askuserquestion-two.json")"
long=$(rep 200 q)
got=$(summary_of "$(with permission-request-askuserquestion.json ".tool_input.questions[0].question = \"$long\"")")
expect 'a long question is clipped to 120 characters' "$(rep 117 q)..." "$got"
mid=$(rep 100 q)
expect 'options that would push the text past 120 are dropped' \
    "$mid" "$(summary_of "$(with permission-request-askuserquestion.json ".tool_input.questions[0].question = \"$mid\" | .tool_input.questions[0].options += [{label: \"$(rep 30 o)\"}]")")"
expect 'a command shows its description, not the command' \
    'Bash: Create empty file y.txt' "$(summary_of "$fx/permission-request-bash.json")"
expect 'a multi-line description runs together on one line' \
    'Bash: Run the install' \
    "$(summary_of "$(with permission-request-bash.json '.tool_input.description = "Run\n\tthe   install\n"')")"
got=$(summary_of "$(with permission-request-bash.json ".tool_input.description = \"$long\"")")
expect 'a long description is clipped to 120 characters' "Bash: $(rep 111 q)..." "$got"
expect 'with no description, only the program is named (a message in the command stays off the lock screen)' \
    'Bash: aq' \
    "$(summary_of "$(with permission-request-bash.json 'del(.tool_input.description) | .tool_input.command = "aq send x \"private words\""')")"
expect 'a write names its file' \
    'Write: /tmp/pushprobe/cwd/x.txt' "$(summary_of "$fx/permission-request-write.json")"
expect 'an edit names its file' \
    'Edit: /tmp/pushprobe/cwd/x.txt' "$(summary_of "$fx/permission-request-edit.json")"
expect 'any other tool is named without its input' \
    'Claude needs your permission to use mcp__slack__send_message' \
    "$(summary_of "$(with permission-request-bash.json '.tool_name = "mcp__slack__send_message" | .tool_input = {text: "private words"}')")"

# --- input it cannot use stores nothing and still stays silent ---
expect 'a question payload without questions' \
    '' "$(summary_of "$(with permission-request-askuserquestion.json 'del(.tool_input.questions)')")"
expect 'a payload without a session id' \
    '' "$(summary_of "$(with permission-request-bash.json 'del(.session_id)')")"
echo 'not json' > "$tmp/garbage.json"
expect 'input that is not JSON' '' "$(summary_of "$tmp/garbage.json")"

# --- notify.sh: the push carries the stored summary ---
reset() { rm -f "$tmp/pushes" "$stash" "$tmp/run/ntfy-rate.log"; }
last_push() { tail -n 1 "$tmp/pushes" 2>/dev/null || true; }

reset; run permission-summary.sh < "$fx/permission-request-askuserquestion.json" >/dev/null
notify "$fx/notification-permission-prompt.json"
expect 'the push is titled with the session name and says what is asked' \
    $'probe-session\tWhich colour for the probe? [Red / Blue]' "$(last_push)"
expect 'the summary is used up by its push' 'gone' "$([ -e "$stash" ] && echo present || echo gone)"

reset; notify "$fx/notification-permission-prompt.json"
expect 'no summary: the payload message is pushed as before' \
    $'probe-session\tClaude needs your permission' "$(last_push)"

reset; run permission-summary.sh < "$fx/permission-request-bash.json" >/dev/null
touch -d '3 minutes ago' "$stash"
notify "$fx/notification-permission-prompt.json"
expect 'a summary from an earlier, answered prompt is not reused' \
    $'probe-session\tClaude needs your permission' "$(last_push)"

reset; run permission-summary.sh < "$(with permission-request-bash.json '.session_id = "00000000-0000-0000-0000-0000000000ff"')" >/dev/null
notify "$fx/notification-permission-prompt.json"
expect "another session's summary is not used" \
    $'probe-session\tClaude needs your permission' "$(last_push)"
rm -f "$tmp/run/perm-summary-00000000-0000-0000-0000-0000000000ff"

reset; STUB_SESSION_NAME='' notify "$fx/notification-permission-prompt.json"
expect 'a session without a title is named after the working directory' \
    "$(basename "$PWD")"$'\tClaude needs your permission' "$(last_push)"

reset; for _ in $(seq 20); do date +%s; done > "$tmp/run/ntfy-rate.log"
run permission-summary.sh < "$fx/permission-request-bash.json" >/dev/null
notify "$fx/notification-permission-prompt.json"
expect 'twenty pushes within five seconds: the next is dropped' '' "$(last_push)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
