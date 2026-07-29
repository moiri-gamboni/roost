#!/usr/bin/env bash
# Deny shell commands that truncate their own output.
#
# The rule this enforces lives in CLAUDE.md and is repeatedly violated anyway. That is a
# mechanism problem, not an attention problem: piping to `head` is a motor pattern that fires
# while a command is being composed, whereas a prohibition sitting in context has to be actively
# recalled at that same instant. Habit wins. Interception does not depend on remembering.
#
# What it costs when it fires: the truncated output is usually the interesting part. A deploy
# log tailed to 25 lines hides which steps ran; a grep piped to head hides the match that
# mattered and produces confident conclusions from a partial read.
#
# Allowed on purpose:
#   tail -f / -F        following a live log is not truncation
#   head -c / tail -c   byte slicing, used to redact rather than to shorten
#   -n >= 100           the CLAUDE.md threshold; big enough that nothing material is lost
set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Strip heredoc bodies and then quoted spans, so a `head` inside a written-out script, a commit
# message, a string or a filename is not mistaken for a pipeline stage.
#
# Order matters and is not obvious: stripping quotes first turns `<<'MSG'` into `<<`, which no
# longer looks like a heredoc opener, and the body survives to be matched. This hook denied its
# own commit that way.
stripped=$(printf '%s' "$cmd" \
    | sed -E "/<<-?[\"']?[A-Za-z_][A-Za-z_0-9]*[\"']?$/,/^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*$/d" \
    | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")

deny() {
    jq -nc --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

# Piping into head/tail at all. The count is irrelevant: the reflex is the pipe.
if grep -qE '\|[[:space:]]*(head|tail)([[:space:]]|$)' <<<"$stripped"; then
    if ! grep -qE '\|[[:space:]]*tail[[:space:]]+-[fF]' <<<"$stripped" \
        && ! grep -qE '\|[[:space:]]*(head|tail)[[:space:]]+-c' <<<"$stripped" \
        && ! grep -qE '\|[[:space:]]*(head|tail)[[:space:]]+-n?[[:space:]]*[1-9][0-9]{2,}' <<<"$stripped"; then
        deny "Piping to head/tail truncates the output you are about to reason from, and the cut part is usually the part that mattered. Re-run it unfiltered. If the volume is genuinely a problem, narrow the command itself (a tighter grep, a --query, a smaller range) rather than the output, or use -n 100 or more."
    fi
fi

# Bare `head -N file` / `tail -N file` below the threshold.
while read -r n; do
    [ -n "$n" ] && [ "$n" -lt 100 ] 2>/dev/null &&
        deny "head/tail with -n ${n} truncates below the 100-line floor in CLAUDE.md. Run it unfiltered first, or raise the count to 100 or more if you genuinely need a bound."
done < <(grep -oE '(^|[[:space:]])(head|tail)[[:space:]]+-n?[[:space:]]*([0-9]+)' <<<"$stripped" | grep -oE '[0-9]+$')

exit 0
