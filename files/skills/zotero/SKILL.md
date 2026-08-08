---
name: zotero
description: This skill should be used when working with a Zotero library — summarizing or reading attached PDFs, organizing items into collections, tagging, adding notes, linking related items, or batch-processing references. Trigger on "Zotero", "my library", "references", "organize my papers/notes", "summarize these PDFs" in a research-library context. Covers the local read API, pyzotero for writes, and direct storage reads for bulk PDF work.
---

# Zotero

Read and batch-manipulate the local Zotero library. Three access paths — pick per operation, and for bulk work write Python scripts (via `uv run`) rather than driving item-by-item.

## Access paths

1. **Direct storage reads — fastest, for PDF/attachment content.** Attachments live at `~/Zotero/storage/<8-char-key>/<file>`. Get the mapping from the API (attachment items carry the key; `zot.dump()`/`zot.file()` fetch content). For bulk text extraction prefer `pdftotext file.pdf -` (poppler, installed by guest-bootstrap) over vision-reading; use the Read tool on the PDF only when layout/figures matter.

2. **Local API — reads, no key, Zotero app must be running.** Read-only mirror of web API v3 at `http://127.0.0.1:23119/api/`. Requires Zotero ≥7 with Settings → Advanced → "Allow other applications on this computer to communicate with Zotero" enabled. pyzotero: `zotero.Zotero(library_id, 'user', local=True)`.

3. **Web API via pyzotero — all writes.** Needs the numeric library/user ID (zotero.org → Settings → Security, "Your userID") and an API key with write access (zotero.org/settings/keys). Store the key at `~/.config/zotero/api-key` (0600), never in scripts. Writes land server-side and sync back to the desktop app on its next sync.

Never write `zotero.sqlite` directly — schema is internal and the app corrupts easily; the API paths above are the only sanctioned writes.

## Script skeleton

```bash
uv run --with pyzotero python - <<'PY'
from pyzotero import zotero
from pathlib import Path

key = Path.home().joinpath(".config/zotero/api-key").read_text().strip()
zot = zotero.Zotero(LIBRARY_ID, "user", key)          # writes
# zot = zotero.Zotero(LIBRARY_ID, "user", local=True) # fast reads, app running

items = zot.everything(zot.top(itemType="-attachment || note"))  # paginates for you
PY
```

## Batch patterns

- **Iterate:** always `zot.everything(...)` (handles the 100-item pagination), or `zot.iterfollow()` for streaming.
- **Summaries → child notes:** create `note` items with `parentItem: <item key>` and a marker tag (e.g. `ai-summary`). Idempotency: before writing, skip items that already have a child note carrying the tag — makes reruns safe.
- **Write in chunks of ≤50** — the web API caps items per `create_items`/`update_items` call. Check the returned `successful`/`failed` dict per chunk; on HTTP 412 (version conflict) re-fetch the item and retry, and back off on 429 honoring `Retry-After`.
- **Collections:** `zot.create_collections([...])`, assign with `zot.addto_collection(coll_key, item)`; collections nest via `parentCollection`.
- **Links between items:** set the item's `relations` field: `{"dc:relation": ["http://zotero.org/users/<userID>/items/<KEY>", ...]}` — shows up as "Related" in the app, and works bidirectionally once both sides are written.
- **Synthesis documents:** for cross-item syntheses, standalone Zotero notes get unwieldy; prefer markdown files in the project, deep-linking items as `zotero://select/library/items/<KEY>` (clickable, opens the app on the item).
- **Templates:** `zot.item_template("note")` etc. for correct field scaffolding before create.

pyzotero also ships an optional CLI and MCP server (same local-API requirement); for at-scale pipelines prefer scripts — per-call tool overhead dominates on hundreds of items.

## Setup on a new device

1. Zotero app installed by guest-bootstrap (deb repo on Ubuntu — self-update disabled, apt handles upgrades; cask on macOS). Sign in and let the library finish syncing (storage files download lazily; "Sync full-text content" + attachment download settings matter for bulk PDF work).
2. Enable the local-API setting (Advanced, see above).
3. Create the API key, store per above, smoke-test with the skeleton (`zot.count_items()`).
