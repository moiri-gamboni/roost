#!/bin/bash
source "$(dirname "$0")/../_setup-env.sh"

# Install clip-forward Python package
if as_user "command -v clip-forward" &>/dev/null; then
    skip "clip-forward already installed"
else
    info "Installing clip-forward..."
    as_user "uv tool install clip-forward --from '$ROOST_DIR/code/clip-forward'"
    ok "clip-forward installed"
fi

# Install shims
SHIM_DIR="$HOME_DIR/.local/lib/clip-forward/shims"
if [ -d "$SHIM_DIR" ] && [ -x "$SHIM_DIR/xclip" ]; then
    skip "clip-forward shims already installed"
else
    as_user "clip-forward install-shims --dir '$SHIM_DIR' --force"
    ok "clip-forward shims installed to $SHIM_DIR"
fi

# sshd drop-in for clean socket forwarding
DROPIN="/etc/ssh/sshd_config.d/50-clip-forward.conf"
if [ -f "$DROPIN" ]; then
    skip "sshd clip-forward config already exists"
else
    echo "StreamLocalBindUnlink yes" > "$DROPIN"
    chmod 644 "$DROPIN"
    systemctl restart ssh
    ok "sshd configured for socket forwarding"
fi
