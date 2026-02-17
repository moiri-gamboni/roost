#!/bin/bash
# Install Docker and configure daemon.
source "$(dirname "$0")/../_setup-env.sh"

if command -v docker &>/dev/null; then
    echo "  [-] Docker already installed (already done)"
else
    # Official APT repository method (https://docs.docker.com/engine/install/ubuntu/)
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
