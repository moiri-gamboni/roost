#!/bin/bash
# Install cloudflared via official Cloudflare apt repository.
# Auth and tunnel creation handled by deploy.sh.
source "$(dirname "$0")/../_setup-env.sh"

if command -v cloudflared &>/dev/null; then
    echo "  [-] cloudflared already installed (already done)"
else
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
        | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update
    apt-get install -y cloudflared
    echo "  [+] cloudflared installed"
fi
