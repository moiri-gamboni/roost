#!/usr/bin/env bash
# The box-wide git hooks. The global core.hooksPath points at ~/roost/claude/git-hooks/,
# where each name in HOOKS is a link to this script, so every repository on the box runs it,
# cloned before or after.
#
#   <hook name> [ARGS]    as a hook (named by the link git ran). pre-push first runs the
#                         scrub gate when the push goes to a public GitHub repository, and
#                         pre-commit and commit-msg when the branch's push remote is one;
#                         then every hook hands over to the repository's own hook,
#                         <git common dir>/hooks/<name>, when it is executable, with the same
#                         arguments and stdin (git itself stops looking there once
#                         core.hooksPath is set).
#   git-hook.sh install   link every name in HOOKS in claude/git-hooks/ and point the global
#                         core.hooksPath there. Idempotent.
#   git-hook.sh check     print what keeps these hooks, or a repository's own, from running
#                         and exit 1: a global core.hooksPath pointing elsewhere; a name in
#                         HOOKS not linked here; and, for each repository within three levels
#                         of ~/roost, a core.hooksPath of its own (which overrides the global
#                         one, so neither the gate nor the pass-through runs there) or an
#                         executable hook of its own under a name HOOKS leaves out.
#
# The pre-push decision, from the remote URL git passes:
#   a local path or file:// URL       no gate: nothing leaves the box.
#   github.com OWNER/REPO             `gh api repos/OWNER/REPO` .visibility, cached for
#                                     VISIBILITY_TTL seconds in ~/.cache/roost-git-hooks/;
#                                     "private" skips the gate, "public" and "internal" run it.
#   any other host, or a lookup that  the gate runs, after a line saying why (fail closed).
#   failed (gh error, 404)            A failed lookup is never cached.
# The commit decision is the same, for each push URL of the remote the current branch
# pushes to (git's own choice: branch.<name>.pushRemote, remote.pushDefault, then the
# upstream's remote; origin on a detached HEAD or a branch with none of them). No such
# remote, or only local URLs: no gate and no gh call.
#
# The gate is public-scrub-check.sh beside this script, run as
# `public-scrub-check.sh [--repo OWNER/REPO] REMOTE URL` with the push's ref lines on stdin,
# `… --staged` from pre-commit and `… --message FILE` from commit-msg; a push or commit it
# must check while it is missing is refused. `--no-verify` on a push or a commit skips these
# hooks, the gate included. A conflict-free merge, a cherry-pick or a rebase runs no
# pre-commit, so the push gate stays the backstop for what they bring in.
set -euo pipefail

# Every hook git 2.43 looks up in the hooks directory (githooks(5)), except:
#   push-to-checkout       its mere presence replaces receive.denyCurrentBranch=updateInstead's
#                          own check-and-update.
#   reference-transaction  they fire on every ref update and index write (a 10-commit rebase:
#   post-index-change      106 and 15 calls, against 24 for all the others), at ~16 ms a call
#                          here; no repository on the box uses them, and `check` names one
#                          that starts to.
#   fsmonitor-watchman     runs only when core.fsmonitor names its path, never looked up here.
HOOKS=(applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
    prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push
    pre-receive update proc-receive post-receive post-update pre-auto-gc post-rewrite
    sendemail-validate p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit)
VISIBILITY_TTL=600

# Where this script really lives, resolved only when needed: git runs the bare pass-through on
# every commit, checkout and ref update, and each readlink is a process.
paths() {
    self=$(readlink -f "${BASH_SOURCE[0]}")
    scripts_dir=${self%/*}
    hooks_dir="${scripts_dir%/*}/git-hooks"
    roost_dir=${scripts_dir%/*/*}
    gate="$scripts_dir/public-scrub-check.sh"
}

say() { echo "git-hook: $*" >&2; }

# owner/repo when URL names a github.com repository, "local" when it is a path on this box,
# nothing for any other host. The scp-like form host:path is only that when no slash comes
# before the first colon (git's own rule); otherwise the URL is a local path.
github_slug() {
    local url="$1" host path
    case "$url" in
        file://*) echo local; return ;;
        *://*) host=${url#*://}; path=${host#*/}; host=${host%%/*} ;;
        *)  host=${url%%:*}
            if [ "$host" = "$url" ] || [[ $host == */* ]]; then echo local; return; fi
            path=${url#*:} ;;
    esac
    host=${host##*@}; host=${host%%:*}; host=${host,,}
    [ "$host" = github.com ] || [ "$host" = ssh.github.com ] || return 0
    path=${path#/}; path=${path%/}; path=${path%.git}
    if [[ $path =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then echo "${path,,}"; fi
}

# public|private|internal for owner/repo; on a failed lookup, gh's error on stderr and exit 1.
visibility() {
    local slug="$1" dir="${XDG_CACHE_HOME:-$HOME/.cache}/roost-git-hooks/visibility" f err out
    f="$dir/${slug/\//%}"
    if [ -f "$f" ] && [ $(( EPOCHSECONDS - $(stat -c %Y "$f") )) -lt "$VISIBILITY_TTL" ]; then
        cat "$f"; return 0
    fi
    err=$(mktemp)
    if ! out=$(timeout 20 gh api "repos/$slug" --jq .visibility 2>"$err"); then
        tail -n 1 "$err" >&2; rm -f "$err"; return 1
    fi
    rm -f "$err"
    case "$out" in
        public|private|internal) ;;
        *) echo "unexpected visibility '$out'" >&2; return 1 ;;
    esac
    mkdir -p "$dir"
    echo "$out" > "$f.$$" && mv "$f.$$" "$f"
    echo "$out"
}

# gated URL WHAT — whether what goes to URL meets the gate: 1 for a local URL or a private
# GitHub repository, 0 (after a line saying why, when it is undecided) otherwise. Sets slug.
gated() {
    local url="$1" vis why=""
    slug=$(github_slug "$url")
    if [ "$slug" = local ]; then return 1; fi
    if [ -z "$slug" ]; then
        why="$url is not a GitHub repository"
    elif ! vis=$(visibility "$slug" 2>&1); then
        why="could not learn whether $slug is public ($vis)"
    elif [ "$vis" = private ]; then
        return 1
    fi
    if [ -n "$why" ]; then say "$why: checking the $2 as if it were public"; fi
}

# run_gate WHAT ARGS... — the gate, with --repo when $slug names a repository.
run_gate() {
    local what="$1" args=()
    shift
    paths
    if [ ! -x "$gate" ]; then
        say "refusing the $what: the scrub gate $gate is not deployed (roost-apply push files/private/public-scrub-check.sh)"
        return 1
    fi
    if [ -n "$slug" ]; then args=(--repo "$slug"); fi
    "$gate" "${args[@]}" "$@"
}

# commit_gate ARGS... — pre-commit and commit-msg: the gate on ARGS when a push URL of the
# current branch's push remote is gated.
commit_gate() {
    local remote urls url
    # The current branch's line alone is non-empty; none on a detached HEAD or unborn branch.
    remote=$(git for-each-ref --format='%(if)%(HEAD)%(then)%(push:remotename)%(end)' refs/heads/)
    remote=${remote//$'\n'/}
    # The one failure is "No such remote": nothing to push to, nothing to check.
    urls=$(git remote get-url --push --all "${remote:-origin}" 2>&1) || return 0
    while IFS= read -r url; do
        if gated "$url" commit; then run_gate commit "$@"; return; fi
    done <<<"$urls"
}

install() {
    local n
    mkdir -p "$hooks_dir"
    for n in "${HOOKS[@]}"; do ln -sfn ../scripts/git-hook.sh "$hooks_dir/$n"; done
    git config --global core.hooksPath "$hooks_dir"
}

check() {
    local problems=() n g h repo scope line global common
    global=$(git config --global --get core.hooksPath || true)
    [ "$global" = "$hooks_dir" ] || problems+=("global core.hooksPath is '${global}', not $hooks_dir")
    for n in "${HOOKS[@]}"; do
        [ "$(readlink -f "$hooks_dir/$n")" = "$self" ] || problems+=("$hooks_dir/$n is not a link to $self")
    done
    while IFS= read -r g; do
        repo=${g%/.git}
        while IFS=$'\t' read -r scope line; do
            case "$scope" in global|system|"") ;; *) problems+=("$repo sets core.hooksPath=$line ($scope), so the box-wide hooks never run there") ;; esac
        done < <(git -C "$repo" config --show-scope --get-all core.hooksPath || true)
        common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || continue
        for h in "$common"/hooks/*; do
            n=${h##*/}
            if [ ! -f "$h" ] || [ ! -x "$h" ]; then continue; fi
            case " ${HOOKS[*]} fsmonitor-watchman " in *" $n "*) continue ;; esac
            case "$n" in *.sample) continue ;; esac
            problems+=("$h never runs: the box-wide hooks do not pass $n through")
        done
    done < <(find "$roost_dir" -maxdepth 3 -name .git)
    [ "${#problems[@]}" -eq 0 ] && return 0
    printf '%s\n' "${problems[@]}" | sort -u
    return 1
}

name=${0##*/}
case "$name" in
    git-hook.sh|git-hook)
        paths
        case "${1:-}" in
            install) install ;;
            check) check ;;
            *) echo "usage: $0 install|check (or run it through a hook name)" >&2; exit 2 ;;
        esac
        exit ;;
esac

own="$(git rev-parse --path-format=absolute --git-common-dir)/hooks/$name"
if [ -x "$own" ]; then paths; fi
if [ ! -x "$own" ] || [ "$(readlink -f "$own")" = "$self" ]; then own=""; fi

case "$name" in
    pre-push)
        refs=$(cat; echo .); refs=${refs%.}
        if gated "$2" push; then printf '%s' "$refs" | run_gate push "$1" "$2" || exit 1; fi
        if [ -n "$own" ]; then exec "$own" "$@" < <(printf '%s' "$refs"); fi
        exit 0 ;;
    pre-commit) commit_gate --staged || exit 1 ;;
    commit-msg) commit_gate --message "$1" || exit 1 ;;
esac
if [ -n "$own" ]; then exec "$own" "$@"; fi
exit 0
