#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-zeta-teams-mcp-dedup.sh —
# v0.15.0-beta5-2 Lane ζ (#1313) — Teams MCP notification failure must
# NOT remove the dedup entry; bounded retry-with-backoff + structured
# audit on permanent failure replace the prior dedup-forget + re-throw
# pattern that caused silent message loss.
#
# Re-exec under bash 4+ so we can use modern array / string features
# (matches scripts/smoke/Beta-beta5-session-id-detect-sudo.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:beta5-2-zeta-teams-mcp-dedup][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Background — Issue #1313 (patch comprehensive audit 2026-05-28, C7,
# severity CRITICAL data-loss):
#
#   plugins/teams/server.ts handleActivity() catch block did:
#
#     try {
#       await mcp.notification({...})
#     } catch (err) {
#       process.stderr.write(`teams channel: failed ... ${err}\n`)
#       recentMessageIds.forget(dedupeKey(chatId, messageId, revision))
#       throw err
#     }
#
#   The intent was "let Teams retry the webhook so we can re-deliver".
#   The side effect: dedup state for the in-flight activity was dropped
#   and the throw caused the adapter to emit 500, which makes Teams Bot
#   Framework retry the same activity. The retry then passed the (now
#   empty) in-memory dedup check, hit MCP again, and (if MCP was still
#   degraded) repeated — with Claude never receiving the original
#   message AND no record that the activity ever arrived.
#
# Fix (Option 1 — internal retry, dedup-preserving):
#
#   deliverMcpNotificationWithRetry() — bounded retry-with-exponential-
#   backoff helper. Tries the notification up to 3 attempts (default)
#   with backoff base 100ms doubling each attempt (100 / 200ms waits
#   between 3 attempts).
#
#   emitMcpDeliveryFailurePermanent() — structured stderr audit row
#   (token `teams_mcp_notification_failed_permanent`) when all retries
#   exhaust, for operator log-scraper → admin escalation.
#
#   Catch-block rewired: dedup entry is preserved on every outcome (no
#   more `recentMessageIds.forget(...)`). On permanent failure we
#   swallow the error (no throw) — returning 2xx to Teams stops Bot
#   Framework from re-driving the same activity webhook against a
#   degraded MCP transport.
#
# Test plan:
#
#   T1 — Static-source: `recentMessageIds.forget(dedupeKey(` is NOT
#        present anywhere in plugins/teams/server.ts. Asserts the
#        symptom-cover line is gone.
#
#   T2 — Static-source: the helpers `deliverMcpNotificationWithRetry`
#        and `emitMcpDeliveryFailurePermanent` are defined and the
#        catch block calls both via `deliverResult.delivered === false`
#        branch. Pins the wiring so a refactor cannot silently regress.
#
#   T3 — Behavioural (succeed-first): inject a send() that resolves on
#        attempt 1. `delivered=true`, `attempts=1`, no sleep, no audit
#        row. Confirms the happy path is byte-identical to the prior
#        first-try success behaviour.
#
#   T4 — Behavioural (succeed-second / mid-retry recovery): inject a
#        send() that throws on attempt 1, resolves on attempt 2.
#        `delivered=true`, `attempts=2`, `sleepCount=1` (single 100ms
#        backoff between attempt 1 and 2). No audit row.
#
#   T5 — Behavioural (all-fail / perma-down): inject a send() that
#        throws on every attempt. `delivered=false`, `attempts=3`,
#        `sleepCount=2` (100ms + 200ms backoffs), and stderr contains
#        the structured `teams_mcp_notification_failed_permanent`
#        audit token with the message_id / chat_id / attempts fields.
#
#   T6 (teeth) — revert just the catch-block rewire (re-add the
#        `recentMessageIds.forget(...)` line) and confirm the static
#        grep in T1 trips. Asserts the smoke catches the regression
#        shape exactly. (We do not actually mutate server.ts in this
#        teeth check — instead we copy the file to a temp path, splice
#        in the forget-line, and re-run the T1 grep against the copy.
#        Reverting the live source would interfere with other smokes
#        running concurrently in CI.)
#
#   T7 (default 4-item brief checklist item 3 — data shape): the audit
#        row is a single line (no embedded newlines) and contains the
#        four key=value fields in stable order: message_id, chat_id,
#        attempts, last_error. Asserts via regex against the captured
#        stderr from T5.
#
#   T8 (ci-select 4-site registration): scripts/ci-select-smoke.sh
#        maps the four files involved in this fix to this smoke.
#        Asserts the entry is present so a future ci-select pass picks
#        up regression coverage automatically.
#
#   T9 (codex r1 BLOCKING follow-up — admin task creation): in the
#        all-fail variant with BRIDGE_ADMIN_AGENT_ID set, the smoke
#        installs a PATH-shimmed bridge-task.sh that records argv. The
#        smoke asserts: (1) the shim was invoked exactly once, (2) the
#        argv carries `create --to <admin> --title <prefix> --body <…>
#        --priority high`, (3) the body contains message_id / chat_id /
#        attempts / last_error, and (4) stderr carries the
#        `teams_mcp_perma_fail_admin_task_created` audit line. Closes
#        the codex r1 BLOCKING gap (issue #1336 R2): the durable
#        operator signal is a queue task, not just a stderr line.
#
#   T10 (edge case — admin unset): when BRIDGE_ADMIN_AGENT_ID is unset,
#        the function MUST fall back to a `admin_task_skipped
#        reason=no_admin_configured` stderr line WITHOUT crashing and
#        WITHOUT spawning bridge-task.sh. Bun harness exit is 0.
#
#   T11 (teeth — strip catches a revert): a static-source pass strips
#        `bridge-task.sh` / `resolveBridgeTaskPath` / the
#        `admin_task_created` audit token from a copy of server.ts and
#        confirms each token would trip a strict grep. Asserts the
#        positive sanity (live source carries all three tokens) and
#        the teeth (stripped copy has none).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; the bun
# invocation reuses plugins/teams/node_modules and exits before the
# httpServer.listen (the `_smoke-mcp-retry` subcommand short-circuits).
# No real Teams / MCP traffic.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses `printf`, `grep`, or direct `$()` substitution against
# a temp file — no `<<<` here-strings into bridge functions and no
# command substitution feeding a heredoc stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="beta5-2-zeta-teams-mcp-dedup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
TEAMS_SERVER="$REPO_ROOT/plugins/teams/server.ts"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
TEAMS_DIR="$REPO_ROOT/plugins/teams"

[[ -f "$TEAMS_SERVER" ]] || smoke_fail "missing $TEAMS_SERVER"
[[ -f "$CI_SELECT" ]] || smoke_fail "missing $CI_SELECT"

# Bun is required to exercise the behavioural smoke variants (T3-T7).
# Static-source tests (T1, T2, T8) run on every host.
HAS_BUN=0
if command -v bun >/dev/null 2>&1; then
  HAS_BUN=1
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# ---------------------------------------------------------------------
# T1: the symptom-cover line is gone from plugins/teams/server.ts.
# ---------------------------------------------------------------------
test_t1_no_forget_dedupe_line() {
  smoke_log "T1: plugins/teams/server.ts has NO 'recentMessageIds.forget(dedupeKey(' on a code line"
  # Allow the helper-block COMMENT to reference the removed line by
  # name (the comment explains what was removed and why). The actual
  # code line is `recentMessageIds.forget(dedupeKey(...))` with a
  # backtick-free pattern. We grep for the exact code form WITHOUT a
  # leading `// ` comment marker.
  local hits
  hits="$(grep -n 'recentMessageIds\.forget(dedupeKey(' "$TEAMS_SERVER" | grep -vE '^\s*[0-9]+:\s*//' || true)"
  # Filter further: comments may also start with `*` (block-comment
  # continuation lines) or `//` indented. The grep -vE above already
  # handles `^<n>:<spaces>//` — also strip backtick references which
  # appear inside helper-block JSDoc-style comments.
  hits="$(printf '%s\n' "$hits" | grep -v '`recentMessageIds\.forget' || true)"
  if [[ -n "$hits" ]]; then
    smoke_fail "T1: live code still calls recentMessageIds.forget(dedupeKey(...):\n$hits"
  fi
  smoke_log "T1 PASS"
}

# ---------------------------------------------------------------------
# T2: helpers + catch-block wiring are present.
# ---------------------------------------------------------------------
test_t2_helper_wiring() {
  smoke_log "T2: deliverMcpNotificationWithRetry + emitMcpDeliveryFailurePermanent defined; catch-block wires both"
  grep -nE '^export async function deliverMcpNotificationWithRetry\(' "$TEAMS_SERVER" >/dev/null \
    || smoke_fail "T2: deliverMcpNotificationWithRetry export not found"
  grep -nE '^export function emitMcpDeliveryFailurePermanent\(' "$TEAMS_SERVER" >/dev/null \
    || smoke_fail "T2: emitMcpDeliveryFailurePermanent export not found"
  # Wiring check: the handleActivity body calls the retry helper and
  # branches on `!deliverResult.delivered`.
  grep -nE 'deliverMcpNotificationWithRetry\(' "$TEAMS_SERVER" >/dev/null \
    || smoke_fail "T2: handleActivity does not call deliverMcpNotificationWithRetry"
  grep -nE 'if \(!deliverResult\.delivered\)' "$TEAMS_SERVER" >/dev/null \
    || smoke_fail "T2: handleActivity does not branch on !deliverResult.delivered"
  grep -nE 'emitMcpDeliveryFailurePermanent\(chatId, messageId,' "$TEAMS_SERVER" >/dev/null \
    || smoke_fail "T2: handleActivity does not invoke emitMcpDeliveryFailurePermanent(chatId, messageId, ...)"
  smoke_log "T2 PASS"
}

# ---------------------------------------------------------------------
# Helper: run _smoke-mcp-retry and return the JSON line on stdout +
# the captured stderr for audit-row grep. Output files land in the
# isolated SMOKE_TMP_ROOT.
# ---------------------------------------------------------------------
run_mcp_retry_variant() {
  local variant="$1"
  local stdout_file="$SMOKE_TMP_ROOT/mcp-retry.$variant.stdout"
  local stderr_file="$SMOKE_TMP_ROOT/mcp-retry.$variant.stderr"
  # bun reads TEAMS_APP_ID / TEAMS_APP_PASSWORD at module-load time (the
  # adapter is constructed at the top of server.ts). Pin smoke values so
  # the import side-effects don't trip on the missing-credentials check.
  TEAMS_APP_ID=smoke TEAMS_APP_PASSWORD=smoke \
    bun "$TEAMS_SERVER" _smoke-mcp-retry --variant "$variant" \
    --chat-id "chat-smoke" --message-id "message-smoke" \
    >"$stdout_file" 2>"$stderr_file"
  printf '%s\n' "$stdout_file" "$stderr_file"
}

# Variant for T9: install a fake `bridge-task.sh` shim under a private
# BRIDGE_HOME and invoke the smoke harness with BRIDGE_ADMIN_AGENT_ID
# set. The shim records the argv it was called with to a sentinel file
# the assertions read.
run_mcp_retry_variant_with_admin_task() {
  local variant="$1"; local admin_agent="$2"; local label="$3"
  local stdout_file="$SMOKE_TMP_ROOT/mcp-retry.$label.stdout"
  local stderr_file="$SMOKE_TMP_ROOT/mcp-retry.$label.stderr"
  local shim_home="$SMOKE_TMP_ROOT/$label.bridge-home"
  local shim_path="$shim_home/bridge-task.sh"
  local argv_file="$SMOKE_TMP_ROOT/$label.shim-argv"
  mkdir -p "$shim_home"
  # PATH-shim (per brief): write a bash script that captures argv +
  # exits 0 (success path). The shim emits a `task #<id>` line on
  # stdout so any downstream parser sees a realistic shape.
  cat >"$shim_path" <<'SHIM_EOF'
#!/usr/bin/env bash
# T9 shim — records argv so the smoke can assert the spawnSync call.
printf '%s\n' "$@" >"$BRIDGE_TASK_SHIM_ARGV_FILE"
printf 'task #99 created\n'
exit 0
SHIM_EOF
  chmod 0755 "$shim_path"
  TEAMS_APP_ID=smoke TEAMS_APP_PASSWORD=smoke \
    BRIDGE_HOME="$shim_home" \
    BRIDGE_ADMIN_AGENT_ID="$admin_agent" \
    BRIDGE_TASK_SHIM_ARGV_FILE="$argv_file" \
    bun "$TEAMS_SERVER" _smoke-mcp-retry --variant "$variant" \
    --chat-id "chat-smoke" --message-id "message-smoke" \
    >"$stdout_file" 2>"$stderr_file"
  printf '%s\n' "$stdout_file" "$stderr_file" "$argv_file" "$shim_path"
}

json_field() {
  local payload_file="$1" field="$2"
  python3 -c 'import json,sys
payload = open(sys.argv[1]).read().strip().splitlines()
if not payload:
    sys.exit("empty payload")
row = json.loads(payload[-1])
val = row.get(sys.argv[2])
if isinstance(val, bool):
    print("true" if val else "false")
elif val is None:
    print("")
else:
    print(val)' "$payload_file" "$field"
}

# ---------------------------------------------------------------------
# T3: succeed-first — happy path byte-identical to prior single-try.
# ---------------------------------------------------------------------
test_t3_succeed_first() {
  smoke_log "T3: succeed-first → delivered=true, attempts=1, no sleep, no audit row"
  local files stdout_file stderr_file
  files="$(run_mcp_retry_variant succeed-first)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  stderr_file="$(printf '%s\n' "$files" | sed -n 2p)"
  smoke_assert_eq "true" "$(json_field "$stdout_file" delivered)" "T3 delivered"
  smoke_assert_eq "1" "$(json_field "$stdout_file" attempts)" "T3 attempts"
  smoke_assert_eq "0" "$(json_field "$stdout_file" sleepCount)" "T3 sleepCount"
  # No audit row on success.
  if grep -q 'teams_mcp_notification_failed_permanent' "$stderr_file"; then
    smoke_fail "T3: audit row leaked on a successful first-attempt delivery"
  fi
  smoke_log "T3 PASS"
}

# ---------------------------------------------------------------------
# T4: succeed-second — MCP recovers mid-retry.
# ---------------------------------------------------------------------
test_t4_succeed_second() {
  smoke_log "T4: succeed-second → delivered=true, attempts=2, sleepCount=1 (100ms), no audit row"
  local files stdout_file stderr_file
  files="$(run_mcp_retry_variant succeed-second)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  stderr_file="$(printf '%s\n' "$files" | sed -n 2p)"
  smoke_assert_eq "true" "$(json_field "$stdout_file" delivered)" "T4 delivered"
  smoke_assert_eq "2" "$(json_field "$stdout_file" attempts)" "T4 attempts"
  smoke_assert_eq "1" "$(json_field "$stdout_file" sleepCount)" "T4 sleepCount"
  if grep -q 'teams_mcp_notification_failed_permanent' "$stderr_file"; then
    smoke_fail "T4: audit row leaked on a delivered-on-retry success"
  fi
  smoke_log "T4 PASS"
}

# ---------------------------------------------------------------------
# T5: all-fail — perma-down audit row + exponential backoff.
# ---------------------------------------------------------------------
test_t5_all_fail_audit_row() {
  smoke_log "T5: all-fail → delivered=false, attempts=3, sleepCount=2 (100/200ms), structured audit row on stderr"
  local files stdout_file stderr_file
  files="$(run_mcp_retry_variant all-fail)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  stderr_file="$(printf '%s\n' "$files" | sed -n 2p)"
  smoke_assert_eq "false" "$(json_field "$stdout_file" delivered)" "T5 delivered"
  smoke_assert_eq "3" "$(json_field "$stdout_file" attempts)" "T5 attempts"
  smoke_assert_eq "2" "$(json_field "$stdout_file" sleepCount)" "T5 sleepCount"
  smoke_assert_eq "3" "$(json_field "$stdout_file" errorsCount)" "T5 errorsCount"
  # Audit row token present.
  if ! grep -q 'teams_mcp_notification_failed_permanent' "$stderr_file"; then
    smoke_fail "T5: audit row 'teams_mcp_notification_failed_permanent' missing from stderr: $(cat "$stderr_file")"
  fi
  # Audit row contains message_id + chat_id + attempts fields.
  local audit_line
  audit_line="$(grep 'teams_mcp_notification_failed_permanent' "$stderr_file" | head -n 1)"
  smoke_assert_contains "$audit_line" "message_id=message-smoke" "T5 audit message_id"
  smoke_assert_contains "$audit_line" "chat_id=chat-smoke" "T5 audit chat_id"
  smoke_assert_contains "$audit_line" "attempts=3" "T5 audit attempts"
  smoke_log "T5 PASS"
}

# ---------------------------------------------------------------------
# T6 (teeth): re-introduce the forget-line into a copy and verify T1
# grep would trip. Confirms the regression detector is load-bearing.
# ---------------------------------------------------------------------
test_t6_teeth_revert_caught() {
  smoke_log "T6 (teeth): re-add 'recentMessageIds.forget(dedupeKey(...))' on a copy → T1 grep MUST trip"
  local copy="$SMOKE_TMP_ROOT/server-revert.ts"
  cp "$TEAMS_SERVER" "$copy"
  # Splice the forget line into the catch block as a CODE line (not a
  # comment). We append a new function with the forget pattern so the
  # grep matches a real code line.
  cat >>"$copy" <<'TYPESCRIPT_EOF'

// T6 teeth: this synthetic function re-introduces the symptom-cover
// pattern so the smoke can confirm the static-source grep would trip.
function _smokeT6Synthetic(chatId: string, messageId: string, revision: string): void {
  recentMessageIds.forget(dedupeKey(chatId, messageId, revision))
}
TYPESCRIPT_EOF
  local hits
  hits="$(grep -n 'recentMessageIds\.forget(dedupeKey(' "$copy" | grep -vE '^\s*[0-9]+:\s*//' \
    | grep -v '`recentMessageIds\.forget' || true)"
  if [[ -z "$hits" ]]; then
    smoke_fail "T6: teeth check failed — synthetic forget-line was not caught by the T1 grep shape"
  fi
  smoke_log "T6 PASS (teeth detector tripped as expected)"
}

# ---------------------------------------------------------------------
# T7: audit-row data-shape (default 4-item brief checklist item 3).
# ---------------------------------------------------------------------
test_t7_audit_row_shape() {
  smoke_log "T7: audit row is a single line + key=value field order is stable"
  local files stdout_file stderr_file
  files="$(run_mcp_retry_variant all-fail)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  stderr_file="$(printf '%s\n' "$files" | sed -n 2p)"
  local audit_lines
  audit_lines="$(grep -c 'teams_mcp_notification_failed_permanent' "$stderr_file" || true)"
  smoke_assert_eq "1" "$audit_lines" "T7 audit_lines (one row per permanent-failure event)"
  local audit_line
  audit_line="$(grep 'teams_mcp_notification_failed_permanent' "$stderr_file" | head -n 1)"
  # Field order: message_id → chat_id → attempts → last_error.
  if ! [[ "$audit_line" =~ message_id=.+chat_id=.+attempts=.+last_error= ]]; then
    smoke_fail "T7: audit row field order regressed (expected message_id < chat_id < attempts < last_error): $audit_line"
  fi
  smoke_log "T7 PASS"
}

# ---------------------------------------------------------------------
# T8: ci-select-smoke.sh maps plugins/teams/server.ts and
# scripts/smoke/beta5-2-zeta-teams-mcp-dedup.sh together.
# ---------------------------------------------------------------------
test_t8_ci_select_registration() {
  smoke_log "T8: ci-select-smoke.sh maps the four affected files to this smoke"
  grep -q "$SMOKE_NAME" "$CI_SELECT" \
    || smoke_fail "T8: ci-select-smoke.sh does not reference '$SMOKE_NAME'"
  # The smoke must be reachable from a plugins/teams/server.ts case
  # arm. ci-select-smoke.sh combines ms365 + teams under a single arm
  # for the shared mkdir/perm regression family — match either form
  # (the dedicated dedupe.ts arm OR the combined server.ts arm).
  local arm_start arm_end
  arm_start="$(grep -nE '^\s*plugins/teams/(server|dedupe)\.ts|^\s*plugins/ms365/server\.ts\|plugins/teams/server\.ts' "$CI_SELECT" \
    | head -n 1 | cut -d: -f1)"
  if [[ -z "$arm_start" ]]; then
    smoke_fail "T8: could not find any plugins/teams/* case arm in ci-select-smoke.sh"
  fi
  # The arm ends at the next `;;`.
  arm_end="$(awk -v start="$arm_start" 'NR>=start && /;;/ {print NR; exit}' "$CI_SELECT")"
  if [[ -z "$arm_end" ]]; then
    smoke_fail "T8: could not delimit plugins/teams/* case arm (no ';;' found after line $arm_start)"
  fi
  local arm_block
  arm_block="$(sed -n "${arm_start},${arm_end}p" "$CI_SELECT")"
  if ! printf '%s\n' "$arm_block" | grep -q "$SMOKE_NAME"; then
    smoke_fail "T8: '$SMOKE_NAME' not registered under the plugins/teams/* arm at lines $arm_start-$arm_end"
  fi
  # ALSO assert: the dedicated dedupe.ts arm exists (per the 4-site
  # registration contract — dedupe.ts is one of the affected files).
  if ! grep -nE '^\s*plugins/teams/dedupe\.ts\)' "$CI_SELECT" >/dev/null; then
    smoke_fail "T8: plugins/teams/dedupe.ts case arm missing — required for 4-site ci-select coverage"
  fi
  # ALSO assert: the smoke name is in add_all_required_static so that
  # changes to scripts/smoke/* or scripts/ci-select-smoke.sh itself
  # (which fan out to add_all_required_static) include this smoke.
  local req_static_start
  req_static_start="$(grep -nE '^add_all_required_static\(\) \{' "$CI_SELECT" | head -n 1 | cut -d: -f1)"
  if [[ -z "$req_static_start" ]]; then
    smoke_fail "T8: add_all_required_static() function not found"
  fi
  local req_static_end
  req_static_end="$(awk -v start="$req_static_start" 'NR>=start && /^\}/ {print NR; exit}' "$CI_SELECT")"
  if [[ -z "$req_static_end" ]]; then
    smoke_fail "T8: add_all_required_static() function unterminated"
  fi
  local req_block
  req_block="$(sed -n "${req_static_start},${req_static_end}p" "$CI_SELECT")"
  # Pure-bash substring test. NOT `printf ... | grep -q` (under `set -o pipefail`
  # grep -q closes the pipe on first match, printf then takes SIGPIPE, the pipeline
  # returns non-zero → a false "missing" once the required list is long enough to
  # fill the pipe buffer before grep exits: Linux/CI; macOS's shorter list hides
  # it). And NOT a `grep <<<` here-string (the heredoc-ban ratchet flags
  # here-strings). `[[ == *..* ]]` has neither a pipe nor a here-string.
  if [[ "$req_block" != *"$SMOKE_NAME"* ]]; then
    smoke_fail "T8: '$SMOKE_NAME' not in add_all_required_static() list"
  fi
  smoke_log "T8 PASS"
}

# ---------------------------------------------------------------------
# T9: codex r1 BLOCKING follow-up — emitMcpDeliveryFailurePermanent
# must create an admin escalation task via bridge-task.sh (the canonical
# operator signal). PATH-shim bridge-task.sh records argv; the smoke
# asserts:
#   - shim was invoked exactly once (one task per perma-fail event)
#   - argv: create, --to <admin>, --title <fixed prefix>, --body <…>,
#     --priority high
#   - body contains message_id, chat_id, attempts, last_error
#   - stderr carries the `admin_task_created` audit line
# ---------------------------------------------------------------------
test_t9_admin_task_created() {
  smoke_log "T9: emitMcpDeliveryFailurePermanent invokes bridge-task.sh create with admin escalation args"
  local files stdout_file stderr_file argv_file
  files="$(run_mcp_retry_variant_with_admin_task all-fail test-admin t9)"
  stdout_file="$(printf '%s\n' "$files" | sed -n 1p)"
  stderr_file="$(printf '%s\n' "$files" | sed -n 2p)"
  argv_file="$(printf '%s\n' "$files" | sed -n 3p)"
  # MCP retry result still has delivered=false (no behavioural drift).
  smoke_assert_eq "false" "$(json_field "$stdout_file" delivered)" "T9 delivered"
  smoke_assert_eq "3" "$(json_field "$stdout_file" attempts)" "T9 attempts"
  # Audit row for the admin task creation MUST be on stderr.
  if ! grep -q 'teams_mcp_perma_fail_admin_task_created' "$stderr_file"; then
    smoke_fail "T9: stderr missing 'teams_mcp_perma_fail_admin_task_created' audit line: $(cat "$stderr_file")"
  fi
  # Shim argv file MUST exist (proves spawnSync actually executed the shim).
  if [[ ! -f "$argv_file" ]]; then
    smoke_fail "T9: bridge-task.sh shim was not invoked (argv file $argv_file missing)"
  fi
  # argv assertions — each argument on its own line in the shim file.
  local argv_content
  argv_content="$(cat "$argv_file")"
  # NOTE: pass the search pattern via `-e --` so BSD grep (macOS) does
  # not interpret a leading `--` argv token as a flag.
  printf '%s\n' "$argv_content" | grep -qx -e 'create' \
    || smoke_fail "T9: argv missing 'create': $argv_content"
  printf '%s\n' "$argv_content" | grep -qx -e '--to' \
    || smoke_fail "T9: argv missing '--to': $argv_content"
  printf '%s\n' "$argv_content" | grep -qx -e 'test-admin' \
    || smoke_fail "T9: argv missing 'test-admin' (admin agent value): $argv_content"
  printf '%s\n' "$argv_content" | grep -qx -e '--title' \
    || smoke_fail "T9: argv missing '--title': $argv_content"
  printf '%s\n' "$argv_content" | grep -q -e '^\[teams-mcp-perma-fail\] message message-smoke undelivered' \
    || smoke_fail "T9: argv title prefix wrong: $argv_content"
  printf '%s\n' "$argv_content" | grep -qx -e '--body' \
    || smoke_fail "T9: argv missing '--body': $argv_content"
  printf '%s\n' "$argv_content" | grep -qx -e '--priority' \
    || smoke_fail "T9: argv missing '--priority': $argv_content"
  printf '%s\n' "$argv_content" | grep -qx -e 'high' \
    || smoke_fail "T9: argv missing 'high' priority value: $argv_content"
  # Body field assertions: body argument is the run of lines AFTER
  # --body and BEFORE the next argv token (the body has embedded
  # newlines because we built it with `[...].join('\n')`). The shim
  # records each argv element on its own line via `printf '%s\n' "$@"`,
  # which serializes the embedded `\n` as a literal newline run.
  # We re-join everything between `--body` and the next `--priority`
  # token. Use a fixed-string match in awk to avoid double-`--`
  # BSD-flag tripping.
  local body_line
  body_line="$(awk '
    $0=="--body" { in_body=1; next }
    in_body && $0=="--priority" { exit }
    in_body { print }
  ' "$argv_file")"
  if [[ -z "$body_line" ]]; then
    smoke_fail "T9: --body argument empty"
  fi
  smoke_assert_contains "$body_line" "message-smoke" "T9 body contains message_id"
  smoke_assert_contains "$body_line" "chat-smoke" "T9 body contains chat_id"
  smoke_assert_contains "$body_line" "attempts: 3" "T9 body contains attempts count"
  smoke_assert_contains "$body_line" "last_error:" "T9 body contains last_error label"
  smoke_log "T9 PASS"
}

# ---------------------------------------------------------------------
# T10: edge case — BRIDGE_ADMIN_AGENT_ID unset → fallback stderr line,
# no bridge-task.sh invocation, no crash. Asserts the graceful skip path.
# ---------------------------------------------------------------------
test_t10_admin_unset_fallback() {
  smoke_log "T10: BRIDGE_ADMIN_AGENT_ID unset → stderr fallback line, no task spawn, no crash"
  local stdout_file="$SMOKE_TMP_ROOT/mcp-retry.t10.stdout"
  local stderr_file="$SMOKE_TMP_ROOT/mcp-retry.t10.stderr"
  # Invoke without BRIDGE_ADMIN_AGENT_ID. BRIDGE_HOME is the
  # smoke_setup_bridge_home temp dir — no bridge-task.sh shim installed
  # there, so the skip-no-admin branch fires before any path probe.
  TEAMS_APP_ID=smoke TEAMS_APP_PASSWORD=smoke \
    BRIDGE_ADMIN_AGENT_ID= \
    bun "$TEAMS_SERVER" _smoke-mcp-retry --variant all-fail \
    --chat-id "chat-smoke" --message-id "message-smoke" \
    >"$stdout_file" 2>"$stderr_file"
  local rc=$?
  if (( rc != 0 )); then
    smoke_fail "T10: smoke harness exited nonzero (rc=$rc) — emitMcpDeliveryFailurePermanent crashed: $(cat "$stderr_file")"
  fi
  smoke_assert_eq "false" "$(json_field "$stdout_file" delivered)" "T10 delivered"
  if ! grep -q 'teams_mcp_perma_fail_admin_task_skipped reason=no_admin_configured' "$stderr_file"; then
    smoke_fail "T10: missing 'teams_mcp_perma_fail_admin_task_skipped reason=no_admin_configured' fallback: $(cat "$stderr_file")"
  fi
  # MUST NOT log a `created` line when admin is unset.
  if grep -q 'teams_mcp_perma_fail_admin_task_created' "$stderr_file"; then
    smoke_fail "T10: leaked 'admin_task_created' line when BRIDGE_ADMIN_AGENT_ID was unset"
  fi
  smoke_log "T10 PASS"
}

# ---------------------------------------------------------------------
# T11 (teeth): verify the static-source assertion catches a revert.
# Splice a synthetic version of emitMcpDeliveryFailurePermanent that
# OMITS the spawnSync call into a copy of server.ts, and confirm a
# strict static grep would trip. Mirrors the T6 teeth pattern.
# ---------------------------------------------------------------------
test_t11_teeth_no_spawn_caught() {
  smoke_log "T11 (teeth): reverting the spawnSync admin-task call MUST trip a static-source check"
  local copy="$SMOKE_TMP_ROOT/server-no-spawn.ts"
  # Build a copy that strips the bridge-task.sh spawn call from the
  # function body. The strict check requires that the live source has
  # BOTH the function `resolveBridgeTaskPath` AND the call site
  # `bridge-task.sh` token + spawnSync. Removing either of those in a
  # copy must trip the grep.
  sed -e '/bridge-task\.sh/d' \
      -e '/resolveBridgeTaskPath/d' \
      -e '/teams_mcp_perma_fail_admin_task_created/d' \
      "$TEAMS_SERVER" >"$copy"
  # The live file must contain all three tokens (positive sanity).
  grep -q 'bridge-task\.sh' "$TEAMS_SERVER" \
    || smoke_fail "T11 sanity: live server.ts has no 'bridge-task.sh' reference — code regression"
  grep -q 'resolveBridgeTaskPath' "$TEAMS_SERVER" \
    || smoke_fail "T11 sanity: live server.ts has no resolveBridgeTaskPath helper"
  grep -q 'teams_mcp_perma_fail_admin_task_created' "$TEAMS_SERVER" \
    || smoke_fail "T11 sanity: live server.ts has no admin_task_created audit token"
  # The stripped copy must trip all three checks.
  if grep -q 'bridge-task\.sh' "$copy"; then
    smoke_fail "T11: teeth strip incomplete — copy still has 'bridge-task.sh'"
  fi
  if grep -q 'resolveBridgeTaskPath' "$copy"; then
    smoke_fail "T11: teeth strip incomplete — copy still has resolveBridgeTaskPath"
  fi
  if grep -q 'teams_mcp_perma_fail_admin_task_created' "$copy"; then
    smoke_fail "T11: teeth strip incomplete — copy still has admin_task_created token"
  fi
  smoke_log "T11 PASS (teeth detector tripped on stripped copy)"
}

# ---------------------------------------------------------------------
# Test runner.
# ---------------------------------------------------------------------
smoke_run "T1 no-forget-dedupe-line" test_t1_no_forget_dedupe_line
smoke_run "T2 helper-wiring" test_t2_helper_wiring

if (( HAS_BUN )); then
  # plugins/teams/node_modules must be present for the bun invocation
  # to import @modelcontextprotocol/sdk + botbuilder. Install on demand
  # exactly as teams-shim-roundtrip.sh does.
  if [[ ! -d "$TEAMS_DIR/node_modules" ]]; then
    smoke_log "ensuring plugins/teams/node_modules present"
    if ! ( cd "$TEAMS_DIR" && bun install --frozen-lockfile --no-summary >&2 ); then
      smoke_fail "bun install in plugins/teams failed"
    fi
  fi
  smoke_run "T3 succeed-first" test_t3_succeed_first
  smoke_run "T4 succeed-second" test_t4_succeed_second
  smoke_run "T5 all-fail-audit-row" test_t5_all_fail_audit_row
  smoke_run "T7 audit-row-shape" test_t7_audit_row_shape
  smoke_run "T9 admin-task-created" test_t9_admin_task_created
  smoke_run "T10 admin-unset-fallback" test_t10_admin_unset_fallback
else
  smoke_skip "T3 succeed-first" "bun not on PATH"
  smoke_skip "T4 succeed-second" "bun not on PATH"
  smoke_skip "T5 all-fail-audit-row" "bun not on PATH"
  smoke_skip "T7 audit-row-shape" "bun not on PATH"
  smoke_skip "T9 admin-task-created" "bun not on PATH"
  smoke_skip "T10 admin-unset-fallback" "bun not on PATH"
fi

smoke_run "T6 teeth-revert-caught" test_t6_teeth_revert_caught
smoke_run "T8 ci-select-registration" test_t8_ci_select_registration
smoke_run "T11 teeth-no-spawn-caught" test_t11_teeth_no_spawn_caught

smoke_log "beta5-2-zeta-teams-mcp-dedup: ALL TESTS PASS"
exit 0
