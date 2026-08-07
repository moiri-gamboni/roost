#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): deny ad-hoc REST writes to the Notion API.
#
# Why: writes to the Apart | Seldon workspace are supposed to go through the tasks sync tool,
# which holds a per-field clobber guard and a dry-run. A hand-rolled `curl -X PATCH` has
# neither, and Moïri owns whatever the integration writes — including the deletions. The MCP
# write tools are already gated by `permissions.ask` in settings.json; the shell was the hole.
#
# This is friction, not a boundary, and nothing depends on it holding. A script on disk making
# the same call internally passes cleanly, which is exactly how `tasks push` gets through.
#
# The deny message deliberately names this file, the wiring, the sanctioned path and the way to
# switch it off. Its predecessor (`no-truncation.sh`, 53b2f9b) was reverted by its own author a
# day later — "someone added a hook, can you remove it" — because the deny message identified
# neither its origin nor its purpose, so the fastest read was "unexplained obstacle".
#
# Matching is deliberately done on the RAW command string, with no heredoc or quote stripping.
# That inverts `no-truncation.sh`, which stripped both, and the inversion is the point: there,
# a `head` inside a quoted string was noise to be discarded; here, the URL being denied almost
# always sits inside quotes (`curl -X PATCH "https://api.notion.com/v1/pages/$id"`) and an
# inline `python3 - <<'PY'` heredoc is a real write vector rather than a false positive.
# Stripping either one would discard the true positives and keep the noise.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# Not about Notion's REST API at all -> not ours. Keys on the host, so SDK calls
# (notion_client, the MCP tools) never reach this hook; those are covered elsewhere.
grep -qF 'api.notion.com' <<<"$cmd" || exit 0

# The sync tools own their writes: guarded, dry-runnable, and the sanctioned path.
grep -qE '(tasks|notion)/_tools/' <<<"$cmd" && exit 0

# Whatever may sit between a method keyword and its verb: spaces, `=`, and quotes — including
# backslash-escaped ones, since `node -e "…{method: \"POST\"}"` and `python3 -c "…method=\"PATCH\""`
# are how these get written at a shell prompt. Both shapes passed the guard until this class
# grew the backslash.
sep='[[:space:]="'"'"'\\]*'

# Write intent: a curl method flag, an explicit method= / method: field, or a mutating call on
# an HTTP client. `put` is only matched behind a named client, so `queue.put(` stays innocent.
write_intent="(-X|--request)${sep}(POST|PATCH|PUT|DELETE)"
write_intent+="|method[[:space:]]*[=:]${sep}(POST|PATCH|PUT|DELETE)"
write_intent+='|(requests|httpx|session|client|http)\.(post|patch|put|delete)[[:space:]]*\('
write_intent+='|\.(post|patch|delete)[[:space:]]*\('
grep -qiE "$write_intent" <<<"$cmd" || exit 0

# Never log the command itself: these carry `Authorization: Bearer <integration token>`.
logger -t roost/notion-write-guard "denied an ad-hoc Notion write command"

jq -nc --arg r 'BLOCKED by the Notion write guard — a roost PreToolUse hook.

What it is: ~/roost/code/server/files/hooks/notion-write-guard.sh, wired into the PreToolUse
block of ~/roost/code/server/files/settings.json (deployed to ~/roost/claude/hooks/).
Why it exists: ad-hoc REST writes to the Apart workspace bypass the sync tool'"'"'s per-field
clobber guard and its dry-run, and Moïri owns whatever his integration writes there.
Sanctioned path: tasks push <slug>   (dry-run by default)
Deliberately disable: remove the PreToolUse entry from files/settings.json, then
roost-apply push files/settings.json.
Honest limit: this reads command strings, not a script'"'"'s internal calls — which is exactly how
tasks push passes. It is friction, not a boundary.' \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
