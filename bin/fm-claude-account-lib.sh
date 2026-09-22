# shellcheck shell=bash
# fm-claude-account-lib.sh - which Claude login folder (CLAUDE_CONFIG_DIR) a
# claude-harness launch uses, and the one validation every source of that
# choice goes through. Sourced by bin/fm-spawn.sh, which owns resolution and
# the launch, and by bin/fm-control.sh, which checks an explicit relaunch
# override before it stops the running agent.
#
# docs/configuration.md "Claude account" owns the operator-facing contract:
# the config/claude-config-dir schema, the precedence, and durability across
# relaunch and recovery. This header owns only the mechanics.
#
# A value is either `default` - launch with no CLAUDE_CONFIG_DIR prefix, so
# Claude uses its own default store - or an absolute path to an existing
# directory. The absolute spelling is kept exactly as given, never
# canonicalized, because Claude keys some per-account state on the string it
# was logged in under. A relative path, a control byte, or a folder that does
# not exist is refused rather than replaced by another account.
#
# The recorded value lives in state/<id>.meta as `claude_config_dir=`, written
# only for claude launches alongside the other launch-time keys, so the PR
# identity block after `pr=` is never extended by it (bin/fm-pr-lib.sh).

FM_CLAUDE_ACCOUNT_META_KEY=claude_config_dir
FM_CLAUDE_ACCOUNT_CONFIG_FILE=claude-config-dir
# Set by fm_claude_account_recorded.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_CLAUDE_ACCOUNT_RECORDED=

# fm_claude_account_check <value> <source-label>
# 0 when <value> is `default` or an absolute path naming an existing directory;
# otherwise prints one refusal naming <source-label> and returns 1.
fm_claude_account_check() {
  local value=$1 label=$2
  case "$value" in
    default) return 0 ;;
    '')
      echo "error: $label names no Claude login folder; give an absolute folder path or 'default'" >&2
      return 1
      ;;
    *[[:cntrl:]]*)
      echo "error: $label contains a control character; refusing to use it as a Claude login folder" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: $label '$value' is not an absolute path; Claude requires an absolute login folder" >&2
      return 1
      ;;
  esac
  if [ ! -d "$value" ]; then
    echo "error: $label '$value' is not an existing directory; refusing rather than launching on a different Claude account (log in once with CLAUDE_CONFIG_DIR='$value' claude)" >&2
    return 1
  fi
}

# fm_claude_account_home_setting <config-dir>
# Prints a home's configured value from <config-dir>/claude-config-dir: its
# first non-empty line that does not start with `#`, with surrounding
# whitespace trimmed. Prints nothing when the file is absent or holds no such
# line. Returns 1 when the file exists but cannot be read.
fm_claude_account_home_setting() {
  local file="$1/$FM_CLAUDE_ACCOUNT_CONFIG_FILE" line
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file exists but is not a readable file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
}

# fm_claude_account_recorded <meta>
# Sets FM_CLAUDE_ACCOUNT_RECORDED to the task record's recorded value and
# returns 0 when the key is present exactly once; returns 2 with the variable
# empty when the record carries no key (a non-claude launch, or one recorded
# before this key existed). Returns 1 with a refusal when the key is repeated.
fm_claude_account_recorded() {
  local meta=$1 count
  FM_CLAUDE_ACCOUNT_RECORDED=
  count=$(grep -c "^$FM_CLAUDE_ACCOUNT_META_KEY=" "$meta" 2>/dev/null || true)
  case "$count" in
    ''|0) return 2 ;;
    1) ;;
    *)
      echo "error: task record $meta names more than one Claude login folder; refusing to guess which account it runs on" >&2
      return 1
      ;;
  esac
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_CLAUDE_ACCOUNT_RECORDED=$(sed -n "s/^$FM_CLAUDE_ACCOUNT_META_KEY=//p" "$meta")
}
