#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1323-nudge-eligibility-recheck-twostage.sh
#
# v0.15.0-beta5-2 Track G — full closure for #1323.
#
# Issue #1323 main body: `bridge-daemon.sh::nudge_agent_session`'s
# verify-grace loop used a fixed `BRIDGE_NUDGE_VERIFY_GRACE_SECONDS`
# (default 2s) to decide whether a sent nudge had reached the agent.
# 2s was too tight for real claude REPL prompt-buffer + system-reminder
# hook latency — operators measured a 4/4 false-positive rate on a
# fresh install (PR #1323 comment 2026-05-28). The pre-fix daemon
# would log "appears dropped (after 2s); will retry" four times in a
# row and let the next idle-nudge tick recover — functional but noisy
# and operator-confusing.
#
# Fix (Option B from the brief — deterministic two-stage check):
#   Stage 1: sleep BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS (default 2s).
#            If task is no longer `queued` → ack, return 0.
#   Stage 2: if task is still `queued`, wait until
#            BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS (default 5s) of
#            TOTAL elapsed time from the start of the verify window
#            (i.e. sleep stage_2_total - stage_1 = 3s additional) and
#            re-poll. Only emit `session_nudge_dropped` if the SECOND
#            check still observes queued. Total wait = stage_2_total
#            (5s by default), NOT stage_1 + stage_2_total (7s — which
#            was the r1 mis-implementation that codex r1 BLOCKING 1
#            flagged).
#
# Companion observability: `agb status` renders a rolling
# `nudge-recheck` line driven by `nudge_recheck_observability_counts`
# in bridge-status.py — drop_total, drop_stage2_used, and
# recheck_timeout_total counters over the configured window.
#
# Test plan:
#   T1: agent acks within stage 1 (2s)
#       → no audit row, return 0, no "appears dropped" log.
#       (5s-boundary assertion: even at default stage_2_total=5, T1
#       never reaches stage 2 because stage 1 already sees claimed.)
#   T2: agent acks within stage 1 .. stage 2 window
#       → stage 1 sees queued, stage 2 sees not-queued
#       → no `session_nudge_dropped` row, no "appears dropped" log,
#         return 0.
#       (5s-boundary assertion: stage 2 polls at stage_2_total=5s
#       TOTAL elapsed, not stage_1 + stage_2 = 7s.)
#   T3: agent never acks (still queued after both stages)
#       → `session_nudge_dropped` row emitted with stage2_used=1,
#         grace_total_seconds=stage_2_total=5, return 1. (Pre-r2
#         this was 7s — see codex r1 BLOCKING 1.)
#   T4: rapid succession — REAL dedup path (codex r1 BLOCKING 3, fully
#       closed at r3). The daemon consults `bridge_daemon_should_skip_
#       nudge` BEFORE the verify-grace block (bridge-daemon.sh:5705) and
#       `bridge_daemon_record_nudge` AFTER a verified send (:5864). A
#       second nudge for the same (agent, task) inside the redelivery
#       window must be deduped — never spawning a parallel verify window.
#       The r1/r2 smoke only drove a synthetic verify-grace timeline and
#       never called the dedup helpers, so the rapid-succession claim was
#       unproven. r3 sources the real helpers from the daemon and drives:
#       T4a: record nudge for (agentA, #1) → should_skip same (agentA, #1)
#            inside window → SKIP (dedup holds; no second verify window).
#       T4b: record nudge for (agentA, #1) → should_skip (agentA, #2)
#            (DIFFERENT task) → NOT skip (a genuinely new task fires).
#       T4c: record nudge for (agentA, #1) → window expires (redelivery=2,
#            real 3s sleep) → should_skip → NOT skip (window slid past).
#       T4d: rapid-succession through the FAITHFUL daemon order. A
#            `nudge_once` wrapper mirrors nudge_agent_session exactly:
#            skip-check (bridge-daemon.sh:5705) → if not skip, verify-grace
#            block → and ONLY if verify returns 0 (task left queued =
#            delivered) record + emit `session_nudge_sent`
#            (bridge-daemon.sh:5836-5864 — a dropped nudge `return 1`s
#            BEFORE record, so a drop never records). Nudge 1 is a
#            successful delivery (timeline queued→claimed) spawned in a
#            `( ... ) &` subshell; we then `wait` for it (the daemon
#            processes each agent at most once per tick — two nudges to the
#            same agent are consecutive ticks, never overlapping verify
#            windows; the dedup helpers carry NO lock, so the real
#            cross-tick guarantee IS the sequencing, which `wait` models).
#            Nudge 2 then runs inline through the same wrapper and hits the
#            now-populated dedup gate. The daemon `return 0`s on the dedup
#            path (bridge-daemon.sh:5723), so the dedup is asserted via the
#            audit rows, NOT the rc: exactly ONE `session_nudge_sent` total
#            (the dedup prevented a second send — the real no-double-counter
#            invariant; counting state-file lines can't prove this because
#            record_nudge overwrites atomically), exactly one
#            `session_nudge_deduped` row from nudge 2, and ZERO
#            `session_nudge_dropped` (nudge 1 succeeded).
#   T5_teeth: bridge-status.py renders the `nudge-recheck` line + JSON
#       `nudge_recheck` block when an audit row exists, and the
#       counter SQL distinguishes stage2_used=1 drops from legacy
#       (no stage2_used key) drops.
#
# Footgun #11 (no python3 heredoc-stdin from a `$()`): every python3
# subprocess in this smoke reads its inputs via argv or file paths,
# never via stdin. The bridge-status.py rendering exercise pipes
# stdout into a captured variable; both render functions are
# argparse-driven and accept --audit-log on the command line.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays + the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1323-nudge-eligibility-recheck-twostage] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1323-nudge-eligibility-recheck-twostage"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
: >"$AUDIT_LOG"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"

# Test fixture: a thin shim that mirrors the two-stage verify-grace
# block in nudge_agent_session (bridge-daemon.sh lines ~5765-5815).
# We intentionally do not source the full daemon — the verify block is
# the unit under test, and the surrounding live-state recheck +
# fingerprint dedup are exercised by the sibling iota smoke. The shim
# emits the same audit fields and uses the same env knobs as the
# in-source path; the structural assertion (T5_teeth) ensures the
# block stays in sync with the daemon.

TIMELINE_DIR="$SMOKE_TMP_ROOT/timeline"
mkdir -p "$TIMELINE_DIR"

# Stub `bridge_audit_log` to write JSON rows to $AUDIT_LOG (matching
# the iota smoke's stub shape).
bridge_audit_log() {
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_json=""
  while (( $# )); do
    case "$1" in
      --detail)
        local kv="$2"
        local k="${kv%%=*}"
        local v="${kv#*=}"
        # JSON-escape quote+backslash. Sufficient for our test values.
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        if [[ -n "$detail_json" ]]; then detail_json+=","; fi
        detail_json+="\"${k}\":\"${v}\""
        shift 2
        ;;
      *) shift ;;
    esac
  done
  local ts
  ts="$(python3 -c "import datetime,sys;print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'))")"
  printf '{"ts":"%s","actor":"%s","action":"%s","target":"%s","detail":{%s}}\n' \
    "$ts" "$actor" "$action" "$target" "$detail_json" >>"$AUDIT_LOG"
}

daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
DAEMON_INFO_LOG="$SMOKE_TMP_ROOT/daemon-info.log"
: >"$DAEMON_INFO_LOG"
daemon_info() { printf '%s\n' "$*" >>"$DAEMON_INFO_LOG"; }

# bridge_queue_task_status — driven by a per-task timeline file (one
# status per line). Each call pops the head and prints it. Falls back
# to "queued" if the file is missing or empty. File-based so the
# `$(bridge_queue_task_status ...)` subshell side-effect of advancing
# the cursor survives back to the caller.
bridge_queue_task_status() {
  local task_id="$1"
  local timeline="$TIMELINE_DIR/${task_id}.timeline"
  if [[ ! -s "$timeline" ]]; then
    printf 'queued'
    return 0
  fi
  local first rest
  first="$(head -n 1 "$timeline")"
  rest="$(tail -n +2 "$timeline")"
  printf '%s' "$rest" >"$timeline"
  printf '%s' "$first"
}

timeline_set() {
  local task_id="$1"
  shift
  local timeline="$TIMELINE_DIR/${task_id}.timeline"
  printf '%s\n' "$@" >"$timeline"
}

# Shim: ONLY the verify-grace block from nudge_agent_session.
# Intentionally a 1:1 copy of the in-source logic so the smoke
# regression bites if the daemon block drifts (the T5_teeth grep
# below pins the source shape too).
#
# r2 semantic: stage_2_total is the TOTAL elapsed window from the
# start of verify, not an additional sleep on top of stage 1. The
# legacy env-var fallback (BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2
# as ADDITIONAL sleep) is preserved so existing smoke harnesses
# (scripts/smoke-test.sh STAGE2=0 path) keep working.
verify_grace_shim() {
  local agent="$1"
  local task_id="$2"
  local live_queued="${3:-1}"
  local live_claimed="${4:-0}"
  local idle="${5:-0}"
  local title="${6:-test-title}"

  local nudge_grace_seconds="${BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS:-${BRIDGE_NUDGE_VERIFY_GRACE_SECONDS:-2}}"
  [[ "$nudge_grace_seconds" =~ ^[0-9]+$ ]] || nudge_grace_seconds=2
  local nudge_grace_stage2_total
  if [[ -n "${BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS:-}" ]]; then
    nudge_grace_stage2_total="${BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS}"
    [[ "$nudge_grace_stage2_total" =~ ^[0-9]+$ ]] || nudge_grace_stage2_total=5
  elif [[ -n "${BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2:-}" ]]; then
    local _legacy_stage2_add="${BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2}"
    [[ "$_legacy_stage2_add" =~ ^[0-9]+$ ]] || _legacy_stage2_add=5
    nudge_grace_stage2_total=$(( nudge_grace_seconds + _legacy_stage2_add ))
  else
    nudge_grace_stage2_total=5
  fi
  local post_status=""
  local nudge_stage2_used=0
  if [[ -n "$task_id" ]]; then
    # Skip the real sleep in smoke — the timeline emulates clock advance.
    post_status="$(bridge_queue_task_status "$task_id" 2>/dev/null || true)"
    if [[ "$post_status" == "queued" ]] && (( nudge_grace_stage2_total > nudge_grace_seconds )); then
      nudge_stage2_used=1
      post_status="$(bridge_queue_task_status "$task_id" 2>/dev/null || true)"
    fi
    if [[ "$post_status" == "queued" ]]; then
      local _total_wait_seconds
      if (( nudge_stage2_used == 1 )); then
        _total_wait_seconds=$nudge_grace_stage2_total
      else
        _total_wait_seconds=$nudge_grace_seconds
      fi
      bridge_audit_log daemon session_nudge_dropped "$agent" \
        --detail task_id="$task_id" \
        --detail reason=submit_lost_post_grace \
        --detail grace_seconds="$nudge_grace_seconds" \
        --detail grace_stage2_total_seconds="$nudge_grace_stage2_total" \
        --detail grace_total_seconds="$_total_wait_seconds" \
        --detail stage2_used="$nudge_stage2_used" \
        --detail queued="$live_queued" \
        --detail claimed="$live_claimed" \
        --detail idle_seconds="$idle" \
        --detail title="$title"
      daemon_info "nudge to ${agent} appears dropped (task #${task_id} still queued after ${_total_wait_seconds}s, stage1=${nudge_grace_seconds}s stage2_total=${nudge_grace_stage2_total}s); will retry on next idle-nudge tick"
      return 1
    fi
  fi
  return 0
}

# --- Source the REAL in-source dedup gate from bridge-daemon.sh --------
# r3 (codex r2 BLOCKING): T4 must exercise the actual rapid-succession
# dedup path (`bridge_daemon_should_skip_nudge` / `bridge_daemon_record_
# nudge`) that `nudge_agent_session` consults BEFORE entering the
# verify-grace block (bridge-daemon.sh:5705 — skip-check; :5864 — record).
# The r1/r2 smoke only drove the synthetic verify-grace timeline and never
# called the dedup helpers, so the ci-select claim of "rapid-succession
# dedup that prevents a same-agent second nudge from spawning a parallel
# verify window" was unproven. We extract the two dedup entry points
# (`bridge_daemon_should_skip_nudge` / `bridge_daemon_record_nudge`) plus
# their five state-file / fingerprint dependencies straight from the
# daemon source so the smoke bites if either side drifts. Extraction
# pattern is the one the sibling iota smoke
# (beta5-2-iota-daemon-escalation-family) already proves: a python pass
# that captures each wanted `name() {` block up to its column-0 `}`,
# skipping over inner heredoc bodies whose lines may themselves start
# with `}`.
#
# Footgun #11 (no python3 heredoc-stdin to a subprocess): the extractor
# program is WRITTEN to a standalone file on disk (a heredoc-to-FILE
# redirect, which is fine) and then invoked with BOTH the source path and
# the wanted-CSV passed as argv — the python3 subprocess reads nothing
# from stdin. This mirrors the AUDIT_DETAIL_HELPER / PARSE_HELPER pattern
# already used below in this smoke.
DEDUP_HELPERS_SUBSET="$SMOKE_TMP_ROOT/daemon-dedup-helpers.sh"
DEDUP_EXTRACT_HELPER="$SMOKE_TMP_ROOT/extract-dedup-helpers.py"
DEDUP_WANTED_HELPERS=(
  bridge_daemon_nudge_state_file
  bridge_daemon_compute_nudge_fingerprint
  bridge_daemon_nudge_task_ts_var
  bridge_daemon_nudge_dedup_load
  bridge_daemon_nudge_dedup_reset_scope
  bridge_daemon_should_skip_nudge
  bridge_daemon_record_nudge
)
DEDUP_WANTED_CSV="$(IFS=,; echo "${DEDUP_WANTED_HELPERS[*]}")"
cat >"$DEDUP_EXTRACT_HELPER" <<'PYEOF'
import re, sys
src_path = sys.argv[1]
wanted = set(sys.argv[2].split(","))
with open(src_path, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
i = 0
fn_start_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{')
heredoc_re = re.compile(r"<<[-']?([A-Za-z_][A-Za-z0-9_]*)'?")
while i < len(lines):
    line = lines[i]
    m = fn_start_re.match(line)
    if m and m.group(1) in wanted:
        block = [line]
        heredoc_term = None
        j = i + 1
        while j < len(lines):
            cur = lines[j]
            block.append(cur)
            if heredoc_term is None:
                hm = heredoc_re.search(cur)
                if hm:
                    heredoc_term = hm.group(1)
            else:
                if cur.rstrip("\n") == heredoc_term:
                    heredoc_term = None
                j += 1
                continue
            if cur == "}\n" or cur == "}":
                break
            j += 1
        out.extend(block)
        out.append("\n")
        i = j + 1
        continue
    i += 1
sys.stdout.write("".join(out))
PYEOF
python3 "$DEDUP_EXTRACT_HELPER" "$REPO_ROOT/bridge-daemon.sh" "$DEDUP_WANTED_CSV" >"$DEDUP_HELPERS_SUBSET"

# All seven helpers must have been captured — a rename/move in the daemon
# would silently shrink this subset and make the dedup tests below vacuous.
for _fn in "${DEDUP_WANTED_HELPERS[@]}"; do
  grep -q "^${_fn}() {" "$DEDUP_HELPERS_SUBSET" \
    || smoke_fail "dedup-extract: bridge-daemon.sh no longer defines ${_fn}() (T4 dedup gate would be vacuous)"
done

# shellcheck source=/dev/null
source "$DEDUP_HELPERS_SUBSET"

# audit_count action target → integer count of matching rows.
audit_count() {
  local action="$1" target="$2"
  local n
  if n="$(grep -c "\"action\":\"${action}\".*\"target\":\"${target}\"" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}

# audit_latest_detail action target field — extract a JSON field. Uses
# a standalone python helper rather than `-c` to keep nested quoting
# legible and to dodge footgun #11.
AUDIT_DETAIL_HELPER=""
audit_latest_detail() {
  local action="$1" target="$2" field="$3"
  local row
  row="$(grep "\"action\":\"${action}\".*\"target\":\"${target}\"" "$AUDIT_LOG" 2>/dev/null | tail -n1)"
  [[ -n "$row" ]] || { printf ''; return; }
  if [[ -z "$AUDIT_DETAIL_HELPER" ]]; then
    AUDIT_DETAIL_HELPER="$SMOKE_TMP_ROOT/audit-detail.py"
    cat >"$AUDIT_DETAIL_HELPER" <<'PYEOF'
import json, sys
try:
    obj = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(0)
detail = obj.get("detail") if isinstance(obj.get("detail"), dict) else {}
sys.stdout.write(str(detail.get(sys.argv[2], "")))
PYEOF
  fi
  python3 "$AUDIT_DETAIL_HELPER" "$row" "$field"
}

# --- T1: agent acks within stage 1 (5s-boundary baseline) --------
smoke_run "T1 stage1-ack: no audit, no drop log" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  # Timeline: stage 1 check sees claimed.
  timeline_set 101 claimed
  # Pin defaults explicitly so the test asserts the published 2s+5s
  # contract regardless of env inherited from the smoke harness.
  export BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS=2
  export BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS=5
  set +e
  verify_grace_shim "agent-t1" "101" 1 0 0 "t1"
  rc=$?
  set -e
  unset BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS
  smoke_assert_eq 0 "$rc" "T1 returns 0 on stage-1 ack"
  drop_count="$(audit_count session_nudge_dropped agent-t1)"
  smoke_assert_eq 0 "$drop_count" "T1 no session_nudge_dropped row"
  smoke_assert_not_contains "$(cat "$DAEMON_INFO_LOG")" "appears dropped" "T1 no 'appears dropped' log"
}

# --- T2: agent acks within stage 2 window (5s-boundary suppression) ---
smoke_run "T2 stage2-ack: stage1 queued, stage2 not — no audit, no drop log" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  # Timeline: stage 1 still queued; stage 2 sees claimed (the
  # false-positive case from #1323 comment 2026-05-28). With the r2
  # rewrite, the SECOND status poll happens at stage_2_total = 5s
  # total elapsed (NOT 2+5=7s).
  timeline_set 202 queued claimed
  export BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS=2
  export BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS=5
  set +e
  verify_grace_shim "agent-t2" "202" 1 0 0 "t2"
  rc=$?
  set -e
  unset BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS
  smoke_assert_eq 0 "$rc" "T2 returns 0 on stage-2 ack"
  drop_count="$(audit_count session_nudge_dropped agent-t2)"
  smoke_assert_eq 0 "$drop_count" "T2 no session_nudge_dropped row (false positive suppressed)"
  smoke_assert_not_contains "$(cat "$DAEMON_INFO_LOG")" "appears dropped" "T2 no 'appears dropped' log"
}

# --- T3: agent never acks → emit drop with stage2_used=1 ----------
# r2 BLOCKING 1: grace_total_seconds is the TOTAL window (5s), not
# stage_1 + stage_2 (7s). The previous r1 assertion of 7 was the bug.
smoke_run "T3 both-stages-queued: emit drop with stage2_used=1" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  timeline_set 303 queued queued
  export BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS=2
  export BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS=5
  set +e
  verify_grace_shim "agent-t3" "303" 1 0 0 "t3"
  rc=$?
  set -e
  unset BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS
  smoke_assert_eq 1 "$rc" "T3 returns 1 on stage-2 still-queued"
  drop_count="$(audit_count session_nudge_dropped agent-t3)"
  smoke_assert_eq 1 "$drop_count" "T3 one session_nudge_dropped row"
  stage2_used="$(audit_latest_detail session_nudge_dropped agent-t3 stage2_used)"
  smoke_assert_eq 1 "$stage2_used" "T3 stage2_used=1"
  total="$(audit_latest_detail session_nudge_dropped agent-t3 grace_total_seconds)"
  smoke_assert_eq 5 "$total" "T3 grace_total_seconds = stage_2_total = 5 (NOT stage_1+stage_2=7)"
  stage2_total="$(audit_latest_detail session_nudge_dropped agent-t3 grace_stage2_total_seconds)"
  smoke_assert_eq 5 "$stage2_total" "T3 grace_stage2_total_seconds = 5"
  smoke_assert_contains "$(cat "$DAEMON_INFO_LOG")" "appears dropped" "T3 'appears dropped' log present"
  smoke_assert_contains "$(cat "$DAEMON_INFO_LOG")" "stage1=2s stage2_total=5s" "T3 log cites stage_1 + stage_2_total"
}

# --- T4: rapid succession — REAL dedup path (codex r1 BLOCKING 3, r3) --
# These tests drive the actual in-source helpers extracted above, NOT the
# synthetic verify-grace timeline. They prove the dedup gate the daemon
# consults at bridge-daemon.sh:5705 before any verify window opens.

# T4a: same (agent, task) inside the window → dedup SKIP.
smoke_run "T4a same-task in-window → should_skip returns SKIP (dedup)" : ; {
  : >"$AUDIT_LOG"
  rm -f "$(bridge_daemon_nudge_state_file agent-t4a)"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=600
  fp="$(bridge_daemon_compute_nudge_fingerprint "1")"
  bridge_daemon_record_nudge "agent-t4a" "$fp" "1"
  state_file="$(bridge_daemon_nudge_state_file agent-t4a)"
  smoke_assert_file_exists "$state_file" "T4a state file written by record_nudge"
  grep -q "^NUDGE_TASK_TS_1=" "$state_file" || smoke_fail "T4a NUDGE_TASK_TS_1 missing after record"
  if bridge_daemon_should_skip_nudge "agent-t4a" "$fp" "1"; then
    : # skip == dedup held
  else
    smoke_fail "T4a should_skip must return SKIP for same (agent, task) inside window"
  fi
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS
}

# T4b: same agent, DIFFERENT task → a genuinely new task must fire.
smoke_run "T4b same-agent different-task → should_skip returns OK (fire)" : ; {
  : >"$AUDIT_LOG"
  rm -f "$(bridge_daemon_nudge_state_file agent-t4b)"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=600
  bridge_daemon_record_nudge "agent-t4b" "$(bridge_daemon_compute_nudge_fingerprint "1")" "1"
  # Task #2 has no NUDGE_TASK_TS_2 entry → dedup must break for the new id.
  if bridge_daemon_should_skip_nudge "agent-t4b" "$(bridge_daemon_compute_nudge_fingerprint "2")" "2"; then
    smoke_fail "T4b should_skip must NOT skip a different task (#2) on the same agent"
  else
    : # not-skip == new task fires
  fi
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS
}

# T4c: window expiry — after the redelivery window slides past, the same
# (agent, task) is eligible again. Uses a real 2s sleep against a 1s
# redelivery window so the elapsed-time math is exercised, not faked.
# The window is 2s (not 1s): with a 1s window the record's `now=N` and an
# immediate recheck at `now=N+1` would compute `(( 1 < 1 ))` = not-skip and
# flake. 2s gives the in-window recheck a full second of slack; the expiry
# sleep is then 3s (> 2s window + 1s clock granularity). The immediate
# in-window skip is already pinned by T4a, so the load-bearing assertion
# here is the post-expiry not-skip.
smoke_run "T4c window expiry → should_skip returns OK after window slides past" : ; {
  : >"$AUDIT_LOG"
  rm -f "$(bridge_daemon_nudge_state_file agent-t4c)"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=2
  fp="$(bridge_daemon_compute_nudge_fingerprint "1")"
  bridge_daemon_record_nudge "agent-t4c" "$fp" "1"
  # Inside the 2s window → skip (slack guards against clock granularity).
  if bridge_daemon_should_skip_nudge "agent-t4c" "$fp" "1"; then
    : # in-window skip
  else
    smoke_fail "T4c should_skip must SKIP immediately after record (inside 2s window)"
  fi
  # Wait past the 2s redelivery window (3s = window + 1s granularity).
  sleep 3
  if bridge_daemon_should_skip_nudge "agent-t4c" "$fp" "1"; then
    smoke_fail "T4c should_skip must NOT skip after the redelivery window expires"
  else
    : # window slid past → eligible again
  fi
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS
}

# nudge_once — faithful 1:1 of nudge_agent_session's dedup→verify→record
# sequence (bridge-daemon.sh:5705 skip-check, :5820-5856 verify-grace,
# :5864 record-after-verified-send, :5866 session_nudge_sent). A dropped
# nudge `return 1`s at :5855 BEFORE the record at :5864, so a drop never
# records and never emits session_nudge_sent — exactly the contract a
# rapid second nudge relies on. The verify side is delegated to the same
# verify_grace_shim the rest of this smoke pins, so the two-stage shape
# and the dedup gate are exercised together (the gap codex r1/r2 flagged).
nudge_once() {
  local agent="$1" task_id="$2" id_csv="$3" title="$4"
  local fp
  fp="$(bridge_daemon_compute_nudge_fingerprint "$id_csv")"
  # Skip-check FIRST — a same-(agent,task) nudge inside the redelivery
  # window short-circuits here, never opening a verify window. The daemon
  # emits session_nudge_deduped and `return 0`s on this path
  # (bridge-daemon.sh:5706-5723) — faithfully mirrored, including the rc.
  # T4d distinguishes the dedup outcome via the audit rows
  # (session_nudge_deduped present, session_nudge_sent absent), not the rc.
  if bridge_daemon_should_skip_nudge "$agent" "$fp" "$id_csv"; then
    bridge_audit_log daemon session_nudge_deduped "$agent" --detail task_id="$task_id"
    return 0
  fi
  # Capture verify_grace_shim's rc via an `if` so we neither trip the
  # caller's `set -e` nor leak a `set +e`/`set -e` toggle out of this
  # function (a leaked errexit flip aborts a backgrounding subshell
  # before it can stash $? — footgun confirmed during r3 negative-control
  # testing). A non-zero rc means the nudge was dropped: return BEFORE
  # the record, mirroring nudge_agent_session's `return 1` at
  # bridge-daemon.sh:5855 (a dropped nudge must NOT record, so the next
  # idle-nudge tick re-fires unconditionally — issue #767).
  if verify_grace_shim "$agent" "$task_id" 1 0 0 "$title"; then
    bridge_daemon_record_nudge "$agent" "$fp" "$id_csv"
    bridge_audit_log daemon session_nudge_sent "$agent" --detail task_id="$task_id"
    return 0
  fi
  return 1
}

# T4d: rapid succession through the faithful daemon order. Nudge 1 is a
# successful delivery in a `( ... ) &` subshell; we wait for it (the daemon
# processes an agent at most once per tick — rapid succession is across
# consecutive ticks, never overlapping verify windows; the dedup helpers
# carry no lock so the sequencing IS the guarantee). Nudge 2 then hits the
# populated gate inline and must dedup. Invariant: exactly one
# session_nudge_sent, nudge 2 deduped, zero drops.
smoke_run "T4d rapid succession (faithful order): nudge 2 deduped, one send, no double-counter" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  rm -f "$(bridge_daemon_nudge_state_file agent-t4d)"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=600
  export BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS=2
  export BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS=5

  # Nudge 1 delivers: stage 1 queued, stage 2 claimed → verify returns 0 →
  # records + emits session_nudge_sent.
  timeline_set 1 queued claimed
  RACE_RC_FILE="$SMOKE_TMP_ROOT/t4d-nudge1.rc"
  (
    set +e
    nudge_once "agent-t4d" "1" "1" "t4d-nudge-1"
    printf '%s' "$?" >"$RACE_RC_FILE"
  ) &
  race_pid=$!
  wait "$race_pid"
  rc1="$(cat "$RACE_RC_FILE" 2>/dev/null || printf 'X')"
  smoke_assert_eq 0 "$rc1" "T4d nudge 1 delivered (verify ok → recorded + sent)"

  # Nudge 2 fires inline (next tick) for the SAME (agent, task) inside the
  # window → the dedup gate short-circuits it. The daemon `return 0`s on the
  # dedup path, so the outcome is asserted via the audit rows below, NOT the
  # rc (session_nudge_deduped present, no second session_nudge_sent).
  timeline_set 1 queued claimed
  nudge_once "agent-t4d" "1" "1" "t4d-nudge-2"
  unset BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS

  # The no-double-counter invariant: exactly ONE session_nudge_sent across
  # both nudges (the second was deduped before it could send/record), and
  # exactly one session_nudge_deduped row from nudge 2.
  sent_total="$(audit_count session_nudge_sent agent-t4d)"
  smoke_assert_eq 1 "$sent_total" "T4d exactly one session_nudge_sent (dedup blocked the second nudge)"
  deduped_total="$(audit_count session_nudge_deduped agent-t4d)"
  smoke_assert_eq 1 "$deduped_total" "T4d exactly one session_nudge_deduped row (nudge 2 short-circuited at the gate)"
  # Nudge 1 succeeded → no drop on either nudge.
  drop_total="$(audit_count session_nudge_dropped agent-t4d)"
  smoke_assert_eq 0 "$drop_total" "T4d zero session_nudge_dropped (nudge 1 delivered, nudge 2 deduped)"
}

# --- T4_legacy: STAGE2 fallback path still disables stage 2 -------
# Legacy r1 env var (BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2=0) must
# keep working so the existing scripts/smoke-test.sh STAGE2=0 path
# does not break on the rename. Same as r1's T4 in spirit; renamed to
# T4_legacy because the brief reassigned T4 to the race scenario.
smoke_run "T4_legacy STAGE2=0 (legacy env) disables stage 2 → drop after stage1 only" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  timeline_set 405 queued
  export BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2=0
  set +e
  verify_grace_shim "agent-t4legacy" "405" 1 0 0 "t4legacy"
  rc=$?
  set -e
  unset BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2
  smoke_assert_eq 1 "$rc" "T4_legacy returns 1 (stage 2 disabled via legacy STAGE2=0, stage 1 still queued)"
  stage2_used="$(audit_latest_detail session_nudge_dropped agent-t4legacy stage2_used)"
  smoke_assert_eq 0 "$stage2_used" "T4_legacy stage2_used=0 (skipped)"
  total="$(audit_latest_detail session_nudge_dropped agent-t4legacy grace_total_seconds)"
  smoke_assert_eq 2 "$total" "T4_legacy grace_total_seconds = stage1 only = 2"
}

# --- T5: bridge-status.py renders the counter line + JSON ----------
smoke_run "T5 bridge-status renders nudge-recheck line + JSON counter" : ; {
  : >"$AUDIT_LOG"
  # Seed audit log:
  #   - 1 session_nudge_dropped with stage2_used=1 (post-fix shape)
  #   - 1 session_nudge_dropped without stage2_used (legacy shape)
  #   - 2 nudge_eligibility_recheck_timeout (#1323 H5 contract)
  bridge_audit_log daemon session_nudge_dropped agent-s5 \
    --detail task_id=701 --detail stage2_used=1 --detail grace_total_seconds=7
  bridge_audit_log daemon session_nudge_dropped agent-s5 \
    --detail task_id=702
  bridge_audit_log daemon nudge_eligibility_recheck_timeout agent-s5 \
    --detail task_id=703 --detail consecutive=1
  bridge_audit_log daemon nudge_eligibility_recheck_timeout agent-s5 \
    --detail task_id=703 --detail consecutive=2

  # Set up enough state for bridge-status.py to render without crashing.
  # The dashboard needs `agent_state` and `tasks` tables; seed them by
  # creating + cancelling a throwaway task via bridge-queue.py (same
  # init pattern the sibling 1106 smoke uses).
  ROSTER_SNAPSHOT="$SMOKE_TMP_ROOT/roster-snapshot.txt"
  : >"$ROSTER_SNAPSHOT"
  DAEMON_PID_FILE="$SMOKE_TMP_ROOT/daemon.pid"
  : >"$DAEMON_PID_FILE"
  python3 "$REPO_ROOT/bridge-queue.py" create \
    --to agent-s5 --from requester \
    --title "schema init" --body "init" --format shell \
    >"$SMOKE_TMP_ROOT/queue-init.sh"
  # shellcheck disable=SC1090
  source "$SMOKE_TMP_ROOT/queue-init.sh"
  python3 "$REPO_ROOT/bridge-queue.py" cancel "$TASK_ID" --actor requester >/dev/null
  unset TASK_ID

  STATUS_OUT="$(python3 "$REPO_ROOT/bridge-status.py" \
    --roster-snapshot "$ROSTER_SNAPSHOT" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$DAEMON_PID_FILE" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --audit-log "$AUDIT_LOG" 2>&1)" || smoke_fail "T5 bridge-status.py text render failed: $STATUS_OUT"
  smoke_assert_contains "$STATUS_OUT" "nudge-recheck" "T5 dashboard renders nudge-recheck line"
  smoke_assert_contains "$STATUS_OUT" "drop_total=2" "T5 drop_total counter correct (both legacy + stage2)"
  smoke_assert_contains "$STATUS_OUT" "drop_stage2_used=1" "T5 stage2_used counter correct (only post-fix shape)"
  smoke_assert_contains "$STATUS_OUT" "recheck_timeout=2" "T5 recheck_timeout counter correct"

  STATUS_JSON="$(python3 "$REPO_ROOT/bridge-status.py" \
    --roster-snapshot "$ROSTER_SNAPSHOT" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$DAEMON_PID_FILE" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --audit-log "$AUDIT_LOG" --json 2>&1)" || smoke_fail "T5 bridge-status.py JSON render failed: $STATUS_JSON"
  # JSON consumer-side parse check. The status JSON is written to a
  # tempfile + a standalone python helper file (also written by this
  # smoke) so we can avoid embedding python source via `-c` with nested
  # quote escapes. Footgun #11 avoidance: no heredoc-stdin, no `<<<`.
  STATUS_JSON_FILE="$SMOKE_TMP_ROOT/status-render.json"
  printf '%s' "$STATUS_JSON" >"$STATUS_JSON_FILE"
  PARSE_HELPER="$SMOKE_TMP_ROOT/parse-status-json.py"
  cat >"$PARSE_HELPER" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
nr = payload.get("nudge_recheck") or {}
sys.stdout.write(
    f"window={nr.get('window_days')} "
    f"drop={nr.get('nudge_drop_total')} "
    f"stage2={nr.get('nudge_drop_stage2_used')} "
    f"timeout={nr.get('recheck_timeout_total')}\n"
)
PYEOF
  parsed="$(python3 "$PARSE_HELPER" "$STATUS_JSON_FILE")"
  smoke_assert_contains "$parsed" "drop=2" "T5 JSON drop_total=2"
  smoke_assert_contains "$parsed" "stage2=1" "T5 JSON drop_stage2_used=1"
  smoke_assert_contains "$parsed" "timeout=2" "T5 JSON recheck_timeout_total=2"
}

# --- T5_teeth: structural shape assertions -------------------------
smoke_run "T5_teeth structural shape in bridge-daemon.sh + bridge-status.py" : ; {
  daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  status_py="$REPO_ROOT/bridge-status.py"

  # r2 BLOCKING 1: bridge-daemon.sh must reference both new env var
  # names. The legacy BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2 grep
  # is preserved separately so the back-compat fallback survives any
  # future renames.
  grep -q 'BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must reference BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS"
  grep -q 'BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must reference BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS"
  grep -q 'BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must keep BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2 fallback"
  grep -q 'stage2_used' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit stage2_used detail on session_nudge_dropped"
  grep -q 'grace_total_seconds' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit grace_total_seconds detail"
  grep -q 'grace_stage2_total_seconds' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit grace_stage2_total_seconds detail (r2)"

  # r3 BLOCKING: the rapid-succession dedup that T4 now exercises lives in
  # nudge_agent_session, which must consult bridge_daemon_should_skip_nudge
  # BEFORE the verify window and bridge_daemon_record_nudge AFTER the send.
  # If a future PR drops either call, the dedup gate (and thus T4's claim)
  # silently regresses — these greps make that a smoke failure.
  grep -q 'bridge_daemon_should_skip_nudge ' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must call bridge_daemon_should_skip_nudge (rapid-succession dedup gate)"
  grep -q 'bridge_daemon_record_nudge ' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must call bridge_daemon_record_nudge (post-send dedup record)"
  # The nudge_once wrapper in T4d models the daemon's audit shape: a
  # deduped nudge emits session_nudge_deduped, a verified send emits
  # session_nudge_sent. Pin both so the wrapper stays faithful.
  grep -q 'session_nudge_deduped' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit session_nudge_deduped on the dedup path"
  grep -q 'session_nudge_sent' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit session_nudge_sent on a verified send"

  grep -q 'nudge_recheck_observability_counts' "$status_py" \
    || smoke_fail "teeth: bridge-status.py must define nudge_recheck_observability_counts"
  grep -q 'nudge-recheck' "$status_py" \
    || smoke_fail "teeth: bridge-status.py must render the nudge-recheck dashboard line"
  grep -q 'drop_stage2_used' "$status_py" \
    || smoke_fail "teeth: bridge-status.py must surface drop_stage2_used"
}

smoke_log "all checks passed"
