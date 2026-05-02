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

apt install -y tmux build-essential jq unzip btrfs-progs snapper glances util-linux bash-completion
ok "Base packages installed"

# TCP BBR: better throughput than the cubic default on lossy/congested
# paths (notably xray traffic from in-China clients through GFW). Drop-in
# survives reboots; fq_codel qdisc (Ubuntu default) is BBR-compatible.
if ! grep -qx 'net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/99-bbr.conf 2>/dev/null; then
    echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
    echo 'net.ipv4.tcp_congestion_control = bbr' > /etc/sysctl.d/99-bbr.conf
    modprobe tcp_bbr
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null
    ok "TCP BBR enabled"
else
    skip "TCP BBR already enabled"
fi
