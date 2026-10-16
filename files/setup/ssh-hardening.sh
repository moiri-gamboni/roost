#!/bin/bash
# SSH hardening via drop-in config file, plus the StreamLocalBindUnlink drop-in that the laptop's
# forwarded sockets need (also deployed by roost-apply push).
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
install -m 0644 "$REMOTE_DIR/files/sshd/50-clip-forward.conf" /etc/ssh/sshd_config.d/50-clip-forward.conf
systemctl restart ssh

ok "SSH hardened via $DROPIN; socket-forward drop-in installed"
