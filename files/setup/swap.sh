#!/bin/bash
# Create swap file sized to available RAM.
source "$(dirname "$0")/../_setup-env.sh"

if swapon --show | grep -q swapfile; then
    skip "Swap already active"
else
    # Determine swap size based on RAM
    RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    if [ "$RAM_MB" -le 8192 ]; then
        SWAP_MB="$RAM_MB"
    else
        SWAP_MB=4096
    fi
    SWAP_GB=$(( (SWAP_MB + 1023) / 1024 ))

    info "RAM: ${RAM_MB}MB, creating ${SWAP_GB}GB swap"
    mkdir -p /swap
    if btrfs filesystem show / &>/dev/null 2>&1; then
        btrfs filesystem mkswapfile --size "${SWAP_GB}G" /swap/swapfile
    else
        dd if=/dev/zero of=/swap/swapfile bs=1M count="$SWAP_MB" status=progress
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile
    fi
    swapon /swap/swapfile
    grep -q '/swap/swapfile' /etc/fstab || \
        echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab
    ok "${SWAP_GB}GB swap created"
fi

if ! grep -q 'vm.swappiness=10' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p >/dev/null
fi
