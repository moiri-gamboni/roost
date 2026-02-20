#!/bin/bash
# SSH hardening via drop-in config file.
source "$(dirname "$0")/../_setup-env.sh"

DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"

cat > "$DROPIN" << 'EOF'
PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF

chmod 644 "$DROPIN"
systemctl restart ssh

ok "SSH hardened via $DROPIN"
