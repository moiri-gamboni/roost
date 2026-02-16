#!/bin/bash
# Disable password authentication and root login.
source "$(dirname "$0")/../_setup-env.sh"

sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

echo "  [+] Password auth disabled, root login disabled"
