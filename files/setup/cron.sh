#!/bin/bash
# Configure cron jobs.
source "$(dirname "$0")/../_setup-env.sh"

# --- Cron jobs ---

export USERNAME HOME_DIR ROOST_DIR_NAME
envsubst '$USERNAME $HOME_DIR $ROOST_DIR_NAME' \
    < "$REMOTE_DIR/files/cron-roost" \
    > "/etc/cron.d/$ROOST_DIR_NAME"

chmod 644 "/etc/cron.d/$ROOST_DIR_NAME"

echo "  [+] Cron jobs configured"
