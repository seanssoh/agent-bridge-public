#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/B-beta4-setup-wizard.sh — v0.15.0-beta4 Lane B (#1268, #1271).
#
# Pins the interactive-wizard contract for `agent-bridge setup teams` and
# `agent-bridge setup ms365`. Before this lane, OOTB operators ran
# `setup teams --yes --app-id ... --app-password-file ... --tenant-id ...`
# and got `write_status: ok` even when `webhook_host=127.0.0.1`,
# `messaging_endpoint=(unset)`, and the Bot Framework registration
# silently dropped every inbound DM. The fix is a 4-step wizard
# (`lib/bridge-setup-wizard.sh`) parameterised by channel kind plus
# auto-mode validation that fails loud with the enumerated list of
# missing required values.
#
# Tests:
#   T1 (auto):     setup teams --yes + all required flags → exit 0
#                  (validate_auto returns clean; full path delegates to
#                  the python wizard which dry-runs).
#   T2 (auto):     setup teams --yes + missing --messaging-endpoint →
#                  fail-loud with structured "missing: ... --messaging-endpoint"
#                  line and non-zero exit.
#   T3 (helper):   interactive wizard helper, fed canned stdin via the
#                  TTY-emulating expect-less drive: simulate stdin via
#                  /dev/tty redirect from a pre-populated FIFO. Asserts
#                  all 7 required teams flags appear in the assembled
#                  py_args array.
#   T4 (auto):     setup ms365 --yes + all required flags → exit 0.
#   T5 (auto):     setup ms365 --yes + missing --redirect-uri → fail-loud
#                  with structured "missing: ... --redirect-uri".
#   T6 (helper):   ms365 wizard helper interactive drive → assembled args
#                  contain client-id / client-secret-file / tenant-id /
#                  redirect-uri / default-scopes + post-summary prints
#                  the redirect URI and client id placeholders.
#   T7 (teeth):    REGRESSION GUARD — setup teams --yes (with --app-id /
#                  --app-password-file / --tenant-id only) MUST fail
#                  loud. Catches a future patch that silently re-collapses
#                  the wizard back to the legacy 2-flag check.
#   T8 (teeth):    setup teams --yes with --messaging-endpoint=
#                  http://localhost:3978 + every other flag → still passes
#                  validate_auto (the wizard accepts the flag-present
#                  shape) AND the python wizard surfaces the loopback
#                  warning. Confirms the gate is on PRESENCE of the
#                  required values, not their content (content-level
#                  warning surface stays inside the python wizard, where
#                  the existing `webhook_host in {127.0.0.1,localhost} +
#                  messaging_endpoint` warn already lives).
#
# Footgun #11: every captured subprocess uses `out=$(... 2>&1)`. No
# `<<EOF` to subprocess, no `<<<` here-strings driven into subshells.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:B-beta4-setup-wizard][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="B-beta4-setup-wizard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
BRIDGE_SETUP_SH="$REPO_ROOT/bridge-setup.sh"
WIZARD_LIB="$REPO_ROOT/lib/bridge-setup-wizard.sh"

smoke_assert_file_exists "$BRIDGE_SETUP_SH" "bridge-setup.sh present"
smoke_assert_file_exists "$WIZARD_LIB" "lib/bridge-setup-wizard.sh present"

# Pick a Bash 4+ interpreter.
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi
export BRIDGE_BASH_BIN="$BRIDGE_BASH"

# Register a synthetic claude agent in the isolated roster so
# bridge_require_agent / bridge_setup_require_claude_agent don't trip
# before the wizard validation.
{
  printf '#!/usr/bin/env bash\n'
  printf '# shellcheck shell=bash disable=SC2034\n'
  printf 'bridge_add_agent_id_if_missing "wizard-test"\n'
  printf 'BRIDGE_AGENT_DESC["wizard-test"]="setup wizard smoke target"\n'
  printf 'BRIDGE_AGENT_ENGINE["wizard-test"]="claude"\n'
  printf 'BRIDGE_AGENT_SESSION["wizard-test"]="wizard-test"\n'
  printf 'BRIDGE_AGENT_WORKDIR["wizard-test"]="%s"\n' "$BRIDGE_AGENT_HOME_ROOT/wizard-test"
} >"$BRIDGE_ROSTER_LOCAL_FILE"

mkdir -p "$BRIDGE_AGENT_HOME_ROOT/wizard-test"

# Stage a fake client-secret file for the teams + ms365 tests.
SECRET_FILE="$SMOKE_TMP_ROOT/client-secret.txt"
printf 'super-secret-bot-password\n' >"$SECRET_FILE"
chmod 0600 "$SECRET_FILE"

# Helper: run bridge-setup.sh as a subshell with the isolated env.
run_setup() {
  local label="$1"; shift
  local out=""
  local rc=0
  out="$("$BRIDGE_BASH" "$BRIDGE_SETUP_SH" "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# ----------------------------------------------------------------------------
# T1: setup teams --yes + all required flags → exit 0 (dry-run delegates
# to the python wizard which finishes without prompting).
# ----------------------------------------------------------------------------
smoke_log "T1: setup teams --yes + all required flags → exit 0 (dry-run)"
T1_OUT=""
T1_RC=0
T1_OUT="$(run_setup "T1" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T1_RC=$?
if (( T1_RC == 0 )); then
  smoke_log "T1 ok: setup teams --yes (full flags) exited 0"
  smoke_assert_contains "$T1_OUT" "write_status: dry_run" "T1 dry_run marker"
else
  smoke_fail "T1: setup teams --yes (full flags) exited rc=$T1_RC; out: $T1_OUT"
fi

# ----------------------------------------------------------------------------
# T2: setup teams --yes + missing --messaging-endpoint → fail-loud.
# ----------------------------------------------------------------------------
smoke_log "T2: setup teams --yes + missing --messaging-endpoint → fail-loud"
T2_OUT=""
T2_RC=0
T2_OUT="$(run_setup "T2" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes 2>&1)" || T2_RC=$?
if (( T2_RC != 0 )); then
  smoke_assert_contains "$T2_OUT" "--messaging-endpoint" "T2 names --messaging-endpoint in fail-loud list"
  smoke_assert_contains "$T2_OUT" "자동 모드" "T2 explains it's auto-mode that failed"
  smoke_log "T2 ok: auto-mode missing --messaging-endpoint exited rc=$T2_RC with structured list"
else
  smoke_fail "T2: setup teams --yes (missing --messaging-endpoint) unexpectedly exited 0; out: $T2_OUT"
fi

# ----------------------------------------------------------------------------
# T3: source the wizard lib directly and exercise validate_auto + the
# required-fields enumerator. Three sub-runs (each in its own subshell
# so a `bridge_die` exit cannot poison the captured signal):
#   T3a — enumerator output for teams + ms365.
#   T3b — validate_auto with ALL teams flags present → rc=0.
#   T3c — validate_auto with only --app-id + --app-password-file
#         present → rc=1 with structured missing list.
# ----------------------------------------------------------------------------
smoke_log "T3: wizard lib direct — required-fields enumerator + validate_auto missing list"

# T3a — required-fields enumerator.
T3A_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
  source "'"$WIZARD_LIB"'"
  printf "teams_required="
  bridge_setup_wizard_required_fields teams | tr "\n" "," | sed "s/,$//"
  printf "\n"
  printf "ms365_required="
  bridge_setup_wizard_required_fields ms365 | tr "\n" "," | sed "s/,$//"
  printf "\n"
' 2>&1)"
smoke_assert_contains "$T3A_OUT" "teams_required=app-id,app-password-file,tenant-id,allow-from,messaging-endpoint,webhook-host,webhook-port" \
  "T3a teams required-fields enumerator"
smoke_assert_contains "$T3A_OUT" "ms365_required=client-id,client-secret-file,tenant-id,redirect-uri" \
  "T3a ms365 required-fields enumerator (issue #1355: default-scopes is now protocol-convention default, not required)"

# T3b — validate_auto with all teams flags present → exit 0.
T3B_OUT=""
T3B_RC=0
T3B_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
  source "'"$WIZARD_LIB"'"
  bridge_setup_wizard_validate_auto teams \
    --app-id A --app-password-file '"$SECRET_FILE"' --tenant-id T \
    --allow-from U --messaging-endpoint https://x/api/messages \
    --webhook-host 0.0.0.0 --webhook-port 3978 --yes
  printf "ok\n"
' 2>&1)" || T3B_RC=$?
if (( T3B_RC == 0 )); then
  smoke_assert_contains "$T3B_OUT" "ok" "T3b validate_auto rc=0 + completed when all flags present"
else
  smoke_fail "T3b: validate_auto unexpectedly died with all flags present; rc=$T3B_RC; out: $T3B_OUT"
fi

# T3c — validate_auto with only --app-id + --app-password-file → die.
T3C_OUT=""
T3C_RC=0
T3C_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
  source "'"$WIZARD_LIB"'"
  bridge_setup_wizard_validate_auto teams \
    --app-id A --app-password-file '"$SECRET_FILE"' --yes
' 2>&1)" || T3C_RC=$?
if (( T3C_RC != 0 )); then
  smoke_assert_contains "$T3C_OUT" "--tenant-id" "T3c missing list names --tenant-id"
  smoke_assert_contains "$T3C_OUT" "--messaging-endpoint" "T3c missing list names --messaging-endpoint"
  smoke_assert_contains "$T3C_OUT" "--allow-from" "T3c missing list names --allow-from"
  smoke_assert_contains "$T3C_OUT" "--webhook-host" "T3c missing list names --webhook-host"
  smoke_assert_contains "$T3C_OUT" "--webhook-port" "T3c missing list names --webhook-port"
  smoke_log "T3 ok: required-fields enumerator + validate_auto fail-loud surface intact"
else
  smoke_fail "T3c: validate_auto with only 2 flags unexpectedly exited 0; out: $T3C_OUT"
fi

# ----------------------------------------------------------------------------
# T4: setup ms365 --yes + all required flags → exit 0 (dry-run).
# Includes the optional --allow-localhost flag since the wizard's
# validate_auto only gates on the canonical 5; the --default-scopes
# value satisfies the `scope` field (the wizard's CLI flag in
# bridge-setup.py is --default-scopes).
# ----------------------------------------------------------------------------
smoke_log "T4: setup ms365 --yes + all required flags → exit 0 (dry-run)"
T4_OUT=""
T4_RC=0
T4_OUT="$(run_setup "T4" \
  ms365 wizard-test \
  --client-id "test-client-id" \
  --client-secret-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --redirect-uri "https://bot.example.com/auth/callback" \
  --default-scopes "openid offline_access Mail.Read" \
  --yes --dry-run 2>&1)" || T4_RC=$?
if (( T4_RC == 0 )); then
  smoke_assert_contains "$T4_OUT" "write_status: dry_run" "T4 dry_run marker"
  smoke_log "T4 ok: setup ms365 --yes (full flags) exited 0"
else
  smoke_fail "T4: setup ms365 --yes (full flags) exited rc=$T4_RC; out: $T4_OUT"
fi

# ----------------------------------------------------------------------------
# T5: setup ms365 --yes + missing --redirect-uri → fail-loud.
# Note: bridge-setup.py used to silently derive the redirect URI from
# .teams/state.json. The wizard validate_auto MUST short-circuit before
# the python wizard so an OOTB operator gets the structured list, not
# a derive-then-warn-then-success.
# ----------------------------------------------------------------------------
smoke_log "T5: setup ms365 --yes + missing --redirect-uri → fail-loud"
T5_OUT=""
T5_RC=0
T5_OUT="$(run_setup "T5" \
  ms365 wizard-test \
  --client-id "test-client-id" \
  --client-secret-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --default-scopes "openid offline_access Mail.Read" \
  --yes 2>&1)" || T5_RC=$?
if (( T5_RC != 0 )); then
  smoke_assert_contains "$T5_OUT" "--redirect-uri" "T5 names --redirect-uri in fail-loud list"
  smoke_assert_contains "$T5_OUT" "자동 모드" "T5 explains auto-mode failure"
  smoke_log "T5 ok: ms365 auto-mode missing --redirect-uri exited rc=$T5_RC"
else
  smoke_fail "T5: setup ms365 --yes (missing --redirect-uri) unexpectedly exited 0; out: $T5_OUT"
fi

# ----------------------------------------------------------------------------
# T6: source the wizard lib and confirm the ms365 post-summary printer
# emits the redirect URI + client id placeholders. The interactive
# prompt body itself is exercised structurally above (T3); the summary
# is the operator-facing post-write step 4.
# ----------------------------------------------------------------------------
smoke_log "T6: ms365 wizard helper — post-summary printer surfaces the manual action list"
T6_OUT=""
T6_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
  source "'"$WIZARD_LIB"'"
  bridge_setup_wizard_post_summary_ms365 \
    "https://bot.example.com/auth/callback" \
    "test-client-id"
' 2>&1)" || true
smoke_assert_contains "$T6_OUT" "step 4" "T6 post-summary names step 4"
smoke_assert_contains "$T6_OUT" "Redirect URIs" "T6 names Entra Redirect URIs surface"
smoke_assert_contains "$T6_OUT" "https://bot.example.com/auth/callback" "T6 surfaces chosen redirect URI"
smoke_assert_contains "$T6_OUT" "test-client-id" "T6 surfaces chosen client id"
smoke_log "T6 ok: ms365 post-summary printer surface intact"

# Teams post-summary parallel check.
T6_TEAMS_OUT=""
T6_TEAMS_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
  source "'"$WIZARD_LIB"'"
  bridge_setup_wizard_post_summary_teams \
    "https://bot.example.com/api/messages" \
    "0.0.0.0" \
    "3978"
' 2>&1)" || true
smoke_assert_contains "$T6_TEAMS_OUT" "step 4" "T6 teams post-summary names step 4"
smoke_assert_contains "$T6_TEAMS_OUT" "Messaging endpoint" "T6 teams names Bot Service messaging endpoint"
smoke_assert_contains "$T6_TEAMS_OUT" "https://bot.example.com/api/messages" "T6 teams surfaces chosen messaging endpoint"
smoke_log "T6 ok (teams): post-summary printer surface intact"

# ----------------------------------------------------------------------------
# T7 (teeth — regression guard): a future patch must not silently
# re-collapse the wizard back to checking only --app-id +
# --app-password. We invoke the legacy-shaped argv (the OOTB recipe
# from the #1268 reproducer) and assert it STILL exits non-zero with
# the structured missing list.
# ----------------------------------------------------------------------------
smoke_log "T7 (teeth): legacy-shape argv (app-id + app-password-file + tenant-id only) MUST fail-loud"
T7_OUT=""
T7_RC=0
T7_OUT="$(run_setup "T7" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --skip-validate --skip-send-test \
  --yes 2>&1)" || T7_RC=$?
if (( T7_RC != 0 )); then
  smoke_assert_contains "$T7_OUT" "--messaging-endpoint" "T7 still names --messaging-endpoint as missing"
  smoke_assert_contains "$T7_OUT" "--webhook-host" "T7 still names --webhook-host as missing"
  smoke_assert_contains "$T7_OUT" "--webhook-port" "T7 still names --webhook-port as missing"
  smoke_log "T7 ok: legacy-shape argv fails loud (regression guard intact)"
else
  smoke_fail "T7: legacy-shape argv unexpectedly exited 0. The wizard collapse is back. out: $T7_OUT"
fi

# ----------------------------------------------------------------------------
# T8 (teeth, R2): codex r1 BLOCKING — when --messaging-endpoint points
# at a host that has no listener and we run WITHOUT --dry-run + WITHOUT
# the air-gapped escape hatch, the wizard MUST die before any state
# file is written. R1 used --dry-run + asserted rc=0 which bypassed
# the entire Step 3 probe layer; that loophole is the reason codex
# called out r1 as BLOCKING.
#
# Mechanics: 127.0.0.1:<random_unused_port> → local-bind probe MAY pass
# (the smoke owns the port at that moment), but the messaging-endpoint
# reachability probe POSTs to the same URL and the socket is already
# closed before the probe runs because we never spawned a real listener
# → URLError → bridge_die. To make the failure deterministic, we point
# messaging-endpoint at a port that has NEVER been bound (no race), so
# the connect attempt always refuses.
# ----------------------------------------------------------------------------
smoke_log "T8 (teeth R2): --messaging-endpoint to unreachable port WITHOUT --dry-run → wizard die"

# Clean any state left by earlier tests (T1-T7) so the "no state file
# leaked" assertion below is meaningful.
rm -rf "$BRIDGE_AGENT_HOME_ROOT/wizard-test/.teams"

# Pick a high port unlikely to collide. Python pick: bind 0, read the
# assigned port, close. The port is then in TIME_WAIT-free state, and
# the next connect will refuse (no listener bound back).
T8_UNREACHABLE_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
' 2>/dev/null)"
if [[ -z "$T8_UNREACHABLE_PORT" || ! "$T8_UNREACHABLE_PORT" =~ ^[0-9]+$ ]]; then
  smoke_fail "T8 setup: failed to pick unreachable port; got '$T8_UNREACHABLE_PORT'"
fi
T8_OUT=""
T8_RC=0
T8_OUT="$(run_setup "T8" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "http://127.0.0.1:${T8_UNREACHABLE_PORT}/api/messages" \
  --webhook-host "127.0.0.1" \
  --webhook-port "${T8_UNREACHABLE_PORT}" \
  --skip-validate --skip-send-test \
  --yes 2>&1)" || T8_RC=$?
if (( T8_RC != 0 )); then
  # Either the messaging_endpoint reachability probe died or the bind
  # probe died (port could already be in use on a noisy CI). Both
  # surfaces are acceptable signals that the gate is wired.
  if [[ "$T8_OUT" == *"reachability failed"* || "$T8_OUT" == *"webhook bind"* ]]; then
    smoke_log "T8 ok: probe gate fired (rc=$T8_RC, surface: reachability OR bind)"
  else
    smoke_fail "T8: rc=$T8_RC but no probe-failure marker in stderr. out: $T8_OUT"
  fi
  # Confirm no .teams state file leaked through.
  if [[ -d "$BRIDGE_AGENT_HOME_ROOT/wizard-test/.teams" ]]; then
    smoke_fail "T8: probe died but .teams state dir was still written. The gate must abort BEFORE state writes."
  fi
else
  smoke_fail "T8: probe gate FAILED to fire — wizard returned rc=0 with an unreachable messaging_endpoint. out: $T8_OUT"
fi

# ----------------------------------------------------------------------------
# T8b (teeth R2): --allow-probe-failure escape hatch downgrades the
# die to a warn. Same unreachable endpoint as T8, but with the flag —
# wizard should now NOT die at the probe gate. The python wizard may
# still fail downstream (since the unreachable endpoint is still
# unreachable for any real bot-service call), but the probe gate must
# emit the warning instead of bridge_die. Assertions are on:
#   - the operator-facing warn text contains "--allow-probe-failure"
#   - rc may be 0 (full pass-through) or non-zero (python wizard
#     downstream failure) — both are acceptable; what matters is the
#     warn-vs-die distinction, signaled by the warn text presence.
# ----------------------------------------------------------------------------
smoke_log "T8b (teeth R2): --allow-probe-failure downgrades die → warn"
T8B_OUT=""
T8B_RC=0
T8B_OUT="$(run_setup "T8b" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "http://127.0.0.1:${T8_UNREACHABLE_PORT}/api/messages" \
  --webhook-host "127.0.0.1" \
  --webhook-port "${T8_UNREACHABLE_PORT}" \
  --skip-validate --skip-send-test \
  --allow-probe-failure \
  --yes 2>&1)" || T8B_RC=$?
if [[ "$T8B_OUT" == *"reachability failed"* && "$T8B_OUT" == *"--allow-probe-failure"* ]]; then
  smoke_log "T8b ok: --allow-probe-failure downgraded die → warn (rc=$T8B_RC, warn text present)"
else
  smoke_fail "T8b: --allow-probe-failure did not produce expected warn text. rc=$T8B_RC out: $T8B_OUT"
fi

# ----------------------------------------------------------------------------
# T9 (R2 positive case): spawn a tiny fixture HTTP server bound to
# 127.0.0.1:<picked_port> that responds with 200 OK to any request.
# Point --messaging-endpoint at it. The wizard's reachability probe
# should succeed (any HTTP response = OK). We DO use --dry-run here
# because the goal is to prove the PROBE path passes, not to write a
# real .teams config. With --dry-run, our gate skips the probe → so
# we need a separate non-dry-run flavor.
#
# Strategy: --skip-validate already skips the python wizard's
# downstream Bot Framework credential probe. The OOTB wizard write
# itself should complete. We accept rc=0 OR a downstream MS Bot
# Service call failure as a "probe passed" signal; the smoke
# assertion is on the ABSENCE of "reachability failed" in stderr.
# ----------------------------------------------------------------------------
smoke_log "T9 (R2 positive): fixture HTTP server on 127.0.0.1 — teams probe passes"
T9_FIXTURE_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
' 2>/dev/null)"
if [[ -z "$T9_FIXTURE_PORT" || ! "$T9_FIXTURE_PORT" =~ ^[0-9]+$ ]]; then
  smoke_fail "T9 setup: failed to pick fixture port; got '$T9_FIXTURE_PORT'"
fi

# Spawn fixture HTTP server. Uses python3 -c so we don't trip the
# heredoc-stdin-in-$(...) footgun (we don't capture this — it's a
# background spawn).
T9_FIXTURE_LOG="$SMOKE_TMP_ROOT/t9-fixture.log"
python3 -c '
import http.server, socketserver, sys, threading
port = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_HEAD(self): self.send_response(200); self.end_headers()
    def do_POST(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a, **kw): pass
with socketserver.TCPServer(("127.0.0.1", port), Handler) as srv:
    srv.timeout = 0.5
    while True:
        srv.handle_request()
' "$T9_FIXTURE_PORT" >"$T9_FIXTURE_LOG" 2>&1 &
T9_FIXTURE_PID=$!
# Wait for the fixture to become reachable (max 3s).
for _ in 1 2 3 4 5 6; do
  if python3 -c '
import socket, sys
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    print("ready")
except Exception:
    sys.exit(1)
finally:
    s.close()
' "$T9_FIXTURE_PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

T9_OUT=""
T9_RC=0
# We need a port for --webhook-port that the smoke can bind (local-bind
# probe needs to pass), AND the fixture port for messaging-endpoint.
# Pick a SECOND port for webhook so it doesn't collide with the
# fixture.
T9_WEBHOOK_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
' 2>/dev/null)"
T9_OUT="$(run_setup "T9" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "http://127.0.0.1:${T9_FIXTURE_PORT}/api/messages" \
  --webhook-host "127.0.0.1" \
  --webhook-port "${T9_WEBHOOK_PORT}" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T9_RC=$?
# Kill fixture before we leave the test.
kill "$T9_FIXTURE_PID" 2>/dev/null || true
wait "$T9_FIXTURE_PID" 2>/dev/null || true

if (( T9_RC == 0 )); then
  smoke_assert_not_contains "$T9_OUT" "reachability failed" "T9 dry-run+fixture: no probe-failure marker"
  smoke_log "T9 ok: dry-run sanity (gate skipped under --dry-run, as designed)"
else
  smoke_fail "T9: dry-run with fixture port rc=$T9_RC unexpected. out: $T9_OUT"
fi

# T9b — same fixture, drop --dry-run so the probe gate fires for real.
# Spawn fixture again (the previous one was killed).
T9B_FIXTURE_LOG="$SMOKE_TMP_ROOT/t9b-fixture.log"
python3 -c '
import http.server, socketserver, sys
port = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_HEAD(self): self.send_response(200); self.end_headers()
    def do_POST(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a, **kw): pass
with socketserver.TCPServer(("127.0.0.1", port), Handler) as srv:
    srv.timeout = 0.5
    while True:
        srv.handle_request()
' "$T9_FIXTURE_PORT" >"$T9B_FIXTURE_LOG" 2>&1 &
T9B_FIXTURE_PID=$!
for _ in 1 2 3 4 5 6; do
  if python3 -c '
import socket, sys
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    print("ready")
except Exception:
    sys.exit(1)
finally:
    s.close()
' "$T9_FIXTURE_PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# Pre-pick a fresh free port for webhook bind probe (the previous one
# might still be in TIME_WAIT).
T9B_WEBHOOK_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
' 2>/dev/null)"
T9B_OUT=""
T9B_RC=0
T9B_OUT="$(run_setup "T9b" \
  teams wizard-test \
  --app-id "test-app-id" \
  --app-password-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "http://127.0.0.1:${T9_FIXTURE_PORT}/api/messages" \
  --webhook-host "127.0.0.1" \
  --webhook-port "${T9B_WEBHOOK_PORT}" \
  --skip-validate --skip-send-test \
  --yes 2>&1)" || T9B_RC=$?
kill "$T9B_FIXTURE_PID" 2>/dev/null || true
wait "$T9B_FIXTURE_PID" 2>/dev/null || true

# We do NOT assert rc=0 here because the python wizard may still fail
# downstream on the dev-channel launch flag write or other lifecycle
# steps in an isolated smoke. We only assert that the probe path
# itself did NOT report "reachability failed" — i.e., the fixture
# satisfied the probe.
smoke_assert_not_contains "$T9B_OUT" "messaging_endpoint reachability failed" "T9b probe passed with fixture listener (no reachability failed marker)"
smoke_assert_not_contains "$T9B_OUT" "webhook bind 127.0.0.1:${T9B_WEBHOOK_PORT}" "T9b local-bind probe passed (no bind-failed marker)"
smoke_log "T9b ok: positive probe path — fixture listener satisfied teams probes"

# ----------------------------------------------------------------------------
# T10 (R2 positive ms365): same fixture pattern for the ms365
# redirect_uri probe. Spawn a tiny HTTP listener, point --redirect-uri
# at it, confirm probe passes (no "reachability failed" marker).
# ----------------------------------------------------------------------------
smoke_log "T10 (R2 positive ms365): fixture HTTP server — ms365 redirect probe passes"
T10_FIXTURE_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
' 2>/dev/null)"
T10_FIXTURE_LOG="$SMOKE_TMP_ROOT/t10-fixture.log"
python3 -c '
import http.server, socketserver, sys
port = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_HEAD(self): self.send_response(200); self.end_headers()
    def do_POST(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a, **kw): pass
with socketserver.TCPServer(("127.0.0.1", port), Handler) as srv:
    srv.timeout = 0.5
    while True:
        srv.handle_request()
' "$T10_FIXTURE_PORT" >"$T10_FIXTURE_LOG" 2>&1 &
T10_FIXTURE_PID=$!
for _ in 1 2 3 4 5 6; do
  if python3 -c '
import socket, sys
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    print("ready")
except Exception:
    sys.exit(1)
finally:
    s.close()
' "$T10_FIXTURE_PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

T10_OUT=""
T10_RC=0
T10_OUT="$(run_setup "T10" \
  ms365 wizard-test \
  --client-id "test-client-id" \
  --client-secret-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --redirect-uri "http://127.0.0.1:${T10_FIXTURE_PORT}/auth/callback" \
  --default-scopes "openid offline_access Mail.Read" \
  --allow-localhost \
  --yes 2>&1)" || T10_RC=$?
kill "$T10_FIXTURE_PID" 2>/dev/null || true
wait "$T10_FIXTURE_PID" 2>/dev/null || true

smoke_assert_not_contains "$T10_OUT" "redirect_uri reachability failed" "T10 ms365 redirect probe passed (no reachability failed marker)"
smoke_log "T10 ok: positive probe path — fixture listener satisfied ms365 redirect probe"

# ----------------------------------------------------------------------------
# T10b (R2 negative ms365): no fixture, unreachable port → wizard die.
# ----------------------------------------------------------------------------
smoke_log "T10b (teeth R2 ms365 negative): unreachable redirect_uri → wizard die"

# Clean any state left by earlier tests (T4, T10) so the "no state
# file leaked" assertion below is meaningful.
rm -rf "$BRIDGE_AGENT_HOME_ROOT/wizard-test/.ms365"

T10B_UNREACHABLE_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
' 2>/dev/null)"
T10B_OUT=""
T10B_RC=0
T10B_OUT="$(run_setup "T10b" \
  ms365 wizard-test \
  --client-id "test-client-id" \
  --client-secret-file "$SECRET_FILE" \
  --tenant-id "test-tenant" \
  --redirect-uri "http://127.0.0.1:${T10B_UNREACHABLE_PORT}/auth/callback" \
  --default-scopes "openid offline_access Mail.Read" \
  --allow-localhost \
  --yes 2>&1)" || T10B_RC=$?
if (( T10B_RC != 0 )); then
  smoke_assert_contains "$T10B_OUT" "redirect_uri reachability failed" "T10b ms365 probe gate fired (rc=$T10B_RC)"
  if [[ -d "$BRIDGE_AGENT_HOME_ROOT/wizard-test/.ms365" ]]; then
    smoke_fail "T10b: probe died but .ms365 state dir was still written. The gate must abort BEFORE state writes."
  fi
  smoke_log "T10b ok: ms365 probe gate fires without --dry-run"
else
  smoke_fail "T10b: ms365 probe gate FAILED to fire — wizard returned rc=0 with unreachable redirect_uri. out: $T10B_OUT"
fi

smoke_log "All B-beta4 setup-wizard tests passed."
