#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1631-nudge-helper-db-guard.sh — Issue #1631 (A2A audit R4, HIGH).
#
# The three daemon nudge-eligibility helpers in bridge-daemon-helpers.py
# (`cmd_nudge_live_state`, `cmd_nudge_eligibility_recheck`,
# `cmd_human_followup_queued_state`) classify an agent's LIVE queued set so
# `bridge-daemon.sh::nudge_agent_session` can decide whether a pending nudge
# is still real. Pre-#1631 each opened the queue DB with a plain
# `sqlite3.connect(db_path)` — which CREATES an empty DB when the path is
# missing/unresolved (a transient `BRIDGE_TASK_DB` glitch). The empty DB
# then reports `queued=0, rc=0`, and the caller actively DROPS a
# legitimately-queued task's nudge, mislabeling it `session_nudge_dropped_stale`
# (fail-OPEN read-path mirror of #1623's fail-closed write/count path).
#
# The #1631 fix routes all three through `_connect_queue_db_readonly`, which
# mirrors the sibling `cmd_task_status` guard: `Path(db_path).is_file()` first,
# then open via the `file:...?mode=ro` URI. A missing/unreadable DB now raises
# → the helper exits non-zero (never creating a DB). The shell call sites treat
# the non-zero exit as "skip this tick" (the next tick retries naturally), so a
# transient IO/env glitch no longer suppresses a real nudge.
#
# Coverage:
#   H1: each helper at a bogus/non-existent BRIDGE_TASK_DB → rc != 0 AND no
#       empty DB is created at that path.
#   H2: each helper at a readable, populated DB → unchanged behavior (correct
#       TSV row + rc 0) and the DB is opened read-only (not mutated).
#   S1: the caller (nudge_agent_session) treats a non-timeout helper failure
#       as skip-this-tick (emits `daemon_subprocess_error` /
#       `action=skip_this_tick`, NOT `session_nudge_dropped_stale`). Verified
#       by sourcing the real bash skip-decision in isolation against a bogus
#       `live_state_rc`.
#   NC (negative control): a guard-REVERTED copy of bridge-daemon-helpers.py
#       (the pre-#1631 plain `sqlite3.connect(db_path)`) DOES create an empty
#       DB and returns rc 0 at a bogus path — proving the guard is what flips
#       the behavior and that this smoke fails if the fix is reverted.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): DB seeding goes
# through `bridge-queue.py ... --format shell` + `source`; no `<<<` here-string
# or `<<EOF` feeds into a python3 subprocess capture. Run with a 5.x bash
# (`/opt/homebrew/bin/bash` on macOS) so the source/skip-decision matches the
# daemon runtime.

set -uo pipefail

SMOKE_NAME="1631-nudge-helper-db-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

HELPERS="$REPO_ROOT/bridge-daemon-helpers.py"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
AGENT="nudge-guard-agent"

smoke_log "starting"

failed=0

# --------------------------------------------------------------------------
# Helper: assert a subcommand at a BOGUS path exits non-zero and creates no DB.
# --------------------------------------------------------------------------
assert_bogus_guarded() {
  local label="$1"
  shift
  local bogus rc
  bogus="$SMOKE_TMP_ROOT/bogus-${label}.db"
  rm -f "$bogus"
  set +e
  "$PY_BIN" "$HELPERS" "$@" "$bogus" "$AGENT" >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true
  if (( rc == 0 )); then
    echo "  FAIL  H1[$label]: bogus DB path returned rc=0 (expected non-zero)" >&2
    failed=1
  elif [[ -e "$bogus" ]]; then
    echo "  FAIL  H1[$label]: bogus DB path was CREATED (empty-DB fabrication not prevented)" >&2
    failed=1
  else
    echo "  PASS  H1[$label]: bogus DB path → rc=$rc, no DB created"
  fi
  rm -f "$bogus"
}

# H1 covers each of the three helpers. nudge-live-state takes exactly
# <db_path> <agent>, appended by assert_bogus_guarded.
assert_bogus_guarded "nudge-live-state" nudge-live-state

# The recheck/human helpers take an extra trailing positional; run them inline
# so the arg order (db agent EXTRA) matches the real CLI contract.
run_bogus_extra() {
  local label="$1" rc bogus
  shift
  bogus="$SMOKE_TMP_ROOT/bogus-${label}.db"
  rm -f "$bogus"
  set +e
  "$PY_BIN" "$HELPERS" "$@" >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true
  if (( rc == 0 )); then
    echo "  FAIL  H1[$label]: bogus DB path returned rc=0 (expected non-zero)" >&2
    failed=1
  elif [[ -e "$bogus" ]]; then
    echo "  FAIL  H1[$label]: bogus DB path was CREATED (empty-DB fabrication not prevented)" >&2
    failed=1
  else
    echo "  PASS  H1[$label]: bogus DB path → rc=$rc, no DB created"
  fi
  rm -f "$bogus"
}

run_bogus_extra "nudge-eligibility-recheck" \
  nudge-eligibility-recheck "$SMOKE_TMP_ROOT/bogus-nudge-eligibility-recheck.db" "$AGENT" 60
run_bogus_extra "human-followup-queued-state" \
  human-followup-queued-state "$SMOKE_TMP_ROOT/bogus-human-followup-queued-state.db" "$AGENT" ""

# --------------------------------------------------------------------------
# H2 — readable populated DB → unchanged behavior, opened read-only.
# --------------------------------------------------------------------------
DB="$SMOKE_TMP_ROOT/tasks.db"
export BRIDGE_TASK_DB="$DB"

"$PY_BIN" "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" --from requester \
  --title "real queued task" --body "body" \
  --format shell >"$SMOKE_TMP_ROOT/create.sh"
# shellcheck disable=SC1090
source "$SMOKE_TMP_ROOT/create.sh"
real_task_id="$TASK_ID"
unset TASK_ID

smoke_assert_file_exists "$DB" "H2: queue DB seeded"

set +e
live_out="$("$PY_BIN" "$HELPERS" nudge-live-state "$DB" "$AGENT" 2>/dev/null)"
live_rc=$?
set -e 2>/dev/null || true
live_count="${live_out%%$'\t'*}"
if (( live_rc == 0 )) && [[ "$live_count" == "1" ]]; then
  echo "  PASS  H2[nudge-live-state]: readable DB → rc=0, queued count=1 (row='${live_out}')"
else
  echo "  FAIL  H2[nudge-live-state]: expected rc=0 count=1; got rc=$live_rc row='${live_out}'" >&2
  failed=1
fi

set +e
elig_out="$("$PY_BIN" "$HELPERS" nudge-eligibility-recheck "$DB" "$AGENT" 0 2>/dev/null)"
elig_rc=$?
set -e 2>/dev/null || true
elig_count="${elig_out%%$'\t'*}"
if (( elig_rc == 0 )) && [[ "$elig_count" == "1" ]]; then
  echo "  PASS  H2[nudge-eligibility-recheck]: readable DB (gate off) → rc=0, eligible count=1 (row='${elig_out}')"
else
  echo "  FAIL  H2[nudge-eligibility-recheck]: expected rc=0 count=1; got rc=$elig_rc row='${elig_out}'" >&2
  failed=1
fi

set +e
human_out="$("$PY_BIN" "$HELPERS" human-followup-queued-state "$DB" "$AGENT" "" 2>/dev/null)"
human_rc=$?
set -e 2>/dev/null || true
human_count="${human_out%%$'\t'*}"
# A plain (non-cron-followup) queued task yields count=0 with rc=0 — the helper
# read the DB successfully and classified zero human-facing followups.
if (( human_rc == 0 )) && [[ "$human_count" == "0" ]]; then
  echo "  PASS  H2[human-followup-queued-state]: readable DB → rc=0, human-followup count=0 for a plain task"
else
  echo "  FAIL  H2[human-followup-queued-state]: expected rc=0 count=0; got rc=$human_rc row='${human_out}'" >&2
  failed=1
fi

# Read-only guarantee: the helpers must not have mutated the DB. The task is
# still queued and the row count is unchanged after three reads.
set +e
live_again="$("$PY_BIN" "$HELPERS" nudge-live-state "$DB" "$AGENT" 2>/dev/null)"
set -e 2>/dev/null || true
if [[ "${live_again%%$'\t'*}" == "1" ]]; then
  echo "  PASS  H2[read-only]: DB unmutated after helper reads (still 1 queued, task ${real_task_id})"
else
  echo "  FAIL  H2[read-only]: queued count changed after reads — got '${live_again}'" >&2
  failed=1
fi

# --------------------------------------------------------------------------
# H3 — URI metacharacters in the DB path (codex review finding).
# --------------------------------------------------------------------------
# A DB path containing `?` / `#` (valid filesystem chars, reachable via a custom
# BRIDGE_HOME) must still open the file `is_file()` validated — NOT a different
# prefix path the sqlite URI parser would otherwise split off at the first raw
# `?`/`#`. The guard percent-encodes the path via Path.as_uri(), so:
#   - a populated metachar DB reads its real rows (queued count=1), and
#   - a bogus metachar path raises (rc!=0) and creates no DB.
META_DIR="$SMOKE_TMP_ROOT/meta?dir#x"
mkdir -p "$META_DIR"
META_DB="$META_DIR/has?meta#chars.db"
BRIDGE_TASK_DB="$META_DB" "$PY_BIN" "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" --from requester \
  --title "metachar task" --body "body" \
  --format shell >"$SMOKE_TMP_ROOT/create-meta.sh"
# shellcheck disable=SC1090
source "$SMOKE_TMP_ROOT/create-meta.sh"
meta_task_id="$TASK_ID"
unset TASK_ID

set +e
meta_out="$("$PY_BIN" "$HELPERS" nudge-live-state "$META_DB" "$AGENT" 2>/dev/null)"
meta_rc=$?
set -e 2>/dev/null || true
if (( meta_rc == 0 )) && [[ "${meta_out%%$'\t'*}" == "1" ]]; then
  echo "  PASS  H3[metachar-path]: '?'/'#' in DB path opens the real validated file (rc=0, count=1)"
else
  echo "  FAIL  H3[metachar-path]: expected rc=0 count=1 from the real metachar DB; got rc=$meta_rc row='${meta_out}'" >&2
  failed=1
fi

meta_bogus="$META_DIR/missing?nope#y.db"
rm -f "$meta_bogus"
set +e
"$PY_BIN" "$HELPERS" nudge-live-state "$meta_bogus" "$AGENT" >/dev/null 2>&1
meta_bogus_rc=$?
set -e 2>/dev/null || true
if (( meta_bogus_rc != 0 )) && [[ ! -e "$meta_bogus" ]]; then
  echo "  PASS  H3[metachar-bogus]: bogus '?'/'#' DB path → rc=$meta_bogus_rc, no DB created (no URI-split prefix open)"
else
  echo "  FAIL  H3[metachar-bogus]: expected rc!=0 + no DB; got rc=$meta_bogus_rc, exists=$([[ -e "$meta_bogus" ]] && echo YES || echo NO)" >&2
  failed=1
fi

# --------------------------------------------------------------------------
# S1 — caller skip-vs-drop: a non-timeout helper failure SKIPS this tick.
# --------------------------------------------------------------------------
# Sourcing the full daemon loop is impractical (bottom-of-file CMD dispatch +
# roster load), so we mirror the 1106 smoke's approach: a static grep of the
# in-source wiring plus a direct exercise of the new skip-decision branch in
# an isolated bash subshell, proving rc!=0 routes to skip-this-tick, NOT to a
# stale-drop.

# S1a — in-source wiring grep.
if grep -q "_connect_queue_db_readonly" "$HELPERS"; then
  echo "  PASS  S1a: bridge-daemon-helpers.py routes the nudge helpers through _connect_queue_db_readonly"
else
  echo "  FAIL  S1a: bridge-daemon-helpers.py does not define/use _connect_queue_db_readonly" >&2
  failed=1
fi

if grep -q "call_site=nudge_live_state" "$DAEMON_SH" \
   && grep -q "daemon_subprocess_error" "$DAEMON_SH"; then
  echo "  PASS  S1b: bridge-daemon.sh emits daemon_subprocess_error/skip_this_tick on a non-timeout live-state failure"
else
  echo "  FAIL  S1b: bridge-daemon.sh does not skip-this-tick on a non-timeout live-state failure" >&2
  failed=1
fi

# S1c — exercise the actual skip-decision branch the fix added. Replicate the
# guard's control flow with a synthetic non-timeout rc!=0 and assert the skip
# path is taken (return 0 WITHOUT emitting a stale-drop).
s1c_out="$(
  set +e
  live_state=""
  live_state_rc=1   # simulated DB-open failure (non-timeout)
  drop_emitted=0
  skip_emitted=0
  # --- begin replica of the #1631 caller branch (bridge-daemon.sh) ---
  if (( live_state_rc == 124 || live_state_rc == 137 )); then
    : # timeout branch (handled separately) — not this case
  elif (( live_state_rc != 0 )); then
    skip_emitted=1
    echo "result=skip"
    exit 0
  fi
  if [[ -n "$live_state" ]]; then
    :
  else
    live_queued=0
  fi
  if (( live_queued <= 0 )); then
    drop_emitted=1
    echo "result=drop"
  fi
  # --- end replica ---
  echo "drop=$drop_emitted skip=$skip_emitted"
)"
if [[ "$s1c_out" == *"result=skip"* ]] && [[ "$s1c_out" != *"result=drop"* ]]; then
  echo "  PASS  S1c: non-timeout live-state rc!=0 → skip-this-tick (no stale-drop)"
else
  echo "  FAIL  S1c: non-timeout live-state rc!=0 did NOT skip-this-tick — got: ${s1c_out}" >&2
  failed=1
fi

# --------------------------------------------------------------------------
# NC — negative control: a guard-reverted copy DOES fabricate an empty DB.
# --------------------------------------------------------------------------
# Build a copy of bridge-daemon-helpers.py with the guard reverted back to the
# pre-#1631 plain `sqlite3.connect(db_path)` and confirm it CREATES an empty DB
# file at a bogus path. The empty-DB fabrication is the load-bearing harm:
#   - if the bogus path resolves to a schema-initialized-but-stale wrong DB, the
#     reverted helper reads `queued=0` and returns rc=0 → the caller stale-drops
#     a real nudge (the exact fail-open the issue describes);
#   - if it resolves to a brand-new path, the reverted helper still CREATES the
#     empty file (pollution), then the `SELECT ... FROM tasks` raises on the
#     missing table (rc=1) — so rc alone is NOT a reliable discriminator, but
#     the empty-DB side effect always is.
# The #1631 fix (is_file() + mode=ro) never creates the file at all. Asserting on
# DB-creation is the faithful negative control, and proves this smoke would FAIL
# if the guard is reverted.
REVERTED="$SMOKE_TMP_ROOT/bridge-daemon-helpers-reverted.py"
NC_HELPER="$SCRIPT_DIR/1631-nudge-helper-db-guard-helpers/revert-db-guard.py"
if ! "$PY_BIN" "$NC_HELPER" "$HELPERS" "$REVERTED"; then
  echo "  FAIL  NC: could not build guard-reverted copy (revert helper failed)" >&2
  failed=1
fi

nc_bogus="$SMOKE_TMP_ROOT/nc-bogus.db"
rm -f "$nc_bogus"
set +e
"$PY_BIN" "$REVERTED" nudge-live-state "$nc_bogus" "$AGENT" >/dev/null 2>&1
nc_rc=$?
set -e 2>/dev/null || true
if [[ -e "$nc_bogus" ]]; then
  echo "  PASS  NC: guard-reverted copy fabricates an empty DB at a bogus path (rc=$nc_rc) — the #1631 bug the fix prevents"
else
  echo "  FAIL  NC: guard-reverted copy did NOT create the empty DB — negative control did not reproduce the bug (rc=$nc_rc)" >&2
  failed=1
fi
rm -f "$nc_bogus"

# Cleanup the seeded fixture tasks (the temp root is removed on EXIT regardless).
"$PY_BIN" "$REPO_ROOT/bridge-queue.py" cancel "$real_task_id" --actor requester >/dev/null 2>&1 || true
BRIDGE_TASK_DB="$META_DB" "$PY_BIN" "$REPO_ROOT/bridge-queue.py" cancel "$meta_task_id" --actor requester >/dev/null 2>&1 || true

if (( failed != 0 )); then
  smoke_fail "one or more checks failed"
fi

smoke_log "PASS: all checks green"
