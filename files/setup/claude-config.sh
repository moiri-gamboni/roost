#!/bin/bash
# Deploy Claude Code configuration, hook scripts, and dangerous command blocker.
source "$(dirname "$0")/../_setup-env.sh"

CLAUDE_DIR="$ROOST_DIR/claude"

# --- Configuration files ---

# settings.json (hooks, cleanup policy, compact policy)
cp "$REMOTE_DIR/files/settings.json" "$CLAUDE_DIR/settings.json"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
echo "  [+] Claude Code configuration written"

# --- Hook scripts ---

# Remove immutable flags if set (allows re-deploy after harden-hooks.sh)
chattr -i "$CLAUDE_DIR/hooks/"*.sh "$CLAUDE_DIR/hooks/"*.md "$CLAUDE_DIR/hooks/"*.py "$CLAUDE_DIR/settings.json" 2>/dev/null || true

# Install shared hook library
cp "$REMOTE_DIR/files/hooks/_hook-env.sh" "$CLAUDE_DIR/hooks/_hook-env.sh"

for hook in session-lock session-unlock reflect notify auto-commit \
            health-check scheduled-task run-scheduled-task auto-update \
            conflict-check ram-monitor cloudflare-assemble roost-apply; do
    cp "$REMOTE_DIR/files/hooks/${hook}.sh" "$CLAUDE_DIR/hooks/${hook}.sh"
    chmod +x "$CLAUDE_DIR/hooks/${hook}.sh"
done
cp "$REMOTE_DIR/files/hooks/reflect.md" "$CLAUDE_DIR/hooks/reflect.md"

# Install dangerous command blocker
cp "$REMOTE_DIR/files/hooks/dangerous-command-blocker.py" "$CLAUDE_DIR/hooks/dangerous-command-blocker.py"
chmod +x "$CLAUDE_DIR/hooks/dangerous-command-blocker.py"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/hooks"

# Substitute ~/roost/ paths in settings.json and reflect.md if using a custom directory name
if [ "$ROOST_DIR_NAME" != "roost" ]; then
    sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/settings.json"
    sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/hooks/reflect.md"
fi

ok "All hook scripts installed"

info "To make hooks immutable (protects against Syncthing tampering):"
info "  sudo bash $REMOTE_DIR/files/setup/harden-hooks.sh"
