#!/bin/bash
# Configure Glances as a systemd service.
source "$(dirname "$0")/../_setup-env.sh"

export USERNAME
RENDERED=$(envsubst '$USERNAME' < "$REMOTE_DIR/files/glances.service")
TARGET="/etc/systemd/system/glances.service"

if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$RENDERED" ]; then
    skip "Glances service already configured"
else
    echo "$RENDERED" > "$TARGET"
    systemctl daemon-reload
    systemctl enable glances
    systemctl restart glances
    ok "Glances running"
fi
