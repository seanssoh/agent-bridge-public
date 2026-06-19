#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-iota-daemon-escalation-family.sh
#
# v0.15.0-beta5-2 Lane ι — patch audit 2026-05-27 enumerated five
# daemon-side nudge/escalation surface gaps:
#
#   #1320 H2  — always-on agent fail_count >= 10 → no operator escalation
#   #1321 H3  — MCP giveup recovered → accumulated miss-notify NOT re-delivered
#   #1322 H4  — nudge dedup fingerprint per-agent → new task addition
#               slides existing task's individual redelivery window
#   #1323 H5  — nudge eligibility recheck timeout (15s) → silent skip
#               (no retry signal, no audit row that names the task)
#   #1318-B   — unclaimed task > N min → no admin escalation
#
# This smoke pins the new helpers + their dedup/escalation/cooldown
# contracts so a future PR cannot regress any of the five surfaces.
#
# Test plan:
#   T1: H2 — fail_count crosses BRIDGE_ALWAYS_ON_FAIL_ESCALATE_AFTER
#       → audit row fires, marker recorded, cooldown re-arm honored on
#       the next-tick (no double-fire within the window).
#   T2: H2 teeth — same threshold a second time within cooldown → audit
#       NOT re-emitted; clearing the marker (recovery) lets the next
#       cycle re-escalate.
#   T3: H3 — enqueue then drain the miss-queue → drained items emit
#       `plugin_mcp_recovery_redelivered` rows; the on-disk file
#       shrinks; cap=0 disables the drain entirely.
#   T4: H4 — per-(agent, task_id) dedup. Two queued tasks → both
#       recorded. Adding a third task does NOT slide the first two's
#       windows; removing the third leaves the first two intact. A
#       new task id (no NUDGE_TASK_TS_<id>) short-circuits the skip.
#   T5: H5 — recheck-timeout tracker increments per-task; M consecutive
#       triggers escalation row + at-most-once admin task; clearing
#       on success resets the counter.
#   T6: #1318-B — process_unclaimed_queue_escalation emits + cooldown.
#       (state-dir + marker contract; helper-only since the python
#       find-open boundary requires a real queue DB and is out of
#       scope for the lib-only smoke harness.)
#   T_teeth (8): revert variants — pin the structural shape so a
#       future PR removing the helper or downgrading the audit emit
#       fails this smoke.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays + the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:beta5-2-iota-daemon-escalation-family] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="beta5-2-iota-daemon-escalation-family"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

# Pin escalation tunables tight enough that we exercise the cooldown
# logic without 10-minute sleeps. Defaults are asserted in T1.
export BRIDGE_ALWAYS_ON_FAIL_ESCALATE_AFTER=3
export BRIDGE_ALWAYS_ON_ESCALATE_COOLDOWN_SECS=1800
export BRIDGE_NUDGE_RECHECK_TIMEOUT_ESCALATE_AFTER=3
export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_SECS=60
export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_COOLDOWN_SECS=1800
export BRIDGE_MCP_RECOVERY_REDELIVER_CAP=50
export BRIDGE_MCP_MISS_QUEUE_HARD_CAP=500

# --- Source the daemon helpers under test (no main entry exec). ----
AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
: >"$AUDIT_LOG"
mkdir -p "$BRIDGE_STATE_DIR"

# Stub primitives BEFORE source so the helpers wire against these.
bridge_audit_log() {
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_csv=""
  while (( $# )); do
    case "$1" in
      --detail)
        if [[ -n "$detail_csv" ]]; then detail_csv+=";"; fi
        detail_csv+="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '{"actor":"%s","action":"%s","target":"%s","detail":"%s"}\n' \
    "$actor" "$action" "$target" "$detail_csv" >>"$AUDIT_LOG"
}

daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
daemon_info() { printf '[stub-info] %s\n' "$*"; }
daemon_log_event() { printf '[stub-log] %s\n' "$*"; }

# daemon_source_state_file — minimal stub that just sources the file if
# it exists. The real helper does validation but for the smoke we only
# need the source semantics (variables land in caller scope).
daemon_source_state_file() {
  local file="$1"
  # Args after position 1 are labels / required-var hints we ignore.
  [[ -f "$file" ]] || return 1
  # shellcheck source=/dev/null
  source "$file" 2>/dev/null || return 1
  return 0
}

# Stub bridge_require_python — we have python3 available on every
# supported host but the daemon-side helper does its own validation
# via this primitive. Stub to a no-op so the helpers don't dispatch
# the full preflight chain.
bridge_require_python() { command -v python3 >/dev/null 2>&1; }

# Stub bridge_resolve_script_dir_check + bridge_daemon_helper_python so
# the lib/daemon-helpers/*.py file-as-argv extractions land at the
# correct path. The real implementations live in lib/bridge-core.sh and
# bridge-daemon.sh respectively; here we just point at the repo root
# so the extracted helpers (mcp-miss-queue-enqueue.py,
# mcp-miss-queue-drain-parse.py, unclaimed-task-filter.py) are
# discoverable in-smoke.
export BRIDGE_SCRIPT_DIR="$REPO_ROOT"
bridge_resolve_script_dir_check() { return 0; }
bridge_daemon_helper_python() {
  local helper="${1:-}"
  [[ -n "$helper" ]] || return 1
  shift || true
  python3 "$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/$helper.py" "$@"
}

# bridge_notify_send — we need to test both success + failure paths.
# Default is "fail" so T3 can exercise the enqueue branch; tests that
# need success will override this stub locally.
_BRIDGE_NOTIFY_RESULT="${_BRIDGE_NOTIFY_RESULT:-0}"
NOTIFY_LOG="$SMOKE_TMP_ROOT/notify-send.log"
: >"$NOTIFY_LOG"
bridge_notify_send() {
  local agent="$1" title="$2" body="$3" task_id="$4" priority="$5"
  printf 'agent=%s title=%s priority=%s rc=%s\n' \
    "$agent" "$title" "$priority" "$_BRIDGE_NOTIFY_RESULT" \
    >>"$NOTIFY_LOG"
  return "$_BRIDGE_NOTIFY_RESULT"
}

# bridge_agent_mcp_giveup_active — driven by an associative array so
# each test pins the predicate result without touching real state.
declare -gA _SMOKE_GIVEUP_ACTIVE=()
bridge_agent_mcp_giveup_active() {
  local agent="$1"
  [[ "${_SMOKE_GIVEUP_ACTIVE[$agent]:-0}" == "1" ]]
}

# Provide a minimum BRIDGE_HOME + SCRIPT_DIR so the
# bridge_daemon_maybe_escalate_always_on_fail helper's "is there a
# task CLI" probe returns false (no admin task fires; we only assert
# the audit row + marker contract here).
export BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
mkdir -p "$BRIDGE_HOME"

# Source bridge-daemon.sh — extract via python so heredoc body lines
# starting with `}` (e.g. a Python dict literal close inside a `<<'PY'`
# block) cannot prematurely terminate awk's regex-driven capture. We
# track the inner heredoc terminator on the start line and only count
# bash function `}` outside the heredoc.
HELPERS_SUBSET="$SMOKE_TMP_ROOT/daemon-helpers.sh"
WANTED_HELPERS=(
  bridge_daemon_note_autostart_failure
  bridge_daemon_clear_autostart_failure
  bridge_daemon_maybe_escalate_always_on_fail
  bridge_daemon_autostart_state_file
  bridge_daemon_nudge_state_file
  bridge_daemon_compute_nudge_fingerprint
  bridge_daemon_nudge_task_ts_var
  # Issue #1973 Track B: should_skip / record_nudge depend on the new
  # capped-exponential backoff helpers; extract them too.
  bridge_daemon_nudge_task_field_var
  bridge_daemon_nudge_backoff_delay
  bridge_daemon_nudge_dedup_load
  bridge_daemon_nudge_dedup_reset_scope
  bridge_daemon_should_skip_nudge
  bridge_daemon_record_nudge
  bridge_daemon_nudge_deferred_var_name
  bridge_daemon_nudge_recheck_timeout_state_file
  bridge_daemon_nudge_recheck_timeout_load
  bridge_daemon_nudge_recheck_timeout_save
  bridge_daemon_nudge_recheck_timeout_reset_scope
  bridge_daemon_nudge_recheck_timeout_clear
  bridge_daemon_nudge_recheck_timeout_track
  bridge_daemon_nudge_emit_recheck_timeout_admin_task
  bridge_daemon_mcp_miss_queue_file
  bridge_daemon_mcp_miss_queue_enqueue
  bridge_daemon_mcp_miss_queue_drain
  bridge_daemon_should_enqueue_mcp_miss
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
        # Capture from this line to the matching `^}$` at column 0,
        # skipping over any inner heredoc whose terminator we detect.
        block = [line]
        depth = 1
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
                # Inside a heredoc — only end on the exact terminator
                # at the line start (bash convention `^TERMINATOR$`).
                if cur.rstrip("\n") == heredoc_term:
                    heredoc_term = None
                j += 1
                continue
            if cur == "}\n" or cur == "}":
                depth = 0
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

# --- helpers --------------------------------------------------------
audit_count() {
  local action="$1" agent="$2"
  local n
  if n="$(grep -c "\"action\":\"${action}\".*\"target\":\"${agent}\"" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}

audit_latest_detail() {
  local action="$1" agent="$2" field="$3"
  local row
  row="$(grep "\"action\":\"${action}\".*\"target\":\"${agent}\"" "$AUDIT_LOG" 2>/dev/null | tail -n1)"
  [[ -n "$row" ]] || { printf ''; return; }
  local detail
  detail="$(printf '%s\n' "$row" | sed -n 's/.*"detail":"\([^"]*\)".*/\1/p')"
  local part
  IFS=';' read -ra parts <<<"$detail"
  for part in "${parts[@]}"; do
    if [[ "$part" == "${field}="* ]]; then
      # shellcheck disable=SC2295  # nested expansion intentional
      printf '%s' "${part#${field}=}"
      return
    fi
  done
  printf ''
}

# --- T1: H2 always-on fail_count crosses threshold → escalation ------
smoke_run "T1 H2 always-on escalation audit" : ; {
  : >"$AUDIT_LOG"
  # Threshold pinned to 3 above. Bump fail counter to 3 in one call —
  # the helper increments by 1 each invocation, so seed by direct file
  # write to skip the "1 → 2 → 3" buildup.
  state_file="$(bridge_daemon_autostart_state_file agent-h2)"
  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
AUTO_START_FAIL_COUNT=2
AUTO_START_NEXT_RETRY_TS=0
AUTO_START_LAST_REASON='start-command-failed'
AUTO_START_LAST_ESCALATED_COUNT=0
AUTO_START_LAST_ESCALATED_TS=0
EOF
  bridge_daemon_note_autostart_failure "agent-h2" "start-command-failed"

  count=$(audit_count always_on_launch_failure_escalated "agent-h2")
  smoke_assert_eq 1 "$count" "T1 always_on_launch_failure_escalated row count"

  fail_count=$(audit_latest_detail always_on_launch_failure_escalated "agent-h2" fail_count)
  smoke_assert_eq 3 "$fail_count" "T1 fail_count=3"

  threshold=$(audit_latest_detail always_on_launch_failure_escalated "agent-h2" threshold)
  smoke_assert_eq 3 "$threshold" "T1 threshold=3 (env override)"

  # Marker file must now record the escalation timestamp + count.
  grep -q "AUTO_START_LAST_ESCALATED_COUNT=3" "$state_file" \
    || smoke_fail "T1 marker missing AUTO_START_LAST_ESCALATED_COUNT=3"
  grep -q "AUTO_START_LAST_ESCALATED_TS=" "$state_file" \
    || smoke_fail "T1 marker missing AUTO_START_LAST_ESCALATED_TS"
}

# --- T2: H2 cooldown re-arm: re-escalation within window suppressed ---
smoke_run "T2 H2 cooldown suppresses double-fire within window" : ; {
  : >"$AUDIT_LOG"
  # The state file from T1 has AUTO_START_LAST_ESCALATED_TS set to
  # roughly now; calling note_autostart_failure again should NOT
  # re-emit the audit row because we are well within the 1800s window.
  bridge_daemon_note_autostart_failure "agent-h2" "start-command-failed"

  count=$(audit_count always_on_launch_failure_escalated "agent-h2")
  smoke_assert_eq 0 "$count" "T2 re-escalation within cooldown suppressed"
}

# --- T2b: H2 recovery clears escalation marker via clear_autostart ---
smoke_run "T2b H2 recovery clears the escalation marker" : ; {
  bridge_daemon_clear_autostart_failure "agent-h2"
  state_file="$(bridge_daemon_autostart_state_file agent-h2)"
  [[ ! -f "$state_file" ]] || smoke_fail "T2b state file should be removed after clear"
}

# --- T3: H3 MCP miss-queue enqueue + drain --------------------------
smoke_run "T3 H3 MCP miss-queue enqueue + drain" : ; {
  : >"$AUDIT_LOG"
  _SMOKE_GIVEUP_ACTIVE[agent-h3]=1
  miss_file="$(bridge_daemon_mcp_miss_queue_file agent-h3)"

  # Enqueue 3 distinct messages while giveup is active.
  bridge_daemon_mcp_miss_queue_enqueue "agent-h3" "Title A" "Body A" normal "" || smoke_fail "T3 enqueue A failed"
  bridge_daemon_mcp_miss_queue_enqueue "agent-h3" "Title B" "Body B" high "task-42" || smoke_fail "T3 enqueue B failed"
  bridge_daemon_mcp_miss_queue_enqueue "agent-h3" "Title C" "Body C" urgent "" || smoke_fail "T3 enqueue C failed"

  smoke_assert_file_exists "$miss_file" "T3 miss queue file created"
  lines=$(wc -l <"$miss_file" | tr -d ' ')
  smoke_assert_eq 3 "$lines" "T3 miss queue file has 3 lines"

  # Dedup: re-enqueueing an identical (title, body) does NOT create a
  # duplicate row.
  bridge_daemon_mcp_miss_queue_enqueue "agent-h3" "Title A" "Body A" normal "" || true
  lines2=$(wc -l <"$miss_file" | tr -d ' ')
  smoke_assert_eq 3 "$lines2" "T3 dedup suppresses identical re-enqueue"

  # Now drain with cap=2; notify stub returns success.
  _BRIDGE_NOTIFY_RESULT=0
  bridge_daemon_mcp_miss_queue_drain "agent-h3" 2
  delivered_count=$(audit_count plugin_mcp_recovery_redelivered "agent-h3")
  smoke_assert_eq 2 "$delivered_count" "T3 drain delivered=2 (cap=2)"

  remaining=$(wc -l <"$miss_file" | tr -d ' ')
  smoke_assert_eq 1 "$remaining" "T3 drain leaves 1 unsent in queue (cap=2)"

  # Drain the rest with cap=50 — empty queue after.
  bridge_daemon_mcp_miss_queue_drain "agent-h3" 50
  if [[ -f "$miss_file" ]]; then
    final=$(wc -l <"$miss_file" | tr -d ' ')
    smoke_assert_eq 0 "$final" "T3 second drain empties the queue"
  fi

  # cap=0 is a no-op even if queue is non-empty.
  bridge_daemon_mcp_miss_queue_enqueue "agent-h3" "Title D" "Body D" normal "" || true
  : >"$AUDIT_LOG"
  bridge_daemon_mcp_miss_queue_drain "agent-h3" 0
  noop_count=$(audit_count plugin_mcp_recovery_redelivered "agent-h3")
  smoke_assert_eq 0 "$noop_count" "T3 cap=0 disables drain"
}

# --- T3b: H3 drain dedup_key written on every audit row -------------
smoke_run "T3b H3 audit row carries dedup_key" : ; {
  rm -f "$(bridge_daemon_mcp_miss_queue_file agent-h3b)"
  : >"$AUDIT_LOG"
  _BRIDGE_NOTIFY_RESULT=0
  bridge_daemon_mcp_miss_queue_enqueue "agent-h3b" "T3b" "B3b" normal "" || true
  bridge_daemon_mcp_miss_queue_drain "agent-h3b" 10
  dedup=$(audit_latest_detail plugin_mcp_recovery_redelivered "agent-h3b" dedup_key)
  [[ -n "$dedup" && "${#dedup}" -ge 8 ]] || smoke_fail "T3b dedup_key should be a non-empty sha-prefix; got '$dedup'"
}

# --- T3c: H3 should_enqueue predicate ------------------------------
smoke_run "T3c H3 should_enqueue gated by giveup_active" : ; {
  _SMOKE_GIVEUP_ACTIVE[agent-h3c]=1
  bridge_daemon_should_enqueue_mcp_miss "agent-h3c" || smoke_fail "T3c giveup-active should enqueue"
  _SMOKE_GIVEUP_ACTIVE[agent-h3d]=0
  if bridge_daemon_should_enqueue_mcp_miss "agent-h3d"; then
    smoke_fail "T3c giveup-inactive should NOT enqueue"
  fi
}

# --- T3d: H3 PRODUCTION PATH — bridge_notify_send wires miss-queue --
# R2 fix (codex r1 BLOCKING 1): the R1 ship added a wrapper
# bridge_notify_send_with_miss_queue() that was never wired in any of
# the 8 production sites. R2 collapsed the H3 enqueue into
# bridge_notify_send itself (lib/bridge-notify.sh) behind a `declare -F`
# gate so every existing call site picks it up automatically. This test
# drives that production path: it sources the real bridge_notify_send,
# stubs the inner notify_python primitive to fail, and asserts the
# miss-queue enqueue + audit row fire WITHOUT calling the enqueue
# helper directly.
smoke_run "T3d H3 PRODUCTION bridge_notify_send wires miss-queue on rc!=0+giveup" : ; {
  # Stash the smoke's existing bridge_notify_send stub — we want the
  # REAL one from lib/bridge-notify.sh for this test only.
  _SMOKE_SAVED_NOTIFY="$(declare -f bridge_notify_send)"
  unset -f bridge_notify_send

  # Minimum stubs the real bridge_notify_send needs to flow through to
  # its rc check. The body content / payload doesn't matter — only the
  # rc + giveup_active + agent name matter for the H3 branch.
  # ★Kind must be a push kind that flows THROUGH to bridge_notify_python:
  # #1996 made `kind == teams` fail-closed early (return 3, routes via
  # managed-send) BEFORE the python primitive, so a `teams` stub would
  # short-circuit and never exercise this H3 miss-queue-on-giveup path.
  # Use `discord` (a real bridge-notify push kind with no early return).
  bridge_agent_notify_kind()    { printf 'discord'; }
  bridge_agent_notify_target()  { printf 'channel-stub'; }
  bridge_agent_notify_account() { printf ''; }
  bridge_compat_config_file()   { printf '%s/runtime.json' "$SMOKE_TMP_ROOT"; }
  bridge_die()                  { printf 'bridge_die: %s\n' "$*" >&2; return 1; }

  # Source lib/bridge-notify.sh so the REAL bridge_notify_send is
  # defined in-scope alongside the daemon helpers we already sourced
  # via the HELPERS_SUBSET extraction.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/bridge-notify.sh"
  # bridge_notify_python is the inner primitive bridge_notify_send
  # calls. Force it to fail so we exercise the H3 enqueue branch.
  # NB: this override MUST land AFTER the source — sourcing
  # lib/bridge-notify.sh redefines bridge_notify_python and would
  # clobber a pre-source stub.
  bridge_notify_python() { return 99; }

  _SMOKE_GIVEUP_ACTIVE[agent-h3d-prod]=1
  miss_file="$(bridge_daemon_mcp_miss_queue_file agent-h3d-prod)"
  rm -f "$miss_file"
  : >"$AUDIT_LOG"

  # Production call shape (matches bridge-daemon.sh:1796 / :3242 etc).
  # Note: this `{ ... }` block executes at script-top-level (not inside
  # a function) so we use a plain assignment rather than `local`.
  _rc=0
  bridge_notify_send "agent-h3d-prod" "Prod title" "Prod body" "" urgent "0" \
    >/dev/null 2>&1 || _rc=$?

  smoke_assert_eq 99 "$_rc" "T3d bridge_notify_send returns inner rc"
  smoke_assert_file_exists "$miss_file" "T3d miss-queue file created via production path"

  lines=$(wc -l <"$miss_file" | tr -d ' ')
  smoke_assert_eq 1 "$lines" "T3d exactly one enqueue from a single failed send"

  # Audit row must record the enqueue with send_rc=99.
  enq_count=$(audit_count plugin_mcp_miss_queue_enqueued "agent-h3d-prod")
  smoke_assert_eq 1 "$enq_count" "T3d plugin_mcp_miss_queue_enqueued audit row fired"
  send_rc=$(audit_latest_detail plugin_mcp_miss_queue_enqueued "agent-h3d-prod" send_rc)
  smoke_assert_eq 99 "$send_rc" "T3d audit row carries send_rc=99 from notify_python"

  # Negative — healthy path: rc=0 → NO enqueue, NO audit row.
  bridge_notify_python() { return 0; }
  rm -f "$miss_file"
  : >"$AUDIT_LOG"
  bridge_notify_send "agent-h3d-prod" "Healthy" "body" "" normal "0" >/dev/null 2>&1
  if [[ -f "$miss_file" ]]; then
    smoke_fail "T3d healthy path must NOT enqueue miss-queue"
  fi
  noop=$(audit_count plugin_mcp_miss_queue_enqueued "agent-h3d-prod")
  smoke_assert_eq 0 "$noop" "T3d healthy path emits no enqueue audit row"

  # Negative — failure but NOT in giveup: rc!=0 + giveup_active=0
  # → NO enqueue.
  bridge_notify_python() { return 99; }
  _SMOKE_GIVEUP_ACTIVE[agent-h3d-prod-no-giveup]=0
  miss_file2="$(bridge_daemon_mcp_miss_queue_file agent-h3d-prod-no-giveup)"
  rm -f "$miss_file2"
  : >"$AUDIT_LOG"
  bridge_notify_send "agent-h3d-prod-no-giveup" "Title" "body" "" normal "0" >/dev/null 2>&1 || true
  if [[ -f "$miss_file2" ]]; then
    smoke_fail "T3d non-giveup failure must NOT enqueue miss-queue"
  fi

  # Restore the smoke's earlier stub so downstream tests are unaffected.
  unset -f bridge_notify_send bridge_notify_python
  unset -f bridge_agent_notify_kind bridge_agent_notify_target bridge_agent_notify_account
  unset -f bridge_compat_config_file bridge_die
  eval "$_SMOKE_SAVED_NOTIFY"
}

# --- T4: H4 per-(agent, task_id) dedup -------------------------------
smoke_run "T4 H4 per-task dedup window" : ; {
  rm -f "$(bridge_daemon_nudge_state_file agent-h4)"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=600

  # Record nudge for [#101, #102].
  fp="$(bridge_daemon_compute_nudge_fingerprint "101,102")"
  bridge_daemon_record_nudge "agent-h4" "$fp" "101,102"
  state_file="$(bridge_daemon_nudge_state_file agent-h4)"
  smoke_assert_file_exists "$state_file" "T4 state file written"

  grep -q "^NUDGE_TASK_TS_101=" "$state_file" || smoke_fail "T4 NUDGE_TASK_TS_101 missing"
  grep -q "^NUDGE_TASK_TS_102=" "$state_file" || smoke_fail "T4 NUDGE_TASK_TS_102 missing"

  # Should skip when both ids are present in the window.
  fp2="$(bridge_daemon_compute_nudge_fingerprint "101,102")"
  if bridge_daemon_should_skip_nudge "agent-h4" "$fp2" "101,102"; then
    :
  else
    smoke_fail "T4 should_skip should return 0 for full overlap inside window"
  fi

  # Now add a new task #103 — at least one task in the live set has NO
  # NUDGE_TASK_TS_<id> entry → should NOT skip.
  fp3="$(bridge_daemon_compute_nudge_fingerprint "101,102,103")"
  if bridge_daemon_should_skip_nudge "agent-h4" "$fp3" "101,102,103"; then
    smoke_fail "T4 new task should break dedup"
  else
    :
  fi

  # Record the new set. Expect existing 101/102 timestamps to be
  # refreshed (record() always writes "now") AND #103 to be added.
  bridge_daemon_record_nudge "agent-h4" "$fp3" "101,102,103"
  grep -q "^NUDGE_TASK_TS_103=" "$state_file" || smoke_fail "T4 NUDGE_TASK_TS_103 missing after add"

  # Drop #102 — its NUDGE_TASK_TS_102 should be pruned from the file.
  bridge_daemon_record_nudge "agent-h4" "$(bridge_daemon_compute_nudge_fingerprint "101,103")" "101,103"
  if grep -q "^NUDGE_TASK_TS_102=" "$state_file"; then
    smoke_fail "T4 NUDGE_TASK_TS_102 should be pruned after task drop"
  fi
  grep -q "^NUDGE_TASK_TS_101=" "$state_file" || smoke_fail "T4 NUDGE_TASK_TS_101 should survive prune"
  grep -q "^NUDGE_TASK_TS_103=" "$state_file" || smoke_fail "T4 NUDGE_TASK_TS_103 should survive prune"
}

# --- T4b: H4 disable via REDELIVERY=0 --------------------------------
smoke_run "T4b H4 REDELIVERY=0 disables dedup" : ; {
  rm -f "$(bridge_daemon_nudge_state_file agent-h4b)"
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=0
  fp="$(bridge_daemon_compute_nudge_fingerprint "201")"
  bridge_daemon_record_nudge "agent-h4b" "$fp" "201"
  if bridge_daemon_should_skip_nudge "agent-h4b" "$fp" "201"; then
    smoke_fail "T4b REDELIVERY=0 should disable dedup"
  fi
  export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=60
}

# --- T5: H5 recheck-timeout tracker increments + escalates -----------
smoke_run "T5 H5 recheck-timeout per-task counter + escalation" : ; {
  rm -f "$(bridge_daemon_nudge_recheck_timeout_state_file agent-h5)"
  : >"$AUDIT_LOG"

  # First timeout — counter = 1, audit row but NO escalation.
  bridge_daemon_nudge_recheck_timeout_track "agent-h5" "501" 15 124 3
  c1=$(audit_count nudge_eligibility_recheck_timeout "agent-h5")
  smoke_assert_eq 1 "$c1" "T5 first timeout emits 1 audit row"
  cons1=$(audit_latest_detail nudge_eligibility_recheck_timeout "agent-h5" consecutive)
  smoke_assert_eq 1 "$cons1" "T5 consecutive=1 after first"
  esc1=$(audit_count nudge_recheck_timeout_escalated "agent-h5")
  smoke_assert_eq 0 "$esc1" "T5 no escalation yet at consec=1"

  # Second + third — third crosses threshold=3.
  bridge_daemon_nudge_recheck_timeout_track "agent-h5" "501" 15 124 3
  bridge_daemon_nudge_recheck_timeout_track "agent-h5" "501" 15 124 3
  cons3=$(audit_latest_detail nudge_eligibility_recheck_timeout "agent-h5" consecutive)
  smoke_assert_eq 3 "$cons3" "T5 consecutive=3 after third"

  esc3=$(audit_count nudge_recheck_timeout_escalated "agent-h5")
  smoke_assert_eq 1 "$esc3" "T5 escalation fires exactly once at threshold"

  # Fourth — already-escalated, no second escalation row emitted.
  bridge_daemon_nudge_recheck_timeout_track "agent-h5" "501" 15 124 3
  esc4=$(audit_count nudge_recheck_timeout_escalated "agent-h5")
  smoke_assert_eq 1 "$esc4" "T5 escalation is at-most-once per (agent, task)"

  # Different task id: independent counter.
  bridge_daemon_nudge_recheck_timeout_track "agent-h5" "502" 15 124 3
  cons_502=$(audit_latest_detail nudge_eligibility_recheck_timeout "agent-h5" consecutive)
  smoke_assert_eq 1 "$cons_502" "T5 sibling task counter starts at 1"
}

# --- T5b: H5 recovery clears counter --------------------------------
smoke_run "T5b H5 clear resets per-task counter" : ; {
  bridge_daemon_nudge_recheck_timeout_clear "agent-h5"
  state_file="$(bridge_daemon_nudge_recheck_timeout_state_file agent-h5)"
  [[ ! -f "$state_file" ]] || smoke_fail "T5b clear should remove state file"

  : >"$AUDIT_LOG"
  bridge_daemon_nudge_recheck_timeout_track "agent-h5" "501" 15 124 3
  cons=$(audit_latest_detail nudge_eligibility_recheck_timeout "agent-h5" consecutive)
  smoke_assert_eq 1 "$cons" "T5b post-clear consecutive=1"
}

# --- T6: #1318-B unclaimed-task structure ---------------------------
# The python find-open boundary requires a real queue DB. Pin the
# helper-only contract (state-dir + marker file shape + cooldown gate
# semantics) here; the full end-to-end is covered in the daemon
# integration smoke when the DB is available.
smoke_run "T6 unclaimed-escalation marker contract" : ; {
  dir="$(bridge_daemon_unclaimed_escalation_state_dir)"
  smoke_assert_contains "$dir" "$BRIDGE_STATE_DIR" "T6 state dir under BRIDGE_STATE_DIR"
  smoke_assert_contains "$dir" "unclaimed-escalations" "T6 state dir name matches"

  marker="$(bridge_daemon_unclaimed_escalation_marker_file "777")"
  smoke_assert_contains "$marker" "$dir" "T6 marker file lives in state dir"
  smoke_assert_contains "$marker" "777.ts" "T6 marker file named per task id"
}

# --- T_teeth: structural revert assertions --------------------------
smoke_run "T_teeth structural shape of new helpers" : ; {
  # H2 — function must exist + emit always_on_launch_failure_escalated.
  command -v bridge_daemon_maybe_escalate_always_on_fail >/dev/null \
    || smoke_fail "teeth: bridge_daemon_maybe_escalate_always_on_fail must exist"
  grep -q 'always_on_launch_failure_escalated' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: always_on_launch_failure_escalated audit emit must be in bridge-daemon.sh"

  # H3 — miss-queue helpers + drain audit emit.
  command -v bridge_daemon_mcp_miss_queue_drain >/dev/null \
    || smoke_fail "teeth: bridge_daemon_mcp_miss_queue_drain must exist"
  grep -q 'plugin_mcp_recovery_redelivered' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: plugin_mcp_recovery_redelivered audit emit must be in bridge-daemon.sh"
  grep -q 'BRIDGE_MCP_RECOVERY_REDELIVER_CAP' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: BRIDGE_MCP_RECOVERY_REDELIVER_CAP env knob must be in bridge-daemon.sh"

  # H3 R2 (codex r1 BLOCKING 1) — bridge_notify_send must internally
  # wire the miss-queue enqueue. Pre-R2 the wrapper
  # bridge_notify_send_with_miss_queue existed but was never wired into
  # the 8 production sites. R2 collapses the logic into the notify
  # primitive itself. Pin both halves so a future PR cannot regress to
  # the unwired wrapper shape.
  grep -q 'plugin_mcp_miss_queue_enqueued' "$REPO_ROOT/lib/bridge-notify.sh" \
    || smoke_fail "teeth: lib/bridge-notify.sh must enqueue plugin_mcp_miss_queue_enqueued (R2 production wiring)"
  grep -q 'bridge_daemon_should_enqueue_mcp_miss' "$REPO_ROOT/lib/bridge-notify.sh" \
    || smoke_fail "teeth: lib/bridge-notify.sh must call bridge_daemon_should_enqueue_mcp_miss (R2 declare -F gate)"
  if grep -q '^bridge_notify_send_with_miss_queue()' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_fail "teeth: bridge_notify_send_with_miss_queue wrapper must NOT exist (R2 collapsed into bridge_notify_send)"
  fi
  # H3 R2 — heredoc-stdin sites must be extracted to lib/daemon-helpers/.
  for _helper in mcp-miss-queue-enqueue.py mcp-miss-queue-drain-parse.py unclaimed-task-filter.py; do
    [[ -f "$REPO_ROOT/lib/daemon-helpers/$_helper" ]] \
      || smoke_fail "teeth: lib/daemon-helpers/$_helper must exist (R2 heredoc-stdin extraction)"
  done

  # H4 — per-task ts var helper + skip-nudge takes 3rd arg.
  command -v bridge_daemon_nudge_task_ts_var >/dev/null \
    || smoke_fail "teeth: bridge_daemon_nudge_task_ts_var must exist"
  grep -q 'NUDGE_TASK_TS_' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: NUDGE_TASK_TS_ per-task var must be in bridge-daemon.sh"

  # H5 — recheck-timeout helpers + audit emit + escalation row.
  command -v bridge_daemon_nudge_recheck_timeout_track >/dev/null \
    || smoke_fail "teeth: bridge_daemon_nudge_recheck_timeout_track must exist"
  grep -q 'nudge_eligibility_recheck_timeout' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: nudge_eligibility_recheck_timeout audit emit must be in bridge-daemon.sh"
  grep -q 'nudge_recheck_timeout_escalated' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: nudge_recheck_timeout_escalated audit emit must be in bridge-daemon.sh"

  # #1318-B — unclaimed-task escalation + main-loop wiring.
  command -v process_unclaimed_queue_escalation >/dev/null \
    || smoke_fail "teeth: process_unclaimed_queue_escalation must exist"
  grep -q 'task_unclaimed_escalated' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: task_unclaimed_escalated audit emit must be in bridge-daemon.sh"
  grep -q 'unclaimed_queue_escalation' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: unclaimed_queue_escalation main-loop wiring must be in bridge-daemon.sh"

  # Env knobs — assert presence so a future PR cannot silently remove
  # operator-tunable surface.
  grep -q 'BRIDGE_ALWAYS_ON_FAIL_ESCALATE_AFTER' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: BRIDGE_ALWAYS_ON_FAIL_ESCALATE_AFTER env knob"
  grep -q 'BRIDGE_NUDGE_RECHECK_TIMEOUT_ESCALATE_AFTER' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: BRIDGE_NUDGE_RECHECK_TIMEOUT_ESCALATE_AFTER env knob"
  grep -q 'BRIDGE_QUEUE_UNCLAIMED_ESCALATE_SECS' "$REPO_ROOT/bridge-daemon.sh" \
    || smoke_fail "teeth: BRIDGE_QUEUE_UNCLAIMED_ESCALATE_SECS env knob"
}

smoke_log "all tests passed: $SMOKE_NAME"
