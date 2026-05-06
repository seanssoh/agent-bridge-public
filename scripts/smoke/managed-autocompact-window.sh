#!/usr/bin/env bash
# scripts/smoke/managed-autocompact-window.sh — Issue #570 / #593 / #630 regression smoke.
#
# Covers `bridge-hooks.py render-shared-settings` resolution of the
# managed Claude Code defaults. Issue #593 made the autoCompactWindow
# resolver class-aware: static→400_000, dynamic→1_000_000,
# unknown/missing→1_000_000 (back-compat). Issue #630 added a
# promptSuggestionEnabled=false managed default so bridge-managed
# Claude agents render with the inline composer ghost text disabled
# (the daemon's SGR-2 dim detector misses newer Claude builds; the
# stable fix is to turn the feature off at the settings layer rather
# than chase ANSI shapes — see PR #566 history).
# The `--launch-cmd` flag is still accepted for backwards compatibility but
# is no longer consulted; the new `--agent-class` flag drives the decision.
#
# Cases covered:
#   - launch_cmd containing '[1m]', no --agent-class → 1_000_000 (unknown→1M)
#   - launch_cmd lacking '[1m]', no --agent-class    → 1_000_000 (unknown→1M)
#   - --launch-cmd empty / omitted                   → 1_000_000 (unknown→1M)
#   - --agent-class static                            → 400_000 (#593)
#   - --agent-class dynamic                           → 1_000_000 (#593)
#   - explicit base / overlay value                  → wins over managed default
#   - CLAUDE_CODE_AUTO_COMPACT_WINDOW                 → operator escape hatch (env
#     wins via Claude Code's resolution order; verified at the runtime layer,
#     not in this renderer-only smoke).
#   - promptSuggestionEnabled default false (#630)
#   - overlay re-enables promptSuggestionEnabled       (#630 operator opt-out)

set -euo pipefail

SMOKE_NAME="managed-autocompact-window"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

assert_window() {
  local effective_file="$1"
  local expected="$2"
  local context="$3"

  python3 - "$effective_file" "$expected" "$context" <<'PY'
import json
import sys
from pathlib import Path

effective_file, expected, context = sys.argv[1:]
payload = json.loads(Path(effective_file).read_text(encoding="utf-8"))
actual = payload.get("autoCompactWindow")
if actual != int(expected):
    raise SystemExit(f"{context}: autoCompactWindow expected {expected}, got {actual!r}")
PY
}

# Issue #630: managed default disables Claude Code inline composer ghost
# text so the daemon's pending-input detector cannot mistake it for real
# typed input. Operator overlays still win.
assert_prompt_suggestion() {
  local effective_file="$1"
  local expected="$2"
  local context="$3"

  python3 - "$effective_file" "$expected" "$context" <<'PY'
import json
import sys
from pathlib import Path

effective_file, expected, context = sys.argv[1:]
payload = json.loads(Path(effective_file).read_text(encoding="utf-8"))
actual = payload.get("promptSuggestionEnabled")
expected_bool = {"true": True, "false": False}[expected.lower()]
if actual is not expected_bool:
    raise SystemExit(
        f"{context}: promptSuggestionEnabled expected {expected_bool}, got {actual!r}"
    )
PY
}

run_render() {
  local base="$1"
  local overlay="$2"
  local effective="$3"
  shift 3
  rm -f "$effective"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$effective" \
    "$@" >/dev/null
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  local case_dir base overlay effective
  case_dir="$SMOKE_TMP_ROOT/render-cases"
  mkdir -p "$case_dir"
  base="$case_dir/settings.json"
  overlay="$case_dir/settings.local.json"
  effective="$case_dir/settings.effective.json"

  rm -f "$base" "$overlay"

  smoke_log "case: launch_cmd contains '[1m]' → 1_000_000 (managed default)"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude --model claude-opus-4-7[1m]"
  assert_window "$effective" "1000000" "[1m] launch_cmd lands on managed 1M default"

  smoke_log "case: launch_cmd lacks '[1m]' → 1_000_000 (managed default, #570 unconditional)"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude --model claude-opus-4-7"
  assert_window "$effective" "1000000" "non-[1m] launch_cmd lands on managed 1M default"

  smoke_log "case: empty --launch-cmd → 1_000_000 (managed default, launch_cmd not consulted)"
  run_render "$base" "$overlay" "$effective" --launch-cmd ""
  assert_window "$effective" "1000000" "empty launch_cmd lands on managed 1M default"

  smoke_log "case: --launch-cmd omitted entirely → 1_000_000 (back-compat path, managed default)"
  run_render "$base" "$overlay" "$effective"
  assert_window "$effective" "1000000" "omitted launch_cmd flag lands on managed 1M default"

  smoke_log "case: --agent-class static → 400_000 (#593 class-aware default)"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "" --agent-class "static"
  assert_window "$effective" "400000" "static class lands on 400_000 (#593)"

  smoke_log "case: --agent-class dynamic → 1_000_000 (#593 class-aware default)"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "" --agent-class "dynamic"
  assert_window "$effective" "1000000" "dynamic class lands on 1_000_000 (#593)"

  smoke_log "case: base autoCompactWindow wins over managed default"
  printf '%s\n' '{"autoCompactWindow":650000}' >"$base"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude [1m]"
  assert_window "$effective" "650000" "explicit base value overrides managed default"
  rm -f "$base"

  smoke_log "case: overlay autoCompactWindow wins over managed default"
  printf '%s\n' '{"autoCompactWindow":475000}' >"$overlay"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude [1m]"
  assert_window "$effective" "475000" "explicit overlay value overrides managed default"

  # Issue #630 — promptSuggestionEnabled managed default.
  rm -f "$base" "$overlay"

  smoke_log "case: promptSuggestionEnabled defaults to false (#630 ghost-text disable)"
  run_render "$base" "$overlay" "$effective" --launch-cmd ""
  assert_prompt_suggestion "$effective" "false" \
    "managed default disables inline composer ghost text"

  smoke_log "case: overlay can re-enable promptSuggestionEnabled (#630 operator opt-out path)"
  printf '%s\n' '{"promptSuggestionEnabled":true}' >"$overlay"
  run_render "$base" "$overlay" "$effective" --launch-cmd ""
  assert_prompt_suggestion "$effective" "true" \
    "operator overlay re-enables ghost text"
  rm -f "$overlay"

  smoke_log "PASS: managed autoCompactWindow resolver matrix (#570 / #593) + promptSuggestionEnabled (#630)"
}

main "$@"
