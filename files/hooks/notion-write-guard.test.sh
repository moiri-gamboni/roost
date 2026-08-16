#!/usr/bin/env bash
# Matcher test for notion-write-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/notion-write-guard.test.sh
#
# Each case feeds a synthetic PreToolUse payload to the hook and asserts allow vs deny.
# "allow" means silence and exit 0; "deny" means a permissionDecision of deny on stdout.
set -uo pipefail

hook="$(dirname "${BASH_SOURCE[0]}")/notion-write-guard.sh"
pass=0
fail=0

check() {
    local expect="$1" label="$2" cmd="$3" out got
    out=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook")
    if grep -q '"permissionDecision":"deny"' <<<"$out"; then got=deny; else got=allow; fi
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'ok    %-5s %s\n' "$got" "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  want=%-5s got=%-5s %s\n' "$expect" "$got" "$label"
    fi
}

# --- must deny: ad-hoc writes ---
check deny 'curl -X PATCH' \
    'curl -X PATCH https://api.notion.com/v1/pages/abc -H "Authorization: Bearer x" -d @b.json'
check deny 'curl -X POST quoted url' \
    'curl -s -X POST "https://api.notion.com/v1/pages" -d @body.json'
check deny 'curl --request DELETE' \
    'curl --request DELETE https://api.notion.com/v1/blocks/abc123'
check deny 'curl -XPATCH (no space)' \
    'curl -XPATCH https://api.notion.com/v1/pages/abc'
check deny 'curl -X patch (lowercase)' \
    'curl -s -X patch https://api.notion.com/v1/pages/abc'
check deny 'python heredoc, requests.patch' \
    "$(printf 'python3 - <<%sPY%s\nimport requests\nrequests.patch("https://api.notion.com/v1/pages/x")\nPY' "'" "'")"
check deny 'python -c, requests.post' \
    'python3 -c '\''import requests; requests.post("https://api.notion.com/v1/pages", json=b)'\'''
check deny 'node fetch, method: POST' \
    'node -e "fetch(\"https://api.notion.com/v1/pages\", {method: \"POST\", body: b})"'
check deny 'method=PATCH form' \
    'python3 -c "requests.request(method=\"PATCH\", url=\"https://api.notion.com/v1/pages/x\")"'

# --- must allow: reads ---
check allow 'GET (no method flag)' \
    'curl -s -H "Authorization: Bearer $T" https://api.notion.com/v1/pages/abc'
check allow 'explicit -X GET' \
    'curl -s -X GET https://api.notion.com/v1/pages/abc'
check allow 'requests.get' \
    'python3 -c '\''import requests; requests.get("https://api.notion.com/v1/pages/x")'\'''

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
# host and a write verb they must now deny — the old allowlist alternative is gone.
check allow 'old tasks/_tools path, no host mentioned (host gate)' \
    'python3 tasks/_tools/push.py --slug 2026-08-05-foo --write'
check deny 'old tasks/_tools path no longer sanctions a write' \
    'python3 tasks/_tools/push.py --endpoint https://api.notion.com/v1/pages -X POST'

# --- degenerate input ---
check allow 'empty command' ''

# --- the false-positive boundary, pinned in both directions ---
# Grepping for a write call is common and passes, because the search pattern carries no `(`.
check allow 'grep for a write call by name' \
    'grep -rn "requests.patch.*api.notion.com" aws_infra/'
# It only trips when the pattern includes the open paren AND the host is in the same command.
# Contrived enough to accept: it costs one bounce, and the deny message says how to proceed.
check deny 'KNOWN FALSE POSITIVE: paren in the pattern, host in the same command' \
    'grep -rn "requests.post(" $(grep -rl api.notion.com .)'

# --- the apart-tools clone: its two tool dirs are sanctioned, the repo root is not ---
check allow 'push via the apart-tools clone CLI' \
    'apart-tools/tasksync/tasks push some-slug --apply # writes api.notion.com'
check allow 'mirror refresh from the apart-tools clone' \
    'apart-tools/notion-mirror/refresh.sh daily # api.notion.com'
check deny 'incidental mention of the clone root does not sanction a raw write' \
    'cd apart-tools && curl -X PATCH "https://api.notion.com/v1/pages/abc"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
