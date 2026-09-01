#!/usr/bin/env bash
# fm-wedge-alarm-lib.sh - the single owner of wedge-alarm CHANNEL RESOLUTION:
# what config/wedge-alarm and FM_WEDGE_ALARM_CHANNEL configure, and whether any
# of it can plausibly reach the captain. bin/fm-supervise-daemon.sh sources this
# for the runtime alert (wedge_alarm_notify calls the resolvers below), and
# bin/fm-afk-launch.sh sources it for the away-mode ENTRY check
# (wedge_alarm_reliable_channel_configured), so both consult the identical
# resolution instead of two copies drifting apart.
#
# Config: config/wedge-alarm (local, gitignored), one channel directive per
# non-empty, non-comment line. FM_WEDGE_ALARM_CHANNEL overrides the file with a
# single directive. Directives:
#   off              disable the active alert entirely, regardless of position
#                    (marker + flash remain) - also the explicit, deliberate
#                    acknowledgment that away-mode entry accepts below
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner (backend-independent)
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via `sh -c`, summary on $1 and on stdin
# An absent config means auto, i.e. default-ON on macOS: the alarm's whole
# purpose is to never be silent, so the reachable OS channel fires unless the
# captain explicitly disables it.
#
# Away-mode entry check (verified live, 2026-09-01, Linux/WSL2): an absent or
# `auto` config resolves to NOTHING on any non-macOS platform - no built-in OS
# channel exists here, and `herdr notification show` itself reported
# {"reason":"disabled","shown":false} rather than actually posting anything,
# with no org.freedesktop.Notifications D-Bus service registered at all. A
# max-defer wedge under that silent configuration fires the alarm exactly as
# designed and STILL reaches nobody, because the design's promise - a guard
# false-positive becomes a visible stall, never a silent one - depends on SOME
# channel actually posting. wedge_alarm_reliable_channel_configured is the
# entry-time predicate: true for any EXPLICIT directive (an admitted `off`
# counts, because the captain has consciously accepted marker-only), false only
# when every configured line is `auto`/`default` and the platform resolves it
# to nothing. bin/fm-afk-launch.sh refuses entry loudly on false rather than
# letting the captain walk away believing a channel that will never fire.

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

# Resolve the platform's default OS-level channel for `auto`. macOS reaches the
# captain via an osascript Notification Center banner; other platforms have no
# built-in OS channel (the captain wires a command: directive), so this prints
# nothing and wedge_alarm_notify logs that the marker is the only signal.
wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

# wedge_alarm_reliable_channel_configured: 0 when at least one configured
# directive is an explicit choice (off, osascript, herdr, command:<cmd>) or an
# auto/default that resolves to a real platform channel; 1 only when every
# configured line is auto/default and none of them resolve to anything - the
# silent-by-default gap this predicate exists to catch.
wedge_alarm_reliable_channel_configured() {
  local ch found_real=1
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    case "$ch" in
      auto|default)
        [ -n "$(wedge_alarm_platform_default)" ] && found_real=0
        ;;
      *)
        found_real=0
        ;;
    esac
  done < <(wedge_alarm_configured_channels)
  return "$found_real"
}
