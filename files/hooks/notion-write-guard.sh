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
# The deny message names the guard, why it exists, the sanctioned path and the honest limit —
# never the way to switch it off; that invites the blocked session to do so. It stays short: a
# session that hits this needs to know what to do next, not where the hook file lives.
#
# Matching is deliberately done on the RAW command string, with no heredoc or quote stripping.
# That inverts `no-truncation.sh`, which stripped both, and the inversion is the point: there,
# a `head` inside a quoted string was noise to be discarded; here, the URL being denied almost
# always sits inside quotes (`curl -X PATCH "https://api.notion.com/v1/pages/$id"`) and an
# inline `python3 - <<'PY'` heredoc is a real write vector rather than a false positive.
# Stripping either one would discard the true positives and keep the noise.
set -uo pipefail

# `|| true` and not `2>/dev/null`: a malformed payload should still leave a visible parse error
# for whoever is debugging, it just must not take the turn down with it.
cmd=$(jq -r '.tool_input.command // empty' || true)
[ -n "$cmd" ] || exit 0

# Not about Notion's REST API at all -> not ours. Keys on the host, so SDK calls
# (notion_client, the MCP tools) never reach this hook; those are covered elsewhere.
grep -qF 'api.notion.com' <<<"$cmd" || exit 0

# The sync tools own their writes: guarded, dry-runnable, and the sanctioned path.
# The apart-tools clone's two tool dirs — the clone ROOT alone is deliberately
# not enough, or any command merely mentioning the repo would pass. (The old
# in-workspace (tasks|notion)/_tools/ alternative was retired 2026-08-16 with
# the trees themselves.)
grep -qE 'apart-tools/(tasksync|notion-mirror)/' <<<"$cmd" && exit 0

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

# Three Notion endpoints read over POST: `/v1/search`, and the `/query` on a data source or a
# database. A paginated dump of the workspace is all POST and all read, so the verb alone cannot
# decide. Pass only when EVERY Notion path in the command is one of those — a command that also
# touches a write endpoint still denies, and a URL assembled from variables leaves no extractable
# path, so the deny stands.
notion_paths=$(grep -oE 'api\.notion\.com/v1/[A-Za-z0-9_./{}$%:-]*' <<<"$cmd")
[ -n "$notion_paths" ] && ! grep -qvE '/(query|search)$' <<<"$notion_paths" && exit 0

# Never log the command itself: these carry `Authorization: Bearer <integration token>`.
logger -t roost/notion-write-guard "denied an ad-hoc Notion write command"

jq -nc --arg r 'BLOCKED by the Notion write guard.

Why it exists: ad-hoc REST writes to the Apart workspace always need explicit user approval.
Sanctioned path if editing a task: tasksync Skill (e.g. tasks push)
Limit: this reads command strings, not a script'"'"'s internal calls. You may write a script,
explain what it does, then ask the user to run it for convenience.' \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
