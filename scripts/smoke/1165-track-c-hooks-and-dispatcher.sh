#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1165-track-c-hooks-and-dispatcher.sh — Issue #1165 Track C
#
# Pins the contract closed by Track C of #1165 (Gaps 7 + 8) — the two
# "agent runtime UI" v2-isolation × Teams plugin gaps that surface as
# (a) PostToolUseFailure traceback flood from inside isolated Claude
# REPL and (b) markerless(existing-install) rejection when `agb` is
# invoked directly from the isolated UID.
#
# Tests:
#
#   T1 (Gap 7): hooks/bridge_hook_common.py::write_audit returns
#               cleanly (no raise, no stderr noise) when the calling
#               UID is a linux-user-isolated agent AND the audit-log
#               path is unwritable. PostToolUse hook would have raised
#               PermissionError on every tool call before the fix.
#   T2 (Gap 7): write_audit still RAISES on controller-side callers
#               (BRIDGE_AGENT_ISOLATION_MODE unset → no isolation).
#               Without this counter-test a future patch could silently
#               swallow controller-side write failures too.
#   T3 (Gap 8): agent-bridge dispatcher recovery block runs when
#               BRIDGE_CONTROLLER_UID is unset and exports the marker
#               file owner's UID. We can't simulate a real cross-UID
#               marker without sudo, so this test grep-asserts the
#               recovery block is present at the dispatcher head (the
#               static-source contract), plus a runtime probe of the
#               extracted block confirming the export fires when stat
#               is shimmed to return a different owner UID.
#   T4 (Gap 8): pre-set BRIDGE_CONTROLLER_UID survives the recovery
#               block (no overwrite). Mirrors the bridge-start.sh:613
#               sudo-wrapper contract — if the wrapper has already
#               set the var, the dispatcher must not stomp it.
#   T5 (Gap 8): markerless install (no layout-marker.sh) → recovery
#               block no-ops gracefully (no error, no spurious env
#               export). Legacy installs that don't have a marker
#               also don't enforce marker validation, so agb works
#               regardless.
#
# Host-agnostic: no sudo required. T3's runtime probe uses a tiny
# extracted-driver script that re-implements the recovery block with
# `bridge_marker_stat_uid` shimmed in shell — independent verification
# of the byte-for-byte logic the dispatcher inlines. The static-source
# grep in T3 closes the loop by ensuring the dispatcher still contains
# the production lines the probe mirrors. Footgun #11 (heredoc-stdin
# subprocess) is off the table — every driver is built with
# `printf '%s\n' >>file`.

set -uo pipefail

SMOKE_NAME="1165-track-c-hooks-and-dispatcher"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGB_FILE="$REPO_ROOT/agent-bridge"
HOOK_COMMON_FILE="$REPO_ROOT/hooks/bridge_hook_common.py"

smoke_assert_file_exists "$AGB_FILE" "agent-bridge dispatcher present"
smoke_assert_file_exists "$HOOK_COMMON_FILE" "hooks/bridge_hook_common.py present"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

PYTHON_BIN="${BRIDGE_PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 \
  || smoke_fail "python3 not found on PATH"

# ---------------------------------------------------------------------------
# Shared py-driver: import hooks/bridge_hook_common as a module and
# invoke write_audit with a controlled BRIDGE_AUDIT_LOG path. The test
# code is parameterized via env so the same driver covers T1 (iso UID,
# unwritable path → no raise) and T2 (controller UID, unwritable path
# → raise).
# ---------------------------------------------------------------------------
build_write_audit_driver() {
  local driver="$1"
  : >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  {
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' '"""Invoke bridge_hook_common.write_audit with a controlled config."""'
    printf '%s\n' 'from __future__ import annotations'
    printf '%s\n' 'import importlib.util'
    printf '%s\n' 'import os'
    printf '%s\n' 'import sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'def load_module(path: Path):'
    printf '%s\n' '    spec = importlib.util.spec_from_file_location("bridge_hook_common", str(path))'
    printf '%s\n' '    if spec is None or spec.loader is None:'
    printf '%s\n' '        raise RuntimeError("cannot load bridge_hook_common from " + str(path))'
    printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
    printf '%s\n' '    spec.loader.exec_module(module)'
    printf '%s\n' '    return module'
    printf '%s\n' ''
    printf '%s\n' 'def main() -> int:'
    printf '%s\n' '    common_path = Path(os.environ["DRIVER_HOOK_COMMON_PATH"])'
    printf '%s\n' '    module = load_module(common_path)'
    printf '%s\n' '    try:'
    printf '%s\n' '        module.write_audit("smoke_action", "smoke_target", {"k": "v"})'
    printf '%s\n' '    except Exception as exc:'
    printf '%s\n' '        print("RAISED:" + type(exc).__name__ + ":" + str(exc))'
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
# T1 — write_audit under iso UID returns cleanly when audit log path
# is unwritable.
# ---------------------------------------------------------------------------
smoke_log "T1: write_audit under iso UID + unwritable audit dir → no raise"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.py"
build_write_audit_driver "$T1_DRIVER"

# Make a directory we own then chmod it 0500 (read+execute only) so
# `mkdir` of a subdir AND `open(..., "a")` of any file inside both
# fail with PermissionError. This is the structural shape of the
# bug — controller-owned dir, iso UID can't write.
T1_ROOT="$SMOKE_TMP_ROOT/t1-audit-root"
mkdir -p "$T1_ROOT/locked"
chmod 0500 "$T1_ROOT/locked"
T1_AUDIT="$T1_ROOT/locked/subdir/audit.jsonl"

T1_OUT="$SMOKE_TMP_ROOT/t1-out.txt"
T1_ERR="$SMOKE_TMP_ROOT/t1-err.txt"
DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON_FILE" \
  BRIDGE_AUDIT_LOG="$T1_AUDIT" \
  BRIDGE_AGENT_ID="iso_smoke_agent" \
  BRIDGE_AGENT_ISOLATION_MODE="linux-user" \
  "$PYTHON_BIN" "$T1_DRIVER" >"$T1_OUT" 2>"$T1_ERR"
T1_RC=$?

if [[ $T1_RC -ne 0 ]]; then
  chmod 0700 "$T1_ROOT/locked" 2>/dev/null || true
  smoke_fail "T1: driver exited with rc=$T1_RC (expected 0). stdout: $(cat "$T1_OUT") stderr: $(cat "$T1_ERR")"
fi
T1_RESULT="$(cat "$T1_OUT" | tr -d '\n')"
if [[ "$T1_RESULT" != "CLEAN" ]]; then
  chmod 0700 "$T1_ROOT/locked" 2>/dev/null || true
  smoke_fail "T1: expected 'CLEAN' (write_audit returned without raise), got: '$T1_RESULT'. stderr: $(cat "$T1_ERR")"
fi
# Stderr must be empty — Claude's hook stderr is what floods the operator.
if [[ -s "$T1_ERR" ]]; then
  chmod 0700 "$T1_ROOT/locked" 2>/dev/null || true
  smoke_fail "T1: write_audit emitted unexpected stderr noise: $(cat "$T1_ERR")"
fi
# Restore mode so cleanup can rm -rf.
chmod 0700 "$T1_ROOT/locked" 2>/dev/null || true
smoke_log "T1 PASS: write_audit under iso UID + unwritable path → swallowed quietly"

# ---------------------------------------------------------------------------
# T2 — write_audit on controller side still RAISES on unwritable path.
# ---------------------------------------------------------------------------
smoke_log "T2: write_audit on controller (no iso mode) + unwritable path → RAISES"

T2_ROOT="$SMOKE_TMP_ROOT/t2-audit-root"
mkdir -p "$T2_ROOT/locked"
chmod 0500 "$T2_ROOT/locked"
T2_AUDIT="$T2_ROOT/locked/subdir/audit.jsonl"

T2_OUT="$SMOKE_TMP_ROOT/t2-out.txt"
T2_ERR="$SMOKE_TMP_ROOT/t2-err.txt"
# Note: BRIDGE_AGENT_ISOLATION_MODE intentionally unset → current_isolated_agent()
# returns None → the swallow branch must NOT fire. We re-use T1_DRIVER
# (same py-driver shape, captures any raise into the "RAISED:" prefix).
env -u BRIDGE_AGENT_ISOLATION_MODE \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON_FILE" \
  BRIDGE_AUDIT_LOG="$T2_AUDIT" \
  BRIDGE_AGENT_ID="controller_smoke_agent" \
  "$PYTHON_BIN" "$T1_DRIVER" >"$T2_OUT" 2>"$T2_ERR"
T2_RC=$?

chmod 0700 "$T2_ROOT/locked" 2>/dev/null || true
if [[ $T2_RC -ne 0 ]]; then
  smoke_fail "T2: driver exited with rc=$T2_RC (the driver itself should still exit 0 — it captures the exception). stdout: $(cat "$T2_OUT") stderr: $(cat "$T2_ERR")"
fi
T2_RESULT="$(cat "$T2_OUT" | tr -d '\n')"
case "$T2_RESULT" in
  RAISED:PermissionError:*|RAISED:OSError:*)
    smoke_log "T2 PASS: controller-side write_audit propagated $T2_RESULT (no silent-swallow regression)"
    ;;
  *)
    smoke_fail "T2: expected RAISED:PermissionError:* (controller path still raises), got: '$T2_RESULT'. stderr: $(cat "$T2_ERR")"
    ;;
esac

# ---------------------------------------------------------------------------
# T3 — agent-bridge dispatcher recovery block: BRIDGE_CONTROLLER_UID
# unset + marker owner != current UID → recovery exports the var.
# ---------------------------------------------------------------------------
smoke_log "T3: dispatcher recovery block exports BRIDGE_CONTROLLER_UID on cross-UID marker"

# Static-source assertion first: the recovery block must be present at
# the dispatcher head (BEFORE `source bridge-lib.sh`). Boomerang — if a
# future refactor lifts the recovery into bridge-lib.sh itself or drops
# it entirely, this assertion fires before the runtime probe.
T3_GREP_GUARD='if \[\[ -z "${BRIDGE_CONTROLLER_UID:-}" \]\]; then'
T3_GREP_EXPORT='export BRIDGE_CONTROLLER_UID="\$_bridge_recovery_owner"'
T3_GREP_MARKER='_bridge_recovery_marker="\${BRIDGE_LAYOUT_MARKER_DIR:-\$_bridge_recovery_home/state}/layout-marker.sh"'

grep -q "$T3_GREP_GUARD" "$AGB_FILE" \
  || smoke_fail "T3: agent-bridge dispatcher missing the recovery guard '$T3_GREP_GUARD'"
grep -q "$T3_GREP_EXPORT" "$AGB_FILE" \
  || smoke_fail "T3: agent-bridge dispatcher missing the recovery export '$T3_GREP_EXPORT'"
grep -q "$T3_GREP_MARKER" "$AGB_FILE" \
  || smoke_fail "T3: agent-bridge dispatcher missing the marker-path formula '$T3_GREP_MARKER'"

# Pre-source position assertion: the recovery block MUST appear before
# `source "$SCRIPT_DIR/bridge-lib.sh"` so it primes the env before
# bridge-marker-bootstrap.sh validates the marker. Use awk to find the
# line numbers and assert ordering.
T3_GUARD_LINE="$(grep -n "$T3_GREP_GUARD" "$AGB_FILE" | head -n 1 | cut -d: -f1)"
T3_SOURCE_LINE="$(grep -n 'source "$SCRIPT_DIR/bridge-lib.sh"' "$AGB_FILE" | head -n 1 | cut -d: -f1)"
if [[ -z "$T3_GUARD_LINE" || -z "$T3_SOURCE_LINE" ]]; then
  smoke_fail "T3: could not locate guard ($T3_GUARD_LINE) or bridge-lib source ($T3_SOURCE_LINE) line in dispatcher"
fi
if (( T3_GUARD_LINE >= T3_SOURCE_LINE )); then
  smoke_fail "T3: recovery guard at line $T3_GUARD_LINE must precede 'source bridge-lib.sh' at line $T3_SOURCE_LINE"
fi
smoke_log "T3 PASS[static]: recovery block at line $T3_GUARD_LINE precedes bridge-lib.sh source at line $T3_SOURCE_LINE"

# Runtime probe: build a tiny shell driver that mirrors the dispatcher's
# recovery block byte-for-byte (the lines the static asserts pin) and
# shims `stat` so it reports a different owner UID. Verifies the logic
# fires end-to-end without needing actual cross-UID privileges.
T3_HOME="$SMOKE_TMP_ROOT/t3-home"
mkdir -p "$T3_HOME/state"
T3_MARKER="$T3_HOME/state/layout-marker.sh"
{
  printf '%s\n' 'BRIDGE_LAYOUT=v2'
  printf '%s\n' "BRIDGE_DATA_ROOT=$T3_HOME/data"
} >>"$T3_MARKER"
chmod 0644 "$T3_MARKER"

T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
: >"$T3_DRIVER"
# Build a driver that:
#   - Honors caller-set BRIDGE_CONTROLLER_UID when arg3 == "preserve",
#     else unsets it (the default — covers T3/T5 fresh-state probes)
#   - Exports BRIDGE_HOME → arg1
#   - Shims `stat` to print arg2 as the marker owner UID
#   - Inlines the recovery block (exact code from agent-bridge head)
#   - Prints the final BRIDGE_CONTROLLER_UID value
# shellcheck disable=SC2129,SC1003  # SC2129: grouped block keeps footgun #11 off the table; SC1003: trailing backslash inside single-quoted printf args is intentional line continuation in the emitted bash, not an escape mistake
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'export BRIDGE_HOME="$1"'
  printf '%s\n' 'FAKE_OWNER_UID="$2"'
  printf '%s\n' 'PRESERVE_MODE="${3:-clear}"'
  printf '%s\n' 'if [[ "$PRESERVE_MODE" != "preserve" ]]; then'
  printf '%s\n' '  unset BRIDGE_CONTROLLER_UID'
  printf '%s\n' 'fi'
  # Shim stat: print a fixed UID so the recovery block sees owner != current.
  # The shim takes precedence over the system stat via PATH. We use a
  # function override which works for the recovery block's `stat` calls
  # because the recovery uses unqualified `stat ...` invocations.
  printf '%s\n' 'stat() {'
  printf '%s\n' '  # Mimic both BSD (-f %u) and GNU (-c %u) invocations.'
  printf '%s\n' '  local _flag="$1"; shift'
  printf '%s\n' '  local _fmt="$1"; shift'
  printf '%s\n' '  if [[ "$_flag" == "-f" || "$_flag" == "-c" ]]; then'
  printf '%s\n' '    case "$_fmt" in'
  printf '%s\n' '      "%u") printf "%s\\n" "$FAKE_OWNER_UID"; return 0 ;;'
  printf '%s\n' '    esac'
  printf '%s\n' '  fi'
  printf '%s\n' '  printf "stat-shim: unhandled args: %s %s %s\\n" "$_flag" "$_fmt" "$*" >&2'
  printf '%s\n' '  return 1'
  printf '%s\n' '}'
  printf '%s\n' 'export -f stat'
  # Inline the production recovery block — byte-identical to agent-bridge
  # head. T3 static-source asserts catch drift in the dispatcher; this
  # driver re-implements the same lines so we can exercise the runtime
  # behavior without sourcing bridge-lib.sh's transitive deps.
  printf '%s\n' 'if [[ -z "${BRIDGE_CONTROLLER_UID:-}" ]]; then'
  printf '%s\n' '  _bridge_recovery_home="${BRIDGE_HOME:-$HOME/.agent-bridge}"'
  printf '%s\n' '  _bridge_recovery_marker="${BRIDGE_LAYOUT_MARKER_DIR:-$_bridge_recovery_home/state}/layout-marker.sh"'
  printf '%s\n' '  if [[ -f "$_bridge_recovery_marker" ]]; then'
  printf '%s\n' '    _bridge_recovery_owner=""'
  printf '%s\n' '    if [[ "$(uname)" == "Darwin" ]]; then'
  printf '%s\n' '      _bridge_recovery_owner="$(stat -f "%u" "$_bridge_recovery_marker" 2>/dev/null || true)"'
  printf '%s\n' '    else'
  printf '%s\n' '      _bridge_recovery_owner="$(stat -c "%u" "$_bridge_recovery_marker" 2>/dev/null || true)"'
  printf '%s\n' '    fi'
  printf '%s\n' '    _bridge_recovery_current="$(id -u 2>/dev/null || true)"'
  printf '%s\n' '    if [[ -n "$_bridge_recovery_owner" \'
  printf '%s\n' '        && -n "$_bridge_recovery_current" \'
  printf '%s\n' '        && "$_bridge_recovery_owner" != "$_bridge_recovery_current" ]]; then'
  printf '%s\n' '      export BRIDGE_CONTROLLER_UID="$_bridge_recovery_owner"'
  printf '%s\n' '    fi'
  printf '%s\n' '    unset _bridge_recovery_owner _bridge_recovery_current'
  printf '%s\n' '  fi'
  printf '%s\n' '  unset _bridge_recovery_home _bridge_recovery_marker'
  printf '%s\n' 'fi'
  printf '%s\n' 'printf "BRIDGE_CONTROLLER_UID=%s\\n" "${BRIDGE_CONTROLLER_UID:-<unset>}"'
} >>"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_RUNTIME_OUT="$(env -u BRIDGE_LAYOUT_MARKER_DIR -u BRIDGE_CONTROLLER_UID "$BRIDGE_BASH" "$T3_DRIVER" "$T3_HOME" "99999" 2>"$SMOKE_TMP_ROOT/t3-runtime-err")" \
  || smoke_fail "T3: runtime probe driver failed (rc=$?). out: $T3_RUNTIME_OUT err: $(cat "$SMOKE_TMP_ROOT/t3-runtime-err")"
if [[ "$T3_RUNTIME_OUT" != "BRIDGE_CONTROLLER_UID=99999" ]]; then
  smoke_fail "T3 runtime: expected 'BRIDGE_CONTROLLER_UID=99999' (recovery exported the marker-stat'd owner UID), got: '$T3_RUNTIME_OUT'. err: $(cat "$SMOKE_TMP_ROOT/t3-runtime-err")"
fi
smoke_log "T3 PASS[runtime]: recovery block exported BRIDGE_CONTROLLER_UID=99999 from cross-UID marker stat"

# ---------------------------------------------------------------------------
# T4 — pre-set BRIDGE_CONTROLLER_UID survives the recovery block.
# ---------------------------------------------------------------------------
smoke_log "T4: pre-set BRIDGE_CONTROLLER_UID is NOT overwritten by recovery"

T4_RUNTIME_OUT="$(env -u BRIDGE_LAYOUT_MARKER_DIR BRIDGE_CONTROLLER_UID=12345 "$BRIDGE_BASH" "$T3_DRIVER" "$T3_HOME" "99999" "preserve" 2>"$SMOKE_TMP_ROOT/t4-runtime-err")" \
  || smoke_fail "T4: runtime probe driver failed (rc=$?). out: $T4_RUNTIME_OUT err: $(cat "$SMOKE_TMP_ROOT/t4-runtime-err")"
if [[ "$T4_RUNTIME_OUT" != "BRIDGE_CONTROLLER_UID=12345" ]]; then
  smoke_fail "T4: expected pre-set 'BRIDGE_CONTROLLER_UID=12345' to survive recovery, got: '$T4_RUNTIME_OUT'. err: $(cat "$SMOKE_TMP_ROOT/t4-runtime-err")"
fi
smoke_log "T4 PASS: pre-set BRIDGE_CONTROLLER_UID=12345 survived the recovery block"

# ---------------------------------------------------------------------------
# T5 — markerless install: recovery block no-ops gracefully.
# ---------------------------------------------------------------------------
smoke_log "T5: markerless install (no layout-marker.sh) → recovery no-op, no error"

T5_HOME="$SMOKE_TMP_ROOT/t5-home"
mkdir -p "$T5_HOME/state"
# Deliberately do NOT create the marker file.
[[ -f "$T5_HOME/state/layout-marker.sh" ]] && smoke_fail "T5 fixture corrupt — marker should not exist"

T5_RUNTIME_OUT="$(env -u BRIDGE_LAYOUT_MARKER_DIR -u BRIDGE_CONTROLLER_UID "$BRIDGE_BASH" "$T3_DRIVER" "$T5_HOME" "99999" 2>"$SMOKE_TMP_ROOT/t5-runtime-err")" \
  || smoke_fail "T5: runtime probe driver failed on markerless install (rc=$?). out: $T5_RUNTIME_OUT err: $(cat "$SMOKE_TMP_ROOT/t5-runtime-err")"
if [[ "$T5_RUNTIME_OUT" != "BRIDGE_CONTROLLER_UID=<unset>" ]]; then
  smoke_fail "T5: expected BRIDGE_CONTROLLER_UID to remain unset on markerless install, got: '$T5_RUNTIME_OUT'. err: $(cat "$SMOKE_TMP_ROOT/t5-runtime-err")"
fi
# Stderr must also be clean — no spurious error from the missing marker.
if [[ -s "$SMOKE_TMP_ROOT/t5-runtime-err" ]]; then
  smoke_fail "T5: expected empty stderr on markerless install, got: $(cat "$SMOKE_TMP_ROOT/t5-runtime-err")"
fi
smoke_log "T5 PASS: markerless install → recovery block no-ops, BRIDGE_CONTROLLER_UID stays unset, no stderr"

smoke_log "all tests PASS (#1165 Track C — Gap 7 hook + Gap 8 dispatcher recovery)"
