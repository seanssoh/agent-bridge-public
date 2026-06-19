#!/usr/bin/env bash
#
# scripts/smoke/1973c-liveness-recovery.sh — Issue #1973 Track C smoke.
#
# Track C of #1973 makes the daemon liveness backstop part of install/upgrade/
# ensure, extends the liveness watcher with gateway-stall detection, writes a
# recovery marker before restart, and runs a ONE-SHOT recovery re-nudge pass on
# the freshly-started daemon (arming Track B's BRIDGE_DAEMON_NUDGE_FORCE_AGENTS
# seam). This smoke pins the three acceptance teeth. It is Linux-CI portable —
# it stubs `systemctl`, the gateway `status --json`, and `bridge_queue_cli`, so
# it needs neither a real systemd user bus nor a live queue.
#
#   C1 — install/upgrade/ensure makes agent-bridge-daemon-liveness.timer
#        present + active when the user bus is available, AND the
#        --skip-liveness-timer opt-out actually skips it, AND
#        bridge_daemon_ensure_liveness_timer installs a missing timer / warns
#        loudly when the user bus is unreachable.
#
#   C2 — the liveness watcher restarts on a stale heartbeat AND on old gateway
#        pending/working requests while the pid is alive (stubbed status --json),
#        and does NOT restart on an idle gateway (the false-restart guard) nor
#        on a single (first) old-request observation (the cross-poll guard).
#
#   C3 — a daemon recovery marker triggers EXACTLY ONE bounded re-nudge pass
#        (force-list = agents with queued non-cron-dispatch work), then the
#        recovery cooldown suppresses a second pass.
#
# All runs use an isolated BRIDGE_HOME and never touch live runtime.
#
# Footgun #11 mitigation: no heredoc-stdin into any subprocess; helper bodies
# are written with printf, and production function bodies are awk-extracted.

set -euo pipefail

SMOKE_NAME="1973c-liveness-recovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd awk

LIVENESS_SRC="$SMOKE_REPO_ROOT/scripts/bridge-daemon-liveness.sh"
INSTALL_SRC="$SMOKE_REPO_ROOT/scripts/install-daemon-systemd.sh"
INSTALL_LIVENESS_SRC="$SMOKE_REPO_ROOT/scripts/install-daemon-liveness-systemd.sh"
DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
for f in "$LIVENESS_SRC" "$INSTALL_SRC" "$INSTALL_LIVENESS_SRC" "$DAEMON_SRC"; do
  [[ -f "$f" ]] || smoke_fail "source not found: $f"
done

smoke_setup_bridge_home "$SMOKE_NAME"

# ---------------------------------------------------------------------------
# Shared stub: a recording `systemctl` on PATH. Records every invocation to
# $SYSTEMCTL_LOG; honors $SYSTEMCTL_IS_ACTIVE_RC for `is-active` and
# $SYSTEMCTL_SHOW_ENV_RC for `show-environment` so a test can simulate an
# available / unreachable user bus and an active / inactive timer.
# ---------------------------------------------------------------------------
STUB_BIN="$SMOKE_TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
SYSTEMCTL_LOG="$SMOKE_TMP_ROOT/systemctl.log"
: >"$SYSTEMCTL_LOG"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >>"%s"\n' "$SYSTEMCTL_LOG"
  printf 'for a in "$@"; do\n'
  printf '  case "$a" in\n'
  printf '    show-environment) exit "${SYSTEMCTL_SHOW_ENV_RC:-0}" ;;\n'
  printf '    is-active) exit "${SYSTEMCTL_IS_ACTIVE_RC:-0}" ;;\n'
  printf '  esac\n'
  printf 'done\n'
  printf 'exit 0\n'
} >"$STUB_BIN/systemctl"
chmod +x "$STUB_BIN/systemctl"

# loginctl stub so install-daemon-systemd.sh's linger guard is a clean no-op.
{
  printf '#!/usr/bin/env bash\n'
  printf 'exit 0\n'
} >"$STUB_BIN/loginctl"
chmod +x "$STUB_BIN/loginctl"

# ===========================================================================
# C1 — install/upgrade/ensure installs the liveness timer (+ opt-out + ensure)
# ===========================================================================
step_c1_install_renders_timer() {
  smoke_log "C1: install-daemon-systemd.sh --enable installs the liveness timer"

  # install-daemon-liveness-systemd.sh derives its timer path from $HOME/.config
  # /systemd/user; give it a clean HOME so the assertion targets a known path.
  local home="$SMOKE_TMP_ROOT/c1-home"
  local timer="$home/.config/systemd/user/agent-bridge-daemon-liveness.timer"
  mkdir -p "$home/.config/systemd/user"
  : >"$SYSTEMCTL_LOG"

  # Run the real installer with our stubbed systemctl/loginctl ahead on PATH,
  # forcing legacy ExecStart (no sudo probe). --enable should trigger the
  # liveness installer, which writes + enables the timer via systemctl.
  HOME="$home" \
  PATH="$STUB_BIN:$PATH" \
    bash "$INSTALL_SRC" \
      --bridge-home "$BRIDGE_HOME" \
      --no-sudo-self \
      --service-path "$home/.config/systemd/user/agent-bridge-daemon.service" \
      --enable >"$SMOKE_TMP_ROOT/c1.out" 2>"$SMOKE_TMP_ROOT/c1.err" \
    || smoke_fail "C1: install-daemon-systemd.sh --enable exited non-zero (err: $(cat "$SMOKE_TMP_ROOT/c1.err"))"

  # The liveness timer unit file must have been written...
  smoke_assert_file_exists "$timer" "C1"
  # ...and `systemctl --user enable --now agent-bridge-daemon-liveness.timer`
  # must have been invoked.
  if ! grep -q 'enable --now agent-bridge-daemon-liveness.timer' "$SYSTEMCTL_LOG"; then
    smoke_fail "C1: liveness timer was not enabled (systemctl log missing enable line)"
  fi
  smoke_log "C1: liveness timer rendered + enabled OK"
}

step_c1_skip_optout() {
  smoke_log "C1: --skip-liveness-timer opt-out skips the timer install"

  local home="$SMOKE_TMP_ROOT/c1b-home"
  local timer="$home/.config/systemd/user/agent-bridge-daemon-liveness.timer"
  mkdir -p "$home/.config/systemd/user"
  : >"$SYSTEMCTL_LOG"

  HOME="$home" \
  PATH="$STUB_BIN:$PATH" \
    bash "$INSTALL_SRC" \
      --bridge-home "$BRIDGE_HOME" \
      --no-sudo-self \
      --service-path "$home/.config/systemd/user/agent-bridge-daemon.service" \
      --skip-liveness-timer \
      --enable >"$SMOKE_TMP_ROOT/c1b.out" 2>"$SMOKE_TMP_ROOT/c1b.err" \
    || smoke_fail "C1: install with --skip-liveness-timer exited non-zero"

  if [[ -f "$timer" ]]; then
    smoke_fail "C1: --skip-liveness-timer still wrote the timer unit"
  fi
  if grep -q 'enable --now agent-bridge-daemon-liveness.timer' "$SYSTEMCTL_LOG"; then
    smoke_fail "C1: --skip-liveness-timer still enabled the timer"
  fi
  # And the opt-out must be LOUD.
  if ! grep -q 'skip-liveness-timer' "$SMOKE_TMP_ROOT/c1b.err"; then
    smoke_fail "C1: --skip-liveness-timer produced no loud warning"
  fi
  smoke_log "C1: opt-out skipped + warned OK"
}

step_c1_ensure_helper() {
  smoke_log "C1: bridge_daemon_ensure_liveness_timer installs missing / warns on dead bus"

  # Extract the ensure helper body from bridge-daemon.sh and drive it with
  # stubbed daemon_info / daemon_warn / systemctl. Linux-gated: the helper is a
  # no-op on macOS (uname != Linux), so we force the Linux branch by stubbing
  # `uname` to print Linux.
  local funcs="$SMOKE_TMP_ROOT/ensure-fn.sh"
  awk '/^bridge_daemon_ensure_liveness_timer\(\) \{/,/^}/' "$DAEMON_SRC" >"$funcs"
  grep -q '^bridge_daemon_ensure_liveness_timer() {' "$funcs" \
    || smoke_fail "C1: could not extract bridge_daemon_ensure_liveness_timer (rename?)"

  # A fake installer that records it was called.
  local fake_install_dir="$SMOKE_TMP_ROOT/ensure-scripts/scripts"
  mkdir -p "$fake_install_dir"
  local install_log="$SMOKE_TMP_ROOT/ensure-install.log"
  : >"$install_log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "installer-called %%s\\n" "$*" >>"%s"\n' "$install_log"
    printf 'exit 0\n'
  } >"$fake_install_dir/install-daemon-liveness-systemd.sh"
  chmod +x "$fake_install_dir/install-daemon-liveness-systemd.sh"

  local driver="$SMOKE_TMP_ROOT/ensure-driver.sh"
  local out_log="$SMOKE_TMP_ROOT/ensure-out.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'uname() { printf "Linux\\n"; }\n'
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"%s"; }\n' "$out_log"
    printf 'daemon_warn() { printf "warn: %%s\\n" "$*" >>"%s"; }\n' "$out_log"
    printf 'SCRIPT_DIR="%s"\n' "$SMOKE_TMP_ROOT/ensure-scripts"
    printf 'BRIDGE_BASH_BIN="bash"\n'
    printf 'BRIDGE_HOME="%s"\n' "$BRIDGE_HOME"
    printf 'source "%s"\n' "$funcs"
    printf 'bridge_daemon_ensure_liveness_timer\n'
  } >"$driver"
  chmod +x "$driver"

  # Case (a): user bus available, timer INACTIVE → installer must be called.
  : >"$out_log"
  : >"$install_log"
  PATH="$STUB_BIN:$PATH" SYSTEMCTL_SHOW_ENV_RC=0 SYSTEMCTL_IS_ACTIVE_RC=3 \
    bash "$driver" >/dev/null 2>&1 || smoke_fail "C1: ensure helper (inactive) exited non-zero"
  grep -q 'installer-called' "$install_log" \
    || smoke_fail "C1: ensure helper did not install a missing/inactive timer"

  # Case (b): user bus available, timer ACTIVE → installer must NOT be called.
  : >"$out_log"
  : >"$install_log"
  PATH="$STUB_BIN:$PATH" SYSTEMCTL_SHOW_ENV_RC=0 SYSTEMCTL_IS_ACTIVE_RC=0 \
    bash "$driver" >/dev/null 2>&1 || smoke_fail "C1: ensure helper (active) exited non-zero"
  if grep -q 'installer-called' "$install_log"; then
    smoke_fail "C1: ensure helper re-installed an already-active timer"
  fi

  # Case (c): user bus UNREACHABLE → loud warn, no install attempt.
  : >"$out_log"
  : >"$install_log"
  PATH="$STUB_BIN:$PATH" SYSTEMCTL_SHOW_ENV_RC=1 \
    bash "$driver" >/dev/null 2>&1 || smoke_fail "C1: ensure helper (dead bus) exited non-zero"
  if grep -q 'installer-called' "$install_log"; then
    smoke_fail "C1: ensure helper tried to install into an unreachable user bus"
  fi
  grep -q 'warn: .*bus unreachable' "$out_log" \
    || smoke_fail "C1: ensure helper did not warn loudly on an unreachable user bus"

  smoke_log "C1: ensure helper install/no-op/warn cases OK"
}

# ===========================================================================
# C2 — liveness restarts on stale heartbeat AND on old gateway requests
# ===========================================================================
# We run the REAL bridge-daemon-liveness.sh with DRY_RUN=1 so no real daemon is
# touched; the recovery marker + audit are still written, which is what we
# assert. The gateway status comes from BRIDGE_DAEMON_GATEWAY_STATUS_CMD (a
# stub that echoes a JSON document).
c2_state_dir=""
c2_setup() {
  c2_state_dir="$SMOKE_TMP_ROOT/c2-state"
  rm -rf "$c2_state_dir"
  mkdir -p "$c2_state_dir"
  # A live-looking pid file: our own pid is alive, so daemon_pid_alive() passes.
  printf '%s\n' "$$" >"$c2_state_dir/daemon.pid"
}

# Build a gateway-status stub command that emits a chosen oldest pending age.
# Field names mirror Track A's `status --json` contract (PR #1978):
# `pending`/`working` counts + `oldest_pending_age`/`oldest_working_age`.
# $2 overrides the pending COUNT (default 1) so the count-gating guard can be
# exercised with a stale age but a zero count.
c2_status_cmd() {
  local oldest="$1"          # integer seconds, or "idle" for no pending/working
  local pending="${2:-1}"    # pending request count (default 1)
  if [[ "$oldest" == "idle" ]]; then
    printf 'printf %s' "'{\"pending\": 0, \"working\": 0}'"
  else
    printf 'printf %s' "'{\"pending\": ${pending}, \"working\": 0, \"oldest_pending_age\": ${oldest}, \"oldest_working_age\": 0}'"
  fi
}

c2_run_liveness() {
  # $1 heartbeat_age_seconds (0=fresh), $2 gateway status cmd, $3 stall_disable
  local hb_age="$1" status_cmd="$2" stall_disable="${3:-0}"
  local hb_file="$c2_state_dir/daemon.heartbeat"
  local now mtime
  now="$(date +%s)"
  mtime=$(( now - hb_age ))
  printf '%s\n' "$mtime" >"$hb_file"
  # Force the heartbeat file mtime to match (so file_mtime reflects hb_age).
  # `stat`-based mtime is what the watcher reads; touch it to the desired epoch.
  if date -r "$mtime" >/dev/null 2>&1; then
    touch -t "$(date -r "$mtime" +%Y%m%d%H%M.%S 2>/dev/null)" "$hb_file" 2>/dev/null || true
  elif touch -d "@$mtime" "$hb_file" 2>/dev/null; then
    :
  fi
  env \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$c2_state_dir" \
    BRIDGE_AUDIT_LOG="$c2_state_dir/audit.jsonl" \
    BRIDGE_DAEMON_HEARTBEAT_FILE="$hb_file" \
    BRIDGE_DAEMON_PID_FILE="$c2_state_dir/daemon.pid" \
    BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 \
    BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=600 \
    BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=0 \
    BRIDGE_DAEMON_GATEWAY_STALL_SECONDS=300 \
    BRIDGE_DAEMON_GATEWAY_STALL_DISABLE="$stall_disable" \
    BRIDGE_DAEMON_GATEWAY_STATUS_CMD="$status_cmd" \
    BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE="$c2_state_dir/gateway-stall.ts" \
    BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE="$c2_state_dir/recovery.env" \
    bash "$LIVENESS_SRC" >"$c2_state_dir/liveness.out" 2>&1 || true
}

c2_marker_reason() {
  [[ -f "$c2_state_dir/recovery.env" ]] || { printf 'NONE'; return; }
  sed -n 's/^BRIDGE_RECOVERY_REASON=//p' "$c2_state_dir/recovery.env" | head -n1 | tr -dc 'a-zA-Z0-9_-'
}

step_c2_heartbeat_stale_restart() {
  smoke_log "C2: stale heartbeat → restart + recovery marker reason=heartbeat_stale"
  c2_setup
  rm -f "$c2_state_dir/recovery.env"
  # Heartbeat 900s old (> 600 threshold); idle gateway so only the heartbeat
  # path can fire. cooldown=0 so it is not suppressed.
  c2_run_liveness 900 "$(c2_status_cmd idle)" 0
  grep -q 'restarted daemon' "$c2_state_dir/liveness.out" \
    || smoke_fail "C2: stale heartbeat did not trigger a restart (out: $(cat "$c2_state_dir/liveness.out"))"
  [[ "$(c2_marker_reason)" == "heartbeat_stale" ]] \
    || smoke_fail "C2: heartbeat restart did not write reason=heartbeat_stale (got: $(c2_marker_reason))"
}

step_c2_gateway_stall_restart() {
  smoke_log "C2: old gateway requests + FRESH heartbeat → gateway-stall restart (pid alive)"
  c2_setup
  rm -f "$c2_state_dir/recovery.env"
  local cmd
  cmd="$(c2_status_cmd 900)"   # oldest pending age 900s >> 300 threshold
  # First poll: only an OBSERVATION (cross-poll guard) — must NOT restart yet.
  c2_run_liveness 0 "$cmd" 0
  if grep -q 'restarted daemon' "$c2_state_dir/liveness.out"; then
    smoke_fail "C2: gateway stall restarted on the FIRST observation (cross-poll guard broken)"
  fi
  [[ -f "$c2_state_dir/gateway-stall.ts" ]] \
    || smoke_fail "C2: first gateway-stall observation did not record the cross-poll witness"
  # Second poll: same old request, fresh heartbeat → gateway-stall restart.
  c2_run_liveness 0 "$cmd" 0
  grep -q 'gateway stall' "$c2_state_dir/liveness.out" \
    || smoke_fail "C2: second old-request observation did not trigger a gateway-stall restart (out: $(cat "$c2_state_dir/liveness.out"))"
  [[ "$(c2_marker_reason)" == "gateway_stall" ]] \
    || smoke_fail "C2: gateway restart did not write reason=gateway_stall (got: $(c2_marker_reason))"
}

step_c2_idle_no_restart() {
  smoke_log "C2: idle gateway + fresh heartbeat → NO restart (false-restart guard)"
  c2_setup
  rm -f "$c2_state_dir/recovery.env"
  # Two polls of an IDLE gateway with a fresh heartbeat: never restart.
  c2_run_liveness 0 "$(c2_status_cmd idle)" 0
  c2_run_liveness 0 "$(c2_status_cmd idle)" 0
  if grep -q 'restarted daemon' "$c2_state_dir/liveness.out"; then
    smoke_fail "C2: idle gateway falsely triggered a restart"
  fi
  if [[ -f "$c2_state_dir/recovery.env" ]]; then
    smoke_fail "C2: idle gateway wrote a recovery marker (should not)"
  fi
}

step_c2_count_zero_no_restart() {
  smoke_log "C2: zero count + stale oldest-age field → NO restart (count-gate guard)"
  c2_setup
  rm -f "$c2_state_dir/recovery.env"
  # A draining/idle gateway can still carry a stale oldest_*_age while its
  # COUNT is 0. The count-gate must ignore the age → no stall → no restart even
  # across two polls (review fix #2: count-blind parser).
  c2_run_liveness 0 "$(c2_status_cmd 900 0)" 0
  c2_run_liveness 0 "$(c2_status_cmd 900 0)" 0
  if grep -q 'restarted daemon' "$c2_state_dir/liveness.out"; then
    smoke_fail "C2: zero-count stale age falsely triggered a restart (count-gate broken)"
  fi
  if [[ -f "$c2_state_dir/recovery.env" ]]; then
    smoke_fail "C2: zero-count stale age wrote a recovery marker (should not)"
  fi
  if [[ -f "$c2_state_dir/gateway-stall.ts" ]]; then
    smoke_fail "C2: zero-count stale age recorded a cross-poll witness (should not)"
  fi
}

step_c2_changed_request_witness_reset() {
  smoke_log "C2: a DIFFERENT old request between polls → witness reset → NO restart (same-request witness guard)"
  c2_setup
  rm -f "$c2_state_dir/recovery.env"
  # Poll 1: an old request born ~900s ago records the witness (birth ≈ now-900).
  c2_run_liveness 0 "$(c2_status_cmd 900)" 0
  if grep -q 'restarted daemon' "$c2_state_dir/liveness.out"; then
    smoke_fail "C2: changed-request: restarted on the FIRST observation (cross-poll guard broken)"
  fi
  [[ -f "$c2_state_dir/gateway-stall.ts" ]] \
    || smoke_fail "C2: changed-request: first observation did not record the witness"
  # Poll 2: the prior old request has DRAINED and a different (newer, but still
  # > threshold) request is now oldest — age 400 → birth ≈ now-400, ~500s off
  # the stored birth, well outside the 10s tolerance. The witness must RESET to
  # a fresh first observation, NOT restart on a request seen only once
  # (review fix #1: same-request cross-poll witness).
  c2_run_liveness 0 "$(c2_status_cmd 400)" 0
  if grep -q 'restarted daemon' "$c2_state_dir/liveness.out"; then
    smoke_fail "C2: changed-request: restarted on a DIFFERENT request witnessed only once (witness identity broken)"
  fi
  if [[ "$(c2_marker_reason)" == "gateway_stall" ]]; then
    smoke_fail "C2: changed-request: wrote a gateway_stall recovery marker (should have reset the witness)"
  fi
}

# ===========================================================================
# C3 — recovery marker → EXACTLY ONE re-nudge pass → cooldown
# ===========================================================================
step_c3_recovery_renudge_once() {
  smoke_log "C3: recovery marker → one re-nudge pass (force-list populated) → cooldown"

  local funcs="$SMOKE_TMP_ROOT/c3-fn.sh"
  awk '/^bridge_daemon_consume_recovery_marker_renudge\(\) \{/,/^}/' "$DAEMON_SRC" >"$funcs"
  grep -q '^bridge_daemon_consume_recovery_marker_renudge() {' "$funcs" \
    || smoke_fail "C3: could not extract bridge_daemon_consume_recovery_marker_renudge (rename?)"

  local c3_state="$SMOKE_TMP_ROOT/c3-state"
  rm -rf "$c3_state"
  mkdir -p "$c3_state"
  local marker="$c3_state/recovery.env"
  local cd_file="$c3_state/recovery-cooldown.ts"
  local audit="$c3_state/audit.log"

  # Write a recovery marker (as the liveness watcher would).
  {
    printf 'BRIDGE_RECOVERY_REASON=gateway_stall\n'
    printf 'BRIDGE_RECOVERY_TS=%s\n' "$(date +%s)"
    printf 'BRIDGE_RECOVERY_OLDEST_REQUEST_AGE=900\n'
    printf 'BRIDGE_RECOVERY_PRIOR_HEARTBEAT_AGE=0\n'
  } >"$marker"

  # Driver: stub bridge_queue_cli (TSV summary: agent-a queued=2, agent-b
  # queued=0) + bridge_audit_log, source the extracted fn, print its echoed CSV.
  local driver="$SMOKE_TMP_ROOT/c3-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="%s"\n' "$c3_state"
    printf 'BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE="%s"\n' "$marker"
    printf 'BRIDGE_DAEMON_RECOVERY_RENUDGE_COOLDOWN_FILE="%s"\n' "$cd_file"
    printf 'BRIDGE_DAEMON_RECOVERY_RENUDGE_COOLDOWN_SECONDS="${BRIDGE_DAEMON_RECOVERY_RENUDGE_COOLDOWN_SECONDS:-300}"\n'
    # TSV columns: agent queued claimed blocked active idle ...
    printf 'bridge_queue_cli() {\n'
    printf '  printf "agent-a\\t2\\t0\\t0\\t1\\t0\\n"\n'
    printf '  printf "agent-b\\t0\\t0\\t0\\t1\\t0\\n"\n'
    printf '}\n'
    printf 'bridge_audit_log() { printf "audit %%s\\n" "${2:-}" >>"%s"; }\n' "$audit"
    printf 'source "%s"\n' "$funcs"
    printf 'rc=0\n'
    printf 'out="$(bridge_daemon_consume_recovery_marker_renudge)" || rc=$?\n'
    printf 'printf "FORCE=%%s RC=%%s\\n" "$out" "$rc"\n'
  } >"$driver"
  chmod +x "$driver"

  : >"$audit"
  local first
  first="$(bash "$driver")"
  # First pass: marker consumed → force-list = agent-a only (agent-b has 0 queued).
  case "$first" in
    "FORCE=agent-a RC=0") : ;;
    *) smoke_fail "C3: first pass force-list wrong (got: $first, want FORCE=agent-a RC=0)" ;;
  esac
  [[ ! -f "$marker" ]] || smoke_fail "C3: recovery marker not consumed (still present)"
  [[ -f "$cd_file" ]] || smoke_fail "C3: recovery cooldown timestamp not written"
  grep -q 'daemon_recovery_renudge_arm' "$audit" \
    || smoke_fail "C3: re-nudge arm audit row not emitted"

  # Re-write the marker and run again WITHIN cooldown → must NOT re-arm (empty
  # force-list), proving the pass is one-shot / cooldown-bounded.
  {
    printf 'BRIDGE_RECOVERY_REASON=gateway_stall\n'
    printf 'BRIDGE_RECOVERY_OLDEST_REQUEST_AGE=900\n'
    printf 'BRIDGE_RECOVERY_PRIOR_HEARTBEAT_AGE=0\n'
  } >"$marker"
  : >"$audit"
  local second
  second="$(bash "$driver")"
  case "$second" in
    "FORCE= RC=0") : ;;
    *) smoke_fail "C3: cooldown pass should arm nothing (got: $second, want FORCE= RC=0)" ;;
  esac
  grep -q 'daemon_recovery_renudge_skip_cooldown' "$audit" \
    || smoke_fail "C3: cooldown skip audit row not emitted"

  # And with cooldown=0, a fresh marker re-arms (proving cooldown is the gate,
  # not a permanent latch).
  {
    printf 'BRIDGE_RECOVERY_REASON=heartbeat_stale\n'
    printf 'BRIDGE_RECOVERY_OLDEST_REQUEST_AGE=0\n'
    printf 'BRIDGE_RECOVERY_PRIOR_HEARTBEAT_AGE=900\n'
  } >"$marker"
  : >"$audit"
  local third
  third="$(BRIDGE_DAEMON_RECOVERY_RENUDGE_COOLDOWN_SECONDS=0 bash "$driver")"
  case "$third" in
    "FORCE=agent-a RC=0") : ;;
    *) smoke_fail "C3: cooldown=0 should re-arm (got: $third, want FORCE=agent-a RC=0)" ;;
  esac

  # No-marker case → RC=1, empty force-list (no spurious pass).
  rm -f "$marker"
  local none
  none="$(bash "$driver")"
  case "$none" in
    "FORCE= RC=1") : ;;
    *) smoke_fail "C3: no-marker case should be RC=1 empty (got: $none)" ;;
  esac

  smoke_log "C3: one-shot re-nudge + cooldown OK"
}

# ---------------------------------------------------------------------------
main() {
  step_c1_install_renders_timer
  step_c1_skip_optout
  step_c1_ensure_helper
  step_c2_heartbeat_stale_restart
  step_c2_gateway_stall_restart
  step_c2_idle_no_restart
  step_c2_count_zero_no_restart
  step_c2_changed_request_witness_reset
  step_c3_recovery_renudge_once
  smoke_log "PASS"
}

main "$@"
