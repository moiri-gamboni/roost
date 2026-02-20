#!/bin/bash
# System updates and base packages.
source "$(dirname "$0")/../_setup-env.sh"

# Disable unattended-upgrades during setup to prevent dpkg lock conflicts.
# Mask prevents any restart triggers. Unmasked and re-enabled at end of deploy.
systemctl mask --now unattended-upgrades 2>/dev/null || true

# Set hostname to match SERVER_NAME from .env
if [ "$(hostname)" != "$SERVER_NAME" ]; then
    hostnamectl set-hostname "$SERVER_NAME"
    ok "Hostname set to $SERVER_NAME"
else
    skip "Hostname already $SERVER_NAME"
fi

apt update
ok "Package list updated"

apt install -y tmux mosh build-essential jq unzip btrfs-progs snapper glances util-linux
ok "Base packages installed"
