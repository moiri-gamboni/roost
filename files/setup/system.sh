#!/bin/bash
# System updates and base packages.
source "$(dirname "$0")/../_setup-env.sh"

apt update && apt upgrade -y
echo "  [+] System updated"

apt install -y tmux build-essential jq unzip btrfs-progs snapper glances
echo "  [+] Base packages installed"
