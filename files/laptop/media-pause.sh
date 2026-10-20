#!/bin/bash
# media-pause — the laptop end of the server's Alt+M dictation
# (files/scripts/dictate.sh), which pauses what plays here while it records.
# Run by media-pause@.service for each connection to
# $XDG_RUNTIME_DIR/media-pause.sock, it reads one line:
#   pause   pause every MPRIS player that is playing (Spotify, a browser tab,
#           most desktop players) and list them in $XDG_RUNTIME_DIR/media-paused
#   resume  play the players the last pause listed, so one paused by hand
#           before the recording stays paused
# Installed as ~/.local/bin/media-pause by install-media-pause.sh.
set -euo pipefail

PAUSED="$XDG_RUNTIME_DIR/media-paused"
read -r verb || true
case "$verb" in
    pause)
        : > "$PAUSED"
        while read -r p; do
            if [ "$(playerctl -p "$p" status)" = Playing ] && playerctl -p "$p" pause; then
                echo "$p" >> "$PAUSED"
                echo "paused $p"
            fi
        done < <(playerctl -l)
        ;;
    resume)
        [ -f "$PAUSED" ] || exit 0
        while read -r p; do
            if playerctl -p "$p" play; then echo "resumed $p"; fi
        done < "$PAUSED"
        rm -f "$PAUSED"
        ;;
    *) echo "unknown request: $verb" >&2; exit 1 ;;
esac
