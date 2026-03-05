#!/bin/bash
# Deploy Claude Code configuration, hook scripts, and dangerous command blocker.
source "$(dirname "$0")/../_setup-env.sh"

CLAUDE_DIR="$ROOST_DIR/claude"

# --- Configuration files ---

# settings.json (hooks, cleanup policy, compact policy)
cp "$REMOTE_DIR/files/settings.json" "$CLAUDE_DIR/settings.json"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
ok "Claude Code configuration written"

# --- CLAUDE.md files ---

# Global CLAUDE.md (epistemic style, learning, preferences)
GLOBAL_CLAUDE_DIR="$HOME_DIR/.claude"
mkdir -p "$GLOBAL_CLAUDE_DIR"
cp "$REMOTE_DIR/files/global-CLAUDE.md" "$GLOBAL_CLAUDE_DIR/CLAUDE.md"
chown -R "$USERNAME:$USERNAME" "$GLOBAL_CLAUDE_DIR"
ok "Global CLAUDE.md installed"

# Code CLAUDE.md (operational conventions, tool preferences)
CODE_DIR="$ROOST_DIR/code"
mkdir -p "$CODE_DIR"
cp "$REMOTE_DIR/files/code-CLAUDE.md" "$CODE_DIR/CLAUDE.md"
chown -R "$USERNAME:$USERNAME" "$CODE_DIR"
ok "Code CLAUDE.md installed"

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
