#!/bin/bash
# Tests for files/scripts/sym.py: whole definitions and callers by name, over a
# fixture tree shaped like the apart-research workspace (a parent repo that
# gitignores the nested code, a node_modules copy that must not count).
#   tests/sym.sh            # from the repo root; needs ast-grep on PATH
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sym="$here/files/scripts/sym.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/sym-test.XXXX")
trap 'rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
has()   { grep -qF -- "$1" <<<"$2"; }
lacks() { ! grep -qF -- "$1" <<<"$2"; }

# The workspace: a git repo that ignores everything at its root, like the
# polyrepo collector, with the code in an ignored sub-directory.
git -C "$T" init -q
printf '/*\n' > "$T/.gitignore"
mkdir -p "$T/code/lib" "$T/code/node_modules/dep"

cat > "$T/code/lib/lib.sh" <<'EOF'
#!/bin/bash
greet() {
    local who=$1
    echo "hello $who"
}
EOF
cat > "$T/code/lib/other.sh" <<'EOF'
#!/bin/bash
main() {
    greet world
}
greet toplevel
echo "greet is only mentioned here"
EOF
cat > "$T/code/mod.py" <<'EOF'
def status_of(thread: dict) -> str:
    kind = thread.get("kind")
    return kind or "idle"


class Bridge:
    def dispatch(self, op):
        return status_of({"kind": op})

    def other(self):
        return 1


def dispatch(x):
    return x


print(status_of({}))
EOF
# A NUL byte inside a string literal: ripgrep treats such a file as binary.
printf 'export const MARK = "a\0b";\n\nexport function topLevel(tokens: unknown[]): string[] {\n  return tokens.map(String);\n}\n\nexport const arrow = (n: number) => {\n  return topLevel([n]);\n};\n\nclass K {\n  run() {\n    return topLevel([]);\n  }\n}\n' > "$T/code/a.ts"
cat > "$T/code/node_modules/dep/index.ts" <<'EOF'
export function topLevel(x: string) { return x; }
EOF

# Output only; the exit status is checked once, explicitly, below.
run() { (cd "$T" && python3 "$sym" "$@") 2>&1 || true; }

out=$(run body greet)
check "bash: body of greet, header with file and line range" has "code/lib/lib.sh:2-5" "$out"
check "bash: body carries the last line of the function"     has 'echo "hello $who"' "$out"

out=$(run body status_of)
check "python: a function with a return annotation is found" has "code/mod.py:1-3" "$out"
check "python: body complete"                                has 'return kind or "idle"' "$out"

out=$(run body Bridge.dispatch)
check "python: Class.method selects the method"              has "code/mod.py:7-8" "$out"
check "python: Class.method skips the same-named function"   lacks "code/mod.py:14" "$out"

out=$(run body dispatch)
check "python: a bare name returns every definition"         has "code/mod.py:14-15" "$out"
check "python: ... including the method"                     has "code/mod.py:7-8" "$out"

out=$(run body topLevel)
check "ts: found in a file with a NUL byte"                  has "code/a.ts:3-5" "$out"
check "ts: node_modules is not searched"                     lacks "node_modules" "$out"

out=$(run body arrow)
check "ts: an arrow function bound to a const"               has "code/a.ts:7-9" "$out"

out=$(run callers greet)
check "bash callers: call inside a function names it"        has "code/lib/other.sh:3  in main" "$out"
check "bash callers: top-level call"                         has "code/lib/other.sh:5  (top level)" "$out"
check "bash callers: a mention in a string is not a call"    lacks "other.sh:6" "$out"
check "bash callers: the definition is not a caller"         lacks "lib.sh" "$out"

out=$(run callers status_of)
check "python callers: method caller named Class.method"     has "code/mod.py:8  in Bridge.dispatch" "$out"
check "python callers: top-level call"                       has "code/mod.py:18  (top level)" "$out"

out=$(run callers topLevel)
check "ts callers: arrow function caller"                    has "code/a.ts:8  in arrow" "$out"
check "ts callers: method caller"                            has "code/a.ts:13  in K.run" "$out"

out=$(run callers greet --bodies)
check "--bodies prints the enclosing function"               has "greet world" "$out"

set +e
out=$(cd "$T" && python3 "$sym" body no_such_symbol 2>&1); rc=$?
set -e
check "unknown name: exit 1"                                 test "$rc" = 1
check "unknown name: says so"                                has "no definition of no_such_symbol" "$out"

out=$(run body greet code/mod.py)
check "an explicit path limits the search"                   has "no definition of greet" "$out"

exit $fail
