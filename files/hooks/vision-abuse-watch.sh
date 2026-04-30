#!/bin/bash
# Daily abuse watch for Vision (Path D) inbound.
#
# Path D's only credential is XRAY_UUID; if it leaks (phone backup, screenshot,
# config sync to an untrusted device), the inbound becomes an open relay until
# the operator rotates. This script provides early-warning by reporting any
# source IP that hasn't been seen before — a sudden spike in novel IPs is the
# leak signal we'd otherwise miss until Hetzner ToS / AbuseIPDB notice.
#
# State: /var/lib/roost-travel/vision-seen-ips.txt — append-only sorted IP
# list. Persists across reboots. Not secret per se, but kept root-only since
# IPs are personal data; mode 0640 root:root.
#
# xray access log format (verified empirically 2026-04-30):
#   2026/04/30 00:00:39.346870 from <SRC_IP>:<PORT> accepted <DST>:<PORT> [<INBOUND> -> <OUTBOUND>]
# We grep for "[vision -> " to filter Vision-tagged lines and pull the SRC_IP.
set -uo pipefail
source "$(dirname "$0")/_hook-env.sh"

ACCESS_LOG=/var/log/xray/access.log
SEEN_DIR=/var/lib/roost-travel
SEEN_FILE="$SEEN_DIR/vision-seen-ips.txt"

# Pre-flight: silently exit if the access log isn't there yet (xray hasn't
# logged anything or the path is different on this server).
if ! sudo test -r "$ACCESS_LOG"; then
    exit 0
fi

sudo install -d -m 0750 -o root -g root "$SEEN_DIR"
sudo touch "$SEEN_FILE"
sudo chmod 0640 "$SEEN_FILE"

# Extract today's source IPs from Vision-tagged access lines. The bracket
# match `[vision -> ` is more specific than `[vision]` (which would also
# match other tags whose names happen to contain "vision"). awk picks the
# token after the literal "from" and strips :port.
today_ips=$(sudo grep -F '[vision -> ' "$ACCESS_LOG" 2>/dev/null \
    | awk '{for (i=1; i<=NF; i++) if ($i == "from") {n=split($(i+1), a, ":"); if (n == 2) print a[1]; else { sub(/:[0-9]+$/, "", $(i+1)); print $(i+1) }; break}}' \
    | sort -u)

if [ -z "$today_ips" ]; then
    exit 0
fi

# Diff: today's IPs not in the seen-file. comm needs both inputs sorted.
known_ips=$(sudo cat "$SEEN_FILE" 2>/dev/null | sort -u)
novel=$(comm -23 <(printf '%s\n' "$today_ips") <(printf '%s\n' "$known_ips"))

if [ -n "$novel" ]; then
    count=$(printf '%s\n' "$novel" | wc -l)
    head=$(printf '%s\n' "$novel" | head -10)
    ntfy_send -t "Vision: $count novel client IP(s)" -p "default" \
        "First-seen IPs on Path D (top 10):\n$head"
    logger -t "$_HOOK_TAG" "$count novel Vision client IPs: $(printf '%s ' $novel)"
fi

# Update seen-file: union of known + today, atomic.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
{ printf '%s\n' "$known_ips"; printf '%s\n' "$today_ips"; } | sort -u | grep -v '^$' > "$tmpfile"
sudo install -m 0640 -o root -g root "$tmpfile" "$SEEN_FILE"
