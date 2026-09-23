#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write): after an edit to an instruction file
# (a CLAUDE.md, AGENTS.md or SKILL.md, including the *-CLAUDE.md sources the
# server repo deploys), hand the model a short checklist as additionalContext.
# These files grow by accretion — each session that hits a problem appends a
# paragraph — and nothing pushed back at write time; this is that push-back.
# Once per session per file, so a run of edits to one file gets it once.
# Always exits 0: PostToolUse cannot block, and this must never break a turn.
set -uo pipefail

[ -t 0 ] && exit 0
input=$(cat)
f=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null || true)
sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null || true)
base=${f##*/}
case "$base" in
    SKILL.md) load="its description is in every session's skill list, loaded whether or not the skill is used, so keep it to when to use the skill in 1–3 sentences; the body loads whole each time the skill is invoked" ;;
    *CLAUDE.md|AGENTS.md)
        case "$f" in
            */roost/claude/CLAUDE.md|*/global-CLAUDE.md) load="the global file loads on every turn of every session and subagent, the most expensive text there is" ;;
            *) load="a repo's root file loads in every session launched there, a subdirectory's when a session reads files in that directory" ;;
        esac ;;
    *) exit 0 ;;
esac

# Seen-marker per (session, file); a missing session id just means no dedup.
if [ -n "$sid" ]; then
    state="${XDG_RUNTIME_DIR:-/tmp}/instruction-file-edit"
    mkdir -p "$state" 2>/dev/null || true
    mark="$state/$sid-$(printf '%s' "$f" | sha1sum | cut -d' ' -f1)"
    [ -e "$mark" ] && exit 0
    : >"$mark" 2>/dev/null || true
fi

jq -cn --arg c "Instruction file edited ($f): $load. Before finishing, check the edit against this:
- Add only what a session would get wrong without it and would not learn when it matters (from a refusal message, --help or a script header).
- Main path here; flags, exit codes and rare branches in the CLI's --help; mechanism and rationale in the script header; history and incident stories in the commit message.
- One home per fact: if it is already written elsewhere, point there instead of restating it.
- Tighten or replace an existing line rather than appending a paragraph; a correction replaces the claim it corrects.
- Before cutting a rule, check why it was added (git log -S '<phrase>')." \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
