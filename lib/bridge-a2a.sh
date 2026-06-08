#!/usr/bin/env bash
# shellcheck shell=bash
# lib/bridge-a2a.sh — A2A cross-bridge handoff lifecycle helpers.
#
# Sourced by bridge-handoff-daemon.sh. Keeps the receiver-daemon
# start/stop/status + delivery-runner tick logic out of the root script
# per the repo convention (new logic lives in lib/bridge-*.sh helpers).
#
# The A2A receiver (`bridge-handoffd.py`) and the sender delivery runner
# (`bridge-a2a.py deliver`) are both managed here. The receiver is a
# long-lived process tracked by a pid file; the delivery runner is a
# short-lived drain invoked per tick (daemon-driven or cron-driven).

# Resolve the source-checkout root that holds the python entry points.
bridge_a2a_repo_root() {
  if [[ -n "${BRIDGE_A2A_REPO_ROOT:-}" ]]; then
    printf '%s' "$BRIDGE_A2A_REPO_ROOT"
    return 0
  fi
  # lib/bridge-a2a.sh -> repo root is the parent of lib/.
  local lib_dir
  lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  printf '%s' "$(cd -P "$lib_dir/.." && pwd -P)"
}

bridge_a2a_state_dir() {
  printf '%s' "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

bridge_a2a_handoff_dir() {
  printf '%s' "$(bridge_a2a_state_dir)/handoff"
}

bridge_a2a_config_path() {
  if [[ -n "${BRIDGE_A2A_CONFIG:-}" ]]; then
    printf '%s' "$BRIDGE_A2A_CONFIG"
    return 0
  fi
  printf '%s' "${BRIDGE_HOME:-$HOME/.agent-bridge}/handoff.local.json"
}

bridge_a2a_pid_file() {
  printf '%s' "$(bridge_a2a_handoff_dir)/handoffd.pid"
}

bridge_a2a_log_file() {
  printf '%s' "${BRIDGE_LOG_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/logs}/a2a-handoffd.log"
}

# True if `pid` is alive AND its command line is the A2A receiver for
# THIS install — i.e. a `bridge-handoffd.py serve` process launched with
# `--pidfile <pid_file>`. A bare `kill -0` is not enough: after the real
# receiver dies, PID reuse can hand that number to an unrelated live
# process (issue #1043 review r1). Matching only `bridge-handoffd.py` +
# `serve` is also not enough: another Agent Bridge install / config runs
# the same binary, so a stale pid file pointing at *that* install's
# receiver would still read as "running" here (review r2). The receiver
# is launched as `bridge-handoffd.py serve --config <config>
# --detach --pidfile <pid_file>`, and the pidfile path is unique per
# `$BRIDGE_HOME`, so requiring the exact `--pidfile <pid_file>` token in
# the cmdline ties the process to the exact pidfile being read.
# `ps -p <pid> -o command=` is portable across macOS and Linux.
#
# Args: $1 = pid, $2 = expected pidfile path the process must reference.
bridge_a2a_receiver_pid_is_receiver() {
  local pid="$1" expect_pid_file="$2" cmd
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$expect_pid_file" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *bridge-handoffd.py* && "$cmd" == *serve* ]] || return 1
  # Bind the match to this install: the running cmdline must carry the
  # exact `--pidfile` value of the pid file we just read.
  [[ "$cmd" == *"--pidfile $expect_pid_file"* ]]
}

# True if a receiver daemon is running: pid file present, the pid is
# alive, AND that pid is genuinely THIS install's A2A receiver process
# (not a coincidental PID-reuse match, nor another install's receiver).
bridge_a2a_receiver_running() {
  local pid_file pid
  pid_file="$(bridge_a2a_pid_file)"
  [[ -f "$pid_file" ]] || return 1
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  bridge_a2a_receiver_pid_is_receiver "$pid" "$pid_file"
}

bridge_a2a_receiver_pid() {
  local pid_file
  pid_file="$(bridge_a2a_pid_file)"
  [[ -f "$pid_file" ]] && cat "$pid_file" 2>/dev/null || true
}

# Start the receiver daemon in the background. Fails closed: the python
# entry point validates the tailnet bind and exits non-zero before this
# helper records a pid.
bridge_a2a_receiver_start() {
  local repo_root config pid_file log_file
  repo_root="$(bridge_a2a_repo_root)"
  config="$(bridge_a2a_config_path)"
  pid_file="$(bridge_a2a_pid_file)"
  log_file="$(bridge_a2a_log_file)"

  if bridge_a2a_receiver_running; then
    echo "[a2a] receiver already running (pid $(bridge_a2a_receiver_pid))"
    return 0
  fi
  if [[ ! -f "$config" ]]; then
    echo "[a2a][error] config not found: $config" >&2
    echo "[a2a]        copy handoff.local.example.json -> $config (chmod 0600)" >&2
    return 1
  fi

  mkdir -p "$(bridge_a2a_handoff_dir)" "$(dirname "$log_file")"

  # Preflight the bind synchronously so a fail-closed startup surfaces a
  # clear error instead of a daemon that exits silently in the background.
  if ! python3 "$repo_root/bridge-handoffd.py" preflight --config "$config"; then
    echo "[a2a][error] preflight failed; receiver not started" >&2
    return 1
  fi

  # Stale pid file from a previous (now-dead) receiver would otherwise let
  # the new launch's success check pass against the old pid.
  rm -f "$pid_file"

  # `serve --detach` double-forks into its own session AFTER the socket
  # bind, so the receiver is reparented out of this shell's process group
  # and survives the launching (managed agent) shell exiting. A bare
  # `nohup ... &` did not detach from the process group, so the listener
  # could be torn down with the tool session — issue #1043. The detached
  # grandchild owns the pid file, so the recorded pid is the durable
  # listener rather than a transient launcher pid.
  #
  # `--pidfile` is placed before `--config` so the per-install unique key
  # that bridge_a2a_receiver_pid_is_receiver() matches on appears early in
  # the cmdline, ahead of the (potentially long) config path, in case
  # `ps -o command=` truncates very long command lines.
  nohup python3 "$repo_root/bridge-handoffd.py" serve \
    --pidfile "$pid_file" --detach --config "$config" \
    >>"$log_file" 2>&1 &
  local launcher_pid=$!
  # The launcher process exits 0 once the detached child is running; if the
  # bind failed closed, it exits non-zero before any detach. Guard the wait
  # so a non-zero exit does not trip the caller's `set -e`.
  local launcher_rc=0
  wait "$launcher_pid" || launcher_rc=$?
  if (( launcher_rc != 0 )); then
    rm -f "$pid_file"
    echo "[a2a][error] receiver failed to start (exit $launcher_rc); see $log_file" >&2
    return 1
  fi

  # Wait for the detached child to publish its pid, then verify the pid is
  # genuinely the A2A receiver process — confirms a durable listener, not a
  # false success against a coincidental pid.
  local waited=0 pid=""
  while (( waited < 10 )); do
    if [[ -f "$pid_file" ]]; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      if bridge_a2a_receiver_pid_is_receiver "$pid" "$pid_file"; then
        break
      fi
    fi
    sleep 1
    waited=$((waited + 1))
    pid=""
  done
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    echo "[a2a][error] receiver did not come up durably; see $log_file" >&2
    return 1
  fi
  echo "[a2a] receiver started (pid $pid); log: $log_file"
  return 0
}

bridge_a2a_receiver_stop() {
  local pid_file pid
  pid_file="$(bridge_a2a_pid_file)"
  if ! bridge_a2a_receiver_running; then
    rm -f "$pid_file" 2>/dev/null || true
    echo "[a2a] receiver not running"
    return 0
  fi
  pid="$(bridge_a2a_receiver_pid)"
  kill "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$pid_file" 2>/dev/null || true
  echo "[a2a] receiver stopped (pid $pid)"
  return 0
}

# Run one delivery-runner drain pass (short-lived).
bridge_a2a_deliver_tick() {
  local repo_root config
  repo_root="$(bridge_a2a_repo_root)"
  config="$(bridge_a2a_config_path)"
  if [[ ! -f "$config" ]]; then
    echo "[a2a][error] config not found: $config" >&2
    return 1
  fi
  python3 "$repo_root/bridge-a2a.py" deliver "$@"
}

# Thin wrapper around `bridge-handoffd.py healthz` (#1405) — read-only serve
# liveness probe via GET /healthz against the configured (resolve_bind-proven)
# bind. Prints the reason word on stdout, returns the python exit code. Never
# binds/serves. Used by `agb a2a daemon healthz` and surfaced in status.
bridge_a2a_receiver_healthz() {
  local repo_root config
  repo_root="$(bridge_a2a_repo_root)"
  config="$(bridge_a2a_config_path)"
  if [[ ! -f "$config" ]]; then
    echo "[a2a][error] config not found: $config" >&2
    return 1
  fi
  python3 "$repo_root/bridge-handoffd.py" healthz --config "$config" "$@"
}

bridge_a2a_status() {
  local config
  config="$(bridge_a2a_config_path)"
  echo "config        : $config $( [[ -f "$config" ]] && printf '(present)' || printf '(MISSING)')"
  echo "handoff_dir   : $(bridge_a2a_handoff_dir)"
  echo "pid_file      : $(bridge_a2a_pid_file)"
  if bridge_a2a_receiver_running; then
    echo "receiver      : running (pid $(bridge_a2a_receiver_pid))"
  else
    echo "receiver      : stopped"
  fi
  echo "log           : $(bridge_a2a_log_file)"

  # #1405: surface the daemon supervisor's view — restart counter, alarm, and
  # last-exit cause — so `agb a2a daemon status` shows the supervised health,
  # not just the bare pid state. The supervise.env is the daemon-written
  # state file (all scalar, A2A_RECEIVER_*-namespaced; sourced safely here).
  local supervise_file
  supervise_file="$(bridge_a2a_handoff_dir)/receiver-supervise.env"
  if [[ -f "$supervise_file" ]]; then
    # Subshell-source so the A2A_RECEIVER_* vars never leak into the caller's
    # scope (and a malformed file cannot poison it).
    (
      # shellcheck source=/dev/null
      # shellcheck disable=SC1090
      source "$supervise_file" 2>/dev/null || exit 0
      local rc="${A2A_RECEIVER_RESTART_COUNT:-0}"
      local alarm="${A2A_RECEIVER_ALARM:-}"
      local reason="${A2A_RECEIVER_LAST_REASON:-}"
      local exit_event="${A2A_RECEIVER_LAST_EXIT_EVENT:-}"
      if [[ -n "$alarm" ]]; then
        printf 'supervise     : ALARM=%s restarts=%s last_reason=%s\n' \
          "$alarm" "$rc" "${reason:-unknown}"
      elif [[ -n "$reason" && "$reason" != "healthy" ]]; then
        printf 'supervise     : restarts=%s last_reason=%s\n' "$rc" "$reason"
      else
        printf 'supervise     : healthy (restarts=%s)\n' "$rc"
      fi
      [[ -n "$exit_event" ]] && printf 'last_exit     : %s\n' "$exit_event"
    )
  fi
  local exit_json
  exit_json="$(bridge_a2a_handoff_dir)/receiver-exit.json"
  [[ -f "$exit_json" ]] && echo "exit_cause    : $exit_json"

  # #1685: surface the destination-side staleness self-heal state — whether a
  # one-shot stale-code restart was attempted for the current upgrade and how it
  # resolved. Read-only; a malformed/absent file is a quiet skip. The JSON read
  # goes through the file-as-argv staleness helper `status` subcommand (footgun
  # #11: NO heredoc-stdin to a subprocess), which prints a TSV `result<TAB>detail`
  # line or nothing.
  local staleness_file repo_root
  staleness_file="$(bridge_a2a_handoff_dir)/receiver-staleness.json"
  repo_root="$(bridge_a2a_repo_root)"
  if [[ -f "$staleness_file" ]]; then
    local _stale_row
    _stale_row="$(python3 "$repo_root/lib/daemon-helpers/a2a-receiver-staleness.py" status "$staleness_file" 2>/dev/null || true)"
    if [[ -n "$_stale_row" ]]; then
      # Split the tab-delimited `result<TAB>detail` row with pure parameter
      # expansion — NO here-string (footgun #11 / H3 heredoc-ban gate). The
      # helper always emits a tab; if one is somehow absent, `%%` leaves the
      # whole row as the result and `#*\t` (no match) makes detail empty rather
      # than duplicating the row.
      local _stale_result _stale_detail
      _stale_result="${_stale_row%%$'\t'*}"
      if [[ "$_stale_row" == *$'\t'* ]]; then
        _stale_detail="${_stale_row#*$'\t'}"
      else
        _stale_detail=""
      fi
      printf 'staleness     : last self-heal=%s%s\n' \
        "${_stale_result:-?}" \
        "$( [[ -n "$_stale_detail" ]] && printf ' (%s)' "$_stale_detail" )"
    fi
    echo "staleness_file: $staleness_file"
  fi
  local boot_marker
  boot_marker="$(bridge_a2a_handoff_dir)/receiver-boot.json"
  [[ -f "$boot_marker" ]] && echo "boot_marker   : $boot_marker"
}

# Trigger + preview one receiver self-heal reconcile (P-self-heal-1, #1403).
# Sends SIGHUP to the running receiver so the LIVE daemon runs an immediate
# reconcile (auto-rebind on local-IP drift + config hot-reload) with no
# restart, then prints a preview of what a reconcile would resolve/prove via
# `bridge-handoffd.py reconcile` (re-resolve + RE-PROVE the bind through the
# unchanged fail-closed proof; validate the config). Both stay fail-closed:
# a resolve/prove failure is reported, never silently bound; the running
# daemon keeps its current proven bind + last-good config on any failure.
bridge_a2a_reconcile() {
  local repo_root config pid
  repo_root="$(bridge_a2a_repo_root)"
  config="$(bridge_a2a_config_path)"
  if [[ ! -f "$config" ]]; then
    echo "[a2a][error] config not found: $config" >&2
    return 1
  fi
  if bridge_a2a_receiver_running; then
    pid="$(bridge_a2a_receiver_pid)"
    if kill -HUP "$pid" 2>/dev/null; then
      echo "[a2a] sent SIGHUP to receiver (pid $pid) — immediate reconcile" \
           "(auto-rebind on local-IP drift + config hot-reload); no restart"
    else
      echo "[a2a][warn] could not signal receiver pid $pid" >&2
    fi
  else
    echo "[a2a] receiver not running — it self-heals on its own timer once started"
  fi
  # Preview the reconcile decision (fail-closed report) using the same proof
  # the running daemon uses.
  python3 "$repo_root/bridge-handoffd.py" reconcile --config "$config"
}

# --------------------------------------------------------------------------
# #1563 PR-4: A2A receiver supervision POLICY (bounded backoff + circuit
# breaker). Pure decision helpers — no live-process I/O — so the daemon
# supervise tick (process_a2a_receiver_supervise_tick in bridge-daemon.sh)
# stays small and the policy is unit-testable in isolation. NONE of these
# touch the fail-closed bind/HMAC boundary; they only decide WHEN the
# supervisor may re-attempt a restart and WHEN to stop + escalate.
#
# The thrash these fix (#1563): when the tailnet bind is transiently
# unavailable (tailnet not yet up / IP drift after a re-login), the receiver
# fails the fail-closed preflight, exits, gets respawned immediately, fails
# again — a ~9-minute crash-loop with no backoff. A transient bind failure
# now backs off exponentially and, after N consecutive failures for the same
# (config-fingerprint, error_class) key, OPENS the breaker (stop respawning +
# escalate once per cooldown). A successful bind RESETS the key. A real
# auth/config error is NEVER routed through the transient-retry path — it is
# held immediately, surfacing the real error instead of thrashing.
# --------------------------------------------------------------------------

# Exponential backoff (seconds) for the Nth consecutive TRANSIENT failure of a
# key: base * 2^(n-1), capped. n is 1-based (the 1st failure waits `base`).
# Tunable via env so the smoke can compress the schedule. Always echoes a
# non-negative integer; clamps a bad/zero input to the floor.
bridge_a2a_backoff_seconds() {
  local n="$1"
  local base="${BRIDGE_A2A_RECEIVER_BACKOFF_BASE_SECONDS:-30}"
  local cap="${BRIDGE_A2A_RECEIVER_BACKOFF_CAP_SECONDS:-900}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  [[ "$base" =~ ^[0-9]+$ ]] || base=30
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=900
  (( n < 1 )) && n=1
  (( base < 1 )) && base=1
  # Compute base * 2^(n-1) with an early exit once we exceed the cap so a
  # large n cannot overflow / spin.
  local secs="$base" i=1
  while (( i < n )); do
    secs=$(( secs * 2 ))
    if (( secs >= cap )); then
      secs="$cap"
      break
    fi
    i=$(( i + 1 ))
  done
  (( secs > cap )) && secs="$cap"
  printf '%s' "$secs"
}

# True (return 0) when the circuit breaker should be OPEN for a key after
# `consec_failures` consecutive TRANSIENT failures — i.e. stop respawning and
# escalate. Threshold tunable via BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD
# (default 5). Only meaningful for the transient class; the caller routes
# auth_config to an immediate hold (never the backoff path) and unknown to the
# legacy bounded-restart cap.
bridge_a2a_breaker_should_open() {
  local consec_failures="$1"
  local threshold="${BRIDGE_A2A_RECEIVER_BACKOFF_OPEN_THRESHOLD:-5}"
  [[ "$consec_failures" =~ ^[0-9]+$ ]] || consec_failures=0
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=5
  (( threshold < 1 )) && threshold=1
  (( consec_failures >= threshold ))
}

# Decide what the supervisor should do for a confirmed-dead receiver, given the
# classified error_class, the per-key consecutive-failure count, the last
# attempt ts, and now. Echoes ONE decision word on stdout:
#   retry   — enough backoff has elapsed (or first attempt); attempt a restart.
#   wait    — a transient failure whose backoff window has NOT elapsed; hold
#             this tick WITHOUT counting a new attempt (no thrash).
#   open    — transient failures reached the open threshold; stop respawning,
#             escalate once per cooldown.
#   hold    — a non-transient auth/config error; do NOT retry into a thrash,
#             surface the real error and escalate once per cooldown.
#
# `error_class` ∈ {transient, auth_config, unknown}. `unknown` returns "retry"
# so the caller falls back to the pre-#1563 bounded-restart cap (a previously
# healthy receiver that died/wedged may legitimately restart promptly).
bridge_a2a_supervise_decision() {
  local error_class="$1" consec_failures="$2" last_attempt_ts="$3" now="$4"
  [[ "$consec_failures" =~ ^[0-9]+$ ]] || consec_failures=0
  [[ "$last_attempt_ts" =~ ^[0-9]+$ ]] || last_attempt_ts=0
  [[ "$now" =~ ^[0-9]+$ ]] || now=0

  case "$error_class" in
    auth_config)
      # Never retry a config/auth error into a thrash — hold + escalate.
      printf 'hold'
      return 0
      ;;
    transient)
      if bridge_a2a_breaker_should_open "$consec_failures"; then
        printf 'open'
        return 0
      fi
      # Honor exponential backoff between transient attempts. The Nth attempt
      # waits backoff(N) since the LAST attempt; consec_failures is the count
      # of failures ALREADY recorded, so the next backoff is backoff(consec+1).
      local need elapsed
      need="$(bridge_a2a_backoff_seconds "$((consec_failures + 1))")"
      elapsed=$(( now - last_attempt_ts ))
      if (( consec_failures > 0 )) && (( elapsed < need )); then
        printf 'wait'
      else
        printf 'retry'
      fi
      return 0
      ;;
    *)
      # unknown — defer to the caller's bounded-restart cap (legacy behavior).
      printf 'retry'
      return 0
      ;;
  esac
}
