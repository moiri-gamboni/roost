#!/bin/bash
# Deploy Claude Code configuration, hook scripts, and dangerous command blocker.
source "$(dirname "$0")/../_setup-env.sh"

CLAUDE_DIR="$HOME_DIR/roost/claude"

# --- Configuration files ---

# settings.json (hooks, cleanup policy, compact policy)
cp "$REMOTE_DIR/files/settings.json" "$CLAUDE_DIR/settings.json"

# machines.json
cp "$REMOTE_DIR/files/machines.json" "$CLAUDE_DIR/machines.json"

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
echo "  [+] Claude Code configuration written"

# --- Hook scripts ---

for hook in session-lock session-unlock reflect notify auto-commit \
            health-check scheduled-task run-scheduled-task auto-update; do
    cp "$REMOTE_DIR/files/hooks/${hook}.sh" "$CLAUDE_DIR/hooks/${hook}.sh"
    chmod +x "$CLAUDE_DIR/hooks/${hook}.sh"
done
cp "$REMOTE_DIR/files/hooks/reflect.md" "$CLAUDE_DIR/hooks/reflect.md"
chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/hooks"
echo "  [+] All hook scripts installed"

# --- Dangerous command blocker ---

echo "  [*] Installing dangerous-command-blocker hook..."
as_user "cd ~ && npx --yes claude-code-templates@latest --hook=security/dangerous-command-blocker --yes" || \
    echo "  [*] Could not install dangerous-command-blocker (install manually later)"
