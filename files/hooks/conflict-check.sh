#!/bin/bash
# Check for Syncthing conflict files and notify via ntfy.
source "$(dirname "$0")/_hook-env.sh"

ROOST_DIR="$HOME/${ROOST_DIR_NAME:-roost}"
LAST_CHECK="$HOOK_RUNTIME_DIR/.last-conflict-check"
touch -a "$LAST_CHECK" 2>/dev/null

CONFLICTS=$(find "$ROOST_DIR" -name "*.sync-conflict-*" -newer "$LAST_CHECK" 2>/dev/null | head -5)

if [ -n "$CONFLICTS" ]; then
    COUNT=$(echo "$CONFLICTS" | wc -l)
    logger -t "$_HOOK_TAG" "Found $COUNT new conflict(s)"
    echo "$CONFLICTS" | while read -r f; do
        logger -t "$_HOOK_TAG" "Conflict: $f"
        ntfy_send -t "Sync conflict" "Conflict file: $f"
    done
else
    logger -t "$_HOOK_TAG" "No new conflicts"
fi

touch "$LAST_CHECK"
