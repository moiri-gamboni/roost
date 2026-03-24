---
name: html2markdown
description: This skill should be used when the user asks to "convert HTML to markdown", "scrape a webpage to markdown", "download a page", "download a webpage", "extract content from HTML", "pipe HTML to markdown", "batch convert HTML files", or mentions "html2markdown", "html-to-markdown", or converting/downloading websites/pages to markdown format. Do NOT trigger on "fetch" (that implies WebFetch, not CLI conversion).
---

# html2markdown CLI

Convert HTML to clean, readable Markdown using the `html2markdown` CLI (v2) from [JohannesKaufmann/html-to-markdown](https://github.com/JohannesKaufmann/html-to-markdown).

## Core Usage Patterns

### Pipe from stdin

```bash
echo "<strong>important</strong>" | html2markdown
curl --no-progress-meter http://example.com | html2markdown
```

### File conversion

```bash
html2markdown --input file.html --output file.md
html2markdown --input "src/*.html" --output "dist/"
html2markdown --input file.html --output file.md --output-overwrite
```

When `--input` is a directory or glob, `--output` must be a directory.

### Content filtering with CSS selectors

```bash
# Only convert the article element
html2markdown --include-selector="article" --input page.html

# Exclude navigation and ads
html2markdown --exclude-selector=".ad, nav, .sidebar" --input page.html

# Combine both
curl -s https://example.com | html2markdown --include-selector="main" --exclude-selector=".comments"
```

### Absolute links

Convert relative links/images to absolute by specifying the source domain:

```bash
curl -s https://example.com/page | html2markdown --domain="https://example.com"
```

## Plugins

Plugins are off by default. Enable with flags:

| Flag | Effect |
|---|---|
| `--plugin-table` | Convert HTML tables to GFM markdown tables |
| `--plugin-strikethrough` | Convert `<strike>`, `<s>`, `<del>` to `~~text~~` |

### Table plugin options

These only apply when `--plugin-table` is enabled:

| Flag | Values | Description |
|---|---|---|
| `--opt-table-cell-padding-behavior` | `aligned`, `minimal`, `none` | Cell padding for visual alignment |
| `--opt-table-header-promotion` | (boolean flag) | Treat first row as header |
| `--opt-table-newline-behavior` | `skip`, `preserve` | How to handle newlines in cells |
| `--opt-table-presentation-tables` | (boolean flag) | Convert `role="presentation"` tables |
| `--opt-table-skip-empty-rows` | (boolean flag) | Omit empty rows |
| `--opt-table-span-cell-behavior` | `empty`, `mirror` | How to render colspan/rowspan |

## Other Options

| Flag | Description |
|---|---|
| `--opt-strong-delimiter` | `"**"` (default) or `"__"` for bold |

## Installation

```bash
# Homebrew
brew install JohannesKaufmann/tap/html2markdown

# Go
go install github.com/JohannesKaufmann/html-to-markdown/v2/cli/html2markdown@latest

# Or download pre-compiled binary from GitHub releases (PREFERRED)
```