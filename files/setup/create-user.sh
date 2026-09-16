#!/bin/bash
# Create non-root user with sudo and SSH keys.
source "$(dirname "$0")/../_setup-env.sh"

if id "$USERNAME" &>/dev/null; then
    echo "  [-] User $USERNAME exists (already done)"
else
    adduser --disabled-password --gecos "" "$USERNAME"
    echo "  [+] Created user $USERNAME"
fi

usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 440 "/etc/sudoers.d/$USERNAME"

# Private home. Every other local user (caddy, privatebin, www-data, ntfy, xray,
# postgres, nobody) is a possible foothold — PrivateBin's PHP pool faces the
# public internet — and with 0755 here each of them could read the whole tree
# (files land 0664 under the 002 user-private-group umask). Caddy, the one
# service whose app roots live under the home, gets a traverse-only ACL in
# setup/caddy.sh rather than membership of group $USERNAME: that group's files
# are group-writable, so membership would grant write, not just read.
chmod 750 "$HOME_DIR"

# Copy SSH keys from root
if [ ! -f "$HOME_DIR/.ssh/authorized_keys" ]; then
    mkdir -p "$HOME_DIR/.ssh"
    cp /root/.ssh/authorized_keys "$HOME_DIR/.ssh/"
    chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.ssh"
    chmod 700 "$HOME_DIR/.ssh"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    echo "  [+] Copied SSH keys to $USERNAME"
fi
