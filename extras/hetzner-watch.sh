#!/bin/bash
# Poll Hetzner for server type availability. Sends an ntfy notification
# when the target type can be created, or, with --rescale, when an existing
# server can be changed to it. Optionally runs a command when availability
# is detected (e.g. the provisioning script).
#
# Usage:
#   ./hetzner-watch.sh                           # one-shot check
#   ./hetzner-watch.sh --poll 300                # poll until available
#   ./hetzner-watch.sh --poll 300 --run CMD...   # poll, then run CMD
#   ./hetzner-watch.sh --rescale SERVER --dry-run                       # check once, print the plan
#   ./hetzner-watch.sh --poll 300 --rescale SERVER [--upgrade-disk] [--run CMD...]
#
# --run takes the rest of the line, so it goes last.
# --rescale waits for WATCH_TYPE in SERVER's own location (a rescale cannot
# move a server) and runs CMD if given, stopping there if it fails. It then
# shuts SERVER down (if that fails, it stops with the type unchanged), changes
# its type and powers it back on, even if the type change failed. The disk
# keeps its size, so the server can return to its old type later; with
# --upgrade-disk it takes the bigger disk and can never be downgraded. A live
# rescale needs NTFY_URL set to a topic that stays reachable while SERVER is
# down, and refuses to rescale the machine it runs on: the shutdown would
# stop it halfway and leave the server off.
# --dry-run checks once and prints what would run; it runs, notifies and
# changes nothing.
# Exit: 0 available (or done), 1 not available or failed, 2 the check itself
# failed (hcloud's error is printed above).
#
# Auth: uses an active hcloud context, or set HCLOUD_TOKEN.
#
# Environment:
#   WATCH_TYPE         Server type to watch for (default: SERVER_TYPE from ../.env, else cx43)
#   WATCH_LOCATION     Location to check (default: SERVER_LOCATION from ../.env, else any;
#                      --rescale uses the server's)
#   NTFY_URL           ntfy endpoint (default: http://localhost:2586/hetzner-watch)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

WATCH_TYPE="${WATCH_TYPE:-${SERVER_TYPE:-cx43}}"
WATCH_LOCATION="${WATCH_LOCATION:-${SERVER_LOCATION:-}}"
NTFY_SET="${NTFY_URL:+1}"
NTFY_URL="${NTFY_URL:-http://localhost:2586/hetzner-watch}"
SHUTDOWN_TIMEOUT=10m
POLL_INTERVAL=0
RESCALE=""
UPGRADE_DISK=0
DRY_RUN=0
RUN_CMD=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        --rescale) RESCALE="$2"; shift 2 ;;
        --upgrade-disk) UPGRADE_DISK=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --run)  shift; RUN_CMD=("$@"); break ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# A --dry-run typed after --run would become part of CMD and turn the run live.
for arg in "${RUN_CMD[@]}"; do
    if [ "$arg" = --dry-run ]; then
        echo "Error: --dry-run after --run would be passed to CMD; put it before --run" >&2
        exit 1
    fi
done

if ! command -v hcloud >/dev/null; then
    echo "Error: hcloud CLI not found"
    exit 1
fi

if ! hcloud server-type list -o noheader >/dev/null; then
    echo "Error: hcloud not authenticated (set HCLOUD_TOKEN or create a context)"
    exit 1
fi

if ! target_json=$(hcloud server-type describe "$WATCH_TYPE" -o json) || [ -z "$target_json" ]; then
    echo "Error: cannot read server type '$WATCH_TYPE' (unknown type, or see hcloud's error above)" >&2
    exit 1
fi
# `locations` carries the per-location `available` flag; an hcloud too old to
# decode it prints none, which would otherwise read as "not available" forever.
if [ "$(jq -r '.locations | type' <<<"$target_json")" != array ]; then
    echo "Error: this hcloud does not report per-location availability; upgrade hcloud" >&2
    exit 1
fi

if [ -n "$RESCALE" ]; then
    server_json=$(hcloud server describe "$RESCALE" -o json) || exit 1
    SERVER_ID=$(jq -r .id <<<"$server_json")
    CURRENT_TYPE=$(jq -r .server_type.name <<<"$server_json")
    WATCH_LOCATION=$(jq -r .location.name <<<"$server_json")
    echo "$RESCALE: $CURRENT_TYPE in $WATCH_LOCATION, $(jq -r .status <<<"$server_json")"
    if [ "$CURRENT_TYPE" = "$WATCH_TYPE" ]; then
        echo "Error: $RESCALE is already $WATCH_TYPE" >&2
        exit 1
    fi
    # The Hetzner metadata service answers only on a Hetzner server, with its id.
    if [ "$(curl -s -m 2 http://169.254.169.254/hetzner/v1/metadata/instance-id)" = "$SERVER_ID" ]; then
        if [ "$DRY_RUN" = 0 ]; then
            echo "Error: refusing to rescale the server this runs on: its shutdown would stop this script halfway and leave $RESCALE off" >&2
            exit 1
        fi
        echo "Note: this runs on $RESCALE; start the live run from another machine"
    fi
    if [ -z "$NTFY_SET" ]; then
        if [ "$DRY_RUN" = 0 ]; then
            echo "Error: set NTFY_URL for a live rescale, to a topic reachable while $RESCALE is down (not its own ntfy): a failure would otherwise reach nobody" >&2
            exit 1
        fi
        echo "Note: NTFY_URL is unset; a live rescale will refuse to start without it"
    fi
    SHUTDOWN_CMD=(hcloud server shutdown --wait --wait-timeout "$SHUTDOWN_TIMEOUT" "$RESCALE")
    CHANGE_CMD=(hcloud server change-type)
    [ "$UPGRADE_DISK" = 1 ] || CHANGE_CMD+=(--keep-disk)
    CHANGE_CMD+=("$RESCALE" "$WATCH_TYPE")
    POWERON_CMD=(hcloud server poweron "$RESCALE")
fi

AVAILABLE_IN=""

# 0 available, 1 not available, 2 the check failed.
check_availability() {
    local available_locations
    available_locations=$(hcloud server-type describe "$WATCH_TYPE" -o json \
        | jq -r '.locations[] | select(.available) | .name' \
        | sort -u) || return 2

    if [ -z "$available_locations" ]; then
        return 1
    fi

    if [ -n "$WATCH_LOCATION" ]; then
        grep -qx "$WATCH_LOCATION" <<<"$available_locations" || return 1
    fi

    AVAILABLE_IN=$(paste -sd, - <<<"$available_locations")
    return 0
}

ntfy() {  # TITLE PRIORITY TAGS BODY
    curl -sS -f -m 30 -o /dev/null "$NTFY_URL" -H "Title: $1" -H "Priority: $2" -H "Tags: $3" -d "$4" \
        || echo "Warning: the ntfy post to $NTFY_URL failed, so nobody was notified of: $1: $4" >&2
}

notify() {
    local loc_msg="${AVAILABLE_IN:-${WATCH_LOCATION:-any location}}"
    local body="$WATCH_TYPE is now available in: $loc_msg"
    [ -n "$RESCALE" ] && body="$body. Rescaling $RESCALE from $CURRENT_TYPE"
    [ ${#RUN_CMD[@]} -gt 0 ] && body="$body. Running: ${RUN_CMD[*]}"
    ntfy "Hetzner $WATCH_TYPE available" high white_check_mark "$body"
}

monthly_price() {  # TYPE: its gross monthly price in WATCH_LOCATION
    hcloud server-type describe "$1" -o json \
        | jq -r --arg l "$WATCH_LOCATION" '.prices[] | select(.location == $l) | .price_monthly.gross' \
        | awk '{ printf "%.2f", $1 }'
}

print_plan() {
    echo "Dry run: once it is available, this would"
    [ ${#RUN_CMD[@]} -gt 0 ] && echo "  run:    ${RUN_CMD[*]}"
    if [ -n "$RESCALE" ]; then
        echo "  run:    ${SHUTDOWN_CMD[*]}"
        echo "  run:    ${CHANGE_CMD[*]}"
        echo "  run:    ${POWERON_CMD[*]}   (unless it is back up already)"
        echo "  price:  $CURRENT_TYPE $(monthly_price "$CURRENT_TYPE") -> $WATCH_TYPE $(monthly_price "$WATCH_TYPE") per month gross in $WATCH_LOCATION"
    fi
    echo "  notify: $NTFY_URL"
}

# Shut down, change type, power on. Success is judged by the state the server
# ends in, which also sets RESULT for the notification.
rescale() {
    local final
    echo "Shutting down $RESCALE..."
    if ! "${SHUTDOWN_CMD[@]}"; then
        RESULT="Shutting down $RESCALE did not complete (waited up to $SHUTDOWN_TIMEOUT), so its type is unchanged. If it ends up off: hcloud server poweron $RESCALE"
        return 1
    fi
    echo "Changing $RESCALE to $WATCH_TYPE..."
    "${CHANGE_CMD[@]}"
    case "$(hcloud server describe "$RESCALE" -o json | jq -r .status)" in
        running|starting|initializing) ;;
        *) echo "Powering on $RESCALE..."; "${POWERON_CMD[@]}" ;;
    esac
    final=$(hcloud server describe "$RESCALE" -o json | jq -r '.server_type.name + " " + .status')
    case "$final" in
        "$WATCH_TYPE running"|"$WATCH_TYPE starting") RESULT="$RESCALE is now $WATCH_TYPE, ${final#* }"; return 0 ;;
        "") RESULT="$RESCALE's state could not be read after the rescale; check it: hcloud server describe $RESCALE" ;;
        *) RESULT="$RESCALE is ${final% *}, ${final#* } (see the script's output)" ;;
    esac
    return 1
}

if [ -n "$RESCALE" ]; then
    echo "Watching for $WATCH_TYPE availability in $WATCH_LOCATION to rescale $RESCALE..."
else
    echo "Watching for $WATCH_TYPE availability${WATCH_LOCATION:+ in $WATCH_LOCATION}..."
fi

while true; do
    check_availability
    rc=$?
    [ "$rc" = 0 ] && break
    if [ "$rc" = 2 ]; then
        msg="Availability check failed (see hcloud's error above)."
    else
        msg="$WATCH_TYPE is not available${WATCH_LOCATION:+ in $WATCH_LOCATION}."
    fi
    if [ "$POLL_INTERVAL" -eq 0 ] || [ "$DRY_RUN" = 1 ]; then
        echo "$msg"
        [ "$DRY_RUN" = 1 ] && print_plan
        exit "$rc"
    fi
    echo "$(date '+%H:%M:%S') $msg Checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done

echo "Available in: $AVAILABLE_IN"
if [ "$DRY_RUN" = 1 ]; then
    print_plan
    exit 0
fi
notify

if [ -n "$RESCALE" ]; then
    if [ ${#RUN_CMD[@]} -gt 0 ]; then
        echo "Running: ${RUN_CMD[*]}"
        "${RUN_CMD[@]}"
        run_rc=$?
        if [ "$run_rc" != 0 ]; then
            echo "Error: command failed (exit $run_rc); $RESCALE is untouched" >&2
            ntfy "Hetzner: $RESCALE rescale failed" urgent warning \
                "Command failed (exit $run_rc) before the shutdown: ${RUN_CMD[*]}. $RESCALE is untouched"
            exit 1
        fi
    fi
    if rescale; then
        echo "$RESULT"
        ntfy "Hetzner: $RESCALE is now $WATCH_TYPE" urgent rocket "$RESULT"
        exit 0
    fi
    echo "Error: $RESULT" >&2
    ntfy "Hetzner: $RESCALE rescale failed" urgent warning "$RESULT"
    exit 1
fi

if [ ${#RUN_CMD[@]} -gt 0 ]; then
    echo "Running: ${RUN_CMD[*]}"
    "${RUN_CMD[@]}"
    run_rc=$?
    if [ "$run_rc" != 0 ]; then
        ntfy "$WATCH_TYPE provisioning failed" urgent warning "Command failed (exit $run_rc): ${RUN_CMD[*]}"
        exit "$run_rc"
    fi
    ntfy "$WATCH_TYPE server ready" urgent rocket "Command succeeded: ${RUN_CMD[*]}"
fi
exit 0
