#!/bin/bash
# The session CLI's notify seam: files/session.conf points SESSION_SWITCH_NOTIFY
# here. Called with one argument, the sentence to push, in two cases: the
# automatic switcher moved the box to another login, or the statusline's
# autosave refused to vault a live credential whose access token is empty
# (nothing can authenticate until it is fixed, hence the higher priority).
# The CLI rate-limits both and runs this detached, after its decision lock is
# released, so a slow push delays nothing.
source "$(dirname "$0")/../lib/_hook-env.sh"

PRIORITY="default"
case "${1:-}" in "session account: not vaulting"*) PRIORITY="high" ;; esac

ntfy_send -t "Claude login" -p "$PRIORITY" "${1:-session: the live login changed}"
