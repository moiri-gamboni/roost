#!/bin/bash
source "$(dirname "$0")/_hook-env.sh"

SESSION_ID=$(hook_json '.session_id')
[ -z "$SESSION_ID" ] && exit 0
rm -f "$CLAUDE_CONFIG_DIR/locks/${SESSION_ID}.lock"

# --- Auto-naming (background) ---
# Runs in background because claude -p may exceed the 5-second SessionEnd timeout.
_HOOK_TAG="roost/session-unlock"

ENCODED_CWD=$(echo "$PWD" | tr '/' '-')
JSONL_FILE="$CLAUDE_CONFIG_DIR/projects/$ENCODED_CWD/$SESSION_ID.jsonl"

# Only proceed if the JSONL exists and has no custom title already
if [ -f "$JSONL_FILE" ] && ! grep -q '"type":"custom-title"' "$JSONL_FILE"; then
    (
        nohup bash -c '
            JSONL_FILE="$1"
            SESSION_ID="$2"
            TAG="$3"

            CONTENT=$(jq -r '\''
                select(.type == "user" or .type == "assistant") |
                .message.content |
                if type == "string" then .
                elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n")
                else empty
                end
            '\'' "$JSONL_FILE" | head -c 10000)

            if [ -z "$CONTENT" ]; then
                logger -t "$TAG" "No conversation content found in $JSONL_FILE, skipping auto-name"
                exit 0
            fi

            NAME=$(echo "$CONTENT" | claude -p --model sonnet \
                "Generate a 2-4 word kebab-case name summarizing this coding session. Output ONLY the name, nothing else. Example: fix-auth-redirect")

            if [ -z "$NAME" ]; then
                logger -t "$TAG" "claude -p returned empty name for session $SESSION_ID"
                exit 0
            fi

            # Sanitize: keep only lowercase alphanumeric and hyphens
            NAME=$(echo "$NAME" | tr "[:upper:]" "[:lower:]" | tr -cd "a-z0-9-" | head -c 60)

            if [ -z "$NAME" ]; then
                logger -t "$TAG" "Sanitized name is empty for session $SESSION_ID"
                exit 0
            fi

            jq -n --arg t "$NAME" --arg s "$SESSION_ID" \
                '{type:"custom-title",customTitle:$t,sessionId:$s}' >> "$JSONL_FILE"

            logger -t "$TAG" "Auto-named session $SESSION_ID: $NAME"
        ' _ "$JSONL_FILE" "$SESSION_ID" "$_HOOK_TAG" </dev/null >/dev/null 2>&1 &
    )
fi
