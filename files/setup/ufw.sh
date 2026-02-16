#!/bin/bash
# Configure UFW: deny all incoming except Tailscale.
source "$(dirname "$0")/../_setup-env.sh"

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow in on tailscale0 >/dev/null
ufw --force enable >/dev/null
echo "  [+] UFW: deny all incoming except Tailscale"
