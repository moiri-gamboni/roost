#!/bin/bash
# Create 4GB swap file.
source "$(dirname "$0")/../_setup-env.sh"

if swapon --show | grep -q swapfile; then
    echo "  [-] Swap already active (already done)"
else
    mkdir -p /swap
    if btrfs filesystem show / &>/dev/null 2>&1; then
        btrfs filesystem mkswapfile --size 4G /swap/swapfile
    else
        dd if=/dev/zero of=/swap/swapfile bs=1M count=4096 status=progress
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile
    fi
    swapon /swap/swapfile
    grep -q '/swap/swapfile' /etc/fstab || \
        echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab
    echo "  [+] 4GB swap created"
fi

if ! grep -q 'vm.swappiness=10' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p >/dev/null
fi
