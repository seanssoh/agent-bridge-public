#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/4494-integrated-dynamic-recovery.sh — Task #4494 Wave D.
#
# Integrated regression smoke for the operator's 2026-05-14 `crm-test`
# dynamic-agent recovery scenario. Exercises the three already-shipped
# surface fixes from #826 / #827 / #828 in a single end-to-end flow:
#
#   Case A — bridge-sync grace preserves a freshly-created dynamic .env.
#            Vector: #826 (PR #837). A 5-minute-old dynamic agent with no
#            tmux session must survive the default 300s grace window
#            instead of being pruned the way the legacy 15s hard-coded
#            window did when startup was slow.
#
#   Case B — live Claude session id accepted before the transcript jsonl
#            exists. Vector: #827 (PR #840). A `~/.claude/sessions/<pid>.json`
#            with matching cwd and an alive pid resolves to a non-empty
#            session id (rc=0) even when no transcript file exists yet.
#
#   Case C — default skill render path does NOT recurse into
#            `agent-bridge --help`. Vector: #828 (PR #839). With
#            BRIDGE_RENDER_SKILL_AUTO_HELP unset, the gate short-circuits
#            before `bridge_render_project_bridge_auto_help_section` runs,
#            so the stubbed `agent-bridge` sentinel stays empty. The
#            opt-in path (env=1) flips the sentinel to populated — a
#            positive control proving the stub is wired correctly.
#
#   Case D — combined recovery flow timing. Times Case A + Case B + Case
#            C (default) in sequence and asserts the wall time stays
#            under 10s on Bash 5.3.9 macOS. Loose bound — each surface
#            fix lands sub-second; integrated should be comfortably
#            under the cap. Catches future regressions where any of the
#            three fixes accidentally regrows a slow path.
#
# Architectural notes for reviewers:
#
# * Case A reuses the Wave A pattern (scripts/smoke/dynamic-start-grace.sh):
#   sources bridge-sync.sh and calls `prune_missing_dynamic_agents`
#   against stubbed dependency helpers. Driving the full
#   `bridge_sync_main` pipeline is not viable on macOS Bash 5.3.9
#   because the downstream `bridge_render_active_roster` helper uses a
#   Python heredoc-stdin form that recurs the Bash 5.3.9 heredoc_write
#   deadlock class tracked under #815. That deadlock is independent of
#   #826's grace fix and out of scope for Wave D. (Forbidden pattern
#   strings intentionally omitted from this comment so the footgun #11
#   self-audit grep recipe does not flag a textual mention as a real
#   callsite.)
#
# * Case B reuses the Wave B pattern
#   (scripts/smoke/claude-live-session-pretranscript.sh): sources
#   bridge-lib.sh under an isolated v2 layout, then pins HOME to a
#   fixture tree so `bridge_detect_claude_session_id` and
#   `bridge_resolve_resume_session_id` resolve against the synthesized
#   sessions/<pid>.json instead of the operator's real `~/.claude`.
#
# * Case C reuses the Wave C pattern
#   (scripts/smoke/skill-render-no-help-recursion.sh): stubs
#   `agent-bridge` to append to a sentinel on every invocation, then
#   exercises the gate-controlled surface via the tracked
#   scripts/smoke/4494-integrated-helpers/skill-gate-driver.sh helper
#   instead of calling the parent `bridge_render_project_bridge_reference`
#   directly. The parent function's curated-reference heredoc body is
#   the unrelated Bash 5.3.9 heredoc_write deadlock class — calling it
#   under `>file` redirection wedges the smoke. Wave C's static
#   `declare -f` gate check plus the dynamic gate-driver pair is the
#   safe target the brief explicitly permits ("or its auto-help helper
#   isolation"). (Forbidden pattern strings intentionally omitted from
#   this comment so the footgun #11 self-audit grep recipe does not
#   flag a textual mention as a real callsite.)
#
# * The driver helper body lives under
#   scripts/smoke/4494-integrated-helpers/skill-gate-driver.sh as a
#   tracked file rather than being embedded inside this wrapper as a
#   heredoc-to-file body. The heredoc-to-file pattern with a multi-line
#   body recurs the Bash 5.3.9 heredoc_write deadlock class — see
#   feedback_bash_heredoc_write_class_recurrence.md and the Wave B/C
#   smoke notes. (Forbidden pattern strings intentionally omitted from
#   this comment so the footgun #11 self-audit grep recipe does not
#   flag a textual mention as a real callsite.)
#
# Footgun #11 self-audit: this fixture writes all multi-line bash bodies
# via tracked helper files plus `printf '%s\n'` + plain redirection (no
# heredoc-to-file, no here-string-to-stdin, no Python heredoc-stdin
# form). The verification matrix in the Wave D brief greps this file
# and the helpers directory for the catalog of forbidden patterns; any
# reintroduction must fail the grep.

# Bash 4+ re-exec (associative arrays + the v2 layout helpers).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:4494-integrated-dynamic-recovery] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="4494-integrated-dynamic-recovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Resolve a Bash 4+ binary path for the sub-driver invocation in Case C
# (mirrors the Wave C smoke). We already re-exec'd this wrapper into Bash
# 4+ so `$BASH` is a safe candidate; the explicit fallbacks cover hosts
# where `$BASH` was inherited from a 3.2 caller.
BASH4_BIN="${BASH4_BIN:-}"
if [[ -z "$BASH4_BIN" ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH:-}"; do
    [[ -n "$_candidate" && -x "$_candidate" ]] || continue
    if "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BASH4_BIN="$_candidate"
      break
    fi
  done
fi
[[ -n "$BASH4_BIN" ]] || smoke_fail "no Bash 4+ interpreter on PATH; set BASH4_BIN"

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd python3

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="python3"

# A pid that is overwhelmingly likely to be unallocated on every platform
# we run on. Used as a sanity-guarded sentinel only in negative-path
# coverage upstream (Wave B). Case B here pins the live orchestrator pid.
DEAD_PID="999999"

# Nanosecond clock for Case D timing. BSD `date` lacks `%N`; python3 is
# already required by the smoke suite, so this adds no new dependency.
now_ns() {
  "$PY_BIN" -c 'import time; print(int(time.time()*1e9))'
}

elapsed_ns_since() {
  local start_ns="$1"
  local end_ns
  end_ns="$(now_ns)"
  printf '%s' "$((end_ns - start_ns))"
}

# ===========================================================================
# Stub surface for Case A — mirrors scripts/smoke/dynamic-start-grace.sh.
# ===========================================================================

declare -g -A STUB_DYNAMIC_AGENTS=()
declare -g -A STUB_CREATED_AT=()
declare -g -A STUB_ACTIVE=()
declare -g -A STUB_ARCHIVED=()
declare -g -A STUB_REMOVED=()

# Re-define the bridge helpers `prune_missing_dynamic_agents` calls,
# AFTER sourcing bridge-sync.sh below, so the stubbed environment
# behaves identically to the live one from the grace-check's point of
# view without driving a real tmux/queue/roster.
define_case_a_stubs() {
  bridge_agent_is_active() {
    [[ -n "${STUB_ACTIVE[$1]+x}" ]]
  }
  bridge_dynamic_agent_ids() {
    local a
    for a in "${!STUB_DYNAMIC_AGENTS[@]}"; do
      printf '%s\n' "$a"
    done | sort
  }
  bridge_archive_dynamic_agent() {
    STUB_ARCHIVED[$1]=1
    return 0
  }
  bridge_remove_dynamic_agent_file() {
    STUB_REMOVED[$1]=1
    return 0
  }
  bridge_agent_clear_idle_marker() { return 0; }
  bridge_agent_session_id() { return 0; }
  bridge_warn() {
    printf '[warn] %s\n' "$*" >&2
  }
}

reset_case_a_state() {
  unset STUB_DYNAMIC_AGENTS STUB_CREATED_AT STUB_ACTIVE STUB_ARCHIVED STUB_REMOVED
  unset BRIDGE_AGENT_CREATED_AT CLAIMED_SESSION_IDS PRUNED_DYNAMIC
  declare -g -A STUB_DYNAMIC_AGENTS=()
  declare -g -A STUB_CREATED_AT=()
  declare -g -A STUB_ACTIVE=()
  declare -g -A STUB_ARCHIVED=()
  declare -g -A STUB_REMOVED=()
  declare -g -A BRIDGE_AGENT_CREATED_AT=()
  declare -g -A CLAIMED_SESSION_IDS=()
  declare -g -A PRUNED_DYNAMIC=()
}

register_dynamic_agent() {
  local agent="$1"
  local created_at="$2"
  STUB_DYNAMIC_AGENTS["$agent"]=1
  STUB_CREATED_AT["$agent"]="$created_at"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$created_at"
}

# Sourcing bridge-sync.sh below also brings in bridge-lib.sh + the lib/
# tree. bridge-lib.sh's top-level checks the v2 layout marker we wrote
# in smoke_setup_bridge_home, so the source is happy. The case-A stubs
# above intentionally override the few helpers `prune_missing_dynamic_agents`
# calls so we never need a real tmux session, queue, or roster.
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-sync.sh"

declare -F resolve_dynamic_start_grace_seconds >/dev/null \
  || smoke_fail "resolve_dynamic_start_grace_seconds missing after sourcing bridge-sync.sh"
declare -F prune_missing_dynamic_agents >/dev/null \
  || smoke_fail "prune_missing_dynamic_agents missing after sourcing bridge-sync.sh"

define_case_a_stubs

# ===========================================================================
# Case A — bridge-sync grace preserves a 5-minute-old dynamic .env.
# ===========================================================================

case_a_grace_preserves_recent_dynamic() {
  reset_case_a_state
  define_case_a_stubs  # re-bind after reset clobbers function locals

  local now within_grace_age
  now="$(date +%s)"
  # The operator's repro is a dynamic agent that has been alive long
  # enough for the legacy 15s hard-coded window to have pruned it but
  # still well within the Wave A 300s default. 240s (4 minutes) is
  # decisively inside the default grace and decisively outside the
  # legacy window — the regression vector. The fix's comparison is
  # `age < grace` (strict), so 300s exact would tip into the prune
  # branch; 240s preserves the boundary headroom the brief's
  # "5-minute-old" shorthand implies.
  within_grace_age="$((now - 240))"
  register_dynamic_agent "crm-test" "$within_grace_age"

  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents

  [[ -z "${STUB_ARCHIVED[crm-test]+x}" ]] \
    || smoke_fail "Case A: 240s-old dynamic 'crm-test' was archived under default 300s grace (regression of #826)"
  [[ -z "${STUB_REMOVED[crm-test]+x}" ]] \
    || smoke_fail "Case A: 240s-old dynamic 'crm-test' file was removed under default 300s grace (regression of #826)"
  [[ -z "${PRUNED_DYNAMIC[crm-test]+x}" ]] \
    || smoke_fail "Case A: 'crm-test' marked as PRUNED_DYNAMIC despite 240s age and default 300s grace"

  # Belt-and-braces: a 60s-old dynamic must also survive — matches Wave A T2
  # directly so any regression that re-introduces the 15s window also fails
  # this sub-assertion (and surfaces with a clearer message than T2 alone).
  reset_case_a_state
  define_case_a_stubs
  register_dynamic_agent "crm-test-young" "$((now - 60))"
  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents
  [[ -z "${STUB_ARCHIVED[crm-test-young]+x}" ]] \
    || smoke_fail "Case A: 60s-old dynamic was archived under default grace (regression of #826 to legacy 15s window)"
}

# ===========================================================================
# Case A driver as a callable closure for the Case D timing harness.
# ===========================================================================

run_case_a_for_timing() {
  reset_case_a_state
  define_case_a_stubs
  local now
  now="$(date +%s)"
  # Match case_a_grace_preserves_recent_dynamic's in-grace age (240s).
  register_dynamic_agent "crm-test" "$((now - 240))"
  unset BRIDGE_DYNAMIC_START_GRACE_SECONDS
  prune_missing_dynamic_agents
  [[ -z "${STUB_ARCHIVED[crm-test]+x}" ]] \
    || smoke_fail "Case D[A]: prune incorrectly archived 'crm-test' during timing pass"
}

# ===========================================================================
# Setup for Cases B and D[B] — synthesize the live Claude session record.
# Mirrors the Wave B helper. Echoes the synthesized session id.
# ===========================================================================

make_claude_session_fixture() {
  local fixture_home="$1"
  local pid="$2"
  local cwd="$3"
  local name="${4:-crm-test}"

  local sid sessions_dir session_file body_tmp
  sid="$("$PY_BIN" -c 'import uuid; print(uuid.uuid4())')"
  sessions_dir="$fixture_home/.claude/sessions"
  mkdir -p "$sessions_dir"
  session_file="$sessions_dir/${pid}.json"

  body_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-4494-body.XXXXXX")"
  PID="$pid" SID="$sid" CWD="$cwd" NAME="$name" \
    "$PY_BIN" -c '
import json
import os

print(
    json.dumps(
        {
            "pid": int(os.environ["PID"]),
            "sessionId": os.environ["SID"],
            "cwd": os.environ["CWD"],
            "name": os.environ["NAME"],
            "status": "idle",
            "startedAt": 1778722000000,
        }
    )
)
' > "$body_tmp"
  cp "$body_tmp" "$session_file"
  rm -f "$body_tmp"

  printf '%s\n' "$sid"
}

# ===========================================================================
# Case B — live Claude session id accepted without transcript jsonl.
# ===========================================================================

case_b_live_session_accepted() {
  local fixture_home tmp_cwd sid detected resolved live_pid rc
  fixture_home="$SMOKE_TMP_ROOT/case-b-home"
  tmp_cwd="$SMOKE_TMP_ROOT/case-b-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  live_pid="$$"
  if ! kill -0 "$live_pid" 2>/dev/null; then
    smoke_fail "Case B: self pid $live_pid is not alive — environment broken"
  fi

  sid="$(make_claude_session_fixture "$fixture_home" "$live_pid" "$tmp_cwd" "crm-test")"

  detected="$(HOME="$fixture_home" bridge_detect_claude_session_id "$tmp_cwd" 0 "")"
  rc=$?
  smoke_assert_eq "0" "$rc" "Case B detect rc"
  smoke_assert_eq "$sid" "$detected" "Case B detect returns synthesized session id (#827)"

  resolved="$(HOME="$fixture_home" bridge_resolve_resume_session_id claude crm-test "$tmp_cwd" "$detected" 2>/dev/null)"
  rc=$?
  smoke_assert_eq "0" "$rc" "Case B resolve rc"
  smoke_assert_eq "$sid" "$resolved" "Case B resolve accepts live session id without transcript (#827)"

  # Guard: no transcript leaked into the fixture HOME behind our back.
  local slug transcript_root
  slug="$(printf '%s' "$tmp_cwd" | tr '/.' '-')"
  transcript_root="$fixture_home/.claude/projects/$slug"
  if [[ -d "$transcript_root" ]]; then
    smoke_fail "Case B: transcript dir leaked into fixture HOME: $transcript_root"
  fi
}

run_case_b_for_timing() {
  local fixture_home tmp_cwd sid detected resolved live_pid
  fixture_home="$SMOKE_TMP_ROOT/case-d-home"
  tmp_cwd="$SMOKE_TMP_ROOT/case-d-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"
  live_pid="$$"
  sid="$(make_claude_session_fixture "$fixture_home" "$live_pid" "$tmp_cwd" "crm-test")"
  detected="$(HOME="$fixture_home" bridge_detect_claude_session_id "$tmp_cwd" 0 "")"
  [[ "$detected" == "$sid" ]] \
    || smoke_fail "Case D[B]: detect did not return the synthesized session id"
  resolved="$(HOME="$fixture_home" bridge_resolve_resume_session_id claude crm-test "$tmp_cwd" "$detected" 2>/dev/null)"
  [[ "$resolved" == "$sid" ]] \
    || smoke_fail "Case D[B]: resolve did not accept the live session id"
}

# ===========================================================================
# Case C setup — stubbed agent-bridge + tracked gate-driver helper.
# ===========================================================================

case_c_setup_stub_cli() {
  local stub_path="$1"
  # Line-by-line printf body — no heredoc-to-file. (Forbidden pattern
  # strings intentionally omitted from this comment so the footgun #11
  # self-audit grep recipe does not flag a textual mention as a real
  # callsite.)
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Stub agent-bridge for scripts/smoke/4494-integrated-dynamic-recovery.sh (Case C).'
    printf '%s\n' '# Records every invocation to the sentinel and returns canned --help text'
    printf '%s\n' '# so the helpers can find their "Usage:" section if the opt-in path runs.'
    printf '%s\n' 'set -u'
    printf '%s\n' 'printf "%s\n" "stub-invoked: $*" >> "${BRIDGE_SMOKE_SENTINEL:?}"'
    printf '%s\n' 'if [[ "${1:-}" == "--help" ]]; then'
    printf '%s\n' '  printf "Usage:\n"'
    printf '%s\n' '  printf "  agent-bridge cron list\n"'
    printf '%s\n' '  printf "  agent-bridge task create\n"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } >"$stub_path"
  chmod +x "$stub_path"
}

case_c_default_render_no_recursion() {
  local stub_cli sentinel driver
  stub_cli="$SMOKE_TMP_ROOT/case-c-agent-bridge"
  sentinel="$SMOKE_TMP_ROOT/case-c-sentinel.log"
  driver="$REPO_ROOT/scripts/smoke/4494-integrated-helpers/skill-gate-driver.sh"
  [[ -f "$driver" ]] \
    || smoke_fail "Case C: missing tracked helper driver: $driver"

  case_c_setup_stub_cli "$stub_cli"
  : >"$sentinel"

  # Self-check the stub: direct invocation must populate the sentinel.
  # Catches a typo in the stub silently making the rest of the case a
  # no-op. Sentinel path passed in via the env var the stub reads
  # (`${BRIDGE_SMOKE_SENTINEL:?}`).
  BRIDGE_SMOKE_SENTINEL="$sentinel" "$stub_cli" --help >/dev/null
  [[ -s "$sentinel" ]] \
    || smoke_fail "Case C: stub agent-bridge did not populate sentinel on direct invocation"
  : >"$sentinel"

  # Default path — env unset. The gate must short-circuit before the
  # auto-help helper runs, so the sentinel stays empty.
  if ! "$BASH4_BIN" "$driver" default "$REPO_ROOT" "$sentinel" "$stub_cli" >/dev/null 2>&1; then
    smoke_fail "Case C default-path gate driver failed"
  fi
  if [[ -s "$sentinel" ]]; then
    smoke_log "sentinel content after default gate path:"
    while IFS= read -r line; do
      smoke_log "  $line"
    done <"$sentinel"
    smoke_fail "Case C: default render path recursed into agent-bridge --help (#828 regression)"
  fi

  # Positive control — opt-in path must populate the sentinel (proves
  # the stub is wired correctly and the gate is actually the difference
  # rather than a silently-misrouted CLI).
  : >"$sentinel"
  if ! "$BASH4_BIN" "$driver" optin "$REPO_ROOT" "$sentinel" "$stub_cli" >/dev/null 2>&1; then
    smoke_fail "Case C opt-in gate driver failed"
  fi
  if [[ ! -s "$sentinel" ]]; then
    smoke_fail "Case C: opt-in render path did NOT invoke agent-bridge --help (stub wiring broken)"
  fi
}

run_case_c_for_timing() {
  local stub_cli sentinel driver
  stub_cli="$SMOKE_TMP_ROOT/case-d-c-agent-bridge"
  sentinel="$SMOKE_TMP_ROOT/case-d-c-sentinel.log"
  driver="$REPO_ROOT/scripts/smoke/4494-integrated-helpers/skill-gate-driver.sh"
  case_c_setup_stub_cli "$stub_cli"
  : >"$sentinel"
  "$BASH4_BIN" "$driver" default "$REPO_ROOT" "$sentinel" "$stub_cli" >/dev/null 2>&1 \
    || smoke_fail "Case D[C]: default-path gate driver failed during timing pass"
  [[ ! -s "$sentinel" ]] \
    || smoke_fail "Case D[C]: default render recursed during timing pass"
}

# ===========================================================================
# Case D — combined recovery flow timing (< 10s on Bash 5.3.9 macOS).
# ===========================================================================

case_d_combined_recovery_under_budget() {
  local budget_ns="10000000000"  # 10s
  local start_ns elapsed
  start_ns="$(now_ns)"
  run_case_a_for_timing
  run_case_b_for_timing
  run_case_c_for_timing
  elapsed="$(elapsed_ns_since "$start_ns")"
  smoke_log "Case D combined elapsed_ns=${elapsed} (budget=${budget_ns})"
  if (( elapsed > budget_ns )); then
    smoke_fail "Case D: combined recovery flow took ${elapsed}ns > budget ${budget_ns}ns (#826/#827/#828 integrated regression)"
  fi
}

smoke_run "Case A — bridge-sync grace preserves 5-min-old dynamic (#826)"    case_a_grace_preserves_recent_dynamic
smoke_run "Case B — live Claude session id accepted pre-transcript (#827)"   case_b_live_session_accepted
smoke_run "Case C — default skill render does not recurse into --help (#828)" case_c_default_render_no_recursion
smoke_run "Case D — combined recovery flow under 10s (operator repro)"        case_d_combined_recovery_under_budget

smoke_log "all assertions passed (#4494 Wave D integrated recovery smoke)"
