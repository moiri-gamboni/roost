#!/bin/bash
# The conflict watch: a root daemon recording which Claude Code session writes in which unit
# (files/scripts/conflict-watch.py). The script, its rules file and the hook arrive with
# `roost-apply push` (the manifest restarts the service); this installs and enables the unit,
# which `roost-apply` alone would start but never enable.
source "$(dirname "$0")/../_setup-env.sh"

export HOME_DIR ROOST_DIR_NAME
RENDERED=$(envsubst '$HOME_DIR $ROOST_DIR_NAME' < "$REMOTE_DIR/files/conflict-watch.service")
TARGET="/etc/systemd/system/conflict-watch.service"

if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$RENDERED" ] && systemctl is-enabled --quiet conflict-watch; then
    skip "conflict-watch service already configured"
else
    echo "$RENDERED" > "$TARGET"
    systemctl daemon-reload
    systemctl enable conflict-watch
    systemctl restart conflict-watch
    ok "conflict-watch running"
fi
