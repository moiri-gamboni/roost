#!/bin/bash
# Install Eternal Terminal (et) from the official PPA.
# Config (/etc/et.cfg) is deployed by roost-apply from files/et.cfg.
source "$(dirname "$0")/../_setup-env.sh"

# Add PPA if not already present
PPA_LIST="/etc/apt/sources.list.d/jgmath2000-ubuntu-et-noble.sources"
if [ ! -f "$PPA_LIST" ] && ! grep -rq 'jgmath2000/et' /etc/apt/sources.list.d/ 2>/dev/null; then
    info "Adding ppa:jgmath2000/et..."
    add-apt-repository -y ppa:jgmath2000/et
    apt-get update
    ok "PPA added"
else
    skip "ppa:jgmath2000/et already configured"
fi

if command -v etserver >/dev/null 2>&1; then
    skip "et already installed ($(dpkg-query -W -f='${Version}' et 2>/dev/null))"
else
    apt-get install -y et
    ok "et installed"
fi

# The package ships an et.service that reads /etc/et.cfg. Enable it now; the
# config rendered by roost-apply (with bind_ip = $TAILSCALE_IP) will be in
# place before the first `systemctl restart et` fires from the manifest.
if ! systemctl is-enabled et.service >/dev/null 2>&1; then
    systemctl enable et.service
    ok "et.service enabled"
else
    skip "et.service already enabled"
fi
