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

# ── Issue #2040: standing recovery for an enabled-but-unloaded daemon ──────────
#
# The daemon can end up ENABLED-BUT-UNLOADED via ANY quiesce/restart path (a lost
# async-bootout race during upgrade, an ensure_singleton restart storm, a
# watchdog-disable that never re-bootstrapped). In that state launchd's
# KeepAlive / systemd's Restart= is MOOT — there is no loaded job to supervise —
# so the daemon stays down indefinitely (~64h observed). cron self-heal is
# impossible (cron dispatch needs the daemon). This INDEPENDENT liveness watcher
# (its own launchd job / systemd timer, survives the daemon's death) is the only
# viable recovery: when the heartbeat is stale AND no daemon pid is alive AND the
# job is PROVEN should-be-running-but-unloaded, re-bootstrap it (bounded +
# cooldown-gated + audited). It must NEVER fight an operator `agb daemon stop` /
# an intentionally-disabled job — the durable "should be running" signal is the
# launchd `disabled=false` + plist/config presence, or systemd `is-enabled`.

# Resolve the launchd uid for the current process. Empty on failure.
rebootstrap_launchd_uid() {
  id -u 2>/dev/null || printf '%s' "${UID:-}"
}

# Read the installer-written launchagent.config to learn the label + plist. Sets
# REBOOTSTRAP_LABEL / REBOOTSTRAP_PLIST globals. Returns 1 when the config is
# absent or the label cannot be resolved (→ not a launchd-managed install we can
# recover). Self-contained — the watcher deliberately does not source bridge-lib.
REBOOTSTRAP_LABEL=""
REBOOTSTRAP_PLIST=""
rebootstrap_launchd_resolve() {
  REBOOTSTRAP_LABEL=""
  REBOOTSTRAP_PLIST=""
  local config_path="${BRIDGE_LAUNCHAGENT_CONFIG_FILE:-$BRIDGE_STATE_DIR/launchagent.config}"
  [[ -f "$config_path" ]] || return 1
  local label plist
  label="$(
    # shellcheck disable=SC1090
    source "$config_path" 2>/dev/null
    printf '%s' "${BRIDGE_LAUNCHAGENT_LABEL:-}"
  )"
  plist="$(
    # shellcheck disable=SC1090
    source "$config_path" 2>/dev/null
    printf '%s' "${BRIDGE_LAUNCHAGENT_PLIST:-}"
  )"
  [[ -n "$label" ]] || return 1
  REBOOTSTRAP_LABEL="$label"
  REBOOTSTRAP_PLIST="$plist"
  return 0
}

# True (returns 0) when launchd has a LOADED job for gui/$uid/$label. `launchctl
# print` exits non-zero when the job is not loaded — the exit code is the signal.
rebootstrap_launchd_job_loaded() {
  local uid="$1" label="$2"
  launchctl print "gui/${uid}/${label}" >/dev/null 2>&1
}

# Report the launchd disabled-state for $label. `launchctl print-disabled
# gui/$uid` emits lines like `"<label>" => true` (disabled) / `"<label>" =>
# false` (enabled). Prints one of:
#   disabled — the label line says `=> true`
#   enabled  — the label line says `=> false` (or, absent any line, the default
#              is enabled — launchd only lists labels with an explicit override)
#   unknown  — `print-disabled` itself failed (domain unreachable / unsupported)
# We FAIL CLOSED on `unknown`: the caller skips recovery, because we cannot prove
# the job is NOT operator-disabled, and the operator-stop guarantee outranks
# auto-recovery (★ never fight an `agb daemon stop`).
rebootstrap_launchd_disabled_state() {
  local uid="$1" label="$2" out
  out="$(launchctl print-disabled "gui/${uid}" 2>/dev/null)" || { printf 'unknown'; return 0; }
  if printf '%s\n' "$out" | grep -E "\"${label}\"[[:space:]]*=>[[:space:]]*(true|disabled)" >/dev/null 2>&1; then
    printf 'disabled'
  else
    printf 'enabled'
  fi
}

# Re-bootstrap an enabled-but-unloaded launchd daemon. Pre-gated by the caller
# (Darwin + launchctl + resolved label + plist exists + NOT disabled + NOT
# loaded). Cooldown-recorded BEFORE the attempt (storm control). bootstrap +
# kickstart, capture stderr, verify loaded. Audits attempt/success/failed.
# Returns 0 on success, 1 on failure.
rebootstrap_launchd_daemon() {
  local uid="$1" label="$2" plist="$3" age="$4"
  emit_audit daemon_liveness_rebootstrap_attempt \
    --detail platform="launchd" \
    --detail label="$label" \
    --detail heartbeat_age_seconds="$age"
  record_cooldown
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would re-bootstrap enabled-but-unloaded launchd job gui/%s/%s\n' "$uid" "$label"
    return 0
  fi
  local err=""
  err="$(launchctl bootstrap "gui/${uid}" "$plist" 2>&1 >/dev/null)" || true
  launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
  if rebootstrap_launchd_job_loaded "$uid" "$label"; then
    emit_audit daemon_liveness_rebootstrap_success \
      --detail platform="launchd" \
      --detail label="$label"
    printf '[liveness] re-bootstrapped enabled-but-unloaded launchd daemon gui/%s/%s\n' "$uid" "$label"
    return 0
  fi
  emit_audit daemon_liveness_rebootstrap_failed \
    --detail platform="launchd" \
    --detail label="$label" \
    --detail launchctl_error="${err:-}"
  printf '[liveness] WARN: launchd daemon still UNLOADED after re-bootstrap (gui/%s/%s) — remediate by hand: launchctl bootstrap gui/%s %s%s\n' \
    "$uid" "$label" "$uid" "$plist" "${err:+ (last launchctl error: $err)}" >&2
  return 1
}

# Darwin entry point. Returns 0 when it HANDLED the not-running case (acted or
# deliberately skipped with its own audit) so main() must NOT fall through to
# daemon_liveness_skip_not_running; returns 1 when this is not a recoverable
# launchd situation and main() should emit the standard skip.
maybe_rebootstrap_launchd() {
  local age="$1"
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 1
  command -v launchctl >/dev/null 2>&1 || return 1
  rebootstrap_launchd_resolve || return 1
  local uid
  uid="$(rebootstrap_launchd_uid)"
  [[ -n "$uid" ]] || return 1
  # Require the plist on disk — bootstrap needs the file, and its presence is
  # half of the "we are launchd-managed" signal.
  [[ -n "$REBOOTSTRAP_PLIST" && -f "$REBOOTSTRAP_PLIST" ]] || return 1
  # ★ Operator-intent guard: a DISABLED job is an intentional stop. SKIP + audit,
  # never re-enable/re-bootstrap. FAIL CLOSED on `unknown` (print-disabled
  # unreadable) — we cannot prove the job is not operator-disabled, and the
  # operator-stop guarantee outranks auto-recovery.
  local disabled_state
  disabled_state="$(rebootstrap_launchd_disabled_state "$uid" "$REBOOTSTRAP_LABEL")"
  if [[ "$disabled_state" != "enabled" ]]; then
    emit_audit daemon_liveness_rebootstrap_skip_disabled \
      --detail platform="launchd" \
      --detail label="$REBOOTSTRAP_LABEL" \
      --detail disabled_state="$disabled_state" \
      --detail heartbeat_age_seconds="$age"
    printf '[liveness] launchd job gui/%s/%s disabled-state=%s — skipping re-bootstrap (operator stop / cannot confirm enabled).\n' \
      "$uid" "$REBOOTSTRAP_LABEL" "$disabled_state"
    return 0
  fi
  # If the job IS loaded, this is not the enabled-but-unloaded case — let the
  # normal skip path handle it (a loaded-but-no-pid job is launchd's to respawn).
  if rebootstrap_launchd_job_loaded "$uid" "$REBOOTSTRAP_LABEL"; then
    emit_audit daemon_liveness_rebootstrap_skip_loaded \
      --detail platform="launchd" \
      --detail label="$REBOOTSTRAP_LABEL" \
      --detail heartbeat_age_seconds="$age"
    return 1
  fi
  # Enabled-but-unloaded confirmed. Storm control: respect the cooldown.
  if cooldown_active; then
    emit_audit daemon_liveness_rebootstrap_skip_cooldown \
      --detail platform="launchd" \
      --detail label="$REBOOTSTRAP_LABEL" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi
  rebootstrap_launchd_daemon "$uid" "$REBOOTSTRAP_LABEL" "$REBOOTSTRAP_PLIST" "$age" || true
  return 0
}

# Linux entry point. The watcher runs from its own systemd --user timer
# (independent of the daemon service), so it survives the daemon's death and can
# restart an enabled-but-inactive `agent-bridge-daemon.service`. Recover ONLY
# when the service is-enabled=enabled/enabled-runtime AND is-active=inactive/
# failed. disabled/static/masked/not-found/bus-unreachable → SKIP, never enable.
# Returns 0 when HANDLED (acted or skipped-with-audit), 1 when main() should emit
# the standard skip.
maybe_rebootstrap_systemd() {
  local age="$1"
  [[ "$(uname -s 2>/dev/null)" == "Linux" ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  local svc="${BRIDGE_DAEMON_SYSTEMD_SERVICE:-agent-bridge-daemon.service}"
  local enabled_state
  # is-enabled prints enabled/enabled-runtime/disabled/static/masked/... on
  # stdout. A non-zero rc with empty output means the user bus is unreachable or
  # the unit is unknown → not recoverable here.
  enabled_state="$(systemctl --user is-enabled "$svc" 2>/dev/null)" || true
  case "$enabled_state" in
    enabled|enabled-runtime) ;;
    "")
      # No output → bus unreachable or unit not found. Skip + audit; never enable.
      emit_audit daemon_liveness_rebootstrap_skip_unavailable \
        --detail platform="systemd" \
        --detail service="$svc" \
        --detail heartbeat_age_seconds="$age"
      return 1
      ;;
    disabled|masked)
      # Operator/intentional stop. SKIP + audit, never re-enable.
      emit_audit daemon_liveness_rebootstrap_skip_disabled \
        --detail platform="systemd" \
        --detail service="$svc" \
        --detail enabled_state="$enabled_state" \
        --detail heartbeat_age_seconds="$age"
      printf '[liveness] systemd unit %s is %s (operator stop) — skipping re-start.\n' "$svc" "$enabled_state"
      return 0
      ;;
    *)
      # static / indirect / generated / unknown — not a unit we manage as a
      # standing daemon. Defer to the normal skip path.
      return 1
      ;;
  esac
  # Enabled. Recover only when NOT active (inactive/failed). An active service
  # with no pidfile is the daemon's own concern, not ours.
  if systemctl --user is-active "$svc" >/dev/null 2>&1; then
    emit_audit daemon_liveness_rebootstrap_skip_loaded \
      --detail platform="systemd" \
      --detail service="$svc" \
      --detail heartbeat_age_seconds="$age"
    return 1
  fi
  if cooldown_active; then
    emit_audit daemon_liveness_rebootstrap_skip_cooldown \
      --detail platform="systemd" \
      --detail service="$svc" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi
  emit_audit daemon_liveness_rebootstrap_attempt \
    --detail platform="systemd" \
    --detail service="$svc" \
    --detail heartbeat_age_seconds="$age"
  record_cooldown
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would re-start enabled-but-inactive systemd unit %s\n' "$svc"
    return 0
  fi
  local err=""
  # reset-failed clears a prior failed state so `start` is not refused.
  systemctl --user reset-failed "$svc" >/dev/null 2>&1 || true
  err="$(systemctl --user start "$svc" 2>&1 >/dev/null)" || true
  if systemctl --user is-active "$svc" >/dev/null 2>&1; then
    emit_audit daemon_liveness_rebootstrap_success \
      --detail platform="systemd" \
      --detail service="$svc"
    printf '[liveness] re-started enabled-but-inactive systemd daemon %s\n' "$svc"
    return 0
  fi
  emit_audit daemon_liveness_rebootstrap_failed \
    --detail platform="systemd" \
    --detail service="$svc" \
    --detail systemctl_error="${err:-}"
  printf '[liveness] WARN: systemd daemon %s still inactive after re-start — remediate: systemctl --user start %s%s\n' \
    "$svc" "$svc" "${err:+ (start error: $err)}" >&2
  return 0
}

# Standing-recovery dispatcher called from main() when the heartbeat is stale and
# no daemon pid is alive, BEFORE the daemon_liveness_skip_not_running fallback.
# Returns 0 when it HANDLED the case (so main must not also emit skip_not_running);
# 1 to fall through to the standard skip.
maybe_rebootstrap_unloaded_daemon() {
  local age="$1"
  maybe_rebootstrap_launchd "$age" && return 0
  maybe_rebootstrap_systemd "$age" && return 0
  return 1
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
    # Issue #2040: before deferring to KeepAlive / Restart=, check the
    # enabled-but-unloaded case those policies CANNOT recover. If the job is
    # proven should-be-running-but-unloaded (launchd: enabled, not disabled, not
    # loaded, plist present / systemd: is-enabled, inactive), re-bootstrap it
    # (cooldown-gated + audited). A DISABLED / operator-stopped job is skipped
    # with its own audit — we never fight an intentional stop.
    if maybe_rebootstrap_unloaded_daemon "$age"; then
      return 0
    fi
    # No live process to kill and nothing recoverable. launchd's KeepAlive /
    # systemd's Restart=always handles the genuine "process gone, job loaded"
    # case; the liveness watcher exists for the silent-hang case. Be
    # conservative and stay out of the way.
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
