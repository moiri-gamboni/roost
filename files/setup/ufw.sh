#!/bin/bash
# Configure UFW: deny all incoming except Tailscale.
source "$(dirname "$0")/../_setup-env.sh"

# Only reset if rules don't already match expected state
if ufw status | grep -q 'tailscale0.*ALLOW' && \
   ufw status | grep -q 'Status: active'; then
    skip "UFW already configured"
else
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow in on tailscale0 >/dev/null
    ufw --force enable >/dev/null
    ok "UFW: deny all incoming except Tailscale"
fi
