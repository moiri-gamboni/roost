#!/bin/bash
# clip — put stdin on the user's clipboard: what the /clip skill runs.
#
#   clip <<'EOF'            clip < FILE
#   the text
#   EOF
#   clip --auto < FILE      an automatic clip (hooks/clip-bang-command.sh)
#
# The text takes both routes, every time:
#   laptop  the laptop's clipboard receiver (files/laptop/install-clip-receive.sh),
#           through the socket the laptop's SSH connection forwards to
#           $XDG_RUNTIME_DIR/clip-receive.sock (README, Laptop tools: SSH forwards). It sets the clipboard without
#           the terminal having focus (desktop caveats: the installer header).
#   OSC 52  through tmux to the terminal that last had input, the phone's
#           included. A Wayland desktop drops it while that terminal's window is
#           unfocused, which is what the laptop route is for.
# Prints one line per route; exits 1 only when neither took the text. The
# laptop line means sshd took the bytes, not that the clipboard did: with no
# receiver behind a live forward they are dropped on the laptop, and a laptop
# asleep behind a live connection takes them when it wakes.
#
# Each clip that took is recorded as "<epoch seconds> manual|auto" in
# $XDG_RUNTIME_DIR/clip-last. --auto sends nothing while the last clip is a
# manual one under 10 minutes old, so text clipped for pasting survives a
# command copied after it; an older automatic clip is replaced freely. Held
# back, it prints one "held:" line and exits 3. Copies made on the laptop
# itself are invisible here and get no such protection.
set -euo pipefail

RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="$RUN/clip-receive.sock"
LAST="$RUN/clip-last"
HOLD=600   # seconds a manual clip is safe from --auto

kind=manual
[[ ${1:-} == --auto ]] && kind=auto
if [[ $kind == auto && -f $LAST ]]; then
    read -r at last_kind < "$LAST"
    age=$(( EPOCHSECONDS - at ))
    if [[ $last_kind == manual ]] && (( age < HOLD )); then
        if (( age < 60 )); then ago="${age}s"; else ago="$(( age / 60 )) min"; fi
        echo "held: a manual clip from $ago ago is kept for $(( HOLD / 60 )) min"
        exit 3
    fi
fi

text=$(mktemp)
trap 'rm -f "$text"' EXIT
cat > "$text"
took=0

# timeout: a text larger than the socket buffer blocks here while the SSH
# connection is stalled (laptop asleep)
if err=$(timeout 5 ncat --send-only -U "$SOCK" < "$text" 2>&1); then
    echo "laptop: sent through the SSH forward"; took=1
else
    echo "laptop: receiver unreachable (${err:-timed out})"
fi

# The client by activity, not $TMUX_PANE: a Claude Code session forked into
# the background (/fork, --bg) runs outside tmux, and a session attached in
# several terminals includes stale ones. Without a
# -t naming one client, tmux silently picks another.
client=$(tmux list-clients -F '#{client_activity} #{client_name}' | sort -rn | awk 'NR==1 {print $2}') || client=""
if [[ -n $client ]] && tmux load-buffer -w -t "$client" - < "$text"; then
    echo "OSC 52: sent to $client"; took=1
else
    echo "OSC 52: no tmux client took it"
fi

[[ $took == 1 ]] || exit 1
echo "$EPOCHSECONDS $kind" > "$LAST"
