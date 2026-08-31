#!/bin/bash
# Configure tmux, bashrc, and create directory structure.
source "$(dirname "$0")/../_setup-env.sh"

# --- tmux and shell ---

cp "$REMOTE_DIR/files/tmux.conf" "$HOME_DIR/.tmux.conf"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.tmux.conf"

MARKER="# === roost-setup ==="
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
    envsubst '$ROOST_DIR_NAME' < "$REMOTE_DIR/files/bashrc-append.sh"
} >> "$BASHRC"

# Append to ~/.profile so non-interactive shells also get PATH/env setup
PROFILE="$HOME_DIR/.profile"
if grep -q "$MARKER" "$PROFILE" 2>/dev/null; then
    marker_line=$(grep -n "$MARKER" "$PROFILE" | head -1 | cut -d: -f1)
    if [ "$marker_line" -gt 1 ]; then
        prev_line=$((marker_line - 1))
        if sed -n "${prev_line}p" "$PROFILE" | grep -q '^$'; then
            sed -i "${prev_line}d" "$PROFILE"
        fi
    fi
    sed -i "/$MARKER/,\$d" "$PROFILE"
fi
{
    echo ""
    echo "$MARKER"
    envsubst '$ROOST_DIR_NAME' < "$REMOTE_DIR/files/profile-append.sh"
} >> "$PROFILE"
echo "  [+] tmux and shell configured"

# --- Directory structure ---

for dir in \
    "$ROOST_DIR/claude/hooks" \
    "$ROOST_DIR/claude/scripts" \
    "$ROOST_DIR/claude/scheduled" \
    "$ROOST_DIR/claude/lib" \
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
    "$HOME_DIR/.config/git/tokens" \
    "$HOME_DIR/.config/systemd/user"
do
    mkdir -p "$dir"
done
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
chmod 700 "$HOME_DIR/.config/git/tokens"
echo "  [+] Directory structure created"

# --- Deploy bashrc.sh to ~/.bashrc.d/ ---
cp "$REMOTE_DIR/files/shell/bashrc.sh" "$HOME_DIR/.bashrc.d/$ROOST_DIR_NAME.sh"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.bashrc.d/$ROOST_DIR_NAME.sh"
echo "  [+] Shell config deployed to $HOME_DIR/.bashrc.d/$ROOST_DIR_NAME.sh"

# Symlink roost-apply into ~/bin so it works in non-interactive shells (e.g. Claude Code Bash tool)
ln -sf "$ROOST_DIR/claude/scripts/roost-apply.sh" "$HOME_DIR/bin/roost-apply"
chown -h "$USERNAME:$USERNAME" "$HOME_DIR/bin/roost-apply"
ln -sf "$ROOST_DIR/claude/scripts/roost-net.sh" "$HOME_DIR/bin/roost-net"
chown -h "$USERNAME:$USERNAME" "$HOME_DIR/bin/roost-net"
# session: the session CLI — identity (`session whoami`), plan usage limits +
# per-session attribution (`session` / `session usage [--all]`), guard/wait
ln -sf "$ROOST_DIR/claude/scripts/session.sh" "$HOME_DIR/bin/session"
chown -h "$USERNAME:$USERNAME" "$HOME_DIR/bin/session"

# Restore the sessions a `session reboot` snapshotted, at boot. Lingering is
# what lets the user manager (and so this unit) run with nobody logged in;
# without it the restore would wait for an SSH login that may never come.
cp "$REMOTE_DIR/files/roost-session-resume.service" \
   "$HOME_DIR/.config/systemd/user/roost-session-resume.service"
chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.config/systemd"
loginctl enable-linger "$USERNAME"
as_user "systemctl --user daemon-reload && systemctl --user enable roost-session-resume.service"
echo "  [+] Session restore-after-reboot enabled"
# granola-digest ships from files/private/, so skip when it isn't deployed
# (public-repo-only checkouts won't have it). The granola mirror tooling itself
# (granola/granola-transcripts/granola-refresh) lives in the apart-tools clone
# since 2026-08-19; its symlinks are wired by the private claude-plugins.sh
# alongside the plugin install.
if [ -f "$ROOST_DIR/claude/scripts/granola-digest.sh" ]; then
    ln -sf "$ROOST_DIR/claude/scripts/granola-digest.sh" "$HOME_DIR/bin/granola-digest"
    chown -h "$USERNAME:$USERNAME" "$HOME_DIR/bin/granola-digest"
fi

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

# `tasks` — the tasksync CLI from the apart-tools clone inside the apart-research
# workspace. Guarded: a box without that checkout just skips the link.
tasks_cli="$HOME_DIR/$ROOST_DIR_NAME/apart-research/apart-tools/tasksync/tasks"
if [ -x "$tasks_cli" ]; then
    ln -sfn "$tasks_cli" "$HOME_DIR/bin/tasks"
    chown -h "$USERNAME:$USERNAME" "$HOME_DIR/bin/tasks"
fi
