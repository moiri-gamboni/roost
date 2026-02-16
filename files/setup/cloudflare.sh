#!/bin/bash
# Install cloudflared binary (auth and tunnel creation handled by deploy.sh).
source "$(dirname "$0")/../_setup-env.sh"

if command -v cloudflared &>/dev/null; then
    echo "  [-] cloudflared already installed (already done)"
else
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
        -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
    echo "  [+] cloudflared installed"
fi
