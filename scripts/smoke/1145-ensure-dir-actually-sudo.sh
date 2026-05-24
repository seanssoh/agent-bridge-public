#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1145-ensure-dir-actually-sudo.sh — Issue #1145.
#
# Beta8 follow-up to #1139 (PR #1142). On a fresh v0.14.5-beta8 install
# (Linux, linux-user isolation) the `agent create <a> --engine claude
# --isolation linux-user` flow still emits stacked PermissionError
# tracebacks from `cmd_link_shared_settings → _ensure_dir_with_sudo`.
# PR #1142 only fixed owner *resolution* in `_isolated_workdir_owner`.
# The remaining failure shape on beta8:
#
#   * `_isolated_workdir_owner` correctly returns `agent-bridge-<a>`.
#   * `_ensure_dir_with_sudo` correctly attempts
#     `sudo -n -u agent-bridge-<a> mkdir -p <workdir>/.claude` FIRST.
#   * The mkdir under sudo fails because the per-agent root
#     `<v2-root>/<a>/` is `root:ab-agent-<a> 2750` — the iso UID is in
#     the group but mode 2750 denies group write, so creating
#     `workdir/` under it requires root (or a pre-scaffolded
#     `workdir/` mode 2770 owned by the iso UID).
#   * The fall-through controller-direct mkdir then also fails with
#     PermissionError. Pre-#1145 that bubbled up as a stacked
#     traceback and the wrapping `agent create` envelope lost the
#     rest of its work.
#
# Fix (this smoke pins the contract):
#   - `_ensure_dir_with_sudo` keeps the sudo-first contract from
#     #1120 (PR #1133): when an isolated owner is detected, sudo-as-
#     iso mkdir is the FIRST call; controller-direct mkdir is the
#     fallback ONLY on sudo failure (T1, T2).
#   - `cmd_link_shared_settings` wraps the per-agent ops in
#     `try/except OSError`, emits a structured single-line warning on
#     `PermissionError` (no traceback), surfaces
#     `HOOK_STATUS=permission_denied` in the payload, and returns 0
#     so the wrapping create flow continues — the proven #1119 /
#     PR #1124 watchdog pattern (T3).
#
# This smoke is HOST-AGNOSTIC: forces `sys.platform = "linux"` inside
# the Python harness; uses fixture trees + stubs for the sudo helper.
#
# Footgun #11 (heredoc_write deadlock class): every driver is built
# with `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash
# functions; no `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1145-ensure-dir-actually-sudo"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# ---------- T1 — _ensure_dir_with_sudo: sudo-as-iso is the FIRST call ----------
#
# When iso_user is detected, the sudo escalation must happen BEFORE
# any controller-direct mkdir. Stub `_sudo_run_as` to record every
# call and create the target dir on success; assert the first
# recorded call is the sudo mkdir as the iso user.
T1_HARNESS="$SMOKE_TMP_ROOT/probe-t1.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T1_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'import os, sys' >>"$T1_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T1_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])' >>"$T1_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T1_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T1_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T1_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T1_HARNESS"
printf '%s\n' 'call_log = sys.argv[2]' >>"$T1_HARNESS"
printf '%s\n' 'iso_user = sys.argv[3]' >>"$T1_HARNESS"
printf '%s\n' 'target = sys.argv[4]' >>"$T1_HARNESS"
printf '%s\n' '# Single ordered call log: every sudo invocation AND every controller-' >>"$T1_HARNESS"
printf '%s\n' '# direct Path.mkdir entry appends one line. T1 then asserts the first' >>"$T1_HARNESS"
printf '%s\n' '# entry is the sudo mkdir, NOT a bare Path.mkdir (the pre-#1120 shape).' >>"$T1_HARNESS"
printf '%s\n' 'import os as _os' >>"$T1_HARNESS"
printf '%s\n' 'def stub_mkdir(self, *args, **kwargs):' >>"$T1_HARNESS"
printf '%s\n' '    with open(call_log, "a") as f:' >>"$T1_HARNESS"
printf '%s\n' '        f.write("mkdir:" + str(self) + "\n")' >>"$T1_HARNESS"
printf '%s\n' '    # Use os.makedirs to honor parents=True without re-entering' >>"$T1_HARNESS"
printf '%s\n' '    # the stub via Path.mkdir`s recursive parents traversal.' >>"$T1_HARNESS"
printf '%s\n' '    _os.makedirs(str(self), exist_ok=kwargs.get("exist_ok", False))' >>"$T1_HARNESS"
printf '%s\n' 'Path.mkdir = stub_mkdir' >>"$T1_HARNESS"
printf '%s\n' 'def fake_sudo_run_as(os_user, *cmd):' >>"$T1_HARNESS"
printf '%s\n' '    with open(call_log, "a") as f:' >>"$T1_HARNESS"
printf '%s\n' '        f.write("sudo:" + repr((os_user,) + cmd) + "\n")' >>"$T1_HARNESS"
printf '%s\n' '    if cmd and cmd[0] == "mkdir":' >>"$T1_HARNESS"
printf '%s\n' '        _os.makedirs(cmd[-1], exist_ok=True)' >>"$T1_HARNESS"
printf '%s\n' '    return 0' >>"$T1_HARNESS"
printf '%s\n' 'mod._sudo_run_as = fake_sudo_run_as' >>"$T1_HARNESS"
# Phase 2 D7 lift: _ensure_dir_with_sudo delegates to bridge_iso_paths.ensure_dir,
# which calls sudo_run_as from its own module globals — patch both sites.
printf '%s\n' 'import importlib' >>"$T1_HARNESS"
printf '%s\n' 'iso_paths = importlib.import_module("bridge_iso_paths")' >>"$T1_HARNESS"
printf '%s\n' 'iso_paths.sudo_run_as = fake_sudo_run_as' >>"$T1_HARNESS"
printf '%s\n' 'mod._ensure_dir_with_sudo(Path(target), iso_user)' >>"$T1_HARNESS"
printf '%s\n' '# Print the FIRST recorded call (must be sudo: ..., never mkdir: ...).' >>"$T1_HARNESS"
printf '%s\n' 'with open(call_log) as f:' >>"$T1_HARNESS"
printf '%s\n' '    first = f.readline().rstrip()' >>"$T1_HARNESS"
printf '%s\n' 'print("first=" + first)' >>"$T1_HARNESS"

T1_LOG="$SMOKE_TMP_ROOT/t1.calls"
: >"$T1_LOG"
T1_TARGET="$SMOKE_TMP_ROOT/t1/agents/dev_mun/workdir/.claude"
T1_OUT="$("$PY_BIN" "$T1_HARNESS" "$REPO_ROOT" "$T1_LOG" "agent-bridge-dev_mun" "$T1_TARGET" 2>"$SMOKE_TMP_ROOT/t1.err")" \
  || smoke_fail "T1 harness rc=$? — see $SMOKE_TMP_ROOT/t1.err (output: $T1_OUT)"
case "$T1_OUT" in
  first=sudo:*) ;;
  *)
    smoke_fail "T1 first recorded call was not the sudo escalation — pre-#1120 bug shape: $T1_OUT"
    ;;
esac
T1_FIRST_CALL="$(head -n 1 "$T1_LOG" 2>/dev/null || printf '')"
[[ "$T1_FIRST_CALL" == *"'agent-bridge-dev_mun'"* ]] \
  || smoke_fail "T1 first sudo call missing iso user 'agent-bridge-dev_mun': $T1_FIRST_CALL"
[[ "$T1_FIRST_CALL" == *"'mkdir'"* ]] \
  || smoke_fail "T1 first sudo call missing 'mkdir' verb: $T1_FIRST_CALL"
# The sudo call must succeed and short-circuit — no controller mkdir
# should appear in the log at all.
if grep -q "^mkdir:" "$T1_LOG"; then
  smoke_fail "T1 controller Path.mkdir invoked despite sudo success: $(cat "$T1_LOG")"
fi
smoke_log "T1 PASS: _ensure_dir_with_sudo routes sudo-as-iso mkdir FIRST when iso_user is set"

# ---------- T2 — _ensure_dir_with_sudo: falls back to controller mkdir on sudo failure ----------
#
# When sudo is unavailable (rc != 0), the function must fall through
# to a controller-direct `path.mkdir(parents=True, exist_ok=True)`.
# Stub `_sudo_run_as` to return rc=127 (sudo missing) and let the
# real mkdir run against a controller-writable temp tree. The
# function must succeed (no exception) when the controller IS the
# parent dir's owner.
T2_HARNESS="$SMOKE_TMP_ROOT/probe-t2.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T2_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'import os, sys' >>"$T2_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T2_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])' >>"$T2_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T2_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T2_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T2_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T2_HARNESS"
printf '%s\n' 'iso_user = sys.argv[2]' >>"$T2_HARNESS"
printf '%s\n' 'target = sys.argv[3]' >>"$T2_HARNESS"
printf '%s\n' 'def fake_sudo_run_as(os_user, *cmd):' >>"$T2_HARNESS"
printf '%s\n' '    return 127  # sudo unavailable' >>"$T2_HARNESS"
printf '%s\n' 'mod._sudo_run_as = fake_sudo_run_as' >>"$T2_HARNESS"
# Phase 2 D7 lift: also patch bridge_iso_paths.sudo_run_as so the stub
# fires from the canonical helper. T2 needs rc=127 from both sites for
# the controller-direct fallback path to be exercised.
printf '%s\n' 'import importlib' >>"$T2_HARNESS"
printf '%s\n' 'iso_paths = importlib.import_module("bridge_iso_paths")' >>"$T2_HARNESS"
printf '%s\n' 'iso_paths.sudo_run_as = fake_sudo_run_as' >>"$T2_HARNESS"
printf '%s\n' 'mod._ensure_dir_with_sudo(Path(target), iso_user)' >>"$T2_HARNESS"
printf '%s\n' 'print("OK" if Path(target).is_dir() else "MISSING")' >>"$T2_HARNESS"

T2_TARGET="$SMOKE_TMP_ROOT/t2/agents/dev_mun/workdir/.claude"
T2_OUT="$("$PY_BIN" "$T2_HARNESS" "$REPO_ROOT" "agent-bridge-dev_mun" "$T2_TARGET" 2>"$SMOKE_TMP_ROOT/t2.err")" \
  || smoke_fail "T2 harness rc=$? — see $SMOKE_TMP_ROOT/t2.err (output: $T2_OUT)"
[[ "$T2_OUT" == "OK" ]] || smoke_fail "T2 expected 'OK' (controller mkdir succeeded after sudo failed), got '$T2_OUT'"
[[ -d "$T2_TARGET" ]] || smoke_fail "T2 target dir not created via controller fallback: $T2_TARGET"
smoke_log "T2 PASS: _ensure_dir_with_sudo falls back to controller-direct mkdir on sudo failure"

# ---------- T3 — cmd_link_shared_settings: PermissionError → graceful, no traceback ----------
#
# Pre-#1145: when `_ensure_dir_with_sudo` re-raises PermissionError
# (BOTH sudo-as-iso mkdir failed AND controller-direct mkdir failed),
# `cmd_link_shared_settings` let the exception bubble up as a Python
# traceback, breaking the wrapping `agent create` envelope.
# Post-#1145: the function catches OSError, emits a structured
# single-line warning to stderr (no traceback), surfaces
# `HOOK_STATUS=permission_denied`, and returns 0.
T3_HARNESS="$SMOKE_TMP_ROOT/probe-t3.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T3_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'import os, sys' >>"$T3_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T3_HARNESS"
printf '%s\n' 'import argparse' >>"$T3_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])' >>"$T3_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T3_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T3_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T3_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T3_HARNESS"
printf '%s\n' '# Stub _isolated_workdir_owner to return the iso user so the function' >>"$T3_HARNESS"
printf '%s\n' '# routes into the sudo-first path. _sudo_run_as returns rc=1 (sudo' >>"$T3_HARNESS"
printf '%s\n' '# escalates but mkdir under sudo failed — the #1145 shape).' >>"$T3_HARNESS"
printf '%s\n' 'mod._isolated_workdir_owner = lambda p: "agent-bridge-dev_mun"' >>"$T3_HARNESS"
printf '%s\n' 'mod._sudo_run_as = lambda os_user, *cmd: 1' >>"$T3_HARNESS"
printf '%s\n' '# Make controller-direct mkdir raise PermissionError too — the #1145' >>"$T3_HARNESS"
printf '%s\n' '# real-world shape where the per-agent root denies controller writes.' >>"$T3_HARNESS"
printf '%s\n' 'def stub_mkdir(self, *a, **kw):' >>"$T3_HARNESS"
printf '%s\n' '    raise PermissionError(13, "Permission denied", str(self))' >>"$T3_HARNESS"
printf '%s\n' 'Path.mkdir = stub_mkdir' >>"$T3_HARNESS"
printf '%s\n' 'args = argparse.Namespace(' >>"$T3_HARNESS"
printf '%s\n' '    workdir=sys.argv[2],' >>"$T3_HARNESS"
printf '%s\n' '    shared_settings_file=sys.argv[3],' >>"$T3_HARNESS"
printf '%s\n' '    format="text",' >>"$T3_HARNESS"
printf '%s\n' ')' >>"$T3_HARNESS"
printf '%s\n' 'rc = mod.cmd_link_shared_settings(args)' >>"$T3_HARNESS"
printf '%s\n' 'print("rc=" + str(rc))' >>"$T3_HARNESS"

T3_WORKDIR="$SMOKE_TMP_ROOT/t3/agents/dev_mun/workdir"
mkdir -p "$T3_WORKDIR"
T3_SHARED="$SMOKE_TMP_ROOT/t3/shared/settings.effective.json"
mkdir -p "$(dirname "$T3_SHARED")"
printf '{}\n' >"$T3_SHARED"

T3_OUT="$("$PY_BIN" "$T3_HARNESS" "$REPO_ROOT" "$T3_WORKDIR" "$T3_SHARED" 2>"$SMOKE_TMP_ROOT/t3.err")" \
  || smoke_fail "T3 harness rc=$? (expected 0 even on PermissionError) — see $SMOKE_TMP_ROOT/t3.err"
[[ "$T3_OUT" == *"rc=0"* ]] \
  || smoke_fail "T3 expected 'rc=0' (graceful exit on PermissionError), got: $T3_OUT"
[[ "$T3_OUT" == *"status: permission_denied"* ]] \
  || smoke_fail "T3 expected 'status: permission_denied' in stdout payload, got: $T3_OUT"
# Stderr must contain the structured one-line warning, NOT a Python traceback.
if grep -q "Traceback" "$SMOKE_TMP_ROOT/t3.err"; then
  smoke_fail "T3 stderr contains Python Traceback — graceful catch failed: $(cat "$SMOKE_TMP_ROOT/t3.err")"
fi
if ! grep -q "\[bridge-hooks\] link-shared-settings:" "$SMOKE_TMP_ROOT/t3.err"; then
  smoke_fail "T3 stderr missing structured warning prefix: $(cat "$SMOKE_TMP_ROOT/t3.err")"
fi
if ! grep -q "iso_user=agent-bridge-dev_mun" "$SMOKE_TMP_ROOT/t3.err"; then
  smoke_fail "T3 stderr missing iso_user context: $(cat "$SMOKE_TMP_ROOT/t3.err")"
fi
smoke_log "T3 PASS: cmd_link_shared_settings surfaces structured warning and returns 0 on PermissionError"

# ---------- T4 — cmd_link_shared_settings: regression — happy path still emits status=updated --
#
# When sudo + filesystem both succeed (non-isolated or pre-scaffolded
# workdir), the function must keep its pre-#1145 payload shape:
# `HOOK_STATUS=updated`, the symlink target line, etc.
T4_HARNESS="$SMOKE_TMP_ROOT/probe-t4.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T4_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'import os, sys, argparse' >>"$T4_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T4_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])' >>"$T4_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T4_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T4_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T4_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T4_HARNESS"
printf '%s\n' '# Non-isolated path: _isolated_workdir_owner returns None,' >>"$T4_HARNESS"
printf '%s\n' '# function uses controller-direct ops the whole way.' >>"$T4_HARNESS"
printf '%s\n' 'mod._isolated_workdir_owner = lambda p: None' >>"$T4_HARNESS"
printf '%s\n' 'args = argparse.Namespace(' >>"$T4_HARNESS"
printf '%s\n' '    workdir=sys.argv[2],' >>"$T4_HARNESS"
printf '%s\n' '    shared_settings_file=sys.argv[3],' >>"$T4_HARNESS"
printf '%s\n' '    format="text",' >>"$T4_HARNESS"
printf '%s\n' ')' >>"$T4_HARNESS"
printf '%s\n' 'rc = mod.cmd_link_shared_settings(args)' >>"$T4_HARNESS"
printf '%s\n' 'print("rc=" + str(rc))' >>"$T4_HARNESS"

T4_WORKDIR="$SMOKE_TMP_ROOT/t4/agents/dev_mun/workdir"
mkdir -p "$T4_WORKDIR"
T4_SHARED="$SMOKE_TMP_ROOT/t4/shared/settings.effective.json"
mkdir -p "$(dirname "$T4_SHARED")"
printf '{}\n' >"$T4_SHARED"

T4_OUT="$("$PY_BIN" "$T4_HARNESS" "$REPO_ROOT" "$T4_WORKDIR" "$T4_SHARED" 2>"$SMOKE_TMP_ROOT/t4.err")" \
  || smoke_fail "T4 harness rc=$? — see $SMOKE_TMP_ROOT/t4.err (output: $T4_OUT)"
[[ "$T4_OUT" == *"rc=0"* ]] \
  || smoke_fail "T4 expected 'rc=0' on happy path, got: $T4_OUT"
[[ "$T4_OUT" == *"status: updated"* ]] \
  || smoke_fail "T4 expected 'status: updated' (happy path), got: $T4_OUT"
[[ "$T4_OUT" != *"status: permission_denied"* ]] \
  || smoke_fail "T4 happy path emitted 'permission_denied' — regression!"
if grep -q "Traceback" "$SMOKE_TMP_ROOT/t4.err"; then
  smoke_fail "T4 happy path emitted a traceback: $(cat "$SMOKE_TMP_ROOT/t4.err")"
fi
smoke_log "T4 PASS: cmd_link_shared_settings happy path unchanged (status=updated, no warning, rc=0)"

smoke_log "all 4 tests PASS (#1145)"
