#!/bin/bash
# Deploy the attention sampler systemd timer (replaces the 1/min cron tick).
source "$(dirname "$0")/../_setup-env.sh"

export USERNAME HOME_DIR ROOST_DIR_NAME

for unit in session-focus-tick.service session-focus-tick.timer; do
    RENDERED=$(envsubst '$USERNAME $HOME_DIR $ROOST_DIR_NAME' < "$REMOTE_DIR/files/$unit")
    TARGET="/etc/systemd/system/$unit"

    if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$RENDERED" ]; then
        skip "Attention sampler $unit already configured"
    else
        echo "$RENDERED" > "$TARGET"
        CHANGED=true
    fi
done

if [ "${CHANGED:-}" = true ]; then
    systemctl daemon-reload
fi

if ! systemctl is-active --quiet session-focus-tick.timer; then
    systemctl enable --now session-focus-tick.timer
    ok "Attention sampler running (10s interval)"
else
    skip "Attention sampler timer already running"
fi
