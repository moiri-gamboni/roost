#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): ask before an ad-hoc REST write to the Notion API.
#
# Why: writes to the Apart | Seldon workspace are supposed to go through the tasks sync tool,
# which holds a per-field clobber guard and a dry-run. A hand-rolled `curl -X PATCH` has
# neither, and Moïri owns whatever the integration writes — including the deletions. The MCP
# write tools are already gated by `permissions.ask` in settings.json; the shell was the hole.
#
# This is friction, not a boundary, and nothing depends on it holding. A script on disk making
# the same call internally passes cleanly, which is exactly how `tasks push` gets through.
#
# The decision is "ask", not "deny": the user sees what the command is about to write and can
# approve it as is. In auto mode a hook's ask still forces the prompt; where nothing can prompt
# (`claude -p`, a background subagent with no surface) ask is a deny. The prompt text reaches
# the user only, so the sanctioned path goes to the model as additionalContext — short, naming
# what to do next and the honest limit, never the way to switch the guard off.
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
logger -t roost/notion-write-guard "asked before an ad-hoc Notion write command"

jq -nc \
    --arg r 'Notion write guard: this command sends a write (POST/PATCH/PUT/DELETE) to api.notion.com outside tasksync, with none of its clobber guard or dry-run. Approve to run it as is; decline and Claude routes the change through tasksync or the Notion MCP write tools.' \
    --arg c 'Notion write guard: this command is an ad-hoc REST write to api.notion.com, so the user was asked to approve it. If it was declined: edit a task through the tasksync skill (tasks push); for a small fix use the Notion MCP write tools, which prompt the user themselves; for a large change write a script, explain what it does, and ask the user to run it. The guard reads command strings only, so a script'"'"'s internal calls pass.' \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r, additionalContext: $c}}'
exit 0
