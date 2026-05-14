#!/usr/bin/env bash
# bridge-daemon.sh — keeps dynamic bridge roster in sync with tmux sessions

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-daemon.sh [--skip-plugin-liveness] <start|ensure|run|status|sync|stop [--force]>"
}

daemon_log_event() {
  local message="$1"
  local timestamp

  timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  mkdir -p "$BRIDGE_STATE_DIR"
  printf '[%s] %s\n' "$timestamp" "$message" >>"$BRIDGE_DAEMON_CRASH_LOG"
}

daemon_info() {
  local message="$1"
  printf '[%s] [info] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message"
}

daemon_warn() {
  local message="$1"
  printf '[%s] [warn] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" >&2
}

daemon_source_state_file() {
  local file="$1"
  local label="${2:-state}"
  local clear_on_error="${3:-0}"
  # Optional 4th positional: whitespace-separated names of variables that MUST
  # be non-empty after sourcing. Empty/truncated env files (e.g. a partially
  # flushed write from an isolated UID) pass `bash -n` + `source` silently
  # and would otherwise leave callers operating on stale or zero-valued vars.
  # Callsites that genuinely tolerate "missing fields" (e.g. first-run
  # daily-backup state) omit this argument.
  local required_vars="${4:-}"
  # Optional 5th positional: whitespace-separated names of every variable
  # the file is expected to define. These are unset BEFORE sourcing so a
  # failed source (unreadable, invalid syntax, missing required var, or
  # missing field) cannot leak previously-sourced values from an earlier
  # caller (e.g. a different agent in the same per-loop-iteration scan)
  # into the post-call read. The required_vars list is implicitly part of
  # this set; callers may list it in either argument. (#576 r3 Finding 1)
  local sanitize_vars="${5:-}"
  local var

  # Sanitize required + caller-declared family BEFORE any of the early-return
  # paths below: an unreadable / syntactically invalid file must not leave
  # stale values from a prior successful source still in scope.
  for var in $required_vars $sanitize_vars; do
    unset "$var"
  done

  [[ -f "$file" ]] || return 1
  if [[ ! -r "$file" ]]; then
    daemon_warn "${label} state file is unreadable; ignoring: $file"
    if [[ "$clear_on_error" == "1" ]]; then
      rm -f "$file" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  if ! "${BASH:-bash}" -n "$file" >/dev/null 2>&1; then
    daemon_warn "${label} state file has invalid shell syntax; ignoring: $file"
    if [[ "$clear_on_error" == "1" ]]; then
      rm -f "$file" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  # shellcheck source=/dev/null
  source "$file" 2>/dev/null || {
    daemon_warn "${label} state file could not be sourced; ignoring: $file"
    if [[ "$clear_on_error" == "1" ]]; then
      rm -f "$file" >/dev/null 2>&1 || true
    fi
    return 1
  }

  if [[ -n "$required_vars" ]]; then
    for var in $required_vars; do
      if [[ -z "${!var:-}" ]]; then
        daemon_warn "${label} state file missing required var ${var}; ignoring: $file"
        if [[ "$clear_on_error" == "1" ]]; then
          rm -f "$file" >/dev/null 2>&1 || true
        fi
        return 1
      fi
    done
  fi
}

# --- Daemon exit observability (issue #193) ----------------------------------
# These traps guarantee every daemon exit path leaves a trail in both
# $BRIDGE_LAUNCHAGENT_LOG and the audit log. Without this, silent exits
# (signals, `set -e` aborts, unhandled errors) block root-cause of crash-
# restart cycles (see issues #190, #194).
#
# Issue #590 PR #599 r3: BRIDGE_LAUNCHAGENT_LOG follows the same precedence
# as BRIDGE_DAEMON_LOG — env override wins, otherwise the installer-written
# marker (resolved via __bridge_resolve_launchagent_log from bridge-lib.sh),
# otherwise the conventional default. Without this, the EXIT trap below
# writes to the wrong file on custom --log-path installs.
if [[ -z "${BRIDGE_LAUNCHAGENT_LOG:-}" ]]; then
  BRIDGE_LAUNCHAGENT_LOG="$(__bridge_resolve_launchagent_log)"
  if [[ -z "$BRIDGE_LAUNCHAGENT_LOG" ]]; then
    BRIDGE_LAUNCHAGENT_LOG="$BRIDGE_STATE_DIR/launchagent.log"
  fi
fi
BRIDGE_LAST_SIGNAL="${BRIDGE_LAST_SIGNAL:-none}"
BRIDGE_DAEMON_LAST_STEP="${BRIDGE_DAEMON_LAST_STEP:-init}"
BRIDGE_DAEMON_ERR_LOCATION="${BRIDGE_DAEMON_ERR_LOCATION:-}"
_BRIDGE_DAEMON_EXIT_LOGGED=0
_BRIDGE_DAEMON_IN_ERR_TRAP=0

_bridge_daemon_on_signal() {
  BRIDGE_LAST_SIGNAL="$1"
}

_bridge_daemon_on_err() {
  # Recursion guard: trap handlers that themselves fail must not retrigger.
  if (( _BRIDGE_DAEMON_IN_ERR_TRAP != 0 )); then
    return 0
  fi
  _BRIDGE_DAEMON_IN_ERR_TRAP=1
  # Record the first failing source:line; keep BRIDGE_DAEMON_LAST_STEP intact
  # so exit records retain the semantic step (e.g. "nudge_scan") alongside
  # the err_location.
  if [[ -z "$BRIDGE_DAEMON_ERR_LOCATION" ]]; then
    BRIDGE_DAEMON_ERR_LOCATION="${BASH_SOURCE[1]:-unknown}:${BASH_LINENO[0]:-0}"
  fi
  _BRIDGE_DAEMON_IN_ERR_TRAP=0
}

_bridge_daemon_on_exit() {
  local ec=$?
  local sig="${BRIDGE_LAST_SIGNAL:-none}"
  local step="${BRIDGE_DAEMON_LAST_STEP:-unknown}"
  local err_location="${BRIDGE_DAEMON_ERR_LOCATION:-}"
  local ts

  # Idempotence: EXIT trap can fire multiple times in edge cases.
  if (( _BRIDGE_DAEMON_EXIT_LOGGED != 0 )); then
    return 0
  fi
  _BRIDGE_DAEMON_EXIT_LOGGED=1

  bridge_stop_queue_gateway_socket_listener >/dev/null 2>&1 || true

  ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)"
  mkdir -p "$BRIDGE_STATE_DIR" 2>/dev/null || true
  printf '[%s] [info] daemon exit pid=%d ec=%d sig=%s last_step=%s err_location=%s\n' \
    "$ts" "$$" "$ec" "$sig" "$step" "${err_location:-none}" \
    2>/dev/null >>"$BRIDGE_LAUNCHAGENT_LOG" || true

  # bridge_audit_log shells out to python; wrap so an audit failure cannot
  # mask the original exit code.
  bridge_audit_log daemon daemon_exit daemon \
    --detail pid="$$" \
    --detail exit_code="$ec" \
    --detail signal="$sig" \
    --detail last_step="$step" \
    --detail err_location="${err_location:-none}" >/dev/null 2>&1 || true

  rm -f "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true
  if (( ec != 0 )); then
    # PR #198 review: daemon_log_event internally does mkdir + append write,
    # either of which can fail (dir unwritable, disk full). Under set -e an
    # unguarded failure here overwrites the original exit code we're trying
    # to report. Guard so the observability path cannot mask the signal.
    daemon_log_event "daemon exiting with status=$ec sig=$sig last_step=$step err_location=${err_location:-none}" 2>/dev/null || true
  fi
  # Ensure the trap returns the original exit code even if a later command
  # (including the guards above) altered $?.
  return "$ec"
}

bridge_agent_heartbeat_file() {
  local agent="$1"
  local workdir=""

  workdir="$(bridge_agent_workdir "$agent")"
  [[ -n "$workdir" ]] || return 1
  printf '%s/HEARTBEAT.md' "$workdir"
}

bridge_agent_heartbeat_state_file() {
  local agent="$1"
  printf '%s/heartbeat/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_agent_heartbeat_activity_state() {
  local agent="$1"
  local session=""
  local engine=""

  if ! bridge_agent_is_active "$agent"; then
    printf '%s' "stopped"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  if bridge_tmux_session_has_prompt "$session" "$engine"; then
    printf '%s' "idle"
    return 0
  fi

  # Issue #835 Wave B: distinguish "tmux up, engine never spawned"
  # (starting) from "engine present mid-turn" (working). The heartbeat
  # path persists activity_state into agent_state, which downstream
  # consumers (bridge-queue priority computation, bridge-doctor
  # diagnostics, dashboard renderers) read directly — so making the
  # snapshot, agent-show, and heartbeat paths agree avoids transient
  # disagreement during the operator's wedge window.
  if bridge_tmux_engine_requires_prompt "$engine" \
      && ! bridge_agent_engine_process_alive "$agent" "$engine"; then
    printf '%s' "starting"
    return 0
  fi

  printf '%s' "working"
}

bridge_agent_heartbeat_due() {
  local agent="$1"
  local interval="${BRIDGE_HEARTBEAT_INTERVAL_SECONDS:-300}"
  local file=""
  local next_ts=0
  local now=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || return 0
  file="$(bridge_agent_heartbeat_state_file "$agent")"
  [[ -f "$file" ]] || return 0
  daemon_source_state_file "$file" "heartbeat" 1 "HEARTBEAT_NEXT_TS" || return 0
  [[ "${HEARTBEAT_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  next_ts="${HEARTBEAT_NEXT_TS:-0}"
  now="$(date +%s)"
  (( now >= next_ts ))
}

bridge_note_agent_heartbeat() {
  local agent="$1"
  local interval="${BRIDGE_HEARTBEAT_INTERVAL_SECONDS:-300}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || interval=300
  file="$(bridge_agent_heartbeat_state_file "$agent")"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
HEARTBEAT_UPDATED_TS=$now
HEARTBEAT_NEXT_TS=$next_ts
EOF
}

write_agent_heartbeat() {
  local agent="$1"
  local heartbeat_file=""
  local state="stopped"
  local summary=""
  local queued=0
  local claimed=0
  local blocked=0
  local active="no"
  local idle="-"
  local last_seen="-"
  local last_nudge="-"
  local session=""
  local workdir=""
  local temp_file=""

  heartbeat_file="$(bridge_agent_heartbeat_file "$agent")" || return 0
  workdir="$(bridge_agent_workdir "$agent")"
  [[ -d "$workdir" ]] || return 0
  mkdir -p "$(dirname "$heartbeat_file")"

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  state="$(bridge_agent_heartbeat_activity_state "$agent")"
  summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
  if [[ -n "$summary" ]]; then
    IFS=$'\t' read -r _agent queued claimed blocked _active idle last_seen last_nudge _session _engine _workdir <<<"$summary"
  fi

  temp_file="$(mktemp)"
  cat >"$temp_file" <<EOF
# Heartbeat

- generated_at: $(bridge_now_iso)
- agent: ${agent}
- description: $(bridge_agent_desc "$agent")
- engine: $(bridge_agent_engine "$agent")
- source: $(bridge_agent_source "$agent")
- session: ${session:--}
- workdir: ${workdir:--}
- active: ${active}
- activity_state: ${state}
- always_on: $(bridge_agent_is_always_on "$agent" && printf 'yes' || printf 'no')
- wake_status: $(bridge_agent_wake_status "$agent")
- notify_status: $(bridge_agent_notify_status "$agent")
- channel_status: $(bridge_agent_channel_status "$agent")

## Queue

- queued: ${queued}
- claimed: ${claimed}
- blocked: ${blocked}

## Runtime

- idle_seconds: ${idle}
- last_seen: ${last_seen}
- last_nudge: ${last_nudge}
EOF

  if [[ -f "$heartbeat_file" ]] && cmp -s "$temp_file" "$heartbeat_file"; then
    rm -f "$temp_file"
  else
    mv "$temp_file" "$heartbeat_file"
  fi
  bridge_note_agent_heartbeat "$agent"
}

refresh_agent_heartbeats() {
  local agent
  local changed=1

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    if ! bridge_agent_heartbeat_due "$agent"; then
      continue
    fi
    write_agent_heartbeat "$agent"
    changed=0
  done

  return "$changed"
}

bridge_watchdog_state_file() {
  printf '%s/watchdog.env' "$BRIDGE_STATE_DIR"
}

bridge_watchdog_report_file() {
  printf '%s/watchdog/latest.md' "$BRIDGE_SHARED_DIR"
}

bridge_usage_poll_state_file() {
  printf '%s/usage/poll.env' "$BRIDGE_STATE_DIR"
}

bridge_claude_token_recovery_state_file() {
  printf '%s/claude-token-recovery.env' "$BRIDGE_STATE_DIR"
}

bridge_usage_due() {
  local interval="${BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS:-300}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || return 0
  file="$(bridge_usage_poll_state_file)"
  [[ -f "$file" ]] || return 0
  daemon_source_state_file "$file" "usage" 1 "USAGE_NEXT_TS" || return 0
  [[ "${USAGE_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  next_ts="${USAGE_NEXT_TS:-0}"
  (( now >= next_ts ))
}

bridge_note_usage_poll() {
  local interval="${BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS:-300}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || interval=300
  file="$(bridge_usage_poll_state_file)"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
USAGE_UPDATED_TS=$now
USAGE_NEXT_TS=$next_ts
EOF
}

bridge_claude_token_recovery_due() {
  local interval="${BRIDGE_CLAUDE_TOKEN_RECOVERY_INTERVAL_SECONDS:-300}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || return 0
  file="$(bridge_claude_token_recovery_state_file)"
  [[ -f "$file" ]] || return 0
  daemon_source_state_file "$file" "claude-token-recovery" 1 "CLAUDE_TOKEN_RECOVERY_NEXT_TS" || return 0
  [[ "${CLAUDE_TOKEN_RECOVERY_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  next_ts="${CLAUDE_TOKEN_RECOVERY_NEXT_TS:-0}"
  (( now >= next_ts ))
}

bridge_note_claude_token_recovery_poll() {
  local interval="${BRIDGE_CLAUDE_TOKEN_RECOVERY_INTERVAL_SECONDS:-300}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || interval=300
  file="$(bridge_claude_token_recovery_state_file)"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
CLAUDE_TOKEN_RECOVERY_UPDATED_TS=$now
CLAUDE_TOKEN_RECOVERY_NEXT_TS=$next_ts
EOF
}

bridge_write_usage_alert_body() {
  local file="$1"
  local title="$2"
  local provider="$3"
  local account="$4"
  local window="$5"
  local bucket="$6"
  local used_percent="$7"
  local reset_at="$8"
  local source="$9"

  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
# ${title}

- provider: ${provider}
- account: ${account:--}
- window: ${window}
- bucket: ${bucket}
- used_percent: ${used_percent}
- reset_at: ${reset_at}
- source: ${source}
- detected_at: $(bridge_now_iso)
EOF
}

bridge_release_poll_state_file() {
  printf '%s/release-check.env' "$BRIDGE_STATE_DIR"
}

bridge_release_due() {
  local interval="${BRIDGE_RELEASE_CHECK_INTERVAL_SECONDS:-86400}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
  (( interval > 0 )) || return 0
  file="$(bridge_release_poll_state_file)"
  [[ -f "$file" ]] || return 0
  daemon_source_state_file "$file" "release" 1 "RELEASE_NEXT_TS" || return 0
  [[ "${RELEASE_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  next_ts="${RELEASE_NEXT_TS:-0}"
  (( now >= next_ts ))
}

bridge_note_release_poll() {
  local interval="${BRIDGE_RELEASE_CHECK_INTERVAL_SECONDS:-86400}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
  (( interval > 0 )) || interval=86400
  file="$(bridge_release_poll_state_file)"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
RELEASE_UPDATED_TS=$now
RELEASE_NEXT_TS=$next_ts
EOF
}

bridge_daily_backup_state_file() {
  printf '%s' "${BRIDGE_DAILY_BACKUP_STATE_FILE:-$BRIDGE_STATE_DIR/daily-backup/state.env}"
}

# Coerce a state.env value (which may be empty, quoted, or hostile) into a
# safe non-negative integer for shell arithmetic. Anything non-numeric
# becomes 0. Issue #507 portability guardrail.
bridge_daily_backup_int() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$raw"
  else
    printf '%s' "0"
  fi
}

# Format a Unix epoch into a portable ISO-8601 string. macOS /bin/date
# does not support `-d @TS`, so we route through Python (already a hard
# dep). Falls back to printing the raw epoch if Python is missing.
bridge_daily_backup_format_epoch() {
  local epoch="${1:-0}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$epoch" <<'PY' 2>/dev/null || printf '%s' "$epoch"
import datetime
import sys

try:
    ts = int(sys.argv[1])
except (IndexError, ValueError):
    print("")
    raise SystemExit(0)
print(datetime.datetime.fromtimestamp(ts).isoformat(timespec="seconds"))
PY
  else
    printf '%s' "$epoch"
  fi
}

# Atomic state.env writer. tmp+rename guarantees the daemon never reads a
# half-written file mid-update (rare but real on a chronically-overloaded
# host).
bridge_daily_backup_write_state() {
  local file="$1"
  local body="$2"
  local tmp=""

  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  printf '%s' "$body" >"$tmp"
  mv "$tmp" "$file"
}

bridge_daily_backup_due() {
  local enabled="${BRIDGE_DAILY_BACKUP_ENABLED:-1}"
  local hour="${BRIDGE_DAILY_BACKUP_HOUR:-4}"
  local cooldown=0
  local file=""
  local today=""
  local now=0
  local current_minutes=0
  local scheduled_minutes=0
  local last_failure_ts=0
  local last_warn_ts=0
  local elapsed=0

  [[ "$enabled" == "1" ]] || return 1
  [[ "$hour" =~ ^[0-9]+$ ]] || hour=4
  (( hour >= 0 && hour <= 23 )) || hour=4
  cooldown="$(bridge_daily_backup_int "${BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS:-3600}")"
  (( cooldown > 0 )) || cooldown=3600

  file="$(bridge_daily_backup_state_file)"
  today="$(date +%F)"
  now="$(date +%s)"
  # Reset every loop so a stale source $file doesn't leak previous state
  # into the next decision.
  DAILY_BACKUP_LAST_SUCCESS_DATE=""
  DAILY_BACKUP_LAST_FAILURE_TS=""
  DAILY_BACKUP_LAST_FAILURE_REASON=""
  DAILY_BACKUP_LAST_WARN_TS=""
  if [[ -f "$file" ]]; then
    daemon_source_state_file "$file" "daily-backup" 0 || true
  fi
  if [[ "${DAILY_BACKUP_LAST_SUCCESS_DATE:-}" == "$today" ]]; then
    return 1
  fi

  # Bug #507: cooldown branch. After a failure (disk_full / timeout /
  # error), suppress the next attempt until the cooldown window expires.
  # Warn + audit at most once per window so the operator sees the signal
  # without log spam.
  last_failure_ts="$(bridge_daily_backup_int "${DAILY_BACKUP_LAST_FAILURE_TS:-0}")"
  if (( last_failure_ts > 0 )); then
    elapsed=$(( now - last_failure_ts ))
    if (( elapsed >= 0 && elapsed < cooldown )); then
      last_warn_ts="$(bridge_daily_backup_int "${DAILY_BACKUP_LAST_WARN_TS:-0}")"
      if (( last_warn_ts == 0 || (now - last_warn_ts) >= cooldown )); then
        local resume_at=""
        resume_at="$(bridge_daily_backup_format_epoch "$(( last_failure_ts + cooldown ))")"
        daemon_warn "daily-backup in cooldown after ${DAILY_BACKUP_LAST_FAILURE_REASON:-failure}; next attempt after $resume_at"
        bridge_audit_log daemon daily_backup_cooldown daemon \
          --detail reason="${DAILY_BACKUP_LAST_FAILURE_REASON:-unknown}" \
          --detail since_ts="$last_failure_ts" \
          --detail cooldown_seconds="$cooldown" \
          --detail resume_at="$resume_at" || true
        bridge_daily_backup_record_warn "$file" "$now"
      fi
      return 1
    fi
  fi

  current_minutes=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  scheduled_minutes=$(( 10#$hour * 60 ))
  (( current_minutes >= scheduled_minutes ))
}

# Update the LAST_WARN_TS in place without losing other state.env keys.
bridge_daily_backup_record_warn() {
  local file="$1"
  local now="$2"
  local body=""

  body="$(bridge_daily_backup_compose_state \
    --success-ts "${DAILY_BACKUP_LAST_SUCCESS_TS:-}" \
    --success-date "${DAILY_BACKUP_LAST_SUCCESS_DATE:-}" \
    --archive "${DAILY_BACKUP_LAST_ARCHIVE:-}" \
    --pruned "${DAILY_BACKUP_LAST_PRUNED_COUNT:-}" \
    --failure-ts "${DAILY_BACKUP_LAST_FAILURE_TS:-}" \
    --failure-reason "${DAILY_BACKUP_LAST_FAILURE_REASON:-}" \
    --failure-detail "${DAILY_BACKUP_LAST_FAILURE_DETAIL:-}" \
    --warn-ts "$now")"
  bridge_daily_backup_write_state "$file" "$body" || return 1
  DAILY_BACKUP_LAST_WARN_TS="$now"
}

# Single source of truth for state.env body assembly. Keeps the schema in
# one place so additions (cooldown_warn, last_archive_bytes, etc.) don't
# get out of sync between success / failure / warn paths.
bridge_daily_backup_compose_state() {
  local success_ts="" success_date="" archive="" pruned=""
  local failure_ts="" failure_reason="" failure_detail="" warn_ts=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --success-ts) success_ts="${2:-}"; shift 2 ;;
      --success-date) success_date="${2:-}"; shift 2 ;;
      --archive) archive="${2:-}"; shift 2 ;;
      --pruned) pruned="${2:-}"; shift 2 ;;
      --failure-ts) failure_ts="${2:-}"; shift 2 ;;
      --failure-reason) failure_reason="${2:-}"; shift 2 ;;
      --failure-detail) failure_detail="${2:-}"; shift 2 ;;
      --warn-ts) warn_ts="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Footgun #11 (refs #815 Wave B): emit via grouped printf to avoid
  # heredoc on a hot path. Caller captures stdout via $(...).
  {
    printf 'DAILY_BACKUP_LAST_SUCCESS_TS=%s\n' "$success_ts"
    printf 'DAILY_BACKUP_LAST_SUCCESS_DATE=%s\n' "$success_date"
    printf 'DAILY_BACKUP_LAST_ARCHIVE=%s\n' "$(printf '%q' "$archive")"
    printf 'DAILY_BACKUP_LAST_PRUNED_COUNT=%s\n' "$pruned"
    printf 'DAILY_BACKUP_LAST_FAILURE_TS=%s\n' "$failure_ts"
    printf 'DAILY_BACKUP_LAST_FAILURE_REASON=%s\n' "$failure_reason"
    printf 'DAILY_BACKUP_LAST_FAILURE_DETAIL=%s\n' "$(printf '%q' "$failure_detail")"
    printf 'DAILY_BACKUP_LAST_WARN_TS=%s\n' "$warn_ts"
  }
}

bridge_note_daily_backup_success() {
  local archive_path="$1"
  local pruned_count="$2"
  local file=""
  local now=0
  local today=""
  local body=""

  file="$(bridge_daily_backup_state_file)"
  now="$(date +%s)"
  today="$(date +%F)"
  body="$(bridge_daily_backup_compose_state \
    --success-ts "$now" \
    --success-date "$today" \
    --archive "$archive_path" \
    --pruned "$pruned_count")"
  bridge_daily_backup_write_state "$file" "$body" || return 1
  bridge_audit_log daemon daily_backup_recovered daemon \
    --detail archive_path="$archive_path" || true
}

# Bug #507 (cooldown wiring): record a backup failure so
# bridge_daily_backup_due skips the next cycle until the cooldown window
# elapses. Reason is one of disk_full | timeout | parse | concurrent |
# error_<...>. Detail carries free/needed bytes or stderr snippets.
bridge_note_daily_backup_failure() {
  local reason="${1:-unknown}"
  local detail="${2:-}"
  local file=""
  local now=0
  local body=""

  file="$(bridge_daily_backup_state_file)"
  now="$(date +%s)"
  # Preserve any prior success record (operator wants to know the last
  # known good archive even after a failure) by sourcing the existing
  # file before composing.
  DAILY_BACKUP_LAST_SUCCESS_TS=""
  DAILY_BACKUP_LAST_SUCCESS_DATE=""
  DAILY_BACKUP_LAST_ARCHIVE=""
  DAILY_BACKUP_LAST_PRUNED_COUNT=""
  if [[ -f "$file" ]]; then
    daemon_source_state_file "$file" "daily-backup" 0 || true
  fi
  body="$(bridge_daily_backup_compose_state \
    --success-ts "${DAILY_BACKUP_LAST_SUCCESS_TS:-}" \
    --success-date "${DAILY_BACKUP_LAST_SUCCESS_DATE:-}" \
    --archive "${DAILY_BACKUP_LAST_ARCHIVE:-}" \
    --pruned "${DAILY_BACKUP_LAST_PRUNED_COUNT:-}" \
    --failure-ts "$now" \
    --failure-reason "$reason" \
    --failure-detail "$detail" \
    --warn-ts "$now")"
  bridge_daily_backup_write_state "$file" "$body" || return 1
  daemon_warn "daily-backup failed: reason=$reason detail=$detail"
  bridge_audit_log daemon daily_backup_failure daemon \
    --detail reason="$reason" \
    --detail detail="$detail" || true

  # PR #508 r3 (operator-requested): daemon log + state.env alone are
  # invisible unless someone actively monitors them. File a task to the
  # admin agent so the operator gets an inbox signal. The cooldown
  # gating in bridge_daily_backup_due (default 1h) already ensures this
  # function is invoked at most once per cooldown window per failure
  # reason — no spam without further dedup logic.
  bridge_emit_daily_backup_failure_admin_task "$reason" "$detail"
}

# Best-effort admin notification when daily-backup fails. No-op if
# BRIDGE_ADMIN_AGENT_ID is unset or the bridge CLI isn't reachable.
# Always returns 0 so a notification failure never cascades into the
# daemon main loop.
bridge_emit_daily_backup_failure_admin_task() {
  local reason="${1:-unknown}"
  local detail="${2:-}"
  local admin="${BRIDGE_ADMIN_AGENT_ID:-}"
  local target_bridge=""
  local body_file=""
  local hostname_short=""
  local cooldown=""
  local resume_at=""

  [[ -n "$admin" ]] || return 0

  # Prefer the live install's CLI (operator-facing paths in the body
  # need to match what the admin will actually run). Fall back to the
  # source checkout's CLI if BRIDGE_HOME isn't laid out yet.
  if [[ -x "$BRIDGE_HOME/agent-bridge" ]]; then
    target_bridge="$BRIDGE_HOME/agent-bridge"
  elif [[ -x "$SCRIPT_DIR/agent-bridge" ]]; then
    target_bridge="$SCRIPT_DIR/agent-bridge"
  else
    return 0
  fi

  hostname_short="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
  cooldown="$(bridge_daily_backup_int "${BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS:-3600}")"
  (( cooldown > 0 )) || cooldown=3600
  resume_at="$(bridge_daily_backup_format_epoch "$(( $(date +%s) + cooldown ))")"

  body_file="$(mktemp -t bridge-daily-backup-fail.XXXXXX.md)"
  case "$reason" in
    disk_full)
      _bridge_render_disk_full_task_body "$detail" "$resume_at" "$cooldown" >"$body_file"
      ;;
    *)
      _bridge_render_generic_failure_task_body "$reason" "$detail" "$resume_at" "$cooldown" >"$body_file"
      ;;
  esac

  if ! "$target_bridge" task create \
       --to "$admin" --priority urgent --from daemon \
       --title "[backup-failed:${reason}] daily-backup paused on ${hostname_short}" \
       --body-file "$body_file" >/dev/null 2>&1; then
    daemon_warn "failed to file [backup-failed:${reason}] task to admin=${admin}; check the admin id and try again"
  fi
  rm -f "$body_file"
  return 0
}

_bridge_render_disk_full_task_body() {
  local detail="${1:-}"
  local resume_at="${2:-}"
  local cooldown="${3:-3600}"

  cat <<EOF
# Daily backup paused — host disk near full

The daily-backup pre-flight check refused to write today's tarball
because free space is below 1.5× the previous archive size (or the
100 MiB floor). The backup is **stopped**; no partial tmp file was
created. The daemon will not retry until cooldown expires.

## Symptom

\`\`\`
${detail:-(no detail)}
\`\`\`

- Cooldown: **${cooldown}s** (next attempt after **${resume_at}**)
- Cooldown env: \`BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS\`

## Recovery (run on this host)

1. Inspect disk usage:

   \`\`\`bash
   df -h "$BRIDGE_HOME"
   du -sh "$BRIDGE_HOME"/backups/{daily,upgrade-*} 2>/dev/null | sort -h
   \`\`\`

2. Free space (in priority order):

   \`\`\`bash
   # Reap orphaned tmp files (typically GBs).
   rm -f "$BRIDGE_HOME"/backups/daily/*.tgz.tmp.*

   # Drop daily archives older than 7 days.
   find "$BRIDGE_HOME"/backups/daily -maxdepth 1 -type f \\
     -name 'agent-bridge-*.tgz' -mtime +7 -print -delete

   # Drop oldest upgrade-* keeping the 5 newest.
   ls -1dt "$BRIDGE_HOME"/backups/upgrade-* 2>/dev/null \\
     | tail -n +6 | xargs -r rm -rf
   \`\`\`

3. Run packaged cleanup (covers all of the above + ~/.claude.json validation):

   \`\`\`bash
   python3 "$BRIDGE_HOME"/bridge-upgrade.py cleanup-residue \\
     --target-root "$BRIDGE_HOME"
   \`\`\`

4. Force a fresh attempt (re-runs preflight + clears failure state on success):

   \`\`\`bash
   python3 "$BRIDGE_HOME"/bridge-upgrade.py daily-backup-live \\
     --target-root "$BRIDGE_HOME" \\
     --backup-dir "$BRIDGE_HOME"/backups/daily
   \`\`\`

## Close this task

Close once the next daemon cycle reports \`outcome=created\` (visible
in \`$BRIDGE_HOME/state/daily-backup/state.env\` as a new
\`DAILY_BACKUP_LAST_SUCCESS_DATE\`) and free space ≥ 1.5× prior archive
size.
EOF
}

_bridge_render_generic_failure_task_body() {
  local reason="${1:-unknown}"
  local detail="${2:-}"
  local resume_at="${3:-}"
  local cooldown="${4:-3600}"

  cat <<EOF
# Daily backup paused — failure reason: ${reason}

The daily-backup attempt failed and the daemon recorded a cooldown
window. The backup is **stopped**; the daemon will not retry until
cooldown expires.

## Symptom

\`\`\`
reason: ${reason}
detail: ${detail:-(no detail)}
\`\`\`

- Cooldown: **${cooldown}s** (next attempt after **${resume_at}**)

## What this could mean

- \`timeout\`: the backup walk exceeded the 120s daemon timeout. Check whether \`$BRIDGE_HOME\` has unexpectedly large directories (e.g. an unbacked \`shared/\` or accidentally-included \`worktrees/\`). Tune \`BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS\` if needed.
- \`parse\` / \`subprocess_rc_*\`: the python3 helper exited unexpectedly. Stderr should be in the daemon log; \`tail -n 200 $BRIDGE_HOME/state/daemon.log\`.
- \`error_sqlite_snapshot\`: \`state/tasks.db\` exists but its hot snapshot failed (corruption, locked). Run \`python3 $BRIDGE_HOME/bridge-upgrade.py verify-tasks-db --target-root $BRIDGE_HOME\` to diagnose.
- \`error_oserror_*\`: filesystem error from tar write or rename. Check disk health.

## Recovery

1. Read the daemon log for context:

   \`\`\`bash
   tail -n 200 "$BRIDGE_HOME"/state/daemon.log
   \`\`\`

2. Read the daily-backup state file:

   \`\`\`bash
   cat "$BRIDGE_HOME"/state/daily-backup/state.env
   \`\`\`

3. Run packaged cleanup (idempotent; will not retry the backup):

   \`\`\`bash
   python3 "$BRIDGE_HOME"/bridge-upgrade.py cleanup-residue \\
     --target-root "$BRIDGE_HOME"
   \`\`\`

4. Force a fresh attempt:

   \`\`\`bash
   python3 "$BRIDGE_HOME"/bridge-upgrade.py daily-backup-live \\
     --target-root "$BRIDGE_HOME" \\
     --backup-dir "$BRIDGE_HOME"/backups/daily
   \`\`\`

Close the task once the next daemon cycle reports \`outcome=created\`.
EOF
}

bridge_release_paths_valid() {
  local shared_ok="0"
  local state_ok="0"
  local task_db_ok="0"

  shared_ok="$(bridge_path_is_within_root "$BRIDGE_SHARED_DIR" "$BRIDGE_HOME")"
  state_ok="$(bridge_path_is_within_root "$BRIDGE_STATE_DIR" "$BRIDGE_HOME")"
  task_db_ok="$(bridge_path_is_within_root "$BRIDGE_TASK_DB" "$BRIDGE_STATE_DIR")"

  if [[ "$shared_ok" != "1" || "$state_ok" != "1" || "$task_db_ok" != "1" ]]; then
    daemon_info "skipping release alert due to mixed bridge paths: home=$BRIDGE_HOME state=$BRIDGE_STATE_DIR shared=$BRIDGE_SHARED_DIR task_db=$BRIDGE_TASK_DB"
    return 1
  fi

  return 0
}

bridge_release_alert_body_file() {
  local tag="${1:-latest}"
  local safe_tag=""

  safe_tag="$(printf '%s' "$tag" | sed 's/[^[:alnum:]._-]/-/g')"
  [[ -n "$safe_tag" ]] || safe_tag="latest"
  printf '%s/releases/%s.md' "$BRIDGE_SHARED_DIR" "$safe_tag"
}

bridge_write_release_alert_body() {
  local body_file="$1"
  local monitor_json="$2"
  local upgrade_check_json="${3:-{}}"

  python3 - "$body_file" "$monitor_json" "$upgrade_check_json" <<'PY'
import json
import sys
from pathlib import Path

body_file = Path(sys.argv[1])
monitor_payload = json.loads(sys.argv[2])
try:
    upgrade_payload = json.loads(sys.argv[3])
except Exception:
    upgrade_payload = {}

alerts = monitor_payload.get("alerts") or []
if not alerts:
    raise SystemExit(1)
alert = alerts[0]
release = monitor_payload.get("release") or {}
tag = str(alert.get("latest_tag") or release.get("latest_tag") or "")
version = str(alert.get("latest_version") or release.get("latest_version") or "")
installed_version = str(alert.get("installed_version") or release.get("installed_version") or "")
release_name = str(alert.get("release_name") or release.get("release_name") or tag or version)
repo = str(alert.get("repo") or release.get("repo") or "")
release_url = str(alert.get("html_url") or release.get("html_url") or "")
published_at = str(alert.get("published_at") or release.get("published_at") or "")
notes = str(alert.get("body") or release.get("body") or "").strip()

upgrade_target_ref = str(upgrade_payload.get("target_ref") or "")
upgrade_target_version = str(upgrade_payload.get("target_version") or "")
upgrade_available = bool(upgrade_payload.get("update_available"))
local_upgrade_ready = bool(
    upgrade_available
    and (
        (tag and upgrade_target_ref == tag)
        or (version and upgrade_target_version == version)
    )
)

if local_upgrade_ready:
    readiness_note = "Direct `agb upgrade` on this server should target the same stable release."
else:
    readiness_note = (
        "This server's local source checkout is not yet pointing at the same stable release. "
        "Downstream/source sync may be required before `agb upgrade` can apply it."
    )

body_file.parent.mkdir(parents=True, exist_ok=True)
with body_file.open("w", encoding="utf-8") as fh:
    fh.write("# Stable Release Available\n\n")
    fh.write(f"- release: {release_name}\n")
    fh.write(f"- tag: {tag or '-'}\n")
    fh.write(f"- version: {version or '-'}\n")
    fh.write(f"- installed_version: {installed_version or '-'}\n")
    fh.write(f"- repo: {repo or '-'}\n")
    fh.write(f"- published_at: {published_at or '-'}\n")
    fh.write(f"- release_url: {release_url or '-'}\n")
    fh.write(f"- detected_at: {monitor_payload.get('generated_at') or '-'}\n")
    fh.write("\n## Patch Action\n\n")
    fh.write("1. Read the release notes below.\n")
    fh.write("2. Summarize the user-facing changes to the admin user in Korean.\n")
    fh.write("3. Ask whether to apply the upgrade now.\n")
    fh.write("4. If the local upgrade path is not ready, explain that source/downstream sync is required first.\n")
    fh.write("\n## Local Upgrade Readiness\n\n")
    fh.write(f"- local_upgrade_ready: {'yes' if local_upgrade_ready else 'no'}\n")
    fh.write(f"- local_upgrade_target_ref: {upgrade_target_ref or '-'}\n")
    fh.write(f"- local_upgrade_target_version: {upgrade_target_version or '-'}\n")
    fh.write(f"- local_upgrade_update_available: {'yes' if upgrade_available else 'no'}\n")
    fh.write(f"- note: {readiness_note}\n")
    fh.write("\n## Release Notes\n\n")
    if notes:
        fh.write(notes)
        fh.write("\n")
    else:
        fh.write("_No release notes were published in the GitHub release body._\n")
PY
}

process_usage_monitor() {
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local monitor_json=""
  local alert_rows=""
  local rotation_rows=""
  local alert_count=0
  local rotation_count=0
  local priority=""
  local title=""
  local body=""
  local provider=""
  local account=""
  local window=""
  local bucket=""
  local used_percent=""
  local reset_at=""
  local source=""
  local body_file=""
  local rotation_agent_scope="${BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS:-static}"
  local rotate_json=""
  local rotation_status_row=""
  local rotation_status=""
  local rotation_reason=""
  local rotation_from=""
  local rotation_to=""
  local rotation_sync_status=""
  # Footgun #11 (refs #815 Wave B): route the alert_rows / rotation_rows
  # loops through tempfiles to avoid `done <<<` heredoc_write wedges.
  local _alert_tmp="" _rotation_tmp=""
  _alert_tmp="$(mktemp)"
  _rotation_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_alert_tmp' '$_rotation_tmp'" RETURN

  [[ "${BRIDGE_USAGE_MONITOR_ENABLED:-1}" == "1" ]] || return 1
  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1
  bridge_usage_due || return 1

  # Issue #831: read each Claude agent's own usage cache, not just the
  # controller's $HOME. Default scope mirrors bridge-auth.sh sync (static
  # Claude roster). Operators can broaden via BRIDGE_USAGE_MONITOR_AGENTS.
  local usage_monitor_agents_scope="${BRIDGE_USAGE_MONITOR_AGENTS:-static}"
  if ! monitor_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-usage.sh" monitor --json --agents "$usage_monitor_agents_scope" 2>/dev/null)"; then
    bridge_note_usage_poll
    return 1
  fi

  # Issue #800 Track A: moved out of `python3 - <<'PY'` heredoc-stdin into a
  # checked-in helper subcommand wrapped by bridge_with_timeout. The original
  # heredoc-stdin pattern allowed bash to wedge in `heredoc_write` BEFORE the
  # python child ever launched (the deadlock class documented in #800);
  # `python3 helpers.py …` has no heredoc on the pipe and the external
  # timeout(1) covers the full call.
  alert_rows="$(bridge_with_timeout 5 usage_alert_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" usage-alert-parse "$monitor_json")" || {
    bridge_note_usage_poll
    return 1
  }

  # Issue #800 regression follow-up (PR #799 introduced this site 30 min
  # after PR #801 closed nine sibling heredoc-stdin sites). Routed through
  # the checked-in helper subcommand wrapped by bridge_with_timeout — same
  # rationale as the usage-alert-parse call above. 5s ceiling (pure JSON
  # filter, no IO); rc=124|137 falls through ``|| rotation_rows=""`` so the
  # loop continues without rotation candidates this tick.
  rotation_rows="$(bridge_with_timeout 5 usage_rotation_candidates_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" usage-rotation-candidates-parse "$monitor_json")" || rotation_rows=""

  printf '%s\n' "$alert_rows" > "$_alert_tmp"
  printf '%s\n' "$rotation_rows" > "$_rotation_tmp"

  local triggering_agent=""
  while IFS=$'\t' read -r provider account window bucket used_percent reset_at source triggering_agent body; do
    [[ -z "$provider" || -z "$window" || -z "$bucket" ]] && continue
    if [[ "$bucket" == "crit" ]]; then
      priority="urgent"
      title="$(printf '%s usage critical' "$provider")"
    else
      priority="high"
      title="$(printf '%s usage warning' "$provider")"
    fi
    if bridge_agent_has_notify_transport "$admin_agent"; then
      bridge_notify_send "$admin_agent" "$title" "$body" "" "$priority" "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
    fi
    # Issue #831: record the triggering agent in the audit row so operators
    # can attribute a per-agent usage spike to its source agent rather than
    # the controller. Empty string preserves the previous row shape for
    # legacy-single-cache invocations.
    bridge_audit_log daemon usage_alert "$admin_agent" \
      --detail provider="$provider" \
      --detail account="$account" \
      --detail window="$window" \
      --detail bucket="$bucket" \
      --detail used_percent="$used_percent" \
      --detail reset_at="$reset_at" \
      --detail source="$source" \
      --detail agent="$triggering_agent"
    alert_count=$((alert_count + 1))
  done < "$_alert_tmp"

  local worst_case_agent=""
  while IFS=$'\t' read -r provider account window used_percent reset_at source worst_case_agent body; do
    [[ -z "$provider" || "$provider" != "claude" || -z "$window" ]] && continue
    # Rotate only once per monitor pass; bridge-usage.py already latches each
    # provider/account/window candidate once per usage reset cycle.
    (( rotation_count > 0 )) && continue
    rotate_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-auth.sh" claude-token rotate \
      --if-auto-enabled \
      --sync \
      --agents "$rotation_agent_scope" \
      --reason "usage:${window}:${used_percent}" \
      --json 2>/dev/null || true)"
    # Issue #800 regression follow-up: rotation outcome parser moved out of
    # heredoc-stdin into the helper subcommand. 5s ceiling — pure JSON
    # parse + tabular print; rc=124|137 leaves the row empty and the
    # subsequent ``IFS=$'\t' read`` decodes to empty fields, which the
    # downstream ``case`` statement routes through the ``error:*`` branch.
    rotation_status_row="$(bridge_with_timeout 5 rotation_status_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" rotation-status-parse "$rotate_json" || true)"
    IFS=$'\t' read -r rotation_status rotation_reason rotation_from rotation_to rotation_sync_status <<<"$rotation_status_row"
    # Issue #831: record `worst_case_agent` — the agent whose usage actually
    # crossed the rotation threshold this pass. Empty for legacy single-cache
    # rows. Distinct from `agent_scope` (the rotation fanout target).
    bridge_audit_log daemon claude_token_rotation "$admin_agent" \
      --detail status="$rotation_status" \
      --detail reason="$rotation_reason" \
      --detail provider="$provider" \
      --detail account="$account" \
      --detail window="$window" \
      --detail used_percent="$used_percent" \
      --detail reset_at="$reset_at" \
      --detail source="$source" \
      --detail from="$rotation_from" \
      --detail to="$rotation_to" \
      --detail sync_status="$rotation_sync_status" \
      --detail agent_scope="$rotation_agent_scope" \
      --detail worst_case_agent="$worst_case_agent"
    case "$rotation_status:$rotation_reason" in
      rotated:*)
        title="claude token rotated"
        body="Claude token rotated after ${window} usage reached ${used_percent}%. active_token=${rotation_to}; sync=${rotation_sync_status:-unknown}."
        priority="high"
        ;;
      skipped:no_alternate_token|error:*)
        title="claude token rotation needs attention"
        body="Claude usage reached ${used_percent}% for ${window}, but token rotation did not complete (${rotation_status:-unknown}${rotation_reason:+: $rotation_reason})."
        priority="high"
        ;;
      *)
        title=""
        ;;
    esac
    if [[ -n "$title" ]] && bridge_agent_has_notify_transport "$admin_agent"; then
      bridge_notify_send "$admin_agent" "$title" "$body" "" "$priority" "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
    fi
    rotation_count=$((rotation_count + 1))
  done < "$_rotation_tmp"

  bridge_note_usage_poll
  (( alert_count > 0 || rotation_count > 0 ))
}

process_claude_token_recovery() {
  local target="${BRIDGE_ADMIN_AGENT_ID:-daemon}"
  local recovery_json=""
  local recovery_row=""
  local status=""
  local reason=""
  local checked_count="0"
  local recovered_count="0"
  local still_disabled_count="0"
  local recovered_csv=""
  local sync_recommended="0"
  local sync_json=""
  local sync_status=""
  local timeout_seconds="${BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS:-60}"
  local check_timeout="${BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS:-45}"
  local retry_seconds="${BRIDGE_CLAUDE_TOKEN_CHECK_RETRY_SECONDS:-1800}"
  local agent_scope="${BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS:-static}"

  [[ "${BRIDGE_CLAUDE_TOKEN_RECOVERY_ENABLED:-1}" == "1" ]] || return 1
  bridge_claude_token_recovery_due || return 1

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=60
  [[ "$check_timeout" =~ ^[0-9]+$ ]] || check_timeout=45
  [[ "$retry_seconds" =~ ^[0-9]+$ ]] || retry_seconds=1800

  if ! recovery_json="$(bridge_with_timeout "$timeout_seconds" claude_token_recovery \
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-auth.sh" claude-token recover-due \
      --timeout "$check_timeout" \
      --retry-seconds "$retry_seconds" \
      --json 2>/dev/null)"; then
    bridge_note_claude_token_recovery_poll
    bridge_audit_log daemon claude_token_recovery "$target" \
      --detail status=error \
      --detail reason=recover_due_failed \
      --detail timeout_seconds="$timeout_seconds" \
      2>/dev/null || true
    return 1
  fi

  # Issue #800 regression follow-up: recovery-outcome parser moved into the
  # helper subcommand. 5s ceiling — pure JSON parse + tabular print; on
  # rc=124|137 the bash callsite sees an empty row and the downstream
  # audit_log captures status="" reason="" which the operator can spot via
  # the daemon_subprocess_timeout row written by bridge_with_timeout.
  recovery_row="$(bridge_with_timeout 5 recovery_status_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" recovery-status-parse "$recovery_json" || true)"
  IFS=$'\t' read -r status reason checked_count recovered_count still_disabled_count recovered_csv sync_recommended <<<"$recovery_row"

  bridge_note_claude_token_recovery_poll

  if [[ "$sync_recommended" == "1" ]]; then
    sync_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-auth.sh" claude-token sync --agents "$agent_scope" --json 2>/dev/null || true)"
    # Issue #800 regression follow-up: sync-status extractor moved into the
    # helper subcommand. 5s ceiling — single dict lookup; rc=124|137 leaves
    # sync_status empty and the surrounding audit_log captures sync_status=""
    # so the operator sees the gap alongside the daemon_subprocess_timeout
    # row.
    sync_status="$(bridge_with_timeout 5 sync_status_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" sync-status-parse "$sync_json" || true)"
  fi

  if [[ "$status" != "skipped" || "${checked_count:-0}" != "0" ]]; then
    bridge_audit_log daemon claude_token_recovery "$target" \
      --detail status="$status" \
      --detail reason="$reason" \
      --detail checked_count="$checked_count" \
      --detail recovered_count="$recovered_count" \
      --detail still_disabled_count="$still_disabled_count" \
      --detail recovered="$recovered_csv" \
      --detail sync_recommended="$sync_recommended" \
      --detail sync_status="$sync_status" \
      2>/dev/null || true
  fi

  if [[ "${recovered_count:-0}" != "0" ]]; then
    daemon_info "claude token recovery: recovered=${recovered_csv:-?} sync=${sync_status:-not-needed}"
  fi

  [[ "$status" != "skipped" && "${checked_count:-0}" != "0" ]]
}

process_release_monitor() {
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local monitor_json=""
  local alert_row=""
  local body_file=""
  local title=""
  local title_prefix="[release] Agent Bridge "
  local existing_id=""
  local create_output=""
  local reported=0
  local tag=""
  local version=""
  local published_at=""
  local release_url=""
  local release_name=""
  local upgrade_check_json="{}"

  [[ "${BRIDGE_RELEASE_CHECK_ENABLED:-1}" == "1" ]] || return 1
  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1
  bridge_release_paths_valid || return 1
  bridge_release_due || return 1

  # Issue #265 proposal A: release monitor hits the GitHub releases endpoint
  # over the network; a stuck SSL handshake here would freeze the main loop
  # at __wait4 with no recovery. Per-call timeout caps the worst case.
  if ! monitor_json="$(bridge_with_timeout "" release_monitor python3 "$SCRIPT_DIR/bridge-release.py" monitor --repo "$BRIDGE_RELEASE_REPO" --installed-version "$(bridge_version)" --state-file "$BRIDGE_RELEASE_CHECK_STATE_FILE" --json 2>/dev/null)"; then
    bridge_note_release_poll
    return 1
  fi

  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout (see bridge-daemon-helpers.py docstring for context).
  alert_row="$(bridge_with_timeout 5 release_alert_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" release-alert-parse "$monitor_json")"

  bridge_note_release_poll
  [[ -n "$alert_row" ]] || return 1
  IFS=$'\t' read -r tag version release_name published_at release_url <<<"$alert_row"
  [[ -n "$tag" ]] || return 1

  # Refs #815 Wave B: wrap the upgrade --check call with bridge_with_timeout
  # (30s ceiling — local readiness probe, normally <1s; protects the release
  # monitor hot path from a wedged upgrader child).
  if ! upgrade_check_json="$(bridge_with_timeout 30 release_upgrade_check "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" upgrade --check --json --no-restart-daemon --target "$BRIDGE_HOME" 2>/dev/null)"; then
    upgrade_check_json="{}"
  fi

  body_file="$(bridge_release_alert_body_file "$tag")"
  if [[ "$(bridge_path_is_within_root "$body_file" "$BRIDGE_SHARED_DIR")" != "1" ]]; then
    daemon_info "skipping release alert because body_file escaped shared dir: body_file=$body_file shared=$BRIDGE_SHARED_DIR"
    return 1
  fi
  if ! bridge_write_release_alert_body "$body_file" "$monitor_json" "$upgrade_check_json"; then
    return 1
  fi

  title="[release] Agent Bridge ${tag} available"
  existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
  if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    if bridge_queue_cli update "$existing_id" --actor daemon --title "$title" --priority normal --body-file "$body_file" >/dev/null 2>&1; then
      reported=1
    fi
  else
    create_output="$(bridge_queue_cli create --to "$admin_agent" --from daemon --priority normal --title "$title" --body-file "$body_file" 2>/dev/null || true)"
    if [[ "$create_output" == task_id=* ]]; then
      reported=1
    fi
  fi

  if (( reported == 1 )); then
    bridge_audit_log daemon release_available "$admin_agent" \
      --detail tag="$tag" \
      --detail version="$version" \
      --detail published_at="$published_at" \
      --detail release_url="$release_url"
    daemon_info "release alert queued for ${admin_agent}: ${tag}"
    return 0
  fi

  return 1
}

process_daily_backup() {
  local backup_json=""
  local subprocess_rc=0
  local outcome=""
  local archive_path=""
  local pruned_count=0
  local free_bytes=0
  local needed_bytes=0
  local error_detail=""
  local retain_days="${BRIDGE_DAILY_BACKUP_RETAIN_DAYS:-7}"

  bridge_daily_backup_due || return 1
  [[ "$retain_days" =~ ^[0-9]+$ ]] || retain_days=7
  (( retain_days > 0 )) || retain_days=7

  # Issue #265 proposal A: daily-backup walks BRIDGE_HOME (large file tree on
  # long-lived installs) and writes a tarball; a hung filesystem (NFS,
  # external mount, full disk waiting on flush) would otherwise stall the
  # daemon main loop. 120s ceiling is well above the observed normal runtime.
  # Bug #507: capture stderr too (separate file) so an error_detail can be
  # surfaced to state.env / audit instead of silently swallowed.
  #
  # PR #508 r2: do NOT wrap the assignment in `if ! ...; then` — `$?`
  # inside that branch is the status of the `!` operator (always 0), not
  # the subprocess. Capture the rc directly via `set +e` / `set -e` toggle
  # so timeouts (124) and non-zero rc map to real failure reasons.
  local stderr_capture=""
  stderr_capture="$(mktemp -t bridge-daily-backup.XXXXXX.err)"
  set +e
  backup_json="$(bridge_with_timeout 120 daily_backup python3 "$SCRIPT_DIR/bridge-upgrade.py" daily-backup-live --target-root "$BRIDGE_HOME" --backup-dir "$BRIDGE_DAILY_BACKUP_DIR" --retain-days "$retain_days" 2>"$stderr_capture")"
  subprocess_rc=$?
  set -e
  if (( subprocess_rc != 0 )); then
    error_detail="$(head -c 400 "$stderr_capture" 2>/dev/null | tr '\n' ' ')"
    rm -f "$stderr_capture"
    if (( subprocess_rc == 124 )); then
      bridge_note_daily_backup_failure "timeout" "bridge_with_timeout 120s exceeded"
    else
      bridge_note_daily_backup_failure "subprocess_rc_${subprocess_rc}" "$error_detail"
    fi
    return 1
  fi
  rm -f "$stderr_capture"

  # Bug #507: parse outcome from the structured JSON instead of relying on
  # `created`. Outcomes other than `created` carry their own follow-up.
  local parse_payload=""
  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout. 60s ceiling (well above the helper's pure-JSON parse
  # cost) mirrors the daily-backup-live budget per the issue's per-site
  # recommendations.
  if ! parse_payload="$(bridge_with_timeout 60 backup_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" backup-parse "$backup_json" 2>/dev/null)"; then
    bridge_note_daily_backup_failure "parse" "python3 invocation failed"
    return 1
  fi
  IFS=$'\t' read -r outcome error_detail archive_path pruned_count free_bytes needed_bytes <<<"$parse_payload"

  case "$outcome" in
    PARSE_ERROR)
      bridge_note_daily_backup_failure "parse" "$error_detail"
      return 1
      ;;
    created)
      bridge_note_daily_backup_success "$archive_path" "$pruned_count"
      bridge_audit_log daemon daily_backup_created daemon \
        --detail archive_path="$archive_path" \
        --detail backup_dir="$BRIDGE_DAILY_BACKUP_DIR" \
        --detail retain_days="$retain_days" \
        --detail pruned_count="$pruned_count" || true
      daemon_info "daily live backup created: $archive_path (pruned=$pruned_count)"
      return 0
      ;;
    skipped_disk_full)
      bridge_note_daily_backup_failure "disk_full" "free=${free_bytes} needed=${needed_bytes}"
      return 1
      ;;
    skipped_concurrent)
      # Another writer holds the lock right now. Don't record a failure
      # because nothing went wrong — just skip and let the lock holder
      # report success on its own state.env update.
      daemon_info "daily-backup skipped: concurrent writer holds lock"
      return 1
      ;;
    skipped_no_target_root|dry_run)
      return 1
      ;;
    error_*)
      bridge_note_daily_backup_failure "$outcome" "$error_detail"
      return 1
      ;;
    *)
      bridge_note_daily_backup_failure "unknown_outcome" "outcome=${outcome} detail=${error_detail}"
      return 1
      ;;
  esac
}

bridge_stall_retry_seconds() {
  local classification="$1"
  case "$classification" in
    rate_limit)
      printf '%s' "${BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS:-30}"
      ;;
    network)
      printf '%s' "${BRIDGE_STALL_NETWORK_RETRY_SECONDS:-60}"
      ;;
    interactive_picker)
      # Pickers expect a single keystroke (Enter / 1 / n), not a text nudge.
      # Daemon does not retry; the main loop routes the picker straight to
      # the admin escalation branch, so any retry value would be dead config.
      printf '%s' "0"
      ;;
    unknown)
      printf '%s' "${BRIDGE_STALL_UNKNOWN_RETRY_SECONDS:-300}"
      ;;
    *)
      printf '%s' "0"
      ;;
  esac
}

bridge_stall_escalate_after_seconds() {
  local classification="$1"
  case "$classification" in
    auth)
      printf '%s' "0"
      ;;
    interactive_picker)
      # Picker stalls block all forward progress on the affected agent
      # and require a deliberate keypress decision; escalate immediately
      # like auth. The main loop hardwires this path and ignores any
      # configured delay, so we hardcode 0 instead of reading an env var
      # the daemon would silently disregard.
      printf '%s' "0"
      ;;
    network)
      printf '%s' "${BRIDGE_STALL_NETWORK_ESCALATE_SECONDS:-600}"
      ;;
    unknown)
      printf '%s' "${BRIDGE_STALL_UNKNOWN_ESCALATE_SECONDS:-600}"
      ;;
    *)
      printf '%s' "${BRIDGE_STALL_ESCALATE_AFTER_SECONDS:-300}"
      ;;
  esac
}

bridge_stall_title_prefix() {
  local classification="$1"
  local agent="$2"
  case "$classification" in
    interactive_picker)
      # Short alias keeps the dedupe prefix in sync with bridge_stall_title.
      printf '[STALL/PICKER] %s ' "$agent"
      ;;
    *)
      printf '[STALL/%s] %s ' "${classification^^}" "$agent"
      ;;
  esac
}

bridge_stall_title() {
  local classification="$1"
  local agent="$2"
  case "$classification" in
    rate_limit)
      printf '[STALL/RATE_LIMIT] %s retry failed' "$agent"
      ;;
    auth)
      printf '[STALL/AUTH] %s requires re-authentication' "$agent"
      ;;
    network)
      printf '[STALL/NETWORK] %s retry failed' "$agent"
      ;;
    interactive_picker)
      printf '[STALL/PICKER] %s blocked on interactive picker' "$agent"
      ;;
    *)
      printf '[STALL/UNKNOWN] %s appears stuck' "$agent"
      ;;
  esac
}

bridge_stall_nudge_message() {
  local classification="$1"
  case "$classification" in
    rate_limit)
      printf '%s' "A rate-limit or capacity error was detected. Retry the current task now and continue from the current state."
      ;;
    network)
      printf '%s' "A transient network or provider error was detected. Retry the current task and continue if the connection is healthy now."
      ;;
    interactive_picker)
      # Never typed into the pane (picker would treat it as a stray keypress);
      # surfaces only in audit/report context strings.
      printf '%s' "An interactive picker is blocking the session. Routing to the admin agent for a keypress decision."
      ;;
    *)
      printf '%s' "The current task appears stalled. Check the current state, summarize what is blocking progress, and continue if work can proceed."
      ;;
  esac
}

bridge_stall_reason_label() {
  local classification="$1"
  case "$classification" in
    rate_limit) printf '%s' "rate-limit/capacity" ;;
    auth) printf '%s' "authentication/session" ;;
    network) printf '%s' "network/provider" ;;
    interactive_picker) printf '%s' "interactive-picker" ;;
    *) printf '%s' "unknown" ;;
  esac
}

bridge_stall_decode_excerpt() {
  local encoded="${1:-}"
  python3 - "$encoded" <<'PY'
import base64, sys
payload = sys.argv[1]
if not payload:
    raise SystemExit(0)
print(base64.b64decode(payload.encode("ascii")).decode("utf-8", errors="ignore"), end="")
PY
}

bridge_stall_recent_audits_markdown() {
  local agent="$1"
  python3 - "$BRIDGE_AUDIT_LOG" "$agent" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
agent = sys.argv[2]
rows = []
if path.is_file():
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            item = json.loads(raw)
        except Exception:
            continue
        detail = item.get("detail") or {}
        target = str(item.get("target") or "")
        if target == agent or str(detail.get("agent") or "") == agent:
            rows.append(item)
rows = rows[-2:]
if not rows:
    print("- none")
else:
    for item in rows:
        ts = str(item.get("ts") or "")
        action = str(item.get("action") or "unknown")
        print(f"- {action} @ {ts}")
PY
}

bridge_write_stall_report_body() {
  local agent="$1"
  local session="$2"
  local classification="$3"
  local idle="$4"
  local claimed="$5"
  local nudge_count="$6"
  local first_detected_ts="$7"
  local matched_pattern="$8"
  local excerpt="$9"
  local body_file="${10}"
  local recommended="${11}"
  local title_label=""
  local audits=""
  local first_detected_iso=""

  title_label="$(bridge_stall_reason_label "$classification")"
  audits="$(bridge_stall_recent_audits_markdown "$agent")"
  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout (5s — pure datetime formatting, no IO).
  first_detected_iso="$(bridge_with_timeout 5 stall_iso_format python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" stall-iso-format "$first_detected_ts")"
  mkdir -p "$(dirname "$body_file")"
  {
    echo "# Stall Report"
    echo
    echo "- agent: $agent"
    echo "- session: ${session:--}"
    echo "- classification: $classification"
    echo "- reason_label: $title_label"
    echo "- idle_seconds: $idle"
    echo "- claimed_count: $claimed"
    echo "- nudge_count: $nudge_count"
    echo "- first_detected_at: ${first_detected_iso:-$(bridge_now_iso)}"
    echo "- detected_at: $(bridge_now_iso)"
    if [[ -n "$matched_pattern" ]]; then
      echo "- matched_pattern: $matched_pattern"
    fi
    echo
    echo "## Recent Audit Events"
    echo
    printf '%s\n' "$audits"
    echo
    echo "## Recommended Next Action"
    echo
    echo "$recommended"
    echo
    echo "## Recent Output"
    echo
    echo '```text'
    printf '%s\n' "$excerpt"
    echo '```'
  } >"$body_file"
}

bridge_clear_stall_state() {
  local agent="$1"
  rm -f "$(bridge_agent_stall_state_file "$agent")"
}

bridge_note_stall_state() {
  local agent="$1"
  local classification="$2"
  local excerpt_hash="$3"
  local first_detected_ts="$4"
  local last_detected_ts="$5"
  local last_scan_ts="$6"
  local idle_seconds="$7"
  local claimed_count="$8"
  local nudge_count="$9"
  local last_nudge_ts="${10}"
  local escalated_ts="${11}"
  local task_id="${12}"
  local matched_pattern="${13:-}"
  # Issue #329 Track D: matched_line_hash is the stable dedup key. Persist it
  # alongside excerpt_hash so a daemon restart resumes the cap correctly.
  local matched_line_hash="${14:-}"
  local state_file

  state_file="$(bridge_agent_stall_state_file "$agent")"
  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
STALL_ACTIVE_CLASSIFICATION=$(printf '%q' "$classification")
STALL_ACTIVE_EXCERPT_HASH=$(printf '%q' "$excerpt_hash")
STALL_ACTIVE_MATCHED_LINE_HASH=$(printf '%q' "$matched_line_hash")
STALL_FIRST_DETECTED_TS=$(printf '%q' "$first_detected_ts")
STALL_LAST_DETECTED_TS=$(printf '%q' "$last_detected_ts")
STALL_LAST_SCAN_TS=$(printf '%q' "$last_scan_ts")
STALL_IDLE_SECONDS=$(printf '%q' "$idle_seconds")
STALL_CLAIMED_COUNT=$(printf '%q' "$claimed_count")
STALL_NUDGE_COUNT=$(printf '%q' "$nudge_count")
STALL_LAST_NUDGE_TS=$(printf '%q' "$last_nudge_ts")
STALL_ESCALATED_TS=$(printf '%q' "$escalated_ts")
STALL_TASK_ID=$(printf '%q' "$task_id")
STALL_MATCHED_PATTERN=$(printf '%q' "$matched_pattern")
EOF
}

bridge_send_stall_nudge() {
  local agent="$1"
  local session="$2"
  local engine="$3"
  local classification="$4"
  local text=""

  text="$(bridge_notification_text "stall detected" "$(bridge_stall_nudge_message "$classification")" "" normal)"
  bridge_tmux_send_and_submit "$session" "$engine" "$text" "$agent"
}

process_stall_reports() {
  local summary_output="${1:-}"
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local admin_available=0
  local now_ts=0
  local changed=1
  local agent=""
  local queued=0
  local claimed=0
  local blocked=0
  local active=0
  local idle=0
  local last_seen=0
  local last_nudge=0
  local session=""
  local engine=""
  local workdir=""
  local attached=0
  local loop_mode="0"
  local refresh_pending=0
  local state_file=""
  local had_state=0
  local active_classification=""
  local active_hash=""
  local active_matched_line_hash=""
  local first_detected_ts=0
  local last_detected_ts=0
  local last_scan_ts=0
  local nudge_count=0
  local last_nudge_ts=0
  local escalated_ts=0
  local task_id=""
  local matched_pattern=""
  local matched_line_hash=""
  local scan_interval="${BRIDGE_STALL_SCAN_INTERVAL_SECONDS:-30}"
  local explicit_idle="${BRIDGE_STALL_EXPLICIT_IDLE_SECONDS:-30}"
  local unknown_idle="${BRIDGE_STALL_UNKNOWN_IDLE_SECONDS:-900}"
  local max_nudges="${BRIDGE_STALL_MAX_NUDGES:-2}"
  local capture=""
  local analysis_shell=""
  local classification=""
  local excerpt_hash=""
  local excerpt_b64=""
  local excerpt=""
  local trigger_stall=0
  local retry_seconds=0
  local escalate_after=0
  local body_file=""
  local title=""
  local title_prefix=""
  local existing_id=""
  local create_output=""
  local recommended=""
  # Issue #329 Track D: composite dedup keys, recomputed each iteration.
  local current_dedup_key=""
  local prior_dedup_key=""
  # Footgun #11 (refs #815 Wave B): tempfile-route the summary loop, the
  # capture analyzer input, and the analyzer shell-output `source` call.
  local _summary_tmp="" _capture_tmp="" _shell_tmp=""
  _summary_tmp="$(mktemp)"
  _capture_tmp="$(mktemp)"
  _shell_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_summary_tmp' '$_capture_tmp' '$_shell_tmp'" RETURN

  [[ "${BRIDGE_STALL_SCAN_ENABLED:-1}" == "1" ]] || return 1
  if [[ -n "$admin_agent" ]] && bridge_agent_exists "$admin_agent"; then
    admin_available=1
  fi
  [[ "$scan_interval" =~ ^[0-9]+$ ]] || scan_interval=30
  [[ "$explicit_idle" =~ ^[0-9]+$ ]] || explicit_idle=30
  [[ "$unknown_idle" =~ ^[0-9]+$ ]] || unknown_idle=900
  [[ "$max_nudges" =~ ^[0-9]+$ ]] || max_nudges=2
  now_ts="$(date +%s)"

  printf '%s\n' "$summary_output" > "$_summary_tmp"

  while IFS=$'\t' read -r agent queued claimed blocked active idle last_seen last_nudge session engine workdir; do
    [[ -n "$agent" ]] || continue
    state_file="$(bridge_agent_stall_state_file "$agent")"
    had_state=0
    active_classification=""
    active_hash=""
    active_matched_line_hash=""
    first_detected_ts=0
    last_detected_ts=0
    last_scan_ts=0
    nudge_count=0
    last_nudge_ts=0
    escalated_ts=0
    task_id=""
    matched_pattern=""

    if [[ -f "$state_file" ]]; then
      if daemon_source_state_file "$state_file" "stall/$agent" 1 "STALL_LAST_SCAN_TS" \
          "STALL_ACTIVE_CLASSIFICATION STALL_ACTIVE_EXCERPT_HASH STALL_ACTIVE_MATCHED_LINE_HASH STALL_FIRST_DETECTED_TS STALL_LAST_DETECTED_TS STALL_NUDGE_COUNT STALL_LAST_NUDGE_TS STALL_ESCALATED_TS STALL_TASK_ID STALL_MATCHED_PATTERN"; then
        had_state=1
      fi
      active_classification="${STALL_ACTIVE_CLASSIFICATION:-}"
      active_hash="${STALL_ACTIVE_EXCERPT_HASH:-}"
      active_matched_line_hash="${STALL_ACTIVE_MATCHED_LINE_HASH:-}"
      first_detected_ts="${STALL_FIRST_DETECTED_TS:-0}"
      last_detected_ts="${STALL_LAST_DETECTED_TS:-0}"
      last_scan_ts="${STALL_LAST_SCAN_TS:-0}"
      nudge_count="${STALL_NUDGE_COUNT:-0}"
      last_nudge_ts="${STALL_LAST_NUDGE_TS:-0}"
      escalated_ts="${STALL_ESCALATED_TS:-0}"
      task_id="${STALL_TASK_ID:-}"
      matched_pattern="${STALL_MATCHED_PATTERN:-}"
    fi
    [[ "$first_detected_ts" =~ ^[0-9]+$ ]] || first_detected_ts=0
    [[ "$last_detected_ts" =~ ^[0-9]+$ ]] || last_detected_ts=0
    [[ "$last_scan_ts" =~ ^[0-9]+$ ]] || last_scan_ts=0
    [[ "$nudge_count" =~ ^[0-9]+$ ]] || nudge_count=0
    [[ "$last_nudge_ts" =~ ^[0-9]+$ ]] || last_nudge_ts=0
    [[ "$escalated_ts" =~ ^[0-9]+$ ]] || escalated_ts=0

    if (( scan_interval > 0 )) && (( last_scan_ts > 0 )) && (( now_ts - last_scan_ts < scan_interval )); then
      continue
    fi

    [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
    [[ "$claimed" =~ ^[0-9]+$ ]] || claimed=0
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
    refresh_pending=0
    bridge_agent_memory_daily_refresh_pending "$agent" && refresh_pending=1
    loop_mode="$(bridge_agent_loop "$agent")"

    trigger_stall=0
    classification=""
    matched_pattern=""
    excerpt_hash=""
    matched_line_hash=""
    excerpt_b64=""
    excerpt=""

    if [[ "$active" == "1" && -n "$session" ]] && bridge_tmux_session_exists "$session"; then
      attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf '0')"
      [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
      if (( attached == 0 )) && [[ "$engine" == "claude" || "$engine" == "codex" ]]; then
        # Issue #374: a loop=1 agent with no claimed work and no pending
        # refresh is genuinely idle -- there is nothing to be stalled on.
        # Skip the per-agent stall scan in this state to avoid classifier
        # false-positives on benign Claude UI text (transcript snippets,
        # tool-call results, system-reminder echoes, etc.) which were
        # repeatedly firing `[Agent Bridge]: stall detected` nudges every
        # 20-30 minutes against admin agents drained to inbox=empty.
        # Non-loop agents and loop agents with active work are unaffected;
        # the trigger_stall==0 cleanup path below still clears stale state.
        if [[ "$loop_mode" == "1" ]] && (( claimed == 0 && refresh_pending == 0 )); then
          :  # fall through to trigger_stall==0 handling
        elif (( claimed > 0 || refresh_pending == 1 )) || [[ "$loop_mode" == "1" ]]; then
          # Issue #264 r3: pass `join` so tmux capture-pane runs with `-J`.
          # Without -J, a long agent reply wraps onto multiple physical lines
          # and only the first carries the glyph prefix; classify() then
          # treats the wrapped continuation as raw provider output and the
          # self-loop returns. Other capture sites that feed classification
          # (context-pressure: bridge-daemon.sh:1583) already use `join`.
          capture="$(bridge_capture_recent "$session" "${BRIDGE_STALL_CAPTURE_LINES:-120}" join 2>/dev/null || true)"
          if [[ -n "$capture" ]]; then
            # Issue #265 proposal A: stall analyzer runs once per active agent
            # per cycle; a single hang would multiply across the roster on
            # every tick. Wrap so a stuck child cannot freeze the whole loop.
            printf '%s\n' "$capture" > "$_capture_tmp"
            analysis_shell="$(bridge_with_timeout "" stall_analyze python3 "$SCRIPT_DIR/bridge-stall.py" analyze --format shell < "$_capture_tmp" 2>/dev/null || true)"
            if [[ -n "$analysis_shell" ]]; then
              STALL_CLASSIFICATION=""
              STALL_MATCHED_PATTERN=""
              STALL_MATCHED_LINE_HASH=""
              STALL_EXCERPT_HASH=""
              STALL_EXCERPT_B64=""
              printf '%s\n' "$analysis_shell" > "$_shell_tmp"
              # shellcheck disable=SC1090
              source "$_shell_tmp"
              classification="${STALL_CLASSIFICATION:-}"
              matched_pattern="${STALL_MATCHED_PATTERN:-}"
              matched_line_hash="${STALL_MATCHED_LINE_HASH:-}"
              excerpt_hash="${STALL_EXCERPT_HASH:-}"
              excerpt_b64="${STALL_EXCERPT_B64:-}"
              excerpt="$(bridge_stall_decode_excerpt "$excerpt_b64")"
            fi
          fi
          # Issue #496: trust the classifier. The previous `unknown`-fallback
          # branch fired whenever (claimed > 0 && idle >= unknown_idle &&
          # excerpt_hash != "") even though the classifier had explicitly
          # returned an empty classification -- meaning no rate_limit, auth,
          # network, or interactive_picker pattern matched the captured pane.
          # Audit-log evidence on the affected host showed 29 spurious fires
          # across 2026-04-29..2026-04-30 against an attached `patch` admin,
          # all with classification=unknown, matched_line_hash="", and a
          # short-lived claimed=1 produced by per-10-min cron ticks
          # (librarian-watchdog, wiki-mention-scan, etc.) that briefly held
          # a queue task. The classifier patterns are deliberately narrow
          # (Issues #161, #264, #329 Track A) so an empty result should be
          # honored as a hard "not stalled" rather than overridden by a
          # heuristic that does not actually correlate with being stuck.
          # Real stalls (rate_limit, auth, network, interactive_picker)
          # still fire because the classifier still matches them.
          if [[ -n "$classification" ]] && (( idle >= explicit_idle )); then
            trigger_stall=1
          fi
        fi
      fi
    fi

    if (( trigger_stall == 0 )); then
      if (( had_state == 1 )); then
        bridge_audit_log daemon stall_recovered "$agent" \
          --detail classification="$active_classification" \
          --detail idle_seconds="$idle" \
          --detail claimed="$claimed"
        bridge_clear_stall_state "$agent"
        changed=0
      fi
      continue
    fi

    # Issue #329 Track D: dedup on matched_line_hash so a single false-positive
    # line in scrollback no longer re-fires every loop. excerpt_hash churns on
    # every idle tick because the captured pane window shifts; matched_line_hash
    # is stable as long as the offending line itself is. When the classifier
    # produced no matched line (unknown-classification idle stall), fall back
    # to the legacy excerpt_hash dedup so behavior there is unchanged.
    if [[ -n "$matched_line_hash" ]]; then
      current_dedup_key="line:$matched_line_hash"
    else
      current_dedup_key="excerpt:$excerpt_hash"
    fi
    if [[ -n "$active_matched_line_hash" ]]; then
      prior_dedup_key="line:$active_matched_line_hash"
    else
      prior_dedup_key="excerpt:$active_hash"
    fi
    if [[ "$active_classification" != "$classification" || "$current_dedup_key" != "$prior_dedup_key" ]]; then
      first_detected_ts="$now_ts"
      nudge_count=0
      last_nudge_ts=0
      escalated_ts=0
      task_id=""
      bridge_audit_log daemon stall_detected "$agent" \
        --detail classification="$classification" \
        --detail idle_seconds="$idle" \
        --detail queued="$queued" \
        --detail claimed="$claimed" \
        --detail excerpt_hash="$excerpt_hash" \
        --detail matched_line_hash="$matched_line_hash"
      changed=0
    fi

    last_detected_ts="$now_ts"
    retry_seconds="$(bridge_stall_retry_seconds "$classification")"
    [[ "$retry_seconds" =~ ^[0-9]+$ ]] || retry_seconds=0
    escalate_after="$(bridge_stall_escalate_after_seconds "$classification")"
    [[ "$escalate_after" =~ ^[0-9]+$ ]] || escalate_after=0

    if [[ "$classification" == "auth" || "$classification" == "interactive_picker" ]]; then
      if (( escalated_ts == 0 )); then
        title="$(bridge_stall_title "$classification" "$agent")"
        title_prefix="$(bridge_stall_title_prefix "$classification" "$agent")"
        if [[ "$classification" == "interactive_picker" ]]; then
          recommended="An interactive picker is blocking the agent's tmux pane. Inspect the captured output, choose a key for the safe default (Enter selects the first option — usually 'Stop and wait for limit to reset' or 'Resume from summary'), and send it via tmux send-keys. Escalate to the operator before choosing options that change billing or plan ('Switch to extra usage', 'Switch to Team plan')."
          notify_summary="Interactive picker is blocking ${agent}. The admin agent must choose a keypress (Enter for default) or escalate to the operator before any billing-impact option."
        else
          recommended="Manual repair is required. Re-authenticate the agent and restart the session once credentials are healthy."
          notify_summary="Authentication/session stall detected for ${agent}. Manual re-login is required."
        fi
        body_file="$(bridge_agent_stall_report_file "$agent" "$classification")"
        bridge_write_stall_report_body "$agent" "$session" "$classification" "$idle" "$claimed" "$nudge_count" "$first_detected_ts" "$matched_pattern" "$excerpt" "$body_file" "$recommended"
        if [[ "$agent" == "$admin_agent" ]] && bridge_agent_has_notify_transport "$admin_agent"; then
          bridge_notify_send "$admin_agent" "$title" "$notify_summary" "" urgent "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
          escalated_ts="$now_ts"
          bridge_audit_log daemon stall_escalated "$admin_agent" \
            --detail agent="$agent" \
            --detail classification="$classification" \
            --detail mode=direct_notify
          changed=0
        elif (( admin_available == 1 )); then
          existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
          if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
            bridge_queue_cli update "$existing_id" --actor daemon --title "$title" --priority urgent --body-file "$body_file" >/dev/null 2>&1 || true
            task_id="$existing_id"
          else
            create_output="$(bridge_queue_cli create --to "$admin_agent" --from daemon --priority urgent --title "$title" --body-file "$body_file" 2>/dev/null || true)"
            if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
              task_id="${BASH_REMATCH[1]}"
            fi
          fi
          if [[ -n "$task_id" ]]; then
            escalated_ts="$now_ts"
            bridge_audit_log daemon stall_escalated "$admin_agent" \
              --detail agent="$agent" \
              --detail classification="$classification" \
              --detail task_id="$task_id"
            changed=0
          fi
        fi
      fi
    else
      if (( nudge_count < max_nudges )) && (( nudge_count == 0 || now_ts - last_nudge_ts >= retry_seconds )); then
        if bridge_send_stall_nudge "$agent" "$session" "$engine" "$classification" >/dev/null 2>&1; then
          nudge_count=$((nudge_count + 1))
          last_nudge_ts="$now_ts"
          bridge_audit_log daemon stall_nudge_sent "$agent" \
            --detail classification="$classification" \
            --detail nudge_count="$nudge_count" \
            --detail idle_seconds="$idle"
          changed=0
        else
          bridge_audit_log daemon stall_nudge_suppressed "$agent" \
            --detail classification="$classification" \
            --detail nudge_count="$nudge_count" \
            --detail idle_seconds="$idle"
          changed=0
        fi
      fi

      if (( escalated_ts == 0 )) && (( nudge_count >= max_nudges )) && (( now_ts - first_detected_ts >= escalate_after )); then
        title="$(bridge_stall_title "$classification" "$agent")"
        title_prefix="$(bridge_stall_title_prefix "$classification" "$agent")"
        recommended="Inspect the stalled session, repair the root cause, and requeue or restart the work only after confirming the session can proceed."
        body_file="$(bridge_agent_stall_report_file "$agent" "$classification")"
        bridge_write_stall_report_body "$agent" "$session" "$classification" "$idle" "$claimed" "$nudge_count" "$first_detected_ts" "$matched_pattern" "$excerpt" "$body_file" "$recommended"
        if [[ "$agent" == "$admin_agent" ]] && bridge_agent_has_notify_transport "$admin_agent"; then
          bridge_notify_send "$admin_agent" "$title" "Persistent ${classification} stall detected for ${agent}. Manual intervention is required." "" urgent "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
          escalated_ts="$now_ts"
          bridge_audit_log daemon stall_escalated "$admin_agent" \
            --detail agent="$agent" \
            --detail classification="$classification" \
            --detail mode=direct_notify
          changed=0
        elif (( admin_available == 1 )); then
          existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
          if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
            bridge_queue_cli update "$existing_id" --actor daemon --title "$title" --priority urgent --body-file "$body_file" >/dev/null 2>&1 || true
            task_id="$existing_id"
          else
            create_output="$(bridge_queue_cli create --to "$admin_agent" --from daemon --priority urgent --title "$title" --body-file "$body_file" 2>/dev/null || true)"
            if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
              task_id="${BASH_REMATCH[1]}"
            fi
          fi
          if [[ -n "$task_id" ]]; then
            escalated_ts="$now_ts"
            bridge_audit_log daemon stall_escalated "$admin_agent" \
              --detail agent="$agent" \
              --detail classification="$classification" \
              --detail task_id="$task_id"
            changed=0
          fi
        fi
      fi
    fi

    bridge_note_stall_state "$agent" "$classification" "$excerpt_hash" "$first_detected_ts" "$last_detected_ts" "$now_ts" "$idle" "$claimed" "$nudge_count" "$last_nudge_ts" "$escalated_ts" "$task_id" "$matched_pattern" "$matched_line_hash"
  done < "$_summary_tmp"

  return "$changed"
}

bridge_permission_escalation_state_dir() {
  printf '%s/permission-escalations' "$BRIDGE_STATE_DIR"
}

bridge_permission_escalation_marker_file() {
  local task_id="$1"
  printf '%s/%s.ts' "$(bridge_permission_escalation_state_dir)" "$task_id"
}

# Fans out unclaimed [PERMISSION] tasks to the admin's human notify channel
# once they exceed BRIDGE_DAEMON_PERMISSION_TIMEOUT_SECONDS. Dedupes via a
# marker file so repeat sweeps do not re-notify.
process_permission_task_timeout_fanout() {
  local admin_agent
  admin_agent="$(bridge_admin_agent_id)"
  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1

  local timeout_seconds="${BRIDGE_DAEMON_PERMISSION_TIMEOUT_SECONDS:-${BRIDGE_PERMISSION_ESCALATION_TIMEOUT_SECONDS:-1800}}"
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=1800
  (( timeout_seconds > 0 )) || return 1

  # Issue #345 Track B (instance #5): the requesting agent's own
  # notify-target is the primary surface for permission decisions, since
  # the operator who owns the decision is closer to that agent than to
  # admin. Admin's notify is now a fallback used only when the requester
  # has no working transport. We therefore drop the prior "admin must
  # have transport" early gate — the per-row branch below decides which
  # surface (or both) gets the notify.
  local admin_has_notify=0
  if bridge_agent_has_notify_transport "$admin_agent"; then
    admin_has_notify=1
  fi

  local tasks_json
  tasks_json="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix '[PERMISSION] ' --all --format json 2>/dev/null || true)"
  [[ -n "$tasks_json" && "$tasks_json" != "[]" ]] || return 1

  local state_dir
  state_dir="$(bridge_permission_escalation_state_dir)"
  mkdir -p "$state_dir"

  local now_ts
  now_ts="$(date +%s)"
  local changed=1

  local expired_rows
  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout (5s — pure JSON filter, no IO).
  expired_rows="$(bridge_with_timeout 5 permission_expire_scan python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" permission-expire-scan "$tasks_json" "$now_ts" "$timeout_seconds" 2>/dev/null || true)"
  [[ -n "$expired_rows" ]] || return 1

  # Footgun #11 (refs #815 Wave B): route the expired_rows loop via tempfile.
  local _expired_tmp=""
  _expired_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_expired_tmp'" RETURN
  printf '%s\n' "$expired_rows" > "$_expired_tmp"

  local task_id age_seconds created_by status title marker age_minutes body_text
  local primary="" notify_target_agent="" requester_has_notify
  while IFS=$'\t' read -r task_id age_seconds created_by status title; do
    [[ "$task_id" =~ ^[0-9]+$ ]] || continue
    marker="$(bridge_permission_escalation_marker_file "$task_id")"
    if [[ -f "$marker" ]]; then
      continue
    fi

    age_minutes=$(( age_seconds / 60 ))
    body_text="[PERMISSION] task #${task_id} unclaimed for ${age_minutes}m — awaiting operator decision. Requested by ${created_by:-unknown}. Status: ${status}. Title: ${title}"

    # Primary path: requester's own notify-target. Falls back to admin
    # notify only when the requester has none (or is the admin itself).
    primary=""
    notify_target_agent=""
    requester_has_notify=0
    if [[ -n "$created_by" && "$created_by" != "$admin_agent" ]] \
        && bridge_agent_exists "$created_by" \
        && bridge_agent_has_notify_transport "$created_by"; then
      requester_has_notify=1
      primary="requester"
      notify_target_agent="$created_by"
    elif (( admin_has_notify == 1 )); then
      primary="admin"
      notify_target_agent="$admin_agent"
    fi

    if [[ -n "$notify_target_agent" ]]; then
      bridge_notify_send "$notify_target_agent" "Permission request timed out" "$body_text" "$task_id" urgent "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
    fi

    bridge_queue_cli update "$task_id" --actor daemon \
      --note "daemon-timeout-escalated (awaiting human) after ${age_minutes}m" >/dev/null 2>&1 || true

    bridge_audit_log daemon permission_task_timeout_escalated "$admin_agent" \
      --detail task_id="$task_id" \
      --detail age_seconds="$age_seconds" \
      --detail requested_by="${created_by:-unknown}" \
      --detail timeout_seconds="$timeout_seconds" \
      --detail primary="${primary:-none}"

    bridge_audit_log daemon permission_fanout "${created_by:-unknown}" \
      --detail task_id="$task_id" \
      --detail primary="${primary:-none}" \
      --detail requester_has_notify="$requester_has_notify" \
      --detail admin_has_notify="$admin_has_notify"

    printf '%s\n' "$now_ts" >"$marker"
    changed=0
  done < "$_expired_tmp"

  return "$changed"
}

bridge_clear_context_pressure_state() {
  local agent="$1"
  rm -f "$(bridge_agent_context_pressure_state_file "$agent")"
}

bridge_note_context_pressure_state() {
  local agent="$1"
  local severity="$2"
  local excerpt_hash="$3"
  local first_detected_ts="$4"
  local last_detected_ts="$5"
  local last_scan_ts="$6"
  local last_report_ts="$7"
  local matched_pattern="${8:-}"
  local state_file=""

  state_file="$(bridge_agent_context_pressure_state_file "$agent")"
  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
CONTEXT_PRESSURE_SEVERITY=$(printf '%q' "$severity")
CONTEXT_PRESSURE_EXCERPT_HASH=$(printf '%q' "$excerpt_hash")
CONTEXT_PRESSURE_FIRST_DETECTED_TS=$(printf '%q' "$first_detected_ts")
CONTEXT_PRESSURE_LAST_DETECTED_TS=$(printf '%q' "$last_detected_ts")
CONTEXT_PRESSURE_LAST_SCAN_TS=$(printf '%q' "$last_scan_ts")
CONTEXT_PRESSURE_LAST_REPORT_TS=$(printf '%q' "$last_report_ts")
CONTEXT_PRESSURE_MATCHED_PATTERN=$(printf '%q' "$matched_pattern")
EOF
}

process_context_pressure_reports() {
  local summary_output="${1:-}"
  local changed=1
  local now_ts=0
  local agent=""
  local queued=0
  local claimed=0
  local blocked=0
  local active=0
  local idle=0
  local last_seen=0
  local last_nudge=0
  local session=""
  local engine=""
  local workdir=""
  local state_file=""
  local had_state=0
  local previous_severity=""
  local previous_hash=""
  local first_detected_ts=0
  local last_detected_ts=0
  local last_scan_ts=0
  local last_report_ts=0
  local matched_pattern=""
  local scan_interval="${BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS:-60}"
  local capture=""
  local analysis_shell=""
  local severity=""
  local excerpt_hash=""
  local inactive=0
  # Footgun #11 (refs #815 Wave B): tempfile-route the summary loop, the
  # context-pressure analyzer capture input, and the analyzer shell-output.
  local _summary_tmp="" _capture_tmp="" _shell_tmp=""
  _summary_tmp="$(mktemp)"
  _capture_tmp="$(mktemp)"
  _shell_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_summary_tmp' '$_capture_tmp' '$_shell_tmp'" RETURN

  [[ "${BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED:-1}" == "1" ]] || return 1
  [[ "$scan_interval" =~ ^[0-9]+$ ]] || scan_interval=60
  now_ts="$(date +%s)"

  printf '%s\n' "$summary_output" > "$_summary_tmp"

  while IFS=$'\t' read -r agent queued claimed blocked active idle last_seen last_nudge session engine workdir; do
    [[ -n "$agent" ]] || continue
    state_file="$(bridge_agent_context_pressure_state_file "$agent")"
    had_state=0
    previous_severity=""
    previous_hash=""
    first_detected_ts=0
    last_detected_ts=0
    last_scan_ts=0
    last_report_ts=0
    matched_pattern=""

    if [[ -f "$state_file" ]]; then
      if daemon_source_state_file "$state_file" "context-pressure/$agent" 1 "CONTEXT_PRESSURE_LAST_SCAN_TS" \
          "CONTEXT_PRESSURE_SEVERITY CONTEXT_PRESSURE_EXCERPT_HASH CONTEXT_PRESSURE_FIRST_DETECTED_TS CONTEXT_PRESSURE_LAST_DETECTED_TS CONTEXT_PRESSURE_LAST_REPORT_TS CONTEXT_PRESSURE_MATCHED_PATTERN"; then
        had_state=1
      fi
      previous_severity="${CONTEXT_PRESSURE_SEVERITY:-}"
      previous_hash="${CONTEXT_PRESSURE_EXCERPT_HASH:-}"
      first_detected_ts="${CONTEXT_PRESSURE_FIRST_DETECTED_TS:-0}"
      last_detected_ts="${CONTEXT_PRESSURE_LAST_DETECTED_TS:-0}"
      last_scan_ts="${CONTEXT_PRESSURE_LAST_SCAN_TS:-0}"
      last_report_ts="${CONTEXT_PRESSURE_LAST_REPORT_TS:-0}"
      matched_pattern="${CONTEXT_PRESSURE_MATCHED_PATTERN:-}"
    fi
    [[ "$first_detected_ts" =~ ^[0-9]+$ ]] || first_detected_ts=0
    [[ "$last_detected_ts" =~ ^[0-9]+$ ]] || last_detected_ts=0
    [[ "$last_scan_ts" =~ ^[0-9]+$ ]] || last_scan_ts=0
    [[ "$last_report_ts" =~ ^[0-9]+$ ]] || last_report_ts=0
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0

    if (( scan_interval > 0 )) && (( last_scan_ts > 0 )) && (( now_ts - last_scan_ts < scan_interval )); then
      continue
    fi

    inactive=0
    if [[ "$active" != "1" || -z "$session" ]]; then
      inactive=1
    elif [[ "$engine" != "claude" && "$engine" != "codex" ]]; then
      inactive=1
    elif ! bridge_tmux_session_exists "$session"; then
      inactive=1
    fi

    if (( inactive == 1 )); then
      if (( had_state == 1 )); then
        bridge_audit_log daemon context_pressure_recovered "$agent" \
          --detail severity="$previous_severity" \
          --detail reason=session_inactive
        bridge_clear_context_pressure_state "$agent"
        changed=0
      fi
      continue
    fi

    capture="$(bridge_capture_recent "$session" "${BRIDGE_CONTEXT_PRESSURE_CAPTURE_LINES:-160}" join 2>/dev/null || true)"
    analysis_shell=""
    severity=""
    matched_pattern=""
    excerpt_hash=""
    if [[ -n "$capture" ]]; then
      # Issue #265 proposal A: same risk profile as the stall analyzer above
      # (per-agent per-cycle); cap subprocess time to keep the loop moving.
      printf '%s\n' "$capture" > "$_capture_tmp"
      analysis_shell="$(bridge_with_timeout "" context_pressure_analyze python3 "$SCRIPT_DIR/bridge-context-pressure.py" analyze --format shell --engine "$engine" < "$_capture_tmp" 2>/dev/null || true)"
      if [[ -n "$analysis_shell" ]]; then
        CONTEXT_PRESSURE_SEVERITY=""
        CONTEXT_PRESSURE_MATCHED_PATTERN=""
        CONTEXT_PRESSURE_EXCERPT_HASH=""
        printf '%s\n' "$analysis_shell" > "$_shell_tmp"
        # shellcheck disable=SC1090
        source "$_shell_tmp"
        severity="${CONTEXT_PRESSURE_SEVERITY:-}"
        matched_pattern="${CONTEXT_PRESSURE_MATCHED_PATTERN:-}"
        excerpt_hash="${CONTEXT_PRESSURE_EXCERPT_HASH:-}"
      fi
    fi

    if [[ -z "$severity" ]]; then
      if (( had_state == 1 )); then
        bridge_audit_log daemon context_pressure_recovered "$agent" \
          --detail severity="$previous_severity" \
          --detail reason=no_pattern
        bridge_clear_context_pressure_state "$agent"
        changed=0
      fi
      continue
    fi

    # Severity change is a real edge for telemetry: bump first_detected_ts and
    # write a fresh audit row. The daemon no longer emits [context-pressure]
    # tasks or direct admin notifications; setup-time native auto-compact is
    # the remediation path (issue #472/#473).
    if [[ "$previous_severity" != "$severity" ]]; then
      first_detected_ts="$now_ts"
      last_report_ts=0
      bridge_audit_log daemon context_pressure_detected "$agent" \
        --detail severity="$severity" \
        --detail excerpt_hash="$excerpt_hash" \
        --detail previous_severity="$previous_severity"
      changed=0
    elif [[ "$previous_hash" != "$excerpt_hash" ]]; then
      bridge_audit_log daemon context_pressure_detected "$agent" \
        --detail severity="$severity" \
        --detail excerpt_hash="$excerpt_hash" \
        --detail mode=hash_drift
      changed=0
    fi

    # Issue #419: dynamic agents are operator-managed. Keep the suppression
    # audit and clear state so first_detected_ts doesn't accumulate forever.
    local source_kind=""
    source_kind="$(bridge_agent_source "$agent")"
    if [[ "$source_kind" == "dynamic" ]]; then
      bridge_audit_log daemon context_pressure_suppressed "$agent" \
        --detail severity="$severity" \
        --detail reason=dynamic_agent_operator_managed \
        --detail excerpt_hash="$excerpt_hash"
      daemon_info "skipped context-pressure task for dynamic agent $agent (operator-managed)"
      bridge_clear_context_pressure_state "$agent"
      changed=0
      continue
    fi

    last_detected_ts="$now_ts"
    bridge_note_context_pressure_state "$agent" "$severity" "$excerpt_hash" "$first_detected_ts" "$last_detected_ts" "$now_ts" "$last_report_ts" "$matched_pattern"
  done < "$_summary_tmp"

  return "$changed"
}

bridge_watchdog_problem_key() {
  local report_json="$1"
  python3 - "$report_json" <<'PY'
import hashlib
import json
import sys

raw = sys.argv[1]
try:
    payload = json.loads(raw)
except Exception:
    print(hashlib.sha256(raw.encode("utf-8")).hexdigest() if raw else "")
    raise SystemExit(0)

agents = []
for item in payload.get("agents", []):
    if isinstance(item, dict):
        stable = dict(item)
        # Age advances every scan; keep heartbeat_present, but exclude the
        # volatile age value so unchanged drift dedupes correctly.
        stable.pop("heartbeat_age_seconds", None)
        agents.append(stable)
    else:
        agents.append(item)
canonical = json.dumps(agents, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest() if canonical else "")
PY
}

bridge_watchdog_due() {
  local interval="${BRIDGE_WATCHDOG_INTERVAL_SECONDS:-1800}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1800
  (( interval > 0 )) || return 0
  file="$(bridge_watchdog_state_file)"
  [[ -f "$file" ]] || return 0
  daemon_source_state_file "$file" "watchdog" 1 "WATCHDOG_NEXT_TS" || return 0
  [[ "${WATCHDOG_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  next_ts="${WATCHDOG_NEXT_TS:-0}"
  (( now >= next_ts ))
}

bridge_note_watchdog_scan() {
  local interval="${BRIDGE_WATCHDOG_INTERVAL_SECONDS:-1800}"
  local file=""
  local now=0
  local next_ts=0
  local last_key="${1:-}"
  local last_report_ts="${2:-0}"

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1800
  (( interval > 0 )) || interval=1800
  file="$(bridge_watchdog_state_file)"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
WATCHDOG_UPDATED_TS=$now
WATCHDOG_NEXT_TS=$next_ts
WATCHDOG_LAST_KEY=$(printf '%q' "$last_key")
WATCHDOG_LAST_REPORT_TS=$(printf '%q' "$last_report_ts")
EOF
}

process_watchdog_report() {
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local title_prefix="[watchdog] "
  local title="[watchdog] agent profile drift"
  local report_file=""
  local report_json=""
  local problem_count=0
  local existing_id=""
  local current_key=""
  local last_key=""
  local last_report_ts=0
  local cooldown=0
  local now_ts=0
  local reported=0

  [[ "${BRIDGE_WATCHDOG_ENABLED:-1}" == "1" ]] || return 1
  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1
  bridge_watchdog_due || return 1

  report_file="$(bridge_watchdog_report_file)"
  mkdir -p "$(dirname "$report_file")"
  if ! "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-watchdog.sh" scan >"$report_file"; then
    return 1
  fi
  if ! report_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-watchdog.sh" scan --json 2>/dev/null)"; then
    return 1
  fi
  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout (5s — single int extraction, no IO).
  problem_count="$(bridge_with_timeout 5 watchdog_problem_count python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" watchdog-problem-count "$report_json")"
  [[ "$problem_count" =~ ^[0-9]+$ ]] || problem_count=0
  current_key="$(bridge_watchdog_problem_key "$report_json")"
  cooldown="${BRIDGE_WATCHDOG_COOLDOWN_SECONDS:-86400}"
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=86400
  now_ts="$(date +%s)"
  if [[ -f "$(bridge_watchdog_state_file)" ]]; then
    daemon_source_state_file "$(bridge_watchdog_state_file)" "watchdog" 1 "WATCHDOG_LAST_REPORT_TS" || true
    last_key="${WATCHDOG_LAST_KEY:-}"
    last_report_ts="${WATCHDOG_LAST_REPORT_TS:-0}"
  fi
  [[ "$last_report_ts" =~ ^[0-9]+$ ]] || last_report_ts=0
  if (( problem_count == 0 )); then
    bridge_note_watchdog_scan "" 0
    return 1
  fi

  existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
  if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    if [[ "$current_key" != "$last_key" ]]; then
      bridge_queue_cli update "$existing_id" --actor "daemon" --title "$title" --priority high --body-file "$report_file" >/dev/null 2>&1 && reported=1
    fi
  elif [[ "$current_key" != "$last_key" || $(( now_ts - last_report_ts )) -ge "$cooldown" ]]; then
    bridge_queue_cli create --to "$admin_agent" --from "daemon" --priority high --title "$title" --body-file "$report_file" >/dev/null 2>&1 && reported=1
  fi

  if (( reported == 1 )); then
    bridge_audit_log daemon watchdog_report "$admin_agent" \
      --detail agent="$admin_agent" \
      --detail problem_count="$problem_count" \
      --detail report_file="$report_file"
    bridge_note_watchdog_scan "$current_key" "$now_ts"
    daemon_info "watchdog reported ${problem_count} agent profile issue(s)"
    return 0
  fi

  bridge_note_watchdog_scan "$last_key" "$last_report_ts"
  return 1
}

bridge_clear_crash_report_state() {
  local agent="$1"
  rm -f "$(bridge_agent_crash_state_file "$agent")"
}

bridge_write_crash_report_body() {
  local agent="$1"
  local body_file="$2"
  local fail_count="$3"
  local exit_code="$4"
  local engine="$5"
  local stderr_file="$6"
  local tail_file="$7"
  local launch_cmd="$8"
  local launch_cmd_display=""

  launch_cmd_display="$(bridge_redact_inline_env_secrets "$launch_cmd")"
  mkdir -p "$(dirname "$body_file")"
  {
    echo "# Crash Loop Report"
    echo
    echo "- agent: $agent"
    echo "- engine: $engine"
    echo "- fail_count: $fail_count"
    echo "- exit_code: $exit_code"
    echo "- stderr_file: ${stderr_file:--}"
    echo "- tail_file: ${tail_file:--}"
    echo "- detected_at: $(bridge_now_iso)"
    echo
    echo "## Launch Command"
    echo
    echo '```bash'
    printf '%s\n' "$launch_cmd_display"
    echo '```'
    echo
    echo "## Stderr Tail"
    echo
    echo '```text'
    if [[ -f "$tail_file" ]]; then
      cat "$tail_file"
    elif [[ -f "$stderr_file" ]]; then
      tail -n 50 "$stderr_file" 2>/dev/null || true
    fi
    echo '```'
  } >"$body_file"
}

process_crash_reports() {
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local report_file=""
  local agent=""
  local fail_count=0
  local exit_code=0
  local engine=""
  local stderr_file=""
  local tail_file=""
  local launch_cmd=""
  local error_hash=""
  local reported_at=""
  local state_file=""
  local last_hash=""
  local last_report_ts=0
  local ack_hash=""
  local ack_ts=0
  local now_ts=0
  local cooldown="${BRIDGE_CRASH_REPORT_COOLDOWN_SECONDS:-1800}"
  local body_file=""
  local title=""
  local title_prefix=""
  local existing_id=""
  local create_output=""
  local reported=1
  local changed=1

  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=1800

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    report_file="$(bridge_agent_crash_report_file "$agent")"
    [[ -f "$report_file" ]] || continue
    fail_count=0
    exit_code=0
    engine=""
    stderr_file=""
    tail_file=""
    launch_cmd=""
    error_hash=""
    reported_at=""
    daemon_source_state_file "$report_file" "crash-report/$agent" 1 "CRASH_AGENT" || continue
    agent="${CRASH_AGENT:-$agent}"
    [[ -n "$agent" ]] || continue
    if ! bridge_agent_exists "$agent"; then
      bridge_agent_clear_crash_report "$agent"
      continue
    fi
    # Issue #230-C: a manual-stop-armed agent is deliberately offline —
    # the operator has already acknowledged it (typically by closing the
    # original [crash-loop] task with a blocked/skip note). Re-reading
    # the stale crash report every sync cycle used to refresh state and
    # emit `crash_loop_report mode=refresh` audits with the same
    # error_hash indefinitely (17×/48h observed for pref-smoke). Skip
    # the entire detection path so nothing mutates, nothing re-audits.
    if bridge_agent_manual_stop_active "$agent"; then
      continue
    fi
    state_file="$(bridge_agent_crash_state_file "$agent")"
    last_hash=""
    last_report_ts=0
    ack_hash=""
    ack_ts=0
    if [[ -f "$state_file" ]]; then
      daemon_source_state_file "$state_file" "crash-state/$agent" 1 "CRASH_LAST_REPORT_TS" \
          "CRASH_LAST_HASH CRASH_ACK_HASH CRASH_ACK_TS" \
        || true
      last_hash="${CRASH_LAST_HASH:-}"
      last_report_ts="${CRASH_LAST_REPORT_TS:-0}"
      ack_hash="${CRASH_ACK_HASH:-}"
      ack_ts="${CRASH_ACK_TS:-0}"
    fi
    [[ "$last_report_ts" =~ ^[0-9]+$ ]] || last_report_ts=0
    [[ "$ack_ts" =~ ^[0-9]+$ ]] || ack_ts=0
    now_ts="$(date +%s)"
    fail_count="${CRASH_FAIL_COUNT:-0}"
    exit_code="${CRASH_EXIT_CODE:-0}"
    engine="${CRASH_ENGINE:-}"
    stderr_file="${CRASH_STDERR_FILE:-}"
    tail_file="${CRASH_TAIL_FILE:-}"
    launch_cmd="${CRASH_LAUNCH_CMD:-}"
    error_hash="${CRASH_ERROR_HASH:-}"
    reported=0

    if [[ "$agent" == "$admin_agent" ]]; then
      if [[ "$error_hash" != "$last_hash" || $(( now_ts - last_report_ts )) -ge "$cooldown" ]]; then
        body="Admin agent crash loop: ${agent} failed ${fail_count} times (exit ${exit_code}). Manual intervention may be required."
        if bridge_agent_has_notify_transport "$admin_agent"; then
          bridge_notify_send "$admin_agent" "Admin crash loop detected" "$body" "" urgent "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
        fi
        bridge_audit_log daemon crash_loop_admin_alert "$admin_agent" \
          --detail agent="$agent" \
          --detail engine="$engine" \
          --detail fail_count="$fail_count" \
          --detail exit_code="$exit_code" \
          --detail error_hash="$error_hash"
        reported=1
      fi
    elif bridge_agent_has_notify_transport "$agent"; then
      # Issue #345 Track B (instance #2): the affected agent's operator-attached
      # surface is closer to the human than admin's queue. Push the crash
      # report to the affected agent's own notify-target with one re-prod,
      # then idle. The admin agent has no special authority to repair a
      # per-agent crash, so the legacy admin-queue path is reserved for the
      # admin == affected case above (no other surface available) and for
      # affected agents with no notify transport (handled in the else branch).
      if [[ "$error_hash" != "$last_hash" || $(( now_ts - last_report_ts )) -ge "$cooldown" ]]; then
        body="Crash loop detected for ${agent}: ${fail_count} failures (exit ${exit_code}). Inspect the session and repair the root cause before relaunch."
        bridge_notify_send "$agent" "Crash loop detected" "$body" "" urgent "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
        bridge_audit_log daemon crash_notified_origin "$agent" \
          --detail target=affected-notify \
          --detail engine="$engine" \
          --detail fail_count="$fail_count" \
          --detail exit_code="$exit_code" \
          --detail error_hash="$error_hash"
        reported=1
      else
        bridge_audit_log daemon crash_notified_origin_suppressed "$agent" \
          --detail reason=cooldown \
          --detail fail_count="$fail_count" \
          --detail error_hash="$error_hash"
      fi
    else
      title="[crash-loop] ${agent} (${fail_count} failures)"
      title_prefix="[crash-loop] ${agent} "
      existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
      if [[ ! "$existing_id" =~ ^[0-9]+$ && -n "$ack_hash" && "$error_hash" == "$ack_hash" ]]; then
        :
      else
        body_file="$(bridge_agent_crash_report_body_file "$agent")"
        bridge_write_crash_report_body "$agent" "$body_file" "$fail_count" "$exit_code" "$engine" "$stderr_file" "$tail_file" "$launch_cmd"
        if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
          # Issue #204: refresh-mode used to fire every scan cycle regardless
          # of whether anything changed since the last refresh. If the admin
          # left the existing [crash-loop] task queued (the normal case until
          # they investigate), the daemon updated the same task body and
          # emitted a `crash_loop_report mode=refresh` audit every ~10 s with
          # an identical error_hash — inbox / audit.jsonl / notify transports
          # all saw duplicate noise on the same signal. Apply the same
          # `error_hash != last_hash || cooldown elapsed` guard the create
          # branch already uses, so a stable signal refreshes at most once
          # per cooldown window (default 1800 s).
          if [[ "$error_hash" == "$last_hash" && $(( now_ts - last_report_ts )) -lt "$cooldown" ]]; then
            :
          else
            bridge_queue_cli update "$existing_id" --actor daemon --title "$title" --priority urgent --body-file "$body_file" >/dev/null 2>&1 || true
            bridge_audit_log daemon crash_loop_report "$admin_agent" \
              --detail agent="$agent" \
              --detail mode=refresh \
              --detail fail_count="$fail_count" \
              --detail exit_code="$exit_code" \
              --detail error_hash="$error_hash" \
              --detail body_file="$body_file"
            reported=1
          fi
        elif [[ "$error_hash" != "$last_hash" || $(( now_ts - last_report_ts )) -ge "$cooldown" ]]; then
          create_output="$(bridge_queue_cli create --to "$admin_agent" --from daemon --priority urgent --title "$title" --body-file "$body_file" 2>/dev/null || true)"
          if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
            bridge_audit_log daemon crash_loop_report "$admin_agent" \
              --detail agent="$agent" \
              --detail mode=create \
              --detail task_id="${BASH_REMATCH[1]}" \
              --detail fail_count="$fail_count" \
              --detail exit_code="$exit_code" \
              --detail error_hash="$error_hash" \
              --detail body_file="$body_file"
            reported=1
          fi
        fi
      fi
    fi

    if (( reported == 1 )); then
      mkdir -p "$(dirname "$state_file")"
      cat >"$state_file" <<EOF
CRASH_LAST_HASH=$(printf '%q' "$error_hash")
CRASH_LAST_REPORT_TS=$(printf '%q' "$now_ts")
CRASH_ACK_HASH=$(printf '%q' "${ack_hash:-}")
CRASH_ACK_TS=$(printf '%q' "${ack_ts:-0}")
EOF
      changed=0
    fi
  done

  return "$changed"
}

bridge_daemon_autostart_state_file() {
  local agent="$1"
  printf '%s/daemon-autostart/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_daemon_autostart_allowed() {
  local agent="$1"
  local file=""
  local next_retry_ts=0
  local now=0

  # #256 Gap 2: a `broken-launch` state file means `bridge-run.sh` tripped
  # its rapid-fail circuit breaker on this agent. The daemon must stop
  # relaunching until an operator clears the quarantine with `agent-bridge
  # agent start <agent>` / `safe-mode <agent>` / `restart <agent>`. Before
  # this gate was wired, the daemon's 1s post-start liveness heuristic saw
  # a session that was still inside claude's ~5–10s startup window, called
  # `bridge_daemon_clear_autostart_failure`, then relaunched on the next
  # reconcile tick — reproducing 137 cycles in 2h13m on the reference
  # host during the #254 crash loop.
  if [[ -f "$(bridge_agent_broken_launch_file "$agent")" ]]; then
    return 1
  fi

  file="$(bridge_daemon_autostart_state_file "$agent")"
  [[ -f "$file" ]] || return 0
  daemon_source_state_file "$file" "autostart/$agent" 1 "AUTO_START_NEXT_RETRY_TS" || return 0
  [[ "${AUTO_START_NEXT_RETRY_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  next_retry_ts="${AUTO_START_NEXT_RETRY_TS:-0}"
  now="$(date +%s)"
  (( now >= next_retry_ts ))
}

bridge_daemon_note_autostart_failure() {
  local agent="$1"
  local reason="$2"
  local file=""
  local fail_count=0
  local next_retry_ts=0
  local delay=5
  local now=0

  file="$(bridge_daemon_autostart_state_file "$agent")"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    daemon_source_state_file "$file" "autostart/$agent" 1 "AUTO_START_NEXT_RETRY_TS" \
        "AUTO_START_FAIL_COUNT AUTO_START_LAST_REASON" \
      || true
  else
    # No state file means a fresh agent or a cleared backoff — wipe any
    # AUTO_START_* values left over from a different agent in this same
    # daemon process so the new fail_count counter starts at 0. (#576 r3)
    unset AUTO_START_FAIL_COUNT AUTO_START_NEXT_RETRY_TS AUTO_START_LAST_REASON
  fi
  AUTO_START_FAIL_COUNT="${AUTO_START_FAIL_COUNT:-0}"
  [[ "$AUTO_START_FAIL_COUNT" =~ ^[0-9]+$ ]] || AUTO_START_FAIL_COUNT=0
  fail_count=$(( AUTO_START_FAIL_COUNT + 1 ))
  now="$(date +%s)"
  if (( fail_count >= 10 )); then
    delay=300
  elif (( fail_count >= 5 )); then
    delay=60
  elif (( fail_count >= 3 )); then
    delay=30
  fi
  next_retry_ts=$(( now + delay ))
  cat >"$file" <<EOF
AUTO_START_FAIL_COUNT=$fail_count
AUTO_START_NEXT_RETRY_TS=$next_retry_ts
AUTO_START_LAST_REASON=$(printf '%q' "$reason")
EOF
  daemon_info "auto-start backoff ${agent} (failures=${fail_count}, retry_in=${delay}s, reason=${reason})"
}

bridge_daemon_clear_autostart_failure() {
  local agent="$1"
  rm -f "$(bridge_daemon_autostart_state_file "$agent")"
}

bridge_dashboard_post_if_changed() {
  local summary_output="$1"
  local summary_file

  [[ -n "$BRIDGE_DASHBOARD_WEBHOOK_URL" ]] || return 0
  [[ -n "$summary_output" ]] || return 0

  summary_file="$(mktemp)"
  printf '%s\n' "$summary_output" >"$summary_file"

  bridge_require_python
  # Issue #265 proposal A: dashboard post issues an outbound HTTP request to
  # the configured webhook URL; a hung handshake or unreachable host would
  # otherwise block the daemon's main-loop tail. Wrap so it can never freeze
  # the scheduler.
  bridge_with_timeout "" dashboard_post python3 "$SCRIPT_DIR/bridge-dashboard.py" \
    --summary-tsv "$summary_file" \
    --state-file "$BRIDGE_DASHBOARD_STATE_FILE" \
    --webhook-url "$BRIDGE_DASHBOARD_WEBHOOK_URL" \
    --roster-tsv "$BRIDGE_ACTIVE_ROSTER_TSV" \
    --task-db "$BRIDGE_TASK_DB" \
    --idle-threshold-seconds "$BRIDGE_DASHBOARD_IDLE_SECONDS" \
    --summary-interval-seconds "$BRIDGE_DASHBOARD_SUMMARY_SECONDS" \
    >/dev/null 2>&1 || true

  rm -f "$summary_file"
}

nudge_agent_session() {
  local agent="$1"
  local _session="$2"
  local queued="$3"
  local claimed="$4"
  local idle="$5"
  local nudge_key="${6:-}"
  local live_state=""
  local live_queued="$queued"
  local live_claimed="$claimed"
  local live_nudge_key="$nudge_key"
  local title
  local message
  local status=0
  local open_task_shell=""
  local task_id=""
  local task_title=""
  local task_priority=""
  local task_status=""

  # Issue #800 Track A (highest-impact site): heredoc-stdin → helper subcommand
  # wrapped by bridge_with_timeout. 15s ceiling — the live-state query is on
  # the per-agent nudge hot path, so a long wait here stalls every subsequent
  # agent in the loop. On timeout (rc=124) we emit an explicit per-agent
  # daemon_subprocess_timeout audit row (the wrapper already writes a
  # generic one without target=$agent context) and skip nudging THIS agent
  # on THIS tick. The next tick retries naturally; if the timeout pattern
  # persists the per-agent audit rows accumulate so the operator can see
  # which agent's DB row keeps wedging the query. We do NOT propagate
  # failure to siblings — the wedge documented in #800 is per-query, not
  # per-loop, so other agents in the scan should still get nudged.
  local live_state_rc=0
  set +e
  live_state="$(bridge_with_timeout 15 nudge_live_state python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" nudge-live-state "$BRIDGE_TASK_DB" "$agent" 2>/dev/null)"
  live_state_rc=$?
  set -e
  if (( live_state_rc == 124 || live_state_rc == 137 )); then
    bridge_audit_log daemon daemon_subprocess_timeout "$agent" \
      --detail call_site=nudge_live_state \
      --detail target_agent="$agent" \
      --detail timeout_seconds=15 \
      --detail exit_code="$live_state_rc" \
      --detail action=skip_this_tick
    daemon_warn "nudge live-state query for ${agent} timed out (rc=${live_state_rc}); skipping nudge this tick"
    return 0
  fi
  if [[ -n "$live_state" ]]; then
    IFS=$'\t' read -r live_queued live_claimed live_nudge_key <<<"$live_state"
  else
    live_queued=0
    live_claimed=0
    live_nudge_key=""
  fi
  [[ "$live_queued" =~ ^[0-9]+$ ]] || live_queued=0
  [[ "$live_claimed" =~ ^[0-9]+$ ]] || live_claimed=0

  if (( live_queued <= 0 )); then
    bridge_audit_log daemon session_nudge_dropped_stale "$agent" \
      --detail queued_snapshot="$queued" \
      --detail claimed_snapshot="$claimed" \
      --detail queued_live="$live_queued" \
      --detail claimed_live="$live_claimed"
    daemon_info "skipped stale nudge for ${agent} (snapshot queued=${queued}, live queued=${live_queued})"
    return 0
  fi

  title="$(bridge_queue_attention_title "$live_queued")"
  open_task_shell="$(bridge_queue_cli find-open --agent "$agent" --format shell 2>/dev/null || true)"
  if [[ -n "$open_task_shell" ]]; then
    # Footgun #11 (refs #815 Wave B): tempfile-route the `source` of the
    # find-open shell output to avoid sourcing /dev/stdin heredoc_write.
    local _open_task_tmp=""
    _open_task_tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f -- '$_open_task_tmp'" RETURN
    printf '%s\n' "$open_task_shell" > "$_open_task_tmp"
    # shellcheck disable=SC1090
    source "$_open_task_tmp"
  fi
  task_status="${TASK_STATUS:-}"
  if [[ "$task_status" == "queued" && -n "$TASK_ID" && -n "$TASK_TITLE" ]]; then
    task_id="$TASK_ID"
    task_title="$TASK_TITLE"
    task_priority="${TASK_PRIORITY:-normal}"
  fi

  message="$(bridge_queue_attention_message "$agent" "$live_queued" "$task_id" "$task_priority" "$task_title")"
  if ! bridge_dispatch_notification "$agent" "$title" "$message" "" "normal"; then
    status=$?
    if [[ "$status" == "2" ]]; then
      return 2
    fi
    return 1
  fi
  bridge_task_note_nudge "$agent" "${live_nudge_key:-$nudge_key}" || true

  # Issue #331 Track A: bridge_dispatch_notification's success only proves the
  # tmux paste/submit helper returned 0 — it does not prove the codex/claude
  # composer actually consumed the C-m. Codex agents have a real race where
  # the paste lands and C-m fires but the placeholder lifecycle eats the
  # submission, leaving the task `queued` while the daemon logs
  # session_nudge_sent. Use the queue itself as the delivery oracle: a
  # successful nudge causes the agent to claim within ~1s; if the task is
  # still queued after $BRIDGE_NUDGE_VERIFY_GRACE_SECONDS (default 2s), flip
  # the audit row to session_nudge_dropped and return non-zero so the next
  # idle-nudge tick (post-cooldown) retries instead of leaving a stale
  # success on the audit log. We do NOT retry inline — a tight loop on a
  # sticky tmux race wastes ticks. Skip when we have no task_id to verify.
  local nudge_grace_seconds="${BRIDGE_NUDGE_VERIFY_GRACE_SECONDS:-2}"
  local post_status=""
  if [[ -n "$task_id" ]]; then
    if [[ "$nudge_grace_seconds" =~ ^[0-9]+$ ]] && (( nudge_grace_seconds > 0 )); then
      sleep "$nudge_grace_seconds"
    fi
    post_status="$(bridge_queue_task_status "$task_id" 2>/dev/null || true)"
    if [[ "$post_status" == "queued" ]]; then
      bridge_audit_log daemon session_nudge_dropped "$agent" \
        --detail task_id="$task_id" \
        --detail reason=submit_lost_post_grace \
        --detail grace_seconds="$nudge_grace_seconds" \
        --detail queued="$live_queued" \
        --detail claimed="$live_claimed" \
        --detail idle_seconds="$idle" \
        --detail title="$title"
      daemon_info "nudge to ${agent} appears dropped (task #${task_id} still queued after ${nudge_grace_seconds}s); will retry on next idle-nudge tick"
      return 1
    fi
  fi

  bridge_audit_log daemon session_nudge_sent "$agent" \
    --detail queued="$live_queued" \
    --detail claimed="$live_claimed" \
    --detail idle_seconds="$idle" \
    --detail task_id="${task_id:-0}" \
    --detail post_status="${post_status:-unknown}" \
    --detail title="$title"
  daemon_info "nudged ${agent} (queued=${live_queued}, claimed=${live_claimed}, idle=${idle}s)"
}

reconcile_prompt_ready_latches() {
  # Issue #589: daemon-poll branch of the prompt-ready latch (Option C).
  # During each sync cycle, for each active agent without a recorded
  # prompt-ready marker, capture the recent pane text and check whether
  # the engine's prompt is showing. If so, write the latch via the
  # daemon-poll source label so the auto-stop idle anchor in
  # bridge-queue.py:_latched_idle_seconds can use it. This is the
  # fallback for agents that booted but haven't received an inject yet
  # (so the send-path latch hasn't fired).
  #
  # Audit volume note (Open Q3): only the daemon-poll path emits an
  # audit row. The send-path latch fires on every successful inject, so
  # auditing it would inflate volume on a healthy install — and the
  # consumer side (auto-stop decision) is already audited separately.
  local agent
  local engine
  local session
  local recent
  local existing
  local marker_file

  if [[ "${BRIDGE_DAEMON_IDLE_LATCH_DISABLED:-0}" == "1" ]]; then
    return 0
  fi

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    engine="$(bridge_agent_engine "$agent")"
    [[ -n "$engine" ]] || continue
    # The latch is only meaningful for engines that have a prompt concept.
    # bridge_tmux_engine_requires_prompt returns 0 (success) for engines
    # that DO require a prompt (claude/codex) and 1 for engines that don't.
    # Latch only when it returns 0; otherwise skip — the agent doesn't have
    # a prompt-ready concept to observe.
    if bridge_tmux_engine_requires_prompt "$engine"; then
      :
    else
      continue
    fi
    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue

    marker_file="$(bridge_agent_prompt_ready_file "$agent")"
    if [[ -f "$marker_file" ]]; then
      existing="$(grep '^PROMPT_READY_SESSION=' "$marker_file" 2>/dev/null | head -n1 | cut -d= -f2-)"
      if [[ -n "$existing" && "$existing" == "$session" ]]; then
        # Already latched for this session — nothing to do.
        continue
      fi
    fi

    recent="$(bridge_capture_recent "$session" 20 2>/dev/null || true)"
    [[ -n "$recent" ]] || continue
    if bridge_tmux_session_has_prompt_from_text "$engine" "$recent"; then
      bridge_agent_note_prompt_ready "$agent" daemon-poll || true
      bridge_audit_log daemon prompt_ready_latched "$agent" \
        --detail engine="$engine" \
        --detail session="$session" \
        --detail source=daemon-poll
    fi
  done
}

flush_pending_attention_spools() {
  # Issue #132a: per-sync-pass flush of the per-agent pending-attention spool.
  # Covers every engine that the tmux inject gate applies to (claude + codex)
  # so a busy Codex session does not permanently accumulate entries either.
  # The flush itself is bounded by the spool size and skips over agents with
  # empty spools in O(1).
  local agent=""
  local session=""
  local engine=""
  local count=0

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    engine="$(bridge_agent_engine "$agent")"
    [[ -n "$engine" ]] || continue
    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue
    count="$(bridge_tmux_pending_attention_count "$agent" 2>/dev/null || printf '0')"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    (( count > 0 )) || continue
    bridge_tmux_pending_attention_flush "$session" "$engine" "$agent" >/dev/null 2>&1 || true
  done
}

recover_claude_bootstrap_blockers() {
  local agent
  local session
  local state=""

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue

    state="$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || true)"
    case "$state" in
      trust|summary)
        if bridge_tmux_prepare_claude_session "$session" 6 >/dev/null 2>&1; then
          daemon_info "advanced claude startup blocker for ${agent} (${state})"
        else
          bridge_warn "failed to advance claude startup blocker for '${agent}' (${state})"
        fi
        ;;
    esac
  done
}

bridge_channel_health_state_file() {
  local agent="$1"
  printf '%s/channel-health/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_channel_health_body_file() {
  local agent="$1"
  printf '%s/channel-health/%s.md' "$BRIDGE_SHARED_DIR" "$agent"
}

bridge_write_channel_health_body() {
  local agent="$1"
  local file="$2"
  local required_channels=""
  local reason=""
  local session=""
  local workdir=""

  required_channels="$(bridge_agent_channels_csv "$agent")"
  reason="$(bridge_agent_channel_status_reason "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"

  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
# Channel Health Alert

- agent: ${agent}
- engine: $(bridge_agent_engine "$agent")
- session: ${session:--}
- workdir: ${workdir:--}
- required_channels: ${required_channels:-(unset)}
- detected_at: $(bridge_now_iso)

## Reason

${reason:-unknown channel health mismatch}

## Channel Diagnostics

$(bridge_agent_channel_diagnostics_text "$agent")

## ACL state

$(bridge_agent_channel_acl_diagnostics_text "$agent")

## Session Health

$(bridge_agent_session_guidance_text "$agent")

## Suggested next steps

1. Run \`agent-bridge setup agent ${agent}\`
2. Inspect \`agent-bridge status --all-agents\`
3. Restart the agent with \`bash bridge-start.sh ${agent} --replace\` after fixing the channel config
EOF
}

bridge_clear_channel_health_state() {
  local agent="$1"
  rm -f "$(bridge_channel_health_state_file "$agent")"
}

bridge_report_channel_health_miss() {
  local agent="$1"
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local status=""
  local reason=""
  local key=""
  local now_ts=""
  local state_file=""
  local body_file=""
  local last_key=""
  local last_report_ts=0
  local cooldown="${BRIDGE_CHANNEL_HEALTH_REPORT_COOLDOWN_SECONDS:-1800}"
  local fallback_used=0
  local notify_body=""

  [[ -n "$admin_agent" ]] || return 0
  bridge_agent_exists "$admin_agent" || return 0
  [[ "$admin_agent" != "$agent" ]] || return 0

  status="$(bridge_agent_channel_status "$agent")"
  # Issue #832: `unknown` (controller-blind) is an indeterminate readiness,
  # not a confirmed mismatch. Treat it like `ok`/`-` for audit purposes —
  # do NOT fire a channel_health_miss row, and clear any stale state so we
  # do not leak a "still firing" signal once the operator fixes ACLs.
  if [[ "$status" != "miss" ]]; then
    bridge_clear_channel_health_state "$agent"
    return 0
  fi

  reason="$(bridge_agent_channel_status_reason "$agent")"
  [[ -n "$reason" ]] || reason="unknown channel health mismatch"
  key="$(bridge_sha1 "${agent}|${reason}|$(bridge_agent_channels_csv "$agent")")"
  now_ts="$(date +%s)"
  state_file="$(bridge_channel_health_state_file "$agent")"
  body_file="$(bridge_channel_health_body_file "$agent")"

  if [[ -f "$state_file" ]]; then
    daemon_source_state_file "$state_file" "channel-health/$agent" 1 "LAST_REPORT_TS" \
        "LAST_KEY" \
      || true
    last_key="${LAST_KEY:-}"
    last_report_ts="${LAST_REPORT_TS:-0}"
  fi
  [[ "$last_report_ts" =~ ^[0-9]+$ ]] || last_report_ts=0
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=1800

  # Issue #345 Track B (instance #3): channel-health miss is a per-agent
  # surface problem. The admin agent has no authority over the affected
  # agent's tokens or channel binding, so dumping a task into admin's queue
  # only generates noise. Try to surface to the affected agent's own
  # notify transport when available (fallback path); otherwise emit an
  # audit row + dashboard flag and let `agent-bridge status` carry the
  # config-drift counter. Never enqueue an admin task for this case.
  if [[ "$key" == "$last_key" && $(( now_ts - last_report_ts )) -lt "$cooldown" ]]; then
    return 0
  fi

  bridge_write_channel_health_body "$agent" "$body_file"

  if bridge_agent_has_notify_transport "$agent"; then
    notify_body="Channel health mismatch detected for ${agent}: ${reason}. Repair the affected channel binding and rerun \`agent-bridge agent show ${agent}\` to confirm."
    bridge_notify_send "$agent" "Channel health mismatch" "$notify_body" "" urgent "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:-0}" >/dev/null 2>&1 || true
    fallback_used=1
  fi

  bridge_audit_log daemon channel_health_miss "$agent" \
    --detail surface="$(bridge_agent_channels_csv "$agent")" \
    --detail reason="$reason" \
    --detail body_file="$body_file" \
    --detail fallback_used="$fallback_used" \
    --detail dashboard_flag=1

  if (( fallback_used == 1 )); then
    daemon_info "channel-health miss for ${agent} surfaced via affected-notify (reason=${reason})"
  else
    daemon_info "channel-health miss for ${agent} recorded as audit + dashboard flag (reason=${reason})"
  fi

  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
LAST_KEY=$(printf '%q' "$key")
LAST_REPORT_TS=$(printf '%q' "$now_ts")
EOF
}

bridge_plugin_liveness_state_file() {
  local agent="$1"
  printf '%s/plugin-liveness/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_clear_plugin_liveness_state() {
  local agent="$1"
  rm -f "$(bridge_plugin_liveness_state_file "$agent")"
}

bridge_note_plugin_liveness_state() {
  local agent="$1"
  local last_key="$2"
  local last_detected_ts="$3"
  local last_restart_ts="$4"
  # Optional 5th positional: cumulative restart-attempt count for this key.
  # Older state files (pre-#715-A) omit this field; callers default to 0.
  local restart_attempts="${5:-0}"
  local state_file=""

  [[ "$restart_attempts" =~ ^[0-9]+$ ]] || restart_attempts=0
  state_file="$(bridge_plugin_liveness_state_file "$agent")"
  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
LAST_KEY=$(printf '%q' "$last_key")
LAST_DETECTED_TS=$(printf '%q' "$last_detected_ts")
LAST_RESTART_TS=$(printf '%q' "$last_restart_ts")
RESTART_ATTEMPTS=$(printf '%q' "$restart_attempts")
EOF
}

bridge_report_plugin_liveness_miss() {
  local agent="$1"
  local session=""
  local attached=0
  local required=""
  local missing=""
  local restart_output=""
  local key=""
  local now_ts=0
  local cooldown="${BRIDGE_PLUGIN_LIVENESS_RESTART_COOLDOWN_SECONDS:-60}"
  # Issue #715 A — bound the restart loop. When the missing-channel set is
  # rooted in operator config (relay token absent, teams unprovisioned, etc.)
  # the channel CSV never recovers from a daemon-side restart, so the agent
  # gets killed every cooldown window forever. Cap consecutive restart
  # attempts per (agent, missing-CSV) key; once the cap is hit, audit a
  # giveup entry once and stop restarting until the CSV changes (i.e., the
  # operator changed something).
  local max_restarts="${BRIDGE_PLUGIN_LIVENESS_MAX_RESTARTS:-5}"
  local state_file=""
  local last_key=""
  local last_detected_ts=0
  local last_restart_ts=0
  local restart_attempts=0

  [[ "${BRIDGE_SKIP_PLUGIN_LIVENESS:-0}" != "1" ]] || return 1
  [[ "$(bridge_agent_source "$agent")" == "static" ]] || return 0
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  [[ "$(bridge_agent_channel_status "$agent")" == "ok" ]] || {
    bridge_clear_plugin_liveness_state "$agent"
    return 0
  }

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || {
    bridge_clear_plugin_liveness_state "$agent"
    return 0
  }
  bridge_tmux_session_exists "$session" || {
    bridge_clear_plugin_liveness_state "$agent"
    return 0
  }

  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    bridge_clear_plugin_liveness_state "$agent"
    return 0
  }

  missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent" || true)"
  if [[ -z "$missing" ]]; then
    bridge_clear_plugin_liveness_state "$agent"
    return 0
  fi

  key="$(bridge_sha1 "${agent}|${missing}")"
  now_ts="$(date +%s)"
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=60
  [[ "$max_restarts" =~ ^[0-9]+$ ]] || max_restarts=5
  state_file="$(bridge_plugin_liveness_state_file "$agent")"
  if [[ -f "$state_file" ]]; then
    daemon_source_state_file "$state_file" "plugin-liveness/$agent" 1 "LAST_DETECTED_TS" \
        "LAST_KEY LAST_RESTART_TS RESTART_ATTEMPTS" \
      || true
    last_key="${LAST_KEY:-}"
    last_detected_ts="${LAST_DETECTED_TS:-0}"
    last_restart_ts="${LAST_RESTART_TS:-0}"
    restart_attempts="${RESTART_ATTEMPTS:-0}"
  fi
  [[ "$last_detected_ts" =~ ^[0-9]+$ ]] || last_detected_ts=0
  [[ "$last_restart_ts" =~ ^[0-9]+$ ]] || last_restart_ts=0
  [[ "$restart_attempts" =~ ^[0-9]+$ ]] || restart_attempts=0

  # If the operator changed something (different missing-channel CSV), reset
  # the attempt counter so we get another full restart budget against the new
  # symptom. Same key on a subsequent miss => stay in the same cycle.
  if [[ "$key" != "$last_key" ]]; then
    restart_attempts=0
  fi

  attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf '0')"
  [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
  if (( attached > 0 )); then
    if [[ "$key" != "$last_key" ]]; then
      bridge_audit_log daemon plugin_mcp_liveness_attached_skip "$agent" \
        --detail missing_channels="$missing" \
        --detail session="$session"
      daemon_info "plugin MCP liveness miss on attached session ${agent} (${missing})"
    fi
    bridge_note_plugin_liveness_state "$agent" "$key" "$now_ts" "$last_restart_ts" "$restart_attempts"
    return 0
  fi

  # Giveup short-circuit. attempts >= max means we already burned our budget
  # for this missing-CSV key. Emit the giveup audit + daemon_info exactly once
  # (the "first entry" — attempts == max), then bump to max+1 as a sentinel so
  # subsequent ticks return silently until the CSV (and thus the key) changes.
  if (( restart_attempts >= max_restarts )); then
    if (( restart_attempts == max_restarts )); then
      bridge_audit_log daemon plugin_mcp_liveness_giveup "$agent" \
        --detail missing_channels="$missing" \
        --detail attempts="$restart_attempts" \
        --detail max_restarts="$max_restarts" \
        --detail session="$session"
      daemon_info "plugin MCP liveness restart limit reached for ${agent} (${missing}); skipping until channel CSV changes"
      restart_attempts=$((max_restarts + 1))
    fi
    bridge_note_plugin_liveness_state "$agent" "$key" "$now_ts" "$last_restart_ts" "$restart_attempts"
    return 0
  fi

  if [[ "$key" == "$last_key" ]] && (( last_restart_ts > 0 )) && (( now_ts - last_restart_ts < cooldown )); then
    bridge_note_plugin_liveness_state "$agent" "$key" "$now_ts" "$last_restart_ts" "$restart_attempts"
    return 0
  fi

  # Cooldown elapsed (or first miss on this key). Count this as a restart
  # attempt before invoking, so a failed restart still consumes budget — the
  # whole point is to bound work against an unrecoverable operator-config
  # state.
  restart_attempts=$((restart_attempts + 1))

  # Preserve the role's configured continue policy. For static Claude roles,
  # forcing --no-continue here destroys the session continuity that the roster
  # or persisted history would otherwise restore.
  if restart_output="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" agent restart "$agent" 2>&1)"; then
    bridge_audit_log daemon plugin_mcp_liveness_restart "$agent" \
      --detail missing_channels="$missing" \
      --detail session="$session" \
      --detail attempts="$restart_attempts" \
      --detail max_restarts="$max_restarts"
    daemon_info "restarted ${agent} after plugin MCP liveness miss (${missing}) [attempt ${restart_attempts}/${max_restarts}]"
    last_restart_ts="$now_ts"
  else
    restart_output="${restart_output//$'\n'/ }"
    restart_output="$(bridge_trim_whitespace "$restart_output")"
    if [[ ${#restart_output} -gt 400 ]]; then
      restart_output="${restart_output:0:400}..."
    fi
    bridge_audit_log daemon plugin_mcp_liveness_restart_failed "$agent" \
      --detail missing_channels="$missing" \
      --detail session="$session" \
      --detail attempts="$restart_attempts" \
      --detail max_restarts="$max_restarts" \
      --detail restart_error="$restart_output"
    daemon_info "plugin MCP liveness restart failed for ${agent} (${missing}) [attempt ${restart_attempts}/${max_restarts}]${restart_output:+: $restart_output}"
  fi

  bridge_note_plugin_liveness_state "$agent" "$key" "$now_ts" "$last_restart_ts" "$restart_attempts"
}

process_plugin_liveness() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -z "$agent" ]] && continue
    bridge_report_plugin_liveness_miss "$agent" || true
  done
}

process_memory_daily_refresh_requests() {
  local agent
  local session
  local summary=""
  local live_agent=""
  local queued=0
  local claimed=0
  local blocked=0
  local attached=0
  local changed=1

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    # Clear any stuck pending state ahead of the gate check; leaving stale
    # pending refreshes around for gate-off agents was causing phantom
    # refreshes if the gate was later re-enabled.
    if ! bridge_agent_memory_daily_refresh_enabled "$agent"; then
      if bridge_agent_memory_daily_refresh_pending "$agent"; then
        bridge_agent_clear_memory_daily_refresh "$agent"
        bridge_audit_log daemon session_refresh_pending_cleared "$agent" \
          --detail reason=gate_off \
          --detail source=memory-daily
        daemon_info "cleared stale pending memory-daily refresh for gate-off ${agent}"
        changed=0
      fi
      continue
    fi
    bridge_agent_memory_daily_refresh_pending "$agent" || continue

    if ! bridge_agent_is_active "$agent"; then
      bridge_agent_clear_memory_daily_refresh "$agent"
      daemon_info "cleared pending memory-daily refresh for inactive ${agent}"
      changed=0
      continue
    fi

    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue

    summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
    if [[ -n "$summary" ]]; then
      IFS=$'\t' read -r live_agent queued claimed blocked _live_active _live_idle _live_last_seen _live_last_nudge _live_session _live_engine _live_workdir <<<"$summary"
      [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
      [[ "$claimed" =~ ^[0-9]+$ ]] || claimed=0
      [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
      if [[ "$live_agent" != "$agent" ]]; then
        queued=0
        claimed=0
        blocked=0
      fi
    else
      queued=0
      claimed=0
      blocked=0
    fi

    if (( claimed > 0 || blocked > 0 )); then
      continue
    fi

    attached="$(bridge_tmux_session_attached_count "$session")"
    [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    (( attached == 0 )) || continue

    if bridge_tmux_send_and_submit "$session" "claude" "/new" >/dev/null 2>&1; then
      bridge_agent_clear_memory_daily_refresh "$agent"
      bridge_audit_log daemon session_refresh_sent "$agent" \
        --detail session="$session" \
        --detail source=memory-daily
      daemon_info "refreshed ${agent} after memory-daily"
      changed=0
    fi
  done

  return "$changed"
}

process_channel_health() {
  local agent

  [[ "${BRIDGE_CHANNEL_HEALTH_ENABLED:-1}" == "1" ]] || return 1
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -z "$agent" ]] && continue
    bridge_report_channel_health_miss "$agent" || true
  done
}

# Issue #597 Track B: PreCompact channel auto-notify observer.
#
# Each daemon sync cycle:
#   1. Walk every started marker under
#      $BRIDGE_STATE_DIR/precompact-events/<agent>/started/.
#      For each eligible agent (opt-in, static source, claude engine, auto
#      trigger, declared channels, dedup window respected) resolve a route
#      via bridge_channel_precompact_target, render a notice template, and
#      send via bridge_channel_send_managed_message wrapped in
#      bridge_with_timeout.
#   2. Walk every completed marker under
#      $BRIDGE_STATE_DIR/precompact-events/<agent>/completed/. If a pending
#      notice exists for that agent (and follow-up has not already been
#      sent), update the EMA stats and send a "back online" follow-up
#      threaded against the original notice when possible.
#   3. Move processed markers to the agent's processed/ subdirectory; move
#      malformed markers to invalid/ silently.
#
# Network sends are wrapped in bridge_with_timeout so a stuck Discord/
# Telegram POST cannot block the daemon's main loop. The kill switch
# BRIDGE_PRECOMPACT_NOTIFY_DISABLED=1 short-circuits the entire helper.
process_precompact_events() {
  if [[ "${BRIDGE_PRECOMPACT_NOTIFY_DISABLED:-0}" == "1" ]]; then
    return 0
  fi

  local events_root="$BRIDGE_STATE_DIR/precompact-events"
  [[ -d "$events_root" ]] || return 0

  local agent_dir agent
  shopt -s nullglob
  for agent_dir in "$events_root"/*; do
    [[ -d "$agent_dir" ]] || continue
    agent="$(basename "$agent_dir")"
    [[ -n "$agent" ]] || continue
    _bridge_precompact_process_started_markers "$agent" "$agent_dir" || true
    _bridge_precompact_process_completed_markers "$agent" "$agent_dir" || true
  done
  shopt -u nullglob
}

# Parse error_class out of bridge-channels.py send-managed-message stderr.
# The send primitive emits "send-managed-message error: <code>: <message>"
# (see bridge-channels.py SendAdapterError handler). Codes include
# track_c_pending (Teams/Mattermost), missing_credentials, platform_error,
# network_error, http_error, malformed_response, unsupported_plugin.
# Falls back to "send_failed" when the stderr is empty or unparseable so the
# audit row always carries a non-empty error_class.
_bridge_precompact_parse_error_class() {
  local stderr_text="${1:-}"
  local fallback="send_failed"
  if [[ -z "$stderr_text" ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  local parsed=""
  parsed="$(printf '%s' "$stderr_text" \
    | grep -E 'send-managed-message error:' \
    | head -1 \
    | sed -E 's/^.*send-managed-message error: *([A-Za-z0-9_-]+).*/\1/' \
    || true)"
  if [[ -n "$parsed" && "$parsed" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s' "$parsed"
  else
    printf '%s' "$fallback"
  fi
}

# Internal: process every started marker for one agent. Each marker either
# becomes a sent notice (with pending state) or is skipped; in both cases the
# marker moves to processed/ so the daemon does not reconsider it. Malformed
# JSON files move to invalid/.
_bridge_precompact_process_started_markers() {
  local agent="$1"
  local agent_dir="$2"
  local started_dir="$agent_dir/started"
  [[ -d "$started_dir" ]] || return 0

  local marker
  shopt -s nullglob
  for marker in "$started_dir"/*.json; do
    _bridge_precompact_handle_started "$agent" "$agent_dir" "$marker" || true
  done
  shopt -u nullglob
}

_bridge_precompact_handle_started() {
  local agent="$1"
  local agent_dir="$2"
  local marker="$3"

  local processed_dir="$agent_dir/processed"
  local invalid_dir="$agent_dir/invalid"
  mkdir -p "$processed_dir" "$invalid_dir"

  local marker_basename
  marker_basename="$(basename "$marker")"

  # Footgun #11 (refs #815 Wave B): tempfile-route the parsed-tsv loop
  # and the three sites that sourced /dev/stdin from shell output
  # (route/render/send).
  local _parsed_tmp="" _route_tmp="" _render_tmp="" _send_tmp=""
  _parsed_tmp="$(mktemp)"
  _route_tmp="$(mktemp)"
  _render_tmp="$(mktemp)"
  _send_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_parsed_tmp' '$_route_tmp' '$_render_tmp' '$_send_tmp'" RETURN

  # Parse the marker JSON via python so we never have to grep raw JSON.
  local parsed
  parsed="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)
print("event_id\t" + str(data.get("event_id") or ""))
print("trigger\t" + str(data.get("trigger") or ""))
print("started_ts\t" + str(data.get("started_ts") or 0))
print("raw_trigger\t" + str(data.get("raw_trigger") or ""))
' "$marker" 2>/dev/null)" || {
    mv -f "$marker" "$invalid_dir/$marker_basename" 2>/dev/null || true
    return 0
  }

  local event_id="" trigger="" started_ts="" raw_trigger=""
  local key="" val=""
  printf '%s\n' "$parsed" > "$_parsed_tmp"
  while IFS=$'\t' read -r key val; do
    case "$key" in
      event_id) event_id="$val" ;;
      trigger) trigger="$val" ;;
      started_ts) started_ts="$val" ;;
      raw_trigger) raw_trigger="$val" ;;
    esac
  done < "$_parsed_tmp"

  if [[ -z "$event_id" ]]; then
    mv -f "$marker" "$invalid_dir/$marker_basename" 2>/dev/null || true
    return 0
  fi

  # Eligibility checks. Any silent skip moves the marker to processed/ so we
  # don't reconsider it on every cycle.
  if ! _bridge_precompact_is_agent_eligible "$agent"; then
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi
  if [[ "$trigger" != "auto" ]]; then
    # Manual /compact never gets an auto-notice (operator typed the command).
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi

  local agent_state_dir="$BRIDGE_STATE_DIR/agents/$agent"
  mkdir -p "$agent_state_dir"

  # Dedup: skip when the same event_id was already processed.
  local last_event_file="$agent_state_dir/precompact-notice-last-event-id"
  if [[ -f "$last_event_file" ]]; then
    local last_event=""
    last_event="$(<"$last_event_file")" 2>/dev/null || last_event=""
    if [[ "$last_event" == "$event_id" ]]; then
      mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
      return 0
    fi
  fi

  # Dedup: skip when the previous notice was sent within the dedup window.
  local last_ts_file="$agent_state_dir/precompact-notice-last-ts"
  local now_ts
  now_ts="$(date +%s 2>/dev/null || echo 0)"
  local dedup_window="${BRIDGE_PRECOMPACT_NOTICE_DEDUP_SECONDS:-300}"
  [[ "$dedup_window" =~ ^[0-9]+$ ]] || dedup_window=300
  if [[ -f "$last_ts_file" ]]; then
    local last_ts=""
    last_ts="$(<"$last_ts_file")" 2>/dev/null || last_ts=""
    if [[ "$last_ts" =~ ^[0-9]+$ ]] && (( now_ts - last_ts < dedup_window )); then
      mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
      return 0
    fi
  fi

  local channels_csv=""
  channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  if [[ -z "$channels_csv" ]]; then
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi

  # Resolve the channel route. Non-zero exit = no recent inbound = silent skip.
  # Invoke python3 directly (bridge_with_timeout wraps timeout(1), which can
  # only wrap external commands — not the bash function bridge_channel_precompact_target).
  local route_output=""
  local route_rc=0
  route_output="$(bridge_with_timeout 15 precompact_route python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" \
    route-precompact-target \
    --agent "$agent" \
    --channels-csv "$channels_csv" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --recency-seconds "${BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS:-1800}" \
    --now-ts "$now_ts" \
    --format shell 2>/dev/null)" || route_rc=$?
  if (( route_rc != 0 )) || [[ -z "$route_output" ]]; then
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi

  local CHANNEL_ROUTE_PLUGIN="" CHANNEL_ROUTE_CHANNEL_ID=""
  local CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID="" CHANNEL_ROUTE_LAST_USER_INBOUND_TS=""
  local CHANNEL_ROUTE_THREAD_ID=""
  printf '%s\n' "$route_output" > "$_route_tmp"
  # shellcheck disable=SC1090
  source "$_route_tmp"

  if [[ -z "$CHANNEL_ROUTE_PLUGIN" || -z "$CHANNEL_ROUTE_CHANNEL_ID" ]]; then
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi

  # Render the notice body.
  local lang
  lang="$(bridge_agent_precompact_notify_lang "$agent")"
  local render_output=""
  render_output="$(bridge_with_timeout 10 precompact_render python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" \
    render-precompact-message \
    --agent "$agent" \
    --kind notice \
    --lang "$lang" \
    --plugin "$CHANNEL_ROUTE_PLUGIN" \
    --channel-id "$CHANNEL_ROUTE_CHANNEL_ID" \
    --trigger "$trigger" \
    --started-ts "$started_ts" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --read-stats \
    --format shell 2>/dev/null)" || {
    bridge_audit_log daemon precompact_notice_failed "$agent" \
      --detail event_id="$event_id" \
      --detail plugin="$CHANNEL_ROUTE_PLUGIN" \
      --detail channel_id="$CHANNEL_ROUTE_CHANNEL_ID" \
      --detail error_class="render_failed" 2>/dev/null || true
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  }

  local PRECOMPACT_BODY_B64="" PRECOMPACT_EXPECTED_SECONDS=""
  local PRECOMPACT_LANG="" PRECOMPACT_KIND="" PRECOMPACT_DURATION_SECONDS=""
  printf '%s\n' "$render_output" > "$_render_tmp"
  # shellcheck disable=SC1090
  source "$_render_tmp"
  local body=""
  if [[ -n "$PRECOMPACT_BODY_B64" ]]; then
    body="$(printf '%s' "$PRECOMPACT_BODY_B64" | base64 -d 2>/dev/null || true)"
  fi
  if [[ -z "$body" ]]; then
    bridge_audit_log daemon precompact_notice_failed "$agent" \
      --detail event_id="$event_id" \
      --detail error_class="empty_body" 2>/dev/null || true
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi

  # Send the notice. Invoke python3 directly (bridge_with_timeout wraps
  # timeout(1), which can only wrap external commands).
  local -a send_args=(
    send-managed-message
    --plugin "$CHANNEL_ROUTE_PLUGIN"
    --agent "$agent"
    --channel-id "$CHANNEL_ROUTE_CHANNEL_ID"
    --body "$body"
    --kind notice
    --bridge-home "$BRIDGE_HOME"
    --bridge-state-dir "$BRIDGE_STATE_DIR"
    --correlation-id "$event_id"
    --format shell
  )
  if [[ -n "$CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID" ]]; then
    send_args+=(--reply-to-message-id "$CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID")
  fi
  if [[ "${BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN:-0}" == "1" ]]; then
    send_args+=(--dry-run)
  fi
  local send_output=""
  local send_rc=0
  local send_stderr_file
  send_stderr_file="$(mktemp 2>/dev/null || printf '%s/precompact-notice-stderr.%s' "${TMPDIR:-/tmp}" "$$")"
  send_output="$(bridge_with_timeout 30 precompact_send python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" "${send_args[@]}" 2>"$send_stderr_file")" || send_rc=$?
  local send_stderr=""
  if [[ -f "$send_stderr_file" ]]; then
    send_stderr="$(cat "$send_stderr_file" 2>/dev/null || true)"
    rm -f "$send_stderr_file" 2>/dev/null || true
  fi

  local CHANNEL_SEND_STATUS="" CHANNEL_SEND_PLUGIN="" CHANNEL_SEND_CHANNEL_ID=""
  local CHANNEL_SEND_REPLY_TO_MESSAGE_ID="" CHANNEL_SEND_MESSAGE_ID=""
  local CHANNEL_SEND_THREAD_ID="" CHANNEL_SEND_DRY_RUN=""
  if [[ -n "$send_output" ]]; then
    printf '%s\n' "$send_output" > "$_send_tmp"
    # shellcheck disable=SC1090
    source "$_send_tmp"
  fi

  if (( send_rc != 0 )) || [[ "$CHANNEL_SEND_STATUS" != "ok" ]]; then
    local error_class
    error_class="$(_bridge_precompact_parse_error_class "$send_stderr")"
    bridge_audit_log daemon precompact_notice_failed "$agent" \
      --detail event_id="$event_id" \
      --detail plugin="$CHANNEL_ROUTE_PLUGIN" \
      --detail channel_id="$CHANNEL_ROUTE_CHANNEL_ID" \
      --detail reply_to_message_id="$CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID" \
      --detail expected_seconds="$PRECOMPACT_EXPECTED_SECONDS" \
      --detail trigger="$trigger" \
      --detail started_ts="$started_ts" \
      --detail send_rc="$send_rc" \
      --detail error_class="$error_class" 2>/dev/null || true
    mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
    return 0
  fi

  # Persist dedup state and pending-notice JSON for the follow-up handler.
  printf '%s\n' "$now_ts" 2>/dev/null >"$last_ts_file" || true
  printf '%s\n' "$event_id" 2>/dev/null >"$last_event_file" || true

  local pending_path="$agent_state_dir/precompact-notice-pending.json"
  python3 -c '
import json, sys
data = {
    "event_id": sys.argv[1],
    "agent": sys.argv[2],
    "plugin": sys.argv[3],
    "channel_id": sys.argv[4],
    "reply_to_message_id": sys.argv[5],
    "notice_message_id": sys.argv[6],
    "thread_id": sys.argv[7],
    "trigger": sys.argv[8],
    "started_ts": int(sys.argv[9] or 0),
    "notice_sent_ts": int(sys.argv[10] or 0),
    "expected_seconds": int(sys.argv[11] or 0),
    "lang": sys.argv[12],
    "dry_run": sys.argv[13] == "1",
}
with open(sys.argv[14], "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
' \
    "$event_id" \
    "$agent" \
    "$CHANNEL_ROUTE_PLUGIN" \
    "$CHANNEL_ROUTE_CHANNEL_ID" \
    "$CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID" \
    "$CHANNEL_SEND_MESSAGE_ID" \
    "$CHANNEL_SEND_THREAD_ID" \
    "$trigger" \
    "$started_ts" \
    "$now_ts" \
    "$PRECOMPACT_EXPECTED_SECONDS" \
    "$PRECOMPACT_LANG" \
    "${CHANNEL_SEND_DRY_RUN:-0}" \
    "$pending_path" 2>/dev/null || true

  bridge_audit_log daemon precompact_notice_sent "$agent" \
    --detail event_id="$event_id" \
    --detail plugin="$CHANNEL_ROUTE_PLUGIN" \
    --detail channel_id="$CHANNEL_ROUTE_CHANNEL_ID" \
    --detail reply_to_message_id="$CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID" \
    --detail notice_message_id="$CHANNEL_SEND_MESSAGE_ID" \
    --detail expected_seconds="$PRECOMPACT_EXPECTED_SECONDS" \
    --detail trigger="$trigger" \
    --detail started_ts="$started_ts" \
    --detail dry_run="${CHANNEL_SEND_DRY_RUN:-0}" 2>/dev/null || true

  mv -f "$marker" "$processed_dir/$event_id.json" 2>/dev/null || true
  : "$raw_trigger"  # silence unused warning under set -u
  return 0
}

_bridge_precompact_is_agent_eligible() {
  local agent="$1"

  bridge_agent_precompact_notify_enabled "$agent" || return 1
  [[ "$(bridge_agent_source "$agent" 2>/dev/null)" == "static" ]] || return 1
  [[ "$(bridge_agent_engine "$agent" 2>/dev/null)" == "claude" ]] || return 1
  return 0
}

_bridge_precompact_process_completed_markers() {
  local agent="$1"
  local agent_dir="$2"
  local completed_dir="$agent_dir/completed"
  [[ -d "$completed_dir" ]] || return 0

  local marker
  shopt -s nullglob
  for marker in "$completed_dir"/*.json; do
    _bridge_precompact_handle_completed "$agent" "$agent_dir" "$marker" || true
  done
  shopt -u nullglob
}

_bridge_precompact_handle_completed() {
  local agent="$1"
  local agent_dir="$2"
  local marker="$3"

  local processed_dir="$agent_dir/processed"
  local invalid_dir="$agent_dir/invalid"
  mkdir -p "$processed_dir" "$invalid_dir"

  local marker_basename
  marker_basename="$(basename "$marker")"

  # Footgun #11 (refs #815 Wave B): tempfile-route the pending-parsed
  # loop plus render/send sites that sourced /dev/stdin from shell output.
  local _pending_tmp="" _render_tmp="" _send_tmp=""
  _pending_tmp="$(mktemp)"
  _render_tmp="$(mktemp)"
  _send_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_pending_tmp' '$_render_tmp' '$_send_tmp'" RETURN

  local completed_ts=""
  completed_ts="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    print(int(data.get("completed_ts") or 0))
except Exception:
    sys.exit(2)
' "$marker" 2>/dev/null)" || {
    mv -f "$marker" "$invalid_dir/$marker_basename" 2>/dev/null || true
    return 0
  }

  local agent_state_dir="$BRIDGE_STATE_DIR/agents/$agent"
  local pending_path="$agent_state_dir/precompact-notice-pending.json"
  if [[ ! -f "$pending_path" ]]; then
    # No pending notice => nothing to follow up. Move on silently.
    mv -f "$marker" "$processed_dir/$marker_basename" 2>/dev/null || true
    return 0
  fi

  # Load pending state.
  local pending_parsed
  pending_parsed="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)
keys = ("event_id", "plugin", "channel_id", "reply_to_message_id",
        "notice_message_id", "trigger", "started_ts", "lang", "dry_run",
        "followup_sent_ts")
for k in keys:
    v = data.get(k, "")
    if isinstance(v, bool):
        v = "1" if v else "0"
    print(f"{k}\t{v}")
' "$pending_path" 2>/dev/null)" || {
    mv -f "$marker" "$invalid_dir/$marker_basename" 2>/dev/null || true
    return 0
  }

  local pending_event_id="" pending_plugin="" pending_channel_id=""
  local pending_reply_to="" pending_notice_msg_id="" pending_trigger=""
  local pending_started_ts="0" pending_lang="" pending_dry_run="0"
  local pending_followup_sent_ts=""
  local pkey="" pval=""
  printf '%s\n' "$pending_parsed" > "$_pending_tmp"
  while IFS=$'\t' read -r pkey pval; do
    case "$pkey" in
      event_id) pending_event_id="$pval" ;;
      plugin) pending_plugin="$pval" ;;
      channel_id) pending_channel_id="$pval" ;;
      reply_to_message_id) pending_reply_to="$pval" ;;
      notice_message_id) pending_notice_msg_id="$pval" ;;
      trigger) pending_trigger="$pval" ;;
      started_ts) pending_started_ts="$pval" ;;
      lang) pending_lang="$pval" ;;
      dry_run) pending_dry_run="$pval" ;;
      followup_sent_ts) pending_followup_sent_ts="$pval" ;;
    esac
  done < "$_pending_tmp"

  if [[ -n "$pending_followup_sent_ts" && "$pending_followup_sent_ts" != "0" ]]; then
    # Already sent followup for this pending notice — completion marker is
    # for a later compaction; archive it.
    mv -f "$marker" "$processed_dir/$marker_basename" 2>/dev/null || true
    return 0
  fi

  if [[ -z "$pending_event_id" || -z "$pending_plugin" || -z "$pending_channel_id" ]]; then
    mv -f "$marker" "$processed_dir/$marker_basename" 2>/dev/null || true
    return 0
  fi

  # Stats mutation + per-event dedup flag are deferred until AFTER a successful
  # follow-up send (see r3 of #611). Rationale: writing the flag and mutating
  # precompact-stats.json before the send means a retry-loop on send failure
  # would either re-blend the EMA (no flag yet) or skip stats entirely while
  # the marker stays pending (flag already present). Both outcomes are wrong.
  # The correct invariant is "stats + flag move iff send succeeded once",
  # implemented by short-circuiting on the flag here and writing it inside
  # the success branch below. Duration is computed locally so the followup
  # body renders correctly even when stats have not yet been recorded.
  local recorded_flag_dir="$agent_state_dir/precompact-completion-recorded"
  local recorded_flag="$recorded_flag_dir/$pending_event_id.flag"
  local duration_secs=$(( completed_ts - pending_started_ts ))
  (( duration_secs >= 0 )) || duration_secs=0

  if [[ -f "$recorded_flag" ]]; then
    # Already processed this event_id (flag survives across retries). Tidy up
    # any stale completed-marker copy and exit; pending JSON was archived to
    # history at the time of the original successful send.
    mv -f "$marker" "$processed_dir/$marker_basename" 2>/dev/null || true
    return 0
  fi

  # Render the follow-up body.
  local render_output=""
  render_output="$(bridge_with_timeout 10 precompact_render_followup python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" \
    render-precompact-message \
    --agent "$agent" \
    --kind followup \
    --lang "${pending_lang:-en}" \
    --plugin "$pending_plugin" \
    --channel-id "$pending_channel_id" \
    --trigger "$pending_trigger" \
    --duration-seconds "$duration_secs" \
    --started-ts "$pending_started_ts" \
    --completed-ts "$completed_ts" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --format shell 2>/dev/null)" || render_output=""

  local PRECOMPACT_BODY_B64="" PRECOMPACT_EXPECTED_SECONDS=""
  local PRECOMPACT_LANG="" PRECOMPACT_KIND="" PRECOMPACT_DURATION_SECONDS=""
  if [[ -n "$render_output" ]]; then
    printf '%s\n' "$render_output" > "$_render_tmp"
    # shellcheck disable=SC1090
    source "$_render_tmp"
  fi
  local body=""
  if [[ -n "$PRECOMPACT_BODY_B64" ]]; then
    body="$(printf '%s' "$PRECOMPACT_BODY_B64" | base64 -d 2>/dev/null || true)"
  fi

  local followup_thread_anchor="$pending_notice_msg_id"
  if [[ -z "$followup_thread_anchor" ]]; then
    followup_thread_anchor="$pending_reply_to"
  fi

  # Honor pending dry-run state to keep notice + followup symmetric in CI.
  local saved_dry_run="${BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN:-0}"
  if [[ "$pending_dry_run" == "1" ]]; then
    export BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1
  fi

  local send_rc=0
  local send_output=""
  local send_stderr=""
  if [[ -z "$body" ]]; then
    send_rc=1
  else
    local -a fu_send_args=(
      send-managed-message
      --plugin "$pending_plugin"
      --agent "$agent"
      --channel-id "$pending_channel_id"
      --body "$body"
      --kind followup
      --bridge-home "$BRIDGE_HOME"
      --bridge-state-dir "$BRIDGE_STATE_DIR"
      --correlation-id "$pending_event_id"
      --format shell
    )
    if [[ -n "$followup_thread_anchor" ]]; then
      fu_send_args+=(--reply-to-message-id "$followup_thread_anchor")
    fi
    if [[ "${BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN:-0}" == "1" ]]; then
      fu_send_args+=(--dry-run)
    fi
    local fu_stderr_file
    fu_stderr_file="$(mktemp 2>/dev/null || printf '%s/precompact-followup-stderr.%s' "${TMPDIR:-/tmp}" "$$")"
    send_output="$(bridge_with_timeout 30 precompact_send_followup python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" "${fu_send_args[@]}" 2>"$fu_stderr_file")" || send_rc=$?
    if [[ -f "$fu_stderr_file" ]]; then
      send_stderr="$(cat "$fu_stderr_file" 2>/dev/null || true)"
      rm -f "$fu_stderr_file" 2>/dev/null || true
    fi
  fi

  if [[ "$pending_dry_run" == "1" ]]; then
    export BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN="$saved_dry_run"
  fi

  local CHANNEL_SEND_STATUS="" CHANNEL_SEND_MESSAGE_ID="" CHANNEL_SEND_DRY_RUN=""
  if [[ -n "$send_output" ]]; then
    printf '%s\n' "$send_output" > "$_send_tmp"
    # shellcheck disable=SC1090
    source "$_send_tmp"
  fi

  local now_ts
  now_ts="$(date +%s 2>/dev/null || echo 0)"

  if (( send_rc != 0 )) || [[ "$CHANNEL_SEND_STATUS" != "ok" ]]; then
    # Honor the retry window: keep pending in place if we're still inside
    # BRIDGE_PRECOMPACT_FOLLOWUP_RETRY_SECONDS; otherwise archive and give up.
    local retry_window="${BRIDGE_PRECOMPACT_FOLLOWUP_RETRY_SECONDS:-600}"
    [[ "$retry_window" =~ ^[0-9]+$ ]] || retry_window=600
    local fu_error_class
    fu_error_class="$(_bridge_precompact_parse_error_class "$send_stderr")"
    bridge_audit_log daemon precompact_followup_failed "$agent" \
      --detail event_id="$pending_event_id" \
      --detail plugin="$pending_plugin" \
      --detail channel_id="$pending_channel_id" \
      --detail duration_seconds="$duration_secs" \
      --detail send_rc="$send_rc" \
      --detail error_class="$fu_error_class" 2>/dev/null || true

    # Update pending followup_attempt_ts and decide whether to expire.
    local notice_sent_ts=0
    notice_sent_ts="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    print(int(data.get("notice_sent_ts") or 0))
except Exception:
    sys.exit(2)
' "$pending_path" 2>/dev/null || echo 0)"

    if [[ "$notice_sent_ts" =~ ^[0-9]+$ ]] && (( now_ts - notice_sent_ts > retry_window )); then
      mkdir -p "$agent_state_dir/precompact-notice-history"
      mv -f "$pending_path" "$agent_state_dir/precompact-notice-history/$pending_event_id.json" 2>/dev/null || true
      mv -f "$marker" "$processed_dir/$marker_basename" 2>/dev/null || true
    else
      python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    data["followup_attempt_ts"] = int(sys.argv[2])
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
' "$pending_path" "$now_ts" 2>/dev/null || true
      # Leave the completed marker in place for the next sync cycle to retry.
    fi
    return 0
  fi

  # Followup succeeded — finalize pending and archive history.
  #
  # Order matters for crash-restart correctness (see r3 of #611):
  #   1. Write the per-event flag FIRST so a crash between flag and stats
  #      leaves the flag present; the next sync short-circuits at the entry
  #      block and never re-blends the EMA. Stats are slightly under-counted
  #      by one sample in that narrow window, which is acceptable; double
  #      counting is not.
  #   2. Run record-precompact-completion to mutate precompact-stats.json.
  #   3. Update the pending JSON in place, then archive + move the marker.
  mkdir -p "$recorded_flag_dir" 2>/dev/null || true
  : 2>/dev/null >"$recorded_flag" || true

  bridge_with_timeout 10 precompact_stats_record python3 "$BRIDGE_SCRIPT_DIR/bridge-channels.py" \
    record-precompact-completion \
    --agent "$agent" \
    --trigger "$pending_trigger" \
    --started-ts "$pending_started_ts" \
    --completed-ts "$completed_ts" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --format shell >/dev/null 2>&1 || true

  python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    data["completed_ts"] = int(sys.argv[2])
    data["duration_seconds"] = int(sys.argv[3])
    data["followup_sent_ts"] = int(sys.argv[4])
    data["followup_message_id"] = sys.argv[5]
    data["stats_updated"] = 1
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
' "$pending_path" "$completed_ts" "$duration_secs" "$now_ts" "$CHANNEL_SEND_MESSAGE_ID" 2>/dev/null || true

  bridge_audit_log daemon precompact_followup_sent "$agent" \
    --detail event_id="$pending_event_id" \
    --detail plugin="$pending_plugin" \
    --detail channel_id="$pending_channel_id" \
    --detail reply_to_message_id="$pending_reply_to" \
    --detail notice_message_id="$pending_notice_msg_id" \
    --detail followup_message_id="$CHANNEL_SEND_MESSAGE_ID" \
    --detail duration_seconds="$duration_secs" \
    --detail dry_run="${CHANNEL_SEND_DRY_RUN:-0}" 2>/dev/null || true

  mkdir -p "$agent_state_dir/precompact-notice-history"
  mv -f "$pending_path" "$agent_state_dir/precompact-notice-history/$pending_event_id.json" 2>/dev/null || true
  mv -f "$marker" "$processed_dir/$marker_basename" 2>/dev/null || true
  return 0
}

cron_worker_running_count() {
  local worker_dir
  local pid_file
  local pid
  local count=0

  worker_dir="$(bridge_cron_worker_dir)"
  mkdir -p "$worker_dir"

  shopt -s nullglob
  for pid_file in "$worker_dir"/*.pid; do
    pid="$(<"$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
      continue
    fi
    rm -f "$pid_file"
  done
  shopt -u nullglob

  printf '%s' "$count"
}

cron_ready_rows_with_retry() {
  local limit="$1"
  local status_snapshot="${2:-}"
  local attempts="${BRIDGE_QUEUE_RETRY_ATTEMPTS:-5}"
  local delay="${BRIDGE_QUEUE_RETRY_DELAY_SECONDS:-0.2}"
  local defer_seconds="${BRIDGE_MEMORY_DAILY_MAX_DEFER_SECONDS:-10800}"
  local output=""
  local status=0
  local try
  local args=()

  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=5
  (( attempts > 0 )) || attempts=1
  [[ "$defer_seconds" =~ ^[0-9]+$ ]] || defer_seconds=10800
  args=(cron-ready --limit "$limit" --format tsv --memory-daily-defer-seconds "$defer_seconds")
  if [[ -n "$status_snapshot" ]]; then
    args+=(--status-snapshot "$status_snapshot")
  fi

  for try in $(seq 1 "$attempts"); do
    if output="$(bridge_queue_cli "${args[@]}" 2>/dev/null)"; then
      printf '%s' "$output"
      return 0
    fi
    status=$?
    sleep "$delay"
  done

  return "$status"
}

claim_cron_task_with_retry() {
  local task_id="$1"
  local agent="$2"
  local lease_seconds="$3"
  local attempts="${BRIDGE_QUEUE_RETRY_ATTEMPTS:-5}"
  local delay="${BRIDGE_QUEUE_RETRY_DELAY_SECONDS:-0.2}"
  local try

  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=5
  (( attempts > 0 )) || attempts=1

  for try in $(seq 1 "$attempts"); do
    if bridge_queue_cli claim "$task_id" --agent "$agent" --lease-seconds "$lease_seconds" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

start_cron_worker() {
  local task_id="$1"
  local log_file

  log_file="$(bridge_cron_worker_log_file "$task_id")"
  mkdir -p "$(dirname "$log_file")"
  bridge_require_python
  python3 - "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" "$task_id" "$log_file" <<'PY' >/dev/null
import os
import subprocess
import sys

bash_bin, daemon_script, task_id, log_file = sys.argv[1:]

with open(os.devnull, "rb") as stdin_handle, open(log_file, "ab", buffering=0) as log_handle:
    subprocess.Popen(
        [bash_bin, daemon_script, "run-cron-worker", task_id],
        stdin=stdin_handle,
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
        close_fds=True,
    )
PY
}

start_cron_dispatch_workers() {
  local max_parallel="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-0}"
  local running_count
  local ready_rows=""
  local status_snapshot_file=""
  local task_id
  local agent
  local _priority
  local _title
  local _body_path
  local started=0
  # Footgun #11 (refs #815 Wave B): tempfile-route ready_rows.
  local _ready_tmp=""
  _ready_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_ready_tmp'" RETURN

  [[ "$max_parallel" =~ ^[0-9]+$ ]] || max_parallel=0
  (( max_parallel > 0 )) || return 0

  running_count="$(cron_worker_running_count)"
  (( running_count < max_parallel )) || return 0

  status_snapshot_file="$(mktemp)"
  bridge_write_roster_status_snapshot "$status_snapshot_file"
  ready_rows="$(cron_ready_rows_with_retry "$max_parallel" "$status_snapshot_file" || true)"
  rm -f "$status_snapshot_file"
  [[ -n "$ready_rows" ]] || return 0

  printf '%s\n' "$ready_rows" > "$_ready_tmp"

  while IFS=$'\t' read -r task_id agent _priority _title _body_path; do
    [[ -n "$task_id" && -n "$agent" ]] || continue
    (( running_count < max_parallel )) || break

    if ! claim_cron_task_with_retry "$task_id" "$agent" "$BRIDGE_CRON_DISPATCH_LEASE_SECONDS"; then
      continue
    fi

    if start_cron_worker "$task_id"; then
      daemon_info "started cron worker for task #${task_id} (${agent})"
      running_count=$((running_count + 1))
      started=1
      continue
    fi

    bridge_warn "failed to start cron worker for task #${task_id}"
    bridge_queue_cli handoff "$task_id" --to "$agent" --from daemon --note "failed to start cron worker" >/dev/null 2>&1 || true
  done < "$_ready_tmp"

  return "$started"
}

cmd_run_cron_worker() {
  local task_id="${1:-}"
  local pid_file=""
  local run_id=""
  local done_note_file=""
  local followup_body_file=""
  local followup_task_id=""
  local followup_title=""
  local followup_title_prefix=""
  local existing_followup_id=""
  local create_output=""
  local followup_priority="normal"
  local followup_actor=""
  local subagent_status=0
  local TASK_ID=""
  local TASK_TITLE=""
  local TASK_STATUS=""
  local TASK_ASSIGNED_TO=""
  local TASK_CREATED_BY=""
  local TASK_PRIORITY=""
  local TASK_CLAIMED_BY=""
  local TASK_BODY_PATH=""
  local CRON_RUN_ID=""
  local CRON_JOB_ID=""
  local CRON_JOB_NAME=""
  local CRON_FAMILY=""
  local CRON_SLOT=""
  local CRON_TARGET_AGENT=""
  local CRON_TARGET_ENGINE=""
  local CRON_DEFERRED_REASON=""
  local CRON_RESULT_STATUS=""
  local CRON_RESULT_SUMMARY=""
  local CRON_RUN_STATE=""
  local CRON_RESULT_FILE=""
  local CRON_STATUS_FILE=""
  local CRON_STDOUT_LOG=""
  local CRON_STDERR_LOG=""
  local CRON_PROMPT_FILE=""
  local CRON_NEEDS_HUMAN_FOLLOWUP=""
  local CRON_FAILURE_CLASS=""

  [[ "$task_id" =~ ^[0-9]+$ ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-daemon.sh run-cron-worker <task-id>"

  pid_file="$(bridge_cron_worker_pid_file "$task_id")"
  mkdir -p "$(dirname "$pid_file")"
  echo "$$" >"$pid_file"
  trap "rm -f '$pid_file'" EXIT

  bridge_queue_source_shell show "$task_id" --format shell

  if [[ -z "$TASK_ASSIGNED_TO" ]]; then
    bridge_warn "cron worker task #${task_id} missing assigned agent"
    return 1
  fi

  if [[ -z "$TASK_BODY_PATH" ]]; then
    run_id="task-${task_id}"
    done_note_file="$(bridge_cron_dispatch_completion_note_file_by_id "$run_id")"
    mkdir -p "$(dirname "$done_note_file")"
    {
      printf '# Cron Dispatch Result\n\n'
      printf -- '- task_id: %s\n' "$task_id"
      printf -- '- state: invalid_task\n'
      printf -- '- reason: missing body_path\n'
    } >"$done_note_file"
    bridge_queue_cli done "$task_id" --agent "$TASK_ASSIGNED_TO" --note-file "$done_note_file" >/dev/null 2>&1 || true
    return 0
  fi

  run_id="$(bridge_cron_run_id_from_body_path "$TASK_BODY_PATH")"
  # shellcheck disable=SC1090
  source <(bridge_cron_load_run_shell "$run_id")

  if [[ "$CRON_RUN_STATE" != "success" || ! -f "$CRON_RESULT_FILE" ]]; then
    if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" run-subagent "$run_id" >/dev/null 2>&1; then
      subagent_status=0
    else
      subagent_status=$?
    fi
    # shellcheck disable=SC1090
    source <(bridge_cron_load_run_shell "$run_id")
  fi

  # Issue #385: distinguish failure-followups (transient API noise) from
  # success-followups (subagent legitimately set needs_human_followup=true).
  # The burst gate below only applies to the failure path; success-with-
  # followup-flag must always create a task, otherwise routine signals like
  # morning-briefing's daily channel-relay handoff are silently suppressed
  # on the first run of every slot.
  local is_failure_followup=0
  if [[ "$CRON_RUN_STATE" != "success" || "$CRON_RESULT_STATUS" == "error" || $subagent_status -ne 0 ]]; then
    CRON_NEEDS_HUMAN_FOLLOWUP="1"
    followup_priority="high"
    is_failure_followup=1
  fi

  # Issue #393: memory_pressure deferrals auto-retry on the next cron
  # slot — emitting a high-priority cron-followup task per deferred slot
  # only wakes the parent agent (e.g. patch), consumes tokens that
  # materialize as more memory, and deepens the pressure that triggered
  # the deferral in the first place. Reset the followup flags after
  # the failure-path set above so the existing burst-counter + creation
  # block silently skips. Real failed/timeout/crash runs still emit a
  # high-priority followup as today; only the memory_pressure deferral
  # path is suppressed.
  if [[ "$CRON_RUN_STATE" == "deferred" && "$CRON_DEFERRED_REASON" == "memory_pressure" ]]; then
    CRON_NEEDS_HUMAN_FOLLOWUP=""
    is_failure_followup=0
    bridge_audit_log daemon cron_followup_suppressed "$TASK_ASSIGNED_TO" \
      --detail run_id="$run_id" \
      --detail job_name="${CRON_JOB_NAME:-$run_id}" \
      --detail family="${CRON_FAMILY:-}" \
      --detail slot="${CRON_SLOT:-}" \
      --detail reason=memory_pressure_deferral
    daemon_info "skipped cron-followup for memory_pressure deferral of ${CRON_FAMILY:-${CRON_JOB_NAME:-$run_id}}"
  fi

  # Trust the subagent's needs_human_followup decision.
  # The alwaysFollowup override was creating noise tasks for no-op results
  # (e.g. "after hours, skipped"). Subagents already set the flag correctly.

  # Issue #230-B: Claude API transients (ConnectionRefused, stream idle
  # timeout, etc.) produce one-off cron failures that the admin can
  # neither act on nor suppress — they just close the task. Burst-gate
  # the followup emission: only surface after the same cron family has
  # failed at least BRIDGE_CRON_FOLLOWUP_FAIL_BURST_THRESHOLD times
  # consecutively. A success resets the counter, and a successful create
  # also resets it so the "every-failure-after-the-first-N-creates-a-new-
  # task" pattern doesn't resurface after the admin closes the first
  # burst task. Existing open followups are still refreshed (update path
  # below) regardless of burst state so long-running investigations
  # don't stall.
  #
  # Key the counter by cron family (CRON_FAMILY), falling back to job
  # name then run id. Family is the right granularity — parallel jobs
  # in the same family (e.g. memory-daily across every agent) should
  # accumulate toward one threshold, not each one independently.
  local cron_family_key="${CRON_FAMILY:-${CRON_JOB_NAME:-$run_id}}"
  local fail_burst_dir="$BRIDGE_STATE_DIR/cron/consecutive-failures"
  local fail_burst_file="$fail_burst_dir/$(bridge_sha1 "$cron_family_key")"
  local fail_burst_lock="${fail_burst_file}.lock"
  local fail_burst_threshold="${BRIDGE_CRON_FOLLOWUP_FAIL_BURST_THRESHOLD:-3}"
  [[ "$fail_burst_threshold" =~ ^[0-9]+$ ]] || fail_burst_threshold=3
  local fail_burst_count=0
  mkdir -p "$fail_burst_dir"
  # Cron workers run in parallel (BRIDGE_CRON_DISPATCH_MAX_PARALLEL=2+),
  # so two failing workers of the same family could race the read-
  # modify-write and lose an increment. Serialise with flock and fall
  # through cleanly if `flock` is missing on the host.
  local _has_flock=0
  if command -v flock >/dev/null 2>&1; then
    _has_flock=1
  fi
  # Use a group command `{ ...; }` instead of a subshell `( ... )` so
  # the variable assignment to fail_burst_count stays visible in the
  # outer scope. A subshell would fork a child process whose local
  # variable mutations evaporate on exit, leaving the downstream
  # `(( fail_burst_count >= fail_burst_threshold ))` gate forever
  # reading 0 → burst threshold never reached → task never created.
  # Issue #385: only failure-followups bump the consecutive-failure
  # counter. A success-with-needs_human_followup is a legitimate signal
  # (morning-briefing channel relay, routine daily digest handoff, etc.)
  # and must not inflate the counter or otherwise affect the gate.
  # Any non-failure outcome resets the counter so a follow-up failure
  # has to re-accumulate from zero.
  if (( _has_flock == 1 )); then
    { flock -x 9
      if (( is_failure_followup == 1 )); then
        fail_burst_count=0
        if [[ -f "$fail_burst_file" ]]; then
          fail_burst_count=$(cat "$fail_burst_file" 2>/dev/null || echo 0)
          [[ "$fail_burst_count" =~ ^[0-9]+$ ]] || fail_burst_count=0
        fi
        fail_burst_count=$(( fail_burst_count + 1 ))
        printf '%s' "$fail_burst_count" >"$fail_burst_file"
      else
        rm -f "$fail_burst_file" 2>/dev/null || true
      fi
    } 9>"$fail_burst_lock"
  else
    if (( is_failure_followup == 1 )); then
      fail_burst_count=0
      if [[ -f "$fail_burst_file" ]]; then
        fail_burst_count=$(cat "$fail_burst_file" 2>/dev/null || echo 0)
        [[ "$fail_burst_count" =~ ^[0-9]+$ ]] || fail_burst_count=0
      fi
      fail_burst_count=$(( fail_burst_count + 1 ))
      printf '%s' "$fail_burst_count" >"$fail_burst_file"
    else
      rm -f "$fail_burst_file" 2>/dev/null || true
    fi
  fi

  # PR1.6 — gate the daemon-side followup task only when the cron-runner
  # legitimately handled reporting itself: `silent` (intentional no-op) or
  # `reported` (cron-runner created an inbox task and recorded its id).
  # `invalid` and any unknown decision must continue to the failure path
  # below so a broken result, schema/validation reject, or inbox writeback
  # failure still wakes the existing daemon-side health surfaces (Codex
  # r1 P1 — without this, a non-zero cron run with reporting_decision=
  # invalid was silently dropped). Legacy cron jobs without a
  # reporting_decision (PR1 rollout, downgrade, manual shim) also flow
  # through the original path unchanged.
  case "${CRON_REPORTING_DECISION:-}" in
    silent|reported)
      if [[ "${CRON_INBOX_TASK_ID:-}" =~ ^[0-9]+$ ]]; then
        daemon_info "cron-runner already wrote inbox task #${CRON_INBOX_TASK_ID} for ${CRON_JOB_NAME:-$run_id} (decision=${CRON_REPORTING_DECISION}); skipping daemon followup"
      else
        daemon_info "cron-runner reported decision=${CRON_REPORTING_DECISION} for ${CRON_JOB_NAME:-$run_id}; skipping daemon followup"
      fi
      CRON_NEEDS_HUMAN_FOLLOWUP=""
      ;;
    invalid)
      daemon_info "cron-runner reported decision=invalid for ${CRON_JOB_NAME:-$run_id}; daemon followup path remains active so the failure surfaces"
      ;;
    "" | *)
      : # empty / unknown → legacy / forward-compatible path, no gate change
      ;;
  esac

  if [[ "$CRON_NEEDS_HUMAN_FOLLOWUP" == "1" ]]; then
    followup_body_file="$(bridge_cron_dispatch_followup_file_by_id "$run_id")"
    bridge_cron_write_followup_body "$run_id" "$followup_body_file"
    followup_actor="cron:${CRON_JOB_NAME:-$run_id}"
    followup_title="[cron-followup] ${CRON_JOB_NAME:-$run_id} (${CRON_SLOT:-$run_id})"
    followup_title_prefix="[cron-followup] ${CRON_JOB_NAME:-$run_id} ("
    # Issue #345 Track B (instance #4): split cron-followup destinations by
    # failure class. `human-config` failures (config drift, binding
    # mismatch, retired-agent cleanup) cannot be closed by admin acting on a
    # queue task; they require operator attention. Surface those via a
    # `cron_human_config_drift` audit row that the dashboard config-drift
    # counter (Track C) reads for the rolling 7d window. Only
    # `admin-resolvable` failures (the default) flow into admin's queue.
    if [[ "$CRON_FAILURE_CLASS" == "human-config" ]]; then
      bridge_audit_log daemon cron_human_config_drift "$TASK_ASSIGNED_TO" \
        --detail run_id="$run_id" \
        --detail job_name="${CRON_JOB_NAME:-$run_id}" \
        --detail family="${CRON_FAMILY:-}" \
        --detail slot="${CRON_SLOT:-}" \
        --detail body_file="$followup_body_file" \
        --detail dashboard_flag=1
      daemon_info "cron-followup human-config drift recorded for ${CRON_JOB_NAME:-$run_id} (no admin task created)"
      # Reset burst counter so a follow-up admin-resolvable failure does
      # not trip the threshold against accumulated drift counts.
      if (( _has_flock == 1 )); then
        { flock -x 9
          rm -f "$fail_burst_file" 2>/dev/null || true
        } 9>"$fail_burst_lock"
      else
        rm -f "$fail_burst_file" 2>/dev/null || true
      fi
    else
    existing_followup_id="$(bridge_queue_cli find-open --agent "$TASK_ASSIGNED_TO" --title-prefix "$followup_title_prefix" 2>/dev/null || true)"
    if [[ "$existing_followup_id" =~ ^[0-9]+$ ]]; then
      bridge_queue_cli update "$existing_followup_id" --actor "$followup_actor" --title "$followup_title" --priority "$followup_priority" --body-file "$followup_body_file" >/dev/null 2>&1 || true
      followup_task_id="$existing_followup_id"
      daemon_info "refreshed cron followup task #${followup_task_id} for ${CRON_JOB_NAME:-$run_id}"
    # Issue #385: success-followups (is_failure_followup=0) bypass the
    # burst threshold. Only transient-failure noise (#230-B's original
    # target) is gated behind fail_burst_threshold.
    elif (( is_failure_followup == 0 )) || (( fail_burst_count >= fail_burst_threshold )); then
      create_output="$(bridge_queue_cli create --to "$TASK_ASSIGNED_TO" --title "$followup_title" --from "$followup_actor" --priority "$followup_priority" --body-file "$followup_body_file" 2>/dev/null || true)"
      if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
        followup_task_id="${BASH_REMATCH[1]}"
        if (( is_failure_followup == 1 )); then
          daemon_info "created cron followup task #${followup_task_id} after ${fail_burst_count} consecutive failures of ${cron_family_key}"
        else
          daemon_info "created cron followup task #${followup_task_id} for success+needs_human_followup signal of ${cron_family_key}"
        fi
        # Reset the burst counter so subsequent failures don't rapid-
        # fire a fresh followup task after the admin closes this one.
        # The cycle restarts only after another BRIDGE_CRON_FOLLOWUP_FAIL_BURST_THRESHOLD
        # consecutive failures or any success (handled above).
        # Reset is a single rm, so a subshell is safe here — no outer
        # scope state to preserve.
        if (( _has_flock == 1 )); then
          { flock -x 9
            rm -f "$fail_burst_file" 2>/dev/null || true
          } 9>"$fail_burst_lock"
        else
          rm -f "$fail_burst_file" 2>/dev/null || true
        fi
      fi
    else
      bridge_audit_log daemon cron_followup_suppressed "$TASK_ASSIGNED_TO" \
        --detail run_id="$run_id" \
        --detail job_name="${CRON_JOB_NAME:-$run_id}" \
        --detail family="${CRON_FAMILY:-}" \
        --detail fail_burst_count="$fail_burst_count" \
        --detail fail_burst_threshold="$fail_burst_threshold" \
        --detail reason=below_threshold
    fi
    fi
  fi

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" finalize-run "$run_id" >/dev/null 2>&1 || true

  if [[ "${CRON_FAMILY:-}" == "memory-daily" && "${CRON_RUN_STATE:-}" == "success" && "${CRON_RESULT_STATUS:-}" != "error" ]]; then
    if bridge_agent_memory_daily_refresh_enabled "$TASK_ASSIGNED_TO"; then
      # Only queue a session refresh when the harvester actually backfilled
      # the queue. no-op / ok / skip results would churn sessions otherwise.
      if bridge_cron_actions_taken_contains "${CRON_RESULT_FILE:-}" "queue-backfill"; then
        bridge_agent_note_memory_daily_refresh "$TASK_ASSIGNED_TO" "$run_id" "${CRON_SLOT:-}"
        bridge_audit_log daemon session_refresh_queued "$TASK_ASSIGNED_TO" \
          --detail run_id="$run_id" \
          --detail slot="${CRON_SLOT:-}" \
          --detail source=memory-daily
        daemon_info "queued memory-daily session refresh for ${TASK_ASSIGNED_TO} run_id=${run_id}"
      else
        bridge_audit_log daemon session_refresh_skipped "$TASK_ASSIGNED_TO" \
          --detail run_id="$run_id" \
          --detail slot="${CRON_SLOT:-}" \
          --detail source=memory-daily \
          --detail reason=no_queue_backfill_action
      fi
    fi
  fi

  done_note_file="$(bridge_cron_dispatch_completion_note_file_by_id "$run_id")"
  bridge_cron_write_completion_note "$run_id" "$done_note_file" "$followup_task_id"
  bridge_queue_cli done "$task_id" --agent "$TASK_ASSIGNED_TO" --note-file "$done_note_file" >/dev/null
  bridge_audit_log daemon cron_worker_complete "$TASK_ASSIGNED_TO" \
    --detail run_id="$run_id" \
    --detail task_id="$task_id" \
    --detail state="${CRON_RUN_STATE:-unknown}" \
    --detail followup_task_id="${followup_task_id:-0}" \
    --detail job_name="${CRON_JOB_NAME:-$run_id}" \
    --detail slot="${CRON_SLOT:-}"
  daemon_info "completed cron worker task #${task_id} run_id=${run_id} state=${CRON_RUN_STATE:-unknown} followup=${followup_task_id:-0}"
}

process_on_demand_agents() {
  local summary_output="$1"
  local agent
  local queued
  local claimed
  local blocked
  local active
  local idle
  local _last_seen
  local _last_nudge
  local session
  local _engine
  local _workdir
  local timeout
  local always_on=0
  local changed=1
  local live_summary=""
  local live_agent=""
  local live_queued=0
  local live_claimed=0
  local live_blocked=0
  local configured_session=""
  local attached_count=0
  # Footgun #11 (refs #815 Wave B): tempfile-route summary_output.
  local _summary_tmp=""
  _summary_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_summary_tmp'" RETURN
  printf '%s\n' "$summary_output" > "$_summary_tmp"

  while IFS=$'\t' read -r agent queued claimed blocked active idle _last_seen _last_nudge session _engine _workdir; do
    [[ -z "$agent" ]] && continue
    bridge_agent_exists "$agent" || continue
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    if bridge_agent_manual_stop_active "$agent"; then
      continue
    fi
    always_on=0
    if bridge_agent_is_always_on "$agent"; then
      always_on=1
    fi
    if [[ "$active" == "1" ]]; then
      bridge_daemon_clear_autostart_failure "$agent"
    fi

    if [[ "$active" == "0" ]]; then
      if ! bridge_daemon_autostart_allowed "$agent"; then
        continue
      fi
      # Defensive guard (issue #190 symptom D): even when the summary reports
      # active=0 (e.g. fresh daemon, state drift, or roster/tmux name mismatch),
      # never auto-start on top of a tmux session that currently has a human
      # client attached. bridge-start.sh without --replace is idempotent today,
      # but skipping early avoids spurious "ensured always-on" log spam that
      # masks real restarts and guards the attached path from future refactors.
      configured_session="$(bridge_agent_session "$agent")"
      if [[ -n "$configured_session" ]] && bridge_tmux_session_exists "$configured_session"; then
        attached_count="$(bridge_tmux_session_attached_count "$configured_session" 2>/dev/null || printf '0')"
        [[ "$attached_count" =~ ^[0-9]+$ ]] || attached_count=0
        if (( attached_count > 0 )); then
          bridge_daemon_clear_autostart_failure "$agent"
          bridge_audit_log daemon autostart_skipped_attached "$agent" \
            --detail session="$configured_session" \
            --detail attached="$attached_count" \
            --detail always_on="$always_on"
          daemon_info "skipped-attached ${agent} (session=${configured_session} attached=${attached_count})"
          continue
        fi
      fi
      if ((( always_on == 1 ))) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          session="$(bridge_agent_session "$agent")"
          sleep 1
          if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
            bridge_daemon_clear_autostart_failure "$agent"
            daemon_info "ensured always-on ${agent}"
            changed=0
          else
            bridge_daemon_note_autostart_failure "$agent" "session-exited-quickly"
          fi
        else
          bridge_daemon_note_autostart_failure "$agent" "start-command-failed"
          bridge_warn "always-on auto-start failed: ${agent}"
        fi
      elif [[ "$queued" =~ ^[0-9]+$ ]] && (( queued > 0 )) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          session="$(bridge_agent_session "$agent")"
          timeout="$(bridge_agent_idle_timeout "$agent")"
          [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
          sleep 1
          if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
            bridge_daemon_clear_autostart_failure "$agent"
            nudge_agent_session "$agent" "$session" "$queued" "$claimed" "0" || true
            daemon_info "auto-started ${agent} (queued=${queued}, timeout=${timeout}s)"
            changed=0
          else
            bridge_daemon_note_autostart_failure "$agent" "session-exited-quickly"
          fi
        else
          bridge_daemon_note_autostart_failure "$agent" "start-command-failed"
          bridge_warn "on-demand auto-start failed: ${agent}"
        fi
      fi
      continue
    fi

    timeout="$(bridge_agent_idle_timeout "$agent")"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
    (( timeout > 0 )) || continue

    if ! [[ "$queued" =~ ^[0-9]+$ && "$claimed" =~ ^[0-9]+$ && "$blocked" =~ ^[0-9]+$ && "$idle" =~ ^[0-9]+$ ]]; then
      continue
    fi
    (( queued == 0 && claimed == 0 && blocked == 0 )) || continue
    (( idle >= timeout )) || continue
    bridge_agent_is_active "$agent" || continue

    live_summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
    if [[ -n "$live_summary" ]]; then
      IFS=$'\t' read -r live_agent live_queued live_claimed live_blocked _live_active _live_idle _live_last_seen _live_last_nudge _live_session _live_engine _live_workdir <<<"$live_summary"
      if [[ "$live_agent" == "$agent" ]]; then
        if ! [[ "$live_queued" =~ ^[0-9]+$ ]]; then live_queued=0; fi
        if ! [[ "$live_claimed" =~ ^[0-9]+$ ]]; then live_claimed=0; fi
        if ! [[ "$live_blocked" =~ ^[0-9]+$ ]]; then live_blocked=0; fi
        (( live_queued == 0 && live_claimed == 0 && live_blocked == 0 )) || continue
      fi
    fi

    if bridge_kill_agent_session "$agent" >/dev/null 2>&1; then
      daemon_info "auto-stopped ${agent} (idle=${idle}s, timeout=${timeout}s)"
      changed=0
    else
      bridge_warn "on-demand auto-stop failed: ${agent}"
    fi
  done < "$_summary_tmp"

  return "$changed"
}

session_is_registered_agent_session() {
  local session="$1"
  local agent
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_session "$agent")" == "$session" ]]; then
      return 0
    fi
  done
  return 1
}

session_matches_idle_reap_patterns() {
  local session="$1"
  case "$session" in
    bridge-smoke-*|bridge-requester-*|auto-start-session-*|always-on-session-*|static-session-*|claude-static-bridge-smoke-*|worker-reuse-*|late-dynamic-agent-*|created-session-*|bootstrap-session-*|bootstrap-wrapper-session-*|broken-channel-*|codex-cli-session-*|project-claude-session-bridge-smoke-*|memtest*|bootstrap-fail*|memphase4-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

reap_idle_dynamic_agents() {
  local threshold="${BRIDGE_DYNAMIC_IDLE_REAP_SECONDS:-3600}"
  local agent
  local session
  local attached
  local idle
  local summary
  local live_agent=""
  local queued=0
  local claimed=0
  local blocked=0
  local changed=1

  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3600
  (( threshold > 0 )) || return 0

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "dynamic" ]] || continue
    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue

    attached="$(bridge_tmux_session_attached_count "$session")"
    [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    (( attached == 0 )) || continue

    summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
    if [[ -n "$summary" ]]; then
      IFS=$'\t' read -r live_agent queued claimed blocked _live_active _live_idle _live_last_seen _live_last_nudge _live_session _live_engine _live_workdir <<<"$summary"
      [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
      [[ "$claimed" =~ ^[0-9]+$ ]] || claimed=0
      [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
      if [[ "$live_agent" != "$agent" ]]; then
        queued=0
        claimed=0
        blocked=0
      fi
    else
      queued=0
      claimed=0
      blocked=0
    fi
    (( queued == 0 && claimed == 0 && blocked == 0 )) || continue

    idle="$(bridge_tmux_session_idle_seconds "$session")"
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
    (( idle >= threshold )) || continue

    if bridge_kill_agent_session "$agent" >/dev/null 2>&1; then
      bridge_archive_dynamic_agent "$agent"
      bridge_remove_dynamic_agent_file "$agent"
      daemon_info "reaped dynamic ${agent} (idle=${idle}s)"
      changed=0
    fi
  done

  return "$changed"
}

reap_idle_orphan_sessions() {
  local threshold="${BRIDGE_ORPHAN_SESSION_REAP_SECONDS:-600}"
  local session
  local attached
  local idle
  local changed=1

  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=600
  (( threshold > 0 )) || return 0

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    session_is_registered_agent_session "$session" && continue
    session_matches_idle_reap_patterns "$session" || continue

    attached="$(bridge_tmux_session_attached_count "$session")"
    [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    (( attached == 0 )) || continue

    idle="$(bridge_tmux_session_idle_seconds "$session")"
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
    (( idle >= threshold )) || continue

    if bridge_tmux_kill_session "$session" >/dev/null 2>&1; then
      sleep 0.2
      if [[ "${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]]; then
        bridge_mcp_orphan_cleanup "orphan-session:${session}" "${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}" 1 >/dev/null 2>&1 || true
      fi
      daemon_info "reaped orphan session ${session} (idle=${idle}s)"
      changed=0
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

  return "$changed"
}

# Issue #791 — surface orphan memory-daily-<agent> cron jobs whose source
# agent is no longer in the live roster. The harvester for such a job fails
# at `agb agent show <agent> --json` and emits a [cron-followup] task every
# day until the operator deletes the cron manually. This sweep enumerates
# memory-daily jobs from the native cron jobs file, cross-checks each one's
# source agent (parsed from the `name` field `memory-daily-<agent>`) against
# the loaded roster (BRIDGE_AGENT_IDS), and surfaces a single [health] task
# to the admin agent with the orphan list + suggested `cron delete` commands.
#
# Surfacing-only by design: we do NOT auto-disable jobs (operator preference
# — idempotent surfacing beats silent mutation). De-duped to one task per
# UTC day via a marker file under BRIDGE_STATE_DIR/memory-daily-orphan-sweep/
# so a daemon that ticks many times per minute does not spam the queue.
process_memory_daily_orphan_sweep() {
  [[ "${BRIDGE_MEMORY_DAILY_ORPHAN_SWEEP_ENABLED:-1}" == "1" ]] || return 0

  local admin_agent
  admin_agent="$(bridge_admin_agent_id)"
  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1

  # Footgun #11 (refs #815 Wave B): tempfile-route orphans_tsv loop.
  local _orphans_tmp=""
  _orphans_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_orphans_tmp'" RETURN

  # The roster is loaded once per daemon-loop iteration before sync_state
  # runs (see the top of the run loop); BRIDGE_AGENT_IDS is therefore the
  # authoritative list for this sweep. Re-load defensively in case a future
  # caller invokes this helper outside the normal loop ordering.
  bridge_load_roster

  local jobs_json
  jobs_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" list --json 2>/dev/null || true)"
  [[ -n "$jobs_json" ]] || return 1

  # Parse memory-daily orphans out of the cron list JSON.
  # Output: tab-separated job_id<TAB>source_agent, one orphan per line.
  # Pass the roster on stdin (newline-delimited) so we do not need to
  # serialize an arbitrarily large array onto argv.
  local roster_stream=""
  local agent_id
  for agent_id in "${BRIDGE_AGENT_IDS[@]:-}"; do
    [[ -n "$agent_id" ]] || continue
    roster_stream+="${agent_id}"$'\n'
  done

  # Embed the roster on argv (newline-joined) rather than piping it on
  # stdin so we do not have to juggle a heredoc + herestring pair on the
  # same `python3` invocation.
  #
  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout (5s — pure JSON diff against the in-memory roster,
  # no IO).
  local orphans_tsv
  orphans_tsv="$(bridge_with_timeout 5 memory_daily_orphan_scan python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" memory-daily-orphan-scan "$jobs_json" "$roster_stream" 2>/dev/null || true)"

  [[ -n "$orphans_tsv" ]] || return 0

  # Dedupe — emit at most one [health] task per UTC day. The marker is
  # written before the queue create call so a partial failure (queue
  # unavailable mid-write) still wins the suppression on the next tick;
  # this is the conservative choice for queue-spam protection.
  local marker_dir="$BRIDGE_STATE_DIR/memory-daily-orphan-sweep"
  mkdir -p "$marker_dir" 2>/dev/null || true
  local today marker
  today="$(date -u '+%Y-%m-%d')"
  marker="$marker_dir/$today.surfaced"
  if [[ -f "$marker" ]]; then
    return 0
  fi

  # Build the body. List one bullet per orphan with the exact `cron delete`
  # command the operator can paste.
  local orphan_count=0
  local body
  body="Orphan memory-daily cron jobs detected — the named source agent is no longer in the loaded roster, so the daily harvester will fail at \`agb agent show <agent> --json\` and emit a [cron-followup] task every day until the cron entry is removed."$'\n\n'
  body+="Run the suggested \`agent-bridge cron delete\` commands to clear:"$'\n\n'

  local job_id source_agent
  printf '%s\n' "$orphans_tsv" > "$_orphans_tmp"
  while IFS=$'\t' read -r job_id source_agent; do
    [[ -n "$job_id" && -n "$source_agent" ]] || continue
    body+="- \`memory-daily-${source_agent}\` (id=${job_id}, source_agent=${source_agent}) — \`agent-bridge cron delete ${job_id}\`"$'\n'
    orphan_count=$(( orphan_count + 1 ))
  done < "$_orphans_tmp"

  (( orphan_count > 0 )) || return 0

  body+=$'\n'"This [health] task is emitted once per UTC day (marker: ${marker}). Re-runs are suppressed until the marker is rotated. Filed by daemon process_memory_daily_orphan_sweep — refs issue #791."

  : > "$marker" 2>/dev/null || true

  local title
  title="[health] orphan memory-daily cron jobs (n=${orphan_count})"

  # Idempotent surface: if today's [health] task is already queued (e.g.,
  # marker file was lost across a state-dir rotation), update in place
  # rather than creating a duplicate.
  local title_prefix="[health] orphan memory-daily cron jobs"
  local existing_id
  existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"

  local reported=0
  if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    if bridge_queue_cli update "$existing_id" --actor daemon --title "$title" --priority normal --note "$body" >/dev/null 2>&1; then
      reported=1
    fi
  else
    if bridge_queue_cli create --to "$admin_agent" --from daemon --priority normal --title "$title" --body "$body" >/dev/null 2>&1; then
      reported=1
    fi
  fi

  if (( reported == 1 )); then
    bridge_audit_log daemon memory_daily_orphan_sweep "$admin_agent" \
      --detail orphan_count="$orphan_count" \
      --detail marker="$marker"
    daemon_info "memory-daily orphan-sweep: surfaced ${orphan_count} orphan job(s) to ${admin_agent}"
    return 0
  fi

  # Roll back the marker so the next tick re-tries — we never want a
  # silent failure to permanently suppress the surface.
  rm -f "$marker" 2>/dev/null || true
  daemon_warn "memory-daily orphan-sweep: failed to emit [health] task (orphan_count=${orphan_count})"
  return 1
}

process_mcp_orphan_cleanup() {
  local enabled="${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}"
  local interval="${BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS:-300}"
  local min_age="${BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS:-300}"
  local notify_threshold="${BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD:-10}"
  local state_dir=""
  local last_file=""
  local report_file=""
  local last_run=0
  local now=0
  local cleanup_json=""
  local parsed=""
  local killed_count=0
  local orphan_count=0
  local freed_mb="0"
  local error_count=0
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local title=""
  local body=""

  [[ "$enabled" == "1" ]] || return 1
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=300
  [[ "$notify_threshold" =~ ^[0-9]+$ ]] || notify_threshold=10

  state_dir="$(bridge_mcp_orphan_cleanup_state_dir)"
  last_file="$(bridge_mcp_orphan_cleanup_last_run_file)"
  report_file="$(bridge_mcp_orphan_cleanup_report_file)"
  mkdir -p "$state_dir"
  now="$(date +%s)"
  if [[ -f "$last_file" ]]; then
    last_run="$(cat "$last_file" 2>/dev/null || printf '0')"
    [[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
  fi
  if (( interval > 0 && now - last_run < interval )); then
    return 1
  fi
  printf '%s\n' "$now" >"$last_file"

  if ! cleanup_json="$(bridge_mcp_orphan_cleanup periodic "$min_age" 1 2>/dev/null)"; then
    bridge_audit_log daemon mcp_orphan_cleanup_failed mcp \
      --detail trigger=periodic \
      --detail min_age_seconds="$min_age"
    return 1
  fi
  printf '%s\n' "$cleanup_json" >"$report_file"

  # Issue #800 Track A: heredoc-stdin → helper subcommand wrapped by
  # bridge_with_timeout (5s — single small JSON file read + count extract).
  parsed="$(bridge_with_timeout 5 mcp_orphan_cleanup_parse python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" mcp-orphan-cleanup-parse "$report_file")" || return 1
  IFS=$'\t' read -r killed_count orphan_count freed_mb error_count <<<"$parsed"
  [[ "$killed_count" =~ ^[0-9]+$ ]] || killed_count=0
  [[ "$orphan_count" =~ ^[0-9]+$ ]] || orphan_count=0
  [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0

  if (( killed_count > 0 )); then
    bridge_audit_log daemon mcp_orphan_cleanup mcp \
      --detail trigger=periodic \
      --detail killed="$killed_count" \
      --detail orphan_count="$orphan_count" \
      --detail freed_mb_estimate="$freed_mb" \
      --detail report_file="$report_file"
    daemon_info "cleaned orphan MCP processes (killed=${killed_count}, freed_mb_estimate=${freed_mb})"
  fi

  if (( error_count > 0 )); then
    bridge_audit_log daemon mcp_orphan_cleanup_errors mcp \
      --detail trigger=periodic \
      --detail errors="$error_count" \
      --detail report_file="$report_file"
  fi

  if (( killed_count >= notify_threshold )) && [[ -n "$admin_agent" ]] && bridge_agent_exists "$admin_agent"; then
    title="[mcp-cleanup] orphan MCP processes cleaned"
    body="고아 MCP 프로세스 ${killed_count}개를 정리했습니다. 예상 회수 메모리: ${freed_mb}MB. report: ${report_file}"
    bridge_dispatch_notification "$admin_agent" "$title" "$body" "" high >/dev/null 2>&1 || true
  fi

  (( killed_count > 0 ))
}

process_queue_gateway_requests() {
  local processed=0

  # Issue #265 proposal A: queue-gateway is mostly local (sqlite + filesystem),
  # but it shells out into bridge-queue.py per pending request — a stuck DB
  # lock or a runaway request batch would otherwise block the loop. Wrap the
  # whole serve-once invocation under one ceiling.
  processed="$(bridge_with_timeout "" queue_gateway_serve_once python3 "$SCRIPT_DIR/bridge-queue-gateway.py" serve-once \
    --root "$(bridge_queue_gateway_root)" \
    --queue-script "$SCRIPT_DIR/bridge-queue.py" \
    --max-requests "${BRIDGE_QUEUE_GATEWAY_MAX_REQUESTS_PER_CYCLE:-100}" 2>/dev/null || printf '0')"
  [[ "$processed" =~ ^[0-9]+$ ]] || processed=0
  if (( processed > 0 )); then
    bridge_audit_log daemon queue_gateway_processed daemon --detail count="$processed"
    return 0
  fi
  return 1
}

bridge_queue_gateway_socket_pid_file() {
  printf '%s/queue-gateway-socket.pid' "$BRIDGE_STATE_DIR"
}

bridge_queue_gateway_socket_log_file() {
  printf '%s/queue-gateway-socket.log' "$BRIDGE_STATE_DIR"
}

bridge_queue_gateway_listener_mode() {
  local mode="${BRIDGE_GATEWAY_LISTENER:-auto}"
  case "$mode" in
    auto|on|off)
      printf '%s' "$mode"
      ;;
    *)
      daemon_warn "invalid BRIDGE_GATEWAY_LISTENER=$mode; falling back to auto"
      printf '%s' "auto"
      ;;
  esac
}

bridge_queue_gateway_listener_requested() {
  local mode
  local transport

  mode="$(bridge_queue_gateway_listener_mode)"
  [[ "$mode" == "off" ]] && return 1
  [[ "$mode" == "on" ]] && return 0
  transport="$(bridge_queue_gateway_transport)"
  [[ "$transport" == "socket" ]] && return 0
  bridge_queue_gateway_agent_socket_transport_configured
}

bridge_queue_gateway_agent_socket_transport_configured() {
  local agent
  local launch_cmd

  for agent in "${BRIDGE_AGENT_IDS[@]:-}"; do
    launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || true)"
    case "$launch_cmd" in
      *BRIDGE_GATEWAY_TRANSPORT=socket*)
        return 0
        ;;
    esac
  done
  return 1
}

bridge_queue_gateway_socket_pid() {
  local pid_file
  pid_file="$(bridge_queue_gateway_socket_pid_file)"
  [[ -f "$pid_file" ]] || return 1
  sed -n '1p' "$pid_file"
}

bridge_queue_gateway_socket_connect_probe() {
  # PR #571 r3 finding 4: real liveness probe. pid+socket-file existence
  # is necessary but not sufficient — a recycled pid plus a leftover
  # socket file (bound by a previous listener that exited without unlink,
  # or `touch`ed by an unrelated tool) both pass the file-only check.
  # This connect probe asks the OS whether *something is actually
  # listening on the socket right now*. SOCK_SEQPACKET connect() against
  # a Unix socket file with no bound listener returns ECONNREFUSED
  # (and against a non-socket regular file returns ENOTSOCK). On
  # success, return 0; on any failure, return 1. The probe is
  # short-lived and side-effect-free (it does not send a payload, so
  # the listener does not need to read or respond).
  local socket_path
  socket_path="$1"
  [[ -n "$socket_path" ]] || return 1
  python3 - "$socket_path" <<'PY' >/dev/null 2>&1
import socket
import sys

path = sys.argv[1]
sock_type = getattr(socket, "SOCK_SEQPACKET", None)
if sock_type is None:
    raise SystemExit(1)
sock = socket.socket(socket.AF_UNIX, sock_type)
try:
    sock.settimeout(1.0)
    sock.connect(path)
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
}

bridge_queue_gateway_socket_is_running() {
  # PR #571 r3 finding 4: defense-in-depth liveness check.
  #   1. pid file present and parseable.
  #   2. recorded pid is alive (`kill -0`).
  #   3. socket file exists at the expected path.
  #   4. connect() to the socket succeeds — i.e. the recorded pid is
  #      *actually* the process bound to that socket, not a recycled
  #      pid that happens to be running an unrelated program.
  # Stages 1-3 alone admit two false-positives:
  #   * recycled pid + leftover socket file (previous listener crashed
  #     without unlinking the bind path; pid was reassigned).
  #   * pid file written manually + socket file `touch`ed (no listener
  #     ever ran).
  # The connect probe rejects both. The caller (start/stop/status) is
  # then expected to remove stale artifacts before its decision becomes
  # idempotent — see bridge_queue_gateway_socket_clean_stale.
  local pid
  local socket_path
  pid="$(bridge_queue_gateway_socket_pid 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  socket_path="$(bridge_queue_gateway_socket_path 2>/dev/null || true)"
  [[ -n "$socket_path" && -S "$socket_path" ]] || return 1
  bridge_queue_gateway_socket_connect_probe "$socket_path" || return 1
  return 0
}

bridge_queue_gateway_socket_clean_stale() {
  # Idempotent stale-state sweep. Removes the pid file + socket file
  # whenever the joint liveness check reports the listener as not
  # actually serving — either because the recorded pid is gone, OR
  # because the connect probe (r3 finding 4) refuses, which catches
  # recycled-pid / stale-socket false-positives that the file-only
  # check would otherwise pass. Safe to call from start (before
  # deciding to spawn) and stop (before claiming success).
  local pid_file
  local socket_path
  local pid

  pid_file="$(bridge_queue_gateway_socket_pid_file)"
  socket_path="$(bridge_queue_gateway_socket_path 2>/dev/null || true)"
  pid="$(bridge_queue_gateway_socket_pid 2>/dev/null || true)"

  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      # Process is gone but pid file lingers → drop it. Also remove the
      # socket because nothing is listening on it; leaving it would
      # confuse the next start (`refuse non-socket` path).
      rm -f "$pid_file"
      if [[ -n "$socket_path" && -S "$socket_path" ]]; then
        rm -f "$socket_path"
      fi
    elif [[ -n "$socket_path" && -S "$socket_path" ]] \
        && ! bridge_queue_gateway_socket_connect_probe "$socket_path"; then
      # pid is alive but connect refuses → recorded pid is not the
      # process actually bound to this socket (recycled pid, or a
      # listener that exited without unlinking). Drop both artifacts so
      # the next start spawns fresh and the next stop does not signal
      # an unrelated process.
      rm -f "$pid_file"
      rm -f "$socket_path"
    fi
  else
    # No pid recorded but a stale socket may exist from a previous run.
    if [[ -n "$socket_path" && -S "$socket_path" ]]; then
      rm -f "$socket_path"
    fi
  fi
}

bridge_start_queue_gateway_socket_listener() {
  local mode
  local transport
  local pid_file
  local log_file
  local socket_path
  local pid
  local wait_seconds
  local attempts
  local i

  mode="$(bridge_queue_gateway_listener_mode)"
  [[ "$mode" == "off" ]] && return 0
  transport="$(bridge_queue_gateway_transport)"
  if [[ "$mode" == "auto" && "$transport" != "socket" ]] \
      && ! bridge_queue_gateway_agent_socket_transport_configured; then
    return 0
  fi
  # Linux-only fail-closed: SO_PEERCRED is the only credential mechanism
  # the gateway implements. On macOS / BSD the listener would start but
  # silently fail every peer-auth check, so refuse to start. The Python
  # listener has the same gate (bridge-queue-gateway.py:_socket_transport_supported)
  # — duplicating it here keeps the startup log explicit instead of
  # surfacing as a Python SystemExit several lines down.
  if [[ "$(bridge_host_platform 2>/dev/null || printf '')" != "Linux" ]]; then
    if [[ "$mode" == "on" || "$transport" == "socket" ]]; then
      daemon_warn "queue gateway socket transport requires Linux; use BRIDGE_GATEWAY_TRANSPORT=file on this platform"
      return 1
    fi
    return 0
  fi
  # Sweep stale pid/socket pairs left by a prior crash so the joint
  # liveness check below makes the right decision.
  bridge_queue_gateway_socket_clean_stale
  if bridge_queue_gateway_socket_is_running; then
    return 0
  fi

  if ! bridge_queue_gateway_runtime_ensure --strict >/dev/null 2>&1; then
    daemon_warn "queue gateway socket runtime is not ready"
    if [[ "$mode" == "on" || "$transport" == "socket" ]]; then
      return 1
    fi
    return 0
  fi

  mkdir -p "$BRIDGE_STATE_DIR"
  pid_file="$(bridge_queue_gateway_socket_pid_file)"
  log_file="$(bridge_queue_gateway_socket_log_file)"
  socket_path="$(bridge_queue_gateway_socket_path)"

  BRIDGE_QUEUE_GATEWAY_SERVER=1 python3 "$SCRIPT_DIR/bridge-queue-gateway.py" socket-server \
    --bridge-home "$BRIDGE_HOME" \
    --queue-script "$SCRIPT_DIR/bridge-queue.py" >>"$log_file" 2>&1 &
  pid="$!"
  printf '%s\n' "$pid" >"$pid_file"

  wait_seconds="${BRIDGE_QUEUE_GATEWAY_SOCKET_START_WAIT_SECONDS:-3}"
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=3
  attempts=$(( wait_seconds * 10 ))
  (( attempts > 0 )) || attempts=1
  # PR #571 r3 finding 4: readiness requires the listener to have
  # actually called bind+listen. `-S` flips true at bind time but a
  # racy reader can still see it before the listener accepts; the
  # connect probe waits for an accepting socket, so a green readiness
  # check here is a proper liveness check, not just a "socket file
  # appeared" check.
  for ((i = 0; i < attempts; i++)); do
    if [[ -S "$socket_path" ]] && kill -0 "$pid" 2>/dev/null \
        && bridge_queue_gateway_socket_connect_probe "$socket_path"; then
      bridge_audit_log daemon queue_gateway_socket_started daemon \
        --detail pid="$pid" \
        --detail socket="$socket_path" >/dev/null 2>&1 || true
      daemon_info "queue gateway socket listener started (pid=$pid socket=$socket_path)"
      return 0
    fi
    sleep 0.1
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  daemon_warn "queue gateway socket listener failed to start"
  if [[ "$mode" == "on" || "$transport" == "socket" ]]; then
    return 1
  fi
  return 0
}

bridge_stop_queue_gateway_socket_listener() {
  # PR #571 r3 finding 4: only signal the recorded pid when ALL three
  # are true: pid alive, socket file present, AND connect probe accepts.
  # The connect probe is the line of defense against signalling an
  # unrelated recycled pid: if pid+socket exist but no listener is
  # bound (recycled pid, leftover socket file, or manual fixture), the
  # recorded pid is not ours to kill — drop the artifacts and return.
  # After signaling (or skipping), unconditionally clear both artifacts
  # so the next start is idempotent.
  local pid_file
  local socket_path
  local pid
  local i

  pid_file="$(bridge_queue_gateway_socket_pid_file)"
  socket_path="$(bridge_queue_gateway_socket_path 2>/dev/null || true)"
  pid="$(bridge_queue_gateway_socket_pid 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
      && [[ -n "$socket_path" && -S "$socket_path" ]] \
      && bridge_queue_gateway_socket_connect_probe "$socket_path"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" >/dev/null 2>&1 || true
    for ((i = 0; i < 30; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    bridge_audit_log daemon queue_gateway_socket_stopped daemon \
      --detail pid="$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$pid_file"
  if [[ -n "$socket_path" && -S "$socket_path" ]]; then
    rm -f "$socket_path"
  fi
}

cmd_sync_cycle() {
  local snapshot_file
  local ready_agents_file
  local nudge_output=""
  local summary_output=""
  local agent
  local session
  local queued
  local claimed
  local idle
  local nudge_key
  local changed=1
  local cron_sync_timeout="${BRIDGE_CRON_SYNC_TIMEOUT:-30}"
  local timeout_bin=""
  # Footgun #11 (refs #815 Wave B): tempfile-route nudge_output loop.
  local _nudge_tmp=""
  _nudge_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_nudge_tmp'" RETURN

  # The daemon is long-lived, so dynamic agents created after startup will not
  # exist in memory unless we reload the roster each cycle.
  # Issue #848: per-process roster memoization means the bare
  # bridge_load_roster call would no-op after the first cycle —
  # invalidate the cache here so each cycle observes fresh disk state.
  BRIDGE_DAEMON_LAST_STEP="load_roster"
  bridge_roster_cache_invalidate
  bridge_load_roster

  # Discord relay runs FIRST — lowest-latency path for DM wake
  BRIDGE_DAEMON_LAST_STEP="discord_relay"
  bridge_discord_relay_step || true

  # Issue #597 Track B: PreCompact channel auto-notify observer. Runs after
  # the Discord relay (so any inbound user activity is already mirrored into
  # the activity index when the route lookup runs) and before bridge-sync,
  # which is the cheap "I/O is mostly done for this cycle" boundary.
  BRIDGE_DAEMON_LAST_STEP="precompact_events"
  process_precompact_events || true

  BRIDGE_DAEMON_LAST_STEP="bridge_sync"
  # Refs #815 Wave B: wrap with bridge_with_timeout so a stuck child cannot
  # wedge the daemon main loop. 30s ceiling — bridge-sync.sh reconciles roster
  # + state under normal conditions in <1s; timeouts here are pathological.
  bridge_with_timeout 30 bridge_sync "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  # Issue #848: bridge-sync.sh ran as a child process and may have
  # touched the roster files; invalidate so this in-loop reload picks
  # up any newly-registered dynamic agents.
  bridge_roster_cache_invalidate
  bridge_load_roster
  BRIDGE_DAEMON_LAST_STEP="queue_gateway"
  if process_queue_gateway_requests; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="reconcile_idle_markers"
  bridge_reconcile_idle_markers || true
  BRIDGE_DAEMON_LAST_STEP="bootstrap_recovery"
  recover_claude_bootstrap_blockers || true
  # Issue #589: prompt-ready latch reconciliation runs BEFORE the
  # attention-spool flush so an agent whose prompt just became visible
  # gets latched and its spooled wakes drain in the same sync tick.
  BRIDGE_DAEMON_LAST_STEP="prompt_ready_reconcile"
  reconcile_prompt_ready_latches || true
  BRIDGE_DAEMON_LAST_STEP="attention_flush"
  flush_pending_attention_spools || true
  BRIDGE_DAEMON_LAST_STEP="channel_health"
  process_channel_health || true
  BRIDGE_DAEMON_LAST_STEP="plugin_liveness"
  process_plugin_liveness || true

  BRIDGE_DAEMON_LAST_STEP="nudge_scan"
  snapshot_file="$(mktemp)"
  ready_agents_file="$(mktemp)"
  bridge_write_agent_snapshot "$snapshot_file"
  # r14 codex Probe 2 — daemon must not hard-fail on a per-cycle write
  # (design contract: daemon never exits its loop). But the previous
  # silent swallow erased the matrix hard-fail signal that r12/r13
  # added. Capture rc + emit a one-line audit so operator can catch
  # matrix-not-applied via `agent-bridge audit follow` instead of
  # cycling on a green-looking daemon.
  if ! bridge_write_idle_ready_agents "$ready_agents_file"; then
    bridge_audit_log daemon daemon_step_warning daemon \
      --detail step="nudge_scan_idle_ready" \
      --detail reason="bridge_write_idle_ready_agents non-zero (matrix not applied or writer error)" \
      2>/dev/null || true
    daemon_log_event "nudge_scan: idle_ready writer failed (matrix-aware fix #781); cycle continues"
  fi
  nudge_output="$(bridge_task_daemon_step "$snapshot_file" "$ready_agents_file" 2>/dev/null || true)"
  rm -f "$snapshot_file"
  rm -f "$ready_agents_file"

  BRIDGE_DAEMON_LAST_STEP="cron_dispatch_workers"
  start_cron_dispatch_workers || true

  BRIDGE_DAEMON_LAST_STEP="nudge_agents"
  printf '%s\n' "$nudge_output" > "$_nudge_tmp"
  while IFS=$'\t' read -r agent session queued claimed idle nudge_key; do
    [[ -z "$agent" || -z "$session" ]] && continue
    if ! bridge_tmux_session_exists "$session"; then
      continue
    fi

    if nudge_agent_session "$agent" "$session" "$queued" "$claimed" "$idle" "$nudge_key"; then
      continue
    fi
    case "$?" in
      2)
        continue
        ;;
    esac
  done < "$_nudge_tmp"

  BRIDGE_DAEMON_LAST_STEP="queue_summary"
  summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null || true)"
  BRIDGE_DAEMON_LAST_STEP="memory_refresh"
  if process_memory_daily_refresh_requests; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="stall_reports"
  if [[ -n "$summary_output" ]] && process_stall_reports "$summary_output"; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="permission_timeout_fanout"
  if process_permission_task_timeout_fanout; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="context_pressure_scan"
  if [[ -n "$summary_output" ]] && process_context_pressure_reports "$summary_output"; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="heartbeats"
  if refresh_agent_heartbeats; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="watchdog"
  if process_watchdog_report; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="crash_reports"
  if process_crash_reports; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="claude_token_recovery"
  if process_claude_token_recovery; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="usage_monitor"
  if process_usage_monitor; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="daily_backup"
  if process_daily_backup; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="release_monitor"
  if process_release_monitor; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="on_demand_agents"
  if [[ -n "$summary_output" ]] && process_on_demand_agents "$summary_output"; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="reap_dynamic"
  if reap_idle_dynamic_agents; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="reap_orphan_sessions"
  if reap_idle_orphan_sessions; then
    changed=0
  fi
  BRIDGE_DAEMON_LAST_STEP="mcp_orphan_cleanup"
  if process_mcp_orphan_cleanup; then
    changed=0
  fi
  if [[ "$changed" == "0" ]]; then
    BRIDGE_DAEMON_LAST_STEP="post_sync"
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  fi

  # Cron sync runs LAST, in the background with a timeout, so it never blocks
  # relay/auto-start above.  Only one sync runs at a time (PID-file guard).
  BRIDGE_DAEMON_LAST_STEP="cron_sync"
  if bridge_cron_sync_enabled; then
    local cron_sync_pid_file="$BRIDGE_STATE_DIR/cron-sync.pid"
    local cron_sync_running=0
    if [[ -f "$cron_sync_pid_file" ]]; then
      local prev_pid
      prev_pid="$(<"$cron_sync_pid_file")"
      if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
        cron_sync_running=1
      else
        rm -f "$cron_sync_pid_file"
      fi
    fi
    if (( cron_sync_running == 0 )); then
      timeout_bin="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
      bridge_audit_log daemon cron_sync_started "cron-sync" \
        --detail timeout_seconds="$cron_sync_timeout"
      (
        sync_started_ts="$(date +%s)"
        sync_status=0
        timed_out=0
        if [[ -n "$timeout_bin" ]]; then
          "$timeout_bin" "$cron_sync_timeout" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" sync >/dev/null 2>&1 || sync_status=$?
        else
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" sync >/dev/null 2>&1 || sync_status=$?
        fi
        if [[ "$sync_status" == "124" || "$sync_status" == "137" ]]; then
          timed_out=1
        fi
        bridge_audit_log daemon cron_sync_finished "cron-sync" \
          --detail status="$sync_status" \
          --detail timed_out="$timed_out" \
          --detail duration_seconds="$(( $(date +%s) - sync_started_ts ))"
        rm -f "$cron_sync_pid_file"
      ) &
      echo "$!" >"$cron_sync_pid_file"
    else
      bridge_audit_log daemon cron_sync_skipped "cron-sync" \
        --detail reason=already_running \
        --detail pid="${prev_pid:-}"
    fi
  fi

  # Issue #791 — surface orphan memory-daily-<agent> cron jobs whose source
  # agent is no longer in the loaded roster. Runs after cron_sync (which
  # only normalizes runtime state, never deletes job entries) so the orphan
  # list reflects the post-sync truth. Best-effort: any failure is logged
  # and must not abort the rest of the sync pass.
  BRIDGE_DAEMON_LAST_STEP="memory_daily_orphan_sweep"
  process_memory_daily_orphan_sweep 2>/dev/null || daemon_warn "memory-daily orphan sweep failed"

  BRIDGE_DAEMON_LAST_STEP="dashboard_post"
  bridge_dashboard_post_if_changed "$summary_output" || true
}

# --- Silence-watchdog sibling (issue #265 proposal C) ----------------------
# A second-line defence against new daemon-hang vectors that slip past the
# proposal A per-call timeout layer. The Python sibling tails audit.jsonl
# for the `daemon_tick` heartbeats from PR #274 and restarts the daemon if
# none has landed within BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS. Lifecycle
# mirrors the cron-sync child PID-file pattern: cmd_start spawns it after
# the daemon is confirmed running, cmd_stop sweeps it after the daemon
# pids. The supervisor itself is a `python3 bridge-watchdog-silence.py run`
# process so `bridge_daemon_all_pids` (matches `bridge-daemon.sh run$`)
# never confuses it with the daemon proper.

bridge_silence_watchdog_pid_file() {
  printf '%s/silence-watchdog.pid' "$BRIDGE_STATE_DIR"
}

bridge_silence_watchdog_enabled() {
  local interval="${BRIDGE_DAEMON_HEARTBEAT_SECONDS:-60}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
  if (( interval == 0 )); then
    return 1
  fi
  if [[ "${BRIDGE_DAEMON_SILENCE_WATCHDOG_DISABLED:-0}" == "1" ]]; then
    return 1
  fi
  [[ -f "$SCRIPT_DIR/bridge-watchdog-silence.py" ]] || return 1
  return 0
}

bridge_start_silence_watchdog() {
  bridge_silence_watchdog_enabled || return 0

  local pid_file
  pid_file="$(bridge_silence_watchdog_pid_file)"

  # Reap stale pid file from a prior run that exited without cleanup.
  if [[ -f "$pid_file" ]]; then
    local prev_pid
    prev_pid="$(<"$pid_file")"
    if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
      daemon_info "silence watchdog already running (pid=$prev_pid)"
      return 0
    fi
    rm -f "$pid_file"
  fi

  mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  local log_file="$BRIDGE_LOG_DIR/silence-watchdog.log"
  # Run detached so it survives the parent shell exiting after `start`.
  if [[ "$(uname -s)" != "Darwin" ]] && command -v setsid >/dev/null 2>&1; then
    setsid python3 "$SCRIPT_DIR/bridge-watchdog-silence.py" run </dev/null >>"$log_file" 2>&1 &
  else
    nohup python3 "$SCRIPT_DIR/bridge-watchdog-silence.py" run </dev/null >>"$log_file" 2>&1 &
    disown || true
  fi
  local watchdog_pid=$!
  echo "$watchdog_pid" >"$pid_file"
  bridge_audit_log daemon daemon_silence_watchdog_started daemon \
    --detail pid="$watchdog_pid" \
    --detail threshold_seconds="${BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS:-600}"
  daemon_info "silence watchdog started (pid=$watchdog_pid)"
}

bridge_stop_silence_watchdog() {
  local pid_file
  pid_file="$(bridge_silence_watchdog_pid_file)"
  [[ -f "$pid_file" ]] || return 0

  local pid
  pid="$(<"$pid_file")"
  rm -f "$pid_file"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    bridge_audit_log daemon daemon_silence_watchdog_stopped daemon \
      --detail pid="$pid" || true
    daemon_info "silence watchdog stopped (pid=$pid)"
  fi
}

bridge_daemon_supplementary_group_preflight() {
  # Issue #712: refuse `bridge-daemon.sh start` when the *current shell*
  # is missing v2 isolation supplementary groups that the operator's
  # passwd entry says they belong to. This is the v1→v2 stale-shell
  # failure mode #668's migration-time warn does not cover (operator
  # later restarts the daemon from the same pre-upgrade shell, daemon
  # comes up "half-alive", reads of group=ab-controller mode 0640 env
  # files trip Permission denied on bridge-state.sh:997).
  #
  # Returns 0 (PASS) — start may proceed — when:
  #   - BRIDGE_DAEMON_FORCE_START_WITH_STALE_GROUPS is truthy (debug hatch), OR
  #   - BRIDGE_DISABLE_ISOLATION is truthy (isolation off entirely), OR
  #   - the host is not Linux (this stale-cache class is a Linux usermod
  #     symptom; macOS has its own dseditgroup membership-refresh story
  #     handled outside this preflight), OR
  #   - getent / id are unavailable (cannot reason about groups; do no
  #     harm), OR
  #   - the controller group (ab-controller) does not exist on the host
  #     (linux-user isolation is not deployed here — e.g. fresh install
  #     that never ran v2 group setup).
  #
  # Returns non-zero (REFUSE) when at least one v2 group from the
  # operator's passwd-driven static group set is absent from the
  # current process's supplementary GID set.
  case "${BRIDGE_DAEMON_FORCE_START_WITH_STALE_GROUPS:-}" in
    1|yes|YES|Yes|on|ON|On|true|TRUE|True)
      # Silent skip: operator opted in to FORCE-start; do not pollute
      # daemon stderr with a warn line on every start.
      return 0
      ;;
  esac
  if declare -F bridge_isolation_disabled_by_env >/dev/null 2>&1 \
      && bridge_isolation_disabled_by_env; then
    return 0
  fi
  [[ "$(uname -s)" == "Linux" ]] || return 0
  command -v getent >/dev/null 2>&1 || return 0
  command -v id >/dev/null 2>&1 || return 0

  local controller_group="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
  local agent_group_prefix="${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}"
  local shared_group="${BRIDGE_SHARED_GROUP:-ab-shared}"

  # If the controller group itself is absent, linux-user isolation is
  # not deployed on this host. Treat as not-applicable (PASS).
  getent group "$controller_group" >/dev/null 2>&1 || return 0

  # Static (passwd-driven) supplementary group set for the operator —
  # includes any group memberships added by `usermod -aG` even when the
  # current shell hasn't picked them up yet.
  local operator="${USER:-$(id -un 2>/dev/null || true)}"
  [[ -n "$operator" ]] || return 0
  local static_groups
  static_groups="$(id -nG -- "$operator" 2>/dev/null || true)"
  [[ -n "$static_groups" ]] || return 0

  # Current process supplementary GID set (numeric). On Linux `id -G`
  # without a user argument reflects the running process's kernel-cached
  # supp set, which is exactly the set the spawned daemon will inherit.
  local proc_gids
  proc_gids="$(id -G 2>/dev/null || true)"
  [[ -n "$proc_gids" ]] || return 0

  local missing=()
  local g
  for g in $static_groups; do
    case "$g" in
      "$controller_group"|"$shared_group"|"${agent_group_prefix}"*)
        local gid
        gid="$(getent group "$g" 2>/dev/null | awk -F: '{print $3}')"
        [[ -n "$gid" ]] || continue
        # Word-boundary match against the space-separated proc_gids.
        case " $proc_gids " in
          *" $gid "*) ;;
          *) missing+=("$g") ;;
        esac
        ;;
    esac
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  daemon_warn ""
  daemon_warn "============================================================"
  daemon_warn "[오류] 데몬을 시작할 수 없습니다: 현재 셸의 supplementary group set이"
  daemon_warn "  v2 isolation 그룹들을 포함하지 않습니다."
  daemon_warn "누락: ${missing[*]}"
  daemon_warn ""
  daemon_warn "셸을 재로그인 (예: exec sudo -i -u \$USER bash) 후 다시 시도하세요."
  daemon_warn ""
  daemon_warn "[error] daemon refused to start: current shell's supplementary"
  daemon_warn "  group set is missing v2 isolation groups."
  daemon_warn "Missing: ${missing[*]}"
  daemon_warn "Re-login (e.g. \`exec sudo -i -u \$USER bash\`) and retry."
  daemon_warn ""
  daemon_warn "자세한 진단 / Diagnostic:"
  daemon_warn "  cat /proc/\$\$/status | grep ^Groups"
  daemon_warn "  id -G"
  daemon_warn ""
  daemon_warn "디버깅용 우회: BRIDGE_DAEMON_FORCE_START_WITH_STALE_GROUPS=1"
  daemon_warn "(권한 오류가 isolated agent history env 읽기에서 다시 발생할 수 있음)"
  daemon_warn "============================================================"
  bridge_audit_log daemon daemon_start_refused daemon \
    --detail reason=stale_supplementary_groups \
    --detail missing="${missing[*]}" >/dev/null 2>&1 || true
  return 1
}

cmd_start() {
  local start_deadline
  local recorded_pid=""
  local recorded_cmdline=""

  # Issue #683: post-upgrade verification (start → status) reported
  # contradictory state — start said "already running pid=NNNN", status said
  # "stopped socket_listener=off". Two failure modes converge here:
  #   1. Stale pid file from a prior daemon that exited without cleanup
  #      (kill -0 returns 1).
  #   2. Pid recycling: kill -0 succeeds for a recorded pid that the OS has
  #      reassigned to an unrelated process (different cmdline).
  # Reap the pid file in both cases before deferring to bridge_daemon_is_running
  # so start and status agree on daemon-up determination.
  recorded_pid="$(bridge_daemon_recorded_pid)"
  if [[ -n "$recorded_pid" ]]; then
    if ! kill -0 "$recorded_pid" 2>/dev/null; then
      daemon_info "stale pid file (pid=${recorded_pid} no longer alive), starting fresh"
      rm -f "$BRIDGE_DAEMON_PID_FILE"
      recorded_pid=""
    else
      recorded_cmdline="$(ps -p "$recorded_pid" -o args= 2>/dev/null || true)"
      if [[ -n "$recorded_cmdline" && "$recorded_cmdline" != *"bridge-daemon.sh run"* ]]; then
        daemon_info "stale pid file (pid=${recorded_pid} belongs to non-bridge process), starting fresh"
        rm -f "$BRIDGE_DAEMON_PID_FILE"
        recorded_pid=""
      fi
    fi
  fi

  if bridge_daemon_is_running; then
    # Issue #815 Wave C: detect pid-alive-but-tick-stale and auto-repair.
    # Before Wave C, `agb daemon start` only checked pid liveness and
    # returned "already running" even when the daemon's main loop had
    # been wedged for hours (issue #815 evidence: heartbeat stuck 18h
    # while pid still alive). Now we also check tick freshness; if the
    # pid is alive but the heartbeat is stale by more than the configured
    # threshold, treat as a silent-but-alive condition and run the repair
    # sequence: kill the silent daemon, clean state, restart fresh.
    local running_pid
    running_pid="$(bridge_daemon_pid)"
    local tick_age=""
    tick_age="$(bridge_daemon_heartbeat_age_seconds 2>/dev/null || true)"
    local fresh_threshold="${BRIDGE_DAEMON_TICK_FRESH_SECONDS:-120}"
    [[ "$fresh_threshold" =~ ^[0-9]+$ ]] || fresh_threshold=120

    local is_silent="false"
    if [[ -z "$tick_age" ]]; then
      # No parseable heartbeat. Either:
      #   (a) `state/daemon.heartbeat` is missing entirely (real wedge or
      #       fresh start before the initial-tick write), or
      #   (b) the file exists but holds an unparseable value (legacy
      #       ISO format the heartbeat parser couldn't normalize; the
      #       BSD `date -j -f` does not accept colonized offsets on
      #       macOS before the r2 fix landed, so a real wedged daemon
      #       could surface here).
      # Either way, use process-age as the tie-breaker: treat as silent
      # only if the daemon process has been alive longer than the
      # start-race grace window (5s). A freshly-started daemon writes
      # the heartbeat within ~1s (cmd_run emits an initial tick before
      # the main loop), so 5s covers the race without masking a real
      # wedge. Codex r1 catch: do NOT gate the process-age fallback on
      # heartbeat-file absence — that mapped (file exists + unparseable)
      # to `is_silent=false` and let `cmd_start` return 0 on a wedged
      # daemon. The fallback fires whenever tick_age is empty.
      local proc_age_seconds=""
      if [[ -r "/proc/$running_pid/stat" ]]; then
        local now_epoch boot_epoch start_jiffies clk_tck
        now_epoch="$(date +%s)"
        # Field 22 is starttime in clock ticks since boot.
        start_jiffies="$(awk '{print $22}' "/proc/$running_pid/stat" 2>/dev/null || true)"
        clk_tck="$(getconf CLK_TCK 2>/dev/null || printf '%s' 100)"
        if [[ "$start_jiffies" =~ ^[0-9]+$ ]] && [[ "$clk_tck" =~ ^[0-9]+$ ]] && (( clk_tck > 0 )); then
          boot_epoch="$(awk '/btime/ {print $2}' /proc/stat 2>/dev/null || true)"
          if [[ "$boot_epoch" =~ ^[0-9]+$ ]]; then
            proc_age_seconds=$(( now_epoch - (boot_epoch + start_jiffies / clk_tck) ))
          fi
        fi
      else
        local etime_seconds
        etime_seconds="$(ps -o etime= -p "$running_pid" 2>/dev/null | awk '{print $1}')"
        # etime format: [[DD-]HH:]MM:SS
        if [[ "$etime_seconds" =~ ^([0-9]+-)?(([0-9]+):)?([0-9]+):([0-9]+)$ ]]; then
          local d=${BASH_REMATCH[1]%-} h=${BASH_REMATCH[3]} m=${BASH_REMATCH[4]} s=${BASH_REMATCH[5]}
          d=${d:-0}; h=${h:-0}
          proc_age_seconds=$(( d * 86400 + h * 3600 + m * 60 + s ))
        fi
      fi
      if [[ "$proc_age_seconds" =~ ^[0-9]+$ ]] && (( proc_age_seconds > 5 )); then
        is_silent="true"
      fi
    elif (( tick_age > fresh_threshold )); then
      is_silent="true"
    fi

    if [[ "$is_silent" == "true" ]]; then
      printf '[daemon] silent daemon detected (pid=%s, tick stale by %ss) — repair sequence: kill + restart\n' \
        "$running_pid" "${tick_age:-unknown}" >&2
      bridge_audit_log daemon daemon_start_repair_silent daemon \
        --detail pid="$running_pid" \
        --detail tick_age_seconds="${tick_age:-unknown}" \
        --detail threshold_seconds="$fresh_threshold" 2>/dev/null || true

      # Stop the silent daemon. We bypass cmd_stop here because cmd_stop
      # has a guard against stopping with active agents (issues
      # #314/#315) that we explicitly want to override on a wedged
      # daemon — the silence watchdog uses `stop --force` for the same
      # reason. We mirror that intent inline so the repair path is
      # legible and doesn't require cmd_stop to learn a new flag.
      if kill -TERM "$running_pid" 2>/dev/null; then
        local deadline=$(( $(date +%s) + 5 ))
        while (( $(date +%s) <= deadline )); do
          kill -0 "$running_pid" 2>/dev/null || break
          sleep 0.2
        done
        if kill -0 "$running_pid" 2>/dev/null; then
          kill -KILL "$running_pid" 2>/dev/null || true
          sleep 0.2
        fi
      fi

      # Stop the silence watchdog cleanly so the restart sequence
      # starts a fresh supervisor with the new daemon pid in view.
      bridge_stop_silence_watchdog 2>/dev/null || true

      # Clean stale state so the restarted daemon does not inherit a
      # confusing heartbeat / pid that would skew the next health check.
      rm -f "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null || true
      rm -f "$BRIDGE_STATE_DIR/daemon.heartbeat" 2>/dev/null || true

      bridge_audit_log daemon daemon_start_repair_silent_killed daemon \
        --detail prior_pid="$running_pid" 2>/dev/null || true
      daemon_info "silent daemon repaired (killed pid=$running_pid); proceeding to fresh start"
      # Fall through to the start path below.
    else
      daemon_info "bridge daemon already running (pid=$running_pid)"
      bridge_start_silence_watchdog || true
      return 0
    fi
  fi

  # Issue #712: stale supplementary-group cache after v1→v2 migration
  # leaves the daemon "half-alive" — it starts, but every read of an
  # isolated-agent state file (group=ab-controller mode 0640) errors
  # with Permission denied. Refuse to start when the current shell's
  # supp set is missing v2 isolation groups it should have per passwd.
  if ! bridge_daemon_supplementary_group_preflight; then
    bridge_die "bridge daemon start refused: stale supplementary groups (set BRIDGE_DAEMON_FORCE_START_WITH_STALE_GROUPS=1 to override)"
  fi

  mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  if [[ "$(uname -s)" != "Darwin" ]] && command -v setsid >/dev/null 2>&1; then
    setsid "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
  else
    nohup "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
    disown || true
  fi

  start_deadline=$(( $(date +%s) + BRIDGE_DAEMON_START_WAIT_SECONDS ))
  while (( $(date +%s) <= start_deadline )); do
    if bridge_daemon_is_running; then
      bridge_audit_log daemon daemon_started daemon \
        --detail pid="$(bridge_daemon_pid)" \
        --detail interval_seconds="$BRIDGE_DAEMON_INTERVAL"
      daemon_info "bridge daemon started (pid=$(bridge_daemon_pid))"
      bridge_start_silence_watchdog || true
      return 0
    fi
    sleep 0.1
  done

  bridge_die "bridge daemon start failed"
}

cmd_run() {
  local cycle_status

  # Signal traps record the received signal name so the EXIT trap can report
  # *why* we're exiting. We keep the existing `daemon_log_event` calls for
  # backwards compatibility with the crash-log file.
  # Signal traps: guard daemon_log_event so an unwritable crash log cannot
  # keep us from reaching `exit 0` under set -e (PR #198 review).
  trap '_bridge_daemon_on_signal TERM; daemon_log_event "received SIGTERM" 2>/dev/null || true; exit 0' TERM
  trap '_bridge_daemon_on_signal INT;  daemon_log_event "received SIGINT"  2>/dev/null || true; exit 0' INT
  trap '_bridge_daemon_on_signal HUP;  daemon_log_event "received SIGHUP"  2>/dev/null || true; exit 0' HUP
  # ERR trap captures the failing source:line under `set -E` (inherited by
  # functions) so we can attribute `set -e` aborts. Guarded against recursion.
  set -E
  trap '_bridge_daemon_on_err' ERR
  # EXIT trap emits the structured exit record (audit + launchagent log) and
  # tidies the pid file.
  trap '_bridge_daemon_on_exit' EXIT

  BRIDGE_DAEMON_LAST_STEP="startup"
  echo "$$" >"$BRIDGE_DAEMON_PID_FILE"
  BRIDGE_DAEMON_LAST_STEP="queue_gateway_socket_listener"
  bridge_start_queue_gateway_socket_listener
  BRIDGE_DAEMON_LAST_STEP="startup"

  # Issue #265: emit a periodic audit `daemon_tick` so external monitoring
  # (and bridge-supervisor) can detect a hung main loop. Without this, a
  # blocked subprocess (the canonical example: tmux send-keys hanging on a
  # closed Discord SSL pipe) leaves the daemon process alive but silent for
  # tens of hours — every operator-facing health check still reports
  # "running" and no cron fires. The tick is throttled (default 60s) so the
  # audit log doesn't grow by 1 line per BRIDGE_DAEMON_INTERVAL second.
  local heartbeat_interval="${BRIDGE_DAEMON_HEARTBEAT_SECONDS:-60}"
  [[ "$heartbeat_interval" =~ ^[0-9]+$ ]] || heartbeat_interval=60
  local last_heartbeat_ts=0
  local now_ts

  # Issue #815 Wave C: emit one initial daemon_tick + heartbeat write BEFORE
  # the first sync cycle so the post-restart healthy state is observable
  # within ~1s, not after the first periodic boundary. Without this, a
  # caller that runs `daemon stop && daemon start && daemon status` in
  # quick succession sees `health: silent` for up to 60s after a successful
  # restart, defeating the auto-repair signal.
  now_ts="$(date +%s)"
  bridge_audit_log daemon daemon_tick daemon \
    --detail loop_step="startup_initial_tick" \
    --detail interval_seconds="$BRIDGE_DAEMON_INTERVAL" \
    --detail heartbeat_interval_seconds="$heartbeat_interval" \
    2>/dev/null || true
  printf '%s\n' "$now_ts" 2>/dev/null >"$BRIDGE_STATE_DIR/daemon.heartbeat" || true
  last_heartbeat_ts="$now_ts"

  while true; do
    BRIDGE_DAEMON_LAST_STEP="sync_cycle"
    if cmd_sync_cycle; then
      :
    else
      cycle_status=$?
      daemon_log_event "sync cycle failed with exit=$cycle_status"
    fi
    now_ts="$(date +%s)"
    if (( heartbeat_interval > 0 )) && (( now_ts - last_heartbeat_ts >= heartbeat_interval )); then
      bridge_audit_log daemon daemon_tick daemon \
        --detail loop_step="$BRIDGE_DAEMON_LAST_STEP" \
        --detail interval_seconds="$BRIDGE_DAEMON_INTERVAL" \
        --detail heartbeat_interval_seconds="$heartbeat_interval" \
        2>/dev/null || true
      # Issue #265 proposal D: also touch a heartbeat file so an OS-level
      # watcher (launchd LaunchAgent on macOS, systemd .timer unit on Linux)
      # can compare its mtime against a staleness threshold and restart the
      # daemon when the main loop stops advancing. The file lives outside the
      # daemon process tree, so a hung daemon cannot interfere with it being
      # observed. See scripts/bridge-daemon-liveness.sh and
      # scripts/install-daemon-liveness-{launchagent,systemd}.sh.
      printf '%s\n' "$now_ts" 2>/dev/null >"$BRIDGE_STATE_DIR/daemon.heartbeat" || true
      last_heartbeat_ts="$now_ts"
    fi
    BRIDGE_DAEMON_LAST_STEP="idle_sleep"
    sleep "$BRIDGE_DAEMON_INTERVAL"
  done
}

cmd_stop() {
  local recorded_pid
  local entry
  local -a pids=()
  local killed=0
  local failed=0
  local orphans=0
  local first_pid=""
  local is_orphan
  local force=0
  local arg

  # Issue #314 Layer 3 / #315 Track 3 — accept --force/-f to bypass the
  # active-agent guard below. Sanctioned callers (the upgrader, the daemon
  # liveness watchdog, the repair-task-db / deploy-live-install scripts)
  # must pass --force so they aren't blocked. Bare operator/admin-agent
  # invocations get the guard.
  for arg in "$@"; do
    case "$arg" in
      --force|-f)
        force=1
        ;;
      *)
        daemon_warn "stop: unknown argument: $arg"
        return 2
        ;;
    esac
  done

  # Issue #314 Layer 3 / #315 Track 3 — Active-agent guard.
  # A bare `bridge-daemon.sh stop` on a host with running always-on agents
  # is the unsafe path documented in the #314 incident: a subsequent daemon
  # restart picks up stale AGENT_SESSION_IDs and `claude --resume` lands on
  # the wrong (often context-saturated) session. The sanctioned entrypoint
  # is `agent-bridge upgrade --apply`, which orchestrates daemon stop+start
  # internally. Refuse the bare call when active agents exist; require
  # --force for the recovery / wedged-host case.
  if (( force != 1 )); then
    local active_count=0
    active_count="$(bridge_active_agent_ids | grep -c . || true)"
    if [[ "$active_count" =~ ^[0-9]+$ ]] && (( active_count > 0 )); then
      daemon_warn ""
      daemon_warn "============================================================"
      daemon_warn "Refusing to stop the bridge daemon: $active_count active agent session(s) detected."
      daemon_warn ""
      daemon_warn "On a host with running agents, use the sanctioned upgrade entrypoint:"
      daemon_warn "    agent-bridge upgrade --apply"
      daemon_warn ""
      daemon_warn "It handles daemon stop + restart + agent re-launch internally"
      daemon_warn "without the cascade risks documented in issues #314 / #315."
      daemon_warn ""
      daemon_warn "If you really intend to stop the daemon directly (e.g. recovery"
      daemon_warn "or wedged-host scenario), re-run with --force:"
      daemon_warn "    bash bridge-daemon.sh stop --force"
      daemon_warn "============================================================"
      bridge_audit_log daemon daemon_stop_refused daemon \
        --detail reason=active_agents_present \
        --detail active_count="$active_count" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  # Stop the silence watchdog *before* killing the daemon so it doesn't
  # observe the stop-induced silence and race a fresh start against ours.
  bridge_stop_silence_watchdog || true
  bridge_stop_queue_gateway_socket_listener || true

  recorded_pid="$(bridge_daemon_recorded_pid)"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    pids+=("$entry")
  done < <(bridge_daemon_all_pids)

  if (( ${#pids[@]} == 0 )); then
    if [[ -n "$recorded_pid" ]]; then
      rm -f "$BRIDGE_DAEMON_PID_FILE"
      daemon_info "stale bridge daemon pid removed"
      return 0
    fi
    daemon_info "bridge daemon not running"
    return 0
  fi

  first_pid="${pids[0]}"
  for entry in "${pids[@]}"; do
    is_orphan=1
    if [[ -n "$recorded_pid" && "$entry" == "$recorded_pid" ]]; then
      is_orphan=0
    fi
    if (( is_orphan == 1 )); then
      orphans=$(( orphans + 1 ))
    fi
    if kill -0 "$entry" 2>/dev/null; then
      if kill "$entry" 2>/dev/null; then
        killed=$(( killed + 1 ))
      else
        failed=$(( failed + 1 ))
      fi
    fi
  done

  rm -f "$BRIDGE_DAEMON_PID_FILE"
  bridge_audit_log daemon daemon_stopped daemon \
    --detail pid="$first_pid" \
    --detail killed_count="$killed" \
    --detail failed_count="$failed" \
    --detail orphan_count="$orphans" \
    --detail recorded_pid="${recorded_pid:-}"

  if (( orphans > 0 )); then
    daemon_info "bridge daemon stopped (killed=$killed, swept $orphans orphan(s) outside pid-file)"
  else
    daemon_info "bridge daemon stopped (pid=$first_pid)"
  fi
}

cmd_status() {
  local socket_status="off"
  if bridge_queue_gateway_listener_requested; then
    socket_status="stopped"
    if bridge_queue_gateway_socket_is_running; then
      socket_status="running"
    fi
  fi
  if bridge_daemon_is_running; then
    echo "running pid=$(bridge_daemon_pid) interval=${BRIDGE_DAEMON_INTERVAL}s db=${BRIDGE_TASK_DB} socket_listener=${socket_status}"
  else
    echo "stopped socket_listener=${socket_status}"
  fi

  # Issue #815 Wave C: surface tick freshness + derived health so
  # operators can answer "is the daemon actually doing work?" not just
  # "is the pid alive?". The fields are additive — existing parsers that
  # key off `running pid=` / `stopped` are unaffected. The single-line
  # `health: <ok|silent|down> ...` summary is the human-facing answer;
  # the three key=value lines preserve the grep-grammar for tooling.
  local health_age="" health_fresh="" health_state=""
  local line
  while IFS= read -r line; do
    case "$line" in
      tick_age_seconds=*) health_age="${line#tick_age_seconds=}" ;;
      tick_fresh=*)       health_fresh="${line#tick_fresh=}" ;;
      health=*)           health_state="${line#health=}" ;;
    esac
    printf '%s\n' "$line"
  done < <(bridge_daemon_health_signal)
  case "$health_state" in
    ok)
      echo "health: ok (pid alive, last tick ${health_age:-?}s ago)"
      ;;
    silent)
      if [[ -n "$health_age" ]]; then
        echo "health: silent (pid alive but tick is ${health_age}s stale — likely wedged; \`agb daemon start\` will auto-repair)"
      else
        echo "health: silent (pid alive but no parseable heartbeat — likely wedged; \`agb daemon start\` will auto-repair)"
      fi
      ;;
    *)
      echo "health: down (no live pid)"
      ;;
  esac
  # Issue #590 / PR #599 r2: surface every log path the operator may need
  # so `agent-bridge daemon status` answers "where is the daemon writing?"
  # directly. r3: BRIDGE_LAUNCHAGENT_LOG is now resolved from the same
  # marker-aware precedence at line 106-122 above, so we just compare the
  # two resolved variables — no second marker read here. When the marker
  # resolves both vars to the same path, only `log=` prints; when the
  # operator overrode BRIDGE_DAEMON_LOG (or there is no marker at all and
  # BRIDGE_LAUNCHAGENT_LOG fell back to its conventional default), the
  # second line surfaces the divergence.
  echo "log=${BRIDGE_DAEMON_LOG}"
  if [[ "$BRIDGE_LAUNCHAGENT_LOG" != "$BRIDGE_DAEMON_LOG" ]]; then
    echo "launchagent_log=${BRIDGE_LAUNCHAGENT_LOG}"
  fi

  # Issue #800 Track C: surface the silence-watchdog state so operators
  # can answer "is anything recovering me if I hang again?" without an
  # extra pgrep / journalctl roundtrip. We call into the watchdog's own
  # `status` subcommand and translate its key lines into `watchdog_*=...`
  # rows so the daemon status grep-grammar stays single-line key=value.
  local watchdog_py="$SCRIPT_DIR/bridge-watchdog-silence.py"
  if [[ -f "$watchdog_py" ]]; then
    local watchdog_out
    # Hard timeout so a wedged audit log (the very condition the watchdog
    # supervises) cannot block `daemon status` itself. The watchdog status
    # path opens the audit JSONL and seeks into it; on a healthy host this
    # returns in <100ms, on a sick host we'd rather show stale-or-missing
    # rows than hang the daemon status caller. Use the project-wide
    # bridge_with_timeout wrapper (lib/bridge-state.sh) so the timeout
    # works on hosts that don't ship GNU `timeout(1)` — notably macOS
    # without coreutils, where the previous bare `command -v timeout` test
    # failed and the call ran unbounded.
    watchdog_out="$(bridge_with_timeout 5 cmd_status_watchdog python3 "$watchdog_py" status 2>/dev/null || true)"
    if [[ -n "$watchdog_out" ]]; then
      local line
      while IFS= read -r line; do
        case "$line" in
          "daemon_script: "*)         echo "watchdog_daemon_script=${line#daemon_script: }" ;;
          "last_daemon_tick: "*)      echo "watchdog_${line//: /=}" ;;
          "last_detection_epoch: "*)  echo "watchdog_${line//: /=}" ;;
          "last_restart_epoch: "*)    echo "watchdog_${line//: /=}" ;;
          "watchdog: "*)              echo "watchdog_process=${line#watchdog: }" ;;
          *) ;;
        esac
      done <<EOF
$watchdog_out
EOF
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-plugin-liveness)
      export BRIDGE_SKIP_PLUGIN_LIVENESS=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

CMD="${1:-}"
case "$CMD" in
  start)
    cmd_start
    ;;
  ensure)
    cmd_start
    ;;
  run)
    cmd_run
    ;;
  run-cron-worker)
    shift || true
    cmd_run_cron_worker "$@"
    ;;
  stop)
    shift || true
    cmd_stop "$@"
    ;;
  status)
    cmd_status
    ;;
  sync)
    cmd_sync_cycle
    ;;
  *)
    usage
    exit 1
    ;;
esac
