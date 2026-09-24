#!/bin/bash
# Attention queue operations (~/roost/code/attention-queue): the beeper service
# user, the four nested btrfs subvolumes that keep decrypted message text out of
# snapper snapshots and the off-site backup, Beeper Server pinned and verified
# against the feed's sha512, the egress policy, and the systemd units, enabled
# here because roost-apply push never enables anything. Beeper Server and the
# bridges are enabled but not started: they need a login first, and the bridges
# need bbctl, mautrix-slack, mautrix-discord and matrimail built from their
# pinned commits, all by hand
# (docs/runbooks/attention-queue.md). Every step is check-then-act.
source "$(dirname "$0")/../_setup-env.sh"

BEEPER_SERVER_VERSION=4.3.123
# Base64 sha512 as the update feed publishes it
BEEPER_SERVER_SHA512=roYYt34b62Q2dEUsBv1xDnELkW3gr5zvBDU28IrWfQWVKdkFOXWtUjKV6LWpTroQ5oLccO1UjmGiYRuNjTaJdw==
BEEPER_HOME=/var/lib/beeper-server
BEEPER_OPT=/opt/beeper-server

# --- service user: no shell, home where the binary unpacks its own cache ---
if id beeper &>/dev/null; then
    skip "beeper user exists"
else
    useradd --system --home-dir "$BEEPER_HOME" --no-create-home --shell /usr/sbin/nologin beeper
    ok "Created beeper system user (uid $(id -u beeper))"
fi

# --- nested subvolumes, created empty before anything writes plaintext ---
# A snapshot of @rootfs does not descend into them. An existing plain directory
# is refused rather than converted: whatever it holds is already in snapshots.
subvolume() {
    local dir=$1 owner=$2 mode=$3
    if btrfs subvolume show "$dir" &>/dev/null; then
        skip "subvolume $dir exists"
        return
    fi
    if [ -e "$dir" ]; then
        echo "  [!] $dir exists but is not a btrfs subvolume; move it aside and re-run" >&2
        exit 1
    fi
    # A missing ~/.local/share or ~/.local/state made here as root would stay
    # root-owned and lock the user out of everything else that lives there.
    case $dir in
        "$HOME_DIR"/*) as_user mkdir -p "$(dirname "$dir")" ;;
        *) mkdir -p "$(dirname "$dir")" ;;
    esac
    btrfs subvolume create "$dir" > /dev/null
    chown "$owner" "$dir"
    chmod "$mode" "$dir"
    ok "Subvolume created: $dir"
}
subvolume "$BEEPER_HOME" beeper:beeper 0700
subvolume "$BEEPER_OPT" root:root 0755
subvolume "$HOME_DIR/.local/share/bbctl" "$USERNAME:$USERNAME" 0700
subvolume "$HOME_DIR/.local/state/attention-queue" "$USERNAME:$USERNAME" 0700

# --- Beeper Server: the tarball stays beside the unpacked build for rollback ---
TARBALL=$BEEPER_OPT/beeper-server-$BEEPER_SERVER_VERSION-linux-x64.tar.gz
if [ -x "$BEEPER_OPT/$BEEPER_SERVER_VERSION/beeper-server" ]; then
    skip "Beeper Server $BEEPER_SERVER_VERSION installed"
else
    info "Downloading Beeper Server $BEEPER_SERVER_VERSION"
    curl -fsSL -o "$TARBALL" "https://beeper-desktop.download.beeper.com/builds/beeper-server-$BEEPER_SERVER_VERSION-linux-x64.tar.gz"
    ACTUAL=$(openssl dgst -sha512 -binary "$TARBALL" | base64 -w0)
    if [ "$ACTUAL" != "$BEEPER_SERVER_SHA512" ]; then
        rm -f "$TARBALL"
        echo "  [!] Beeper Server tarball sha512 mismatch (got $ACTUAL)" >&2
        exit 1
    fi
    mkdir -p "$BEEPER_OPT/$BEEPER_SERVER_VERSION"
    tar -C "$BEEPER_OPT/$BEEPER_SERVER_VERSION" --strip-components=1 -xzf "$TARBALL"
    ok "Beeper Server $BEEPER_SERVER_VERSION unpacked"
fi
# `current` is the rollback lever; an existing link is a choice, left alone.
if [ -L "$BEEPER_OPT/current" ]; then
    skip "$BEEPER_OPT/current -> $(readlink "$BEEPER_OPT/current")"
else
    ln -s "$BEEPER_SERVER_VERSION" "$BEEPER_OPT/current"
    ok "$BEEPER_OPT/current -> $BEEPER_SERVER_VERSION"
fi

# Crash reporting off; the server leaves this file as written.
if [ -f "$BEEPER_HOME/data/config.json" ]; then
    skip "Beeper Server config.json exists"
else
    install -d -m 0700 -o beeper -g beeper "$BEEPER_HOME/data"
    printf '{\n  "sentry_disabled": true\n}\n' > "$BEEPER_HOME/data/config.json"
    chown beeper:beeper "$BEEPER_HOME/data/config.json"
    chmod 0600 "$BEEPER_HOME/data/config.json"
    ok "Beeper Server config.json written (sentry_disabled)"
fi

# --- egress policy: script and allowlist (roost-apply keeps them current after this) ---
install -d -m 0755 /etc/beeper-egress
for pair in "beeper-egress.sh:/usr/local/sbin/beeper-egress:0755" "egress-hosts:/etc/beeper-egress/hosts:0644"; do
    IFS=: read -r src dst mode <<< "$pair"
    if cmp -s "$REMOTE_DIR/files/beeper/$src" "$dst"; then
        skip "$dst current"
    else
        install -m "$mode" "$REMOTE_DIR/files/beeper/$src" "$dst"
        ok "$dst installed"
    fi
done

# --- libolm: mautrix-discord v0.7.7 links it (its mautrix-go predates the pure-Go backend) ---
if dpkg-query -W -f='${Status}\n' libolm3 2>&1 | grep -qx 'install ok installed'; then
    skip "libolm3 installed"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q libolm3
    ok "libolm3 installed"
fi

# --- matrimail's key: encrypts the stored Gmail refresh token. Created once and
#     never rewritten: a new passphrase makes every stored credential unreadable ---
if [ -e /etc/attention-queue/matrimail.env ]; then
    skip "matrimail passphrase file exists"
else
    install -d -m 700 /etc/attention-queue
    ( umask 077; { printf 'MATRIMAIL_PASSPHRASE='; openssl rand -base64 48 | tr -d '\n'; printf '\nMATRIMAIL_LOG_LEVEL=info\n'; } > /etc/attention-queue/matrimail.env )
    ok "matrimail passphrase file created"
fi

# --- units ---
export USERNAME HOME_DIR
CHANGED=false
for unit in beeper-egress.service beeper-egress-ensure.service beeper-egress-ensure.timer beeper-server.service attention-bridge@.service attention-bridge@email.service.d/matrimail.conf; do
    RENDERED=$(envsubst '$USERNAME $HOME_DIR' < "$REMOTE_DIR/files/beeper/$unit")
    TARGET=/etc/systemd/system/$unit
    mkdir -p "$(dirname "$TARGET")"
    if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$RENDERED" ]; then
        skip "$unit already configured"
    else
        echo "$RENDERED" > "$TARGET"
        CHANGED=true
    fi
done
if $CHANGED; then
    systemctl daemon-reload
fi

# The policy and its timer need nothing else and go live now; the server and
# the bridge wait for their logins (they start at the next boot regardless).
for unit in beeper-egress.service beeper-egress-ensure.timer; do
    if systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit"; then
        skip "$unit enabled and active"
    else
        systemctl enable --now "$unit"
        ok "$unit enabled and started"
    fi
done
for unit in beeper-server.service attention-bridge@slack.service attention-bridge@discord.service attention-bridge@email.service; do
    if systemctl is-enabled --quiet "$unit"; then
        skip "$unit enabled"
    else
        systemctl enable "$unit"
        ok "$unit enabled (start it after its login: docs/runbooks/attention-queue.md)"
    fi
done
