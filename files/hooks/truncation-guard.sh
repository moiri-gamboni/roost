#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): deny head/tail invocations that truncate below 100 lines.
#
# Why: the CLAUDE.md rule ("NEVER use head -N or tail -N with N < 100. Run commands unfiltered
# first") keeps being violated across sessions and rewordings. That is a mechanism problem, not
# an attention one: piping to `head` is a motor pattern that fires while the command is being
# composed, whereas a prohibition sitting in context has to be recalled at that same instant.
# Habit wins. Interception does not depend on remembering.
#
# What the rule protects: the cut part is usually the interesting part. A deploy log tailed to
# 25 lines hides which steps ran; a grep piped to head hides the match that mattered and
# produces a confident conclusion from a partial read.
#
# Allowed on purpose:
#   -n / --lines >= 100      the CLAUDE.md floor
#   -c / --bytes             byte slicing, used to redact rather than to shorten
#   tail -f / -F / --follow  following a live log is not truncation (a count beside it still is)
#   --help / --version
# Denied on purpose: a bare `head`/`tail` with no count — the default is 10 lines, under the floor.
#
# This is friction, not a boundary. Its predecessor (`no-truncation.sh`, 53b2f9b) was reverted
# by its own author a day later because the deny message identified neither its origin nor its
# purpose, so the fastest read was "unexplained obstacle". The message below names all of it.
#
# Matching runs on the command with heredoc bodies and quoted spans STRIPPED, in that order —
# stripping quotes first turns `<<'MSG'` into `<<`, which no longer reads as a heredoc opener,
# and the body survives to be matched (the predecessor denied its own commit that way). The
# inverse of notion-write-guard.sh, which matches raw: there the target sits inside quotes;
# here a `head` inside a quoted string, a commit message or a doc is noise. Double-quoted spans
# holding a `$` survive, because `echo "$(ls | head -5)"` is code and the common idiom for it.
# Consequence: the body of `bash -c '… | head -3'` passes. Accepted.
set -uo pipefail

# `|| true` and not `2>/dev/null`: a malformed payload should still leave a visible parse error
# for whoever is debugging, it just must not take the turn down with it.
cmd=$(jq -r '.tool_input.command // empty' || true)
[ -n "$cmd" ] || exit 0

# Cheapest gate first: no head/tail word at all -> not ours (`tailscale`, `HEAD`, `headless` pass).
grep -qwE 'head|tail' <<<"$cmd" || exit 0

stripped=$(printf '%s' "$cmd" \
    | sed -E "/<<-?[\"']?[A-Za-z_][A-Za-z_0-9]*[\"']?$/,/^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*$/d" \
    | sed -E "s/'[^']*'//g; s/\"[^\"$]*\"//g")

deny() {
    logger -t roost/truncation-guard "denied $1"
    jq -nc --arg r "BLOCKED by the truncation guard — a roost PreToolUse hook. Offending stage: $1

What it is: ~/roost/code/server/files/hooks/truncation-guard.sh, wired into the PreToolUse block of
~/roost/code/server/files/settings.json (deployed to ~/roost/claude/hooks/).
Why it exists: the CLAUDE.md rule against head/tail under 100 lines is broken by habit, not by
intent, and the cut part of an output is usually the part that mattered.
What to do instead: run the command unfiltered. If the volume is genuinely a problem, narrow the
COMMAND (a tighter grep, a --query, a smaller range, awk), not its output; -n 100 or more passes.
tail -f, -c/--bytes and --help pass too.
Deliberately disable: remove this hook's PreToolUse entry from files/settings.json, then
roost-apply push files/settings.json.
Honest limit: it reads the command string with quotes and heredocs stripped, so a truncation inside
bash -c '…' or a script on disk passes. Friction, not a boundary." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

# Split into simple commands: pipes, separators, subshells, command substitution, newlines.
# A segment is ours when it starts with head/tail (an optional sudo in front), i.e. the word is
# in command position — `git log HEAD` and `cat /tmp/head/x` never get here.
while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg=$(sed -E 's/^sudo[[:space:]]+//' <<<"$seg")
    grep -qE '^(head|tail)([[:space:]]|$)' <<<"$seg" || continue
    args="${seg#head}"; args="${args#tail}"

    grep -qE '(^|[[:space:]])--(help|version)([[:space:]]|$)' <<<"$args" && continue
    grep -qE '(^|[[:space:]])(-[a-zA-Z]*c|--bytes)' <<<"$args" && continue

    # The line count: -n N, -nN, -qn N, --lines=N, --lines N, legacy -N. Sign (+N / -N) ignored:
    # `tail -n +5` and `head -n -5` still discard lines, and the floor is about magnitude.
    n=$(grep -oE '(^|[[:space:]])(-[a-zA-Z]*n[[:space:]]*|--lines(=|[[:space:]]+)|-)[+-]?[0-9]+' <<<"$args" \
        | grep -oE '[0-9]+$' | awk 'NR == 1')
    if [ -n "$n" ]; then
        [ "$n" -lt 100 ] && deny "$seg"
        continue
    fi
    grep -qE '(^|[[:space:]])(-[a-zA-Z]*[fF]|--follow)' <<<"$args" && continue
    deny "$seg (no count: head/tail default to 10 lines)"
done < <(tr '|;&()`' '\n' <<<"$stripped")

exit 0
