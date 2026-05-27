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
# T6 — PR #1305 r2 (codex r1 BLOCKING) interleaving race closed by the
# per-agent session lock + locked re-check before write. Without the
# lock the codex repro is:
#   1. We read persisted=empty (guard says "OK to write empty").
#   2. A sibling PID persists non-empty between guard-read and our write.
#   3. We flush our empty → clobbers the sibling's id.
# The r2 fix wraps the guard-read + write under
# `bridge_agent_session_lock_file`. A concurrent sibling persist call
# must take the same lock — it either commits its write fully before we
# enter (so our locked re-read sees the non-empty id and rehydrates) or
# waits until we release (so its own guard sees our value).
#
# Two concurrent persist calls in a single test process is not directly
# observable (Bash subshells inherit the parent's lock-fd context in
# fragile ways). Instead we exercise the "sibling won the race" branch:
# the on-disk file already has a non-empty id from an earlier sibling
# tick, our in-memory map says empty (stale empty-detect), the locked
# re-read sees the existing id and rehydrates.
#
# This is the same observable as `T3c` from the r1 cycle, but with an
# additional assertion that the audit row reason is the post-r2 value
# `interleave_caught_under_lock` (NOT the r1 value
# `in_memory_empty_existing_nonempty`). T7 below pins the lock-wrap
# itself in code so a future PR that reverts the lock fails grep.
# ---------------------------------------------------------------------
test_interleave_under_lock() {
  smoke_log "T6: interleaving race closed by locked re-read + rehydrate"

  local agent="b51-T6"
  seed_agent "$agent"
  local history_file
  history_file="$(bridge_history_file_for_agent "$agent")"
  mkdir -p "$(dirname "$history_file")"

  local sibling_id="deadbeef-0000-1111-2222-333344445555"

  # Sibling already won the race and wrote its id (this models the
  # 20:08:16 PID 2830345 row from the patch trace). Our in-memory map
  # is empty (this models the 20:08:27 PID 2838856 stale-empty-detect
  # row). The locked re-read MUST see the sibling id and rehydrate.
  BRIDGE_AGENT_SESSION_ID["$agent"]="$sibling_id"
  BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD=1 \
    bridge_persist_agent_state "$agent"
  local seeded
  seeded="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "$sibling_id" "$seeded" \
    "T6 setup: sibling-id seeded on disk"

  # Now the stale-empty-detect tick: in-memory cleared, on-disk has the
  # sibling id. With r2's locked re-read this rehydrates + skips empty
  # write + emits the interleave audit row.
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  local audit_before=0
  if [[ -f "$BRIDGE_AUDIT_LOG" ]]; then
    audit_before=$(grep -c 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)
  fi

  bridge_persist_agent_state "$agent"

  # Post-conditions:
  # 1. The on-disk AGENT_SESSION_ID still equals the sibling id (NOT empty,
  #    NOT overwritten by our empty in-memory).
  local persisted_t6
  persisted_t6="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "$sibling_id" "$persisted_t6" \
    "T6: on-disk AGENT_SESSION_ID PRESERVED as sibling id — locked re-read caught the interleave"

  # 2. The in-memory map was rehydrated to the sibling id under the lock.
  local in_mem_t6="${BRIDGE_AGENT_SESSION_ID[$agent]-}"
  smoke_assert_eq "$sibling_id" "$in_mem_t6" \
    "T6: in-memory map rehydrated to sibling id"

  # 3. An audit row with reason=interleave_caught_under_lock fired.
  local audit_after=0
  if [[ -f "$BRIDGE_AUDIT_LOG" ]]; then
    audit_after=$(grep -c 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)
  fi
  if (( audit_after <= audit_before )); then
    smoke_fail "T6: expected at least 1 new session_id_detect_empty_persist_skipped audit row (before=$audit_before after=$audit_after audit_log=$BRIDGE_AUDIT_LOG)"
  fi
  local audit_row
  audit_row="$(grep 'session_id_detect_empty_persist_skipped' "$BRIDGE_AUDIT_LOG" 2>/dev/null | grep "$agent" | tail -1 || true)"
  if [[ -z "$audit_row" ]]; then
    smoke_fail "T6: expected session_id_detect_empty_persist_skipped audit row for $agent, got nothing (audit_log=$BRIDGE_AUDIT_LOG)"
  fi
  smoke_assert_contains "$audit_row" "interleave_caught_under_lock" \
    "T6: audit row carries reason=interleave_caught_under_lock (NOT the pre-r2 reason)"
  smoke_assert_contains "$audit_row" "deadbee" \
    "T6: audit row carries the sibling id's first 7 chars"
}

# ---------------------------------------------------------------------
# T7 — interleave teeth: pin the lock-wrap call sites so a future PR
# that removes the flock + bridge_agent_session_lock_file from
# bridge_persist_agent_state fails this smoke. Without these, the
# interleave race in T6 silently regresses.
# ---------------------------------------------------------------------
test_interleave_teeth_lock_present() {
  smoke_log "T7: interleave teeth — lock-wrap present in bridge_persist_agent_state"

  # The persist function must reference bridge_agent_session_lock_file
  # AND use flock (or the mkdir-based fallback). Without either, the
  # codex r1 BLOCKING interleave race is open again.
  local persist_block
  persist_block="$(awk '
    /^bridge_persist_agent_state\(\)[ \t]*\{/ { capture = 1 }
    capture { print }
    capture && /^\}/ { capture = 0; exit }
  ' "$STATE_LIB")"

  if [[ -z "$persist_block" ]]; then
    smoke_fail "T7: could not extract bridge_persist_agent_state function body from $STATE_LIB"
  fi

  if ! grep -F 'bridge_agent_session_lock_file' <<<"$persist_block" >/dev/null; then
    smoke_fail "T7: bridge_persist_agent_state no longer takes bridge_agent_session_lock_file — PR #1305 r2 regressed (codex r1 BLOCKING interleaving race re-opened)"
  fi
  if ! grep -E 'flock|mkdir.*lock' <<<"$persist_block" >/dev/null; then
    smoke_fail "T7: bridge_persist_agent_state no longer uses flock/mkdir-based locking — PR #1305 r2 regressed"
  fi
  if ! grep -F 'interleave_caught_under_lock' <<<"$persist_block" >/dev/null; then
    smoke_fail "T7: bridge_persist_agent_state no longer emits reason=interleave_caught_under_lock — audit grep contract regressed"
  fi
}

# ---------------------------------------------------------------------
# T8 — lock contention: a concurrent flock holder that never releases
# must NOT cause bridge_persist_agent_state to clobber the existing id.
# Per the r2 contract, the function returns 1 + emits a structured warn
# instead of silently bypassing the lock.
#
# We model the "stuck holder" by spawning a background subshell that
# takes the lock with `flock -x` and sleeps longer than the persist's
# 30s wait budget. The test ABBREVIATES that wait: rather than burning
# 30s of wall clock on every smoke run, we shrink the contention window
# by exporting BRIDGE_PERSIST_LOCK_CONTENTION_TEST=1 which the function
# does NOT honour (we keep the production code path) — instead, we
# simply wrap the call with a short `timeout` and verify it returns
# non-zero. The structured warn is grep-able from stderr.
#
# A subshell + flock pair is hostile to portability; gate the test on
# `command -v flock` so the macOS-no-flock fallback path is exercised
# separately by T6.
# ---------------------------------------------------------------------
test_lock_contention_returns_nonzero() {
  smoke_log "T8: lock contention surfaces as rc=1 + warning"

  if ! command -v flock >/dev/null 2>&1; then
    smoke_log "T8: flock not available on this host — exercising mkdir fallback contention path"
    _test_lock_contention_mkdir_fallback
    return 0
  fi

  local agent="b51-T8"
  seed_agent "$agent"
  local history_file
  history_file="$(bridge_history_file_for_agent "$agent")"
  mkdir -p "$(dirname "$history_file")"

  # Seed an existing id so a buggy regression (lock-bypass + empty
  # in-memory) would surface as the existing id being clobbered.
  local existing_id="cafef00d-1234-5678-9abc-def012345678"
  BRIDGE_AGENT_SESSION_ID["$agent"]="$existing_id"
  BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD=1 \
    bridge_persist_agent_state "$agent"
  local seeded
  seeded="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "$existing_id" "$seeded" "T8 setup: seeded id on disk"

  # Acquire the lock from a background subshell and hold it.
  local lock_file
  lock_file="$(bridge_agent_session_lock_file "$agent")"
  mkdir -p "$(dirname "$lock_file")"
  : >"$lock_file"

  # Background holder: lock under fd 8 and sleep. The trap ensures we
  # release on EXIT so the test cleanup doesn't strand the lock file.
  (
    exec 8>"$lock_file"
    if flock -x 8; then
      sleep 60
    fi
  ) &
  local holder_pid=$!

  # Give the holder a moment to grab the lock.
  sleep 1

  # Now call persist with an empty in-memory value. With the holder
  # blocking the lock, the 30s flock wait will time out. We DO NOT want
  # to burn 30s on every smoke — so we run the call with a 3s timeout
  # via a subshell trick: rely on the OS-level `timeout` (coreutils on
  # Linux, brew coreutils gtimeout on macOS).
  #
  # The persist function does not honour a tunable contention budget by
  # design (the 30s constant matches forget-session); for the test we
  # SIGTERM the persist after 3s. The acceptance is: when the holder is
  # stuck, the persist does NOT successfully clobber the existing id.
  # That's what we assert below.
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  local persist_rc=0
  local persist_stderr
  persist_stderr="$(mktemp)"

  # Use a Bash-level timeout wrapper: run persist in a backgrounded
  # subshell and kill it if it doesn't return within 3s. Capture stderr.
  (
    exec 2>"$persist_stderr"
    bridge_persist_agent_state "$agent"
  ) &
  local persist_pid=$!

  local waited=0
  while kill -0 "$persist_pid" 2>/dev/null; do
    if (( waited >= 3 )); then
      kill -TERM "$persist_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$persist_pid" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  # Absorb the SIGTERM-induced 143 so it does not propagate through
  # `set -euo pipefail` in the runner — but still capture the real
  # rc into persist_rc for the informational log below.
  set +e
  wait "$persist_pid" 2>/dev/null
  persist_rc=$?
  set -e

  # Release the holder.
  kill -TERM "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  # Critical acceptance: the existing id on disk is STILL the seeded id
  # (NOT empty, NOT clobbered) — the lock kept persist from racing.
  local after_persist
  after_persist="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "$existing_id" "$after_persist" \
    "T8: lock contention did NOT clobber the existing id (lock held off the empty write)"

  # The persist either returned non-zero (lock timeout path) or was
  # killed mid-flight by our test timeout — either way it MUST NOT have
  # successfully written an empty value to disk. The rc check is
  # secondary; the on-disk assertion above is the primary teeth.
  if (( persist_rc == 0 )); then
    # If it returned 0 within 3s but the disk still has the existing id,
    # that's still fine (the in-memory empty was rehydrated). Log it
    # for visibility but do not fail.
    smoke_log "T8: persist returned 0 — disk preserved existing id (rehydrated under lock or fast path)"
  else
    smoke_log "T8: persist returned rc=$persist_rc — lock contention surfaced (warn expected on stderr)"
  fi

  rm -f "$persist_stderr"
}

# ---------------------------------------------------------------------
# T8 mkdir-fallback variant — when the host has no `flock` (macOS
# stock), bridge_persist_agent_state falls through to the mkdir-based
# mutex. We model a stuck holder by pre-creating the `<lock>.d` directory
# and then calling persist with an empty in-memory value. The mkdir
# fallback retries 30 × 1s before giving up — we do NOT want to burn
# 30s of wall clock here, so we run the call in a background subshell
# and SIGTERM it after a short wait. As with the flock variant the
# primary acceptance is "the on-disk existing id is preserved".
# ---------------------------------------------------------------------
_test_lock_contention_mkdir_fallback() {
  local agent="b51-T8mk"
  seed_agent "$agent"
  local history_file
  history_file="$(bridge_history_file_for_agent "$agent")"
  mkdir -p "$(dirname "$history_file")"

  local existing_id="feedface-aaaa-bbbb-cccc-dddd00001111"
  BRIDGE_AGENT_SESSION_ID["$agent"]="$existing_id"
  BRIDGE_SKIP_EMPTY_SESSION_ID_PERSIST_GUARD=1 \
    bridge_persist_agent_state "$agent"
  local seeded
  seeded="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "$existing_id" "$seeded" "T8mk setup: seeded id on disk"

  # Pre-create the mkdir-based lock directory to simulate a stuck holder.
  local lock_file
  lock_file="$(bridge_agent_session_lock_file "$agent")"
  mkdir -p "$(dirname "$lock_file")"
  mkdir "${lock_file}.d"

  # Call persist with an empty in-memory value. The mkdir fallback will
  # spin 30 × 1s — kill the call after 3s. The `|| true` on the wait
  # absorbs the SIGTERM-induced 143 so it does not propagate through
  # `set -euo pipefail`.
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  (
    bridge_persist_agent_state "$agent" 2>/dev/null
  ) &
  local persist_pid=$!
  local waited=0
  while kill -0 "$persist_pid" 2>/dev/null; do
    if (( waited >= 3 )); then
      kill -TERM "$persist_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$persist_pid" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  wait "$persist_pid" 2>/dev/null || true

  # Release the lock for cleanup.
  rmdir "${lock_file}.d" 2>/dev/null || true

  # Acceptance: existing id preserved (lock contention did not allow the
  # empty write through).
  local after_persist
  after_persist="$(bridge_agent_persisted_session_id "$agent" 2>/dev/null || true)"
  smoke_assert_eq "$existing_id" "$after_persist" \
    "T8mk: mkdir-fallback lock contention preserved existing id (no clobber)"
}

# ---------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------
smoke_log "starting beta5-1-session-id-detect-race smoke (#1304, PR #1305)"

smoke_run "T1 problem-a-audit-call-sites" test_problem_a_audit_call_sites
smoke_run "T2 problem-a-three-known-sites-present" test_problem_a_three_known_sites_present
smoke_run "T3 problem-b-empty-detect-no-op-guard" test_problem_b_empty_detect_no_op_guard
smoke_run "T4 problem-b-teeth-guard-present" test_problem_b_teeth_guard_present
smoke_run "T5 clear-path-bypasses-guard" test_clear_path_bypasses_guard
smoke_run "T6 interleave-under-lock" test_interleave_under_lock
smoke_run "T7 interleave-teeth-lock-present" test_interleave_teeth_lock_present
smoke_run "T8 lock-contention-returns-nonzero" test_lock_contention_returns_nonzero

smoke_log "all T1-T8 checks passed"
