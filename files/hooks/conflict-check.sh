#!/bin/bash
# Check for Syncthing conflict files and notify via ntfy.
source "$(dirname "$0")/_hook-env.sh"

ROOST_DIR="$HOME/roost"
LAST_CHECK="$HOOK_RUNTIME_DIR/.last-conflict-check"
touch -a "$LAST_CHECK" 2>/dev/null

find "$ROOST_DIR" -name "*.sync-conflict-*" -newer "$LAST_CHECK" 2>/dev/null \
    | head -5 \
    | while read -r f; do
        ntfy_send -t "Sync conflict" "Conflict file: $f"
    done

touch "$LAST_CHECK"
