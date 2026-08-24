#!/bin/bash
# Pull btrfs snapshots from roost server to local backup.
# Runs on the LAPTOP via systemd timer (roost-backup.timer).
#
# Backs up two snapper configs, each into its own set of subvolumes in $BACKUP_DIR:
#   root        -> snapshot-<N>     (the server root filesystem)
#   roost-data  -> roost-data-<N>   (the Hetzner volume: docker + the notion mirror)
# Each config carries its own incremental-parent state file; the flat naming keeps
# the privileged helper's no-subdir contract (btrfs-backup-helper.sh) intact.
# Retention per config: 5 restore points — the newest of each of the 3 most
# recent distinct days (the newest overall is the incremental parent), plus the
# newest of the previous ISO week and of the previous month. Days are bucketed
# by RECEIVE time from a script-maintained index: btrfs otime is unusable here,
# an incremental receive inherits the clone ancestor's.
#
# After each successful receive the new parent is pinned server-side
# (`snapper modify --cleanup-algorithm '' --userdata pin=roost-backup`) and the
# previous one released, so a multi-day laptop-off gap can't let snapper's
# 24-hourly timeline cleanup age the parent out and force a ~113 GiB full resend.
#
# Runs with no ssh-agent, so the key comes from ROOST_SSH_KEY (ssh -i +
# IdentitiesOnly; the installer sets it when ~/.ssh/roost-backup exists) rather
# than an ~/.ssh/config stanza: that key is `restrict`ed in the server's
# authorized_keys, and a `Host roost` IdentityFile would strip port forwarding
# from every interactive session too.
set -euo pipefail

# Direct terminal runs lack the ROOST_* env the systemd unit carries; import it
# from the installed unit so `roost-backup` just works interactively.
if [ -z "${ROOST_SERVER:-}" ] && command -v systemctl >/dev/null; then
    while IFS= read -r kv; do export "${kv?}"; done < <(
        systemctl show roost-backup.service -p Environment --value | tr ' ' '\n' | grep '^ROOST_' || true
    )
fi

SERVER_HOST="${ROOST_SERVER:?set ROOST_SERVER or configure in service file}"
SERVER_USER="${ROOST_USER:?set ROOST_USER or configure in service file}"
BACKUP_DIR="${ROOST_BACKUP_DIR:-/backup/roost}"
STATE_DIR="$HOME/.local/state/roost-backup"
RECEIVED_INDEX="$STATE_DIR/received.tsv"
NTFY_URL="${ROOST_NTFY_URL:-}"
SSH_KEY="${ROOST_SSH_KEY:-}"

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
Keeps 5 restore points per config: the newest snapshot of each of the 3
most recent days, plus the newest from the previous ISO week and from the
previous month (last completed week / month end-states).

Run directly in a terminal for a progress meter (pv if installed, dd
otherwise); the ROOST_* environment is imported from the installed
roost-backup.service unit when not already set.

Options:
  --help       Show this help message
  --dry-run    Show what would be done without making changes
  --full       Force a full (non-incremental) send

Environment variables:
  ROOST_SERVER       Server hostname (required, set via service file)
  ROOST_USER         SSH user (required, set via service file)
  ROOST_BACKUP_DIR   Local btrfs backup path (default: /backup/roost)
  ROOST_NTFY_URL     ntfy URL for failure alerts (optional)
  ROOST_SSH_KEY      Private key to use (optional; ssh -i + IdentitiesOnly=yes)
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
touch "$RECEIVED_INDEX"
if [ ! -d "$BACKUP_DIR" ]; then
    die "Backup directory $BACKUP_DIR does not exist (must be a btrfs filesystem)"
fi

# Progress meter for the send stream on interactive runs (pv when installed,
# dd otherwise); plain passthrough under the timer so the journal stays clean.
meter() {
    if [ ! -t 2 ]; then
        cat
    elif command -v pv >/dev/null; then
        pv
    else
        dd bs=1M status=progress
    fi
}

# ClearAllForwardings: a data pull needs none, and the backup key is `restrict`ed
# server-side, so a RemoteForward inherited from ~/.ssh/config would only warn.
SSH=(ssh -o ClearAllForwardings=yes)
if [ -n "$SSH_KEY" ]; then
    [ -f "$SSH_KEY" ] || die "ROOST_SSH_KEY=$SSH_KEY does not exist"
    SSH+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi

# Back up one snapper config via incremental (or full) btrfs send/receive.
#   $1 config      snapper config name (root, roost-data)
#   $2 snap_base   server dir holding <N>/snapshot (/.snapshots, /mnt/roost-data/.snapshots)
#   $3 prefix      local subvol name prefix (snapshot, roost-data) -- no slashes (helper contract)
#   $4 state_file  local file recording the last received snapshot number
backup_config() {
    local config="$1" snap_base="$2" prefix="$3" state_file="$4"
    local raw_list newest parent prev_parent dest_name stale

    log "[$config] Listing snapshots on $SERVER_HOST..."
    raw_list=$("${SSH[@]}" "$SSH_TARGET" "sudo snapper -c $config --csvout --no-headers list --columns number,type,description") \
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
    prev_parent=""
    [ -f "$state_file" ] && prev_parent=$(cat "$state_file")
    if [ "$FORCE_FULL" = false ] && [ -n "$prev_parent" ]; then
        parent="$prev_parent"
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
        "${SSH[@]}" "$SSH_TARGET" "sudo btrfs send -p ${snap_base}/${parent}/snapshot ${snap_base}/${newest}/snapshot" \
            | meter | sudo "$HELPER" receive \
            || die "[$config] Incremental btrfs send/receive failed (#$parent -> #$newest)"
    else
        log "[$config] Full send: #$newest"
        "${SSH[@]}" "$SSH_TARGET" "sudo btrfs send ${snap_base}/${newest}/snapshot" \
            | meter | sudo "$HELPER" receive \
            || die "[$config] Full btrfs send/receive failed (#$newest)"
    fi

    # btrfs receive creates a subvolume named "snapshot"; rename to include the number
    if [ -d "$BACKUP_DIR/snapshot" ]; then
        sudo "$HELPER" rename snapshot "$dest_name"
    fi

    # Update state file and clear trap (receive succeeded)
    echo "$newest" > "$state_file"
    trap - EXIT

    # Record the receive time ourselves. Neither btrfs otime nor the subvolume's
    # mtime can be trusted for this: an incrementally received subvolume inherits
    # its clone ancestor's otime (so every incremental off one full send reports
    # the same instant), and mtime is the source directory's mtime carried in the
    # send stream, which only coincidentally tracks when we received it.
    printf '%s\t%s\n' "$dest_name" "$(date +%s)" >> "$RECEIVED_INDEX"

    # Pin the new parent against snapper's timeline cleanup so a multi-day gap
    # before the next run can't age it out and force a full resend, then release
    # the previous parent back to normal aging. Skip the release when the old
    # parent is already gone from the server (raw_list is authoritative).
    "${SSH[@]}" "$SSH_TARGET" "sudo snapper -c $config modify --cleanup-algorithm '' --userdata pin=roost-backup $newest" \
        || warn "[$config] Could not pin #$newest; a >24h gap may force a full resend"
    if [ -n "$prev_parent" ] && [ "$prev_parent" != "$newest" ] \
        && echo "$raw_list" | grep -q "^${prev_parent},"; then
        "${SSH[@]}" "$SSH_TARGET" "sudo snapper -c $config modify --cleanup-algorithm timeline --userdata pin= $prev_parent" \
            || warn "[$config] Could not unpin old parent #$prev_parent; snapper will never clean it up"
    fi

    log "[$config] Backup complete: #$newest -> $BACKUP_DIR/$dest_name"

    prune_config "$config" "$prefix"
}

# Retention (GFS): the newest snapshot of each of the 3 most recent distinct
# days (the newest overall is the incremental parent), plus the newest from a
# previous ISO week and from a previous month -- last completed week / month
# end-states. Ages come from the script-maintained receive index.
prune_config() {
    local config="$1" prefix="$2"
    local -A birth=() keep=() seen_days=()
    local existing num when spec fmt cur slot b kept

    mapfile -t existing < <(
        find "$BACKUP_DIR" -maxdepth 1 -name "${prefix}-*" -type d \
            | sed "s|.*/${prefix}-||" | sort -rn
    )
    [ "${#existing[@]}" -gt 0 ] || return 0
    keep[${existing[0]}]="latest"

    # Ages come from RECEIVED_INDEX, which we write at receive time. Fall back to
    # btrfs otime (via stat %W -- no privilege needed, unlike `btrfs subvolume
    # show`, which sudoers does not permit) only for subvolumes predating the
    # index; warn, because for anything received incrementally that otime is the
    # ancestor full send's, not this snapshot's.
    for num in "${existing[@]}"; do
        when=$(awk -F'\t' -v n="${prefix}-${num}" '$1==n{t=$2} END{print t}' \
                   "$RECEIVED_INDEX") || when=""
        if [ -z "$when" ]; then
            when=$(stat -c %W "$BACKUP_DIR/${prefix}-${num}") || when=""
            case "$when" in 0|-|'') when="" ;; esac
            [ -n "$when" ] && warn "[$config] ${prefix}-$num predates the receive index; using btrfs otime (may be the ancestor full send's)"
        fi
        birth[$num]="$when"
    done

    # Dailies: existing is sorted newest-first, so the first snapshot seen in
    # each of the first 3 distinct day buckets is that day's newest.
    for num in "${existing[@]}"; do
        [ -n "${birth[$num]}" ] || continue
        b=$(date -d "@${birth[$num]}" +%F)
        [ -n "${seen_days[$b]:-}" ] && continue
        [ "${#seen_days[@]}" -ge 3 ] && break
        seen_days[$b]=1
        keep[$num]="${keep[$num]:-}${keep[$num]:+,}daily"
    done

    # %G-%V and %Y-%m compare lexicographically; "< current bucket" means
    # "from a previous week/month". Newest match wins each slot.
    for spec in "%G-%V:$(date +%G-%V):weekly" "%Y-%m:$(date +%Y-%m):monthly"; do
        IFS=: read -r fmt cur slot <<< "$spec"
        for num in "${existing[@]}"; do
            [ -n "${birth[$num]}" ] || continue
            b=$(date -d "@${birth[$num]}" "+$fmt")
            if [[ "$b" < "$cur" ]]; then
                keep[$num]="${keep[$num]:-}${keep[$num]:+,}$slot"
                break
            fi
        done
    done

    kept=""
    for num in "${existing[@]}"; do
        if [ -n "${keep[$num]:-}" ]; then
            kept="$kept ${prefix}-$num(${keep[$num]})"
            continue
        fi
        if [ -z "${birth[$num]}" ]; then
            warn "[$config] Cannot read creation time of ${prefix}-$num; keeping it"
            continue
        fi
        log "[$config] Pruning $BACKUP_DIR/${prefix}-$num"
        sudo "$HELPER" delete "${prefix}-$num" \
            || warn "[$config] Failed to delete ${prefix}-$num"
    done
    log "[$config] Kept:$kept"
}

# Root filesystem first (existing backups keep their snapshot-<N> names), then the volume.
backup_config root       /.snapshots                "snapshot"   "$STATE_DIR/last-snapshot"
backup_config roost-data /mnt/roost-data/.snapshots "roost-data" "$STATE_DIR/last-snapshot-roost-data"

log "Done."
