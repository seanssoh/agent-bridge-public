#!/usr/bin/env bash
# scripts/smoke/1140-purge-home-os-cleanup.sh — issue #1140.
#
# `agent delete` on an isolated (linux-user) agent must also reap two
# additional trees that survived PR #1129 (the closer of #1121):
#   - the OS-level home dir `/home/agent-bridge-<a>/` (provisioned by
#     `useradd --home-dir`)
#   - the v2 per-agent workdir tree `$BRIDGE_AGENT_ROOT_V2/<a>/` (the
#     `home/`, `workdir/`, `runtime/`, `logs/` children that
#     `agent create` scaffolds on a v2 install)
#
# This smoke exercises the *decision logic* of the new Step 5 (OS home
# reap) and Step 6 (v2 workdir reap) helpers that are now part of
# `bridge_isolation_v2_reap_isolated_agent_account` — same shim-record
# approach as scripts/smoke/1121-agent-delete-os-purge.sh:
# `rm` is replaced by a bash function that records argv. Production
# code paths pass literal `/home` and the live `$BRIDGE_AGENT_ROOT_V2`
# as hardcoded/env-resolved arguments respectively; the smoke invokes
# the internal helpers directly with tmpdir args to exercise the
# decision logic without touching the real /home or live data root.
#
# Cases:
#   C1. Step 5 happy path — Linux + agent-bridge-<slug> + home dir
#       exists in tmpdir: rm -rf hits the exact composed path.
#   C2. Step 5 absent target — sudoers-style silent no-op (no rm, no
#       warning row) when the home dir does not exist.
#   C3. Step 5 strict pattern gate — refuses an os_user whose name
#       would not match `^agent-bridge-[a-zA-Z0-9_-]+$` (defensive,
#       Gate 2 already blocks but the helper re-checks).
#   C4. Step 5 best-effort warn — rm failure emits a structured WARN
#       row but the helper still returns 0 (Step 6 must still fire).
#   C5. Step 6 happy path — v2 workdir tree exists under the tmpdir
#       agent_root: rm -rf hits the exact `<agent_root>/<agent>`.
#   C6. Step 6 absent root — empty `agent_root_v2` argument (legacy v1
#       install) is a clean silent no-op (no rm at `/`+<agent> shape).
#   C7. Step 6 strict slug gate — refuses an agent name that is not
#       `^[a-zA-Z0-9_-]+$` (would block `..` or shell metacharacter
#       smuggling even if Gate 2 upstream were bypassed).
#   C8. Step 6 best-effort warn — rm failure emits a structured WARN
#       row + helper still returns 0.
#
# The fully destructive path (a real rm against `/home/agent-bridge-*`
# or the live `$BRIDGE_AGENT_ROOT_V2/<agent>`) can only be verified on
# a live Linux host with root or passwordless sudo — see the PR's
# "Manual verification needed" section.

set -euo pipefail

SMOKE_NAME="1140-purge-home-os-cleanup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Run an internal-helper probe in a fully isolated subshell with `rm`
# shimmed to record argv (and optionally fail) instead of mutating the
# host. The probe writes its body to a file and invokes it as `bash
# $file` to avoid the Bash 5.3.9 heredoc-stdin-to-subprocess deadlock
# (footgun #11) — same shape PR #893 / #1129 r4 settled on.
#
# Args:
#   $1 — helper to invoke ("os_home" | "v2_workdir")
#   $2 — agent name
#   $3 — os_user (only meaningful for "os_home")
#   $4 — staging mode for the target tree on the fake host:
#          "present" — pre-create the tree so the helper rm fires
#          "absent"  — leave it missing (helper silent no-op)
#   $5 — rm failure mode ("ok" | "fail")
#   $6 — root override:
#          for os_home: home_root passed to the helper (typically the
#                       smoke tmpdir under $SMOKE_TMP_ROOT/home, OR a
#                       literal sentinel "/etc/passwd-parent" for the
#                       strict pattern gate case — the gate refuses
#                       before composing rm)
#          for v2_workdir: agent_root_v2 passed to the helper (the
#                          smoke tmpdir under $SMOKE_TMP_ROOT/data/agents
#                          OR the empty string to assert the legacy
#                          no-op early return)
#
# Prints, one per line, a decision trace the caller can grep:
#   RM_RF <path>
#   RM_RF_FAIL <path>
#   WARN <text>
run_helper_probe() {
  local helper="$1"
  local agent="$2"
  local os_user="$3"
  local stage_mode="$4"
  local rm_mode="$5"
  local root_arg="$6"

  # Stage the target tree for "present" cases. For os_home that means
  # creating the leaf <root_arg>/<os_user>; for v2_workdir it means
  # creating <root_arg>/<agent>.
  if [[ "$stage_mode" == "present" ]]; then
    if [[ "$helper" == "os_home" && -n "$os_user" && -n "$root_arg" ]]; then
      mkdir -p "$root_arg/$os_user"
      # Drop a sentinel file so a future bug that rm'd the wrong tree
      # would show up as an unstaged path in the trace.
      : >"$root_arg/$os_user/.sentinel"
    elif [[ "$helper" == "v2_workdir" && -n "$agent" && -n "$root_arg" ]]; then
      mkdir -p "$root_arg/$agent/home"
      mkdir -p "$root_arg/$agent/workdir"
      : >"$root_arg/$agent/.sentinel"
    fi
  fi

  local probe_file="$SMOKE_TMP_ROOT/probe-$$-${RANDOM}.sh"
  cat >"$probe_file" <<PROBE
set -uo pipefail

# rm shim: records argv for the (rm, -rf, --, PATH) shape both helpers
# use. Any other rm shape falls through to the real binary so the test
# never silently masks an unintended rm.
rm() {
  if [[ "\${1:-}" == "-rf" && "\${2:-}" == "--" ]]; then
    if [[ "${rm_mode}" == "fail" ]]; then
      printf 'RM_RF_FAIL %s\n' "\$3"
      return 1
    fi
    printf 'RM_RF %s\n' "\$3"
    return 0
  fi
  command rm "\$@"
}
bridge_warn() { printf 'WARN %s\n' "\$*" >&2; }
bridge_die()  { printf 'DIE %s\n' "\$*" >&2; exit 1; }

# Provide a minimal _bridge_isolation_v2_run_root_or_sudo stand-in that
# routes through the shimmed rm. The real helper would try direct-first
# then sudo; both paths land at the same rm-rf-double-dash-PATH shape
# our shim intercepts above. We keep the function signature identical
# so the internal helpers see the same caller contract.
_bridge_isolation_v2_run_root_or_sudo() {
  "\$@"
}

source "${SMOKE_REPO_ROOT}/lib/bridge-isolation-v2.sh"

case "${helper}" in
  os_home)
    _bridge_isolation_v2_reap_os_home_dir "${agent}" "${os_user}" "${root_arg}" 2>&1
    ;;
  v2_workdir)
    _bridge_isolation_v2_reap_v2_workdir "${agent}" "${root_arg}" 2>&1
    ;;
esac
PROBE
  bash "$probe_file"
  local probe_rc=$?
  rm -f "$probe_file"
  return $probe_rc
}

# ---------------------------------------------------------------------------
# C1 — Step 5 happy path: rm -rf at <home_root>/<os_user>.
# ---------------------------------------------------------------------------
test_step5_happy_path_removes_home_dir() {
  local home_root="$SMOKE_TMP_ROOT/home"
  rm -rf "$home_root"
  local out
  out="$(run_helper_probe "os_home" "bob" "agent-bridge-bob" "present" "ok" "$home_root")"

  smoke_assert_contains "$out" "RM_RF ${home_root}/agent-bridge-bob" \
    "C1: OS home dir removed at exactly <home_root>/<os_user>"
  smoke_assert_not_contains "$out" "WARN" \
    "C1: no warning on successful rm"
  smoke_assert_not_contains "$out" "refusing to rm" \
    "C1: strict pattern gate accepts canonical agent-bridge-<slug>"
}

# ---------------------------------------------------------------------------
# C2 — Step 5 absent target: clean silent no-op.
# ---------------------------------------------------------------------------
test_step5_absent_target_silent_noop() {
  local home_root="$SMOKE_TMP_ROOT/home"
  rm -rf "$home_root"
  mkdir -p "$home_root"
  local out
  out="$(run_helper_probe "os_home" "bob" "agent-bridge-bob" "absent" "ok" "$home_root")"

  smoke_assert_not_contains "$out" "RM_RF" \
    "C2: no rm attempted when the home dir is absent"
  smoke_assert_not_contains "$out" "WARN" \
    "C2: absent target produces no warning row (clean no-op)"
}

# ---------------------------------------------------------------------------
# C3 — Step 5 strict pattern gate: refuses a non-`agent-bridge-*` user.
# ---------------------------------------------------------------------------
test_step5_strict_pattern_gate_refuses() {
  local home_root="$SMOKE_TMP_ROOT/home"
  rm -rf "$home_root"
  mkdir -p "$home_root/operator"
  : >"$home_root/operator/.sentinel"
  local out
  # os_user "operator" — composed leaf does not match the strict
  # `^agent-bridge-[a-zA-Z0-9_-]+$` pattern; helper refuses.
  out="$(run_helper_probe "os_home" "bob" "operator" "absent" "ok" "$home_root")"

  smoke_assert_not_contains "$out" "RM_RF" \
    "C3: rm NOT attempted when composed leaf misses the strict pattern"
  smoke_assert_contains "$out" "refusing to rm" \
    "C3: refusal reported via bridge_warn (defence-in-depth gate)"
  # Sentinel must survive — the helper's refusal is the load-bearing
  # safety property here.
  [[ -f "$home_root/operator/.sentinel" ]] || \
    smoke_fail "C3: sentinel file removed despite pattern gate (defence breach)"
}

# ---------------------------------------------------------------------------
# C4 — Step 5 best-effort: rm failure emits WARN + helper returns 0.
# ---------------------------------------------------------------------------
test_step5_rm_failure_emits_warning_row() {
  local home_root="$SMOKE_TMP_ROOT/home"
  rm -rf "$home_root"
  local out
  out="$(run_helper_probe "os_home" "bob" "agent-bridge-bob" "present" "fail" "$home_root")"

  smoke_assert_contains "$out" "RM_RF_FAIL ${home_root}/agent-bridge-bob" \
    "C4: rm shim recorded the failing call"
  smoke_assert_contains "$out" "failed to remove OS home dir" \
    "C4: rm failure produces a structured WARN row (best-effort delete)"
  smoke_assert_contains "$out" "WARN" \
    "C4: warning is emitted via bridge_warn (visible in audit/log)"
}

# ---------------------------------------------------------------------------
# C5 — Step 6 happy path: rm -rf at <agent_root_v2>/<agent>.
# ---------------------------------------------------------------------------
test_step6_happy_path_removes_v2_workdir() {
  local data_agents="$SMOKE_TMP_ROOT/data/agents"
  rm -rf "$data_agents"
  local out
  out="$(run_helper_probe "v2_workdir" "bob" "" "present" "ok" "$data_agents")"

  smoke_assert_contains "$out" "RM_RF ${data_agents}/bob" \
    "C5: v2 workdir removed at exactly <agent_root_v2>/<agent>"
  smoke_assert_not_contains "$out" "WARN" \
    "C5: no warning on successful rm"
}

# ---------------------------------------------------------------------------
# C6 — Step 6 absent root (legacy v1 install): clean silent no-op.
# ---------------------------------------------------------------------------
test_step6_absent_root_silent_noop() {
  local out
  # agent_root_v2 = "" → helper must early-return; absolutely no rm
  # shape can fire (would otherwise compose `/bob` which is catastrophic).
  out="$(run_helper_probe "v2_workdir" "bob" "" "absent" "ok" "")"

  smoke_assert_not_contains "$out" "RM_RF" \
    "C6: no rm attempted when agent_root_v2 is empty (legacy v1)"
  smoke_assert_not_contains "$out" "WARN" \
    "C6: empty agent_root_v2 produces no warning row (clean no-op)"
}

# ---------------------------------------------------------------------------
# C7 — Step 6 strict slug gate: refuses a `..` agent slug.
# ---------------------------------------------------------------------------
test_step6_strict_slug_gate_refuses() {
  local data_agents="$SMOKE_TMP_ROOT/data/agents"
  rm -rf "$data_agents"
  mkdir -p "$data_agents/legit"
  : >"$data_agents/legit/.sentinel"
  local out
  # `..` is the canonical defence test — even if Gate 2 upstream were
  # bypassed, the helper must refuse anything outside the slug regex.
  out="$(run_helper_probe "v2_workdir" ".." "" "absent" "ok" "$data_agents")"

  smoke_assert_not_contains "$out" "RM_RF" \
    "C7: rm NOT attempted when agent slug misses the strict pattern"
  smoke_assert_contains "$out" "refusing to rm" \
    "C7: refusal reported via bridge_warn (defence-in-depth gate)"
  # Sentinel must survive — the legit sibling agent's tree must be
  # untouched by a refused-slug call.
  [[ -f "$data_agents/legit/.sentinel" ]] || \
    smoke_fail "C7: legit sibling tree removed despite slug gate (defence breach)"
}

# ---------------------------------------------------------------------------
# C8 — Step 6 best-effort: rm failure emits WARN + helper returns 0.
# ---------------------------------------------------------------------------
test_step6_rm_failure_emits_warning_row() {
  local data_agents="$SMOKE_TMP_ROOT/data/agents"
  rm -rf "$data_agents"
  local out
  out="$(run_helper_probe "v2_workdir" "bob" "" "present" "fail" "$data_agents")"

  smoke_assert_contains "$out" "RM_RF_FAIL ${data_agents}/bob" \
    "C8: rm shim recorded the failing call"
  smoke_assert_contains "$out" "failed to remove v2 workdir" \
    "C8: rm failure produces a structured WARN row (best-effort delete)"
  smoke_assert_contains "$out" "WARN" \
    "C8: warning is emitted via bridge_warn (visible in audit/log)"
}

main() {
  smoke_require_cmd bash
  smoke_make_temp_root "1140-purge-home-os-cleanup"
  trap smoke_cleanup_temp_root EXIT

  smoke_run "C1 Step 5 happy path: rm -rf at <home_root>/<os_user>" \
    test_step5_happy_path_removes_home_dir
  smoke_run "C2 Step 5 absent target: silent no-op" \
    test_step5_absent_target_silent_noop
  smoke_run "C3 Step 5 strict pattern gate refuses non-agent-bridge user" \
    test_step5_strict_pattern_gate_refuses
  smoke_run "C4 Step 5 rm failure: structured WARN, helper returns 0" \
    test_step5_rm_failure_emits_warning_row
  smoke_run "C5 Step 6 happy path: rm -rf at <agent_root_v2>/<agent>" \
    test_step6_happy_path_removes_v2_workdir
  smoke_run "C6 Step 6 empty agent_root_v2 (legacy v1): silent no-op" \
    test_step6_absent_root_silent_noop
  smoke_run "C7 Step 6 strict slug gate refuses dotdot agent slug" \
    test_step6_strict_slug_gate_refuses
  smoke_run "C8 Step 6 rm failure: structured WARN, helper returns 0" \
    test_step6_rm_failure_emits_warning_row

  smoke_log "passed"
}

main "$@"
