#!/bin/bash
# Deploy the RAM monitor systemd timer.
source "$(dirname "$0")/../_setup-env.sh"

export USERNAME HOME_DIR ROOST_DIR_NAME

for unit in ram-monitor.service ram-monitor.timer; do
    RENDERED=$(envsubst '$USERNAME $HOME_DIR $ROOST_DIR_NAME' < "$REMOTE_DIR/files/$unit")
    TARGET="/etc/systemd/system/$unit"

    if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$RENDERED" ]; then
        skip "RAM monitor $unit already configured"
    else
        echo "$RENDERED" > "$TARGET"
        CHANGED=true
    fi
done

if [ "${CHANGED:-}" = true ]; then
    systemctl daemon-reload
fi

if ! systemctl is-active --quiet ram-monitor.timer; then
    systemctl enable --now ram-monitor.timer
    ok "RAM monitor running (10s interval)"
else
    skip "RAM monitor timer already running"
fi
