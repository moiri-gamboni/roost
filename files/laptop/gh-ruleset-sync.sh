#!/bin/bash
# Sync the "Protect main" ruleset across all repos owned by the authenticated gh user.
# Runs on the LAPTOP via systemd timer (gh-ruleset-sync.timer).
set -euo pipefail

RULESET_FILE="${ROOST_RULESET_FILE:-/etc/roost/rulesets/protect-main.json}"
NTFY_URL="${ROOST_NTFY_URL:-}"
DRY_RUN=0
VERBOSE=0

LOG_TAG="roost/gh-ruleset-sync"
log()  { logger -t "$LOG_TAG" "$*"; echo "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "WARNING: $*" >&2; }
err()  { logger -t "$LOG_TAG" -p user.err "$*"; echo "ERROR: $*" >&2; }

alert() {
    [ -z "$NTFY_URL" ] && return 0
    # ntfy server runs auth-default-access=deny-all; without the token,
    # posts get 403'd and curl swallows it via `|| true`. install-gh-
    # ruleset-sync.sh fetches the token from server's ~/services/.ntfy-
    # token and writes it to /etc/gh-ruleset-sync.env (EnvironmentFile=).
    local -a auth=()
    [ -n "${ROOST_NTFY_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $ROOST_NTFY_TOKEN")
    curl -sS -o /dev/null --max-time 10 \
        "${auth[@]}" \
        -H "Title: gh-ruleset-sync" \
        -H "Tags: shield" \
        -d "$1" "$NTFY_URL" || true
}

usage() {
    cat <<'EOF'
Usage: gh-ruleset-sync [--help] [--dry-run] [--verbose]

Syncs the "Protect main" ruleset across all repos owned by the authenticated gh user.
Skips forks and archived repos. Idempotent.

Environment:
  ROOST_RULESET_FILE  Path to ruleset JSON (default: /etc/roost/rulesets/protect-main.json)
  ROOST_NTFY_URL      ntfy endpoint for failure alerts (default: unset, no alerts)
  ROOST_NTFY_TOKEN    Bearer token for ntfy auth (required; server denies anonymous posts)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)    usage; exit 0 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        *)         err "Unknown arg: $1"; usage; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { warn "gh not found, skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { err "jq not found"; alert "jq missing on laptop"; exit 1; }
gh auth token >/dev/null 2>&1 || { warn "gh not authenticated, skipping"; exit 0; }
curl -fsS --max-time 5 https://api.github.com/zen >/dev/null 2>&1 \
    || { warn "api.github.com unreachable, skipping"; exit 0; }
[ -r "$RULESET_FILE" ] || { err "ruleset file missing: $RULESET_FILE"; alert "ruleset file missing: $RULESET_FILE"; exit 1; }

RULESET_NAME=$(jq -r .name "$RULESET_FILE")
GH_USER=$(gh api user -q .login)

CREATED=0
EXISTED=0
FAILED=0

while IFS= read -r repo; do
    [ -z "$repo" ] && continue

    EXISTS=""
    CHECK_OK=0
    for attempt in 1 2; do
        if RESP=$(gh api "repos/$repo/rulesets?includes_parents=false" 2>&1); then
            EXISTS=$(echo "$RESP" | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id' || true)
            CHECK_OK=1
            break
        fi
        [ $attempt -eq 1 ] && sleep 2
    done

    if [ $CHECK_OK -eq 0 ]; then
        FAILED=$((FAILED + 1))
        warn "$repo: ruleset check failed after retry"
        continue
    fi

    if [ -n "$EXISTS" ]; then
        EXISTED=$((EXISTED + 1))
        [ $VERBOSE -eq 1 ] && log "$repo: already protected (ruleset $EXISTS)"
        continue
    fi

    if [ $DRY_RUN -eq 1 ]; then
        log "$repo: would create ruleset (dry-run)"
        CREATED=$((CREATED + 1))
        continue
    fi

    POSTED=0
    for attempt in 1 2; do
        if gh api "repos/$repo/rulesets" -X POST --input "$RULESET_FILE" >/dev/null 2>&1; then
            CREATED=$((CREATED + 1))
            [ $VERBOSE -eq 1 ] && log "$repo: created"
            POSTED=1
            break
        fi
        [ $attempt -eq 1 ] && sleep 2
    done
    if [ $POSTED -eq 0 ]; then
        FAILED=$((FAILED + 1))
        warn "$repo: POST failed after retry"
    fi
done < <(gh repo list --source --no-archived --json nameWithOwner,owner -q \
    ".[] | select(.owner.login == \"$GH_USER\") | .nameWithOwner" --limit 200)

SUMMARY="Ruleset sync: $CREATED created, $EXISTED existed, $FAILED failed"
if [ $FAILED -gt 0 ]; then
    err "$SUMMARY"
    alert "$SUMMARY"
else
    log "$SUMMARY"
fi

exit 0
