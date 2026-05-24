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
# Two-part test:
#   T1a: the helper accepts a `mode` kwarg and a `group` kwarg
#        (signature inspection via Python introspect). A regression
#        that drops the kwargs trips here.
#   T1b: the sudo-as-iso script body contains a `chmod "$2" "$1"`
#        step (static-source assertion against bridge-setup.py).
#        A regression that re-omits the chmod immediately fails.
#   T1c: behavioral — call the helper on a controller-owned target.
#        The helper falls through to Path.mkdir (no isolated owner
#        detected), so the resulting dir lands at the umask-derived
#        mode. The assertion is that the call DID NOT raise, which
#        proves the new signature still accepts a zero-arg call.

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
  printf '%s\n' 'mode_default = sig.parameters["mode"].default'
  printf '%s\n' 'assert mode_default == 0o2750, "mode default expected 0o2750, got " + oct(mode_default)'
  printf '%s\n' 'print("OK")'
} >>"$T1A_HARNESS"

T1A_OUT="$("$PY_BIN" "$T1A_HARNESS" "$REPO_ROOT" 2>&1)" || smoke_fail "T1a harness failed: $T1A_OUT"
[[ "$T1A_OUT" == *"OK"* ]] || smoke_fail "T1a expected 'OK' from signature probe, got: $T1A_OUT"
smoke_log "T1a PASS: _isolation_aware_mkdir signature includes mode + group params (mode default = 0o2750)"

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

# ---------- T5 — Gap 1 behavioral: sudo-script renders chmod arg correctly ----------
#
# When the isolated-owner probe DOES return an owner, the helper
# constructs a sudo argv that includes the rendered mode_oct as $2.
# Mock the subprocess.run + _resolve_isolated_owner_for_path so we
# can inspect the argv shape without actually escalating. This is
# the highest-fidelity test for Gap 1 short of an actual Linux iso
# user fixture (which requires root).

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
  printf '%s\n' 'mod._resolve_isolated_owner_for_path = lambda _p: "agent-bridge-fake"'
  printf '%s\n' 'recorded = []'
  printf '%s\n' 'class FakeCompletedProcess:'
  printf '%s\n' '    def __init__(self, args):'
  printf '%s\n' '        self.args = args'
  printf '%s\n' '        self.returncode = 0'
  printf '%s\n' '        self.stdout = "ab-agent-fake"'
  printf '%s\n' '        self.stderr = ""'
  printf '%s\n' 'def fake_run(argv, check=False, capture_output=False, text=False):'
  printf '%s\n' '    recorded.append(list(argv))'
  printf '%s\n' '    if argv[:2] == ["id", "-gn"]:'
  printf '%s\n' '        # id -gn agent-bridge-fake — return a fake group'
  printf '%s\n' '        return FakeCompletedProcess(argv)'
  printf '%s\n' '    if argv[:3] == ["sudo", "-n", "-u"]:'
  printf '%s\n' '        # sudo -n -u agent-bridge-fake bash -c ... — claim success'
  printf '%s\n' '        return FakeCompletedProcess(argv)'
  printf '%s\n' '    return FakeCompletedProcess(argv)'
  printf '%s\n' 'mod.subprocess.run = fake_run'
  printf '%s\n' 'target = tmp / "iso-channel-dir"'
  printf '%s\n' 'mod._isolation_aware_mkdir(target, mode=0o2750)'
  printf '%s\n' '# Inspect the sudo argv (last call).'
  printf '%s\n' 'sudo_calls = [c for c in recorded if c[:3] == ["sudo", "-n", "-u"]]'
  printf '%s\n' 'assert sudo_calls, "no sudo call recorded: " + repr(recorded)'
  printf '%s\n' 'argv = sudo_calls[-1]'
  printf '%s\n' '# argv shape: sudo -n -u <owner> bash -c <script> bridge-isolation <path> <mode_oct> [<group>]'
  printf '%s\n' 'assert argv[3] == "agent-bridge-fake", "unexpected owner: " + repr(argv)'
  printf '%s\n' 'assert argv[4] == "bash", "expected bash, got: " + repr(argv)'
  printf '%s\n' 'assert argv[5] == "-c", "expected -c, got: " + repr(argv)'
  printf '%s\n' 'script_body = argv[6]'
  printf '%s\n' 'assert "mkdir -p" in script_body, "script body missing mkdir: " + script_body'
  printf '%s\n' 'assert "chmod" in script_body, "script body missing chmod: " + script_body'
  printf '%s\n' 'assert argv[7] == "bridge-isolation", "expected $0 label, got: " + repr(argv)'
  printf '%s\n' 'assert argv[8] == str(target), "expected path as $1, got: " + repr(argv)'
  printf '%s\n' 'assert argv[9] == "2750", "expected mode_oct=2750 as $2, got: " + repr(argv)'
  printf '%s\n' '# Optional group arg only present when id -gn resolved a primary group'
  printf '%s\n' '# (it did, in our stub). assert at $3.'
  printf '%s\n' 'assert argv[10] == "ab-agent-fake", "expected group as $3, got: " + repr(argv)'
  printf '%s\n' 'print("OK")'
} >>"$T5_HARNESS"

T5_TMP="$SMOKE_TMP_ROOT/t5-tree"
mkdir -p "$T5_TMP"
T5_OUT="$("$PY_BIN" "$T5_HARNESS" "$REPO_ROOT" "$T5_TMP" 2>&1)" || smoke_fail "T5 harness failed: $T5_OUT"
[[ "$T5_OUT" == *"OK"* ]] || smoke_fail "T5 expected 'OK', got: $T5_OUT"
smoke_log "T5 PASS: _isolation_aware_mkdir sudo argv carries mode_oct + group args (Gap 1 wire-up correct)"

smoke_log "all tests PASS (#1165 Track A — Gaps 1-4 scaffold/mode widening)"
