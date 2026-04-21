#!/bin/bash
# Toggle the Hetzner cloud firewall rules that expose travel-VPN ports.
# Runs on the LAPTOP during travel; complements server-side `roost-net travel on/off`.
#
# Rules managed (all inbound, dual-stack: 0.0.0.0/0 + ::/0):
#   tcp/443    -- travel-vpn-reality   (VLESS+gRPC+REALITY, Path B)
#   tcp/51820  -- travel-vpn-ss2022-tcp (Shadowsocks-2022 TCP, Path C)
#   udp/51820  -- travel-vpn-ss2022-udp (Shadowsocks-2022 UDP, Path C)
#
# Firewall identity: ${SERVER_NAME}-fw (same convention as deploy.sh).
# The hcloud CLI must have a context configured (e.g. `hcloud context create roost`).
# Token discovery follows hcloud's normal resolution order; HCLOUD_TOKEN from .env
# is honored if set, otherwise the active hcloud context applies.
set -euo pipefail

LOG_TAG="roost/net-fw"
log()  { logger -t "$LOG_TAG" "$*"; echo "$*"; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "WARNING: $*" >&2; }
die()  { logger -t "$LOG_TAG" -p user.err "$*"; echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: roost-net-fw {open|close|status} [--help]

Open or close Hetzner firewall rules for travel-VPN traffic.

Subcommands:
  open      Add 443/tcp, 51820/tcp, 51820/udp inbound rules (dual-stack).
  close     Remove those rules.
  status    Print the current state of each rule.

Environment:
  Reads SERVER_NAME from .env at repo root (firewall name is ${SERVER_NAME}-fw).
  HCLOUD_TOKEN may be set in .env; otherwise the active `hcloud context` applies.

Exit status:
  0 on success.
  Nonzero on hcloud failures. Already-open / already-closed states are no-ops
  and exit 0 with an informational message.

Examples:
  roost-net-fw open
  roost-net-fw close
  roost-net-fw status
EOF
}

case "${1:-}" in
    --help|-h|help) usage; exit 0 ;;
    "") usage; exit 2 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ENV_FILE="$REPO_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090,SC1091
    . "$ENV_FILE"
    set +a
else
    die ".env not found at $ENV_FILE (run from the claude-roost checkout)"
fi

: "${SERVER_NAME:?SERVER_NAME must be set in .env}"

FW_NAME="${SERVER_NAME}-fw"

RULES=(
    "tcp 443 travel-vpn-reality"
    "tcp 51820 travel-vpn-ss2022-tcp"
    "udp 51820 travel-vpn-ss2022-udp"
)

SOURCE_IPS_V4="0.0.0.0/0"
SOURCE_IPS_V6="::/0"

command -v hcloud >/dev/null || die "hcloud CLI not found (install from https://github.com/hetznercloud/cli)"
command -v jq     >/dev/null || die "jq not found (apt install jq)"

FW_JSON_CACHE=""

fetch_fw_json() {
    if [ -z "$FW_JSON_CACHE" ]; then
        FW_JSON_CACHE=$(hcloud firewall describe "$FW_NAME" -o json) \
            || die "Firewall '$FW_NAME' not found or hcloud auth failed"
    fi
    printf '%s' "$FW_JSON_CACHE"
}

invalidate_cache() { FW_JSON_CACHE=""; }

# States: "ok" (dual-stack match), "partial-v4" / "partial-v6" / "partial-other"
# (rule present but source_ips drifted), "missing" (no such rule).
# Emit at most one line even if somehow there are duplicate rules matching.
rule_state() {
    local proto="$1" port="$2" desc="$3"
    fetch_fw_json | jq -r \
        --arg p "$proto" --arg port "$port" --arg d "$desc"  \
        --arg v4 "$SOURCE_IPS_V4" --arg v6 "$SOURCE_IPS_V6" '
            [ .rules[]?
              | select(.direction == "in"
                       and .protocol == $p
                       and (.port // "") == $port
                       and (.description // "") == $d)
              | (.source_ips // [])
              | (if (index($v4) != null) and (index($v6) != null) then "ok"
                 elif (index($v4) != null) then "partial-v4"
                 elif (index($v6) != null) then "partial-v6"
                 else "partial-other"
                 end) ]
            | (.[0] // "missing")
        '
}

cmd_open() {
    local proto port desc state any_added=0
    for rule in "${RULES[@]}"; do
        read -r proto port desc <<<"$rule"
        state=$(rule_state "$proto" "$port" "$desc")
        if [ "$state" = "ok" ]; then
            log "already open: $proto/$port ($desc)"
            continue
        fi
        # partial-* means a stale rule with the same description but drifted
        # source_ips. Remove it first so the add below doesn't create a duplicate.
        if [ "$state" != "missing" ]; then
            warn "replacing drifted rule ($state): $proto/$port ($desc)"
            purge_any_rule "$proto" "$port" "$desc"
        fi
        log "opening: $proto/$port ($desc)"
        hcloud firewall add-rule "$FW_NAME" \
            --direction in --protocol "$proto" --port "$port" \
            --source-ips "$SOURCE_IPS_V4" --source-ips "$SOURCE_IPS_V6" \
            --description "$desc"
        any_added=1
        invalidate_cache
    done
    verify_state "open"
    if [ "$any_added" -eq 0 ]; then
        log "no changes: all travel-vpn rules already present on $FW_NAME"
    else
        log "done: travel-vpn rules present on $FW_NAME"
    fi
}

cmd_close() {
    local proto port desc state any_removed=0
    for rule in "${RULES[@]}"; do
        read -r proto port desc <<<"$rule"
        state=$(rule_state "$proto" "$port" "$desc")
        if [ "$state" = "missing" ]; then
            log "already closed: $proto/$port ($desc)"
            continue
        fi
        log "closing: $proto/$port ($desc)"
        purge_any_rule "$proto" "$port" "$desc"
        any_removed=1
        invalidate_cache
    done
    verify_state "close"
    if [ "$any_removed" -eq 0 ]; then
        log "no changes: no travel-vpn rules present on $FW_NAME"
    else
        log "done: travel-vpn rules removed from $FW_NAME"
    fi
}

# Remove every rule matching (direction=in, proto, port, desc) regardless of
# source_ips shape. hcloud delete-rule matches on full reflect.DeepEqual, so
# we ask the API for the exact source_ips of each matching rule and delete
# each one individually.
purge_any_rule() {
    local proto="$1" port="$2" desc="$3"
    local ips_json ip
    local -a ips_args tmp_ips
    while IFS= read -r ips_json; do
        [ -z "$ips_json" ] && continue
        ips_args=()
        mapfile -t tmp_ips < <(printf '%s' "$ips_json" | jq -r '.[]')
        for ip in "${tmp_ips[@]}"; do
            ips_args+=(--source-ips "$ip")
        done
        [ ${#ips_args[@]} -eq 0 ] && continue
        hcloud firewall delete-rule "$FW_NAME" \
            --direction in --protocol "$proto" --port "$port" \
            "${ips_args[@]}" \
            --description "$desc"
    done < <(
        fetch_fw_json | jq -c \
            --arg p "$proto" --arg port "$port" --arg d "$desc" '
                .rules[]?
                | select(.direction == "in"
                         and .protocol == $p
                         and (.port // "") == $port
                         and (.description // "") == $d)
                | (.source_ips // [])
            '
    )
    invalidate_cache
}

# Post-condition check: after open/close, re-fetch and assert each rule is in
# the expected terminal state. Trip-critical: never trust the absence of a
# hcloud error as proof; only the firewall's own state is authoritative.
verify_state() {
    local want="$1" proto port desc state any_wrong=0
    for rule in "${RULES[@]}"; do
        read -r proto port desc <<<"$rule"
        state=$(rule_state "$proto" "$port" "$desc")
        case "$want:$state" in
            open:ok|close:missing) ;;
            *)
                warn "post-check: $proto/$port ($desc) expected $want but state=$state"
                any_wrong=1
                ;;
        esac
    done
    [ "$any_wrong" -eq 0 ] || die "post-check failed for $want; inspect with: hcloud firewall describe $FW_NAME -o json"
}

cmd_status() {
    local proto port desc state rc=0
    printf '%-28s %-6s %-6s %s\n' "description" "proto" "port" "state"
    printf '%-28s %-6s %-6s %s\n' "----------------------------" "------" "------" "--------"
    for rule in "${RULES[@]}"; do
        read -r proto port desc <<<"$rule"
        state=$(rule_state "$proto" "$port" "$desc")
        printf '%-28s %-6s %-6s %s\n' "$desc" "$proto" "$port" "$state"
        # Non-terminal states (partial-*) exit 2 so CI pipelines can trip on them.
        case "$state" in
            ok|missing) ;;
            *) rc=2 ;;
        esac
    done
    return "$rc"
}

case "${1:-}" in
    open)   shift; cmd_open   "$@" ;;
    close)  shift; cmd_close  "$@" ;;
    status) shift; cmd_status "$@" ;;
    *) echo "Unknown subcommand: ${1:-}" >&2; usage; exit 2 ;;
esac
