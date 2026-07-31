#!/usr/bin/env bash
# claude-account — switch between Claude subscription logins on this box.
#
# One Claude Code config dir = one logged-in account (credentials live in
# <dir>/.credentials.json, identity in <dir>/.claude.json). The primary dir
# (~/roost/claude, account name "main") doubles as the shared store; alternate
# accounts are thin dirs under ~/roost/claude-accounts/<name>/ holding only
# login + app state, with the roost-managed pieces symlinked back to the
# primary dir: settings.json (hooks/statusline wiring — absolute paths, so the
# shared machinery runs identically), CLAUDE.md, skills/, plugins/, projects/
# (shared transcripts + memory, so `claude --resume` works across accounts) and
# history.jsonl. Usage tracking is keyed by login EMAIL, not by dir (see
# statusline.sh / session.sh), so each account's rate-limit windows and
# attribution stay separate no matter which dir carries them — and two dirs
# logged into the same account share one window cache, which is correct
# (limits are account-wide).
#
# Commands:
#   list             accounts + login emails, default/this-shell markers,
#                    symlink-drift check
#   add <name>       scaffold a new account dir (then `claude-account login`)
#   login <name>     run `claude /login` against that account's dir
#   use <name|main>  set the default for NEW interactive shells and `agent`
#                    windows. Running sessions keep the account they launched
#                    with; cron/BASH_ENV jobs always stay on main so scheduled
#                    work never silently burns an alternate account's budget.
#   current          effective account in this shell + the configured default
#   dir <name>       print the account's config dir (scripting, `agent -a`)
set -euo pipefail

ROOST_DIR_NAME="${ROOST_DIR_NAME:-roost}"
PRIMARY="$HOME/$ROOST_DIR_NAME/claude"
ACCTS="$HOME/$ROOST_DIR_NAME/claude-accounts"
DEFAULT_LINK="$ACCTS/default"
# Symlinked into every alternate dir. settings.json is runtime-rewritten by the
# app; if it ever rewrites via rename the symlink silently becomes a real file
# and the account drifts — `list` checks for exactly that.
SHARED=(settings.json CLAUDE.md skills plugins projects history.jsonl)

die() { echo "claude-account: $*" >&2; exit 1; }

acct_dir() {  # $1=name -> config dir path ("main" = the primary dir)
  case "${1:-}" in
    main) printf '%s\n' "$PRIMARY" ;;
    ''|*/*|.*|default) die "invalid account name '${1:-}'" ;;
    *) printf '%s\n' "$ACCTS/$1" ;;
  esac
}

email_of() {  # $1=config dir -> login email ("" if none recorded)
  jq -r '.oauthAccount.emailAddress // empty' "$1/.claude.json" 2>/dev/null || true
}

default_dir() {  # resolved default target; primary when unset/dangling
  local d
  if d=$(readlink -f "$DEFAULT_LINK" 2>/dev/null) && [ -d "$d" ]; then
    printf '%s' "$d"
  else
    printf '%s' "$PRIMARY"
  fi
}

cmd_list() {
  local def eff d name email tag drift item
  def=$(default_dir)
  eff=$(readlink -f "${CLAUDE_CONFIG_DIR:-$PRIMARY}" 2>/dev/null) || eff="$PRIMARY"
  printf '%-12s %-36s %s\n' ACCOUNT LOGIN NOTES
  for d in "$PRIMARY" "$ACCTS"/*; do
    [ -d "$d" ] || continue
    [ "$d" = "$DEFAULT_LINK" ] && continue
    if [ "$d" = "$PRIMARY" ]; then name=main; else name=${d##*/}; fi
    email=$(email_of "$d")
    [ -f "$d/.credentials.json" ] || email=""
    tag=""
    [ "$(readlink -f "$d")" = "$def" ] && tag="default"
    [ "$(readlink -f "$d")" = "$eff" ] && tag="${tag:+$tag, }this shell"
    if [ "$d" != "$PRIMARY" ]; then
      drift=""
      for item in "${SHARED[@]}"; do
        [ -e "$d/$item" ] && [ ! -L "$d/$item" ] && drift="${drift:+$drift,}$item"
      done
      [ -n "$drift" ] && tag="${tag:+$tag, }DRIFT: $drift no longer symlinked to main — diff against $PRIMARY and re-link"
    fi
    printf '%-12s %-36s %s\n' "$name" "${email:-(not logged in)}" "$tag"
  done
}

cmd_add() {
  local name="${1:?usage: claude-account add <name>}" d item
  d=$(acct_dir "$name")
  [ "$d" = "$PRIMARY" ] && die "'main' is the primary dir — it already exists"
  [ -e "$d" ] && die "$d already exists"
  mkdir -p "$d"
  for item in "${SHARED[@]}"; do
    [ -e "$PRIMARY/$item" ] && ln -s "$PRIMARY/$item" "$d/$item"
  done
  # Seed app state from the primary account minus its identity: keeps MCP
  # servers, trusted-project flags and onboarding state; /login writes the new
  # oauthAccount. Later divergence is fine — the pieces that must stay in sync
  # are the symlinks above.
  jq 'del(.oauthAccount) | del(.userID)' "$PRIMARY/.claude.json" > "$d/.claude.json"
  chmod 600 "$d/.claude.json"
  echo "Account dir ready: $d"
  echo "Next: claude-account login $name    (then: claude-account use $name, or per-window: agent -a $name)"
}

cmd_login() {
  local name="${1:?usage: claude-account login <name>}" d
  d=$(acct_dir "$name")
  [ -d "$d" ] || die "no such account '$name' (create it: claude-account add $name)"
  echo "Launching claude /login for '$name' ($d) — complete the OAuth flow there."
  CLAUDE_CONFIG_DIR="$d" exec claude /login
}

cmd_use() {
  local name="${1:?usage: claude-account use <name|main>}" d
  d=$(acct_dir "$name")
  if [ "$d" = "$PRIMARY" ]; then
    rm -f "$DEFAULT_LINK"
  else
    [ -d "$d" ] || die "no such account '$name' (create it: claude-account add $name)"
    [ -f "$d/.credentials.json" ] || echo "warning: '$name' has no login yet — run: claude-account login $name" >&2
    mkdir -p "$ACCTS"
    ln -sfn "$d" "$DEFAULT_LINK"
  fi
  echo "Default account: $name — applies to new interactive shells and new \`agent\` windows."
  echo "Running sessions and already-open shells keep their account (this shell: export CLAUDE_CONFIG_DIR=\"$d\")."
  echo "Cron/scheduled jobs always stay on main."
}

cmd_current() {
  local eff def name email
  eff=$(readlink -f "${CLAUDE_CONFIG_DIR:-$PRIMARY}" 2>/dev/null) || eff="$PRIMARY"
  name=main; [ "$eff" != "$(readlink -f "$PRIMARY")" ] && name=${eff##*/}
  email=$(email_of "$eff")
  printf 'this shell: %s (%s)\n' "$name" "${email:-not logged in}"
  def=$(default_dir)
  name=main; [ "$def" != "$(readlink -f "$PRIMARY")" ] && name=${def##*/}
  printf 'default:    %s\n' "$name"
}

case "${1:-list}" in
  list) cmd_list ;;
  add) shift; cmd_add "$@" ;;
  login) shift; cmd_login "$@" ;;
  use) shift; cmd_use "$@" ;;
  current) cmd_current ;;
  dir) shift; d=$(acct_dir "${1:?usage: claude-account dir <name>}"); [ -d "$d" ] || die "no such account '${1}'"; printf '%s\n' "$d" ;;
  -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '${1}' (list|add|login|use|current|dir)" ;;
esac
