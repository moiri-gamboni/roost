#!/bin/bash
# Poll Hetzner for server type availability. Sends an ntfy notification
# when the target type can be created. Optionally runs a command (e.g.
# the provisioning script) when availability is detected.
#
# Usage:
#   ./hetzner-watch.sh                           # one-shot check
#   ./hetzner-watch.sh --poll 300                # poll until available
#   ./hetzner-watch.sh --poll 300 --run CMD...   # poll, then run CMD
#
# Auth: uses an active hcloud context, or set HCLOUD_TOKEN.
#
# Environment:
#   WATCH_TYPE         Server type to watch for (default: cx43)
#   WATCH_LOCATION     Location to check (default: empty = any)
#   NTFY_URL           ntfy endpoint (default: http://localhost:2586/hetzner-watch)
set -uo pipefail

WATCH_TYPE="${WATCH_TYPE:-cx43}"
WATCH_LOCATION="${WATCH_LOCATION:-}"
NTFY_URL="${NTFY_URL:-http://localhost:2586/hetzner-watch}"
POLL_INTERVAL=0
RUN_CMD=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        --run)  shift; RUN_CMD=("$@"); break ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if ! command -v hcloud &>/dev/null; then
    echo "Error: hcloud CLI not found"
    exit 1
fi

if ! hcloud server-type list -o noheader &>/dev/null; then
    echo "Error: hcloud not authenticated (set HCLOUD_TOKEN or create a context)"
    exit 1
fi

AVAILABLE_IN=""

check_availability() {
    local type_id
    type_id=$(hcloud server-type describe "$WATCH_TYPE" -o json 2>/dev/null | jq -r '.id // empty')

    if [ -z "$type_id" ]; then
        echo "Error: unknown server type '$WATCH_TYPE'" >&2
        return 1
    fi

    local available_locations
    available_locations=$(hcloud datacenter list -o json \
        | jq -r --argjson id "$type_id" \
            '.[] | select(.server_types.available | index($id)) | .location.name' \
        | sort -u)

    if [ -z "$available_locations" ]; then
        return 1
    fi

    if [ -n "$WATCH_LOCATION" ]; then
        echo "$available_locations" | grep -q "^${WATCH_LOCATION}$" || return 1
    fi

    AVAILABLE_IN=$(echo "$available_locations" | paste -sd, -)
    return 0
}

notify() {
    local loc_msg="${AVAILABLE_IN:-${WATCH_LOCATION:-any location}}"
    local body="$WATCH_TYPE is now available in: $loc_msg"
    [ ${#RUN_CMD[@]} -gt 0 ] && body="$body. Running: ${RUN_CMD[*]}"
    curl -s "$NTFY_URL" \
        -H "Title: Hetzner $WATCH_TYPE available" \
        -H "Priority: high" \
        -H "Tags: white_check_mark" \
        -d "$body"
}

echo "Watching for $WATCH_TYPE availability${WATCH_LOCATION:+ in $WATCH_LOCATION}..."

while true; do
    if check_availability; then
        echo "Available in: $AVAILABLE_IN"
        notify
        if [ ${#RUN_CMD[@]} -gt 0 ]; then
            echo "Running: ${RUN_CMD[*]}"
            if "${RUN_CMD[@]}"; then
                curl -s "$NTFY_URL" \
                    -H "Title: $WATCH_TYPE server ready" \
                    -H "Priority: urgent" \
                    -H "Tags: rocket" \
                    -d "Command succeeded: ${RUN_CMD[*]}"
            else
                curl -s "$NTFY_URL" \
                    -H "Title: $WATCH_TYPE provisioning failed" \
                    -H "Priority: urgent" \
                    -H "Tags: warning" \
                    -d "Command failed (exit $?): ${RUN_CMD[*]}"
            fi
        fi
        exit 0
    fi

    if [ "$POLL_INTERVAL" -eq 0 ]; then
        echo "Not available."
        exit 1
    fi

    echo "$(date '+%H:%M:%S') Not available. Checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done
