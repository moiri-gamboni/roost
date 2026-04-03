#!/bin/bash
# Pull btrfs snapshots from roost server to local backup.
# Runs on the LAPTOP via systemd timer (roost-backup.timer).
set -euo pipefail

SERVER_HOST="${ROOST_SERVER:-roost}"
SERVER_USER="${ROOST_USER:?set ROOST_USER or configure in service file}"
BACKUP_DIR="${ROOST_BACKUP_DIR:-/backup/roost}"
STATE_DIR="$HOME/.local/state/roost-backup"
NTFY_URL="${ROOST_NTFY_URL:-}"
KEEP_COUNT="${ROOST_BACKUP_KEEP:-7}"

STATE_FILE="$STATE_DIR/last-snapshot"
SSH_TARGET="$SERVER_USER@$SERVER_HOST"
LOG_TAG="roost/backup"

log()  { logger -t "$LOG_TAG" "$*"; echo "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "WARNING: $*" >&2; }
die()  { logger -t "$LOG_TAG" -p user.err "$*"; echo "ERROR: $*" >&2; alert "$*"; exit 1; }

alert() {
    [ -z "$NTFY_URL" ] && return 0
    curl -sS -o /dev/null --max-time 10 \
        -H "Title: roost-backup failed" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        -d "$1" "$NTFY_URL" 2>/dev/null || true
}

usage() {
    cat <<'EOF'
Usage: roost-backup [OPTIONS]

Pull btrfs snapshots from the roost server to a local backup directory.

Options:
  --help       Show this help message
  --dry-run    Show what would be done without making changes
  --full       Force a full (non-incremental) send

Environment variables:
  ROOST_SERVER       Server hostname (default: roost)
  ROOST_USER         SSH user (required, set via service file)
  ROOST_BACKUP_DIR   Local btrfs backup path (default: /backup/roost)
  ROOST_NTFY_URL     ntfy URL for failure alerts (optional)
  ROOST_BACKUP_KEEP  Number of snapshots to keep (default: 7)
EOF
    exit 0
}

DRY_RUN=false
FORCE_FULL=false
for arg in "$@"; do
    case "$arg" in
        --help) usage ;;
        --dry-run) DRY_RUN=true ;;
        --full) FORCE_FULL=true ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# Ensure state and backup directories exist
mkdir -p "$STATE_DIR"
if [ ! -d "$BACKUP_DIR" ]; then
    die "Backup directory $BACKUP_DIR does not exist (must be a btrfs filesystem)"
fi

# List snapper snapshots on server (timeline snapshots only)
log "Listing snapshots on $SERVER_HOST..."
raw_list=$(ssh "$SSH_TARGET" "sudo snapper -c root --csvout --no-headers list --columns number,type,description") \
    || die "Failed to list snapshots on $SERVER_HOST"

# Parse timeline snapshots, pick the newest
newest=""
while IFS=',' read -r num type desc; do
    # Timeline snapshots are type=single with description=timeline
    [ "$desc" = "timeline" ] || continue
    newest="$num"
done <<< "$raw_list"

[ -n "$newest" ] || die "No timeline snapshots found on server"
log "Newest server snapshot: #$newest"

# Determine parent for incremental send
parent=""
if [ "$FORCE_FULL" = false ] && [ -f "$STATE_FILE" ]; then
    parent=$(cat "$STATE_FILE")
    # Verify parent still exists on server
    if ! echo "$raw_list" | grep -q "^${parent},"; then
        warn "Parent snapshot #$parent no longer exists on server, falling back to full send"
        parent=""
    fi
fi

if [ "$parent" = "$newest" ]; then
    log "Already up to date (snapshot #$newest)"
    exit 0
fi

# Perform the send/receive
dest_name="snapshot-${newest}"
if [ "$DRY_RUN" = true ]; then
    if [ -n "$parent" ]; then
        log "[dry-run] Would incremental send #$parent -> #$newest to $BACKUP_DIR/$dest_name"
    else
        log "[dry-run] Would full send #$newest to $BACKUP_DIR/$dest_name"
    fi
else
    HELPER=/usr/local/bin/roost-backup-helper

    # Clean up stale subvolumes from failed previous runs
    for stale in "snapshot" "$dest_name"; do
        if [ -d "$BACKUP_DIR/$stale" ]; then
            log "Removing stale $BACKUP_DIR/$stale from previous attempt..."
            sudo "$HELPER" delete "$stale" || die "Failed to remove stale $stale"
        fi
    done

    # Clean up partial receive on unexpected exit
    trap 'if [ -d "$BACKUP_DIR/snapshot" ]; then sudo "$HELPER" delete snapshot 2>/dev/null || true; fi' EXIT

    if [ -n "$parent" ]; then
        log "Incremental send: #$parent -> #$newest"
        ssh "$SSH_TARGET" "sudo btrfs send -p /.snapshots/${parent}/snapshot /.snapshots/${newest}/snapshot" \
            | sudo "$HELPER" receive \
            || die "Incremental btrfs send/receive failed (#$parent -> #$newest)"
    else
        log "Full send: #$newest"
        ssh "$SSH_TARGET" "sudo btrfs send /.snapshots/${newest}/snapshot" \
            | sudo "$HELPER" receive \
            || die "Full btrfs send/receive failed (#$newest)"
    fi

    # btrfs receive creates a subvolume named "snapshot"; rename to include the number
    if [ -d "$BACKUP_DIR/snapshot" ]; then
        sudo "$HELPER" rename snapshot "$dest_name"
    fi

    # Update state file and clear trap (receive succeeded)
    echo "$newest" > "$STATE_FILE"
    trap - EXIT
    log "Backup complete: #$newest -> $BACKUP_DIR/$dest_name"
fi

# Prune old snapshots (keep KEEP_COUNT most recent)
if [ "$DRY_RUN" = false ]; then
    mapfile -t existing < <(
        find "$BACKUP_DIR" -maxdepth 1 -name 'snapshot-*' -type d \
            | sed 's|.*/snapshot-||' | sort -n
    )
    count=${#existing[@]}
    if [ "$count" -gt "$KEEP_COUNT" ]; then
        prune_count=$((count - KEEP_COUNT))
        log "Pruning $prune_count old snapshot(s) (keeping $KEEP_COUNT)..."
        for ((i = 0; i < prune_count; i++)); do
            old="${existing[$i]}"
            log "Deleting $BACKUP_DIR/snapshot-$old"
            sudo "$HELPER" delete "snapshot-$old" \
                || warn "Failed to delete snapshot-$old"
        done
    fi
fi

log "Done."
