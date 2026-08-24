#!/bin/bash
# Watch upstream Roughdraft for anything that would change our fork's job.
#
# The global `roughdraft` is built from our fork's main branch because
# registry 0.1.10 is broken three ways (see the roughdraft skill's
# "When something is broken" section). That arrangement only stays correct if we notice when upstream
# moves: a merged PR means dropping a cherry-pick, a release means re-checking
# whether the fork is still needed at all.
#
# Notifies only when the picture changes, so a quiet upstream is silent.
HOOK_DROP_TO_SUDO_USER=1
source "$(dirname "$0")/../lib/_hook-env.sh"

UPSTREAM_REPO="Lex-Inc/roughdraft"
FORK_DIR="$HOME/roost/code/roughdraft"
STATE_FILE="$CLAUDE_CONFIG_DIR/state/roughdraft-watch.state"

# PRs we carry as cherry-picks: merging one means dropping our copy on rebase.
CHERRY_PICKED_PRS=(110 144)
# Ours: merging it means dropping our commits and keeping only the rebase.
OUR_PRS=(145)

mkdir -p "$(dirname "$STATE_FILE")"

# gh needs a token; cron has no keyring prompt, so fail loudly rather than
# silently reporting "no changes" forever.
if ! gh auth status >/dev/null 2>&1; then
    logger -t "$_HOOK_TAG" -p user.warning "gh not authenticated; cannot check upstream"
    ntfy_send -t "Roughdraft watch broken" -p default \
        "gh is not authenticated, so upstream Roughdraft is no longer being watched. Run: gh auth login"
    exit 0
fi

# Signature entries are one per line and compared with a whole-line match, so
# that e.g. npm=0.1.1 is not seen inside a recorded npm=0.1.10.
signature=""
changes=""

note_change() { changes="$changes
$1"; }

record() { signature="$signature$1
"; }

is_known() { [ -f "$STATE_FILE" ] && grep -qxF "$1" "$STATE_FILE"; }

# True only when we have a baseline and this entry is new in it.
is_new() { [ -f "$STATE_FILE" ] && ! is_known "$1"; }

# --- upstream main ---
upstream_sha="$(git ls-remote "https://github.com/$UPSTREAM_REPO.git" refs/heads/main 2>/dev/null | awk '{print $1}')"
if [ -n "$upstream_sha" ]; then
    record "main=$upstream_sha"
    if is_new "main=$upstream_sha"; then
        subject="$(gh api "repos/$UPSTREAM_REPO/commits/$upstream_sha" --jq '.commit.message' 2>/dev/null | head -1)"
        note_change "upstream main moved to ${upstream_sha:0:8}: ${subject:-unknown}
  -> rebase fork main, rebuild, reinstall"
    fi
fi

# --- published release ---
npm_version="$(npm view roughdraft version 2>/dev/null)"
if [ -n "$npm_version" ]; then
    record "npm=$npm_version"
    if is_new "npm=$npm_version"; then
        note_change "npm published roughdraft@$npm_version
  -> check whether our three fixes are in it; the fork may be droppable"
    fi
fi

# --- pull request states ---
check_pr() {
    local pr="$1" role="$2" state merged_at
    local json
    json="$(gh pr view "$pr" --repo "$UPSTREAM_REPO" --json state,mergedAt 2>/dev/null)" || return 0
    state="$(printf '%s' "$json" | jq -r '.state // "UNKNOWN"')"
    merged_at="$(printf '%s' "$json" | jq -r '.mergedAt // "none"')"
    record "pr$pr=$state"

    is_new "pr$pr=$state" || return 0

    case "$role:$state" in
        cherry-pick:MERGED)
            note_change "PR #$pr (cherry-picked into the fork) MERGED $merged_at
  -> drop our copy of it when rebasing" ;;
        cherry-pick:CLOSED)
            note_change "PR #$pr (cherry-picked into the fork) was CLOSED without merging
  -> we now carry it alone; it will not arrive via upstream" ;;
        ours:MERGED)
            note_change "our PR #$pr MERGED $merged_at
  -> drop our commits when rebasing and keep only the rebase" ;;
        ours:CLOSED)
            note_change "our PR #$pr was CLOSED without merging
  -> the fix stays fork-only" ;;
        *)
            note_change "PR #$pr is now $state" ;;
    esac
}

for pr in "${CHERRY_PICKED_PRS[@]}"; do check_pr "$pr" "cherry-pick"; done
for pr in "${OUR_PRS[@]}"; do check_pr "$pr" "ours"; done

# --- review activity on our PRs (someone engaging is the signal we want) ---
for pr in "${OUR_PRS[@]}"; do
    count="$(gh pr view "$pr" --repo "$UPSTREAM_REPO" --json comments,reviews \
        --jq '((.comments // []) | length) + ((.reviews // []) | length)' 2>/dev/null)"
    [ -n "$count" ] || continue
    record "pr${pr}activity=$count"
    if is_new "pr${pr}activity=$count"; then
        note_change "new comment or review on our PR #$pr (now $count)
  -> https://github.com/$UPSTREAM_REPO/pull/$pr"
    fi
done

# Nothing recorded yet: seed the baseline silently so the first real change is
# the first notification, rather than one that lists the whole world.
if [ ! -f "$STATE_FILE" ]; then
    printf '%s' "$signature" > "$STATE_FILE"
    logger -t "$_HOOK_TAG" "seeded baseline"
    exit 0
fi

if [ -z "$changes" ]; then
    logger -t "$_HOOK_TAG" "no upstream changes"
    exit 0
fi

printf '%s' "$signature" > "$STATE_FILE"
logger -t "$_HOOK_TAG" "upstream changed:$(printf '%s' "$changes" | tr '\n' ' ')"

behind=""
if [ -d "$FORK_DIR/.git" ]; then
    git -C "$FORK_DIR" fetch upstream --quiet 2>/dev/null || true
    n="$(git -C "$FORK_DIR" rev-list --count main..upstream/main 2>/dev/null)"
    [ -n "$n" ] && [ "$n" != "0" ] && behind="

fork main is $n commit(s) behind upstream/main."
fi

ntfy_send -t "Roughdraft upstream changed" -p default \
    "$(printf '%s\n%s' "$changes" "$behind")"
