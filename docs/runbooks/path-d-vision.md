# Runbook: Path D (Vision) not working or never selected

Path D = VLESS + XTLS-Vision over TLS on `:8443`, cert at `/etc/roost-travel/vision-cert/`. Provisioning and design: `files/travel/CLAUDE.md`.

1. **Cert health:** `sudo openssl x509 -checkend 604800 -noout -in /etc/roost-travel/vision-cert/fullchain.cer && echo OK`. Fail = renewal stuck: `journalctl -u vision-cert-renew` for the last run, or rerun with `sudo systemctl start vision-cert-renew.service`. If the timer never fired: `systemctl list-timers vision-cert-renew.timer`.
2. **Listener health:** `sudo roost-net test` exercises the loopback + fallback chain; `[PASS] vision fallback responds` is end-to-end.
3. **xray-side errors:** `journalctl -u xray --since '5 minutes ago' | grep -iE 'vision|tls|cert'`. Cert path mismatch and permissions (xray reads via group `xray`) are the typical first-deploy bugs.
4. **Abuse signals:** `sudo cat /var/lib/roost-travel/vision-seen-ips.txt` lists every IP that has ever hit the Vision inbound; `vision-abuse-watch.sh` ntfys novel ones daily. A sudden spike → rotate `XRAY_UUID` with `roost-net rotate-keys` and re-distribute client configs (`singbox-client-deploy.md`).
