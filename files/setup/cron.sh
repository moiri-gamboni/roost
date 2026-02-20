#!/bin/bash
# Configure cron jobs and initialize grepai.
source "$(dirname "$0")/../_setup-env.sh"

# --- Cron jobs ---

export USERNAME HOME_DIR ROOST_DIR_NAME
envsubst '$USERNAME $HOME_DIR $ROOST_DIR_NAME' \
    < "$REMOTE_DIR/files/cron-roost" \
    > "/etc/cron.d/$ROOST_DIR_NAME"

chmod 644 "/etc/cron.d/$ROOST_DIR_NAME"

# Clean up old names
rm -f /etc/cron.d/self-host
if [ "$ROOST_DIR_NAME" != "roost" ]; then
    rm -f /etc/cron.d/roost
fi
echo "  [+] Cron jobs configured"

# --- Initial grepai setup ---

if as_user "command -v grepai" &>/dev/null; then
    for dir in "$ROOST_DIR/memory" "$ROOST_DIR/claude/skills"; do
        if [ ! -f "$dir/.grepai/config.yaml" ]; then
            echo "  [*] Initializing grepai in $dir..."
            as_user "cd $dir && grepai init" && \
                echo "  [+] grepai initialized in $dir" || \
                echo "  [*] grepai init failed in $dir (run manually: cd $dir && grepai init)"
        else
            echo "  [-] grepai already initialized in $dir (already done)"
        fi
    done
    echo "  [*] Start grepai watch daemons with: grepai watch --background"
else
    echo "  [*] grepai not available; skipping init"
fi
