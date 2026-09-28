#!/usr/bin/env bash
# Fixture test for files/scripts/git-hook.sh, the box-wide git hooks. Builds a
# throwaway roost layout (claude/scripts with the dispatcher and a stub scrub
# gate, claude/git-hooks from `install`), a fake `gh` answering the visibility
# lookup, and a fake `ssh` that lands git@github.com:OWNER/REPO pushes in local
# bare repos, so every push below is a real `git push` whose pre-push hook sees
# a GitHub URL. Needs no network and never touches the user's git config.
#   tests/git-hook.sh            # from the repo root
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/git-hook-test.XXXX")
trap 'rm -rf "$T"' EXIT

R="$T/roost"; S="$R/claude/scripts"; H="$R/claude/git-hooks"
mkdir -p "$S" "$T/bin" "$T/github" "$R/code"
cp "$here/files/scripts/git-hook.sh" "$S/git-hook.sh"

# The stub gate records how it was called and what it read, and refuses when
# the pushed ref lines carry the word PLANTED.
cat > "$S/public-scrub-check.sh" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf 'args: %s\n%s\n' "$*" "$input" >> "$GATE_LOG"
! grep -q PLANTED <<<"$input$(git log --format=%B -1 2>&1)"
EOF
chmod +x "$S/public-scrub-check.sh"

# Fake gh: `gh api repos/OWNER/REPO --jq .visibility` answers from
# $T/visibility/<owner>/<repo>; a missing file is a 404, FAKE_GH_DOWN a network error.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ -n "${FAKE_GH_DOWN:-}" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
slug=${2#repos/}; slug=${slug,,}
if [ -f "$VIS_DIR/$slug" ]; then cat "$VIS_DIR/$slug"; exit 0; fi
printf '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1
EOF
# Fake ssh: git runs `ssh [opts] git@github.com "git-receive-pack 'owner/repo.git'"`.
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${*: -1}"; path=${cmd#*\'}; path=${path%\'}; path=${path%.git}
exec git-receive-pack "$GITHUB_DIR/${path,,}.git"
EOF
chmod +x "$T/bin/gh" "$T/bin/ssh"

export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GATE_LOG="$T/gate.log" VIS_DIR="$T/visibility"
export GITHUB_DIR="$T/github" XDG_CACHE_HOME="$T/cache"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
# calls LOG — how many times the fake gh (one line per call) or the stub gate ran.
calls() { if [ -f "$1" ]; then grep -c -v '^refs/' "$1"; else echo 0; fi; }
reset_logs() { rm -f "$GH_LOG" "$GATE_LOG"; }

# github OWNER/REPO VISIBILITY — a bare "GitHub" repo and the fake gh's answer for it.
github() {
    git init -q --bare "$GITHUB_DIR/$1.git"
    mkdir -p "$VIS_DIR/${1%/*}"; echo "$3" > "$VIS_DIR/$1"
}
# work DIR URL — a work repo with one commit and origin at URL.
work() {
    git init -q -b main "$1"
    git -C "$1" remote add origin "$2"
    git -C "$1" commit -q --allow-empty -m "start"
}

echo "== install"
check "install exits 0" "$S/git-hook.sh" install
check "global core.hooksPath points at claude/git-hooks" \
    test "$(git config --global core.hooksPath)" = "$H"
check "pre-push is a link to the dispatcher" test "$(readlink -f "$H/pre-push")" = "$S/git-hook.sh"
check "pre-commit and post-rewrite are linked too" test -L "$H/pre-commit" -a -L "$H/post-rewrite"
check "push-to-checkout is not linked (its presence replaces updateInstead's own logic)" test ! -e "$H/push-to-checkout"
check "reference-transaction is not linked (it fires on every ref update)" test ! -e "$H/reference-transaction"
check "install is idempotent" "$S/git-hook.sh" install
check "check passes on a clean layout" "$S/git-hook.sh" check

echo "== pre-push: the visibility decision"
github acme/private-thing x private
github acme/public-thing x public
github acme/internal-thing x internal

reset_logs
work "$T/w-private" git@github.com:acme/private-thing.git
git -C "$T/w-private" commit -q --allow-empty -m "PLANTED name"
check "a push to a private repo succeeds" git -C "$T/w-private" push -q origin main
check "the gate did not run for the private repo" test "$(calls "$GATE_LOG")" = 0
check "gh was asked once" test "$(calls "$GH_LOG")" = 1

reset_logs
work "$T/w-public" git@github.com:acme/public-thing.git
check "a clean push to a public repo succeeds" git -C "$T/w-public" push -q origin main
check "the gate ran with --repo owner/repo, the remote name and URL" \
    grep -q '^args: --repo acme/public-thing origin git@github.com:acme/public-thing.git$' "$GATE_LOG"
check "the gate read the ref lines" grep -q '^refs/heads/main [0-9a-f]\{40\} refs/heads/main 0\{40\}$' "$GATE_LOG"
git -C "$T/w-public" commit -q --allow-empty -m "PLANTED name"
out=$(git -C "$T/w-public" push origin main 2>&1); rc=$?
check "a push the gate refuses fails" test "$rc" -ne 0
check "... and never reached the remote" \
    test "$(git -C "$GITHUB_DIR/acme/public-thing.git" log --format=%s -1 main)" = start

reset_logs
work "$T/w-internal" git@github.com:acme/internal-thing.git
git -C "$T/w-internal" commit -q --allow-empty -m "PLANTED"
out=$(git -C "$T/w-internal" push origin main 2>&1); rc=$?
check "an internal repo is gated like a public one" test "$rc" -ne 0

echo "== pre-push: the cache"
reset_logs
git -C "$T/w-private" commit -q --allow-empty -m "more"
git -C "$T/w-private" push -q origin main
check "a second push within the TTL asks gh nothing" test "$(calls "$GH_LOG")" = 0
cache_file=$(find "$XDG_CACHE_HOME" -type f -name '*private-thing*')
check "the answer is cached under XDG_CACHE_HOME" test -n "$cache_file"
touch -d '-11 minutes' "$cache_file"
git -C "$T/w-private" commit -q --allow-empty -m "more"
git -C "$T/w-private" push -q origin main
check "an expired entry is asked again" test "$(calls "$GH_LOG")" = 1
echo public > "$VIS_DIR/acme/private-thing"          # the repo went public
touch -d '-11 minutes' "$cache_file"
git -C "$T/w-private" commit -q --allow-empty -m "PLANTED after going public"
out=$(git -C "$T/w-private" push origin main 2>&1); rc=$?
check "after expiry a repo made public is gated" test "$rc" -ne 0
echo private > "$VIS_DIR/acme/private-thing"; rm -f "$cache_file"
git -C "$T/w-private" reset -q --hard HEAD~1

echo "== pre-push: fail closed"
reset_logs
work "$T/w-missing" git@github.com:acme/not-there.git
github acme/not-there x private; rm "$VIS_DIR/acme/not-there"   # exists for git, 404 for gh
out=$(git -C "$T/w-missing" push origin main 2>&1); rc=$?
check "a 404 from gh runs the gate" test "$(calls "$GATE_LOG")" = 1
check "... and says why" grep -q 'Not Found' <<<"$out"
check "... and a clean push still goes through" test "$rc" -eq 0
check "a failed lookup is not cached" test -z "$(find "$XDG_CACHE_HOME" -type f -name '*not-there*')"

reset_logs
git -C "$T/w-private" commit -q --allow-empty -m "PLANTED while GitHub is down"
out=$(FAKE_GH_DOWN=1 git -C "$T/w-private" push origin main 2>&1); rc=$?
check "gh failing runs the gate even for a private repo" test "$rc" -ne 0
check "... and prints gh's error" grep -q 'error connecting' <<<"$out"
git -C "$T/w-private" reset -q --hard HEAD~1

reset_logs
out=$(printf 'refs/heads/main %s refs/heads/main %s\n' "$(printf 'a%.0s' {1..40})" "$(printf '0%.0s' {1..40})" \
    | (cd "$T/w-public" && "$H/pre-push" origin https://gitlab.example.com/acme/thing.git) 2>&1); rc=$?
check "a non-GitHub host runs the gate, without --repo" grep -q '^args: origin https://gitlab.example.com/acme/thing.git$' "$GATE_LOG"
check "... and says why" grep -q 'not a GitHub' <<<"$out"

reset_logs
mv "$S/public-scrub-check.sh" "$S/gate.away"
out=$(git -C "$T/w-public" push origin main 2>&1); rc=$?
check "a missing gate refuses a push to a public repo" test "$rc" -ne 0
check "... naming the missing gate" grep -q 'public-scrub-check.sh' <<<"$out"
check "... while a private push still goes through" git -C "$T/w-private" push -q origin main
mv "$S/gate.away" "$S/public-scrub-check.sh"

echo "== pre-push: URL forms"
for url in git@github.com:Acme/Public-Thing.git ssh://git@github.com/acme/public-thing \
           https://github.com/acme/public-thing.git/ ssh://git@ssh.github.com:443/acme/public-thing.git; do
    reset_logs; rm -rf "$XDG_CACHE_HOME"
    printf 'refs/heads/x %s refs/heads/x %s\n' "$(printf 'a%.0s' {1..40})" "$(printf '0%.0s' {1..40})" \
        | (cd "$T/w-public" && "$H/pre-push" origin "$url") > /dev/null 2>&1
    check "$url resolves to acme/public-thing" grep -qi '^api repos/acme/public-thing ' "$GH_LOG"
done

reset_logs
git init -q --bare "$T/local-remote.git"
work "$T/w-local" "$T/local-remote.git"
git -C "$T/w-local" commit -q --allow-empty -m "PLANTED"
check "a push to a local path succeeds" git -C "$T/w-local" push -q origin main
check "... without asking gh or running the gate" test "$(calls "$GH_LOG")$(calls "$GATE_LOG")" = 00
git -C "$T/w-local" remote add file "file://$T/local-remote.git"
check "a file:// URL is local too" git -C "$T/w-local" push -q file main:other
check "... and not gated" test "$(calls "$GATE_LOG")" = 0

echo "== pass-through to the repository's own hooks"
reset_logs
cat > "$T/w-public/.git/hooks/pre-push" <<EOF
#!/bin/sh
printf 'own: %s\n' "\$*" >> "$T/own.log"; cat >> "$T/own.log"
[ ! -e "$T/own-refuses" ]
EOF
chmod +x "$T/w-public/.git/hooks/pre-push"
git -C "$T/w-public" reset -q --hard HEAD~1                 # drop the PLANTED commit
git -C "$T/w-public" commit -q --allow-empty -m "clean"
check "a push with the repo's own pre-push succeeds" git -C "$T/w-public" push -q origin main
check "the repo's own pre-push ran with the same arguments" \
    grep -q '^own: origin git@github.com:acme/public-thing.git$' "$T/own.log"
check "... and the same ref lines on stdin" grep -q '^refs/heads/main [0-9a-f]\{40\} refs/heads/main [0-9a-f]\{40\}$' "$T/own.log"
check "the gate ran too" test "$(calls "$GATE_LOG")" = 1
touch "$T/own-refuses"
git -C "$T/w-public" commit -q --allow-empty -m "clean again"
out=$(git -C "$T/w-public" push origin main 2>&1); rc=$?
check "the repo's own pre-push can still refuse" test "$rc" -ne 0
rm "$T/own-refuses"

printf '#!/bin/sh\necho refused by own pre-commit >&2\nexit 1\n' > "$T/w-local/.git/hooks/pre-commit"
# shellcheck disable=SC2016  # $1 is the hook's own argument, expanded when it runs
printf '#!/bin/sh\necho "$1" > "%s/post-checkout.log"\n' "$T" > "$T/w-local/.git/hooks/post-checkout"
chmod +x "$T/w-local/.git/hooks/pre-commit" "$T/w-local/.git/hooks/post-checkout"
echo x > "$T/w-local/f"; git -C "$T/w-local" add f
out=$(git -C "$T/w-local" commit -m "blocked" 2>&1); rc=$?
check "the repo's own pre-commit can refuse a commit" test "$rc" -ne 0
check "... with its own message" grep -q 'refused by own pre-commit' <<<"$out"
git -C "$T/w-local" checkout -q -b side
check "post-checkout ran with git's arguments" test -s "$T/post-checkout.log"
git -C "$T/w-local" worktree add -q "$T/w-local-wt" -b wt-branch
rm -f "$T/post-checkout.log"
git -C "$T/w-local-wt" checkout -q -b wt-other
check "a linked worktree runs the common hooks dir's hooks" test -s "$T/post-checkout.log"
out=$(git -C "$T/w-local-wt" commit --allow-empty -m "blocked in worktree" 2>&1); rc=$?
check "... pre-commit included" test "$rc" -ne 0
rm "$T/w-local/.git/hooks/pre-commit"
check "no repo hook: the commit goes through" git -C "$T/w-local" commit -q -m "fine"

ln -s "$H/pre-push" "$T/w-local/.git/hooks/pre-push"
out=$(timeout 10 git -C "$T/w-local" push origin side 2>&1); rc=$?
check "a repo hook that links back to the dispatcher is not re-entered" test "$rc" -eq 0
rm "$T/w-local/.git/hooks/pre-push"

echo "== check"
git init -q "$R/code/overridden"
git -C "$R/code/overridden" config core.hooksPath .git/hooks
out=$("$S/git-hook.sh" check 2>&1); rc=$?
check "a repo overriding core.hooksPath fails the check" test "$rc" -ne 0
check "... naming the repo" grep -q 'code/overridden' <<<"$out"
git -C "$R/code/overridden" config --unset core.hooksPath
printf '#!/bin/sh\nexit 0\n' > "$R/code/overridden/.git/hooks/reference-transaction"
chmod +x "$R/code/overridden/.git/hooks/reference-transaction"
out=$("$S/git-hook.sh" check 2>&1); rc=$?
check "a repo hook under a name the dispatcher leaves out fails the check" test "$rc" -ne 0
check "... naming the hook" grep -q 'overridden/.git/hooks/reference-transaction never runs' <<<"$out"
chmod -x "$R/code/overridden/.git/hooks/reference-transaction"
check "a non-executable one does not" "$S/git-hook.sh" check
rm "$H/pre-push"
out=$("$S/git-hook.sh" check 2>&1); rc=$?
check "a missing hook link fails the check" test "$rc" -ne 0
"$S/git-hook.sh" install
git config --global core.hooksPath /elsewhere
out=$("$S/git-hook.sh" check 2>&1); rc=$?
check "a foreign global core.hooksPath fails the check" test "$rc" -ne 0
"$S/git-hook.sh" install
check "install repairs both" "$S/git-hook.sh" check

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
