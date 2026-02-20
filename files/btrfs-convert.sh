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
# e2fsck returns 1 when it corrects errors and 2 when it corrects errors and
# suggests a reboot. Both are success for our purposes; only 4+ means real failure.
e2fsck -fy "$DISK" || { rc=$?; [ "$rc" -lt 4 ] || exit "$rc"; }

echo "[2/6] Converting ext4 to btrfs (this may take a few minutes)..."
btrfs-convert "$DISK"

echo "[3/7] Mounting and creating subvolumes..."
mount -o discard=async,space_cache=v2 "$DISK" /mnt
btrfs subvolume create /mnt/@rootfs
btrfs subvolume create /mnt/@swap

echo "[4/7] Moving files into subvolume..."
cd /mnt
shopt -s dotglob
for item in *; do
    [ "$item" = "@rootfs" ] && continue
    [ "$item" = "@swap" ] && continue
    mv "$item" @rootfs/
done
btrfs subvolume set-default /mnt/@rootfs

echo "[5/7] Updating fstab..."
DISK_UUID=$(blkid -s UUID -o value "$DISK")

# Replace the root mount line
if grep -q "UUID=${DISK_UUID}" /mnt/@rootfs/etc/fstab; then
    sed -i "s|^UUID=${DISK_UUID}.*|UUID=${DISK_UUID} / btrfs defaults,discard=async,space_cache=v2,subvol=@rootfs 0 0|" /mnt/@rootfs/etc/fstab
else
    # Fallback: match on mount point
    sed -i "s|^\S\+\s\+/\s\+ext4\s\+\S\+\s\+[0-9]\+\s\+[0-9]\+|UUID=${DISK_UUID} / btrfs defaults,discard=async,space_cache=v2,subvol=@rootfs 0 0|" /mnt/@rootfs/etc/fstab
fi

# Add @swap subvolume mount (swap.sh will create the swap file inside it)
echo "UUID=${DISK_UUID} /swap btrfs defaults,subvol=@swap 0 0" >> /mnt/@rootfs/etc/fstab

echo "[6/7] Creating /swap mount point..."
mkdir -p /mnt/@rootfs/swap

echo "New fstab entries:"
grep -E '^\S+\s+/(swap\s|\s)' /mnt/@rootfs/etc/fstab

echo "[7/7] Reinstalling GRUB for btrfs..."

# Remount the subvolume directly at /mnt so the chroot root matches the mount
# point in /proc/self/mountinfo. This lets grub-probe resolve / to the device.
cd /
umount /mnt
mount -o subvol=@rootfs,discard=async,space_cache=v2 "$DISK" /mnt

mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run

# Mount EFI partition if present
EFI_PART=$(blkid -t TYPE=vfat -o device 2>/dev/null || true)
if [ -n "$EFI_PART" ] && [ -d /mnt/boot/efi ]; then
    mount "$EFI_PART" /mnt/boot/efi
    echo "Mounted EFI partition $EFI_PART"
fi

PARENT_DISK="${DISK%[0-9]*}"
chroot /mnt /bin/bash -c "
    set -euo pipefail
    update-initramfs -u
    grub-install $PARENT_DISK
    if [ -d /boot/efi ]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram
    fi
    update-grub
"

# Cleanup mounts
[ -n "$EFI_PART" ] && umount /mnt/boot/efi 2>/dev/null || true
umount /mnt/run
umount /mnt/sys
umount /mnt/proc
umount /mnt/dev/pts
umount /mnt/dev
cd /
umount /mnt

echo "btrfs conversion complete."
