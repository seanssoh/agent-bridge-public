#!/usr/bin/env bash
# scripts/smoke/9882-daemon-audit-fp.sh — regression smoke for the #9882
# daemon duplicate-execution AUDIT FALSE-POSITIVE fix (PR-1b of the rc2
# #1563 daemon redesign). Covers BUG A + BUG B.
#
# Root cause (#9882, evidence #9872/#9880): on a HEALTHY single-daemon host
# the duplicate-daemon audit false-positived TWICE in 15 minutes. The daemon
# was fine; the ALERT logic over-escalated.
#
#   BUG A — bridge_daemon_self_check escalated an admin "duplicate daemon"
#     task whenever the latest `daemon_started` audit pid was alive + had a
#     `bridge-daemon.sh run` cmdline, UNLESS an owner record positively
#     DISPROVED it. Every INCONCLUSIVE case (no owner record, owner_rec_pid
#     != latest_pid, unreadable start-time, or matching start-times) fell to
#     `other_alive=true` and pushed the admin task → the false positive.
#
#   BUG B — `daemon_started` must be emitted only by the surviving singleton
#     holder AT the final long-lived daemon pid. A wrapper that FORKS (not
#     exec) `bridge-daemon.sh run` would emit at the wrapper pid, which then
#     differs from the real daemon $$ → feeds BUG A's mismatch path.
#
# The #9882 fix makes BUG A escalate ONLY on POSITIVE proof of a distinct
# live duplicate generation (alive + daemon cmdline + owner record names
# this pid + owner-record start_time matches live `ps -o lstart=` + pid !=
# self); every inconclusive mismatch is audit-only
# (`escalation=suppressed_unproven`), no admin task. PR-1 (#1563) guarantees
# the singleton always writes the owner record, so a GENUINE duplicate is
# still provable and STILL alerts.
#
# Everything sourced here is the REAL shipped lib (lib/bridge-daemon-
# control.sh), not a copy, so a revert of the gate fails this smoke.
#
# Assertions:
#   A1 — no-FP / unproven: a `daemon_started` row for an ALIVE,
#        daemon-cmdline pid with NO owner record → self_check emits
#        `daemon_pid_mismatch` with `escalation=suppressed_unproven`,
#        returns 1, and pushes NO admin task. (Teeth: revert the gate and
#        it escalates → this assertion catches it.)
#   A2 — no-FP / owner record names a DIFFERENT pid (inconclusive): alive
#        daemon-cmdline pid, owner record present but owner_rec_pid !=
#        latest_pid → still audit-only, NO admin task.
#   A3 — real-dup STILL alerts: an ALIVE daemon-cmdline pid WITH a matching
#        owner record (owner_rec_pid == latest_pid AND owner-record
#        start_time == live lstart) and pid != self → escalation=
#        proven_duplicate and the admin task IS pushed (the legitimate alert
#        still fires; the proof gate is not a blanket no-alert).
#   A4 — recycled-pid preserved: alive daemon-cmdline pid whose owner-record
#        start_time PROVABLY mismatches the live lstart → recycled_pid=true,
#        return 1, NO admin task (existing #1563 behavior, unchanged).
#   B1 — BUG B static invariant: exactly ONE `bridge_audit_log daemon
#        daemon_started` emit exists in the tree, it lives inside
#        bridge_daemon_ensure_singleton, and ensure_singleton is called from
#        exactly ONE site (cmd_run). No spawn/wrapper path emits the row.
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge state
# is touched. Stand-in daemons live on a smoke-local PATH, never the system
# binaries.
#
# Footgun #11: write-to-file heredocs (`cat >FILE <<TAG`) + printf only — no
# heredoc-stdin to subprocess, no here-strings, no process substitution.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
SKIPS=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
# _skip: an environment limitation prevented an assertion from running, but
# it is NOT a regression. Loud by design.
_skip() { TOTAL=$((TOTAL + 1)); SKIPS=$((SKIPS + 1)); printf '[skip] %s: %s\n' "$1" "$2"; }

CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
if [[ ! -r "$CONTROL_LIB" ]]; then
  printf '[FAIL] daemon-control lib not found at %s\n' "$CONTROL_LIB" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-9882-smoke.XXXXXX")"

STANDIN_PIDS=()
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() {
  local p
  for p in "${STANDIN_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$SMOKE_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Isolated bridge home + state dir. Nothing here touches ~/.agent-bridge.
export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_HOME/logs"

# self_check reads the latest `daemon_started` pid from this JSONL audit log.
export BRIDGE_AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"

# Capture the action token (2nd arg) of every bridge_audit_log call so the
# assertions can grep for daemon_pid_mismatch. We also persist the full arg
# vector of the LAST call to a file so we can assert the escalation detail.
AUDIT_LOG="$SMOKE_DIR/audit-actions.log"
AUDIT_LAST_ARGS="$SMOKE_DIR/audit-last-args.log"
: >"$AUDIT_LOG"
: >"$AUDIT_LAST_ARGS"
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_audit_log() {
  printf '%s\n' "${2:-}" >>"$AUDIT_LOG" 2>/dev/null || true
  printf '%s\n' "$*" >"$AUDIT_LAST_ARGS" 2>/dev/null || true
}
audit_count() {
  local token="$1"
  grep -c -x "$token" "$AUDIT_LOG" 2>/dev/null | tr -dc '0-9' | head -c 8
}
reset_audit() { : >"$AUDIT_LOG"; : >"$AUDIT_LAST_ARGS"; }

# Admin agent + bridge-task.sh stub: self_check pushes the duplicate-daemon
# alert only when BOTH an admin agent id AND a resolvable bridge-task.sh are
# available. We point BRIDGE_SCRIPT_DIR at a smoke-local dir holding a stub
# `bridge-task.sh` that records every invocation to ESCALATION_LOG, and set
# BRIDGE_ADMIN_AGENT_ID. So "did self_check escalate?" == "was the stub
# invoked?".
export BRIDGE_ADMIN_AGENT_ID="smoke-admin"
STUB_SCRIPT_DIR="$SMOKE_DIR/bin"
mkdir -p "$STUB_SCRIPT_DIR"
export BRIDGE_SCRIPT_DIR="$STUB_SCRIPT_DIR"
ESCALATION_LOG="$SMOKE_DIR/escalation.log"
: >"$ESCALATION_LOG"
TASK_STUB="$STUB_SCRIPT_DIR/bridge-task.sh"
cat >"$TASK_STUB" <<STUB
#!/usr/bin/env bash
# Records that self_check pushed the admin duplicate-daemon alert.
printf 'escalated %s\n' "\$*" >>"$ESCALATION_LOG" 2>/dev/null || true
exit 0
STUB
chmod +x "$TASK_STUB"
escalation_count() {
  grep -c '^escalated ' "$ESCALATION_LOG" 2>/dev/null | tr -dc '0-9' | head -c 8
}
reset_escalation() { : >"$ESCALATION_LOG"; }

# shellcheck source=/dev/null
source "$CONTROL_LIB"

for fn in bridge_daemon_self_check _bridge_daemon_proc_start_time \
          _bridge_daemon_singleton_owner_path _bridge_daemon_singleton_owner_field \
          _bridge_daemon_singleton_cmdline; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf '[FAIL] %s not defined after sourcing %s\n' "$fn" "$CONTROL_LIB" >&2
    exit 1
  fi
done

# A stand-in "daemon" whose `ps -o args=` contains `bridge-daemon.sh run`
# (the exact substring the self-check cmdline gate matches). Launched from a
# smoke-local path so it never resembles the real daemon.
DAEMON_SHAPED="$SMOKE_DIR/bridge-daemon.sh"
cat >"$DAEMON_SHAPED" <<'STANDIN'
#!/usr/bin/env bash
# Stand-in matched by `*bridge-daemon.sh run*`. Sleeps so kill -0 is true.
sleep 600
STANDIN
chmod +x "$DAEMON_SHAPED"

STANDIN_LAST_PID=""
start_standin_daemon() {
  "$DAEMON_SHAPED" run &
  STANDIN_LAST_PID=$!
  STANDIN_PIDS+=("$STANDIN_LAST_PID")
}

# Write a single `daemon_started` audit JSONL row naming pid=$1 as the most
# recent daemon. printf-built — no heredoc-stdin / python emitter.
write_daemon_started_row() {
  local pid="$1"
  printf '{"category":"daemon","action":"daemon_started","actor":"daemon","detail":{"pid":"%s","wrapper":"direct"}}\n' \
    "$pid" >"$BRIDGE_AUDIT_LOG"
}

# Write an owner record (pid/cmdline/start_time/generation) next to the
# pid-file — the same shape ensure_singleton publishes.
write_owner_record() {
  local pid="$1" start="$2" gen="$3"
  {
    printf 'pid=%s\n' "$pid"
    printf 'cmdline=%s\n' "$DAEMON_SHAPED run"
    printf 'start_time=%s\n' "$start"
    printf 'generation=%s\n' "$gen"
  } >"$BRIDGE_DAEMON_PID_FILE.owner"
}

reset_state() {
  rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.owner" "$BRIDGE_AUDIT_LOG" 2>/dev/null || true
  reset_audit
  reset_escalation
}

last_args_has() {
  grep -q -- "$1" "$AUDIT_LAST_ARGS" 2>/dev/null
}

# ===========================================================================
# A1 — no-FP / unproven: alive daemon-cmdline pid, NO owner record. The
#      audited pid is genuinely live + daemon-shaped, but nothing proves it
#      is a DISTINCT generation → audit-only, NO admin task.
# ===========================================================================
reset_state
start_standin_daemon; A1_PID="$STANDIN_LAST_PID"
sleep 0.3
write_daemon_started_row "$A1_PID"
# Deliberately no owner record.
bridge_daemon_self_check
A1_RC=$?
A1_MISMATCH="$(audit_count daemon_pid_mismatch)"
A1_ESCALATIONS="$(escalation_count)"
if (( A1_RC == 1 )) && (( ${A1_MISMATCH:-0} >= 1 )) \
   && (( ${A1_ESCALATIONS:-0} == 0 )) && last_args_has 'escalation=suppressed_unproven'; then
  _pass "A1: unproven mismatch (no owner record) → daemon_pid_mismatch escalation=suppressed_unproven, NO admin task"
else
  _fail "A1: no-FP on unproven mismatch" "rc=$A1_RC mismatch=${A1_MISMATCH:-0} escalations=${A1_ESCALATIONS:-0} last_args=$(cat "$AUDIT_LAST_ARGS" 2>/dev/null)"
fi
kill "$A1_PID" 2>/dev/null || true

# ===========================================================================
# A2 — no-FP / owner record names a DIFFERENT pid. Owner record present but
#      owner_rec_pid != latest_pid → inconclusive → audit-only, NO task.
# ===========================================================================
reset_state
start_standin_daemon; A2_PID="$STANDIN_LAST_PID"
sleep 0.3
A2_LIVE_START="$(_bridge_daemon_proc_start_time "$A2_PID" 2>/dev/null || true)"
write_daemon_started_row "$A2_PID"
# Owner record names some OTHER pid (matching start irrelevant — pid differs).
write_owner_record "$((A2_PID + 1))" "${A2_LIVE_START:-somestart}" "111"
bridge_daemon_self_check
A2_RC=$?
A2_ESCALATIONS="$(escalation_count)"
if (( A2_RC == 1 )) && (( ${A2_ESCALATIONS:-0} == 0 )) \
   && last_args_has 'escalation=suppressed_unproven'; then
  _pass "A2: owner record names a different pid (owner_rec_pid != latest_pid) → suppressed_unproven, NO admin task"
else
  _fail "A2: no-FP on pid-mismatched owner record" "rc=$A2_RC escalations=${A2_ESCALATIONS:-0} last_args=$(cat "$AUDIT_LAST_ARGS" 2>/dev/null)"
fi
kill "$A2_PID" 2>/dev/null || true

# ===========================================================================
# A3 — real-dup STILL alerts. Alive daemon-cmdline pid WITH a matching owner
#      record (owner_rec_pid == latest_pid AND owner-record start_time ==
#      live lstart) and pid != self → POSITIVE proof → escalate.
# ===========================================================================
reset_state
start_standin_daemon; A3_PID="$STANDIN_LAST_PID"
sleep 0.3
A3_LIVE_START="$(_bridge_daemon_proc_start_time "$A3_PID" 2>/dev/null || true)"
if [[ -z "$A3_LIVE_START" ]]; then
  _skip "A3: real-dup still alerts" "could not read live start_time via ps -o lstart= (ps unavailable?) — A1/A2/A4 still gate the no-FP behavior"
else
  write_daemon_started_row "$A3_PID"
  write_owner_record "$A3_PID" "$A3_LIVE_START" "999"
  bridge_daemon_self_check
  A3_RC=$?
  A3_ESCALATIONS="$(escalation_count)"
  if (( A3_RC == 1 )) && (( ${A3_ESCALATIONS:-0} >= 1 )) \
     && last_args_has 'escalation=proven_duplicate'; then
    _pass "A3: PROVEN distinct live duplicate (owner record matches pid + start) → escalation=proven_duplicate, admin task PUSHED"
  else
    _fail "A3: real-dup still alerts" "rc=$A3_RC escalations=${A3_ESCALATIONS:-0} live_start='$A3_LIVE_START' last_args=$(cat "$AUDIT_LAST_ARGS" 2>/dev/null)"
  fi
fi
kill "$A3_PID" 2>/dev/null || true

# ===========================================================================
# A4 — recycled-pid preserved. Alive daemon-cmdline pid whose owner-record
#      start_time PROVABLY mismatches the live lstart → recycled_pid=true →
#      return 1, NO admin task. (Existing #1563 behavior, unchanged.)
# ===========================================================================
reset_state
start_standin_daemon; A4_PID="$STANDIN_LAST_PID"
sleep 0.3
write_daemon_started_row "$A4_PID"
# Owner record names this pid but with a BOGUS start_time (provable recycle).
write_owner_record "$A4_PID" "Thu Jan  1 00:00:00 1970" "1"
bridge_daemon_self_check
A4_RC=$?
A4_ESCALATIONS="$(escalation_count)"
if (( A4_RC == 1 )) && (( ${A4_ESCALATIONS:-0} == 0 )) \
   && last_args_has 'recycled_pid=true' && last_args_has 'escalation=suppressed_recycled_pid'; then
  _pass "A4: recycled pid (owner start_time mismatch) preserved → recycled_pid=true, NO admin task"
else
  _fail "A4: recycled-pid preserved" "rc=$A4_RC escalations=${A4_ESCALATIONS:-0} last_args=$(cat "$AUDIT_LAST_ARGS" 2>/dev/null)"
fi
kill "$A4_PID" 2>/dev/null || true

# ===========================================================================
# B1 — BUG B static invariant. Exactly ONE `bridge_audit_log daemon
#      daemon_started` emit in the tree, inside ensure_singleton; and
#      ensure_singleton is called from exactly ONE site (cmd_run). No
#      spawn/wrapper path emits the row at its own pid.
# ===========================================================================
# Count emit sites (non-comment) across the whole tree. grep -rn emits
# `path:lineno:content`; we write that to a temp file and iterate with a
# plain file redirect (no process substitution / heredoc-stdin — footgun
# #11). The smoke dir + the lint baseline files are excluded so only real
# source emits count.
B1_EMITS_FILE="$SMOKE_DIR/b1-emits.txt"
grep -rnE 'bridge_audit_log[[:space:]]+daemon[[:space:]]+daemon_started' "$REPO_ROOT" --include='*.sh' 2>/dev/null \
  | grep -v '/scripts/smoke/' >"$B1_EMITS_FILE" || true
B1_EMIT_HITS=0
B1_EMIT_LOC=""
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  # hit is "path:lineno:content"; strip path:lineno to test for comment.
  hit_path="${hit%%:*}"
  hit_rest="${hit#*:}"
  hit_lineno="${hit_rest%%:*}"
  hit_content="${hit_rest#*:}"
  trimmed="${hit_content#"${hit_content%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]] && continue
  B1_EMIT_HITS=$((B1_EMIT_HITS + 1))
  B1_EMIT_LOC="$hit_path:$hit_lineno"
done <"$B1_EMITS_FILE"

# The single emit must live in bridge-daemon-control.sh and be inside the
# ensure_singleton function (between its `() {` and the next top-level `}`).
B1_IN_ENSURE="no"
if [[ "$B1_EMIT_LOC" == *"lib/bridge-daemon-control.sh:"* ]]; then
  emit_line="${B1_EMIT_LOC##*:}"
  ensure_start="$(grep -nE '^bridge_daemon_ensure_singleton\(\)' "$CONTROL_LIB" 2>/dev/null | head -n1 | cut -d: -f1)"
  selfcheck_start="$(grep -nE '^bridge_daemon_self_check\(\)' "$CONTROL_LIB" 2>/dev/null | head -n1 | cut -d: -f1)"
  if [[ "$emit_line" =~ ^[0-9]+$ && "$ensure_start" =~ ^[0-9]+$ && "$selfcheck_start" =~ ^[0-9]+$ ]] \
     && (( emit_line > ensure_start )) && (( emit_line < selfcheck_start )); then
    B1_IN_ENSURE="yes"
  fi
fi

# ensure_singleton must be CALLED from exactly one site. We grep the whole
# tree, then exclude: smoke files, comment lines, the function DEFINITION,
# and `command -v` capability guards. What remains is the real invocation(s).
# The single legitimate call site is cmd_run (bridge-daemon.sh).
B1_CALLS_FILE="$SMOKE_DIR/b1-calls.txt"
grep -rnE 'bridge_daemon_ensure_singleton' "$REPO_ROOT" --include='*.sh' 2>/dev/null \
  | grep -v '/scripts/smoke/' \
  | grep -v 'command -v' \
  | grep -vE 'bridge_daemon_ensure_singleton\(\)' >"$B1_CALLS_FILE" || true
B1_CALL_SITES=0
B1_CALL_LOC=""
while IFS= read -r call; do
  [[ -n "$call" ]] || continue
  call_content="${call#*:}"; call_content="${call_content#*:}"
  trimmed="${call_content#"${call_content%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]] && continue
  B1_CALL_SITES=$((B1_CALL_SITES + 1))
  B1_CALL_LOC="${call%%:*}:$( { call_rest="${call#*:}"; printf '%s' "${call_rest%%:*}"; } )"
done <"$B1_CALLS_FILE"

if (( B1_EMIT_HITS == 1 )) && [[ "$B1_IN_ENSURE" == "yes" ]] && (( ${B1_CALL_SITES:-0} == 1 )); then
  _pass "B1: exactly ONE daemon_started emit ($B1_EMIT_LOC) inside ensure_singleton, with exactly ONE ensure_singleton call site ($B1_CALL_LOC = cmd_run) — no wrapper-emit"
else
  _fail "B1: BUG B emit-at-final-pid invariant" "emit_hits=$B1_EMIT_HITS emit_loc=$B1_EMIT_LOC in_ensure=$B1_IN_ENSURE call_sites=${B1_CALL_SITES:-0} call_loc=$B1_CALL_LOC"
fi

# ---------------------------------------------------------------------------
printf '\n[summary] %d checks, %d failures, %d skipped\n' "$TOTAL" "$FAILS" "$SKIPS"
(( FAILS == 0 )) || exit 1
exit 0
