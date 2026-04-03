#!/bin/bash
# Deploy Claude Code configuration, hook scripts, and dangerous command blocker.
source "$(dirname "$0")/../_setup-env.sh"

CLAUDE_DIR="$ROOST_DIR/claude"

# --- Configuration files ---

# settings.json (hooks, cleanup policy, compact policy)
cp "$REMOTE_DIR/files/settings.json" "$CLAUDE_DIR/settings.json"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
ok "Claude Code configuration written"

# --- CLAUDE.md files (from private config, optional) ---

if [ -f "$REMOTE_DIR/files/private/global-CLAUDE.md" ]; then
    cp "$REMOTE_DIR/files/private/global-CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
    chown "$USERNAME:$USERNAME" "$CLAUDE_DIR/CLAUDE.md"
    ok "Global CLAUDE.md installed"
else
    info "Global CLAUDE.md not found (files/private/ missing). Skipping."
fi

CODE_DIR="$ROOST_DIR/code"
mkdir -p "$CODE_DIR"
if [ -f "$REMOTE_DIR/files/private/code-CLAUDE.md" ]; then
    cp "$REMOTE_DIR/files/private/code-CLAUDE.md" "$CODE_DIR/CLAUDE.md"
    chown -R "$USERNAME:$USERNAME" "$CODE_DIR"
    ok "Code CLAUDE.md installed"
else
    info "Code CLAUDE.md not found (files/private/ missing). Skipping."
fi

# --- Hook scripts ---

# Remove immutable flags if set (allows re-deploy after harden-hooks.sh)
chattr -i "$CLAUDE_DIR/hooks/"*.sh "$CLAUDE_DIR/hooks/"*.md "$CLAUDE_DIR/hooks/"*.py "$CLAUDE_DIR/settings.json" 2>/dev/null || true

# Install shared hook library
cp "$REMOTE_DIR/files/hooks/_hook-env.sh" "$CLAUDE_DIR/hooks/_hook-env.sh"

for hook in session-lock session-unlock reflect notify \
            health-check scheduled-task run-scheduled-task auto-update \
            ram-monitor cloudflare-assemble roost-apply; do
    cp "$REMOTE_DIR/files/hooks/${hook}.sh" "$CLAUDE_DIR/hooks/${hook}.sh"
    chmod +x "$CLAUDE_DIR/hooks/${hook}.sh"
done
cp "$REMOTE_DIR/files/hooks/reflect.md" "$CLAUDE_DIR/hooks/reflect.md"

# Install dangerous command blocker
cp "$REMOTE_DIR/files/hooks/dangerous-command-blocker.py" "$CLAUDE_DIR/hooks/dangerous-command-blocker.py"
chmod +x "$CLAUDE_DIR/hooks/dangerous-command-blocker.py"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/hooks"

# Substitute ~/roost/ paths in settings.json and reflect.md
sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/settings.json"
sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/hooks/reflect.md"

ok "All hook scripts installed"

info "To make hooks immutable (protects against unauthorized modification):"
info "  sudo bash $REMOTE_DIR/files/setup/harden-hooks.sh"
