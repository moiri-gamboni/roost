#!/bin/bash
# Disable IPv6 via sysctl.
source "$(dirname "$0")/../_setup-env.sh"

if grep -q 'net.ipv6.conf.all.disable_ipv6=1' /etc/sysctl.conf; then
    echo "  [-] IPv6 already disabled (already done)"
else
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    sysctl -p
    echo "  [+] IPv6 disabled"
fi
