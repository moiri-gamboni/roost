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
    # Substitute roost paths if using a custom directory name
    if [ "$ROOST_DIR_NAME" != "roost" ]; then
        sed -i "s|~/roost/|~/$ROOST_DIR_NAME/|g; s|\$HOME/roost/|\$HOME/$ROOST_DIR_NAME/|g" "$HOME_DIR/.bashrc"
    fi
fi
echo "  [+] tmux and shell configured"

# --- Directory structure ---

for dir in \
    "$ROOST_DIR/claude/hooks" \
    "$ROOST_DIR/claude/skills" \
    "$ROOST_DIR/claude/locks" \
    "$ROOST_DIR/cloudflared/apps" \
    "$ROOST_DIR/shell" \
    "$ROOST_DIR/memory/debugging" \
    "$ROOST_DIR/memory/projects" \
    "$ROOST_DIR/memory/patterns" \
    "$ROOST_DIR/code/life" \
    "$HOME_DIR/.cloudflared" \
    "$HOME_DIR/.locks" \
    "$HOME_DIR/services" \
    "$HOME_DIR/bin"
do
    mkdir -p "$dir"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
echo "  [+] Directory structure created"

# --- Deploy bashrc.sh to roost/shell/ ---
cp "$REMOTE_DIR/files/shell/bashrc.sh" "$ROOST_DIR/shell/bashrc.sh"
chown "$USERNAME:$USERNAME" "$ROOST_DIR/shell/bashrc.sh"
echo "  [+] Shell config deployed to $ROOST_DIR/shell/bashrc.sh"
