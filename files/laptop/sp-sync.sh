#!/bin/bash
# Sync SuperProductivity to the server's time-tracking log, so the morning
# planning session has yesterday's real hours with the laptop closed.
# Server side: ~/roost/apart-research/workspace/timetracking/sp/ (days/,
# sync.json, archive/), reached through a key the server restricts to
# write-only rsync into that one directory (rrsync -wo).
#
# Runs on the LAPTOP as sp-sync@<trigger>.service (systemd user units):
#   sp-sync.path   on every new SP backup file: about every 5 minutes while SP
#                  runs, never while it is closed. SP writes its data no more
#                  often than that, so the server is at most one write behind,
#                  and nothing is left to catch at shutdown.
#   sp-sync.timer  15-minute fallback.
# Either way the run is a no-op when SP's newest backup and op log are what
# the last good push already sent, so an idle SP costs nothing.
#
# Each run extracts the whole covered history into the archive (a hand edit to
# any day is picked up, not only recent ones), renders one export folder per
# day from it (python -m sp.days), and pushes the folders and sync.json. The
# full archive follows at most hourly. Pushes never delete on the server.
#
# A failed push (offline, server down) is retried by the next trigger. The run
# exits non-zero, and so ntfys through OnFailure, only on the third failure in
# a row and then at most every 6 hours; a day the renderer refuses (its new
# render would hold fewer ticks than the folder already sent) alerts at once.
set -euo pipefail

TRIGGER="${1:-manual}"
SERVER_HOST="${ROOST_SERVER:?set ROOST_SERVER (the unit file does)}"
SERVER_USER="${ROOST_USER:?set ROOST_USER (the unit file does)}"
EXTRACT_DIR="${SP_EXTRACT_DIR:-$HOME/Code/superproductivity-extract}"
ARCHIVE="${SP_ARCHIVE:-$HOME/.local/share/sp-archive}"
STATE="${SP_SYNC_STATE:-$HOME/.local/state/sp-sync}"
KEY="${SP_SYNC_KEY:-$HOME/.ssh/sp-sync}"
ARCHIVE_EVERY="${SP_ARCHIVE_PUSH_EVERY:-3600}"
SP_BACKUPS="${SP_BACKUPS_DIR:-$HOME/snap/superproductivity/current/.config/superProductivity/backups}"
SP_IDB="${SP_IDB_DIR:-$HOME/snap/superproductivity/common/.config/superProductivity/IndexedDB}"
PY="$EXTRACT_DIR/.venv/bin/python"

log() { echo "sp-sync[$TRIGGER]: $*"; }
# A state file holding a number, or 0 when it is missing or holds anything else.
num() { local v=0; [ -f "$1" ] && v=$(< "$1"); [[ $v =~ ^[0-9]+$ ]] || v=0; echo "$v"; }

mkdir -p "$STATE/outbox/days"
exec 9>"$STATE/lock"
# A save that lands while a run is pushing would be stranded by skipping: the
# next trigger may be SP's next write, five minutes off, or never if the lid
# closes first. So a path or manual run waits for the lock and then pushes the
# newer data; only the fallback timer, which has nothing new to bring, skips.
if [ "$TRIGGER" = timer ]; then
    flock -n 9 || { log "another run holds the lock; this one is skipped"; exit 0; }
elif ! flock -w 300 9; then
    log "the lock was held for 5 minutes; skipping"
    exit 0
fi

# Exit 0 while failures are transient, 1 (which ntfys via OnFailure) on the
# third in a row, then at most every 6 hours until a push succeeds again.
fail() {
    local n now last
    n=$(( $(num "$STATE/failures") + 1 ))
    echo "$n" > "$STATE/failures"
    log "FAILED ($n in a row): $*"
    now=$(date +%s)
    last=$(num "$STATE/last-alert")
    if (( n >= 3 && now - last >= 21600 )); then
        echo "$now" > "$STATE/last-alert"
        exit 1
    fi
    exit 0
}

# What SP has on disk: the newest backup's content and the op log's files.
# Backups are written every 5 minutes whether or not anything changed, so
# their mtimes alone would make every trigger look like new data.
fingerprint() {
    local newest
    newest=$(find "$SP_BACKUPS" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
    { [ -n "$newest" ] && sha1sum < "$newest"; find "$SP_IDB" -type f -printf '%P %s\n' | sort; } | sha1sum | cut -d' ' -f1
}
fp=$(fingerprint)
last_fp=""
[ -f "$STATE/last-ok-fingerprint" ] && last_fp=$(< "$STATE/last-ok-fingerprint")
if [ "$TRIGGER" != manual ] && [ "$last_fp" = "$fp" ]; then
    log "SP has written nothing new since the last push"
    exit 0
fi

[ -x "$PY" ] || fail "no venv at $EXTRACT_DIR/.venv: run $EXTRACT_DIR/extract.sh once by hand"
start=$("$PY" -c 'import json, sys; print(json.load(open(sys.argv[1]))["windows"][0]["start"])' \
        "$ARCHIVE/derived/extraction-summary.json" 2>&1) || start=""
[[ $start =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || fail "$ARCHIVE declares no covered window; seed it first (header of install-sp-sync.sh)"

# The whole covered history, so a total edited for any day reaches the server.
# The run's own output is scratch (the archive keeps what matters), so sync
# runs do not pile up under the archive's runs/.
rm -rf "$STATE/run"
rc=0
"$EXTRACT_DIR/extract.sh" --from "$start" --to "$(date +%F)" --archive "$ARCHIVE" --out "$STATE/run" \
    > "$STATE/extract.log" 2>&1 || rc=$?
(( rc == 0 )) || fail "extract exited $rc; see $STATE/extract.log"

rc=0
(cd "$EXTRACT_DIR" && "$PY" -m sp.days "$ARCHIVE" "$STATE/outbox/days") > "$STATE/days.log" 2>&1 || rc=$?
(( rc == 0 || rc == 3 )) || fail "day render exited $rc; see $STATE/days.log"
refused=$(grep -h '^REFUSED' "$STATE/days.log" || true)
log "$(head -n 1 "$STATE/days.log")"

sp_running=false
pgrep -xi 'super ?productivi(ty)?' > /dev/null && sp_running=true
"$PY" - "$ARCHIVE" "$STATE/outbox" "$TRIGGER" "$sp_running" "$SP_BACKUPS" \
    "$(git -C "$EXTRACT_DIR" rev-parse --short HEAD 2>&1)" "$(hostname)" <<'EOF'
import datetime, glob, json, os, sys
archive, outbox, trigger, running, backups, sha, host = sys.argv[1:]
local = lambda ts: datetime.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")
last_op = 0
with open(os.path.join(archive, "raw", "indexeddb", "ops-log.jsonl")) as fh:
    for line in fh:
        t = (json.loads(line).get("op") or {}).get("t") or 0
        last_op = max(last_op, t)
snaps = glob.glob(os.path.join(backups, "*.json"))
days = sorted(d for d in os.listdir(os.path.join(outbox, "days")) if not d.startswith("."))
sync = {
    "synced_at": local(datetime.datetime.now().timestamp()),
    "trigger": trigger,
    "sp_running": running == "true",
    "last_op_at": local(last_op / 1000) if last_op else None,
    "last_backup_at": local(max(os.path.getmtime(p) for p in snaps)) if snaps else None,
    "days": {"first": days[0] if days else None, "last": days[-1] if days else None, "count": len(days)},
    "host": host,
    "extract_sha": sha,
}
tmp = os.path.join(outbox, ".sync.json.tmp")
with open(tmp, "w") as fh:
    json.dump(sync, fh, indent=2)
    fh.write("\n")
os.replace(tmp, os.path.join(outbox, "sync.json"))
EOF

# ControlPath=none: the laptop's Host block shares one connection (ControlMaster),
# and riding it would push with the full-access key instead of this restricted one.
ssh_cmd="ssh -i $KEY -o IdentitiesOnly=yes -o ControlPath=none -o ControlMaster=no -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=20"
target="$SERVER_USER@$SERVER_HOST"
# Paths are relative to the directory rrsync confines the key to (…/timetracking/sp).
rsync -rt --exclude '.*' -e "$ssh_cmd" "$STATE/outbox/days/" "$target:days/" > "$STATE/push.log" 2>&1 \
    || fail "push of days/ failed; see $STATE/push.log"
rsync -t -e "$ssh_cmd" "$STATE/outbox/sync.json" "$target:sync.json" >> "$STATE/push.log" 2>&1 \
    || fail "push of sync.json failed; see $STATE/push.log"

now=$(date +%s)
last_archive=$(num "$STATE/last-archive-push")
if (( now - last_archive >= ARCHIVE_EVERY )); then
    # runs/ holds whole one-off exports; the op union and runs.jsonl are the archive.
    if rsync -rt --exclude 'runs/' -e "$ssh_cmd" "$ARCHIVE/" "$target:archive/" >> "$STATE/push.log" 2>&1; then
        echo "$now" > "$STATE/last-archive-push"
    else
        log "archive push failed (days/ went up); the next run retries it"
    fi
fi

echo "$fp" > "$STATE/last-ok-fingerprint"
echo 0 > "$STATE/failures"
log "pushed (sp_running=$sp_running)"

if [ -n "$refused" ]; then
    log "$refused"
    exit 1
fi
