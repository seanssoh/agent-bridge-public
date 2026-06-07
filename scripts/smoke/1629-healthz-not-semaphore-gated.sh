#!/usr/bin/env bash
# scripts/smoke/1629-healthz-not-semaphore-gated.sh — A2A receiver liveness
# probe must NOT share the request-concurrency semaphore (#1629, audit R2 HIGH).
#
# Problem (#1629): the A2A receiver (bridge-handoffd.py) acquires a slot of the
# `_request_semaphore` in process_request — at ACCEPT time, before the request
# line is even parsed — and only releases it after the handler finishes. The
# liveness endpoint (GET /healthz, do_GET) therefore ran ONLY inside a held
# slot. When all `max_concurrent_requests` slots were occupied by legitimate
# slow enqueues, the supervisor's GET /healthz probe got a 503, the supervisor
# (bridge-daemon.sh) misclassified the receiver DOWN, and restarted it
# mid-handoff — a self-inflicted outage exactly under peak traffic.
#
# Fix (#1629): process_request MSG_PEEKs the request line BEFORE the semaphore
# gate; a `GET <healthz_path>` is dispatched WITHOUT consuming a slot, so a
# saturated-but-healthy receiver still answers liveness 200. The probe still
# flows through the normal handler (do_GET) and returns exactly what it did
# before. EVERY other method/path (enqueue + all signed control paths) still
# acquires a slot at accept time; the HMAC / bind / remote_addr / allowlist /
# dedupe gates are UNTOUCHED.
#
# Asserts:
#   (1) static teeth — process_request has the healthz peek-exemption branch and
#       a non-destructive MSG_PEEK helper; the semaphore release is CONDITIONAL
#       (so the exempt probe never over-releases a BoundedSemaphore). Reverting
#       the fix removes these and FAILS (1).
#   (2) live behavior — with EVERY semaphore slot held by slow connections:
#         * GET /healthz returns 200 (the exemption — NOT 503), and
#         * a real GET / returns 503 (proves the slots really ARE saturated,
#           i.e. the 200 above is the exemption, not an idle receiver).
#       Pre-fix, the slow connections saturate the semaphore and the healthz
#       probe ALSO 503s -> this check FAILS, which is the negative control.
#   (3) baseline — on an UN-saturated receiver, GET /healthz returns 200
#       (the exemption did not change the normal-path response).
#   (4) fail-closed INTACT — the semaphore exemption did not loosen the boundary:
#       a bad HMAC still -> 401 and a non-allowlisted target still -> 403.
#   (5) accept-loop NOT stalled — the classification peek runs on the single
#       accept thread, so it MUST be bounded. With an idle peer holding a
#       connection open but withholding its request line, a fresh GET /healthz
#       must still be answered FAST (well under the request timeout), not after
#       the full deadline. Pre-bounded-peek (a blocking MSG_PEEK with the full
#       request timeout) this took ~request_timeout and FAILS (5) — the codex r1
#       [P1] (one slow-connect connection starving the accept loop).
#   (6) exempt probe is BOUNDED — the probe skips the request semaphore but still
#       runs a worker thread that parses headers, so a healthz-SHAPED slow flood
#       (request line then stall) must not spawn unbounded threads. The probe has
#       its own small bounded semaphore; overflow connections beyond the bound
#       are rejected fast (503) at accept time with no thread. codex r2 [P1].
#
# Loopback / test-bind harness (BRIDGE_A2A_ALLOW_TEST_BIND=1, free port) +
# absent `tailscale` mirrors 1405-handoffd-supervision.sh / a2a-cross-bridge.sh.
# Footgun #11: all Python driving is via the *-helper.py file-as-argv sidecar.
# Run with /opt/homebrew/bin/bash (Bash 5.x) on macOS.

set -euo pipefail

SMOKE_NAME="1629-healthz-not-semaphore-gated"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HANDOFFD_PID=""
A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"

# A small concurrency cap so a couple of slow connections saturate the semaphore,
# and a multi-second request deadline so the held connections occupy their slots
# long enough for the probes to fire while saturated.
export BRIDGE_A2A_ALLOW_TEST_BIND=1
export BRIDGE_A2A_MAX_CONCURRENT_REQUESTS=2
export BRIDGE_A2A_REQUEST_TIMEOUT_SECONDS=4

cleanup() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

config_path()      { printf '%s/handoff.local.json' "$BRIDGE_HOME"; }
handoffd_pidfile() { printf '%s/handoff/handoffd.pid' "$BRIDGE_STATE_DIR"; }
handoffd_log()     { printf '%s/a2a-handoffd.log' "$BRIDGE_LOG_DIR"; }
receiver_pid_now() { cat "$(handoffd_pidfile)" 2>/dev/null || true; }

pick_free_port() { python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" free-port; }

# A valid loopback config: bind 127.0.0.1 under BRIDGE_A2A_ALLOW_TEST_BIND so a
# real receiver can come up.
write_loopback_config() {
  local port="$1"
  mkdir -p "$BRIDGE_HOME"
  {
    printf '{\n'
    printf '  "bridge_id": "bridge-b",\n'
    printf '  "listen": { "address": "127.0.0.1", "port": %s, "enqueue_path": "/enqueue" },\n' "$port"
    printf '  "timestamp_skew_seconds": 300,\n'
    printf '  "peers": [\n'
    printf '    {\n'
    printf '      "id": "bridge-a",\n'
    printf '      "address": "127.0.0.1",\n'
    printf '      "port": %s,\n' "$port"
    printf '      "secret": "%s",\n' "$A2A_SECRET"
    printf '      "inbound_allowlist": ["reviewer"],\n'
    printf '      "caps": { "max_body_bytes": 262144 }\n'
    printf '    }\n'
    printf '  ]\n'
    printf '}\n'
  } >"$(config_path)"
  chmod 0600 "$(config_path)"
}

start_receiver_via_lifecycle() {
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" start >/dev/null 2>&1
  local waited=0
  while (( waited < 50 )); do
    if python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$(handoffd_log)" 2>/dev/null)"
}

# --- Check (1): static teeth — the exemption branch + MSG_PEEK helper +
#               conditional release exist in process_request -----------------
check_source_exemption_present() {
  local src
  src="$(cat "$SMOKE_REPO_ROOT/bridge-handoffd.py")"
  smoke_assert_contains "$src" "_peek_is_healthz_probe" \
    "(1) process_request has a non-destructive healthz peek helper"
  smoke_assert_contains "$src" "socket.MSG_PEEK" \
    "(1) the peek is non-destructive (MSG_PEEK — bytes left for the real handler)"
  smoke_assert_contains "$src" "if self._peek_is_healthz_probe(request):" \
    "(1) process_request exempts the healthz probe BEFORE the request semaphore acquire"
  smoke_assert_contains "$src" "if semaphore is not None:" \
    "(1) the semaphore release is per-connection (exempt probe never over-releases)"
  smoke_assert_contains "$src" "_healthz_semaphore" \
    "(1) the exempt probe has its OWN bounded semaphore (healthz-shaped flood cannot spawn unbounded threads)"
}

# --- Check (2): live — healthz 200 while saturated, real request 503 --------
check_healthz_alive_while_saturated() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  HANDOFFD_PID="$(receiver_pid_now)"

  local out
  out="$(python3 "$SCRIPT_DIR/1629-healthz-not-semaphore-gated-helper.py" \
    saturate-then-probe 127.0.0.1 "$A2A_PORT" "$BRIDGE_A2A_MAX_CONCURRENT_REQUESTS" 4 2>/dev/null || true)"

  smoke_assert_contains "$out" "HELD=$BRIDGE_A2A_MAX_CONCURRENT_REQUESTS" \
    "(2) all $BRIDGE_A2A_MAX_CONCURRENT_REQUESTS semaphore slots were held by slow connections"
  smoke_assert_contains "$out" "REAL=503" \
    "(2) a real request 503s under saturation (proves the semaphore IS full)"
  smoke_assert_contains "$out" "HEALTHZ=200" \
    "(2) GET /healthz still returns 200 while saturated (the #1629 exemption, NOT 503)"
  smoke_assert_not_contains "$out" "HEALTHZ=503" \
    "(2) the saturated receiver did NOT 503 the liveness probe"

  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

# --- Check (3): baseline — healthz 200 on an UN-saturated receiver ----------
check_healthz_baseline() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  HANDOFFD_PID="$(receiver_pid_now)"

  local out
  out="$(python3 "$SCRIPT_DIR/1629-healthz-not-semaphore-gated-helper.py" \
    probe-healthz 127.0.0.1 "$A2A_PORT" 2>/dev/null || true)"
  smoke_assert_contains "$out" "HEALTHZ=200" \
    "(3) GET /healthz returns 200 on an idle receiver (exemption preserves the normal response)"

  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

# --- Check (4): fail-closed INTACT — the exemption did NOT loosen the boundary
check_fail_closed_intact() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  HANDOFFD_PID="$(receiver_pid_now)"

  local base="http://127.0.0.1:$A2A_PORT"

  local out_auth
  out_auth="$(python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" auth-fail "$base" bridge-a "$A2A_SECRET" 2>/dev/null || true)"
  smoke_assert_contains "$out_auth" "STATUS=401" \
    "(4) fail-closed INTACT: bad HMAC still -> 401 (healthz exemption did not loosen auth)"

  local out_allow
  out_allow="$(python3 "$SCRIPT_DIR/a2a-cross-bridge-helper.py" allowlist-fail "$base" bridge-a "$A2A_SECRET" 2>/dev/null || true)"
  smoke_assert_contains "$out_allow" "STATUS=403" \
    "(4) fail-closed INTACT: non-allowlisted target still -> 403 (allowlist unchanged)"

  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

# --- Check (5): an idle slow-connect peer must NOT stall the accept loop ------
check_idle_connect_does_not_stall_accept() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  HANDOFFD_PID="$(receiver_pid_now)"

  local out
  out="$(python3 "$SCRIPT_DIR/1629-healthz-not-semaphore-gated-helper.py" \
    idle-connect-then-probe 127.0.0.1 "$A2A_PORT" 2>/dev/null || true)"
  smoke_assert_contains "$out" "HEALTHZ=200" \
    "(5) GET /healthz still answered 200 with an idle peer holding a connection open"

  # The request timeout is BRIDGE_A2A_REQUEST_TIMEOUT_SECONDS=4 (4000ms). A
  # blocking accept-loop peek would make the probe wait ~that long; the bounded
  # peek answers in tens of ms. Assert comfortably under the timeout.
  local elapsed
  elapsed="$(printf '%s\n' "$out" | sed -n 's/.*ELAPSED_MS=\([0-9]*\).*/\1/p' | head -1)"
  [[ "$elapsed" =~ ^[0-9]+$ ]] || smoke_fail "(5) could not parse ELAPSED_MS from: $out"
  (( elapsed < 1500 )) || smoke_fail \
    "(5) healthz probe took ${elapsed}ms with an idle peer — the accept-loop peek STALLED (blocking peek regression; expected < 1500ms, request timeout is 4000ms)"
  smoke_log "(5) idle-peer healthz probe answered in ${elapsed}ms (accept loop not stalled)"

  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

# --- Check (6): a healthz-shaped slow flood is bounded (no unbounded threads) -
# DEFAULT_MAX_CONCURRENT_HEALTHZ in bridge-handoffd.py is 8. Flood with 12
# healthz-shaped slow connections (request line then stall): the first 8 acquire
# the healthz semaphore and hang in header parsing; the 4 overflow connections
# get a fast 503 at accept time (no thread). Pre-fix (exempt probe with no bound)
# all 12 would be accepted into threads and the overflow would NOT be 503'd.
HEALTHZ_BOUND=8
check_healthz_flood_is_bounded() {
  A2A_PORT="$(pick_free_port)"
  write_loopback_config "$A2A_PORT"
  start_receiver_via_lifecycle
  HANDOFFD_PID="$(receiver_pid_now)"

  local flood=$((HEALTHZ_BOUND + 4))
  local out
  out="$(python3 "$SCRIPT_DIR/1629-healthz-not-semaphore-gated-helper.py" \
    healthz-slow-flood 127.0.0.1 "$A2A_PORT" "$flood" "$HEALTHZ_BOUND" 2>/dev/null || true)"
  smoke_assert_contains "$out" "OVERFLOW=4" \
    "(6) flood opened $flood healthz-shaped slow connections (4 over the bound of $HEALTHZ_BOUND)"
  smoke_assert_contains "$out" "REJECTED=4" \
    "(6) all 4 overflow connections were rejected fast (503) — the exempt probe is bounded, no unbounded thread spawn"

  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  HANDOFFD_PID=""
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1629-healthz-not-semaphore-gated"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_run "(1) static: process_request exempts GET /healthz from the semaphore" check_source_exemption_present
  smoke_run "(2) live: healthz 200 while saturated; real request 503 (negative control)" check_healthz_alive_while_saturated
  smoke_run "(3) baseline: healthz 200 on an idle receiver" check_healthz_baseline
  smoke_run "(4) fail-closed INTACT: bad HMAC -> 401, unknown peer -> 403" check_fail_closed_intact
  smoke_run "(5) idle slow-connect peer does NOT stall the accept loop" check_idle_connect_does_not_stall_accept
  smoke_run "(6) healthz-shaped slow flood is bounded (no unbounded thread spawn)" check_healthz_flood_is_bounded

  smoke_log "passed"
}

main "$@"
