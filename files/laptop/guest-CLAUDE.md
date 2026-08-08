# Research Workspace

Academic research workstation. The two main surfaces are Google Docs (the user's notes, and most documents — drafts, syntheses, digests) and Zotero (the paper library). Provisioned by `guest-bootstrap.sh` from https://github.com/moiri-gamboni/roost.

## Toolkit

| Tool | Use |
|---|---|
| gdoc | Google Docs/Drive CLI: `gdoc cat DOC_ID` (markdown out), `gdoc find "query"`, `gdoc ls`, `gdoc new "Title"`, `gdoc write DOC_ID draft.md`, `gdoc edit DOC_ID "old" "new"`, `gdoc comments DOC_ID`, `gdoc comment DOC_ID "text" --quote "anchor"`. `--json` for scripting. |
| `zotero` skill | The paper-library loop: bulk PDF summaries, collections, tags, related-item links. Start there for anything library-related. |
| pdftotext (poppler) | Cheap bulk PDF→text; prefer it over vision-reading except for figure-heavy layouts |
| rodney | Headless-Chrome CLI: open, scrape, screenshot, print-to-PDF JS-heavy pages (`rodney --help`) |
| html2markdown (+ skill) | Clean webpage/HTML → readable markdown |
| pandoc | markdown → PDF/docx, citations via citeproc |
| mmdc | Mermaid → PNG/SVG figures; render to verify before shipping a diagram |
| showboat | Verifiable analysis docs: commentary + executable code blocks + captured output; `showboat verify` re-runs and diffs |
| uv · node · gh · go | Python scripting (`uv run --with <pkg>`), JS runtime for the tools above, GitHub CLI, Go builds |

## Workflows

- **Notes and documents live in Google Docs.** Read notes with `gdoc cat` (arrives as markdown), locate with `gdoc find`/`gdoc ls`. Deliver anything written for the user — syntheses, digests, drafts — to Docs (`gdoc new` / `gdoc write` from a markdown file).
- **Review loop:** put the draft in Docs, the user comments there (desktop or phone); read comments with `gdoc comments`, respond with `gdoc comment --quote`, edit with `gdoc edit`, iterate.
- **Paper intake → summaries:** per the zotero skill — iterate items missing the `ai-summary` child note, `pdftotext | claude -p --model claude-sonnet-5`, write the note back. Summaries stay in Zotero as child notes (they're data: bulk re-readable via the API); resumable by construction. Bulk runs burn this account's rate-limit windows, so plan large backlogs as chunks.
- **Synthesis:** run over the Zotero summary notes, not the PDFs — cluster, add `dc:relation` links between items — and write the human-facing result to Docs, citing items as `zotero://select/library/items/<KEY>` links so the user can jump from prose to paper.
- **Web research:** WebSearch/WebFetch are built in; reach for rodney or `curl | html2markdown` when a page resists plain fetching.

## Setup

Walk the user through whichever of these a task needs and is missing:

- **Google Docs/Drive (gdoc):** one-time OAuth client, then sign-in.
  1. In Google Cloud Console (any project, e.g. a new one named `gdoc`): enable the **Google Drive API** and **Google Docs API**, then create **OAuth 2.0 credentials** of type **Desktop application** and download the JSON to `~/.config/gdoc/credentials.json`. If the consent screen is in testing mode, add the account below as a test user.
  2. `gdoc auth --account <the-designated-google-account>` (add `--no-browser` for a manual URL). This machine uses a dedicated Google account; docs and folders are shared into it from other accounts as needed — if a doc the user mentions isn't findable, it likely isn't shared yet.
- **Zotero:** sign in + let it sync (attachments download lazily); enable Settings → Advanced → "Allow other applications…" (local read API); create an API key at zotero.org/settings/keys with write access and store it at `~/.config/zotero/api-key` (0600).
- **GitHub:** `gh auth login`.
- **Optional Claude account pinning:** `claude setup-token` → `export CLAUDE_CODE_OAUTH_TOKEN=…` in the shell rc.
