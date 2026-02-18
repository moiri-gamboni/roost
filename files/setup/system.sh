#!/bin/bash
# System updates and base packages.
source "$(dirname "$0")/../_setup-env.sh"

apt update
ok "Package list updated"

apt install -y tmux build-essential jq unzip btrfs-progs snapper glances util-linux unattended-upgrades
ok "Base packages installed"

# Configure unattended-upgrades for security patches only
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

ok "Unattended security upgrades configured"
