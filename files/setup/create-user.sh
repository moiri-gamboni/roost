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

# Copy SSH keys from root
if [ ! -f "$HOME_DIR/.ssh/authorized_keys" ]; then
    mkdir -p "$HOME_DIR/.ssh"
    cp /root/.ssh/authorized_keys "$HOME_DIR/.ssh/"
    chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.ssh"
    chmod 700 "$HOME_DIR/.ssh"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    echo "  [+] Copied SSH keys to $USERNAME"
fi
