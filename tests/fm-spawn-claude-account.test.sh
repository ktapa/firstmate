#!/usr/bin/env bash
# Behavior tests for which Claude login folder (CLAUDE_CONFIG_DIR) fm-spawn.sh
# launches a claude worker under, and what it records for the next relaunch.
#
# These drive fm-spawn through meta writing and launch construction with the
# shared fake tmux pane and a real isolated git worktree; the fake tmux logs the
# literal launch command, so assertions pin what the pane would run without
# starting Claude. Relaunch reuse of the recorded account is pinned through the
# control plane in tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-account)

# make_case <name> <harness> <id...> -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG
make_case() {
  local name=$1 harness=$2 id
  shift 2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$HOME_DIR" "$id"
  done
}

# make_store <name> -> an existing login folder under the case
make_store() {
  local store="$CASE_DIR/$1"
  mkdir -p "$store"
  printf '%s\n' "$store"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/config"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# run_spawn [fm-spawn args...]. The invoking shell's CLAUDE_CONFIG_DIR is
# pinned to FM_TEST_CLAUDE_CONFIG_DIR (empty by default) so assertions never
# depend on the developer's own Claude account.
run_spawn() {
  : > "$LAUNCH_LOG"
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

meta_value() {  # <id> <key>
  sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta"
}

set_home_account() {  # <config-dir> <value>
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/claude-config-dir"
}

assert_launch_account() {  # <store> <message>
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR='$1' env -u CURSOR_AGENT" "$2"
}

# --- resolution precedence ----------------------------------------------------

test_home_setting_chooses_the_account_and_is_recorded() {
  local id=acct-home-a1 out rc alt
  make_case home-setting claude "$id"
  alt=$(make_store claude-alt)
  set_home_account "$HOME_DIR/config" "  $alt  "

  out=$(run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "a claude spawn with a home account should succeed"$'\n'"$out"
  assert_launch_account "$alt" "the home's config/claude-config-dir did not reach the claude launch"
  [ "$(meta_value "$id" claude_config_dir)" = "$alt" ] \
    || fail "the resolved account must be recorded for the next relaunch, got '$(meta_value "$id" claude_config_dir)'"
  pass "a home's config/claude-config-dir chooses and records a claude worker's account"
}

test_home_setting_wins_over_the_inherited_account() {
  local id=acct-home-b2 out rc alt main
  make_case home-over-env claude "$id"
  alt=$(make_store claude-alt)
  main=$(make_store claude-main)
  set_home_account "$HOME_DIR/config" "$alt"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$main" run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "spawn should succeed"$'\n'"$out"
  assert_launch_account "$alt" "the home setting must win over firstmate's own CLAUDE_CONFIG_DIR"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "$main" "the inherited account leaked into the launch"
  pass "the home's account wins over the account firstmate itself runs under"
}

test_explicit_override_wins_over_the_home_setting() {
  local id=acct-flag-c3 out rc alt main
  make_case flag-over-home claude "$id"
  alt=$(make_store claude-alt)
  main=$(make_store claude-main)
  set_home_account "$HOME_DIR/config" "$alt"

  out=$(run_ship_spawn "$id" "$PROJ_DIR" --claude-config-dir "$main"); rc=$?
  expect_code 0 "$rc" "spawn with an explicit account should succeed"$'\n'"$out"
  assert_launch_account "$main" "the explicit --claude-config-dir must win over the home setting"
  [ "$(meta_value "$id" claude_config_dir)" = "$main" ] \
    || fail "the explicit account must be what is recorded"
  pass "--claude-config-dir overrides the home's account for that worker"
}

test_inherited_account_is_recorded_when_no_home_setting() {
  local id=acct-env-d4 out rc main
  make_case env-fallback claude "$id"
  main=$(make_store claude-main)

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$main" run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "spawn should succeed"$'\n'"$out"
  assert_launch_account "$main" "firstmate's own CLAUDE_CONFIG_DIR must still be forwarded"
  [ "$(meta_value "$id" claude_config_dir)" = "$main" ] \
    || fail "an inherited account must be recorded so a relaunch from another shell keeps it"
  pass "with no home setting, firstmate's own account is forwarded and recorded"
}

test_nothing_configured_records_the_default_store() {
  local id=acct-none-e5 out rc
  make_case none claude "$id"

  out=$(run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "spawn should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR=" "no account means no prefix, as before"
  [ "$(meta_value "$id" claude_config_dir)" = default ] \
    || fail "an unconfigured claude launch must record default, got '$(meta_value "$id" claude_config_dir)'"
  pass "an unconfigured claude launch keeps today's launch and records the default store"
}

test_default_home_setting_does_not_inherit_firstmates_account() {
  local id=acct-default-f6 out rc alt
  make_case default-setting claude "$id"
  alt=$(make_store claude-alt)
  set_home_account "$HOME_DIR/config" "# use Claude's own default store"$'\n'"default"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$alt" run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "spawn should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR=" \
    "a home pinned to default must not forward firstmate's own account"
  [ "$(meta_value "$id" claude_config_dir)" = default ] || fail "default must be recorded"
  pass "a home pinned to default uses Claude's own store even when firstmate runs under another"
}

test_non_claude_launch_records_no_account() {
  local id=acct-codex-g7 out rc alt
  make_case codex-none codex "$id"
  alt=$(make_store claude-alt)
  set_home_account "$HOME_DIR/config" "$alt"

  out=$(run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "codex spawn should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR=" "codex must not receive a claude account"
  if grep -q '^claude_config_dir=' "$HOME_DIR/state/$id.meta"; then
    fail "a non-claude launch must record no claude account"
  fi
  pass "a non-claude launch neither receives nor records a Claude account"
}

test_batch_forwards_the_explicit_account() {
  local id1=acct-batch-h8 id2=acct-batch-h9 out rc alt
  make_case batch claude "$id1" "$id2"
  alt=$(make_store claude-alt)

  out=$(run_ship_spawn "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --claude-config-dir "$alt"); rc=$?
  expect_code 0 "$rc" "batch spawn should succeed"$'\n'"$out"
  [ "$(meta_value "$id1" claude_config_dir)" = "$alt" ] || fail "first batch task lost the shared account"
  [ "$(meta_value "$id2" claude_config_dir)" = "$alt" ] || fail "second batch task lost the shared account"
  pass "batch dispatch forwards a shared --claude-config-dir to every pair"
}

# --- secondmates: the target home owns the account ----------------------------

test_secondmate_uses_its_own_homes_account() {
  local id=acct-sm-j1 sm out rc alt main
  make_case sm-home claude "$id"
  alt=$(make_store claude-alt)
  main=$(make_store claude-main)
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  set_home_account "$HOME_DIR/config" "$main"
  set_home_account "$sm/config" "$alt"

  out=$(run_spawn "$id" "$sm" --harness claude --secondmate); rc=$?
  expect_code 0 "$rc" "secondmate spawn should succeed"$'\n'"$out"
  assert_launch_account "$alt" "a secondmate must launch on its own home's account, not the primary's"
  [ "$(meta_value "$id" claude_config_dir)" = "$alt" ] || fail "the secondmate's account must be recorded"
  [ "$(cat "$sm/config/claude-config-dir")" = "$alt" ] \
    || fail "spawning the secondmate must not overwrite its home's own account with the primary's"
  pass "a secondmate launches on its own home's account, which is never inherited from the primary"
}

test_secondmate_respawn_reuses_the_recorded_account() {
  local id=acct-sm-k2 sm out rc alt main
  make_case sm-respawn claude "$id"
  alt=$(make_store claude-alt)
  main=$(make_store claude-main)
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$id" "$sm" --harness claude --secondmate --claude-config-dir "$alt"); rc=$?
  expect_code 0 "$rc" "first secondmate spawn should succeed"$'\n'"$out"
  assert_launch_account "$alt" "the explicit account did not reach the first launch"

  # A recovery respawn runs from whatever shell the liveness sweep has, with no
  # override; it must stay on the recorded account.
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$main" run_spawn "$id" --secondmate); rc=$?
  expect_code 0 "$rc" "secondmate respawn should succeed"$'\n'"$out"
  assert_launch_account "$alt" "a secondmate respawn silently moved to another account"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "$main" "the respawn shell's account leaked into the launch"
  [ "$(meta_value "$id" claude_config_dir)" = "$alt" ] || fail "the respawn must keep the recorded account"
  pass "a secondmate recovery respawn keeps the account its record names"
}

# --- refusals -----------------------------------------------------------------

test_override_is_refused_for_a_non_claude_harness() {
  local id=acct-refuse-m1 out rc alt
  make_case refuse-codex codex "$id"
  alt=$(make_store claude-alt)

  out=$(run_ship_spawn "$id" "$PROJ_DIR" --harness codex --claude-config-dir "$alt"); rc=$?
  [ "$rc" -ne 0 ] || fail "--claude-config-dir on a codex spawn must be refused"
  assert_contains "$out" "applies only to claude launches" "the refusal must say why"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not publish a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must launch nothing"
  pass "--claude-config-dir is refused for a non-claude harness"
}

test_unusable_accounts_are_refused_before_any_endpoint() {
  local id out rc
  make_case refuse-paths claude acct-refuse-n1 acct-refuse-n2 acct-refuse-n3 acct-refuse-n4 acct-refuse-n5

  id=acct-refuse-n1
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --claude-config-dir "$CASE_DIR/missing"); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing override folder must be refused"
  assert_contains "$out" "not an existing directory" "the refusal must name the missing folder"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not publish a task record"

  id=acct-refuse-n2
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --claude-config-dir relative/store); rc=$?
  [ "$rc" -ne 0 ] || fail "a relative override must be refused"
  assert_contains "$out" "not an absolute path" "the refusal must say the path is relative"

  id=acct-refuse-n3
  set_home_account "$HOME_DIR/config" "$CASE_DIR/gone"
  out=$(run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  [ "$rc" -ne 0 ] || fail "a home setting naming a missing folder must be refused, not skipped"
  assert_contains "$out" "$HOME_DIR/config/claude-config-dir" "the refusal must name the config file"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not publish a task record"
  rm -f "$HOME_DIR/config/claude-config-dir"

  id=acct-refuse-n4
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/nowhere" run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  [ "$rc" -ne 0 ] || fail "an inherited account naming a missing folder must be refused"
  assert_contains "$out" "own CLAUDE_CONFIG_DIR" "the refusal must name the inherited source"

  id=acct-refuse-n5
  out=$(run_ship_spawn "$id" "$PROJ_DIR" --claude-config-dir=); rc=$?
  [ "$rc" -ne 0 ] || fail "an empty override must be refused"
  assert_contains "$out" "requires a non-empty value" "the refusal must say the value is empty"

  [ ! -s "$LAUNCH_LOG" ] || fail "no refused spawn may launch anything"
  pass "missing, relative, and empty accounts from every source are refused before launch"
}

test_override_is_refused_for_a_remote_secondmate() {
  local id=acct-remote-p1 out rc alt
  make_case refuse-remote claude "$id"
  alt=$(make_store claude-alt)
  cat > "$HOME_DIR/data/secondmates.md" <<EOF
- $id - remote tasks (host: remote-mac; root: /opt/firstmate; home: /opt/homes/$id; scope: remote tasks; projects: alpha; added 2026-09-22)
EOF

  out=$(run_spawn "$id" --secondmate --claude-config-dir "$alt"); rc=$?
  [ "$rc" -ne 0 ] || fail "--claude-config-dir must be refused for a remote secondmate"
  assert_contains "$out" "set config/claude-config-dir in its remote home" \
    "the refusal must point at the remote home's own setting"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused remote spawn must not publish a task record"
  pass "--claude-config-dir is refused for a remote secondmate, whose home owns its account"
}

test_unreadable_home_setting_is_refused() {
  local id=acct-cfg-q1 out rc
  make_case unreadable-setting claude "$id"
  mkdir -p "$HOME_DIR/config/claude-config-dir"

  out=$(run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable home setting must refuse the spawn"
  assert_contains "$out" "is not a readable file" "the refusal must name the unreadable setting"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not publish a task record"
  pass "an unreadable config/claude-config-dir refuses rather than falling back"
}

test_home_setting_chooses_the_account_and_is_recorded
test_home_setting_wins_over_the_inherited_account
test_explicit_override_wins_over_the_home_setting
test_inherited_account_is_recorded_when_no_home_setting
test_nothing_configured_records_the_default_store
test_default_home_setting_does_not_inherit_firstmates_account
test_non_claude_launch_records_no_account
test_batch_forwards_the_explicit_account
test_secondmate_uses_its_own_homes_account
test_secondmate_respawn_reuses_the_recorded_account
test_override_is_refused_for_a_non_claude_harness
test_unusable_accounts_are_refused_before_any_endpoint
test_override_is_refused_for_a_remote_secondmate
test_unreadable_home_setting_is_refused

# --- claude.ai connectors stay off for every unattended launch ----------------

test_connectors_are_off_for_every_unattended_claude_launch() {
  local id=conn-off-r1 sm out rc
  make_case connectors claude "$id" conn-off-r2 conn-off-r3
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" conn-off-r3

  out=$(run_ship_spawn "$id" "$PROJ_DIR"); rc=$?
  expect_code 0 "$rc" "crewmate spawn should succeed"$'\n'"$out"
  assert_contains "$(cat "$LAUNCH_LOG")" "ENABLE_CLAUDEAI_MCP_SERVERS=false " "crewmate launch must disable claude.ai connectors"

  out=$(run_spawn conn-off-r2 "$PROJ_DIR" --scout); rc=$?
  expect_code 0 "$rc" "scout spawn should succeed"$'\n'"$out"
  assert_contains "$(cat "$LAUNCH_LOG")" "ENABLE_CLAUDEAI_MCP_SERVERS=false " "scout launch must disable claude.ai connectors"

  out=$(run_spawn conn-off-r3 "$sm" --harness claude --secondmate); rc=$?
  expect_code 0 "$rc" "secondmate spawn should succeed"$'\n'"$out"
  assert_contains "$(cat "$LAUNCH_LOG")" "ENABLE_CLAUDEAI_MCP_SERVERS=false " "secondmate launch must disable claude.ai connectors"

  out=$(run_spawn conn-off-r3 --secondmate); rc=$?
  expect_code 0 "$rc" "secondmate respawn should succeed"$'\n'"$out"
  assert_contains "$(cat "$LAUNCH_LOG")" "ENABLE_CLAUDEAI_MCP_SERVERS=false " "a respawn must disable claude.ai connectors"
  pass "crewmate, scout, secondmate, and respawn launches all disable claude.ai connectors"
}

test_connectors_are_off_for_every_unattended_claude_launch

echo "# all fm-spawn-claude-account tests passed"
