#!/bin/bash
# One-shot initialiser for Vision (Path D) wildcard cert.
#
# Issues *.$DOMAIN via Let's Encrypt + acme.sh DNS-01 against Cloudflare.
# Idempotent: if a non-expiring cert already exists at the install path,
# exits 0 without contacting LE. Run as root (the cert/key files end up
# owned root:xray with mode 0640/0600 so xray can read them).
#
# Required env on first run:
#   CF_Token  -- Cloudflare API token with Zone:DNS:Edit on $DOMAIN's zone.
#                (The CLOUDFLARE_API_TOKEN from the laptop's .env is the
#                same value.) acme.sh persists this into account.conf so
#                subsequent renewals via the timer don't need it.
#   DOMAIN    -- Apex domain to issue *.$DOMAIN under (provided by
#                _setup-env.sh in the deploy chain, or .sync-env when run
#                manually as moiri).
#
# Standard idiomatic invocation:
#   sudo CF_Token=$CLOUDFLARE_API_TOKEN DOMAIN=$DOMAIN \
#       /etc/roost-travel/vision-cert-init.sh
set -euo pipefail

CERT_HOME=/etc/roost-travel/vision-cert
CONFIG_HOME=/etc/roost-travel/acme-config
INSTALL_FULLCHAIN="$CERT_HOME/fullchain.cer"
INSTALL_KEY="$CERT_HOME/private.key"
ACME_HOME=/root/.acme.sh
ACME_BIN="$ACME_HOME/acme.sh"
LE_EMAIL_DEFAULT="acme@${DOMAIN:-localhost}"
RENEWAL_THRESHOLD_DAYS=30

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root" >&2
    exit 1
fi

: "${DOMAIN:?DOMAIN env var required (apex domain to issue *.\$DOMAIN under)}"

# Idempotency: skip if cert already exists and isn't due for renewal.
if [ -f "$INSTALL_FULLCHAIN" ] \
        && openssl x509 -checkend $(( RENEWAL_THRESHOLD_DAYS * 86400 )) \
            -noout -in "$INSTALL_FULLCHAIN" >/dev/null 2>&1; then
    echo "Vision cert already exists at $INSTALL_FULLCHAIN and is fresh (>${RENEWAL_THRESHOLD_DAYS}d). Skipping."
    exit 0
fi

# Install acme.sh if not present. The official installer's `email=` arg sets
# the default LE registration email; we register explicitly below so the value
# here just satisfies the installer's requirement.
if [ ! -x "$ACME_BIN" ]; then
    echo "Installing acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s "email=$LE_EMAIL_DEFAULT"
fi

# Disable acme.sh's self-update path (we route updates through auto-update.sh
# in plans/add-stealth-protocols.md Task 11 instead, to keep with the cooldown
# + GitHub-release-tracked update discipline of the rest of the stack).
"$ACME_BIN" --upgrade --auto-upgrade 0 >/dev/null

install -d -m 0700 -o root -g root "$CERT_HOME" "$CONFIG_HOME"

# Register the LE account if not already done. acme.sh defaults to ZeroSSL;
# pin --server letsencrypt to keep the CA explicit (and to comply with the
# "no surprise CA changes" policy).
if [ ! -f "$CONFIG_HOME/account.conf" ]; then
    : "${CF_Token:?CF_Token env var required (Cloudflare API token, Zone:DNS:Edit)}"
    "$ACME_BIN" --register-account \
        --server letsencrypt \
        --config-home "$CONFIG_HOME" \
        --accountemail "$LE_EMAIL_DEFAULT"
fi

# Issue. Wildcard requires DNS-01 (CF). We pass the bare domain too because
# `*.example.com` does NOT cover `example.com` itself, and a future use may
# need the apex SAN (cheap insurance, same TXT-record dance either way).
: "${CF_Token:?CF_Token env var required (Cloudflare API token, Zone:DNS:Edit)}"
export CF_Token
"$ACME_BIN" --issue \
    --server letsencrypt \
    --dns dns_cf \
    -d "$DOMAIN" \
    -d "*.$DOMAIN" \
    --config-home "$CONFIG_HOME" \
    --cert-home "$CERT_HOME"

# Install cert + key to the path xray reads from. install-cert renames/copies;
# subsequent --cron renewals re-trigger the same paths. The -d here is the
# CERT NAME (acme.sh's term: first -d at issuance), not a per-SAN identifier.
# We issued with `-d $DOMAIN -d *.$DOMAIN` so the cert name is $DOMAIN.
"$ACME_BIN" --install-cert \
    -d "$DOMAIN" \
    --config-home "$CONFIG_HOME" \
    --cert-home "$CERT_HOME" \
    --fullchain-file "$INSTALL_FULLCHAIN" \
    --key-file "$INSTALL_KEY"

# xray needs read access; cert is non-secret (public CA-issued), key is.
chgrp xray "$INSTALL_FULLCHAIN" "$INSTALL_KEY"
chmod 0640 "$INSTALL_FULLCHAIN"
chmod 0640 "$INSTALL_KEY"

echo "Vision cert installed at $INSTALL_FULLCHAIN (key at $INSTALL_KEY)"
