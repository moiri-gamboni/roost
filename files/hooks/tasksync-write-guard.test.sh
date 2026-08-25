#!/usr/bin/env bash
# Matcher test for tasksync-write-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/tasksync-write-guard.test.sh
#
# Each case feeds a synthetic PreToolUse payload to the hook and asserts allow vs deny.
# "allow" means silence and exit 0; "deny" means a permissionDecision of deny on stdout.
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/tasksync-write-guard.sh"
pass=0
fail=0

WS="/home/moiri/roost/apart-research"

verdict() {
    if grep -q '"permissionDecision":"deny"' <<<"$1"; then echo deny; else echo allow; fi
}

report() {
    local expect="$1" got="$2" label="$3"
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'ok    %-5s %s\n' "$got" "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  want=%-5s got=%-5s %s\n' "$expect" "$got" "$label"
    fi
}

check_bash() {
    local expect="$1" label="$2" cmd="$3" out
    out=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook")
    report "$expect" "$(verdict "$out")" "bash: $label"
}

check_write() {
    local expect="$1" label="$2" path="$3" content="$4" out
    out=$(jq -nc --arg p "$path" --arg c "$content" \
        '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}' | bash "$hook")
    report "$expect" "$(verdict "$out")" "write: $label"
}

check_edit() {
    local expect="$1" label="$2" path="$3" old="$4" new="$5" out
    out=$(jq -nc --arg p "$path" --arg o "$old" --arg n "$new" \
        '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n}}' | bash "$hook")
    report "$expect" "$(verdict "$out")" "edit: $label"
}

HEADER='## 2026-08-25 · session 0f5abaae-ff4b-4b00-a853-38abc9be3471 ("A title") · ~0.5h'
TOTAL='**Total:** ~0.5h · no P80'

# --- Write: a worklog written whole with stint lines is the bypass ---
check_write deny 'worklog.md with a stint header' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "# Worklog

$HEADER
- did things
"
check_write deny 'worklog.md with a Total line' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "# Worklog

$TOTAL
"
check_write allow 'worklog.md with only narrative (no header, no Total)' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "# Worklog

notes to self
"
check_write allow 'a research.md is not guarded' \
    "$WS/tasks/2026-08-25-some-slug/research.md" "$HEADER"
check_write allow 'a worklog.md outside the workspace tasks tree' \
    "/tmp/somewhere/worklog.md" "$HEADER"

# --- Edit: adding a header by hand denies; repairing one in place passes ---
check_edit deny 'appending a stint header' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "- old bullet" "- old bullet

$HEADER"
check_edit deny 'appending a Total line' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "- done" "- done

$TOTAL"
check_edit allow 'correcting the hours of an existing header' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "$HEADER" "${HEADER%\~0.5h}~0.2h"
check_edit allow 'correcting an existing Total in place' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "$TOTAL" '**Total:** ~0.3h · no P80'
check_edit allow 'editing narrative bullets' \
    "$WS/tasks/2026-08-25-some-slug/worklog.md" "- old bullet" "- corrected bullet"
check_edit allow 'an Edit elsewhere that pastes a header-shaped line' \
    "$WS/notes/estimates.md" "x" "$HEADER"

# --- identity.json and tasks/.sync are tooling-owned wholesale ---
check_write deny 'identity.json' \
    "$WS/tasks/2026-08-25-some-slug/identity.json" '{"page_id": "x"}'
check_edit deny 'identity.json edit' \
    "$WS/tasks/2026-08-25-some-slug/identity.json" '"stage": 1' '"stage": 9'
check_write deny 'tasks/.sync/ls.md' \
    "$WS/tasks/.sync/ls.md" "# tasks ls"
check_write deny 'tasks/.sync/stints.json' \
    "$WS/tasks/.sync/stints.json" '{}'
check_write allow 'task.md is the working copy, freely edited' \
    "$WS/tasks/2026-08-25-some-slug/task.md" "---
status: \"Done\"
---

# T
"

# --- Bash: shell writes into the guarded files ---
check_bash deny 'printf redirect into a worklog' \
    "printf '$HEADER\n' >> tasks/2026-08-25-some-slug/worklog.md"
check_bash deny 'echo redirect, absolute path' \
    "echo done >> $WS/tasks/2026-08-25-some-slug/worklog.md"
check_bash deny 'tee into a worklog' \
    "printf x | tee -a tasks/2026-08-25-some-slug/worklog.md"
check_bash deny 'sed -i on a worklog' \
    "sed -i 's/~0.5h/~1h/' tasks/2026-08-25-some-slug/worklog.md"
check_bash deny 'redirect into identity.json' \
    "echo '{}' > tasks/2026-08-25-some-slug/identity.json"
check_bash deny 'sed -i on the generated ls.md' \
    "sed -i 's/a/b/' tasks/.sync/ls.md"
check_bash deny 'python heredoc opening a worklog for append' \
    "$(printf 'python3 - <<%sPY%s\nopen("tasks/2026-08-25-x/worklog.md", "a").write("x")\nPY' "'" "'")"

# --- Bash: reads and the CLI itself pass ---
check_bash allow 'reading a worklog' \
    "cat tasks/2026-08-25-some-slug/worklog.md"
check_bash allow 'grepping the tree' \
    "grep -rn 'Total' tasks/2026-08-25-some-slug/worklog.md tasks/.sync/"
check_bash allow 'the stint verb (never names the file)' \
    "tasks stint 2026-08-25-some-slug --note 'did things' --total"
check_bash allow 'the checker reading a folder' \
    "python3 apart-tools/tasksync/check-worklog.py tasks/2026-08-25-some-slug"
check_bash allow 'git recovery of a worklog' \
    "git checkout -- tasks/2026-08-25-some-slug/worklog.md"
check_bash allow 'git add of task folders' \
    "git add tasks/2026-08-25-some-slug/worklog.md tasks/2026-08-25-some-slug/task.md"
check_bash allow 'redirect into a task.md (unguarded file)' \
    "cat body.md >> tasks/2026-08-25-some-slug/task.md"
check_bash allow 'redirect into a worklog outside tasks/' \
    "echo x >> notes/worklog.md"

# --- other tools never match ---
out=$(jq -nc '{tool_name: "Read", tool_input: {file_path: "/x/tasks/a/identity.json"}}' | bash "$hook")
report allow "$(verdict "$out")" "read: identity.json (not a write tool)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
