---
name: zotero
description: This skill should be used when working with a Zotero library — summarizing or reading attached PDFs, organizing items into collections, tagging, adding notes, linking related items, or batch-processing references. Trigger on "Zotero", "my library", "references", "organize my papers/notes", "summarize these PDFs" in a research-library context. Covers the local read API, pyzotero for writes, and direct storage reads for bulk PDF work.
---

# Zotero

Read and batch-manipulate the local Zotero library. Three access paths — pick per operation, and for bulk work write Python scripts (via `uv run`) rather than driving item-by-item.

## Access paths

1. **Direct storage reads — fastest, for PDF/attachment content.** Attachments live at `~/Zotero/storage/<8-char-key>/<file>`. Get the mapping from the API (attachment items carry the key; `zot.dump()`/`zot.file()` fetch content). For bulk text extraction prefer `pdftotext file.pdf -` (poppler, installed by guest-bootstrap) over vision-reading; use the Read tool on the PDF only when layout/figures matter.

2. **Local API — preferred whenever the app is running.** Mirror of web API v3 at `http://127.0.0.1:23119/api/`; requires Settings → Advanced → "Allow other applications on this computer to communicate with Zotero". Reads need no key (pyzotero: `zotero.Zotero(library_id, 'user', local=True)`). Writes (Zotero 10+): authorize once via `POST http://127.0.0.1:23119/api/local/authorize` with an application name — Zotero shows Allow / Always Allow / Deny; **Always Allow** returns a reusable 32-char key (plain Allow is single-use). Store it at `~/.config/zotero/local-api-key` (0600), send as a `Zotero-API-Key` header. Request/response shapes are identical to the web API (items, collections, tags, saved searches, file uploads). pyzotero's local mode is documented for reads; if it refuses writes, hit the endpoints directly (requests/curl) — same JSON.

3. **Web API via pyzotero — headless machines (no running app) or pre-10 clients.** Needs the numeric library/user ID (zotero.org → Settings → Security, "Your userID") and an API key created at zotero.org/settings/keys/new — enable **Allow write access** and **Allow notes access** (child-note writes need both). Store at `~/.config/zotero/api-key` (0600), never in scripts. Writes land server-side and sync down to the desktop app.

Never write `zotero.sqlite` directly — schema is internal and the app corrupts easily; the API paths above are the only sanctioned writes.

## Script skeleton

```bash
uv run --with pyzotero python - <<'PY'
from pyzotero import zotero
from pathlib import Path

zot = zotero.Zotero(LIBRARY_ID, "user", local=True)   # app running (reads; writes need the local key, see above)
# headless / pre-10 fallback — web API:
# key = Path.home().joinpath(".config/zotero/api-key").read_text().strip()
# zot = zotero.Zotero(LIBRARY_ID, "user", key)

items = zot.everything(zot.top(itemType="-attachment || note"))  # paginates for you
PY
```

## Batch patterns

- **Iterate:** always `zot.everything(...)` (handles the 100-item pagination), or `zot.iterfollow()` for streaming.
- **Summaries → child notes:** create `note` items with `parentItem: <item key>` and a marker tag (e.g. `ai-summary`). Idempotency: before writing, skip items that already have a child note carrying the tag — makes reruns safe.
- **Write in chunks of ≤50** — the web API caps items per `create_items`/`update_items` call. Check the returned `successful`/`failed` dict per chunk; on HTTP 412 (version conflict) re-fetch the item and retry, and back off on 429 honoring `Retry-After`.
- **Collections:** `zot.create_collections([...])`, assign with `zot.addto_collection(coll_key, item)`; collections nest via `parentCollection`.
- **Links between items:** set the item's `relations` field: `{"dc:relation": ["http://zotero.org/users/<userID>/items/<KEY>", ...]}` — shows up as "Related" in the app, and works bidirectionally once both sides are written.
- **Synthesis documents:** for cross-item syntheses, standalone Zotero notes get unwieldy; draft as markdown, deep-linking items as `zotero://select/library/items/<KEY>` (clickable, opens the app on the item). Where `gdoc` is available, deliver the finished document to Google Docs (`gdoc write`) — that's the user-facing reading/review surface; the per-item summaries stay in Zotero as the machine-readable layer.
- **Templates:** `zot.item_template("note")` etc. for correct field scaffolding before create.

pyzotero also ships an optional CLI and MCP server (same local-API requirement); for at-scale pipelines prefer scripts — per-call tool overhead dominates on hundreds of items.

## Generating summaries at scale

The patterns above store summaries; generating them is its own stage. For bulk runs, summarize with headless `claude -p` — one document per invocation, not the interactive session's own context (keeps each summary grounded in exactly one paper, and the run resumable):

```bash
pdftotext "$pdf" - | claude -p --model claude-sonnet-5 \
  "Summarize this paper for a research-library note: 2-3 paragraphs, then key claims, methods, limitations, and likely connections to adjacent work. Markdown, no preamble."
```

- Sonnet is the right tier for per-paper summarization. Save the interactive session's model for the passes that need cross-paper judgment: drawing links, clustering, synthesis — and run those over the *notes*, not the PDFs (orders of magnitude less input).
- The loop composes with the idempotency marker: select items lacking the `ai-summary` child note → `pdftotext` → `claude -p` → write the note. A failed item stays unmarked and is retried next run, so chunk the backlog freely.
- Bulk runs burn the logged-in account's 5h/weekly rate-limit windows — plan multi-hundred-paper backlogs as resumable chunks rather than one sitting.
- `pdftotext` is the cheap default; for figure-heavy papers where layout carries the content, Read the PDF directly (vision) instead, accepting the higher cost per item.

## Setup on a new device

1. Zotero app installed by guest-bootstrap (deb repo on Ubuntu — self-update disabled, apt handles upgrades; cask on macOS). Sign in and let the library finish syncing (storage files download lazily; "Sync full-text content" + attachment download settings matter for bulk PDF work).
2. Enable the local-API setting (Advanced, see above).
3. Before the first write: `POST /api/local/authorize`, have the user pick **Always Allow**, store the key per above. A zotero.org API key is only needed for headless/web-API use.
4. Smoke-test with the skeleton (`zot.count_items()`).
