#!/bin/bash
# Privileged helper for roost-backup. Run via sudo, not directly.
# Performs btrfs receive, subvolume delete, and rename within /backup/roost/ only.
set -euo pipefail

BACKUP_DIR="/backup/roost"

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    receive)
        # Stdin: btrfs send stream
        btrfs receive "$BACKUP_DIR/"
        ;;
    rename)
        # Args: rename <from> <to> (names only, not paths)
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "Usage: $0 rename <from> <to>"
        [[ "$2" != */* ]] || die "Name must not contain slashes: $2"
        [[ "$3" != */* ]] || die "Name must not contain slashes: $3"
        mv "$BACKUP_DIR/$2" "$BACKUP_DIR/$3"
        ;;
    delete)
        # Args: delete <name> (name only, not path)
        [ -n "${2:-}" ] || die "Usage: $0 delete <name>"
        [[ "$2" != */* ]] || die "Name must not contain slashes: $2"
        btrfs subvolume delete "$BACKUP_DIR/$2"
        ;;
    *)
        die "Usage: $0 {receive|rename <from> <to>|delete <name>}"
        ;;
esac
