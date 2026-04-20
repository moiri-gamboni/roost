#!/bin/bash
# Install Tailscale (does NOT authenticate; auth is handled by deploy.sh).
source "$(dirname "$0")/../_setup-env.sh"

if command -v tailscale &>/dev/null; then
    skip "Tailscale already installed"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
fi

# Pin iptables backend (not nftables) so travel-vpn fwmark rules have
# predictable Tailscale mark bits to mask around (see plan §2.5, M18).
OVERRIDE_DIR="/etc/systemd/system/tailscaled.service.d"
mkdir -p "$OVERRIDE_DIR"
cp "$REMOTE_DIR/files/tailscaled-iptables.conf" "$OVERRIDE_DIR/iptables-pin.conf"
systemctl daemon-reload
if systemctl is-active tailscaled &>/dev/null; then
    systemctl restart tailscaled
fi
ok "tailscaled pinned to iptables backend"
