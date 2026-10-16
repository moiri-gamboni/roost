#!/bin/bash
# Test for the mods-switch alarm in files/scheduled/claude-flags-refresh.sh: after a refresh,
# an ntfy goes out when tengu_plugin_hooks_modules (the switch every installed mod loads
# under) is not true in the refreshed cache, and the journal line names its value. The script
# runs for real in a temporary tree against a fake `claude` that rewrites .claude.json the way a
# telemetry-on start does, with ntfy_send and logger stubbed.
#   tests/claude-flags-refresh.sh   # from the repo root
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/flags-refresh.XXXX")
trap 'rm -rf "$T"' EXIT

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

mkdir -p "$T/bin"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
cat > "$T/bin/logger" <<'EOF'
#!/bin/bash
printf '%s\n' "${*: -1}" >> "$JOURNAL"
EOF
chmod +x "$T/bin/"*

# The refresh start is the one given --input-format; the tool probe reads a prompt on stdin and
# answers with the init event. The refresh rewrites the cached flags from $NEW_FLAGS and moves
# cachedGrowthBookFeaturesAt, which is how the script tells a fetch from a failed one.
fake_claude() {
    cat <<'EOF'
#!/bin/bash
config=$CLAUDE_CONFIG_DIR/.claude.json
case "$*" in
    *--input-format*)
        jq --argjson f "$NEW_FLAGS" \
            '.cachedGrowthBookFeatures = $f | .cachedGrowthBookFeaturesAt += 1' "$config" > "$config.new"
        mv "$config.new" "$config" ;;
    *)
        cat > /dev/null
        echo '{"type":"system","subtype":"init","tools":["Bash","Read"]}' ;;
esac
EOF
}

# Runs the script in a fresh tree whose refresh brings in the flags $1; leaves the ntfy
# messages in $T/ntfy and the journal lines in $T/journal.
refresh_to() {
    local tree=$T/tree
    rm -rf "$tree"
    mkdir -p "$tree/roost/claude/scheduled" "$tree/roost/claude/lib" \
        "$tree/home/.local/bin" "$tree/home/.local/share/claude/versions"
    cp "$here/files/scheduled/claude-flags-refresh.sh" "$tree/roost/claude/scheduled/"
    cat > "$tree/roost/claude/lib/_hook-env.sh" <<'EOF'
set -uo pipefail
_HOOK_TAG=roost/claude-flags-refresh
ntfy_send() { printf '%s\n' "$*" >> "$NTFY"; }
EOF
    fake_claude > "$tree/home/.local/share/claude/versions/9.9.9"
    chmod +x "$tree/home/.local/share/claude/versions/9.9.9"
    ln -s "$tree/home/.local/share/claude/versions/9.9.9" "$tree/home/.local/bin/claude"
    printf '%s\n' '{"cachedGrowthBookFeatures":{"tengu_plugin_hooks_modules":true,"other_flag":1},"cachedGrowthBookFeaturesAt":1000,"cachedExperimentFeatures":[],"cachedExperimentData":{}}' \
        > "$tree/roost/claude/.claude.json"
    : > "$T/ntfy"; : > "$T/journal"
    PATH="$T/bin:$PATH" HOME="$tree/home" CLAUDE_CONFIG_DIR="$tree/roost/claude" \
        NTFY="$T/ntfy" JOURNAL="$T/journal" NEW_FLAGS="$1" \
        bash "$tree/roost/claude/scheduled/claude-flags-refresh.sh"
}

echo "switch still on:"
refresh_to '{"tengu_plugin_hooks_modules":true,"other_flag":2}'
check "no ntfy"                       test ! -s "$T/ntfy"
check "journal line names the value"  grep -q "tengu_plugin_hooks_modules=true" "$T/journal"

echo "switch turned off:"
refresh_to '{"tengu_plugin_hooks_modules":false,"other_flag":1}'
check "ntfy names the flag and its value"  grep -q "tengu_plugin_hooks_modules=false" "$T/ntfy"
check "journal line names the value"       grep -q "tengu_plugin_hooks_modules=false" "$T/journal"

echo "switch gone from the flags:"
refresh_to '{"other_flag":1}'
check "ntfy is sent"                  test -s "$T/ntfy"
check "journal line says it is null"  grep -q "tengu_plugin_hooks_modules=null" "$T/journal"

exit "$fail"
