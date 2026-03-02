#!/bin/bash
# Opt-in: make hook scripts and config immutable so Syncthing cannot modify them.
# Run after deploying hooks. Re-run after updating hooks (auto-update.sh
# or deploy.sh will need to call `chattr -i` first).
#
# Usage: sudo bash harden-hooks.sh
source "$(dirname "$0")/../_setup-env.sh"

HOOKS_DIR="$ROOST_DIR/claude/hooks"
CLAUDE_DIR="$ROOST_DIR/claude"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "Error: $HOOKS_DIR does not exist"
    exit 1
fi

# Remove immutable flags first (idempotent)
chattr -i "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/*.md "$HOOKS_DIR"/*.py "$CLAUDE_DIR/settings.json" 2>/dev/null || true

# Set immutable on hook scripts
for f in "$HOOKS_DIR"/*.sh; do
    [ -f "$f" ] && chattr +i "$f"
done

# Set immutable on hook data files
for f in "$HOOKS_DIR"/*.md; do
    [ -f "$f" ] && chattr +i "$f"
done

# Set immutable on Python hooks
for f in "$HOOKS_DIR"/*.py; do
    [ -f "$f" ] && chattr +i "$f"
done

# Set immutable on settings.json (hook definitions)
[ -f "$CLAUDE_DIR/settings.json" ] && chattr +i "$CLAUDE_DIR/settings.json"

ok "Hook scripts, data files, and settings.json are now immutable (chattr +i)"
info "To update, first run: sudo chattr -i $HOOKS_DIR/*.sh $HOOKS_DIR/*.md $HOOKS_DIR/*.py $CLAUDE_DIR/settings.json"
