#!/bin/bash
# PermissionRequest hook: remember what a permission prompt asks, so notify.sh's phone push can say it.
#
# Why: the Notification hook that drives the push carries only "Claude needs your permission"
# (captured on 2.1.301 for an AskUserQuestion and for a Bash prompt alike; the payload names no
# tool), yet 36 of the 51 pushes traced on 2026-10-16 were AskUserQuestion dialogs, whose whole
# content is the question. PermissionRequest fires as the prompt opens, about six seconds before
# that Notification, with tool_name and tool_input: for AskUserQuestion, Write, Edit, Bash and a
# prompt a PreToolUse hook forced with "ask" alike (all observed). So the text is stored per
# session and notify.sh reads it when the Notification arrives.
#
# The newest prompt wins: one file per session, overwritten. A prompt answered within the six
# seconds never gets a Notification and leaves its text behind, which is why notify.sh ignores
# a file older than two minutes; with two prompts open at once, the first push shows the
# second's text. A Bash prompt shows the model's description of the command (the tool's
# `description` field), or only the program when there is none: the command itself can carry a
# message (`aq send ... '<text>'`) that should not reach a lock screen, and so can any other
# tool's input, which is why other tools are named without it. Edit and Write show the file path.
#
# Prints nothing and always exits 0: stdout from a PermissionRequest hook is read as a decision.
# A payload this cannot read stores nothing, and the push falls back to the generic text.
source "$(dirname "$0")/../lib/_hook-env.sh"

hook_input >/dev/null
SID=$(hook_json '.session_id')
[ -n "$SID" ] || exit 0

SUMMARY=$(hook_input | jq -r '
    def flat: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    def clip: if length > 120 then .[:117] + "..." else . end;
    (.tool_name // empty) as $tool
    | .tool_input as $in
    | if $tool == "AskUserQuestion" then
        ($in.questions[0].question // empty | flat) as $q
        | ($in.questions | length) as $n
        | (if $n > 1 then " (+\($n - 1) more)" else "" end) as $more
        | ($in.questions[0].options // [] | map(.label // "" | flat) | join(" / ")) as $opts
        | ($q + (if $opts != "" then " [" + $opts + "]" else "" end) + $more) as $full
        | if ($full | length) <= 120 then $full else $q + $more | clip end
      elif $tool == "Bash" then
        ($in.description // "" | flat) as $d
        | if $d != "" then "Bash: \($d)" | clip
          else ($in.command // "" | flat | split(" ")[0]) as $p
            | if $p != "" then "Bash: \($p)" else empty end
          end
      elif $tool == "Edit" or $tool == "Write" then
        ($in.file_path // empty) as $p | "\($tool): \($p)" | clip
      else
        "Claude needs your permission to use \($tool)"
      end')

[ -n "$SUMMARY" ] && printf '%s\n' "$SUMMARY" > "$HOOK_RUNTIME_DIR/perm-summary-$SID"
exit 0
