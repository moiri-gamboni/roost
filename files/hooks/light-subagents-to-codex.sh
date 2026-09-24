#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): refuse a Sonnet- or Haiku-model subagent spawn and hand the
# session the antiphon command that runs the same work as a Codex thread (GPT-6-Luna, max effort).
#
# Why: on this box the light tier of delegation is Codex through antiphon, not a light Claude
# model; Claude subagents run on Opus (global CLAUDE.md, Agents & Subagents). Plugins such as
# praxis pin `model: sonnet` in their own agent definitions and cannot know that, so the rule is
# enforced here rather than in each plugin.
#
# The model is the call's `model`, else the `model:` line of the agent definition the
# `subagent_type` names: `<plugin>:<agent>` resolves through installed_plugins.json to the
# plugin's `agents/<agent>.md`; a bare name to `$CLAUDE_CONFIG_DIR/agents/` or the project's
# `.claude/agents/`. Built-in agent types have no file and pass. Forks pass (they run this
# session's model). When the definition file is found, the deny names it so antiphon can carry
# its instructions (`--instructions`).
#
# The decision is "deny": the reason is what the model reads. Friction, not a boundary: any
# parse problem, an unresolvable type, or no `antiphon` on PATH allows. The reason offers an Opus
# respawn for when Codex is unavailable, and never names a way to switch the hook off.
set -uo pipefail

command -v antiphon >/dev/null || exit 0
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

# \x1f, not a tab: read merges runs of whitespace separators, so an empty model would shift cwd into it
IFS=$'\x1f' read -r kind model cwd < <(jq -r '[(.tool_input.subagent_type // ""), (.tool_input.model // ""), (.cwd // "")] | join("\u001f")' || true)
[ "${kind:-}" = "fork" ] && exit 0

defn=""
case "${kind:-}" in
    *:*)
        plugin=${kind%%:*}; agent=${kind#*:}
        root=$(jq -r --arg p "$plugin@" '.plugins | to_entries[] | select(.key | startswith($p)) | .value[0].installPath // empty' \
            "$config/plugins/installed_plugins.json" || true)
        root=${root%%$'\n'*}
        [ -n "$root" ] && [ -f "$root/agents/$agent.md" ] && defn="$root/agents/$agent.md"
        ;;
    ?*)
        for f in "$config/agents/$kind.md" "${cwd:-.}/.claude/agents/$kind.md"; do
            [ -f "$f" ] && { defn=$f; break; }
        done
        ;;
esac

if [ -z "${model:-}" ] && [ -n "$defn" ]; then
    # the first `model:` line inside the leading frontmatter block
    model=$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} /^model:/ {sub(/^model:[ \t]*/, ""); gsub(/["\047]/, ""); print; exit}' "$defn")
fi
shopt -s nocasematch
[[ ${model:-} =~ (^|[-_])(sonnet|haiku)($|[-_[]) ]] || exit 0
shopt -u nocasematch

name="codex-${kind##*:}"; name=${name:0:40}-$RANDOM
instr=""; [ -n "$defn" ] && instr=" --instructions $defn"
logger -t roost/light-subagents-to-codex "refused a ${model} spawn (${kind:-general-purpose}); routed to antiphon"

jq -nc \
    --arg r "This box runs Sonnet- and Haiku-class subagent work on Codex (GPT-6-Luna at max effort) through antiphon, not on a light Claude model. Run this ${kind:-subagent} task as a Codex thread instead, in a background Bash (run_in_background), with the prompt you were giving this Agent call after the --:
antiphon start -C ${cwd:-.} -n ${name} -m gpt-6-luna --effort max --read-only${instr} --no-report --wait --timeout 3600 -- \"<prompt>\"
Drop --read-only when the task edits files (add --worktree to keep its changes separable). The Bash output is the thread's final answer; parallel legs are parallel background Bash calls, each with its own -n. If antiphon is unavailable (\`antiphon ping\` fails, or the Codex plan's limit is spent), spawn the same agent again with model: \"opus\"." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
