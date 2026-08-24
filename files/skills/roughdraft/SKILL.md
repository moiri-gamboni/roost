---
name: roughdraft
description: Put a Markdown file in front of the user for review in a browser, then read their comments and suggested edits back and reply inside the document. Use when the user wants to review, comment on, or mark up a document, when handing over a plan or draft for feedback, or when they say "open this in roughdraft" or "rd". Covers opening the document, waiting for Done Reviewing without losing the signal, and the CriticMarkup shapes that actually render.
---

# Roughdraft

A local Markdown review app. You open one `.md` file, the user reads it in a browser and leaves comments and suggested changes, clicks **Done Reviewing**, and you read their feedback back out of the same file and reply in it. The Markdown file on disk is the only state — there is no separate review database.

The user may call it `rd`. That is shorthand in conversation only: never create a shell alias, executable, symlink, or command named `rd`.

When the user asks for a plan, write the plan to disk as Markdown first, then open it. Do not paste a plan into chat and ask for comments.

## Open a document and wait

```bash
roughdraft open "/absolute/path/to/file.md"
```

Run this with `run_in_background: true`. The command blocks until the user clicks Done Reviewing, and that exit is your signal to resume — backgrounding it keeps the process alive across turns and re-invokes you when it exits, instead of dying on a tool timeout. **Never interrupt, kill, or "tidy up" the waiting process.**

`roughdraft open` starts the server if it is not already running. The server is global and long-lived on port 7373; it does not need starting per document, and there is no systemd unit. What *is* per document is the waiter: each `open` registers one, and if it dies the page stays live and the user's click still queues server-side, but nothing is listening. Re-attach by opening the file again.

One file at a time — opening a second document replaces the first in the UI.

## Give the user a reachable link

The box is headless and the reviewer is on another device. `~/.bashrc.d/roost.sh` exports `ROUGHDRAFT_BIND_HOST` (loopback plus the tailnet address), `ROUGHDRAFT_TOKEN` (Roughdraft refuses a non-loopback bind without one) and `ROUGHDRAFT_NO_OPEN=1`.

Roughdraft still *prints* `http://localhost:7373/...` because that host is hardcoded. **Rewrite it to the tailnet IP** before handing the link over:

```
http://100.73.69.20:7373/?path=<url-encoded absolute path>
```

## Read the review back

When the wait exits, read the file from disk and respond to every comment and suggested change. Reply in the file, save, then open it again so the conversation continues in the document.

Treat suggested insertions, deletions, and substitutions as *feedback*, not as edits to apply — unless the user says to accept them.

Markers: comment `{>>text<<}`, insertion `{++text++}`, deletion `{--text--}`, substitution `{~~old~>new~~}`, highlight `{==text==}`. CriticMarkup inside fenced code blocks is literal example text, not feedback.

## Write feedback in the shape that renders

New comments and suggestions of your own: a compact inline reference (`{#c1}`, `{#s1}`) plus metadata in final YAML endmatter — `by` (your agent label), `at` (ISO timestamp). Anchored comments look like `{==selected text==}{>>Comment text<<}{#c1}`. Older documents may carry inline attribute blocks instead; preserve those unless you are deliberately removing the comment.

**Replies go in the endmatter with `body` + `re: <parent>` and no inline marker.** That is the shape the spec documents and the app itself writes, and it renders as a threaded card under its parent. Never pair an inline `{#cN}` marker *with* an endmatter `re:` entry for the same id — that registers as two items sharing one id and `roughdraft doctor` fails with `Duplicate review id`.

````markdown
{==selected text==}{>>Comment text<<}{#c1}
{++new text++}{#s1}

---
comments:
  c1:
    by: user
    at: "2026-04-28T12:00:00.000Z"
  c2:
    body: My reply, threaded under c1.
    by: AI
    at: "2026-04-28T12:05:00.000Z"
    re: c1
suggestions:
  s1:
    by: AI
    at: "2026-04-28T12:10:00.000Z"
````

Validate every document you write with `roughdraft doctor <path>` before handing it back — it catches duplicate ids and malformed markers the app would otherwise swallow silently. `doctor` is a parser check only, so it cannot tell you whether something *renders*; when that is the question, load the page and look.

`roughdraft help` and `roughdraft help criticmarkup` have the local command details; the full spec is at https://roughdraft.md/spec/roughdraft-flavored-markdown.md.

## When something is broken

The install is a build of our own fork, because the published package is not usable. Read this section before reinstalling or debugging anything that smells like a Roughdraft bug rather than a usage mistake. Two symptoms worth recognising on sight:

- **`command not found`** — a Node upgrade stranded the install. Rebuild and reinstall per the procedure below, with `--prefix "$HOME/.local"`.
- **The waiter dies around the five-minute mark** — the fork build fixes this; a stock 0.1.10 has crept back in. Interim workaround: `roughdraft open "$f" --no-watch` plus a `curl` long-poll against `POST /api/review-events/watch` with `{"projectPath":"<dirname>","path":"<basename>","fromNow":true}`, which has no client-side header cap.

### Provenance

Registry 0.1.10 is broken three ways, so the global `roughdraft` is built from `~/roost/code/roughdraft` (remotes: `upstream` = Lex-Inc, `fork` = moiri-gamboni), branch `main`. **The fork's `main` is the integration branch, not an upstream mirror**: a fork you install from should show its fixes on the branch you land on, and PRs are cut from separate topic branches based on `upstream/main`. As of 2026-08-24 `main` is 88 commits ahead of `upstream/main` (`git log --oneline upstream/main..main`): draft persistence and save recovery, remote-CLI reconnect, image and whitespace comments, serializer/anchor fixes, the fuzz harnesses, plus the three upstream-facing fixes:

| Fix | Origin | Upstream status |
|---|---|---|
| `yaml` missing from the published package (every command dies on `ERR_MODULE_NOT_FOUND`) | cherry-picked from PR #110 | open |
| `runWatch` crashed at 300s on undici's `headersTimeout`, losing the reviewer's click | cherry-picked from PR #144 | open |
| Comment rail and selection banner dropped replies stored in YAML endmatter, and replying to such a reply silently did nothing | ours, PR #145 | open |

Nothing has merged upstream since 2026-06-19. `~/roost/claude/scheduled/roughdraft-watch.sh` (daily) ntfys when upstream `main`, the npm version or any of those PRs changes, saying what it implies for the next rebase; its state is in `~/roost/claude/state/roughdraft-watch.state`.

### Rebase and reinstall

On `main`: `git fetch upstream && git rebase upstream/main`, drop any commit that has landed upstream, then `pnpm install && pnpm test && pnpm build && npm pack && npm i -g --prefix "$HOME/.local" ./roughdraft-*.tgz` (`pnpm` via `corepack enable --install-directory ~/bin`) and `git push --force-with-lease fork main`. The force-push is expected: rebasing keeps the fix set legible as N commits on top of upstream, which matters more here than an append-only history on a branch only we consume. Cut PR branches from `upstream/main`, never from fork `main`, or the PR carries our other work with it. The repo's own `CLAUDE.md`/`AGENTS.md` are upstream's and use a worktree-specific `roughdraft-dev-<worktree>` CLI for development; the global `roughdraft` is only ever the packed build.

### Server lifecycle

One long-lived process on `:7373`, started on demand by `roughdraft open`, state in `~/.roughdraft/server.json`. No systemd unit and none needed: it is not per-document, and it restarts on the next `open` after a reboot. `~/.bashrc.d/roost.sh` exports `ROUGHDRAFT_BIND_HOST` (loopback + the Tailscale IP, so the UI is reachable from the tailnet), `ROUGHDRAFT_TOKEN` (from `~/.config/roughdraft/token`; Roughdraft refuses a non-loopback bind without one because its remote endpoints rewrite files on disk) and `ROUGHDRAFT_NO_OPEN=1`.
