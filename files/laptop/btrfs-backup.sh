#!/bin/bash
# Pull btrfs snapshots from roost server to local backup.
# Runs on the LAPTOP via systemd timer (roost-backup.timer).
#
# Backs up two snapper configs, each into its own set of subvolumes in $BACKUP_DIR:
#   root        -> snapshot-<N>     (the server root filesystem)
#   roost-data  -> roost-data-<N>   (the Hetzner volume: docker + the notion mirror)
# Each config carries its own incremental-parent state file; the flat naming keeps
# the privileged helper's no-subdir contract (btrfs-backup-helper.sh) intact.
set -euo pipefail

SERVER_HOST="${ROOST_SERVER:?set ROOST_SERVER or configure in service file}"
SERVER_USER="${ROOST_USER:?set ROOST_USER or configure in service file}"
BACKUP_DIR="${ROOST_BACKUP_DIR:-/backup/roost}"
STATE_DIR="$HOME/.local/state/roost-backup"
NTFY_URL="${ROOST_NTFY_URL:-}"
KEEP_COUNT="${ROOST_BACKUP_KEEP:-7}"

SSH_TARGET="$SERVER_USER@$SERVER_HOST"
LOG_TAG="roost/backup"
HELPER=/usr/local/bin/roost-backup-helper

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
Backs up both the server root filesystem and the roost-data volume.

Options:
  --help       Show this help message
  --dry-run    Show what would be done without making changes
  --full       Force a full (non-incremental) send

Environment variables:
  ROOST_SERVER       Server hostname (required, set via service file)
  ROOST_USER         SSH user (required, set via service file)
  ROOST_BACKUP_DIR   Local btrfs backup path (default: /backup/roost)
  ROOST_NTFY_URL     ntfy URL for failure alerts (optional)
  ROOST_BACKUP_KEEP  Number of snapshots to keep per config (default: 7)
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

# Back up one snapper config via incremental (or full) btrfs send/receive.
#   $1 config      snapper config name (root, roost-data)
#   $2 snap_base   server dir holding <N>/snapshot (/.snapshots, /mnt/roost-data/.snapshots)
#   $3 prefix      local subvol name prefix (snapshot, roost-data) -- no slashes (helper contract)
#   $4 state_file  local file recording the last received snapshot number
backup_config() {
    local config="$1" snap_base="$2" prefix="$3" state_file="$4"
    local raw_list newest parent dest_name stale existing count prune_count old i

    log "[$config] Listing snapshots on $SERVER_HOST..."
    raw_list=$(ssh "$SSH_TARGET" "sudo snapper -c $config --csvout --no-headers list --columns number,type,description") \
        || die "[$config] Failed to list snapshots on $SERVER_HOST"

    # Newest timeline snapshot (type=single, description=timeline)
    newest=""
    while IFS=',' read -r num _ desc; do
        [ "$desc" = "timeline" ] || continue
        newest="$num"
    done <<< "$raw_list"

    if [ -z "$newest" ]; then
        warn "[$config] No timeline snapshots found on server; skipping"
        return 0
    fi
    log "[$config] Newest server snapshot: #$newest"

    # Parent for incremental send: last received, if it still exists on the server
    parent=""
    if [ "$FORCE_FULL" = false ] && [ -f "$state_file" ]; then
        parent=$(cat "$state_file")
        if ! echo "$raw_list" | grep -q "^${parent},"; then
            warn "[$config] Parent snapshot #$parent no longer on server; falling back to full send"
            parent=""
        fi
    fi

    if [ "$parent" = "$newest" ]; then
        log "[$config] Already up to date (snapshot #$newest)"
        return 0
    fi

    dest_name="${prefix}-${newest}"
    if [ "$DRY_RUN" = true ]; then
        if [ -n "$parent" ]; then
            log "[dry-run][$config] Would incremental send #$parent -> #$newest to $BACKUP_DIR/$dest_name"
        else
            log "[dry-run][$config] Would full send #$newest to $BACKUP_DIR/$dest_name"
        fi
        return 0
    fi

    # Clean up stale subvolumes from a failed previous run
    for stale in "snapshot" "$dest_name"; do
        if [ -d "$BACKUP_DIR/$stale" ]; then
            log "[$config] Removing stale $BACKUP_DIR/$stale from previous attempt..."
            sudo "$HELPER" delete "$stale" || die "[$config] Failed to remove stale $stale"
        fi
    done

    # Clean up a partial receive on unexpected exit
    trap 'if [ -d "$BACKUP_DIR/snapshot" ]; then sudo "$HELPER" delete snapshot 2>/dev/null || true; fi' EXIT

    if [ -n "$parent" ]; then
        log "[$config] Incremental send: #$parent -> #$newest"
        ssh "$SSH_TARGET" "sudo btrfs send -p ${snap_base}/${parent}/snapshot ${snap_base}/${newest}/snapshot" \
            | sudo "$HELPER" receive \
            || die "[$config] Incremental btrfs send/receive failed (#$parent -> #$newest)"
    else
        log "[$config] Full send: #$newest"
        ssh "$SSH_TARGET" "sudo btrfs send ${snap_base}/${newest}/snapshot" \
            | sudo "$HELPER" receive \
            || die "[$config] Full btrfs send/receive failed (#$newest)"
    fi

    # btrfs receive creates a subvolume named "snapshot"; rename to include the number
    if [ -d "$BACKUP_DIR/snapshot" ]; then
        sudo "$HELPER" rename snapshot "$dest_name"
    fi

    # Update state file and clear trap (receive succeeded)
    echo "$newest" > "$state_file"
    trap - EXIT
    log "[$config] Backup complete: #$newest -> $BACKUP_DIR/$dest_name"

    # Prune old snapshots for this config (keep KEEP_COUNT most recent)
    mapfile -t existing < <(
        find "$BACKUP_DIR" -maxdepth 1 -name "${prefix}-*" -type d \
            | sed "s|.*/${prefix}-||" | sort -n
    )
    count=${#existing[@]}
    if [ "$count" -gt "$KEEP_COUNT" ]; then
        prune_count=$((count - KEEP_COUNT))
        log "[$config] Pruning $prune_count old snapshot(s) (keeping $KEEP_COUNT)..."
        for ((i = 0; i < prune_count; i++)); do
            old="${existing[$i]}"
            log "[$config] Deleting $BACKUP_DIR/${prefix}-$old"
            sudo "$HELPER" delete "${prefix}-$old" \
                || warn "[$config] Failed to delete ${prefix}-$old"
        done
    fi
}

# Root filesystem first (existing backups keep their snapshot-<N> names), then the volume.
backup_config root       /.snapshots                "snapshot"   "$STATE_DIR/last-snapshot"
backup_config roost-data /mnt/roost-data/.snapshots "roost-data" "$STATE_DIR/last-snapshot-roost-data"

log "Done."
