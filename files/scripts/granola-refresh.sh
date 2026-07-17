#!/usr/bin/env bash
# granola-refresh — keep a Granola notes mirror current, then optionally brief on what's new.
#   1. incremental summaries (public API key)   2. transcripts (OAuth MCP, missing only)
#   3. granola-digest, if installed — a personal Opus brief of the new/changed notes
# Both fetch steps are idempotent and only touch new/changed notes, so a daily cadence
# stays well under the MCP transcript rate limit. Also ntfys (3-day cooldown) if the
# MCP OAuth refresh token expires and needs a one-time re-auth.
#
#   granola-refresh <mirror-dir>        (or set GRANOLA_MIRROR)
set -uo pipefail
COMMIT=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --commit) COMMIT=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
DIR=""
[ ${#ARGS[@]} -gt 0 ] && DIR="${ARGS[0]}"
DIR="${DIR:-${GRANOLA_MIRROR:-}}"
[ -n "$DIR" ] || { echo "usage: granola-refresh [--commit] <mirror-dir>   (or set GRANOLA_MIRROR)" >&2; exit 2; }
STATE="$HOME/.local/state"; mkdir -p "$STATE"
CHANGED="$STATE/granola-changed.txt"

ntfy() {   # ntfy PRIORITY TITLE MESSAGE
  local tok=""
  [ -f "$HOME/services/.ntfy-token" ] && tok=$(cat "$HOME/services/.ntfy-token")
  curl -sS -m 10 -H "Priority: $1" -H "Title: $2" ${tok:+-H "Authorization: Bearer $tok"} \
    -d "$3" "http://localhost:2586/claude-$(whoami)" >/dev/null || true
}

# Commit just the mirror + today's brief. Uses a pathspec commit, so anything else
# already staged in that repo is left untouched.
commit_mirror() {
  local repo updates
  # rev-parse is expected to fail when the mirror isn't in a repo — a supported setup
  if ! repo=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null); then
    echo "  $DIR is not inside a git repo — skipping commit"
    return 0
  fi
  updates="$(dirname "$DIR")/updates/granola"
  local paths=("$DIR")
  [ -d "$updates" ] && paths+=("$updates")
  if [ -z "$(git -C "$repo" status --porcelain -- "${paths[@]}")" ]; then
    echo "  nothing to commit"
    return 0
  fi
  git -C "$repo" add -- "${paths[@]}"
  if git -C "$repo" commit -q -m "granola: mirror refresh $(date +%F)" -- "${paths[@]}"; then
    echo "  $(git -C "$repo" log --oneline -1)"
  else
    echo "  commit failed"
  fi
}

echo "[$(date -Is)] granola-refresh: summaries -> $DIR"
granola sync "$DIR" --changed-file "$CHANGED"

echo "[$(date -Is)] granola-refresh: transcripts"
granola-transcripts sync "$DIR"; rc=$?
if [ "$rc" -eq 0 ]; then
  rm -f "$STATE/granola-oauth-alerted"
elif [ "$rc" -eq 3 ]; then
  # MCP OAuth refresh token expired -> ntfy, at most once every 3 days
  if [ ! -f "$STATE/granola-oauth-alerted" ] || [ -z "$(find "$STATE/granola-oauth-alerted" -mtime -3)" ]; then
    ntfy urgent "Granola MCP re-auth needed" "OAuth token expired — transcripts paused (summaries still updating). Re-run the browser approval to restore transcripts."
    touch "$STATE/granola-oauth-alerted"
  fi
  echo "[$(date -Is)]   MCP token expired — re-auth needed (ntfy sent)."
else
  echo "[$(date -Is)]   transcript step failed (rc=$rc)."
fi

# Optional personal digest (deployed from the private repo); skipped if not installed.
if command -v granola-digest >/dev/null; then
  echo "[$(date -Is)] granola-refresh: digest"
  granola-digest "$DIR" "$CHANGED" || echo "[$(date -Is)]   digest step failed."
fi

if [ "$COMMIT" -eq 1 ]; then
  echo "[$(date -Is)] granola-refresh: commit"
  commit_mirror
fi

echo "[$(date -Is)] granola-refresh: done"
