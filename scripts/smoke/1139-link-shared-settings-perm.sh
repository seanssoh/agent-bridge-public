#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1139-link-shared-settings-perm.sh — Issue #1139.
#
# Beta7 follow-up to #1120 (PR #1133). Two regressions reproduced on a
# fresh v0.14.5-beta7 install (Linux, linux-user isolation):
#
#   Sub-A. `agent create <a> --engine claude --isolation linux-user
#          --always-on yes` still emits stacked PermissionError
#          tracebacks from `cmd_link_shared_settings →
#          _ensure_dir_with_sudo`. The failing target (`.claude/`)
#          is `agent-bridge-<a>:<controller-gid> mode 0700` — uid
#          maps to `agent-bridge-<a>` but gid is the controller's
#          group (not `ab-agent-<a>`). PR #1133's gid-based
#          `getpwall()` enumeration finds no `agent-bridge-*` user
#          whose PRIMARY gid matches the controller's gid, so
#          `_isolated_workdir_owner` returns None and the function
#          falls back to a controller-direct `path.mkdir(...)` that
#          re-raises PermissionError.
#
#          Fix: uid-first lookup. Trust `pwd.getpwuid(st_uid).pw_name`
#          unconditionally when it starts with `agent-bridge-` —
#          uid alone is the identity signal; gid is irrelevant when
#          uid already names the isolated UID.
#
#   Sub-B. `agent show <a>` reports `onboarding_state: complete` for
#          a half-scaffolded workdir whose SESSION-TYPE.md parses to
#          `complete` but where one or more canonical markers
#          (CLAUDE.md / SOUL.md / MEMORY.md / MEMORY-SCHEMA.md) are
#          missing. `setup agent` (via `bridge-setup.sh`) flags the
#          half-scaffold correctly. `bridge_agent_onboarding_state`
#          and `setup agent` must agree on the same agent.
#
#          Fix: after parsing the state from SESSION-TYPE.md,
#          `bridge_agent_onboarding_state` checks the canonical
#          marker set in the same dir. Missing marker(s) downgrade
#          `complete` → `partial`. The marker probe uses the same
#          controller-first / iso-UID-fallback trust path as the
#          SESSION-TYPE.md read.
#
# This smoke is HOST-AGNOSTIC: it runs on macOS dev hosts too
# (forces `sys.platform = "linux"` inside the Python harness; uses
# fixture trees + stubs for the iso-UID helper).
#
# Footgun #11 (heredoc_write deadlock class): every driver is built
# with `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash
# functions; no `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1139-link-shared-settings-perm"
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

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# ---------- T1 — Sub-A: uid-first lookup, controller-gid on workdir ---------

# Drives `_isolated_workdir_owner` against a synthetic workdir whose
# st_uid maps to `agent-bridge-<slug>` but whose st_gid is the
# controller's gid (NOT `ab-agent-<slug>`). Pre-fix this fell through
# to the gid-based getpwall() enumeration, found no match, and
# returned None. Post-fix uid-first returns the iso UID immediately.
T1_HARNESS="$SMOKE_TMP_ROOT/probe-uid-first.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T1_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 (heredoc-stdin) off the table
printf '%s\n' 'import os, sys' >>"$T1_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T1_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])  # repo root for bridge-hooks.py import' >>"$T1_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T1_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T1_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T1_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T1_HARNESS"
printf '%s\n' '# Force linux platform check to pass — smoke runs on macOS dev hosts too' >>"$T1_HARNESS"
printf '%s\n' 'mod.sys.platform = "linux"' >>"$T1_HARNESS"
printf '%s\n' 'import pwd' >>"$T1_HARNESS"
printf '%s\n' 'CONTROLLER_UID = os.getuid()' >>"$T1_HARNESS"
printf '%s\n' 'CONTROLLER_GID = os.getgid()  # the failing scenario'  >>"$T1_HARNESS"
printf '%s\n' 'ISO_UID = CONTROLLER_UID + 50  # not the controller' >>"$T1_HARNESS"
printf '%s\n' 'ISO_GID_REAL = CONTROLLER_UID + 51  # the iso group (NOT on workdir)' >>"$T1_HARNESS"
printf '%s\n' 'AGENT_SLUG = sys.argv[2]' >>"$T1_HARNESS"
printf '%s\n' 'def fake_getpwuid(uid):' >>"$T1_HARNESS"
printf '%s\n' '    if uid == ISO_UID:' >>"$T1_HARNESS"
printf '%s\n' '        return pwd.struct_passwd(("agent-bridge-" + AGENT_SLUG, "x", uid, ISO_GID_REAL, "", "/var/empty", "/usr/sbin/nologin"))' >>"$T1_HARNESS"
printf '%s\n' '    raise KeyError(uid)' >>"$T1_HARNESS"
printf '%s\n' 'def fake_getpwall():' >>"$T1_HARNESS"
printf '%s\n' '    # Critically, NO entry has PRIMARY gid == CONTROLLER_GID. So if the' >>"$T1_HARNESS"
printf '%s\n' '    # function falls into gid-based enumeration with the workdir gid, it' >>"$T1_HARNESS"
printf '%s\n' '    # will find nothing and return None. The uid-first branch is what' >>"$T1_HARNESS"
printf '%s\n' '    # makes T1 pass.' >>"$T1_HARNESS"
printf '%s\n' '    return [' >>"$T1_HARNESS"
printf '%s\n' '        pwd.struct_passwd(("agent-bridge-" + AGENT_SLUG, "x", ISO_UID, ISO_GID_REAL, "", "/var/empty", "/usr/sbin/nologin")),' >>"$T1_HARNESS"
printf '%s\n' '    ]' >>"$T1_HARNESS"
printf '%s\n' 'pwd.getpwuid = fake_getpwuid' >>"$T1_HARNESS"
printf '%s\n' 'pwd.getpwall = fake_getpwall' >>"$T1_HARNESS"
printf '%s\n' 'real_lstat = Path.lstat' >>"$T1_HARNESS"
printf '%s\n' 'def stub_lstat(self):' >>"$T1_HARNESS"
printf '%s\n' '    s = real_lstat(self)' >>"$T1_HARNESS"
printf '%s\n' '    stub = self / ".smoke-owner"' >>"$T1_HARNESS"
printf '%s\n' '    if stub.exists():' >>"$T1_HARNESS"
printf '%s\n' '        line = stub.read_text().strip().split(":")' >>"$T1_HARNESS"
printf '%s\n' '        uid, gid = int(line[0]), int(line[1])' >>"$T1_HARNESS"
printf '%s\n' '        return os.stat_result((s.st_mode, s.st_ino, s.st_dev, s.st_nlink, uid, gid, s.st_size, s.st_atime, s.st_mtime, s.st_ctime))' >>"$T1_HARNESS"
printf '%s\n' '    return s' >>"$T1_HARNESS"
printf '%s\n' 'Path.lstat = stub_lstat' >>"$T1_HARNESS"
printf '%s\n' 'workdir = Path(sys.argv[3])' >>"$T1_HARNESS"
printf '%s\n' 'result = mod._isolated_workdir_owner(workdir)' >>"$T1_HARNESS"
printf '%s\n' 'print(result or "")' >>"$T1_HARNESS"

T1_AGENT="dev_mun"
T1_AGENT_ROOT="$SMOKE_TMP_ROOT/t1/agents/$T1_AGENT"
T1_WORKDIR="$T1_AGENT_ROOT/workdir"
mkdir -p "$T1_WORKDIR"
# Synthesize the failing v0.14.5-beta7 owner combo:
#   uid = ISO_UID  (agent-bridge-<slug>)
#   gid = CONTROLLER_GID  (NOT ab-agent-<slug> — the actual bug shape)
ISO_UID=$(($(id -u) + 50))
CONTROLLER_GID=$(id -g)
printf '%s:%s\n' "$ISO_UID" "$CONTROLLER_GID" >"$T1_WORKDIR/.smoke-owner"
T1_OUT="$("$PY_BIN" "$T1_HARNESS" "$REPO_ROOT" "$T1_AGENT" "$T1_WORKDIR" 2>"$SMOKE_TMP_ROOT/t1.err")" \
  || smoke_fail "T1 harness rc=$? — see $SMOKE_TMP_ROOT/t1.err"
[[ "$T1_OUT" == "agent-bridge-$T1_AGENT" ]] \
  || smoke_fail "T1 expected 'agent-bridge-$T1_AGENT' (uid-first), got '$T1_OUT' — pre-fix returned None when gid != ab-agent-<slug>"
smoke_log "T1 PASS: _isolated_workdir_owner uid-first returns iso UID when gid=controller's"

# ---------- T2 — Sub-A: _ensure_dir_with_sudo no PermissionError when iso_user set --

# When uid-first detection returns the iso user (T1's contract),
# `_ensure_dir_with_sudo` calls sudo-as-iso first. Stub sudo so it
# actually creates the dir. The function must NOT raise PermissionError
# (the original #1139 traceback). Asserts the call-order contract.
T2_HARNESS="$SMOKE_TMP_ROOT/probe-ensure.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T2_HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'import os, sys' >>"$T2_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T2_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])' >>"$T2_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T2_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T2_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T2_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T2_HARNESS"
printf '%s\n' 'call_log = sys.argv[2]' >>"$T2_HARNESS"
printf '%s\n' 'iso_user = sys.argv[3]' >>"$T2_HARNESS"
printf '%s\n' 'target = sys.argv[4]' >>"$T2_HARNESS"
printf '%s\n' 'def fake_sudo_run_as(os_user, *cmd):' >>"$T2_HARNESS"
printf '%s\n' '    with open(call_log, "a") as f:' >>"$T2_HARNESS"
printf '%s\n' '        f.write(repr((os_user,) + cmd) + "\n")' >>"$T2_HARNESS"
printf '%s\n' '    if cmd and cmd[0] == "mkdir":' >>"$T2_HARNESS"
printf '%s\n' '        Path(cmd[-1]).mkdir(parents=True, exist_ok=True)' >>"$T2_HARNESS"
printf '%s\n' '    return 0' >>"$T2_HARNESS"
printf '%s\n' 'mod._sudo_run_as = fake_sudo_run_as' >>"$T2_HARNESS"
# Phase 2 D7 lift: _ensure_dir_with_sudo delegates to bridge_iso_paths.ensure_dir,
# which calls sudo_run_as from its own module globals — patch both sites.
printf '%s\n' 'import importlib' >>"$T2_HARNESS"
printf '%s\n' 'iso_paths = importlib.import_module("bridge_iso_paths")' >>"$T2_HARNESS"
printf '%s\n' 'iso_paths.sudo_run_as = fake_sudo_run_as' >>"$T2_HARNESS"
printf '%s\n' 'try:' >>"$T2_HARNESS"
printf '%s\n' '    mod._ensure_dir_with_sudo(Path(target), iso_user)' >>"$T2_HARNESS"
printf '%s\n' '    print("OK")' >>"$T2_HARNESS"
printf '%s\n' 'except PermissionError as e:' >>"$T2_HARNESS"
printf '%s\n' '    print("PERMERR:" + repr(e))' >>"$T2_HARNESS"
printf '%s\n' '    sys.exit(1)' >>"$T2_HARNESS"

T2_LOG="$SMOKE_TMP_ROOT/t2.calls"
: >"$T2_LOG"
T2_TARGET="$SMOKE_TMP_ROOT/t2/agents/$T1_AGENT/workdir/.claude"
T2_OUT="$("$PY_BIN" "$T2_HARNESS" "$REPO_ROOT" "$T2_LOG" "agent-bridge-$T1_AGENT" "$T2_TARGET" 2>"$SMOKE_TMP_ROOT/t2.err")" \
  || smoke_fail "T2 harness rc=$? — see $SMOKE_TMP_ROOT/t2.err (output: $T2_OUT)"
[[ "$T2_OUT" == "OK" ]] || smoke_fail "T2 expected 'OK', got: $T2_OUT"
T2_FIRST_LINE="$(head -n 1 "$T2_LOG" 2>/dev/null || printf '')"
[[ "$T2_FIRST_LINE" == *"'agent-bridge-$T1_AGENT'"* ]] \
  || smoke_fail "T2 first sudo call missing iso user '$T1_AGENT': $T2_FIRST_LINE"
[[ "$T2_FIRST_LINE" == *"'mkdir'"* ]] \
  || smoke_fail "T2 first sudo call missing 'mkdir': $T2_FIRST_LINE"
[[ -d "$T2_TARGET" ]] || smoke_fail "T2 target dir was not created via sudo stub: $T2_TARGET"
smoke_log "T2 PASS: _ensure_dir_with_sudo sudo-as-iso succeeds when uid-first detection returns the iso user"

# ---------- T3 — Sub-B: bridge_agent_onboarding_state returns partial when markers missing --

# Drives `bridge_agent_onboarding_state` against a fixture workdir
# whose SESSION-TYPE.md parses to `complete` but which is missing
# one or more canonical markers (CLAUDE.md / SOUL.md / MEMORY.md /
# MEMORY-SCHEMA.md). Pre-fix the function returned `complete` —
# matching `agent show`'s false-positive. Post-fix the marker check
# downgrades to `partial`.
T3_DRIVER="$SMOKE_TMP_ROOT/probe-onboarding.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T3_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T3_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"; FIXTURE_DIR="$2"' >>"$T3_DRIVER"
printf '%s\n' '# Extract the helper + main fn from bridge-agents.sh. Both are bounded by' >>"$T3_DRIVER"
printf '%s\n' '# `^bridge_agent_onboarding_markers_complete() {` / `^bridge_agent_onboarding_state() {`' >>"$T3_DRIVER"
printf '%s\n' '# and a leading `^}`.' >>"$T3_DRIVER"
printf '%s\n' 'awk "/^bridge_agent_onboarding_markers_complete\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh" >"$FIXTURE_DIR/helper-fn.sh"' >>"$T3_DRIVER"
printf '%s\n' 'awk "/^bridge_agent_onboarding_state\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh" >"$FIXTURE_DIR/state-fn.sh"' >>"$T3_DRIVER"
printf '%s\n' '# Stubs: workdir + default_home resolve to the fixture tree. iso UID probe' >>"$T3_DRIVER"
printf '%s\n' '# is intentionally NOT declared so the controller `[[ -f ]]` path is what' >>"$T3_DRIVER"
printf '%s\n' '# reads the markers (matches a non-isolated agent / dev host).' >>"$T3_DRIVER"
printf '%s\n' 'bridge_agent_workdir() { printf "%s" "$FIXTURE_DIR/workdir"; }' >>"$T3_DRIVER"
printf '%s\n' 'bridge_agent_default_home() { printf "%s" "$FIXTURE_DIR/home"; }' >>"$T3_DRIVER"
printf '%s\n' '# shellcheck disable=SC1091' >>"$T3_DRIVER"
printf '%s\n' 'source "$FIXTURE_DIR/helper-fn.sh"' >>"$T3_DRIVER"
printf '%s\n' '# shellcheck disable=SC1091' >>"$T3_DRIVER"
printf '%s\n' 'source "$FIXTURE_DIR/state-fn.sh"' >>"$T3_DRIVER"
printf '%s\n' 'bridge_agent_onboarding_state "smoke-agent"' >>"$T3_DRIVER"

T3_DIR="$SMOKE_TMP_ROOT/t3"
T3_WORKDIR="$T3_DIR/workdir"
mkdir -p "$T3_WORKDIR"
# SESSION-TYPE.md parses to `complete` but CLAUDE.md / SOUL.md / etc.
# are missing (the half-scaffolded shape). Per #1139 sub-B, the
# returned state must downgrade to `partial`.
printf '%s\n' '- Onboarding State: complete' >"$T3_WORKDIR/SESSION-TYPE.md"

T3_RESULT="$("$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_DIR" 2>"$SMOKE_TMP_ROOT/t3.err")" \
  || smoke_fail "T3 driver rc=$? — see $SMOKE_TMP_ROOT/t3.err"
[[ "$T3_RESULT" == "partial" ]] \
  || smoke_fail "T3 expected 'partial' (half-scaffolded), got '$T3_RESULT' — pre-fix returned 'complete' (false-positive)"
smoke_log "T3 PASS: bridge_agent_onboarding_state returns 'partial' when canonical markers missing"

# ---------- T4 — Sub-B regression guard: complete with all markers stays complete --

# Same driver as T3 but with all five canonical markers present
# alongside SESSION-TYPE.md. The marker check must NOT spuriously
# downgrade a genuine `complete` state.
T4_DIR="$SMOKE_TMP_ROOT/t4"
T4_WORKDIR="$T4_DIR/workdir"
mkdir -p "$T4_WORKDIR"
printf '%s\n' '- Onboarding State: complete' >"$T4_WORKDIR/SESSION-TYPE.md"
for _marker in CLAUDE.md SOUL.md MEMORY.md MEMORY-SCHEMA.md; do
  printf '%s\n' "marker stub" >"$T4_WORKDIR/$_marker"
done

T4_RESULT="$("$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T4_DIR" 2>"$SMOKE_TMP_ROOT/t4.err")" \
  || smoke_fail "T4 driver rc=$? — see $SMOKE_TMP_ROOT/t4.err"
[[ "$T4_RESULT" == "complete" ]] \
  || smoke_fail "T4 expected 'complete' (all markers present), got '$T4_RESULT' — marker check should not regress"
smoke_log "T4 PASS: bridge_agent_onboarding_state keeps 'complete' when all canonical markers present"

smoke_log "all 4 tests PASS (#1139)"
