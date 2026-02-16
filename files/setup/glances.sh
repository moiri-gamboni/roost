#!/bin/bash
# Configure Glances as a systemd service.
source "$(dirname "$0")/../_setup-env.sh"

export USERNAME
envsubst '$USERNAME' \
    < "$REMOTE_DIR/files/glances.service" \
    > /etc/systemd/system/glances.service

systemctl daemon-reload
systemctl enable --now glances
echo "  [+] Glances running"
