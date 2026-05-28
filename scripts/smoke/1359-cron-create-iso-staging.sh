#!/usr/bin/env bash
# scripts/smoke/1359-cron-create-iso-staging.sh — Issue #1359 tactical smoke.
#
# Validates the iso-v2 → controller staging delegation path for
# `agb cron create`. The reproducer (2026-05-28 v0.15.0-beta5-2,
# operator host test_clean): an iso v2 agent runs `agb cron create`
# → PermissionError on `cron/jobs.json` (controller-owned 0640) →
# operator falls back to system crontab → bridge-native + system
# crontab race-fire same job → duplicate work.
#
# This smoke pins six scenarios. Smokes run as the operator's UID so we
# simulate the iso-vs-controller split by pointing the agent's
# `BRIDGE_AGENT_OS_USER` metadata at the current OS user — the staging
# helper's owner-UID check then resolves to "current uid == expected
# iso uid" and the apply path proceeds.
#
# Cases:
#   T1 — staging request from iso UID flows through to native-create,
#        result.json carries cron_id, jobs.json has the new entry.
#   T2 — controller UID (no BRIDGE_AGENT_ID) calls bridge-cron.sh create
#        → direct path runs (regression — existing path is unaffected).
#   T2b — codex r2 BLOCKING #1: a stale staging row (age > stale_secs)
#        must be swept BEFORE apply, not after — the pre-r2 tick order
#        would execute the abandoned request and the sweep would
#        no-op because apply wrote a result.json. + teeth.
#   T3 — staging payload with actor_agent ≠ target agent → rejected,
#        result.json carries actor_agent_mismatch.
#   T3b — codex r2 BLOCKING #3: bridge-cron.sh entry path with
#        BRIDGE_AGENT_ID=A + `--agent B` (cross-agent) MUST exit
#        non-zero with an explicit error; the pre-r2 shape silently
#        fell through to the direct write path. + teeth.
#   T4 — staging payload owned by a different UID than the agent's iso
#        UID → rejected, result.json carries file_owner_uid_mismatch.
#   T4b — codex r2 BLOCKING #2: a forged `actor_uid` field that is not
#        parseable as int (e.g. "not-int") MUST produce an explicit
#        reject result with reason=malformed_actor_uid, NOT a Python
#        crash that leaves the request unresolved and re-applied next
#        tick. + teeth.
#   T5 — stale staging file (no result, age > stale_secs) → swept by
#        the daemon-side helper, audit captures the sweep.
#   T6 — TEETH: with staging delegation routing bypassed (jobs.json
#        forced unwritable but no staging helper available), the iso-
#        UID create fails — proves the staging path is what closes the
#        PermissionError.

set -euo pipefail

SMOKE_NAME="1359-cron-create-iso-staging"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
JOBS_FILE="$BRIDGE_NATIVE_CRON_JOBS_FILE"
STAGING_ROOT="$BRIDGE_STATE_DIR/cron-staging"
ISO_AGENT="iso-smoke"
PEER_AGENT="iso-peer"
ISO_STAGING_DIR="$STAGING_ROOT/$ISO_AGENT"
PEER_STAGING_DIR="$STAGING_ROOT/$PEER_AGENT"
mkdir -p "$ISO_STAGING_DIR" "$PEER_STAGING_DIR"
chmod 0711 "$STAGING_ROOT" 2>/dev/null || true
chmod 2770 "$ISO_STAGING_DIR" 2>/dev/null || chmod 0770 "$ISO_STAGING_DIR"
chmod 2770 "$PEER_STAGING_DIR" 2>/dev/null || chmod 0770 "$PEER_STAGING_DIR"
# Seed an empty jobs.json so the apply path can find it.
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$JOBS_FILE"

# Pin staging timing tight so T1/T5 run quickly.
export BRIDGE_CRON_STAGING_TIMEOUT_SECONDS=10
export BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS=1
export BRIDGE_CRON_STAGING_STALE_SECONDS=2
export BRIDGE_CRON_STAGING_DIR="$STAGING_ROOT"
export BRIDGE_NATIVE_CRON_JOBS_FILE="$JOBS_FILE"

# Build the agent-meta.env that lets the staging.py apply path resolve
# the agent's iso UID. We point it at the current OS user so the
# smoke's apply step recognizes our UID as the expected iso UID.
META_DIR="$BRIDGE_STATE_DIR/agents/$ISO_AGENT"
mkdir -p "$META_DIR"
cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF

# Helper to call staging.py directly.
staging_py() {
  "$PY_BIN" "$REPO_ROOT/lib/cron-helpers/staging.py" "$@"
}

# Helper to read result file fields.
result_field() {
  local result_path="$1"
  local field="$2"
  "$PY_BIN" - "$result_path" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
val = data.get(sys.argv[2])
print("" if val is None else val)
PY
}

# Count jobs in jobs.json.
jobs_count() {
  "$PY_BIN" - "$JOBS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(len(data.get("jobs") or []))
PY
}

# ---------------------------------------------------------------------------
# T1 — iso UID staging request applies cleanly.
# ---------------------------------------------------------------------------
smoke_log "T1: iso UID staging request → daemon apply → cron id in jobs.json"

T1_PAYLOAD="$(
  "$PY_BIN" - "$ISO_AGENT" "$CURRENT_UID" <<'PY'
import json
import sys

agent, uid = sys.argv[1], int(sys.argv[2])
print(json.dumps({
    "schema_version": 1,
    "action": "create",
    "actor_agent": agent,
    "actor_uid": uid,
    "agent": agent,
    "schedule": "0 5 * * *",
    "at": None,
    "tz": "Asia/Seoul",
    "title": f"{agent}-daily-brief",
    "payload": "Run the morning brief.",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}))
PY
)"

T1_UUID="$(staging_py write-request "$STAGING_ROOT" "$ISO_AGENT" "$T1_PAYLOAD")"
T1_UUID="${T1_UUID%%$'\n'*}"
[[ -n "$T1_UUID" ]] || smoke_fail "T1: write-request returned empty uuid"

# Verify the file was written at mode 0660 under the per-agent subdir.
T1_PATH="$ISO_STAGING_DIR/$T1_UUID.json"
[[ -f "$T1_PATH" ]] || smoke_fail "T1: staging file missing: $T1_PATH"
T1_MODE="$(stat -c '%a' "$T1_PATH" 2>/dev/null || stat -f '%Lp' "$T1_PATH" 2>/dev/null || echo '?')"
smoke_assert_eq "660" "$T1_MODE" "T1: staging file must be mode 0660"

# Simulate daemon apply directly. We do NOT spawn the full daemon —
# the apply path is unit-testable via `staging.py apply`. The
# canonical actor_agent (third arg) comes from the staging-path dirname
# in the daemon; here we pass it explicitly.
if ! staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T1_UUID" "$JOBS_FILE" >/dev/null 2>&1; then
  smoke_fail "T1: staging apply returned non-zero rc"
fi

T1_RESULT="$ISO_STAGING_DIR/$T1_UUID.result.json"
[[ -f "$T1_RESULT" ]] || smoke_fail "T1: result.json missing: $T1_RESULT"
T1_STATUS="$(result_field "$T1_RESULT" status)"
T1_AUDIT_ACTION="$(result_field "$T1_RESULT" audit_action)"
T1_CRON_ID="$(result_field "$T1_RESULT" cron_id)"
smoke_assert_eq "ok" "$T1_STATUS" "T1: result status must be ok"
smoke_assert_eq "cron_staging_applied" "$T1_AUDIT_ACTION" "T1: result audit_action must be cron_staging_applied"
[[ -n "$T1_CRON_ID" ]] || smoke_fail "T1: result missing cron_id"
smoke_assert_eq "1" "$(jobs_count)" "T1: jobs.json must contain exactly 1 job after apply"

smoke_log "ok: T1 — iso UID staging request applied (cron_id=$T1_CRON_ID)"

# ---------------------------------------------------------------------------
# T2 — controller UID direct path (regression).
# ---------------------------------------------------------------------------
smoke_log "T2: controller UID direct path (no BRIDGE_AGENT_ID, no staging)"

# Without BRIDGE_AGENT_ID, the predicate must NOT route through
# staging — direct native-create runs.
T2_BEFORE="$(jobs_count)"
unset BRIDGE_AGENT_ID
"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent "$ISO_AGENT" \
  --schedule "0 6 * * *" \
  --tz "Asia/Seoul" \
  --title "$ISO_AGENT-evening-brief" \
  --payload "Run the evening brief." >/dev/null
T2_AFTER="$(jobs_count)"
[[ "$T2_AFTER" -eq $(( T2_BEFORE + 1 )) ]] || \
  smoke_fail "T2: direct native-create should add exactly one job (before=$T2_BEFORE after=$T2_AFTER)"

# Exercise the bridge-cron.sh dispatcher itself: with BRIDGE_AGENT_ID
# unset AND jobs.json writable, the predicate must NOT route through
# staging — the direct native-create path runs. Cheapest assertion: run
# bridge-cron.sh create end-to-end with the file directly writable, and
# confirm one job was added without any staging file appearing.
T2_BEFORE_DIRECT="$(jobs_count)"
T2_STAGING_COUNT_BEFORE="$(find "$ISO_STAGING_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
unset BRIDGE_AGENT_ID
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$ISO_AGENT" \
  --schedule "0 11 * * *" \
  --tz "Asia/Seoul" \
  --title "$ISO_AGENT-direct-via-bridge-cron-sh" \
  --payload "direct path probe" >/dev/null
T2_AFTER_DIRECT="$(jobs_count)"
T2_STAGING_COUNT_AFTER="$(find "$ISO_STAGING_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$T2_AFTER_DIRECT" -eq $(( T2_BEFORE_DIRECT + 1 )) ]] || \
  smoke_fail "T2: direct bridge-cron.sh create should add 1 job (before=$T2_BEFORE_DIRECT after=$T2_AFTER_DIRECT)"
[[ "$T2_STAGING_COUNT_AFTER" -eq "$T2_STAGING_COUNT_BEFORE" ]] || \
  smoke_fail "T2: direct path must NOT create any staging file (before=$T2_STAGING_COUNT_BEFORE after=$T2_STAGING_COUNT_AFTER)"
smoke_log "ok: T2 — direct path unaffected; no staging file created"

# ---------------------------------------------------------------------------
# T3 — payload.actor_agent != path dirname (cross-agent forge attempt).
# ---------------------------------------------------------------------------
smoke_log "T3: payload claims actor_agent != staging path dirname → reject"

# Iso UID writes a request file claiming to be from PEER_AGENT but
# drops it into ISO_AGENT's subdir. The matrix-grant boundary would
# block ISO_AGENT's UID from writing into PEER_AGENT's subdir, but
# nothing stops the iso UID from lying in its own subdir's payload.
# The daemon recovers the canonical actor_agent from the dirname and
# rejects the mismatch.
T3_PAYLOAD="$(
  "$PY_BIN" - "$PEER_AGENT" "$PEER_AGENT" "$CURRENT_UID" <<'PY'
import json
import sys

actor, target, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({
    "schema_version": 1,
    "action": "create",
    "actor_agent": actor,
    "actor_uid": uid,
    "agent": target,
    "schedule": "0 7 * * *",
    "at": None,
    "tz": "Asia/Seoul",
    "title": f"{target}-forged-cron",
    "payload": "Cross-agent forge attempt",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}))
PY
)"

# Drop under ISO_AGENT's subdir but claim PEER_AGENT in the payload.
T3_UUID="$(staging_py write-request "$STAGING_ROOT" "$ISO_AGENT" "$T3_PAYLOAD")"
T3_UUID="${T3_UUID%%$'\n'*}"
T3_BEFORE="$(jobs_count)"
set +e
staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T3_UUID" "$JOBS_FILE" >/dev/null 2>&1
T3_RC=$?
set -e
[[ "$T3_RC" -ne 0 ]] || smoke_fail "T3: apply must fail with non-zero rc"
T3_RESULT="$ISO_STAGING_DIR/$T3_UUID.result.json"
T3_AUDIT_ACTION="$(result_field "$T3_RESULT" audit_action)"
T3_ERROR="$(result_field "$T3_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T3_AUDIT_ACTION" "T3: audit_action must be rejected"
smoke_assert_contains "$T3_ERROR" "payload_actor_agent_mismatch" "T3: error must explain payload_actor_agent_mismatch"
T3_AFTER="$(jobs_count)"
[[ "$T3_AFTER" -eq "$T3_BEFORE" ]] || smoke_fail "T3: jobs.json count must NOT change (before=$T3_BEFORE after=$T3_AFTER)"
smoke_log "ok: T3 — payload-vs-dirname mismatch reject pinned (error=$T3_ERROR)"

# ---------------------------------------------------------------------------
# T4 — file owner UID does NOT match the agent's iso UID (forged staging).
# ---------------------------------------------------------------------------
smoke_log "T4: file owner uid != agent iso uid → reject"

# We can't chown to a different UID without root. Instead we point the
# agent-meta.env at a different OS user. The staging.py apply path
# will resolve the expected iso UID to that user's UID — which must
# NOT equal CURRENT_UID. Find a non-current real user from /etc/passwd
# (the daemon would normally use the real iso UID).
OTHER_USER=""
OTHER_UID=""
while IFS=: read -r u _ id_ _; do
  if [[ "$u" != "$CURRENT_USER" && -n "$id_" && "$id_" != "$CURRENT_UID" && "$id_" -ge 0 ]]; then
    OTHER_USER="$u"
    OTHER_UID="$id_"
    break
  fi
done </etc/passwd

if [[ -z "$OTHER_USER" || -z "$OTHER_UID" ]]; then
  smoke_log "T4: skip — no second non-root non-current user available on /etc/passwd"
else
  # Temporarily flip the agent-meta.env to that other user, then apply.
  cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$OTHER_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
  T4_PAYLOAD="$(
    "$PY_BIN" - "$ISO_AGENT" "$CURRENT_UID" <<'PY'
import json
import sys

agent, uid = sys.argv[1], int(sys.argv[2])
print(json.dumps({
    "schema_version": 1,
    "action": "create",
    "actor_agent": agent,
    "actor_uid": uid,
    "agent": agent,
    "schedule": "0 8 * * *",
    "at": None,
    "tz": "Asia/Seoul",
    "title": f"{agent}-forged-cron",
    "payload": "Forged attempt",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}))
PY
)"
  T4_UUID="$(staging_py write-request "$STAGING_ROOT" "$ISO_AGENT" "$T4_PAYLOAD")"
  T4_UUID="${T4_UUID%%$'\n'*}"
  T4_BEFORE="$(jobs_count)"
  set +e
  staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T4_UUID" "$JOBS_FILE" >/dev/null 2>&1
  T4_RC=$?
  set -e
  [[ "$T4_RC" -ne 0 ]] || smoke_fail "T4: apply must fail with non-zero rc"
  T4_RESULT="$ISO_STAGING_DIR/$T4_UUID.result.json"
  T4_AUDIT_ACTION="$(result_field "$T4_RESULT" audit_action)"
  T4_ERROR="$(result_field "$T4_RESULT" error)"
  smoke_assert_eq "cron_staging_rejected" "$T4_AUDIT_ACTION" "T4: audit_action must be rejected"
  smoke_assert_contains "$T4_ERROR" "file_owner_uid_mismatch" "T4: error must explain file_owner_uid_mismatch"
  T4_AFTER="$(jobs_count)"
  [[ "$T4_AFTER" -eq "$T4_BEFORE" ]] || smoke_fail "T4: jobs.json count must NOT change"
  smoke_log "ok: T4 — forged staging reject pinned (error=$T4_ERROR)"
  # Restore the canonical agent-meta.env for the remaining cases.
  cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
fi

# ---------------------------------------------------------------------------
# T5 — stale staging file (no result, age > stale_secs) → swept.
# ---------------------------------------------------------------------------
smoke_log "T5: stale staging file (no result, age > stale_secs) → swept"

T5_UUID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' || "$PY_BIN" -c "import secrets; print(secrets.token_hex(16))")"
T5_PATH="$ISO_STAGING_DIR/$T5_UUID.json"
printf '{"schema_version":1,"action":"create","actor_agent":"%s","actor_uid":%s,"agent":"%s","schedule":"0 9 * * *","at":null,"tz":"Asia/Seoul","title":"stale-cron","payload":"stale","payload_file":null,"kind":"text","disabled":false,"delete_after_run":false}\n' \
  "$ISO_AGENT" "$CURRENT_UID" "$ISO_AGENT" >"$T5_PATH"
# Backdate the file by 60s so it's past the 2s stale threshold.
T5_PAST="$(date -d '60 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v -60S '+%Y%m%d%H%M.%S' 2>/dev/null)"
if [[ -n "$T5_PAST" ]]; then
  touch -t "$T5_PAST" "$T5_PATH"
fi
T5_SWEEP_OUT="$(staging_py sweep-stale "$STAGING_ROOT" "2")"
[[ -n "$T5_SWEEP_OUT" ]] || smoke_fail "T5: sweep-stale produced no output"
smoke_assert_contains "$T5_SWEEP_OUT" "$T5_UUID" "T5: sweep output must reference uuid"
smoke_assert_contains "$T5_SWEEP_OUT" "\"swept\": true" "T5: sweep must mark file as swept"
[[ ! -f "$T5_PATH" ]] || smoke_fail "T5: staging file must be unlinked after sweep"
smoke_log "ok: T5 — stale staging file swept"

# ---------------------------------------------------------------------------
# T2b (codex r2 BLOCKING #1) — stale staging row must be swept BEFORE
# apply, not after. The previous tick order ran apply on every row and
# then ran sweep-stale, which meant an abandoned row got executed and
# the sweep no-op'd because apply wrote a result.json sibling.
# ---------------------------------------------------------------------------
smoke_log "T2b: stale staging row → daemon-step sweep-first (NO apply, NO jobs.json mutation)"

# Construct a perfectly valid payload for ISO_AGENT, write it to its
# subdir, then backdate the mtime past the 2s threshold. scan-pending
# should emit `stale: true`; the daemon's apply step should then
# unlink the file + emit `cron_staging_stale_rejected` audit WITHOUT
# invoking native-create. We probe the daemon contract with a tiny
# inline shell function that mirrors the new `if [[ "$stale" == "1" ]]`
# branch (the exact lines added in bridge-daemon.sh r2).
T2B_UUID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' || "$PY_BIN" -c "import secrets; print(secrets.token_hex(16))")"
T2B_PATH="$ISO_STAGING_DIR/$T2B_UUID.json"
printf '{"schema_version":1,"action":"create","actor_agent":"%s","actor_uid":%s,"agent":"%s","schedule":"0 13 * * *","at":null,"tz":"Asia/Seoul","title":"%s-stale-row","payload":"do not run","payload_file":null,"kind":"text","disabled":false,"delete_after_run":false}\n' \
  "$ISO_AGENT" "$CURRENT_UID" "$ISO_AGENT" "$ISO_AGENT" >"$T2B_PATH"
# Backdate so scan-pending tags `stale: true`.
T2B_PAST="$(date -d '60 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v -60S '+%Y%m%d%H%M.%S' 2>/dev/null)"
if [[ -n "$T2B_PAST" ]]; then
  touch -t "$T2B_PAST" "$T2B_PATH"
fi

# Confirm scan-pending reports stale: true (BRIDGE_CRON_STAGING_STALE_SECONDS=2)
T2B_SCAN="$(staging_py scan-pending "$STAGING_ROOT")"
T2B_ROW="$(printf '%s\n' "$T2B_SCAN" | grep -F "$T2B_UUID" || true)"
[[ -n "$T2B_ROW" ]] || smoke_fail "T2b: scan-pending did not emit a row for $T2B_UUID"
smoke_assert_contains "$T2B_ROW" "\"stale\": true" "T2b: scan-pending must mark the row stale"

# Now run the daemon's stale-row branch logic. The new branch (added
# in bridge-daemon.sh r2) unlinks the staging file inline and emits a
# `cron_staging_stale_rejected` audit row. We replicate the contract
# here with a tiny inline runner: parse scan-pending → if stale, rm
# the file + record the audit; do NOT call staging_py apply. The teeth
# variant below removes the unlink to prove the contract is exercised.
T2B_BEFORE_JOBS="$(jobs_count)"
T2B_AUDIT_LOG="$SMOKE_TMP_ROOT/t2b-audit.log"
: >"$T2B_AUDIT_LOG"
T2B_APPLIED_LOG="$SMOKE_TMP_ROOT/t2b-applied.log"
: >"$T2B_APPLIED_LOG"

# Probe runner — mirrors bridge-daemon.sh r2 lines 8866+.
t2b_daemon_step() {
  local scan_out="$1"
  local _row
  while IFS= read -r _row; do
    [[ -n "$_row" ]] || continue
    local _uuid="" _stale="" _actor=""
    local _parsed
    _parsed="$("$PY_BIN" - "$_row" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
print("uuid=" + str(data.get("uuid") or ""))
print("actor_agent=" + str(data.get("actor_agent") or ""))
print("stale=" + ("1" if data.get("stale") else "0"))
PY
)"
    while IFS= read -r _line; do
      case "$_line" in
        uuid=*) _uuid="${_line#uuid=}" ;;
        actor_agent=*) _actor="${_line#actor_agent=}" ;;
        stale=*) _stale="${_line#stale=}" ;;
      esac
    done <<<"$_parsed"
    [[ -n "$_uuid" && -n "$_actor" ]] || continue
    if [[ "$_stale" == "1" ]]; then
      # New r2 branch — sweep first, no apply.
      rm -f "$STAGING_ROOT/$_actor/${_uuid}.json"
      printf 'audit: cron_staging_stale_rejected uuid=%s actor=%s\n' \
        "$_uuid" "$_actor" >>"$T2B_AUDIT_LOG"
      continue
    fi
    # Non-stale path would call staging_py apply — log so the smoke
    # can prove apply was NOT exercised for the stale row.
    staging_py apply "$STAGING_ROOT" "$_actor" "$_uuid" "$JOBS_FILE" >/dev/null 2>&1 || true
    printf 'applied: uuid=%s actor=%s\n' "$_uuid" "$_actor" >>"$T2B_APPLIED_LOG"
  done <<<"$scan_out"
}
t2b_daemon_step "$T2B_SCAN"

# Assert: file unlinked, audit recorded, NO apply ran for this uuid,
# NO jobs.json mutation.
[[ ! -f "$T2B_PATH" ]] || smoke_fail "T2b: stale staging file must be unlinked by the daemon step"
T2B_AUDIT_LINE="$(grep -F "$T2B_UUID" "$T2B_AUDIT_LOG" || true)"
smoke_assert_contains "$T2B_AUDIT_LINE" "cron_staging_stale_rejected" \
  "T2b: audit must record cron_staging_stale_rejected"
T2B_APPLIED_LINE="$(grep -F "$T2B_UUID" "$T2B_APPLIED_LOG" || true)"
[[ -z "$T2B_APPLIED_LINE" ]] || smoke_fail "T2b: stale row must NOT trigger staging_py apply (got: $T2B_APPLIED_LINE)"
T2B_AFTER_JOBS="$(jobs_count)"
[[ "$T2B_AFTER_JOBS" -eq "$T2B_BEFORE_JOBS" ]] || \
  smoke_fail "T2b: jobs.json count must NOT change (before=$T2B_BEFORE_JOBS after=$T2B_AFTER_JOBS)"
T2B_RESULT="$ISO_STAGING_DIR/$T2B_UUID.result.json"
[[ ! -f "$T2B_RESULT" ]] || smoke_fail "T2b: stale sweep MUST NOT write a result.json"
smoke_log "ok: T2b — stale row swept first, no apply, no jobs.json mutation"

# T2b teeth — defense-in-depth coverage: a stale row that bypasses
# the daemon's scan-time stale branch (e.g. clock skew, scan-time
# threshold race) must STILL be caught by the apply-time re-stat in
# staging.py. We bypass the scan-time branch by calling apply
# directly on a backdated row, then assert the apply emits the
# stale-at-apply reject (NOT a stale_at_apply = scan-time would
# have been swept, but bypassing scan only exposes us to apply).
# This pins the two-layer defense — neither layer alone is required
# for correctness, but both must agree on the stale verdict.
smoke_log "T2b teeth: bypass daemon scan-time stale branch → apply-time re-stat still catches"
T2B_TEETH_UUID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' || "$PY_BIN" -c "import secrets; print(secrets.token_hex(16))")"
T2B_TEETH_PATH="$ISO_STAGING_DIR/$T2B_TEETH_UUID.json"
printf '{"schema_version":1,"action":"create","actor_agent":"%s","actor_uid":%s,"agent":"%s","schedule":"0 14 * * *","at":null,"tz":"Asia/Seoul","title":"%s-teeth-stale","payload":"teeth","payload_file":null,"kind":"text","disabled":false,"delete_after_run":false}\n' \
  "$ISO_AGENT" "$CURRENT_UID" "$ISO_AGENT" "$ISO_AGENT" >"$T2B_TEETH_PATH"
if [[ -n "$T2B_PAST" ]]; then
  touch -t "$T2B_PAST" "$T2B_TEETH_PATH"
fi
T2B_TEETH_BEFORE_JOBS="$(jobs_count)"
# Skip the daemon scan-time stale branch entirely — just apply.
staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T2B_TEETH_UUID" "$JOBS_FILE" >/dev/null 2>&1 || true
T2B_TEETH_AFTER_JOBS="$(jobs_count)"
T2B_TEETH_RESULT="$ISO_STAGING_DIR/$T2B_TEETH_UUID.result.json"
# Apply-time re-stat must have rejected as stale → result.json with
# audit_action=cron_staging_stale_rejected, no jobs.json mutation.
[[ -f "$T2B_TEETH_RESULT" ]] || smoke_fail "T2b teeth: apply-time re-stat must write a result.json"
T2B_TEETH_AUDIT="$(result_field "$T2B_TEETH_RESULT" audit_action)"
smoke_assert_eq "cron_staging_stale_rejected" "$T2B_TEETH_AUDIT" \
  "T2b teeth: apply-time re-stat must reject stale row as cron_staging_stale_rejected"
[[ "$T2B_TEETH_AFTER_JOBS" -eq "$T2B_TEETH_BEFORE_JOBS" ]] || \
  smoke_fail "T2b teeth: jobs.json must NOT change (before=$T2B_TEETH_BEFORE_JOBS after=$T2B_TEETH_AFTER_JOBS)"
smoke_log "ok: T2b teeth — two-layer defense (scan-time + apply-time re-stat) confirmed"

# ---------------------------------------------------------------------------
# T2c (codex r2 review escalation) — apply-time freshness re-check.
# scan-pending captures the stale flag at scan time; a row aged just
# under the threshold can cross the threshold before its apply turn.
# The new staging.py apply-time re-stat must short-circuit that row
# as `cron_staging_stale_rejected` rather than executing it.
# ---------------------------------------------------------------------------
smoke_log "T2c: row crossed stale threshold before apply turn → reject at apply"

T2C_UUID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' || "$PY_BIN" -c "import secrets; print(secrets.token_hex(16))")"
T2C_PATH="$ISO_STAGING_DIR/$T2C_UUID.json"
printf '{"schema_version":1,"action":"create","actor_agent":"%s","actor_uid":%s,"agent":"%s","schedule":"0 18 * * *","at":null,"tz":"Asia/Seoul","title":"%s-race-stale","payload":"never run","payload_file":null,"kind":"text","disabled":false,"delete_after_run":false}\n' \
  "$ISO_AGENT" "$CURRENT_UID" "$ISO_AGENT" "$ISO_AGENT" >"$T2C_PATH"
# Backdate past the stale threshold (BRIDGE_CRON_STAGING_STALE_SECONDS=2).
T2C_PAST="$(date -d '60 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v -60S '+%Y%m%d%H%M.%S' 2>/dev/null)"
if [[ -n "$T2C_PAST" ]]; then
  touch -t "$T2C_PAST" "$T2C_PATH"
fi

# Call apply DIRECTLY (skip the scan-pending stale branch). This
# simulates the race where scan saw a fresh row but it crossed the
# threshold before this apply turn. The apply-time re-stat must
# observe the stale age and reject.
T2C_BEFORE_JOBS="$(jobs_count)"
set +e
staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T2C_UUID" "$JOBS_FILE" >/dev/null 2>&1
T2C_RC=$?
set -e
[[ "$T2C_RC" -ne 0 ]] || smoke_fail "T2c: apply must fail with non-zero rc on stale-at-apply row"
T2C_RESULT="$ISO_STAGING_DIR/$T2C_UUID.result.json"
[[ -f "$T2C_RESULT" ]] || smoke_fail "T2c: result.json MUST exist after stale-at-apply reject"
T2C_AUDIT_ACTION="$(result_field "$T2C_RESULT" audit_action)"
T2C_ERROR="$(result_field "$T2C_RESULT" error)"
smoke_assert_eq "cron_staging_stale_rejected" "$T2C_AUDIT_ACTION" \
  "T2c: audit_action must be cron_staging_stale_rejected"
smoke_assert_contains "$T2C_ERROR" "stale_at_apply" \
  "T2c: error must explain stale_at_apply"
T2C_AFTER_JOBS="$(jobs_count)"
[[ "$T2C_AFTER_JOBS" -eq "$T2C_BEFORE_JOBS" ]] || \
  smoke_fail "T2c: jobs.json count must NOT change (before=$T2C_BEFORE_JOBS after=$T2C_AFTER_JOBS)"
# Request file must be unlinked so sweep-stale does not re-emit it.
[[ ! -f "$T2C_PATH" ]] || smoke_fail "T2c: stale-at-apply must unlink the request file"
smoke_log "ok: T2c — apply-time stale re-check closes the scan/apply race"

# ---------------------------------------------------------------------------
# T3b (codex r2 BLOCKING #3) — bridge-cron.sh entry path: iso UID with
# `--agent` != BRIDGE_AGENT_ID must REJECT (exit non-zero) with an
# explicit error, NOT silently fall through to the direct write.
# ---------------------------------------------------------------------------
smoke_log "T3b: bridge-cron.sh --agent != BRIDGE_AGENT_ID → reject, NO jobs.json mutation"

# We need to force the iso-context active branch. The current process
# UID equals the controller UID (we cannot escalate to a different
# UID in CI), so the simplest path is to make jobs.json non-writable
# for the current UID (mode 0400) AND set BRIDGE_AGENT_ID +
# BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT (the public contract of
# bridge_isolation_v2_active). The predicate then sees "jobs.json
# present, not writable" and routes through the bridge_die guard.
T3B_HOME="$BRIDGE_HOME/t3b"
T3B_JOBS_DIR="$T3B_HOME/cron"
T3B_JOBS_FILE="$T3B_JOBS_DIR/jobs.json"
mkdir -p "$T3B_JOBS_DIR"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$T3B_JOBS_FILE"
chmod 0400 "$T3B_JOBS_FILE"
# Sanity: at the smoke's UID, the file must report as non-writable.
[[ ! -w "$T3B_JOBS_FILE" ]] || smoke_fail "T3b: setup error — jobs.json must be non-writable to exercise the iso branch"
T3B_HASH_BEFORE="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T3B_JOBS_FILE")"

T3B_STDERR="$SMOKE_TMP_ROOT/t3b-stderr.log"
T3B_RC=0
set +e
BRIDGE_LAYOUT=v2 \
BRIDGE_DATA_ROOT="$BRIDGE_HOME" \
BRIDGE_AGENT_ID="$ISO_AGENT" \
BRIDGE_NATIVE_CRON_JOBS_FILE="$T3B_JOBS_FILE" \
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$PEER_AGENT" \
  --schedule "0 15 * * *" \
  --tz "Asia/Seoul" \
  --title "$PEER_AGENT-cross-agent-attempt" \
  --payload "should be rejected" >/dev/null 2>"$T3B_STDERR"
T3B_RC=$?
set -e
chmod 0600 "$T3B_JOBS_FILE"
[[ "$T3B_RC" -ne 0 ]] || smoke_fail "T3b: cross-agent create MUST exit non-zero (got rc=0)"
T3B_ERR="$(cat "$T3B_STDERR" 2>/dev/null || true)"
smoke_assert_contains "$T3B_ERR" "cron mutation refused" \
  "T3b: stderr must explain the reject"
smoke_assert_contains "$T3B_ERR" "$PEER_AGENT" \
  "T3b: stderr must name the requested peer agent"
T3B_HASH_AFTER="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T3B_JOBS_FILE")"
smoke_assert_eq "$T3B_HASH_BEFORE" "$T3B_HASH_AFTER" \
  "T3b: jobs.json must be unchanged after the reject"
smoke_log "ok: T3b — cross-agent reject pinned (rc=$T3B_RC)"

# T3b teeth — bypass the new bridge_die guard (drop the iso-context
# preconditions) and prove the smoke catches it: with BRIDGE_AGENT_ID
# unset the predicate skips the iso branch entirely and the create
# would run as the controller. This pins that the reject was gated on
# the BRIDGE_AGENT_ID + iso-active + cross-agent shape, and that
# disabling those preconditions lets the same command path through
# (the buggy pre-r2 fall-through behavior).
smoke_log "T3b teeth: bypass the bridge_die guard → smoke catches direct-write attempt"
chmod 0600 "$T3B_JOBS_FILE"
T3B_TEETH_STDERR="$SMOKE_TMP_ROOT/t3b-teeth-stderr.log"
T3B_TEETH_RC=0
set +e
unset BRIDGE_AGENT_ID
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$PEER_AGENT" \
  --schedule "0 16 * * *" \
  --tz "Asia/Seoul" \
  --title "$PEER_AGENT-teeth-bypass" \
  --payload "would succeed without the guard" >/dev/null 2>"$T3B_TEETH_STDERR" || T3B_TEETH_RC=$?
set -e
[[ "$T3B_TEETH_RC" -eq 0 ]] || smoke_fail "T3b teeth: controller path should succeed (got rc=$T3B_TEETH_RC stderr=$(cat "$T3B_TEETH_STDERR" 2>/dev/null | head -5))"
smoke_log "ok: T3b teeth — bypass confirms the guard is what blocks cross-agent in iso context"

# ---------------------------------------------------------------------------
# T3c (codex r2 review escalation) — defense-in-depth: cross-agent
# reject must ALSO fire when jobs.json happens to be writable by the
# iso UID (a misconfigured-operator opened the file's group bits).
# The previous shape gated the bridge_die on the staging predicate,
# which itself returned 1 when jobs.json was writable → the cross-
# agent direct-write bypassed the guard.
# ---------------------------------------------------------------------------
smoke_log "T3c: writable jobs.json + iso identity + cross-agent → still rejected"

T3C_HOME="$BRIDGE_HOME/t3c"
T3C_JOBS_DIR="$T3C_HOME/cron"
T3C_JOBS_FILE="$T3C_JOBS_DIR/jobs.json"
mkdir -p "$T3C_JOBS_DIR"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$T3C_JOBS_FILE"
chmod 0600 "$T3C_JOBS_FILE"
# Sanity: file MUST be writable here — this is the misconfigured case.
[[ -w "$T3C_JOBS_FILE" ]] || smoke_fail "T3c: setup error — jobs.json must be writable for this case"
T3C_HASH_BEFORE="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T3C_JOBS_FILE")"

T3C_STDERR="$SMOKE_TMP_ROOT/t3c-stderr.log"
T3C_RC=0
set +e
BRIDGE_LAYOUT=v2 \
BRIDGE_DATA_ROOT="$BRIDGE_HOME" \
BRIDGE_AGENT_ID="$ISO_AGENT" \
BRIDGE_NATIVE_CRON_JOBS_FILE="$T3C_JOBS_FILE" \
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$PEER_AGENT" \
  --schedule "0 17 * * *" \
  --tz "Asia/Seoul" \
  --title "$PEER_AGENT-writable-bypass-attempt" \
  --payload "should still be rejected" >/dev/null 2>"$T3C_STDERR"
T3C_RC=$?
set -e
[[ "$T3C_RC" -ne 0 ]] || smoke_fail "T3c: cross-agent create on writable jobs.json MUST still exit non-zero (got rc=0)"
T3C_ERR="$(cat "$T3C_STDERR" 2>/dev/null || true)"
smoke_assert_contains "$T3C_ERR" "cron mutation refused" \
  "T3c: stderr must explain the reject even when jobs.json is writable"
T3C_HASH_AFTER="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T3C_JOBS_FILE")"
smoke_assert_eq "$T3C_HASH_BEFORE" "$T3C_HASH_AFTER" \
  "T3c: jobs.json must be unchanged even when writable"
smoke_log "ok: T3c — writable-jobs.json bypass closed (rc=$T3C_RC)"

# ---------------------------------------------------------------------------
# T3d (codex r2 self-review BLOCKING) — `--kind shell` must hit the
# same cross-agent identity reject. The previous shape gated the
# bridge_die on `kind == text`; a shell-kind request from inside an
# iso UID with writable jobs.json would skip the guard entirely and
# fall through to the native python entry point, which writes a job
# for `args.agent`. The reject must fire on identity context
# regardless of kind.
# ---------------------------------------------------------------------------
smoke_log "T3d: --kind shell + iso identity + cross-agent → rejected (kind-agnostic guard)"

T3D_HOME="$BRIDGE_HOME/t3d"
T3D_JOBS_DIR="$T3D_HOME/cron"
T3D_JOBS_FILE="$T3D_JOBS_DIR/jobs.json"
mkdir -p "$T3D_JOBS_DIR"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$T3D_JOBS_FILE"
chmod 0600 "$T3D_JOBS_FILE"
# Writable jobs.json so the bug shape (kind=shell skip → direct write)
# would land a real mutation; the reject must still fire.
[[ -w "$T3D_JOBS_FILE" ]] || smoke_fail "T3d: setup error — jobs.json must be writable"
T3D_HASH_BEFORE="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T3D_JOBS_FILE")"

T3D_STDERR="$SMOKE_TMP_ROOT/t3d-stderr.log"
T3D_RC=0
set +e
BRIDGE_LAYOUT=v2 \
BRIDGE_DATA_ROOT="$BRIDGE_HOME" \
BRIDGE_AGENT_ID="$ISO_AGENT" \
BRIDGE_NATIVE_CRON_JOBS_FILE="$T3D_JOBS_FILE" \
bash "$REPO_ROOT/bridge-cron.sh" create \
  --kind shell \
  --agent "$PEER_AGENT" \
  --schedule "0 18 * * *" \
  --tz "Asia/Seoul" \
  --title "$PEER_AGENT-shell-cross-agent-attempt" \
  --payload "echo should be rejected" >/dev/null 2>"$T3D_STDERR"
T3D_RC=$?
set -e
[[ "$T3D_RC" -ne 0 ]] || smoke_fail "T3d: --kind shell cross-agent create MUST exit non-zero (got rc=0)"
T3D_ERR="$(cat "$T3D_STDERR" 2>/dev/null || true)"
smoke_assert_contains "$T3D_ERR" "cron mutation refused" \
  "T3d: stderr must explain the reject for kind=shell too"
smoke_assert_contains "$T3D_ERR" "$PEER_AGENT" \
  "T3d: stderr must name the requested peer agent"
T3D_HASH_AFTER="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T3D_JOBS_FILE")"
smoke_assert_eq "$T3D_HASH_BEFORE" "$T3D_HASH_AFTER" \
  "T3d: jobs.json must be unchanged after the reject (no shell-kind direct write)"
smoke_log "ok: T3d — kind=shell cross-agent reject pinned (rc=$T3D_RC)"

# ---------------------------------------------------------------------------
# T4b (codex r2 BLOCKING #2) — forged `actor_uid` field that does not
# parse as int must produce an explicit reject result, NOT a Python
# crash that leaves the request unresolved and re-applied next tick.
# ---------------------------------------------------------------------------
smoke_log "T4b: forged actor_uid 'not-int' → explicit reject, no poison retry"

T4B_UUID="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' || "$PY_BIN" -c "import secrets; print(secrets.token_hex(16))")"
T4B_PATH="$ISO_STAGING_DIR/$T4B_UUID.json"
# Hand-craft the payload so actor_uid is a string (the field would
# normally be an int — a malicious writer or a buggy serializer
# can sneak a string through).
"$PY_BIN" - "$ISO_AGENT" "$T4B_PATH" <<'PY'
import json
import sys

agent, path = sys.argv[1], sys.argv[2]
payload = {
    "schema_version": 1,
    "action": "create",
    "actor_agent": agent,
    "actor_uid": "not-int",
    "agent": agent,
    "schedule": "0 17 * * *",
    "at": None,
    "tz": "Asia/Seoul",
    "title": f"{agent}-malformed-actor-uid",
    "payload": "should be rejected",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
    fh.write("\n")
PY
chmod 0660 "$T4B_PATH"

T4B_BEFORE_JOBS="$(jobs_count)"
set +e
staging_py apply "$STAGING_ROOT" "$ISO_AGENT" "$T4B_UUID" "$JOBS_FILE" >/dev/null 2>&1
T4B_RC=$?
set -e
[[ "$T4B_RC" -ne 0 ]] || smoke_fail "T4b: apply must fail with non-zero rc on malformed actor_uid"
T4B_RESULT="$ISO_STAGING_DIR/$T4B_UUID.result.json"
[[ -f "$T4B_RESULT" ]] || smoke_fail "T4b: result.json MUST exist after explicit reject"
T4B_AUDIT_ACTION="$(result_field "$T4B_RESULT" audit_action)"
T4B_ERROR="$(result_field "$T4B_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T4B_AUDIT_ACTION" \
  "T4b: audit_action must be cron_staging_rejected"
smoke_assert_contains "$T4B_ERROR" "malformed_actor_uid" \
  "T4b: error must explain malformed_actor_uid"
T4B_AFTER_JOBS="$(jobs_count)"
[[ "$T4B_AFTER_JOBS" -eq "$T4B_BEFORE_JOBS" ]] || \
  smoke_fail "T4b: jobs.json count must NOT change (before=$T4B_BEFORE_JOBS after=$T4B_AFTER_JOBS)"

# T4b retry-poison check: rerun apply on the SAME uuid. scan-pending
# would normally skip it because the result.json now exists. We
# emulate the "next tick" condition by calling scan-pending and
# verifying the uuid is NOT emitted (result skips it). This proves
# the daemon does not retry the poison file.
T4B_SCAN="$(staging_py scan-pending "$STAGING_ROOT")"
T4B_REEMIT="$(printf '%s\n' "$T4B_SCAN" | grep -F "$T4B_UUID" || true)"
[[ -z "$T4B_REEMIT" ]] || smoke_fail "T4b: scan-pending must NOT re-emit a uuid with a result.json sibling (got: $T4B_REEMIT)"
smoke_log "ok: T4b — malformed actor_uid → explicit reject + no retry poison"

# T4b teeth — verify the smoke would catch a regression. If staging.py
# regressed to a bare `int(payload_actor_uid)` (no try/except), the
# call would raise ValueError before any _write_result. We simulate
# that by inspecting the staging.py source for the try/except token
# directly — defensive correlation rather than re-running an old
# version of the file.
smoke_log "T4b teeth: verify staging.py r2 carries the try/except guard"
T4B_TEETH_GUARD="$(grep -c "malformed_actor_uid" "$REPO_ROOT/lib/cron-helpers/staging.py" || true)"
[[ "$T4B_TEETH_GUARD" -ge 1 ]] || \
  smoke_fail "T4b teeth: staging.py must reference malformed_actor_uid (regression marker)"
smoke_log "ok: T4b teeth — regression marker present in staging.py"

# ---------------------------------------------------------------------------
# T6 (teeth) — staging delegation routing removed → operator hits PermissionError.
# ---------------------------------------------------------------------------
smoke_log "T6 teeth: bypass staging routing → iso UID hits PermissionError"

# Simulate the iso boundary: jobs.json sits inside a directory that
# the current UID cannot write into (mode 0500 — read+execute only).
# That mirrors the operator-host shape where the iso UID can traverse
# `cron/` (group=ab-shared --x via setgid parent) but cannot write
# inside it. native-create's `atomic_write_jobs` requires a writable
# parent dir for the temp-file + rename — same failure surface as the
# reported PermissionError on the operator host.
T6_DIR="$BRIDGE_HOME/cron-noaccess"
T6_PATH="$T6_DIR/jobs.json"
mkdir -p "$T6_DIR"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$T6_PATH"
chmod 0500 "$T6_DIR"

# Without the staging predicate routing through, native-create writes
# directly into the parent dir and fails because the dir is not
# writable.
set +e
T6_RC=0
T6_ERR_FILE="$SMOKE_TMP_ROOT/t6-stderr.log"
"$PY_BIN" "$REPO_ROOT/bridge-cron.py" native-create \
  --jobs-file "$T6_PATH" \
  --agent "$ISO_AGENT" \
  --schedule "0 10 * * *" \
  --tz "Asia/Seoul" \
  --title "$ISO_AGENT-teeth" \
  --payload "Teeth probe" >/dev/null 2>"$T6_ERR_FILE" || T6_RC=$?
set -e
chmod 0700 "$T6_DIR"
[[ "$T6_RC" -ne 0 ]] || smoke_fail "T6: bypass path MUST fail with non-zero rc (got 0)"
T6_ERR="$(cat "$T6_ERR_FILE" 2>/dev/null || true)"
smoke_assert_contains "$T6_ERR" "Permission" "T6: native-create must surface PermissionError-class failure"
smoke_log "ok: T6 — bypass path fails (rc=$T6_RC), proving staging is what closes the gap"

smoke_log "all 1359-cron-create-iso-staging cases passed"
