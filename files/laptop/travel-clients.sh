#!/bin/bash
# Thin wrapper around `ssh $USERNAME@$SERVER_NAME 'roost-net client <mode>'`.
# Secrets live on the server; we never render templates on the laptop.
set -euo pipefail

LOG_TAG="roost/travel-clients"
log()  { logger -t "$LOG_TAG" "$*"; echo "$*" >&2; }
die()  { logger -t "$LOG_TAG" -p user.err "$*"; echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: travel-clients {android|laptop|ssh} [--save PATH] [--send-tailscale PEER]

Fetch a travel-VPN client config from the server; stdout by default.

Subcommands:
  android   Android sing-box JSON (TUN-only). Import as Local profile -> From
            file in sing-box-for-android. SFA's QR scanner expects URI profiles
            (vless://, ss://, or sing-box://import-remote-profile?url=...) and
            rejects raw JSON, so a QR workflow would require hosting the JSON
            and isn't worth the infra here -- use --send-tailscale instead.
  laptop    Linux sing-box JSON (TUN + 127.0.0.1:54321 SOCKS5 inbound).
  ssh       SSH config snippet for the \`roost-travel\` host alias.

Flags:
  --save PATH            Write config to PATH (mode 0600, parent 0700).
  --send-tailscale PEER  Save to a temp file and \`tailscale file cp\` to PEER.
                         Requires Tailscale up on both laptop and PEER with
                         incoming files enabled on PEER.
  --help                 Show this message.

Environment:
  Reads USERNAME and SERVER_NAME from .env at repo root. Target:
      ssh \$USERNAME@\$SERVER_NAME 'roost-net client <mode>'
  Server resolves via Tailscale MagicDNS, so this only works with Tailscale up.

Examples:
  travel-clients android --save ~/.cache/roost/sb-android.json
  travel-clients android --send-tailscale pixel-7a
  travel-clients laptop > ~/.config/sing-box/travel.json
  travel-clients ssh   >> ~/.ssh/config
EOF
}

case "${1:-}" in
    --help|-h|help) usage; exit 0 ;;
    "") usage; exit 2 ;;
esac

MODE="$1"; shift
case "$MODE" in
    android|laptop|ssh) ;;
    *) echo "Unknown subcommand: $MODE" >&2; usage; exit 2 ;;
esac

SAVE_PATH=""
TS_PEER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --save)
            [ $# -ge 2 ] || die "--save requires a path"
            SAVE_PATH="$2"; shift 2 ;;
        --send-tailscale)
            [ $# -ge 2 ] || die "--send-tailscale requires a peer name"
            TS_PEER="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown flag: $1" ;;
    esac
done

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
: "${USERNAME:?USERNAME must be set in .env}"

SSH_TARGET="$USERNAME@$SERVER_NAME"

command -v ssh >/dev/null || die "ssh not found"
[ -n "$TS_PEER" ] && { command -v tailscale >/dev/null || die "tailscale CLI not found"; }

log "fetching client config ($MODE) via ssh $SSH_TARGET"
# -n : detach stdin so subshell capture doesn't deadlock on an SSH prompt.
# BatchMode=yes : fail fast instead of prompting for a password.
# ConnectTimeout=10 : refuse to hang on half-open networks (e.g. flaky hotels).
# bash -lc : ~/bin is added to PATH only via ~/.profile on Ubuntu, which isn't
# sourced for a non-interactive non-login SSH command shell; a login shell is.
CONFIG=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
            "bash -lc 'roost-net client $MODE'") \
    || die "ssh roost-net client $MODE failed (is Tailscale up? is roost-net installed?)"

if [ -z "$CONFIG" ]; then
    die "server returned empty config for mode '$MODE'"
fi

# Write to a specific path under 0700 parent + 0600 file (config carries long-
# lived credentials: UUID, REALITY private key, SS-2022 password).
save_config() {
    local path="$1" dir
    dir=$(dirname -- "$path")
    install -d -m 0700 "$dir"
    ( umask 077 && printf '%s\n' "$CONFIG" > "$path" )
    chmod 0600 "$path"
    log "wrote $path (mode 0600)"
}

if [ -n "$SAVE_PATH" ]; then
    save_config "$SAVE_PATH"
elif [ -n "$TS_PEER" ]; then
    tmp_dir="${XDG_CACHE_HOME:-$HOME/.cache}/roost"
    tmp_path="$tmp_dir/sb-${MODE}.json"
    save_config "$tmp_path"
    log "sending to tailscale peer '$TS_PEER'..."
    if ts_cp_out=$(tailscale file cp "$tmp_path" "${TS_PEER}:" 2>&1); then
        log "sent $tmp_path -> ${TS_PEER}: (receive on peer via Tailscale app -> Files)"
    elif echo "$ts_cp_out" | grep -q 'Access denied'; then
        die "tailscale file cp needs root on Linux. Run ONCE: sudo tailscale set --operator=\$USER, then retry. Local copy left at $tmp_path"
    else
        die "tailscale file cp failed: $ts_cp_out (is '$TS_PEER' online and accepting files? local copy at $tmp_path)"
    fi
else
    printf '%s\n' "$CONFIG"
fi
