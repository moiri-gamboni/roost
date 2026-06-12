---
name: pastebin
description: Publish text or markdown as an end-to-end-encrypted paste with a public shareable link, using the self-hosted PrivateBin at https://paste.${DOMAIN}/. Use when the user asks to publish, share, or paste a document, note, report, or snippet for someone else — especially recipients outside the tailnet. Also covers reading and deleting existing pastes via pbincli.
---

# PrivateBin (paste.${DOMAIN})

Self-hosted zero-knowledge pastebin. Encryption and decryption happen client
side; the server stores ciphertext only. The decryption key is the URL
fragment after `#` and never reaches the server — anyone holding the full
link can decrypt, so treat links to sensitive content as secrets themselves.

The public hostname is **read-only** (Caddy rejects tunnel-tagged write
methods with 403). Pastes are created only from this server, through the
loopback origin.

## Publish

`pbincli` (a uv tool on PATH) is preconfigured in
`~/.config/pbincli/pbincli.conf` to use the loopback origin
`http://127.0.0.1:8095/` — the only endpoint that accepts writes:

```bash
OUT=$(pbincli send --format markdown --expire 1week --json --text "$(cat document.md)")
echo "$OUT" | jq -r '.result.link, .result.deletelink' \
  | sed 's|http://127.0.0.1:8095|https://paste.${DOMAIN}|'
```

**Always rewrite the host** in `link`/`deletelink` to
`https://paste.${DOMAIN}/` before sharing, as above — the paste id and key
are host-independent, so the rewritten links work for anyone.

- **Default to `--format markdown`** (also the instance default; renders
  headings, lists, links). Use `syntaxhighlighting` for code, `plaintext`
  for raw text.
- **Always pass `--expire` explicitly** (pbincli's own default is 1day).
  Choices: `5min 10min 1hour 1day 1week 1month 1year never`. Default to
  `1week`; prefer `1month`/`1year` for documents meant to stay up; confirm
  with the user before `never`.
- Other flags: `--burn` (destroy after first read), `--password PW` (extra
  passphrase on top of the URL key), `--file PATH` (attach a file).
- `--json` prints `{status, result: {id, password, deletetoken, link,
  deletelink}}` — `password` here is the URL key, not `--password`.

**Always report back:** the rewritten public link, the rewritten delete link
(or token), and the expiry chosen.

## Read / delete

```bash
pbincli get "https://paste.${DOMAIN}/?<id>#<key>"   # saves text to paste-<id>.txt in cwd (-o DIR to redirect)
pbincli delete "pasteid=<id>&deletetoken=<token>"   # runs via loopback (public side is read-only)
```

## Notes

- Loopback is exempt from the per-IP rate limit, so bulk publishing needs no
  delays between sends.
- The public web UI renders pastes for anyone but its Send button fails with
  403 by design; comments (discussion) are disabled instance-wide.
- Tokened delete links still work publicly — deletion is a GET authorized by
  the secret token in the link.
- Server layout (repo: `files/privatebin/`): php8.3-fpm pool `privatebin` +
  Caddy on `127.0.0.1:8095` (write gate in `privatebin.caddy`), public
  ingress via the Cloudflare Tunnel fragment
  `~/roost/cloudflared/apps/privatebin.yml`, pastes in
  `/var/lib/privatebin/data`, config in `/etc/privatebin/conf.php`.
