#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1671-teams-eaddrinuse-diagnostic.sh —
# v0.16.3 #1671-A — plugins/teams/server.ts must emit a CLEAR, actionable
# EADDRINUSE diagnostic (HOST:PORT + TEAMS_WEBHOOK_PORT env var name +
# "another process ... holds this port") instead of the prior bare
# `process.exit(1)` with a terse "http listen failed" line, AND it must NOT
# reap/kill the port holder (diagnostic-only — the reap was deferred because
# the holder's provenance is unprovable across a UID boundary; see the
# server.ts comment block at the httpServer 'error' handler).
#
# Re-exec under bash 4+ so we can use modern array / string features
# (matches scripts/smoke/beta5-2-zeta-teams-mcp-dedup.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1671-teams-eaddrinuse-diagnostic][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Background — Issue #1671-A (cm-prod LTS-blocker triage 2026-06-08):
#
#   teams-triage runs plugins/teams/server.ts in router-host mode and binds
#   its expected loopback port (e.g. 3982). On a post-upgrade restart that
#   bind hit EADDRINUSE because a reparented (ppid=1) stale teams listener
#   from a prior session still held the port. The prior handler was:
#
#     httpServer.on('error', err => {
#       process.stderr.write(`teams channel: http listen failed on ...: ${err}\n`)
#       process.exit(1)
#     })
#
#   → the operator had no actionable signal and the only recovery was waiting
#   out the orphan's #69 parent-death watchdog (a ~22-min gap during which the
#   router-default triage agent dropped unknown-Teams-sender traffic).
#
# Fix (codex full-consensus direction, LOW-RISK half — ALWAYS shipped):
#
#   `buildListenErrorDiagnostic(code, host, port, err)` is a pure function:
#     - code 'EADDRINUSE' → a clear diagnostic naming HOST:PORT, the
#       TEAMS_WEBHOOK_PORT env var, and "another process ... holds this port",
#       plus the recovery hint (ss/lsof + restart, #69 self-heal note).
#     - any other code → the prior terse "http listen failed" line.
#   The single `httpServer.on('error', ...)` handler calls it and exits 1.
#
#   The reap+retry half was DEFERRED (NOT shipped) for #1671-A: a safe reap
#   needs a strict provenance gate (prove the holder is THIS agent's own
#   stale teams listener), but the actual cm-prod holder ran under a different
#   OS user so its argv/cwd/env are unreadable → ownership is UNPROVABLE → a
#   reap would be killing an arbitrary port holder. So server.ts emits the
#   diagnostic and exits, letting the existing #69 watchdog self-heal.
#
# Test plan:
#
#   T1 — Static-source: the EADDRINUSE branch tokens are present in
#        plugins/teams/server.ts (buildListenErrorDiagnostic, the EADDRINUSE
#        code check, the TEAMS_WEBHOOK_PORT mention, the "another process"
#        phrase). Pins the diagnostic content so a refactor cannot silently
#        regress to a terse line.
#
#   T2 — Static-source: the handler does NOT call any kill/reap primitive
#        in the bind-error path (no process.kill / spawnSync('kill' ...) /
#        treeKill in the buildListenErrorDiagnostic body or the 'error'
#        handler). Asserts the deferred-reap decision stays deferred — an
#        un-provable reap must not sneak in.
#
#   T3 — Behavioural (EADDRINUSE diagnostic shape): invoke the
#        `_smoke-listen-error-diagnostic --variant eaddrinuse` subcommand
#        with TEAMS_WEBHOOK_HOST/PORT set and assert the stdout diagnostic
#        contains HOST:PORT, the env var name, the "another process ... holds
#        this port" phrase, and the EADDRINUSE token. (No real listener.)
#
#   T4 — Behavioural (generic-error fallback): the `--variant generic`
#        subcommand emits the terse "http listen failed on HOST:PORT" line
#        and does NOT mention TEAMS_WEBHOOK_PORT / EADDRINUSE. Pins that the
#        EADDRINUSE branch is selective and non-port errors keep the old
#        shape.
#
#   T5 — Behavioural (REAL listener path + NEGATIVE reap-proof, REQUIRED):
#        start an UNRELATED decoy http listener on a free loopback port,
#        then start the real server.ts (full httpServer.listen path) against
#        the SAME port. Assert: (a) server.ts exits NON-ZERO, (b) its stderr
#        carries the EADDRINUSE diagnostic, and (c) the decoy listener is
#        STILL ALIVE afterwards — proving server.ts does NOT kill an
#        unrelated port holder (diagnostic-only, no reap).
#
#   T6 (teeth) — copy server.ts, revert the EADDRINUSE branch back to the
#        bare terse line, and confirm the T1 content grep would trip. Asserts
#        the regression detector is load-bearing. (We do not mutate the live
#        source — concurrent CI smokes share it.)
#
#   T7 — ci-select registration: scripts/ci-select-smoke.sh maps
#        plugins/teams/server.ts to this smoke AND lists it in
#        add_all_required_static.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; the bun
# invocations short-circuit before / at httpServer.listen and use stub
# TEAMS_APP_ID/TEAMS_APP_PASSWORD so module load does not trip the
# missing-credentials check. The behavioural listener test binds a free
# loopback port and tears everything down on EXIT. No real Teams traffic.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every assertion
# uses `printf`/`grep`/`$()` against temp files — no `<<<` here-strings into
# bridge functions and no command substitution feeding a heredoc stdin into
# subprocess capture.

set -uo pipefail

SMOKE_NAME="1671-teams-eaddrinuse-diagnostic"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
TEAMS_SERVER="$REPO_ROOT/plugins/teams/server.ts"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
TEAMS_DIR="$REPO_ROOT/plugins/teams"

[[ -f "$TEAMS_SERVER" ]] || smoke_fail "missing $TEAMS_SERVER"
[[ -f "$CI_SELECT" ]] || smoke_fail "missing $CI_SELECT"

# Bun is required to exercise the behavioural variants (T3-T5).
# Static-source tests (T1, T2, T6, T7) run on every host.
HAS_BUN=0
if command -v bun >/dev/null 2>&1; then
  HAS_BUN=1
fi
# node is needed for the T5 decoy listener (a tiny http server).
HAS_NODE=0
if command -v node >/dev/null 2>&1; then
  HAS_NODE=1
fi

DECOY_PID=""
cleanup() {
  if [[ -n "$DECOY_PID" ]] && kill -0 "$DECOY_PID" 2>/dev/null; then
    kill "$DECOY_PID" 2>/dev/null || true
    wait "$DECOY_PID" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# ---------------------------------------------------------------------
# T1: the EADDRINUSE diagnostic content is present in server.ts.
# ---------------------------------------------------------------------
test_t1_diagnostic_content_present() {
  smoke_log "T1: server.ts carries the buildListenErrorDiagnostic EADDRINUSE branch + content tokens"
  grep -qE '^export function buildListenErrorDiagnostic\(' "$TEAMS_SERVER" \
    || smoke_fail "T1: buildListenErrorDiagnostic export not found"
  grep -q "code === 'EADDRINUSE'" "$TEAMS_SERVER" \
    || smoke_fail "T1: EADDRINUSE code check not found in server.ts"
  grep -q 'TEAMS_WEBHOOK_PORT' "$TEAMS_SERVER" \
    || smoke_fail "T1: diagnostic does not name TEAMS_WEBHOOK_PORT env var"
  grep -q 'another process' "$TEAMS_SERVER" \
    || smoke_fail "T1: diagnostic missing the 'another process ... holds this port' phrase"
  # The bind-error handler must call the diagnostic builder.
  grep -q 'buildListenErrorDiagnostic(code, HOST, PORT, err)' "$TEAMS_SERVER" \
    || smoke_fail "T1: httpServer 'error' handler does not call buildListenErrorDiagnostic(code, HOST, PORT, err)"
  smoke_log "T1 PASS"
}

# ---------------------------------------------------------------------
# T2: the bind-error path does NOT reap/kill the port holder.
# ---------------------------------------------------------------------
test_t2_no_reap_in_bind_error_path() {
  smoke_log "T2: server.ts bind-error path performs NO kill/reap (deferred-reap stays deferred)"
  # Extract the buildListenErrorDiagnostic body + the httpServer 'error'
  # handler block and assert no kill primitive appears in either.
  # We grep the whole file for kill primitives that would only make sense
  # in a reap path: process.kill(, spawnSync('kill', execSync('kill,
  # treeKill(. server.ts already uses spawnSync for bridge-guard / git, so
  # we must scope to actual KILL invocations, not any spawnSync.
  local kill_hits
  kill_hits="$(grep -nE 'process\.kill\(|spawnSync\(.kill|execSync\(.kill|treeKill\(|kill -9|killProcess\(' "$TEAMS_SERVER" \
    | grep -vE '^\s*[0-9]+:\s*//' || true)"
  if [[ -n "$kill_hits" ]]; then
    smoke_fail "T2: server.ts contains a kill/reap primitive — an un-provable reap must NOT be present:\n$kill_hits"
  fi
  smoke_log "T2 PASS (no kill/reap primitive present)"
}

# ---------------------------------------------------------------------
# Helper: run the diagnostic subcommand and capture stdout.
# ---------------------------------------------------------------------
run_diagnostic_variant() {
  local variant="$1" host="$2" port="$3"
  local stdout_file="$SMOKE_TMP_ROOT/diag.$variant.stdout"
  local stderr_file="$SMOKE_TMP_ROOT/diag.$variant.stderr"
  # Isolation (codex r1 [P2]): server.ts runs module-load side effects
  # (chmod/read .env, consent sweep) BEFORE the smoke subcommand short-circuit.
  # ENV_FILE is derived from TEAMS_STATE_DIR (join(STATE_DIR, '.env')), so
  # pinning TEAMS_STATE_DIR + MS365_CALLBACK_SHARED_DIR under the temp root is
  # sufficient to keep the launch off live ~/.claude/channels/teams state.
  # (BRIDGE_HOME is already the smoke_setup_bridge_home temp dir.)
  TEAMS_APP_ID=smoke TEAMS_APP_PASSWORD=smoke \
    TEAMS_STATE_DIR="$SMOKE_TMP_ROOT/teams-state" \
    MS365_CALLBACK_SHARED_DIR="$SMOKE_TMP_ROOT/ms365-callbacks" \
    TEAMS_WEBHOOK_HOST="$host" TEAMS_WEBHOOK_PORT="$port" \
    bun "$TEAMS_SERVER" _smoke-listen-error-diagnostic --variant "$variant" \
    >"$stdout_file" 2>"$stderr_file"
  printf '%s\n' "$stdout_file" "$stderr_file"
}

# ---------------------------------------------------------------------
# T3: EADDRINUSE diagnostic shape.
# ---------------------------------------------------------------------
test_t3_eaddrinuse_diagnostic_shape() {
  smoke_log "T3: --variant eaddrinuse emits HOST:PORT + TEAMS_WEBHOOK_PORT + 'another process ... holds this port'"
  local files stdout_file
  files="$(run_diagnostic_variant eaddrinuse 127.0.0.1 3982)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  local out
  out="$(cat "$stdout_file")"
  smoke_assert_contains "$out" "127.0.0.1:3982" "T3 HOST:PORT"
  smoke_assert_contains "$out" "EADDRINUSE" "T3 EADDRINUSE token"
  smoke_assert_contains "$out" "TEAMS_WEBHOOK_PORT" "T3 env var name"
  smoke_assert_contains "$out" "another process" "T3 'another process' phrase"
  smoke_assert_contains "$out" "holds this port" "T3 'holds this port' phrase"
  smoke_log "T3 PASS"
}

# ---------------------------------------------------------------------
# T4: generic-error fallback shape (non-EADDRINUSE keeps the terse line).
# ---------------------------------------------------------------------
test_t4_generic_fallback_shape() {
  smoke_log "T4: --variant generic emits the terse 'http listen failed' line, NOT the EADDRINUSE diagnostic"
  local files stdout_file
  files="$(run_diagnostic_variant generic 127.0.0.1 3982)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  local out
  out="$(cat "$stdout_file")"
  smoke_assert_contains "$out" "http listen failed on 127.0.0.1:3982" "T4 terse line"
  # The generic branch must NOT leak the EADDRINUSE-specific phrasing.
  smoke_assert_not_contains "$out" "another process" "T4 no EADDRINUSE phrase on generic error"
  smoke_assert_not_contains "$out" "TEAMS_WEBHOOK_PORT" "T4 no env var name on generic error"
  smoke_log "T4 PASS"
}

# ---------------------------------------------------------------------
# T5: REAL listener path + NEGATIVE reap-proof — an unrelated decoy
# listener holding the port is NOT killed; server.ts emits the diagnostic
# and exits non-zero.
# ---------------------------------------------------------------------
test_t5_real_listener_decoy_survives() {
  smoke_log "T5: decoy holds the port → server.ts EADDRINUSE diagnostic + exit≠0; decoy STILL ALIVE (no reap)"
  # Pick a free loopback port: bind+release with node to discover an
  # ephemeral port, then immediately reuse it for the decoy. There is a
  # tiny TOCTOU window but the decoy reclaims it instantly; if the decoy
  # itself fails to bind we skip rather than false-fail.
  local decoy_js="$SMOKE_TMP_ROOT/decoy-listener.mjs"
  cat >"$decoy_js" <<'DECOY_EOF'
import { createServer } from 'http'
const port = Number(process.env.DECOY_PORT) // # noqa: iso-helper-boundary
const s = createServer((_req, res) => { res.writeHead(200); res.end('decoy') })
s.on('error', (e) => { process.stderr.write('decoy-error: ' + e + '\n'); process.exit(3) })
s.listen(port, '127.0.0.1', () => { process.stderr.write('decoy: listening\n') })
process.on('SIGTERM', () => process.exit(0))
DECOY_EOF
  # Discover a free port.
  local port
  port="$(node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>console.log(p))})' 2>/dev/null)"
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
    smoke_skip "T5 real-listener-decoy" "could not discover a free loopback port"
    return
  fi
  local decoy_stderr="$SMOKE_TMP_ROOT/decoy.stderr"
  DECOY_PORT="$port" node "$decoy_js" 2>"$decoy_stderr" &
  DECOY_PID=$!
  # Wait for the decoy to actually be listening (poll its stderr marker).
  local waited=0
  while ! grep -q 'decoy: listening' "$decoy_stderr" 2>/dev/null; do
    if ! kill -0 "$DECOY_PID" 2>/dev/null; then
      smoke_skip "T5 real-listener-decoy" "decoy listener failed to bind port $port"
      DECOY_PID=""
      return
    fi
    waited=$((waited + 1))
    if (( waited > 50 )); then
      smoke_skip "T5 real-listener-decoy" "decoy listener did not report listening within timeout"
      return
    fi
    sleep 0.1
  done

  local srv_stdout="$SMOKE_TMP_ROOT/srv.stdout"
  local srv_stderr="$SMOKE_TMP_ROOT/srv.stderr"
  local rc=0
  # Isolation (codex r1 [P2]): pin the Teams state + ms365 callback dirs under
  # the temp root so this FULL-server launch (which runs ensureStateDir,
  # chmod/read .env, and sweepOutboundConsents at module load before the
  # httpServer 'error' handler fires) never touches live
  # ~/.claude/channels/teams state. BRIDGE_HOME is already the temp dir.
  TEAMS_APP_ID=smoke TEAMS_APP_PASSWORD=smoke \
    TEAMS_STATE_DIR="$SMOKE_TMP_ROOT/teams-state-t5" \
    MS365_CALLBACK_SHARED_DIR="$SMOKE_TMP_ROOT/ms365-callbacks-t5" \
    TEAMS_WEBHOOK_HOST=127.0.0.1 TEAMS_WEBHOOK_PORT="$port" \
    bun "$TEAMS_SERVER" >"$srv_stdout" 2>"$srv_stderr" || rc=$?

  # (a) server.ts must have exited non-zero (EADDRINUSE → exit 1).
  if (( rc == 0 )); then
    smoke_fail "T5: server.ts exited 0 despite the port being held (expected non-zero EADDRINUSE exit). stderr: $(cat "$srv_stderr")"
  fi
  # (b) the EADDRINUSE diagnostic is on stderr.
  if ! grep -q 'EADDRINUSE: another process' "$srv_stderr"; then
    smoke_fail "T5: server.ts did not emit the EADDRINUSE diagnostic on the real listener path. stderr: $(cat "$srv_stderr")"
  fi
  grep -q "127.0.0.1:$port" "$srv_stderr" \
    || smoke_fail "T5: diagnostic missing the contested HOST:PORT 127.0.0.1:$port. stderr: $(cat "$srv_stderr")"
  # (c) NEGATIVE reap-proof: the decoy must still be alive — server.ts must
  # NOT have killed the unrelated port holder.
  if ! kill -0 "$DECOY_PID" 2>/dev/null; then
    smoke_fail "T5: the unrelated decoy listener was KILLED — server.ts must NOT reap an arbitrary port holder (diagnostic-only)."
  fi
  smoke_log "T5 PASS (decoy survived; diagnostic emitted; exit non-zero)"
  kill "$DECOY_PID" 2>/dev/null || true
  wait "$DECOY_PID" 2>/dev/null || true
  DECOY_PID=""
}

# ---------------------------------------------------------------------
# T6 (teeth): revert the EADDRINUSE branch to a terse line on a copy and
# verify the T1 content grep would trip.
# ---------------------------------------------------------------------
test_t6_teeth_revert_caught() {
  smoke_log "T6 (teeth): stripping the EADDRINUSE diagnostic content on a copy MUST trip the T1 grep"
  local copy="$SMOKE_TMP_ROOT/server-revert.ts"
  # Strip the lines that carry the EADDRINUSE diagnostic content tokens.
  sed -e "/code === 'EADDRINUSE'/d" \
      -e '/another process/d' \
      -e '/TEAMS_WEBHOOK_PORT/d' \
      "$TEAMS_SERVER" >"$copy"
  # Positive sanity: the live file has all three tokens.
  grep -q "code === 'EADDRINUSE'" "$TEAMS_SERVER" \
    || smoke_fail "T6 sanity: live server.ts missing EADDRINUSE code check"
  grep -q 'another process' "$TEAMS_SERVER" \
    || smoke_fail "T6 sanity: live server.ts missing 'another process' phrase"
  grep -q 'TEAMS_WEBHOOK_PORT' "$TEAMS_SERVER" \
    || smoke_fail "T6 sanity: live server.ts missing TEAMS_WEBHOOK_PORT mention"
  # Teeth: the stripped copy must have none of them.
  if grep -q "code === 'EADDRINUSE'" "$copy"; then
    smoke_fail "T6: teeth strip incomplete — copy still has EADDRINUSE code check"
  fi
  if grep -q 'another process' "$copy"; then
    smoke_fail "T6: teeth strip incomplete — copy still has 'another process' phrase"
  fi
  if grep -q 'TEAMS_WEBHOOK_PORT' "$copy"; then
    smoke_fail "T6: teeth strip incomplete — copy still names TEAMS_WEBHOOK_PORT"
  fi
  smoke_log "T6 PASS (teeth detector tripped on stripped copy)"
}

# ---------------------------------------------------------------------
# T7: ci-select-smoke.sh maps plugins/teams/server.ts to this smoke and
# lists it in add_all_required_static.
# ---------------------------------------------------------------------
test_t7_ci_select_registration() {
  smoke_log "T7: ci-select-smoke.sh registers '$SMOKE_NAME' under the plugins/teams/server.ts arm + add_all_required_static"
  grep -q "$SMOKE_NAME" "$CI_SELECT" \
    || smoke_fail "T7: ci-select-smoke.sh does not reference '$SMOKE_NAME'"
  # Reachable from the plugins/teams/server.ts case arm (combined ms365+teams arm).
  local arm_start arm_end
  arm_start="$(grep -nE '^\s*plugins/ms365/server\.ts\|plugins/teams/server\.ts' "$CI_SELECT" \
    | head -n 1 | cut -d: -f1)"
  if [[ -z "$arm_start" ]]; then
    smoke_fail "T7: could not find the plugins/ms365/server.ts|plugins/teams/server.ts case arm in ci-select-smoke.sh"
  fi
  arm_end="$(awk -v start="$arm_start" 'NR>=start && /;;/ {print NR; exit}' "$CI_SELECT")"
  if [[ -z "$arm_end" ]]; then
    smoke_fail "T7: could not delimit the teams/server.ts case arm (no ';;' after line $arm_start)"
  fi
  local arm_block
  arm_block="$(sed -n "${arm_start},${arm_end}p" "$CI_SELECT")"
  # Pure-bash membership ([[ == *..* ]]) — NOT `printf | grep -q`: under
  # `set -o pipefail`, grep -q exits on first match and closes the pipe while
  # printf is mid-write, so printf takes SIGPIPE and pipefail propagates that
  # failure, flipping `if !` into a false negative as the block grows (the
  # SIGPIPE-under-pipefail smoke-seam class).
  if [[ "$arm_block" != *"$SMOKE_NAME"* ]]; then
    smoke_fail "T7: '$SMOKE_NAME' not registered under the teams/server.ts arm at lines $arm_start-$arm_end"
  fi
  # add_all_required_static membership.
  local req_static_start req_static_end req_block
  req_static_start="$(grep -nE '^add_all_required_static\(\) \{' "$CI_SELECT" | head -n 1 | cut -d: -f1)"
  if [[ -z "$req_static_start" ]]; then
    smoke_fail "T7: add_all_required_static() function not found"
  fi
  req_static_end="$(awk -v start="$req_static_start" 'NR>=start && /^\}/ {print NR; exit}' "$CI_SELECT")"
  if [[ -z "$req_static_end" ]]; then
    smoke_fail "T7: add_all_required_static() function unterminated"
  fi
  req_block="$(sed -n "${req_static_start},${req_static_end}p" "$CI_SELECT")"
  if [[ "$req_block" != *"$SMOKE_NAME"* ]]; then
    smoke_fail "T7: '$SMOKE_NAME' not in add_all_required_static() list"
  fi
  smoke_log "T7 PASS"
}

# ---------------------------------------------------------------------
# Test runner.
# ---------------------------------------------------------------------
smoke_run "T1 diagnostic-content-present" test_t1_diagnostic_content_present
smoke_run "T2 no-reap-in-bind-error-path" test_t2_no_reap_in_bind_error_path

if (( HAS_BUN )); then
  # plugins/teams/node_modules must be present for the bun invocation to
  # import @modelcontextprotocol/sdk + botbuilder. Install on demand exactly
  # as beta5-2-zeta-teams-mcp-dedup.sh does.
  if [[ ! -d "$TEAMS_DIR/node_modules" ]]; then
    smoke_log "ensuring plugins/teams/node_modules present"
    if ! ( cd "$TEAMS_DIR" && bun install --frozen-lockfile --no-summary >&2 ); then
      smoke_fail "bun install in plugins/teams failed"
    fi
  fi
  smoke_run "T3 eaddrinuse-diagnostic-shape" test_t3_eaddrinuse_diagnostic_shape
  smoke_run "T4 generic-fallback-shape" test_t4_generic_fallback_shape
  if (( HAS_NODE )); then
    smoke_run "T5 real-listener-decoy-survives" test_t5_real_listener_decoy_survives
  else
    smoke_skip "T5 real-listener-decoy-survives" "node not on PATH (needed for decoy listener)"
  fi
else
  smoke_skip "T3 eaddrinuse-diagnostic-shape" "bun not on PATH"
  smoke_skip "T4 generic-fallback-shape" "bun not on PATH"
  smoke_skip "T5 real-listener-decoy-survives" "bun not on PATH"
fi

smoke_run "T6 teeth-revert-caught" test_t6_teeth_revert_caught
smoke_run "T7 ci-select-registration" test_t7_ci_select_registration

smoke_log "1671-teams-eaddrinuse-diagnostic: ALL TESTS PASS"
exit 0
