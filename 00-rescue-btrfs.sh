#!/bin/bash
# Convert ext4 root filesystem to btrfs. Run in Hetzner rescue mode.
#
# Usage: bash 00-rescue-btrfs.sh [device]
#   Default device: /dev/sda1
set -euo pipefail

LOGFILE="/tmp/rescue-btrfs-$(date +%Y-%m-%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

DISK="${1:-/dev/sda1}"

echo "============================================"
echo "  btrfs Conversion: $DISK"
echo "============================================"
echo ""
echo "This will convert $DISK from ext4 to btrfs."
echo "The server must be in Hetzner rescue mode."
echo ""
read -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# Ensure btrfs tools are available
if ! command -v btrfs-convert &>/dev/null; then
    echo "Installing btrfs-progs..."
    apt-get update -qq && apt-get install -y -qq btrfs-progs
fi

# Ensure disk is not mounted
umount "$DISK" 2>/dev/null || true

echo ""
echo "[1/6] Checking filesystem..."
e2fsck -f "$DISK"

echo ""
echo "[2/6] Converting ext4 to btrfs (this may take a few minutes)..."
btrfs-convert "$DISK"

echo ""
echo "[3/6] Mounting and creating @rootfs subvolume..."
mount -o discard=async,space_cache=v2 "$DISK" /mnt
btrfs subvolume create /mnt/@rootfs

echo "[4/6] Moving files into subvolume..."
cd /mnt
for item in *; do
    [ "$item" = "@rootfs" ] && continue
    mv "$item" @rootfs/
done
btrfs subvolume set-default /mnt/@rootfs

echo ""
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

echo ""
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

echo ""
echo "============================================"
echo "  Conversion complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Disable rescue mode in the Hetzner Console"
echo "  2. Reboot the server"
echo "  3. SSH in and verify: btrfs filesystem show /"
echo ""
