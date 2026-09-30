#!/bin/bash
# Configure snapper for btrfs snapshots, and keep regenerable churn out of them.
source "$(dirname "$0")/../_setup-env.sh"

if ! btrfs filesystem show / &>/dev/null 2>&1; then
    echo "  [*] Not btrfs; skipping snapper setup"
    exit 0
fi

if ! snapper list-configs | grep -q root; then
    snapper -c root create-config /
    snapper set-config \
        TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes \
        TIMELINE_MIN_AGE=1800 TIMELINE_LIMIT_HOURLY=24 \
        TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 \
        TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 \
        NUMBER_CLEANUP=yes NUMBER_MIN_AGE=1800 \
        NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5
    echo "  [+] Snapper configured"
else
    echo "  [-] Snapper already configured (already done)"
fi

# Regenerable, high-churn trees are nested subvolumes: a snapshot of @rootfs
# does not descend into them, so neither snapper's timeline nor the off-site
# btrfs send carries toolchains, package caches, editor server builds or the
# drop mirror — the churn that otherwise stays pinned for the whole retention
# window and fills a 152G root whose live tree is ~50G (plans/snapshot-exclusions.md).
NESTED_SUBVOLS=(
    .cache .npm
    .local/share/fnm .local/share/uv .local/share/pnpm .local/share/virtualenvs .local/share/claude
    .vscode-server/cli .vscode-server/extensions .codex/packages
    go/pkg/mod .agent-browser/browsers
    "$ROOST_DIR_NAME/drop"
)
for rel in "${NESTED_SUBVOLS[@]}"; do
    dir="$HOME_DIR/$rel"
    btrfs subvolume show "$dir" &>/dev/null && continue
    if [ ! -e "$dir" ]; then
        mkdir -p "$(dirname "$dir")"
        btrfs subvolume create "$dir" >/dev/null
        chown "$USERNAME:$USERNAME" "$dir" "$(dirname "$dir")"
        echo "  [+] Subvolume created: $rel"
        continue
    fi
    # Convert in place: reflink the tree into a fresh subvolume (no data is
    # duplicated, only metadata), then swap. Processes holding files in the old
    # tree keep their inodes, so it stays as <dir>.old until nothing runs out
    # of it (VS Code server, uvx-run MCP servers, the mmdc and roughdraft browsers);
    # deleting it under a live uvx env is the `uv cache prune --force` hazard.
    [ -e "$dir.subvol" ] && btrfs subvolume delete "$dir.subvol" >/dev/null
    btrfs subvolume create "$dir.subvol" >/dev/null
    cp -a --reflink=always "$dir/." "$dir.subvol/"
    chown --reference="$dir" "$dir.subvol"
    chmod --reference="$dir" "$dir.subvol"
    mv "$dir" "$dir.old"
    mv "$dir.subvol" "$dir"
    echo "  [+] Subvolume converted: $rel (old tree kept at $rel.old until its processes exit)"
done

# /tmp is a top-level subvolume (@tmp) mounted over the rootfs /tmp dir: test
# suites and tools churn hundreds of thousands of scratch files through it, and
# nested in @rootfs every hourly snapshot pinned them (5.5G live plus the
# metadata). It cannot be converted in place like the trees above, because live
# sockets sit in it (tmux's among them), so the mount takes effect at the next
# boot. nofail: a missing @tmp leaves /tmp on the rootfs dir, as before. Boot
# empties /tmp either way (Ubuntu's tmpfiles `D /tmp`); what the mount hides
# underneath is cleared by scheduled/disk-cleanup.sh.
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*//')
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
TOP=$(mktemp -d)
mount -o subvolid=5 "$ROOT_DEV" "$TOP"
if [ -d "$TOP/@tmp" ]; then
    echo "  [-] @tmp subvolume already exists (already done)"
else
    btrfs subvolume create "$TOP/@tmp" >/dev/null
    chmod 1777 "$TOP/@tmp"
    echo "  [+] @tmp subvolume created"
fi
umount "$TOP" && rmdir "$TOP"
if grep -qE '^\S+\s+/tmp\s' /etc/fstab; then
    echo "  [-] /tmp already in fstab (already done)"
else
    echo "UUID=$ROOT_UUID /tmp btrfs defaults,discard=async,space_cache=v2,subvol=@tmp,nofail 0 0" >> /etc/fstab
    echo "  [+] /tmp mounts @tmp from the next boot"
fi

# Disable COW for database directories
for dir in /var/lib/postgresql /var/lib/typesense; do
    mkdir -p "$dir"
    chattr +C "$dir" || true
done
echo "  [+] COW disabled for database directories"
