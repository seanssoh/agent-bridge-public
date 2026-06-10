#!/usr/bin/env bash
# scripts/smoke/1756-settings-preserve-model-user-keys.sh — Issue #1756 regression smoke.
#
# Background (#1756): the settings renderers preserve only the keys in
# `PRESERVED_USER_KEYS` across every rerender (upgrade / restart-propagate /
# rerender-settings). `model` — an operator's pinned Claude session model —
# was NOT on that list, so an operator who pinned `"model"` saw it silently
# reverted to the CLI default on the next re-render (live-confirmed on a
# macOS v0.16.5 install). The fix adds `model` plus the benign
# session-preference toggles `alwaysThinkingEnabled` / `agentPushNotifEnabled`
# to the allowlist — keys that are user preferences with NO bridge-managed
# default (so the bridge has no rendered value to lose). It stays a CURATED
# ALLOWLIST, not a preserve-everything denylist, so arbitrary keys still drop
# and the #1495 invalid-hook-key sanitize contract holds.
#
# Sub-tests (mapped to the issue's verification matrix):
#   (a) `model` + the new benign toggles survive a rerender; an arbitrary
#       unknown key (`unrelatedSetting`) does NOT — allowlist stays tight.
#       REVERT TEETH: removing `model` from PRESERVED_USER_KEYS fails this.
#   (b) Managed keys still re-render — a stale per-agent hook command is
#       corrected by the render even while user keys are preserved.
#   (c) The #1495 poison hook key is still sanitized on the same render that
#       preserves `model` — the sanitize contract and the allowlist coexist.
#   (d) Adoption fold (`link-shared-settings`): converting a regular per-agent
#       settings.json carrying `model` to the managed symlink folds `model`
#       into the shared effective target — nothing lost at symlink takeover.
#
# (Criterion (e) — global `model` inherits through the #11901 safety filter —
# is pinned in 11901-shared-global-settings-inherit-helper.py, which renders
# the shared path with an operator-global; this smoke covers the per-agent
# preserve + adoption surface.)

set -euo pipefail

SMOKE_NAME="1756-settings-preserve-model-user-keys"
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
  mkdir -p "$FIXTURE_BRIDGE_HOME/agents/.claude"

  # Use the real shared base so the smoke catches base-side regressions too.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"
  echo '{}' >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"

  BASE="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"
  OVERLAY="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"
  EFFECTIVE="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.effective.json"
}

invoke_shared_renderer() {
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$BASE" \
    --overlay-settings-file "$OVERLAY" \
    --effective-settings-file "$EFFECTIVE" \
    --agent-class static \
    --launch-cmd ""
}

assert_model_and_toggles_preserved() {
  # (a) operator edits the effective file with model + the new benign toggles
  # plus an arbitrary unknown key. The render must keep the allowlisted ones
  # and drop the arbitrary one.
  invoke_shared_renderer >/dev/null
  python3 "$SCRIPT_DIR/1756-settings-preserve-model-user-keys-helper.py" seed-user-keys "$EFFECTIVE"

  invoke_shared_renderer >/dev/null

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_contains "$content" '"model": "claude-opus-4-8[1m]"' \
    "operator model pin preserved across rerender (#1756 core — REVERT TEETH)"
  smoke_assert_contains "$content" '"alwaysThinkingEnabled": true' \
    "alwaysThinkingEnabled session toggle preserved"
  smoke_assert_contains "$content" '"agentPushNotifEnabled": false' \
    "agentPushNotifEnabled session toggle preserved (operator-set false honored)"
  smoke_assert_not_contains "$content" "unrelatedSetting" \
    "arbitrary unknown key still dropped (allowlist stays tight, not a denylist)"
}

assert_managed_keys_still_rerender() {
  # (b) the render still OWNS managed surface: a stale per-agent hook command
  # in the effective file is corrected to the bridge base command on rerender
  # even though user keys are preserved. Seed a bogus Stop hook command and
  # confirm the render restores the real one.
  python3 "$SCRIPT_DIR/1756-settings-preserve-model-user-keys-helper.py" seed-stale-hook "$EFFECTIVE"

  invoke_shared_renderer >/dev/null

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_contains "$content" 'mark-idle.sh' \
    "managed bridge Stop hook re-rendered over a stale per-agent hook (#1756 (b))"
  smoke_assert_not_contains "$content" 'STALE-OPERATOR-HOOK.sh' \
    "stale operator hook command does NOT survive (render owns managed keys)"
  smoke_assert_contains "$content" '"model": "claude-opus-4-8[1m]"' \
    "model still preserved alongside the managed-hook correction"
}

assert_poison_hook_key_sanitized_with_model_preserved() {
  # (c) the #1495 invalid-hook-key sanitize and the new model preserve coexist:
  # a poison hook event (PermissionDenied — rejected by CC v2.1.87) is dropped
  # on the SAME render that preserves model.
  python3 "$SCRIPT_DIR/1756-settings-preserve-model-user-keys-helper.py" seed-poison-hook "$EFFECTIVE"

  invoke_shared_renderer 2>/dev/null >/dev/null

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_not_contains "$content" 'PermissionDenied' \
    "invalid hook event still sanitized (#1495 contract holds under #1756)"
  smoke_assert_contains "$content" '"model": "claude-opus-4-8[1m]"' \
    "model preserved on the same render that sanitizes the poison hook key"
}

assert_adoption_fold_preserves_model() {
  # (d) link-shared-settings adoption fold: a regular per-agent settings.json
  # carrying model is converted to the managed symlink; model must be folded
  # into the shared effective target so it is NOT lost at takeover.
  local wd="$SMOKE_TMP_ROOT/adopt-workdir"
  mkdir -p "$wd/.claude"
  # The shared effective target the symlink will point at — render it fresh
  # WITHOUT model (simulating the pre-#1756 render output the operator never
  # had model folded into).
  local shared_effective="$SMOKE_TMP_ROOT/shared/settings.effective.json"
  mkdir -p "$(dirname "$shared_effective")"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$BASE" \
    --overlay-settings-file "$OVERLAY" \
    --effective-settings-file "$shared_effective" \
    --agent-class static \
    --launch-cmd "" >/dev/null
  smoke_assert_not_contains "$(cat "$shared_effective")" '"model"' \
    "pre-adoption shared effective has no model (operator key lives only in the per-agent file)"

  # The operator's regular per-agent settings.json carrying a pinned model.
  cat >"$wd/.claude/settings.json" <<'EOF'
{
  "model": "claude-opus-4-8[1m]",
  "enabledPlugins": {"context7@official": false}
}
EOF

  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" link-shared-settings \
    --workdir "$wd" \
    --shared-settings-file "$shared_effective" 2>/dev/null >/dev/null

  # The workdir settings.json is now a symlink to the shared effective file.
  [[ -L "$wd/.claude/settings.json" ]] \
    || smoke_fail "workdir settings.json should be a symlink after adoption"
  local folded
  folded="$(cat "$shared_effective")"
  smoke_assert_contains "$folded" '"model": "claude-opus-4-8[1m]"' \
    "model folded into shared effective at adoption time (#1756 (3) — no loss at symlink takeover)"
  smoke_assert_contains "$folded" '"context7@official": false' \
    "operator enabledPlugins also folded at adoption (existing preserved key)"
}

main() {
  build_fixture

  smoke_run "model + benign toggles preserved; arbitrary key dropped (#1756 (a))" \
    assert_model_and_toggles_preserved
  smoke_run "managed keys still re-render over stale per-agent hook (#1756 (b))" \
    assert_managed_keys_still_rerender
  smoke_run "poison hook key sanitized while model preserved (#1756 (c))" \
    assert_poison_hook_key_sanitized_with_model_preserved
  smoke_run "adoption fold carries model into shared effective (#1756 (d))" \
    assert_adoption_fold_preserves_model

  smoke_log "PASS"
}

main "$@"
