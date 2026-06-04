#!/usr/bin/env bash
# scripts/smoke/1453-channel-sticky-false-inbound.sh — Issue #1453 smoke.
#
# A bridge channel agent (telegram/discord) silently loses INBOUND delivery
# while OUTBOUND keeps working when its
# `enabledPlugins["<plugin>@<marketplace>"]` entry is `false` in the
# rendered settings.effective.json. The plugin delivers inbound as an MCP
# notification; if the plugin is disabled in the session's enabledPlugins,
# Claude Code never wires the handler → inbound is dropped with no error.
#
# Two compounding bridge mechanisms (both fixed in bridge-hooks.py):
#
#   A. The renderer never learned which channel plugins the agent runs
#      with. The managed-default parser
#      (`agent_bridge_development_plugin_settings`) only matched the
#      internal `--dangerously-load-development-channels` flag inline in
#      the launch command. But (1) the launched process uses the public
#      `--channels` alias, and (2) for a NORMALLY-CREATED channel agent the
#      bridge composes `--channels` from BRIDGE_AGENT_CHANNELS at launch
#      time — the *stored* launch command the renderer is fed
#      (`bridge_agent_launch_cmd_raw`) carries NO channel flag at all. Either
#      way the renderer saw zero specs → managed defaults never asserted the
#      launched plugin `true`. The fix: parse the `--channels` alias inline
#      AND thread the agent's resolved channels CSV (the
#      `bridge_agent_channels_csv` SSOT) into the renderer as
#      `--channels-csv`; the union is the launched channel set.
#
#   B. `enabledPlugins` is a PRESERVED user key merged LAST, so once
#      Claude Code's plugin runtime records `<channel>: false` into the
#      effective file, every rerender (restart / rerender / upgrade
#      propagate) re-preserves that `false` and the managed `true` can
#      never win. The sticky-false survived forever; a restart provably
#      did nothing. The fix re-asserts the bridge's authority over
#      LAUNCHED-channel plugins AFTER the preserved merge, while still
#      preserving operator enable/disable for NON-launched plugins.
#
# Sub-tests (all driven through the `render-shared-settings` Python
# renderer — the chokepoint every live agent's settings.effective.json
# flows through on start / restart / upgrade):
#
#   FRESH+CSV     — a fresh render of a normally-created channel agent
#                   (launch cmd has NO --channels; channels via
#                   --channels-csv) enables the launched channel plugin —
#                   the production path that was actually broken (fix A).
#
#   INLINE-ALIAS  — an agent whose launch command DOES carry `--channels`
#                   inline (no CSV) still enables the plugin — pins the
#                   launch-cmd alias parser independently.
#
#   STICKY-FALSE  — seed an effective file with the launched channel's
#                   enabledPlugins entry = false (as Claude Code's runtime
#                   would record it), rerender, and assert it is forced
#                   back to true (covers fix B). TEETH: the seed is
#                   asserted false BEFORE the render, so reverting
#                   `_repair_sticky_false_channel_enables` makes the
#                   post-render "true" assertion fail.
#
#   LEGIT-DISABLE — a NON-launched plugin disabled in the effective file
#                   stays disabled across the rerender (the repair must not
#                   over-reach and re-enable plugins the operator turned
#                   off that are not part of the launched channel set).
#
#   STDOUT/STDERR — the sticky-false correction `[warn]` lands on stderr;
#                   stdout stays the pure shell key=val render payload.
#
# Does NOT exercise the bash sudo stage→install→symlink dance
# (Linux-host-only, covered operator-side per OPERATIONS.md).

set -euo pipefail

SMOKE_NAME="1453-channel-sticky-false-inbound"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# The launched channel plugin spec the agent runs with. `enabledPlugins`
# keys are the `<plugin>@<marketplace>` form (leading `plugin:` stripped).
CHANNEL_SPEC="telegram@claude-plugins-official"
# A second, NON-launched plugin used to prove the repair does not
# re-enable operator-disabled plugins outside the launched channel set.
OTHER_SPEC="some-tool@third-party-marketplace"
# The PRIMARY production reality: a normally-created channel agent stores a
# launch command WITHOUT the `--channels` flag — the bridge composes that
# flag from BRIDGE_AGENT_CHANNELS at launch time, and the renderer is fed
# `bridge_agent_launch_cmd_raw` (no channels). The agent's channel set
# reaches the renderer ONLY via `--channels-csv` (resolved from
# `bridge_agent_channels_csv`, the SSOT). These two values model that path.
LAUNCH_CMD="claude --dangerously-skip-permissions --name jjujju"
CHANNELS_CSV="plugin:${CHANNEL_SPEC}"
# The legacy/inline path: some agents DO carry the channel flag inline in the
# launch command (explicit `--channels` / dev-channels args). Used by the
# inline-alias sub-test to pin fix A's launch-cmd parser independently.
LAUNCH_CMD_INLINE="claude --dangerously-skip-permissions --name jjujju --channels plugin:${CHANNEL_SPEC}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"

  FIXTURE_BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  mkdir -p "$FIXTURE_BRIDGE_HOME/agents/.claude"

  # Seed the shared base settings the renderer pulls in. A copy of the
  # REAL source base keeps the render faithful to a live install.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"

  # Empty overlay (no per-agent overrides). The shared renderer treats a
  # JSON `{}` as "no overrides"; a zero-byte file is rejected by load_json,
  # so write an explicit empty object.
  printf '{}\n' >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"
}

# Render the shared settings into a caller-named effective file and route
# stderr to a caller-named file so the stdout/stderr separation can be
# asserted. Models the PRODUCTION path: the launch command carries NO
# `--channels` flag; the channel set arrives via `--channels-csv` (the
# BRIDGE_AGENT_CHANNELS SSOT, the only signal a normally-created channel
# agent's renderer has).
render_shared() {
  local effective="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --effective-settings-file "$effective" \
    --launch-cmd "$LAUNCH_CMD" \
    --agent-class static \
    --channels-csv "$CHANNELS_CSV" \
    --format shell \
    >"$stdout_file" 2>"$stderr_file"
}

# Assert `enabledPlugins[<spec>]` in $1 is exactly JSON `true`/`false` per
# the $3 expectation ("true" or "false"). Fails loudly otherwise.
#
# python3 -c with file-as-argv (path + spec + expected) rather than a
# heredoc-stdin subprocess, to stay clear of the footgun-#11 heredoc-ban
# lint (scripts/lint-heredoc-ban.sh).
assert_plugin_enabled_state() {
  local path="$1"
  local spec="$2"
  local expected="$3"
  local context="$4"
  python3 -c '
import json
import sys

path, spec, expected, context = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)  # raises on malformed -> smoke fails loudly
enabled = data.get("enabledPlugins", {})
if not isinstance(enabled, dict):
    sys.stderr.write(context + ": enabledPlugins is not an object: " + repr(enabled) + "\n")
    sys.exit(1)
actual = enabled.get(spec)
want = True if expected == "true" else False
if actual is not want:
    sys.stderr.write(
        context + ": enabledPlugins[" + spec + "] is " + repr(actual)
        + " want " + repr(want) + "\n"
    )
    sys.exit(1)
' "$path" "$spec" "$expected" "$context" \
    || smoke_fail "$context"
}

# FRESH+CSV — fix A, PRODUCTION path: a fresh render of a normally-created
# channel agent (launch cmd has NO --channels; channels arrive via
# --channels-csv) enables the launched channel plugin in managed defaults.
# This is the path codex flagged: the stored launch command does not carry
# --channels, so without --channels-csv threading the renderer would emit
# zero specs and the channel would never be asserted enabled.
assert_fresh_csv_enables() {
  local effective="$SMOKE_TMP_ROOT/fresh.effective.json"
  local out="$SMOKE_TMP_ROOT/fresh.out"
  local err="$SMOKE_TMP_ROOT/fresh.err"
  render_shared "$effective" "$out" "$err"

  smoke_assert_file_exists "$effective" \
    "fresh CSV render produced settings.effective.json"

  assert_plugin_enabled_state "$effective" "$CHANNEL_SPEC" "true" \
    "fresh --channels-csv render enables the launched channel plugin (fix A CSV path: #1453)"
}

# INLINE-ALIAS — fix A, legacy/inline path: an agent whose launch command
# DOES carry the public `--channels` alias inline (and NO --channels-csv)
# still gets the launched channel plugin enabled. Pins the launch-cmd parser
# independently of the CSV threading.
assert_inline_channels_alias_enables() {
  local effective="$SMOKE_TMP_ROOT/inline.effective.json"
  local out="$SMOKE_TMP_ROOT/inline.out"
  local err="$SMOKE_TMP_ROOT/inline.err"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --effective-settings-file "$effective" \
    --launch-cmd "$LAUNCH_CMD_INLINE" \
    --agent-class static \
    --format shell \
    >"$out" 2>"$err"

  assert_plugin_enabled_state "$effective" "$CHANNEL_SPEC" "true" \
    "inline --channels (no CSV) render enables the launched channel plugin (fix A alias: #1453)"
}

# CSV MULTI-CHANNEL — fix A robustness: --channels-csv may carry multiple
# channel items (the form bridge_agent_channels_csv emits). Each
# `plugin:<x>@<m>` item must be enabled; a `server:<name>` item is not a
# plugin and must NOT appear in enabledPlugins. A single inline --channels
# flag value may ALSO be a CSV (bridge_extract_channels_from_command), so
# exercise both the --channels-csv arg and an inline CSV flag value.
assert_channels_csv_multi_enables() {
  local effective="$SMOKE_TMP_ROOT/csv.effective.json"
  local out="$SMOKE_TMP_ROOT/csv.out"
  local err="$SMOKE_TMP_ROOT/csv.err"
  local csv_spec_b="discord@claude-plugins-official"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --effective-settings-file "$effective" \
    --launch-cmd "claude --name multi" \
    --channels-csv "plugin:${CHANNEL_SPEC},plugin:${csv_spec_b},server:irc" \
    --agent-class static \
    --format shell \
    >"$out" 2>"$err"

  assert_plugin_enabled_state "$effective" "$CHANNEL_SPEC" "true" \
    "CSV multi render enables the first launched plugin (fix A CSV: #1453)"
  assert_plugin_enabled_state "$effective" "$csv_spec_b" "true" \
    "CSV multi render enables the second launched plugin (fix A CSV: #1453)"
  # The server: item is not a plugin — it must not be written as an
  # enabledPlugins entry.
  smoke_assert_not_contains "$(cat "$effective")" '"server:irc"' \
    "CSV multi render does NOT add the server: item as a plugin"
}

# STICKY-FALSE — fix B: a pre-existing effective file with the launched
# channel's entry = false is forced back to true on rerender.
assert_sticky_false_repaired() {
  local effective="$SMOKE_TMP_ROOT/sticky.effective.json"

  # Seed the effective file exactly as a live agent would carry it AFTER
  # Claude Code's plugin runtime recorded the launched channel disabled.
  # enabledPlugins is a PRESERVED user key, so without the repair this
  # `false` is re-preserved on every rerender and the managed `true` can
  # never win.
  cat >"$effective" <<EOF
{
  "enabledPlugins": {
    "${CHANNEL_SPEC}": false
  }
}
EOF

  # TEETH — prove the seed is actually false BEFORE the render. If a future
  # refactor stops seeding false, the post-render "true" assertion would
  # pass vacuously; this guards against that.
  assert_plugin_enabled_state "$effective" "$CHANNEL_SPEC" "false" \
    "TEETH: seeded effective file starts with the launched channel DISABLED"

  local out="$SMOKE_TMP_ROOT/sticky.out"
  local err="$SMOKE_TMP_ROOT/sticky.err"
  render_shared "$effective" "$out" "$err"

  # The render re-preserves enabledPlugins from the existing effective file
  # (so the false is carried in), then the #1453 repair forces the LAUNCHED
  # channel's entry back to true. Reverting
  # `_repair_sticky_false_channel_enables` makes THIS assertion fail.
  assert_plugin_enabled_state "$effective" "$CHANNEL_SPEC" "true" \
    "rerender REPAIRS the sticky-false launched channel to true (fix B: #1453)"
}

# LEGIT-DISABLE — the repair must not over-reach: a NON-launched plugin the
# operator disabled in the effective file stays disabled.
assert_non_launched_disable_preserved() {
  local effective="$SMOKE_TMP_ROOT/legit.effective.json"

  cat >"$effective" <<EOF
{
  "enabledPlugins": {
    "${CHANNEL_SPEC}": false,
    "${OTHER_SPEC}": false
  }
}
EOF

  local out="$SMOKE_TMP_ROOT/legit.out"
  local err="$SMOKE_TMP_ROOT/legit.err"
  render_shared "$effective" "$out" "$err"

  # Launched channel repaired to true...
  assert_plugin_enabled_state "$effective" "$CHANNEL_SPEC" "true" \
    "launched channel repaired to true alongside a legit disable"
  # ...but the operator's disable of a NON-launched plugin is preserved.
  assert_plugin_enabled_state "$effective" "$OTHER_SPEC" "false" \
    "NON-launched plugin stays operator-disabled (repair does not over-reach: #1453)"
}

# STDOUT/STDERR — the sticky-false correction warns on stderr; stdout stays
# the pure shell key=val payload.
assert_warn_on_stderr_stdout_pure() {
  local effective="$SMOKE_TMP_ROOT/stream.effective.json"

  cat >"$effective" <<EOF
{
  "enabledPlugins": {
    "${CHANNEL_SPEC}": false
  }
}
EOF

  local out="$SMOKE_TMP_ROOT/stream.out"
  local err="$SMOKE_TMP_ROOT/stream.err"
  render_shared "$effective" "$out" "$err"

  local stdout_content stderr_content
  stdout_content="$(cat "$out")"
  stderr_content="$(cat "$err")"

  smoke_assert_contains "$stderr_content" '[warn]' \
    "sticky-false correction warns on stderr"
  smoke_assert_contains "$stderr_content" '1453' \
    "stderr warning names the #1453 sticky-false condition"
  smoke_assert_contains "$stderr_content" "$CHANNEL_SPEC" \
    "stderr warning names the corrected channel plugin"
  smoke_assert_not_contains "$stdout_content" '[warn]' \
    "stdout carries NO warning text (stays machine-parseable)"
  smoke_assert_contains "$stdout_content" 'EFFECTIVE_SETTINGS_FILE=' \
    "stdout carries the shell-format render payload"
}

main() {
  build_fixture

  smoke_run "fresh --channels-csv render enables the launched channel plugin (production path)" \
    assert_fresh_csv_enables
  smoke_run "inline --channels alias (no CSV) enables the launched channel plugin" \
    assert_inline_channels_alias_enables
  smoke_run "CSV multi enables each plugin item, drops server item" \
    assert_channels_csv_multi_enables
  smoke_run "rerender repairs the sticky-false launched channel (with teeth)" \
    assert_sticky_false_repaired
  smoke_run "non-launched operator-disable is preserved (no over-reach)" \
    assert_non_launched_disable_preserved
  smoke_run "sticky-false correction warns on stderr, stdout stays pure" \
    assert_warn_on_stderr_stdout_pure

  smoke_log "PASS"
}

main "$@"
