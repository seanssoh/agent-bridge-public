#!/usr/bin/env bash
# bridge-daemon-liveness.sh — issue #265 proposal D
#
# OS-level liveness watcher for the Agent Bridge daemon. Designed to run
# OUTSIDE the daemon process tree (under launchd on macOS or systemd .timer
# on Linux) so a hung daemon main loop cannot prevent the watcher from
# observing it.
#
# Behavior:
#   1. Read mtime of $BRIDGE_STATE_DIR/daemon.heartbeat (touched by
#      bridge-daemon.sh::cmd_run on every BRIDGE_DAEMON_HEARTBEAT_SECONDS
#      tick — see commit that added the printf next to bridge_audit_log
#      daemon_tick).
#   2. If the file does not exist, do nothing — fresh install or daemon
#      not yet started; let the daemon's normal start path establish the
#      baseline.
#   3. If mtime is younger than BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS
#      (default 600s = 10 min), do nothing.
#   4. If stale AND the daemon pid is recorded AND alive, AND the cooldown
#      since the last restart attempt has elapsed, run
#      `bridge-daemon.sh stop --force && bridge-daemon.sh start`. Cooldown prevents
#      a broken daemon from triggering a restart-loop every minute.
#   5. If stale but the daemon is not running, do nothing — the normal
#      start path (launchd KeepAlive / systemd Restart=always) will bring
#      it back; the liveness watcher only addresses the silent-hang case
#      where the process is alive but the loop has frozen.
#
# Issue #1973 (Track C) — gateway-stall detection. The original watcher only
# recovered a pid-alive-but-heartbeat-frozen daemon. The #1973 incident was a
# different class: the heartbeat KEPT advancing (the main loop ticked) but the
# file-transport queue gateway DRAIN stalled, so `agb claim`/`agb done` hard-
# timed-out for ~1.5h while every health check said "running". A heartbeat
# watcher cannot see that. We add a second restart trigger:
#
#   6. If the gateway has pending OR working requests whose OLDEST age exceeds
#      BRIDGE_DAEMON_GATEWAY_STALL_SECONDS AND that oldest age STAYS above the
#      threshold across one poll (the prior observation, persisted to disk),
#      AND the daemon pid is alive, restart the daemon (same cooldown gate as
#      the heartbeat path). The cross-poll requirement plus the "must have OLD
#      pending/working requests" requirement is what keeps an *idle* daemon
#      (zero queued requests, or a brief in-flight request) from ever being
#      restarted — a false restart would itself be an outage.
#
# The gateway state comes from Track A's `bridge-queue-gateway.py status --json`
# (pending/working counts + oldest ages). We consume it through a configurable
# command (BRIDGE_DAEMON_GATEWAY_STATUS_CMD) so this watcher targets A's
# contract without re-implementing it, and so the smoke can stub it.
#
# Before any restart (heartbeat OR gateway) the watcher writes a recovery
# marker (BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE) so the freshly-started daemon
# knows to run a one-shot re-nudge pass for idle agents whose queued tasks were
# stranded by the stall (see bridge-daemon.sh cmd_run consumption).
#
# Audit:
#   Writes one of `daemon_liveness_ok`, `daemon_liveness_skip_no_baseline`,
#   `daemon_liveness_skip_not_running`, `daemon_liveness_skip_cooldown`,
#   `daemon_liveness_restart_attempt`, `daemon_liveness_restart_failed`,
#   `daemon_liveness_gateway_stall_observed`, or
#   `daemon_liveness_gateway_stall_restart` to $BRIDGE_AUDIT_LOG when
#   bridge-audit.py is invokable. Failures to write audit are non-fatal — the
#   watcher's job is restarting, not logging.
#
# Environment:
#   BRIDGE_HOME                                  default $HOME/.agent-bridge
#   BRIDGE_STATE_DIR                             default $BRIDGE_HOME/state
#   BRIDGE_AUDIT_LOG                             default $BRIDGE_HOME/logs/audit.jsonl
#   BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS     default 600
#   BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS      default 600
#   BRIDGE_DAEMON_HEARTBEAT_FILE                 default $BRIDGE_STATE_DIR/daemon.heartbeat
#   BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE         default $BRIDGE_STATE_DIR/daemon-liveness-cooldown.ts
#   BRIDGE_DAEMON_LIVENESS_DRY_RUN               set to 1 to log the decision but skip the actual stop/start
#   BRIDGE_DAEMON_GATEWAY_STALL_SECONDS          default 300; oldest pending/working age that counts as a stall
#   BRIDGE_DAEMON_GATEWAY_STATUS_CMD             override the `status --json` command (smoke stub seam)
#   BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE       default $BRIDGE_STATE_DIR/daemon-gateway-stall.ts (cross-poll witness)
#   BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE          default $BRIDGE_STATE_DIR/daemon-recovery-renudge.env (recovery marker)
#   BRIDGE_DAEMON_GATEWAY_STALL_DISABLE          set to 1 to skip gateway-stall detection entirely (heartbeat-only)

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
: "${BRIDGE_STATE_DIR:=$BRIDGE_HOME/state}"
: "${BRIDGE_AUDIT_LOG:=$BRIDGE_HOME/logs/audit.jsonl}"
: "${BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS:=600}"
: "${BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS:=600}"
: "${BRIDGE_DAEMON_HEARTBEAT_FILE:=$BRIDGE_STATE_DIR/daemon.heartbeat}"
: "${BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE:=$BRIDGE_STATE_DIR/daemon-liveness-cooldown.ts}"
: "${BRIDGE_DAEMON_LIVENESS_DRY_RUN:=0}"
: "${BRIDGE_DAEMON_GATEWAY_STALL_SECONDS:=300}"
: "${BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE:=$BRIDGE_STATE_DIR/daemon-gateway-stall.ts}"
# Cross-poll witness identity tolerance (seconds). The witness stores the
# oldest stalled request's approximate BIRTH time (observation_ts - oldest_age),
# which is stable across polls for the SAME request. A second poll only counts
# as a true cross-poll witness when the current oldest-request birth matches the
# stored birth within this tolerance (absorbs age-measurement jitter). A birth
# outside tolerance means the prior old request drained / a different request is
# now oldest, so the witness resets to a fresh first observation rather than
# restarting on a request seen only once (review fix: same-request witness).
: "${BRIDGE_DAEMON_GATEWAY_STALL_WITNESS_TOLERANCE_SECONDS:=10}"
: "${BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE:=$BRIDGE_STATE_DIR/daemon-recovery-renudge.env}"
: "${BRIDGE_DAEMON_GATEWAY_STALL_DISABLE:=0}"

# Sanitize numeric envs — fall back to defaults on garbage so a typo in a
# launchd EnvironmentVariables block can't disable the watcher.
[[ "$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=600
[[ "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]  || BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=600
[[ "$BRIDGE_DAEMON_GATEWAY_STALL_SECONDS" =~ ^[0-9]+$ ]]      || BRIDGE_DAEMON_GATEWAY_STALL_SECONDS=300

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
DAEMON_PID_FILE="${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}"

now_ts() { date +%s; }

file_mtime() {
  # macOS / BSD: stat -f %m. Linux / GNU coreutils: stat -c %Y.
  local f="$1"
  local mtime
  if mtime="$(stat -f %m "$f" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  if mtime="$(stat -c %Y "$f" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  return 1
}

emit_audit() {
  # Best-effort JSON-line audit. We deliberately do not source bridge-lib.sh
  # (heavy: pulls in tmux/queue/state modules) just for one log line — the
  # python script is small and standalone.
  local action="$1"
  shift || true
  local audit_py="$REPO_ROOT/bridge-audit.py"
  [[ -x "$audit_py" || -f "$audit_py" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$BRIDGE_AUDIT_LOG")" 2>/dev/null || true
  python3 "$audit_py" write \
    --file "$BRIDGE_AUDIT_LOG" \
    --actor daemon_liveness \
    --action "$action" \
    --target daemon \
    "$@" >/dev/null 2>&1 || true
}

daemon_pid_alive() {
  local pid
  [[ -f "$DAEMON_PID_FILE" ]] || return 1
  pid="$(head -n1 "$DAEMON_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

cooldown_active() {
  # Returns 0 (true) when last restart attempt is within cooldown window.
  local last_ts now
  [[ -f "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" ]] || return 1
  last_ts="$(tr -d '[:space:]' <"$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" 2>/dev/null)"
  [[ "$last_ts" =~ ^[0-9]+$ ]] || return 1
  now="$(now_ts)"
  (( now - last_ts < BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS ))
}

record_cooldown() {
  mkdir -p "$(dirname "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE")" 2>/dev/null || true
  printf '%s\n' "$(now_ts)" 2>/dev/null >"$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" || true
}

# Issue #1973 (Track C). Write the recovery marker the freshly-started daemon
# consumes once to run a bounded re-nudge pass. The daemon path
# (bridge-daemon.sh cmd_run) deletes the file after one read, so it is a single
# latch per restart — a second restart re-writes it. Best-effort: a failed
# write must not block the restart itself.
write_recovery_marker() {
  local reason="$1"
  local oldest_age="$2"
  local heartbeat_age="$3"
  mkdir -p "$(dirname "$BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE")" 2>/dev/null || true
  {
    printf 'BRIDGE_RECOVERY_REASON=%q\n' "$reason"
    printf 'BRIDGE_RECOVERY_TS=%q\n' "$(now_ts)"
    printf 'BRIDGE_RECOVERY_OLDEST_REQUEST_AGE=%q\n' "${oldest_age:-0}"
    printf 'BRIDGE_RECOVERY_PRIOR_HEARTBEAT_AGE=%q\n' "${heartbeat_age:-0}"
  } 2>/dev/null >"$BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE" || true
}

# Issue #1973 (Track C). Query Track A's gateway `status --json` and emit the
# OLDEST age (seconds) across pending+working requests, or empty when the
# gateway is idle / status is unavailable / status is unparseable. We default
# to `bridge-queue-gateway.py status --json`; the smoke overrides via
# BRIDGE_DAEMON_GATEWAY_STATUS_CMD. The status command itself is Track A's; we
# only read its `pending`/`working` oldest-age fields.
gateway_oldest_stalled_age() {
  local status_json=""
  if [[ -n "${BRIDGE_DAEMON_GATEWAY_STATUS_CMD:-}" ]]; then
    status_json="$(eval "$BRIDGE_DAEMON_GATEWAY_STATUS_CMD" 2>/dev/null || true)"
  else
    local gw="$REPO_ROOT/bridge-queue-gateway.py"
    [[ -f "$gw" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    status_json="$(python3 "$gw" status --json --bridge-home "$BRIDGE_HOME" 2>/dev/null || true)"
  fi
  [[ -n "$status_json" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # Parse the MAX of the pending/working oldest-age fields, but ONLY when the
  # corresponding request COUNT is positive. Field names mirror Track A's
  # `status --json` contract (PR #1978): `pending`/`working` counts and
  # `oldest_pending_age`/`oldest_working_age` seconds. A zero count must never
  # contribute its oldest-age — a draining/idle gateway can still carry a stale
  # age field, and treating that as a stall would fire a false restart (review
  # fix: count-gate). A missing field or empty/idle gateway prints nothing → the
  # caller treats it as "no stall".
  printf '%s' "$status_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ages = []
for count_key, age_key in (("pending", "oldest_pending_age"), ("working", "oldest_working_age")):
    cnt = d.get(count_key)
    age = d.get(age_key)
    if isinstance(cnt, bool) or isinstance(age, bool):
        continue
    if isinstance(cnt, (int, float)) and cnt > 0 and isinstance(age, (int, float)) and age >= 0:
        ages.append(int(age))
if ages:
    print(max(ages))
' 2>/dev/null
}

# Shared restart mechanics for both the heartbeat-stale and gateway-stall
# triggers. The recovery marker + cooldown are written by the CALLER before
# this runs (so the marker exists even on a DRY_RUN), and the per-trigger audit
# (attempt) is the caller's too — this helper owns only the actual `restart
# --force` invocation + the rc handling shared by both paths. $1 is a short tag
# used in the log line + the refused/failed audit details.
_perform_daemon_restart() {
  local tag="$1"
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would restart daemon (%s)\n' "$tag"
    return 0
  fi
  # Use BRIDGE_HOME's daemon script so the watcher targets the same install
  # root the heartbeat file was observed in. The launchd plist sets
  # BRIDGE_HOME explicitly; override via env if running by hand.
  #
  # Issue #1463: route through the single `restart` verb instead of a
  # direct `stop --force` + `start`. On macOS launchd installs `restart`
  # cycles launchd's OWN supervised job (`launchctl kickstart -k`) so the
  # fresh daemon is launchd's instance and holds the singleton lock inside
  # the supervised process tree — KeepAlive then has nothing to thrash
  # against. A direct out-of-band stop+start (the old code) established a
  # NON-launchd lock holder and re-armed the KeepAlive vs lock thrash on
  # every ~600s liveness restart. On Linux (systemd/nohup) `restart` falls
  # through to the same stop+start it always did, so this is a no-op there.
  # rc=2 means restart REFUSED (out-of-band split needs a one-time operator
  # reconcile) — surface it distinctly rather than masking it as success.
  #
  # --force: the liveness watchdog only fires on a wedged daemon. Bypass the
  # #314/#315 active-agent guard so a stuck daemon can still be restarted on a
  # host with running agents.
  local restart_rc=0
  bash "$DAEMON_SH" restart --force >/dev/null 2>&1 || restart_rc=$?
  if (( restart_rc == 2 )); then
    emit_audit daemon_liveness_restart_refused \
      --detail reason="launchd_out_of_band_split" \
      --detail trigger="$tag"
    printf '[liveness] restart REFUSED (out-of-band launchd split) — run "bridge-daemon.sh stop --force" once to reconcile\n'
    return 1
  fi
  if (( restart_rc != 0 )); then
    emit_audit daemon_liveness_restart_failed \
      --detail restart_rc="$restart_rc" \
      --detail trigger="$tag"
    return 1
  fi
  return 0
}

restart_daemon() {
  local pid="$1"
  local age="$2"
  emit_audit daemon_liveness_restart_attempt \
    --detail pid="$pid" \
    --detail heartbeat_age_seconds="$age" \
    --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
  write_recovery_marker heartbeat_stale "" "$age"
  record_cooldown
  if _perform_daemon_restart heartbeat_stale; then
    printf '[liveness] restarted daemon pid=%s age=%ss\n' "$pid" "$age"
    return 0
  fi
  return 1
}

# Issue #1973 (Track C). Gateway-stall restart: the daemon pid is alive and the
# heartbeat is fresh, but the queue gateway has OLD pending/working requests
# (the drain stalled). Same cooldown + recovery-marker contract as the
# heartbeat path; the marker reason distinguishes the trigger for the daemon's
# one-shot re-nudge consumer.
restart_daemon_gateway() {
  local pid="$1"
  local oldest_age="$2"
  local heartbeat_age="$3"
  emit_audit daemon_liveness_gateway_stall_restart \
    --detail pid="$pid" \
    --detail oldest_request_age_seconds="$oldest_age" \
    --detail heartbeat_age_seconds="$heartbeat_age" \
    --detail gateway_stall_threshold_seconds="$BRIDGE_DAEMON_GATEWAY_STALL_SECONDS"
  write_recovery_marker gateway_stall "$oldest_age" "$heartbeat_age"
  record_cooldown
  if _perform_daemon_restart gateway_stall; then
    printf '[liveness] restarted daemon (gateway stall) pid=%s oldest_request_age=%ss\n' "$pid" "$oldest_age"
    return 0
  fi
  return 1
}

# Issue #1973 (Track C). Gateway-stall detection. Returns 0 and restarts only
# when ALL of: (a) gateway-stall detection enabled, (b) the gateway reports an
# OLD pending/working request (oldest age >= stall threshold — an idle gateway
# reports nothing and never trips this), (c) that oldest age was ALSO old on
# the prior poll (cross-poll witness on disk — a single transient slow request
# does not trip it), (d) the daemon pid is alive, (e) not within cooldown.
# Otherwise it records/clears the cross-poll witness and returns non-zero so
# main() falls through to its normal heartbeat verdict.
maybe_restart_on_gateway_stall() {
  local pid="$1"
  local heartbeat_age="$2"
  [[ "$BRIDGE_DAEMON_GATEWAY_STALL_DISABLE" == "1" ]] && return 1

  local oldest_age=""
  oldest_age="$(gateway_oldest_stalled_age || true)"
  if [[ -z "$oldest_age" || ! "$oldest_age" =~ ^[0-9]+$ ]] \
     || (( oldest_age < BRIDGE_DAEMON_GATEWAY_STALL_SECONDS )); then
    # No old pending/working request → the gateway is draining (or idle).
    # Clear the cross-poll witness so a future single slow request must again
    # be observed twice before it can trigger a restart.
    rm -f "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" 2>/dev/null || true
    return 1
  fi

  # The gateway has an OLD request. Require a prior observation of the SAME
  # request (cross-poll witness) before restarting, so neither a single
  # transient slow request NOR a fresh old request that appears between polls
  # can fire a restart on a single sighting. The witness stores the oldest
  # request's approximate BIRTH time (observation_ts - oldest_age), which is
  # stable across polls for the same request; a current birth outside tolerance
  # of the stored one means the prior old request drained / a different request
  # is now oldest, so we reset to a fresh first observation instead of trusting
  # the stale witness (review fix: same-request cross-poll witness).
  local now obs_birth prior_birth witness_ok
  now="$(now_ts)"
  obs_birth=$(( now - oldest_age ))
  prior_birth=""
  if [[ -f "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" ]]; then
    prior_birth="$(tr -d '[:space:]' <"$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" 2>/dev/null)"
  fi
  witness_ok=0
  if [[ -n "$prior_birth" && "$prior_birth" =~ ^-?[0-9]+$ ]]; then
    local delta=$(( obs_birth - prior_birth ))
    (( delta < 0 )) && delta=$(( -delta ))
    (( delta <= BRIDGE_DAEMON_GATEWAY_STALL_WITNESS_TOLERANCE_SECONDS )) && witness_ok=1
  fi
  if (( witness_ok == 0 )); then
    # First observation of THIS old request (no prior witness, or the oldest
    # request changed/drained between polls) — record its birth and wait for the
    # next poll. Never restart on a request witnessed only once.
    mkdir -p "$(dirname "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE")" 2>/dev/null || true
    printf '%s\n' "$obs_birth" 2>/dev/null >"$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" || true
    emit_audit daemon_liveness_gateway_stall_observed \
      --detail oldest_request_age_seconds="$oldest_age" \
      --detail oldest_request_birth_ts="$obs_birth" \
      --detail gateway_stall_threshold_seconds="$BRIDGE_DAEMON_GATEWAY_STALL_SECONDS" \
      --detail observation="first"
    return 1
  fi

  # Second consecutive observation of an old request. Honor the cooldown so a
  # broken daemon does not restart-loop.
  if cooldown_active; then
    emit_audit daemon_liveness_skip_cooldown \
      --detail pid="$pid" \
      --detail oldest_request_age_seconds="$oldest_age" \
      --detail trigger="gateway_stall" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 1
  fi

  rm -f "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" 2>/dev/null || true
  restart_daemon_gateway "$pid" "$oldest_age" "$heartbeat_age"
  return 0
}

main() {
  local mtime now age pid

  if [[ ! -f "$BRIDGE_DAEMON_HEARTBEAT_FILE" ]]; then
    emit_audit daemon_liveness_skip_no_baseline \
      --detail heartbeat_file="$BRIDGE_DAEMON_HEARTBEAT_FILE"
    return 0
  fi

  if ! mtime="$(file_mtime "$BRIDGE_DAEMON_HEARTBEAT_FILE")"; then
    emit_audit daemon_liveness_skip_no_baseline \
      --detail heartbeat_file="$BRIDGE_DAEMON_HEARTBEAT_FILE" \
      --detail reason="stat_failed"
    return 0
  fi

  now="$(now_ts)"
  age=$(( now - mtime ))

  # Issue #1973 (Track C). Gateway-stall detection runs FIRST and regardless of
  # heartbeat freshness — the #1973 wedge had a FRESH heartbeat (the loop kept
  # ticking) while the queue gateway drain stalled. It only acts when the
  # daemon pid is alive AND the gateway has an OLD pending/working request seen
  # across two polls; otherwise it is a no-op and we continue to the heartbeat
  # verdict below.
  if pid="$(daemon_pid_alive)"; then
    if maybe_restart_on_gateway_stall "$pid" "$age"; then
      return 0
    fi
  fi

  if (( age < BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS )); then
    emit_audit daemon_liveness_ok \
      --detail heartbeat_age_seconds="$age" \
      --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
    return 0
  fi

  if ! pid="$(daemon_pid_alive)"; then
    # No live process to kill. launchd's KeepAlive / systemd's Restart=always
    # handles the "process gone" case; the liveness watcher exists for the
    # silent-hang case. Be conservative and stay out of the way.
    emit_audit daemon_liveness_skip_not_running \
      --detail heartbeat_age_seconds="$age" \
      --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
    return 0
  fi

  if cooldown_active; then
    emit_audit daemon_liveness_skip_cooldown \
      --detail pid="$pid" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi

  restart_daemon "$pid" "$age"
}

main "$@"
