#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/l1n-iso-uid-queue-roster-skip.sh — L1-N (beta21).
#
# Background: an iso UID running `agb task create --to <agent>`
# subprocesses bridge-task.sh, which sources bridge-lib.sh and calls
# `bridge_load_roster`. Pre-L1-N, that path:
#
#   1. Looked for the scoped env at the legacy path
#      `$BRIDGE_ACTIVE_AGENT_DIR/<agent>/agent-env.sh` ONLY — never at
#      the v2 path `$BRIDGE_AGENT_ROOT_V2/<agent>/runtime/agent-env.sh`
#      where the writer actually puts it on a v2 install.
#   2. When scoped env was not found, unconditionally sourced
#      `BRIDGE_ROSTER_LOCAL_FILE` (which is 0600 root-only), EACCESed
#      from the iso UID, and crashed the bridge-task.sh wrapper with a
#      misleading "queue gateway timed out" error.
#
# L1-N fix (lib/bridge-state.sh::bridge_load_roster):
#   a. Scoped-env discovery extension: when BRIDGE_AGENT_ID is set, try
#      `$BRIDGE_AGENT_ROOT_V2/<agent>/runtime/agent-env.sh` BEFORE
#      falling back to the legacy path.
#   b. Queue-safe roster_local skip: when scoped env was not found
#      AND the calling UID is non-controller AND
#      $BRIDGE_ROSTER_LOCAL_FILE is unreadable AND
#      BRIDGE_QUEUE_SAFE_CONTEXT=1 (set by bridge-task.sh and the
#      `agb show|claim|done|...` shorthand in agent-bridge), warn once
#      and skip the protected source instead of failing.
#   c. Non-queue context with the same precondition fails closed with
#      an actionable error pointing at scoped env / controller-side
#      invocation.
#
# This smoke pins those three contracts:
#   T1 — v2 scoped env discovery: writer-shaped scoped env at the v2
#        runtime path is discovered when BRIDGE_AGENT_ID is set; BRIDGE_AGENT_ENV_FILE
#        is exported to that path (so bridge_queue_gateway_proxy_agent
#        sees gateway-proxy mode without a pre-exported env var).
#   T2 — legacy scoped env discovery still works (fallback): a fixture
#        at the legacy path is honored when the v2 path is absent. Pins
#        the back-compat surface for pre-v2 installs and tests.
#   T3 — queue-safe skip on unreadable roster_local: with no scoped
#        env, unreadable roster_local, simulated iso UID, AND
#        BRIDGE_QUEUE_SAFE_CONTEXT=1, bridge_load_roster returns 0
#        without sourcing the protected roster. The once-per-process
#        warn emits but is not asserted (cosmetic).
#   T4 — fail-closed without queue-safe context: same precondition but
#        BRIDGE_QUEUE_SAFE_CONTEXT=0 (or unset) → bridge_load_roster
#        dies with an actionable error message that names the file and
#        points at scoped env / controller-side invocation.
#   T5 — controller-side invocation with unreadable roster is still a
#        hard fail (the iso-UID skip MUST NOT mask filesystem damage
#        for a legitimate controller-side caller).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home. Iso UID is
# simulated by setting BRIDGE_CONTROLLER_UID to a number different from
# $EUID — bridge_load_roster's iso detection uses
# `EUID != BRIDGE_CONTROLLER_UID && EUID != 0` to pick the iso path
# without actually being a different UID (which would need root +
# useradd we cannot do on macOS smoke). Roster_local "unreadable" is
# achieved by chmod 000; restored to 0600 before cleanup.
#
# Footgun #11 — no heredoc-stdin. Fixtures written via
# `cat >file <<EOF` on flat strings; no command substitution feeding a
# heredoc; no <<< here-strings into bridge functions.

set -uo pipefail

# Re-exec under Bash 4+ for associative arrays.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:l1n-iso-uid-queue-roster-skip] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="l1n-iso-uid-queue-roster-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  # Restore roster_local mode in case a test left it at 0000.
  if [[ -n "${BRIDGE_ROSTER_LOCAL_FILE:-}" && -f "${BRIDGE_ROSTER_LOCAL_FILE:-}" ]]; then
    chmod 0600 "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# Public roster needs at least one syntactically-valid line for
# bridge_load_roster to source without error. Use a comment so no maps
# get populated and we can prove the function exits cleanly.
cat >"$BRIDGE_ROSTER_FILE" <<'EOF'
# public roster (smoke fixture — no agents declared)
EOF

# Protected roster at 0600 — same shape as a live install. Tests
# selectively chmod 000 to simulate the EACCES case.
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<'EOF'
# protected roster (smoke fixture — sentinel for T5 readability)
BRIDGE_ROSTER_LOCAL_SENTINEL=1
EOF
chmod 0600 "$BRIDGE_ROSTER_LOCAL_FILE"

# Build a writer-shaped scoped env file at the v2 path. Just needs to be
# a sourceable bash file; we sentinel-export a value the test can
# assert.
v2_scoped_env_path_for() {
  local agent="$1"
  printf '%s/%s/runtime/agent-env.sh' "$BRIDGE_AGENT_ROOT_V2" "$agent"
}

write_v2_scoped_env() {
  local agent="$1"
  local sentinel="$2"
  local path
  path="$(v2_scoped_env_path_for "$agent")"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
# v2 scoped env (smoke fixture for L1-N T1)
BRIDGE_AGENT_ID="$agent"
BRIDGE_TASK_DB="/dev/null"
BRIDGE_GATEWAY_PROXY="1"
BRIDGE_L1N_SCOPED_ENV_SENTINEL="$sentinel"
EOF
  chmod 0640 "$path"
}

write_legacy_scoped_env() {
  local agent="$1"
  local sentinel="$2"
  local path="$BRIDGE_ACTIVE_AGENT_DIR/$agent/agent-env.sh"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
# legacy scoped env (smoke fixture for L1-N T2)
BRIDGE_AGENT_ID="$agent"
BRIDGE_L1N_LEGACY_SENTINEL="$sentinel"
EOF
  chmod 0640 "$path"
}

# ---------- T1: v2 scoped env discovery -------------------------------------

test_t1_v2_scoped_env_discovered() {
  smoke_log "T1: v2 runtime/agent-env.sh discovered when BRIDGE_AGENT_ID is set"

  local agent="iso_l1n_t1"
  write_v2_scoped_env "$agent" "T1-v2-found"

  # Sub-shell so the export/unset don't leak. Also clear the per-process
  # cache flag the lib sets so the load actually runs.
  local out rc=0
  out="$("$SMOKE_BASH" -c "
    set -uo pipefail
    unset BRIDGE_AGENT_ENV_FILE BRIDGE_ROSTER_CACHE_LOADED BRIDGE_L1N_SCOPED_ENV_SENTINEL
    export BRIDGE_AGENT_ID='$agent'
    export BRIDGE_QUEUE_SAFE_CONTEXT=1
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_load_roster >/dev/null 2>&1
    printf 'sentinel=%s\n' \"\${BRIDGE_L1N_SCOPED_ENV_SENTINEL:-UNSET}\"
    printf 'env_file=%s\n' \"\${BRIDGE_AGENT_ENV_FILE:-UNSET}\"
  " 2>/dev/null)" || rc=$?

  smoke_assert_eq "0" "$rc" "T1 sub-shell exited 0"
  smoke_assert_contains "$out" "sentinel=T1-v2-found" \
    "T1: bridge_load_roster sourced the v2 scoped env (sentinel set)"
  smoke_assert_contains "$out" "runtime/agent-env.sh" \
    "T1: BRIDGE_AGENT_ENV_FILE exported to the v2 runtime path"
}

# ---------- T2: legacy scoped env discovery fallback ------------------------

test_t2_legacy_scoped_env_fallback() {
  smoke_log "T2: legacy state/agents/<X>/agent-env.sh used when v2 path absent"

  local agent="iso_l1n_t2"
  # NO v2 scoped env — only legacy.
  write_legacy_scoped_env "$agent" "T2-legacy-found"

  local out rc=0
  out="$("$SMOKE_BASH" -c "
    set -uo pipefail
    unset BRIDGE_AGENT_ENV_FILE BRIDGE_ROSTER_CACHE_LOADED BRIDGE_L1N_LEGACY_SENTINEL
    export BRIDGE_AGENT_ID='$agent'
    export BRIDGE_QUEUE_SAFE_CONTEXT=1
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_load_roster >/dev/null 2>&1
    printf 'sentinel=%s\n' \"\${BRIDGE_L1N_LEGACY_SENTINEL:-UNSET}\"
  " 2>/dev/null)" || rc=$?

  smoke_assert_eq "0" "$rc" "T2 sub-shell exited 0"
  smoke_assert_contains "$out" "sentinel=T2-legacy-found" \
    "T2: bridge_load_roster fell back to the legacy scoped env path"
}

# ---------- T3: queue-safe iso UID skip on unreadable roster_local ----------

test_t3_queue_safe_skip() {
  smoke_log "T3: queue-safe iso UID + unreadable roster_local → skip with warn"

  # No scoped env; chmod 000 the protected roster; simulate iso UID.
  chmod 000 "$BRIDGE_ROSTER_LOCAL_FILE"

  local out rc=0
  # Pick a sentinel BRIDGE_CONTROLLER_UID that EUID != it AND EUID != 0
  # to trigger the iso UID branch. Use 999999 — clearly not a real
  # operator UID. If somehow the smoke runs as root (EUID=0) the gate
  # would skip the iso branch; assert below that we're not running as
  # root to keep the test meaningful.
  if [[ "$EUID" -eq 0 ]]; then
    smoke_log "T3 skipped — smoke is running as root, iso UID branch can't be exercised here (gate is EUID != 0)"
    chmod 0600 "$BRIDGE_ROSTER_LOCAL_FILE"
    return 0
  fi

  out="$("$SMOKE_BASH" -c "
    set -uo pipefail
    unset BRIDGE_AGENT_ENV_FILE BRIDGE_ROSTER_CACHE_LOADED BRIDGE_AGENT_ID BRIDGE_ROSTER_LOCAL_SKIP_WARNED
    export BRIDGE_CONTROLLER_UID=999999
    export BRIDGE_QUEUE_SAFE_CONTEXT=1
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_load_roster
    printf 'rc=%s\n' \$?
  " 2>&1)" || rc=$?

  chmod 0600 "$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_assert_eq "0" "$rc" "T3 sub-shell exited 0 (queue-safe skip is non-fatal)"
  smoke_assert_contains "$out" "rc=0" \
    "T3: bridge_load_roster returned 0 after queue-safe skip"
  smoke_assert_contains "$out" "queue-safe verb context" \
    "T3: bridge_warn emitted the queue-safe skip explanation"
  # Sanity: the protected roster's sentinel was NOT sourced.
  smoke_assert_not_contains "$out" "BRIDGE_ROSTER_LOCAL_SENTINEL" \
    "T3: protected roster file was NOT sourced (no leaked sentinel)"
}

# ---------- T4: fail-closed without queue-safe context ----------------------

test_t4_fail_closed_no_queue_context() {
  smoke_log "T4: iso UID + unreadable roster_local + NO queue-safe context → fail closed"

  if [[ "$EUID" -eq 0 ]]; then
    smoke_log "T4 skipped — smoke is running as root, iso UID branch can't be exercised"
    return 0
  fi

  chmod 000 "$BRIDGE_ROSTER_LOCAL_FILE"

  local out rc=0
  # Note: bridge_die exits the SUBSHELL non-zero; we capture stderr+stdout
  # combined so the actionable message is visible to assertions.
  out="$("$SMOKE_BASH" -c "
    set -uo pipefail
    unset BRIDGE_AGENT_ENV_FILE BRIDGE_ROSTER_CACHE_LOADED BRIDGE_AGENT_ID BRIDGE_QUEUE_SAFE_CONTEXT BRIDGE_ROSTER_LOCAL_SKIP_WARNED
    export BRIDGE_CONTROLLER_UID=999999
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_load_roster
  " 2>&1)" || rc=$?

  chmod 0600 "$BRIDGE_ROSTER_LOCAL_FILE"

  if [[ "$rc" -eq 0 ]]; then
    smoke_fail "T4: expected non-zero rc from bridge_load_roster (fail-closed); got rc=0 (would silently continue with half-loaded roster)"
  fi
  smoke_assert_contains "$out" "cannot read protected roster" \
    "T4: actionable error names the unreadable roster"
  smoke_assert_contains "$out" "queue-safe verb" \
    "T4: actionable error points at queue-safe verbs"
  smoke_assert_contains "$out" "scoped agent env" \
    "T4: actionable error points at scoped agent env recovery"
}

# ---------- T5: controller-side hard fail on unreadable roster --------------

test_t5_controller_side_hard_fail() {
  smoke_log "T5: controller-side caller + unreadable roster_local → still fail closed"

  if [[ "$EUID" -eq 0 ]]; then
    smoke_log "T5 skipped — smoke is running as root, gating on EUID != 0 cannot be exercised"
    return 0
  fi

  chmod 000 "$BRIDGE_ROSTER_LOCAL_FILE"

  local out rc=0
  # Set BRIDGE_CONTROLLER_UID == EUID so the iso UID gate does NOT
  # fire. The fail-closed branch should still trigger because the
  # protected roster is unreadable and we cannot prove iso-UID-with-
  # queue-safe-verb.
  out="$("$SMOKE_BASH" -c "
    set -uo pipefail
    unset BRIDGE_AGENT_ENV_FILE BRIDGE_ROSTER_CACHE_LOADED BRIDGE_AGENT_ID BRIDGE_QUEUE_SAFE_CONTEXT BRIDGE_ROSTER_LOCAL_SKIP_WARNED
    export BRIDGE_CONTROLLER_UID=\$EUID
    # Even setting QUEUE_SAFE here should NOT mask filesystem damage on
    # a controller-side caller — the EUID == BRIDGE_CONTROLLER_UID gate
    # is what differentiates iso UID from controller; queue-safe alone
    # is not sufficient.
    export BRIDGE_QUEUE_SAFE_CONTEXT=1
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_load_roster
  " 2>&1)" || rc=$?

  chmod 0600 "$BRIDGE_ROSTER_LOCAL_FILE"

  if [[ "$rc" -eq 0 ]]; then
    smoke_fail "T5: controller-side caller silently survived an unreadable roster — iso-UID skip leaked beyond its gate"
  fi
  smoke_assert_contains "$out" "cannot read protected roster" \
    "T5: actionable error fires for controller-side caller too"
}

# Locate a Bash 4+ binary for sub-shell tests (mirrors the re-exec
# probe at the top of this file). On macOS hosts the smoke is already
# re-exec'd into a Bash 4+ at the head, but sub-shell tests below need
# the same binary explicitly for the `"$SMOKE_BASH" -c '...'` calls.
SMOKE_BASH=""
for _candidate in "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash" bash; do
  if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
    SMOKE_BASH="$_candidate"
    break
  fi
done
[[ -n "$SMOKE_BASH" ]] || smoke_fail "no Bash 4+ binary found for sub-shell tests"

test_t1_v2_scoped_env_discovered
smoke_log "ok: T1 (v2 scoped env discovery)"

test_t2_legacy_scoped_env_fallback
smoke_log "ok: T2 (legacy scoped env fallback)"

test_t3_queue_safe_skip
smoke_log "ok: T3 (queue-safe iso UID skip)"

test_t4_fail_closed_no_queue_context
smoke_log "ok: T4 (fail-closed without queue-safe context)"

test_t5_controller_side_hard_fail
smoke_log "ok: T5 (controller-side hard fail)"

smoke_log "passed"
