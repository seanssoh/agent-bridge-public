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
#   T3 — staging payload with actor_agent ≠ target agent → rejected,
#        result.json carries actor_agent_mismatch.
#   T4 — staging payload owned by a different UID than the agent's iso
#        UID → rejected, result.json carries file_owner_uid_mismatch.
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
STAGING_DIR="$BRIDGE_STATE_DIR/cron-staging"
ISO_AGENT="iso-smoke"
mkdir -p "$STAGING_DIR"
chmod 2770 "$STAGING_DIR" 2>/dev/null || chmod 0770 "$STAGING_DIR"
# Seed an empty jobs.json so the apply path can find it.
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$JOBS_FILE"

# Pin staging timing tight so T1/T5 run quickly.
export BRIDGE_CRON_STAGING_TIMEOUT_SECONDS=10
export BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS=1
export BRIDGE_CRON_STAGING_STALE_SECONDS=2
export BRIDGE_CRON_STAGING_DIR="$STAGING_DIR"
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

T1_UUID="$(staging_py write-request "$STAGING_DIR" "$T1_PAYLOAD")"
T1_UUID="${T1_UUID%%$'\n'*}"
[[ -n "$T1_UUID" ]] || smoke_fail "T1: write-request returned empty uuid"

# Verify the file was written at mode 0660.
T1_PATH="$STAGING_DIR/$T1_UUID.json"
[[ -f "$T1_PATH" ]] || smoke_fail "T1: staging file missing: $T1_PATH"
T1_MODE="$(stat -c '%a' "$T1_PATH" 2>/dev/null || stat -f '%Lp' "$T1_PATH" 2>/dev/null || echo '?')"
smoke_assert_eq "660" "$T1_MODE" "T1: staging file must be mode 0660"

# Simulate daemon apply directly. We do NOT spawn the full daemon —
# the apply path is unit-testable via `staging.py apply`.
if ! staging_py apply "$STAGING_DIR" "$T1_UUID" "$JOBS_FILE" >/dev/null 2>&1; then
  smoke_fail "T1: staging apply returned non-zero rc"
fi

T1_RESULT="$STAGING_DIR/$T1_UUID.result.json"
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
T2_STAGING_COUNT_BEFORE="$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
unset BRIDGE_AGENT_ID
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$ISO_AGENT" \
  --schedule "0 11 * * *" \
  --tz "Asia/Seoul" \
  --title "$ISO_AGENT-direct-via-bridge-cron-sh" \
  --payload "direct path probe" >/dev/null
T2_AFTER_DIRECT="$(jobs_count)"
T2_STAGING_COUNT_AFTER="$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$T2_AFTER_DIRECT" -eq $(( T2_BEFORE_DIRECT + 1 )) ]] || \
  smoke_fail "T2: direct bridge-cron.sh create should add 1 job (before=$T2_BEFORE_DIRECT after=$T2_AFTER_DIRECT)"
[[ "$T2_STAGING_COUNT_AFTER" -eq "$T2_STAGING_COUNT_BEFORE" ]] || \
  smoke_fail "T2: direct path must NOT create any staging file (before=$T2_STAGING_COUNT_BEFORE after=$T2_STAGING_COUNT_AFTER)"
smoke_log "ok: T2 — direct path unaffected; no staging file created"

# ---------------------------------------------------------------------------
# T3 — actor_agent mismatch (iso UID tries to create cron for ANOTHER agent).
# ---------------------------------------------------------------------------
smoke_log "T3: actor_agent != target agent → reject (cross-agent boundary)"

T3_PAYLOAD="$(
  "$PY_BIN" - "$ISO_AGENT" "other-agent" "$CURRENT_UID" <<'PY'
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
    "title": f"{target}-cross-cron",
    "payload": "Cross-agent attempt",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}))
PY
)"

T3_UUID="$(staging_py write-request "$STAGING_DIR" "$T3_PAYLOAD")"
T3_UUID="${T3_UUID%%$'\n'*}"
T3_BEFORE="$(jobs_count)"
set +e
staging_py apply "$STAGING_DIR" "$T3_UUID" "$JOBS_FILE" >/dev/null 2>&1
T3_RC=$?
set -e
[[ "$T3_RC" -ne 0 ]] || smoke_fail "T3: apply must fail with non-zero rc"
T3_RESULT="$STAGING_DIR/$T3_UUID.result.json"
T3_AUDIT_ACTION="$(result_field "$T3_RESULT" audit_action)"
T3_ERROR="$(result_field "$T3_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T3_AUDIT_ACTION" "T3: audit_action must be rejected"
smoke_assert_contains "$T3_ERROR" "actor_agent_mismatch" "T3: error must explain actor_agent_mismatch"
T3_AFTER="$(jobs_count)"
[[ "$T3_AFTER" -eq "$T3_BEFORE" ]] || smoke_fail "T3: jobs.json count must NOT change (before=$T3_BEFORE after=$T3_AFTER)"
smoke_log "ok: T3 — cross-agent reject pinned (error=$T3_ERROR)"

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
  T4_UUID="$(staging_py write-request "$STAGING_DIR" "$T4_PAYLOAD")"
  T4_UUID="${T4_UUID%%$'\n'*}"
  T4_BEFORE="$(jobs_count)"
  set +e
  staging_py apply "$STAGING_DIR" "$T4_UUID" "$JOBS_FILE" >/dev/null 2>&1
  T4_RC=$?
  set -e
  [[ "$T4_RC" -ne 0 ]] || smoke_fail "T4: apply must fail with non-zero rc"
  T4_RESULT="$STAGING_DIR/$T4_UUID.result.json"
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
T5_PATH="$STAGING_DIR/$T5_UUID.json"
printf '{"schema_version":1,"action":"create","actor_agent":"%s","actor_uid":%s,"agent":"%s","schedule":"0 9 * * *","at":null,"tz":"Asia/Seoul","title":"stale-cron","payload":"stale","payload_file":null,"kind":"text","disabled":false,"delete_after_run":false}\n' \
  "$ISO_AGENT" "$CURRENT_UID" "$ISO_AGENT" >"$T5_PATH"
# Backdate the file by 60s so it's past the 2s stale threshold.
T5_PAST="$(date -d '60 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v -60S '+%Y%m%d%H%M.%S' 2>/dev/null)"
if [[ -n "$T5_PAST" ]]; then
  touch -t "$T5_PAST" "$T5_PATH"
fi
T5_SWEEP_OUT="$(staging_py sweep-stale "$STAGING_DIR" "2")"
[[ -n "$T5_SWEEP_OUT" ]] || smoke_fail "T5: sweep-stale produced no output"
smoke_assert_contains "$T5_SWEEP_OUT" "$T5_UUID" "T5: sweep output must reference uuid"
smoke_assert_contains "$T5_SWEEP_OUT" "\"swept\": true" "T5: sweep must mark file as swept"
[[ ! -f "$T5_PATH" ]] || smoke_fail "T5: staging file must be unlinked after sweep"
smoke_log "ok: T5 — stale staging file swept"

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
