#!/usr/bin/env bash
# scripts/smoke/1437-reactive-cron-rotation.sh — Issue #1437 smoke.
#
# Headless cron hosts have no claude-hud `.usage-cache.json`, so the daemon's
# proactive usage-driven Claude OAT rotation never fires there. This smoke
# proves the REACTIVE run-path: on a live cron run that hit the usage
# limit / 429, the runner detects the quota, ROTATES FIRST (so `claude-token
# rotate` still sees >=2 enabled tokens), THEN deterministically disables the
# vacated quota-hit token, and re-dispatches the failed job ONCE.
#
# No live OAuth: a fake 429 run output is injected against a 2-token fake pool
# wired through the REAL bridge-auth.py registry logic. A fake re-dispatch
# recorder captures the single re-dispatch invocation.
#
# Case 1 (2-token pool): detect -> rotate advances (new != old) -> old token
#   ends quota_limited -> `--agents all` sync invoked -> exactly one
#   re-dispatch fired -> audit `claude_token_rotation` present.
# Case 2 (no enabled alternate): detect -> rotate is a no-op -> quota-hit token
#   left as-is (still enabled, not force-disabled by us) -> ZERO re-dispatch
#   (no infinite loop).
#
# Footgun #11: no heredoc-stdin / here-string into a subprocess anywhere —
# fakes are written with printf, classification/rotation goes through files.

set -euo pipefail

SMOKE_NAME="1437-reactive-cron-rotation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
HELPER="$SCRIPT_DIR/1437-reactive-cron-rotation-helper.py"

smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home

REGISTRY="$BRIDGE_HOME/claude-oauth-tokens.json"
FAKE_TOKEN_CLI="$SMOKE_TMP_ROOT/fake-claude-token"
FAKE_REDISPATCH="$SMOKE_TMP_ROOT/fake-redispatch"
REDISPATCH_LOG="$SMOKE_TMP_ROOT/redispatch-invocations.log"

# --- fake `claude-token` CLI: delegate to the REAL bridge-auth.py against our
# isolated registry, AND record the rotate argv so we can assert `--agents all`
# was synced. Synthetic (non-OAuth-shaped) tokens keep the credential guard
# happy. Two runtime failure-injection toggles let the smoke exercise the
# return-code paths the real `bridge-auth.sh` wrapper produces:
#   FAKE_ROTATE_SYNC_FAIL=1 — rotate emits `rotated` JSON but exits nonzero
#       (mirrors bridge-auth.sh exiting sync_rc when `--agents all` sync fails).
#   FAKE_MARK_QUOTA_FAIL=1  — mark-quota exits nonzero WITHOUT disabling the
#       token (so the old token stays enabled → the runner must NOT redispatch).
#   FAKE_LIST_FAIL_FIRST=1  — the FIRST `list` (the runner's pre-rotation
#       registry read) fails, forcing old_active to be recovered from the rotate
#       payload's old_active_token_id. Subsequent `list` calls succeed (a
#       per-run counter file under SMOKE_TMP_ROOT tracks which call we're on).
LIST_CALL_COUNTER="$SMOKE_TMP_ROOT/list-call-counter"
ROTATE_ARGV_LOG="$SMOKE_TMP_ROOT/rotate-argv.log"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'if [[ "${1:-}" == "rotate" ]]; then printf "%%s\\n" "$*" >>%q; fi\n' "$ROTATE_ARGV_LOG"
  # first-list failure injection: fail only the runner's pre-rotation read.
  printf 'if [[ "${1:-}" == "list" && "${FAKE_LIST_FAIL_FIRST:-0}" == "1" ]]; then\n'
  printf '  n=0; [[ -f %q ]] && n=$(cat %q); n=$((n+1)); printf "%%s" "$n" >%q\n' \
    "$LIST_CALL_COUNTER" "$LIST_CALL_COUNTER" "$LIST_CALL_COUNTER"
  printf '  if [[ "$n" == "1" ]]; then printf "%%s\\n" "boom: injected list failure" >&2; exit 9; fi\n'
  printf 'fi\n'
  # mark-quota failure injection: emit a rc!=0 WITHOUT touching the registry.
  printf 'if [[ "${1:-}" == "mark-quota" && "${FAKE_MARK_QUOTA_FAIL:-0}" == "1" ]]; then\n'
  printf '  printf "%%s\\n" "{\\"status\\":\\"error\\",\\"reason\\":\\"injected\\"}"; exit 3\n'
  printf 'fi\n'
  printf '%q %q --registry %q "$@"\n' "$PY_BIN" "$REPO_ROOT/bridge-auth.py" "$REGISTRY"
  printf 'rc=$?\n'
  # rotate sync failure injection: real rotate already mutated the registry +
  # printed `rotated` JSON; force a nonzero exit like the wrapper would.
  printf 'if [[ "${1:-}" == "rotate" && "${FAKE_ROTATE_SYNC_FAIL:-0}" == "1" && $rc -eq 0 ]]; then rc=7; fi\n'
  printf 'exit $rc\n'
} >"$FAKE_TOKEN_CLI"
chmod +x "$FAKE_TOKEN_CLI"

# --- fake re-dispatch recorder: append the run_id it was handed.
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "${1:-}" >>%q\n' "$REDISPATCH_LOG"
} >"$FAKE_REDISPATCH"
chmod +x "$FAKE_REDISPATCH"

export BRIDGE_CLAUDE_TOKEN_CMD="$FAKE_TOKEN_CLI"
export BRIDGE_CRON_REACTIVE_REDISPATCH_CMD="$FAKE_REDISPATCH"

write_registry() {
  # $1 = tokB enabled? (1/0)
  local tokb_enabled="$1"
  "$PY_BIN" -c '
import json, sys
reg, tokb_enabled = sys.argv[1], sys.argv[2] == "1"
data = {
  "version": 1,
  "active_token_id": "tokA",
  "auto_rotate_enabled": True,
  "rotation_threshold": 99.0,
  "tokens": [
    {"id": "tokA", "token": "FAKE-SYNTHETIC-TOKEN-AAAAAAAAAAAA", "enabled": True},
    {"id": "tokB", "token": "FAKE-SYNTHETIC-TOKEN-BBBBBBBBBBBB", "enabled": tokb_enabled},
  ],
}
open(reg, "w").write(json.dumps(data, indent=2))
' "$REGISTRY" "$tokb_enabled"
}

registry_active() {
  "$PY_BIN" -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("active_token_id", ""))
' "$REGISTRY"
}

token_attr() {
  # $1 = token id, $2 = attr key (enabled / disabled_reason / ...)
  "$PY_BIN" -c '
import json, sys
d = json.load(open(sys.argv[1]))
tid, key = sys.argv[2], sys.argv[3]
row = next((t for t in d.get("tokens", []) if t.get("id") == tid), {})
print(row.get(key, ""))
' "$REGISTRY" "$1" "$2"
}

summary_field() {
  # $1 = summary json file, $2 = key
  "$PY_BIN" -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get(sys.argv[2])
print("" if v is None else v)
' "$1" "$2"
}

audit_count() {
  # $1 = action
  local action="$1"
  if [[ ! -f "$BRIDGE_AUDIT_LOG" ]]; then
    printf '0\n'
    return
  fi
  "$PY_BIN" -c '
import json, sys
log, action = sys.argv[1], sys.argv[2]
n = 0
for line in open(log, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get("action") == action:
        n += 1
print(n)
' "$BRIDGE_AUDIT_LOG" "$action"
}

redispatch_count() {
  # Count non-empty lines in the re-dispatch log (0 when absent/empty).
  if [[ ! -s "$REDISPATCH_LOG" ]]; then
    printf '0\n'
    return
  fi
  grep -c . "$REDISPATCH_LOG"
}

inject_429_output() {
  # Writes a fake 429 run: empty stdout, limit message on STDERR (the common
  # case the issue calls out — 429 frequently lands on stderr).
  local stdout_file="$1"
  local stderr_file="$2"
  : >"$stdout_file"
  printf 'Claude API error: 429 Too Many Requests — you have hit your limit. resets in 3h 12m\n' >"$stderr_file"
}

# ===========================================================================
# Case 1 — 2-token enabled pool: full reactive chain.
# ===========================================================================
smoke_log "case 1: 2-token enabled pool — detect/rotate/disable/redispatch"

write_registry 1
: >"$REDISPATCH_LOG" || true
: >"$ROTATE_ARGV_LOG" || true

RUN_DIR_1="$BRIDGE_CRON_STATE_DIR/runs/run-c1"
mkdir -p "$RUN_DIR_1"
STDOUT_1="$RUN_DIR_1/stdout.log"
STDERR_1="$RUN_DIR_1/stderr.log"
inject_429_output "$STDOUT_1" "$STDERR_1"

SUMMARY_1="$SMOKE_TMP_ROOT/summary-c1.json"
"$PY_BIN" "$HELPER" \
  --run-dir "$RUN_DIR_1" \
  --run-id "run-c1" \
  --job-id "job-1437" \
  --stdout-file "$STDOUT_1" \
  --stderr-file "$STDERR_1" \
  --returncode 1 >"$SUMMARY_1"

smoke_log "case 1 summary: $(cat "$SUMMARY_1")"

smoke_assert_eq "True" "$(summary_field "$SUMMARY_1" detected)" "case1.detected"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_1" rotated)" "case1.rotated"
smoke_assert_eq "tokA" "$(summary_field "$SUMMARY_1" old_active)" "case1.old_active"
smoke_assert_eq "tokB" "$(summary_field "$SUMMARY_1" new_active)" "case1.new_active"

# Rotate must advance away from the quota-hit active.
OLD_ACTIVE="$(summary_field "$SUMMARY_1" old_active)"
NEW_ACTIVE="$(summary_field "$SUMMARY_1" new_active)"
[[ "$NEW_ACTIVE" != "$OLD_ACTIVE" ]] || smoke_fail "case1: rotate did not advance ($OLD_ACTIVE == $NEW_ACTIVE)"

# Registry: new active is tokB; old tokA is disabled + quota_limited.
smoke_assert_eq "tokB" "$(registry_active)" "case1.registry.active"
smoke_assert_eq "False" "$(token_attr tokA enabled)" "case1.tokA.enabled"
smoke_assert_eq "quota_limited" "$(token_attr tokA disabled_reason)" "case1.tokA.disabled_reason"
smoke_assert_eq "True" "$(token_attr tokB enabled)" "case1.tokB.enabled"

# `--agents all` was synced on the rotate, and the sync succeeded (rc 0).
smoke_assert_contains "$(cat "$ROTATE_ARGV_LOG")" "--agents all" "case1.rotate.agents_all"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_1" agents_synced)" "case1.agents_synced"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_1" old_disabled)" "case1.old_disabled"

# Exactly one re-dispatch fired, for run-c1.
REDISPATCH_COUNT="$(redispatch_count)"
smoke_assert_eq "1" "$REDISPATCH_COUNT" "case1.redispatch.count"
smoke_assert_contains "$(cat "$REDISPATCH_LOG")" "run-c1" "case1.redispatch.run_id"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_1" redispatched)" "case1.summary.redispatched"

# Audit rows present.
smoke_assert_eq "1" "$(audit_count claude_token_rotation)" "case1.audit.claude_token_rotation"
smoke_assert_eq "1" "$(audit_count cron_quota_detected)" "case1.audit.cron_quota_detected"

smoke_log "case 1 OK"

# ===========================================================================
# Case 1b — re-dispatch attempt cap: a SECOND quota hit on the SAME job must
# NOT re-dispatch again (persisted per-job cap = 1 by default). This guards
# against an infinite re-dispatch loop on a persistent global quota.
# ===========================================================================
smoke_log "case 1b: per-job attempt cap blocks a second re-dispatch"

# Rebuild a fresh 2-token pool so the rotate itself can succeed again; the cap,
# not the pool, must be what blocks the second re-dispatch.
write_registry 1
RUN_DIR_1B="$BRIDGE_CRON_STATE_DIR/runs/run-c1b"
mkdir -p "$RUN_DIR_1B"
STDOUT_1B="$RUN_DIR_1B/stdout.log"
STDERR_1B="$RUN_DIR_1B/stderr.log"
inject_429_output "$STDOUT_1B" "$STDERR_1B"

SUMMARY_1B="$SMOKE_TMP_ROOT/summary-c1b.json"
# Disable cooldown so the cap (not the cooldown) is the thing under test.
BRIDGE_CRON_REACTIVE_COOLDOWN_SECONDS=0 "$PY_BIN" "$HELPER" \
  --run-dir "$RUN_DIR_1B" \
  --run-id "run-c1b" \
  --job-id "job-1437" \
  --stdout-file "$STDOUT_1B" \
  --stderr-file "$STDERR_1B" \
  --returncode 1 >"$SUMMARY_1B"

smoke_log "case 1b summary: $(cat "$SUMMARY_1B")"

smoke_assert_eq "attempt_cap_reached" "$(summary_field "$SUMMARY_1B" redispatch_decision)" "case1b.decision"
# Still exactly one re-dispatch total (the cap held).
REDISPATCH_COUNT_1B="$(redispatch_count)"
smoke_assert_eq "1" "$REDISPATCH_COUNT_1B" "case1b.redispatch.count_unchanged"

smoke_log "case 1b OK"

# ===========================================================================
# Case 2 — no enabled alternate: rotate is a no-op, ZERO re-dispatch, no loop.
# ===========================================================================
smoke_log "case 2: no enabled alternate — no-op rotate, zero re-dispatch"

write_registry 0   # tokB disabled => only tokA enabled
: >"$REDISPATCH_LOG"
: >"$ROTATE_ARGV_LOG"

# Snapshot the rotation-audit count BEFORE the no-op so we can assert the no-op
# adds NO new claude_token_rotation row (prior cases may have rotated >1 time).
ROTATION_AUDIT_BEFORE="$(audit_count claude_token_rotation)"

RUN_DIR_2="$BRIDGE_CRON_STATE_DIR/runs/run-c2"
mkdir -p "$RUN_DIR_2"
STDOUT_2="$RUN_DIR_2/stdout.log"
STDERR_2="$RUN_DIR_2/stderr.log"
inject_429_output "$STDOUT_2" "$STDERR_2"

SUMMARY_2="$SMOKE_TMP_ROOT/summary-c2.json"
"$PY_BIN" "$HELPER" \
  --run-dir "$RUN_DIR_2" \
  --run-id "run-c2" \
  --job-id "job-1437-no-alt" \
  --stdout-file "$STDOUT_2" \
  --stderr-file "$STDERR_2" \
  --returncode 1 >"$SUMMARY_2"

smoke_log "case 2 summary: $(cat "$SUMMARY_2")"

smoke_assert_eq "True" "$(summary_field "$SUMMARY_2" detected)" "case2.detected"
smoke_assert_eq "False" "$(summary_field "$SUMMARY_2" rotated)" "case2.rotated"
# Active token unchanged; tokA still enabled (we did NOT force-disable it — no
# healthy alternate, so leaving it enabled lets recovery + the next run retry).
smoke_assert_eq "tokA" "$(registry_active)" "case2.registry.active"
smoke_assert_eq "True" "$(token_attr tokA enabled)" "case2.tokA.enabled"

# ZERO re-dispatch — the critical no-loop guarantee.
REDISPATCH_COUNT_2="$(redispatch_count)"
smoke_assert_eq "0" "$REDISPATCH_COUNT_2" "case2.redispatch.count_zero"
# No NEW claude_token_rotation audit row for the no-op rotate.
smoke_assert_eq "$ROTATION_AUDIT_BEFORE" "$(audit_count claude_token_rotation)" "case2.audit.no_new_rotation"

smoke_log "case 2 OK"

# ===========================================================================
# Case 3 — `--agents all` sync FAILS (rotate JSON says rotated, rc != 0). The
# registry rotation still happened, so we still rotate + disable the old token,
# but we must record agents_synced=False (AC1's all-agents claim must be
# honest, not silently treated as a clean propagation).
# ===========================================================================
smoke_log "case 3: rotate ok but --agents all sync fails (rc!=0)"

write_registry 1
: >"$REDISPATCH_LOG"
: >"$ROTATE_ARGV_LOG"

RUN_DIR_3="$BRIDGE_CRON_STATE_DIR/runs/run-c3"
mkdir -p "$RUN_DIR_3"
STDOUT_3="$RUN_DIR_3/stdout.log"
STDERR_3="$RUN_DIR_3/stderr.log"
inject_429_output "$STDOUT_3" "$STDERR_3"

SUMMARY_3="$SMOKE_TMP_ROOT/summary-c3.json"
FAKE_ROTATE_SYNC_FAIL=1 "$PY_BIN" "$HELPER" \
  --run-dir "$RUN_DIR_3" \
  --run-id "run-c3" \
  --job-id "job-1437-syncfail" \
  --stdout-file "$STDOUT_3" \
  --stderr-file "$STDERR_3" \
  --returncode 1 >"$SUMMARY_3"

smoke_log "case 3 summary: $(cat "$SUMMARY_3")"

# Registry rotation still happened; old token still retired.
smoke_assert_eq "True" "$(summary_field "$SUMMARY_3" rotated)" "case3.rotated"
smoke_assert_eq "tokB" "$(registry_active)" "case3.registry.active"
smoke_assert_eq "False" "$(token_attr tokA enabled)" "case3.tokA.disabled"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_3" old_disabled)" "case3.old_disabled"
# But the sync failure is recorded, not hidden.
smoke_assert_eq "False" "$(summary_field "$SUMMARY_3" agents_synced)" "case3.agents_synced_false"

smoke_log "case 3 OK"

# ===========================================================================
# Case 4 — mark-quota FAILS (rc!=0 and the token stays enabled). The hard
# requirement is that the old quota-hit token must never remain enabled after a
# successful rotate; if we cannot prove it is disabled, we must NOT re-dispatch
# (re-running with the quota token still in the enabled pool risks the next
# rotation cycling straight back into it).
# ===========================================================================
smoke_log "case 4: mark-quota fails -> old token stays enabled -> ZERO re-dispatch"

write_registry 1
: >"$REDISPATCH_LOG"
: >"$ROTATE_ARGV_LOG"
ROTATION_AUDIT_BEFORE_4="$(audit_count claude_token_rotation)"

RUN_DIR_4="$BRIDGE_CRON_STATE_DIR/runs/run-c4"
mkdir -p "$RUN_DIR_4"
STDOUT_4="$RUN_DIR_4/stdout.log"
STDERR_4="$RUN_DIR_4/stderr.log"
inject_429_output "$STDOUT_4" "$STDERR_4"

SUMMARY_4="$SMOKE_TMP_ROOT/summary-c4.json"
FAKE_MARK_QUOTA_FAIL=1 "$PY_BIN" "$HELPER" \
  --run-dir "$RUN_DIR_4" \
  --run-id "run-c4" \
  --job-id "job-1437-markfail" \
  --stdout-file "$STDOUT_4" \
  --stderr-file "$STDERR_4" \
  --returncode 1 >"$SUMMARY_4"

smoke_log "case 4 summary: $(cat "$SUMMARY_4")"

# Rotate still advanced (tokB active), but the old token could NOT be disabled.
smoke_assert_eq "True" "$(summary_field "$SUMMARY_4" rotated)" "case4.rotated"
smoke_assert_eq "tokB" "$(registry_active)" "case4.registry.active"
smoke_assert_eq "True" "$(token_attr tokA enabled)" "case4.tokA.still_enabled"
smoke_assert_eq "False" "$(summary_field "$SUMMARY_4" old_disabled)" "case4.old_disabled_false"
# Loop-safety: ZERO re-dispatch because the old token is still enabled.
smoke_assert_eq "old_token_still_enabled" "$(summary_field "$SUMMARY_4" redispatch_decision)" "case4.decision"
smoke_assert_eq "0" "$(redispatch_count)" "case4.redispatch.count_zero"

smoke_log "case 4 OK"

# ===========================================================================
# Case 5 — pre-rotation registry read FAILS. `old_active` cannot be read up
# front, but the rotate payload reports `old_active_token_id`. The runner must
# recover the old token id from the payload, still disable it, and (since it is
# now provably disabled) re-dispatch. Guards the fail-open hole where an empty
# old_active would skip the disable + loop-safety guard.
# ===========================================================================
smoke_log "case 5: pre-rotation read fails -> recover old id from rotate payload"

write_registry 1
: >"$REDISPATCH_LOG"
: >"$ROTATE_ARGV_LOG"
rm -f "$LIST_CALL_COUNTER"

RUN_DIR_5="$BRIDGE_CRON_STATE_DIR/runs/run-c5"
mkdir -p "$RUN_DIR_5"
STDOUT_5="$RUN_DIR_5/stdout.log"
STDERR_5="$RUN_DIR_5/stderr.log"
inject_429_output "$STDOUT_5" "$STDERR_5"

SUMMARY_5="$SMOKE_TMP_ROOT/summary-c5.json"
FAKE_LIST_FAIL_FIRST=1 "$PY_BIN" "$HELPER" \
  --run-dir "$RUN_DIR_5" \
  --run-id "run-c5" \
  --job-id "job-1437-prereadfail" \
  --stdout-file "$STDOUT_5" \
  --stderr-file "$STDERR_5" \
  --returncode 1 >"$SUMMARY_5"

smoke_log "case 5 summary: $(cat "$SUMMARY_5")"

# Old id recovered from the rotate payload, token disabled, re-dispatch fired.
smoke_assert_eq "tokA" "$(summary_field "$SUMMARY_5" old_active)" "case5.old_active_recovered"
smoke_assert_eq "tokB" "$(summary_field "$SUMMARY_5" new_active)" "case5.new_active"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_5" rotated)" "case5.rotated"
smoke_assert_eq "False" "$(token_attr tokA enabled)" "case5.tokA.disabled"
smoke_assert_eq "True" "$(summary_field "$SUMMARY_5" old_disabled)" "case5.old_disabled"
smoke_assert_eq "1" "$(redispatch_count)" "case5.redispatch.count"

smoke_log "case 5 OK"

smoke_log "PASS"
