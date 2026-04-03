#!/bin/bash
# Configure tmux, bashrc, and create directory structure.
source "$(dirname "$0")/../_setup-env.sh"

# --- tmux and shell ---

cp "$REMOTE_DIR/files/tmux.conf" "$HOME_DIR/.tmux.conf"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.tmux.conf"

MARKER="# === self-host-setup ==="
BASHRC="$HOME_DIR/.bashrc"

# Remove old marker block + preceding blank line to prevent accumulation on re-deploy
if grep -q "$MARKER" "$BASHRC"; then
    marker_line=$(grep -n "$MARKER" "$BASHRC" | head -1 | cut -d: -f1)
    if [ "$marker_line" -gt 1 ]; then
        prev_line=$((marker_line - 1))
        if sed -n "${prev_line}p" "$BASHRC" | grep -q '^$'; then
            sed -i "${prev_line}d" "$BASHRC"
        fi
    fi
    sed -i "/$MARKER/,\$d" "$BASHRC"
fi

# Append current version
{
    echo ""
    echo "$MARKER"
    cat "$REMOTE_DIR/files/bashrc-append.sh"
} >> "$BASHRC"

if [ "$ROOST_DIR_NAME" != "roost" ]; then
    sed -i "s|ROOST_DIR_NAME:-roost|ROOST_DIR_NAME:-$ROOST_DIR_NAME|g" "$BASHRC"
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
    "$ROOST_DIR/drop" \
    "$HOME_DIR/.config/git/tokens"
do
    mkdir -p "$dir"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
chmod 700 "$HOME_DIR/.config/git/tokens"
echo "  [+] Directory structure created"

# --- Deploy bashrc.sh to ~/.bashrc.d/ ---
cp "$REMOTE_DIR/files/shell/bashrc.sh" "$HOME_DIR/.bashrc.d/roost.sh"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.bashrc.d/roost.sh"
echo "  [+] Shell config deployed to $HOME_DIR/.bashrc.d/roost.sh"

# Clean up old shell config location
rm -rf "$ROOST_DIR/shell"

# --- Git identity ---
if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
    as_user "git config --global user.name '$GIT_USER_NAME'"
    as_user "git config --global user.email '$GIT_USER_EMAIL'"
    echo "  [+] Git identity configured"
else
    echo "  [-] Git identity skipped (GIT_USER_NAME/GIT_USER_EMAIL not set)"
fi

# --- SSH key for commit signing ---
if [ ! -f "$HOME_DIR/.ssh/id_ed25519" ]; then
    as_user "ssh-keygen -t ed25519 -N '' -f '$HOME_DIR/.ssh/id_ed25519' -C '$USERNAME@$SERVER_NAME'"
    echo "  [+] SSH key generated for commit signing"
else
    echo "  [-] SSH key already exists (skipping generation)"
fi

as_user "git config --global gpg.format ssh"
as_user "git config --global user.signingkey '$HOME_DIR/.ssh/id_ed25519.pub'"
as_user "git config --global commit.gpgsign true"
echo "  [+] Git commit signing configured"
