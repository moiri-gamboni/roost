#!/bin/bash
# One-shot laptop install for the SuperProductivity sync (sp-sync.sh header for
# what it does and why its triggers are what they are).
#   1. ~/.local/bin/sp-sync
#   2. ~/.ssh/sp-sync, the push key (made if missing), and the authorized_keys
#      line the server needs for it: write-only rsync into
#      ~/roost/apart-research/workspace/timetracking/sp, from this laptop's
#      tailnet addresses only
#   3. ~/.config/sp-sync/ntfy.env (0600: NTFY_URL + the server's ntfy token)
#   4. user units sp-sync@.service, sp-sync.path, sp-sync.timer and
#      ntfy-sp-sync@.service, rendered and enabled
#   5. one sync run, whose result is printed
#
# Needs the superproductivity-extract clone (SP_EXTRACT_DIR, default
# ~/Code/superproductivity-extract) and an archive at ~/.local/share/sp-archive
# that declares a covered window. Seed one from existing exports with
#   python3 -m sp.archive ~/.local/share/sp-archive EXPORT...
# or from SP alone with
#   ./extract.sh --from <first day in SP> --to "$(date +%F)" --archive ~/.local/share/sp-archive
# (both from the clone's root).
#
# Idempotent: rerun after a snap refresh, since the path unit watches the
# resolved revision's backups folder. Set DEBUG=1 for full command tracing.
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SP_EXTRACT_DIR="${SP_EXTRACT_DIR:-$HOME/Code/superproductivity-extract}"
ARCHIVE="$HOME/.local/share/sp-archive"
KEY="$HOME/.ssh/sp-sync"
UNIT_DIR="$HOME/.config/systemd/user"

step() { printf '\n  [*] %s\n' "$1"; }
ok()   { printf '  [+] %s\n'  "$1"; }
die()  { printf '  [!] %s\n'  "$1" >&2; exit 1; }

[ -f "$REPO_ROOT/.env" ] || die "$REPO_ROOT/.env not found"
read -r USERNAME SERVER_NAME ROOST_DIR_NAME < <(
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
    : "${USERNAME:?USERNAME missing from .env}"
    : "${SERVER_NAME:?SERVER_NAME missing from .env}"
    : "${ROOST_DIR_NAME:=roost}"
    printf '%s %s %s\n' "$USERNAME" "$SERVER_NAME" "$ROOST_DIR_NAME"
)

step "Checking the extract clone and its venv"
[ -x "$SP_EXTRACT_DIR/extract.sh" ] || die "no extract.sh in $SP_EXTRACT_DIR (set SP_EXTRACT_DIR)"
# --help builds the venv on a first run and exits.
"$SP_EXTRACT_DIR/extract.sh" --help > /dev/null
ok "extract ready at $SP_EXTRACT_DIR ($(git -C "$SP_EXTRACT_DIR" rev-parse --short HEAD))"

step "Locating SuperProductivity's backups and IndexedDB"
read -r SP_BACKUPS_DIR SP_IDB_DIR < <(cd "$SP_EXTRACT_DIR" && .venv/bin/python -c '
import os
from sp import locate
lay = locate.detect()
assert lay.config_dirs and lay.leveldb, "SuperProductivity data not found"
print(os.path.join(lay.config_dirs[-1], "backups"), os.path.dirname(lay.leveldb))')
[ -d "$SP_BACKUPS_DIR" ] || die "backups folder $SP_BACKUPS_DIR missing"
ok "backups $SP_BACKUPS_DIR"
ok "IndexedDB $SP_IDB_DIR"

step "Checking the archive"
"$SP_EXTRACT_DIR/.venv/bin/python" -c '
import json, sys
w = json.load(open(sys.argv[1]))["windows"]
assert w, "no covered window"
print(f"  [+] archive covers {w[0][\"start\"]} .. {w[-1][\"end\"]}")' \
    "$ARCHIVE/derived/extraction-summary.json" || die "seed $ARCHIVE first (this script's header)"

step "Push key"
if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "sp-sync@$(hostname)" -f "$KEY"
    ok "made $KEY"
else
    ok "using $KEY"
fi
TS4=$(tailscale ip -4 | head -n 1)
TS6=$(tailscale ip -6 | head -n 1)
AUTH_LINE="from=\"$TS4,$TS6\",restrict,command=\"/usr/bin/rrsync -wo /home/$USERNAME/$ROOST_DIR_NAME/apart-research/workspace/timetracking/sp\" $(cat "$KEY.pub")"

step "ntfy credentials for failure alerts"
SERVER_TS=$(tailscale ip -4 "$SERVER_NAME" | head -n 1)
[ -n "$SERVER_TS" ] || die "could not resolve $SERVER_NAME on the tailnet; is it online?"
NTFY_TOKEN=$(ssh -o BatchMode=yes "$USERNAME@$SERVER_NAME" 'cat ~/services/.ntfy-token') \
    || die "could not read ~/services/.ntfy-token on $SERVER_NAME"
[ -n "$NTFY_TOKEN" ] || die "the server's ntfy token is empty"
install -d -m 0700 "$HOME/.config/sp-sync"
umask 077
printf 'NTFY_URL=http://%s:2586/claude-%s\nNTFY_TOKEN=%s\n' "$SERVER_TS" "$USERNAME" "$NTFY_TOKEN" \
    > "$HOME/.config/sp-sync/ntfy.env"
umask 022
ok "wrote ~/.config/sp-sync/ntfy.env (0600)"

step "Installing ~/.local/bin/sp-sync and the user units"
install -Dm755 "$SCRIPT_DIR/sp-sync.sh" "$HOME/.local/bin/sp-sync"
install -d -m 0755 "$UNIT_DIR"
export USERNAME SERVER_NAME SP_EXTRACT_DIR SP_BACKUPS_DIR SP_IDB_DIR
for u in sp-sync@.service sp-sync.path sp-sync.timer ntfy-sp-sync@.service; do
    envsubst '${USERNAME} ${SERVER_NAME} ${SP_EXTRACT_DIR} ${SP_BACKUPS_DIR} ${SP_IDB_DIR}' \
        < "$SCRIPT_DIR/$u" > "$UNIT_DIR/$u"
done
systemctl --user daemon-reload
systemctl --user enable --now sp-sync.path sp-sync.timer
ok "sp-sync.path and sp-sync.timer enabled"

step "One sync now"
if systemctl --user start sp-sync@manual.service; then
    ok "sync ran"
else
    printf '  [!] the sync failed; journalctl --user -u sp-sync@manual -n 30\n' >&2
fi
journalctl --user -u sp-sync@manual.service -n 6 --no-pager -o cat

echo
echo "The server needs this line in ~/.ssh/authorized_keys (once):"
echo "  $AUTH_LINE"
echo
echo "Inspect: systemctl --user list-timers sp-sync.timer; journalctl --user -u 'sp-sync@*'"
if ! loginctl show-user "$USER" -p Linger | grep -q 'Linger=yes'; then
    echo "User units run only while you are logged in, which is when SP runs too: fine as is."
fi
