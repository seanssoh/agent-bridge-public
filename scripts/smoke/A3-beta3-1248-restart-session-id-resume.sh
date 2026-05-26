#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/A3-beta3-1248-restart-session-id-resume.sh — Issue #1248.
#
# v0.15.0-beta3 Lane A3 — agent restart spawned a fresh Claude session
# instead of resuming because `bridge_refresh_agent_session_id` swallowed
# every persist-write failure into a silent `>/dev/null 2>&1 || true`,
# and the `--no-continue` vs `continue=1` CLI/roster matrix in
# `bridge-run.sh` had no fail-loud gate when the persisted resume id was
# missing. The two layers covered by THIS smoke (layer 1 — the daemon's
# stale supplementary-group set that prevents the controller from
# creating `state/agents/<a>/` in the first place — is Lane A12):
#
#   Layer 2 — `bridge_refresh_agent_session_id` (lib/bridge-state.sh):
#     on `bridge_persist_agent_state` write failure, fail loud with the
#     structured reason `state_dir_write_failed:session_id agent=… path=… rc=…`
#     instead of swallowing the rc. On success, emit a `[session-id]`
#     stderr breadcrumb + `session_id_persisted` audit row.
#
#   Layer 3 — `bridge-run.sh` reconcile:
#     after `--continue` / `--no-continue` overrides have folded into
#     `BRIDGE_AGENT_CONTINUE`, the script fails loud when effective
#     continue=1 AND `bridge_agent_session_id` is empty. Single source
#     of truth for the resume verb; no more silent `--continue` fallback
#     when the persisted id is missing.
#
# Test plan:
#   T1: `bridge_refresh_agent_session_id` fails loud on persist-write
#       failure. Mock `bridge_persist_agent_state` as a 1-returning stub
#       so the function reaches the new bridge_die path; assert the
#       structured reason text appears in stderr.
#   T2: On a successful persist, the new `[session-id] agent=… id=… written=…`
#       breadcrumb is emitted to stderr.
#   T3: `bridge-run.sh --dry-run` with continue=1 + session_id present
#       emits a resume verb in the launch_cmd (claude `--resume <id>`
#       or codex `resume <id>`).
#   T4: `bridge-run.sh --dry-run` with continue=1 + session_id empty
#       fails loud with the exact remediation message ((a)/(b)/(c)
#       option list).
#   T5: `bridge-run.sh --dry-run --no-continue` (and roster continue=0)
#       emits NO resume verb in the launch_cmd. Includes the equivalent
#       case where the CLI override flips a roster continue=1 to 0.
#   T6 (teeth): revert the fail-loud fix in `bridge_refresh_agent_session_id`
#       and assert T1's contract no longer holds. Asserts the structured
#       text (`state_dir_write_failed:session_id`) is present in
#       lib/bridge-state.sh — if a future PR removes the fix, this
#       teeth check fails citing #1248.
#   T7 (teeth): revert the reconcile gate in `bridge-run.sh` and assert
#       T4's contract no longer holds. Asserts the structured remediation
#       text is present in bridge-run.sh — if removed, fails citing
#       #1248.
#   T8 (r2, codex r1 BLOCKING): `bridge-start.sh`'s post-startup
#       `bridge_refresh_agent_session_id` call must NOT swallow stderr or
#       use `|| true`. The function `bridge_die`s on persist-write
#       failure; the prior shape `>/dev/null 2>&1 || true` redirected the
#       structured reason to /dev/null AND could not intercept the
#       process-exiting `bridge_die`, so bridge-start.sh died silently
#       after tmux creation. Asserts (a) the broken shape (re-introduced
#       via a stubbed `f(){ exit 1; }`) reproduces the silent-death
#       symptom and (b) the post-r2 shape lets the structured stderr
#       reach the parent.
#   T9 (teeth, r2): grep-asserts bridge-start.sh does NOT contain the
#       `>/dev/null 2>&1 ... || true` swallow on the
#       `bridge_refresh_agent_session_id` call site — if a future PR
#       re-introduces it, this smoke fails citing codex r1 finding.
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
  echo "[smoke:A3-beta3-1248-restart-session-id-resume] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="A3-beta3-1248-restart-session-id-resume"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "A3-beta3-1248-restart-session-id-resume"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Source the library functions under test.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_refresh_agent_session_id >/dev/null; then
  smoke_fail "bridge_refresh_agent_session_id not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_persist_agent_state >/dev/null; then
  smoke_fail "bridge_persist_agent_state not defined (sanity check)"
fi
if ! declare -F bridge_audit_log >/dev/null; then
  smoke_fail "bridge_audit_log not defined (sanity check)"
fi

# Seed a minimal in-memory agent for the function-level tests (T1/T2).
bridge_reset_roster_maps

AGENT_ID="a3-1248"
WORKDIR="$SMOKE_TMP_ROOT/work-$AGENT_ID"
mkdir -p "$WORKDIR"

BRIDGE_AGENT_IDS=("$AGENT_ID")
BRIDGE_AGENT_DESC["$AGENT_ID"]="$AGENT_ID smoke fixture"
BRIDGE_AGENT_ENGINE["$AGENT_ID"]="claude"
BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_ID"
BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$WORKDIR"
BRIDGE_AGENT_LOOP["$AGENT_ID"]="1"
BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="1"
BRIDGE_AGENT_SOURCE["$AGENT_ID"]="static"
BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="$(bridge_history_key_for claude "$AGENT_ID" "$WORKDIR")"
BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]=""

HISTORY_FILE="$(bridge_history_file_for_agent "$AGENT_ID")"
mkdir -p "$(dirname "$HISTORY_FILE")"

# Avoid the sudo-handoff write path (not available in the smoke env).
bridge_state_v2_isolated_target() { return 1; }

# Shadow `bridge_detect_session_id` so the refresh function does not
# need a real Claude transcript to "discover" an id. The smoke controls
# what gets returned from this helper to drive T1/T2.
_A3_INJECTED_SID=""
bridge_detect_session_id() {
  printf '%s' "$_A3_INJECTED_SID"
}

# ---------------------------------------------------------------------
# T1 — bridge_refresh_agent_session_id fails loud on persist-write
#      failure. Mock bridge_persist_agent_state to fail; assert the
#      structured reason `state_dir_write_failed:session_id` lands in
#      stderr.
# ---------------------------------------------------------------------
test_persist_failure_fails_loud() {
  _A3_INJECTED_SID="sid-T1-$$"
  BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]=""

  # Stash the real persister so we can restore at the end of the test.
  eval "$(declare -f bridge_persist_agent_state | sed '1s/^/_orig_t1_/')"
  # shellcheck disable=SC2329  # invoked indirectly via bridge_refresh_agent_session_id
  bridge_persist_agent_state() {
    # Simulate a state-dir write failure (mkdir or printf rc=1).
    return 1
  }

  local stderr_capture="$SMOKE_TMP_ROOT/t1.stderr"
  local rc=0
  # The function calls bridge_die which exits the subshell.
  # We run it under a subshell + `|| rc=$?` to capture rc + stderr.
  set +e
  ( bridge_refresh_agent_session_id "$AGENT_ID" 1 0 ) >/dev/null 2>"$stderr_capture"
  rc=$?
  set -e

  # Restore the real persister regardless of pass/fail.
  eval "$(declare -f _orig_t1_bridge_persist_agent_state | sed 's/^_orig_t1_//')"
  unset -f _orig_t1_bridge_persist_agent_state 2>/dev/null || true

  local stderr_body=""
  stderr_body="$(cat "$stderr_capture" 2>/dev/null || true)"

  smoke_assert_eq "1" "$rc" \
    "T1 bridge_refresh_agent_session_id returned non-zero on persist failure"
  smoke_assert_contains "$stderr_body" "state_dir_write_failed:session_id" \
    "T1 structured reason text appears in stderr"
  smoke_assert_contains "$stderr_body" "agent=$AGENT_ID" \
    "T1 stderr carries the agent name"
  smoke_assert_contains "$stderr_body" "rc=1" \
    "T1 stderr carries the persist rc"
}

# ---------------------------------------------------------------------
# T2 — On successful persist, the function emits a `[session-id]`
#      breadcrumb to stderr (the ops-visible success signal the brief
#      called out).
# ---------------------------------------------------------------------
test_success_emits_breadcrumb() {
  _A3_INJECTED_SID="sid-T2-aabbccddeeff0011"
  BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]=""

  local stderr_capture="$SMOKE_TMP_ROOT/t2.stderr"
  local stdout_capture="$SMOKE_TMP_ROOT/t2.stdout"
  set +e
  bridge_refresh_agent_session_id "$AGENT_ID" 1 0 >"$stdout_capture" 2>"$stderr_capture"
  local rc=$?
  set -e

  smoke_assert_eq "0" "$rc" \
    "T2 bridge_refresh_agent_session_id returned 0 on success"

  local stderr_body=""
  stderr_body="$(cat "$stderr_capture" 2>/dev/null || true)"
  smoke_assert_contains "$stderr_body" "[session-id]" \
    "T2 [session-id] breadcrumb tag present in stderr"
  smoke_assert_contains "$stderr_body" "agent=$AGENT_ID" \
    "T2 breadcrumb carries the agent name"
  # The function prints the first 8 chars of the id.
  smoke_assert_contains "$stderr_body" "id=sid-T2-a" \
    "T2 breadcrumb carries the short id"

  local stdout_body=""
  stdout_body="$(cat "$stdout_capture" 2>/dev/null || true)"
  smoke_assert_eq "$_A3_INJECTED_SID" "$stdout_body" \
    "T2 stdout still carries the full session id"
}

# ---------------------------------------------------------------------
# Helper for T3/T4/T5: write a minimal roster on disk so `bridge-run.sh`
# (a fresh subprocess) can load it. The roster is intentionally minimal
# — `bridge-run.sh --dry-run` exits before any tmux/launch side effects,
# so just engine + workdir + launch_cmd + continue is enough.
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
# T3 — continue=1 + session_id present -> resume verb in launch_cmd.
#      The launch_cmd builder emits `--resume <id>` (claude) when the
#      reconcile gate passes (session_id non-empty). To keep the
#      transcript-freshness resolver (bridge_resolve_resume_session_id)
#      happy without driving a real Claude binary, seed a minimal
#      .jsonl under a smoke-scoped CLAUDE_CONFIG_DIR.
# ---------------------------------------------------------------------
test_continue1_with_session_id_emits_resume() {
  local agent="a3-T3"
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  write_dryrun_roster "$agent" 1 "$sid"
  local workdir="$BRIDGE_AGENT_HOME_ROOT/$agent"

  # Seed a minimal Claude transcript so the resolver accepts the
  # candidate as eligible. Slug is workdir.replace("/", "-") and
  # workdir.replace("/", "-").replace(".", "-"); the resolver tries both.
  # The realpath form is what ends up persistent on disk.
  local claude_root="$SMOKE_TMP_ROOT/claude-config-T3"
  local resolved_workdir
  resolved_workdir="$(cd -P "$workdir" && pwd -P)"
  local slug="${resolved_workdir//\//-}"
  local projects_dir="$claude_root/projects/$slug"
  mkdir -p "$projects_dir"
  printf '{"role":"user","content":"smoke-T3"}\n' >"$projects_dir/$sid.jsonl"
  # Ensure recent mtime (well within the 48h window).
  touch "$projects_dir/$sid.jsonl"

  local out=""
  out="$(CLAUDE_CONFIG_DIR="$claude_root" bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"

  smoke_assert_contains "$out" "agent=$agent" \
    "T3 dry-run echoes agent"
  smoke_assert_contains "$out" "continue=1" \
    "T3 dry-run echoes continue=1"
  smoke_assert_contains "$out" "session_id=$sid" \
    "T3 dry-run echoes the persisted session_id"
  smoke_assert_contains "$out" "--resume $sid" \
    "T3 launch_cmd emits --resume <id> when continue=1 + session_id present"
}

# ---------------------------------------------------------------------
# T4 — continue=1 + session_id empty -> fail-loud with the exact
#      remediation message. This is the #1248 surface.
# ---------------------------------------------------------------------
test_continue1_empty_session_id_fails_loud() {
  local agent="a3-T4"
  write_dryrun_roster "$agent" 1 ""

  local out=""
  local rc=0
  set +e
  out="$(bash "$REPO_ROOT/bridge-run.sh" "$agent" --continue --dry-run 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    smoke_fail "T4 expected non-zero rc from bridge-run.sh when continue=1 + session_id empty, got rc=0; out=$out"
  fi
  smoke_assert_contains "$out" "session_id missing" \
    "T4 error message starts with session_id missing"
  smoke_assert_contains "$out" "(a) run agent first interactively to capture" \
    "T4 remediation (a) present"
  smoke_assert_contains "$out" "(b) set continue=0 explicitly" \
    "T4 remediation (b) present"
  smoke_assert_contains "$out" "(c) check #1246 daemon supp-group state" \
    "T4 remediation (c) cites #1246"
  smoke_assert_contains "$out" "agent=$agent" \
    "T4 message carries the agent name"
}

# ---------------------------------------------------------------------
# T5 — continue=0 (or `--no-continue` CLI override) -> NO resume verb.
#      Two cases: roster continue=0 with no override, AND roster
#      continue=1 with `--no-continue` overriding to 0.
# ---------------------------------------------------------------------
test_continue0_emits_no_resume_verb() {
  # Case A: roster continue=0, session_id empty (the typical fresh-start
  # path). With continue=0 the gate is not entered and the launch_cmd
  # contains no --resume verb.
  local agent_a="a3-T5a"
  write_dryrun_roster "$agent_a" 0 ""
  local out_a=""
  out_a="$(bash "$REPO_ROOT/bridge-run.sh" "$agent_a" --no-continue --dry-run 2>&1)"
  smoke_assert_contains "$out_a" "agent=$agent_a" \
    "T5a dry-run echoes agent"
  smoke_assert_contains "$out_a" "continue=0" \
    "T5a dry-run echoes continue=0"
  smoke_assert_not_contains "$out_a" "--resume" \
    "T5a launch_cmd contains no --resume verb when continue=0"
  smoke_assert_not_contains "$out_a" "--continue" \
    "T5a launch_cmd contains no --continue verb when continue=0"

  # Case B: roster continue=1 BUT `--no-continue` CLI flag overrides to
  # 0. The gate must NOT fire (because effective continue is 0 after the
  # override is folded in) and the launch_cmd must not carry a resume
  # verb. This is the path bridge-start.sh exercises via
  # FORCE_FRESH_SESSION on first boot.
  local agent_b="a3-T5b"
  write_dryrun_roster "$agent_b" 1 "sid-T5b-stale"
  local out_b=""
  out_b="$(bash "$REPO_ROOT/bridge-run.sh" "$agent_b" --no-continue --dry-run 2>&1)"
  smoke_assert_contains "$out_b" "agent=$agent_b" \
    "T5b dry-run echoes agent"
  smoke_assert_contains "$out_b" "continue=0" \
    "T5b --no-continue override flips effective continue to 0"
  smoke_assert_not_contains "$out_b" "--resume" \
    "T5b --no-continue suppresses --resume even when session_id is persisted"
}

# ---------------------------------------------------------------------
# T6 (teeth) — revert the fail-loud fix in
# `bridge_refresh_agent_session_id` and the T1 contract no longer holds.
# Asserts the structured text is present in lib/bridge-state.sh so a
# future PR that removes the fix triggers this smoke citing #1248.
# ---------------------------------------------------------------------
test_teeth_layer2_fix_present() {
  local state_lib="$REPO_ROOT/lib/bridge-state.sh"
  smoke_assert_file_exists "$state_lib" \
    "T6 teeth: lib/bridge-state.sh exists"

  local hit=""
  hit="$(grep -F 'state_dir_write_failed:session_id' "$state_lib" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T6 teeth: the Layer-2 fail-loud structured reason 'state_dir_write_failed:session_id' is missing from $state_lib — issue #1248 regressed"
  fi

  hit="$(grep -F '[session-id]' "$state_lib" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T6 teeth: the Layer-2 [session-id] success breadcrumb is missing from $state_lib — issue #1248 regressed"
  fi

  hit="$(grep -F 'session_id_persisted' "$state_lib" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T6 teeth: the session_id_persisted audit action is missing from $state_lib — issue #1248 regressed"
  fi
}

# ---------------------------------------------------------------------
# T7 (teeth) — revert the reconcile gate in `bridge-run.sh` and the T4
# contract no longer holds. Asserts the structured remediation text is
# present in bridge-run.sh so a future PR that removes the gate triggers
# this smoke citing #1248.
# ---------------------------------------------------------------------
test_teeth_layer3_gate_present() {
  local runner="$REPO_ROOT/bridge-run.sh"
  smoke_assert_file_exists "$runner" \
    "T7 teeth: bridge-run.sh exists"

  local hit=""
  hit="$(grep -F 'session_id missing' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T7 teeth: the Layer-3 reconcile gate remediation text 'session_id missing' is missing from $runner — issue #1248 regressed"
  fi

  hit="$(grep -F '(c) check #1246 daemon supp-group state' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T7 teeth: the Layer-3 reconcile gate remediation (c) is missing from $runner — issue #1248 regressed"
  fi

  hit="$(grep -F 'session_id_missing_resume_blocked' "$runner" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T7 teeth: the Layer-3 audit action 'session_id_missing_resume_blocked' is missing from $runner — issue #1248 regressed"
  fi
}

# ---------------------------------------------------------------------
# T8 (r2, codex r1 BLOCKING) — bridge-start.sh's
# bridge_refresh_agent_session_id call must NOT swallow stderr or `|| true`
# the process-exiting `bridge_die`. The broken pre-r2 shape was
# `>/dev/null 2>&1 || true`, which (a) redirected the structured reason
# to /dev/null and (b) could not intercept `bridge_die`'s `exit 1` — so
# bridge-start.sh died silently after tmux creation, swallowing
# `state_dir_write_failed:session_id`.
#
# We don't invoke the real bridge-start.sh (it requires tmux + a real
# session). Instead we exercise the exact bash behavior the codex finding
# names: a stubbed `f(){ ... exit 1; }` (mimicking bridge_die) called under
# both the broken and fixed shape, in a child bash with `set -e` to mirror
# bridge-start.sh's runtime. This is the same probe codex used in the
# brief.
# ---------------------------------------------------------------------
test_bridge_start_no_swallow_on_exit() {
  local broken_out="$SMOKE_TMP_ROOT/t8-broken.out"
  local broken_err="$SMOKE_TMP_ROOT/t8-broken.err"
  local broken_rc=0
  # Broken pre-r2 shape: stderr redirected to /dev/null AND `|| true` cannot
  # intercept exit 1. The "survived" echo line must NOT execute (proves
  # bridge-start.sh died silently), AND the structured reason must NOT
  # appear in stderr (proves the swallow was hiding it).
  set +e
  bash -c '
    set -euo pipefail
    f(){ echo "state_dir_write_failed:session_id agent=t8 path=/p rc=1" >&2; exit 1; }
    f >/dev/null 2>&1 || true
    echo "survived" >&2
  ' >"$broken_out" 2>"$broken_err"
  broken_rc=$?
  set -e
  local broken_err_body=""
  broken_err_body="$(cat "$broken_err" 2>/dev/null || true)"
  if (( broken_rc == 0 )); then
    smoke_fail "T8 broken shape rc=0 — expected the stub bash to inherit the exit and die"
  fi
  smoke_assert_not_contains "$broken_err_body" "survived" \
    "T8 broken shape: 'survived' must not execute (bridge_die exit cannot be intercepted)"
  smoke_assert_not_contains "$broken_err_body" "state_dir_write_failed:session_id" \
    "T8 broken shape: structured reason swallowed by 2>&1 (this is the codex r1 symptom)"

  # Fixed post-r2 shape: drop `2>&1` and `|| true`. Stderr is preserved;
  # bridge_die's structured reason reaches the parent. The parent still
  # dies (bridge_die's exit propagates) but loud, with the structured
  # reason visible to the operator.
  local fixed_out="$SMOKE_TMP_ROOT/t8-fixed.out"
  local fixed_err="$SMOKE_TMP_ROOT/t8-fixed.err"
  local fixed_rc=0
  set +e
  bash -c '
    set -euo pipefail
    f(){ echo "state_dir_write_failed:session_id agent=t8 path=/p rc=1" >&2; exit 1; }
    f >/dev/null
    echo "survived" >&2
  ' >"$fixed_out" 2>"$fixed_err"
  fixed_rc=$?
  set -e
  local fixed_err_body=""
  fixed_err_body="$(cat "$fixed_err" 2>/dev/null || true)"
  if (( fixed_rc == 0 )); then
    smoke_fail "T8 fixed shape rc=0 — bridge_die's exit must still propagate"
  fi
  smoke_assert_contains "$fixed_err_body" "state_dir_write_failed:session_id" \
    "T8 fixed shape: structured reason now reaches stderr (codex r1 BLOCKING closed)"
  smoke_assert_not_contains "$fixed_err_body" "survived" \
    "T8 fixed shape: bridge_die's exit still propagates (no silent continuation)"
}

# ---------------------------------------------------------------------
# T9 (teeth, r2) — grep-asserts bridge-start.sh's call site does NOT
# re-introduce the `>/dev/null 2>&1 ... || true` swallow on
# bridge_refresh_agent_session_id. If a future PR adds the swallow back,
# this smoke fails citing the codex r1 finding on PR #1259.
# ---------------------------------------------------------------------
test_teeth_bridge_start_no_swallow() {
  local start_sh="$REPO_ROOT/bridge-start.sh"
  smoke_assert_file_exists "$start_sh" \
    "T9 teeth: bridge-start.sh exists"

  # Find every NON-COMMENT line that calls bridge_refresh_agent_session_id
  # in bridge-start.sh. There should currently be exactly one such call
  # site (post-launch session_id capture). Each line must NOT contain the
  # combined `2>&1` + `|| true` swallow shape, and must not redirect
  # stderr to /dev/null.
  #
  # The grep filter strips `LINENO:` prefix first and skips lines whose
  # post-LINENO content starts with `#` (comments). Without the strip,
  # the r2-added explanatory comment in bridge-start.sh that documents
  # the OLD broken shape would false-positive this check.
  local call_lines=""
  call_lines="$(
    grep -n 'bridge_refresh_agent_session_id' "$start_sh" \
      | awk -F: '{
          ln=$1; sub(/^[^:]*:/, "", $0);
          # $0 is now the line content; ltrim and skip comments.
          s=$0; sub(/^[[:space:]]+/, "", s);
          if (s ~ /^#/) next;
          print ln ":" $0;
        }' \
      || true
  )"
  if [[ -z "$call_lines" ]]; then
    smoke_fail "T9 teeth: bridge-start.sh has no non-comment bridge_refresh_agent_session_id call — issue #1248 regressed (call removed?)"
  fi

  # Inspect each call line for the swallow shape.
  local line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"2>&1"* && "$line" == *"|| true"* ]]; then
      smoke_fail "T9 teeth: bridge-start.sh re-introduced the '2>&1 ... || true' swallow on bridge_refresh_agent_session_id (codex r1 BLOCKING on PR #1259): $line"
    fi
    if [[ "$line" == *">/dev/null 2>&1"* ]]; then
      smoke_fail "T9 teeth: bridge-start.sh redirects bridge_refresh_agent_session_id stderr to /dev/null — structured 'state_dir_write_failed:session_id' would be hidden: $line"
    fi
  done <<<"$call_lines"
}

smoke_run "T1 persist-write failure fails loud"               test_persist_failure_fails_loud
smoke_run "T2 successful persist emits [session-id]"          test_success_emits_breadcrumb
smoke_run "T3 continue=1 + sid present -> --resume verb"      test_continue1_with_session_id_emits_resume
smoke_run "T4 continue=1 + sid empty -> fail-loud + remediation" test_continue1_empty_session_id_fails_loud
smoke_run "T5 continue=0 / --no-continue -> no resume verb"   test_continue0_emits_no_resume_verb
smoke_run "T6 teeth: Layer-2 fail-loud fix present"           test_teeth_layer2_fix_present
smoke_run "T7 teeth: Layer-3 reconcile gate present"          test_teeth_layer3_gate_present
smoke_run "T8 bridge-start.sh stderr no longer swallowed"     test_bridge_start_no_swallow_on_exit
smoke_run "T9 teeth: bridge-start.sh has no 2>&1+|| true swallow" test_teeth_bridge_start_no_swallow

smoke_log "all checks passed"
