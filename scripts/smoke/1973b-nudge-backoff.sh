#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1973b-nudge-backoff.sh
#
# Issue #1973 Track B — capped exponential re-nudge backoff (no fixed-
# interval storm). During the v0.16.15 drain-stall outage the daemon's
# unclaimed-task / cron-followup re-notification re-fired about every 5
# minutes with NO backoff, which the operator experienced as a notification
# storm. Track B extends the EXISTING per-task nudge state (no parallel
# registry) so each (agent, task) re-nudge interval grows
# base -> base*2 -> ... -> cap, resetting when the task makes real progress
# (claim/done/reassign -> no longer queued -> state pruned). The #1944
# `[unclaimed-task]` once-latch stays the DEFAULT; only when an operator
# opts into periodic re-nudging (cooldown>0) does the capped backoff apply.
#
# Teeth:
#   B1 — routine idle-nudge backoff: bridge_daemon_record_nudge advances a
#        per-task NUDGE_TASK_NEXT_TS_<id> on a capped exponential schedule
#        (60 -> 120 -> 240 -> ... -> cap) and bridge_daemon_should_skip_nudge
#        honors it; a task leaving the live set RESETS attempts (re-queue
#        starts at the base window again). Urgent/high tasks use the lower
#        cap. The Track-C one-shot force bypass fires exactly once.
#   B2 — `[unclaimed-task]` default once-latch is single-shot (regression
#        guard against the storm), periodic mode (cooldown>0) backs off on a
#        capped exponential schedule instead of a fixed interval, and the
#        attached-human-followup escalation upserts ONE admin task while its
#        refresh cadence backs off too.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess. The daemon functions are sourced via the same awk/py extractor
# the 1944 smoke uses; all queue mutation is via the bridge-queue.py CLI.

set -euo pipefail

# Re-exec under Bash 4+ for the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1973b-nudge-backoff] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1973b-nudge-backoff"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
QUEUE="$REPO_ROOT/bridge-queue.py"

smoke_require_cmd python3
smoke_require_cmd sqlite3

ADMIN="admin-agent"
TARGET="stuck-agent"

export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$BRIDGE_LOG_DIR"
: >"$AUDIT_LOG"

# --- Boundary stubs (everything except the functions under test) ------
bridge_audit_log() {
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_csv=""
  while (( $# )); do
    case "$1" in
      --detail)
        if [[ -n "$detail_csv" ]]; then detail_csv+=";"; fi
        detail_csv+="$2"
        shift 2 ;;
      *) shift ;;
    esac
  done
  printf '{"actor":"%s","action":"%s","target":"%s","detail":"%s"}\n' \
    "$actor" "$action" "$target" "$detail_csv" >>"$AUDIT_LOG"
}
daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
daemon_info() { printf '[stub-info] %s\n' "$*"; }
bridge_require_python() { command -v python3 >/dev/null 2>&1; }

# --- Extract the daemon functions under test --------------------------
HELPERS_SUBSET="$SMOKE_TMP_ROOT/daemon-helpers.sh"
WANTED_HELPERS=(
  bridge_daemon_nudge_state_file
  bridge_daemon_compute_nudge_fingerprint
  bridge_daemon_nudge_task_ts_var
  bridge_daemon_nudge_task_field_var
  bridge_daemon_nudge_backoff_delay
  bridge_daemon_nudge_dedup_load
  bridge_daemon_nudge_dedup_reset_scope
  bridge_daemon_should_skip_nudge
  bridge_daemon_record_nudge
)
WANTED_CSV="$(IFS=,; echo "${WANTED_HELPERS[*]}")"
export WANTED_CSV
python3 - "$REPO_ROOT/bridge-daemon.sh" >"$HELPERS_SUBSET" <<'PY'
import os, re, sys
src_path = sys.argv[1]
wanted = set(os.environ.get("WANTED_CSV", "").split(","))
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
PY
# shellcheck source=/dev/null
source "$HELPERS_SUBSET"

# --- helpers ----------------------------------------------------------
# Read a per-task field var value straight out of the on-disk nudge state
# file for the given agent. Echoes empty when absent. Parses the file text
# directly (NOT `source`) so a same-named var left in the parent test scope
# by the in-process record/load functions cannot leak into the reading and
# mask a genuine on-disk prune.
read_state_field() {
  local agent="$1" var="$2" file line val=""
  file="$(bridge_daemon_nudge_state_file "$agent")"
  [[ -f "$file" ]] || { printf ''; return 0; }
  # Last assignment wins (matches `source` semantics). Strip the `%q` quoting
  # the writer applies to plain integer values (none for our numeric fields).
  while IFS= read -r line; do
    case "$line" in
      "${var}="*) val="${line#*=}" ;;
    esac
  done <"$file"
  printf '%s' "$val"
}

# ======================================================================
# B0 — pure backoff math: 60/120/240/cap + urgent lower cap
# ======================================================================
smoke_run "B0 backoff delay is capped exponential (60/120/240/...->cap)" : ; {
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS \
        BRIDGE_DAEMON_NUDGE_REDELIVERY_URGENT_MAX_SECONDS
  smoke_assert_eq 60  "$(bridge_daemon_nudge_backoff_delay 0 normal)" "B0 attempt0 = base 60"
  smoke_assert_eq 120 "$(bridge_daemon_nudge_backoff_delay 1 normal)" "B0 attempt1 = 120"
  smoke_assert_eq 240 "$(bridge_daemon_nudge_backoff_delay 2 normal)" "B0 attempt2 = 240"
  smoke_assert_eq 480 "$(bridge_daemon_nudge_backoff_delay 3 normal)" "B0 attempt3 = 480"
  smoke_assert_eq 900 "$(bridge_daemon_nudge_backoff_delay 4 normal)" "B0 attempt4 clamps to cap 900"
  smoke_assert_eq 900 "$(bridge_daemon_nudge_backoff_delay 9 normal)" "B0 large attempt stays at cap 900"
  # A huge attempt count must not overflow the shift; still clamps to cap.
  smoke_assert_eq 900 "$(bridge_daemon_nudge_backoff_delay 99 normal)" "B0 overflow-guarded attempt stays at cap"
  # Urgent/high get the LOWER cap (default 300) even past base.
  smoke_assert_eq 300 "$(bridge_daemon_nudge_backoff_delay 4 urgent)" "B0 urgent clamps to lower urgent cap 300"
  smoke_assert_eq 300 "$(bridge_daemon_nudge_backoff_delay 9 high)"   "B0 high clamps to lower urgent cap 300"
  # Custom base/cap honored.
  smoke_assert_eq 40 "$(BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=10 BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS=1000 bridge_daemon_nudge_backoff_delay 2 normal)" "B0 custom base 10 -> attempt2 = 40"
  # When the urgent cap is LOWER than base, the cap dominates (no base floor
  # pushing it back up) — the bug the floor=min(base,cap) fix guards.
  smoke_assert_eq 30 "$(BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=120 BRIDGE_DAEMON_NUDGE_REDELIVERY_URGENT_MAX_SECONDS=30 bridge_daemon_nudge_backoff_delay 0 urgent)" "B0 urgent cap below base collapses floor to cap"
}

# ======================================================================
# B1 — routine record/skip cycle backs off and resets on progress
# ======================================================================
smoke_run "B1 routine nudge state backs off exponentially + resets on progress" : ; {
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS \
        BRIDGE_DAEMON_NUDGE_REDELIVERY_URGENT_MAX_SECONDS BRIDGE_DAEMON_NUDGE_FORCE_AGENTS
  agent="b1-agent"
  rm -f "$(bridge_daemon_nudge_state_file "$agent")"
  fp="$(bridge_daemon_compute_nudge_fingerprint "7")"

  # First record: attempts -> 1, NEXT_TS = now + 120 (delay for attempt1).
  bridge_daemon_record_nudge "$agent" "$fp" "7" normal
  a1="$(read_state_field "$agent" NUDGE_TASK_ATTEMPTS_7)"
  smoke_assert_eq 1 "$a1" "B1 first record sets attempts=1"
  ts1="$(read_state_field "$agent" NUDGE_TASK_TS_7)"
  next1="$(read_state_field "$agent" NUDGE_TASK_NEXT_TS_7)"
  smoke_assert_eq 120 "$(( next1 - ts1 ))" "B1 next-window after attempt1 = 120s (base*2)"
  res1="$(read_state_field "$agent" NUDGE_TASK_LAST_RESULT_7)"
  smoke_assert_eq sent "$res1" "B1 last-result recorded as sent"

  # Within the window -> should_skip returns 0 (skip).
  if bridge_daemon_should_skip_nudge "$agent" "$fp" "7"; then :; else
    smoke_fail "B1 within the backoff window the nudge must be skipped"
  fi

  # Backdate the recorded ts past the 120s window -> should fire again.
  state_file="$(bridge_daemon_nudge_state_file "$agent")"
  old_ts="$(( $(date +%s) - 1000 ))"
  sed -i.bak "s/^NUDGE_TASK_TS_7=.*/NUDGE_TASK_TS_7=${old_ts}/; s/^NUDGE_TASK_NEXT_TS_7=.*/NUDGE_TASK_NEXT_TS_7=$(( old_ts + 120 ))/" "$state_file"
  rm -f "${state_file}.bak"
  if bridge_daemon_should_skip_nudge "$agent" "$fp" "7"; then
    smoke_fail "B1 once the window elapsed the nudge must fire (not skip)"
  fi

  # Second record: attempts -> 2, next window doubles to 240s.
  bridge_daemon_record_nudge "$agent" "$fp" "7" normal
  a2="$(read_state_field "$agent" NUDGE_TASK_ATTEMPTS_7)"
  smoke_assert_eq 2 "$a2" "B1 second record advances attempts=2"
  ts2="$(read_state_field "$agent" NUDGE_TASK_TS_7)"
  next2="$(read_state_field "$agent" NUDGE_TASK_NEXT_TS_7)"
  smoke_assert_eq 240 "$(( next2 - ts2 ))" "B1 next-window after attempt2 = 240s"

  # Third record: attempts -> 3, window 480s.
  bridge_daemon_record_nudge "$agent" "$fp" "7" normal
  ts3="$(read_state_field "$agent" NUDGE_TASK_TS_7)"
  next3="$(read_state_field "$agent" NUDGE_TASK_NEXT_TS_7)"
  smoke_assert_eq 480 "$(( next3 - ts3 ))" "B1 next-window after attempt3 = 480s"

  # RESET on progress: the task leaves the live set (claimed/done). The next
  # record with a DIFFERENT live id prunes #7 entirely; a later re-queue of
  # #7 starts attempts at 1 again with the base*2 window.
  bridge_daemon_record_nudge "$agent" "$(bridge_daemon_compute_nudge_fingerprint "9")" "9" normal
  pruned="$(read_state_field "$agent" NUDGE_TASK_ATTEMPTS_7)"
  smoke_assert_eq "" "$pruned" "B1 task leaving the live set prunes its backoff state (reset)"
  bridge_daemon_record_nudge "$agent" "$fp" "7" normal
  a_reset="$(read_state_field "$agent" NUDGE_TASK_ATTEMPTS_7)"
  smoke_assert_eq 1 "$a_reset" "B1 re-queued task restarts at attempts=1 (backoff reset)"
  ts_r="$(read_state_field "$agent" NUDGE_TASK_TS_7)"
  next_r="$(read_state_field "$agent" NUDGE_TASK_NEXT_TS_7)"
  smoke_assert_eq 120 "$(( next_r - ts_r ))" "B1 reset restores the base*2 window (no carried backoff)"
}

# ======================================================================
# B1b — Track-C one-shot force bypass overrides the backoff window
# ======================================================================
smoke_run "B1b Track-C force-agents env bypasses the backoff once" : ; {
  unset BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS
  agent="b1b-agent"
  rm -f "$(bridge_daemon_nudge_state_file "$agent")"
  fp="$(bridge_daemon_compute_nudge_fingerprint "5")"
  bridge_daemon_record_nudge "$agent" "$fp" "5" normal
  # Inside the window -> normally skipped.
  if bridge_daemon_should_skip_nudge "$agent" "$fp" "5"; then :; else
    smoke_fail "B1b precondition: fresh record should be within the window (skip)"
  fi
  # With the agent in the force list, the gate must NOT skip (fire).
  if BRIDGE_DAEMON_NUDGE_FORCE_AGENTS="other,$agent,more" \
       bridge_daemon_should_skip_nudge "$agent" "$fp" "5"; then
    smoke_fail "B1b Track-C force bypass must force a re-nudge (not skip)"
  fi
  # A different agent in the list is unaffected (still skipped).
  if BRIDGE_DAEMON_NUDGE_FORCE_AGENTS="someone-else" \
       bridge_daemon_should_skip_nudge "$agent" "$fp" "5"; then :; else
    smoke_fail "B1b force list must only bypass the named agent"
  fi
}

# ======================================================================
# B2 setup — real queue DB + the escalation functions under test
# ======================================================================
DB="$BRIDGE_STATE_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"
python3 "$QUEUE" init >/dev/null
export BRIDGE_ADMIN_AGENT_ID="$ADMIN"
export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_SECS=1

declare -ga BRIDGE_AGENT_IDS=("$ADMIN" "$TARGET")
bridge_agent_exists() { local a="$1"; [[ "$a" == "$ADMIN" || "$a" == "$TARGET" ]]; }
bridge_queue_cli() { python3 "$QUEUE" "$@"; }
bridge_queue_task_status() {
  python3 "$QUEUE" show "$1" --format shell 2>/dev/null \
    | sed -n 's/^TASK_STATUS=//p' | tr -d "'"
}
export BRIDGE_SCRIPT_DIR="$REPO_ROOT"
bridge_daemon_helper_python() {
  local helper="${1:-}"; [[ -n "$helper" ]] || return 1; shift || true
  python3 "$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/$helper.py" "$@"
}

ESC_HELPERS="$SMOKE_TMP_ROOT/esc-helpers.sh"
ESC_WANTED=(
  bridge_daemon_unclaimed_escalation_state_dir
  bridge_daemon_unclaimed_escalation_marker_file
  process_unclaimed_queue_escalation
  bridge_daemon_sweep_stale_unclaimed_markers
)
ESC_CSV="$(IFS=,; echo "${ESC_WANTED[*]}")"
export WANTED_CSV="$ESC_CSV"
python3 - "$REPO_ROOT/bridge-daemon.sh" >"$ESC_HELPERS" <<'PY'
import os, re, sys
src_path = sys.argv[1]
wanted = set(os.environ.get("WANTED_CSV", "").split(","))
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
PY
# shellcheck source=/dev/null
source "$ESC_HELPERS"

# shellcheck disable=SC2120  # optional override arg; all callers use the $TARGET default
escalations_for_target() {
  local who="${1:-$TARGET}" n
  if n="$(grep -c "\"action\":\"task_unclaimed_escalated\".*target_agent=${who};" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}
count_open_with_prefix() {
  local prefix="$1" json
  json="$(python3 "$QUEUE" find-open --agent "$ADMIN" --title-prefix "$prefix" --all --format json 2>/dev/null || printf '[]')"
  python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$json"
}
backdate_task() {
  local task_id="$1" seconds_ago="${2:-600}" cutoff
  cutoff="$(( $(date +%s) - seconds_ago ))"
  # Age BOTH created_ts and updated_ts: the unclaimed-task filter ages from
  # max(created_ts, updated_ts) (Issue #1970 — a just-requeued task carries a
  # fresh updated_ts), so backdating created_ts alone leaves the fixture
  # "fresh" and no escalation fires. Backdate both to age it past threshold.
  sqlite3 "$DB" "UPDATE tasks SET created_ts=${cutoff}, updated_ts=${cutoff} WHERE id=${task_id};"
}
queue_stuck_task() {
  local title="$1" out id
  out="$(python3 "$QUEUE" create --to "$TARGET" --from someone --priority normal \
           --title "$title" --body "stuck body" --format shell)"
  id="$(printf '%s\n' "$out" | sed -n 's/^TASK_ID=//p' | tr -d "'")"
  backdate_task "$id" 600
  printf '%s' "$id"
}
UNCLAIMED_PREFIX="[unclaimed-task] #"

# ======================================================================
# B2a — default once-latch stays single-shot (storm regression guard)
# ======================================================================
smoke_run "B2a default once-latch: many ticks emit a single escalation" : ; {
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS
  : >"$AUDIT_LOG"
  stuck_id="$(queue_stuck_task "default once-latch thing")"
  process_unclaimed_queue_escalation || true
  # Backdate the marker far into the past (preserving line 2 = agent) — under
  # the pre-#1944 fixed-cooldown this re-fired every tick (the storm). The
  # default once-latch must keep it at ONE.
  marker="$(bridge_daemon_unclaimed_escalation_marker_file "$stuck_id")"
  printf '%s\n%s\n' "$(( $(date +%s) - 99999 ))" "$TARGET" >"$marker"
  process_unclaimed_queue_escalation || true
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target)" "B2a default once-latch fires exactly once across many ticks"
  smoke_assert_eq 1 "$(count_open_with_prefix "$UNCLAIMED_PREFIX")" "B2a exactly one open [unclaimed-task] admin task"
}

# ======================================================================
# B2b — periodic mode (cooldown>0) backs off exponentially, not fixed
# ======================================================================
smoke_run "B2b periodic mode re-arm uses capped exponential, not fixed" : ; {
  : >"$AUDIT_LOG"
  # Isolate from B2a: claim every still-queued TARGET task and drop stale
  # escalation markers so only B2b's own task drives this case.
  esc_dir="$(bridge_daemon_unclaimed_escalation_state_dir)"
  rm -f "$esc_dir"/*.ts 2>/dev/null || true
  prior_ids="$(python3 "$QUEUE" find-open --agent "$TARGET" --status-filter queued --all --format json \
    | python3 -c 'import json,sys; print(" ".join(str(r["id"]) for r in json.load(sys.stdin)))')"
  for _pid in $prior_ids; do python3 "$QUEUE" claim "$_pid" --agent "$TARGET" >/dev/null 2>&1 || true; done
  base=100
  export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS="$base"
  # Keep the cap high so the doubling is observable across attempts.
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS=100000
  pid="$(queue_stuck_task "periodic backoff thing")"
  marker="$(bridge_daemon_unclaimed_escalation_marker_file "$pid")"

  # Tick 1 -> first escalation; marker attempts=1.
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target)" "B2b first tick escalates once"
  smoke_assert_eq 1 "$(sed -n '3p' "$marker")" "B2b marker records attempt count = 1"

  # First re-arm window = base*2^1 = 200s. A re-tick at 150s elapsed (inside
  # 200 but PAST the old fixed base of 100) must STILL be suppressed — proof
  # the window grew past the seed, not a fixed `base` interval.
  printf '%s\n%s\n%s\n' "$(( $(date +%s) - 150 ))" "$TARGET" "1" >"$marker"
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target)" "B2b re-tick at 150s (inside the grown 200s window) is suppressed"

  # Past the 200s window -> re-arm. attempts advances to 2.
  printf '%s\n%s\n%s\n' "$(( $(date +%s) - 250 ))" "$TARGET" "1" >"$marker"
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 2 "$(escalations_for_target)" "B2b past the 200s window the periodic escalation re-arms"
  smoke_assert_eq 2 "$(sed -n '3p' "$marker")" "B2b marker attempt count advances to 2 after re-arm"

  # Second re-arm window = base*2^2 = 400s. A re-tick at 300s elapsed (past
  # the prior 200s window) must be suppressed — the window keeps growing.
  printf '%s\n%s\n%s\n' "$(( $(date +%s) - 300 ))" "$TARGET" "2" >"$marker"
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 2 "$(escalations_for_target)" "B2b re-tick at 300s (inside the grown 400s window) is suppressed (window doubled again)"
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS
}

# ======================================================================
# B2c — attached-human-followup upserts ONE task + backs off its refresh
# ======================================================================
# Extract the attached-human-followup escalation + its marker helper and
# drive it directly: two refreshes within the grown backoff window must NOT
# create a second admin task (upsert-open), and the rate-limit window must
# grow past the seed cooldown (capped exponential, not fixed).
AH_HELPERS="$SMOKE_TMP_ROOT/ah-helpers.sh"
AH_WANTED=(
  bridge_daemon_attached_human_followup_marker_file
  bridge_daemon_attached_human_followup_escalate
  bridge_daemon_nudge_backoff_delay
)
AH_CSV="$(IFS=,; echo "${AH_WANTED[*]}")"
export WANTED_CSV="$AH_CSV"
python3 - "$REPO_ROOT/bridge-daemon.sh" >"$AH_HELPERS" <<'PY'
import os, re, sys
src_path = sys.argv[1]
wanted = set(os.environ.get("WANTED_CSV", "").split(","))
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
PY
# shellcheck source=/dev/null
source "$AH_HELPERS"

smoke_run "B2c attached-human-followup upserts ONE task + backs off refresh" : ; {
  : >"$AUDIT_LOG"
  ah_base=100
  export BRIDGE_FORWARD_FOLLOWUP_ATTACHED_ESCALATE_COOLDOWN_SECS="$ah_base"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS=100000
  src_id="$(queue_stuck_task "human followup source")"
  STRANDED_PREFIX="[forward-followup-stranded] #${src_id} on ${TARGET} "

  # First escalation files ONE admin task; marker attempts -> 1.
  bridge_daemon_attached_human_followup_escalate \
    "$TARGET" "sess-1" "1" "$src_id" "$src_id" "human followup source" \
    "$(( $(date +%s) - 600 ))" "forward_to_user" "discord" "ref" "text" "1" "0" || true
  n1="$(count_open_with_prefix "$STRANDED_PREFIX")"
  smoke_assert_eq 1 "$n1" "B2c first escalation files exactly one admin task"
  marker_ah="$(bridge_daemon_attached_human_followup_marker_file "$src_id")"
  smoke_assert_eq 1 "$(sed -n '2p' "$marker_ah")" "B2c marker records attempt count = 1"

  # First re-arm window = base*2 = 200s. A refresh at 150s elapsed (past the
  # seed 100s but inside the grown 200s window) must be suppressed AND must
  # NOT create a second admin task.
  printf '%s\n%s\n' "$(( $(date +%s) - 150 ))" "1" >"$marker_ah"
  bridge_daemon_attached_human_followup_escalate \
    "$TARGET" "sess-1" "1" "$src_id" "$src_id" "human followup source" \
    "$(( $(date +%s) - 600 ))" "forward_to_user" "discord" "ref" "text" "1" "0" || true
  smoke_assert_eq 1 "$(count_open_with_prefix "$STRANDED_PREFIX")" "B2c refresh inside the grown window upserts (still ONE task)"

  # Past the 200s window -> refresh fires; attempts -> 2; still ONE task.
  printf '%s\n%s\n' "$(( $(date +%s) - 250 ))" "1" >"$marker_ah"
  bridge_daemon_attached_human_followup_escalate \
    "$TARGET" "sess-1" "1" "$src_id" "$src_id" "human followup source" \
    "$(( $(date +%s) - 600 ))" "forward_to_user" "discord" "ref" "text" "1" "0" || true
  smoke_assert_eq 1 "$(count_open_with_prefix "$STRANDED_PREFIX")" "B2c refresh past the window still upserts ONE task (never a stream)"
  smoke_assert_eq 2 "$(sed -n '2p' "$marker_ah")" "B2c marker attempt count advances to 2 after the window elapsed"
  unset BRIDGE_FORWARD_FOLLOWUP_ATTACHED_ESCALATE_COOLDOWN_SECS BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS
}

# ======================================================================
# B_teeth — structural shape so a revert fails this smoke
# ======================================================================
smoke_run "B_teeth backoff source shape" : ; {
  daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  grep -q 'bridge_daemon_nudge_backoff_delay()' "$daemon_sh" \
    || smoke_fail "teeth: capped-backoff helper bridge_daemon_nudge_backoff_delay must exist"
  grep -q 'NUDGE_TASK_NEXT_TS' "$daemon_sh" \
    || smoke_fail "teeth: per-task NEXT_TS backoff field must be present in the nudge state"
  grep -q 'BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS' "$daemon_sh" \
    || smoke_fail "teeth: backoff cap env BRIDGE_DAEMON_NUDGE_REDELIVERY_MAX_SECONDS must be present"
  grep -q 'BRIDGE_DAEMON_NUDGE_FORCE_AGENTS' "$daemon_sh" \
    || smoke_fail "teeth: Track-C one-shot force-bypass seam must be present"
  # The #1944 once-latch default MUST remain (cooldown defaults to 0).
  grep -q 'BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS:-0' "$daemon_sh" \
    || smoke_fail "teeth: #1944 once-latch default (cooldown 0) must be preserved"
  grep -q '(( cooldown == 0 ))' "$daemon_sh" \
    || smoke_fail "teeth: #1944 once-latch short-circuit must be preserved"
}

smoke_log "all tests passed: $SMOKE_NAME"
