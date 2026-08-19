#!/bin/bash
# Weekly btrfs data-chunk compaction (Sunday 2:30am via cron-roost).
#
# btrfs fills the device with chunk allocations df never shows: data chunks
# part-emptied by deletions keep their allocation, and once allocation reaches
# the device edge the metadata pool can no longer grow — the next metadata
# spike aborts the transaction and force-flips the fs read-only (2026-08-19:
# root went RO this way at df=75%). Relocating part-empty data chunks returns
# their slack to the unallocated pool. Data chunks only: balancing metadata
# would shrink the very pool this protects; dlimit bounds the weekly I/O.
HOOK_DROP_TO_SUDO_USER=1
source "$(dirname "$0")/../lib/_hook-env.sh"

unalloc_gib() {
    sudo -n btrfs filesystem usage -b "$1" 2>/dev/null |
        awk '/Device unallocated:/ {printf "%d", $3 / 1024^3}'
}

for mnt in / /mnt/roost-data; do
    mountpoint -q "$mnt" || continue
    before=$(unalloc_gib "$mnt")
    if out=$(sudo -n btrfs balance start -dusage=50 -dlimit=30 "$mnt" 2>&1); then
        logger -t "$_HOOK_TAG" "$mnt: $out (unallocated ${before}GiB -> $(unalloc_gib "$mnt")GiB)"
    else
        logger -t "$_HOOK_TAG" "FAIL $mnt: $out"
        ntfy_send -t "btrfs balance failed" -p "high" "$mnt: $out"
    fi
done
