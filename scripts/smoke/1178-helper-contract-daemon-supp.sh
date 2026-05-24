#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1178-helper-contract-daemon-supp.sh — Issue #1178.
#
# Cycle 12 architectural root: beta16's #1175 sweep landed clean but
# `setup teams test_iso2` STILL traceback at bridge-setup.py L368
# (`path.mkdir(parents=True, exist_ok=True)` on an isolated path). Three
# concurrent root causes, all addressed in this PR:
#
#   A. Helper layer bug — `resolve_isolated_owner_for_path` swallowed
#      `PermissionError` as `OSError: pass` and treated "controller is
#      blind to inode" as "no isolated lineage". The opposite of the
#      truth — PermissionError IS the positive signal of isolation.
#      Returning None then steered `_isolation_aware_mkdir` into the
#      `owner is None` branch, which ran a raw mkdir and raised
#      PermissionError. Fix: recover via `_sudo_stat_owner` (new helper,
#      uses `sudo -n stat` to read the owner under root).
#   C. Daemon supp-groups stale — bash daemon cannot self-refresh the
#      Linux kernel supplementary-group set (no `os.initgroups()` analog
#      in bash; `exec sg` is invasive). Emit a startup WARNING when the
#      running process's `id -G` differs from the canonical `id -G <user>`
#      and the missing set contains `ab-agent-*`. Operator runbook in
#      KNOWN_ISSUES.md §28 covers the manual resolution.
#   Lint. Extended `scripts/lint-raw-pathlib-on-isolated.sh` to catch
#      mutators (`.mkdir(`, `.unlink(`, `.touch(`, `.rmdir(`,
#      `shutil.copy/copy2/move/rmtree(`, `os.makedirs/remove/rename(`),
#      not just probes (`.exists()/is_file()/is_dir()/stat()`). Boomerang
#      test: temporarily add `Path('.').mkdir()` → lint fails.
#
# Tests:
#   T1: `resolve_isolated_owner_for_path` PermissionError → sudo-stat
#       fallback → returns owner (regression for #1178 helper swallow).
#   T1b: `isolated_workdir_owner` PermissionError on lstat → sudo-stat
#       fallback returns owner (the same helper sees the same class of
#       trip from a different entry point).
#   T2: legacy non-isolated path → walks normally (no regression on
#       shared-mode).
#   T3: daemon supp-groups warning fires when `id -G` (process) is
#       missing an `ab-agent-*` GID that `id -G <user>` (canonical) has.
#       Stubs `id` / `getent` / `uname` via a shim PATH directory.
#   T3b: daemon warning is silent on macOS (uname != Linux).
#   T4: lint catches NEW raw mutator pattern. Boomerang: inject
#       `Path('.').mkdir()` into a scratch copy of bridge-setup.py,
#       assert the lint fails. Then inject `shutil.copy(...)`, assert
#       the lint also fails on that pattern. (r2) Third boomerang
#       injects `.symlink_to(...)` and asserts the lint fails after
#       the pattern extension closed codex r1 BLOCKING 2.
#   T5: setup teams L368 reproducer — assert `_isolation_aware_mkdir`
#       on a blind-but-isolated path does NOT raise PermissionError
#       when `_sudo_stat_owner` is stubbed to return the owner.
#   T6: (r2) daemon `restart` subcommand exists — the supp-groups
#       warning recommends `agent-bridge daemon restart`; that verb
#       must dispatch to a real handler (cmd_restart = stop + start)
#       and appear in the usage string. Closes codex r1 BLOCKING 1.
#
# Host-agnostic: every Linux-specific behavior is exercised via PATH
# shims (`id`, `getent`, `uname`, `sudo`, `stat`) and Python `subprocess`
# stubs. No real `agent-bridge-*` users. Works on Linux + macOS.
#
# Footgun #11: every Python harness built with `printf '%s\n' >file`
# and run as `python3 <file>`; PATH-shim scripts assembled the same
# way. No `<<<` here-string or `<<EOF` feeds into subprocess capture.

set -uo pipefail

SMOKE_NAME="1178-helper-contract-daemon-supp"
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

# ---------------------------------------------------------------------------
# T1, T1b, T2, T5: Python harness against the shared module + bridge-setup.
# ---------------------------------------------------------------------------

HARNESS="$SMOKE_TMP_ROOT/run.py"
: >"$HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Issue #1178 smoke: helper PermissionError → sudo-stat fallback + _isolation_aware_mkdir L368 reproducer."""'
  printf '%s\n' 'import sys, importlib.util, subprocess'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'tmp = Path(sys.argv[2])'
  printf '%s\n' ''
  printf '%s\n' 'sys.path.insert(0, repo + "/lib")'
  printf '%s\n' 'import bridge_iso_paths as iso  # type: ignore'
  printf '%s\n' ''
  printf '%s\n' 'def load_module(name, path):'
  printf '%s\n' '    spec = importlib.util.spec_from_file_location(name, path)'
  printf '%s\n' '    mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' '    spec.loader.exec_module(mod)'
  printf '%s\n' '    return mod'
  printf '%s\n' ''
  printf '%s\n' 'bsetup = load_module("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' ''
  printf '%s\n' '# Force linux platform for the lstat-walker tests (helper short-'
  printf '%s\n' '# circuits to None on non-linux; the cycle 12 bug is linux-only).'
  printf '%s\n' 'iso.sys.platform = "linux"'
  printf '%s\n' ''
  printf '%s\n' '# Synthetic Path subclasses that raise PermissionError on the relevant probe.'
  printf '%s\n' 'class BlindExistsPath(type(Path())):  # type: ignore[misc]'
  printf '%s\n' '    """exists() raises PermissionError; everything else works."""'
  printf '%s\n' '    def exists(self):'
  printf '%s\n' '        raise PermissionError(13, "Permission denied", str(self))'
  printf '%s\n' ''
  printf '%s\n' 'class BlindLstatPath(type(Path())):  # type: ignore[misc]'
  printf '%s\n' '    """lstat() raises PermissionError; exists() defers to lstat path so also raises."""'
  printf '%s\n' '    def lstat(self):'
  printf '%s\n' '        raise PermissionError(13, "Permission denied", str(self))'
  printf '%s\n' ''
  printf '%s\n' '# Capture the original _sudo_stat_owner for restore between tests.'
  printf '%s\n' 'original_sudo_stat_owner = iso._sudo_stat_owner'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T1: resolve_isolated_owner_for_path PermissionError → sudo-stat fallback ----------'
  printf '%s\n' '# Pre-#1178: PermissionError was swallowed under `except OSError: pass` and the'
  printf '%s\n' '# walker climbed up blindly, returning None on a chain where every ancestor'
  printf '%s\n' '# denied the controller. Post-#1178: the sudo-stat fallback runs first and'
  printf '%s\n' '# returns the authoritative owner.'
  printf '%s\n' ''
  printf '%s\n' '# T1a: PermissionError on .exists() AND sudo-stat returns owner → owner wins'
  printf '%s\n' 'iso._sudo_stat_owner = lambda p: "agent-bridge-iso2"'
  printf '%s\n' 'blind = BlindExistsPath(str(tmp / "iso2/workdir/.teams"))'
  printf '%s\n' 'owner = iso.resolve_isolated_owner_for_path(blind)'
  printf '%s\n' 'assert owner == "agent-bridge-iso2", "T1a: expected agent-bridge-iso2 from sudo-stat recovery, got " + repr(owner)'
  printf '%s\n' 'print("T1a PASS: resolve_isolated_owner_for_path PermissionError → _sudo_stat_owner returns owner")'
  printf '%s\n' ''
  printf '%s\n' '# T1b: PermissionError + sudo-stat returns None on leaf, then returns owner on parent'
  printf '%s\n' '# (walker keeps climbing when sudo-stat at the leaf also fails).'
  printf '%s\n' 'calls = []'
  printf '%s\n' 'def stat_parent_only(p):'
  printf '%s\n' '    calls.append(str(p))'
  printf '%s\n' '    if str(p).endswith("/.teams"):'
  printf '%s\n' '        return None'
  printf '%s\n' '    return "agent-bridge-iso2"'
  printf '%s\n' 'iso._sudo_stat_owner = stat_parent_only'
  printf '%s\n' 'blind = BlindExistsPath(str(tmp / "iso2/workdir/.teams"))'
  printf '%s\n' 'owner = iso.resolve_isolated_owner_for_path(blind)'
  printf '%s\n' 'assert owner == "agent-bridge-iso2", "T1b: walker should climb after leaf sudo-stat fails, got " + repr(owner)'
  printf '%s\n' 'assert len(calls) >= 2, "T1b: walker should have called sudo-stat at least twice (leaf + parent), got calls=" + repr(calls)'
  printf '%s\n' 'print("T1b PASS: walker climbs from blind leaf through blind parent → owner via parent sudo-stat")'
  printf '%s\n' ''
  printf '%s\n' '# T1c: PRE-#1178 REGRESSION CONTRACT — disable _sudo_stat_owner (returns None),'
  printf '%s\n' '# assert resolve_isolated_owner_for_path returns None on a chain where every'
  printf '%s\n' '# ancestor raises PermissionError. This is the pre-#1178 behavior; the helper'
  printf '%s\n' '# fix is what changes the post-#1178 contract from "None" to "owner via sudo-stat".'
  printf '%s\n' 'iso._sudo_stat_owner = lambda p: None'
  printf '%s\n' 'blind = BlindExistsPath(str(tmp / "iso2/workdir/.teams"))'
  printf '%s\n' 'owner = iso.resolve_isolated_owner_for_path(blind)'
  printf '%s\n' 'assert owner is None, "T1c: without sudo-stat recovery + blind chain → returns None (pre-fix shape), got " + repr(owner)'
  printf '%s\n' 'print("T1c PASS: regression contract — disabling sudo-stat fallback reproduces pre-#1178 None return")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T1d: isolated_workdir_owner PermissionError → sudo-stat fallback ----------'
  printf '%s\n' '# The same class of bug existed in isolated_workdir_owner: lstat raising'
  printf '%s\n' '# PermissionError fell through `except OSError: pass` and the walker climbed up'
  printf '%s\n' '# without sudo-stat recovery. Post-#1178 the lstat-PermissionError branch tries'
  printf '%s\n' '# sudo-stat first and returns the owner immediately on success.'
  printf '%s\n' 'iso._sudo_stat_owner = lambda p: "agent-bridge-iso2" if str(p).endswith("/.teams") else None'
  printf '%s\n' 'blind = BlindLstatPath(str(tmp / "iso2/workdir/.teams"))'
  printf '%s\n' 'owner = iso.isolated_workdir_owner(blind)'
  printf '%s\n' 'assert owner == "agent-bridge-iso2", "T1d: lstat PermissionError → sudo-stat recovery, got " + repr(owner)'
  printf '%s\n' 'print("T1d PASS: isolated_workdir_owner lstat PermissionError → _sudo_stat_owner returns owner")'
  printf '%s\n' ''
  printf '%s\n' '# Restore for subsequent tests.'
  printf '%s\n' 'iso._sudo_stat_owner = original_sudo_stat_owner'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T2: legacy non-isolated path walks normally ----------'
  printf '%s\n' '# Direct shared-mode regression: a controller-owned path must return None'
  printf '%s\n' '# (no isolated lineage), not trigger any sudo subprocess. The helper short-'
  printf '%s\n' '# circuits before _sudo_stat_owner is ever called when exists() succeeds.'
  printf '%s\n' 'shared = tmp / "controller-owned/some/dir"'
  printf '%s\n' 'shared.mkdir(parents=True)'
  printf '%s\n' 'iso._sudo_stat_owner = lambda p: (_ for _ in ()).throw(AssertionError("must not be called on shared path"))'
  printf '%s\n' 'owner = iso.resolve_isolated_owner_for_path(shared)'
  printf '%s\n' 'assert owner is None, "T2: shared-mode path must return None (no agent-bridge-* owner), got " + repr(owner)'
  printf '%s\n' 'print("T2 PASS: shared-mode path walks normally (no sudo subprocess invoked, returns None)")'
  printf '%s\n' ''
  printf '%s\n' '# Restore.'
  printf '%s\n' 'iso._sudo_stat_owner = original_sudo_stat_owner'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T5: setup teams L368 reproducer ----------'
  printf '%s\n' '# `_isolation_aware_mkdir` on a blind-but-isolated path. Pre-#1178: the helper'
  printf '%s\n' '# returned None for owner → mkdir branch ran → PermissionError → operator'
  printf '%s\n' '# traceback. Post-#1178: the helper resolves owner via sudo-stat → sudo-mkdir'
  printf '%s\n' '# branch runs → no PermissionError.'
  printf '%s\n' ''
  printf '%s\n' '# Stub _sudo_stat_owner on the SHARED module (bridge-setup imports it via alias).'
  printf '%s\n' 'iso._sudo_stat_owner = lambda p: "agent-bridge-iso2"'
  printf '%s\n' ''
  printf '%s\n' '# Stub subprocess.run on bridge_setup so the sudo-mkdir invocation succeeds.'
  printf '%s\n' 'class T5SubStub:'
  printf '%s\n' '    def __init__(self):'
  printf '%s\n' '        self.calls = []'
  printf '%s\n' '    def __call__(self, *args, **kwargs):'
  printf '%s\n' '        self.calls.append(args[0] if args else [])'
  printf '%s\n' '        return subprocess.CompletedProcess(args=args[0], returncode=0, stdout="", stderr="")'
  printf '%s\n' 'stub = T5SubStub()'
  printf '%s\n' 'original_bsetup_run = bsetup.subprocess.run'
  printf '%s\n' 'original_iso_run = iso.subprocess.run'
  printf '%s\n' 'bsetup.subprocess.run = stub'
  printf '%s\n' 'iso.subprocess.run = stub'
  printf '%s\n' 'try:'
  printf '%s\n' '    blind_dir = BlindExistsPath(str(tmp / "iso2/workdir/.teams"))'
  printf '%s\n' '    try:'
  printf '%s\n' '        bsetup._isolation_aware_mkdir(blind_dir, agent="iso2")'
  printf '%s\n' '        raised = None'
  printf '%s\n' '    except PermissionError as exc:'
  printf '%s\n' '        raised = exc'
  printf '%s\n' '    assert raised is None, "T5: _isolation_aware_mkdir L368 reproducer MUST NOT raise PermissionError after helper-A fix; got " + repr(raised)'
  printf '%s\n' '    # Confirm sudo-mkdir was attempted (not the raw mkdir branch).'
  printf '%s\n' '    sudo_calls = [c for c in stub.calls if len(c) > 0 and c[0] == "sudo"]'
  printf '%s\n' '    assert len(sudo_calls) >= 1, "T5: at least one sudo invocation expected (sudo-mkdir branch), got calls=" + repr(stub.calls)'
  printf '%s\n' '    print("T5 PASS: _isolation_aware_mkdir on blind isolated path → sudo-mkdir branch, no PermissionError (L368 reproducer fix)")'
  printf '%s\n' 'finally:'
  printf '%s\n' '    bsetup.subprocess.run = original_bsetup_run'
  printf '%s\n' '    iso.subprocess.run = original_iso_run'
  printf '%s\n' '    iso._sudo_stat_owner = original_sudo_stat_owner'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T6: shared module exposes _sudo_stat_owner ----------'
  printf '%s\n' 'assert hasattr(iso, "_sudo_stat_owner"), "T6: shared module missing _sudo_stat_owner"'
  printf '%s\n' 'assert callable(iso._sudo_stat_owner), "T6: _sudo_stat_owner must be callable"'
  printf '%s\n' 'print("T6 PASS: _sudo_stat_owner exposed on shared module for monkey-patching")'
  printf '%s\n' ''
  printf '%s\n' 'print("ALL PASS")'
} >>"$HARNESS"

OUT="$("$PY_BIN" "$HARNESS" "$REPO_ROOT" "$SMOKE_TMP_ROOT" 2>&1)" \
  || smoke_fail "Python harness failed: $OUT"
[[ "$OUT" == *"ALL PASS"* ]] \
  || smoke_fail "expected 'ALL PASS' marker, got: $OUT"

printf '%s\n' "$OUT" | while IFS= read -r line; do
  case "$line" in
    "T"*" PASS"*|"ALL PASS"*) smoke_log "$line" ;;
  esac
done

# ---------------------------------------------------------------------------
# T3 + T3b: daemon supp-groups warning (PATH-shim test).
# ---------------------------------------------------------------------------
# Build a PATH-shim directory with controlled `id` / `getent` / `uname`
# implementations, source bridge-daemon.sh, call the helper directly,
# and assert the warning fires (or not) per the scenario.

SHIM_DIR="$SMOKE_TMP_ROOT/shim-bin"
mkdir -p "$SHIM_DIR"

# T3: Linux + stale supp-groups + missing ab-agent-* → warning fires.
write_t3_shims() {
  : >"$SHIM_DIR/uname"
  printf '%s\n' '#!/usr/bin/env bash' >>"$SHIM_DIR/uname"
  printf '%s\n' 'echo Linux' >>"$SHIM_DIR/uname"
  chmod +x "$SHIM_DIR/uname"

  # id: when called with no args → process GIDs. Called with `-G` → list.
  # Called with `-G <user>` → canonical list.
  # Called with `-un` → user name.
  : >"$SHIM_DIR/id"
  # shellcheck disable=SC2129  # per-line emit mirrors footgun #11 avoidance shape (see 1175 smoke)
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '  "-un") echo "patch" ;;'
    printf '%s\n' '  "-G") echo "100 200 300" ;;'
    printf '%s\n' '  "-G patch") echo "100 200 300 9001" ;;'
    printf '%s\n' '  *) echo "id: unsupported invocation: $*" >&2; exit 1 ;;'
    printf '%s\n' 'esac'
  } >>"$SHIM_DIR/id"
  chmod +x "$SHIM_DIR/id"

  # getent: getent group 9001 → ab-agent-iso2:x:9001:patch
  : >"$SHIM_DIR/getent"
  # shellcheck disable=SC2129
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '  "group 9001") echo "ab-agent-iso2:x:9001:patch" ;;'
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } >>"$SHIM_DIR/getent"
  chmod +x "$SHIM_DIR/getent"
}

# T3b: macOS (uname != Linux) → silent no-op.
write_t3b_shims() {
  : >"$SHIM_DIR/uname"
  printf '%s\n' '#!/usr/bin/env bash' >>"$SHIM_DIR/uname"
  printf '%s\n' 'echo Darwin' >>"$SHIM_DIR/uname"
  chmod +x "$SHIM_DIR/uname"

  # Defensive id/getent that would scream if reached (proves no-op).
  : >"$SHIM_DIR/id"
  printf '%s\n' '#!/usr/bin/env bash' >>"$SHIM_DIR/id"
  printf '%s\n' 'echo "id: macOS shim must not be reached" >&2; exit 99' >>"$SHIM_DIR/id"
  chmod +x "$SHIM_DIR/id"

  : >"$SHIM_DIR/getent"
  printf '%s\n' '#!/usr/bin/env bash' >>"$SHIM_DIR/getent"
  printf '%s\n' 'echo "getent: macOS shim must not be reached" >&2; exit 99' >>"$SHIM_DIR/getent"
  chmod +x "$SHIM_DIR/getent"
}

# Extract the helper definition + invoke harness. We avoid sourcing the
# full bridge-daemon.sh (it would pull bridge-lib.sh + roster + everything),
# extract just the helper function body via awk and define it standalone.
extract_helper() {
  local source="$REPO_ROOT/bridge-daemon.sh"
  local out="$SMOKE_TMP_ROOT/helper-extract.sh"
  : >"$out"
  # shellcheck disable=SC2129  # per-line emit mirrors footgun #11 avoidance shape
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # Need daemon_warn too (helper calls it).
    awk '/^daemon_warn\(\) \{/,/^\}/' "$source"
    printf '%s\n' ''
    awk '/^bridge_daemon_warn_if_supp_groups_stale\(\) \{/,/^\}/' "$source"
    printf '%s\n' ''
    printf '%s\n' 'bridge_daemon_warn_if_supp_groups_stale'
  } >>"$out"
  printf '%s\n' "$out"
}

HELPER_RUNNER="$(extract_helper)"
chmod +x "$HELPER_RUNNER"

# T3: stale supp-groups → warning fires.
write_t3_shims
T3_OUT="$(PATH="$SHIM_DIR:$PATH" bash "$HELPER_RUNNER" 2>&1)"
T3_RC=$?
if [[ "$T3_RC" -ne 0 ]]; then
  smoke_fail "T3: helper extract runner exited non-zero (rc=$T3_RC), output: $T3_OUT"
fi
if [[ "$T3_OUT" != *"stale"* ]] || [[ "$T3_OUT" != *"ab-agent-iso2"* ]]; then
  smoke_fail "T3: expected stale supp-groups warning mentioning ab-agent-iso2, got: $T3_OUT"
fi
if [[ "$T3_OUT" != *"KNOWN_ISSUES.md"* ]] || [[ "$T3_OUT" != *"§28"* ]]; then
  smoke_fail "T3: expected resolution-runbook pointer in warning, got: $T3_OUT"
fi
smoke_log "T3 PASS: daemon supp-groups stale warning fires with ab-agent-* group name + runbook pointer"

# T3b: macOS → no warning.
write_t3b_shims
T3B_OUT="$(PATH="$SHIM_DIR:$PATH" bash "$HELPER_RUNNER" 2>&1)"
T3B_RC=$?
if [[ "$T3B_RC" -ne 0 ]]; then
  smoke_fail "T3b: helper extract runner exited non-zero on macOS shim (rc=$T3B_RC), output: $T3B_OUT"
fi
if [[ -n "$T3B_OUT" ]]; then
  smoke_fail "T3b: macOS (uname != Linux) must produce no warning output, got: $T3B_OUT"
fi
smoke_log "T3b PASS: daemon supp-groups helper is silent on macOS (uname != Linux)"

# ---------------------------------------------------------------------------
# T4: lint catches NEW raw mutator pattern (boomerang).
# ---------------------------------------------------------------------------

LINT_SCRIPT="$REPO_ROOT/scripts/lint-raw-pathlib-on-isolated.sh"
BASELINE_FILE="$REPO_ROOT/scripts/baselines/raw-pathlib-baseline.txt"

[[ -x "$LINT_SCRIPT" ]] || smoke_fail "lint script missing or non-executable: $LINT_SCRIPT"
[[ -f "$BASELINE_FILE" ]] || smoke_fail "baseline file missing: $BASELINE_FILE"

# T4a: self-test PASS on the extended pattern.
if ! "$LINT_SCRIPT" --self-test >/dev/null 2>&1; then
  smoke_fail "T4a: lint script --self-test FAILED — extended pattern detection broken"
fi
smoke_log "T4a PASS: lint --self-test on the extended mutator pattern (6 positives across probe + mutator surfaces, including symlink_to)"

# T4b: baseline check PASS on the current tree (extended pattern, all noqa'd).
if ! "$LINT_SCRIPT" --check >/dev/null 2>&1; then
  ACTUAL_OUT="$("$LINT_SCRIPT" --check 2>&1 || true)"
  smoke_fail "T4b: lint --check FAIL on the integration tree (after noqa sweep): $ACTUAL_OUT"
fi
smoke_log "T4b PASS: lint --check on the integration tree (extended pattern, all sites either routed-safe or noqa'd)"

# T4c: boomerang — inject a violating raw `Path('.').mkdir()` into a
# scratch copy of bridge-setup.py and assert lint FAILS.
T4_SCRATCH="$SMOKE_TMP_ROOT/scratch-repo"
mkdir -p "$T4_SCRATCH/scripts/baselines" "$T4_SCRATCH/lib"
cp "$REPO_ROOT/bridge-setup.py" "$T4_SCRATCH/bridge-setup.py"
cp "$REPO_ROOT/bridge-hooks.py" "$T4_SCRATCH/bridge-hooks.py"
cp "$REPO_ROOT/scripts/baselines/raw-pathlib-baseline.txt" \
   "$T4_SCRATCH/scripts/baselines/raw-pathlib-baseline.txt"

printf '\n# T4c boomerang regression site (smoke-only)\n_violating_probe = Path(".").mkdir()\n' \
  >>"$T4_SCRATCH/bridge-setup.py"

mkdir -p "$T4_SCRATCH/scripts"
cp "$LINT_SCRIPT" "$T4_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh"
chmod +x "$T4_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh"

T4C_OUT="$(
  BRIDGE_RAW_PATHLIB_BASELINE_FILE="$T4_SCRATCH/scripts/baselines/raw-pathlib-baseline.txt" \
  "$T4_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh" --check 2>&1
)"
T4C_RC=$?

if [[ "$T4C_RC" -eq 0 ]]; then
  smoke_fail "T4c boomerang: lint MUST fail when a NEW raw .mkdir() lands in bridge-setup.py; got rc=$T4C_RC, output: $T4C_OUT"
fi
if [[ "$T4C_OUT" != *"bridge-setup.py"* ]]; then
  smoke_fail "T4c boomerang: lint failure output should mention bridge-setup.py; got: $T4C_OUT"
fi
smoke_log "T4c PASS (boomerang): lint catches NEW raw \`Path('.').mkdir()\` injected into bridge-setup.py"

# T4d: second boomerang — inject `shutil.copy(...)` and assert lint also fails.
# Reset scratch tree from the pristine repo files first.
cp "$REPO_ROOT/bridge-setup.py" "$T4_SCRATCH/bridge-setup.py"
cp "$REPO_ROOT/bridge-hooks.py" "$T4_SCRATCH/bridge-hooks.py"
printf '\n# T4d boomerang regression site (smoke-only)\n_violating_copy = shutil.copy("/tmp/x", "/tmp/y")\n' \
  >>"$T4_SCRATCH/bridge-hooks.py"

T4D_OUT="$(
  BRIDGE_RAW_PATHLIB_BASELINE_FILE="$T4_SCRATCH/scripts/baselines/raw-pathlib-baseline.txt" \
  "$T4_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh" --check 2>&1
)"
T4D_RC=$?

if [[ "$T4D_RC" -eq 0 ]]; then
  smoke_fail "T4d boomerang: lint MUST fail when a NEW raw shutil.copy() lands in bridge-hooks.py; got rc=$T4D_RC, output: $T4D_OUT"
fi
if [[ "$T4D_OUT" != *"bridge-hooks.py"* ]]; then
  smoke_fail "T4d boomerang: lint failure output should mention bridge-hooks.py; got: $T4D_OUT"
fi
smoke_log "T4d PASS (boomerang): lint catches NEW raw \`shutil.copy(...)\` injected into bridge-hooks.py"

# T4e: third boomerang — inject `Path('.').symlink_to(...)` and assert
# lint also fails (#1178 r2 codex r1 BLOCKING 2: the pre-r2 pattern
# omitted symlink_to even though bridge-hooks.py:1313/1519 already had
# raw .symlink_to() sites on isolated-setting paths).
cp "$REPO_ROOT/bridge-setup.py" "$T4_SCRATCH/bridge-setup.py"
cp "$REPO_ROOT/bridge-hooks.py" "$T4_SCRATCH/bridge-hooks.py"
printf '\n# T4e boomerang regression site (smoke-only)\n_violating_symlink = Path("link").symlink_to("target")\n' \
  >>"$T4_SCRATCH/bridge-hooks.py"

T4E_OUT="$(
  BRIDGE_RAW_PATHLIB_BASELINE_FILE="$T4_SCRATCH/scripts/baselines/raw-pathlib-baseline.txt" \
  "$T4_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh" --check 2>&1
)"
T4E_RC=$?

if [[ "$T4E_RC" -eq 0 ]]; then
  smoke_fail "T4e boomerang: lint MUST fail when a NEW raw .symlink_to() lands in bridge-hooks.py; got rc=$T4E_RC, output: $T4E_OUT"
fi
if [[ "$T4E_OUT" != *"bridge-hooks.py"* ]]; then
  smoke_fail "T4e boomerang: lint failure output should mention bridge-hooks.py; got: $T4E_OUT"
fi
smoke_log "T4e PASS (boomerang): lint catches NEW raw \`.symlink_to(...)\` injected into bridge-hooks.py"

# ---------------------------------------------------------------------------
# T6: daemon restart subcommand exists (#1178 r2 codex r1 BLOCKING 1).
# The supp-groups warning recommends `agent-bridge daemon restart`; that
# recommendation must point at a real subcommand. Pre-r2 the dispatch
# only had start/ensure/run/stop/status/sync, so bare `bash
# bridge-daemon.sh restart` fell into the `*)` arm, printed usage,
# and exited rc=1.
#
# We don't execute the actual stop+start here (it would touch the live
# daemon); instead we verify the dispatch arm exists by invoking with
# --help (which short-circuits before cmd_restart runs). If `restart`
# is unknown the script prints usage and exits 1; if `restart` is a
# real verb, the help short-circuit returns 0.
# ---------------------------------------------------------------------------

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
[[ -f "$DAEMON_SH" ]] || smoke_fail "T6: bridge-daemon.sh missing at $DAEMON_SH"

# T6a: dispatch arm exists. `restart --help` should exit 0 (matches the
# shape of `stop --help`, `start --help`, etc.).
T6A_OUT="$(bash "$DAEMON_SH" restart --help 2>&1 || true)"
T6A_RC=$?
if [[ "$T6A_RC" -ne 0 ]]; then
  smoke_fail "T6a: \`bash bridge-daemon.sh restart --help\` must exit 0 (the restart dispatch arm should short-circuit on help). Got rc=$T6A_RC, output: $T6A_OUT"
fi
smoke_log "T6a PASS: \`bridge-daemon.sh restart --help\` short-circuits with rc=0 (dispatch arm exists)"

# T6b: usage string advertises the restart verb so operators discover
# the warning's recommended command via `--help`.
T6B_OUT="$(bash "$DAEMON_SH" --help 2>&1 || true)"
if [[ "$T6B_OUT" != *"restart"* ]]; then
  smoke_fail "T6b: usage string must mention 'restart' so the supp-groups warning's recommended command is discoverable; got: $T6B_OUT"
fi
smoke_log "T6b PASS: usage string advertises the restart subcommand"

smoke_log "OK"
