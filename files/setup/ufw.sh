#!/bin/bash
# Configure UFW: deny all incoming except Tailscale.
source "$(dirname "$0")/../_setup-env.sh"

# Only reset if rules don't already match expected state
if ufw status | grep -q 'tailscale0.*ALLOW' && \
   ufw status | grep -q '22/tcp.*ALLOW' && \
   ufw status | grep -q 'Status: active'; then
    skip "UFW already configured"
else
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow in on tailscale0 >/dev/null
    # Allow SSH so the Hetzner cloud firewall controls public SSH access.
    # When the cloud firewall SSH rule is removed, traffic never reaches the
    # server, so this UFW rule doesn't weaken security.
    ufw allow 22/tcp >/dev/null
    ufw --force enable >/dev/null
    ok "UFW: deny all incoming except Tailscale + SSH"
fi
