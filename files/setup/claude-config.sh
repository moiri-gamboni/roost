#!/bin/bash
# Deploy Claude Code configuration, hook scripts, and dangerous command blocker.
source "$(dirname "$0")/../_setup-env.sh"

CLAUDE_DIR="$HOME_DIR/roost/claude"

# --- Configuration files ---

# settings.json (hooks, cleanup policy, compact policy)
cp "$REMOTE_DIR/files/settings.json" "$CLAUDE_DIR/settings.json"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
echo "  [+] Claude Code configuration written"

# --- Hook scripts ---

# Remove immutable flags if set (allows re-deploy after harden-hooks.sh)
chattr -i "$CLAUDE_DIR/hooks/"*.sh "$CLAUDE_DIR/hooks/"*.md "$CLAUDE_DIR/settings.json" 2>/dev/null || true

# Install shared hook library
cp "$REMOTE_DIR/files/hooks/_hook-env.sh" "$CLAUDE_DIR/hooks/_hook-env.sh"

for hook in session-lock session-unlock reflect notify auto-commit \
            health-check scheduled-task run-scheduled-task auto-update \
            conflict-check ram-monitor; do
    cp "$REMOTE_DIR/files/hooks/${hook}.sh" "$CLAUDE_DIR/hooks/${hook}.sh"
    chmod +x "$CLAUDE_DIR/hooks/${hook}.sh"
done
cp "$REMOTE_DIR/files/hooks/reflect.md" "$CLAUDE_DIR/hooks/reflect.md"
chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/hooks"
ok "All hook scripts installed"

info "To make hooks immutable (protects against Syncthing tampering):"
info "  sudo bash $REMOTE_DIR/files/setup/harden-hooks.sh"

# --- Dangerous command blocker ---

echo "  [*] Installing dangerous-command-blocker hook..."
as_user "cd ~ && CLAUDE_CONFIG_DIR=$CLAUDE_DIR npx --yes claude-code-templates@latest --hook=security/dangerous-command-blocker --yes" || \
    echo "  [*] Could not install dangerous-command-blocker (install manually later)"

# Move files that landed in ~/.claude/ instead of $CLAUDE_DIR
if [ -d "$HOME_DIR/.claude/scripts" ]; then
    mkdir -p "$CLAUDE_DIR/scripts"
    cp -rn "$HOME_DIR/.claude/scripts/"* "$CLAUDE_DIR/scripts/" 2>/dev/null || true
    rm -rf "$HOME_DIR/.claude/scripts"
    chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/scripts"
    echo "  [+] Moved hook scripts from ~/.claude/ to $CLAUDE_DIR/"
fi

# Merge any PreToolUse hooks the template wrote to ~/.claude/settings.json
if [ -f "$HOME_DIR/.claude/settings.json" ]; then
    NEW_HOOKS=$(jq '.hooks.PreToolUse // empty' "$HOME_DIR/.claude/settings.json" 2>/dev/null)
    if [ -n "$NEW_HOOKS" ] && [ "$NEW_HOOKS" != "null" ]; then
        jq --argjson new "$NEW_HOOKS" '.hooks.PreToolUse = (.hooks.PreToolUse // []) + $new' \
            "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp"
        mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
        chown "$USERNAME:$USERNAME" "$CLAUDE_DIR/settings.json"
        echo "  [+] Merged PreToolUse hooks into $CLAUDE_DIR/settings.json"
    fi
    rm -f "$HOME_DIR/.claude/settings.json"
fi

# Fix script paths to use $CLAUDE_DIR instead of ~/.claude/
if grep -q '\.claude/scripts/' "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    sed -i "s|\.claude/scripts/|roost/claude/scripts/|g" "$CLAUDE_DIR/settings.json"
    echo "  [+] Updated script paths in settings.json"
fi
