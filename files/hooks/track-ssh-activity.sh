#!/bin/bash
# Touch the connection-activity marker iff any SSH (port 22) or ET (port 2022)
# connection is currently established. Run from cron every minute.
#
# The marker's mtime is read by agents-cleanup.sh as "last time the user was
# connected to the box." Captures both SSH and Eternal Terminal transports
# without relying on journalctl, group membership, or pty/tty quirks.
set -euo pipefail

HOOK_DIR="$(dirname "$(readlink -f "$0")")"
MARKER="$(dirname "$HOOK_DIR")/last-connection-activity"

if ss -tHn state established '( sport = :22 or sport = :2022 )' 2>/dev/null | grep -q .; then
    touch "$MARKER"
fi
