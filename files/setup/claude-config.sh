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

# Substitute ~/roost/ paths in settings.json and reflect.md if using a custom directory name
if [ "$ROOST_DIR_NAME" != "roost" ]; then
    sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/settings.json"
    sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g" "$CLAUDE_DIR/hooks/reflect.md"
fi

ok "All hook scripts installed"

info "To make hooks immutable (protects against Syncthing tampering):"
info "  sudo bash $REMOTE_DIR/files/setup/harden-hooks.sh"

# --- Dangerous command blocker ---

echo "  [*] Installing dangerous-command-blocker hook..."
as_user "cd ~ && CLAUDE_CONFIG_DIR=$CLAUDE_DIR npx --yes claude-code-templates@latest --hook=security/dangerous-command-blocker --yes" || \
    echo "  [*] Could not install dangerous-command-blocker (install manually later)"

# claude-code-templates ignores CLAUDE_CONFIG_DIR and writes to ~/.claude/:
#   - ~/.claude/settings.local.json  (PreToolUse hook config)
#   - ~/.claude/hooks/dangerous-command-blocker.py  (the actual script)
# The config may reference .claude/scripts/ even though the file is in .claude/hooks/.
# We consolidate everything into $CLAUDE_DIR/hooks/ and fix the paths.

# Move script files from ~/.claude/hooks/ and ~/.claude/scripts/ into $CLAUDE_DIR/hooks/
for subdir in hooks scripts; do
    if [ -d "$HOME_DIR/.claude/$subdir" ]; then
        mkdir -p "$CLAUDE_DIR/hooks"
        cp -rn "$HOME_DIR/.claude/$subdir/"* "$CLAUDE_DIR/hooks/" 2>/dev/null || true
        rm -rf "$HOME_DIR/.claude/$subdir"
        chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR/hooks"
        echo "  [+] Moved ~/.claude/$subdir/ into $CLAUDE_DIR/hooks/"
    fi
done

# Merge PreToolUse hooks into our settings.json
merge_pretooluse() {
    local src="$1"
    [ -f "$src" ] || return 1
    local new_hooks
    new_hooks=$(jq '.hooks.PreToolUse // empty' "$src" 2>/dev/null)
    [ -n "$new_hooks" ] && [ "$new_hooks" != "null" ] || return 1
    jq --argjson new "$new_hooks" '.hooks.PreToolUse = (.hooks.PreToolUse // []) + $new' \
        "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp"
    mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
    chown "$USERNAME:$USERNAME" "$CLAUDE_DIR/settings.json"
    echo "  [+] Merged PreToolUse hooks from $src"
    rm -f "$src"
    return 0
}

merge_pretooluse "$HOME_DIR/.claude/settings.json" || true
merge_pretooluse "$HOME_DIR/.claude/settings.local.json" || true
merge_pretooluse "$CLAUDE_DIR/settings.local.json" || true

# Fix all .claude/scripts/ and .claude/hooks/ references to point to $CLAUDE_DIR/hooks/
# (claude-code-templates references .claude/scripts/ but puts files in .claude/hooks/)
if grep -qE '\.claude/(scripts|hooks)/' "$CLAUDE_DIR/settings.json" 2>/dev/null; then
    sed -i "s|\.claude/scripts/|$ROOST_DIR_NAME/claude/hooks/|g; s|\.claude/hooks/|$ROOST_DIR_NAME/claude/hooks/|g" \
        "$CLAUDE_DIR/settings.json"
    echo "  [+] Updated script paths in settings.json"
fi
