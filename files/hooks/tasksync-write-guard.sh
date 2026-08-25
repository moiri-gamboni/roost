#!/usr/bin/env bash
# PreToolUse hook (matchers: Bash, Write|Edit): deny hand-writes to what the tasks
# CLI owns in the apart-research workspace.
#
# Why: the worklog stint headers and Total lines are a calibration corpus written
# from measured values by `tasks stint` (`session time` attended figures, the
# delta marker in tasks/.sync/stints.json). A header typed by hand is where the
# grammar breaks and the duration gets guessed — the 2026-08-25 incident was a
# `printf` of an eyeballed "~1.5h" over a measured ~17 min. identity.json and
# tasks/.sync/ are tooling-owned outright: every hand edit there is either lost on
# the next pull or lies to the next verb.
#
# What passes, deliberately: task.md / research.md / write-up.md (the authored
# files), worklog narrative bullets, an Edit that corrects an existing header or
# Total *in place* (the repair path — it adds no line, so the header count does
# not grow), git recovery (`git checkout -- …`), and every `tasks …` verb, which
# never names these files on its command line. This is friction, not a boundary:
# a script writing the file internally passes, which is exactly how the CLI does.
#
# Matching is done on the RAW command string for Bash (same stance as
# notion-write-guard.sh): the guarded path almost always sits inside quotes, and a
# `python3 - <<'PY'` heredoc opening the file for write is a real vector.
# Does not source _hook-env.sh: it fires on every Bash, Write and Edit call.
set -uo pipefail

payload=$(cat || true)
[ -n "$payload" ] || exit 0
tool=$(jq -r '.tool_name // empty' <<<"$payload" || true)

WS_TASKS="$HOME/roost/apart-research/tasks"
STINT_LINES='^## 20[0-9]{2}-[0-9]{2}-[0-9]{2}|^\*\*Total:\*\*'

count_stint_lines() {
    # grep -c exits 1 on zero matches; the count is still what it printed.
    grep -cE "$STINT_LINES" <<<"$1" || true
}

deny() {
    local what="$1" fix="$2"
    logger -t roost/tasksync-write-guard "denied a hand write: $what"
    jq -nc --arg r "BLOCKED by the tasksync write guard — a roost PreToolUse hook.

What it is: ~/roost/code/server/files/hooks/tasksync-write-guard.sh, wired into the
PreToolUse block of ~/roost/code/server/files/settings.json (deployed to
~/roost/claude/hooks/).
Why it exists: $what is owned by the tasks CLI. Worklog stint headers and Totals
are a calibration corpus written from measured values ('session time' attended
hours); identity.json and tasks/.sync/ are tooling-owned and rewritten by the
next verb. A hand write here is how durations get guessed.
Sanctioned path: $fix
Repairs: an Edit that corrects an existing stint header or Total in place (adding
no new one) passes this guard.
Deliberately disable: remove the hook's PreToolUse entries from
files/settings.json in the server repo, then redeploy settings per its procedure.
Honest limit: this reads tool inputs, not a script's internal writes — which is
exactly how the CLI itself passes. It is friction, not a boundary." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

if [ "$tool" = "Write" ] || [ "$tool" = "Edit" ]; then
    path=$(jq -r '.tool_input.file_path // empty' <<<"$payload" || true)
    case "$path" in
        "$WS_TASKS"/.sync/*)
            deny "the generated sync state ($path)" \
                 "every tasksync verb rewrites tasks/.sync/ itself; run the verb" ;;
        "$WS_TASKS"/*/identity.json)
            deny "a tooling-owned identity file ($path)" \
                 "tasks pull (it spawns and repairs identity.json)" ;;
        "$WS_TASKS"/*/worklog.md)
            if [ "$tool" = "Write" ]; then
                content=$(jq -r '.tool_input.content // empty' <<<"$payload" || true)
                if [ "$(count_stint_lines "$content")" -gt 0 ]; then
                    deny "a worklog stint header or Total written by hand ($path)" \
                         "tasks stint <slug> [--note …] [--total] (measured hours; --manual/--hours for what nothing measured)"
                fi
            else
                old=$(jq -r '.tool_input.old_string // empty' <<<"$payload" || true)
                new=$(jq -r '.tool_input.new_string // empty' <<<"$payload" || true)
                if [ "$(count_stint_lines "$new")" -gt "$(count_stint_lines "$old")" ]; then
                    deny "a worklog stint header or Total added by hand ($path)" \
                         "tasks stint <slug> [--note …] [--total] (measured hours; --manual/--hours for what nothing measured)"
                fi
            fi ;;
    esac
    exit 0
fi

[ "$tool" = "Bash" ] || exit 0
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" || true)
[ -n "$cmd" ] || exit 0

# Not about the guarded files at all -> not ours. Cheap bail before any regex work.
grep -qE 'tasks/[^[:space:]"'"'"']*/(worklog\.md|identity\.json)|tasks/\.sync/' <<<"$cmd" || exit 0

guarded='tasks/([^[:space:]"'"'"']*/)?(worklog\.md|identity\.json)|tasks/\.sync/'

# A redirect aimed at a guarded file (not merely a command that mentions one and
# redirects elsewhere), or a writer token in a command that names one.
redirect='>>?[[:space:]]*["'"'"']?[^[:space:]<>|;&"'"'"']*('"$guarded"')'
writer='(^|[[:space:];&|])(tee|mv|cp)[[:space:]]|sed[[:space:]]+(-[^i[:space:]]+[[:space:]]+)*-i'
pyopen='open\([^)]*(worklog\.md|identity\.json|tasks/\.sync/)[^)]*["'"'"'](w|a)'

if grep -qE "$redirect" <<<"$cmd" \
    || { grep -qE "$writer" <<<"$cmd" && grep -qE "$guarded" <<<"$cmd"; } \
    || grep -qE "$pyopen" <<<"$cmd"; then
    deny "a shell write into a tasks CLI-owned file (worklog.md stint lines, identity.json, or tasks/.sync/)" \
         "tasks stint <slug> for worklogs; tasks pull for identity.json and tasks/.sync/"
fi
exit 0
