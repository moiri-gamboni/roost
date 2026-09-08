#!/usr/bin/env bash
# Matcher test for notion-write-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/notion-write-guard.test.sh
#
# Each case feeds a synthetic PreToolUse payload to the hook and asserts allow vs ask.
# "allow" means silence and exit 0; "ask" means a permissionDecision of ask on stdout.
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/notion-write-guard.sh"
pass=0
fail=0

check() {
    local expect="$1" label="$2" cmd="$3" out got
    out=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook")
    if grep -q '"permissionDecision":"ask"' <<<"$out"; then got=ask; else got=allow; fi
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'ok    %-5s %s\n' "$got" "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  want=%-5s got=%-5s %s\n' "$expect" "$got" "$label"
    fi
}

# --- must ask: ad-hoc writes ---
check ask  'curl -X PATCH' \
    'curl -X PATCH https://api.notion.com/v1/pages/abc -H "Authorization: Bearer x" -d @b.json'
check ask  'curl -X POST quoted url' \
    'curl -s -X POST "https://api.notion.com/v1/pages" -d @body.json'
check ask  'curl --request DELETE' \
    'curl --request DELETE https://api.notion.com/v1/blocks/abc123'
check ask  'curl -XPATCH (no space)' \
    'curl -XPATCH https://api.notion.com/v1/pages/abc'
check ask  'curl -X patch (lowercase)' \
    'curl -s -X patch https://api.notion.com/v1/pages/abc'
check ask  'python heredoc, requests.patch' \
    "$(printf 'python3 - <<%sPY%s\nimport requests\nrequests.patch("https://api.notion.com/v1/pages/x")\nPY' "'" "'")"
check ask  'python -c, requests.post' \
    'python3 -c '\''import requests; requests.post("https://api.notion.com/v1/pages", json=b)'\'''
check ask  'node fetch, method: POST' \
    'node -e "fetch(\"https://api.notion.com/v1/pages\", {method: \"POST\", body: b})"'
check ask  'method=PATCH form' \
    'python3 -c "requests.request(method=\"PATCH\", url=\"https://api.notion.com/v1/pages/x\")"'

# --- must allow: reads ---
check allow 'GET (no method flag)' \
    'curl -s -H "Authorization: Bearer $T" https://api.notion.com/v1/pages/abc'
check allow 'explicit -X GET' \
    'curl -s -X GET https://api.notion.com/v1/pages/abc'
check allow 'requests.get' \
    'python3 -c '\''import requests; requests.get("https://api.notion.com/v1/pages/x")'\'''

# --- must allow: the POST-shaped reads (search, and query on a data source or database) ---
check allow 'curl -X POST /v1/search' \
    'curl -s -X POST https://api.notion.com/v1/search -d "{}"'
check allow 'requests.post on a data source query' \
    'python3 -c '\''requests.post("https://api.notion.com/v1/data_sources/9dd10ae5/query", json=b)'\'''
check allow 'legacy database query, url in a variable path' \
    'curl -s -X POST "https://api.notion.com/v1/databases/$db/query" -d @body.json'
check allow 'f-string path with a placeholder segment' \
    'python3 dump.py # urllib.request.Request(f"https://api.notion.com/v1/data_sources/{ds}/query", method="POST")'
check ask  'a query alongside a page write still asks' \
    'curl -X POST https://api.notion.com/v1/data_sources/x/query && curl -X PATCH https://api.notion.com/v1/pages/y'
check ask  'host present but no extractable /v1/ path' \
    'curl -X POST "$NOTION_BASE/pages" -H "Host: api.notion.com"'

# --- the verb is attributed per line: a GET beside a POST-shaped read passes ---
check allow 'httpx.get schema + httpx.post query, one heredoc' \
    "$(printf 'uv run python - <<%sEOF%s\nimport httpx\ndb = httpx.get(f"https://api.notion.com/v1/databases/{ROSTER}", headers=H).json()\nr = httpx.post(f"https://api.notion.com/v1/databases/{ROSTER}/query", headers=H, json=body)\nEOF' "'" "'")"
check allow 'bare curl GET, then curl -X POST /query' \
    'curl -s -H "Authorization: Bearer $T" https://api.notion.com/v1/databases/$db | jq .properties; curl -s -X POST "https://api.notion.com/v1/databases/$db/query" -d "{}"'
check allow 'explicit -X GET beside a /v1/search' \
    "$(printf 'curl -X GET https://api.notion.com/v1/pages/abc\ncurl -X POST https://api.notion.com/v1/search -d "{}"')"
check allow 'requests.get page + requests.post search' \
    "$(printf 'python3 - <<%sPY%s\nrequests.get("https://api.notion.com/v1/pages/x")\nrequests.post("https://api.notion.com/v1/search", json={})\nPY' "'" "'")"
check allow 'a /query call split across lines, nothing else' \
    "$(printf 'python3 - <<%sPY%s\nr = httpx.post(\n    "https://api.notion.com/v1/databases/x/query", json=q)\nPY' "'" "'")"

# --- a write line that cannot be paired with its URL falls back to every path in the command ---
check ask  'query line, then a patch whose URL sits on the next line' \
    "$(printf 'python3 - <<%sPY%s\nhttpx.post("https://api.notion.com/v1/databases/x/query", json=q)\nhttpx.patch(\n    f"https://api.notion.com/v1/pages/{pid}", json=p)\nPY' "'" "'")"
check ask  'query line, then curl -X PATCH with the URL on a continuation line' \
    "$(printf 'curl -X POST https://api.notion.com/v1/data_sources/x/query -d "{}"\ncurl -X PATCH \\\n  "https://api.notion.com/v1/pages/$id" -d @b.json')"
check ask  'GET and PATCH on the same line' \
    'curl -s https://api.notion.com/v1/databases/x && curl -X PATCH https://api.notion.com/v1/pages/y -d @b.json'
check ask  'URL literal on the get line, reused by a patch through a variable' \
    "$(printf 'python3 - <<%sPY%s\nrows = httpx.post("https://api.notion.com/v1/databases/x/query", json=q)\ncur = httpx.get(url := f"https://api.notion.com/v1/pages/{pid}")\nhttpx.patch(url, json=p)\nPY' "'" "'")"
check ask  'a literal query and a variable-URL patch on one line' \
    'python3 -c '\''requests.post("https://api.notion.com/v1/databases/x/query", json=q); requests.patch(url, json=p)'\'''
check allow 'a /query call split across lines beside a GET' \
    "$(printf 'python3 - <<%sPY%s\ndb = httpx.get("https://api.notion.com/v1/databases/x")\nr = httpx.post(\n    "https://api.notion.com/v1/databases/x/query", json=q)\nPY' "'" "'")"
check allow 'URL assigned to a variable on the line before its post' \
    "$(printf 'python3 - <<%sPY%s\nurl = f"https://api.notion.com/v1/databases/{db}/query"\nr = httpx.post(url, json=q)\nPY' "'" "'")"
check ask  'two URL variables, one a page, then a patch through one of them' \
    "$(printf 'python3 - <<%sPY%s\np_url = f"https://api.notion.com/v1/pages/{pid}"\nq_url = "https://api.notion.com/v1/databases/x/query"\nhttpx.patch(p_url, json=p)\nPY' "'" "'")"
check ask  'two calls in one segment sharing one literal' \
    'python3 -c '\''x = [requests.post("https://api.notion.com/v1/databases/x/query"), requests.patch(url)]'\'''
# The URL is gathered from the neighbouring lines only up to the next HTTP call, so an intervening
# `.get(` cuts a variable URL off from the call that uses it. One bounce.
check ask  'KNOWN FALSE POSITIVE: a variable /query URL behind an intervening .get( call' \
    "$(printf 'python3 - <<%sPY%s\nurl = "https://api.notion.com/v1/databases/x/query"\nk = cfg.get("k")\nr = httpx.post(url, json=q)\nPY' "'" "'")"

# --- must allow: false-positive candidates ---
check allow 'filename containing the host' \
    'cat /tmp/api.notion.com.log'
check allow 'grep for the host string' \
    'grep -rn "api.notion.com" notion/_tools/'
check allow 'heredoc writing docs that mention the host' \
    "$(printf 'cat > doc.md <<%sMD%s\nWe call api.notion.com to read rows.\nMD' "'" "'")"
check allow 'write verb but different host' \
    'curl -X POST https://example.com/api/v1/thing'
check allow 'queue.put is not an HTTP put' \
    'python3 -c "q.put(1)"  # see api.notion.com/v1/pages for the shape'

# --- the retired in-workspace tool paths (trees deleted 2026-08-16) ---
# Without the host in the command the host gate passes these anyway; WITH the
# host and a write verb they must now ask — the old allowlist alternative is gone.
check allow 'old tasks/_tools path, no host mentioned (host gate)' \
    'python3 tasks/_tools/push.py --slug 2026-08-05-foo --write'
check ask  'old tasks/_tools path no longer sanctions a write' \
    'python3 tasks/_tools/push.py --endpoint https://api.notion.com/v1/pages -X POST'

# --- degenerate input ---
check allow 'empty command' ''

# --- the false-positive boundary, pinned in both directions ---
# Grepping for a write call is common and passes, because the search pattern carries no `(`.
check allow 'grep for a write call by name' \
    'grep -rn "requests.patch.*api.notion.com" aws_infra/'
# It only trips when the pattern includes the open paren AND the host is in the same command.
# Contrived enough to accept: it costs one bounce, and the deny message says how to proceed.
check ask  'KNOWN FALSE POSITIVE: paren in the pattern, host in the same command' \
    'grep -rn "requests.post(" $(grep -rl api.notion.com .)'

# --- the apart-tools clone: its two tool dirs are sanctioned, the repo root is not ---
check allow 'push via the apart-tools clone CLI' \
    'apart-tools/tasksync/tasks push some-slug --apply # writes api.notion.com'
check allow 'mirror refresh from the apart-tools clone' \
    'apart-tools/notion-mirror/refresh.sh daily # api.notion.com'
check ask  'incidental mention of the clone root does not sanction a raw write' \
    'cd apart-tools && curl -X PATCH "https://api.notion.com/v1/pages/abc"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
