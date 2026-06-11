#!/usr/bin/env bash
# scripts/smoke/1786-tasksdb-doctor-verb.sh — Issue #1786 smoke.
#
# #1786: the upgrade-complete checklist told the ADMIN AGENT to run
# `python3 bridge-upgrade.py verify-tasks-db --target-root <root>`, but the
# v0.16.8 tool-policy hook blocks any Bash command that names the queue DB
# path. Worse, that helper's `mode=ro` open of the WAL-journaled live queue
# fails SQLITE_CANTOPEN ("unable to open database file") whenever the `-shm`
# sidecar is absent (right after a checkpoint) — a FALSE negative on a
# healthy db. The fix routes the health check through the policy-blessed
# `agent-bridge doctor --detectors tasks-db` verb and hardens BOTH the doctor
# probe and the raw helper with a `mode=ro` -> `immutable=1` fallback plus a
# 3-state (ok / corrupt / unverifiable) contract.
#
# Test matrix:
#   A. Blessed verb (`bridge-doctor.py --detectors tasks-db --json`) returns
#      NO `tasks-db` finding on a HEALTHY db — including the exact #1786
#      WAL-mode-no-sidecar case that broke the raw `mode=ro` helper.
#   B. Detects a CORRUPT db (quick_check fail -> state=corrupt) and a MISSING
#      db (state=missing), each as a single `tasks-db` finding.
#   C. UNVERIFIABLE (indeterminate): an unreadable db reports state=
#      unverifiable, NEVER ok and distinct from corrupt (#1774/#1782/#1791
#      indeterminate-most-conservative class).
#   D. The upgrade-complete verification block (lib/bridge-cleanup.sh) STEP 4
#      references the blessed `agent-bridge doctor --detectors tasks-db` verb
#      and does NOT regress to the blocked raw `verify-tasks-db` command at
#      its run line (grep teeth).
#   E. tool-policy: the blessed verb shape is ALLOWED from an admin agent
#      session, while commands that name the queue DB path are DENIED —
#      bare `sqlite3 <db>`, `--task-db <db>`, AND the env-prefix forms
#      `DB=<db> sqlite3 "$DB"` / `BRIDGE_TASK_DB=<db> sqlite3
#      "$BRIDGE_TASK_DB"` (codex r1 leading-assignment-value bypass). Probes
#      the real PreToolUse hook like #1690/#1790.
#   F1. The raw `verify-tasks-db` helper reports state=ok + exit 0 on a healthy
#      WAL/no-sidecar db, accepting EITHER open_mode — the portable contract is
#      "healthy reads ok", not "the fallback always fires" (Linux mode=ro can
#      succeed where macOS CANTOPENs; pinning immutable=1 was the CI-red bug).
#   F2. DETERMINISTIC immutable-fallback proof: a healthy WAL/empty-wal db under
#      a read-only state dir forces mode=ro CANTOPEN on every POSIX host, so the
#      immutable=1 fallback must fire and yield a real ok (not unverifiable).
#      Precondition-probed so a platform that legitimately allows mode=ro skips
#      rather than hard-fails.
#
# Footgun #11: every JSON stdin payload is built with `printf` and piped via
# `< file`; the fixture DBs are seeded with a file-as-argv python helper
# (scripts/smoke/1786-tasksdb-seed.py) — no heredoc-stdin / here-string.

set -euo pipefail

SMOKE_NAME="1786-tasksdb-doctor-verb"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "1786-tasksdb-doctor-verb"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

DOCTOR="$REPO_ROOT/bridge-doctor.py"
UPGRADE="$REPO_ROOT/bridge-upgrade.py"
CLEANUP_LIB="$REPO_ROOT/lib/bridge-cleanup.sh"
POLICY="$REPO_ROOT/hooks/tool-policy.py"
SEED="$SCRIPT_DIR/1786-tasksdb-seed.py"
INSPECT="$SCRIPT_DIR/1455-settings-doctor-helper.py"

smoke_assert_file_exists "$DOCTOR" "doctor script present"
smoke_assert_file_exists "$UPGRADE" "upgrade script present"
smoke_assert_file_exists "$CLEANUP_LIB" "cleanup lib present"
smoke_assert_file_exists "$POLICY" "tool-policy hook present"
smoke_assert_file_exists "$SEED" "1786 seed helper present"
smoke_assert_file_exists "$INSPECT" "doctor-output inspector present"

EMPTY_AGENT_LIST="$SMOKE_TMP_ROOT/agent-list.empty.json"
printf '%s\n' '[]' >"$EMPTY_AGENT_LIST"

# run_doctor <bridge-home> -> writes JSON to $DOCTOR_OUT, prints nothing.
DOCTOR_OUT="$SMOKE_TMP_ROOT/doctor.out.json"
run_doctor() {
  local home="$1"
  BRIDGE_HOME="$home" "$PY_BIN" "$DOCTOR" \
    --detectors tasks-db --json \
    --agent-list-json "$EMPTY_AGENT_LIST" \
    --task-db "$home/state/tasks.db" \
    >"$DOCTOR_OUT"
}

d_count() { "$PY_BIN" "$INSPECT" count "$DOCTOR_OUT" "$1"; }
d_field() { "$PY_BIN" "$INSPECT" field "$DOCTOR_OUT" tasks-db "" "$1"; }
d_traceback() { "$PY_BIN" "$INSPECT" has-traceback "$DOCTOR_OUT"; }

# make_home <name> -> prints the bridge-home path with state/ created.
make_home() {
  local name="$1"
  local home="$SMOKE_TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s' "$home"
}

# ---------------------------------------------------------------------------
# A. Healthy WAL db, NO sidecars (the exact #1786 case) -> no tasks-db finding.
# ---------------------------------------------------------------------------
HOME_OK="$(make_home home-ok)"
"$PY_BIN" "$SEED" wal-healthy "$HOME_OK/state/tasks.db"
[[ -f "$HOME_OK/state/tasks.db-shm" ]] && smoke_fail "fixture leaked a -shm sidecar"
run_doctor "$HOME_OK"
smoke_assert_eq "no" "$(d_traceback)" "A: doctor did not traceback"
smoke_assert_eq "0" "$(d_count tasks-db)" "A: healthy WAL db (no sidecar) -> zero tasks-db findings"

# ---------------------------------------------------------------------------
# B1. Corrupt db -> one tasks-db finding, state=corrupt.
# ---------------------------------------------------------------------------
HOME_CORRUPT="$(make_home home-corrupt)"
"$PY_BIN" "$SEED" corrupt "$HOME_CORRUPT/state/tasks.db"
run_doctor "$HOME_CORRUPT"
smoke_assert_eq "no" "$(d_traceback)" "B1: doctor did not traceback"
smoke_assert_eq "1" "$(d_count tasks-db)" "B1: corrupt db -> one tasks-db finding"
smoke_assert_eq "corrupt" "$(d_field state)" "B1: corrupt db -> state=corrupt"

# B2. Missing db -> one tasks-db finding, state=missing.
HOME_MISSING="$(make_home home-missing)"
run_doctor "$HOME_MISSING"
smoke_assert_eq "1" "$(d_count tasks-db)" "B2: missing db -> one tasks-db finding"
smoke_assert_eq "missing" "$(d_field state)" "B2: missing db -> state=missing"

# B3. not-a-database (damaged header -> probe raises DatabaseError) MUST be
#     corrupt, not unverifiable (codex r3 P2): a real corrupt tasks.db must not
#     hide behind the "may still be healthy, do not treat as corruption" copy.
HOME_NOTDB="$(make_home home-notdb)"
"$PY_BIN" "$SEED" not-a-db "$HOME_NOTDB/state/tasks.db"
run_doctor "$HOME_NOTDB"
smoke_assert_eq "1" "$(d_count tasks-db)" "B3: not-a-db -> one tasks-db finding"
smoke_assert_eq "corrupt" "$(d_field state)" "B3: not-a-db -> state=corrupt (NOT unverifiable)"

# ---------------------------------------------------------------------------
# C. Unverifiable (indeterminate) -> state=unverifiable, NEVER ok, distinct
#    from corrupt. Skip when running as root (root reads through chmod 000).
# ---------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  HOME_UNVERIF="$(make_home home-unverif)"
  "$PY_BIN" "$SEED" plain "$HOME_UNVERIF/state/tasks.db"
  chmod 000 "$HOME_UNVERIF/state/tasks.db"
  run_doctor "$HOME_UNVERIF"
  chmod 600 "$HOME_UNVERIF/state/tasks.db"
  smoke_assert_eq "1" "$(d_count tasks-db)" "C: unreadable db -> one tasks-db finding"
  smoke_assert_eq "unverifiable" "$(d_field state)" "C: unreadable db -> state=unverifiable (not ok, not corrupt)"
else
  smoke_log "skip C: running as root, chmod 000 read-block does not hold"
fi

# ---------------------------------------------------------------------------
# C2. WAL-unmerged gate (codex r1 P2): a healthy db with committed pages in a
#     non-empty -wal, no -shm, mode=ro CANTOPENs (read-only dir). The
#     immutable=1 fallback would bypass the WAL and report a STALE ok — the
#     gate must instead report unverifiable. Skip as root (read-only dir does
#     not block root).
# ---------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  HOME_WALU="$(make_home home-walu)"
  "$PY_BIN" "$SEED" wal-unmerged "$HOME_WALU/state/tasks.db"
  [[ -s "$HOME_WALU/state/tasks.db-wal" ]] || smoke_fail "C2: fixture must leave a non-empty -wal"
  [[ -e "$HOME_WALU/state/tasks.db-shm" ]] && smoke_fail "C2: fixture must NOT leave a -shm"
  chmod 0500 "$HOME_WALU/state"
  run_doctor "$HOME_WALU"
  chmod 0700 "$HOME_WALU/state"
  smoke_assert_eq "1" "$(d_count tasks-db)" "C2: wal-unmerged+ro-dir -> one tasks-db finding"
  smoke_assert_eq "unverifiable" "$(d_field state)" "C2: wal-unmerged+ro-dir -> unverifiable, NOT a stale immutable ok"
  # Raw helper must reach the same verdict (operator-shell path).
  C2_OUT="$SMOKE_TMP_ROOT/c2-raw.json"
  chmod 0500 "$HOME_WALU/state"
  set +e
  "$PY_BIN" "$UPGRADE" verify-tasks-db --target-root "$HOME_WALU" >"$C2_OUT"
  C2_RC=$?
  set -e
  chmod 0700 "$HOME_WALU/state"
  smoke_assert_eq "1" "$C2_RC" "C2: raw verify-tasks-db exits 1 on wal-unmerged+ro-dir"
  grep -q '"state": "unverifiable"' "$C2_OUT" || smoke_fail "C2: raw helper must report unverifiable, not a stale ok"
  if grep -q '"open_mode": "immutable=1"' "$C2_OUT"; then
    smoke_fail "C2: raw helper must NOT accept an immutable read that bypasses the non-empty -wal"
  fi
  smoke_log "ok: C2 wal-unmerged gate holds (no stale immutable ok) in both doctor + raw helper"
else
  smoke_log "skip C2: running as root, read-only-dir CANTOPEN does not hold"
fi

# ---------------------------------------------------------------------------
# D. Template grep teeth — step 4 uses the blessed verb, not the blocked
#    raw command at its run line.
# ---------------------------------------------------------------------------
BLOCK_OUT="$SMOKE_TMP_ROOT/verification-block.txt"
# shellcheck source=lib/bridge-cleanup.sh
( source "$CLEANUP_LIB"; bridge_cleanup_render_verification_block "$HOME_OK" ) >"$BLOCK_OUT"
grep -q 'doctor --detectors tasks-db' "$BLOCK_OUT" \
  || smoke_fail "D: verification block must reference the blessed doctor verb"
# The doctor run line must pin the queue to THIS install three ways (#1786
# codex r1/r2/r3): (a) CLEAR the inherited BRIDGE_TASK_DB / BRIDGE_STATE_DIR
# overrides (doctor honors them before $BRIDGE_HOME/state — an admin session
# exports them), (b) BRIDGE_HOME=$TARGET_ROOT, (c) the TARGET install's own
# $TARGET_ROOT/agent-bridge binary (not PATH's, which may lack the tasks-db
# detector). Assert on the actual run line (non-comment).
DOCTOR_RUN_LINE="$(grep -vE '^\s*#' "$BLOCK_OUT" | grep 'doctor --detectors tasks-db' || true)"
for needle in 'BRIDGE_TASK_DB=' 'BRIDGE_STATE_DIR=' 'BRIDGE_HOME="$TARGET_ROOT"' '"$TARGET_ROOT/agent-bridge" doctor'; do
  case "$DOCTOR_RUN_LINE" in
    *"$needle"*) ;;
    *) smoke_fail "D: doctor run line missing '$needle' (got: $DOCTOR_RUN_LINE)" ;;
  esac
done
# The run line (a non-comment line) must NOT invoke the raw verify-tasks-db
# helper. Comments documenting the operator-shell fallback are allowed; an
# actual run line is the regression we guard against.
if grep -vE '^\s*#' "$BLOCK_OUT" | grep -q 'verify-tasks-db --target-root'; then
  smoke_fail "D: verification block regressed to the hook-blocked raw verify-tasks-db run line"
fi
smoke_log "ok: D template references blessed verb pinned to \$TARGET_ROOT, no raw verify-tasks-db run line"

# ---------------------------------------------------------------------------
# E. tool-policy — blessed verb ALLOWED, raw db-path command routing.
# ---------------------------------------------------------------------------
POLICY_HOME="$(make_home policy-home)"
"$PY_BIN" "$SEED" plain "$POLICY_HOME/state/tasks.db"
DB_PATH="$POLICY_HOME/state/tasks.db"

# Issue #1806: a STRICT trusted admin (env BRIDGE_ADMIN_AGENT_ID + controller-
# roster agreement) may now run an EXACT `sqlite3 <task_db> …` invocation
# (allow+audit). The strict predicate reads the controller roster via
# `agent list --json`; pin it deterministically with the read-only test seam so
# this smoke does NOT depend on (or leak from) the operator's live roster.
POLICY_ROSTER_JSON="$SMOKE_TMP_ROOT/1786-controller-roster.json"
printf -- '%s\n' \
  '[' \
  '  {"agent": "patch", "admin": true, "source": "static"}' \
  ']' \
  >"$POLICY_ROSTER_JSON"

# Build a PreToolUse Bash payload. $1 target file, $2 command.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
write_bash_payload() {
  local target="$1" command="$2" esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1786",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}
verdict_of() {
  if [[ "$1" == *'"permissionDecision": "deny"'* ]]; then printf 'DENY'; else printf 'ALLOW'; fi
}
# $1 label, $2 command, $3 ALLOW|DENY.
assert_bash_verdict() {
  local label="$1" command="$2" want="$3" payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(
    BRIDGE_HOME="$POLICY_HOME" \
    BRIDGE_AGENT_ID="patch" \
    BRIDGE_ADMIN_AGENT_ID="patch" \
    BRIDGE_GUARD_ADMIN_ROSTER_JSON="$POLICY_ROSTER_JSON" \
    BRIDGE_AGENT_CLASS_FOR_HOOK="system" \
    "$PY_BIN" "$POLICY" <"$payload"
  )"
  got="$(verdict_of "$out")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: E ${label} -> ${got}"
  else
    smoke_log "FAIL: E ${label} -> ${got}, want ${want}"
    smoke_log "      command: ${command}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "E ${label}: expected ${want}, got ${got}"
  fi
}

assert_bash_verdict "blessed verb (agent-bridge)" \
  "agent-bridge doctor --detectors tasks-db --json" ALLOW
assert_bash_verdict "blessed verb (agb)" \
  "agb doctor --detectors tasks-db --json" ALLOW
# The full rendered template run line (cleared overrides + target binary, codex
# r3 P1) must stay hook-ALLOWED — clearing BRIDGE_TASK_DB/BRIDGE_STATE_DIR and
# pinning BRIDGE_HOME does NOT name the queue DB path on the argv, so the
# queue-DB gate does not fire. (A `--task-db <path>` form WOULD name the path
# and be blocked — which is why the template clears env instead.)
assert_bash_verdict "rendered template run line" \
  "BRIDGE_TASK_DB= BRIDGE_STATE_DIR= BRIDGE_HOME=\"${POLICY_HOME}\" \"${POLICY_HOME}/agent-bridge\" doctor --detectors tasks-db --json" ALLOW
# A --task-db that names the literal queue DB path IS hook-blocked — proving WHY
# the template clears env instead of passing --task-db.
assert_bash_verdict "doctor --task-db <db path>" \
  "agent-bridge doctor --detectors tasks-db --task-db ${DB_PATH} --json" DENY
# Issue #1806 (operator policy 2026-06-12, SUPERSEDES #1786's admin-deny for
# this exact shape): a STRICT trusted admin may now run an EXACT
# `sqlite3 <literal task_db> …` invocation — allow+audit. The blessed `doctor`
# verb above stays the RECOMMENDED path (and is what the template renders), but
# the guard no longer hard-blocks the admin's raw read. The relaxation is tight:
# it requires the FIRST positional to resolve to EXACTLY the task DB, with NO
# shell metachar / embedding (so the var-indirection + sibling forms below stay
# DENIED). Audited via the `admin_sqlite3_task_db` row.
assert_bash_verdict "trusted-admin raw sqlite3 on literal db path (#1806)" \
  "sqlite3 ${DB_PATH} 'PRAGMA quick_check'" ALLOW
# Env-prefix bypass (codex r1, patch-dev): a leading `VAR=<tasks.db>` assignment
# whose VALUE statically spells the queue DB path must be DENIED — the opener
# references the path via the `$VAR` indirection, which the #1806 sqlite3
# carve-out rejects (its FIRST positional is `$DB`/`$BRIDGE_TASK_DB`, an
# unresolved expansion → fail-closed), and the queue-DB argv gate's
# leading-assignment decode catches the path. (Static-decodable class #1709;
# runtime-only $var indirection is #1738.) Both patch-dev probes verbatim:
assert_bash_verdict "env-prefix DB=<path> sqlite3 \$DB" \
  "DB=${DB_PATH} sqlite3 \"\$DB\" 'PRAGMA quick_check'" DENY
assert_bash_verdict "env-prefix BRIDGE_TASK_DB=<path> sqlite3 \$BRIDGE_TASK_DB" \
  "BRIDGE_TASK_DB=${DB_PATH} sqlite3 \"\$BRIDGE_TASK_DB\" 'PRAGMA quick_check'" DENY
# Negative controls: an env-prefix naming a NON-queue path, and the rendered
# template's EMPTY-valued clears, must stay ALLOWED (no over-block).
assert_bash_verdict "env-prefix non-queue path stays allowed" \
  "DB=/tmp/somewhere-else.db sqlite3 \"\$DB\" 'SELECT 1'" ALLOW

# ---------------------------------------------------------------------------
# F1. Raw verify-tasks-db on a healthy WAL/no-sidecar db reports state=ok and
#     exits 0 — accepting EITHER open path. The portable contract is "a
#     healthy db reads ok", NOT "the immutable fallback always fires": on
#     macOS sqlite a fresh `mode=ro` of a WAL db with no -shm CANTOPENs (->
#     immutable fallback), but on Linux sqlite it can succeed directly via
#     mode=ro. Both are correct; pinning open_mode here was the CI-red bug.
# ---------------------------------------------------------------------------
HOME_RAW="$(make_home home-raw)"
"$PY_BIN" "$SEED" wal-healthy "$HOME_RAW/state/tasks.db"
RAW_OUT="$SMOKE_TMP_ROOT/raw-verify.json"
set +e
"$PY_BIN" "$UPGRADE" verify-tasks-db --target-root "$HOME_RAW" >"$RAW_OUT"
RAW_RC=$?
set -e
smoke_assert_eq "0" "$RAW_RC" "F1: raw verify-tasks-db exits 0 on healthy WAL db (no sidecar)"
"$PY_BIN" "$INSPECT" has-traceback "$RAW_OUT" >/dev/null
grep -q '"state": "ok"' "$RAW_OUT" || smoke_fail "F1: raw helper must report state=ok on healthy WAL db"
RAW_MODE="$(grep -o '"open_mode": "[^"]*"' "$RAW_OUT" || true)"
case "$RAW_MODE" in
  *'mode=ro'*|*'immutable=1'*) ;;
  *) smoke_fail "F1: open_mode must be mode=ro or immutable=1 (got: ${RAW_MODE:-<none>})" ;;
esac
smoke_log "ok: F1 healthy WAL/no-sidecar -> state=ok (${RAW_MODE})"

# ---------------------------------------------------------------------------
# F2. DETERMINISTIC immutable-fallback proof (cross-platform): a healthy WAL
#     db with an EMPTY/absent -wal under a READ-ONLY state dir. mode=ro cannot
#     create the -shm it needs (read-only dir blocks it on every POSIX host),
#     so the fallback to immutable=1 MUST fire and MUST return state=ok (the
#     empty -wal makes the immutable read safe — no un-checkpointed pages to
#     skip). Asserts the fallback path actually works + yields a real ok (not
#     unverifiable). Skip as root (read-only dir does not block root).
# ---------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  HOME_FB="$(make_home home-fallback)"
  "$PY_BIN" "$SEED" wal-healthy "$HOME_FB/state/tasks.db"
  [[ -e "$HOME_FB/state/tasks.db-wal" ]] && smoke_fail "F2: fixture must have NO -wal (empty)"
  FB_OUT="$SMOKE_TMP_ROOT/fb-verify.json"
  chmod 0500 "$HOME_FB/state"
  # Precondition probe: confirm a bare mode=ro open of THIS fixture actually
  # CANTOPENs under the read-only dir before asserting the fallback. SQLite
  # WAL semantics make this true on every POSIX host (a ro WAL open must
  # create the -shm, which a read-only dir forbids), but if a platform/sqlite
  # build legitimately allows the mode=ro read we skip F2's assertion rather
  # than hard-fail the suite (F1 already proves the portable ok contract).
  RO_PRECOND="$("$PY_BIN" "$SEED" probe-mode-ro "$HOME_FB/state/tasks.db" 2>/dev/null || true)"
  if [[ "$RO_PRECOND" == "cantopen" ]]; then
    set +e
    "$PY_BIN" "$UPGRADE" verify-tasks-db --target-root "$HOME_FB" >"$FB_OUT"
    FB_RC=$?
    set -e
    chmod 0700 "$HOME_FB/state"
    smoke_assert_eq "0" "$FB_RC" "F2: forced-CANTOPEN + empty-wal -> exit 0 via immutable fallback"
    grep -q '"state": "ok"' "$FB_OUT" || smoke_fail "F2: must report state=ok (not unverifiable) via immutable fallback"
    grep -q '"open_mode": "immutable=1"' "$FB_OUT" \
      || smoke_fail "F2: mode=ro CANTOPEN on a read-only dir MUST fall back to immutable=1"
    smoke_log "ok: F2 forced-CANTOPEN + empty-wal -> immutable=1 fallback fires, state=ok"
  else
    chmod 0700 "$HOME_FB/state"
    smoke_log "skip F2: mode=ro did not CANTOPEN on this host (precond=${RO_PRECOND:-<none>}); F1 covers the portable ok contract"
  fi
else
  smoke_log "skip F2: running as root, read-only-dir CANTOPEN does not hold"
fi

smoke_log "PASS"
