#!/bin/bash
# clip — put stdin on the user's clipboard: what the /clip skill runs.
#
#   clip <<'EOF'            clip < FILE
#   the text
#   EOF
#
# The text takes both routes, every time:
#   laptop  the laptop's clipboard receiver (files/laptop/install-clip-receive.sh),
#           through the socket files/laptop/roost-forwards.service forwards to
#           $XDG_RUNTIME_DIR/clip-receive.sock. It sets the clipboard without
#           the terminal having focus (desktop caveats: the installer header).
#   OSC 52  through tmux to the terminal that last had input, the phone's
#           included. A Wayland desktop drops it while that terminal's window is
#           unfocused, which is what the laptop route is for.
# Prints one line per route; exits 1 only when neither took the text. The
# laptop line means sshd took the bytes, not that the clipboard did: with no
# receiver behind a live forward they are dropped on the laptop, and a laptop
# asleep behind a live connection takes them when it wakes.
set -euo pipefail

SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/clip-receive.sock"

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

[[ $took == 1 ]]
