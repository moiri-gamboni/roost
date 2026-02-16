#!/bin/bash
# Configure cron jobs and run initial grepai index.
source "$(dirname "$0")/../_setup-env.sh"

# --- Cron jobs ---

export USERNAME HOME_DIR
envsubst '$USERNAME $HOME_DIR' \
    < "$REMOTE_DIR/files/cron-self-host" \
    > /etc/cron.d/self-host

chmod 644 /etc/cron.d/self-host
echo "  [+] Cron jobs configured"

# --- Initial grepai index ---

if [ -f "$HOME_DIR/bin/grepai" ]; then
    echo "  [*] Running initial grepai index..."
    as_user "$HOME_DIR/bin/grepai index $HOME_DIR/roost/memory $HOME_DIR/roost/claude/skills" && \
        echo "  [+] grepai index created" || \
        echo "  [*] grepai indexing failed (run manually later: grepai index ~/roost/memory ~/roost/claude/skills)"
else
    echo "  [*] grepai not available; skipping index"
fi
