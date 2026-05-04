#!/usr/bin/env bash
# scripts/smoke/managed-autocompact-window.sh — Issue #547 regression smoke.
#
# Covers `bridge-hooks.py render-shared-settings` resolution of the managed
# autoCompactWindow default:
#   - launch_cmd contains '[1m]' → 1_000_000 (Opus 4.7 1M-context line)
#   - launch_cmd lacks '[1m]'    → 400_000  (legacy / Opus 4.6 era)
#   - --launch-cmd omitted        → 400_000  (back-compat with pre-#547 callers)

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

  smoke_log "case: launch_cmd contains '[1m]' → 1_000_000"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude --model claude-opus-4-7[1m]"
  assert_window "$effective" "1000000" "1m launch_cmd raises managed default"

  smoke_log "case: launch_cmd lacks '[1m]' → 400_000"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude --model claude-opus-4-7"
  assert_window "$effective" "400000" "non-1m launch_cmd preserves legacy default"

  smoke_log "case: empty --launch-cmd → 400_000 (back-compat for unspecified)"
  run_render "$base" "$overlay" "$effective" --launch-cmd ""
  assert_window "$effective" "400000" "empty launch_cmd falls through to legacy default"

  smoke_log "case: --launch-cmd omitted entirely → 400_000 (back-compat for pre-#547 callers)"
  run_render "$base" "$overlay" "$effective"
  assert_window "$effective" "400000" "omitted launch_cmd flag preserves legacy default"

  smoke_log "case: base autoCompactWindow wins over managed default even on [1m]"
  printf '%s\n' '{"autoCompactWindow":650000}' >"$base"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude [1m]"
  assert_window "$effective" "650000" "explicit base value overrides managed default"
  rm -f "$base"

  smoke_log "case: overlay autoCompactWindow wins over managed default on [1m]"
  printf '%s\n' '{"autoCompactWindow":475000}' >"$overlay"
  run_render "$base" "$overlay" "$effective" \
    --launch-cmd "claude [1m]"
  assert_window "$effective" "475000" "explicit overlay value overrides managed default"

  smoke_log "PASS: managed autoCompactWindow resolver matrix (#547)"
}

main "$@"
