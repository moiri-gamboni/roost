#!/bin/bash
# Configure tmux, bashrc, and create directory structure.
source "$(dirname "$0")/../_setup-env.sh"

# --- tmux and shell ---

cp "$REMOTE_DIR/files/tmux.conf" "$HOME_DIR/.tmux.conf"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.tmux.conf"

MARKER="# === self-host-setup ==="
if ! grep -q "$MARKER" "$HOME_DIR/.bashrc"; then
    {
        echo ""
        echo "$MARKER"
        cat "$REMOTE_DIR/files/bashrc-append.sh"
    } >> "$HOME_DIR/.bashrc"
fi
echo "  [+] tmux and shell configured"

# --- Directory structure ---

for dir in \
    "$HOME_DIR/roost/claude/hooks" \
    "$HOME_DIR/roost/claude/skills/learned" \
    "$HOME_DIR/roost/claude/locks" \
    "$HOME_DIR/roost/memory/debugging" \
    "$HOME_DIR/roost/memory/projects" \
    "$HOME_DIR/roost/memory/patterns" \
    "$HOME_DIR/roost/code/life" \
    "$HOME_DIR/.cloudflared" \
    "$HOME_DIR/services" \
    "$HOME_DIR/bin"
do
    mkdir -p "$dir"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
echo "  [+] Directory structure created"
