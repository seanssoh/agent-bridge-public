#!/usr/bin/env bash
# scripts/smoke/2140-handoffd-detach-reexec.sh — A2A receiver detach fork-safety.
#
# Issue #2140: `bridge-handoffd.py serve --detach` daemonized with a pure POSIX
# double-fork that NEVER `exec`'d, so the long-lived serving process kept the
# fork-inherited interpreter state. The reconcile loop's bind re-prove
# (resolve_bind -> getaddrinfo) then ran in that fork-polluted grandchild and
# segfaulted on macOS NAT64 (Network.framework / getaddrinfo is not fork-safe in
# a process that double-forked WITHOUT exec).
#
# The fix: after binding + PROVING the listener synchronously in the launcher,
# re-`exec` a FRESH interpreter (carrying internal --already-detached +
# --inherited-listen-fd N) for the serving process, which ADOPTS the
# already-proven listener instead of re-binding. resolve_bind() still re-proves
# the bind every reconcile tick — now fork-safely.
#
# This smoke proves, in an isolated loopback BRIDGE_HOME (no real tailnet):
#   (a) `serve --detach` re-execs into a FRESH interpreter — the durable
#       listener's cmdline carries --already-detached + --inherited-listen-fd
#       (absent pre-fix: the durable process was the double-forked grandchild
#       whose cmdline was the original `serve --pidfile ... --detach ...`).
#   (b) the re-exec'd process ADOPTS the inherited fd (no second bind: healthz
#       is green on the adopted listener) AND still runs the bind re-prove each
#       reconcile (a SIGHUP-triggered reconcile lands a reconcile log line).
#   (c) a missing / invalid inherited fd FAILS CLOSED (exit non-zero + the
#       inherited_fd_missing / inherited_fd_invalid audit code) — it never
#       silently re-binds a fresh, unproven socket.
#
# Loopback harness reuses BRIDGE_A2A_ALLOW_TEST_BIND=1 + a free port, mirroring
# 1405-handoffd-supervision.sh. EVERY assertion has teeth: pre-fix, check (a)'s
# cmdline marker is absent and check (c)'s audit codes never appear (argparse
# rejects the unknown --already-detached flag before cmd_serve runs).

set -euo pipefail

SMOKE_NAME="2140-handoffd-detach-reexec"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"

export BRIDGE_A2A_ALLOW_TEST_BIND=1
# Keep the reconcile timer slow (SIGHUP drives the reconcile we assert on) so the
# periodic tick never races our log-boundary inspection.
export BRIDGE_A2A_RECONCILE_INTERVAL=3600

cleanup() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

pick_free_port() {
  python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" free-port
}

handoffd_pidfile() {
  printf '%s/handoff/handoffd.pid' "$BRIDGE_STATE_DIR"
}

handoffd_log() {
  printf '%s/a2a-handoffd.log' "$BRIDGE_LOG_DIR"
}

receiver_pid_now() {
  cat "$(handoffd_pidfile)" 2>/dev/null || true
}

write_loopback_config() {
  local port="$1"
  mkdir -p "$BRIDGE_HOME"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "listen": { "address": "127.0.0.1", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"]
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

# Start the receiver through the lifecycle script (nohup ... serve --detach
# --pidfile ...). A durable start ALSO proves the process gate
# (bridge_a2a_receiver_pid_is_receiver) recognizes the re-exec'd cmdline (it
# still carries `--pidfile <pidfile>` after the exec).
start_receiver_via_lifecycle() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" start >/dev/null 2>&1
  local waited=0
  while (( waited < 60 )); do
    if python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$(handoffd_log)" 2>/dev/null)"
}

# --- Check (a): serve --detach re-execs into a fresh interpreter ---------------
# The durable listener (from the pidfile) must be the RE-EXEC'D process: its
# cmdline carries the internal --already-detached + --inherited-listen-fd
# markers. Pre-fix the durable process is the double-forked grandchild whose
# cmdline is the ORIGINAL `serve --pidfile ... --detach --config ...` (no
# --already-detached), so this FAILS pre-fix.
check_reexec_fresh_interpreter() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle

  local pid cmd
  pid="$(receiver_pid_now)"
  [[ -n "$pid" ]] || smoke_fail "no durable receiver pid recorded"
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  smoke_assert_contains "$cmd" "--already-detached" \
    "durable listener is the re-exec'd process (--already-detached in cmdline)"
  smoke_assert_contains "$cmd" "--inherited-listen-fd" \
    "re-exec'd process adopts an inherited listen fd (--inherited-listen-fd in cmdline)"
  # It must still be a real serve process bound to this install's pidfile, i.e.
  # the re-exec preserved the tokens the process gate keys on.
  smoke_assert_contains "$cmd" "bridge-handoffd.py" \
    "re-exec'd cmdline still names bridge-handoffd.py"
  smoke_assert_contains "$cmd" "serve" \
    "re-exec'd cmdline still carries the serve subcommand"
}

# --- Check (b): adopts the inherited fd + re-proves the bind each reconcile ----
# healthz green proves the ADOPTED listener serves (had the re-exec re-bound a
# fresh socket, the --already-detached path would have FAILED CLOSED — it only
# ever adopts). A SIGHUP-triggered reconcile must land a reconcile log line —
# proving resolve_bind() re-runs (the #16247 bind re-prove) in the fresh
# interpreter — and the process must SURVIVE that re-prove. On a real macOS
# NAT64 host the pre-fix grandchild segfaulted exactly here; surviving the
# re-prove is the fork-safety invariant (the loopback test-bind cannot
# reproduce the NAT64 getaddrinfo crash itself — that is patch's live gate).
check_adopts_fd_and_reproves() {
  local out rc=0
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" healthz \
    --config "$BRIDGE_HOME/handoff.local.json" --timeout 3 2>&1)" || rc=$?
  smoke_assert_eq "0" "$rc" "healthz exits 0 against the adopted-fd receiver"
  smoke_assert_contains "$out" "healthy" "healthz prints 'healthy' on the adopted listener"

  local pid
  pid="$(receiver_pid_now)"
  [[ -n "$pid" ]] || smoke_fail "no durable receiver pid for the reconcile re-prove"

  # Mark a log boundary, fire a SIGHUP (immediate reconcile), then assert the
  # re-exec'd serve loop re-proved the bind (a reconcile line appears AFTER the
  # boundary). The handoffd re-installs its SIGHUP handler post-exec.
  local log_before
  log_before="$(wc -l < "$(handoffd_log)" 2>/dev/null || printf '0')"
  kill -HUP "$pid" 2>/dev/null || smoke_fail "could not SIGHUP receiver pid $pid"
  local waited=0 fresh=""
  while (( waited < 30 )); do
    fresh="$(tail -n +"$((log_before + 1))" "$(handoffd_log)" 2>/dev/null || true)"
    [[ "$fresh" == *reconcile* ]] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_assert_contains "$fresh" "reconcile" \
    "SIGHUP drove a reconcile (resolve_bind re-prove) in the re-exec'd interpreter"
  # The re-exec'd process must have SURVIVED running getaddrinfo in the reconcile
  # re-prove (the #2140 segfault was a child-of-fork-pre-exec crash right here).
  kill -0 "$pid" 2>/dev/null \
    || smoke_fail "re-exec'd receiver pid $pid died during the reconcile bind re-prove"
}

# --- Check (c1): --already-detached with NO inherited fd fails closed ----------
# A re-exec marker without a listener to adopt must REFUSE to serve (it must not
# silently re-bind a fresh, unproven socket). Pre-fix: argparse rejects the
# unknown --already-detached flag (exit 2), so the inherited_fd_missing audit
# code never appears — asserting the code gives teeth.
check_fail_closed_missing_fd() {
  local out rc=0
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve --already-detached \
    --config "$BRIDGE_HOME/handoff.local.json" 2>&1)" || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "serve --already-detached with no fd exits non-zero"
  smoke_assert_contains "$out" "inherited_fd_missing" \
    "missing inherited fd fails closed with the inherited_fd_missing audit code"
}

# --- Check (c2): --already-detached with an INVALID (non-socket) fd fails closed
# Pointing --inherited-listen-fd at fd 0 (/dev/null, a non-socket) must fail
# closed (getsockname -> ENOTSOCK), not adopt a bogus listener.
check_fail_closed_invalid_fd() {
  local out rc=0
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve --already-detached \
    --inherited-listen-fd 0 --config "$BRIDGE_HOME/handoff.local.json" \
    </dev/null 2>&1)" || rc=$?
  smoke_assert_match "$rc" '^[1-9]' "serve --already-detached with a non-socket fd exits non-zero"
  smoke_assert_contains "$out" "inherited_fd_invalid" \
    "a non-socket inherited fd fails closed with the inherited_fd_invalid audit code"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_run "serve --detach re-execs into a fresh interpreter" check_reexec_fresh_interpreter
  smoke_run "re-exec'd process adopts the inherited fd + re-proves the bind" check_adopts_fd_and_reproves
  smoke_run "missing inherited fd fails closed" check_fail_closed_missing_fd
  smoke_run "invalid (non-socket) inherited fd fails closed" check_fail_closed_invalid_fd

  smoke_log "passed"
}

main "$@"
