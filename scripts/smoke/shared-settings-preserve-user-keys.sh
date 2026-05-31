#!/usr/bin/env bash
# scripts/smoke/shared-settings-preserve-user-keys.sh — Issue #613 regression smoke.
#
# Validates that `bridge-hooks.py render-shared-settings` preserves
# user-owned keys on rerender, matching the long-standing behavior of
# `render-isolated-home-settings`.
#
# Background (issue #613): the shared renderer used to overwrite the
# effective file from `managed defaults < base < overlay` on every call
# and silently dropped per-agent edits to `enabledPlugins`,
# `extraKnownMarketplaces`, `apiKeyHelper`,
# `skipDangerousModePermissionPrompt`. Operators
# who disabled heavy plugins per-agent saw their edits reverted on the
# next `agent restart`, `agent rerender-settings --apply`, `bridge-init.sh`
# run, or `agb upgrade propagate`. The fix extracted a shared
# `_load_preserved_user_keys()` helper used by both renderers; this smoke
# guards the shared-renderer path so the asymmetry can't silently return.
#
# Sub-tests:
#   1. Fresh render produces an effective file with no user keys
#      (preservation is a no-op when there's nothing to preserve).
#   2. After an operator edits the effective file with the preserved
#      keys, the next render keeps them verbatim.
#   3. Rerender is idempotent — same SHA256 across two consecutive runs.
#   4. Non-allowlisted operator keys do NOT round-trip — only the
#      documented allowlist is preserved.

set -euo pipefail

SMOKE_NAME="shared-settings-preserve-user-keys"
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

  # Use the real shared base so the smoke catches base-side regressions
  # at the same time it validates the preserve contract.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"
  # The shared renderer's `load_json` raises on a zero-byte file, so seed
  # the overlay with an explicit empty JSON object — matches the operator
  # contract that an absent / empty-object overlay is a no-op.
  echo '{}' >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"

  BASE="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"
  OVERLAY="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"
  EFFECTIVE="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.effective.json"
}

invoke_renderer() {
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$BASE" \
    --overlay-settings-file "$OVERLAY" \
    --effective-settings-file "$EFFECTIVE" \
    --launch-cmd ""
}

invoke_renderer_with_agent_bridge_plugin() {
  BRIDGE_HOME="$FIXTURE_BRIDGE_HOME" \
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
      --base-settings-file "$BASE" \
      --overlay-settings-file "$OVERLAY" \
      --effective-settings-file "$EFFECTIVE" \
      --launch-cmd "claude --dangerously-load-development-channels plugin:teams@agent-bridge"
}

assert_fresh_render_has_no_user_keys() {
  invoke_renderer >/dev/null

  smoke_assert_file_exists "$EFFECTIVE" \
    "settings.effective.json rendered by shared renderer"

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_not_contains "$content" '"enabledPlugins"' \
    "fresh render: no enabledPlugins preserved (nothing to preserve yet)"
  smoke_assert_not_contains "$content" '"extraKnownMarketplaces"' \
    "fresh render: no extraKnownMarketplaces preserved"
  smoke_assert_not_contains "$content" '"apiKeyHelper"' \
    "fresh render: no apiKeyHelper preserved"
  smoke_assert_not_contains "$content" '"skipDangerousModePermissionPrompt"' \
    "fresh render: no skipDangerousModePermissionPrompt preserved"
}

assert_user_keys_preserved_on_rerender() {
  # Operator edits the effective file in place — the documented per-agent
  # override pattern this smoke is regressing against.
  python3 - "$EFFECTIVE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["enabledPlugins"] = {"context7@claude-plugins-official": False}
payload["extraKnownMarketplaces"] = {
    "acme": {"source": {"type": "github", "repo": "acme/marketplace"}}
}
payload["apiKeyHelper"] = "/tmp/agent-bridge/claude-oat-api-key-helper.sh"
payload["skipDangerousModePermissionPrompt"] = True
payload["unrelatedSetting"] = "should-not-leak-into-effective"
path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

  invoke_renderer >/dev/null

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_contains "$content" '"context7@claude-plugins-official": false' \
    "enabledPlugins preserved with operator-disabled value"
  smoke_assert_contains "$content" '"acme"' \
    "extraKnownMarketplaces preserved with operator value"
  smoke_assert_contains "$content" '"apiKeyHelper": "/tmp/agent-bridge/claude-oat-api-key-helper.sh"' \
    "apiKeyHelper preserved with operator value"
  smoke_assert_contains "$content" '"skipDangerousModePermissionPrompt": true' \
    "skipDangerousModePermissionPrompt preserved"
  smoke_assert_not_contains "$content" "unrelatedSetting" \
    "non-allowlisted operator key dropped (allowlist is tight)"
}

assert_agent_bridge_plugin_settings_rendered() {
  rm -f "$EFFECTIVE"
  invoke_renderer_with_agent_bridge_plugin >/dev/null

  local content
  content="$(cat "$EFFECTIVE")"
  smoke_assert_contains "$content" '"teams@agent-bridge": true' \
    "Agent Bridge dev plugin is enabled from launch command"
  smoke_assert_contains "$content" '"extraKnownMarketplaces"' \
    "Agent Bridge marketplace settings are rendered"
  smoke_assert_contains "$content" "\"path\": \"$FIXTURE_BRIDGE_HOME\"" \
    "Agent Bridge marketplace path points at BRIDGE_HOME"
}

assert_idempotent() {
  local before after
  before="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$EFFECTIVE")"
  invoke_renderer >/dev/null
  after="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$EFFECTIVE")"
  smoke_assert_eq "$before" "$after" \
    "shared renderer is idempotent across consecutive renders"
}

main() {
  build_fixture

  smoke_run "fresh render: no preserved keys" \
    assert_fresh_render_has_no_user_keys
  smoke_run "operator-edited keys preserved across rerender" \
    assert_user_keys_preserved_on_rerender
  smoke_run "rerender is idempotent" \
    assert_idempotent
  smoke_run "Agent Bridge dev plugin settings rendered from launch command" \
    assert_agent_bridge_plugin_settings_rendered

  smoke_log "PASS"
}

main "$@"
