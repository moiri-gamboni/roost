#!/bin/bash
# Generate REALITY keypair, short IDs, UUID, gRPC service name, WS path, and
# SS-2022 password. Writes /etc/roost-travel/state.env (0600 root).
# Default: refuses to overwrite existing state.env. --force regenerates
# everything; --backfill preserves existing keys and only generates missing
# ones (used when adding a new key field — e.g. when introducing a new
# inbound — without rotating credentials in active use).
set -euo pipefail

STATE_DIR=/etc/roost-travel
STATE_FILE="$STATE_DIR/state.env"
XRAY_BIN=/usr/local/bin/xray
TAG=roost/keys-init

force=false
backfill=false
for arg in "$@"; do
    case "$arg" in
        --force) force=true ;;
        --backfill) backfill=true ;;
        --state-file=*) STATE_FILE="${arg#--state-file=}" ;;
        -h|--help)
            cat <<'USAGE'
Usage: keys-init.sh [--force | --backfill] [--state-file=PATH]

Generates state.env (default: /etc/roost-travel/state.env, 0600 root) with
fresh REALITY keys, UUID, WS path, gRPC service name, REALITY short IDs, and
SS-2022 password. Requires the xray binary to be installed.

  --force            Overwrite an existing state.env, rotating all keys.
  --backfill         Preserve existing keys; only generate missing ones.
                     Use when extending state.env with a new field (e.g.
                     adding an inbound), so currently-active credentials
                     aren't disturbed.
  --state-file=PATH  Override the destination file (used by tests).
USAGE
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if $force && $backfill; then
    echo "Error: --force and --backfill are mutually exclusive" >&2
    exit 2
fi

if [ -f "$STATE_FILE" ] && ! $force && ! $backfill; then
    echo "state.env exists at $STATE_FILE; skipping (use --force to regenerate, --backfill to add missing keys)"
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

# In --backfill mode, load existing values into the env so the generation
# blocks below skip already-set keys. The state.env values are stored
# UPPERCASE; we map to the local lowercase names used by the heredoc below.
if $backfill && [ -f "$STATE_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    set +a
    xray_uuid="${XRAY_UUID:-}"
    xray_path="${XRAY_PATH:-}"
    grpc_service_name="${GRPC_SERVICE_NAME:-}"
    reality_private_key="${REALITY_PRIVATE_KEY:-}"
    reality_public_key="${REALITY_PUBLIC_KEY:-}"
    short_ids_json="${REALITY_SHORT_IDS:-}"
    ss2022_password="${SS2022_PASSWORD:-}"
    vision_sni="${VISION_SNI:-}"
else
    # Force or first-run: empty so every block below generates fresh.
    xray_uuid="" xray_path="" grpc_service_name=""
    reality_private_key="" reality_public_key=""
    short_ids_json="" ss2022_password=""
    vision_sni=""
fi

# UUID — prefer xray's built-in; fall back to uuidgen for defensive parity.
if [ -z "$xray_uuid" ]; then
    if xray_uuid=$("$XRAY_BIN" uuid 2>/dev/null) && [ -n "$xray_uuid" ]; then
        :
    elif command -v uuidgen >/dev/null; then
        xray_uuid=$(uuidgen -r | tr '[:upper:]' '[:lower:]')
    else
        echo "Error: neither 'xray uuid' nor uuidgen available" >&2
        exit 1
    fi
fi

# WS path: 12 hex characters (6 bytes of entropy). openssl is required for
# SS2022_PASSWORD below so reuse it here rather than depending on xxd.
[ -n "$xray_path" ] || xray_path=$(openssl rand -hex 6)

# gRPC service name: 10 alphanumerics. 16 bytes of base64 strips to ~18 alnum
# characters after removing +/=, so `head -c 10` is guaranteed to fill — and
# this pipeline has bounded upstream output, which avoids the SIGPIPE that a
# `tr < /dev/urandom | head` would raise under `set -o pipefail`.
[ -n "$grpc_service_name" ] || grpc_service_name=$(openssl rand -base64 16 | tr -d '/+=' | head -c 10)

# REALITY x25519 keypair — atomic pair. If either half is missing,
# regenerate BOTH together to avoid a private/public mismatch.
if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ]; then
    # Xray v26 output format:
    #   PrivateKey: <base64url>
    #   Password (PublicKey): <base64url>
    #   Hash32: <base64url>
    x25519_output=$("$XRAY_BIN" x25519)
    reality_private_key=$(awk '/^PrivateKey:/ {print $2; exit}' <<< "$x25519_output")
    reality_public_key=$(awk  '/PublicKey/   {print $NF; exit}' <<< "$x25519_output")
    if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ]; then
        echo "Error: failed to parse x25519 keypair from xray output" >&2
        echo "$x25519_output" >&2
        exit 1
    fi
fi

# Four REALITY short IDs of lengths 4, 8, 12, 16 hex chars (2/4/6/8 bytes).
# JSON array string is stored in state.env single-quoted so shell `source` keeps
# the literal; envsubst drops it verbatim into xray config.
if [ -z "$short_ids_json" ]; then
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
fi

# SS-2022 password: 32 bytes of entropy, base64-encoded (canonical format for
# 2022-blake3-chacha20-poly1305 — the cipher derives its 32-byte key from this).
[ -n "$ss2022_password" ] || ss2022_password=$(openssl rand -base64 32)

# VISION_SNI: TLS server-name for VLESS-Vision Path D (TCP 8443 direct to
# Hetzner). The wildcard cert `*.$DOMAIN` covers any subdomain. The operator
# may edit state.env to pick a different label — but it must resolve to the
# Hetzner IP via DNS so GFW's SNI-resolves-to-connection-IP heuristic
# doesn't flag the connection. plans/add-stealth-protocols.md Task 12 adds
# deploy.sh automation that ensures the DNS A/AAAA records exist for the
# default label.
if [ -z "$vision_sni" ]; then
    if [ -z "${DOMAIN:-}" ]; then
        echo "Error: DOMAIN not set; cannot generate VISION_SNI." >&2
        echo "       Set DOMAIN in env (e.g. via _setup-env.sh) or add VISION_SNI to" >&2
        echo "       state.env manually then re-run with --backfill." >&2
        exit 1
    fi
    vision_sni="static.$DOMAIN"
fi

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
VISION_SNI='$vision_sni'
EOF

install -m 0600 -o root -g root "$tmpfile" "$STATE_FILE"
# Do NOT interpolate $xray_uuid / $grpc_service_name into the logger line:
# journald is adm-group-readable on Ubuntu and retained for weeks, which
# would leak the VLESS auth credential and Path-B obscurity token past
# the 0600 protection of state.env itself.
logger -t "$TAG" "Wrote $STATE_FILE"
echo "Wrote $STATE_FILE"
