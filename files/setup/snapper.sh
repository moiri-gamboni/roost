#!/bin/bash
# Configure snapper for btrfs snapshots.
source "$(dirname "$0")/../_setup-env.sh"

if btrfs filesystem show / &>/dev/null 2>&1; then
    if ! snapper list-configs | grep -q root; then
        snapper -c root create-config /
        snapper set-config \
            TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes \
            TIMELINE_MIN_AGE=1800 TIMELINE_LIMIT_HOURLY=24 \
            TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=4 \
            TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 \
            NUMBER_CLEANUP=yes NUMBER_MIN_AGE=1800 \
            NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5
        echo "  [+] Snapper configured"
    else
        echo "  [-] Snapper already configured (already done)"
    fi

    # Disable COW for database directories
    for dir in /var/lib/postgresql /var/lib/typesense; do
        mkdir -p "$dir"
        chattr +C "$dir" || true
    done
    echo "  [+] COW disabled for database directories"
else
    echo "  [*] Not btrfs; skipping snapper setup"
fi
