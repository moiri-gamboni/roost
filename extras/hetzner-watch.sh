#!/bin/bash
# Poll Hetzner for server type availability. Sends an ntfy notification
# when the target type can be created, then exits.
#
# Usage:
#   ./hetzner-watch.sh                     # one-shot check
#   ./hetzner-watch.sh --poll 300          # check every 5 minutes until available
#
# Environment (or source .env):
#   HCLOUD_TOKEN       Hetzner API token (required)
#   WATCH_TYPE         Server type to watch for (default: cx43)
#   WATCH_LOCATION     Location to check (default: empty = any)
#   NTFY_URL           ntfy endpoint (default: http://localhost:2586/hetzner-watch)
set -uo pipefail

WATCH_TYPE="${WATCH_TYPE:-cx43}"
WATCH_LOCATION="${WATCH_LOCATION:-}"
NTFY_URL="${NTFY_URL:-http://localhost:2586/hetzner-watch}"
PROBE_NAME="capacity-probe-$$"
POLL_INTERVAL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${HCLOUD_TOKEN:-}" ]; then
    echo "Error: HCLOUD_TOKEN is required"
    exit 1
fi
export HCLOUD_TOKEN

check_availability() {
    local args=(
        --name "$PROBE_NAME"
        --type "$WATCH_TYPE"
        --image ubuntu-24.04
        --start-after-create false
    )
    [ -n "$WATCH_LOCATION" ] && args+=(--location "$WATCH_LOCATION")

    if hcloud server create "${args[@]}" 2>/dev/null; then
        # Available! Delete the probe server immediately.
        hcloud server delete "$PROBE_NAME" 2>/dev/null
        return 0
    fi
    return 1
}

notify() {
    local loc_msg="${WATCH_LOCATION:-any location}"
    curl -s "$NTFY_URL" \
        -H "Title: Hetzner $WATCH_TYPE available" \
        -H "Priority: high" \
        -H "Tags: white_check_mark" \
        -d "$WATCH_TYPE is now available in $loc_msg. Upgrade with: hcloud server change-type --server <name> --type $WATCH_TYPE --keep-disk"
}

cleanup() {
    hcloud server delete "$PROBE_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "Watching for $WATCH_TYPE availability${WATCH_LOCATION:+ in $WATCH_LOCATION}..."

while true; do
    if check_availability; then
        echo "Available!"
        notify
        exit 0
    fi

    if [ "$POLL_INTERVAL" -eq 0 ]; then
        echo "Not available."
        exit 1
    fi

    echo "$(date '+%H:%M:%S') Not available. Checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done
