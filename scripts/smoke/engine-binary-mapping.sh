#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/engine-binary-mapping.sh — engine→binary mapping fix.
#
# `patch-agy` (engine=antigravity, binary=agy) was permanently skipped
# by the daemon's always-on autostart gate because bridge-daemon.sh
# probed `command -v antigravity` instead of the real binary name.
# fail_count ran from 10 to 94 in one day before the operator caught
# the watchdog escalation loop.
#
# The fix introduces `bridge_engine_binary_name()` in
# lib/bridge-engine-descriptor.sh and routes the daemon autostart gate
# through it. This smoke pins:
#
#   T1. bridge_engine_binary_name claude       → 'claude' (rc=0)
#   T2. bridge_engine_binary_name codex        → 'codex'  (rc=0)
#   T3. bridge_engine_binary_name antigravity  → 'agy'    (rc=0)
#   T4. bridge_engine_binary_name unknown      → ''       (rc=1)
#   T5. Integration: with a stub `agy` binary on PATH and the descriptor
#       loaded, the binary-name resolved for an `antigravity` engine
#       (`agy`) is visible to `command -v` and the daemon gate would
#       pass; with `agy` removed from PATH the gate would fail with
#       the actionable `engine-cli-missing:agy` reason.
#
# Isolation: temp working dir under /tmp; no live BRIDGE_HOME reads.

set -euo pipefail

SMOKE_NAME="engine-binary-mapping"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$SMOKE_REPO_ROOT"
DESCRIPTOR="$REPO_ROOT/lib/bridge-engine-descriptor.sh"
[[ -f "$DESCRIPTOR" ]] || smoke_fail "missing helper: $DESCRIPTOR"

smoke_make_temp_root "$SMOKE_NAME"

# Source the descriptor in an isolated subshell so the surrounding
# smoke harness env stays untouched. The descriptor is dependency-free
# — pure case-table accessors — so direct sourcing is safe.
#
# Each test invokes a fresh `bash -c` to ensure rc / stdout are not
# polluted by a stale function from the parent shell.

assert_binary_name() {
  local engine="$1"
  local expected_out="$2"
  local expected_rc="$3"
  local context="$4"
  local out
  local rc
  set +e
  out="$(bash -c "source '$DESCRIPTOR'; bridge_engine_binary_name '$engine'" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "$expected_out" "$out" "$context: stdout"
  smoke_assert_eq "$expected_rc" "$rc" "$context: rc"
}

# T1: claude → claude (rc=0)
smoke_run "T1 claude → claude" \
  assert_binary_name claude claude 0 "T1"

# T2: codex → codex (rc=0)
smoke_run "T2 codex → codex" \
  assert_binary_name codex codex 0 "T2"

# T3: antigravity → agy (rc=0) — the regression-fixing mapping.
smoke_run "T3 antigravity → agy" \
  assert_binary_name antigravity agy 0 "T3"

# T4: unknown engine → empty stdout, rc=1.
smoke_run "T4 unknown → rc=1" \
  assert_binary_name nonesuch '' 1 "T4"

# T5: integration — a stub `agy` on a controlled PATH is resolvable;
# removing it makes the gate fail with the actionable binary name. The
# guard exercised here mirrors the autostart-gate `command -v` probe in
# bridge-daemon.sh (after the engine→binary resolution).
STUB_DIR="$SMOKE_TMP_ROOT/path"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/agy" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/agy"

assert_gate_resolution() {
  local engine="$1"
  local expect_command_v_rc="$2"
  local expect_resolved_bin="$3"
  local path_value="$4"
  local context="$5"
  local payload rc
  set +e
  payload="$(PATH="$path_value" bash -c "
    source '$DESCRIPTOR'
    engine_bin=\"\$(bridge_engine_binary_name '$engine' 2>/dev/null || printf '%s' '$engine')\"
    printf 'resolved=%s\n' \"\$engine_bin\"
    if command -v \"\$engine_bin\" >/dev/null 2>&1; then
      printf 'cmdv=0\n'
    else
      printf 'cmdv=1\n'
    fi
  ")"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || smoke_fail "$context: subshell rc=$rc, payload=$payload"
  local resolved cmdv
  resolved="$(printf '%s\n' "$payload" | sed -n 's/^resolved=//p')"
  cmdv="$(printf '%s\n' "$payload" | sed -n 's/^cmdv=//p')"
  smoke_assert_eq "$expect_resolved_bin" "$resolved" "$context: resolved binary"
  smoke_assert_eq "$expect_command_v_rc" "$cmdv" "$context: command -v rc"
}

# T5a: with stub `agy` on PATH, the gate's `command -v` succeeds (rc=0).
smoke_run "T5a antigravity gate passes when agy on PATH" \
  assert_gate_resolution antigravity 0 agy "$STUB_DIR:/usr/bin:/bin" "T5a"

# T5b: with `agy` removed, the gate's `command -v` fails (rc=1) and the
# binary name in the audit reason is the real `agy`, not the engine
# token. We assert the resolved binary string to pin that the failure
# message will be `engine-cli-missing:agy` (the daemon site interpolates
# this value into the reason). PATH carries `/usr/bin:/bin` so the inner
# shell can still exec `bash` itself; only `agy` is absent.
SMOKE_EMPTY_BIN_DIR="$SMOKE_TMP_ROOT/path-no-agy"
mkdir -p "$SMOKE_EMPTY_BIN_DIR"
smoke_run "T5b antigravity gate fails with agy when agy absent from PATH" \
  assert_gate_resolution antigravity 1 agy "$SMOKE_EMPTY_BIN_DIR:/usr/bin:/bin" "T5b"

smoke_log "smoke test passed"
