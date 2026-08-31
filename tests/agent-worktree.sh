#!/bin/bash
# Fixture test for files/scripts/agent-worktree.sh: a polyrepo parent with a
# sub-repo on a feature branch, a linked-worktree sub-repo, a nested repo two
# levels down, ignored state of every kind, and uncommitted WIP. Runs create,
# then finish under each exit outcome. Needs no Claude: the hook JSON is faked.
#   tests/agent-worktree.sh            # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
AW="$here/files/scripts/agent-worktree.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/aw-test.XXXX")
export AGENT_WORKTREES_DIR="$T/trees"
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-c}"; }

# --- fixture ---------------------------------------------------------------
P="$T/ws"; mkdir -p "$P"; git -C "$P" init -q -b main
mkdir -p "$P/docs" "$P/tasks/t1" "$P/files"
echo doc > "$P/docs/a.md"; echo w > "$P/tasks/t1/w.md"; echo x > "$P/files/x.txt"
printf '/*\n!/.gitignore\n!/docs/\n!/tasks/\n!/files/\ntasks/.sync/\n' > "$P/.gitignore"
commit_all "$P" init
mkdir -p "$P/tasks/.sync" "$P/data" "$P/.claude"; echo base > "$P/tasks/.sync/base.json"; echo d > "$P/data/big.csv"
echo 'SECRET=1' > "$P/.env"
echo '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$P/.claude/settings.local.json"
git -C "$P" config --add agent.worktreeCopy 'tasks/.sync'
git -C "$P" config --add agent.worktreeEnv 'APART_WORKSPACE=@ROOT@'
# WIP in the parent (must not be copied): an untracked file in a tracked dir + a modification
echo wip > "$P/docs/wip.txt"; echo more >> "$P/docs/a.md"
# sub-repo A on a feature branch, with a venv and .env
A="$P/subA"; mkdir -p "$A/.venv"; git -C "$A" init -q -b main; echo a > "$A/a.py"; printf '.venv/\n.env\n' > "$A/.gitignore"; commit_all "$A" init
git -C "$A" checkout -q -b feat; echo a2 >> "$A/a.py"; commit_all "$A" feat; echo v > "$A/.venv/lib"; echo K=1 > "$A/.env"; echo wip > "$A/a-wip"
# sub-repo B: a linked worktree of an outside repo
B0="$T/brepo"; mkdir -p "$B0"; git -C "$B0" init -q -b main; echo b > "$B0/b"; commit_all "$B0" init
git -C "$B0" worktree add -q "$P/subB" -b topic
# nested repo two levels down, like files/private
N="$P/files/private"; mkdir -p "$N"; git -C "$N" init -q -b main; echo n > "$N/n"; commit_all "$N" init

create() {  # $1=name → prints root
    printf '{"name":"%s","cwd":"%s","session_id":"sid-%s"}' "$1" "$P/docs" "$1" | "$AW" create 2>"$T/create.err"
}

echo "== create"
ROOT=$(create one); echo "  root=$ROOT"
check "root is a worktree of the parent on worktree-one" [ "$(git -C "$ROOT" branch --show-current)" = worktree-one ]
check "root has no WIP (docs/wip.txt absent, docs/a.md clean)" bash -c "[ ! -e '$ROOT/docs/wip.txt' ] && [ -z \"\$(git -C '$ROOT' status --porcelain)\" ]"
check "tracked tasks/t1/w.md checked out" [ -f "$ROOT/tasks/t1/w.md" ]
check "tasks/.sync copied (real dir, not symlink)" bash -c "[ -d '$ROOT/tasks/.sync' ] && [ ! -L '$ROOT/tasks/.sync' ] && [ -f '$ROOT/tasks/.sync/base.json' ]"
check "data/ symlinked to the live dir" [ "$(readlink "$ROOT/data")" = "$P/data" ]
check ".env reflink-copied as a regular file" bash -c "[ -f '$ROOT/.env' ] && [ ! -L '$ROOT/.env' ] && grep -q SECRET '$ROOT/.env'"
check "subA is a symlink into the store" [ "$(readlink "$ROOT/subA")" = "$AGENT_WORKTREES_DIR/ws/one.repos/subA" ]
check "subA store is a worktree of A on worktree-one from feat" bash -c "[ \"\$(git -C '$ROOT/subA' branch --show-current)\" = worktree-one ] && [ \"\$(git -C '$ROOT/subA' rev-parse HEAD)\" = \"\$(git -C '$A' rev-parse feat)\" ]"
check "subA/.venv symlinked, .env copied, WIP a-wip absent" bash -c "[ -L '$ROOT/subA/.venv' ] && [ -f '$ROOT/subA/.env' ] && [ ! -L '$ROOT/subA/.env' ] && [ ! -e '$ROOT/subA/a-wip' ]"
check "subB (linked worktree) is a symlink to the live dir" [ "$(readlink "$ROOT/subB")" = "$P/subB" ]
check "files/private is a symlink to its own store worktree" bash -c "[ -L '$ROOT/files/private' ] && [ \"\$(git -C '$ROOT/files/private' branch --show-current)\" = worktree-one ]"
check "files/x.txt still a checked-out file" [ -f "$ROOT/files/x.txt" ]
check ".claude/settings.local.json generated with env and permissions kept" bash -c "[ -f '$ROOT/.claude/settings.local.json' ] && [ ! -L '$ROOT/.claude/settings.local.json' ] && [ \"\$(jq -r .env.APART_WORKSPACE '$ROOT/.claude/settings.local.json')\" = '$ROOT' ] && [ \"\$(jq -r '.permissions.allow[0]' '$ROOT/.claude/settings.local.json')\" = 'Bash(ls:*)' ]"
check "record lists root, subA, files/private" bash -c "grep -c '^wt' '$AGENT_WORKTREES_DIR/.sessions/sid-one' | grep -qx 3"
check "live parent untouched: status unchanged, no stray files" bash -c "[ \"\$(git -C '$P' status --porcelain | wc -l)\" = 3 ]"    # M a.md, ?? wip.txt, ?? files/private/

echo "== finish: clean root removed by Claude, subA committed → ff into feat"
echo new > "$ROOT/subA/new.py"; commit_all "$ROOT/subA" "session work"
git -C "$P" worktree remove --force "$ROOT"; git -C "$P" branch -q -D worktree-one     # what Claude does on a clean exit
"$AW" finish one 2>"$T/finish.err" || bad "finish exited $?"
check "feat fast-forwarded to the session commit" [ "$(git -C "$A" log -1 --format=%s feat)" = "session work" ]
check "A's live checkout file updated by the ff" grep -q new "$A/new.py"
check "subA worktree + branch gone" bash -c "[ ! -e '$AGENT_WORKTREES_DIR/ws/one.repos/subA' ] && ! git -C '$A' show-ref -q refs/heads/worktree-one"
check "files/private worktree + branch gone (no commits)" bash -c "[ ! -e '$AGENT_WORKTREES_DIR/ws/one.repos' ] && ! git -C '$N' show-ref -q refs/heads/worktree-one"
check "record removed" [ ! -e "$AGENT_WORKTREES_DIR/.sessions/sid-one" ]
check "subB untouched" [ "$(git -C "$P/subB" branch --show-current)" = topic ]

echo "== finish: dirty sub kept"
ROOT=$(create two); echo dirt > "$ROOT/subA/dirt"
git -C "$P" worktree remove --force "$ROOT"; git -C "$P" branch -q -D worktree-two
"$AW" finish two 2>"$T/finish.err" || bad "finish exited $?"
check "dirty subA store kept" [ -f "$AGENT_WORKTREES_DIR/ws/two.repos/subA/dirt" ]
check "record marked kept" grep -qx 'state=kept' "$AGENT_WORKTREES_DIR/.sessions/sid-two"
rm -rf "$AGENT_WORKTREES_DIR/ws/two.repos"; git -C "$A" worktree prune; git -C "$A" branch -q -D worktree-two; rm -f "$AGENT_WORKTREES_DIR/.sessions/sid-two"

echo "== finish: root kept by the user → nothing touched"
ROOT=$(create three); echo c > "$ROOT/subA/c"; commit_all "$ROOT/subA" "kept work"
"$AW" finish three 2>"$T/finish.err" || bad "finish exited $?"
check "root still present" [ -d "$ROOT" ]
check "subA worktree still present, feat not moved" bash -c "[ -d '$ROOT/subA/' ] && [ \"\$(git -C '$A' log -1 --format=%s feat)\" = 'session work' ]"
git -C "$P" worktree remove --force "$ROOT"; git -C "$P" branch -q -D worktree-three
"$AW" finish three 2>"$T/finish.err" || bad "finish exited $?"
check "after the root goes, the sub commit fast-forwards" [ "$(git -C "$A" log -1 --format=%s feat)" = "kept work" ]

echo "== finish: ff refused because feat moved on"
ROOT=$(create four); echo s > "$ROOT/subA/s"; commit_all "$ROOT/subA" "diverging"
echo m > "$A/m"; commit_all "$A" "feat moved"
git -C "$P" worktree remove --force "$ROOT"; git -C "$P" branch -q -D worktree-four
"$AW" finish four 2>"$T/finish.err" || bad "finish exited $?"
check "branch worktree-four kept in A" git -C "$A" show-ref -q refs/heads/worktree-four
check "feat untouched" [ "$(git -C "$A" log -1 --format=%s feat)" = "feat moved" ]
check "kept reason names the merge" grep -q "moved on" "$T/finish.err"
git -C "$A" worktree remove --force "$AGENT_WORKTREES_DIR/ws/four.repos/subA" 2>/dev/null || true; git -C "$A" branch -q -D worktree-four; rm -rf "$AGENT_WORKTREES_DIR/ws/four.repos" "$AGENT_WORKTREES_DIR/.sessions/sid-four"

echo "== gc: dead pid → finished"
ROOT=$(create five); sed -i 's/^pid=.*/pid=999999/' "$AGENT_WORKTREES_DIR/.sessions/sid-five"
git -C "$P" worktree remove --force "$ROOT"; git -C "$P" branch -q -D worktree-five
"$AW" gc 2>"$T/gc.err" || bad "gc exited $?"
check "gc removed the session's store and record" bash -c "[ ! -e '$AGENT_WORKTREES_DIR/ws/five.repos' ] && [ ! -e '$AGENT_WORKTREES_DIR/.sessions/sid-five' ]"

echo "== list runs"
ROOT=$(create six); "$AW" list >"$T/list.out" 2>&1 || bad "list exited $?"; check "list names the tree" grep -q '^six ' "$T/list.out"

[ $fail -eq 0 ] && echo "ALL PASSED" || { echo "FAILURES"; echo "--- last create.err:"; cat "$T/create.err"; echo "--- last finish.err:"; cat "$T/finish.err"; exit 1; }
