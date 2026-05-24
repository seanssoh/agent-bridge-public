#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1120-controller-ops-isolated.sh — Issue #1120.
#
# Pins the contract that controller-side ops over v2-isolated workdirs
# route through privileged helpers instead of leaking PermissionError
# tracebacks (sub-A) or false `missing` values (sub-B).
#
# The bug (#1120) on a Linux v2 install:
#
#   Sub-A. `agent create dev_mun --engine claude --isolation linux-user`
#          fired 6 stacked Python tracebacks on stderr from
#          `bridge-hooks.py:_ensure_dir_with_sudo` even though the
#          create itself exited 0. Root cause: `_isolated_workdir_owner`
#          returned None when the workdir did not exist yet (mid-create,
#          link-shared-settings runs BEFORE `bridge_linux_prepare_agent_
#          isolation` materializes the per-agent workdir), so the
#          function fell into a controller-direct `path.mkdir(parents=
#          True, exist_ok=True)` that the v2 per-agent root
#          (`root:ab-agent-<slug> 2750`) blocks.
#
#   Sub-B. `agent show <iso-agent>` reported
#          `onboarding_state: missing` for an isolated agent whose
#          SESSION-TYPE.md was readable to the isolated UID. Root
#          cause: `bridge_agent_onboarding_state` ran `[[ -f $path ]]`
#          as the controller — which cannot traverse the per-agent
#          root — and short-circuited to `missing`. Downstream
#          watchdog / restart-readiness signals fired re-onboarding
#          decisions on the wrong state.
#
# This smoke is HOST-AGNOSTIC: it does not require Linux + sudo +
# ab-agent-* groups. Instead it exercises the same code paths with
# fixture trees and lookup stubs, asserting the post-fix contract:
#
#   T1. `_isolated_workdir_owner` walks up to the deepest existing
#       ancestor and recovers the isolated UID name from a synthetic
#       `agent-bridge-<slug>` owner (the canonical v2 workdir shape).
#       Pre-fix: lstat on a non-existent path returned None.
#
#   T2. `_isolated_workdir_owner` recovers the isolated UID name from
#       the per-agent ROOT's group when its owner is root (the
#       `root:ab-agent-<slug> 2750` shape). Pre-fix: did not handle
#       this case at all — owner != `agent-bridge-*` → returned None.
#
#   T3. `_ensure_dir_with_sudo` calls `sudo -n -u <iso> mkdir -p
#       <path>` FIRST when iso_user is set (was post-failure
#       fallback before). Verified via a sudo-stub that records the
#       invocation.
#
#   T4. `bridge_agent_onboarding_state` returns `unverifiable`
#       (not `missing`) when the SESSION-TYPE.md candidates are
#       unreadable to the controller AND the iso-UID probe is
#       unavailable (rc=2 from `bridge_isolation_run_as_agent_user_
#       via_bash`). Pre-fix: silently returned `missing`.
#
#   T5. `bridge_agent_onboarding_state` returns the correct state
#       (e.g. `complete`) when the iso-UID probe DOES succeed and
#       reads the line through. Pre-fix: still returned `missing`
#       because the controller `[[ -f ]]` short-circuited before
#       the iso-UID probe ran.
#
# Footgun #11 (heredoc_write deadlock class): the smoke uses
# `printf '%s\n' >file` for every driver, no `<<<` here-strings
# feeding bridge functions, no `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1120-controller-ops-isolated"
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

# ---------- Sub-finding A — _isolated_workdir_owner + _ensure_dir_with_sudo ----

# T1+T2 drive `_isolated_workdir_owner` via a tiny Python harness. We monkey-
# patch `pwd.getpwuid` / `grp.getgrgid` + `os.getuid` so the host's actual
# /etc/passwd content is irrelevant — the test fixture controls every signal
# the helper consults.
T1_T2_HARNESS="$SMOKE_TMP_ROOT/probe-owner.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T1_T2_HARNESS"
# shellcheck disable=SC2129  # explicit per-line emit keeps footgun #11 (heredoc-stdin) off the table
printf '%s\n' 'import os, sys, types' >>"$T1_T2_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T1_T2_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])  # repo root for bridge-hooks.py import' >>"$T1_T2_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T1_T2_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T1_T2_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T1_T2_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T1_T2_HARNESS"
printf '%s\n' '# Force linux platform check to pass — the smoke runs on macOS too' >>"$T1_T2_HARNESS"
printf '%s\n' 'mod.sys.platform = "linux"' >>"$T1_T2_HARNESS"
printf '%s\n' '# Stubs: emulate fixed owner/group lookups for the synthetic v2 tree' >>"$T1_T2_HARNESS"
printf '%s\n' 'import pwd, grp' >>"$T1_T2_HARNESS"
printf '%s\n' 'CONTROLLER_UID = os.getuid()' >>"$T1_T2_HARNESS"
printf '%s\n' 'ISO_UID = CONTROLLER_UID + 50  # not the controller' >>"$T1_T2_HARNESS"
printf '%s\n' 'ROOT_UID = 0' >>"$T1_T2_HARNESS"
printf '%s\n' 'ISO_GID = CONTROLLER_UID + 51' >>"$T1_T2_HARNESS"
printf '%s\n' 'AGENT_SLUG = sys.argv[2]' >>"$T1_T2_HARNESS"
printf '%s\n' 'def fake_getpwuid(uid):' >>"$T1_T2_HARNESS"
printf '%s\n' '    if uid == ISO_UID:' >>"$T1_T2_HARNESS"
printf '%s\n' '        return pwd.struct_passwd(("agent-bridge-" + AGENT_SLUG, "x", uid, ISO_GID, "", "/var/empty", "/usr/sbin/nologin"))' >>"$T1_T2_HARNESS"
printf '%s\n' '    if uid == ROOT_UID:' >>"$T1_T2_HARNESS"
printf '%s\n' '        return pwd.struct_passwd(("root", "x", uid, 0, "", "/root", "/bin/bash"))' >>"$T1_T2_HARNESS"
printf '%s\n' '    raise KeyError(uid)' >>"$T1_T2_HARNESS"
printf '%s\n' 'def fake_getgrgid(gid):' >>"$T1_T2_HARNESS"
printf '%s\n' '    if gid == ISO_GID:' >>"$T1_T2_HARNESS"
# r2 (codex #5726 BLOCKING #2): r1 used the group name to reconstruct the
# isolated user via "ab-agent-<X>" → "agent-bridge-<X>" string replace, but
# user/group truncation strategies diverge for long agent names. The fix
# uses pwd.getpwall() lookup by primary gid instead. Stub a hash-truncated
# group name AND a separately-truncated user name to exercise this gap.
printf '%s\n' '        return grp.struct_group(("ab-agent-" + AGENT_SLUG[:7] + "-65c189b", "x", gid, []))' >>"$T1_T2_HARNESS"
printf '%s\n' '    raise KeyError(gid)' >>"$T1_T2_HARNESS"
printf '%s\n' 'def fake_getpwall():' >>"$T1_T2_HARNESS"
printf '%s\n' '    return [' >>"$T1_T2_HARNESS"
printf '%s\n' '        pwd.struct_passwd(("agent-bridge-" + AGENT_SLUG, "x", ISO_UID, ISO_GID, "", "/var/empty", "/usr/sbin/nologin")),' >>"$T1_T2_HARNESS"
printf '%s\n' '        pwd.struct_passwd(("root", "x", 0, 0, "", "/root", "/bin/bash")),' >>"$T1_T2_HARNESS"
printf '%s\n' '    ]' >>"$T1_T2_HARNESS"
printf '%s\n' 'pwd.getpwuid = fake_getpwuid' >>"$T1_T2_HARNESS"
printf '%s\n' 'pwd.getpwall = fake_getpwall' >>"$T1_T2_HARNESS"
printf '%s\n' 'grp.getgrgid = fake_getgrgid' >>"$T1_T2_HARNESS"
printf '%s\n' '# Stub lstat for arbitrary fixture paths: encode (uid, gid) in a file inside' >>"$T1_T2_HARNESS"
printf '%s\n' '# the path tree. The harness creates real dirs but lstat returns a synthetic' >>"$T1_T2_HARNESS"
printf '%s\n' '# st_uid/st_gid keyed off the per-dir stub file.' >>"$T1_T2_HARNESS"
printf '%s\n' 'real_lstat = Path.lstat' >>"$T1_T2_HARNESS"
printf '%s\n' 'def stub_lstat(self):' >>"$T1_T2_HARNESS"
printf '%s\n' '    s = real_lstat(self)' >>"$T1_T2_HARNESS"
printf '%s\n' '    stub = self / ".smoke-owner"' >>"$T1_T2_HARNESS"
printf '%s\n' '    if stub.exists():' >>"$T1_T2_HARNESS"
printf '%s\n' '        line = stub.read_text().strip().split(":")' >>"$T1_T2_HARNESS"
printf '%s\n' '        uid, gid = int(line[0]), int(line[1])' >>"$T1_T2_HARNESS"
printf '%s\n' '        # Build a stat_result with controlled uid/gid' >>"$T1_T2_HARNESS"
printf '%s\n' '        return os.stat_result((s.st_mode, s.st_ino, s.st_dev, s.st_nlink, uid, gid, s.st_size, s.st_atime, s.st_mtime, s.st_ctime))' >>"$T1_T2_HARNESS"
printf '%s\n' '    return s' >>"$T1_T2_HARNESS"
printf '%s\n' 'Path.lstat = stub_lstat' >>"$T1_T2_HARNESS"
printf '%s\n' 'workdir = Path(sys.argv[3])' >>"$T1_T2_HARNESS"
printf '%s\n' 'result = mod._isolated_workdir_owner(workdir)' >>"$T1_T2_HARNESS"
printf '%s\n' 'print(result or "")' >>"$T1_T2_HARNESS"

# T1 fixture: workdir is owned by `agent-bridge-<slug>` directly (canonical v2)
T1_AGENT="dev_mun_t1"
T1_AGENT_ROOT="$SMOKE_TMP_ROOT/t1/agents/$T1_AGENT"
T1_WORKDIR="$T1_AGENT_ROOT/workdir"
mkdir -p "$T1_WORKDIR"
# Synthesize: workdir is owned by ISO_UID (= controller_uid + 50), group ISO_GID
ISO_UID=$(($(id -u) + 50))
ISO_GID=$(($(id -u) + 51))
printf '%s:%s\n' "$ISO_UID" "$ISO_GID" >"$T1_WORKDIR/.smoke-owner"
T1_OUT="$("$PY_BIN" "$T1_T2_HARNESS" "$REPO_ROOT" "$T1_AGENT" "$T1_WORKDIR" 2>"$SMOKE_TMP_ROOT/t1.err")" \
  || smoke_fail "T1 harness rc=$? — see $SMOKE_TMP_ROOT/t1.err"
[[ "$T1_OUT" == "agent-bridge-$T1_AGENT" ]] \
  || smoke_fail "T1 expected 'agent-bridge-$T1_AGENT', got '$T1_OUT'"
smoke_log "T1 PASS: _isolated_workdir_owner returns iso UID from direct owner"

# T2 fixture: workdir does NOT exist, the parent (per-agent root) is
# root-owned with `ab-agent-<slug>` group (the v2 `root:ab-agent-<slug> 2750`
# shape). The helper must walk up + recover the iso UID via the group.
T2_AGENT="dev_mun_t2"
T2_AGENT_ROOT="$SMOKE_TMP_ROOT/t2/agents/$T2_AGENT"
mkdir -p "$T2_AGENT_ROOT"
# Per-agent root is root-owned, ab-agent-<slug> group
printf '%s:%s\n' "0" "$ISO_GID" >"$T2_AGENT_ROOT/.smoke-owner"
T2_WORKDIR="$T2_AGENT_ROOT/workdir"  # Intentionally NOT mkdir'd
T2_OUT="$("$PY_BIN" "$T1_T2_HARNESS" "$REPO_ROOT" "$T2_AGENT" "$T2_WORKDIR" 2>"$SMOKE_TMP_ROOT/t2.err")" \
  || smoke_fail "T2 harness rc=$? — see $SMOKE_TMP_ROOT/t2.err"
[[ "$T2_OUT" == "agent-bridge-$T2_AGENT" ]] \
  || smoke_fail "T2 expected 'agent-bridge-$T2_AGENT' (group-derived), got '$T2_OUT'"
smoke_log "T2 PASS: _isolated_workdir_owner recovers iso UID from per-agent root group"

# T3 — _ensure_dir_with_sudo invokes sudo-as-iso-user FIRST. We use a stub
# `sudo` wrapper that records argv to a file. Stub returns rc=0 so the
# function should NEVER reach the controller-direct fallback (no traceback,
# no PermissionError).
T3_HARNESS="$SMOKE_TMP_ROOT/probe-ensure.py"
printf '%s\n' '#!/usr/bin/env python3' >"$T3_HARNESS"
# shellcheck disable=SC2129  # explicit per-line emit keeps footgun #11 (heredoc-stdin) off the table
printf '%s\n' 'import os, sys, subprocess' >>"$T3_HARNESS"
printf '%s\n' 'from pathlib import Path' >>"$T3_HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])' >>"$T3_HARNESS"
printf '%s\n' 'import importlib.util' >>"$T3_HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$T3_HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$T3_HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$T3_HARNESS"
printf '%s\n' 'call_log = sys.argv[2]' >>"$T3_HARNESS"
printf '%s\n' 'iso_user = sys.argv[3]' >>"$T3_HARNESS"
printf '%s\n' 'target = sys.argv[4]' >>"$T3_HARNESS"
printf '%s\n' '# Stub _sudo_run_as so it always succeeds AND records its argv.' >>"$T3_HARNESS"
printf '%s\n' 'def fake_sudo_run_as(os_user, *cmd):' >>"$T3_HARNESS"
printf '%s\n' '    with open(call_log, "a") as f:' >>"$T3_HARNESS"
printf '%s\n' '        f.write(repr((os_user,) + cmd) + "\n")' >>"$T3_HARNESS"
printf '%s\n' '    # Actually create the dir so the post-condition check passes' >>"$T3_HARNESS"
printf '%s\n' '    if cmd and cmd[0] == "mkdir":' >>"$T3_HARNESS"
printf '%s\n' '        Path(cmd[-1]).mkdir(parents=True, exist_ok=True)' >>"$T3_HARNESS"
printf '%s\n' '    return 0' >>"$T3_HARNESS"
printf '%s\n' 'mod._sudo_run_as = fake_sudo_run_as' >>"$T3_HARNESS"
# Phase 2 D7 lift: _ensure_dir_with_sudo delegates to bridge_iso_paths.ensure_dir,
# which calls sudo_run_as from its OWN module globals — patching only
# bridge_hooks._sudo_run_as misses the real call site. Patch both so the
# stub fires regardless of which module owns the escalation.
printf '%s\n' 'import importlib' >>"$T3_HARNESS"
printf '%s\n' 'iso_paths = importlib.import_module("bridge_iso_paths")' >>"$T3_HARNESS"
printf '%s\n' 'iso_paths.sudo_run_as = fake_sudo_run_as' >>"$T3_HARNESS"
printf '%s\n' 'mod._ensure_dir_with_sudo(Path(target), iso_user)' >>"$T3_HARNESS"
printf '%s\n' 'print("OK")' >>"$T3_HARNESS"

T3_LOG="$SMOKE_TMP_ROOT/t3.calls"
: >"$T3_LOG"
T3_TARGET="$SMOKE_TMP_ROOT/t3/agents/dev_mun_t3/workdir/.claude"
T3_OUT="$("$PY_BIN" "$T3_HARNESS" "$REPO_ROOT" "$T3_LOG" "agent-bridge-dev_mun_t3" "$T3_TARGET" 2>"$SMOKE_TMP_ROOT/t3.err")" \
  || smoke_fail "T3 harness rc=$? — see $SMOKE_TMP_ROOT/t3.err"
[[ "$T3_OUT" == "OK" ]] || smoke_fail "T3 harness expected 'OK', got: $T3_OUT"
T3_CALLS="$(wc -l <"$T3_LOG" | tr -d ' ')"
[[ "$T3_CALLS" -ge 1 ]] || smoke_fail "T3 expected _sudo_run_as to be called at least once, got $T3_CALLS"
T3_FIRST_LINE="$(head -n 1 "$T3_LOG")"
[[ "$T3_FIRST_LINE" == *"'agent-bridge-dev_mun_t3'"* ]] \
  || smoke_fail "T3 first sudo call missing iso user: $T3_FIRST_LINE"
[[ "$T3_FIRST_LINE" == *"'mkdir'"* ]] \
  || smoke_fail "T3 first sudo call missing 'mkdir': $T3_FIRST_LINE"
smoke_log "T3 PASS: _ensure_dir_with_sudo calls sudo-as-iso-user first (no controller traceback)"

# ---------- Sub-finding B — bridge_agent_onboarding_state ---------------------

# Smoke driver: source the lib + define stubs for the agent helpers we need
# (workdir/default_home + the isolation probe). The function under test
# reads the candidate SESSION-TYPE.md path; the harness sets up two
# variants (T4 unreadable+no-sudo, T5 unreadable+sudo-OK).
T4_T5_DRIVER="$SMOKE_TMP_ROOT/probe-onboarding.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T4_T5_DRIVER"
# shellcheck disable=SC2129  # explicit per-line emit keeps footgun #11 (heredoc-stdin) off the table
printf '%s\n' 'set -uo pipefail' >>"$T4_T5_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"; CASE="$2"; FIXTURE_DIR="$3"' >>"$T4_T5_DRIVER"
printf '%s\n' '# Pull just the bridge_agent_onboarding_state function from bridge-agents.sh' >>"$T4_T5_DRIVER"
printf '%s\n' 'awk_start="^bridge_agent_onboarding_state\\(\\) \\{"' >>"$T4_T5_DRIVER"
printf '%s\n' 'awk "/$awk_start/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh" >"$FIXTURE_DIR/onboarding-fn.sh"' >>"$T4_T5_DRIVER"
printf '%s\n' '# Stubs for the helpers `bridge_agent_onboarding_state` consults.' >>"$T4_T5_DRIVER"
printf '%s\n' 'bridge_agent_workdir() { printf "%s" "$FIXTURE_DIR/workdir"; }' >>"$T4_T5_DRIVER"
printf '%s\n' 'bridge_agent_default_home() { printf "%s" "$FIXTURE_DIR/home"; }' >>"$T4_T5_DRIVER"
printf '%s\n' 'case "$CASE" in' >>"$T4_T5_DRIVER"
printf '%s\n' '  T4)' >>"$T4_T5_DRIVER"
printf '%s\n' '    # Controller-blind candidates + iso UID probe unavailable (rc=2).' >>"$T4_T5_DRIVER"
printf '%s\n' '    bridge_isolation_run_as_agent_user_via_bash() { return 2; }' >>"$T4_T5_DRIVER"
printf '%s\n' '    ;;' >>"$T4_T5_DRIVER"
printf '%s\n' '  T5)' >>"$T4_T5_DRIVER"
printf '%s\n' '    # Controller-blind candidates + iso UID probe succeeds with the' >>"$T4_T5_DRIVER"
printf '%s\n' '    # SESSION-TYPE.md content on stdout (rc=0).' >>"$T4_T5_DRIVER"
printf '%s\n' '    bridge_isolation_run_as_agent_user_via_bash() {' >>"$T4_T5_DRIVER"
printf '%s\n' '      printf "%s\\n" "- Onboarding State: complete"' >>"$T4_T5_DRIVER"
printf '%s\n' '      return 0' >>"$T4_T5_DRIVER"
printf '%s\n' '    }' >>"$T4_T5_DRIVER"
printf '%s\n' '    ;;' >>"$T4_T5_DRIVER"
printf '%s\n' '  *) echo "unknown case: $CASE" >&2; exit 2 ;;' >>"$T4_T5_DRIVER"
printf '%s\n' 'esac' >>"$T4_T5_DRIVER"
printf '%s\n' '# shellcheck disable=SC1091' >>"$T4_T5_DRIVER"
printf '%s\n' 'source "$FIXTURE_DIR/onboarding-fn.sh"' >>"$T4_T5_DRIVER"
printf '%s\n' 'bridge_agent_onboarding_state "$CASE"' >>"$T4_T5_DRIVER"

T4_DIR="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_DIR"
# Intentionally do NOT create SESSION-TYPE.md (`[[ -f ]]` returns false).
T4_RESULT="$("$BRIDGE_BASH" "$T4_T5_DRIVER" "$REPO_ROOT" T4 "$T4_DIR" 2>"$SMOKE_TMP_ROOT/t4.err")" \
  || smoke_fail "T4 driver rc=$? — see $SMOKE_TMP_ROOT/t4.err"
[[ "$T4_RESULT" == "unverifiable" ]] \
  || smoke_fail "T4 expected 'unverifiable' (controller-blind + no sudo), got '$T4_RESULT'"
smoke_log "T4 PASS: bridge_agent_onboarding_state returns 'unverifiable' when controller-blind"

T5_DIR="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_DIR"
T5_RESULT="$("$BRIDGE_BASH" "$T4_T5_DRIVER" "$REPO_ROOT" T5 "$T5_DIR" 2>"$SMOKE_TMP_ROOT/t5.err")" \
  || smoke_fail "T5 driver rc=$? — see $SMOKE_TMP_ROOT/t5.err"
[[ "$T5_RESULT" == "complete" ]] \
  || smoke_fail "T5 expected 'complete' (iso probe returned the line), got '$T5_RESULT'"
smoke_log "T5 PASS: bridge_agent_onboarding_state honors iso-UID probe output"

smoke_log "all 5 tests PASS (#1120)"
