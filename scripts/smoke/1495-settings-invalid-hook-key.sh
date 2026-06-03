#!/usr/bin/env bash
# scripts/smoke/1495-settings-invalid-hook-key.sh — Issue #1495 smoke.
#
# Claude Code (v2.1.87) rejects the ENTIRE settings.json — every key,
# including enabledPlugins / skipDangerousModePermissionPrompt — when the
# `hooks` record carries an event name it does not recognize
# ("PermissionDenied: Invalid key in record"). The legacy
# `PermissionDenied` block shipped by the tracked base
# agents/.claude/settings.json (commit 83c03c28, #93) was exactly such a
# key, and `bridge-hooks.py merge_settings` PRESERVES existing keys, so a
# once-dirty settings.json kept the broken key across every rerender.
#
# This smoke pins the #1495 fix from BOTH directions:
#
#   FRESH-INSTALL — a freshly rendered effective file (from the now-fixed
#   base) carries NO PermissionDenied / no non-allowlisted hook event, is
#   valid JSON, and still has the valid bridge hook suite.
#
#   EXISTING-DIRTY — seed an effective settings.json that already carries
#   PermissionDenied (plus valid user keys + valid hook events), run the
#   render, and assert the invalid event is stripped while every valid
#   key (enabledPlugins, skipDangerousModePermissionPrompt, Stop,
#   PreToolUse, …) survives intact. TEETH: the seed is asserted to
#   contain PermissionDenied BEFORE the render, so reverting the prune in
#   bridge-hooks.py (`_prune_invalid_hook_keys`) makes the post-render
#   "removed" assertion fail.
#
#   STDOUT/STDERR — the render path keeps stdout pure (shell/JSON key=val
#   lines only); the drop `[warn]` goes to stderr, never stdout.
#
# Coverage: the `bridge-hooks.py render-isolated-home-settings` +
# `render-shared-settings` Python renderers (the chokepoint every live
# agent's settings.effective.json flows through on start / restart /
# upgrade). Does NOT exercise the bash sudo stage→install→symlink dance
# (Linux-host-only, covered operator-side per OPERATIONS.md).

set -euo pipefail

SMOKE_NAME="1495-settings-invalid-hook-key"
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

  # Seed the shared base settings the renderer pulls in. Use a copy of
  # the REAL source so the fresh-install case catches a regression where
  # the tracked base reintroduces an invalid hook key.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"

  # Empty overlay (no per-agent overrides).
  : >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"
}

# Render into a fresh isolated home and return the effective file path
# via the $1-named global. Routes stderr to a caller-named file so the
# stdout/stderr separation can be asserted.
render_isolated() {
  local home_dir="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  mkdir -p "$home_dir/.claude"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$home_dir" \
    --base-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json" \
    --overlay-settings-file "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json" \
    --launch-cmd "" \
    --format shell \
    >"$stdout_file" 2>"$stderr_file"
}

# Assert a file parses as JSON and its `hooks` record carries only
# allowlisted Claude Code events. Fails (exit 1) otherwise.
#
# Uses `python3 -c` with file-as-argv (path + context) rather than a
# `python3 - <<'PY'` heredoc-stdin subprocess, so the smoke stays clear
# of the footgun-#11 heredoc-ban lint (scripts/lint-heredoc-ban.sh).
assert_valid_cc_settings() {
  local path="$1"
  local context="$2"
  python3 -c '
import json
import sys

path, context = sys.argv[1], sys.argv[2]
# MUST mirror bridge-hooks.py VALID_CLAUDE_HOOK_EVENTS — the complete set of
# bridge-managed hook events the prune keeps (incl. the bridge-wired
# PostToolUseFailure + the #8945 PostCompact/PermissionRequest/SubagentStart).
# PermissionDenied is intentionally absent (legacy, pruned).
valid = {
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit",
    "Notification", "Stop", "SubagentStart", "SubagentStop", "PreCompact",
    "PostCompact", "PermissionRequest", "SessionStart", "SessionEnd",
}
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)  # raises on malformed -> smoke fails loudly
hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    sys.stderr.write(context + ": hooks is not an object\n")
    sys.exit(1)
bad = sorted(k for k in hooks if k not in valid)
if bad:
    sys.stderr.write(context + ": invalid hook event(s) present: " + repr(bad) + "\n")
    sys.exit(1)
' "$path" "$context" || smoke_fail "$context: validator reported invalid Claude Code settings"
}

assert_fresh_install_clean() {
  local home_dir="$SMOKE_TMP_ROOT/fresh-home"
  local out="$SMOKE_TMP_ROOT/fresh.out"
  local err="$SMOKE_TMP_ROOT/fresh.err"
  render_isolated "$home_dir" "$out" "$err"

  local effective="$home_dir/.claude/settings.effective.json"
  smoke_assert_file_exists "$effective" \
    "fresh render produced settings.effective.json"

  local content
  content="$(cat "$effective")"
  smoke_assert_not_contains "$content" '"PermissionDenied"' \
    "fresh render carries NO PermissionDenied event (#1495)"
  smoke_assert_not_contains "$content" 'permission_escalation.py' \
    "fresh render does NOT wire the dead permission_escalation.py hook"
  # The valid bridge hook suite must still be present — the fix removes
  # only the invalid event, not the working hooks.
  smoke_assert_contains "$content" '"Stop"' \
    "fresh render keeps the Stop hook"
  smoke_assert_contains "$content" '"PreToolUse"' \
    "fresh render keeps the PreToolUse hook"
  smoke_assert_contains "$content" '"SessionStart"' \
    "fresh render keeps the SessionStart hook"

  assert_valid_cc_settings "$effective" \
    "fresh render is valid Claude Code settings"
}

assert_existing_dirty_repaired() {
  local home_dir="$SMOKE_TMP_ROOT/dirty-home"
  mkdir -p "$home_dir/.claude"

  # Mirror a live agent that was rendered BEFORE the #1495 fix:
  #   - its regular settings.json carries the valid preserved user keys
  #     (enabledPlugins / extraKnownMarketplaces / skipDangerous…), AND
  #   - an operator overlay (settings.local.json) carries the invalid
  #     PermissionDenied hook event. merge_settings folds the overlay
  #     into `merged`, so without _prune_invalid_hook_keys the rerendered
  #     effective file would STILL ship PermissionDenied — exactly the
  #     bug that makes Claude Code skip the whole file. The prune is what
  #     strips it; reverting the prune makes the post-render assertion
  #     below fail (TEETH on the fix, not just on the fixture).
  local seed="$home_dir/.claude/settings.json"
  cat >"$seed" <<'EOF'
{
  "autoMemoryEnabled": true,
  "enabledPlugins": ["channel-discord", "channel-teams"],
  "extraKnownMarketplaces": {"acme": {"source": "github:acme/marketplace"}},
  "skipDangerousModePermissionPrompt": true
}
EOF

  local dirty_bridge="$SMOKE_TMP_ROOT/dirty-bridge"
  mkdir -p "$dirty_bridge/agents/.claude"
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$dirty_bridge/agents/.claude/settings.json"
  # The overlay carries BOTH the invalid legacy event (PermissionDenied,
  # must be stripped) AND four genuinely bridge-wired events that the prune
  # MUST keep: PostToolUseFailure (wired by ensure-tool-policy-hooks at
  # start/upgrade, independent of the render path) plus the #8945 Codex-
  # coverage trio (PostCompact / PermissionRequest / SubagentStart). #1499
  # codex r1 caught that an incomplete allowlist pruned PostToolUseFailure
  # → the tool-policy failure hook silently vanished on isolated render.
  cat >"$dirty_bridge/agents/.claude/settings.local.json" <<'EOF'
{
  "hooks": {
    "PermissionDenied": [
      {"hooks": [{"type": "command", "command": "python3 ~/.agent-bridge/hooks/permission_escalation.py", "timeout": 10}]}
    ],
    "PostToolUseFailure": [
      {"hooks": [{"type": "command", "command": "python3 ~/.agent-bridge/hooks/tool-policy.py", "timeout": 10}]}
    ],
    "PostCompact": [
      {"hooks": [{"type": "command", "command": "python3 ~/.agent-bridge/hooks/pre-compact.py", "timeout": 10}]}
    ],
    "PermissionRequest": [
      {"hooks": [{"type": "command", "command": "python3 ~/.agent-bridge/hooks/tool-policy.py", "timeout": 10}]}
    ],
    "SubagentStart": [
      {"hooks": [{"type": "command", "command": "python3 ~/.agent-bridge/hooks/check-inbox.py", "timeout": 10}]}
    ]
  }
}
EOF

  # TEETH — prove the merged INPUT actually carries the invalid event
  # before the render. If a future refactor stops seeding it, the
  # post-render "removed" assertion would pass vacuously; this guards
  # against that.
  smoke_assert_contains "$(cat "$dirty_bridge/agents/.claude/settings.local.json")" \
    '"PermissionDenied"' \
    "TEETH: overlay input starts WITH PermissionDenied"

  local out="$SMOKE_TMP_ROOT/dirty.out"
  local err="$SMOKE_TMP_ROOT/dirty.err"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$home_dir" \
    --base-settings-file "$dirty_bridge/agents/.claude/settings.json" \
    --overlay-settings-file "$dirty_bridge/agents/.claude/settings.local.json" \
    --launch-cmd "" \
    --format shell \
    >"$out" 2>"$err"

  local effective="$home_dir/.claude/settings.effective.json"
  smoke_assert_file_exists "$effective" \
    "dirty render produced settings.effective.json"

  local content
  content="$(cat "$effective")"
  # The invalid event is stripped on render — this is the core repair
  # (preserve-merge alone would keep the overlay's key). Reverting
  # _prune_invalid_hook_keys makes THIS assertion fail.
  smoke_assert_not_contains "$content" '"PermissionDenied"' \
    "dirty render STRIPS PermissionDenied (#1495 repair via prune)"
  smoke_assert_not_contains "$content" 'permission_escalation.py' \
    "dirty render strips the dead permission_escalation.py wiring"

  # Every valid key survives — the prune must not over-reach. The
  # preserved user keys flow through PRESERVED_USER_KEYS; the valid hook
  # events flow through the base.
  smoke_assert_contains "$content" '"enabledPlugins"' \
    "dirty render PRESERVES enabledPlugins"
  smoke_assert_contains "$content" 'channel-discord' \
    "dirty render preserves enabledPlugins value"
  smoke_assert_contains "$content" '"extraKnownMarketplaces"' \
    "dirty render preserves extraKnownMarketplaces"
  smoke_assert_contains "$content" '"skipDangerousModePermissionPrompt"' \
    "dirty render preserves skipDangerousModePermissionPrompt"
  smoke_assert_contains "$content" '"Stop"' \
    "dirty render preserves the valid Stop hook event"
  smoke_assert_contains "$content" '"PreToolUse"' \
    "dirty render preserves the base PreToolUse hook event"

  # #1499 codex r1 regression guard: the prune must NOT drop a bridge-owned
  # hook event. These four are wired by the bridge itself (PostToolUseFailure
  # via ensure-tool-policy-hooks; PostCompact/PermissionRequest/SubagentStart
  # via #8945 Codex coverage) and are all valid CC events, so they MUST
  # survive the prune. Reverting the allowlist to its r1 (9-event) form makes
  # these four assertions fail — the exact bug codex caught.
  smoke_assert_contains "$content" '"PostToolUseFailure"' \
    "dirty render PRESERVES the bridge-wired PostToolUseFailure hook (#1499 r1)"
  smoke_assert_contains "$content" '"PostCompact"' \
    "dirty render preserves the #8945 PostCompact hook event"
  smoke_assert_contains "$content" '"PermissionRequest"' \
    "dirty render preserves the #8945 PermissionRequest hook event"
  smoke_assert_contains "$content" '"SubagentStart"' \
    "dirty render preserves the #8945 SubagentStart hook event"

  assert_valid_cc_settings "$effective" \
    "dirty render is valid Claude Code settings after repair"
}

assert_stdout_pure_stderr_warns() {
  # Drive the prune through a MERGED input so the warn genuinely fires.
  # An invalid hook event can reach the merged payload from the tracked
  # base (a regression) OR an operator overlay (settings.local.json).
  # Seed the overlay with PermissionDenied; the renderer merges it into
  # `merged`, the prune strips it, and the `[warn]` lands on stderr.
  local home_dir="$SMOKE_TMP_ROOT/stream-home"
  mkdir -p "$home_dir/.claude"

  # Per-render bridge home with a dirty overlay (leaves the shared
  # build_fixture base/overlay untouched for the other sub-tests).
  local dirty_bridge="$SMOKE_TMP_ROOT/stream-bridge"
  mkdir -p "$dirty_bridge/agents/.claude"
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$dirty_bridge/agents/.claude/settings.json"
  cat >"$dirty_bridge/agents/.claude/settings.local.json" <<'EOF'
{
  "hooks": {
    "PermissionDenied": [
      {"hooks": [{"type": "command", "command": "echo dead"}]}
    ]
  }
}
EOF

  local out="$SMOKE_TMP_ROOT/stream.out"
  local err="$SMOKE_TMP_ROOT/stream.err"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-isolated-home-settings \
    --isolated-home "$home_dir" \
    --base-settings-file "$dirty_bridge/agents/.claude/settings.json" \
    --overlay-settings-file "$dirty_bridge/agents/.claude/settings.local.json" \
    --launch-cmd "" \
    --format shell \
    >"$out" 2>"$err"

  # The merged-in invalid event must be stripped from the written file.
  local effective="$home_dir/.claude/settings.effective.json"
  smoke_assert_file_exists "$effective" \
    "stream render produced settings.effective.json"
  smoke_assert_not_contains "$(cat "$effective")" '"PermissionDenied"' \
    "overlay-sourced PermissionDenied stripped on render (#1495 prune)"

  local stdout_content stderr_content
  stdout_content="$(cat "$out")"
  stderr_content="$(cat "$err")"

  # The drop warning must be on stderr only — the --json/--format shell
  # render paths MUST keep stdout machine-parseable.
  smoke_assert_contains "$stderr_content" '[warn]' \
    "drop warning is emitted to stderr"
  smoke_assert_contains "$stderr_content" 'PermissionDenied' \
    "stderr warning names the dropped event"
  smoke_assert_not_contains "$stdout_content" '[warn]' \
    "stdout carries NO warning text (stays pure)"
  smoke_assert_not_contains "$stdout_content" 'invalid Claude Code hook' \
    "stdout carries no warning prose (stays pure)"

  # stdout must be the shell key=val payload (machine-parseable). The
  # effective-settings-file row is always present on this render path.
  smoke_assert_contains "$stdout_content" 'EFFECTIVE_SETTINGS_FILE=' \
    "stdout carries the shell-format render payload"
}

main() {
  build_fixture

  smoke_run "fresh render carries no invalid hook key" \
    assert_fresh_install_clean
  smoke_run "existing dirty settings repaired on render (with teeth)" \
    assert_existing_dirty_repaired
  smoke_run "drop warning on stderr, stdout stays pure" \
    assert_stdout_pure_stderr_warns

  smoke_log "PASS"
}

main "$@"
