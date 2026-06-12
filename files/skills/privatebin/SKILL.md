---
name: privatebin
description: Publish text or markdown as an end-to-end-encrypted paste with a public shareable link, using the self-hosted PrivateBin at https://paste.${DOMAIN}/. Use when the user asks to publish, share, or paste a document, note, report, or snippet for someone else — especially recipients outside the tailnet. Also covers reading and deleting existing pastes via pbincli.
---

# PrivateBin (paste.${DOMAIN})

Self-hosted zero-knowledge pastebin. Encryption and decryption happen client
side; the server stores ciphertext only. The decryption key is the URL
fragment after `#` and never reaches the server — anyone holding the full
link can decrypt, so treat links to sensitive content as secrets themselves.

## Publish

Use `pbincli` (a uv tool on PATH; the server URL is preset in
`~/.config/pbincli/pbincli.conf`):

```bash
pbincli send --format markdown --expire 1week --json --text "$(cat document.md)"
echo "quick note" | pbincli send --format markdown --expire 1week --json -
```

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

**Always report back:** the full paste link, the delete link (or token), and
the expiry chosen.

## Read / delete

```bash
pbincli get "https://paste.${DOMAIN}/?<id>#<key>"      # saves text to paste-<id>.txt in cwd (-o DIR to redirect)
pbincli delete "pasteid=<id>&deletetoken=<token>"
```

## Notes

- Paste creation is rate-limited to one per 10 s per client IP. If a send
  fails with a traffic-limit error, wait ~10 s and retry. For bulk publishing,
  `--server http://127.0.0.1:8095/` skips the limit (loopback is exempt) but
  the printed link will carry the loopback host — swap it for
  `https://paste.${DOMAIN}/` before sharing.
- The web UI at https://paste.${DOMAIN}/ is public; anyone with the URL can
  create pastes there too (it also defaults to markdown).
- Server layout (repo: `files/privatebin/`): php8.3-fpm pool `privatebin` +
  Caddy on `127.0.0.1:8095`, public ingress via the Cloudflare Tunnel fragment
  `~/roost/cloudflared/apps/privatebin.yml`, pastes in
  `/var/lib/privatebin/data`, config in `/etc/privatebin/conf.php`.
