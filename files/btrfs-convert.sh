#!/bin/bash
# Convert ext4 root partition to btrfs with @rootfs subvolume.
# Run in Hetzner rescue mode. Does NOT source _setup-env.sh (not available).
#
# Usage: bash /tmp/btrfs-convert.sh /dev/sda1
set -euo pipefail

DISK="${1:?Usage: btrfs-convert.sh <device>}"

# Ensure btrfs tools are available
if ! command -v btrfs-convert &>/dev/null; then
    echo "Installing btrfs-progs..."
    apt-get update -qq && apt-get install -y -qq btrfs-progs
fi

# Ensure disk is not mounted
umount "$DISK" 2>/dev/null || true

echo "[1/6] Checking filesystem..."
e2fsck -f "$DISK"

echo "[2/6] Converting ext4 to btrfs (this may take a few minutes)..."
btrfs-convert "$DISK"

echo "[3/6] Mounting and creating @rootfs subvolume..."
mount -o discard=async,space_cache=v2 "$DISK" /mnt
btrfs subvolume create /mnt/@rootfs

echo "[4/6] Moving files into subvolume..."
cd /mnt
shopt -s dotglob
for item in *; do
    [ "$item" = "@rootfs" ] && continue
    mv "$item" @rootfs/
done
btrfs subvolume set-default /mnt/@rootfs

echo "[5/6] Updating fstab..."
DISK_UUID=$(blkid -s UUID -o value "$DISK")

# Replace the root mount line
if grep -q "UUID=${DISK_UUID}" /mnt/@rootfs/etc/fstab; then
    sed -i "s|^UUID=${DISK_UUID}.*|UUID=${DISK_UUID} / btrfs defaults,discard=async,space_cache=v2,subvol=@rootfs 0 0|" /mnt/@rootfs/etc/fstab
else
    # Fallback: match on mount point
    sed -i "s|^\S\+\s\+/\s\+ext4\s\+\S\+\s\+[0-9]\+\s\+[0-9]\+|UUID=${DISK_UUID} / btrfs defaults,discard=async,space_cache=v2,subvol=@rootfs 0 0|" /mnt/@rootfs/etc/fstab
fi

echo "New fstab entry:"
grep -E '^\S+\s+/\s' /mnt/@rootfs/etc/fstab

echo "[6/6] Updating GRUB..."
mount --bind /dev /mnt/@rootfs/dev
mount --bind /proc /mnt/@rootfs/proc
mount --bind /sys /mnt/@rootfs/sys
mount --bind /dev/pts /mnt/@rootfs/dev/pts

chroot /mnt/@rootfs /bin/bash -c "
    update-initramfs -u
    update-grub
"

umount /mnt/@rootfs/dev/pts
umount /mnt/@rootfs/dev
umount /mnt/@rootfs/proc
umount /mnt/@rootfs/sys
cd /
umount /mnt

echo "btrfs conversion complete."
