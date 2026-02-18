#!/bin/bash
source "$(dirname "$0")/_hook-env.sh"

MESSAGE=$(hook_json '.message // "Input needed"')
TITLE=$(hook_json '.title')
TYPE=$(hook_json '.notification_type')
PROJECT=$(basename "$PWD")

rate_limit_ok || exit 0

PRIORITY="default"
[ "$TYPE" = "permission_prompt" ] && PRIORITY="urgent"

ntfy_send \
    -t "${TITLE:-$PROJECT}" \
    -p "$PRIORITY" \
    "$MESSAGE"
