#!/usr/bin/env bash
# scripts/smoke/isolated-settings-rendering.sh — Issue #544 PR2 smoke.
#
# Validates the `bridge-hooks.py render-isolated-home-settings` Python
# renderer against a stub isolated home. Exercises five sub-tests:
#
# 1. The rendered `<isolated-home>/.claude/settings.effective.json`
#    contains the bridge hook entries (Stop / UserPromptSubmit /
#    SessionStart / PermissionDenied — the suite shipped in
#    agents/.claude/settings.json after PR #550).
# 2. `<isolated-home>/.claude/settings.json` is a symlink pointing at
#    the relative path `settings.effective.json`.
# 3. Pre-existing user keys (`enabledPlugins`, `extraKnownMarketplaces`,
#    `skipDangerousModePermissionPrompt`) from the prior regular
#    `settings.json` are preserved into the rendered effective file.
# 4. Re-running the renderer is idempotent — same SHA256 on the
#    effective file across two consecutive invocations with no changes.
# 5. Re-running with an updated user-key value (after the symlink is in
#    place — i.e. via the staging path the bash helper uses) propagates
#    the new value, proving the renderer re-reads each invocation
#    rather than caching the first preserved set.
#
# Coverage: Python renderer logic only. Does NOT exercise:
#   - the bash wrapper `bridge_install_isolated_home_settings`'s sudo
#     stage→install→symlink-swap dance (requires real sudo + a real
#     isolated UID owning the .claude/ tree on a Linux host);
#   - the wire-in via `run_rerender_settings` and the
#     `bridge_migration_isolate --reapply` path (covered by callers).
# End-to-end coverage is operator-side per OPERATIONS.md (`agent-bridge
# isolate <agent> --reapply` + agent restart).

set -euo pipefail

SMOKE_NAME="isolated-settings-rendering"
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

  # Seed the shared base settings the renderer pulls in. Use a copy of
  # the real source so the smoke catches a future regression where the
  # base loses one of the managed hook entries.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"

  # Empty overlay — the renderer must tolerate absence + treat it as
  # `{}`. Touch it so the path exists; the renderer's load_json returns
  # `{}` for empty content too.
  : >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"

  # Pre-existing isolated UID settings.json with the three preserved
  # user keys, plus an extraneous key (`unrelatedSetting`) the renderer
  # MUST drop — only the documented allowlist is propagated.
  cat >"$FIXTURE_ISOLATED_HOME/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": ["foo", "bar"],
  "extraKnownMarketplaces": {"acme": {"source": "github:acme/marketplace"}},
  "skipDangerousModePermissionPrompt": true,
  "unrelatedSetting": "should-not-leak-into-effective"
}
EOF

  EFFECTIVE="$FIXTURE_ISOLATED_HOME/.claude/settings.effective.json"
  SETTINGS_LINK="$FIXTURE_ISOLATED_HOME/.claude/settings.json"
}

invoke_renderer() {
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$FIXTURE_ISOLATED_HOME" \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --launch-cmd ""
}

assert_hook_entries_present() {
  invoke_renderer >/dev/null

  smoke_assert_file_exists "$EFFECTIVE" \
    "settings.effective.json rendered into isolated home"

  local content
  content="$(cat "$EFFECTIVE")"
  # The bridge hook commands all live under `~/.agent-bridge/hooks/`.
  # Under the isolated UID this resolves via the per-home
  # `~/.agent-bridge -> $BRIDGE_HOME` symlink installed by
  # bridge_linux_install_agent_bridge_symlink. Asserting on the literal
  # path keeps the smoke independent of the symlink-resolution side.
  smoke_assert_contains "$content" '"Stop"' \
    "Stop hook event present in rendered effective"
  smoke_assert_contains "$content" '"UserPromptSubmit"' \
    "UserPromptSubmit event present"
  smoke_assert_contains "$content" '"SessionStart"' \
    "SessionStart event present"
  smoke_assert_contains "$content" '"PermissionDenied"' \
    "PermissionDenied event present"
  smoke_assert_contains "$content" 'mark-idle.sh' \
    "Stop suite includes mark-idle.sh"
  smoke_assert_contains "$content" 'surface-reply-enforce.py' \
    "Stop suite includes surface-reply-enforce.py (PR #550)"
  smoke_assert_contains "$content" 'session-stop.py' \
    "Stop suite includes session-stop.py (PR #550)"
  smoke_assert_contains "$content" 'session-start.py' \
    "SessionStart points at session-start.py"
  smoke_assert_contains "$content" 'prompt_timestamp.py' \
    "UserPromptSubmit includes prompt_timestamp.py"
  smoke_assert_contains "$content" 'permission_escalation.py' \
    "PermissionDenied points at permission_escalation.py"
}

assert_settings_is_symlink() {
  [[ -L "$SETTINGS_LINK" ]] || smoke_fail \
    "settings.json must be a symlink, got regular file: $SETTINGS_LINK"
  local target
  target="$(readlink "$SETTINGS_LINK")"
  smoke_assert_eq "settings.effective.json" "$target" \
    "settings.json target relative path"
}

assert_user_keys_preserved() {
  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_contains "$content" '"enabledPlugins"' \
    "enabledPlugins preserved into effective"
  smoke_assert_contains "$content" '"extraKnownMarketplaces"' \
    "extraKnownMarketplaces preserved into effective"
  smoke_assert_contains "$content" '"skipDangerousModePermissionPrompt"' \
    "skipDangerousModePermissionPrompt preserved into effective"
  smoke_assert_contains "$content" '"foo"' \
    "enabledPlugins value array element preserved"
  # The unrelated key MUST NOT leak through. The renderer's preserve
  # allowlist is intentionally tight — anything outside it is operator-
  # supplied state we don't promise to round-trip.
  smoke_assert_not_contains "$content" "unrelatedSetting" \
    "non-allowlisted user key dropped from effective"
}

assert_idempotent() {
  # Re-render with no input changes; the file's SHA256 must match.
  local before after
  before="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$EFFECTIVE")"
  invoke_renderer >/dev/null
  after="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$EFFECTIVE")"
  smoke_assert_eq "$before" "$after" \
    "rendered effective file SHA256 stable across consecutive renders"
}

assert_user_key_update_propagates() {
  # After the first render, settings.json is a symlink — there is no
  # regular user file for the renderer to extract preserved keys from.
  # The bash wrapper `bridge_install_isolated_home_settings` handles
  # this by reading the live settings.json into a controller-owned
  # staging area and pointing the renderer at THAT staging tree. Mirror
  # that contract in the smoke: stage a fresh isolated-home tree with
  # an updated user-key value and verify the rerender adopts it.
  local stage_root="$SMOKE_TMP_ROOT/stage-update"
  local stage_home="$stage_root/isolated-home"
  mkdir -p "$stage_home/.claude"
  cat >"$stage_home/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": ["foo", "bar", "baz-new"],
  "extraKnownMarketplaces": {"acme": {"source": "github:acme/marketplace-v2"}},
  "skipDangerousModePermissionPrompt": false
}
EOF
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$stage_home" \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --launch-cmd "" >/dev/null

  local content
  content="$(cat "$stage_home/.claude/settings.effective.json")"
  smoke_assert_contains "$content" '"baz-new"' \
    "updated enabledPlugins entry propagates on re-render"
  smoke_assert_contains "$content" 'marketplace-v2' \
    "updated extraKnownMarketplaces value propagates"
  # The boolean flip must take effect — JSON serializer writes lowercase.
  smoke_assert_contains "$content" '"skipDangerousModePermissionPrompt": false' \
    "boolean flip on skipDangerousModePermissionPrompt propagates"
}

main() {
  build_fixture

  smoke_run "bridge hook entries rendered into effective" \
    assert_hook_entries_present
  smoke_run "settings.json is a symlink to settings.effective.json" \
    assert_settings_is_symlink
  smoke_run "pre-existing user keys preserved" \
    assert_user_keys_preserved
  smoke_run "renderer is idempotent across consecutive runs" \
    assert_idempotent
  smoke_run "user-key updates propagate via staged re-render" \
    assert_user_key_update_propagates

  smoke_log "PASS"
}

main "$@"
