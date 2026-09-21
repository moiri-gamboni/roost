#!/bin/bash
# Install earlyoom and deploy its options (files/earlyoom.default).
source "$(dirname "$0")/../_setup-env.sh"

if dpkg -s earlyoom >/dev/null 2>&1; then
    skip "earlyoom installed"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom
    ok "earlyoom installed"
fi

SRC="$REMOTE_DIR/files/earlyoom.default"
TARGET="/etc/default/earlyoom"
if [ -f "$TARGET" ] && cmp -s "$SRC" "$TARGET"; then
    skip "earlyoom options already configured"
else
    install -m 0644 "$SRC" "$TARGET"
    systemctl restart earlyoom
    ok "earlyoom options deployed"
fi

if ! systemctl is-active --quiet earlyoom; then
    systemctl enable --now earlyoom
    ok "earlyoom running"
else
    skip "earlyoom already running"
fi
