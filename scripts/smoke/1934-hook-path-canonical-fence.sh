#!/usr/bin/env bash
# scripts/smoke/1934-hook-path-canonical-fence.sh — Issue #1934 facet 1 smoke.
#
# A settings render run with a TRANSIENT / test BRIDGE_HOME (an acceptance
# root like `/tmp/agb-iso-test-<token>`) used to compute hook COMMAND paths as
# `$BRIDGE_HOME/hooks/<hook>` and persist those /tmp paths into LIVE agent
# `settings.effective.json` (and the `_template` scaffold). When the OS reaped
# /tmp the hook files vanished and every agent went fail-closed-deaf
# (UserPromptSubmit) + tool-deadlocked (PreToolUse `*`) with no self-recovery —
# this bricked a production farm.
#
# The fix routes every hook-command path through `_stable_hooks_dir`
# (bridge-hooks.py): when `<bridge_home>/hooks` is transient AND a canonical
# install hooks dir (`~/.agent-bridge/hooks`) EXISTS, the renderer writes the
# canonical (reaping-survivable) path instead — ALWAYS, even if the transient
# tree is populated at render time. Only when there is NO canonical install does
# a (self-contained) transient render keep its own path.
#
# This smoke controls the canonical install via $HOME so each branch is exercised
# deterministically and hermetically (no dependency on the host's real
# ~/.agent-bridge):
#
#   FENCE (canonical present) — render with a transient BRIDGE_HOME while HOME
#   points at a temp home that DOES contain `.agent-bridge/hooks`. The rendered
#   effective file must NOT contain the transient `<transient>/hooks/` path; it
#   must resolve to that canonical hooks dir.
#
#   KEEP (no canonical) — render with a transient BRIDGE_HOME while HOME points
#   at a temp home with NO `.agent-bridge/hooks`. With nothing reaping-survivable
#   to fence to, the renderer keeps the transient bridge_home's own hooks path
#   (a self-contained render that pollutes no live/canonical home).
#
# Coverage: `bridge-hooks.py render-shared-settings` -> `_normalize_bridge_hook_
# paths` -> `_stable_hooks_dir`.

set -euo pipefail

SMOKE_NAME="1934-hook-path-canonical-fence"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Render a shared effective file under a chosen bridge_home + HOME, echo content.
# $1 = bridge_home (with agents/.claude seeded); $2 = HOME for the render.
render_shared_effective() {
  local bridge_home="$1" home="$2"
  HOME="$home" python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$bridge_home/agents/.claude/settings.json" \
    --overlay-settings-file "$bridge_home/agents/.claude/settings.local.json" \
    --effective-settings-file "$bridge_home/agents/.claude/settings.effective.json" \
    --operator-global-settings-file "" \
    --launch-cmd "" >/dev/null
  cat "$bridge_home/agents/.claude/settings.effective.json"
}

seed_base() {
  local bridge_home="$1"
  mkdir -p "$bridge_home/agents/.claude"
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$bridge_home/agents/.claude/settings.json"
  # The shared renderer's load_json raises on a zero-byte overlay; "{}" is the
  # canonical "no overrides" signal.
  printf '{}\n' >"$bridge_home/agents/.claude/settings.local.json"
}

assert_transient_fenced_to_canonical() {
  smoke_make_temp_root "$SMOKE_NAME"
  # A transient acceptance root with NO populated hooks dir — the production
  # failure shape. $SMOKE_TMP_ROOT is itself a mktemp dir (/tmp or /var/folders),
  # so the resolved <bridge_home>/hooks is transient.
  local bh="$SMOKE_TMP_ROOT/agb-iso-test-token"
  seed_base "$bh"
  [[ -d "$bh/hooks" ]] && smoke_fail "fixture invalid: transient hooks dir should be absent"

  # A canonical install present under a controlled HOME.
  local home="$SMOKE_TMP_ROOT/canon-home"
  local canon="$home/.agent-bridge/hooks"
  mkdir -p "$canon"

  local content
  content="$(render_shared_effective "$bh" "$home")"

  smoke_assert_not_contains "$content" "$bh/hooks/" \
    "transient BRIDGE_HOME hook paths are NOT written into live settings (#1934)"
  smoke_assert_contains "$content" "$canon/tool-policy.py" \
    "transient hook paths fence to the canonical install hooks dir (#1934)"
  smoke_cleanup_temp_root
}

assert_transient_no_canonical_keeps_own() {
  smoke_make_temp_root "$SMOKE_NAME"
  # Same transient bridge_home, but HOME has NO canonical install — a genuinely
  # self-contained render with nothing reaping-survivable to fence to.
  local bh="$SMOKE_TMP_ROOT/self-contained"
  seed_base "$bh"
  local home="$SMOKE_TMP_ROOT/empty-home"
  mkdir -p "$home"
  [[ -d "$home/.agent-bridge/hooks" ]] && smoke_fail "fixture invalid: empty HOME must have no canonical install"

  local content
  content="$(render_shared_effective "$bh" "$home")"

  smoke_assert_contains "$content" "$bh/hooks/tool-policy.py" \
    "self-contained transient render keeps its OWN hooks dir when no canonical exists (#1934)"
  smoke_cleanup_temp_root
}

main() {
  smoke_run "transient BRIDGE_HOME is fenced to the canonical install hooks dir" \
    assert_transient_fenced_to_canonical
  smoke_run "transient render with no canonical install keeps its own hooks dir" \
    assert_transient_no_canonical_keeps_own

  smoke_log "PASS"
}

main "$@"
