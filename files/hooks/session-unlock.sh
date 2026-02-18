#!/bin/bash
source "$(dirname "$0")/_hook-env.sh"

SESSION_ID=$(hook_json '.session_id')
[ -z "$SESSION_ID" ] && exit 0
rm -f "$CLAUDE_CONFIG_DIR/locks/${SESSION_ID}.lock"
