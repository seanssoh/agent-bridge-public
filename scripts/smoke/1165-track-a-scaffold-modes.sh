#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1165-track-a-scaffold-modes.sh — Issue #1165 Track A.
#
# Four scaffold/mode widening gaps in the v2-isolation x Teams plugin
# contract. Each gap was reachable only after the v0.14.5-beta9-13
# isolation cluster closed, but they are pre-existing v2 contract gaps
# not v0.14.5 regressions.
#
# Coverage matrix:
#
#   T1 (Gap 1): `_isolation_aware_mkdir` default mode is 2750 (not 0700);
#               the helper accepts a `mode` parameter; the helper
#               emits the chmod step in its sudo-as-iso script.
#               Static-source assertion + behavioral assertion on a
#               non-isolated host (falls through to Path.mkdir, lands
#               at umask-derived mode — but the new signature is
#               exercised so a regression dropping the mode parameter
#               trips T1).
#
#   T2 (Gap 2): `bridge_linux_prepare_agent_isolation` chmods
#               `~/.claude` to 2770 (not 2750). Static-source assertion
#               against lib/bridge-agents.sh. Boomerang: a revert to
#               2750 immediately fails this smoke.
#
#   T3 (Gap 3): `bridge_install_teams_plugin_node_modules` includes a
#               `chmod -R go+rX node_modules` step after the successful
#               bun install branch. Static-source assertion against
#               lib/bridge-channels.sh.
#
#   T4 (Gap 4): the scaffold sudo-handoff block in `bridge-agent.sh`
#               includes `$BRIDGE_AGENT_HOME_ROOT/$agent` (legacy
#               agents/<X>/) in the chmod 0755 list. Static-source
#               assertion against bridge-agent.sh — the legacy
#               per-agent dir must be normalized in the v2 scaffold
#               isolation-active branch.
#
# Host-agnostic: every assertion is either a static-source grep (T2,
# T3, T4, half of T1) or runs against a non-isolated mkdir target that
# returns no isolated owner (the other half of T1). No sudo or root
# needed.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every driver
# is built with `printf '%s\n' >file` and run as `bash <file>`; no
# `<<<` here-string or `<<EOF` feeds into a bash function; no
# `$(...)` capture of a heredoc-stdin subprocess.

set -uo pipefail

SMOKE_NAME="1165-track-a-scaffold-modes"
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

# Portable mode-read shim (GNU vs BSD stat).
file_mode_octal() {
  local path="$1"
  if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
    stat -f '%Lp' "$path" 2>/dev/null
  else
    stat -c '%a' "$path" 2>/dev/null
  fi
}

# ---------- T1 — _isolation_aware_mkdir: signature + sudo-script shape ----------
#
# Three-part test:
#   T1a: the helper accepts `mode`, `group`, AND `agent` kwargs
#        (signature inspection via Python introspect). A regression
#        that drops `agent` (the v2 group-resolution input — #1165 r2
#        BLOCKING 1) immediately trips here.
#   T1b: the sudo-as-iso script body contains a `chmod "$2" "$1"`
#        step (static-source assertion against bridge-setup.py).
#        A regression that re-omits the chmod immediately fails.
#   T1c: behavioral — call the helper on a controller-owned target.
#        The helper falls through to Path.mkdir (no isolated owner
#        detected), so the resulting dir lands at the umask-derived
#        mode. The assertion is that the call DID NOT raise on the
#        new full signature, proving zero-arg / mode-only / mode+group /
#        mode+group+agent call shapes all parse cleanly.

T1A_HARNESS="$SMOKE_TMP_ROOT/t1a.py"
: >"$T1A_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' 'import sys, inspect, importlib.util'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' 'mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(mod)'
  printf '%s\n' 'sig = inspect.signature(mod._isolation_aware_mkdir)'
  printf '%s\n' 'params = list(sig.parameters.keys())'
  printf '%s\n' 'assert "path" in params, "missing path param: " + repr(params)'
  printf '%s\n' 'assert "mode" in params, "missing mode param: " + repr(params)'
  printf '%s\n' 'assert "group" in params, "missing group param: " + repr(params)'
  printf '%s\n' 'assert "agent" in params, "missing agent param (1165 r2 BLOCKING 1): " + repr(params)'
  printf '%s\n' 'mode_default = sig.parameters["mode"].default'
  printf '%s\n' 'assert mode_default == 0o2750, "mode default expected 0o2750, got " + oct(mode_default)'
  printf '%s\n' '# v2 helper presence check — Python mirror of bridge_isolation_v2_agent_group_name.'
  printf '%s\n' 'assert hasattr(mod, "_v2_agent_group_name"), "missing _v2_agent_group_name helper (1165 r2 BLOCKING 1)"'
  printf '%s\n' 'helper_sig = inspect.signature(mod._v2_agent_group_name)'
  printf '%s\n' 'assert "agent" in helper_sig.parameters, "_v2_agent_group_name missing agent param: " + repr(list(helper_sig.parameters))'
  printf '%s\n' 'print("OK")'
} >>"$T1A_HARNESS"

T1A_OUT="$("$PY_BIN" "$T1A_HARNESS" "$REPO_ROOT" 2>&1)" || smoke_fail "T1a harness failed: $T1A_OUT"
[[ "$T1A_OUT" == *"OK"* ]] || smoke_fail "T1a expected 'OK' from signature probe, got: $T1A_OUT"
smoke_log "T1a PASS: _isolation_aware_mkdir signature includes mode + group + agent params (1165 r2 BLOCKING 1 wire-up present)"

# T1b — static-source assertion on the sudo-script body.
T1B_SOURCE="$REPO_ROOT/bridge-setup.py"
if ! grep -q "'chmod \"\$2\" \"\$1\"'," "$T1B_SOURCE"; then
  smoke_fail "T1b expected sudo-script chmod line in $T1B_SOURCE — missing 'chmod \"\$2\" \"\$1\"' literal"
fi
# Anti-pattern: the pre-#1165 umask-only block must NOT survive.
# That block sandwiched 'mkdir -p "$1"\n' directly between 'umask
# 0077\n' and 'exit 0\n' with NO 'chmod "$2" "$1"\n' line between
# them. Detect the legacy shape with a Python multi-line search
# (portable across GNU / BSD grep — `grep -P` is not on BSD).
if "$PY_BIN" -c '
import sys
src = open(sys.argv[1]).read()
legacy = "umask 0077\\n\x27\n        \x27mkdir -p \"$1\"\\n\x27\n        \x27exit 0\\n\x27"
sys.exit(0 if legacy in src else 1)
' "$T1B_SOURCE" 2>/dev/null; then
  smoke_fail "T1b regression: legacy umask-only sudo block (no chmod) still present in $T1B_SOURCE"
fi
smoke_log "T1b PASS: sudo-script contains chmod step (no regression to umask-only block)"

# T1c — behavioral fall-through (non-isolated host).
T1C_HARNESS="$SMOKE_TMP_ROOT/t1c.py"
: >"$T1C_HARNESS"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' 'import sys, importlib.util'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'tmp = Path(sys.argv[2])'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' 'mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(mod)'
  printf '%s\n' '# Force the isolated-owner probe to return None (controller-owned).'
  printf '%s\n' 'mod._resolve_isolated_owner_for_path = lambda _p: None'
  printf '%s\n' 'target = tmp / "deep" / "tree"'
  printf '%s\n' 'mod._isolation_aware_mkdir(target)'
  printf '%s\n' 'assert target.is_dir(), "target not created: " + str(target)'
  printf '%s\n' 'mod._isolation_aware_mkdir(target, mode=0o2770)'
  printf '%s\n' 'mod._isolation_aware_mkdir(target, mode=0o2770, group="nogroup")'
  printf '%s\n' '# r2: agent= call shape (the v2 helper input).'
  printf '%s\n' 'mod._isolation_aware_mkdir(target, mode=0o2770, agent="fake_agent")'
  printf '%s\n' 'print("OK")'
} >>"$T1C_HARNESS"

T1C_TMP="$SMOKE_TMP_ROOT/t1c-tree"
T1C_OUT="$("$PY_BIN" "$T1C_HARNESS" "$REPO_ROOT" "$T1C_TMP" 2>&1)" || smoke_fail "T1c harness failed: $T1C_OUT"
[[ "$T1C_OUT" == *"OK"* ]] || smoke_fail "T1c expected 'OK', got: $T1C_OUT"
smoke_log "T1c PASS: _isolation_aware_mkdir accepts default + (mode,) + (mode, group) call shapes"

# ---------- T2 — bridge_linux_prepare_agent_isolation: ~/.claude is 2770 ----------
#
# Static-source assertion against lib/bridge-agents.sh. The chmod line
# for `isolated_claude_dir` must read 2770 (not 2750). Boomerang: a
# revert to 2750 trips this immediately.

T2_SOURCE="$REPO_ROOT/lib/bridge-agents.sh"
if grep -q '^  bridge_linux_sudo_root chmod 2750 "$isolated_claude_dir"' "$T2_SOURCE"; then
  smoke_fail "T2 regression: lib/bridge-agents.sh still has 'chmod 2750 \"\$isolated_claude_dir\"' (Gap 2 closed by widening to 2770)"
fi
grep -q '^  bridge_linux_sudo_root chmod 2770 "$isolated_claude_dir"' "$T2_SOURCE" \
  || smoke_fail "T2 expected 'chmod 2770 \"\$isolated_claude_dir\"' line in $T2_SOURCE (Gap 2 widening missing)"
# Sanity: the bridge_die error message should also be updated to match
# the new mode. A stale "chmod 2750" error message points to a
# half-applied edit.
if grep -q 'isolation v2: chmod 2750 on .\$isolated_claude_dir.' "$T2_SOURCE"; then
  smoke_fail "T2 stale error message: lib/bridge-agents.sh still references 'chmod 2750' in bridge_die for isolated_claude_dir"
fi
grep -q 'isolation v2: chmod 2770 on .\$isolated_claude_dir.' "$T2_SOURCE" \
  || smoke_fail "T2 expected bridge_die error message referencing 'chmod 2770' for isolated_claude_dir in $T2_SOURCE"
smoke_log "T2 PASS: ~/.claude chmod widened to 2770 (Gap 2 closed)"

# ---------- T3 — bridge_install_teams_plugin_node_modules: chmod -R go+rX ----------
#
# Static-source assertion against lib/bridge-channels.sh. After the
# `bun install --frozen-lockfile` success branch, the helper must
# call `chmod -R go+rX "$plugin_dir/node_modules"`. Boomerang: a
# revert that drops the chmod (or restricts to mode 0700) trips
# this smoke.

T3_SOURCE="$REPO_ROOT/lib/bridge-channels.sh"
grep -q 'chmod -R go+rX "\$plugin_dir/node_modules"' "$T3_SOURCE" \
  || smoke_fail "T3 expected 'chmod -R go+rX \"\$plugin_dir/node_modules\"' line in $T3_SOURCE (Gap 3 widening missing)"
# Anti-pattern: no `chmod -R go-rwx` or similar restriction on the
# same path (a future hardening attempt that would re-introduce the
# isolated-UID-can't-read bug).
if grep -qE 'chmod -R go-?rwx? "\$plugin_dir/node_modules"' "$T3_SOURCE"; then
  smoke_fail "T3 regression: lib/bridge-channels.sh hardens node_modules back to controller-only (Gap 3 re-opens)"
fi
smoke_log "T3 PASS: post-bun-install chmod -R go+rX present on plugins/teams/node_modules (Gap 3 closed)"

# ---------- T4 — bridge-agent.sh scaffold sudo-handoff covers legacy agents/<X>/ ----------
#
# Static-source assertion against bridge-agent.sh. The v2 scaffold
# isolation-active sudo block (the existing block around lines 681-
# 709 that chmod 0755's _scaffold_v2_root / home / _scaffold_v2_sibling)
# must ALSO normalize the legacy `$BRIDGE_AGENT_HOME_ROOT/$agent` so
# the legacy-teams-mcp pruner and other inventory scanners can stat
# into it from any UID on the box.

T4_SOURCE="$REPO_ROOT/bridge-agent.sh"
# Required line: the new sudo chmod 0755 step on the legacy per-agent root.
grep -q 'bridge_linux_sudo_root chmod 0755 "\$_scaffold_legacy_root"' "$T4_SOURCE" \
  || smoke_fail "T4 expected 'chmod 0755 \"\$_scaffold_legacy_root\"' line in $T4_SOURCE (Gap 4 legacy normalize missing)"
# Required line: the new sudo mkdir + chown alongside it.
grep -q 'bridge_linux_sudo_root mkdir -p "\$_scaffold_legacy_root"' "$T4_SOURCE" \
  || smoke_fail "T4 expected 'mkdir -p \"\$_scaffold_legacy_root\"' line in $T4_SOURCE (Gap 4 pre-create missing)"
grep -q 'bridge_linux_sudo_root chown "\$_scaffold_controller" "\$_scaffold_legacy_root"' "$T4_SOURCE" \
  || smoke_fail "T4 expected 'chown \"\$_scaffold_controller\" \"\$_scaffold_legacy_root\"' line in $T4_SOURCE (Gap 4 chown missing)"
# Required: the legacy root resolves from BRIDGE_AGENT_HOME_ROOT + agent.
grep -q 'local _scaffold_legacy_root="\$BRIDGE_AGENT_HOME_ROOT/\$agent"' "$T4_SOURCE" \
  || smoke_fail "T4 expected '_scaffold_legacy_root=\"\$BRIDGE_AGENT_HOME_ROOT/\$agent\"' assignment in $T4_SOURCE"
# Gate: the new block must live INSIDE the existing isolation-active
# sudo branch so it only fires for v2 linux-user installs.
# Verify the new line is preceded (anywhere earlier in the file) by
# the `_scaffold_isolation_active` gate. This is a structural-shape
# sanity check, not a syntactic guarantee.
grep -q '_scaffold_isolation_active=1' "$T4_SOURCE" \
  || smoke_fail "T4 expected '_scaffold_isolation_active=1' gate to still exist in $T4_SOURCE"
smoke_log "T4 PASS: scaffold sudo block normalizes legacy \$BRIDGE_AGENT_HOME_ROOT/\$agent to 0755 (Gap 4 closed)"

# ---------- T5 — Gap 1 r2: chgrp targets ab-agent-<agent>, NOT id -gn primary ----------
#
# Codex r1 BLOCKING 1: the pre-r2 helper resolved the chgrp target with
# `id -gn <isolated-uid>`. On a v2 install the isolated UID's PRIMARY
# group is whatever `useradd -r` defaulted to (often `users` or a
# per-UID equivalent), NOT `ab-agent-<agent>` — `ab-agent-<agent>` is
# added as a SUPPLEMENTARY group of the isolated UID and the
# controller. So a chgrp to the primary group re-locks the controller
# out of every subsequent os.stat against .teams/.
#
# r2 fix: the helper now accepts an `agent=` kwarg and computes the
# correct supplementary group via _v2_agent_group_name (Python mirror
# of bridge_isolation_v2_agent_group_name). This test stubs `id -gn`
# to return an UNRELATED primary group ('users') and asserts the
# resulting chgrp argv uses `ab-agent-<agent>`, NOT the stubbed
# primary. A regression that re-introduces the id -gn derivation
# trips this immediately because `users` would land at argv[10]
# instead of `ab-agent-fake_agent`.

T5_HARNESS="$SMOKE_TMP_ROOT/t5.py"
: >"$T5_HARNESS"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' 'import sys, subprocess, importlib.util'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'tmp = Path(sys.argv[2])'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' 'mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(mod)'
  printf '%s\n' '# Force the isolated-owner probe to return a fake iso user so the'
  printf '%s\n' '# escalation branch runs.'
  printf '%s\n' 'mod._resolve_isolated_owner_for_path = lambda _p: "agent-bridge-fake_agent"'
  printf '%s\n' 'recorded = []'
  printf '%s\n' 'class FakeCompletedProcess:'
  printf '%s\n' '    def __init__(self, args, stdout=""):'
  printf '%s\n' '        self.args = args'
  printf '%s\n' '        self.returncode = 0'
  printf '%s\n' '        # r2: id -gn returns an UNRELATED primary group (NOT'
  printf '%s\n' '        # ab-agent-fake_agent). If the helper still derives the'
  printf '%s\n' '        # chgrp target from id -gn output, "users" would leak'
  printf '%s\n' '        # into the sudo argv and the assertion below fails.'
  printf '%s\n' '        self.stdout = stdout'
  printf '%s\n' '        self.stderr = ""'
  printf '%s\n' 'def fake_run(argv, check=False, capture_output=False, text=False):'
  printf '%s\n' '    recorded.append(list(argv))'
  printf '%s\n' '    if argv[:2] == ["id", "-gn"]:'
  printf '%s\n' '        # id -gn agent-bridge-fake_agent — return UNRELATED'
  printf '%s\n' '        # primary group (mirrors real v2 useradd -r behavior).'
  printf '%s\n' '        return FakeCompletedProcess(argv, stdout="users")'
  printf '%s\n' '    if argv[:3] == ["sudo", "-n", "-u"]:'
  printf '%s\n' '        # sudo -n -u agent-bridge-fake_agent bash -c ... — claim success'
  printf '%s\n' '        return FakeCompletedProcess(argv)'
  printf '%s\n' '    return FakeCompletedProcess(argv)'
  printf '%s\n' 'mod.subprocess.run = fake_run'
  printf '%s\n' 'target = tmp / "iso-channel-dir"'
  printf '%s\n' '# r2: pass agent="fake_agent" — the v2 helper should resolve to'
  printf '%s\n' '# "ab-agent-fake_agent" and the chgrp arg should NOT be "users".'
  printf '%s\n' 'mod._isolation_aware_mkdir(target, mode=0o2750, agent="fake_agent")'
  printf '%s\n' '# Inspect the sudo argv (last call).'
  printf '%s\n' 'sudo_calls = [c for c in recorded if c[:3] == ["sudo", "-n", "-u"]]'
  printf '%s\n' 'assert sudo_calls, "no sudo call recorded: " + repr(recorded)'
  printf '%s\n' 'argv = sudo_calls[-1]'
  printf '%s\n' '# argv shape: sudo -n -u <owner> bash -c <script> bridge-isolation <path> <mode_oct> [<group>]'
  printf '%s\n' 'assert argv[3] == "agent-bridge-fake_agent", "unexpected owner: " + repr(argv)'
  printf '%s\n' 'assert argv[4] == "bash", "expected bash, got: " + repr(argv)'
  printf '%s\n' 'assert argv[5] == "-c", "expected -c, got: " + repr(argv)'
  printf '%s\n' 'script_body = argv[6]'
  printf '%s\n' 'assert "mkdir -p" in script_body, "script body missing mkdir: " + script_body'
  printf '%s\n' 'assert "chmod" in script_body, "script body missing chmod: " + script_body'
  printf '%s\n' 'assert argv[7] == "bridge-isolation", "expected $0 label, got: " + repr(argv)'
  printf '%s\n' 'assert argv[8] == str(target), "expected path as $1, got: " + repr(argv)'
  printf '%s\n' 'assert argv[9] == "2750", "expected mode_oct=2750 as $2, got: " + repr(argv)'
  printf '%s\n' '# r2 BLOCKING 1 assertion: chgrp target must be the v2'
  printf '%s\n' '# ab-agent-<agent> group (controller-readable supplementary),'
  printf '%s\n' '# NOT the id -gn primary ("users" in this stub). A regression'
  printf '%s\n' '# to id -gn derivation lands "users" at argv[10] and trips here.'
  printf '%s\n' 'assert argv[10] == "ab-agent-fake_agent", "r2 BLOCKING 1 regression: chgrp arg should be ab-agent-fake_agent (v2 helper), got " + repr(argv[10])'
  printf '%s\n' 'assert "users" not in argv, "r2 BLOCKING 1 regression: id -gn primary group leaked into sudo argv: " + repr(argv)'
  printf '%s\n' '# r2: id -gn should NOT be invoked when agent= resolves the v2'
  printf '%s\n' '# group successfully (priority: explicit group > v2 helper > id'
  printf '%s\n' '# -gn fallback). A regression that re-introduces id -gn as the'
  printf '%s\n' '# primary path would record an ["id", "-gn", ...] call here.'
  printf '%s\n' 'id_calls = [c for c in recorded if c[:2] == ["id", "-gn"]]'
  printf '%s\n' 'assert not id_calls, "r2 BLOCKING 1 regression: id -gn was invoked even though agent= was set: " + repr(id_calls)'
  printf '%s\n' 'print("OK")'
} >>"$T5_HARNESS"

T5_TMP="$SMOKE_TMP_ROOT/t5-tree"
mkdir -p "$T5_TMP"
T5_OUT="$("$PY_BIN" "$T5_HARNESS" "$REPO_ROOT" "$T5_TMP" 2>&1)" || smoke_fail "T5 harness failed: $T5_OUT"
[[ "$T5_OUT" == *"OK"* ]] || smoke_fail "T5 expected 'OK', got: $T5_OUT"
smoke_log "T5 PASS: _isolation_aware_mkdir chgrp targets v2 ab-agent-<agent> (NOT id -gn primary) — r2 BLOCKING 1 closed"

# ---------- T6 — _v2_agent_group_name: Python mirror correctness ----------
#
# r2 BLOCKING 1: the v2 helper is a pure-Python mirror of the bash
# bridge_isolation_v2_agent_group_name (lib/bridge-isolation-v2.sh:406-460).
# Both sides must compose the same group name for the same agent name on
# the same platform — otherwise the controller's `os.stat` on the
# chgrp'd dir mismatches the supplementary group it was added to by the
# bash grant path.
#
# Coverage:
#   - Short name -> ab-agent-<agent> (no truncation needed)
#   - Long name (>23 chars on Linux) -> hash-truncated form
#   - Invalid chars -> None (matches bash `return 1`)
#   - Empty name -> None

T6_HARNESS="$SMOKE_TMP_ROOT/t6.py"
: >"$T6_HARNESS"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' 'import sys, importlib.util, hashlib'
  printf '%s\n' 'repo = sys.argv[1]'
  printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_setup", repo + "/bridge-setup.py")'
  printf '%s\n' 'mod = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(mod)'
  printf '%s\n' '# Short name — no truncation needed. Both linux and darwin paths'
  printf '%s\n' '# pass the composition through unchanged for <= 32 chars.'
  printf '%s\n' 'assert mod._v2_agent_group_name("patch") == "ab-agent-patch", "short-name composition failed: " + repr(mod._v2_agent_group_name("patch"))'
  printf '%s\n' '# Invalid chars — must return None (matches bash regex reject).'
  printf '%s\n' 'assert mod._v2_agent_group_name("Has-Uppercase") is None, "Uppercase should reject"'
  printf '%s\n' '_dash_out = mod._v2_agent_group_name("-starts-with-dash")'
  printf '%s\n' 'assert _dash_out is None, "dash-prefix anchor should reject (got " + repr(_dash_out) + ")"'
  printf '%s\n' 'assert mod._v2_agent_group_name("has space") is None, "space should reject"'
  printf '%s\n' 'assert mod._v2_agent_group_name("") is None, "empty should reject"'
  printf '%s\n' '# Linux path: long name -> hash-truncated. ab-agent- prefix = 9 chars,'
  printf '%s\n' '# leaves 23 for the agent segment. A 30-char agent overflows; the'
  printf '%s\n' '# linux helper should compose ab-agent-<head>-<hash>.'
  printf '%s\n' 'if sys.platform != "darwin":'
  printf '%s\n' '    long_name = "a_very_long_agent_name_for_test"  # 30 chars'
  printf '%s\n' '    out = mod._v2_agent_group_name(long_name)'
  printf '%s\n' '    assert out is not None, "long-name truncation should not return None"'
  printf '%s\n' '    assert len(out) <= 32, "truncated group name exceeds 32 chars: " + repr(out)'
  printf '%s\n' '    assert out.startswith("ab-agent-"), "missing prefix: " + repr(out)'
  printf '%s\n' '    expected_hash = hashlib.sha256(long_name.encode()).hexdigest()[:7]'
  printf '%s\n' '    assert out.endswith("-" + expected_hash), "hash suffix mismatch: expected ...-" + expected_hash + ", got " + repr(out)'
  printf '%s\n' 'print("OK")'
} >>"$T6_HARNESS"

T6_OUT="$("$PY_BIN" "$T6_HARNESS" "$REPO_ROOT" 2>&1)" || smoke_fail "T6 harness failed: $T6_OUT"
[[ "$T6_OUT" == *"OK"* ]] || smoke_fail "T6 expected 'OK', got: $T6_OUT"
smoke_log "T6 PASS: _v2_agent_group_name mirrors bash helper (short + long + invalid)"

# ---------- T3b — Gap 3 r2: idempotent chmod runs even when node_modules pre-exists ----------
#
# Codex r1 BLOCKING 2: the original Gap 3 fix only chmod'd after a
# fresh `bun install`. When node_modules already exists (the common
# case on a re-run of `agb setup teams`), the helper early-returns
# BEFORE the chmod, so a pre-existing tree created with controller
# umask 077 stays unreadable to isolated UIDs and
# bridge-dev-plugin-cache.py still fails on `Permission denied`.
#
# r2 fix: the chmod runs unconditionally before the early-return. This
# test (purely static-source) verifies the chmod call appears BEFORE
# the "already present — skipping bun install" early-return so the
# idempotent path is covered.

T3B_SOURCE="$REPO_ROOT/lib/bridge-channels.sh"
T3B_HARNESS="$SMOKE_TMP_ROOT/t3b.py"
: >"$T3B_HARNESS"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' 'import sys, re'
  printf '%s\n' 'src = open(sys.argv[1]).read()'
  printf '%s\n' '# Locate the bridge_install_teams_plugin_node_modules function body.'
  printf '%s\n' '# Boundary: starts at the function decl, ends at the first ^} at column 0.'
  printf '%s\n' 'm = re.search(r"^bridge_install_teams_plugin_node_modules\(\)[^{]*\{(.*?)^\}", src, re.DOTALL | re.MULTILINE)'
  printf '%s\n' 'assert m, "could not find bridge_install_teams_plugin_node_modules function body"'
  printf '%s\n' 'body = m.group(1)'
  printf '%s\n' '# Locate the actual early-return command line — the bridge_info'
  printf '%s\n' '# "[setup] ... already present — skipping bun install" + return 0'
  printf '%s\n' '# combo. Substring matches inside comment blocks must NOT be the'
  printf '%s\n' '# first hit (the comment block also discusses "already present"'
  printf '%s\n' '# as part of the design rationale).'
  printf '%s\n' 'early_re = re.compile(r"^\s*bridge_info \"\[setup\] \$plugin_dir/node_modules already present", re.MULTILINE)'
  printf '%s\n' 'early_match = early_re.search(body)'
  printf '%s\n' 'assert early_match, "missing bridge_info early-return announcement"'
  printf '%s\n' 'early_idx = early_match.start()'
  printf '%s\n' '# Locate the chmod command line — match a real bash invocation,'
  printf '%s\n' '# not a substring inside a comment block (a `# chmod -R go+rX ...`'
  printf '%s\n' '# explainer comment would otherwise be the first hit).'
  printf '%s\n' 'chmod_re = re.compile(r"^\s*(if !\s*)?chmod -R go\+rX \"\$plugin_dir/node_modules\"", re.MULTILINE)'
  printf '%s\n' 'chmod_matches = list(chmod_re.finditer(body))'
  printf '%s\n' 'assert chmod_matches, "missing chmod -R go+rX command line in function body"'
  printf '%s\n' 'first_chmod_idx = chmod_matches[0].start()'
  printf '%s\n' '# r2 assertion: at least one chmod command must precede the'
  printf '%s\n' '# early-return announcement. If the chmod ONLY appears after'
  printf '%s\n' '# the bridge_info early-return, the idempotent path (existing'
  printf '%s\n' '# node_modules) skips chmod entirely — the r1 bug.'
  printf '%s\n' 'assert first_chmod_idx < early_idx, "r2 BLOCKING 2 regression: chmod -R go+rX command appears AFTER the bridge_info early-return; idempotent path skipped (chmod cmd at %d, early-return at %d)" % (first_chmod_idx, early_idx)'
  printf '%s\n' 'print("OK")'
} >>"$T3B_HARNESS"

T3B_OUT="$("$PY_BIN" "$T3B_HARNESS" "$T3B_SOURCE" 2>&1)" || smoke_fail "T3b harness failed: $T3B_OUT"
[[ "$T3B_OUT" == *"OK"* ]] || smoke_fail "T3b expected 'OK', got: $T3B_OUT"
smoke_log "T3b PASS: chmod -R go+rX runs on idempotent (pre-existing node_modules) path — r2 BLOCKING 2 closed"

# ---------- T3c — Gap 3 r2 behavioral: chmod actually widens pre-existing tree ----------
#
# Beyond the static-source check, exercise the actual function body
# against a fixture: pre-create a node_modules/ tree with restrictive
# modes (dirs 0700, files 0600) and call the helper. Assert post-call
# modes are widened (group + other have read/traverse).

T3C_DRIVER="$SMOKE_TMP_ROOT/t3c.sh"
: >"$T3C_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'repo="$1"'
  printf '%s\n' 'fixture="$2"'
  printf '%s\n' '# Mock BRIDGE_SCRIPT_DIR + bridge_resolve_script_dir_check so the'
  printf '%s\n' '# helper points at our fixture instead of the real repo. We need'
  printf '%s\n' '# the function code without its dependencies on the rest of the'
  printf '%s\n' '# channel module — source bridge-channels.sh under a controlled'
  printf '%s\n' '# environment.'
  printf '%s\n' 'BRIDGE_SCRIPT_DIR="$fixture"'
  printf '%s\n' 'export BRIDGE_SCRIPT_DIR'
  printf '%s\n' '# Stub the dependencies the helper needs from bridge-core.sh /'
  printf '%s\n' '# bridge-channels.sh internals.'
  printf '%s\n' 'bridge_info() { printf "[info] %s\n" "$*"; }'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_resolve_script_dir_check() { [[ -n "$BRIDGE_SCRIPT_DIR" ]]; }'
  printf '%s\n' 'bridge_resolve_bun_executable() { return 1; }  # not exercised on idempotent path'
  printf '%s\n' 'export -f bridge_info bridge_warn bridge_resolve_script_dir_check bridge_resolve_bun_executable'
  printf '%s\n' '# Source just the function definition by extracting it. Simpler'
  printf '%s\n' '# than sourcing all of bridge-channels.sh (which would pull in'
  printf '%s\n' '# more transitive deps).'
  printf '%s\n' 'tmp_fn="$(mktemp -t t3c-fn-XXXXXX.sh)"'
  printf '%s\n' 'trap '"'"'rm -f "$tmp_fn"'"'"' EXIT'
  printf '%s\n' 'awk '"'"'/^bridge_install_teams_plugin_node_modules\(\)/,/^\}/'"'"' "$repo/lib/bridge-channels.sh" >"$tmp_fn"'
  printf '%s\n' '# shellcheck disable=SC1090'
  printf '%s\n' 'source "$tmp_fn"'
  printf '%s\n' '# Run the function; should hit the idempotent branch (node_modules exists).'
  printf '%s\n' 'bridge_install_teams_plugin_node_modules 0 ""'
} >>"$T3C_DRIVER"
chmod +x "$T3C_DRIVER"

T3C_FIXTURE="$SMOKE_TMP_ROOT/t3c-fixture"
mkdir -p "$T3C_FIXTURE/plugins/teams/node_modules/.bin"
mkdir -p "$T3C_FIXTURE/plugins/teams/node_modules/some-pkg/lib"
: >"$T3C_FIXTURE/plugins/teams/node_modules/.bin/some-bin"
: >"$T3C_FIXTURE/plugins/teams/node_modules/some-pkg/lib/index.js"
chmod 0700 "$T3C_FIXTURE/plugins/teams/node_modules" "$T3C_FIXTURE/plugins/teams/node_modules/.bin" "$T3C_FIXTURE/plugins/teams/node_modules/some-pkg" "$T3C_FIXTURE/plugins/teams/node_modules/some-pkg/lib"
chmod 0600 "$T3C_FIXTURE/plugins/teams/node_modules/.bin/some-bin" "$T3C_FIXTURE/plugins/teams/node_modules/some-pkg/lib/index.js"

T3C_OUT="$(bash "$T3C_DRIVER" "$REPO_ROOT" "$T3C_FIXTURE" 2>&1)" || smoke_fail "T3c driver failed: $T3C_OUT"

# Assert post-call modes are widened. `chmod -R go+rX` should land:
#   - dirs: 0700 -> 0755 (group + other get rx)
#   - regular files: 0600 -> 0644 (group + other get r, no x because
#     the file had no execute bit)
post_root_mode="$(file_mode_octal "$T3C_FIXTURE/plugins/teams/node_modules")"
post_bin_dir_mode="$(file_mode_octal "$T3C_FIXTURE/plugins/teams/node_modules/.bin")"
post_bin_mode="$(file_mode_octal "$T3C_FIXTURE/plugins/teams/node_modules/.bin/some-bin")"
post_js_mode="$(file_mode_octal "$T3C_FIXTURE/plugins/teams/node_modules/some-pkg/lib/index.js")"
[[ "$post_root_mode" == "755" ]] \
  || smoke_fail "T3c idempotent chmod missed root node_modules dir: expected 755, got $post_root_mode"
[[ "$post_bin_dir_mode" == "755" ]] \
  || smoke_fail "T3c idempotent chmod missed .bin dir: expected 755, got $post_bin_dir_mode"
[[ "$post_bin_mode" == "644" ]] \
  || smoke_fail "T3c idempotent chmod missed .bin file: expected 644, got $post_bin_mode"
[[ "$post_js_mode" == "644" ]] \
  || smoke_fail "T3c idempotent chmod missed nested file: expected 644, got $post_js_mode"
smoke_log "T3c PASS: idempotent path actually widens pre-existing 0700/0600 tree to 0755/0644"

smoke_log "all tests PASS (#1165 Track A r2 — Gaps 1-4 + r2 BLOCKING 1/2)"
