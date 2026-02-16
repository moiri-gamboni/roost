#!/bin/bash
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
rm -f "$CLAUDE_CONFIG_DIR/locks/${SESSION_ID}.lock"
