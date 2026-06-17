#!/usr/bin/env bash
# scripts/smoke/1945-iso-restart-settings-iso-uid.sh — issue #1945 (cm-prod F7).
#
# `agent restart <iso-bot> --no-attach` re-renders the per-agent
# `settings.effective.json` on every start (via the bridge_ensure_claude_*_hook
# chain → bridge_link_claude_settings_to_shared in lib/bridge-hooks.sh). On a v2
# linux-user-isolated install the render target resolves to
# `$BRIDGE_AGENT_ROOT_V2/<agent>/home/.claude/settings.effective.json`, and that
# `home/` tree is owned by the ISOLATED UID (mode 2770) per the prepare contract.
# The pre-fix code rendered straight into that path with a bare controller-UID
# pathlib write (`render-shared-settings` → bridge-hooks.py save_json:
# parent.mkdir + open `.tmp` + rename). When the controller is not the owner and
# lacks a LIVE supplementary-group cache for `ab-agent-<a>` (KNOWN_ISSUES §28 /
# #1207) that write raises `PermissionError [Errno 13]` on
# `settings.effective.json.tmp`, and the restart aborts the plugin reseed.
#
# THE FIX (lib/bridge-hooks.sh, bridge_link_claude_settings_to_shared): for an
# iso v2 agent, render into a controller-owned mktemp STAGE, then
# `bridge_linux_sudo_root install`/`mv` the staged file into the final iso-owned
# path under root — mirroring the existing bridge_install_isolated_home_settings
# publish pattern. Shared / non-isolated agents keep the direct render (byte-for-
# byte unchanged). The render never writes the iso-owned effective dir as the
# controller, so the restart no longer EACCESes.
#
# Cases (temp dir; never touches live runtime). v2 isolation is Linux-only, so
# the iso predicate + sudo escalation are STUBBED: the iso-effective predicate is
# pinned ON, and bridge_linux_sudo_root is replaced with a spy that records its
# argv and runs the op directly as the test user (the same direct fall-through
# the real helper takes off-Linux / as root). The real
# bridge_link_claude_settings_to_shared function is exercised end to end.
#
#   T1  ISO agent: render-shared-settings targets a STAGE path under TMPDIR
#       (NOT the iso-owned effective_file), the final effective_file is placed
#       via a sudo-backed `install`/`mv`, and the file exists with the rendered
#       content. Proves the controller never bare-writes the iso-owned dir.
#   T2  ISO agent + sudo absent: when bridge_linux_sudo_root cannot escalate the
#       function FAILS LOUD (rc != 0) instead of silently falling back to a
#       controller-direct write that re-denies.
#   T3  SHARED (non-iso) agent: the iso branch is NOT taken — render-shared-
#       settings writes the effective_file DIRECTLY (no stage, no sudo install).
#       Regression guard that the non-iso path is byte-for-byte unchanged.
#   T4  ISO agent whose iso-owned `.claude` is a SYMLINK: the function REFUSES
#       the root mkdir/install/mv (return 1) and never writes through the link.
#       Guards the iso-UID symlink-redirect escalation.
#
# Footgun #11 mitigation: zero heredoc-stdin to a subprocess (the harness body
# is written to a temp .sh with `cat > file` then run via `bash <file>`).

set -uo pipefail

SMOKE_NAME="1945-iso-restart-settings-iso-uid"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# The render target for an iso agent resolves to
# $BRIDGE_AGENT_ROOT_V2/<agent>/home/.claude/settings.effective.json. Lay down a
# minimal shared base + overlay so the real renderer has inputs.
BASE_FILE="$SMOKE_TMP_ROOT/settings.base.json"
OVERLAY_FILE="$SMOKE_TMP_ROOT/settings.overlay.json"
printf '{}\n' >"$BASE_FILE"
printf '{}\n' >"$OVERLAY_FILE"

# Run bridge_link_claude_settings_to_shared in a subshell with the real lib
# sourced and a focused set of stubs. $1=agent $2=iso(1/0) $3=sudo_ok(1/0)
# $4=workdir $5=effective_file. Writes spy lines (render_eff=, sudo=, link_rc=)
# to $SPY_LOG.
#
# NB: bridge_link_claude_settings_to_shared declares its OWN `local agent`,
# `local effective_file`, `local workdir`, etc. Bash dynamic scoping means a
# stub reading those bare names from inside the call would see the function's
# (partially-assigned) locals — not our fixture values. So all passthrough
# state goes through uniquely-named `_S1945_*` globals the stubs read directly.
# The harness body that sources the real lib, installs focused stubs, and drives
# bridge_link_claude_settings_to_shared once. It is written to a standalone temp
# script and executed with a fresh `bash <file>` (NOT a `( )` subshell): the
# smoke parent carries an EXIT-cleanup trap, and sourcing bridge-lib.sh performs
# an `exec` fd-redirect that, inside a same-process subshell, leaks the parent's
# stdout into the capture file. A separate `bash` process fully isolates
# fd/trap/exec state so the capture is clean. All inputs arrive via exported
# _S1945_* env (no dynamic-scope collision with the function's own
# `local agent`/`effective_file`). Spy markers print to STDOUT with a `SPY:`
# prefix; every assertion greps for that prefix so lib source noise is harmless.
BODY_SCRIPT="$SMOKE_TMP_ROOT/run-body.sh"
cat >"$BODY_SCRIPT" <<'BODY'
set +e
# shellcheck disable=SC1090
source "$REPO_ROOT/bridge-lib.sh"

bridge_hook_shared_settings_base_file() { printf '%s' "$_S1945_BASE"; }
bridge_hook_shared_settings_overlay_file() { printf '%s' "$_S1945_OVERLAY"; }
bridge_hook_operator_global_settings_file() { printf ''; }
bridge_hook_per_agent_settings_effective_file() { printf '%s' "$_S1945_EFF"; }
bridge_hook_per_agent_settings_effective_file_v1() { printf '%s' "$_S1945_EFF"; }
bridge_hook_paths_equal() { [[ "$1" == "$2" ]] && printf '1' || printf '0'; }
bridge_agent_workdir_step_a_complete() { return 0; }

if [[ "$_S1945_ISO" == "1" ]]; then
  bridge_agent_linux_user_isolation_effective() { return 0; }
else
  bridge_agent_linux_user_isolation_effective() { return 1; }
fi

# #1766 group-publish helpers: pinned-on enforce + group resolver to the
# operator's own group so the publish does not fail the run; the publish itself
# is not what this smoke asserts.
bridge_isolation_v2_enforce() { return 0; }
bridge_isolation_v2_agent_group_name() { id -gn 2>/dev/null || printf 'staff'; }

# Spy on bridge_hooks_python: emit the render-shared-settings effective target to
# STDOUT, and for render-shared-settings actually write the JSON so the
# downstream install has a real staged file. Other subcommands no-op.
bridge_hooks_python() {
  local _sub="$1"; shift
  if [[ "$_sub" == "render-shared-settings" ]]; then
    local _eff=""
    local -a _a=("$@")
    local _i
    for ((_i = 0; _i < ${#_a[@]}; _i++)); do
      if [[ "${_a[$_i]}" == "--effective-settings-file" ]]; then
        _eff="${_a[$((_i + 1))]}"
      fi
    done
    printf 'SPY:render_eff=%s\n' "$_eff"
    if [[ -n "$_eff" ]]; then
      mkdir -p "${_eff%/*}" 2>/dev/null || true
      printf '{"_rendered":true}\n' >"$_eff" 2>/dev/null || true
    fi
    return 0
  fi
  return 0
}

# Spy on bridge_linux_sudo_root: emit argv to STDOUT. When sudo_ok, run the op
# directly as the test user (the real helper's off-Linux / as-root fall-
# through). When NOT sudo_ok, simulate `sudo -n` refusal (rc 1, no-op).
if [[ "$_S1945_SUDO_OK" == "1" ]]; then
  bridge_linux_sudo_root() { printf 'SPY:sudo=%s\n' "$*"; "$@"; }
else
  bridge_linux_sudo_root() { printf 'SPY:sudo_denied=%s\n' "$*"; return 1; }
fi

bridge_link_claude_settings_to_shared "$_S1945_WORKDIR" "" "$_S1945_AGENT"
printf 'SPY:link_rc=%s\n' "$?"
BODY

run_link() {
  _S1945_AGENT="$1"
  _S1945_ISO="$2"
  _S1945_SUDO_OK="$3"
  _S1945_WORKDIR="$4"
  _S1945_EFF="$5"
  local out_log="$6"
  export _S1945_AGENT _S1945_ISO _S1945_SUDO_OK _S1945_WORKDIR _S1945_EFF
  export _S1945_BASE="$BASE_FILE" _S1945_OVERLAY="$OVERLAY_FILE" REPO_ROOT
  bash "$BODY_SCRIPT" >"$out_log" 2>&1
}

# Out-of-tree log dir for subshell stdout capture (kept OUT of $SMOKE_TMP_ROOT
# so it is independent of the bridge-home fixtures; cleaned with the temp root's
# sibling on trap exit via its own mktemp under TMPDIR).
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-1945-logs.XXXXXX")"

# =====================================================================
# T1 — ISO agent: staged render + sudo install, never a bare write into the
#      iso-owned effective dir.
# =====================================================================
T1_AGENT="isobot"
T1_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$T1_AGENT/workdir"
T1_EFF="$BRIDGE_AGENT_ROOT_V2/$T1_AGENT/home/.claude/settings.effective.json"
mkdir -p "$T1_WORKDIR" "${T1_EFF%/*}"
T1_LOG="$LOG_DIR/t1.log"
run_link "$T1_AGENT" 1 1 "$T1_WORKDIR" "$T1_EFF" "$T1_LOG"
smoke_assert_contains "$(cat "$T1_LOG")" "SPY:link_rc=0" "T1 link rc=0"
# The final effective file must be placed via a sudo-backed install/mv whose
# SOURCE is a controller-owned `bridge-shared-settings.*` STAGE — NOT a bare
# controller render straight into the iso-owned effective_file (the EACCES bug).
T1_INSTALL="$(grep '^SPY:sudo=install -m 0600 ' "$T1_LOG" | head -n1)"
[[ -n "$T1_INSTALL" ]] || smoke_fail "T1 FAIL — no sudo-backed staged install of the effective settings"
# Layout: `SPY:sudo=install -m 0600 <stage_src> <iso_dest_tmp>`.
T1_STAGE_SRC="$(printf '%s\n' "$T1_INSTALL" | awk '{print $(NF-1)}')"
case "$T1_STAGE_SRC" in
  */bridge-shared-settings.*/settings.effective.json)
    : ;;
  *)
    smoke_fail "T1 FAIL — install source is not a controller-owned stage: $T1_STAGE_SRC" ;;
esac
[[ "$T1_STAGE_SRC" != "$T1_EFF" ]] \
  || smoke_fail "T1 FAIL — render wrote the iso-owned effective_file DIRECTLY; the controller-write EACCES is unfixed"
grep -q '^SPY:sudo=mv -f ' "$T1_LOG" || smoke_fail "T1 FAIL — no sudo-backed atomic mv of the effective settings"
[[ -f "$T1_EFF" ]] || smoke_fail "T1 FAIL — effective settings not placed at $T1_EFF"
grep -q '_rendered' "$T1_EFF" || smoke_fail "T1 FAIL — effective settings content not the rendered payload"
smoke_log "T1 PASS — iso render staged under TMPDIR + sudo-installed to the iso home; no bare controller write"

# =====================================================================
# T2 — ISO agent + sudo escalation denied: FAIL LOUD, do not silently fall
#      back to a controller-direct write.
# =====================================================================
T2_AGENT="isobot2"
T2_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$T2_AGENT/workdir"
T2_EFF="$BRIDGE_AGENT_ROOT_V2/$T2_AGENT/home/.claude/settings.effective.json"
mkdir -p "$T2_WORKDIR" "${T2_EFF%/*}"
T2_LOG="$LOG_DIR/t2.log"
run_link "$T2_AGENT" 1 0 "$T2_WORKDIR" "$T2_EFF" "$T2_LOG"
smoke_assert_not_contains "$(cat "$T2_LOG")" "SPY:link_rc=0" "T2 link must NOT report success when sudo is denied"
grep -q '^SPY:link_rc=' "$T2_LOG" || smoke_fail "T2 FAIL — function did not return at all"
T2_RC="$(grep '^SPY:link_rc=' "$T2_LOG" | head -n1 | cut -d= -f2-)"
[[ "$T2_RC" != "0" ]] || smoke_fail "T2 FAIL — function returned 0 despite sudo denial (silent fallback)"
[[ ! -f "$T2_EFF" ]] || smoke_fail "T2 FAIL — effective settings were written despite sudo denial (controller-direct fallback)"
smoke_log "T2 PASS — iso render fails loud (rc=$T2_RC) when sudo escalation is denied"

# =====================================================================
# T3 — SHARED (non-iso) agent: direct render, no stage, no sudo install.
# =====================================================================
T3_AGENT="sharedbot"
T3_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$T3_AGENT/workdir"
T3_EFF="$BRIDGE_AGENT_HOME_ROOT/$T3_AGENT/.claude/settings.effective.json"
mkdir -p "$T3_WORKDIR" "${T3_EFF%/*}"
T3_LOG="$LOG_DIR/t3.log"
run_link "$T3_AGENT" 0 1 "$T3_WORKDIR" "$T3_EFF" "$T3_LOG"
smoke_assert_contains "$(cat "$T3_LOG")" "SPY:link_rc=0" "T3 shared link rc=0"
# Non-iso branch: the render writes the effective_file DIRECTLY (the stub writes
# the JSON in place), and there is NO sudo-backed staged install — i.e. the iso
# staging path was not taken (byte-for-byte unchanged behavior).
smoke_assert_not_contains "$(cat "$T3_LOG")" "SPY:sudo=install -m 0600" "T3 shared agent must NOT sudo-install (direct render)"
smoke_assert_not_contains "$(cat "$T3_LOG")" "bridge-shared-settings." "T3 shared agent must NOT use a render stage"
[[ -f "$T3_EFF" ]] || smoke_fail "T3 FAIL — shared agent effective settings not written directly at $T3_EFF"
grep -q '_rendered' "$T3_EFF" || smoke_fail "T3 FAIL — shared effective settings content not the rendered payload"
smoke_log "T3 PASS — shared (non-iso) agent renders directly; iso staging path not taken"

# =====================================================================
# T4 — ISO agent whose iso-owned `.claude` dir is a SYMLINK: the function must
#      REFUSE the root write (return 1) and NOT write through the link. Guards
#      the iso-UID symlink-redirect escalation (codex review). The link points
#      at an out-of-tree target; assert the target is never written.
# =====================================================================
T4_AGENT="isobot4"
T4_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$T4_AGENT/workdir"
T4_HOME="$BRIDGE_AGENT_ROOT_V2/$T4_AGENT/home"
T4_EVIL="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-1945-evil.XXXXXX")"
mkdir -p "$T4_WORKDIR" "$T4_HOME"
# Plant an attacker-style symlink at the iso `.claude` dir aimed outside the tree.
ln -s "$T4_EVIL" "$T4_HOME/.claude"
T4_EFF="$T4_HOME/.claude/settings.effective.json"
T4_LOG="$LOG_DIR/t4.log"
run_link "$T4_AGENT" 1 1 "$T4_WORKDIR" "$T4_EFF" "$T4_LOG"
smoke_assert_not_contains "$(cat "$T4_LOG")" "SPY:link_rc=0" "T4 must NOT succeed when .claude is a symlink"
T4_RC="$(grep '^SPY:link_rc=' "$T4_LOG" | head -n1 | cut -d= -f2-)"
[[ "$T4_RC" != "0" ]] || smoke_fail "T4 FAIL — function returned 0 despite a symlinked iso .claude (redirect not refused)"
smoke_assert_not_contains "$(cat "$T4_LOG")" "SPY:sudo=install -m 0600" "T4 must NOT install through the symlink"
[[ ! -e "$T4_EVIL/settings.effective.json" ]] \
  || smoke_fail "T4 FAIL — root write FOLLOWED the symlink into '$T4_EVIL' (iso-UID redirect)"
rm -rf "$T4_EVIL"
smoke_log "T4 PASS — symlinked iso .claude refused; no root write through the link"

rm -rf "$LOG_DIR"

smoke_log "ALL PASS — #1945 iso restart settings render is staged + sudo-installed, fails loud, shared path unchanged"
