#!/bin/bash
# agent-worktree — composite per-session git worktrees for `claude --worktree`.
#
# Wired box-wide as Claude Code's WorktreeCreate hook (replacing its `git worktree
# add`) and as a SessionEnd hook. A session launched in a repo gets, under
# $AGENT_WORKTREES_DIR/<repo>/<name>/:
#   - a git worktree of the repo on branch worktree-<name>, from the current HEAD
#     (the branch in flight, not the default branch);
#   - for every nested repo the parent gitignores (a polyrepo workspace), its own
#     worktree on worktree-<name>, kept beside the root in <name>.repos/ and
#     symlinked at its usual path — so Claude deleting the root on exit can never
#     take uncommitted sub-repo work with it;
#   - nested repos that are themselves linked worktrees (`.git` is a file) →
#     symlinks to the live dir (shared);
#   - every ignored directory (venvs, caches, data, mirrors) → symlink to the live
#     one; every ignored file (.env) → reflink copy; `git config --add
#     agent.worktreeCopy <glob>` names ignored dirs to copy instead (per-session
#     state such as tasksync's tasks/.sync);
#   - .claude/: real dir, entries symlinked; settings.local.json generated when
#     `git config --add agent.worktreeEnv KEY=VALUE` is set (@ROOT@ → the tree's
#     root, @NAME@ → its name), else symlinked;
#   - untracked, non-ignored files (WIP) are deliberately NOT copied: a session
#     starts from committed state plus its own changes.
#
# At exit Claude removes a clean root itself and prompts Keep/Remove for a dirty
# one; SessionEnd then runs `finish`: each sub worktree is removed if it made no
# commits, fast-forwarded into the branch it came from when that is a pure ff
# and the live checkout accepts it, and kept (with an ntfy summary) otherwise.
#
# Modes:
#   agent-worktree create           WorktreeCreate hook — JSON {name,cwd,session_id} on stdin, prints root
#   agent-worktree finish [NAME]    SessionEnd hook (JSON on stdin) or by name
#   agent-worktree gc               finish every tree whose Claude process is gone
#   agent-worktree list             trees and their state
set -euo pipefail

BASE="${AGENT_WORKTREES_DIR:-$HOME/roost/worktrees}"
RECORDS="$BASE/.sessions"
TAG="roost/agent-worktree"

log() { logger -t "$TAG" -- "$*"; printf 'agent-worktree: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- discovery -------------------------------------------------------------

# Nearest ancestor process whose command is claude (the session owning this hook).
claude_pid() {
    local pid=$PPID cmd
    while [ "${pid:-1}" -gt 1 ]; do
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in *claude*) echo "$pid"; return 0 ;; esac
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 1)
    done
    echo ""
}

pid_is_claude() {  # $1=pid
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null \
        && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q claude
}

same_fs() { [ "$(stat -c %d "$1")" = "$(stat -c %d "$2")" ]; }

# --- tree construction -----------------------------------------------------

# add_worktree REPO PATH BRANCH → registers PATH as a worktree of REPO on a new BRANCH from HEAD.
add_worktree() {
    git -C "$1" worktree add -q -b "$3" "$2" >&2
}

# copy_or_link REL SRC DST — an ignored directory: symlink, or reflink copy when a
# copy-glob matches (state the session must own, e.g. tasks/.sync).
copy_globs=()
wants_copy() {  # $1=rel path without trailing slash
    local g
    for g in "${copy_globs[@]}"; do
        # shellcheck disable=SC2254  # the glob is the point
        case "$1" in $g) return 0 ;; esac
    done
    return 1
}

# populate REPO WT NAME DEPTH — fill worktree WT of REPO with the ignored state
# the checkout lacks; at DEPTH 0 nested repos become composite worktrees, deeper
# ones become symlinks.
populate() {
    local repo=$1 wt=$2 name=$3 depth=$4
    local rel entry src dst
    local -a made=()          # every entry we materialize, for the per-worktree excludes
    mapfile -t copy_globs < <(git -C "$repo" config --get-all agent.worktreeCopy || true)

    # Nested repos hide among both ignored and merely-untracked directories.
    local -a nested=()
    while IFS= read -r -d '' entry; do
        rel=${entry%/}
        [ -e "$repo/$rel/.git" ] && nested+=("$rel")
    done < <(git -C "$repo" ls-files -o --exclude-standard --directory -z; \
             git -C "$repo" ls-files -o -i --exclude-standard --directory -z)

    local -a pids=()
    for rel in "${nested[@]}"; do
        src="$repo/$rel"; dst="$wt/$rel"
        mkdir -p "$(dirname "$dst")"
        if [ "$depth" -eq 0 ] && [ -d "$src/.git" ]; then
            mkdir -p "$(dirname "$SUBSTORE/$rel")"
            ln -s "$SUBSTORE/$rel" "$dst"        # before backgrounding: the ignored-entry pass must see it
            ( sub_worktree "$src" "$rel" "$SUBSTORE/$rel" "$name" ) &
            pids+=($!)
        else
            ln -s "$src" "$dst"      # a linked worktree, or a repo nested too deep: share it
        fi
        made+=("$rel")
    done

    # Ignored entries: directories → symlink (or copy on a glob match), files →
    # reflink copy (symlink when the file sits on another filesystem: a bind-
    # mounted volume's media would otherwise be copied byte for byte).
    while IFS= read -r -d '' entry; do
        rel=${entry%/}; src="$repo/$rel"; dst="$wt/$rel"
        [ -e "$dst" ] || [ -L "$dst" ] && continue          # nested repo, or produced by the checkout
        case "$rel" in .claude|.claude/*) continue ;; esac
        mkdir -p "$(dirname "$dst")"
        if [ -d "$src" ] && [ ! -L "$src" ]; then
            if wants_copy "$rel"; then cp -a --reflink=auto "$src" "$dst"; else ln -s "$src" "$dst"; fi
        elif [ -f "$src" ] && same_fs "$src" "$(dirname "$dst")"; then
            cp -a --reflink=auto "$src" "$dst"
        else
            ln -s "$src" "$dst"
        fi
        made+=("$rel")
    done < <(git -C "$repo" ls-files -o -i --exclude-standard --directory -z)

    # Dir-only gitignore patterns (`.venv/`) do not match the symlinks standing
    # in for those dirs, and an untracked nested repo is not ignored at all —
    # either would make a fresh tree look dirty to Claude's exit check. A
    # per-worktree excludes file hides exactly what this script materialized,
    # without touching the real checkout's view.
    if [ ${#made[@]} -gt 0 ]; then
        git -C "$repo" config extensions.worktreeConfig true
        local gd xf
        gd=$(git -C "$wt" rev-parse --absolute-git-dir); mkdir -p "$gd/info"; xf="$gd/info/exclude-agent"
        { local gx; gx=$(git config --global --get core.excludesFile || echo "$HOME/.config/git/ignore")
          [ -f "$gx" ] && cat "$gx"
          printf '/%s\n' "${made[@]}"
          echo '/.claude'
        } > "$xf"
        git -C "$wt" config --worktree core.excludesFile "$xf"
    fi

    claude_dir "$repo" "$wt" "$name" "$depth"

    local pid rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    return $rc
}

# sub_worktree SRC REL STORE NAME — a nested repo's own worktree beside the root (already symlinked into it).
sub_worktree() {
    local src=$1 rel=$2 store=$3 name=$4
    add_worktree "$src" "$store" "worktree-$name"
    populate "$src" "$store" "$name" 1
    printf 'wt\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$src" "$store" \
        "$(git -C "$src" symbolic-ref --short -q HEAD || true)" "$(git -C "$src" rev-parse HEAD)" >> "$RECORD"
}

# claude_dir REPO WT NAME DEPTH — .claude/ as a real directory of symlinks, with
# settings.local.json generated when the repo asks for per-tree env.
claude_dir() {
    local repo=$1 wt=$2 name=$3 depth=$4
    [ -d "$repo/.claude" ] || return 0
    mkdir -p "$wt/.claude"
    local e
    for e in "$repo"/.claude/* "$repo"/.claude/.[!.]*; do
        [ -e "$e" ] || continue
        case "$(basename "$e")" in worktrees|settings.local.json) continue ;; esac
        [ -e "$wt/.claude/$(basename "$e")" ] || ln -s "$e" "$wt/.claude/$(basename "$e")"
    done
    local -a env=()
    [ "$depth" -eq 0 ] && mapfile -t env < <(git -C "$repo" config --get-all agent.worktreeEnv || true)
    if [ ${#env[@]} -eq 0 ]; then
        [ -f "$repo/.claude/settings.local.json" ] && ln -s "$repo/.claude/settings.local.json" "$wt/.claude/settings.local.json"
        return 0
    fi
    local kv envjson='{}'
    for kv in "${env[@]}"; do
        kv=${kv//@ROOT@/$wt}; kv=${kv//@NAME@/$name}
        envjson=$(jq -n --argjson e "$envjson" --arg k "${kv%%=*}" --arg v "${kv#*=}" '$e + {($k): $v}')
    done
    local basejson='{}'
    [ -f "$repo/.claude/settings.local.json" ] && basejson=$(cat "$repo/.claude/settings.local.json")
    jq -n --argjson b "$basejson" --argjson e "$envjson" '$b + {env: (($b.env // {}) + $e)}' \
        > "$wt/.claude/settings.local.json"
}

cmd_create() {
    local in name cwd sid repo
    in=$(cat)
    name=$(jq -r '.name // empty' <<<"$in"); cwd=$(jq -r '.cwd // empty' <<<"$in"); sid=$(jq -r '.session_id // empty' <<<"$in")
    if [ -z "$name" ] || [ -z "$cwd" ]; then die "WorktreeCreate input lacks name/cwd"; fi
    name=${name//[^A-Za-z0-9._-]/-}
    repo=$(git -C "$cwd" rev-parse --show-toplevel 2>&1) || die "$cwd is not inside a git repository"
    local root
    root="$BASE/$(basename "$repo")/$name"
    SUBSTORE="$root.repos"
    [ -e "$root" ] && die "$root already exists"
    mkdir -p "$RECORDS" "$(dirname "$root")"
    RECORD="$RECORDS/${sid:-$name}"
    {
        echo "name=$name"; echo "repo=$repo"; echo "root=$root"; echo "substore=$SUBSTORE"
        echo "pid=$(claude_pid)"; echo "created=$(date -Is)"
        printf 'wt\t.\t%s\t%s\t%s\t%s\n' "$repo" "$root" \
            "$(git -C "$repo" symbolic-ref --short -q HEAD || true)" "$(git -C "$repo" rev-parse HEAD)"
    } > "$RECORD"

    local t0; t0=$(date +%s.%N)
    add_worktree "$repo" "$root" "worktree-$name"
    populate "$repo" "$root" "$name" 0 || log "some nested worktrees failed (see journal); continuing"
    log "created $root in $(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")s"
    echo "$root"
}

# --- integration -----------------------------------------------------------

# integrate REL REAL WT SRC BASE → prints one of: clean merged kept:<reason>
integrate() {
    local rel=$1 real=$2 wt=$3 src=$4 base=$5
    local branch="worktree-$NAME"
    if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        echo "kept:uncommitted changes in $wt"; return
    fi
    if git -C "$real" show-ref --verify -q "refs/heads/$branch"; then
        local tip; tip=$(git -C "$real" rev-parse "$branch")
        if [ "$tip" = "$base" ]; then
            remove_wt "$real" "$wt"; git -C "$real" branch -q -D "$branch"; echo clean; return
        fi
        if [ -z "$src" ]; then echo "kept:$rel has commits on $branch but came from a detached HEAD"; return; fi
        if ! git -C "$real" merge-base --is-ancestor "$src" "$branch"; then
            echo "kept:$rel: $src moved on since; merge $branch by hand"; return
        fi
        if [ "$(git -C "$real" symbolic-ref --short -q HEAD || true)" = "$src" ]; then
            if ! git -C "$real" merge -q --ff-only "$branch" >/dev/null 2>&1; then
                echo "kept:$rel: live checkout refused the fast-forward of $branch into $src (local changes in the way)"; return
            fi
        elif ! git -C "$real" branch -q -f "$src" "$branch" 2>/dev/null; then
            echo "kept:$rel: could not move $src to $branch (checked out elsewhere?)"; return
        fi
        remove_wt "$real" "$wt"; git -C "$real" branch -q -D "$branch"; echo merged; return
    fi
    remove_wt "$real" "$wt"; echo clean      # branch already gone: Claude removed it, or the user did
}

remove_wt() {  # $1=real $2=wt
    if [ -d "$2" ]; then git -C "$1" worktree remove -f -f "$2" >/dev/null 2>&1 || rm -rf "$2"; fi
    [ -L "$2" ] && rm -f "$2"
    git -C "$1" worktree prune
}

# finish_record FILE — integrate every worktree of one session; drop the record unless something was kept.
finish_record() {
    local rec=$1
    NAME=$(sed -n 's/^name=//p' "$rec"); local root substore
    root=$(sed -n 's/^root=//p' "$rec"); substore=$(sed -n 's/^substore=//p' "$rec")
    if [ -d "$root" ]; then
        # The user answered Keep at Claude's exit prompt (or the session is still
        # running): the tree is theirs to resume, sub worktrees included.
        log "$NAME: root kept at $root; leaving its worktrees in place"
        sed -i '/^state=/d' "$rec"; echo "state=kept" >> "$rec"
        return 0
    fi
    local rel real wt src base res
    local -a kept=() merged=()
    while IFS=$'\t' read -r tag rel real wt src base; do
        [ "$tag" = wt ] || continue
        res=$(integrate "$rel" "$real" "$wt" "$src" "$base")
        case "$res" in
            merged) merged+=("$rel → $src") ;;
            kept:*) kept+=("${res#kept:}") ;;
        esac
    done < "$rec"
    [ -d "$substore" ] && find "$substore" -depth -type d -empty -delete 2>/dev/null
    local summary=""
    [ ${#merged[@]} -gt 0 ] && summary+="fast-forwarded: $(printf '%s; ' "${merged[@]}")"$'\n'
    [ ${#kept[@]} -gt 0 ] && summary+="kept: $(printf '%s; ' "${kept[@]}")"
    if [ ${#kept[@]} -gt 0 ]; then
        log "$NAME: $summary"
        sed -i '/^state=/d' "$rec"; echo "state=kept" >> "$rec"
    else
        [ -n "$summary" ] && log "$NAME: $summary"
        rm -f "$rec"
    fi
}

# A finish that itself blew up is invisible (it runs after the session closed),
# so that — and only that — warrants a push notification.
finish_or_alert() {
    local rec=$1
    finish_record "$rec" && return 0
    local n; n=$(sed -n 's/^name=//p' "$rec" 2>/dev/null || echo '?')
    # shellcheck disable=SC1091
    . "$(dirname "$(readlink -f "$0")")/../lib/_hook-env.sh" \
        && ntfy_send -t "agent-worktree finish failed" -p high "worktree $n: agent-worktree finish failed; see journalctl -t $TAG and agent-worktree list"
    return 1
}

cmd_finish() {
    local rec
    if [ $# -gt 0 ]; then
        rec=$(grep -lx "name=$1" "$RECORDS"/* 2>/dev/null | head -n 1 || true)
        [ -n "$rec" ] || die "no tree named $1"
    else
        [ -t 0 ] && die "usage: agent-worktree finish NAME (or hook JSON on stdin)"
        local sid; sid=$(jq -r '.session_id // empty' 2>/dev/null || true)
        [ -n "$sid" ] && [ -f "$RECORDS/$sid" ] || exit 0      # not a composite-worktree session
        rec="$RECORDS/$sid"
    fi
    finish_or_alert "$rec"
}

cmd_gc() {
    local rec pid
    for rec in "$RECORDS"/*; do
        [ -f "$rec" ] || continue
        pid=$(sed -n 's/^pid=//p' "$rec")
        pid_is_claude "$pid" && continue
        finish_or_alert "$rec" || true
    done
}

cmd_list() {
    local rec pid state name flag
    for rec in "$RECORDS"/*; do
        [ -f "$rec" ] || continue
        pid=$(sed -n 's/^pid=//p' "$rec"); state=$(sed -n 's/^state=//p' "$rec"); name=$(sed -n 's/^name=//p' "$rec")
        printf '%s  %s  %s  %s\n' "$name" "$(sed -n 's/^repo=//p' "$rec")" \
            "$(pid_is_claude "$pid" && echo live || echo "${state:-ended}")" "$(sed -n 's/^created=//p' "$rec")"
        while IFS=$'\t' read -r tag rel real wt src base; do
            [ "$tag" = wt ] || continue
            flag=""
            [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && flag=" dirty"
            if git -C "$real" show-ref --verify -q "refs/heads/worktree-$name" \
                && [ "$(git -C "$real" rev-parse "worktree-$name")" != "$base" ]; then flag+=" commits"; fi
            printf '    %-28s %s%s\n' "$rel" "${src:-detached}" "$flag"
        done < <(cat "$rec")
    done
}

case "${1:-}" in
    create) cmd_create ;;
    finish) shift; cmd_finish "$@" ;;
    gc)     cmd_gc ;;
    list)   cmd_list ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 1 ;;
esac
