# Runbook: deploy a sing-box client config change (in-country safe)

For changes to `files/scripts/roost-net.sh`'s client rendering (`render_android` and friends) while the user depends on the tunnel. Server-side nothing restarts; the change lands on the next client refresh, so the risk is entirely in the client swap. Background: `files/travel/CLAUDE.md`.

1. **Pre-flight.** On the laptop: `dpkg -s sing-box | awk '/^Version:/ {print $2}'`. Note the Android version from the sing-box app's About screen. Anything unfamiliar → sidecar-test the DoH-with-urltest-detour pattern first (sing-box issue #3792).
2. **Deploy server-side** over the existing eSIM-routed sing-box or Tailscale: `roost-apply push files/scripts/roost-net.sh`.
3. **Refresh the laptop:** `roost-travel config` (auto-restarts the unit if active; ~3-15s gap; the atomic-swap fallback keeps the previous config if the new one fails `sing-box check`).
4. **Refresh Android:** from the laptop `roost-net client android --send-tailscale <peer>` (via `files/laptop/travel-clients.sh`), then re-import in the sing-box app. Verify the active profile name.
5. **Verify:** `bash files/laptop/travel-test.sh` must include a `DNS via tunnel: example.com -> ...` PASS line; curl through the tunnel works.
6. **Rollback:** `git revert <commit>` + `roost-apply push files/scripts/roost-net.sh` + `roost-travel config`. Realistic 60-120s. Tailscale stays up throughout (independent transport).
