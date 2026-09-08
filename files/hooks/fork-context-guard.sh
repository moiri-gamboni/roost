#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): turn a fork into a permission prompt once the session's
# context passes 500k tokens.
#
# Why: the global CLAUDE.md delegation rule forks first whenever the work needs what this
# session has built up, and stops forking past 500k tokens of context — a fork inherits the
# whole window and re-reads it every turn. A session cannot see its own context size without
# running a command, so the cap is enforced here instead of recalled: the hook reads the
# figure from the transcript's newest assistant row (input + cache_read + cache_creation is
# the request's context, the same number the status line shows) and it is per-session by
# construction, unlike the `session` overview's per-login cache.
#
# The decision is "ask", not "deny": the user sees the figure and can approve the fork anyway.
# In auto mode a hook's ask still forces the prompt; where nothing can prompt (`claude -p`, a
# background subagent with no surface) ask is a deny, which is the cap holding. The reason
# text reaches the user only, so the same figure goes to the model as additionalContext.
#
# Friction, not a boundary: any parse problem allows. Never names the way to switch it off.
set -uo pipefail

cap=500000

# One jq for both fields. `|| true` and not `2>/dev/null`: a malformed payload should still
# leave a visible parse error for whoever is debugging, it just must not take the turn down.
IFS=$'\t' read -r kind transcript < <(jq -r '[(.tool_input.subagent_type // ""), (.transcript_path // "")] | @tsv' || true)
[ "${kind:-}" = "fork" ] || exit 0
[ -n "${transcript:-}" ] && [ -r "$transcript" ] || exit 0

# Newest assistant row with a usage block, read from the end: `sed '$a\'` supplies the newline
# a torn last line (a write in flight) lacks — without it tac glues that line to the row
# before and both are lost — tac + grep -m stop early on a multi-MB transcript (0.3s on a
# 78 MB one), and `fromjson?` skips the torn line instead of aborting the whole read. The
# scan depth is a correctness bound, not just a speed one: a usage row behind that many
# usage-less assistant rows is invisible and the guard falls open. Real transcripts carry
# usage on every assistant row (0 of 16,137 sampled lacked it), so 40 is slack, and the
# test table pins the boundary.
# shellcheck disable=SC1003  # `$a\` is sed's append-nothing idiom, not an escaped quote
ctx=$(sed '$a\' "$transcript" | tac | grep -a -m 40 '"type":"assistant"' \
    | jq -rR 'fromjson? | select(.type == "assistant" and .message.usage) | .message.usage
              | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' \
    | head -n 1)
# A readable transcript with no usable row is the one allow worth a trace: it is what a
# transcript-format change would look like, and silence here is indistinguishable from
# "nobody is over the cap".
[[ ${ctx:-} =~ ^[0-9]+$ ]] || { logger -t roost/fork-context-guard "allowed a fork: no usable assistant usage row in $transcript"; exit 0; }
[ "$ctx" -gt "$cap" ] || exit 0

pretty=$(sed -E ':a;s/([0-9])([0-9]{3})($|,)/\1,\2\3/;ta' <<<"$ctx")
logger -t roost/fork-context-guard "asked before a fork at ${ctx} tokens of context"

jq -nc \
    --arg r "Fork context guard: this session's context is ${pretty} tokens, past the 500k fork cap. Approve to fork anyway — the fork inherits all of it and re-reads it every turn. Decline and Claude spawns a fresh subagent with a full briefing instead." \
    --arg c "Fork context guard: this session's context is ${pretty} tokens, past the 500k fork cap (global CLAUDE.md, Agents & Subagents), so the user was asked to approve this fork. If it was declined, spawn a fresh subagent instead, with a full briefing: the goal and why it matters, what is already known or ruled out, scope, and what to report." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r, additionalContext: $c}}'
exit 0
