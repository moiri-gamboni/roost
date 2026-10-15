#!/usr/bin/env bash
# Stop hook: puts the command a reply hands the user to run with `!` on their clipboard.
# The command is the first one in the final message (`last_assistant_message`): an inline
# code span whose text starts with "! ", or a line of its own starting with "! " (a fenced
# block's line) but not "! [", which is git's refused-push line. The global CLAUDE.md asks
# for the span form. It goes through `clip --auto` (files/scripts/clip.sh), which leaves a
# manual clip under 10 minutes old in place.
#
# The clip keeps the "! " and has no trailing newline: pasted into an empty Claude Code
# prompt, a leading "!" switches it to bash mode, so paste + Enter runs it in the session
# (Claude Code's behaviour, seen on 2.1.300: if a pasted command stops running, recheck
# that first); pasted into a shell, "! cmd" runs cmd with its exit status negated. One
# systemMessage line reports the outcome, shown under the reply as "Stop says: …"; a reply
# without such a command leaves no trace. Main session only: subagents end on
# SubagentStop, which this is not wired to.
set -uo pipefail

msg=$(jq -r '.last_assistant_message // empty' || true)
# Code spans paired left to right as markdown pairs them, and lines starting with "! ", in
# order of appearance; a "!" between two spans is never inside one.
cmd=
# shellcheck disable=SC2016  # the backticks are the regex's, not a substitution
while IFS= read -r m; do
    m=${m#"${m%%[![:space:]]*}"}
    [[ $m == \`* ]] && m=${m:1:-1}
    if [[ $m =~ ^!\ +[^[:space:]] ]]; then cmd=${m%"${m##*[![:space:]]}"}; break; fi
done < <(grep -aoP '`[^`]+`|^\s*! +[^\s\[].*' <<<"$msg")
[[ -n $cmd ]] || exit 0

out=$(printf '%s' "$cmd" | clip --auto); rc=$?
case $rc in
    0) note="copied \"$cmd\" to your clipboard" ;;
    3) note="\"$cmd\" not copied to your clipboard: ${out#held: }" ;;
    *) out=${out:-clip exited $rc}; note="\"$cmd\" not copied: ${out//$'\n'/; }" ;;
esac
jq -nc --arg m "$note" '{systemMessage: $m}'
