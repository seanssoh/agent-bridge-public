#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1947-memory-rebuild-graceful-skip.sh — Issue #1947
# (cm-prod RCA F5).
#
# The `[upgrade-complete]` bootstrap rebuilds each agent's memory index by
# calling `bridge-memory.py rebuild-index`. When an iso agent's home (or its
# `users/` subtree) is `0700` (iso-UID-only) the CONTROLLER running the
# rebuild cannot read it: `collect_index_documents` probes/walks the tree
# (`exists()`, `iterdir`, `glob`, `rglob`) and the per-doc read loop opens
# each file, so a `PermissionError`/`OSError` on the unreadable path
# propagated → the rebuild aborted with a non-zero rc and the whole bootstrap
# failed. The `0700` is CORRECT isolation, not a bug, so the rebuild should
# graceful-skip the unreadable path (warn + continue) and complete over the
# readable docs with rc=0.
#
# Fix: `collect_index_documents` skips an unreadable dir/probe (warn +
# drop), and `cmd_rebuild_index` skips an unreadable individual doc (warn +
# `skipped_count++`). A fully-unreadable home still returns rc=0.
#
# Non-vacuous: on origin/main the same fixture aborts with a traceback and a
# non-zero exit (PermissionError out of `add_markdown` / the read loop).
#
# This smoke needs NO real iso UID — a `chmod 000` subdir is unreadable to
# the controller's own user, which reproduces the same boundary. No sudo, no
# useradd; host-agnostic.
#
# Footgun #11 (heredoc-stdin deadlock class): the rebuild is invoked via
# `python3 bridge-memory.py rebuild-index ... --json` with file/argv args
# only. No `<<EOF` / `<<<` / `<<'PY'` to a subprocess anywhere.

set -uo pipefail

SMOKE_NAME="1947-memory-rebuild-graceful-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
MEMORY_PY="$REPO_ROOT/bridge-memory.py"

# shellcheck disable=SC2329  # invoked via trap below
cleanup() {
  # Restore traversal perms on any 0700/000 fixture dirs so the temp-root
  # teardown can recurse and delete them.
  if [[ -n "${FIXTURE_HOME:-}" && -d "$FIXTURE_HOME" ]]; then
    chmod -R u+rwX "$FIXTURE_HOME" 2>/dev/null || true
  fi
  if [[ -n "${UNREADABLE_HOME:-}" && -d "$UNREADABLE_HOME" ]]; then
    chmod -R u+rwX "$UNREADABLE_HOME" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

if [[ ! -r "$MEMORY_PY" ]]; then
  smoke_fail "cannot read bridge-memory.py at $MEMORY_PY"
fi

# ---------------------------------------------------------------------
# T1 — partial unreadable tree: a readable doc + an UNREADABLE users
#      subdir. Rebuild must return rc=0, index the readable doc, and
#      emit a skip warning for the unreadable subtree.
# ---------------------------------------------------------------------
FIXTURE_HOME="$SMOKE_TMP_ROOT/agents/bot1"
mkdir -p "$FIXTURE_HOME/users/alice" "$FIXTURE_HOME/users/iso-bot"
printf '# Soul\nreadable soul content\n' >"$FIXTURE_HOME/SOUL.md"
printf '# User\nalice profile content\n' >"$FIXTURE_HOME/users/alice/USER.md"
printf '# Secret\niso-only content\n' >"$FIXTURE_HOME/users/iso-bot/USER.md"
# Simulate the iso 0700 boundary: the controller's own user cannot read a
# 000 dir (same PermissionError class as a cross-UID 0700 dir).
chmod 000 "$FIXTURE_HOME/users/iso-bot"

T1_DB="$SMOKE_TMP_ROOT/index-t1.sqlite"
T1_OUT="$SMOKE_TMP_ROOT/t1.out"
T1_ERR="$SMOKE_TMP_ROOT/t1.err"
"$PY_BIN" "$MEMORY_PY" rebuild-index \
  --agent bot1 --home "$FIXTURE_HOME" --bridge-home "$SMOKE_TMP_ROOT" \
  --db-path "$T1_DB" --json >"$T1_OUT" 2>"$T1_ERR"
t1_rc=$?

if (( t1_rc != 0 )); then
  cat "$T1_ERR" >&2
  smoke_fail "T1 rebuild-index exited rc=$t1_rc on a partially-unreadable tree (expected 0)"
fi
smoke_log "ok: T1 rebuild-index rc=0 on a partially-unreadable tree"

grep -q "skipping unreadable" "$T1_ERR" \
  || smoke_fail "T1 no 'skipping unreadable' warning emitted for the iso-bot subtree"
smoke_log "ok: T1 skip warning emitted for the unreadable subtree"

# The readable docs (SOUL.md + alice's USER.md) must be indexed; the
# unreadable iso-bot doc must NOT be. document_count >= 2 proves the
# readable docs survived the skip.
if ! grep -Eq '"document_count": [2-9]' "$T1_OUT"; then
  cat "$T1_OUT" >&2
  smoke_fail "T1 readable docs were not indexed (document_count < 2)"
fi
smoke_log "ok: T1 readable docs indexed despite the unreadable subtree"

# Confirm the readable content actually landed in the index (the rebuild
# really ran, not just returned 0 over an empty set). Query the rebuilt DB
# directly so this does not couple to the search CLI's default-db-path
# resolution. The probe script is staged to a file and run via `python3 --
# file` (footgun #11: no heredoc-stdin to the subprocess).
T1_PROBE="$SMOKE_TMP_ROOT/t1-probe.py"
printf '%s\n' \
  'import sqlite3, sys' \
  'db = sys.argv[1]' \
  'conn = sqlite3.connect(db)' \
  'rows = conn.execute("SELECT count(*) FROM chunks WHERE text LIKE ?", ("%alice profile%",)).fetchone()[0]' \
  'conn.close()' \
  'sys.exit(0 if rows >= 1 else 1)' \
  >"$T1_PROBE"
if ! "$PY_BIN" -- "$T1_PROBE" "$T1_DB"; then
  smoke_fail "T1 readable doc content not found in the rebuilt index chunks table"
fi
smoke_log "ok: T1 readable content is present in the rebuilt index"

# ---------------------------------------------------------------------
# T2 — fully-unreadable home: every doc is skipped, but the rebuild still
#      returns rc=0 with a warning (an iso bot the controller cannot read
#      is an expected, documented boundary).
# ---------------------------------------------------------------------
UNREADABLE_HOME="$SMOKE_TMP_ROOT/agents/iso-only"
mkdir -p "$UNREADABLE_HOME"
printf '# Soul\nunreadable to controller\n' >"$UNREADABLE_HOME/SOUL.md"
chmod 000 "$UNREADABLE_HOME"

T2_DB="$SMOKE_TMP_ROOT/index-t2.sqlite"
T2_OUT="$SMOKE_TMP_ROOT/t2.out"
T2_ERR="$SMOKE_TMP_ROOT/t2.err"
"$PY_BIN" "$MEMORY_PY" rebuild-index \
  --agent iso-only --home "$UNREADABLE_HOME" --bridge-home "$SMOKE_TMP_ROOT" \
  --db-path "$T2_DB" --json >"$T2_OUT" 2>"$T2_ERR"
t2_rc=$?

if (( t2_rc != 0 )); then
  cat "$T2_ERR" >&2
  smoke_fail "T2 rebuild-index exited rc=$t2_rc on a fully-unreadable home (expected 0)"
fi
smoke_log "ok: T2 rebuild-index rc=0 on a fully-unreadable home"

grep -q "skipping unreadable" "$T2_ERR" \
  || smoke_fail "T2 no 'skipping unreadable' warning emitted for the unreadable home"
smoke_log "ok: T2 skip warning emitted for the fully-unreadable home"

grep -q '"document_count": 0' "$T2_OUT" \
  || smoke_fail "T2 expected document_count 0 for a fully-unreadable home"
smoke_log "ok: T2 fully-unreadable home indexes 0 docs and returns rc=0"

# ---------------------------------------------------------------------
# T3 — --dry-run mirrors the real rebuild: an unreadable JSON capture is
#      skipped in dry-run too (the dry-run loop must actually probe the
#      doc, not blindly count it). Codex review caught a dry-run/real
#      divergence here; this pins the alignment.
# ---------------------------------------------------------------------
T3_HOME="$SMOKE_TMP_ROOT/agents/bot3"
mkdir -p "$T3_HOME/raw/captures/ingested"
printf '# Soul\ndry-run readable\n' >"$T3_HOME/SOUL.md"
printf '{"capture_id": "c1", "text": "readable capture"}\n' \
  >"$T3_HOME/raw/captures/ingested/c1.json"
printf '{"capture_id": "c2", "text": "iso-only capture"}\n' \
  >"$T3_HOME/raw/captures/ingested/c2.json"
chmod 000 "$T3_HOME/raw/captures/ingested/c2.json"

T3_OUT="$SMOKE_TMP_ROOT/t3.out"
T3_ERR="$SMOKE_TMP_ROOT/t3.err"
"$PY_BIN" "$MEMORY_PY" rebuild-index \
  --agent bot3 --home "$T3_HOME" --bridge-home "$SMOKE_TMP_ROOT" \
  --db-path "$SMOKE_TMP_ROOT/index-t3.sqlite" --dry-run --json \
  >"$T3_OUT" 2>"$T3_ERR"
t3_rc=$?

if (( t3_rc != 0 )); then
  cat "$T3_ERR" >&2
  smoke_fail "T3 --dry-run rebuild-index exited rc=$t3_rc on an unreadable JSON capture (expected 0)"
fi
grep -q "skipping unreadable doc" "$T3_ERR" \
  || smoke_fail "T3 --dry-run did not skip the unreadable JSON capture"
grep -q '"skipped_count": 1' "$T3_OUT" \
  || smoke_fail "T3 --dry-run skipped_count did not reflect the unreadable JSON capture"
smoke_log "ok: T3 --dry-run skips an unreadable JSON capture (matches the real rebuild)"

smoke_log "all assertions passed"
exit 0
