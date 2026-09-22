# beeper/ — Beeper Server egress containment

Beeper Server (the headless Beeper Desktop that the attention queue in `~/roost/code/attention-queue` reads over `127.0.0.1:23373`) is closed source and ships product analytics with no working opt-out, so it runs as its own system user, `beeper`, behind a default-deny egress policy. Plan and rationale: `~/roost/apart-research/plans/attention-queue.md`.

## Files

- `beeper-egress.sh` → `/usr/local/sbin/beeper-egress` (root). `up` resolves the allowlist, builds the `beeper-egress` chain in both `iptables` and `ip6tables`, and hooks it into `OUTPUT` for `--uid-owner beeper`; `ensure` re-resolves and rebuilds when the address set differs from the one last applied, or a chain, its final REJECT, or a hook is missing; `down` removes both (the user is then unfiltered). The chain is loopback ACCEPT, then TCP 443 ACCEPT per address, then LOG (`beeper-reject: `, rate-limited per destination so a telemetry burst cannot hide a needed host), then REJECT. It is replaced whole by `iptables-restore --noflush`, which commits atomically, so a refresh never passes through a state without the REJECT.
- `egress-hosts` → `/etc/beeper-egress/hosts`: the allowlist, one host per line with why.

## State and inspection

- `/var/lib/beeper-egress/addresses`: the union of every address ever resolved for the hosts still listed (`<address> <host>`), so a DNS rotation can add addresses but never strand the server; removing a host from the list drops its addresses on the next `ensure`. `addresses.applied` is the set last applied in both families, written only after both succeed, so a failed apply is retried on the next run. Runs take a lock (`/run/beeper-egress.lock`), so the timer and a server start never interleave.
- Rejected traffic: `sudo journalctl -k | grep 'beeper-reject: '` (the kernel journal needs root). A reject to a known telemetry host is the policy working; a reject to anything else means Beeper needs a host the list lacks.
- The chain: `sudo iptables -S beeper-egress`, `sudo ip6tables -S beeper-egress`.
- The chain is the only per-uid rule this policy puts in `OUTPUT` (`-j beeper-egress`, not `-j REJECT`), and the travel VPN's kill-switch checks match xray's own uid, so neither policy's checks can pass on the other's rules.

## Paths

- `/opt/beeper-server/<version>/beeper-server` with `current` → the running version, plus the vendor tarball beside it for rollback; the feed publishes a sha512 to check a download against (`https://api.beeper.com/desktop/update-feed.json?bundleID=com.automattic.beeper.server&platform=linux&channel=stable&arch=x64`).
- `/var/lib/beeper-server` (0700 `beeper`): the user's home; `.cache/BeeperServer/` is where the binary unpacks itself, `data/` is `--data-dir` (message store, logs, `config.json` with `sentry_disabled`).
- `~/.local/share/bbctl/built/`: `bbctl` and the bridges, built here from pinned release tags rather than downloaded (bbctl's own download path has no checksum). Bridges build with the pure-Go crypto backend, `./build.sh -tags goolm -o <path>` in a checkout of the tag, and run through `bbctl run --custom-startup-command <path> sh-<type>`; `~/.local/bin/bbctl` and the unversioned bridge names are symlinks to the current build.
- `/opt/beeper-server` and `/var/lib/beeper-server`, plus the bridges' `~/.local/share/bbctl` and the queue's `~/.local/state/attention-queue`, are nested btrfs subvolumes: decrypted message text stays out of snapper snapshots and the off-site backup.

Beeper Server and the one-minute `ensure` currently run as transient units started by hand (`systemctl status beeper-server beeper-egress-ensure.timer`); they do not survive a reboot, and nothing runs unfiltered after one because nothing starts.
