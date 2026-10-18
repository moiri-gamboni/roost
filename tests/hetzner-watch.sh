#!/bin/bash
# Test for extras/hetzner-watch.sh: availability comes from the server type's
# per-location flags; --rescale waits in the server's own location, runs --run
# first and stops if it fails, then shuts down, changes the type (disk kept
# unless --upgrade-disk) and powers back on even when the change fails;
# --dry-run makes no change, runs nothing and notifies nobody, and is refused
# after --run; a live rescale of the machine the script runs on, or without
# NTFY_URL, is refused; a failed ntfy post or hcloud check is reported as
# such. hcloud and curl are stubs on PATH, so no Hetzner API or ntfy server
# is reached.
#   tests/hetzner-watch.sh   # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/hetzner-watch-test.XXXX")
trap 'rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# A copy without a ../.env beside it, so the repo's own .env is never sourced.
mkdir -p "$T/repo/extras" "$T/bin" "$T/stub"
cp "$here/extras/hetzner-watch.sh" "$T/repo/extras/"
watch="$T/repo/extras/hetzner-watch.sh"

cat > "$T/bin/hcloud" <<'EOF'
#!/bin/bash
# Every call is logged; mutating calls also update server.json.
echo "hcloud $*" >> "$STUB_DIR/calls"
srv="$STUB_DIR/server.json"
set_srv() { jq "$@" "$srv" > "$srv.tmp" && mv "$srv.tmp" "$srv"; }
case "$1 $2" in
    "server-type list") echo "114 cx43" ;;
    "server-type describe")
        n=1; [[ -f $STUB_DIR/describes-$3 ]] && n=$(( $(<"$STUB_DIR/describes-$3") + 1 ))
        echo "$n" > "$STUB_DIR/describes-$3"
        f="$STUB_DIR/type-$3.json"
        [[ -n ${STUB_AVAIL_FROM:-} && $3 = "${STUB_AVAIL_TYPE:-}" && $n -ge $STUB_AVAIL_FROM ]] && f="$STUB_DIR/type-$3.later.json"
        [[ -n ${STUB_DESCRIBE_FAIL_FROM:-} && $n -ge $STUB_DESCRIBE_FAIL_FROM ]] && { echo "hcloud: unable to authenticate your token" >&2; exit 1; }
        [[ -f $f ]] || { echo "hcloud: server type not found: $3" >&2; exit 1; }
        cat "$f" ;;
    "server describe") cat "$srv" ;;
    "server shutdown")
        [[ -n ${STUB_SHUTDOWN_FAIL:-} ]] && { echo "hcloud: timeout waiting for server to shut down" >&2; exit 1; }
        set_srv '.status = "off"' ;;
    "server change-type")
        [[ -n ${STUB_CHANGE_FAIL:-} ]] && { echo "hcloud: invalid_server_type" >&2; exit 1; }
        set_srv --arg t "${*: -1}" '.server_type.name = $t' ;;
    "server poweron") set_srv '.status = "running"' ;;
    *) echo "stub hcloud: unexpected call: $*" >&2; exit 99 ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
# The Hetzner metadata service answers STUB_INSTANCE_ID, or is unreachable;
# any other call is an ntfy post, recorded by its Title header, or refused
# (as curl -f reports an HTTP error) under STUB_NTFY_FAIL.
for a; do
    case $a in
        *169.254.169.254*) [[ -n ${STUB_INSTANCE_ID:-} ]] || exit 7; printf '%s' "$STUB_INSTANCE_ID"; exit 0 ;;
    esac
done
[[ -n ${STUB_NTFY_FAIL:-} ]] && { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
for a; do case $a in "Title: "*) echo "${a#Title: }" >> "$STUB_DIR/ntfy" ;; esac; done
EOF
chmod +x "$T/bin/hcloud" "$T/bin/curl"
export PATH="$T/bin:$PATH" STUB_DIR="$T/stub" NTFY_URL=http://ntfy.invalid/test

# type NAME LOCATION:AVAILABLE... — a server type served by `server-type describe`.
type_json() {
    local name=$1; shift
    local locs="[]" prices="[]" l
    for l in "$@"; do
        locs=$(jq --arg n "${l%%:*}" --argjson a "${l##*:}" \
            '. + [{id: 1, name: $n, available: $a, recommended: true, deprecation: null}]' <<<"$locs")
        prices=$(jq --arg n "${l%%:*}" --arg g "$( [[ $name = cx53 ]] && echo 22.9900 || echo 12.4900 )" \
            '. + [{location: $n, price_monthly: {net: $g, gross: $g}}]' <<<"$prices")
    done
    jq -n --arg name "$name" --argjson locs "$locs" --argjson prices "$prices" \
        '{id: 114, name: $name, cores: 8, memory: 16, disk: 160, prices: $prices, locations: $locs}'
}
reset() {
    rm -rf "$T/stub"; mkdir "$T/stub"; : > "$T/stub/calls"
    type_json cx43 hel1:true fsn1:true > "$T/stub/type-cx43.json"
    type_json cx53 hel1:"${1:-true}" fsn1:true > "$T/stub/type-cx53.json"
    jq -n '{id: 4242, name: "roost", status: "running", server_type: {name: "cx43"}, location: {name: "hel1"}}' \
        > "$T/stub/server.json"
}
mutating() { grep -E 'shutdown|change-type|poweron|^RUN' "$T/stub/calls" || true; }
# shellcheck disable=SC2016  # expanded by the sh -c it is handed to
run_marker=(--run sh -c 'echo RUN >> "$STUB_DIR/calls"')

echo "dry run, target available in the server's location"
reset true
out=$(WATCH_TYPE=cx53 "$watch" --rescale roost --dry-run "${run_marker[@]}" 2>&1) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "no change made, --run not run" test -z "$(mutating)"
check "nobody notified" test ! -e "$T/stub/ntfy"
check "names the current type and location" grep -q 'roost: cx43 in hel1, running' <<<"$out"
check "prints the shutdown it would run" grep -qF 'hcloud server shutdown --wait --wait-timeout 10m roost' <<<"$out"
check "prints the type change, disk kept" grep -qF 'hcloud server change-type --keep-disk roost cx53' <<<"$out"
check "prints the --run command" grep -qF 'sh -c echo RUN' <<<"$out"
check "prints both monthly prices" grep -qE '12\.49.*22\.99' <<<"$out"

echo "dry run, target available only in another location"
reset false
out=$(WATCH_TYPE=cx53 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "exit 1" test "$rc" = 1
check "says not available in hel1" grep -q 'cx53 is not available in hel1' <<<"$out"
check "no change made" test -z "$(mutating)"

echo "one-shot provisioning check reads the per-location flags"
reset true
out=$(WATCH_TYPE=cx53 WATCH_LOCATION='' "$watch" 2>&1) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "lists every available location" grep -q 'Available in: fsn1,hel1' <<<"$out"
check "nothing beyond reads" test -z "$(mutating)"

echo "hcloud too old to report per-location availability"
reset true
jq 'del(.locations)' "$T/stub/type-cx53.json" > "$T/stub/t" && mv "$T/stub/t" "$T/stub/type-cx53.json"
out=$(WATCH_TYPE=cx53 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "exit 1" test "$rc" = 1
check "says to upgrade hcloud" grep -qi 'upgrade hcloud' <<<"$out"

echo "unknown target type"
reset true
out=$(WATCH_TYPE=cx99 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "exit 1" test "$rc" = 1
check "names the type" grep -q "cannot read server type 'cx99'" <<<"$out"

echo "target is the current type"
reset true
out=$(WATCH_TYPE=cx43 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "exit 1" test "$rc" = 1
check "says it already is" grep -q 'roost is already cx43' <<<"$out"

echo "live rescale"
reset true
out=$(WATCH_TYPE=cx53 "$watch" --rescale roost "${run_marker[@]}" 2>&1) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
want=$'RUN\nhcloud server shutdown --wait --wait-timeout 10m roost\nhcloud server change-type --keep-disk roost cx53\nhcloud server poweron roost'
check "--run, shutdown, change-type, poweron, in that order" test "$(mutating)" = "$want"
check "server ends running as cx53" test "$(jq -r '.status + " " + .server_type.name' "$T/stub/server.json")" = "running cx53"
check "success notified" grep -q 'roost is now cx53' "$T/stub/ntfy"

echo "--upgrade-disk"
reset true
WATCH_TYPE=cx53 "$watch" --rescale roost --upgrade-disk > /dev/null 2>&1 && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "change-type without --keep-disk" grep -qx 'hcloud server change-type roost cx53' "$T/stub/calls"

echo "--run fails: nothing is shut down"
reset true
out=$(WATCH_TYPE=cx53 "$watch" --rescale roost --run false 2>&1) && rc=0 || rc=$?
check "exit nonzero" test "$rc" != 0
check "no change made" test -z "$(mutating)"
check "failure notified" grep -qi 'failed' "$T/stub/ntfy"

echo "type change fails: the server is powered back on"
reset true
out=$(WATCH_TYPE=cx53 STUB_CHANGE_FAIL=1 "$watch" --rescale roost 2>&1) && rc=0 || rc=$?
check "exit nonzero" test "$rc" != 0
check "poweron still called" grep -qx 'hcloud server poweron roost' "$T/stub/calls"
check "server ends running as cx43" test "$(jq -r '.status + " " + .server_type.name' "$T/stub/server.json")" = "running cx43"
check "failure notified" grep -qi 'rescale failed' "$T/stub/ntfy"

echo "shutdown times out: the type is left alone"
reset true
out=$(WATCH_TYPE=cx53 STUB_SHUTDOWN_FAIL=1 "$watch" --rescale roost 2>&1) && rc=0 || rc=$?
check "exit nonzero" test "$rc" != 0
check "no change-type" test -z "$(grep change-type "$T/stub/calls" || true)"
check "failure notified" grep -qi 'rescale failed' "$T/stub/ntfy"

echo "the machine it runs on: live refused, dry run allowed"
reset true
out=$(WATCH_TYPE=cx53 STUB_INSTANCE_ID=4242 "$watch" --rescale roost "${run_marker[@]}" 2>&1) && rc=0 || rc=$?
check "live: exit 1" test "$rc" = 1
check "live: no change made, --run not run" test -z "$(mutating)"
check "live: says why" grep -q 'refusing to rescale the server this runs on' <<<"$out"
out=$(WATCH_TYPE=cx53 STUB_INSTANCE_ID=4242 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "dry run: exit 0" test "$rc" = 0
check "dry run: warns a live run must start elsewhere" grep -q 'start the live run from another machine' <<<"$out"

echo "polling: rescales once the type turns available"
reset false
type_json cx53 hel1:true fsn1:true > "$T/stub/type-cx53.later.json"
out=$(WATCH_TYPE=cx53 STUB_AVAIL_TYPE=cx53 STUB_AVAIL_FROM=3 timeout 20 "$watch" --poll 1 --rescale roost 2>&1) && rc=0 || rc=$?
check "exit 0" test "$rc" = 0
check "waited at least one round" grep -q 'not available in hel1. Checking again' <<<"$out"
check "then rescaled" test "$(jq -r .server_type.name "$T/stub/server.json")" = cx53

echo "--dry-run typed after --run: refused, not run live"
reset true
out=$(WATCH_TYPE=cx53 "$watch" --rescale roost --run true --dry-run 2>&1) && rc=0 || rc=$?
check "exit 1" test "$rc" = 1
check "no change made" test -z "$(mutating)"
check "says to move it" grep -q 'put it before --run' <<<"$out"

echo "NTFY_URL unset: live rescale refused, dry run warns"
reset true
out=$(env -u NTFY_URL WATCH_TYPE=cx53 "$watch" --rescale roost 2>&1) && rc=0 || rc=$?
check "live: exit 1" test "$rc" = 1
check "live: no change made" test -z "$(mutating)"
check "live: says to set NTFY_URL" grep -q 'set NTFY_URL for a live rescale' <<<"$out"
out=$(env -u NTFY_URL WATCH_TYPE=cx53 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "dry run: exit 0" test "$rc" = 0
check "dry run: notes it" grep -q 'NTFY_URL is unset' <<<"$out"

echo "an ntfy post that fails is reported"
reset true
out=$(WATCH_TYPE=cx53 STUB_NTFY_FAIL=1 "$watch" --rescale roost 2>&1) && rc=0 || rc=$?
check "rescale still completes, exit 0" test "$rc" = 0
check "warns nobody was notified" grep -q 'Warning: the ntfy post to .* failed' <<<"$out"

echo "an hcloud error during the check is not read as unavailability"
reset true
out=$(WATCH_TYPE=cx53 STUB_DESCRIBE_FAIL_FROM=2 "$watch" --rescale roost --dry-run 2>&1) && rc=0 || rc=$?
check "exit 2" test "$rc" = 2
check "says the check failed" grep -q 'Availability check failed' <<<"$out"
check "does not say not available" test -z "$(grep 'not available' <<<"$out" || true)"

echo "provisioning --run that fails: its exit code comes back"
reset true
out=$(WATCH_TYPE=cx53 WATCH_LOCATION='' "$watch" --run sh -c 'exit 3' 2>&1) && rc=0 || rc=$?
check "exit 3" test "$rc" = 3
check "failure notified" grep -q 'cx53 provisioning failed' "$T/stub/ntfy"

exit "$fail"
