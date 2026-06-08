#!/usr/bin/env bash
# scripts/smoke/1689-statusline-preserve-rerender.sh — Issue #1689 regression smoke.
#
# Validates that the isolated-home settings rerender
# (`bridge-hooks.py render-isolated-home-settings`) PRESERVES an
# operator-configured top-level `statusLine` across every rerender.
#
# Background (issue #1689): an operator sets up a status line — e.g. the
# claude-hud HUD via `/claude-hud:setup` — which lives as a top-level
# `statusLine` object in settings.json. The rerender composes
# `managed defaults < base < overlay < preserved`, where `preserved` keeps
# ONLY the allowlist `PRESERVED_USER_KEYS`. `statusLine` was NOT on the
# allowlist, so every rerender (agent restart / `agb upgrade` / relink)
# silently dropped it and the operator's HUD vanished on the next upgrade.
# The fix adds "statusLine" to PRESERVED_USER_KEYS.
#
# Irony documented in the issue: the bridge already has HUD-aware code
# (`hud_usage_tap` reads + patches `settings["statusLine"]["command"]`),
# so the rerender that drops statusLine would also delete whatever the tap
# just wrote. This smoke proves a tap-patched command round-trips too.
#
# Sub-tests:
#   1. An operator statusLine survives a fresh render into the effective
#      file (this is the core #1689 fix — REVERT TEETH: removing
#      "statusLine" from PRESERVED_USER_KEYS makes this assertion FAIL).
#   2. A hud_usage_tap-patched statusLine.command (the
#      `python3 .../hud-usage-tap.py | exec "...bun..."` shape) round-trips
#      through a subsequent rerender — the two HUD paths are reconciled.
#   3. The statusLine survives a symlink-aware second render (the
#      post-first-install state where settings.json is a symlink to
#      settings.effective.json), proving idempotent preservation across
#      consecutive upgrades.

set -euo pipefail

SMOKE_NAME="1689-statusline-preserve-rerender"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"

  FIXTURE_BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  FIXTURE_ISOLATED_HOME="$SMOKE_TMP_ROOT/isolated-home"

  mkdir -p \
    "$FIXTURE_BRIDGE_HOME/agents/.claude" \
    "$FIXTURE_ISOLATED_HOME/.claude"

  # Use a copy of the real shared base so the smoke catches a base-side
  # regression alongside the preserve contract.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"

  # Empty overlay — the renderer treats an absent/empty overlay as `{}`.
  : >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"

  # Pre-existing isolated-UID settings.json carrying an operator statusLine
  # (claude-hud HUD shape). The renderer must carry it forward verbatim.
  # The `unrelatedSetting` key is the tight-allowlist control: it must NOT
  # round-trip even though statusLine now does.
  cat >"$FIXTURE_ISOLATED_HOME/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": ["foo"],
  "statusLine": {
    "type": "command",
    "command": "exec \"$HOME/.claude/claude-hud/node_modules/.bin/bun\" \"$HOME/.claude/claude-hud/src/index.ts\""
  },
  "unrelatedSetting": "should-not-leak-into-effective"
}
EOF

  EFFECTIVE="$FIXTURE_ISOLATED_HOME/.claude/settings.effective.json"  # noqa: iso-helper-boundary — smoke fixture path, not a runtime controller->iso callsite
  SETTINGS_LINK="$FIXTURE_ISOLATED_HOME/.claude/settings.json"
}

invoke_renderer() {
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$FIXTURE_ISOLATED_HOME" \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --launch-cmd ""
}

assert_statusline_preserved_on_render() {
  # Core #1689 fix + REVERT TEETH. Without "statusLine" in
  # PRESERVED_USER_KEYS the rendered effective file drops it and these
  # assertions FAIL — that is the regression this smoke guards.
  invoke_renderer >/dev/null

  smoke_assert_file_exists "$EFFECTIVE" \
    "settings.effective.json rendered into isolated home"  # noqa: iso-helper-boundary — assertion label, not a runtime callsite

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_contains "$content" '"statusLine"' \
    "operator statusLine preserved into effective (#1689 — HUD survives rerender)"
  smoke_assert_contains "$content" 'claude-hud/src/index.ts' \
    "statusLine.command value preserved verbatim"
  # Tight allowlist control: the unrelated operator key must still be dropped.
  smoke_assert_not_contains "$content" "unrelatedSetting" \
    "non-allowlisted user key still dropped (allowlist stays tight)"
}

assert_hud_tap_patched_command_round_trips() {
  # Issue #1689 irony: hud_usage_tap patches statusLine.command to pipe
  # through hud-usage-tap.py. With statusLine preserved, that patched
  # command must survive a subsequent rerender rather than being deleted.
  # Build a fresh isolated home whose statusLine.command is already in the
  # tapped shape, render, and confirm the tap prefix round-trips.
  local stage_root="$SMOKE_TMP_ROOT/stage-hud-tap"
  local stage_home="$stage_root/isolated-home"
  mkdir -p "$stage_home/.claude"
  cat >"$stage_home/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": ["foo"],
  "statusLine": {
    "type": "command",
    "command": "python3 /opt/agent-bridge/scripts/hud-usage-tap.py | exec \"$HOME/.claude/claude-hud/node_modules/.bin/bun\" \"$HOME/.claude/claude-hud/src/index.ts\""
  }
}
EOF
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$stage_home" \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --launch-cmd "" >/dev/null

  local content
  content="$(cat "$stage_home/.claude/settings.effective.json")"  # noqa: iso-helper-boundary — smoke fixture path, not a runtime callsite
  smoke_assert_contains "$content" 'hud-usage-tap.py' \
    "hud_usage_tap-patched statusLine.command round-trips through rerender (#1689)"
  smoke_assert_contains "$content" 'claude-hud/src/index.ts' \
    "the tapped HUD exec target survives alongside the tap prefix"
}

assert_statusline_survives_symlink_render() {
  # Post-first-install state: settings.json is a symlink to
  # settings.effective.json. A second render that only sees the symlink
  # must still preserve statusLine by dereferencing to the effective file
  # (the every-upgrade rerender path). Without preservation the HUD
  # vanishes on the NEXT upgrade even if it survived the first.
  local stage_root="$SMOKE_TMP_ROOT/stage-symlink-statusline"
  local stage_home="$stage_root/isolated-home"
  mkdir -p "$stage_home/.claude"
  # Seed an effective file (output of a prior render) already carrying a
  # preserved statusLine, then point settings.json at it as a symlink.
  cat >"$stage_home/.claude/settings.effective.json" <<'EOF'  # noqa: iso-helper-boundary — smoke fixture seed, not a runtime callsite
{
  "autoMemoryEnabled": true,
  "enabledPlugins": ["plugin-from-prior-render"],
  "statusLine": {
    "type": "command",
    "command": "exec \"$HOME/.claude/claude-hud/node_modules/.bin/bun\" \"$HOME/.claude/claude-hud/src/index.ts\""
  },
  "hooks": {}
}
EOF
  ln -s "settings.effective.json" "$stage_home/.claude/settings.json"  # noqa: iso-helper-boundary — smoke fixture symlink, not a runtime callsite

  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$stage_home" \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --launch-cmd "" >/dev/null

  local content
  content="$(cat "$stage_home/.claude/settings.effective.json")"  # noqa: iso-helper-boundary — smoke fixture path, not a runtime callsite
  smoke_assert_contains "$content" '"statusLine"' \
    "statusLine survives second render through symlink dereference (#1689)"
  smoke_assert_contains "$content" 'claude-hud/src/index.ts' \
    "statusLine.command survives the symlink-aware rerender verbatim"
}

main() {
  build_fixture

  smoke_run "operator statusLine preserved across rerender (#1689 core + revert teeth)" \
    assert_statusline_preserved_on_render
  smoke_run "hud_usage_tap-patched statusLine.command round-trips" \
    assert_hud_tap_patched_command_round_trips
  smoke_run "statusLine survives symlink-aware second render" \
    assert_statusline_survives_symlink_render

  smoke_log "PASS"
}

main "$@"
