# Runbook: attention queue credentials, updates and recovery

The attention queue (`~/roost/code/attention-queue`) reads a headless Beeper Desktop on this box through a self-hosted Slack bridge. Three credentials can expire and one binary can need rolling; this is what to do for each. Design and state reference: `files/beeper/CLAUDE.md`; the pass itself: the clone's README.

## What runs where

| Piece | Unit / schedule | Runs as | Log |
|---|---|---|---|
| Egress allowlist (iptables + ip6tables chains for the `beeper` uid) | `beeper-egress.service` at boot; `beeper-egress-ensure.timer` every 5 min; also `ExecStartPre` of the server | root | `journalctl -t roost/beeper-egress`; rejects: `sudo journalctl -k \| grep beeper-reject` |
| Beeper Server (Desktop API on `127.0.0.1:23373`) | `beeper-server.service` | `beeper` | `sudo journalctl -u beeper-server`; `/var/lib/beeper-server/data/logs/` |
| Slack bridge (`mautrix-slack` through `bbctl run`) | `attention-bridge@slack.service` | moiri | `sudo journalctl -u attention-bridge@slack`; `~/.local/share/bbctl/prod/sh-slack/logs/bridge.log` (JSON, rotated) |
| The pass (`aq pass`) | cron, every quarter hour (`/etc/cron.d/roost-mirrors`) | moiri | `~/.local/state/attention-queue/pass.log`; API log `~/.local/state/attention-queue/api-log/` |
| Dead-man | every 5 min inside `health-check.sh` | moiri | `journalctl -t roost/health-check` |

Everything is enabled and returns after a reboot (`setup/attention-queue.sh` does the enabling; `roost-apply push` never does). To check after a reboot:

```bash
for u in beeper-egress.service beeper-egress-ensure.timer beeper-server.service attention-bridge@slack.service; do
    printf '%-32s %s %s\n' "$u" "$(systemctl is-active "$u")" "$(systemctl is-enabled "$u")"
done
sudo iptables -S OUTPUT | grep beeper-egress && sudo ip6tables -S OUTPUT | grep beeper-egress
~/roost/code/attention-queue/aq pass --dry-run; echo "exit $?"
```

Every failure below also shows up as a line in the `Service health alert` ntfy within five minutes; the lines name the check.

## The Beeper Server setup token

`~/.config/attention-queue/beeper-token` (0600) is the Matrix access token the headless login handed back; the pass and the dead-man send it as the bearer.

- **How expiry shows.** `aq pass` exits 1 with a 401 body in `~/.local/state/attention-queue/api-log/<today>.jsonl`; the dead-man reports `Beeper accounts unreadable` and, three slots later, `attention queue: last pass N min ago`. Beeper Server itself keeps running: the token gates the API, not the server's own session.
- **Where to re-authenticate.** On the box, against the API, no token needed for these calls:

  ```bash
  API=http://127.0.0.1:23373
  RID=$(curl -sf -X POST $API/v1/app/setup/start | jq -r .setupRequestID)
  curl -sf -X POST $API/v1/app/setup/email -H 'Content-Type: application/json' \
      -d "{\"setupRequestID\":\"$RID\",\"email\":\"<the account's email>\"}"      # 204; code arrives by mail
  curl -sf -X POST $API/v1/app/setup/response -H 'Content-Type: application/json' \
      -d "{\"setupRequestID\":\"$RID\",\"response\":\"<code>\"}" | jq -r .matrix.accessToken > ~/.config/attention-queue/beeper-token
  chmod 600 ~/.config/attention-queue/beeper-token
  ```

  An account that already exists logs straight in (reply shape: `attention-queue/captures/v1-app-setup-response-redacted.json`). Then `aq pass --dry-run` must exit 0.
- **From the phone?** No: the calls run on the box. A Claude session over SSH can run them; the code lands in the account's mailbox.
- **Meanwhile.** The bridge is unaffected (it does not use this token); messages keep flowing into Beeper. The board goes stale and nudges stop until the pass runs again.

## The bridge manager login (`bbctl`)

`~/.config/bbctl/config.json` holds the `bbctl` access token for the Beeper account. The bridge reads it at start to fetch its registration; a running bridge does not need it again.

- **How expiry shows.** Only at the next bridge start: `attention-bridge@slack` fails and restarts every 10 s, `sudo journalctl -u attention-bridge@slack` shows the login error, the dead-man reports `attention-bridge@slack.service not running` and the Slack account as not `connected`.
- **Where to re-authenticate.** On the box: `bbctl login` (emailed code), then `sudo systemctl restart attention-bridge@slack`.
- **From the phone?** No; SSH.
- **Meanwhile.** Nothing bridges: Slack messages arriving while the bridge is down are backfilled when it reconnects (the bridge backfills on start).

## The Slack session

The bridge holds a Slack browser session (`xoxc-` token + `xoxd-` cookie) in `~/.local/share/bbctl/prod/sh-slack/mautrix-slack.db`, obtained with `login token` because Slack's email login demands a CAPTCHA the command interface cannot show.

- **How expiry shows.** The bridge stays up but the login goes bad: `GET /v1/accounts` shows `sh-slack_…` with a status other than `connected` (`bad-credentials` in the bridge's state), the dead-man reports `Beeper account not connected: sh-slack_… <status>`, and the bridge bot posts in its control chat. `aq pass` then alarms `account matched zero chats` once the chats stop listing.
- **Where to re-authenticate.** In the bridge's control chat (the DM with `@sh-slackbot:beeper.local`, room `!6FrQeeevFdLaH0k16dqQ:beeper.local`): send `login token`, then paste the `xoxc-…` token and the `xoxd-…` cookie value from a logged-in Slack web session (browser dev tools, `api.slack.com` requests or the `d` cookie on `app.slack.com`). No unit restart needed.
- **From the phone?** The command and the paste, yes, from the Beeper app. Getting the token and cookie out of a browser session realistically needs a desktop browser.
- **Meanwhile.** Existing chats stay readable; nothing new arrives from Slack and nothing sent from Beeper reaches Slack. Once logged in again the bridge backfills.

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
FEED='https://api.beeper.com/desktop/update-feed.json?bundleID=com.automattic.beeper.server&platform=linux&channel=stable&arch=x64'
curl -s "$FEED" | jq '{version, url, sha512, pub_date}'
V=$(curl -s "$FEED" | jq -r .version)
sudo curl -fsSL -o "/opt/beeper-server/beeper-server-$V-linux-x64.tar.gz" "$(curl -s "$FEED" | jq -r .url)"
[ "$(sudo openssl dgst -sha512 -binary "/opt/beeper-server/beeper-server-$V-linux-x64.tar.gz" | base64 -w0)" = "$(curl -s "$FEED" | jq -r .sha512)" ] && echo sha512 OK
sudo mkdir -p "/opt/beeper-server/$V" && sudo tar -C "/opt/beeper-server/$V" --strip-components=1 -xzf "/opt/beeper-server/beeper-server-$V-linux-x64.tar.gz"
sudo ln -sfn "$V" /opt/beeper-server/current && sudo systemctl restart beeper-server
curl -s http://127.0.0.1:23373/v1/info | jq -r .app.version
curl -s -H "Authorization: Bearer $(cat ~/.config/attention-queue/beeper-token)" http://127.0.0.1:23373/v1/accounts | jq -r '.[] | "\(.accountID) \(.status)"'
~/roost/code/attention-queue/aq pass --dry-run > /dev/null; echo "exit $?"
```

If the sha512 line does not print, delete the tarball and stop. After a good update, watch `sudo journalctl -k | grep beeper-reject` for a reject to an address outside the telemetry hosts: a new version wanting a new host shows up there (and in the dead-man as `beeper rejects to unlisted destinations`), and the fix is a line in `files/beeper/egress-hosts` pushed with `roost-apply`. Then bump `BEEPER_SERVER_VERSION` and `BEEPER_SERVER_SHA512` in `files/setup/attention-queue.sh` so a rebuilt box installs the version that is running. Remove the version before the previous one once the new one has run a day.

## Rebuild or update the bridge binaries

`bbctl` and `mautrix-slack` are built here from pinned release tags with the pure-Go crypto backend, never downloaded (bbctl's own download path has no checksum). Versions and the build command are in `files/beeper/CLAUDE.md`. To move to a new tag: build into `~/.local/share/bbctl/built/mautrix-slack-<tag>`, point the `mautrix-slack` symlink at it, `sudo systemctl restart attention-bridge@slack`, confirm `Received hello event from websocket (now really connected)` in `sudo journalctl -u attention-bridge@slack`, and record the new tag. The previous binary stays beside it for rollback (flip the symlink back, restart).

## The egress policy after a firewall change

`ufw reload`, `ufw disable`/`enable` and `systemctl restart ufw` flush the built-in chains, which drops the `beeper-egress` hook from `OUTPUT` (the chain itself survives). The ensure timer restores it within five minutes and the dead-man's probe runs ensure itself when it fails; to close the window at once: `sudo systemctl restart beeper-egress` (or `sudo beeper-egress ensure`). Never `beeper-egress down` while Beeper Server runs: it leaves the user unfiltered until the next ensure.

To see what the policy is refusing: `sudo journalctl -k --since -1h | grep beeper-reject | sed -E 's/.*DST=([^ ]+).*DPT=([0-9]+).*/\1:\2/' | sort | uniq -c`. Rejects to `rudderstack.beeper-tools.com`, `es.beeper-tools.com` and `o248881.ingest.us.sentry.io` (resolve them to compare) are the policy working, at a steady 200 or so an hour.
