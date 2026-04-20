#!/bin/bash
# Thin wrapper around `ssh $USERNAME@$SERVER_NAME 'roost-net client <mode>'`.
# Secrets live on the server; we never render templates on the laptop.
set -euo pipefail

LOG_TAG="roost/travel-clients"
log()  { logger -t "$LOG_TAG" "$*"; echo "$*" >&2; }
warn() { logger -t "$LOG_TAG" -p user.warning "$*"; echo "WARNING: $*" >&2; }
die()  { logger -t "$LOG_TAG" -p user.err "$*"; echo "ERROR: $*" >&2; exit 1; }

DEFAULT_QR_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/roost"

usage() {
    cat <<EOF
Usage: travel-clients {android|laptop|ssh} [--qr] [--qr-file PATH]

Fetch a travel-VPN client config from the server and print it to stdout.

Subcommands:
  android   Android sing-box JSON (TUN-only).
  laptop    Linux sing-box JSON (TUN + 127.0.0.1:1080 SOCKS5 inbound).
  ssh       SSH config snippet for the \`roost-travel\` host alias.

Flags:
  --qr              Render the output as a terminal QR code (UTF8).
  --qr-file PATH    Also write a PNG QR to PATH
                    (default: ${DEFAULT_QR_DIR}/sb-<mode>.png, mode 0600).
  --help            Show this message.

Environment:
  Reads USERNAME and SERVER_NAME from .env at repo root. Target:
      ssh \$USERNAME@\$SERVER_NAME 'roost-net client <mode>'
  Server resolves via Tailscale MagicDNS, so this only works with Tailscale up.

Examples:
  travel-clients android > ~/.cache/roost/sb-android.json
  travel-clients android --qr
  travel-clients android --qr-file ~/.cache/roost/sb.png
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

QR=0
QR_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --qr) QR=1; shift ;;
        --qr-file)
            [ $# -ge 2 ] || die "--qr-file requires a path"
            QR_FILE="$2"; shift 2 ;;
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
if [ "$QR" -eq 1 ] || [ -n "$QR_FILE" ]; then
    command -v qrencode >/dev/null \
        || die "qrencode not found (apt install qrencode)"
fi

log "fetching client config ($MODE) via ssh $SSH_TARGET"
# -n : detach stdin so subshell capture doesn't deadlock on an SSH prompt.
# BatchMode=yes : fail fast instead of prompting for a password.
# ConnectTimeout=10 : refuse to hang on half-open networks (e.g. flaky hotels).
CONFIG=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
            "roost-net client $MODE") \
    || die "ssh roost-net client $MODE failed (is Tailscale up? is roost-net installed?)"

if [ -z "$CONFIG" ]; then
    die "server returned empty config for mode '$MODE'"
fi

printf '%s\n' "$CONFIG"

if [ "$QR" -eq 1 ]; then
    printf '%s' "$CONFIG" | qrencode -t UTF8 -o - >&2
fi

# Default QR file only auto-applied for android (typical mobile import use case).
if [ -n "$QR_FILE" ] || { [ "$QR" -eq 1 ] && [ "$MODE" = "android" ]; }; then
    qr_path="${QR_FILE:-$DEFAULT_QR_DIR/sb-${MODE}.png}"
    qr_dir=$(dirname -- "$qr_path")
    # Config contains long-lived credentials (UUID, REALITY key, SS-2022 pw).
    # Guard against world-readable /tmp-style leaks even if the user supplied
    # a custom path by forcing 0700 dir + 0600 file.
    install -d -m 0700 "$qr_dir"
    ( umask 077 && printf '%s' "$CONFIG" | qrencode -o "$qr_path" )
    chmod 0600 "$qr_path"
    log "QR written: $qr_path (mode 0600)"
fi
