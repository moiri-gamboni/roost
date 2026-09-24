# Runbook: attention queue credentials, updates and recovery

The attention queue (`~/roost/code/attention-queue`) reads a headless Beeper Desktop on this box through self-hosted Slack, Discord and email bridges. Five credentials can expire and one binary can need rolling; this is what to do for each. Design and state reference: `files/beeper/CLAUDE.md`; the pass itself: the clone's README.

## What runs where

| Piece | Unit / schedule | Runs as | Log |
|---|---|---|---|
| Egress allowlist (iptables + ip6tables chains for the `beeper` uid) | `beeper-egress.service` at boot; `beeper-egress-ensure.timer` every 5 min; also `ExecStartPre` of the server | root | `journalctl -t roost/beeper-egress`; rejects: `sudo journalctl -k \| grep beeper-reject` |
| Beeper Server (Desktop API on `127.0.0.1:23373`) | `beeper-server.service` | `beeper` | `sudo journalctl -u beeper-server`; `/var/lib/beeper-server/data/logs/` |
| Slack bridge (`mautrix-slack` through `bbctl run`) | `attention-bridge@slack.service` | moiri | `sudo journalctl -u attention-bridge@slack`; `~/.local/share/bbctl/prod/sh-slack/logs/bridge.log` (JSON, rotated) |
| Discord bridge (`mautrix-discord` through `bbctl run`) | `attention-bridge@discord.service` | moiri | `sudo journalctl -u attention-bridge@discord`; `~/.local/share/bbctl/prod/sh-discord/logs/` |
| Email bridge (the matrimail fork through `bbctl run`, type `bridgev2`) | `attention-bridge@email.service` + drop-in `matrimail.conf` | moiri | `sudo journalctl -u attention-bridge@email`; `~/.local/share/bbctl/prod/sh-email/logs/` |
| The pass (`aq pass`) | cron, every quarter hour (`/etc/cron.d/roost-mirrors`) | moiri | `~/.local/state/attention-queue/pass.log`; API log `~/.local/state/attention-queue/api-log/` |
| Dead-man | every 5 min inside `health-check.sh` | moiri | `journalctl -t roost/health-check` |

Everything is enabled and returns after a reboot (`setup/attention-queue.sh` does the enabling; `roost-apply push` never does). To check after a reboot:

```bash
for u in beeper-egress.service beeper-egress-ensure.timer beeper-server.service attention-bridge@slack.service attention-bridge@discord.service attention-bridge@email.service; do
    printf '%-32s %s %s\n' "$u" "$(systemctl is-active "$u")" "$(systemctl is-enabled "$u")"
done
sudo iptables -S OUTPUT | grep beeper-egress && sudo ip6tables -S OUTPUT | grep beeper-egress
~/roost/code/attention-queue/aq pass --dry-run; echo "exit $?"
```

Every failure below also shows up as a line in the `Service health alert` ntfy within five minutes; the lines name the check.

## The Beeper Server setup token

`~/.config/attention-queue/beeper-token` (0600) is the Matrix access token the headless login handed back; the pass and the dead-man send it as the bearer.

- **How expiry shows.** `aq pass` exits 1 with a 401 body in `~/.local/state/attention-queue/api-log/<today>.jsonl`; the dead-man reports `Beeper accounts unreadable` and, three slots later, `attention queue: no pass for over 45 min`. Beeper Server itself keeps running: the token gates the API, not the server's own session.
- **Where to re-authenticate.** On the box, against the API. Untested for re-authentication: this sequence has run once, for the first login, before any account was set up on the server, so whether it logs in again while one is set up is unknown. The API spec marks these three calls as needing no token, but `GET /v1/app/setup`, which it marks optional-auth, answers 401 without one today, so a 401 here is possible:

  ```bash
  API=http://127.0.0.1:23373
  RID=$(curl -sf -X POST $API/v1/app/setup/start | jq -r .setupRequestID)
  curl -sf -X POST $API/v1/app/setup/email -H 'Content-Type: application/json' \
      -d "{\"setupRequestID\":\"$RID\",\"email\":\"<the account's email>\"}"      # 204; code arrives by mail
  curl -sf -X POST $API/v1/app/setup/response -H 'Content-Type: application/json' \
      -d "{\"setupRequestID\":\"$RID\",\"response\":\"<code>\"}" | jq -r .matrix.accessToken > ~/.config/attention-queue/beeper-token
  chmod 600 ~/.config/attention-queue/beeper-token
  ```

  At the first login the email of an existing Beeper account logged straight in, with no signup step (reply shape: `attention-queue/captures/v1-app-setup-response-redacted.json`). Then `aq pass --dry-run` must exit 0.
- **From the phone?** No: the calls run on the box. A Claude session over SSH can run them; the code lands in the account's mailbox.
- **Meanwhile.** The bridge is unaffected (it does not use this token); messages keep flowing into Beeper. The board goes stale and nudges stop until the pass runs again.

## The bridge manager login (`bbctl`)

`~/.config/bbctl/config.json` holds the `bbctl` access token for the Beeper account. The bridge reads it at start to fetch its registration; a running bridge does not need it again.

- **How expiry shows.** Only at the next bridge start: the `attention-bridge@…` units fail and restart every 10 s, `sudo journalctl -u attention-bridge@slack` (or `@discord`) shows the login error, the dead-man reports the unit `not running` and the account as not `connected`.
- **Where to re-authenticate.** On the box: `bbctl login` (emailed code), then `sudo systemctl restart attention-bridge@slack attention-bridge@discord attention-bridge@email`.
- **From the phone?** No; SSH.
- **Meanwhile.** Nothing bridges: Slack messages arriving while the bridge is down are backfilled when it reconnects (the bridge backfills on start).

## The Slack session

The bridge holds a Slack browser session (`xoxc-` token + `xoxd-` cookie) in `~/.local/share/bbctl/prod/sh-slack/mautrix-slack.db`, obtained with `login token` because Slack's email login demands a CAPTCHA the command interface cannot show.

- **How expiry shows.** The bridge stays up but the login goes bad: `GET /v1/accounts` shows `sh-slack_…` with a status other than `connected` (`bad-credentials` in the bridge's state), the dead-man reports `Beeper account not connected: sh-slack_… <status>`, and the bridge bot posts in its control chat. Once the chats stop listing, the pass records `No chats at all for sh-slack_…` and the dead-man reports it as `attention queue alarm: …`.
- **Where to re-authenticate.** In the bridge's control chat (the DM with `@sh-slackbot:beeper.local`, room `!6FrQeeevFdLaH0k16dqQ:beeper.local`): send `login token`, then paste the `xoxc-…` token and the `xoxd-…` cookie value from a logged-in Slack web session (browser dev tools, `api.slack.com` requests or the `d` cookie on `app.slack.com`). No unit restart needed.
- **From the phone?** The command and the paste, yes, from the Beeper app. Getting the token and cookie out of a browser session realistically needs a desktop browser.
- **Meanwhile.** Existing chats stay readable; nothing new arrives from Slack and nothing sent from Beeper reaches Slack. Once logged in again the bridge backfills.

## The Discord login

The bridge holds a Discord user token in `~/.local/share/bbctl/prod/sh-discord/mautrix-discord.db`, obtained with `login-token user <token>` because the QR login (`login-qr`) is scanned and approved on the phone but then refused by Discord with an hCaptcha (`captcha-required`) for a login from a server address, and the bridge cannot show one. Only the Apart server is bridged (`guilds bridge 1042030674388979713 --entire`; every other server stays at "never bridge"), plus DMs; guild channels are created muted.

- **How expiry shows.** A Discord password change, a "log out all devices", or Discord disabling the account invalidates the token: `GET /v1/accounts` shows `sh-discord_…` as not `connected`, the dead-man reports it, and the bot posts in its control chat.
- **Where to re-authenticate.** In the bridge's control chat, the encrypted DM with `@sh-discordbot:beeper.local`, room `!qK7NBaN2S5BWhFuZKJsf:beeper.local` (an earlier unencrypted DM with the bot, `!4soLg4KAMoNJbIjVFvKW:beeper.local`, is ignored: the bridge requires encryption and drops what arrives there). Send `login-token user <token>`, where the token is the `authorization` request header of any `discord.com/api/v9/…` request in a logged-in browser session (dev tools, Network tab). The bot deletes the message after reading it.
- **From the phone?** The command, yes; getting the token out of a browser realistically needs a desktop browser.
- **Meanwhile.** Existing chats stay readable; nothing new arrives from Discord. If Discord disabled the account (the enforcement risk of a non-official client, mautrix/discord #235), expect a forced password change first.

## The Gmail login

The email bridge holds a Google refresh token for moiri@apartresearch.com in `~/.local/share/bbctl/prod/sh-email/sh-email.db`, encrypted with the passphrase in `/etc/attention-queue/matrimail.env` (root, 0600). The OAuth client is a Desktop client in an Internal Google Cloud project of the Apart Workspace, so the token has no fixed expiry; its ID and secret are in the bridge's `config.yaml` (`network.gmail_oauth`) and in `~/.config/attention-queue/gmail-oauth-client.env`. The scope is `modify` (Gmail API read, label and send), which still covers the whole mailbox.

- **How expiry shows.** A password change, a revoked grant (https://myaccount.google.com/permissions) or an admin policy change kills the token: `GET /v1/accounts` shows `sh-email_…` as not `connected`, the dead-man reports it, and the bot posts a re-authorise notice in its control chat. The bridge then retries every thirty seconds indefinitely (a known upstream behaviour).
- **Where to re-authenticate.** In the bridge's control chat, the encrypted DM with `@sh-emailbot:beeper.local`, room `!ciK5fRfu0IQPoBFD0vHI:beeper.local`: send `login`, then the address, then `modify`. The bot answers with a Google URL whose redirect is `http://127.0.0.1:8765/callback` on this box. Open it in a laptop browser, allow, and either run `ssh -N -L 8765:127.0.0.1:8765 moiri@100.73.69.20` first, or copy the failed-to-load callback URL from the address bar and fetch it on the box (`curl -s '<that URL>'`): the code in it is single-use, expires in minutes and is bound to a verifier only the bridge holds. Never use the bridge's `oauth paste-token`, which puts a permanent full-mailbox token into chat history. Pick `default` (INBOX) at the folder prompt unless the watched folders are being changed on purpose.
- **From the phone?** The chat steps, yes; the callback needs the box, so a laptop or an SSH session.
- **Meanwhile.** Nothing new arrives from Gmail and nothing sent from Beeper reaches it; mail is not lost, since the bridge reads Gmail's history from its saved cursor when it reconnects (Gmail keeps about a week of history; past that the gap is skipped with a log line).
- **The passphrase.** Never change `MATRIMAIL_PASSPHRASE`: nothing re-encrypts the stored token, so a new value makes it unreadable and the bridge refuses to start. If the file is lost, delete the bridge's stored login (`logout moiri@apartresearch.com` in the control chat), create a new file and log in again.

## The recovery key

The account's cross-signing was created by Beeper Server during setup (the phone's verification never reached it), so the recovery key the user holds is the root of trust for every device, the bridge's included.

- **How loss shows.** Not as an expiry: only when a device has to be verified again (a new phone, a reset).
- **Where to re-verify.** From the phone against the existing key, or on the box with `POST /v1/app/setup/verification/recovery-key` (`{"recoveryKey": …}`).
- **Do not reset it** (`/v1/app/setup/verification/recovery-key/reset`) while the bridge is logged in: the bridge trusts the account's cross-signing on first use (`cross-signed-tofu`), so a reset makes it treat the account as a stranger and withhold room keys from every device until the bridge is logged out and in again. If a reset is unavoidable: reset, verify the phone against the new key, then `bbctl` `delete` and re-run the bridge (which registers afresh and rebuilds its portals from Slack; Beeper-side history is kept by the homeserver).
- **Meanwhile.** With the key merely lost, everything keeps running; the risk is a future device that cannot be verified.

## Roll Beeper Server back

The kept tarball and the unpacked previous build make this one symlink:

```bash
ls /opt/beeper-server                      # 4.3.123/ current -> …  beeper-server-4.3.123-linux-x64.tar.gz
sudo ln -sfn 4.3.123 /opt/beeper-server/current
sudo systemctl restart beeper-server
curl -s http://127.0.0.1:23373/v1/info | jq -r .app.version
```

The data directory (`/var/lib/beeper-server/data`) is shared across versions; a downgrade past a schema migration is the one case this cannot promise, so keep the previous version's directory until the new one has run a day.

## Update Beeper Server

Updates are manual. The server does not update itself: 4.3.144 was published on 2026-09-23 while 4.3.123 ran for 19 h with no new build in its cache. The feed publishes the version, the artifact URL and a base64 sha512:

```bash
bash -e <<'EOF'
FEED='https://api.beeper.com/desktop/update-feed.json?bundleID=com.automattic.beeper.server&platform=linux&channel=stable&arch=x64'
META=$(curl -fsS "$FEED")
jq '{version, url, sha512, pub_date}' <<<"$META"
V=$(jq -r .version <<<"$META")
if [ "$V" = "$(readlink /opt/beeper-server/current)" ]; then echo "already on $V"; exit 0; fi
TARBALL=/opt/beeper-server/beeper-server-$V-linux-x64.tar.gz
sudo curl -fsSL -o "$TARBALL" "$(jq -r .url <<<"$META")"
if [ "$(sudo openssl dgst -sha512 -binary "$TARBALL" | base64 -w0)" != "$(jq -r .sha512 <<<"$META")" ]; then
    sudo rm -f "$TARBALL"
    echo "sha512 MISMATCH: tarball deleted, nothing installed" >&2
    exit 1
fi
echo "sha512 OK"
sudo mkdir -p "/opt/beeper-server/$V"
sudo tar -C "/opt/beeper-server/$V" --strip-components=1 -xzf "$TARBALL"
sudo ln -sfn "$V" /opt/beeper-server/current
sudo systemctl restart beeper-server
EOF
```

The block stops at the first failed step; on a sha512 mismatch it has deleted the tarball and changed nothing else. Then check the new version, the accounts and a pass:

```bash
curl -s http://127.0.0.1:23373/v1/info | jq -r .app.version
curl -s -H "Authorization: Bearer $(cat ~/.config/attention-queue/beeper-token)" http://127.0.0.1:23373/v1/accounts | jq -r '.[] | "\(.accountID) \(.status)"'
~/roost/code/attention-queue/aq pass --dry-run > /dev/null; echo "exit $?"
```

After a good update, watch `sudo journalctl -k | grep beeper-reject` for a reject to an address outside the telemetry hosts: a new version wanting a new host shows up there (and in the dead-man as `beeper rejects to unlisted destinations`), and the fix is a line in `files/beeper/egress-hosts` pushed with `roost-apply`. Then bump `BEEPER_SERVER_VERSION` and `BEEPER_SERVER_SHA512` in `files/setup/attention-queue.sh` so a rebuilt box installs the version that is running. Remove the version before the previous one once the new one has run a day.

## Rebuild or update the bridge binaries

`bbctl`, `mautrix-slack`, `mautrix-discord` and `matrimail` are built here from pinned commits, never downloaded (bbctl's own download path has no checksum). Versions and the build command are in `files/beeper/CLAUDE.md`. To move to a new tag: build into `~/.local/share/bbctl/built/mautrix-slack-<tag>`, point the `mautrix-slack` symlink at it, `sudo systemctl restart attention-bridge@slack`, confirm `Received hello event from websocket (now really connected)` in `sudo journalctl -u attention-bridge@slack`, and record the new tag. The previous binary stays beside it for rollback (flip the symlink back, restart). `mautrix-slack` builds with the pure-Go crypto backend (`-tags goolm`); `mautrix-discord` v0.7.7 cannot, because its mautrix-go predates that option, so it links Ubuntu's `libolm3` and is built with plain `./build.sh -o <path>` in a checkout of the tag; the same steps apply with `@discord`. `matrimail` is built from the fork's reviewed branch in `~/roost/code/matrimail` with `./build.sh -o ~/.local/share/bbctl/built/matrimail-<short sha>` (pure-Go crypto), linked as `matrimail`, restarted with `@email`.

## The egress policy after a firewall change

On this box ufw leaves the built-in chains alone (`MANAGE_BUILTINS=no` in `/etc/default/ufw`), so `ufw reload`, `ufw disable`/`enable` and `systemctl restart ufw` keep the `beeper-egress` hook in `OUTPUT`. The hook goes when something flushes the built-in chains: a hand `iptables -F`/`-X` (or the `ip6tables` twin), another tool restoring the whole filter table, or ufw itself if `MANAGE_BUILTINS` is ever set to `yes`. The ensure timer puts it back within five minutes, and the dead-man's probe runs ensure itself when it fails. To put it back at once:

```bash
sudo beeper-egress ensure
sudo iptables -S OUTPUT | grep beeper-egress && sudo ip6tables -S OUTPUT | grep beeper-egress
```

Do not use `sudo systemctl restart beeper-egress` for this: Beeper Server `Requires=` that unit, so restarting it restarts the server too. Never `beeper-egress down` while Beeper Server runs: it leaves the user unfiltered until the next ensure.

To see what the policy is refusing: `sudo journalctl -k --since -1h | grep beeper-reject | sed -E 's/.*DST=([^ ]+).*DPT=([0-9]+).*/\1:\2/' | sort | uniq -c`. Rejects to `rudderstack.beeper-tools.com`, `es.beeper-tools.com` and `o248881.ingest.us.sentry.io` (resolve them to compare) are the policy working, at a steady 200 or so an hour.
