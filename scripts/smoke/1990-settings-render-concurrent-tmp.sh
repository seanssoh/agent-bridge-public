#!/usr/bin/env bash
# scripts/smoke/1990-settings-render-concurrent-tmp.sh — Issue #1990 regression smoke.
#
# Validates that concurrent `bridge-hooks.py render-shared-settings` writers
# against the SAME effective file never collide on a shared temp file —
# neither raising a `save_json` traceback nor publishing a truncated /
# partially-written effective file.
#
# Background (issue #1990): on cm-prod the daemon's plugin-MCP-liveness
# watchdog restarts a bot, and that restart re-renders the bot's
# `settings.effective.json`. When a manual reseed (or a sibling restart) of
# the same bot re-rendered the same file at the same instant, both render
# processes wrote through the SAME fixed `settings.effective.json.tmp` inode:
#   * one writer's `os.replace(tmp, effective)` renamed the shared tmp out
#     from under the other → `FileNotFoundError` inside `save_json`, which the
#     daemon logged as `plugin_mcp_liveness_restart_failed` (non-fatal,
#     self-healing on the next tick, but noisy and a real flap risk), and
#   * in the worse interleaving the second writer's `open("w")` truncated the
#     tmp the first writer was mid-dump on, so a partial/empty effective file
#     could be published (plugins/MCP off until the next render).
#
# The fix routes every settings writer (`save_json` + the isolated-home
# renderer) through a PER-WRITER unique temp file (`tempfile.mkstemp` in the
# destination directory), so concurrent renders never share a tmp inode while
# `os.replace` stays atomic.
#
# This smoke is mutation-proven: reverting the fix (a shared fixed `.tmp`
# name) makes the concurrent-render assertions flap/fail.
#
# Sub-tests:
#   1. N renderers launched concurrently against the same effective file,
#      repeated over many rounds: every render exits 0, no render emits a
#      Python traceback, and after every round the effective file is complete
#      valid JSON carrying a known managed key.

set -euo pipefail

SMOKE_NAME="1990-settings-render-concurrent-tmp"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Tunables — high enough that the OLD (shared-tmp) code reliably surfaces the
# collision, low enough to stay fast on CI.
ROUNDS="${SMOKE_1990_ROUNDS:-12}"
WRITERS="${SMOKE_1990_WRITERS:-6}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"

  FIXTURE_BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  mkdir -p "$FIXTURE_BRIDGE_HOME/agents/.claude"

  # Use the real shared base so the renderer exercises the production merge.
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"
  echo '{}' >"$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"

  BASE="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.json"
  OVERLAY="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.local.json"
  EFFECTIVE="$FIXTURE_BRIDGE_HOME/agents/.claude/settings.effective.json"

  STDERR_DIR="$SMOKE_TMP_ROOT/stderr"
  mkdir -p "$STDERR_DIR"
}

# Run one render to the shared effective file, capturing its stderr to a
# per-writer file and its exit code to a per-writer file.
render_once() {
  local idx="$1"
  local err_file="$STDERR_DIR/round-${idx}.err"
  local rc_file="$STDERR_DIR/round-${idx}.rc"
  local rc=0
  BRIDGE_HOME="$FIXTURE_BRIDGE_HOME" \
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
      --base-settings-file "$BASE" \
      --overlay-settings-file "$OVERLAY" \
      --effective-settings-file "$EFFECTIVE" \
      --launch-cmd "" \
      >/dev/null 2>"$err_file" || rc=$?
  printf '%s' "$rc" >"$rc_file"
}

assert_concurrent_render_never_collides() {
  local round writer pids rc err
  for (( round = 1; round <= ROUNDS; round++ )); do
    rm -f "$STDERR_DIR"/round-*.err "$STDERR_DIR"/round-*.rc

    pids=()
    for (( writer = 1; writer <= WRITERS; writer++ )); do
      render_once "$writer" &
      pids+=("$!")
    done
    # Wait for every concurrent writer in this round.
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done

    # Every render must have exited 0 (a collision raised SystemExit/traceback
    # → non-zero) and emitted no Python traceback.
    for (( writer = 1; writer <= WRITERS; writer++ )); do
      rc="$(cat "$STDERR_DIR/round-${writer}.rc" 2>/dev/null || printf '1')"
      smoke_assert_eq "$rc" "0" \
        "round ${round} writer ${writer}: render exited cleanly (no tmp collision)"
      err="$(cat "$STDERR_DIR/round-${writer}.err" 2>/dev/null || printf '')"
      smoke_assert_not_contains "$err" "Traceback (most recent call last)" \
        "round ${round} writer ${writer}: render emitted no Python traceback"
    done

    # After the round, the published effective file must be COMPLETE valid
    # JSON carrying a known managed key — never truncated/empty from a
    # mid-write tmp being os.replace'd into place.
    smoke_assert_file_exists "$EFFECTIVE" \
      "round ${round}: effective file present after concurrent renders"
    # The published effective file must parse as complete JSON AND carry a
    # managed key the renderer always emits ("hooks") — a truncated/partial
    # tmp os.replace'd into place would either fail to parse or miss the key.
    # Inline `python3 -c` (no heredoc — keeps the heredoc-stdin lint baseline
    # clean; the path is passed as argv).
    if ! SMOKE_1990_EFFECTIVE="$EFFECTIVE" python3 -c 'import json, os, sys; p = os.environ["SMOKE_1990_EFFECTIVE"]; d = json.load(open(p, encoding="utf-8")); sys.exit(0 if "hooks" in d else 1)'; then
      smoke_fail "round ${round}: effective file was not complete valid JSON (with managed 'hooks' key) after concurrent renders (truncation/partial-write race)"
    fi
  done
}

main() {
  build_fixture

  smoke_run "concurrent renders never collide on a shared temp file (#1990)" \
    assert_concurrent_render_never_collides

  smoke_log "PASS"
}

main "$@"
