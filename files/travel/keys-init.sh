#!/bin/bash
# Generate REALITY keypair, short IDs, UUID, gRPC service name, WS path, and
# SS-2022 password. Writes /etc/roost-travel/state.env (0600 root).
# Idempotent: refuses to overwrite existing state.env unless --force.
set -euo pipefail

STATE_DIR=/etc/roost-travel
STATE_FILE="$STATE_DIR/state.env"
XRAY_BIN=/usr/local/bin/xray
TAG=roost/keys-init

force=false
for arg in "$@"; do
    case "$arg" in
        --force) force=true ;;
        -h|--help)
            cat <<'USAGE'
Usage: keys-init.sh [--force]

Generates /etc/roost-travel/state.env with fresh REALITY keys, UUID, WS path,
gRPC service name, REALITY short IDs, and SS-2022 password. Requires the xray
binary to be installed. Run as root (writes 0600 file owned root:root).

  --force   Overwrite an existing state.env instead of skipping.
USAGE
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if [ -f "$STATE_FILE" ] && [ "$force" = false ]; then
    echo "state.env exists; skipping (use --force to regenerate)"
    exit 0
fi

if [ ! -x "$XRAY_BIN" ]; then
    echo "Error: $XRAY_BIN not found. Run files/setup/travel-vpn.sh first." >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (writing $STATE_FILE as 0600 root:root)" >&2
    exit 1
fi

install -d -m 0755 -o root -g root "$STATE_DIR"

# UUID — prefer xray's built-in; fall back to uuidgen for defensive parity.
if xray_uuid=$("$XRAY_BIN" uuid 2>/dev/null) && [ -n "$xray_uuid" ]; then
    :
elif command -v uuidgen >/dev/null; then
    xray_uuid=$(uuidgen -r | tr '[:upper:]' '[:lower:]')
else
    echo "Error: neither 'xray uuid' nor uuidgen available" >&2
    exit 1
fi

# WS path: 12 hex characters (6 bytes of entropy). openssl is required for
# SS2022_PASSWORD below so reuse it here rather than depending on xxd.
xray_path=$(openssl rand -hex 6)

# gRPC service name: 10 alphanumerics. 16 bytes of base64 strips to ~18 alnum
# characters after removing +/=, so `head -c 10` is guaranteed to fill — and
# this pipeline has bounded upstream output, which avoids the SIGPIPE that a
# `tr < /dev/urandom | head` would raise under `set -o pipefail`.
grpc_service_name=$(openssl rand -base64 16 | tr -d '/+=' | head -c 10)

# REALITY x25519 keypair — xray emits both lines; parse each.
x25519_output=$("$XRAY_BIN" x25519)
reality_private_key=$(awk -F': *' '/^Private ?[Kk]ey/ {print $2; exit}' <<< "$x25519_output")
reality_public_key=$(awk -F': *' '/^Public ?[Kk]ey/  {print $2; exit}' <<< "$x25519_output")
if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ]; then
    echo "Error: failed to parse x25519 keypair from xray output" >&2
    echo "$x25519_output" >&2
    exit 1
fi

# Four REALITY short IDs of lengths 4, 8, 12, 16 hex chars (2/4/6/8 bytes).
# JSON array string is stored in state.env single-quoted so shell `source` keeps
# the literal; envsubst drops it verbatim into xray config.
short_ids_json=$(
    printf '['
    first=true
    for hex_len in 4 8 12 16; do
        $first || printf ','
        first=false
        bytes=$((hex_len / 2))
        sid=$(openssl rand -hex "$bytes")
        printf '"%s"' "$sid"
    done
    printf ']'
)

# SS-2022 password: 32 bytes of entropy, base64-encoded (canonical format for
# 2022-blake3-chacha20-poly1305 — the cipher derives its 32-byte key from this).
ss2022_password=$(openssl rand -base64 32)

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat > "$tmpfile" <<EOF
# Travel-VPN state — generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by keys-init.sh.
# Rotate with: sudo /etc/roost-travel/keys-init.sh --force
XRAY_UUID='$xray_uuid'
XRAY_PATH='$xray_path'
GRPC_SERVICE_NAME='$grpc_service_name'
REALITY_PRIVATE_KEY='$reality_private_key'
REALITY_PUBLIC_KEY='$reality_public_key'
REALITY_SHORT_IDS='$short_ids_json'
SS2022_PASSWORD='$ss2022_password'
EOF

install -m 0600 -o root -g root "$tmpfile" "$STATE_FILE"
logger -t "$TAG" "Wrote $STATE_FILE (uuid=$xray_uuid grpc=$grpc_service_name)"
echo "Wrote $STATE_FILE"
