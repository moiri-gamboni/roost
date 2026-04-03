#!/bin/bash
# Watch ~/drop/ and auto-sync to roost server.
# Runs on the LAPTOP via systemd user service (drop-watch.service).
set -euo pipefail

SERVER_HOST="${ROOST_SERVER:-roost}"
SERVER_USER="${ROOST_USER:?set ROOST_USER or configure in service file}"
ROOST_DIR_NAME="${ROOST_DIR_NAME:-roost}"
DROP_DIR="${HOME}/drop"

usage() {
    cat <<'EOF'
Usage: drop-watch [OPTIONS]

Watch ~/drop/ for changes and rsync to the roost server.

Options:
  --help    Show this help message

Environment variables:
  ROOST_SERVER  Server hostname (default: roost)
  ROOST_USER    SSH user (required, set via service file)
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --help) usage ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

SSH_TARGET="$SERVER_USER@$SERVER_HOST"
RSYNC_OPTS=(-avz --delete -e ssh)

mkdir -p "$DROP_DIR"

do_sync() {
    rsync "${RSYNC_OPTS[@]}" "$DROP_DIR/" "$SSH_TARGET:~/${ROOST_DIR_NAME}/drop/"
}

# Initial sync
echo "Initial sync of $DROP_DIR to $SSH_TARGET:~/drop/..."
do_sync

command -v inotifywait >/dev/null || { echo "inotifywait not found; install inotify-tools" >&2; exit 1; }

echo "Watching $DROP_DIR for changes..."
inotifywait -mrq -e create -e modify -e delete -e move "$DROP_DIR" |
while read -r _dir _events _file; do
    # Debounce: consume all events that arrive within 2 seconds
    while read -r -t 2 _dir2 _events2 _file2; do :; done
    echo "Change detected, syncing..."
    do_sync || echo "Sync failed, will retry on next change" >&2
done

# inotifywait exited unexpectedly
exit 1
