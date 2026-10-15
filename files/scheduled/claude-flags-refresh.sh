#!/bin/bash
# Refresh Claude Code's cached feature flags once per Claude Code version.
#
# Telemetry is off on this box, and with it Claude Code's feature-flag fetch, so
# sessions read their flags from the copy cached in .claude.json
# (CLAUDE_CODE_GB_DISK_CACHE_WHEN_TELEMETRY_OFF, exported by shell/bashrc.sh), and
# nothing else refreshes that copy. A new release run against weeks-old flags is a
# combination nobody tests: flags added since fall back to their defaults (mostly
# off), and features Anthropic has switched off since stay on.
#
# Started by claude-flags-refresh.path on any change in ~/.local/bin. Claude Code's
# own background updater and `claude update` both end by relinking
# ~/.local/bin/claude to the new version. Each version gets one attempt: once it is
# refreshed or its fetch has failed, later changes in that directory exit here.
#
# The refresh is one headless start with telemetry back on and no prompt: it
# fetches the flags, writes them to .claude.json and exits within seconds, with no
# model call. That start sends Anthropic one telemetry row, and the flag request
# carries the account's identifiers; real sessions stay telemetry-off. A failed
# fetch still exits 0 and leaves cachedGrowthBookFeaturesAt where it was, which is
# how it is caught here. Then a telemetry-off start with a short prompt (one small
# model call) lists the tools a new session now gets, since a flag can add or remove
# a tool. Hooks are disabled and MCP servers off in both starts, so the session
# hooks (conflict watch, time tracking) never see them and the compared list holds
# built-in tools only. An ntfy goes out when that list changed, when the fetch
# failed, and when no list could be taken.
#
# The flags each refresh replaced are kept in $STATE_DIR/flags-<when>.json, the
# newest 10, <when> being the time that refresh ran. To go back to one, as yourself
# rather than root (the umask keeps .claude.json 0600); new sessions read it, and
# the next version refreshes again:
#   (umask 077; f=~/roost/claude/state/claude-flags-refresh/flags-<when>.json c=~/roost/claude/.claude.json
#    jq --slurpfile f "$f" '. + $f[0]' "$c" > "$c.restore" && mv "$c.restore" "$c")
# To retry a failed fetch, refresh again within a version, or catch an update that
# landed while the service was running (systemd drops those changes):
#   rm -f ~/roost/claude/state/claude-flags-refresh/{version,failed}
#   sudo systemctl start claude-flags-refresh.service
HOOK_DROP_TO_SUDO_USER=1
source "$(dirname "$0")/../lib/_hook-env.sh"
set -e
umask 077  # the backups are copies of part of .claude.json, which is 0600

CLAUDE="$HOME/.local/bin/claude"
CONFIG="$CLAUDE_CONFIG_DIR/.claude.json"
STATE_DIR="$CLAUDE_CONFIG_DIR/state/claude-flags-refresh"
mkdir -p "$STATE_DIR"
cd "$STATE_DIR"  # the two starts run here, not in / where systemd starts the script

# An update is a burst of renames, and systemd drops the changes made while this
# service runs: read the link once the burst has settled, so the start its first
# temporary file triggered sees where the link ends up.
sleep 5
version=$(basename "$(readlink -f "$CLAUDE")")
last=""
failed=""
[ -f "$STATE_DIR/version" ] && last=$(<"$STATE_DIR/version")
[ -f "$STATE_DIR/failed" ] && failed=$(<"$STATE_DIR/failed")
{ [ "$version" = "$last" ] || [ "$version" = "$failed" ]; } && exit 0

# Both starts identify themselves as an interactive session would, since the
# entrypoint is one of the attributes the flags are evaluated against. The probe
# sets the cache switch itself because a service never sources shell/bashrc.sh
# (telemetry stays off through settings.json). Its answer is the init event, which
# comes before the model call, so the list is complete even when that call fails
# (a login at its usage cap): hence no pipefail, and an empty list means failure.
probe_tools() (
    set +o pipefail
    printf 'Reply with the single word ok.' |
        CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_GB_DISK_CACHE_WHEN_TELEMETRY_OFF=1 \
        timeout 300 "$CLAUDE" -p --no-session-persistence --strict-mcp-config --max-turns 1 \
            --settings '{"disableAllHooks":true,"env":{"ENABLE_CLAUDEAI_MCP_SERVERS":"false"}}' \
            --output-format stream-json --verbose |
        jq -r 'select(.type == "system" and .subtype == "init") | .tools[]' | LC_ALL=C sort
)
cached_at() { jq '.cachedGrowthBookFeaturesAt // 0' "$CONFIG"; }

# The first run has no list from a previous version: take one under the old flags.
[ -s "$STATE_DIR/tools" ] || probe_tools > "$STATE_DIR/tools"

backup="$STATE_DIR/flags-$(date -u +%Y%m%dT%H%M%SZ).json"
jq '{cachedGrowthBookFeatures, cachedGrowthBookFeaturesAt, cachedExperimentFeatures, cachedExperimentData}' \
    "$CONFIG" > "$backup"
before_at=$(cached_at)
rc=0
CLAUDE_CODE_ENTRYPOINT=cli timeout 300 "$CLAUDE" -p --no-session-persistence --strict-mcp-config \
    --settings '{"disableAllHooks":true,"env":{"DISABLE_TELEMETRY":"","DO_NOT_TRACK":"0","ENABLE_CLAUDEAI_MCP_SERVERS":"false"}}' \
    --input-format stream-json --output-format stream-json --verbose < /dev/null > /dev/null || rc=$?
if [ "$(cached_at)" = "$before_at" ]; then
    rm -f "$backup"
    printf '%s\n' "$version" > "$STATE_DIR/failed"
    logger -t "$_HOOK_TAG" -p user.warning \
        "flag fetch for Claude Code $version failed: cachedGrowthBookFeaturesAt unchanged (exit $rc)"
    ntfy_send -t "Claude Code flags not refreshed" \
        "The feature-flag fetch for Claude Code $version failed, so new sessions keep the flags from before the update. To retry: rm ~/roost/claude/state/claude-flags-refresh/failed && sudo systemctl start claude-flags-refresh.service"
    exit 1
fi
rm -f "$STATE_DIR/failed"
ls -1t "$STATE_DIR"/flags-*.json | tail -n +11 | xargs -r rm --

summary=$(jq -r --slurpfile old "$backup" '
    .cachedGrowthBookFeatures as $new | $old[0].cachedGrowthBookFeatures as $was
    | ([$new | keys[]] - [$was | keys[]] | length) as $added
    | ([$was | keys[]] - [$new | keys[]] | length) as $removed
    | [$was | keys[] as $k | select(($new | has($k)) and $new[$k] != $was[$k]) | $k] as $changed
    | "\($added) added, \($removed) removed, \($changed | length) changed\(if $changed == [] then "" else ": " + ($changed | join(" ")) end)"
' "$CONFIG") || summary="could not diff against $backup"
logger -t "$_HOOK_TAG" "flags for Claude Code $version: $summary"

# The refresh itself succeeded, so a failed probe still marks the version done:
# otherwise every later change in ~/.local/bin would fetch the flags again.
tools=$(probe_tools)
if [ -z "$tools" ]; then
    logger -t "$_HOOK_TAG" -p user.warning "tool probe for Claude Code $version listed nothing; tools not compared"
    ntfy_send -t "Claude Code $version: tool list not checked" \
        "The tool probe after the flag refresh listed nothing, so a tool these flags add or remove goes unreported. journalctl -t roost/claude-flags-refresh"
else
    if [ -s "$STATE_DIR/tools" ]; then
        # The C locale here as in probe_tools: comm needs the order sort gave.
        gained=$(LC_ALL=C comm -13 "$STATE_DIR/tools" <(printf '%s\n' "$tools") | paste -sd ' ')
        lost=$(LC_ALL=C comm -23 "$STATE_DIR/tools" <(printf '%s\n' "$tools") | paste -sd ' ')
        if [ -n "$gained$lost" ]; then
            logger -t "$_HOOK_TAG" "tools for Claude Code $version: gained ${gained:-none}, lost ${lost:-none}"
            ntfy_send -t "Claude Code $version: tools changed" \
                "New sessions gained: ${gained:-none}. Lost: ${lost:-none}."
        fi
    fi
    printf '%s\n' "$tools" > "$STATE_DIR/tools"
fi
printf '%s\n' "$version" > "$STATE_DIR/version"
