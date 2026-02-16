#!/bin/bash
# Install Tailscale (does NOT authenticate; auth is handled by deploy.sh).
source "$(dirname "$0")/../_setup-env.sh"

if command -v tailscale &>/dev/null; then
    echo "  [-] Tailscale already installed (already done)"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "  [+] Tailscale installed"
fi
