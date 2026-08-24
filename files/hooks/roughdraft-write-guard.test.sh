#!/usr/bin/env bash
# Filesystem test for roughdraft-write-guard.sh. Not deployed (deliberately absent from the
# roost-apply manifest) — run it from the repo: bash files/hooks/roughdraft-write-guard.test.sh
#
# Each case builds a throwaway document tree, feeds a synthetic PreToolUse payload to the hook,
# and asserts on what landed in the sidecar. Two invariants are checked on EVERY case, because
# they are the whole posture of this hook: it exits 0, and it prints nothing (any stdout would
# be read as a permission decision, and an "ask" is a hard deny in a headless subagent).
#
# The 90-second debounce is exercised with `touch -d` rather than a sleep or a test-only knob:
# the threshold stays a single hard-coded number in the hook, and the suite stays fast.
#
# shellcheck disable=SC2034  # case-local vars are read by the single-quoted assertions in yn()
# shellcheck disable=SC2016  # those assertions are single-quoted on purpose: yn() evals them
set -uo pipefail

hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/roughdraft-write-guard.sh"
pass=0
fail=0
tmproot=$(mktemp -d)
trap 'rm -rf "$tmproot"' EXIT

MARKED=$'# Doc\n\n{==reviewed==}{>>looks good<<}{#c1}\n'
PLAIN=$'# Doc\n\nJust prose, no review markers. {#c1} is an anchor, not a marker.\n'

# A fresh document directory per case.
newcase() { mktemp -d "$tmproot/case.XXXXXX"; }

# Fire the hook the way Claude Code does: JSON on stdin, nothing else.
# Records the exit status in $rc and stdout in $out; both are asserted by ok().
fire() {
    local tool="$1" path="$2" cwd="${3:-$tmproot}"
    out=$(jq -nc --arg t "$tool" --arg p "$path" \
        '{tool_name: $t, tool_input: {file_path: $p}}' |
        (cd "$cwd" && bash "$hook"))
    rc=$?
}

# Fire with a raw payload, for the degenerate-input cases.
fire_raw() {
    out=$(printf '%s' "$1" | bash "$hook")
    rc=$?
}

ok() {
    local cond="$1" label="$2"
    if [ "$rc" -ne 0 ]; then
        fail=$((fail + 1))
        printf 'FAIL  %s  [hook exited %d, must always be 0]\n' "$label" "$rc"
        return
    fi
    if [ -n "$out" ]; then
        fail=$((fail + 1))
        printf 'FAIL  %s  [hook wrote to stdout: %s]\n' "$label" "$out"
        return
    fi
    if [ "$cond" = "yes" ]; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s\n' "$label"
    fi
}

yn() { if eval "$1"; then echo yes; else echo no; fi; }

# Snapshots for <doc> live in <dir>/.roughdraft-history/v1/<stem>/.
leafdir() {
    local doc="$1" dir base
    dir=$(dirname -- "$doc")
    base=$(basename -- "$doc")
    printf '%s/.roughdraft-history/v1/%s' "$dir" "${base%.md}"
}

countsnaps() {
    local leaf
    leaf=$(leafdir "$1")
    find "$leaf" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l
}

# Age everything already in the sidecar so the debounce never masks the case under test.
age_sidecar() {
    local leaf
    leaf=$(leafdir "$1")
    [ -d "$leaf" ] || return 0
    find "$leaf" -maxdepth 1 -type f -name '*.md' -exec touch -d '2 hours ago' -- {} +
}

# --- the bail ladder ---

d=$(newcase); printf '%s' "$MARKED" > "$d/notes.txt"
fire Write "$d/notes.txt"
ok "$(yn '[ ! -d "$d/.roughdraft-history" ]')" 'non-.md file is ignored'

d=$(newcase); printf '%s' "$PLAIN" > "$d/plain.md"
fire Write "$d/plain.md"
ok "$(yn '[ ! -d "$d/.roughdraft-history" ]')" '.md without CriticMarkup markers is ignored'

d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
fire Read "$d/doc.md"
ok "$(yn '[ ! -d "$d/.roughdraft-history" ]')" 'a non-Write/Edit tool is ignored'

d=$(newcase)
fire Write "$d/absent.md"
ok "$(yn '[ ! -d "$d/.roughdraft-history" ]')" 'a file that does not exist yet is ignored'

d=$(newcase); printf '%s' "$MARKED" > "$d/secret.md"; chmod 000 "$d/secret.md"
fire Write "$d/secret.md"
ok "$(yn '[ ! -d "$d/.roughdraft-history" ]')" 'an unreadable file is ignored (and does not crash)'
chmod 644 "$d/secret.md"

d=$(newcase); mkdir -p "$d/.roughdraft-history/v1/doc"
printf '%s' "$MARKED" > "$d/.roughdraft-history/v1/doc/2026-01-01T00-00-00-000Z--p1--save.md"
fire Write "$d/.roughdraft-history/v1/doc/2026-01-01T00-00-00-000Z--p1--save.md"
ok "$(yn '[ ! -d "$d/.roughdraft-history/v1/doc/.roughdraft-history" ]')" \
    'a path already inside .roughdraft-history is skipped (no history of history)'

fire_raw ''
ok yes 'empty stdin payload exits 0 silently'

fire_raw 'not json at all'
ok yes 'malformed payload exits 0 silently'

fire_raw '{"tool_name":"Write","tool_input":{}}'
ok yes 'missing file_path exits 0 silently'

# --- the snapshot itself ---

d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
fire Write "$d/doc.md"
leaf=$(leafdir "$d/doc.md")
ok "$(yn '[ "$(countsnaps "$d/doc.md")" -eq 1 ]')" 'Write to a marker-bearing .md creates one snapshot'

snap=$(find "$leaf" -maxdepth 1 -type f -name '*.md')
ok "$(yn 'cmp -s -- "$d/doc.md" "$snap"')" 'the snapshot is byte-identical to the pre-write file'

ok "$(yn '[[ $(basename -- "$snap") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{3}Z--p[0-9]+--hook\.md$ ]]')" \
    'the snapshot filename matches the frozen id grammar'

ok "$(yn '[ "$(cat "$d/.roughdraft-history/.gitignore")" = "*" ]')" \
    'creating the history dir writes a .gitignore containing *'

d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
fire Edit "$d/doc.md"
ok "$(yn '[ "$(countsnaps "$d/doc.md")" -eq 1 ]')" 'Edit snapshots too'

d=$(newcase); printf '%s' "$MARKED" > "$d/a b.md"
fire Write "$d/a b.md"
ok "$(yn '[ "$(countsnaps "$d/a b.md")" -eq 1 ]')" 'a document whose name contains a space is snapshotted'

# The payload Claude Code actually sends carries five more top-level fields and a full
# tool_input. The two the hook reads must still come out of it.
d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
fire_raw "$(jq -nc --arg p "$d/doc.md" '{
    session_id: "abc123", transcript_path: "/home/u/t.jsonl", cwd: "/home/u",
    permission_mode: "acceptEdits", hook_event_name: "PreToolUse", tool_name: "Write",
    tool_input: {file_path: $p, content: "# Doc\n\nrewritten\n"}}')"
ok "$(yn '[ "$(countsnaps "$d/doc.md")" -eq 1 ]')" 'a full realistic PreToolUse payload is parsed'

# --- dedup and debounce ---

d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
fire Write "$d/doc.md"
age_sidecar "$d/doc.md"
fire Write "$d/doc.md"
ok "$(yn '[ "$(countsnaps "$d/doc.md")" -eq 1 ]')" \
    'identical content is deduped against the newest snapshot'

d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
fire Write "$d/doc.md"
printf '%s' "${MARKED}changed\n" > "$d/doc.md"
fire Write "$d/doc.md"
ok "$(yn '[ "$(countsnaps "$d/doc.md")" -eq 1 ]')" \
    'a second write within the debounce window does not churn the ring'

age_sidecar "$d/doc.md"
fire Write "$d/doc.md"
ok "$(yn '[ "$(countsnaps "$d/doc.md")" -eq 2 ]')" \
    'changed content past the debounce window is snapshotted'

# --- symlink refusal (S4) ---

d=$(newcase); elsewhere=$(newcase)
printf '%s' "$MARKED" > "$d/doc.md"
ln -s "$elsewhere" "$d/.roughdraft-history"
fire Write "$d/doc.md"
ok "$(yn '[ -z "$(find "$elsewhere" -mindepth 1)" ]')" \
    'a symlinked .roughdraft-history is refused, writing nothing into the target'

d=$(newcase); elsewhere=$(newcase)
printf '%s' "$MARKED" > "$d/doc.md"
mkdir -p "$d/.roughdraft-history"
ln -s "$elsewhere" "$d/.roughdraft-history/v1"
fire Write "$d/doc.md"
ok "$(yn '[ -z "$(find "$elsewhere" -mindepth 1)" ]')" 'a symlinked v1 dir is refused'

d=$(newcase); elsewhere=$(newcase)
printf '%s' "$MARKED" > "$d/doc.md"
mkdir -p "$d/.roughdraft-history/v1"
ln -s "$elsewhere" "$d/.roughdraft-history/v1/doc"
fire Write "$d/doc.md"
ok "$(yn '[ -z "$(find "$elsewhere" -mindepth 1)" ]')" 'a symlinked <stem> leaf is refused'

# --- prune: the cap, the pinned review entry, and the poisoned-filename attack (S3) ---

d=$(newcase); printf '%s' "$MARKED" > "$d/doc.md"
leaf="$d/.roughdraft-history/v1/doc"
mkdir -p "$leaf"
# The oldest entry is the last reviewed state: it must survive eviction.
printf 'reviewed\n' > "$leaf/2020-01-01T00-00-00-000Z--p1--review.md"
for i in $(seq -w 2 56); do
    printf 'filler %s\n' "$i" > "$leaf/2020-01-01T00-00-${i}-000Z--p1--save.md"
done
age_sidecar "$d/doc.md"
before=$(countsnaps "$d/doc.md")
fire Write "$d/doc.md"
ok "$(yn '[ "$before" -eq 56 ] && [ "$(countsnaps "$d/doc.md")" -eq 50 ]')" \
    'the ring is pruned back to 50 entries'
ok "$(yn '[ -f "$leaf/2020-01-01T00-00-00-000Z--p1--review.md" ]')" \
    'the newest --review entry is never evicted, even as the oldest file'
ok "$(yn '[ ! -f "$leaf/2020-01-01T00-00-02-000Z--p1--save.md" ]')" \
    'eviction takes the oldest non-review entries first'

# S3: a snapshot filename containing a space must not turn the prune into a
# delete of unrelated files in whatever directory the agent happened to be in.
d=$(newcase); cwd=$(newcase)
printf '%s' "$MARKED" > "$d/doc.md"
leaf="$d/.roughdraft-history/v1/doc"
mkdir -p "$leaf"
printf 'poison\n' > "$leaf/0000 evil.md"
for i in $(seq -w 1 55); do
    printf 'filler %s\n' "$i" > "$leaf/2020-01-01T00-00-${i}-000Z--p1--save.md"
done
age_sidecar "$d/doc.md"
printf 'bystander\n' > "$cwd/0000"
printf 'bystander\n' > "$cwd/evil.md"
fire Write "$d/doc.md" "$cwd"
ok "$(yn '[ -f "$cwd/0000" ] && [ -f "$cwd/evil.md" ]')" \
    'S3: a space in a snapshot name does not delete same-named files in the cwd'
ok "$(yn '[ ! -f "$leaf/0000 evil.md" ]')" \
    'S3: the space-named oldest entry is itself evicted correctly'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
