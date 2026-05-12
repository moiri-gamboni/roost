#!/bin/bash
# Resolve GH_TOKEN per-session from the cwd's git remote owner.
# Writes `export GH_TOKEN=<value>` to $CLAUDE_ENV_FILE; Claude Code sources it
# before the session sees its env. Silently exits if no remote, no token,
# or GH_TOKEN already set in the inherited environment.
source "$(dirname "$0")/_hook-env.sh"

# Respect explicit overrides (e.g. GH_TOKEN=$OTHER agent ~/dir)
[ -n "${GH_TOKEN:-}" ] && exit 0

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

TOKEN_DIR="$HOME/.config/git/tokens"
[ -d "$TOKEN_DIR" ] || exit 0

# Session cwd; SessionStart hook receives it via JSON input or $PWD
CWD=$(hook_json '.cwd')
[ -z "$CWD" ] && CWD="$PWD"

owner=""
remote_url=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
if [ -n "$remote_url" ]; then
    owner=$(echo "$remote_url" | sed -n 's|.*github\.com[:/]\([^/]*\)/.*|\1|p' | tr '[:upper:]' '[:lower:]')
fi

token_file=""
if [ -n "$owner" ] && [ -f "$TOKEN_DIR/$owner" ]; then
    token_file="$TOKEN_DIR/$owner"
else
    # Personal fallback: first non-dotfile token (matches old _resolve_gh_token behavior)
    token_file=$(find "$TOKEN_DIR" -maxdepth 1 -type f -not -name '.*' | sort | head -1)
fi

[ -n "$token_file" ] && [ -f "$token_file" ] || exit 0
token=$(cat "$token_file")
[ -n "$token" ] || exit 0

printf 'export GH_TOKEN=%q\n' "$token" >> "$CLAUDE_ENV_FILE"
