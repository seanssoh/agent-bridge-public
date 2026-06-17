#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1944-unclaimed-escalation-once-latch.sh
#
# Issue #1944 (cm-prod RCA F6) — daemon nudge-retry churn on idle/wedged
# agents. The unclaimed-task escalation (process_unclaimed_queue_escalation)
# re-minted a fresh high-priority admin escalation task every cooldown
# window (default 1800s) for a STILL-stuck queued task — cm-prod saw
# #8691/#8765/... all for the same queued #8677. The fix makes the
# per-(agent, task) marker a once-latch: by default (cooldown==0) a marker
# present + task still queued suppresses every further escalation until the
# stale-marker sweep clears it (task leaves `queued`). Operators who want
# periodic re-nudging opt back in via
# BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS>0.
#
# This smoke drives process_unclaimed_queue_escalation + the stale-marker
# sweep END-TO-END against a REAL queue DB (the dedupe path that the
# beta5-2-iota smoke's T6 explicitly left out as "needs a real DB"):
#
#   D1 — default once-latch: 3 ticks on a still-stuck queued task →
#        exactly ONE task_unclaimed_escalated audit row and ONE open
#        [unclaimed-task] admin task (NOT 3 — the #1944 churn).
#   D2 — the single escalation body advertises the once-only cadence
#        (no "fires at most once per <N>s cooldown window" text) so the
#        operator is not told a re-nudge is coming.
#   D3 — re-arm after the task leaves `queued`: claim the stuck task →
#        sweep clears the marker → re-queue (fresh id) re-escalates once.
#   D4 — opt-in periodic re-nudging: with
#        BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS>0 the legacy
#        cooldown re-arm still fires a second escalation after the window
#        elapses (back-compat for operators who set the knob).
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess. The daemon function is sourced via the same awk/py extractor
# the iota smoke uses; all queue mutation is via the bridge-queue.py CLI.

set -euo pipefail

# Re-exec under Bash 4+ for the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1944-unclaimed-escalation-once-latch] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1944-unclaimed-escalation-once-latch"
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
TARGET2="stuck-agent-2"

export BRIDGE_ADMIN_AGENT_ID="$ADMIN"
# Age threshold 1s: we backdate created_ts so the task is "expired"
# deterministically without sleeping.
export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_SECS=1

DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_STATE_DIR"
export BRIDGE_TASK_DB="$DB"
python3 "$QUEUE" init >/dev/null

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$BRIDGE_LOG_DIR"
: >"$AUDIT_LOG"

# --- Boundary stubs (everything except the function under test) -------
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

# Roster: ADMIN + TARGET + TARGET2 all "exist". TARGET holds the stuck task;
# TARGET2 is the reassignment destination in the D5 handoff case.
declare -ga BRIDGE_AGENT_IDS=("$ADMIN" "$TARGET" "$TARGET2")
bridge_agent_exists() {
  local a="$1"
  [[ "$a" == "$ADMIN" || "$a" == "$TARGET" || "$a" == "$TARGET2" ]]
}

# Route the queue CLI to the real bridge-queue.py against the test DB.
bridge_queue_cli() {
  python3 "$QUEUE" "$@"
}
bridge_queue_task_status() {
  python3 "$QUEUE" show "$1" --format shell 2>/dev/null \
    | sed -n 's/^TASK_STATUS=//p' | tr -d "'"
}

# Helper-python dispatcher (same shape the iota smoke uses).
export BRIDGE_SCRIPT_DIR="$REPO_ROOT"
bridge_daemon_helper_python() {
  local helper="${1:-}"
  [[ -n "$helper" ]] || return 1
  shift || true
  python3 "$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/$helper.py" "$@"
}

# --- Extract the daemon functions under test --------------------------
HELPERS_SUBSET="$SMOKE_TMP_ROOT/daemon-helpers.sh"
WANTED_HELPERS=(
  bridge_daemon_unclaimed_escalation_state_dir
  bridge_daemon_unclaimed_escalation_marker_file
  process_unclaimed_queue_escalation
  bridge_daemon_sweep_stale_unclaimed_markers
)
IOTA_WANTED_CSV="$(IFS=,; echo "${WANTED_HELPERS[*]}")"
export IOTA_WANTED_CSV
python3 - "$REPO_ROOT/bridge-daemon.sh" >"$HELPERS_SUBSET" <<'PY'
import os, re, sys
src_path = sys.argv[1]
wanted = set(os.environ.get("IOTA_WANTED_CSV", "").split(","))
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
# Count task_unclaimed_escalated rows whose target_agent detail names the
# given agent (default TARGET) — i.e. the churn the #1944 once-latch
# governs. Scoped to a named target on purpose: the admin's OWN unclaimed
# escalation task can itself age past the (tiny test) threshold and trip
# the admin-target audit-only branch, which is pre-existing behavior
# orthogonal to the once-latch.
escalations_for_target() {
  local who="${1:-$TARGET}" n
  # Anchor on the trailing `;` (target_agent is always followed by another
  # --detail in the stub's CSV) so a prefix agent name like `stuck-agent`
  # does NOT also match `stuck-agent-2`.
  if n="$(grep -c "\"action\":\"task_unclaimed_escalated\".*target_agent=${who};" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}

count_open_with_prefix() {
  local prefix="$1"
  local json
  json="$(python3 "$QUEUE" find-open --agent "$ADMIN" --title-prefix "$prefix" --all --format json 2>/dev/null || printf '[]')"
  python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$json"
}

# Backdate a task's created_ts so it crosses the age threshold without a sleep.
backdate_task() {
  local task_id="$1" seconds_ago="${2:-600}"
  local cutoff
  cutoff="$(( $(date +%s) - seconds_ago ))"
  sqlite3 "$DB" "UPDATE tasks SET created_ts=${cutoff} WHERE id=${task_id};"
}

# Queue a task against TARGET and backdate it so it is an "old unclaimed" task.
queue_stuck_task() {
  local title="$1"
  local out id
  out="$(python3 "$QUEUE" create --to "$TARGET" --from someone --priority normal \
           --title "$title" --body "stuck body" --format shell)"
  id="$(printf '%s\n' "$out" | sed -n 's/^TASK_ID=//p' | tr -d "'")"
  backdate_task "$id" 600
  printf '%s' "$id"
}

UNCLAIMED_PREFIX="[unclaimed-task] #"

# ======================================================================
# D1 — default once-latch: 3 ticks → exactly ONE escalation
# ======================================================================
smoke_run "D1 default once-latch: 3 ticks emit a single escalation" : ; {
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS
  : >"$AUDIT_LOG"
  stuck_id="$(queue_stuck_task "fix the thing")"

  process_unclaimed_queue_escalation || true
  # Simulate a long-stuck task spanning MANY cooldown windows: backdate the
  # marker's ts far into the past while PRESERVING line 2 (the agent key —
  # the daemon writes a 2-line marker). Pre-#1944 (cooldown default 1800s)
  # this is exactly the cm-prod F6 churn trigger — each subsequent tick
  # whose marker ts is older than the cooldown re-escalated. The once-latch
  # default must keep it at ONE regardless of how stale the marker ts is.
  marker="$(bridge_daemon_unclaimed_escalation_marker_file "$stuck_id")"
  printf '%s\n%s\n' "$(( $(date +%s) - 99999 ))" "$TARGET" >"$marker"
  process_unclaimed_queue_escalation || true
  process_unclaimed_queue_escalation || true

  esc_count="$(escalations_for_target)"
  smoke_assert_eq 1 "$esc_count" "D1 task_unclaimed_escalated fires exactly once across 3 ticks (stale marker does NOT re-arm)"

  open_count="$(count_open_with_prefix "$UNCLAIMED_PREFIX")"
  smoke_assert_eq 1 "$open_count" "D1 exactly one open [unclaimed-task] admin task (no per-tick churn)"

  marker="$(bridge_daemon_unclaimed_escalation_marker_file "$stuck_id")"
  smoke_assert_file_exists "$marker" "D1 once-latch marker recorded for the stuck task"
}

# ======================================================================
# D2 — body advertises the once-only cadence (no cooldown-window text)
# ======================================================================
smoke_run "D2 escalation body advertises once-only cadence" : ; {
  open_id="$(python3 "$QUEUE" find-open --agent "$ADMIN" --title-prefix "$UNCLAIMED_PREFIX" --all --format json \
    | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["id"] if rows else "")')"
  [[ -n "$open_id" ]] || smoke_fail "D2 precondition: expected an open [unclaimed-task] from D1"
  # `show --format text` renders the inline body under the `body:` section.
  combined="$(python3 "$QUEUE" show "$open_id" --format text 2>/dev/null)"
  case "$combined" in
    *"once per (agent, queued task id)"*)
      : ;;
    *)
      smoke_fail "D2 body should advertise once-only cadence; got: ${combined:0:200}" ;;
  esac
  case "$combined" in
    *"at most once per"*"cooldown window"*)
      smoke_fail "D2 body must NOT promise a periodic cooldown-window re-nudge under the default" ;;
    *) : ;;
  esac
}

# ======================================================================
# D3 — re-arm after the task leaves `queued`
# ======================================================================
smoke_run "D3 sweep clears marker on claim; re-queue re-escalates" : ; {
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS
  # D1 left exactly one stuck task escalated. Claim it → no longer queued.
  d1_id="$(python3 "$QUEUE" find-open --agent "$TARGET" --status-filter queued --all --format json \
    | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["id"] if rows else "")')"
  [[ -n "$d1_id" ]] || smoke_fail "D3 precondition: expected a queued stuck task from D1"
  python3 "$QUEUE" claim "$d1_id" --agent "$TARGET" >/dev/null

  marker_d1="$(bridge_daemon_unclaimed_escalation_marker_file "$d1_id")"
  bridge_daemon_sweep_stale_unclaimed_markers || true
  if [[ -f "$marker_d1" ]]; then
    smoke_fail "D3 stale-marker sweep should drop the marker once the task is claimed"
  fi

  : >"$AUDIT_LOG"
  new_id="$(queue_stuck_task "another stuck thing")"
  for _ in 1 2 3; do
    process_unclaimed_queue_escalation || true
  done
  re_count="$(escalations_for_target)"
  smoke_assert_eq 1 "$re_count" "D3 a genuine re-queue (new id) re-escalates exactly once"
  [[ "$new_id" != "$d1_id" ]] || smoke_fail "D3 sanity: new task id should differ from the claimed one"
}

# ======================================================================
# D4 — opt-in periodic re-nudging (cooldown>0 back-compat)
# ======================================================================
smoke_run "D4 cooldown>0 opt-in re-arms after the window elapses" : ; {
  : >"$AUDIT_LOG"
  # Large cooldown so the wall-clock cost of a tick can never accidentally
  # exceed the "inside window" threshold (the marker timestamp vs the
  # re-tick now-ts race). We drive the "window elapsed" branch by
  # explicitly backdating the marker instead of sleeping. NB: this block
  # runs at script top level (smoke_run ran `:`), so plain assignment, not
  # `local`.
  cooldown_window=3600
  export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS="$cooldown_window"
  d4_id="$(queue_stuck_task "cooldown opt-in thing")"

  process_unclaimed_queue_escalation || true
  c1="$(escalations_for_target)"
  smoke_assert_eq 1 "$c1" "D4 first tick escalates once"

  # Immediate re-tick well inside the window → suppressed.
  process_unclaimed_queue_escalation || true
  c2="$(escalations_for_target)"
  smoke_assert_eq 1 "$c2" "D4 re-tick inside cooldown window is suppressed"

  # Backdate the marker ts beyond the cooldown window (preserving the agent
  # on line 2 so the (agent, task) latch still applies), then re-tick → re-arm.
  marker_d4="$(bridge_daemon_unclaimed_escalation_marker_file "$d4_id")"
  printf '%s\n%s\n' "$(( $(date +%s) - cooldown_window - 60 ))" "$TARGET" >"$marker_d4"
  process_unclaimed_queue_escalation || true
  c3="$(escalations_for_target)"
  smoke_assert_eq 2 "$c3" "D4 cooldown re-arm fires a second escalation after the window"
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS
}

# ======================================================================
# D5 — same-id handoff/reassignment re-arms the (agent, task) latch
# ======================================================================
# The marker is keyed by (agent, task), NOT task alone. A `handoff` keeps
# the SAME task id and status='queued' but changes the assignee, so a
# marker written for the prior assignee must NOT silence the alert for the
# NEW (now-stuck) assignee. Pre-fix (marker keyed by task id only) this
# was a permanent silent-drop. (codex r1 BLOCKING — issue #1944.)
smoke_run "D5 same-id handoff to a different agent re-escalates once" : ; {
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS
  : >"$AUDIT_LOG"
  ho_id="$(queue_stuck_task "handoff churn thing")"

  # First escalation lands on TARGET; the once-latch then holds for TARGET.
  process_unclaimed_queue_escalation || true
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target "$TARGET")" "D5 escalates once for the original assignee"

  marker_ho="$(bridge_daemon_unclaimed_escalation_marker_file "$ho_id")"
  smoke_assert_file_exists "$marker_ho" "D5 marker present after first escalation"
  # Marker must record the agent on line 2 (the latch key).
  if [[ "$(sed -n '2p' "$marker_ho")" != "$TARGET" ]]; then
    smoke_fail "D5 marker line 2 must record the escalated agent ($TARGET)"
  fi

  # Hand the SAME task off to TARGET2 — same id, stays queued, new assignee.
  python3 "$QUEUE" handoff "$ho_id" --to "$TARGET2" --from "$TARGET" --note "reassign" >/dev/null
  status_after="$(python3 "$QUEUE" show "$ho_id" --format shell | sed -n 's/^TASK_STATUS=//p' | tr -d "'")"
  smoke_assert_eq queued "$status_after" "D5 handoff keeps the task queued (same id)"
  # The backdated created_ts survives handoff (handoff only bumps updated_ts),
  # so the task is still "old" — but re-confirm by backdating defensively.
  backdate_task "$ho_id" 600

  # Re-tick: the latch is keyed by agent, so TARGET2 (no matching marker
  # agent) MUST be escalated even though the marker file still exists.
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target "$TARGET2")" "D5 re-escalates once for the NEW assignee after handoff"
  # And it must not have re-fired again for the original assignee.
  smoke_assert_eq 1 "$(escalations_for_target "$TARGET")" "D5 no duplicate escalation for the original assignee"
  # The marker now records the new agent → a further re-tick is suppressed.
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target "$TARGET2")" "D5 once-latch re-engages for the new assignee"
  if [[ "$(sed -n '2p' "$marker_ho")" != "$TARGET2" ]]; then
    smoke_fail "D5 marker line 2 must be re-stamped to the new agent ($TARGET2)"
  fi
}

# ======================================================================
# D6 — legacy single-line marker (empty line 2) must not silent-drop
# ======================================================================
# A marker left on disk by a pre-#1944 daemon has only line 1 (the ts) and
# an empty line 2. Treating an empty agent as a match would re-open the
# silent-drop after a handoff (codex r2 BLOCKING). The latch must apply
# ONLY when line 2 names the current assignee, so a legacy marker
# re-escalates ONCE and re-stamps itself with the agent.
smoke_run "D6 legacy one-line marker re-escalates once and self-heals" : ; {
  unset BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS
  : >"$AUDIT_LOG"
  leg_id="$(queue_stuck_task "legacy marker thing")"

  # Simulate a pre-#1944 marker: ts only, no agent line.
  marker_leg="$(bridge_daemon_unclaimed_escalation_marker_file "$leg_id")"
  mkdir -p "$(dirname "$marker_leg")"
  printf '%s\n' "$(date +%s)" >"$marker_leg"
  [[ -z "$(sed -n '2p' "$marker_leg")" ]] || smoke_fail "D6 precondition: marker line 2 must be empty"

  # First tick: empty line 2 → NOT trusted as a match → re-escalate once.
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target "$TARGET")" "D6 legacy marker re-escalates once (no silent-drop)"
  # The marker self-heals: line 2 now names the agent.
  if [[ "$(sed -n '2p' "$marker_leg")" != "$TARGET" ]]; then
    smoke_fail "D6 legacy marker must self-heal: line 2 should now record $TARGET"
  fi
  # Subsequent ticks are suppressed (the latch now has the agent key).
  process_unclaimed_queue_escalation || true
  smoke_assert_eq 1 "$(escalations_for_target "$TARGET")" "D6 once-latch re-engages after self-heal"
}

# ======================================================================
# D_teeth — structural shape so a revert fails this smoke
# ======================================================================
smoke_run "D_teeth once-latch source shape" : ; {
  daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  # The default cooldown must be once-only (0), not the pre-#1944 1800s.
  grep -q 'BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS:-0' "$daemon_sh" \
    || smoke_fail "teeth: unclaimed-escalation cooldown must default to 0 (once-only)"
  # The once-latch short-circuit must exist.
  grep -q '(( cooldown == 0 ))' "$daemon_sh" \
    || smoke_fail "teeth: once-latch short-circuit '(( cooldown == 0 ))' must be present"
  # The (agent, task) latch key: the marker must record the agent and the
  # escalation must compare it against the current assignee (codex r1).
  # Issue #1973 Track B extended the marker with a line-3 attempt count for
  # the periodic-mode backoff; the agent must still be the line-2 field
  # (`"$now_ts" "$agent"` immediately after the ts), so anchor on that
  # ordering rather than the exact line count.
  grep -qF 'printf '\''%s\n%s\n%s\n'\'' "$now_ts" "$agent" "$(( _esc_new_attempts + 1 ))"' "$daemon_sh" \
    || smoke_fail "teeth: marker must record the agent on line 2 (agent,task latch key)"
  grep -q '_marker_agent' "$daemon_sh" \
    || smoke_fail "teeth: escalation must compare the marker agent to the current assignee"
}

smoke_log "all tests passed: $SMOKE_NAME"
