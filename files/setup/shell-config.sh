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
    # Substitute default ROOST_DIR_NAME if using a custom directory name
    if [ "$ROOST_DIR_NAME" != "roost" ]; then
        sed -i "s|ROOST_DIR_NAME:-roost|ROOST_DIR_NAME:-$ROOST_DIR_NAME|g" "$HOME_DIR/.bashrc"
    fi
fi
echo "  [+] tmux and shell configured"

# --- Directory structure ---

for dir in \
    "$ROOST_DIR/claude/hooks" \
    "$ROOST_DIR/claude/skills" \
    "$ROOST_DIR/claude/locks" \
    "$ROOST_DIR/cloudflared/apps" \
    "$HOME_DIR/.bashrc.d" \
    "$ROOST_DIR/memory/debugging" \
    "$ROOST_DIR/memory/projects" \
    "$ROOST_DIR/memory/patterns" \
    "$ROOST_DIR/code/life" \
    "$HOME_DIR/.cloudflared" \
    "$HOME_DIR/.locks" \
    "$HOME_DIR/services" \
    "$HOME_DIR/bin" \
    "$HOME_DIR/drop"
do
    mkdir -p "$dir"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
echo "  [+] Directory structure created"

# --- Deploy bashrc.sh to ~/.bashrc.d/ ---
cp "$REMOTE_DIR/files/shell/bashrc.sh" "$HOME_DIR/.bashrc.d/roost.sh"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.bashrc.d/roost.sh"
echo "  [+] Shell config deployed to $HOME_DIR/.bashrc.d/roost.sh"

# --- Git identity ---
if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
    as_user "git config --global user.name '$GIT_USER_NAME'"
    as_user "git config --global user.email '$GIT_USER_EMAIL'"
    echo "  [+] Git identity configured"
else
    echo "  [-] Git identity skipped (GIT_USER_NAME/GIT_USER_EMAIL not set)"
fi
