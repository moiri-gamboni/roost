#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write): after an edit to an instruction file
# (a CLAUDE.md, AGENTS.md or SKILL.md, including the *-CLAUDE.md sources the
# server repo deploys) or a README.md, hand the model a short checklist as
# additionalContext. These files grow by accretion — each session that hits a
# problem appends a paragraph — and a README tends to restate its sibling
# CLAUDE.md; nothing pushed back at write time, and this is that push-back.
# Once per session per file, so a run of edits to one file gets it once.
# Always exits 0: PostToolUse cannot block, and this must never break a turn.
set -uo pipefail

[ -t 0 ] && exit 0
input=$(cat)
f=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null || true)
sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null || true)
base=${f##*/}
readme=0
case "$base" in
    SKILL.md) load="its description is in every session's skill list, loaded whether or not the skill is used, so keep it to when to use the skill in 1–3 sentences; the body loads whole each time the skill is invoked" ;;
    *CLAUDE.md|AGENTS.md)
        case "$f" in
            */roost/claude/CLAUDE.md|*/global-CLAUDE.md) load="the global file loads on every turn of every session and subagent, the most expensive text there is" ;;
            *) load="a repo's root file loads in every session launched there, a subdirectory's when a session reads files in that directory" ;;
        esac ;;
    README.md) readme=1 ;;
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

if [ "$readme" = 1 ]; then
    c="README edited ($f). A README is for humans: what the tool is, how to install and use it, and the concepts and reference a user needs. Sessions read the CLAUDE.md and skill beside it instead. Before finishing:
- Anything that restates the sibling CLAUDE.md, SKILL.md or --help gets one home: user-facing behaviour here, working on the code in CLAUDE.md, using the tool from a session in the skill. Point instead of repeating.
- No history, changelog, resolved follow-ups or incident stories in the body; those go in commit messages.
- Keep how-to steps free of explanation paragraphs, and reference free of instructions (the diataxis skill has the detail).
- Skills and code cite README sections by name: grep for a heading before renaming or cutting it."
else
    c="Instruction file edited ($f): $load. Before finishing, check the edit against this:
- Add only what a session would get wrong without it and would not learn when it matters (from a refusal message, --help or a script header).
- Main path here; flags, exit codes and rare branches in the CLI's --help; mechanism and rationale in the script header; history and incident stories in the commit message.
- One home per fact: if it is already written elsewhere (including the README beside it), point there instead of restating it.
- Tighten or replace an existing line rather than appending a paragraph; a correction replaces the claim it corrects.
- Before cutting a rule, check why it was added (git log -S '<phrase>')."
fi
jq -cn --arg c "$c" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
