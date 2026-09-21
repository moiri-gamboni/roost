#!/usr/bin/env bash
# SubagentStart hook: tell every subagent that it is one, and that its brief is its own to execute.
#
# Why: a subagent has no way to see its own position. Its prompt is a brief like any other
# message, its tool list is the parent's (Agent included), and the global CLAUDE.md it loads
# says "delegate down by default" — written for the session holding the work, but read by the
# subagent as applying to the one brief it holds. Asked "do you know if you're a subagent?",
# a depth-2 subagent that had just handed its brief to a single child answered "yes, I'm the
# top-level session". SubagentStart's additionalContext is injected into the subagent's
# conversation before its first model call (verified on 2.1.278 with a marker string), so this
# is where the fact lands. redelegation-guard.sh is the backstop for the case the sentence
# does not reach: it denies the hand-off itself.
#
# No depth here: the subagent's meta.json (which carries spawnDepth) is written only after this
# hook returns, so the type is the one fact available. Always exits 0.
set -uo pipefail

atype=$(jq -r '.agent_type // "unknown type"') || atype="unknown type"
[ -n "$atype" ] || atype="unknown type"   # empty stdin: jq prints nothing and exits 0
jq -nc --arg c "You are a subagent (${atype}), spawned by a session that is waiting for your report. The brief in your first message is yours to execute with your own tools: do the work, then report. Spawn subagents only to split that brief into independent legs that run in parallel (all in one message), or for a small part of it. Never hand the brief itself to a single child — that re-delegation costs a whole extra agent and delays the result while producing nothing. The global CLAUDE.md's 'delegate down by default' addresses the session that briefed you, not you." \
    '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $c}}'
exit 0
