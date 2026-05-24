#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1170-safe-path-check-sudo-escalate.sh — Issue #1170.
#
# bridge-setup.py `_safe_path_check` was a raw `path.exists()` wrapped in
# a reactive try/except: on PermissionError it would fall through to
# `sudo -n -u <os_user> test -e <path>`. That shape worked when the
# controller could at least lstat the parent dir; but under v2 isolation
# with `.teams/` mode 2750 owned by `agent-bridge-<a>:ab-agent-<a>` AND
# the controller NOT in `ab-agent-<a>`, `path.exists()` raises a
# PermissionError that bubbles to `_safe_read_env` and aborts the entire
# `setup teams|telegram|discord <agent>` flow with a traceback before
# the recovery prompt ever fires.
#
# The fix flips the shape: when `os_user` is provided, sudo-escalate
# FIRST (proactive), then fall through to the direct pathlib check only
# when sudo is unavailable (rc=127 / FileNotFoundError). The direct
# check itself wraps PermissionError with a fail-closed "absent" return
# so `_safe_read_env` skips the read instead of bubbling the traceback.
#
# r2 (#1170, codex review): the proactive sudo call goes through
# `subprocess.run(..., timeout=5)` directly instead of `_sudo_run_as`
# so we can (a) plumb a real timeout and (b) inspect stderr to
# distinguish a clean `test` rc=1 ("path absent" — authoritative) from
# a `sudo -n` policy/auth rc=1 ("sudo: a password is required" —
# underlying `test` never ran, fall through to direct pathlib). The r1
# shape conflated the two and could overwrite preserved `.env` state
# whenever sudo was installed-but-not-authorized.
#
# Coverage:
#   T1: os_user is None + path is controller-readable → direct pathlib
#       returns True. No sudo invoked.
#   T2: os_user is None + path is controller-readable + path absent →
#       direct pathlib returns False. No sudo invoked.
#   T3: os_user provided + sudo-stub says "exists" (rc=0) → returns
#       True. Direct pathlib NEVER consulted (proactive sudo wins).
#   T4: os_user provided + sudo-stub says "absent" (rc=1, empty stderr)
#       → returns False. Direct pathlib NEVER consulted.
#   T5: os_user provided + sudo unavailable (FileNotFoundError) + path
#       raises PermissionError on direct pathlib → fail-closed False
#       (NOT raise). #1170 acceptance.
#   T6: os_user is None + path raises PermissionError on direct
#       pathlib + walker also returns None → fail-closed False (NOT
#       raise). #1170 acceptance (controller blind + no recoverable
#       owner).
#   T6a: os_user is None + path raises PermissionError + walker
#        recovers owner → sudo escalate succeeds.
#   T7: `is_symlink` op still works under the same sudo-first shape
#       (parity with `exists`).
#   T8 (#1170 r2 acceptance): os_user provided + sudo-stub rc=1 with
#       stderr "sudo: a password is required" (policy failure, not test
#       result) + path is controller-readable → falls through to direct
#       pathlib and returns True. Regression contract: revert
#       stderr-discrimination → returns False prematurely.
#   T9 (#1170 r2): os_user provided + sudo-stub rc=1 with empty stderr
#       (clean test rc=1) + path raises PermissionError on direct
#       pathlib → returns False (authoritative — must NOT fall through
#       on a clean test failure).
#   T10 (#1170 r2 acceptance): os_user provided + sudo-stub raises
#        TimeoutExpired (stuck sudo/PAM/NSS lookup) + path is
#        controller-readable → falls through to direct pathlib and
#        returns True (NOT wedge). Regression contract: revert timeout
#        plumbing → harness wall-clock hangs past the 5s budget.
#
# Host-agnostic: every test stubs `subprocess.run` on the module (for
# the proactive sudo path) and `_sudo_run_as` (for the
# PermissionError-fallback path) and `_resolve_isolated_owner_for_path`
# directly. No real `agent-bridge-*` users, no actual sudo invocation.
# Works on Linux + macOS.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every harness
# is built with `printf '%s\n' >file` and run as `python3 <file>`; no
# `<<<` here-string or `<<EOF` feeds into a subprocess capture.

set -uo pipefail

SMOKE_NAME="1170-safe-path-check-sudo-escalate"
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

HARNESS="$SMOKE_TMP_ROOT/run.py"
: >"$HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Issue #1170 smoke: _safe_path_check sudo-escalates proactively + fail-closes."""'
  printf '%s\n' 'import sys, time, importlib.util, subprocess'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'tmp = Path(sys.argv[2])'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' 'mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(mod)'
  printf '%s\n' ''
  printf '%s\n' '# Counter of sudo invocations so each test can assert "consulted" / "not consulted".'
  printf '%s\n' 'class SudoStub:'
  printf '%s\n' '    def __init__(self, rc):'
  printf '%s\n' '        self.rc = rc'
  printf '%s\n' '        self.calls = []'
  printf '%s\n' '    def __call__(self, os_user, *cmd):'
  printf '%s\n' '        self.calls.append((os_user, cmd))'
  printf '%s\n' '        return subprocess.CompletedProcess(args=list(cmd), returncode=self.rc, stdout="", stderr="")'
  printf '%s\n' ''
  printf '%s\n' '# Subprocess.run stub used by the proactive sudo path in _safe_path_check'
  printf '%s\n' '# (r2 — direct subprocess.run with timeout=5, bypassing _sudo_run_as).'
  printf '%s\n' 'class SubprocessRunStub:'
  printf '%s\n' '    def __init__(self, rc=0, stderr="", raises=None):'
  printf '%s\n' '        self.rc = rc'
  printf '%s\n' '        self.stderr_text = stderr'
  printf '%s\n' '        self.raises = raises  # exception instance to raise, if any'
  printf '%s\n' '        self.calls = []  # list of (args, kwargs)'
  printf '%s\n' '    def __call__(self, *args, **kwargs):'
  printf '%s\n' '        self.calls.append((args, kwargs))'
  printf '%s\n' '        if self.raises is not None:'
  printf '%s\n' '            raise self.raises'
  printf '%s\n' '        return subprocess.CompletedProcess('
  printf '%s\n' '            args=args[0] if args else [],'
  printf '%s\n' '            returncode=self.rc,'
  printf '%s\n' '            stdout="",'
  printf '%s\n' '            stderr=self.stderr_text,'
  printf '%s\n' '        )'
  printf '%s\n' ''
  printf '%s\n' '# A pathlib.Path subclass whose .exists() / .is_symlink() raise PermissionError —'
  printf '%s\n' '# mirrors the controller-blind-to-isolated-leaf scenario without needing real UIDs.'
  printf '%s\n' 'class BlindPath(type(Path()))  : # type: ignore[misc]'
  printf '%s\n' '    def exists(self):'
  printf '%s\n' '        raise PermissionError(13, "Permission denied", str(self))'
  printf '%s\n' '    def is_symlink(self):'
  printf '%s\n' '        raise PermissionError(13, "Permission denied", str(self))'
  printf '%s\n' ''
  printf '%s\n' 'def reset_stubs(sudo_rc=None, walker_result=None, subproc_rc=0,'
  printf '%s\n' '                subproc_stderr="", subproc_raises=None):'
  printf '%s\n' '    """Reinstall stubs; return (sudo_stub, subproc_stub, walker_calls)."""'
  printf '%s\n' '    sudo = SudoStub(sudo_rc if sudo_rc is not None else 0)'
  printf '%s\n' '    mod._sudo_run_as = sudo'
  printf '%s\n' '    # Replace subprocess.run on the module-level `subprocess` reference so'
  printf '%s\n' '    # the proactive direct-subprocess.run path in _safe_path_check is captured.'
  printf '%s\n' '    subproc_stub = SubprocessRunStub(rc=subproc_rc, stderr=subproc_stderr, raises=subproc_raises)'
  printf '%s\n' '    mod.subprocess.run = subproc_stub'
  printf '%s\n' '    walker_calls = []'
  printf '%s\n' '    def walker(p):'
  printf '%s\n' '        walker_calls.append(p)'
  printf '%s\n' '        return walker_result'
  printf '%s\n' '    mod._resolve_isolated_owner_for_path = walker'
  printf '%s\n' '    return sudo, subproc_stub, walker_calls'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T1: os_user None, real path exists ----------'
  printf '%s\n' 'real = tmp / "t1-exists"'
  printf '%s\n' 'real.write_text("x")'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs()'
  printf '%s\n' 'rv = mod._safe_path_check("exists", real, None)'
  printf '%s\n' 'assert rv is True, "T1 expected True for real existing path with os_user=None, got " + repr(rv)'
  printf '%s\n' 'assert sudo.calls == [], "T1: _sudo_run_as MUST NOT be invoked when os_user is None and direct check works; got " + repr(sudo.calls)'
  printf '%s\n' 'assert subproc.calls == [], "T1: subprocess.run MUST NOT be invoked when os_user is None; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T1 PASS: os_user=None + readable path → direct pathlib True, no sudo")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T2: os_user None, real path absent ----------'
  printf '%s\n' 'absent = tmp / "t2-absent"'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs()'
  printf '%s\n' 'rv = mod._safe_path_check("exists", absent, None)'
  printf '%s\n' 'assert rv is False, "T2 expected False for absent path with os_user=None, got " + repr(rv)'
  printf '%s\n' 'assert sudo.calls == [], "T2: _sudo_run_as MUST NOT be invoked when os_user is None; got " + repr(sudo.calls)'
  printf '%s\n' 'assert subproc.calls == [], "T2: subprocess.run MUST NOT be invoked when os_user is None; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T2 PASS: os_user=None + absent path → direct pathlib False, no sudo")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T3: os_user provided + sudo says "exists" ----------'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(subproc_rc=0)'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t3-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("exists", blind, "agent-bridge-test")'
  printf '%s\n' 'assert rv is True, "T3 expected True from subproc-rc=0, got " + repr(rv)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T3: subprocess.run MUST be invoked exactly once when os_user provided; got " + repr(subproc.calls)'
  printf '%s\n' 'args_tuple, kwargs = subproc.calls[0]'
  printf '%s\n' 'argv = args_tuple[0]'
  printf '%s\n' 'assert argv == ["sudo", "-n", "-u", "agent-bridge-test", "test", "-e", str(blind)], "T3 sudo argv shape wrong: " + repr(argv)'
  printf '%s\n' 'assert kwargs.get("timeout") == 5, "T3: subprocess.run MUST be called with timeout=5; got kwargs=" + repr(kwargs)'
  printf '%s\n' 'assert sudo.calls == [], "T3: _sudo_run_as MUST NOT be invoked in proactive path (#1170 r2 uses subprocess.run directly); got " + repr(sudo.calls)'
  printf '%s\n' 'print("T3 PASS: os_user provided + subproc-rc=0 → True via proactive sudo (direct subprocess.run, timeout=5)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T4: os_user provided + sudo says "absent" (clean rc=1, empty stderr) ----------'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(subproc_rc=1, subproc_stderr="")'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t4-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("exists", blind, "agent-bridge-test")'
  printf '%s\n' 'assert rv is False, "T4 expected False from subproc-rc=1 (clean test rc=1), got " + repr(rv)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T4: subprocess.run MUST be invoked exactly once; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T4 PASS: os_user provided + clean subproc-rc=1 → False via proactive sudo (no pathlib fallthrough)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T5 (#1170 acceptance): os_user + sudo unavailable + blind path ----------'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(subproc_raises=FileNotFoundError("sudo not found"))'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t5-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("exists", blind, "agent-bridge-test")'
  printf '%s\n' 'assert rv is False, "T5 (#1170): expected fail-closed False when sudo unavailable + path blind, got " + repr(rv)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T5: proactive subprocess.run MUST be attempted first; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T5 PASS (#1170): sudo unavailable + blind path → fail-closed False (NOT raise)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T6 (#1170 acceptance): os_user None + blind path + walker empty ----------'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(walker_result=None)'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t6-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("exists", blind, None)'
  printf '%s\n' 'assert rv is False, "T6 (#1170): expected fail-closed False when walker also empty, got " + repr(rv)'
  printf '%s\n' 'assert len(walker_calls) == 1, "T6: walker MUST be consulted when initial os_user is None; got " + repr(walker_calls)'
  printf '%s\n' 'assert sudo.calls == [], "T6: _sudo_run_as MUST NOT be invoked when walker returns None; got " + repr(sudo.calls)'
  printf '%s\n' 'assert subproc.calls == [], "T6: subprocess.run MUST NOT be invoked in proactive path when os_user is None; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T6 PASS (#1170): os_user=None + blind path + walker empty → fail-closed False (NOT raise)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T6a: walker resolves owner → recovered via sudo (PermissionError-fallback path) ----------'
  printf '%s\n' '# This path still uses _sudo_run_as (only the proactive path was migrated to direct subprocess.run).'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(sudo_rc=0, walker_result="agent-bridge-walker")'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t6a-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("exists", blind, None)'
  printf '%s\n' 'assert rv is True, "T6a expected True via walker → sudo recovery, got " + repr(rv)'
  printf '%s\n' 'assert len(walker_calls) == 1, "T6a: walker consulted exactly once; got " + repr(walker_calls)'
  printf '%s\n' 'assert len(sudo.calls) == 1, "T6a: _sudo_run_as invoked once after walker resolved; got " + repr(sudo.calls)'
  printf '%s\n' 'assert sudo.calls[0][0] == "agent-bridge-walker", "T6a sudo invoked with wrong os_user: " + repr(sudo.calls[0])'
  printf '%s\n' 'print("T6a PASS: os_user=None + blind path + walker recovers → sudo escalate succeeds (fallback path uses _sudo_run_as)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T7: is_symlink op honored under same sudo-first shape ----------'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(subproc_rc=0)'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t7-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("is_symlink", blind, "agent-bridge-test")'
  printf '%s\n' 'assert rv is True, "T7 expected True from subproc-stub for is_symlink, got " + repr(rv)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T7: subprocess.run invoked once; got " + repr(subproc.calls)'
  printf '%s\n' 'argv = subproc.calls[0][0][0]'
  printf '%s\n' 'assert argv == ["sudo", "-n", "-u", "agent-bridge-test", "test", "-h", str(blind)], "T7 sudo argv shape wrong for is_symlink: " + repr(argv)'
  printf '%s\n' 'print("T7 PASS: is_symlink op uses sudo-first with -h flag")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T8 (#1170 r2 acceptance): sudo policy failure (rc=1 + "sudo:" stderr) MUST NOT be treated as "absent" ----------'
  printf '%s\n' '# Regression contract: revert stderr-discrimination → this returns False prematurely.'
  printf '%s\n' 'real_t8 = tmp / "t8-real"'
  printf '%s\n' 'real_t8.write_text("readable to controller")'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs('
  printf '%s\n' '    subproc_rc=1,'
  printf '%s\n' '    subproc_stderr="sudo: a password is required",'
  printf '%s\n' ')'
  printf '%s\n' 'rv = mod._safe_path_check("exists", real_t8, "agent-bridge-test")'
  printf '%s\n' 'assert rv is True, "T8 (#1170 r2): sudo policy failure (rc=1 + sudo: stderr) MUST fall through to direct pathlib and observe the controller-readable path; got " + repr(rv)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T8: subprocess.run invoked exactly once; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T8 PASS (#1170 r2): sudo-policy-failure (rc=1 + \"sudo:\" stderr) → falls through to direct pathlib, returns True")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T9 (#1170 r2): clean test rc=1 (empty stderr) MUST stay authoritative ----------'
  printf '%s\n' '# Distinguishes from T8: when stderr does NOT start with "sudo:", rc=1 is the test\x27s answer.'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(subproc_rc=1, subproc_stderr="")'
  printf '%s\n' 'blind_t9 = BlindPath(str(tmp / "t9-blind"))'
  printf '%s\n' 'rv = mod._safe_path_check("exists", blind_t9, "agent-bridge-test")'
  printf '%s\n' 'assert rv is False, "T9 (#1170 r2): clean test rc=1 (empty stderr) MUST be authoritative False, got " + repr(rv)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T9: subprocess.run invoked exactly once; got " + repr(subproc.calls)'
  printf '%s\n' 'print("T9 PASS (#1170 r2): clean rc=1 + empty stderr → authoritative False (no pathlib fallthrough)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T10 (#1170 r2 acceptance): TimeoutExpired falls through, does NOT wedge ----------'
  printf '%s\n' '# Simulates stuck sudo/PAM/NSS lookup. Regression contract: revert timeout plumbing → harness wall-clock hangs.'
  printf '%s\n' 'real_t10 = tmp / "t10-real"'
  printf '%s\n' 'real_t10.write_text("readable to controller")'
  printf '%s\n' 'timeout_exc = subprocess.TimeoutExpired(cmd=["sudo"], timeout=5)'
  printf '%s\n' 'sudo, subproc, walker_calls = reset_stubs(subproc_raises=timeout_exc)'
  printf '%s\n' 't10_start = time.monotonic()'
  printf '%s\n' 'rv = mod._safe_path_check("exists", real_t10, "agent-bridge-test")'
  printf '%s\n' 't10_elapsed = time.monotonic() - t10_start'
  printf '%s\n' 'assert rv is True, "T10 (#1170 r2): TimeoutExpired MUST fall through to direct pathlib, got " + repr(rv)'
  printf '%s\n' 'assert t10_elapsed < 2.0, "T10: harness wall-clock MUST stay tight (TimeoutExpired is synthetic); got " + repr(t10_elapsed)'
  printf '%s\n' 'assert len(subproc.calls) == 1, "T10: subprocess.run attempted exactly once; got " + repr(subproc.calls)'
  printf '%s\n' 'kwargs = subproc.calls[0][1]'
  printf '%s\n' 'assert kwargs.get("timeout") == 5, "T10: subprocess.run MUST be called with timeout=5; got kwargs=" + repr(kwargs)'
  printf '%s\n' 'print("T10 PASS (#1170 r2): TimeoutExpired → falls through to direct pathlib, returns True (NOT wedge)")'
  printf '%s\n' ''
  printf '%s\n' 'print("ALL PASS")'
} >>"$HARNESS"

OUT="$("$PY_BIN" "$HARNESS" "$REPO_ROOT" "$SMOKE_TMP_ROOT" 2>&1)" \
  || smoke_fail "harness failed: $OUT"
[[ "$OUT" == *"ALL PASS"* ]] \
  || smoke_fail "expected 'ALL PASS' marker, got: $OUT"

# Echo the harness body so the per-test PASS lines surface in the smoke log.
printf '%s\n' "$OUT" | while IFS= read -r line; do
  case "$line" in
    "T"*" PASS"*|"ALL PASS"*) smoke_log "$line" ;;
  esac
done

smoke_log "OK"
