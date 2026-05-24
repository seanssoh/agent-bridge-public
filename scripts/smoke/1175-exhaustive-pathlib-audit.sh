#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1175-exhaustive-pathlib-audit.sh — Issue #1175.
#
# Cycles 9-10-11 (#1165 → #1170 → #1175) all surfaced the same class of
# bug — a raw pathlib metadata probe in the controller-side setup/render
# flow hit an isolated agent's tree, raised PermissionError, and crashed
# the operator recovery / rerender flow before the sudo-escalating
# fallback could fire. Each cycle fixed exactly ONE site, then the
# operator's next reproducer surfaced an adjacent raw site (e.g.
# `bridge-setup.py:392 _isolation_aware_mkdir` immediately after the
# `_safe_path_check` fix in #1170 landed at L498-).
#
# #1175 broke the whack-a-mole by:
#   1. Lifting `_safe_path_check`, `_safe_read_env`, `_safe_load_json`,
#      `_isolated_workdir_owner`, `_resolve_isolated_owner_for_path`,
#      `_sudo_run_as`, `_parse_dotenv_text` into the canonical
#      `lib/bridge_iso_paths.py` shared module.
#   2. Both `bridge-setup.py` and `bridge-hooks.py` import the canonical
#      names; local duplicate definitions are deleted.
#   3. Sweeping the HIGH raw-pathlib sites in both files (4 in setup-py,
#      12+ in hooks-py per the #1175 inventory) and rewriting them to go
#      through the shared safe wrappers.
#   4. Adding `scripts/lint-raw-pathlib-on-isolated.sh` as a regression
#      guard so NEW raw pathlib metadata calls on isolated paths must
#      either route through the safe wrapper OR carry an explicit
#      `# noqa: raw-pathlib-controller-only` whitelist marker.
#
# Coverage:
#   T1: shared-module `safe_path_check` proactive-sudo + stderr-
#       discrimination contracts (regression-mirror of the #1170 r2
#       T8/T9 catches). Imports from `lib/bridge_iso_paths.py` directly
#       so we exercise the canonical module, not the import alias.
#   T2: `safe_read_env` + `safe_load_json` round-trip through the shared
#       module: directly-readable `.env` / JSON returns parsed payload;
#       sudo-cat-fallback returns parsed payload on synthetic
#       PermissionError + sudo-stub success; fail-closed `{}`/`default`
#       on PermissionError + missing-owner.
#   T3: `bridge-setup.py:_isolation_aware_mkdir` is idempotent when
#       re-run against a controller-readable existing dir AND does not
#       raise PermissionError when the existence probe is forced to
#       fail-closed (simulated via monkey-patching `_safe_path_check`).
#       Regression for the #1175 next-reproducer (L392 in patch's
#       inventory).
#   T4: `bridge-hooks.py:_load_preserved_user_keys` returns `{}` (fail-
#       closed) when the underlying `_safe_path_check` reports "absent"
#       on a blind path — NOT a traceback. Regression for the
#       PostToolUseFailure flood (#1165 Gap 7 family + #1173 sister).
#   T4b: `bridge-hooks.py:next_backup_path` (#1175 r2 / PR #1176 codex
#        review) accepts optional `os_user` and routes the collision
#        loop through `_safe_path_check`. Regression for the blind-
#        path PermissionError that escaped the outer
#        `cmd_link_shared_settings` sudo-fallback in r1.
#   T5 (boomerang): `scripts/lint-raw-pathlib-on-isolated.sh` catches a
#       NEW raw `Path.exists()` introduced into bridge-setup.py. The
#       smoke temporarily appends a violating line, runs the lint,
#       asserts failure, then removes the line. This validates the lint
#       script itself + the baseline ratchet semantics.
#   T6: shared-module presence + back-compat aliases. `lib/bridge_iso_paths.py`
#       must export every public name AND every legacy private-name
#       alias (`_safe_path_check`, `_sudo_run_as`, etc.) so the existing
#       #1170 smoke harness (`scripts/smoke/1170-safe-path-check-sudo-escalate.sh`)
#       — which stubs `mod._sudo_run_as` on the bridge-setup.py module —
#       keeps working without churn.
#
# Host-agnostic: every test stubs `subprocess.run` on the relevant module
# and uses synthetic `PermissionError`-raising path subclasses. No real
# `agent-bridge-*` users, no actual sudo invocation. Works on Linux + macOS.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every harness is
# built with `printf '%s\n' >file` and run as `python3 <file>`; no
# `<<<` here-string or `<<EOF` feeds into a subprocess capture.

set -uo pipefail

SMOKE_NAME="1175-exhaustive-pathlib-audit"
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
# T1+T2+T3+T4+T6: Python harness against the shared module + both
# importing scripts.
# ---------------------------------------------------------------------------

HARNESS="$SMOKE_TMP_ROOT/run.py"
: >"$HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Issue #1175 smoke: canonical iso-paths module + safe-wrapper sweep."""'
  printf '%s\n' 'import sys, importlib.util, subprocess, json, os'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'tmp = Path(sys.argv[2])'
  printf '%s\n' ''
  printf '%s\n' '# Insert repo lib/ on sys.path so we can import the shared module directly,'
  printf '%s\n' '# the same way bridge-setup.py / bridge-hooks.py do.'
  printf '%s\n' 'sys.path.insert(0, repo + "/lib")'
  printf '%s\n' ''
  printf '%s\n' 'import bridge_iso_paths as iso  # type: ignore'
  printf '%s\n' ''
  printf '%s\n' '# Load both consumer scripts via importlib so we exercise the import'
  printf '%s\n' '# wiring (top-of-file `from bridge_iso_paths import ... as _...`).'
  printf '%s\n' 'def load_module(name, path):'
  printf '%s\n' '    spec = importlib.util.spec_from_file_location(name, path)'
  printf '%s\n' '    mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' '    spec.loader.exec_module(mod)'
  printf '%s\n' '    return mod'
  printf '%s\n' ''
  printf '%s\n' 'bsetup = load_module("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' 'bhooks = load_module("bridge_hooks", repo + "/bridge-hooks.py")'
  printf '%s\n' ''
  printf '%s\n' '# A pathlib.Path subclass whose .exists() / .is_symlink() raise PermissionError.'
  printf '%s\n' 'class BlindPath(type(Path())):  # type: ignore[misc]'
  printf '%s\n' '    def exists(self):'
  printf '%s\n' '        raise PermissionError(13, "Permission denied", str(self))'
  printf '%s\n' '    def is_symlink(self):'
  printf '%s\n' '        raise PermissionError(13, "Permission denied", str(self))'
  printf '%s\n' ''
  printf '%s\n' 'class SubprocessRunStub:'
  printf '%s\n' '    def __init__(self, rc=0, stderr="", stdout="", raises=None):'
  printf '%s\n' '        self.rc = rc'
  printf '%s\n' '        self.stderr_text = stderr'
  printf '%s\n' '        self.stdout_text = stdout'
  printf '%s\n' '        self.raises = raises'
  printf '%s\n' '        self.calls = []'
  printf '%s\n' '    def __call__(self, *args, **kwargs):'
  printf '%s\n' '        self.calls.append((args, kwargs))'
  printf '%s\n' '        if self.raises is not None:'
  printf '%s\n' '            raise self.raises'
  printf '%s\n' '        return subprocess.CompletedProcess('
  printf '%s\n' '            args=args[0] if args else [],'
  printf '%s\n' '            returncode=self.rc,'
  printf '%s\n' '            stdout=self.stdout_text,'
  printf '%s\n' '            stderr=self.stderr_text,'
  printf '%s\n' '        )'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T1: shared-module safe_path_check proactive sudo + stderr discrimination ----------'
  printf '%s\n' '# Mirror of #1170 T3/T4/T8/T9 against the canonical module (not the bridge-setup.py'
  printf '%s\n' '# import alias). Tests the contract end-to-end at the canonical layer.'
  printf '%s\n' ''
  printf '%s\n' '# T1a: subproc rc=0 → True via proactive sudo, no fallthrough'
  printf '%s\n' 'stub = SubprocessRunStub(rc=0)'
  printf '%s\n' 'iso.subprocess.run = stub'
  printf '%s\n' 'blind = BlindPath(str(tmp / "t1a-blind"))'
  printf '%s\n' 'rv = iso.safe_path_check("exists", blind, "agent-bridge-test")'
  printf '%s\n' 'assert rv is True, "T1a: expected True from proactive sudo rc=0, got " + repr(rv)'
  printf '%s\n' 'assert len(stub.calls) == 1, "T1a: subprocess.run called exactly once; got " + repr(stub.calls)'
  printf '%s\n' 'kwargs = stub.calls[0][1]'
  printf '%s\n' 'assert kwargs.get("timeout") == 5, "T1a: must call with timeout=5; got " + repr(kwargs)'
  printf '%s\n' 'print("T1a PASS: shared safe_path_check + sudo rc=0 → True (proactive sudo with timeout=5)")'
  printf '%s\n' ''
  printf '%s\n' '# T1b: subproc rc=1 + clean stderr → False (authoritative)'
  printf '%s\n' 'stub = SubprocessRunStub(rc=1, stderr="")'
  printf '%s\n' 'iso.subprocess.run = stub'
  printf '%s\n' 'rv = iso.safe_path_check("exists", BlindPath(str(tmp / "t1b-blind")), "agent-bridge-test")'
  printf '%s\n' 'assert rv is False, "T1b: clean rc=1 must be authoritative False, got " + repr(rv)'
  printf '%s\n' 'print("T1b PASS: shared safe_path_check + clean rc=1 → False (no pathlib fallthrough)")'
  printf '%s\n' ''
  printf '%s\n' '# T1c: subproc rc=1 + "sudo:" stderr → fall through to direct pathlib (controller-readable)'
  printf '%s\n' 'real = tmp / "t1c-real"'
  printf '%s\n' 'real.write_text("x")'
  printf '%s\n' 'stub = SubprocessRunStub(rc=1, stderr="sudo: a password is required")'
  printf '%s\n' 'iso.subprocess.run = stub'
  printf '%s\n' 'rv = iso.safe_path_check("exists", real, "agent-bridge-test")'
  printf '%s\n' 'assert rv is True, "T1c: sudo policy failure must fall through to direct pathlib + observe real path, got " + repr(rv)'
  printf '%s\n' 'print("T1c PASS: shared safe_path_check + sudo:-prefixed stderr → falls through, returns True")'
  printf '%s\n' ''
  printf '%s\n' '# T1d: is_symlink op routes correctly'
  printf '%s\n' 'stub = SubprocessRunStub(rc=0)'
  printf '%s\n' 'iso.subprocess.run = stub'
  printf '%s\n' 'rv = iso.safe_path_check("is_symlink", BlindPath(str(tmp / "t1d-blind")), "agent-bridge-test")'
  printf '%s\n' 'assert rv is True, "T1d: is_symlink + rc=0 → True, got " + repr(rv)'
  printf '%s\n' 'argv = stub.calls[0][0][0]'
  printf '%s\n' 'assert argv[4] == "test" and argv[5] == "-h", "T1d: is_symlink must use -h flag at argv[5]; got argv=" + repr(argv)'
  printf '%s\n' 'print("T1d PASS: shared safe_path_check is_symlink uses -h flag")'
  printf '%s\n' ''
  printf '%s\n' '# Reset subprocess.run so subsequent tests work normally'
  printf '%s\n' 'iso.subprocess.run = subprocess.run'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T2: safe_read_env + safe_load_json round-trip ----------'
  printf '%s\n' ''
  printf '%s\n' '# T2a: controller-readable .env returns parsed payload'
  printf '%s\n' 'env_path = tmp / "t2a.env"'
  printf '%s\n' 'env_path.write_text("KEY1=value1\nKEY2 = value2\n# comment\n\nKEY3=value with spaces\n")'
  printf '%s\n' 'payload = iso.safe_read_env(env_path)'
  printf '%s\n' 'assert payload == {"KEY1": "value1", "KEY2": "value2", "KEY3": "value with spaces"}, "T2a: expected parsed dotenv, got " + repr(payload)'
  printf '%s\n' 'print("T2a PASS: shared safe_read_env reads + parses controller-readable .env")'
  printf '%s\n' ''
  printf '%s\n' '# T2b: missing .env returns {}'
  printf '%s\n' 'missing = tmp / "t2b-missing.env"'
  printf '%s\n' 'payload = iso.safe_read_env(missing)'
  printf '%s\n' 'assert payload == {}, "T2b: expected {} for missing, got " + repr(payload)'
  printf '%s\n' 'print("T2b PASS: shared safe_read_env returns {} for missing file (matches load_dotenv contract)")'
  printf '%s\n' ''
  printf '%s\n' '# T2c: controller-readable JSON returns parsed payload'
  printf '%s\n' 'json_path = tmp / "t2c.json"'
  printf '%s\n' 'json_path.write_text(json.dumps({"a": 1, "b": [2, 3]}))'
  printf '%s\n' 'doc = iso.safe_load_json(json_path, {})'
  printf '%s\n' 'assert doc == {"a": 1, "b": [2, 3]}, "T2c: expected parsed JSON, got " + repr(doc)'
  printf '%s\n' 'print("T2c PASS: shared safe_load_json reads + parses controller-readable JSON")'
  printf '%s\n' ''
  printf '%s\n' '# T2d: missing JSON returns default'
  printf '%s\n' 'missing_json = tmp / "t2d-missing.json"'
  printf '%s\n' 'doc = iso.safe_load_json(missing_json, {"default": True})'
  printf '%s\n' 'assert doc == {"default": True}, "T2d: expected default for missing, got " + repr(doc)'
  printf '%s\n' 'print("T2d PASS: shared safe_load_json returns default for missing file")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T3: _isolation_aware_mkdir L392 next-reproducer ----------'
  printf '%s\n' '# Patch checked back into beta15: a re-run of `agb setup teams` on a pre-'
  printf '%s\n' '# existing isolated `.teams/` dir raised PermissionError at bridge-setup.py:392'
  printf '%s\n' '# because the existence probe was a raw `path.exists()`. After #1175 the probe'
  printf '%s\n' '# routes through `_safe_path_check`; on a blind-but-actually-existing path the'
  printf '%s\n' '# wrapper sudo-escalates first and skips the mkdir, returning cleanly.'
  printf '%s\n' ''
  printf '%s\n' '# T3a: controller-readable existing dir is idempotent (early return)'
  printf '%s\n' 'existing = tmp / "t3a-existing"'
  printf '%s\n' 'existing.mkdir()'
  printf '%s\n' '# call with no owner / no group — must short-circuit without touching subprocess.'
  printf '%s\n' 'bsetup._isolation_aware_mkdir(existing)'
  printf '%s\n' 'assert existing.is_dir(), "T3a: existing dir must still be a dir, got " + repr(existing.stat() if existing.exists() else None)'
  printf '%s\n' 'print("T3a PASS: _isolation_aware_mkdir is idempotent on controller-readable existing dir")'
  printf '%s\n' ''
  printf '%s\n' '# T3b: blind-but-existing-via-sudo path -- safe_path_check returns True via the'
  printf '%s\n' '# stubbed subprocess.run, mkdir short-circuits, no PermissionError raised.'
  printf '%s\n' '# We monkey-patch the module-level subprocess.run to simulate sudo success.'
  printf '%s\n' 'original_subproc_run = bsetup.subprocess.run'
  printf '%s\n' 'class T3SubStub:'
  printf '%s\n' '    def __init__(self):'
  printf '%s\n' '        self.calls = []'
  printf '%s\n' '    def __call__(self, *args, **kwargs):'
  printf '%s\n' '        self.calls.append(args)'
  printf '%s\n' '        return subprocess.CompletedProcess(args=args[0], returncode=0, stdout="", stderr="")'
  printf '%s\n' ''
  printf '%s\n' '# Also stub the resolver to return an owner (forces the sudo branch in safe_path_check).'
  printf '%s\n' 'original_resolver = bsetup._resolve_isolated_owner_for_path'
  printf '%s\n' 'bsetup._resolve_isolated_owner_for_path = lambda p: "agent-bridge-test"'
  printf '%s\n' 'iso.subprocess.run = T3SubStub()'
  printf '%s\n' 'try:'
  printf '%s\n' '    blind_dir = BlindPath(str(tmp / "t3b-blind-existing"))'
  printf '%s\n' '    # Should NOT raise PermissionError; the safe wrapper sudo-escalates first.'
  printf '%s\n' '    try:'
  printf '%s\n' '        bsetup._isolation_aware_mkdir(blind_dir)'
  printf '%s\n' '        raised = None'
  printf '%s\n' '    except PermissionError as exc:'
  printf '%s\n' '        raised = exc'
  printf '%s\n' '    assert raised is None, "T3b: _isolation_aware_mkdir on blind-but-sudo-exists MUST NOT raise PermissionError; got " + repr(raised)'
  printf '%s\n' '    print("T3b PASS: _isolation_aware_mkdir on blind-but-sudo-exists path → no traceback (#1175 next-reproducer guard)")'
  printf '%s\n' 'finally:'
  printf '%s\n' '    iso.subprocess.run = original_subproc_run'
  printf '%s\n' '    bsetup._resolve_isolated_owner_for_path = original_resolver'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T4: bridge-hooks._load_preserved_user_keys traceback-free on blind path ----------'
  printf '%s\n' '# Pre-#1175 the bridge-hooks renderer raised PermissionError on its'
  printf '%s\n' '# `effective_path.exists()` probe whenever the isolated home was beyond'
  printf '%s\n' '# the controller traversal grant. After #1175 the probe routes through'
  printf '%s\n' '# `_safe_path_check` which fail-closes when no sudo escalation is available,'
  printf '%s\n' '# so the renderer continues with an empty preserved-keys dict.'
  printf '%s\n' ''
  printf '%s\n' 'blind_eff = BlindPath(str(tmp / "t4-blind.effective.json"))'
  printf '%s\n' '# No sudo available, no owner resolvable → safe wrapper fail-closes to False'
  printf '%s\n' '# → _load_preserved_user_keys returns {}.'
  printf '%s\n' 'try:'
  printf '%s\n' '    preserved = bhooks._load_preserved_user_keys(blind_eff)'
  printf '%s\n' '    t4_raised = None'
  printf '%s\n' 'except PermissionError as exc:'
  printf '%s\n' '    preserved = None'
  printf '%s\n' '    t4_raised = exc'
  printf '%s\n' 'assert t4_raised is None, "T4: _load_preserved_user_keys MUST NOT raise PermissionError on a blind effective_path; got " + repr(t4_raised)'
  printf '%s\n' 'assert preserved == {}, "T4: blind effective_path → empty preserved dict, got " + repr(preserved)'
  printf '%s\n' 'print("T4 PASS: _load_preserved_user_keys fail-closes on blind path → {} (no PostToolUseFailure traceback flood)")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T4b: next_backup_path isolation-aware on blind path ----------'
  printf '%s\n' '# Codex r1 BLOCKING on PR #1176: `next_backup_path` ran a raw'
  printf '%s\n' '# `candidate.exists()` against the original path, so when'
  printf '%s\n' '# `cmd_link_shared_settings` confirmed an isolated `settings.json`'
  printf '%s\n' '# existed via `_safe_path_check("exists", settings_path, os_user)`'
  printf '%s\n' '# (proactive-sudo branch), the very next `next_backup_path`'
  printf '%s\n' '# call could raise PermissionError before the sudo-backed'
  printf '%s\n' '# copy2/rm fallback could fire. After #1175 r2 the helper'
  printf '%s\n' '# accepts an optional `os_user` and routes through the safe'
  printf '%s\n' '# wrapper, so the same blind-path probe returns a candidate'
  printf '%s\n' '# instead of raising.'
  printf '%s\n' ''
  printf '%s\n' '# T4b-1: blind path WITHOUT os_user falls through (controller-only'
  printf '%s\n' '# legacy call sites still work; safe wrapper fail-closes to "absent"'
  printf '%s\n' '# so the first candidate is returned without raising).'
  printf '%s\n' 'blind_orig = BlindPath(str(tmp / "t4b-blind/settings.json"))'
  printf '%s\n' 'try:'
  printf '%s\n' '    cand_no_user = bhooks.next_backup_path(blind_orig)'
  printf '%s\n' '    t4b1_raised = None'
  printf '%s\n' 'except PermissionError as exc:'
  printf '%s\n' '    cand_no_user = None'
  printf '%s\n' '    t4b1_raised = exc'
  printf '%s\n' 'assert t4b1_raised is None, "T4b-1: next_backup_path(blind, None) MUST NOT raise PermissionError; got " + repr(t4b1_raised)'
  printf '%s\n' 'assert cand_no_user is not None and ".agent-bridge.bak-" in cand_no_user.name, "T4b-1: expected backup-named candidate; got " + repr(cand_no_user)'
  printf '%s\n' 'print("T4b-1 PASS: next_backup_path(blind, None) fail-closes via safe wrapper (no traceback)")'
  printf '%s\n' ''
  printf '%s\n' '# T4b-2: blind path WITH os_user routes the existence probe through'
  printf '%s\n' '# the safe wrapper. We stub iso.subprocess.run to return sudo rc=1'
  printf '%s\n' '# clean stderr (authoritative "absent"), so the first candidate'
  printf '%s\n' '# is returned and no raw `.exists()` ever fires.'
  printf '%s\n' 'stub_t4b2 = SubprocessRunStub(rc=1, stderr="")'
  printf '%s\n' 'original_iso_run = iso.subprocess.run'
  printf '%s\n' 'iso.subprocess.run = stub_t4b2'
  printf '%s\n' 'try:'
  printf '%s\n' '    cand_with_user = bhooks.next_backup_path(blind_orig, "agent-bridge-test")'
  printf '%s\n' '    t4b2_raised = None'
  printf '%s\n' 'except PermissionError as exc:'
  printf '%s\n' '    cand_with_user = None'
  printf '%s\n' '    t4b2_raised = exc'
  printf '%s\n' 'finally:'
  printf '%s\n' '    iso.subprocess.run = original_iso_run'
  printf '%s\n' 'assert t4b2_raised is None, "T4b-2: next_backup_path(blind, os_user) MUST NOT raise PermissionError; got " + repr(t4b2_raised)'
  printf '%s\n' 'assert cand_with_user is not None and ".agent-bridge.bak-" in cand_with_user.name, "T4b-2: expected backup-named candidate; got " + repr(cand_with_user)'
  printf '%s\n' 'assert len(stub_t4b2.calls) >= 1, "T4b-2: subprocess.run must have been called via _safe_path_check sudo branch; got calls=" + repr(stub_t4b2.calls)'
  printf '%s\n' 'argv = stub_t4b2.calls[0][0][0]'
  printf '%s\n' 'assert argv[:4] == ["sudo", "-n", "-u", "agent-bridge-test"], "T4b-2: must invoke sudo -n -u <user>; got argv=" + repr(argv)'
  printf '%s\n' 'print("T4b-2 PASS: next_backup_path(blind, os_user) routes existence probe through proactive sudo (no raw .exists())")'
  printf '%s\n' ''
  printf '%s\n' '# T4b-3: collision loop with os_user still terminates. Stub sudo to'
  printf '%s\n' '# return rc=0 (exists) for first 2 candidates then rc=1 (absent).'
  printf '%s\n' 'class CollisionStub:'
  printf '%s\n' '    def __init__(self):'
  printf '%s\n' '        self.calls = []'
  printf '%s\n' '    def __call__(self, *args, **kwargs):'
  printf '%s\n' '        self.calls.append((args, kwargs))'
  printf '%s\n' '        rc = 0 if len(self.calls) <= 2 else 1'
  printf '%s\n' '        return subprocess.CompletedProcess(args=args[0], returncode=rc, stdout="", stderr="")'
  printf '%s\n' 'stub_collision = CollisionStub()'
  printf '%s\n' 'iso.subprocess.run = stub_collision'
  printf '%s\n' 'try:'
  printf '%s\n' '    cand_collide = bhooks.next_backup_path(blind_orig, "agent-bridge-test")'
  printf '%s\n' 'finally:'
  printf '%s\n' '    iso.subprocess.run = original_iso_run'
  printf '%s\n' 'assert "-2" in cand_collide.name, "T4b-3: after 2 collisions expected -2 suffix; got " + repr(cand_collide.name)'
  printf '%s\n' 'assert len(stub_collision.calls) == 3, "T4b-3: expected 3 sudo probes (collide, collide, free); got calls=" + repr(stub_collision.calls)'
  printf '%s\n' 'print("T4b-3 PASS: next_backup_path collision loop routes every probe through safe wrapper")'
  printf '%s\n' ''
  printf '%s\n' '# ---------- T6: back-compat aliases ----------'
  printf '%s\n' '# Existing #1170 smoke harness stubs `mod._sudo_run_as` on bridge-setup.py.'
  printf '%s\n' '# After #1175 the name is imported from `lib/bridge_iso_paths.py` — the alias'
  printf '%s\n' '# must exist on both sides (the shared module exports it; bridge-setup.py'
  printf '%s\n' '# rebinds it as a module-level name via the `as _sudo_run_as` import alias).'
  printf '%s\n' 'for name in ("_isolated_workdir_owner", "_resolve_isolated_owner_for_path",'
  printf '%s\n' '             "_sudo_run_as", "_safe_path_check", "_safe_read_env",'
  printf '%s\n' '             "_safe_load_json", "_parse_dotenv_text"):'
  printf '%s\n' '    assert hasattr(iso, name), "T6: shared module missing back-compat alias: " + name'
  printf '%s\n' 'for name in ("_isolated_workdir_owner", "_resolve_isolated_owner_for_path",'
  printf '%s\n' '             "_sudo_run_as", "_safe_path_check", "_safe_read_env",'
  printf '%s\n' '             "_safe_load_json", "_parse_dotenv_text"):'
  printf '%s\n' '    assert hasattr(bsetup, name), "T6: bridge-setup.py missing back-compat alias: " + name'
  printf '%s\n' 'for name in ("_isolated_workdir_owner", "_resolve_isolated_owner_for_path",'
  printf '%s\n' '             "_sudo_run_as", "_safe_path_check", "_safe_read_env",'
  printf '%s\n' '             "_safe_load_json"):'
  printf '%s\n' '    assert hasattr(bhooks, name), "T6: bridge-hooks.py missing back-compat alias: " + name'
  printf '%s\n' 'print("T6 PASS: back-compat aliases present on shared module + both importing scripts")'
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
# T5 (boomerang): lint-raw-pathlib-on-isolated catches a NEW raw site.
# ---------------------------------------------------------------------------

LINT_SCRIPT="$REPO_ROOT/scripts/lint-raw-pathlib-on-isolated.sh"
BASELINE_FILE="$REPO_ROOT/scripts/baselines/raw-pathlib-baseline.txt"

[[ -x "$LINT_SCRIPT" ]] || smoke_fail "lint script missing or non-executable: $LINT_SCRIPT"
[[ -f "$BASELINE_FILE" ]] || smoke_fail "baseline file missing: $BASELINE_FILE"

# T5a: self-test PASS
if ! "$LINT_SCRIPT" --self-test >/dev/null 2>&1; then
  smoke_fail "T5a: lint script --self-test FAILED — pattern detection or whitelist filter is broken"
fi
smoke_log "T5a PASS: lint script --self-test (pattern detection + whitelist + comment filter)"

# T5b: baseline check PASS on the current tree.
if ! "$LINT_SCRIPT" --check >/dev/null 2>&1; then
  ACTUAL_OUT="$("$LINT_SCRIPT" --check 2>&1 || true)"
  smoke_fail "T5b: lint --check FAIL on the integration tree — baseline drifted: $ACTUAL_OUT"
fi
smoke_log "T5b PASS: lint --check on the integration tree (count matches baseline)"

# T5c: boomerang. Inject a violating raw `Path('.').exists()` into a
# scratch copy of bridge-setup.py and assert the lint FAILS against it.
# We point the lint at a temporary REPO_ROOT via env-driven baseline file
# so we do not touch the real source tree.
T5_SCRATCH="$SMOKE_TMP_ROOT/scratch-repo"
mkdir -p "$T5_SCRATCH/scripts/baselines" "$T5_SCRATCH/lib"
cp "$REPO_ROOT/bridge-setup.py" "$T5_SCRATCH/bridge-setup.py"
cp "$REPO_ROOT/bridge-hooks.py" "$T5_SCRATCH/bridge-hooks.py"
cp "$REPO_ROOT/scripts/baselines/raw-pathlib-baseline.txt" \
   "$T5_SCRATCH/scripts/baselines/raw-pathlib-baseline.txt"

# Append a violating line at end of bridge-setup.py (top-level call site,
# no whitelist marker → must be counted).
printf '\n# T5 boomerang regression site (smoke-only)\n_violating_probe = Path(".").exists()\n' \
  >>"$T5_SCRATCH/bridge-setup.py"

# Invoke the lint pointed at the scratch tree. Copy the lint script INTO
# the scratch tree first so its SCRIPT_DIR-relative REPO_ROOT resolves
# to the scratch root (the script computes REPO_ROOT as `<script>/..`).
mkdir -p "$T5_SCRATCH/scripts"
cp "$LINT_SCRIPT" "$T5_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh"
chmod +x "$T5_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh"

T5_OUT="$(
  BRIDGE_RAW_PATHLIB_BASELINE_FILE="$T5_SCRATCH/scripts/baselines/raw-pathlib-baseline.txt" \
  "$T5_SCRATCH/scripts/lint-raw-pathlib-on-isolated.sh" --check 2>&1
)"
T5_RC=$?

# The lint MUST have failed (non-zero rc) AND mentioned the violation.
if [[ "$T5_RC" -eq 0 ]]; then
  smoke_fail "T5c boomerang: lint MUST fail when a NEW raw site lands in bridge-setup.py; got rc=$T5_RC, output: $T5_OUT"
fi

# Soft-check: the failure output should mention the bridge-setup.py target.
if [[ "$T5_OUT" != *"bridge-setup.py"* ]]; then
  smoke_fail "T5c boomerang: lint failure output should mention bridge-setup.py; got: $T5_OUT"
fi

smoke_log "T5c PASS (boomerang): lint catches NEW raw \`Path('.').exists()\` injected into bridge-setup.py"

smoke_log "OK"
