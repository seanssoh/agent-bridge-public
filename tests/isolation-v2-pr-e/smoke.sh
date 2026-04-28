#!/usr/bin/env bash
# tests/isolation-v2-pr-e/smoke.sh
#
# Acceptance test for PR-E. See top of file in PR-E plan-review r5/r6
# for the full case list. The smoke drives the REAL helpers from
# `lib/bridge-agents.sh`, `lib/bridge-isolation-v2.sh`, and
# `bridge-run.sh` (helper definition copied inline because the smoke
# cannot run the full bridge-run.sh entrypoint).
#
# Each case is a function; a small dispatcher sets up the v2 (or
# legacy) subshell, sources bridge-lib.sh, installs a sudo-wrapper
# stub that logs argv, and invokes the case body. Subshell isolation
# is via `( ... )` parens, which inherit functions defined in the
# parent.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log()  { printf '[v2-pr-e] %s\n' "$*"; }
die()  { printf '[v2-pr-e][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[v2-pr-e][skip] %s\n' "$*"; exit 0; }
ok()   { printf '[v2-pr-e] ok: %s\n' "$*"; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required"
fi
command -v python3 >/dev/null 2>&1 || skip "python3 missing"

TMP_ROOT="$(mktemp -d -t isolation-v2-pr-e.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT
export TMPDIR="${TMPDIR:-/tmp}"
export BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1

# Issue #403 (#406): redirect the isolated-user home root into the
# TMP_ROOT so even if a test passes an os_user that collides with a
# real account, the destructive paths land in our tempdir, not
# /home/<user>. Consumed by bridge_agent_linux_user_home() in
# lib/bridge-agents.sh. Per-case run_in_v2/run_in_legacy fixtures
# below set this again with case-scoped values, but the top-level
# default keeps any direct (non-fixture) helper call safe.
mkdir -p "$TMP_ROOT/fake-home"
export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$TMP_ROOT/fake-home"
mkdir -p "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/agb-smoke-fake-user"

# PR-E r3 P1 (this PR): a global refuse-log captures every
# [sudo-stub][refuse] line emitted by any case body. Cases that do NOT
# opt in (the default) fail at end-of-run if the log is non-empty — a
# refused live-install write must never be silently masked by a positive
# log assertion. Cases that explicitly want to assert refusal must check
# + truncate this log themselves.
SUDO_REFUSE_LOG="$TMP_ROOT/sudo-stub-refuse.log"
: >"$SUDO_REFUSE_LOG"
export SUDO_REFUSE_LOG

# ---------------------------------------------------------------------------
# Subshell helpers — caller passes a function NAME (defined in this
# script) and we invoke it after wiring up the lib + sudo stub.
# ---------------------------------------------------------------------------

# Stub bridge_linux_sudo_root — log argv to $_BRIDGE_LINUX_SUDO_LOG_FILE,
# pass through benign filesystem ops, swallow setfacl. The log path is
# stored in a non-local variable because bash binds variable references
# at call time, not at function-definition time, so a `local log` would
# be out of scope when the stub is invoked later.
#
# Issue #403 fix #2 — sudo stub TMP_ROOT path guard: rm/ln/mkdir/etc
# pass-through paths must be inside $TMP_ROOT. The previous stub passed
# any path through, which combined with a controller-shaped os_user in
# CT4 (fix #3) wiped the operator's live install. Anything that escapes
# TMP_ROOT now logs a [refuse] line and returns 99.
make_sudo_stub() {
  _BRIDGE_LINUX_SUDO_LOG_FILE="$1"
  _BRIDGE_LINUX_SUDO_ALLOWED_PREFIX="${TMP_ROOT:?make_sudo_stub: TMP_ROOT must be set}"
  _BRIDGE_LINUX_SUDO_REFUSE_LOG="${SUDO_REFUSE_LOG:?make_sudo_stub: SUDO_REFUSE_LOG must be set}"
  bridge_linux_sudo_root() {
    printf '%s\n' "$*" >>"$_BRIDGE_LINUX_SUDO_LOG_FILE"
    # Issue #403 (#406): refuse to exec a destructive op when ANY
    # positional arg looks like an absolute path outside $TMP_ROOT.
    # Belt-and-suspenders against helper code paths that compute paths
    # from os_user. `test` is left in its own arm because its args may
    # be non-path predicates; mktemp/python3 may receive non-path args
    # (caught by the leading-`/` filter). Refusals are also persisted
    # to $SUDO_REFUSE_LOG so end-of-run assertion can fail the smoke
    # if any case body silently relied on the guard (PR-E r3 P1).
    local _arg _tmp_canon _tmp_raw _arg_canon
    _tmp_raw="${TMP_ROOT:-}"
    _tmp_canon="$(readlink -f "$_tmp_raw" 2>/dev/null)"
    [[ -z "$_tmp_canon" ]] && _tmp_canon="$_tmp_raw"
    for _arg in "$@"; do
      case "$_arg" in
        /*)
          # Accept the arg if either its raw or its resolved form is rooted
          # under TMP_ROOT (raw or canonical). On macOS, readlink -f returns
          # empty for nonexistent paths, so the raw match is required to
          # avoid spurious rejection of valid TMP_ROOT-relative ops on files
          # that don't yet exist when the stub runs.
          _arg_canon="$(readlink -f "$_arg" 2>/dev/null)"
          [[ -z "$_arg_canon" ]] && _arg_canon="$_arg"
          case "$_arg_canon" in
            "$_tmp_canon"|"$_tmp_canon"/*|"$_tmp_raw"|"$_tmp_raw"/*) continue ;;
          esac
          case "$_arg" in
            "$_tmp_canon"|"$_tmp_canon"/*|"$_tmp_raw"|"$_tmp_raw"/*) continue ;;
          esac
          local _refuse_msg
          _refuse_msg="$(printf '[smoke][sudo-stub][refuse] %s with arg %s outside TMP_ROOT %s (issue #403)' \
            "$1" "$_arg" "$_tmp_canon")"
          printf '%s\n' "$_refuse_msg" >&2
          printf '%s\n' "$_refuse_msg" >>"$_BRIDGE_LINUX_SUDO_REFUSE_LOG"
          return 99
          ;;
      esac
    done
    case "${1:-}" in
      # Filesystem state ops we want to exercise — the case body asserts
      # post-conditions like mode/existence after these run.
      test) shift; test "$@" ;;
      mkdir|chmod|touch|ln|rm|mv|find|mktemp|python3) "$@" ;;
      # chown/chgrp need root in real life. The smoke is rootless, so
      # we only want them in the sudo log (for grep-on-log assertions).
      # Skip the actual call. Failure of a real chgrp to a non-existent
      # group would otherwise wipe out the v2 fail-fast we validate.
      chown|chgrp) return 0 ;;
      setfacl) return 0 ;;
      bash) shift; bash "$@" ;;  # pass-through for `bash -lc 'command -v setfacl'`
      *) return 0 ;;
    esac
  }
}

# PR-E r3 P1: clear EVERY inherited BRIDGE_* env var before sourcing
# bridge-lib.sh, then re-export only the ones the fixture needs. The
# previous fixture only reset BRIDGE_HOME/BRIDGE_LAYOUT/BRIDGE_DATA_ROOT
# and a handful of v2 roots; vars like BRIDGE_ACTIVE_AGENT_DIR,
# BRIDGE_STATE_DIR, BRIDGE_LOG_DIR, BRIDGE_AGENT_HOME_ROOT, etc. carried
# over from the operator shell (or a parent test runner) and silently
# steered helpers at the live install. Two preserved exceptions:
#   - SUDO_REFUSE_LOG: the global refuse-log path the sudo stub writes
#     to; needs to outlive the subshell so end-of-run assertion sees it.
#   - TMPDIR: posix-standard, not bridge-owned; preserved.
_smoke_clear_bridge_env() {
  local _var
  while read -r _var; do
    [[ -n "$_var" ]] || continue
    case "$_var" in
      # Caller-prefixed test hooks must survive the mass unset — they're
      # the fixture's own knobs, not host state. Add new ones here as
      # cases evolve; never expand the list to host-driven vars.
      BRIDGE_RUN_UMASK_PROBE_FILE) continue ;;
      BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING) continue ;;
    esac
    unset "$_var" 2>/dev/null || true
  done < <(compgen -v BRIDGE_ 2>/dev/null || true)
}

run_in_v2() {
  local case_dir="$1"; shift
  local sudo_log="$1"; shift
  local fn="$1"; shift
  (
    set -e
    _smoke_clear_bridge_env
    export BRIDGE_HOME="$case_dir/bridge-home"
    export BRIDGE_LAYOUT="v2"
    export BRIDGE_DATA_ROOT="$case_dir/data"
    # Issue #403 fix #3: pin BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT under
    # TMP_ROOT so any helper that builds `<root>/<os_user>/.agent-bridge`
    # cannot resolve to the controller's $HOME, even if a future case
    # forgets and uses a controller-shaped os_user. The default `/home`
    # is what got us into the live-install wipe.
    export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$case_dir/iso-users"
    mkdir -p "$BRIDGE_HOME" "$BRIDGE_DATA_ROOT/agents" \
             "$BRIDGE_DATA_ROOT/shared" "$BRIDGE_DATA_ROOT/state" \
             "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"
    make_sudo_stub "$sudo_log"
    "$fn" "$@"
  )
}

run_in_legacy() {
  local case_dir="$1"; shift
  local sudo_log="$1"; shift
  local fn="$1"; shift
  (
    set -e
    _smoke_clear_bridge_env
    export BRIDGE_HOME="$case_dir/bridge-home"
    export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$case_dir/iso-users"
    mkdir -p "$BRIDGE_HOME" "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"
    make_sudo_stub "$sudo_log"
    "$fn" "$@"
  )
}

assert_no_setfacl() {
  local sudo_log="$1"
  local context="${2:-}"
  if grep -qE '(^|find .* -exec )setfacl' "$sudo_log"; then
    printf '[v2-pr-e][error] %s: expected zero setfacl calls but found:\n' "$context" >&2
    grep -nE 'setfacl' "$sudo_log" >&2 || true
    return 1
  fi
}

assert_some_setfacl() {
  local sudo_log="$1"
  local context="${2:-}"
  if ! grep -qE '(^|find .* -exec )setfacl' "$sudo_log"; then
    printf '[v2-pr-e][error] %s: expected at least one setfacl call but found none\n' "$context" >&2
    return 1
  fi
}

# Inline copy of bridge_run_apply_v2_umask_if_needed — keeps the smoke
# self-contained without sourcing bridge-run.sh (which has top-level
# argv parsing). Drift between this copy and the real helper is itself
# something the smoke catches, because the underlying contract
# (`bridge_isolation_v2_active && bridge_agent_linux_user_isolation_effective`
# → umask 007) is what gets tested.
smoke_bridge_run_apply_v2_umask_if_needed() {
  local agent="$1"
  if bridge_isolation_v2_active 2>/dev/null \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    umask 007
  fi
  if [[ -n "${BRIDGE_RUN_UMASK_PROBE_FILE:-}" ]]; then
    umask >"$BRIDGE_RUN_UMASK_PROBE_FILE" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# P1: ACL primitive helpers no-op in v2 mode
# ---------------------------------------------------------------------------
case_p1() {
  bridge_linux_acl_add "u:foo:r--" /tmp/x
  bridge_linux_acl_add_recursive "u:foo:rwX" /tmp/x
  bridge_linux_acl_add_default_dirs_recursive "u:foo:rwX" /tmp/x
  bridge_linux_acl_remove_recursive "u:foo" /tmp/x
}
log "case: P1 ACL primitive helpers no-op in v2"
P1_DIR="$TMP_ROOT/p1"
P1_LOG="$P1_DIR/sudo.log"
mkdir -p "$P1_DIR"
: >"$P1_LOG"
run_in_v2 "$P1_DIR" "$P1_LOG" case_p1 || die "P1 case_p1 returned non-zero"
assert_no_setfacl "$P1_LOG" "P1 v2 primitives" || die "P1 leaked setfacl"
ok "P1 v2 ACL primitives all no-op"

# ---------------------------------------------------------------------------
# P2: Direct-setfacl helpers no-op in v2 mode
# ---------------------------------------------------------------------------
case_p2() {
  bridge_linux_revoke_traverse_chain "foo" "/tmp/some/dir" "/tmp"
  bridge_linux_revoke_plugin_channel_grants "foo" "fake-plugin" "/tmp/plugins" "/tmp"
  bridge_linux_acl_repair_channel_env_files "smoke-agent" >/dev/null 2>&1 || true
}
log "case: P2 direct-setfacl helpers no-op in v2"
P2_DIR="$TMP_ROOT/p2"
P2_LOG="$P2_DIR/sudo.log"
mkdir -p "$P2_DIR"
: >"$P2_LOG"
run_in_v2 "$P2_DIR" "$P2_LOG" case_p2 || die "P2 case_p2 returned non-zero"
assert_no_setfacl "$P2_LOG" "P2 v2 direct setfacl helpers" || die "P2 leaked setfacl"
ok "P2 v2 direct-setfacl helpers all no-op"

# ---------------------------------------------------------------------------
# P3: grant_traverse_chain v2-noop via bridge_linux_acl_add
# ---------------------------------------------------------------------------
case_p3() {
  local base="$1"
  bridge_linux_grant_traverse_chain "foo" "$base/a/b/c" "$base"
}
log "case: P3 grant_traverse_chain v2-noop"
P3_DIR="$TMP_ROOT/p3"
P3_LOG="$P3_DIR/sudo.log"
mkdir -p "$P3_DIR/a/b/c"
: >"$P3_LOG"
run_in_v2 "$P3_DIR" "$P3_LOG" case_p3 "$P3_DIR" || die "P3 case_p3 returned non-zero"
assert_no_setfacl "$P3_LOG" "P3 v2 grant_traverse_chain" || die "P3 leaked setfacl"
ok "P3 v2 grant_traverse_chain no-op"

# ---------------------------------------------------------------------------
# P4: _bridge_linux_grant_traverse_paths refactor parity + safety
# ---------------------------------------------------------------------------
case_p4_emit() {
  local target="$1"
  local stop="$2"
  _bridge_linux_grant_traverse_paths "$target" "$stop"
}
log "case: P4 _bridge_linux_grant_traverse_paths parity"
P4_DIR="$TMP_ROOT/p4"
P4_LOG="$P4_DIR/sudo.log"
mkdir -p "$P4_DIR/x/y/z"
: >"$P4_LOG"
v2_paths="$(run_in_v2 "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x/y/z" "$P4_DIR")"
legacy_paths="$(run_in_legacy "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x/y/z" "$P4_DIR")"
[[ "$v2_paths" == "$legacy_paths" ]] \
  || die "P4 path emitter parity failed: v2='$v2_paths' legacy='$legacy_paths'"
empty_out="$(run_in_v2 "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x" "" 2>/dev/null)"
[[ -z "$empty_out" ]] || die "P4 missing-stop should emit no paths, got: $empty_out"
slash_out="$(run_in_v2 "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x" "/" 2>/dev/null)"
[[ -z "$slash_out" ]] || die "P4 stop=/ should emit no paths, got: $slash_out"
ok "P4 path emitter parity + safety guards intact"

# ---------------------------------------------------------------------------
# E1: bridge_write_linux_agent_env_file in v2 — chgrp + 0640, no setfacl
# ---------------------------------------------------------------------------
case_e1() {
  local env_file="$1"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-e1")
  BRIDGE_AGENT_ENGINE["smoke-e1"]="codex"
  BRIDGE_AGENT_WORKDIR["smoke-e1"]="/tmp/wd"
  BRIDGE_AGENT_ISOLATION_MODE["smoke-e1"]="linux-user"
  BRIDGE_AGENT_OS_USER["smoke-e1"]="ec2-user"
  bridge_write_linux_agent_env_file "smoke-e1" "$env_file"
  local mode
  mode=$(stat -c "%a" "$env_file")
  [[ "$mode" == "640" ]] || { echo "expected mode 640, got $mode" >&2; return 30; }
}
log "case: E1 env file v2 group-mode"
E1_DIR="$TMP_ROOT/e1"
E1_LOG="$E1_DIR/sudo.log"
mkdir -p "$E1_DIR"
: >"$E1_LOG"
run_in_v2 "$E1_DIR" "$E1_LOG" case_e1 "$E1_DIR/env.sh" \
  || die "E1 env file v2 path failed"
assert_no_setfacl "$E1_LOG" "E1 v2 env file" || die "E1 leaked setfacl"
grep -q "^chmod 0640 .*env\.sh" "$E1_LOG" || die "E1 missing chmod 0640 in sudo log"
grep -q "^chgrp ab-agent-smoke-e1 .*env\.sh" "$E1_LOG" || die "E1 missing chgrp ab-agent-smoke-e1"
ok "E1 env file v2 group-mode (chgrp + chmod 0640, no setfacl)"

# ---------------------------------------------------------------------------
# M1: manifest writer in v2 with agent arg
# ---------------------------------------------------------------------------
case_m1() {
  local iso="$1"
  local ctrl="$2"
  bridge_write_isolated_installed_plugins_manifest \
    "ec2-user" "$iso" "$ctrl" "" "" "smoke-m1"
  [[ -f "$iso/installed_plugins.json" ]] || { echo "manifest missing" >&2; return 31; }
}
log "case: M1 manifest writer v2 group-mode"
M1_DIR="$TMP_ROOT/m1"
M1_LOG="$M1_DIR/sudo.log"
mkdir -p "$M1_DIR/iso-plugins" "$M1_DIR/ctrl-plugins"
echo '{"plugins":{}}' > "$M1_DIR/ctrl-plugins/installed_plugins.json"
: >"$M1_LOG"
run_in_v2 "$M1_DIR" "$M1_LOG" case_m1 "$M1_DIR/iso-plugins" "$M1_DIR/ctrl-plugins" \
  || die "M1 case_m1 returned non-zero"
assert_no_setfacl "$M1_LOG" "M1 v2 manifest" || die "M1 leaked setfacl"
grep -q "^chmod 0640 .*\.tmp\." "$M1_LOG" || die "M1 missing chmod 0640 on tmp"
grep -q "^chgrp ab-agent-smoke-m1" "$M1_LOG" || die "M1 missing chgrp ab-agent-smoke-m1"
ok "M1 manifest writer v2 group-mode"

# ---------------------------------------------------------------------------
# M2: manifest writer dies in v2 without agent arg
# ---------------------------------------------------------------------------
case_m2() {
  local iso="$1"
  local ctrl="$2"
  bridge_write_isolated_installed_plugins_manifest \
    "ec2-user" "$iso" "$ctrl" "" ""  # intentional: no agent arg
}
log "case: M2 manifest writer requires agent arg in v2"
M2_DIR="$TMP_ROOT/m2"
M2_LOG="$M2_DIR/sudo.log"
mkdir -p "$M2_DIR/iso-plugins" "$M2_DIR/ctrl-plugins"
echo '{"plugins":{}}' > "$M2_DIR/ctrl-plugins/installed_plugins.json"
: >"$M2_LOG"
m2_rc=0
run_in_v2 "$M2_DIR" "$M2_LOG" case_m2 "$M2_DIR/iso-plugins" "$M2_DIR/ctrl-plugins" \
  2>/dev/null || m2_rc=$?
[[ $m2_rc -ne 0 ]] || die "M2 manifest writer should die without agent arg in v2"
ok "M2 manifest writer requires agent arg in v2 (rc=$m2_rc)"

# ---------------------------------------------------------------------------
# PC1: bridge_linux_share_plugin_catalog plugin root in v2
# ---------------------------------------------------------------------------
case_pc1() {
  local iso_root="$1"
  local ctrl_home="$2"
  local user_home="$3"
  local shared_root="$4"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-pc1")
  BRIDGE_AGENT_ENGINE["smoke-pc1"]="claude"
  BRIDGE_AGENT_WORKDIR["smoke-pc1"]="/tmp/wd-pc1"
  BRIDGE_AGENT_CHANNELS["smoke-pc1"]=""
  BRIDGE_AGENT_PLUGINS["smoke-pc1"]=""
  # Override controller home resolution so the helper does not walk into
  # the real operator home. The helper's tempdir guard restricts the
  # override to BRIDGE_HOME under /tmp/ or $TMPDIR/, which our run_in_v2
  # fixture already places. The helper expects controller HOME (not the
  # plugins dir); it appends `/.claude/plugins` itself.
  export BRIDGE_CONTROLLER_HOME_OVERRIDE="$ctrl_home"
  # PR-E r2 P2#4 fix: v2 mode requires a populated shared plugins cache;
  # the legacy controller_home fallback is now rejected. Point at a
  # populated cache so PC1 exercises the v2-canonical path.
  export BRIDGE_SHARED_ROOT="$shared_root"
  bridge_linux_share_plugin_catalog "ec2-user" "$user_home" "ec2-user" "smoke-pc1"
  [[ -d "$iso_root" ]] || { echo "iso plugins root missing" >&2; return 32; }
}
log "case: PC1 plugin catalog root v2 group-mode"
PC1_DIR="$TMP_ROOT/pc1"
PC1_LOG="$PC1_DIR/sudo.log"
mkdir -p "$PC1_DIR/iso-home/.claude" \
         "$PC1_DIR/ctrl-home/.claude/plugins" \
         "$PC1_DIR/shared/plugins-cache"
echo '{"plugins":{}}' > "$PC1_DIR/ctrl-home/.claude/plugins/installed_plugins.json"
echo '{"plugins":{}}' > "$PC1_DIR/shared/plugins-cache/installed_plugins.json"
: >"$PC1_LOG"
ISO_PLUGIN_ROOT="$PC1_DIR/iso-home/.claude/plugins"
run_in_v2 "$PC1_DIR" "$PC1_LOG" case_pc1 \
  "$ISO_PLUGIN_ROOT" "$PC1_DIR/ctrl-home" "$PC1_DIR/iso-home" "$PC1_DIR/shared" \
  || die "PC1 case_pc1 returned non-zero"
assert_no_setfacl "$PC1_LOG" "PC1 v2 plugin catalog" || die "PC1 leaked setfacl"
grep -q "^chmod 2750 .*\.claude/plugins" "$PC1_LOG" \
  || die "PC1 missing chmod 2750 on plugins root"
grep -q "^chown root:ab-agent-smoke-pc1 .*\.claude/plugins" "$PC1_LOG" \
  || die "PC1 missing chown root:ab-agent-smoke-pc1 on plugins root"
ok "PC1 plugin catalog root v2 group-mode (2750 + group-correct, no setfacl)"

# ---------------------------------------------------------------------------
# UM1: bridge-run.sh v2 umask helper sets 0007
# ---------------------------------------------------------------------------
case_um1() {
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-um1")
  BRIDGE_AGENT_ENGINE["smoke-um1"]="codex"
  BRIDGE_AGENT_WORKDIR["smoke-um1"]="/tmp/wd"
  BRIDGE_AGENT_ISOLATION_MODE["smoke-um1"]="linux-user"
  BRIDGE_AGENT_OS_USER["smoke-um1"]="ec2-user"
  smoke_bridge_run_apply_v2_umask_if_needed "smoke-um1"
}
log "case: UM1 bridge_run_apply_v2_umask_if_needed in v2"
UM1_DIR="$TMP_ROOT/um1"
UM1_LOG="$UM1_DIR/sudo.log"
UM1_PROBE="$UM1_DIR/umask.probe"
mkdir -p "$UM1_DIR"
: >"$UM1_PROBE"
BRIDGE_RUN_UMASK_PROBE_FILE="$UM1_PROBE" run_in_v2 "$UM1_DIR" "$UM1_LOG" case_um1 \
  || die "UM1 case_um1 returned non-zero"
um1_recorded="$(cat "$UM1_PROBE" 2>/dev/null || true)"
[[ "$um1_recorded" == "0007" ]] || die "UM1 expected probe=0007, got: '$um1_recorded'"
ok "UM1 v2 + linux-user → bridge-run.sh helper sets umask 0007"

# ---------------------------------------------------------------------------
# UM2: helper inert in legacy mode
# ---------------------------------------------------------------------------
case_um2() {
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-um2")
  BRIDGE_AGENT_ENGINE["smoke-um2"]="codex"
  BRIDGE_AGENT_ISOLATION_MODE["smoke-um2"]="shared"
  smoke_bridge_run_apply_v2_umask_if_needed "smoke-um2"
}
log "case: UM2 bridge_run_apply_v2_umask_if_needed inert in legacy"
UM2_DIR="$TMP_ROOT/um2"
UM2_LOG="$UM2_DIR/sudo.log"
UM2_PROBE="$UM2_DIR/umask.probe"
mkdir -p "$UM2_DIR"
: >"$UM2_PROBE"
BRIDGE_RUN_UMASK_PROBE_FILE="$UM2_PROBE" run_in_legacy "$UM2_DIR" "$UM2_LOG" case_um2 \
  || die "UM2 case_um2 returned non-zero"
um2_recorded="$(cat "$UM2_PROBE" 2>/dev/null || true)"
[[ "$um2_recorded" == "0077" ]] || die "UM2 expected probe=0077 (bridge-lib default), got: '$um2_recorded'"
ok "UM2 legacy mode → helper inert (umask stays 0077)"

# ---------------------------------------------------------------------------
# UM3: real bridge-run.sh entrypoint applies umask 0007 in v2 (PR #399 r2 FAIL #14)
#
# UM1 only asserts the helper *body* sets umask correctly. r1 FAIL #14
# noted that the bug was *call ordering* — bridge-run.sh called the helper
# before its definition was parsed, so initial v2 launches inherited the
# bridge-lib.sh default 0077 even though the helper body was correct.
# UM3 drives the actual bridge-run.sh entrypoint with --dry-run + the
# umask probe to assert the call site (line ~91 of bridge-run.sh) is
# observably effective. Uses BRIDGE_HOST_PLATFORM_OVERRIDE=Linux so the
# linux_user_isolation_effective check passes on macOS as well.
# ---------------------------------------------------------------------------
log "case: UM3 real bridge-run.sh entrypoint applies umask 0007 in v2"
UM3_DIR="$TMP_ROOT/um3"
UM3_PROBE="$UM3_DIR/umask.probe"
UM3_HOME="$UM3_DIR/bridge-home"
UM3_DATA="$UM3_DIR/data"
UM3_STATE="$UM3_HOME/state"
UM3_ROSTER_FILE="$UM3_HOME/agent-roster.sh"
UM3_ROSTER_LOCAL="$UM3_HOME/agent-roster.local.sh"
UM3_WORKDIR="$UM3_DIR/agent-workdir"
mkdir -p "$UM3_HOME" "$UM3_DATA/agents" "$UM3_DATA/shared" "$UM3_DATA/state" \
         "$UM3_STATE/agents" "$UM3_WORKDIR"
: >"$UM3_PROBE"
: >"$UM3_ROSTER_FILE"
# BRIDGE_AGENT_SESSION must be set so bridge_agent_exists returns true,
# which gates bridge_require_agent inside bridge-run.sh.
cat >"$UM3_ROSTER_LOCAL" <<EOF
#!/usr/bin/env bash
bridge_add_agent_id_if_missing "smoke-um3"
BRIDGE_AGENT_ENGINE["smoke-um3"]="codex"
BRIDGE_AGENT_SESSION["smoke-um3"]="smoke-um3"
BRIDGE_AGENT_WORKDIR["smoke-um3"]="$UM3_WORKDIR"
BRIDGE_AGENT_ISOLATION_MODE["smoke-um3"]="linux-user"
BRIDGE_AGENT_OS_USER["smoke-um3"]="ec2-user"
BRIDGE_AGENT_LAUNCH_CMD["smoke-um3"]="codex"
EOF
um3_rc=0
BRIDGE_HOME="$UM3_HOME" \
BRIDGE_LAYOUT="v2" \
BRIDGE_DATA_ROOT="$UM3_DATA" \
BRIDGE_STATE_DIR="$UM3_STATE" \
BRIDGE_ACTIVE_AGENT_DIR="$UM3_STATE/agents" \
BRIDGE_ROSTER_FILE="$UM3_ROSTER_FILE" \
BRIDGE_ROSTER_LOCAL_FILE="$UM3_ROSTER_LOCAL" \
BRIDGE_HOST_PLATFORM_OVERRIDE="Linux" \
BRIDGE_RUN_UMASK_PROBE_FILE="$UM3_PROBE" \
  bash "$REPO_ROOT/bridge-run.sh" smoke-um3 --dry-run >/dev/null 2>"$UM3_DIR/run.err" \
  || um3_rc=$?
[[ $um3_rc -eq 0 ]] \
  || die "UM3 bridge-run.sh --dry-run failed rc=$um3_rc; stderr=$(cat "$UM3_DIR/run.err" 2>/dev/null)"
um3_recorded="$(cat "$UM3_PROBE" 2>/dev/null || true)"
[[ "$um3_recorded" == "0007" ]] \
  || die "UM3 expected probe=0007 (real bridge-run.sh entrypoint, v2 + linux-user), got: '$um3_recorded'; stderr=$(cat "$UM3_DIR/run.err" 2>/dev/null)"
ok "UM3 real bridge-run.sh entrypoint sets umask 0007 (call ordering fixed)"

# ---------------------------------------------------------------------------
# EC1/EC2/EC3: engine CLI v2 fail-fast vs system-path pass-through
# ---------------------------------------------------------------------------
case_ec1() {
  local home_path="$1"
  bridge_resolve_engine_cli() { printf "%s" "$home_path/fake-home/.local/bin/claude"; }
  bridge_linux_traverse_stop_for() { printf "%s" "$home_path/fake-home"; }
  bridge_linux_grant_engine_cli_access "ec2-user" "claude"
}
case_ec2() {
  local home_path="$1"
  bridge_resolve_engine_cli() { printf "%s" "$home_path/fake-system/claude-symlink"; }
  bridge_linux_traverse_stop_for() {
    case "$1" in
      *fake-home/.local/bin/claude) printf "%s" "$home_path/fake-home" ;;
      *) printf "" ;;
    esac
  }
  bridge_linux_grant_engine_cli_access "ec2-user" "claude"
}
case_ec3() {
  local home_path="$1"
  bridge_resolve_engine_cli() { printf "%s" "$home_path/fake-system/claude"; }
  bridge_linux_traverse_stop_for() { printf ""; }
  bridge_linux_can_sudo_to() { return 1; }  # skip optional probe
  bridge_linux_grant_engine_cli_access "ec2-user" "claude"
}
log "case: EC1/EC2/EC3 engine CLI v2 controller-home reject + system-path pass"
EC_DIR="$TMP_ROOT/ec"
EC_LOG="$EC_DIR/sudo.log"
mkdir -p "$EC_DIR/fake-home/.local/bin" "$EC_DIR/fake-system"
touch "$EC_DIR/fake-home/.local/bin/claude"
chmod 0755 "$EC_DIR/fake-home/.local/bin/claude"
touch "$EC_DIR/fake-system/claude"
chmod 0755 "$EC_DIR/fake-system/claude"
ln -sf "$EC_DIR/fake-home/.local/bin/claude" "$EC_DIR/fake-system/claude-symlink"
: >"$EC_LOG"

ec1_rc=0
run_in_v2 "$EC_DIR" "$EC_LOG" case_ec1 "$EC_DIR" 2>/dev/null || ec1_rc=$?
[[ $ec1_rc -ne 0 ]] || die "EC1 expected die for controller-home cli_path, got rc=0"
ok "EC1 v2 engine CLI controller-home reject (rc=$ec1_rc)"

ec2_rc=0
run_in_v2 "$EC_DIR" "$EC_LOG" case_ec2 "$EC_DIR" 2>/dev/null || ec2_rc=$?
[[ $ec2_rc -ne 0 ]] || die "EC2 expected die for controller-home cli_real (symlink), got rc=0"
ok "EC2 v2 engine CLI controller-home cli_real reject (rc=$ec2_rc)"

: >"$EC_LOG"
run_in_v2 "$EC_DIR" "$EC_LOG" case_ec3 "$EC_DIR" \
  || die "EC3 case_ec3 returned non-zero"
assert_no_setfacl "$EC_LOG" "EC3 v2 engine CLI system path" || die "EC3 leaked setfacl on system path"
ok "EC3 v2 engine CLI system path pass-through (no setfacl)"

# ---------------------------------------------------------------------------
# CR1: credentials helper in v2 → setfacl ≥ 1 (transitional exception)
# ---------------------------------------------------------------------------
case_cr1() {
  local cr_dir="$1"
  bridge_linux_require_setfacl() { return 0; }
  getent() {
    if [[ "$1" == "passwd" && "$2" == "ec2-user" ]]; then
      printf "ec2-user:x:1000:1000::%s:/bin/bash\n" "$cr_dir/ctrl-home"
    fi
  }
  bridge_linux_grant_claude_credentials_access \
    "ec2-user" "$cr_dir/iso-home" "ec2-user" "claude"
}
log "case: CR1 credentials helper v2 transitional exception"
CR_DIR="$TMP_ROOT/cr"
CR_LOG="$CR_DIR/sudo.log"
mkdir -p "$CR_DIR/ctrl-home/.claude" "$CR_DIR/iso-home"
echo '{"token":"redacted"}' > "$CR_DIR/ctrl-home/.claude/.credentials.json"
chmod 0600 "$CR_DIR/ctrl-home/.claude/.credentials.json"
: >"$CR_LOG"
run_in_v2 "$CR_DIR" "$CR_LOG" case_cr1 "$CR_DIR" \
  || die "CR1 case_cr1 returned non-zero"
assert_some_setfacl "$CR_LOG" "CR1 v2 credentials helper" \
  || die "CR1 expected setfacl ≥ 1 for v2 cred exception"
grep -q "setfacl -m m::r-- .*\.credentials\.json" "$CR_LOG" \
  || die "CR1 expected credential ACL mask repair (m::r--)"
ok "CR1 v2 credentials helper transitional exception (setfacl ≥ 1)"

# ---------------------------------------------------------------------------
# CR2: credentials helper in v2 + missing setfacl → die before symlink plant
# ---------------------------------------------------------------------------
case_cr2() {
  local cr_dir="$1"
  bridge_linux_require_setfacl() { bridge_die "smoke: setfacl missing in v2+claude"; }
  getent() {
    if [[ "$1" == "passwd" && "$2" == "ec2-user" ]]; then
      printf "ec2-user:x:1000:1000::%s:/bin/bash\n" "$cr_dir/ctrl-home"
    fi
  }
  bridge_linux_grant_claude_credentials_access \
    "ec2-user" "$cr_dir/iso-home" "ec2-user" "claude"
}
log "case: CR2 credentials helper v2 fails loud when setfacl missing"
CR2_DIR="$TMP_ROOT/cr2"
CR2_LOG="$CR2_DIR/sudo.log"
mkdir -p "$CR2_DIR/ctrl-home/.claude" "$CR2_DIR/iso-home"
echo '{"token":"redacted"}' > "$CR2_DIR/ctrl-home/.claude/.credentials.json"
: >"$CR2_LOG"
cr2_rc=0
run_in_v2 "$CR2_DIR" "$CR2_LOG" case_cr2 "$CR2_DIR" 2>/dev/null || cr2_rc=$?
[[ $cr2_rc -ne 0 ]] || die "CR2 expected die when setfacl missing in v2+claude, got rc=0"
[[ ! -e "$CR2_DIR/iso-home/.claude/.credentials.json" ]] \
  || die "CR2 expected no symlink plant on early die, but found one"
ok "CR2 v2+claude+missing-setfacl fails loud before symlink plant (rc=$cr2_rc)"

# ---------------------------------------------------------------------------
# LP1: legacy parity — same helpers emit setfacl in legacy mode
# ---------------------------------------------------------------------------
case_lp1() {
  local base="$1"
  bridge_linux_acl_add "u:foo:r--" "$base/a"
  bridge_linux_acl_add_recursive "u:foo:rwX" "$base/a"
  bridge_linux_grant_traverse_chain "foo" "$base/a/b" "$base"
}
log "case: LP1 legacy parity (setfacl ≥ 1)"
LP_DIR="$TMP_ROOT/lp"
LP_LOG="$LP_DIR/sudo.log"
mkdir -p "$LP_DIR/a/b"
: >"$LP_LOG"
run_in_legacy "$LP_DIR" "$LP_LOG" case_lp1 "$LP_DIR" \
  || die "LP1 case_lp1 returned non-zero"
assert_some_setfacl "$LP_LOG" "LP1 legacy primitives" \
  || die "LP1 legacy mode produced no setfacl (regression)"
ok "LP1 legacy parity preserved (setfacl ≥ 1)"

# ---------------------------------------------------------------------------
# CT1/CT2/CT3 — channel symlink target group-mode + TOCTOU + symlink reject
# ---------------------------------------------------------------------------
case_ct() {
  local iso_home="$1"
  local target="$2"
  local agent="$3"
  bridge_linux_install_isolated_channel_symlink \
    "ec2-user" "$iso_home" "ec2-user" "discord" "$target" "$agent"
}
log "case: CT1/CT2/CT3 channel symlink target group-mode + TOCTOU"
CT_DIR="$TMP_ROOT/ct"
CT_LOG="$CT_DIR/sudo.log"
mkdir -p "$CT_DIR/iso-home/.claude/channels" "$CT_DIR/state"
TARGET_NEW="$CT_DIR/state/discord-new"
TARGET_EXISTING="$CT_DIR/state/discord-existing"
mkdir -p "$TARGET_EXISTING"
TARGET_SYMLINK="$CT_DIR/state/discord-symlink"
ln -s "$TARGET_EXISTING" "$TARGET_SYMLINK"

# CT1: new target.
: >"$CT_LOG"
run_in_v2 "$CT_DIR" "$CT_LOG" case_ct "$CT_DIR/iso-home" "$TARGET_NEW" "smoke-ct1" \
  || die "CT1 case_ct returned non-zero"
assert_no_setfacl "$CT_LOG" "CT1 v2 channel symlink (new)" || die "CT1 leaked setfacl"
grep -q "^chmod 2770 .*discord-new" "$CT_LOG" || die "CT1 missing chmod 2770"
grep -q "^chgrp ab-agent-smoke-ct1 .*discord-new" "$CT_LOG" || die "CT1 missing chgrp ab-agent-smoke-ct1"
ok "CT1 v2 channel symlink target (new) → 2770/group-correct, no setfacl"

# CT2: existing target.
: >"$CT_LOG"
run_in_v2 "$CT_DIR" "$CT_LOG" case_ct "$CT_DIR/iso-home" "$TARGET_EXISTING" "smoke-ct2" \
  || die "CT2 case_ct returned non-zero"
assert_no_setfacl "$CT_LOG" "CT2 v2 channel symlink (existing)" || die "CT2 leaked setfacl"
grep -q "^chmod 2770 .*discord-existing" "$CT_LOG" || die "CT2 missing chmod 2770 on existing"
grep -q "^chgrp ab-agent-smoke-ct2 .*discord-existing" "$CT_LOG" || die "CT2 missing chgrp on existing"
ok "CT2 v2 channel symlink target (existing) → idempotent normalize"

# CT3: target is a symlink — refuse.
: >"$CT_LOG"
ct3_rc=0
run_in_v2 "$CT_DIR" "$CT_LOG" case_ct "$CT_DIR/iso-home" "$TARGET_SYMLINK" "smoke-ct3" \
  2>/dev/null || ct3_rc=$?
[[ $ct3_rc -ne 0 ]] || die "CT3 expected non-zero rc when target is symlink, got 0"
if grep -qE "^(chgrp|chmod 2770) .*discord-symlink" "$CT_LOG"; then
  die "CT3 unexpectedly mutated symlink target: $(grep -E 'discord-symlink' "$CT_LOG")"
fi
ok "CT3 v2 channel symlink target (symlink) → reject without mutation (rc=$ct3_rc)"

# ---------------------------------------------------------------------------
# CT4 (PR-E r2 P1#2): v2 prepare quiesce check — alive tmux session → die.
# Issue #403 fix #3: every CT4 case body uses a synthetic os_user that
# CANNOT collide with a controller login. Combined with run_in_v2's
# pinned BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT under TMP_ROOT, no helper
# downstream can resolve `<root>/<os_user>/.agent-bridge` to the
# operator's live install.
# ---------------------------------------------------------------------------
case_ct4_alive() {
  local agent="$1"
  local workdir="$2"
  local synthetic_os_user="agent-bridge-smoke-${agent}"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="ab.${agent}"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="linux-user"
  BRIDGE_AGENT_OS_USER["$agent"]="$synthetic_os_user"
  bridge_tmux_session_exists() { return 0; }
  # Marker so the BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1 bypass case can
  # confirm that quiesce was skipped (rc=42 means setfacl marker reached).
  # Inert in the locked-alive case because quiesce dies first.
  bridge_linux_require_setfacl() { exit 42; }
  bridge_linux_prepare_agent_isolation \
    "$agent" "$synthetic_os_user" "$workdir" "$(id -un)"
}
case_ct4_dead() {
  local agent="$1"
  local workdir="$2"
  local synthetic_os_user="agent-bridge-smoke-${agent}"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="ab.${agent}"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="linux-user"
  BRIDGE_AGENT_OS_USER["$agent"]="$synthetic_os_user"
  bridge_tmux_session_exists() { return 1; }
  bridge_linux_require_setfacl() { exit 42; }
  bridge_linux_prepare_agent_isolation \
    "$agent" "$synthetic_os_user" "$workdir" "$(id -un)"
}
log "case: CT4 v2 prepare quiesce check (P1#2 fix)"
CT4_DIR="$TMP_ROOT/ct4"
CT4_LOG="$CT4_DIR/sudo.log"
CT4_ALIVE_ERR="$CT4_DIR/alive.err"
mkdir -p "$CT4_DIR"
: >"$CT4_LOG"
: >"$CT4_ALIVE_ERR"
ct4_alive_rc=0
# r2 follow-up (codex r1 FAIL #1): just `rc != 0` is non-deterministic
# because case_ct4_alive's bridge_linux_require_setfacl marker exits 42.
# If quiesce fails to fire, the body would still reach the marker and exit
# with rc=42 — masking a missing gate. Capture stderr and assert:
#   (a) rc != 0   — some failure happened
#   (b) rc != 42  — the marker (post-quiesce path) was NOT reached
#   (c) stderr contains the quiesce die's "tmux session" phrase
# Together these pin the failure to bridge_die from the quiesce gate.
run_in_v2 "$CT4_DIR" "$CT4_LOG" case_ct4_alive "smoke-ct4" "$CT4_DIR/wd" \
  2>"$CT4_ALIVE_ERR" || ct4_alive_rc=$?
[[ $ct4_alive_rc -ne 0 ]] || die "CT4 expected die when tmux session is alive, got rc=0"
[[ $ct4_alive_rc -ne 42 ]] \
  || die "CT4-alive: expected quiesce-die rc=1, got marker rc=42 — quiesce gate did not fire (stderr: $(cat "$CT4_ALIVE_ERR" 2>/dev/null))"
grep -q 'tmux session' "$CT4_ALIVE_ERR" \
  || die "CT4-alive: stderr did not contain quiesce-die 'tmux session' message — gate may not have fired (stderr: $(cat "$CT4_ALIVE_ERR" 2>/dev/null))"
ok "CT4-alive v2 prepare with live session → fails loud (rc=$ct4_alive_rc, quiesce gate fired)"
: >"$CT4_LOG"
ct4_dead_rc=0
run_in_v2 "$CT4_DIR" "$CT4_LOG" case_ct4_dead "smoke-ct4-dead" "$CT4_DIR/wd2" \
  2>/dev/null || ct4_dead_rc=$?
[[ $ct4_dead_rc -eq 42 ]] \
  || die "CT4-dead expected rc=42 (quiesce passed → setfacl marker), got rc=$ct4_dead_rc"
ok "CT4-dead v2 prepare with no session → quiesce passes (rc=$ct4_dead_rc, marker)"
: >"$CT4_LOG"
ct4_bypass_rc=0
BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1 \
  run_in_v2 "$CT4_DIR" "$CT4_LOG" case_ct4_alive "smoke-ct4-bypass" "$CT4_DIR/wd3" \
  2>/dev/null || ct4_bypass_rc=$?
[[ $ct4_bypass_rc -eq 42 ]] \
  || die "CT4-bypass expected rc=42 (quiesce skipped → setfacl marker), got rc=$ct4_bypass_rc"
ok "CT4-bypass BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1 skips quiesce gate (rc=$ct4_bypass_rc, marker)"

# ---------------------------------------------------------------------------
# CR3 (PR-E r2 P1#3): v2 cred ACL setfacl failure → die before symlink plant
# ---------------------------------------------------------------------------
case_cr3() {
  local cr_dir="$1"
  bridge_linux_require_setfacl() { return 0; }
  # Override the sudo stub: setfacl returns 1 (filesystem ACL disabled etc.).
  bridge_linux_sudo_root() {
    printf '%s\n' "$*" >>"$_BRIDGE_LINUX_SUDO_LOG_FILE"
    case "${1:-}" in
      setfacl) return 1 ;;
      test) shift; test "$@" ;;
      mkdir|chmod|touch|ln|rm|mv|find|mktemp|python3) "$@" ;;
      chown|chgrp) return 0 ;;
      bash) shift; bash "$@" ;;
      *) return 0 ;;
    esac
  }
  getent() {
    if [[ "$1" == "passwd" && "$2" == "ec2-user" ]]; then
      printf "ec2-user:x:1000:1000::%s:/bin/bash\n" "$cr_dir/ctrl-home"
    fi
  }
  bridge_linux_grant_claude_credentials_access \
    "ec2-user" "$cr_dir/iso-home" "ec2-user" "claude"
}
log "case: CR3 v2 cred setfacl failure → die before symlink plant (P1#3 fix)"
CR3_DIR="$TMP_ROOT/cr3"
CR3_LOG="$CR3_DIR/sudo.log"
mkdir -p "$CR3_DIR/ctrl-home/.claude" "$CR3_DIR/iso-home"
echo '{"token":"redacted"}' > "$CR3_DIR/ctrl-home/.claude/.credentials.json"
chmod 0600 "$CR3_DIR/ctrl-home/.claude/.credentials.json"
: >"$CR3_LOG"
cr3_rc=0
run_in_v2 "$CR3_DIR" "$CR3_LOG" case_cr3 "$CR3_DIR" 2>/dev/null || cr3_rc=$?
[[ $cr3_rc -ne 0 ]] \
  || die "CR3 expected die when v2 cred setfacl fails, got rc=0 (P1#3 regression)"
[[ ! -e "$CR3_DIR/iso-home/.claude/.credentials.json" ]] \
  || die "CR3 expected NO symlink plant on setfacl failure, but found one (P1#3 regression)"
ok "CR3 v2 cred setfacl failure → fails loud, no symlink planted (rc=$cr3_rc)"

# ---------------------------------------------------------------------------
# PC2 (PR-E r2 P2#4): v2 plugin catalog with empty shared cache → die
# ---------------------------------------------------------------------------
case_pc2() {
  local user_home="$1"
  local ctrl_home="$2"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-pc2")
  BRIDGE_AGENT_ENGINE["smoke-pc2"]="claude"
  BRIDGE_AGENT_WORKDIR["smoke-pc2"]="$TMP_ROOT/wd-pc2"
  # PR-E r3 P2: PC2 agent NEEDS plugins (declares a plugin: channel),
  # so the v2 + empty cache path must die. PC3 below pairs this — same
  # setup, but no-plugin agent — and asserts the narrow fix returns 0.
  BRIDGE_AGENT_CHANNELS["smoke-pc2"]="plugin:fake-plugin"
  BRIDGE_AGENT_PLUGINS["smoke-pc2"]=""
  export BRIDGE_CONTROLLER_HOME_OVERRIDE="$ctrl_home"
  # NOTE: BRIDGE_SHARED_ROOT is intentionally unset by run_in_v2 so the
  # v2_shared_plugins_root gate fails. The legacy fallback (controller_home/
  # .claude/plugins) IS present on disk — the fix is that v2 mode must not
  # walk into it.
  bridge_linux_share_plugin_catalog "ec2-user" "$user_home" "ec2-user" "smoke-pc2"
}
log "case: PC2 v2 plugin catalog with empty shared cache + plugin agent → die (P2#4 fix)"
PC2_DIR="$TMP_ROOT/pc2"
PC2_LOG="$PC2_DIR/sudo.log"
mkdir -p "$PC2_DIR/iso-home/.claude" "$PC2_DIR/ctrl-home/.claude/plugins"
echo '{"plugins":{}}' > "$PC2_DIR/ctrl-home/.claude/plugins/installed_plugins.json"
: >"$PC2_LOG"
pc2_rc=0
run_in_v2 "$PC2_DIR" "$PC2_LOG" case_pc2 "$PC2_DIR/iso-home" "$PC2_DIR/ctrl-home" \
  2>/dev/null || pc2_rc=$?
[[ $pc2_rc -ne 0 ]] \
  || die "PC2 expected die in v2 + empty shared cache + plugin agent, got rc=0 (P2#4 regression)"
ok "PC2 v2 + empty shared cache + plugin agent → fails loud (rc=$pc2_rc)"

# ---------------------------------------------------------------------------
# PC3 (PR-E r3 P2 narrow): v2 + empty shared cache + no-plugin agent → no-op.
# This pins the dev-codex r2 P2 finding: codex / no-plugin claude agents
# must not be blocked by a missing shared plugins-cache because they
# have nothing to share.
# ---------------------------------------------------------------------------
case_pc3() {
  local user_home="$1"
  local ctrl_home="$2"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-pc3")
  BRIDGE_AGENT_ENGINE["smoke-pc3"]="codex"
  BRIDGE_AGENT_WORKDIR["smoke-pc3"]="$TMP_ROOT/wd-pc3"
  BRIDGE_AGENT_CHANNELS["smoke-pc3"]="discord,telegram"   # non-plugin only
  BRIDGE_AGENT_PLUGINS["smoke-pc3"]=""
  export BRIDGE_CONTROLLER_HOME_OVERRIDE="$ctrl_home"
  bridge_linux_share_plugin_catalog "ec2-user" "$user_home" "ec2-user" "smoke-pc3"
}
log "case: PC3 v2 plugin catalog with empty shared cache + no-plugin agent → no-op (P2 narrow)"
PC3_DIR="$TMP_ROOT/pc3"
PC3_LOG="$PC3_DIR/sudo.log"
mkdir -p "$PC3_DIR/iso-home/.claude" "$PC3_DIR/ctrl-home/.claude/plugins"
echo '{"plugins":{}}' > "$PC3_DIR/ctrl-home/.claude/plugins/installed_plugins.json"
: >"$PC3_LOG"
run_in_v2 "$PC3_DIR" "$PC3_LOG" case_pc3 "$PC3_DIR/iso-home" "$PC3_DIR/ctrl-home" \
  || die "PC3 case_pc3 returned non-zero — codex/no-plugin agents must not be blocked by empty shared cache"
ok "PC3 v2 + empty shared cache + no-plugin agent → silent no-op"

# ---------------------------------------------------------------------------
# EP1 (PR-E r2 P1#1 verification): bridge-run.sh entrypoint dry-run
# produces no "command not found" — guards against future regressions of
# the umask helper definition order. P1#1 itself was already fixed in
# the upstream merge of #399; this case pins the contract.
# ---------------------------------------------------------------------------
log "case: EP1 bridge-run.sh entrypoint dry-run no 'command not found' (P1#1)"
# r2 follow-up (codex r1 FAIL #2): EP1 used to depend on `bridge-run.sh
# --list` returning at least one host roster agent and skipped silently
# otherwise — non-deterministic across hosts (CI runners, fresh clones).
# Build a synthetic fixture roster under TMP_ROOT (same shape as UM3
# above) so EP1 always has a deterministic target. The fixture is
# pointed at via BRIDGE_ROSTER_FILE / BRIDGE_ROSTER_LOCAL_FILE so the
# host's roster is never read.
EP1_DIR="$TMP_ROOT/ep1"
EP1_HOME="$EP1_DIR/bridge-home"
EP1_DATA="$EP1_DIR/data"
EP1_STATE="$EP1_HOME/state"
EP1_ROSTER_FILE="$EP1_HOME/agent-roster.sh"
EP1_ROSTER_LOCAL="$EP1_HOME/agent-roster.local.sh"
EP1_WORKDIR="$EP1_DIR/agent-workdir"
EP1_OUT="$EP1_DIR/out"
EP1_ERR="$EP1_DIR/err"
mkdir -p "$EP1_HOME" "$EP1_DATA/agents" "$EP1_DATA/shared" "$EP1_DATA/state" \
         "$EP1_STATE/agents" "$EP1_WORKDIR"
: >"$EP1_ROSTER_FILE"
cat >"$EP1_ROSTER_LOCAL" <<EOF
#!/usr/bin/env bash
bridge_add_agent_id_if_missing "agent-bridge-smoke-ep1"
BRIDGE_AGENT_ENGINE["agent-bridge-smoke-ep1"]="codex"
BRIDGE_AGENT_SESSION["agent-bridge-smoke-ep1"]="agent-bridge-smoke-ep1"
BRIDGE_AGENT_WORKDIR["agent-bridge-smoke-ep1"]="$EP1_WORKDIR"
BRIDGE_AGENT_ISOLATION_MODE["agent-bridge-smoke-ep1"]="shared"
BRIDGE_AGENT_LAUNCH_CMD["agent-bridge-smoke-ep1"]="codex"
EOF
ep1_target_agent="agent-bridge-smoke-ep1"
BRIDGE_HOME="$EP1_HOME" \
BRIDGE_DATA_ROOT="$EP1_DATA" \
BRIDGE_STATE_DIR="$EP1_STATE" \
BRIDGE_ACTIVE_AGENT_DIR="$EP1_STATE/agents" \
BRIDGE_ROSTER_FILE="$EP1_ROSTER_FILE" \
BRIDGE_ROSTER_LOCAL_FILE="$EP1_ROSTER_LOCAL" \
  bash "$REPO_ROOT/bridge-run.sh" "$ep1_target_agent" --dry-run \
  >"$EP1_OUT" 2>"$EP1_ERR" || true
if grep -q "command not found" "$EP1_ERR" "$EP1_OUT" 2>/dev/null; then
  printf '[v2-pr-e][error] EP1 bridge-run.sh "%s" --dry-run emitted "command not found":\n' "$ep1_target_agent" >&2
  grep -n "command not found" "$EP1_ERR" "$EP1_OUT" >&2 || true
  die "EP1 P1#1 regression — umask helper ordering broken"
fi
ok "EP1 bridge-run.sh dry-run on synthetic '$ep1_target_agent' → no 'command not found' (P1#1 verified)"

# ---------------------------------------------------------------------------
# X1-X4: root-required (opt-in via BRIDGE_TEST_V2_PRE_ROOT=1)
# ---------------------------------------------------------------------------
if [[ "${BRIDGE_TEST_V2_PRE_ROOT:-0}" != "1" ]]; then
  log "skip: X1-X4 (set BRIDGE_TEST_V2_PRE_ROOT=1 + provide sudo to enable)"
else
  if ! sudo -n true 2>/dev/null; then
    log "skip: X1-X4 (BRIDGE_TEST_V2_PRE_ROOT=1 set but sudo -n unavailable)"
  else
    log "case: X1-X4 root-required (operator opt-in)"
    cat <<'OPERATOR_NOTE'
[v2-pr-e] X1-X4 operator probes (run against live install with at least two ab-agent groups):
  X1. # Cross-agent EACCES — agent A's UID cannot read agent B's root.
      sudo -u agent-bridge-<A> test -r $BRIDGE_AGENT_ROOT_V2/<B>
                                                                  -> fails (group separation)
      sudo -u agent-bridge-<A> ls    $BRIDGE_AGENT_ROOT_V2/<B>
                                                                  -> fails
  X2. # Self-agent — A's UID can read its own resources.
      sudo -u agent-bridge-<A> cat $BRIDGE_AGENT_ROOT_V2/<A>/runtime/agent-env.sh
                                                                  -> ok (group r--)
      sudo -u agent-bridge-<A> cat $BRIDGE_AGENT_ROOT_V2/<A>/.claude/plugins/installed_plugins.json
                                                                  -> ok (group r--)
      sudo -u agent-bridge-<A> test -x $BRIDGE_AGENT_ROOT_V2/<A>/.claude/plugins
                                                                  -> ok (group r-x)
      sudo -u agent-bridge-<A> test -d $BRIDGE_AGENT_ROOT_V2/<A>/workdir/.discord
                                                                  -> ok (group r-x via 2770)
  X3. # Engine CLI exec via isolated UID.
      sudo -u agent-bridge-<A> test -x $(command -v claude)        -> ok (system path)
  X4. # Channel target file inheritance — setgid + umask 007 composition.
      sudo -u agent-bridge-<A> bash -c 'umask 007; touch $BRIDGE_AGENT_ROOT_V2/<A>/workdir/.discord/state.env'
      stat -c '%G %a' $BRIDGE_AGENT_ROOT_V2/<A>/workdir/.discord/state.env
                                                                  -> "ab-agent-<A> 660"
OPERATOR_NOTE
    ok "X1-X4 operator probes documented (manual run against live install)"
  fi
fi

# PR-E r3 P1: end-of-run refuse-log assertion. Any case body that caused
# bridge_linux_sudo_root to refuse a path-escape attempt has appended a
# line to $SUDO_REFUSE_LOG. A non-empty log is a smoke FAIL — a
# refused live-install write must never be silently masked by a positive
# log assertion in the same case.
if [[ -s "$SUDO_REFUSE_LOG" ]]; then
  printf '[v2-pr-e][error] sudo-stub refused %d host-escape attempt(s):\n' \
    "$(wc -l <"$SUDO_REFUSE_LOG")" >&2
  cat "$SUDO_REFUSE_LOG" >&2
  die "smoke caught at least one helper trying to mutate outside TMP_ROOT — fix the helper or the case body before merging (positive cases must not depend on the sudo-stub guard for safety)"
fi
ok "no sudo-stub refusals across all cases (no helper attempted to escape TMP_ROOT)"

log "PR-E smoke complete"
