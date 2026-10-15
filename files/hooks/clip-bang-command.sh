#!/usr/bin/env bash
# Stop hook: puts the command a reply hands the user to run with `!` on their clipboard.
# The command is the first one in the final message (`last_assistant_message`): an inline
# code span starting with "! " whose opening backtick is not glued to a word (so "`x`! Now"
# is prose), or a line of its own starting with "! " (a fenced block's line). The global
# CLAUDE.md asks for the span form. It goes through `clip --auto` (scripts/clip.sh), which
# leaves a manual clip under 10 minutes old in place.
#
# The clip keeps the "! " and has no trailing newline: pasted into an empty Claude Code
# prompt, a leading "!" switches it to bash mode, so paste + Enter runs it in the session
# (checked on 2.1.300 with a bracketed paste); pasted into a shell, "! cmd" runs cmd with
# its exit status negated. One systemMessage line reports the outcome, shown under the
# reply as "Stop says: …"; a reply without such a command leaves no trace. Main session
# only: subagents end on SubagentStop, which this is not wired to.
set -uo pipefail

msg=$(jq -r '.last_assistant_message // empty' || true)
# shellcheck disable=SC2016  # the backticks are the regex's, not a substitution
mapfile -t found < <(grep -aoP '(?<![\w`])`\K! +[^\s`][^`]*(?=`)|^\s*\K! +\S.*' <<<"$msg")
cmd=${found[0]:-}
cmd=${cmd%"${cmd##*[![:space:]]}"}
[[ -n $cmd ]] || exit 0

out=$(printf '%s' "$cmd" | clip --auto)
case $? in
    0) note="copied \"$cmd\" to your clipboard" ;;
    3) note="\"$cmd\" not copied to your clipboard: ${out#held: }" ;;
    *) note="\"$cmd\" not copied: no route to your clipboard" ;;
esac
jq -nc --arg m "$note" '{systemMessage: $m}'
