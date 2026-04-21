#!/bin/bash
# Assemble /etc/cloudflared/config.yml from the base tunnel header and
# per-app ingress fragments in ~/roost/cloudflared/apps/*.yml.
# Called by roost-apply.sh --cloudflare; can also be run standalone.
set -euo pipefail
source "$(dirname "$0")/_hook-env.sh"

CONFIG="/etc/cloudflared/config.yml"
# Derive APPS_DIR from the script's own path (/.../$ROOST_DIR_NAME/claude/hooks/
# -> /.../$ROOST_DIR_NAME/cloudflared/apps) rather than $HOME, which is /root
# when roost-net invokes this via `sudo cloudflare-assemble.sh`.
_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
_ROOST_DIR="$(cd "$_SCRIPT_DIR/../.." && pwd)"
APPS_DIR="$_ROOST_DIR/cloudflared/apps"

if [ ! -f "$CONFIG" ]; then
    logger -t "$_HOOK_TAG" "No existing $CONFIG, nothing to assemble"
    exit 0
fi

# Extract tunnel header (everything before the ingress: block)
TUNNEL_ID=$(grep -m1 '^tunnel:' "$CONFIG" | awk '{print $2}')
CREDS_FILE=$(grep -m1 '^credentials-file:' "$CONFIG" | awk '{print $2}')

if [ -z "$TUNNEL_ID" ] || [ -z "$CREDS_FILE" ]; then
    logger -t "$_HOOK_TAG" "Could not parse tunnel ID or credentials-file from $CONFIG"
    exit 1
fi

# Build new config
ASSEMBLED=$(mktemp)
trap 'rm -f "$ASSEMBLED"' EXIT

cat > "$ASSEMBLED" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDS_FILE}

ingress:
EOF

# Insert app fragments. Each fragment should be pre-indented for the ingress block:
#   - hostname: app.example.com
#     service: http://localhost:3000
if [ -d "$APPS_DIR" ] && compgen -G "$APPS_DIR/*.yml" > /dev/null; then
    for frag in "$APPS_DIR"/*.yml; do
        logger -t "$_HOOK_TAG" "Including fragment: $(basename "$frag")"
        cat "$frag" >> "$ASSEMBLED"
        # Ensure trailing newline
        [[ $(tail -c1 "$frag" | wc -l) -eq 0 ]] && echo "" >> "$ASSEMBLED"
    done
else
    logger -t "$_HOOK_TAG" "No app fragments in $APPS_DIR"
fi

# Append mandatory catch-all
echo "  - service: http_status:404" >> "$ASSEMBLED"

# Compare before writing
if diff -q "$CONFIG" "$ASSEMBLED" > /dev/null 2>&1; then
    logger -t "$_HOOK_TAG" "Cloudflare config unchanged"
    exit 0
fi

sudo cp "$ASSEMBLED" "$CONFIG"
logger -t "$_HOOK_TAG" "Assembled cloudflare config with $(compgen -G "$APPS_DIR/*.yml" 2>/dev/null | wc -l) fragment(s)"
