#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-1-session-id-detect-race.sh — Issue #1304.
#
# v0.15.0-beta5-1 — beta5 Lane β PR #1300 fixed the iso v2 sudo wrap path
# inside bridge_detect_claude_session_id / bridge_resolve_resume_session_id
# so the detect helpers can read 0600-jsonl session files. But TWO residual
# bugs remained, observed in patch's cm-prod-agentworkflow-vm01 trace on
# 2026-05-27:
#
#   20:08:15 UTC  PID 2829871  session_id_detect_empty    (non-sudo path,
#                                                         os_user NOT passed)
#   20:08:16 UTC  PID 2830345  session_id_persisted  54f1742e  (sudo path OK)
#   20:08:27 UTC  PID 2838856  session_id_detect_empty    (non-sudo path →
#                                                         OVERWRITES 54f1742e)
#   end state    history.env   AGENT_SESSION_ID=''        (overwritten)
#
# Problem A — caller os_user passthrough race:
#   `bridge_resolve_agent_iso_sudo_user` may return empty in early roster-
#   load PIDs (BRIDGE_AGENT_OS_USER not yet hydrated, sudo probe transient
#   failure, etc.). Each detect call site must defensively resolve the
#   sudo user via bridge_resolve_agent_iso_sudo_user and thread it as
#   `os_user` (5th arg to bridge_detect_claude_session_id, 6th to
#   bridge_detect_session_id). This smoke audits ALL non-smoke call sites
#   to assert they pass the os_user arg.
#
# Problem B — empty-detect overwrites a previously-persisted session_id:
#   When the detect returns empty (race / non-sudo fallthrough / etc.) the
#   pre-#1304 bridge_persist_agent_state path would serialise the empty
#   in-memory value back to history.env, clobbering a successful 54f1742e
#   that landed 11s earlier from a sibling daemon tick. The detect's empty
#   result is "nothing detected this tick", not "session_id is empty".
#   The fix adds a defense-in-depth no-op guard inside
#   `bridge_persist_agent_state`: when in-memory is empty AND on-disk has
#   a non-empty AGENT_SESSION_ID, rehydrate the in-memory value from disk
#   (so other fields like updated_at still flush) and emit the
#   `session_id_detect_empty_persist_skipped` audit row.
#
# Test plan:
#   T1 (Problem A audit): grep every non-smoke `bridge_detect_session_id`
#       / `bridge_detect_claude_session_id` call site and assert each
#       passes a non-empty os_user-shaped arg (either `_iso_sudo_user` or
#       a similarly named local resolved via
#       `bridge_resolve_agent_iso_sudo_user`).
#   T2 (Problem A teeth): the static call-site list MUST include the
#       three known production sites — bridge-sync.sh::refresh_missing_
#       session_ids, lib/bridge-state.sh::bridge_claude_resume_session_
#       id_for_agent, lib/bridge-state.sh::bridge_refresh_agent_session_
#       id. A future PR that adds a new call site without the os_user
#       arg will fail T1 above; this teeth check pins the three known
#       sites so a refactor that renames/moves a site cannot silently
#       drop the assertion.
#   T3 (Problem B): three-tick race scenario.
#       (a) detect empty + no existing on-disk → persist may write empty
#           (legit fresh state — guard MUST NOT fire).
#       (b) detect=ABC + no existing → persist ABC (guard MUST NOT fire).
#       (c) detect empty + existing=ABC → rehydrate from disk, persist
#           keeps ABC, audit row emitted (guard MUST fire).
#   T4 (Problem B teeth): grep-assert the guard is present in
#       lib/bridge-state.sh. A future PR that removes the rehydrate
#       branch or the audit-row emit will fail this teeth check.
#   T5 (regression / non-iso back-compat): bridge_clear_agent_session_id
#       (an explicit clear path) MUST bypass the guard via
#       BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD=1 so the clear actually
#       lands on disk. Without this bypass forget-session would no-op.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `cat >file <<EOF` plain bodies on flat string variables — no command
# substitution feeding a heredoc stdin, no `<<<` here-strings into
# bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash
# 3.2 — match the recipe used by other smokes.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:beta5-1-session-id-detect-race] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="beta5-1-session-id-detect-race"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "beta5-1-session-id-detect-race"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Source the library functions under test.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

# Sanity checks.
if ! declare -F bridge_persist_agent_state >/dev/null; then
  smoke_fail "bridge_persist_agent_state not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_clear_agent_session_id >/dev/null; then
  smoke_fail "bridge_clear_agent_session_id not defined (sanity check)"
fi
if ! declare -F bridge_agent_persisted_session_id >/dev/null; then
  smoke_fail "bridge_agent_persisted_session_id not defined (sanity check)"
fi
if ! declare -F bridge_audit_log >/dev/null; then
  smoke_fail "bridge_audit_log not defined (sanity check)"
fi

STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
SYNC_SH="$REPO_ROOT/bridge-sync.sh"

# ---------------------------------------------------------------------
# T1 — Problem A audit: every non-smoke detect call site passes an
# os_user-shaped arg.
#
# We grep for the call sites in the two production files
# (lib/bridge-state.sh, bridge-sync.sh) and assert each call site's
# expansion includes a variable matching the resolver convention
# (`_iso_sudo_user`). The detect helper signature is:
#   bridge_detect_claude_session_id <workdir> <since_ms> <exclude_csv>
#                                   <claude_config_dir> <os_user>
#   bridge_detect_session_id <engine> <workdir> <since_hint> <exclude>
#                            <claude_config_dir> <os_user>
# ---------------------------------------------------------------------
test_problem_a_audit_call_sites() {
  smoke_log "T1: audit non-smoke detect call sites for os_user passthrough"

  # Gather the call sites with surrounding context so multi-line
  # invocations are captured intact.
  local file
  for file in "$STATE_LIB" "$SYNC_SH"; do
    smoke_assert_file_exists "$file" "T1: production file exists ($file)"
  done

  # Find every CALLER of the detect helpers (skipping the definitions
  # themselves + comments). awk-based audit avoids the heredoc-stdin
  # footgun #11 — the body lives in a flat awk script invoked with the
  # file as positional argv.
  local audit_report="$SMOKE_TMP_ROOT/t1-audit.txt"
  : >"$audit_report"

  # Strategy: for each call-site line (the trigger line that contains the
  # detect helper invocation, e.g.
  #   detected="$(bridge_detect_claude_session_id ...
  # ), capture that line + the next 7 lines so a multi-line `$(...)`
  # substitution is included. Then check whether the captured block
  # mentions an os_user-shaped local. We skip the function-definition
  # body lines (which only show the helper *name* on the def line + use
  # it internally).
  local AWK_AUDIT='
    BEGIN { hold_n = 0 }
    # Function definition opener: enter def mode, eat its body until "}".
    /^bridge_detect_(claude_)?session_id\(\)[ \t]*\{/ { in_def = 1; next }
    in_def && /^\}/ { in_def = 0; next }
    in_def { next }
    # Skip comments.
    /^[ \t]*#/ { next }
    # Caller lines: contain the function name and are NOT the def signature
    # (already handled). Heuristic for the def signature is matched above.
    {
      if (match($0, /bridge_detect_(claude_)?session_id/)) {
        # Build a window: this line + next 7.
        block = $0
        line_no = NR
        for (k = 0; k < 7; k++) {
          if ((getline nxt) > 0) {
            block = block " " nxt
          } else {
            break
          }
        }
        if (block ~ /_iso_sudo_user|iso_sudo_user|os_user/) {
          print "OK\t" FILENAME ":" line_no "\t" block
        } else {
          print "MISS\t" FILENAME ":" line_no "\t" block
        }
      }
    }
  '

  awk "$AWK_AUDIT" "$STATE_LIB" "$SYNC_SH" >"$audit_report"

  # Iterate and bucket OK / MISS.
  local total=0
  local with_user=0
  local missing_lines=""
  while IFS=$'\t' read -r tag location block; do
    [[ -n "$tag" ]] || continue
    total=$(( total + 1 ))
    if [[ "$tag" == "OK" ]]; then
      with_user=$(( with_user + 1 ))
    else
      missing_lines+=$'\n'"  $location → $block"
    fi
  done <"$audit_report"

  smoke_log "T1: audited $total non-smoke detect call sites (with_user=$with_user)"
  if (( total == 0 )); then
    smoke_fail "T1: no call sites found — audit regex broken (expected at least 3)"
  fi
  if (( with_user != total )); then
    smoke_fail "T1: $((total - with_user)) call site(s) do not thread os_user — Problem A regressed: $missing_lines"
  fi
}

# ---------------------------------------------------------------------
# T2 — Problem A teeth: pin the three known production call sites.
# ---------------------------------------------------------------------
test_problem_a_three_known_sites_present() {
  smoke_log "T2: pin the three known production call sites"

  # Site 1: lib/bridge-state.sh::bridge_claude_resume_session_id_for_agent
  # calls bridge_detect_claude_session_id with _iso_sudo_user as 5th arg.
  if ! grep -F 'bridge_detect_claude_session_id "$workdir" "$_since_ms" "$_quarantine_csv" "$_claude_config_dir" "$_iso_sudo_user"' "$STATE_LIB" >/dev/null; then
    smoke_fail "T2: bridge_claude_resume_session_id_for_agent does not pass _iso_sudo_user to bridge_detect_claude_session_id (Lane β PR #1300 regressed)"
  fi

  # Site 2: lib/bridge-state.sh::bridge_refresh_agent_session_id calls
  # bridge_detect_session_id with _iso_sudo_user as 6th arg.
  if ! grep -F '"$_iso_sudo_user"' "$STATE_LIB" >/dev/null; then
    smoke_fail "T2: lib/bridge-state.sh no longer references _iso_sudo_user — Lane β PR #1300 regressed"
  fi

  # Site 3: bridge-sync.sh::refresh_missing_session_ids resolves and
  # threads _iso_sudo_user as 6th arg to bridge_detect_session_id.
  if ! grep -F '_iso_sudo_user="$(bridge_resolve_agent_iso_sudo_user' "$SYNC_SH" >/dev/null; then
    smoke_fail "T2: bridge-sync.sh refresh_missing_session_ids does not resolve _iso_sudo_user — Lane β PR #1300 regressed"
  fi
  if ! grep -F '"$_iso_sudo_user"' "$SYNC_SH" >/dev/null; then
    smoke_fail "T2: bridge-sync.sh does not pass _iso_sudo_user to bridge_detect_session_id — Lane β PR #1300 regressed"
  fi
}

# ---------------------------------------------------------------------
# Helper: seed an in-memory + on-disk static agent fixture so the
# Problem B tests can drive the persist path.
# ---------------------------------------------------------------------
seed_agent() {
  local agent="$1"
  local workdir="$SMOKE_TMP_ROOT/work-$agent"
  mkdir -p "$workdir"

  bridge_reset_roster_maps
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_HISTORY_KEY["$agent"]="$(bridge_history_key_for claude "$agent" "$workdir")"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  # Make sure the v2 isolated-target write path is short-circuited so the
  # smoke does not require sudo. shellcheck flags this as unused because
  # it's invoked indirectly via bridge_write_agent_state_file.
  # shellcheck disable=SC2329
  bridge_state_v2_isolated_target() { return 1; }
}

# ---------------------------------------------------------------------
# T3 — Problem B: three-tick race scenario.
# ---------------------------------------------------------------------
test_problem_b_empty_detect_no_op_guard() {
  smoke_log "T3: empty-detect no-op guard 3-tick race scenario"

  local agent="b51-T3"
  seed_agent "$agent"
  local history_file
  history_file="$(bridge_history_file_for_agent "$agent")"
  mkdir -p "$(dirname "$history_file")"

  # ---- Tick (a): detect empty + no existing → persist may write empty
  # (legit fresh state — guard MUST NOT fire).
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  # Ensure no prior history file.
  rm -f "$history_file"
  # shellcheck disable=SC2034
  local audit_before_a=0
  if [[ -f "$BRIDGE_AUDIT_LOG" ]]; then
    audit_before_a=$(wc -l <"$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)
  fi
  bridge_persist_agent_state "$agent"
  smoke_assert_file_exists "$history_file" "T3a history file written even with empty session_id (no existing)"
  # The history file should carry an empty AGENT_SESSION_ID.
  local persisted_a
  persisted_a="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "" "$persisted_a" "T3a: on-disk AGENT_SESSION_ID is empty (legit fresh state)"
  # No 'session_id_detect_empty_persist_skipped' audit row should be
  # emitted for the fresh-state case.
  local audit_count_a=0
  if [[ -f "$BRIDGE_AUDIT_LOG" ]]; then
    audit_count_a=$(grep -c 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)
  fi
  smoke_assert_eq "0" "$audit_count_a" \
    "T3a: no detect_empty_persist_skipped audit row when no existing id on disk"

  # ---- Tick (b): detect=ABC + no existing → persist ABC (guard MUST NOT fire).
  BRIDGE_AGENT_SESSION_ID["$agent"]="abcdef00-1111-2222-3333-444455556666"
  bridge_persist_agent_state "$agent"
  local persisted_b
  persisted_b="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "abcdef00-1111-2222-3333-444455556666" "$persisted_b" \
    "T3b: on-disk AGENT_SESSION_ID is the persisted id"
  local audit_count_b=0
  if [[ -f "$BRIDGE_AUDIT_LOG" ]]; then
    audit_count_b=$(grep -c 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)
  fi
  smoke_assert_eq "0" "$audit_count_b" \
    "T3b: no detect_empty_persist_skipped audit row when in-memory is non-empty"

  # ---- Tick (c): detect empty + existing=ABC → NO-OP (rehydrate +
  # persist keeps ABC, audit row emitted).
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  bridge_persist_agent_state "$agent"
  local persisted_c
  persisted_c="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "abcdef00-1111-2222-3333-444455556666" "$persisted_c" \
    "T3c: on-disk AGENT_SESSION_ID PRESERVED — guard blocked the empty overwrite"
  local audit_count_c=0
  if [[ -f "$BRIDGE_AUDIT_LOG" ]]; then
    audit_count_c=$(grep -c 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)
  fi
  if (( audit_count_c < 1 )); then
    smoke_fail "T3c: expected at least 1 session_id_detect_empty_persist_skipped audit row, got $audit_count_c (audit_log=$BRIDGE_AUDIT_LOG)"
  fi
  # The audit row carries the existing short-hash (7 chars).
  local audit_row
  audit_row="$(grep 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null | tail -1)"
  smoke_assert_contains "$audit_row" "abcdef0" \
    "T3c: audit row carries the existing short id (first 7 chars)"
  smoke_assert_contains "$audit_row" "$agent" \
    "T3c: audit row carries the agent name"

  # The in-memory map MUST be rehydrated so downstream code sees the id.
  local in_mem_c="${BRIDGE_AGENT_SESSION_ID[$agent]-}"
  smoke_assert_eq "abcdef00-1111-2222-3333-444455556666" "$in_mem_c" \
    "T3c: in-memory map rehydrated from disk"
}

# ---------------------------------------------------------------------
# T4 — Problem B teeth: grep-assert the guard is present.
# ---------------------------------------------------------------------
test_problem_b_teeth_guard_present() {
  smoke_log "T4: Problem B teeth — guard present in lib/bridge-state.sh"

  local hit=""
  hit="$(grep -F 'session_id_detect_empty_persist_skipped' "$STATE_LIB" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T4: audit-row name 'session_id_detect_empty_persist_skipped' missing from $STATE_LIB — Problem B fix regressed (#1304)"
  fi

  hit="$(grep -F 'BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD' "$STATE_LIB" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T4: bypass env var 'BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD' missing from $STATE_LIB — Problem B fix regressed (#1304)"
  fi

  hit="$(grep -F 'bridge_agent_persisted_session_id' "$STATE_LIB" || true)"
  if [[ -z "$hit" ]]; then
    smoke_fail "T4: bridge_persist_agent_state no longer calls bridge_agent_persisted_session_id — Problem B fix regressed (#1304)"
  fi
}

# ---------------------------------------------------------------------
# T5 — non-iso regression / back-compat: bridge_clear_agent_session_id
# (the explicit clear path) MUST bypass the guard so the clear lands on
# disk.
# ---------------------------------------------------------------------
test_clear_path_bypasses_guard() {
  smoke_log "T5: bridge_clear_agent_session_id bypasses the no-op guard"

  local agent="b51-T5"
  seed_agent "$agent"
  local history_file
  history_file="$(bridge_history_file_for_agent "$agent")"
  mkdir -p "$(dirname "$history_file")"

  # Seed an existing id on disk.
  BRIDGE_AGENT_SESSION_ID["$agent"]="cafebabe-1234-5678-9abc-def012345678"
  BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD=1 \
    bridge_persist_agent_state "$agent"
  local seeded
  seeded="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "cafebabe-1234-5678-9abc-def012345678" "$seeded" \
    "T5 setup: seeded id is on disk"

  # Now invoke the explicit clear. This MUST land an empty
  # AGENT_SESSION_ID on disk despite the in-memory being empty + on-disk
  # being non-empty (the exact condition the guard normally blocks).
  bridge_clear_agent_session_id "$agent"
  local cleared
  cleared="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "" "$cleared" \
    "T5: bridge_clear_agent_session_id wrote empty AGENT_SESSION_ID to disk (guard bypassed)"
}

# ---------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------
smoke_log "starting beta5-1-session-id-detect-race smoke (#1304)"

smoke_run "T1 problem-a-audit-call-sites" test_problem_a_audit_call_sites
smoke_run "T2 problem-a-three-known-sites-present" test_problem_a_three_known_sites_present
smoke_run "T3 problem-b-empty-detect-no-op-guard" test_problem_b_empty_detect_no_op_guard
smoke_run "T4 problem-b-teeth-guard-present" test_problem_b_teeth_guard_present
smoke_run "T5 clear-path-bypasses-guard" test_clear_path_bypasses_guard

smoke_log "all T1-T5 checks passed"
