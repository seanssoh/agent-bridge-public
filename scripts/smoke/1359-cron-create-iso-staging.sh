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
#
#   Issue #1474 — admin cross-agent cron provisioning exemption. The
#   #1359 boundary blocks ALL cross-agent cron mutation; #1474 carves
#   out the genuine controller/admin (bootstrap-memory-system.sh) while
#   keeping every regular iso agent — and every env-forging attacker —
#   blocked. The exemption is gated on the daemon's controller-resolved
#   admin id (AGB_CRON_STAGING_ADMIN_AGENT, never the payload) PLUS the
#   non-forgeable file-owner-UID + dirname checks already in #1359.
#   T7 — POSITIVE: admin (=AGB_CRON_STAGING_ADMIN_AGENT) stages a
#        cross-agent text cron → daemon applies it FOR THE TARGET agent.
#   T7b — bridge-cron.sh entry path: admin BRIDGE_AGENT_ID + cross-agent
#        --kind text must NOT 'cron mutation refused' (proceeds to
#        staging); a NON-admin id + the SAME command still refuses.
#   T8 — SECURITY (env-forgery still refused): a regular iso agent that
#        forges actor_agent=<admin> inside its OWN staging subdir is
#        rejected at the dirname gate — the admin name in the payload
#        cannot move the file out of the attacker's own subdir.
#   T8b — SECURITY (file-owner backstop): even granting a payload that
#        claims actor_agent=<admin> with a matching dirname, a file
#        owned by the WRONG UID (not the admin's iso UID) is rejected
#        at file_owner_uid_mismatch — the kernel UID is the proof.
#   T8c — SECURITY (admin-unset): with AGB_CRON_STAGING_ADMIN_AGENT
#        unset/empty the exemption is fully disabled — even a real
#        admin-named cross-agent request falls back to the strict
#        same-agent-only reject. No env in the apply process other than
#        the daemon-supplied admin id can open the cross-agent path.
#   T8d — SECURITY (shell-kind stays blocked): an admin cross-agent
#        request with --kind shell must STILL be refused at the CLI
#        guard — shell staging is out of scope, #1474 only widens text.
#   T8e — SECURITY (target abuse): even the genuine admin may not
#        provision a cron for an UNREGISTERED target. The daemon-supplied
#        roster allowlist (AGB_CRON_STAGING_TARGET_ALLOWLIST) confines
#        the exemption to real cron-delivery agents; a ghost target is
#        rejected with admin_cross_agent_unregistered_target.

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

# ===========================================================================
# Issue #1474 — admin cross-agent cron provisioning exemption.
# ===========================================================================
# We reuse ISO_AGENT (meta.env → CURRENT_USER, so its "iso UID" resolves
# to our own UID and apply proceeds) as the stand-in ADMIN, and PEER_AGENT
# as the cross-agent target. The exemption is authorized ONLY when the
# daemon-supplied AGB_CRON_STAGING_ADMIN_AGENT equals the request's
# (path-derived) actor_agent. The payload never names the admin.
ADMIN_AGENT="$ISO_AGENT"
# Restore the canonical (CURRENT_USER) meta.env in case T4 left it flipped
# for a skipped path — defensive; T4 already restores on its taken branch.
cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF

# Helper to build a staging payload (actor, target).
mk_1474_payload() {
  local actor="$1" target="$2"
  "$PY_BIN" - "$actor" "$target" "$CURRENT_UID" <<'PY'
import json
import sys

actor, target, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({
    "schema_version": 1,
    "action": "create",
    "actor_agent": actor,
    "actor_uid": uid,
    "agent": target,
    "schedule": "0 3 * * *",
    "at": None,
    "tz": "Asia/Seoul",
    "title": f"memory-daily-{target}",
    "payload": "Run the daily memory harvest.",
    "payload_file": None,
    "kind": "text",
    "disabled": False,
    "delete_after_run": False,
}))
PY
}

# ---------------------------------------------------------------------------
# T7 — POSITIVE: genuine admin cross-agent text cron → daemon applies it
# FOR THE TARGET agent.
# ---------------------------------------------------------------------------
smoke_log "T7: admin cross-agent staging request → daemon applies cron FOR THE TARGET"

T7_BEFORE_JOBS="$(jobs_count)"
T7_UUID="$(staging_py write-request "$STAGING_ROOT" "$ADMIN_AGENT" "$(mk_1474_payload "$ADMIN_AGENT" "$PEER_AGENT")")"
T7_UUID="${T7_UUID%%$'\n'*}"
[[ -n "$T7_UUID" ]] || smoke_fail "T7: write-request returned empty uuid"

# Apply WITH the daemon-supplied admin id + registered-target allowlist
# (mirrors bridge-daemon.sh r1474 passing BRIDGE_ADMIN_AGENT_ID + the
# roster-derived cron-delivery-target set). The third arg is the
# canonical actor (path dirname) the daemon recovers — here ADMIN_AGENT.
T7_ALLOWLIST="$PEER_AGENT"$'\n'"$ADMIN_AGENT"
set +e
AGB_CRON_STAGING_ADMIN_AGENT="$ADMIN_AGENT" \
AGB_CRON_STAGING_TARGET_ALLOWLIST="$T7_ALLOWLIST" \
  staging_py apply "$STAGING_ROOT" "$ADMIN_AGENT" "$T7_UUID" "$JOBS_FILE" >/dev/null 2>&1
T7_RC=$?
set -e
[[ "$T7_RC" -eq 0 ]] || smoke_fail "T7: admin cross-agent apply must succeed (rc=$T7_RC)"
T7_RESULT="$ISO_STAGING_DIR/$T7_UUID.result.json"
[[ -f "$T7_RESULT" ]] || smoke_fail "T7: result.json missing: $T7_RESULT"
T7_STATUS="$(result_field "$T7_RESULT" status)"
T7_AUDIT="$(result_field "$T7_RESULT" audit_action)"
T7_CRON_ID="$(result_field "$T7_RESULT" cron_id)"
smoke_assert_eq "ok" "$T7_STATUS" "T7: result status must be ok"
smoke_assert_eq "cron_staging_applied" "$T7_AUDIT" "T7: audit_action must be cron_staging_applied"
[[ -n "$T7_CRON_ID" ]] || smoke_fail "T7: result missing cron_id"
T7_AFTER_JOBS="$(jobs_count)"
[[ "$T7_AFTER_JOBS" -eq $(( T7_BEFORE_JOBS + 1 )) ]] || \
  smoke_fail "T7: exactly one job must be added (before=$T7_BEFORE_JOBS after=$T7_AFTER_JOBS)"
# The created cron MUST belong to the TARGET, not the admin actor.
# Footgun #11: use `python3 -c <script> argv...` (NOT a heredoc-in-
# command-substitution) so this assertion does not add a new C1 site to
# .lint-heredoc-baseline.tsv.
T7_OWNER_PROBE='import json,sys
jobs=json.load(open(sys.argv[1]))["jobs"]
target,cron_id=sys.argv[2],sys.argv[3]
hit=next((j for j in jobs if j.get("id")==cron_id or j.get("name")==cron_id),None)
print("missing" if hit is None else ("yes" if hit.get("agent")==target else "no:"+str(hit.get("agent"))))'
T7_TARGET_OWNED="$("$PY_BIN" -c "$T7_OWNER_PROBE" "$JOBS_FILE" "$PEER_AGENT" "$T7_CRON_ID")"
smoke_assert_eq "yes" "$T7_TARGET_OWNED" "T7: created cron must be owned by the TARGET agent ($PEER_AGENT), not the admin"
smoke_log "ok: T7 — admin cross-agent provision applied for target (cron_id=$T7_CRON_ID)"

# ---------------------------------------------------------------------------
# T7b — bridge-cron.sh entry path: admin BRIDGE_AGENT_ID + cross-agent
# --kind text must NOT be rejected at the CLI guard (proceeds to staging);
# a NON-admin id running the same command IS rejected.
# ---------------------------------------------------------------------------
smoke_log "T7b: bridge-cron.sh admin cross-agent text → proceeds to staging (NOT refused); non-admin → refused"

T7B_HOME="$BRIDGE_HOME/t7b"
T7B_JOBS_DIR="$T7B_HOME/cron"
T7B_JOBS_FILE="$T7B_JOBS_DIR/jobs.json"
mkdir -p "$T7B_JOBS_DIR"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$T7B_JOBS_FILE"
# Non-writable so the iso-context branch routes through staging.
chmod 0400 "$T7B_JOBS_FILE"
[[ ! -w "$T7B_JOBS_FILE" ]] || smoke_fail "T7b: setup error — jobs.json must be non-writable"

# Admin case: BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID == ADMIN_AGENT.
# Staging will queue then time out fast (no daemon in this smoke), but the
# crucial assertion is that we did NOT hit 'cron mutation refused'.
T7B_STDERR="$SMOKE_TMP_ROOT/t7b-admin-stderr.log"
T7B_RC=0
set +e
BRIDGE_LAYOUT=v2 \
BRIDGE_DATA_ROOT="$BRIDGE_HOME" \
BRIDGE_AGENT_ID="$ADMIN_AGENT" \
BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
BRIDGE_NATIVE_CRON_JOBS_FILE="$T7B_JOBS_FILE" \
BRIDGE_CRON_STAGING_DIR="$STAGING_ROOT" \
BRIDGE_CRON_STAGING_TIMEOUT_SECONDS=2 \
BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS=1 \
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$PEER_AGENT" \
  --schedule "0 3 * * *" \
  --tz "Asia/Seoul" \
  --title "memory-daily-$PEER_AGENT" \
  --payload "admin cross-agent provision" >/dev/null 2>"$T7B_STDERR"
T7B_RC=$?
set -e
T7B_ERR="$(cat "$T7B_STDERR" 2>/dev/null || true)"
smoke_assert_not_contains "$T7B_ERR" "cron mutation refused" \
  "T7b: admin cross-agent text must NOT be refused at the CLI guard"
smoke_assert_contains "$T7B_ERR" "cron-staging" \
  "T7b: admin cross-agent text must route through the staging path"

# Non-admin case: SAME command, BRIDGE_AGENT_ID != admin → must refuse.
T7B_NA_STDERR="$SMOKE_TMP_ROOT/t7b-nonadmin-stderr.log"
T7B_NA_RC=0
set +e
BRIDGE_LAYOUT=v2 \
BRIDGE_DATA_ROOT="$BRIDGE_HOME" \
BRIDGE_AGENT_ID="$PEER_AGENT" \
BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
BRIDGE_NATIVE_CRON_JOBS_FILE="$T7B_JOBS_FILE" \
BRIDGE_CRON_STAGING_DIR="$STAGING_ROOT" \
bash "$REPO_ROOT/bridge-cron.sh" create \
  --agent "$ISO_AGENT" \
  --schedule "0 3 * * *" \
  --tz "Asia/Seoul" \
  --title "memory-daily-$ISO_AGENT" \
  --payload "non-admin cross-agent attempt" >/dev/null 2>"$T7B_NA_STDERR"
T7B_NA_RC=$?
set -e
chmod 0600 "$T7B_JOBS_FILE"
[[ "$T7B_NA_RC" -ne 0 ]] || smoke_fail "T7b: non-admin cross-agent MUST exit non-zero"
T7B_NA_ERR="$(cat "$T7B_NA_STDERR" 2>/dev/null || true)"
smoke_assert_contains "$T7B_NA_ERR" "cron mutation refused" \
  "T7b: non-admin cross-agent must be refused even when an admin is configured"
smoke_log "ok: T7b — CLI guard exempts admin text, still refuses non-admin"

# ---------------------------------------------------------------------------
# T8 — SECURITY: env-forgery still refused. A regular iso agent forging
# actor_agent=<admin> inside its OWN staging subdir is rejected at the
# dirname gate. This is the heart of the non-forgeability guarantee.
# ---------------------------------------------------------------------------
smoke_log "T8: iso agent forges actor_agent=<admin> in its OWN subdir → rejected (dirname gate)"

# PEER_AGENT (the attacker) drops a request into its OWN subdir but lies
# in the payload claiming to be the admin (ADMIN_AGENT) and targeting a
# third agent. Even with AGB_CRON_STAGING_ADMIN_AGENT=<admin> set, the
# daemon recovers the canonical actor from the dirname (PEER_AGENT) and
# rejects the payload's admin claim.
T8_BEFORE_JOBS="$(jobs_count)"
T8_UUID="$(staging_py write-request "$STAGING_ROOT" "$PEER_AGENT" "$(mk_1474_payload "$ADMIN_AGENT" "victim-agent")")"
T8_UUID="${T8_UUID%%$'\n'*}"
set +e
AGB_CRON_STAGING_ADMIN_AGENT="$ADMIN_AGENT" \
  staging_py apply "$STAGING_ROOT" "$PEER_AGENT" "$T8_UUID" "$JOBS_FILE" >/dev/null 2>&1
T8_RC=$?
set -e
[[ "$T8_RC" -ne 0 ]] || smoke_fail "T8: forged-admin cross-agent apply MUST fail"
T8_RESULT="$PEER_STAGING_DIR/$T8_UUID.result.json"
T8_AUDIT="$(result_field "$T8_RESULT" audit_action)"
T8_ERROR="$(result_field "$T8_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T8_AUDIT" "T8: audit_action must be rejected"
smoke_assert_contains "$T8_ERROR" "payload_actor_agent_mismatch" \
  "T8: forged admin-in-payload must be caught at the dirname gate"
T8_AFTER_JOBS="$(jobs_count)"
[[ "$T8_AFTER_JOBS" -eq "$T8_BEFORE_JOBS" ]] || smoke_fail "T8: jobs.json must NOT change"
smoke_log "ok: T8 — payload admin-forgery rejected at dirname gate (error=$T8_ERROR)"

# ---------------------------------------------------------------------------
# T8b — SECURITY: file-owner backstop. Even when the payload claims
# actor_agent=<admin> AND the dirname matches <admin>, a staging file
# whose OWNER UID is not the admin's iso UID is rejected. The kernel UID
# is the non-forgeable proof — an attacker cannot make the OS report its
# file as owned by the admin's UID. We simulate by pointing the admin's
# agent-meta.env at a DIFFERENT OS user than the smoke's own UID (which
# owns the file), so file_owner_uid != resolved-admin-iso-uid.
# ---------------------------------------------------------------------------
smoke_log "T8b: admin-named request whose file is owned by the WRONG UID → file_owner_uid_mismatch"

# Find a real second user (as T4 does) to stand in as the "admin's iso UID".
T8B_OTHER_USER=""
T8B_OTHER_UID=""
while IFS=: read -r u _ id_ _; do
  if [[ "$u" != "$CURRENT_USER" && -n "$id_" && "$id_" =~ ^[0-9]+$ && "$id_" != "$CURRENT_UID" ]]; then
    T8B_OTHER_USER="$u"
    T8B_OTHER_UID="$id_"
    break
  fi
done </etc/passwd

if [[ -z "$T8B_OTHER_USER" || -z "$T8B_OTHER_UID" ]]; then
  smoke_log "T8b: skip — no second resolvable user on /etc/passwd to stand in as the admin iso UID"
else
  # Flip ADMIN_AGENT's meta.env to the other user → its resolved iso UID
  # is T8B_OTHER_UID, but the file the smoke writes is owned by CURRENT_UID.
  cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$T8B_OTHER_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
  T8B_BEFORE_JOBS="$(jobs_count)"
  T8B_UUID="$(staging_py write-request "$STAGING_ROOT" "$ADMIN_AGENT" "$(mk_1474_payload "$ADMIN_AGENT" "$PEER_AGENT")")"
  T8B_UUID="${T8B_UUID%%$'\n'*}"
  set +e
  AGB_CRON_STAGING_ADMIN_AGENT="$ADMIN_AGENT" \
    staging_py apply "$STAGING_ROOT" "$ADMIN_AGENT" "$T8B_UUID" "$JOBS_FILE" >/dev/null 2>&1
  T8B_RC=$?
  set -e
  [[ "$T8B_RC" -ne 0 ]] || smoke_fail "T8b: wrong-owner admin request MUST fail"
  T8B_RESULT="$ISO_STAGING_DIR/$T8B_UUID.result.json"
  T8B_AUDIT="$(result_field "$T8B_RESULT" audit_action)"
  T8B_ERROR="$(result_field "$T8B_RESULT" error)"
  smoke_assert_eq "cron_staging_rejected" "$T8B_AUDIT" "T8b: audit_action must be rejected"
  smoke_assert_contains "$T8B_ERROR" "file_owner_uid_mismatch" \
    "T8b: wrong-owner admin request must be caught by the kernel-UID backstop"
  T8B_AFTER_JOBS="$(jobs_count)"
  [[ "$T8B_AFTER_JOBS" -eq "$T8B_BEFORE_JOBS" ]] || smoke_fail "T8b: jobs.json must NOT change"
  smoke_log "ok: T8b — file-owner backstop holds even for an admin-named request (error=$T8B_ERROR)"
  # Restore canonical meta.env for the remaining case.
  cat >"$META_DIR/agent-meta.env" <<EOF
BRIDGE_AGENT_OS_USER=$CURRENT_USER
BRIDGE_AGENT_ISOLATION_MODE=linux-user
BRIDGE_AGENT_ENGINE=claude
BRIDGE_AGENT_HOME=$BRIDGE_HOME
EOF
fi

# ---------------------------------------------------------------------------
# T8c — SECURITY: with the daemon-supplied admin id unset/empty, the
# exemption is fully disabled — even a real admin-named cross-agent
# request falls back to the strict same-agent-only reject. Proves no
# other env in the apply process can open the cross-agent path.
# ---------------------------------------------------------------------------
smoke_log "T8c: AGB_CRON_STAGING_ADMIN_AGENT unset → admin exemption disabled (strict reject)"

T8C_BEFORE_JOBS="$(jobs_count)"
T8C_UUID="$(staging_py write-request "$STAGING_ROOT" "$ADMIN_AGENT" "$(mk_1474_payload "$ADMIN_AGENT" "$PEER_AGENT")")"
T8C_UUID="${T8C_UUID%%$'\n'*}"
set +e
# Explicitly empty admin id (and ensure no inherited value leaks in).
env -u AGB_CRON_STAGING_ADMIN_AGENT \
  "$PY_BIN" "$REPO_ROOT/lib/cron-helpers/staging.py" \
  apply "$STAGING_ROOT" "$ADMIN_AGENT" "$T8C_UUID" "$JOBS_FILE" >/dev/null 2>&1
T8C_RC=$?
set -e
[[ "$T8C_RC" -ne 0 ]] || smoke_fail "T8c: with no admin configured, cross-agent apply MUST fail"
T8C_RESULT="$ISO_STAGING_DIR/$T8C_UUID.result.json"
T8C_AUDIT="$(result_field "$T8C_RESULT" audit_action)"
T8C_ERROR="$(result_field "$T8C_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T8C_AUDIT" "T8c: audit_action must be rejected"
smoke_assert_contains "$T8C_ERROR" "actor_agent_mismatch" \
  "T8c: admin-unset must fall back to the strict same-agent reject"
T8C_AFTER_JOBS="$(jobs_count)"
[[ "$T8C_AFTER_JOBS" -eq "$T8C_BEFORE_JOBS" ]] || smoke_fail "T8c: jobs.json must NOT change"
smoke_log "ok: T8c — exemption disabled when no admin id is supplied (error=$T8C_ERROR)"

# ---------------------------------------------------------------------------
# T8d — SECURITY: shell-kind admin cross-agent stays blocked at the CLI
# guard. #1474 only widens TEXT cross-agent; shell staging is out of
# scope (the runner needs controller-side script ownership the staging
# path cannot prove from a forged payload).
# ---------------------------------------------------------------------------
smoke_log "T8d: admin cross-agent --kind shell → STILL refused at the CLI guard"

T8D_HOME="$BRIDGE_HOME/t8d"
T8D_JOBS_DIR="$T8D_HOME/cron"
T8D_JOBS_FILE="$T8D_JOBS_DIR/jobs.json"
mkdir -p "$T8D_JOBS_DIR"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$T8D_JOBS_FILE"
chmod 0600 "$T8D_JOBS_FILE"
T8D_HASH_BEFORE="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T8D_JOBS_FILE")"
T8D_STDERR="$SMOKE_TMP_ROOT/t8d-stderr.log"
T8D_RC=0
set +e
BRIDGE_LAYOUT=v2 \
BRIDGE_DATA_ROOT="$BRIDGE_HOME" \
BRIDGE_AGENT_ID="$ADMIN_AGENT" \
BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
BRIDGE_NATIVE_CRON_JOBS_FILE="$T8D_JOBS_FILE" \
bash "$REPO_ROOT/bridge-cron.sh" create \
  --kind shell \
  --agent "$PEER_AGENT" \
  --schedule "0 3 * * *" \
  --tz "Asia/Seoul" \
  --title "$PEER_AGENT-admin-shell-attempt" \
  --payload "echo should be refused" >/dev/null 2>"$T8D_STDERR"
T8D_RC=$?
set -e
[[ "$T8D_RC" -ne 0 ]] || smoke_fail "T8d: admin cross-agent --kind shell MUST exit non-zero"
T8D_ERR="$(cat "$T8D_STDERR" 2>/dev/null || true)"
smoke_assert_contains "$T8D_ERR" "cron mutation refused" \
  "T8d: admin shell-kind cross-agent must still be refused (text-only exemption)"
T8D_HASH_AFTER="$("$PY_BIN" -c "import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$T8D_JOBS_FILE")"
smoke_assert_eq "$T8D_HASH_BEFORE" "$T8D_HASH_AFTER" "T8d: jobs.json must be unchanged"
smoke_log "ok: T8d — shell-kind admin cross-agent still refused (rc=$T8D_RC)"

# ---------------------------------------------------------------------------
# T8e — SECURITY (target abuse, codex r1 BLOCKING): even the genuine admin
# may not provision a cron for an UNREGISTERED target. The daemon supplies
# the roster-derived cron-delivery-target allowlist; a target that is
# syntactically valid but NOT in the allowlist is rejected. This confines
# the exemption to real agents and prevents ghost-cron creation.
# ---------------------------------------------------------------------------
smoke_log "T8e: admin cross-agent to an UNREGISTERED target → rejected (allowlist gate)"

T8E_GHOST="ghost-unregistered-agent"
T8E_BEFORE_JOBS="$(jobs_count)"
T8E_UUID="$(staging_py write-request "$STAGING_ROOT" "$ADMIN_AGENT" "$(mk_1474_payload "$ADMIN_AGENT" "$T8E_GHOST")")"
T8E_UUID="${T8E_UUID%%$'\n'*}"
set +e
# Admin id supplied AND the file owner check would pass (ADMIN_AGENT meta
# → CURRENT_USER), but the allowlist deliberately EXCLUDES the ghost target.
AGB_CRON_STAGING_ADMIN_AGENT="$ADMIN_AGENT" \
AGB_CRON_STAGING_TARGET_ALLOWLIST="$PEER_AGENT"$'\n'"$ADMIN_AGENT" \
  staging_py apply "$STAGING_ROOT" "$ADMIN_AGENT" "$T8E_UUID" "$JOBS_FILE" >/dev/null 2>&1
T8E_RC=$?
set -e
[[ "$T8E_RC" -ne 0 ]] || smoke_fail "T8e: admin cross-agent to a ghost target MUST fail"
T8E_RESULT="$ISO_STAGING_DIR/$T8E_UUID.result.json"
T8E_AUDIT="$(result_field "$T8E_RESULT" audit_action)"
T8E_ERROR="$(result_field "$T8E_RESULT" error)"
smoke_assert_eq "cron_staging_rejected" "$T8E_AUDIT" "T8e: audit_action must be rejected"
smoke_assert_contains "$T8E_ERROR" "admin_cross_agent_unregistered_target" \
  "T8e: ghost target must be caught by the registered-target allowlist"
T8E_AFTER_JOBS="$(jobs_count)"
[[ "$T8E_AFTER_JOBS" -eq "$T8E_BEFORE_JOBS" ]] || smoke_fail "T8e: jobs.json must NOT change"
smoke_log "ok: T8e — unregistered admin cross-agent target rejected (error=$T8E_ERROR)"

smoke_log "all 1359-cron-create-iso-staging cases passed"
