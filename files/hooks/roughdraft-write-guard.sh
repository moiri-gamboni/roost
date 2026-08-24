#!/usr/bin/env bash
# PreToolUse hook (matcher: Write|Edit): snapshot a CriticMarkup-bearing .md file before an
# agent overwrites it.
#
# Why: review content saved to disk — CriticMarkup comments, suggestions, YAML endmatter — is
# ordinary markdown to every other tool on the box. A second session writing the file from a
# stale copy erases it, and until now the only recovery was an hourly btrfs snapshot: whole
# filesystem, operator-only. This copies the pre-write bytes into a sidecar next to the
# document, where `roughdraft history <file>` can list and restore them.
#
# It NEVER emits a permission decision and always exits 0. `permissionDecision: "ask"` is a hard
# DENY wherever no prompt surface exists — background subagents, `claude -p`, `dontAsk` — which
# is most of the traffic on this box, and it would land on the review-resolution happy path
# (agent reads reviewed doc, rewrites it whole). That is the shape that got `no-truncation.sh`
# (53b2f9b) reverted by its own author the next morning. This is recovery, not prevention: the
# snapshot is already on disk by the time the write happens, so nothing has to be interrupted.
#
# It does not source ../lib/_hook-env.sh. The hook fires on every Write and every Edit, so the
# `tailscale ip` subprocess, runtime-dir mkdir and per-exit logger that sourcing costs would be
# paid thousands of times a day for a facility used on a handful of them. Same reasoning as
# notion-write-guard.sh, which fires on every Bash call.
#
# The on-disk format is a frozen cross-repo contract, implemented twice — here and in
# packages/server/src/checkpoint-store.ts on the Roughdraft side. Do not change the path layout,
# the filename grammar, or the content-only dedup rule without changing both. It is specified in
# the Roughdraft repo at docs/spec/history-sidecar.md.
set -uo pipefail

# Deterministic ordering for the ring: filenames are timestamp-prefixed, so a byte-wise sort is
# a chronological sort — but only under a byte-wise collation.
export LC_ALL=C

# Not fed a payload -> not running as a hook (someone ran the file by hand).
[ -t 0 ] && exit 0

# One jq for both fields. `|| true` rather than 2>/dev/null: a malformed payload should still
# leave a visible parse error for whoever is debugging, it just must not take the turn down.
# tool_name comes first because it cannot contain a newline; the path is read to EOF so that a
# newline inside a filename truncates nothing (and the trailing newline jq adds is stripped).
{ IFS= read -r tool; IFS= read -r -d '' file; } < <(
    jq -r '(.tool_name // ""), (.tool_input.file_path // "")' || true
)
file=${file%$'\n'}

case "${tool:-}" in
    Write | Edit) ;;
    *) exit 0 ;;
esac

case "${file:-}" in
    *.md) ;;
    *) exit 0 ;;
esac

# A snapshot is itself a .md file. Snapshotting one would build a history of the history.
case "$file" in
    */.roughdraft-history/*) exit 0 ;;
esac

# A first Write creates the file, so there are no pre-write bytes to keep. `-r` as well as `-f`:
# an unreadable file would fail the cp anyway, and this keeps the error out of the log.
[ -f "$file" ] && [ -r "$file" ] || exit 0

# Only documents that carry review content are worth the sidecar. `{#c1}` anchors do NOT count:
# an anchor with no marker means the review items live elsewhere or have been resolved away.
grep -qaF -e '{>>' -e '{++' -e '{--' -e '{~~' -e '{==' -- "$file" || exit 0

dir=$(dirname -- "$file")
base=$(basename -- "$file")
hist="$dir/.roughdraft-history"
leaf="$hist/v1/${base%.md}"

# Refuse a symlinked sidecar at any level. Without this, anyone who can drop a symlink beside a
# reviewed document gets file creation in an arbitrary directory, triggered remotely by whoever
# next edits that document (security S4).
for d in "$hist" "$hist/v1" "$leaf"; do
    if [ -L "$d" ]; then
        logger -t roost/roughdraft-write-guard "refused: symlinked history dir at $d"
        exit 0
    fi
done

mkdir -p "$leaf" || exit 0

# `git clean -fd` would otherwise delete the sidecar and `git add -A` would publish content the
# author deleted on purpose.
[ -f "$hist/.gitignore" ] || printf '*\n' > "$hist/.gitignore"

snapshots() { find "$leaf" -maxdepth 1 -type f -name '*.md' -print0 | sort -z; }

newest=$(snapshots | tail -z -n 1 | tr -d '\0')
if [ -n "$newest" ]; then
    # Content-only dedup, so the Roughdraft side and this hook agree without sharing code.
    cmp -s -- "$file" "$newest" && exit 0

    # Debounce: an agent's edit burst is a dozen writes in a minute, and letting each one land
    # would evict the reviewed state out of a 50-entry ring within a single task.
    mtime=$(stat -c %Y -- "$newest" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - mtime )) -lt 90 ] && exit 0
fi

snap="$leaf/$(date -u +%Y-%m-%dT%H-%M-%S-%3NZ)--p$$--hook.md"
if ! cp -- "$file" "$snap"; then
    logger -t roost/roughdraft-write-guard "snapshot failed for $file"
    exit 0
fi
# The path only, never the content: reviewed documents hold whatever the author was reviewing,
# and journald is not the place for it.
logger -t roost/roughdraft-write-guard "snapshotted $file -> $snap"

# Prune oldest-first to the cap, but never the newest reviewed state — that is the one version
# whose loss the whole feature exists to prevent.
#
# Never `ls | xargs`: a snapshot filename containing a space would split into two arguments and
# delete unrelated files in whatever directory the agent happened to be standing in, and anyone
# who can write beside the document can plant such a name (security S3).
mapfile -d '' all < <(snapshots)
excess=$(( ${#all[@]} - 50 ))
[ "$excess" -gt 0 ] || exit 0

pinned=""
for f in "${all[@]}"; do
    case "$f" in *--review.md) pinned=$f ;; esac
done

doomed=()
for f in "${all[@]}"; do
    [ "$excess" -gt 0 ] || break
    [ "$f" = "$pinned" ] && continue
    doomed+=("$f")
    excess=$(( excess - 1 ))
done
[ ${#doomed[@]} -gt 0 ] && printf '%s\0' "${doomed[@]}" | xargs -0 rm -f --

exit 0
