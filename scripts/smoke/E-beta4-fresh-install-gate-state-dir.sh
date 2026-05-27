#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/E-beta4-fresh-install-gate-state-dir.sh — Issues #1265 + #1269.
#
# v0.15.0-beta4 Lane E — fresh-install first-wake gate + daemon wake
# state-dir self-heal.
#
# Two distinct surfaces, one smoke (both close the OOTB fresh-install
# story together):
#
#   Issue #1265 — Lane A3 (PR #1259) reconcile gate in bridge-run.sh
#   correctly fail-louded on the #1248 "lost state" case (an agent that
#   has launched before but lost its persisted session_id), but also
#   fired on the fresh-install first-wake case: a brand-new admin agent
#   (`patch`, `patch-dev`) has `continue=1` (roster default) AND
#   `session_id=""` (no jsonl yet, never launched). That gate turned
#   `agb admin` on a fresh install into a die path with `(a)/(b)/(c)`
#   remediation that the OOTB operator could not navigate. Lane E adds
#   a fresh-state branch: `state/agents/<a>/launch.history` absent =>
#   proceed without --resume + structured info + touch the marker so
#   the NEXT empty-sid condition correctly falls into the lost-state die.
#
#   Issue #1269 — Lane A12 R2/R3 (#1252) wired `bridge_agent_state_dir_self_heal`
#   into the `agent create` and `agent start` paths only, leaving the
#   daemon's three auto-wake paths (`process_on_demand_agents` always-on,
#   `process_on_demand_agents` queued on-demand, and
#   `bridge_daemon_cron_dispatch_wake`) unhealed. This broke the
#   always-on auto-recovery contract: a fresh-install always-on agent
#   would never come up purely from daemon-driven wakes — the operator
#   had to invoke `agent-bridge agent start <a>` once before daemon
#   restarts. Lane E wires the helper into all three sites.
#
# Test plan:
#   T1  fresh agent (no launch.history) + continue=1 + session_id="" ->
#       fresh-state branch (no `--resume`, no die) + history touched.
#   T2  post-launch agent (launch.history present) + continue=1 +
#       session_id="" -> die with (a)/(b)/(c) remediation (lost-state
#       preserved).
#   T3  continue=0 / --no-continue -> no resume verb (gate not entered).
#   T4  daemon wake call site self-heals state dir absent state — grep
#       proof in bridge-daemon.sh on all three wake sites (always-on
#       branch, queued on-demand branch, cron-dispatch wake).
#   T5 (teeth) revert the fresh-state branch in bridge-run.sh => fresh
#       wake would die again. Asserts the marker keywords are present
#       in bridge-run.sh so a future PR that removes the branch trips
#       this smoke citing #1265.
#   T6 (teeth) revert the daemon-wake self-heal calls => state-dir-absent
#       wake would lose auto-recovery. Asserts the helper call grep
#       footprint is present in bridge-daemon.sh on each of the three
#       wake sites — if any future PR drops one, this smoke fails citing
#       #1269.
#
# Isolation: temp BRIDGE_HOME with v2 layout via smoke_setup_bridge_home;
# the smoke never reads or writes the operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `cat >file <<EOF` plain bodies on flat string variables — no command
# substitution feeding a heredoc stdin, no `<<<` here-strings into bridge
# functions. See `memory/feedback_bash_heredoc_write_class_recurrence.md`.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash
# 3.2 — match the recipe used by other smokes.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:E-beta4-fresh-install-gate-state-dir] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="E-beta4-fresh-install-gate-state-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "E-beta4-fresh-install-gate-state-dir"

REPO_ROOT="$SMOKE_REPO_ROOT"

# ---------------------------------------------------------------------
# Helper: write a minimal roster on disk so a fresh `bridge-run.sh`
# subprocess can load it. `--dry-run` exits before any tmux/launch side
# effects, so engine + workdir + launch_cmd + continue + session_id is
# enough.
# ---------------------------------------------------------------------
write_dryrun_roster() {
  local agent="$1"
  local continue_mode="$2"
  local session_id="$3"
  local engine="${4:-claude}"
  local workdir="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$agent"
BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
BRIDGE_AGENT_ENGINE["$agent"]="$engine"
BRIDGE_AGENT_SESSION["$agent"]="$agent"
BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["$agent"]="claude --dangerously-skip-permissions --name $agent"
BRIDGE_AGENT_LOOP["$agent"]=0
BRIDGE_AGENT_CONTINUE["$agent"]=$continue_mode
BRIDGE_AGENT_SESSION_ID["$agent"]="$session_id"
EOF
}

# ---------------------------------------------------------------------
# T1 — fresh agent (no launch.history) + continue=1 + session_id=""
#      -> fresh-state branch fires. The dry-run must NOT die, must NOT
#      emit a `--resume` verb (no session id to resume).
#
#      R2 (codex r1 BLOCKING — dry-run poisoning): dry-run must be
#      side-effect-free. The launch.history marker MUST NOT be created
#      by a dry-run inspection — otherwise a never-launched agent
#      flips to "launched before" state and the next real first launch
#      (or a second dry-run) dies on the lost-state path. The marker
#      is now deferred to the real-launch path (post-dry-run-exit).
# ---------------------------------------------------------------------
test_fresh_first_wake_no_die() {
  local agent="e-T1-fresh"
  write_dryrun_roster "$agent" 1 ""

  # Ensure state/agents/<a>/ does NOT exist yet (fresh install simulation)
  local agent_state_dir="$BRIDGE_STATE_DIR/agents/$agent"
  rm -rf "$agent_state_dir" 2>/dev/null || true

  local out=""
  local rc=0
  set +e
  out="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"
  rc=$?
  set -e

  smoke_assert_eq "0" "$rc" \
    "T1 dry-run on fresh first-wake exits 0 (no die)"
  smoke_assert_contains "$out" "agent=$agent" \
    "T1 dry-run echoes agent"
  smoke_assert_contains "$out" "continue=1" \
    "T1 dry-run echoes continue=1"
  smoke_assert_not_contains "$out" "session_id missing" \
    "T1 dry-run does not contain the lost-state die remediation"
  smoke_assert_not_contains "$out" "--resume" \
    "T1 launch_cmd has no --resume verb on fresh first-wake (no session_id to resume)"
  smoke_assert_contains "$out" "fresh first-wake" \
    "T1 dry-run emits the structured fresh-first-wake info breadcrumb"

  # R2 (codex r1 BLOCKING — dry-run poisoning): marker MUST NOT exist
  # after a dry-run inspection. dry-run is advertised as side-effect-free;
  # creating the marker here would flip never-launched -> launched-before
  # state and poison the next real first launch / second dry-run into the
  # lost-state die branch.
  local marker="$BRIDGE_STATE_DIR/agents/$agent/launch.history"
  if [[ -f "$marker" ]]; then
    smoke_fail "T1 R2: launch.history marker MUST NOT be created by dry-run inspection — found at $marker (codex r1 BLOCKING: dry-run poisons next real first launch / second dry-run)"
  fi
}

# ---------------------------------------------------------------------
# T2 — post-launch agent (launch.history present) + continue=1 +
#      session_id="" -> die with (a)/(b)/(c) remediation. This is the
#      genuine #1248 lost-state path; Lane E must NOT regress it.
# ---------------------------------------------------------------------
test_lost_state_still_fails_loud() {
  local agent="e-T2-lost"
  write_dryrun_roster "$agent" 1 ""

  # Simulate "agent has launched before" by pre-touching the marker.
  local marker="$BRIDGE_STATE_DIR/agents/$agent/launch.history"
  mkdir -p "$(dirname "$marker")"
  : >"$marker"

  local out=""
  local rc=0
  set +e
  out="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    smoke_fail "T2 expected non-zero rc from bridge-run.sh when post-launch agent + continue=1 + session_id empty, got rc=0; out=$out"
  fi
  smoke_assert_contains "$out" "session_id missing" \
    "T2 lost-state error message present"
  smoke_assert_contains "$out" "(a) run agent first interactively to capture" \
    "T2 remediation (a) preserved"
  smoke_assert_contains "$out" "(b) set continue=0 explicitly" \
    "T2 remediation (b) preserved"
  smoke_assert_contains "$out" "(c) check #1246 daemon supp-group state" \
    "T2 remediation (c) preserved"
}

# ---------------------------------------------------------------------
# T3 — continue=0 / --no-continue -> no resume verb (gate not entered).
#      Sanity that the Lane E branch doesn't accidentally affect the
#      already-correct continue=0 path.
# ---------------------------------------------------------------------
test_continue0_unchanged() {
  local agent="e-T3-no-continue"
  write_dryrun_roster "$agent" 0 ""
  local out=""
  out="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --no-continue --dry-run 2>&1)"
  smoke_assert_contains "$out" "agent=$agent" \
    "T3 dry-run echoes agent"
  smoke_assert_contains "$out" "continue=0" \
    "T3 dry-run echoes continue=0"
  smoke_assert_not_contains "$out" "--resume" \
    "T3 launch_cmd contains no --resume verb when continue=0"
  smoke_assert_not_contains "$out" "session_id missing" \
    "T3 continue=0 path does not trigger the gate"
}

# ---------------------------------------------------------------------
# T4 — daemon wake call sites all guard with
#      `bridge_agent_state_dir_self_heal`. Grep proof in bridge-daemon.sh
#      on three distinct trigger detail strings (one per site):
#        - trigger=always_on_wake
#        - trigger=on_demand_wake
#        - trigger=cron_dispatch_wake
#      The audit detail names give a deterministic per-site signature
#      that future PRs cannot satisfy by adding a single self-heal call
#      and missing one of the other two sites.
# ---------------------------------------------------------------------
test_daemon_wake_self_heal_grep() {
  local daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  smoke_assert_file_exists "$daemon_sh" \
    "T4: bridge-daemon.sh exists"

  local helper_hit=""
  helper_hit="$(grep -c 'bridge_agent_state_dir_self_heal' "$daemon_sh" || true)"
  if (( helper_hit < 3 )); then
    smoke_fail "T4: bridge-daemon.sh has only ${helper_hit} bridge_agent_state_dir_self_heal call(s); expected >=3 (always-on, on-demand, cron-dispatch) — #1269 regressed"
  fi

  local site_a=""
  site_a="$(grep -F 'trigger=always_on_wake' "$daemon_sh" || true)"
  if [[ -z "$site_a" ]]; then
    smoke_fail "T4: missing always-on wake self_heal site marker (audit detail trigger=always_on_wake) — #1269 regressed (always-on branch)"
  fi

  local site_b=""
  site_b="$(grep -F 'trigger=on_demand_wake' "$daemon_sh" || true)"
  if [[ -z "$site_b" ]]; then
    smoke_fail "T4: missing queued on-demand wake self_heal site marker (audit detail trigger=on_demand_wake) — #1269 regressed (on-demand branch)"
  fi

  local site_c=""
  site_c="$(grep -F 'trigger=cron_dispatch_wake' "$daemon_sh" || true)"
  if [[ -z "$site_c" ]]; then
    smoke_fail "T4: missing cron-dispatch wake self_heal site marker (audit detail trigger=cron_dispatch_wake) — #1269 regressed (cron-dispatch branch)"
  fi

  local audit_action_hit=""
  audit_action_hit="$(grep -c 'state_dir_self_heal_failed' "$daemon_sh" || true)"
  if (( audit_action_hit < 3 )); then
    smoke_fail "T4: bridge-daemon.sh has only ${audit_action_hit} 'state_dir_self_heal_failed' audit row(s); expected >=3 (one per wake site) — #1269 regressed"
  fi
}

# ---------------------------------------------------------------------
# T5 (teeth) — bridge-run.sh fresh-state branch keywords present.
#              If a future PR removes the branch, this smoke fails citing
#              #1265.
# ---------------------------------------------------------------------
test_teeth_fresh_state_branch_present() {
  local runner="$REPO_ROOT/bridge-run.sh"
  smoke_assert_file_exists "$runner" \
    "T5 teeth: bridge-run.sh exists"

  local hit=""
  hit="$(grep -F 'launch.history' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T5 teeth: bridge-run.sh fresh-state branch keyword 'launch.history' missing — issue #1265 regressed"
  fi

  hit="$(grep -F 'fresh first-wake' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T5 teeth: bridge-run.sh fresh-first-wake structured log missing — issue #1265 regressed"
  fi

  hit="$(grep -F 'fresh_first_wake' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T5 teeth: bridge-run.sh fresh_first_wake audit action missing — issue #1265 regressed"
  fi
}

# ---------------------------------------------------------------------
# T6 (teeth) — bridge-daemon.sh wake self-heal call footprint present
#              on each of the three wake sites. If any future PR drops
#              the per-site call (or merges them in a way that loses a
#              trigger), this smoke fails citing #1269.
# ---------------------------------------------------------------------
test_teeth_daemon_self_heal_sites_present() {
  local daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  smoke_assert_file_exists "$daemon_sh" \
    "T6 teeth: bridge-daemon.sh exists"

  # Each site emits a distinct `trigger=...` audit-detail. Cross-check
  # both the helper invocation count AND the three trigger markers so
  # the smoke catches both "removed entirely" and "merged into a single
  # call that lost a trigger" regressions.
  local helper_hits=0
  helper_hits="$(grep -c 'bridge_agent_state_dir_self_heal "\$agent"' "$daemon_sh" || true)"
  if (( helper_hits < 3 )); then
    smoke_fail "T6 teeth: bridge-daemon.sh has only ${helper_hits} 'bridge_agent_state_dir_self_heal \"\$agent\"' invocation(s); expected >=3 (one per wake site) — #1269 regressed"
  fi

  local trigger=""
  for trigger in always_on_wake on_demand_wake cron_dispatch_wake; do
    local mark=""
    mark="$(grep -F "trigger=$trigger" "$daemon_sh" || true)"
    if [[ -z "$mark" ]]; then
      smoke_fail "T6 teeth: bridge-daemon.sh missing per-wake-site trigger marker 'trigger=$trigger' — #1269 regressed (per-site signature lost)"
    fi
  done
}

# ---------------------------------------------------------------------
# T_dry_run_seq — R2 (codex r1 BLOCKING): dry-run side-effect-free
#                 sequence reproduction.
#
# Codex r1 BLOCKING repro:
#   - first  `bridge-run.sh <a> --continue --dry-run` => marker created
#     by the resume gate (PRE-R2 bug)
#   - second `bridge-run.sh <a> --continue --dry-run` => marker now
#     exists, so the gate falls through to the lost-state die branch
#     with rc=1 + "session_id missing", even though no real launch
#     ever happened
#
# Post-R2 contract:
#   step 1: first dry-run                => rc=0, marker NOT created
#   step 2: second dry-run (same agent)  => rc=0, fresh-state preserved,
#                                            marker still NOT created
#   step 3: simulated real launch        => marker created (touch
#                                            simulates the post-dry-run
#                                            real-launch block)
#   step 4: post-launch dry-run with     => rc != 0, lost-state die
#           empty session_id                (#1248 gate path preserved)
#
# Step 3 simulates the real-launch marker write rather than spawning
# claude (the smoke does not have an engine). Step 4 covers the
# already-implemented T2 contract from the same agent's lifecycle so
# we prove the whole sequence end-to-end.
# ---------------------------------------------------------------------
test_dry_run_sequence_side_effect_free() {
  local agent="e-Tseq-dryrun"
  write_dryrun_roster "$agent" 1 ""

  local agent_state_dir="$BRIDGE_STATE_DIR/agents/$agent"
  rm -rf "$agent_state_dir" 2>/dev/null || true

  local marker="$BRIDGE_STATE_DIR/agents/$agent/launch.history"

  # Step 1: first dry-run.
  local out1=""
  local rc1=0
  set +e
  out1="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"
  rc1=$?
  set -e
  smoke_assert_eq "0" "$rc1" \
    "T_dry_run_seq step 1: first dry-run exits 0"
  smoke_assert_contains "$out1" "fresh first-wake" \
    "T_dry_run_seq step 1: fresh-first-wake info breadcrumb fires"
  smoke_assert_not_contains "$out1" "session_id missing" \
    "T_dry_run_seq step 1: no lost-state die on first dry-run"
  if [[ -f "$marker" ]]; then
    smoke_fail "T_dry_run_seq step 1: marker MUST NOT exist after first dry-run (codex r1 BLOCKING: dry-run poisons fresh-install state); found at $marker"
  fi

  # Step 2: second dry-run on the same agent — must still be fresh state,
  # NOT lost-state. This is the codex r1 direct repro.
  local out2=""
  local rc2=0
  set +e
  out2="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"
  rc2=$?
  set -e
  smoke_assert_eq "0" "$rc2" \
    "T_dry_run_seq step 2: SECOND dry-run still exits 0 (no die from poisoned marker)"
  smoke_assert_contains "$out2" "fresh first-wake" \
    "T_dry_run_seq step 2: fresh-first-wake breadcrumb still fires (fresh state preserved)"
  smoke_assert_not_contains "$out2" "session_id missing" \
    "T_dry_run_seq step 2: second dry-run does NOT trip lost-state die (codex r1 BLOCKING repro)"
  if [[ -f "$marker" ]]; then
    smoke_fail "T_dry_run_seq step 2: marker MUST STILL NOT exist after second dry-run; found at $marker (R2 regression: dry-run is no longer side-effect-free)"
  fi

  # Step 3: simulate a real launch reaching the post-dry-run real-launch
  # block — that block touches the marker once. The smoke can't spawn
  # claude; we simulate the marker write inline, exactly as the
  # production block does.
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  : >"$marker"
  smoke_assert_file_exists "$marker" \
    "T_dry_run_seq step 3: simulated real launch creates marker"

  # Step 4: post-launch dry-run with empty session_id => lost-state die.
  # Same gate path as T2, but exercised on the same agent's lifecycle so
  # the whole sequence (fresh -> fresh -> launched -> lost) is covered
  # end-to-end.
  local out4=""
  local rc4=0
  set +e
  out4="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"
  rc4=$?
  set -e
  if (( rc4 == 0 )); then
    smoke_fail "T_dry_run_seq step 4: expected non-zero rc from post-launch lost-state dry-run, got rc=0; out=$out4"
  fi
  smoke_assert_contains "$out4" "session_id missing" \
    "T_dry_run_seq step 4: lost-state die fires once marker is present (#1248 gate preserved)"
}

# ---------------------------------------------------------------------
# T_neg_dry_run_marker — R2 teeth: marker creation must NOT live
# inside the resume gate, and must NOT live inside the dry-run echo
# block. If a future PR re-introduces in-gate marker creation, the
# dry-run-poisoning bug returns. Grep-based regression catcher.
# ---------------------------------------------------------------------
test_teeth_dry_run_marker_deferred() {
  local runner="$REPO_ROOT/bridge-run.sh"
  smoke_assert_file_exists "$runner" \
    "T_neg_dry_run_marker: bridge-run.sh exists"

  # Must reference the deferred-marker hint variable, proving the gate
  # captures intent and a downstream block consumes it.
  local hit=""
  hit="$(grep -F 'BRIDGE_RUN_PENDING_FRESH_MARKER' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T_neg_dry_run_marker: BRIDGE_RUN_PENDING_FRESH_MARKER deferred-marker hint missing — R2 fix regressed (codex r1 BLOCKING)"
  fi

  # Must mention the codex r1 BLOCKING context so a future hand cannot
  # delete the deferral without seeing why it exists.
  hit="$(grep -F 'dry-run poisoning' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T_neg_dry_run_marker: 'dry-run poisoning' rationale comment missing in bridge-run.sh — R2 fix regressed"
  fi

  # The resume gate must NOT contain the touch/echo-into-marker call
  # any more. Search the gate-only line range for ': >"$_gate_launch_history"'
  # and assert no hit. (Awk over the file to scope: from the gate
  # entry to the closing `fi` two stanzas down.)
  local gate_section=""
  gate_section="$(awk '/_resume_gate_enabled="\$\{BRIDGE_AGENT_RESUME_GATE_ENABLED:-1\}"/,/unset _resume_gate_enabled/' "$runner")"
  if [[ -z "$gate_section" ]]; then
    smoke_fail "T_neg_dry_run_marker: unable to extract resume-gate section from bridge-run.sh — file shape changed unexpectedly"
  fi
  if echo "$gate_section" | grep -F ': >"$_gate_launch_history"' >/dev/null 2>&1; then
    smoke_fail "T_neg_dry_run_marker: in-gate marker touch re-introduced (': >\"\$_gate_launch_history\"') — codex r1 BLOCKING dry-run poisoning regressed"
  fi
  if echo "$gate_section" | grep -F 'mkdir -p "$(dirname "$_gate_launch_history")"' >/dev/null 2>&1; then
    smoke_fail "T_neg_dry_run_marker: in-gate marker parent mkdir re-introduced — codex r1 BLOCKING dry-run poisoning regressed"
  fi
}

smoke_run "T1 fresh first-wake skips die + dry-run leaves no marker (R2)" test_fresh_first_wake_no_die
smoke_run "T2 lost-state still fails loud with (a)/(b)/(c)"          test_lost_state_still_fails_loud
smoke_run "T3 continue=0 / --no-continue gate not entered"           test_continue0_unchanged
smoke_run "T4 daemon wake self_heal wired at all 3 sites"            test_daemon_wake_self_heal_grep
smoke_run "T5 teeth: bridge-run.sh fresh-state branch present"       test_teeth_fresh_state_branch_present
smoke_run "T6 teeth: bridge-daemon.sh self-heal sites all present"   test_teeth_daemon_self_heal_sites_present
smoke_run "T_dry_run_seq: dry-run side-effect-free across 2 runs (R2)" test_dry_run_sequence_side_effect_free
smoke_run "T_neg_dry_run_marker: in-gate marker creation absent (R2)"  test_teeth_dry_run_marker_deferred
