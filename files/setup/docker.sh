#!/bin/bash
# Install Docker and configure daemon.
source "$(dirname "$0")/../_setup-env.sh"

if command -v docker &>/dev/null; then
    echo "  [-] Docker already installed (already done)"
else
    curl -fsSL https://get.docker.com | sh
    echo "  [+] Docker installed"
fi

usermod -aG docker "$USERNAME"

# Copy daemon config and systemd override
cp "$REMOTE_DIR/files/docker-daemon.json" /etc/docker/daemon.json

OVERRIDE_DIR="/etc/systemd/system/docker.service.d"
mkdir -p "$OVERRIDE_DIR"
cp "$REMOTE_DIR/files/docker-tailscale.conf" "$OVERRIDE_DIR/tailscale.conf"

systemctl daemon-reload
systemctl restart docker
echo "  [+] Docker configured (log rotation, IPv6 disabled, waits for Tailscale)"
