#!/usr/bin/env bash
# scripts/smoke/beta27-E-hook-permission-fail-open-markers.sh — issue #1217 Track E.
#
# Pins the contract closed by beta27 Track E — two precompact marker
# writers (hooks/pre-compact.py::_write_started_marker and
# hooks/session_start.py::_write_compact_completed_marker) now wrap
# their write sequences in an iso-UID-gated try/except. Under iso v2
# the isolated UID cannot mkdir into the controller-owned
# state/precompact-events tree; before Track E the failure was
# swallowed by the outer generic `except Exception: pass` with no
# audit telemetry, so operators had no signal which marker writer
# fell open. Now:
#   - iso UID + PermissionError/OSError → write_audit() called with
#     `hook_permission_fail_open.<area>.<marker_kind>`, then return.
#   - controller + PermissionError/OSError → re-raise; the outer
#     generic except still swallows it so the exit-0 contract is
#     preserved (no observable behavior change for the controller path).
#
# Tests:
#   T1 (pre-compact, iso UID)         — under iso, mkdir of marker dir
#                                       raises PermissionError → no
#                                       traceback, audit event recorded.
#   T2 (pre-compact, controller)      — under controller, mkdir raises
#                                       → outer except still swallows;
#                                       NO audit event recorded (proves
#                                       the inner except re-raised).
#   T3 (session_start, iso UID)       — same iso pattern for completed
#                                       marker; audit event recorded.
#   T4 (session_start, controller)    — controller pattern, no audit.
#   T5 (sibling 1205 smoke)           — run scripts/smoke/1205-hook-iso-
#                                       fail-open.sh to confirm the
#                                       sibling pattern remains green.
#
# The "iso UID" predicate is gated on `_current_agent_under_foreign_uid`
# (UID-side check) inside hooks/bridge_hook_common.py:_under_isolated_uid.
# We simulate iso by setting BRIDGE_CONTROLLER_UID to a synthetic value
# different from the smoke runner's euid (same shape as 1205 smoke).
#
# Footgun #11: pipe/argv stdin only. Drivers written via `printf >>file`.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-beta27-E-smoke.XXXXXX")"
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  # Restore permissive perms so rm -rf can drain any chmod'd dirs.
  if [[ -d "$SMOKE_DIR" ]]; then
    find "$SMOKE_DIR" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  fi
  rm -rf "$SMOKE_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! command -v python3 >/dev/null 2>&1; then
  printf '[FAIL] python3 not on PATH\n' >&2
  exit 1
fi

HOOK_COMMON="$REPO_ROOT/hooks/bridge_hook_common.py"
PRECOMPACT_HOOK="$REPO_ROOT/hooks/pre-compact.py"
SESSION_START_HOOK="$REPO_ROOT/hooks/session_start.py"

for f in "$HOOK_COMMON" "$PRECOMPACT_HOOK" "$SESSION_START_HOOK"; do
  if [[ ! -f "$f" ]]; then
    printf '[FAIL] required hook file missing: %s\n' "$f" >&2
    exit 1
  fi
done

CURRENT_EUID="$(python3 -c 'import os; print(os.geteuid())')"
SYNTHETIC_NON_MATCH_UID="999999"
if [[ "$CURRENT_EUID" == "$SYNTHETIC_NON_MATCH_UID" ]]; then
  SYNTHETIC_NON_MATCH_UID="999998"
fi

ABSURD_TRACEBACK_GREP='Traceback (most recent call last)'

# ---------------------------------------------------------------------------
# Driver A — exercises hooks/pre-compact.py::_write_started_marker.
# Loads pre-compact as a module (dashed filename → importlib), points its
# `_state_dir()` at a controlled BRIDGE_HOME / BRIDGE_STATE_DIR tree, and
# chmods the precompact-events parent to 0555 so the mkdir fails under
# the smoke runner UID (matches the iso v2 contract).
# ---------------------------------------------------------------------------
build_driver_a() {
  local driver="$1"
  : >"$driver"
  # shellcheck disable=SC2129
  {
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' '"""Invoke pre-compact._write_started_marker under a controlled env."""'
    printf '%s\n' 'from __future__ import annotations'
    printf '%s\n' 'import importlib.util'
    printf '%s\n' 'import os'
    printf '%s\n' 'import sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'def load_module(name, path):'
    printf '%s\n' '    spec = importlib.util.spec_from_file_location(name, str(path))'
    printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
    printf '%s\n' '    sys.modules[name] = module'
    printf '%s\n' '    spec.loader.exec_module(module)'
    printf '%s\n' '    return module'
    printf '%s\n' ''
    printf '%s\n' 'def main() -> int:'
    printf '%s\n' '    hooks_dir = Path(os.environ["DRIVER_HOOKS_DIR"]).resolve()'  # noqa: iso-helper-boundary
    printf '%s\n' '    sys.path.insert(0, str(hooks_dir))'
    printf '%s\n' '    pc = load_module("pre_compact", hooks_dir / "pre-compact.py")'
    printf '%s\n' '    agent = os.environ.get("DRIVER_AGENT", "smoke_agent")'  # noqa: iso-helper-boundary
    printf '%s\n' '    try:'
    printf '%s\n' '        pc._write_started_marker(agent, {}, "manual")'
    printf '%s\n' '    except Exception as exc:'
    printf '%s\n' '        print("RAISED:" + type(exc).__name__ + ":" + str(exc)[:200])'
    printf '%s\n' '        return 0'
    printf '%s\n' '    print("CLEAN")'
    printf '%s\n' '    return 0'
    printf '%s\n' ''
    printf '%s\n' 'if __name__ == "__main__":'
    printf '%s\n' '    raise SystemExit(main())'
  } >>"$driver"
  chmod +x "$driver"
}

# ---------------------------------------------------------------------------
# Driver B — exercises hooks/session_start.py::_write_compact_completed_marker.
# Same shape as driver A but for session_start.
# ---------------------------------------------------------------------------
build_driver_b() {
  local driver="$1"
  : >"$driver"
  # shellcheck disable=SC2129
  {
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' '"""Invoke session_start._write_compact_completed_marker under a controlled env."""'
    printf '%s\n' 'from __future__ import annotations'
    printf '%s\n' 'import importlib.util'
    printf '%s\n' 'import os'
    printf '%s\n' 'import sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'def load_module(name, path):'
    printf '%s\n' '    spec = importlib.util.spec_from_file_location(name, str(path))'
    printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
    printf '%s\n' '    sys.modules[name] = module'
    printf '%s\n' '    spec.loader.exec_module(module)'
    printf '%s\n' '    return module'
    printf '%s\n' ''
    printf '%s\n' 'def main() -> int:'
    printf '%s\n' '    hooks_dir = Path(os.environ["DRIVER_HOOKS_DIR"]).resolve()'  # noqa: iso-helper-boundary
    printf '%s\n' '    sys.path.insert(0, str(hooks_dir))'
    printf '%s\n' '    ss = load_module("session_start_mod", hooks_dir / "session_start.py")'
    printf '%s\n' '    agent = os.environ.get("DRIVER_AGENT", "smoke_agent")'  # noqa: iso-helper-boundary
    printf '%s\n' '    try:'
    printf '%s\n' '        ss._write_compact_completed_marker(agent, "compact")'
    printf '%s\n' '    except Exception as exc:'
    printf '%s\n' '        print("RAISED:" + type(exc).__name__ + ":" + str(exc)[:200])'
    printf '%s\n' '        return 0'
    printf '%s\n' '    print("CLEAN")'
    printf '%s\n' '    return 0'
    printf '%s\n' ''
    printf '%s\n' 'if __name__ == "__main__":'
    printf '%s\n' '    raise SystemExit(main())'
  } >>"$driver"
  chmod +x "$driver"
}

DRIVER_A="$SMOKE_DIR/driver-a.py"
DRIVER_B="$SMOKE_DIR/driver-b.py"
build_driver_a "$DRIVER_A"
build_driver_b "$DRIVER_B"

# Setup a BRIDGE_HOME shape with a controller-owned precompact-events
# parent that the smoke can chmod to force the PermissionError.
# Each test gets its own subtree so chmods don't bleed.
prep_bridge_home() {
  local home="$1"
  local agent="$2"
  mkdir -p "$home/state/precompact-events"
  # chmod 0555 on the parent so any sub-mkdir (e.g. <agent>/started/) fails
  # for non-root callers — exactly the iso v2 failure mode where the
  # isolated UID hits a controller-owned tree.
  chmod 0555 "$home/state/precompact-events"
  # Pre-create the audit log dir so write_audit can land its event there
  # (audit_log_path() resolves to $BRIDGE_HOME/logs/agents/<agent>/audit.jsonl
  # when BRIDGE_AGENT_ID is set).
  mkdir -p "$home/logs/agents/$agent"
}

assert_no_traceback() {
  local label="$1"
  local err_file="$2"
  if grep -q "$ABSURD_TRACEBACK_GREP" "$err_file" 2>/dev/null; then
    _fail "$label" "stderr contained Traceback (operator UX still broken). stderr: $(cat "$err_file")"
    return 1
  fi
  return 0
}

audit_log_path_for() {
  local home="$1"
  local agent="$2"
  printf '%s\n' "$home/logs/agents/$agent/audit.jsonl"
}

audit_event_present() {
  local audit_file="$1"
  local event_name="$2"
  [[ -f "$audit_file" ]] || return 1
  grep -q "\"action\": \"$event_name\"" "$audit_file" 2>/dev/null
}

# ===========================================================================
# T1 — pre-compact, iso UID, mkdir fails → no traceback, audit recorded.
# ===========================================================================
T1_HOME="$SMOKE_DIR/t1-bridge-home"
T1_AGENT="iso_pc_agent"
prep_bridge_home "$T1_HOME" "$T1_AGENT"

T1_OUT="$SMOKE_DIR/t1-out.txt"
T1_ERR="$SMOKE_DIR/t1-err.txt"
DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_AGENT="$T1_AGENT" \
  BRIDGE_HOME="$T1_HOME" \
  BRIDGE_STATE_DIR="$T1_HOME/state" \
  BRIDGE_AGENT_ID="$T1_AGENT" \
  BRIDGE_CONTROLLER_UID="$SYNTHETIC_NON_MATCH_UID" \
  python3 "$DRIVER_A" >"$T1_OUT" 2>"$T1_ERR"
T1_RC=$?

chmod 0700 "$T1_HOME/state/precompact-events" 2>/dev/null || true
if [[ $T1_RC -ne 0 ]]; then
  _fail "T1" "driver exited with rc=$T1_RC. stdout: $(cat "$T1_OUT") stderr: $(cat "$T1_ERR")"
else
  T1_RESULT="$(cat "$T1_OUT" | tr -d '\n')"
  if [[ "$T1_RESULT" != "CLEAN" ]]; then
    _fail "T1" "expected 'CLEAN' (write swallowed cleanly), got: '$T1_RESULT'. stderr: $(cat "$T1_ERR")"
  elif ! assert_no_traceback "T1" "$T1_ERR"; then
    : # _fail already called
  else
    T1_AUDIT="$(audit_log_path_for "$T1_HOME" "$T1_AGENT")"
    if audit_event_present "$T1_AUDIT" "hook_permission_fail_open.precompact.started_marker"; then
      _pass "T1: pre-compact iso UID → CLEAN + audit event recorded"
    else
      _fail "T1" "audit event hook_permission_fail_open.precompact.started_marker NOT found in $T1_AUDIT"
    fi
  fi
fi

# ===========================================================================
# T2 — pre-compact, controller, mkdir fails → CLEAN (outer swallow), NO audit.
# ===========================================================================
T2_HOME="$SMOKE_DIR/t2-bridge-home"
T2_AGENT="ctrl_pc_agent"
prep_bridge_home "$T2_HOME" "$T2_AGENT"

T2_OUT="$SMOKE_DIR/t2-out.txt"
T2_ERR="$SMOKE_DIR/t2-err.txt"
env -u BRIDGE_AGENT_ISOLATION_MODE \
    -u BRIDGE_CONTROLLER_UID \
  DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_AGENT="$T2_AGENT" \
  BRIDGE_HOME="$T2_HOME" \
  BRIDGE_STATE_DIR="$T2_HOME/state" \
  BRIDGE_AGENT_ID="$T2_AGENT" \
  python3 "$DRIVER_A" >"$T2_OUT" 2>"$T2_ERR"
T2_RC=$?

chmod 0700 "$T2_HOME/state/precompact-events" 2>/dev/null || true
if [[ $T2_RC -ne 0 ]]; then
  _fail "T2" "driver exited with rc=$T2_RC. stdout: $(cat "$T2_OUT") stderr: $(cat "$T2_ERR")"
else
  T2_RESULT="$(cat "$T2_OUT" | tr -d '\n')"
  # Controller path: inner except re-raises → outer except Exception swallows
  # → driver sees CLEAN. Critically, no audit event must be emitted, proving
  # the iso branch was NOT taken.
  if [[ "$T2_RESULT" != "CLEAN" ]]; then
    _fail "T2" "expected 'CLEAN' (outer swallow preserves exit-0), got: '$T2_RESULT'. stderr: $(cat "$T2_ERR")"
  elif ! assert_no_traceback "T2" "$T2_ERR"; then
    : # _fail already called
  else
    T2_AUDIT="$(audit_log_path_for "$T2_HOME" "$T2_AGENT")"
    if audit_event_present "$T2_AUDIT" "hook_permission_fail_open.precompact.started_marker"; then
      _fail "T2" "controller path emitted iso audit event — inner except's iso gate is wrong (event found in $T2_AUDIT)"
    else
      _pass "T2: pre-compact controller → CLEAN (outer swallow) + NO audit (inner re-raised)"
    fi
  fi
fi

# ===========================================================================
# T3 — session_start, iso UID, mkdir fails → no traceback, audit recorded.
# ===========================================================================
T3_HOME="$SMOKE_DIR/t3-bridge-home"
T3_AGENT="iso_ss_agent"
prep_bridge_home "$T3_HOME" "$T3_AGENT"

T3_OUT="$SMOKE_DIR/t3-out.txt"
T3_ERR="$SMOKE_DIR/t3-err.txt"
DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_AGENT="$T3_AGENT" \
  BRIDGE_HOME="$T3_HOME" \
  BRIDGE_STATE_DIR="$T3_HOME/state" \
  BRIDGE_AGENT_ID="$T3_AGENT" \
  BRIDGE_CONTROLLER_UID="$SYNTHETIC_NON_MATCH_UID" \
  python3 "$DRIVER_B" >"$T3_OUT" 2>"$T3_ERR"
T3_RC=$?

chmod 0700 "$T3_HOME/state/precompact-events" 2>/dev/null || true
if [[ $T3_RC -ne 0 ]]; then
  _fail "T3" "driver exited with rc=$T3_RC. stdout: $(cat "$T3_OUT") stderr: $(cat "$T3_ERR")"
else
  T3_RESULT="$(cat "$T3_OUT" | tr -d '\n')"
  if [[ "$T3_RESULT" != "CLEAN" ]]; then
    _fail "T3" "expected 'CLEAN', got: '$T3_RESULT'. stderr: $(cat "$T3_ERR")"
  elif ! assert_no_traceback "T3" "$T3_ERR"; then
    : # _fail already called
  else
    T3_AUDIT="$(audit_log_path_for "$T3_HOME" "$T3_AGENT")"
    if audit_event_present "$T3_AUDIT" "hook_permission_fail_open.session_start.completed_marker"; then
      _pass "T3: session_start iso UID → CLEAN + audit event recorded"
    else
      _fail "T3" "audit event hook_permission_fail_open.session_start.completed_marker NOT found in $T3_AUDIT"
    fi
  fi
fi

# ===========================================================================
# T4 — session_start, controller, mkdir fails → CLEAN + NO audit.
# ===========================================================================
T4_HOME="$SMOKE_DIR/t4-bridge-home"
T4_AGENT="ctrl_ss_agent"
prep_bridge_home "$T4_HOME" "$T4_AGENT"

T4_OUT="$SMOKE_DIR/t4-out.txt"
T4_ERR="$SMOKE_DIR/t4-err.txt"
env -u BRIDGE_AGENT_ISOLATION_MODE \
    -u BRIDGE_CONTROLLER_UID \
  DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_AGENT="$T4_AGENT" \
  BRIDGE_HOME="$T4_HOME" \
  BRIDGE_STATE_DIR="$T4_HOME/state" \
  BRIDGE_AGENT_ID="$T4_AGENT" \
  python3 "$DRIVER_B" >"$T4_OUT" 2>"$T4_ERR"
T4_RC=$?

chmod 0700 "$T4_HOME/state/precompact-events" 2>/dev/null || true
if [[ $T4_RC -ne 0 ]]; then
  _fail "T4" "driver exited with rc=$T4_RC. stdout: $(cat "$T4_OUT") stderr: $(cat "$T4_ERR")"
else
  T4_RESULT="$(cat "$T4_OUT" | tr -d '\n')"
  if [[ "$T4_RESULT" != "CLEAN" ]]; then
    _fail "T4" "expected 'CLEAN' (outer swallow), got: '$T4_RESULT'. stderr: $(cat "$T4_ERR")"
  elif ! assert_no_traceback "T4" "$T4_ERR"; then
    : # _fail already called
  else
    T4_AUDIT="$(audit_log_path_for "$T4_HOME" "$T4_AGENT")"
    if audit_event_present "$T4_AUDIT" "hook_permission_fail_open.session_start.completed_marker"; then
      _fail "T4" "controller path emitted iso audit event (event found in $T4_AUDIT)"
    else
      _pass "T4: session_start controller → CLEAN (outer swallow) + NO audit"
    fi
  fi
fi

# ===========================================================================
# T5 — sibling pattern: 1205-hook-iso-fail-open.sh must still pass after
# Track E edits. Cheap-but-meaningful smoke linkage.
# ===========================================================================
SIBLING_SMOKE="$REPO_ROOT/scripts/smoke/1205-hook-iso-fail-open.sh"
if [[ -x "$SIBLING_SMOKE" ]]; then
  if "$SIBLING_SMOKE" >"$SMOKE_DIR/t5.out" 2>"$SMOKE_DIR/t5.err"; then
    _pass "T5: sibling 1205-hook-iso-fail-open.sh still PASS"
  else
    _fail "T5" "sibling 1205-hook-iso-fail-open.sh FAILED. stdout: $(cat "$SMOKE_DIR/t5.out") stderr: $(cat "$SMOKE_DIR/t5.err")"
  fi
else
  printf '[warn] T5 sibling smoke not executable; skipping\n'
fi

printf '[%s] %d/%d passed\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
