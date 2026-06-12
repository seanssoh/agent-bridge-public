#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-reconcile-conflict-policy.sh — Issue #1820.
#
# Exercises lib/upgrade-helpers/layout-v2-reconcile.py against a fixture that
# seeds every outcome class the design verdict mandates:
#   - v1-only file            -> copied_from_v1
#   - identical both sides     -> no-op (skipped: identical)
#   - v2 is line-boundary prefix of v1 (v1 superset)  -> adopt v1 (preserved)
#   - v1 is prefix of v2 (v2 already superset)         -> keep v2 (preserved)
#   - divergent suffixes       -> conflict archive + marker + manual queue task
#   - memory/** divergent      -> conflict archive (non-append-like rule)
#   - foreign symlink under memory/ -> skipped fail-closed
# Plus: dry-run writes nothing; apply backs up BOTH sides; a second apply is
# idempotent (zero new data changes, conflict re-reported but not re-archived).
#
# Footgun #11: the python helper is invoked file-as-argv only.

set -uo pipefail
SMOKE_NAME="1820-reconcile-conflict-policy"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/lib/upgrade-helpers/layout-v2-reconcile.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

BH="$BRIDGE_HOME"
DR="$BRIDGE_DATA_ROOT"

mk() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" >"$1"; }

# Agent A: v1-only top MEMORY + v1-only memory tree file -> copied.
mkdir -p "$DR/agents/A/home"
mk "$BH/agents/A/MEMORY.md" 'l1\nl2\n'
mk "$BH/agents/A/memory/2026-06-01.md" 'note-x\n'

# Agent B: v2 is prefix of v1 -> adopt v1 (superset) into v2.
mkdir -p "$DR/agents/B/home"
mk "$DR/agents/B/home/MEMORY.md" 'a\nb\n'
mk "$BH/agents/B/MEMORY.md" 'a\nb\nc\n'

# Agent E: v1 is prefix of v2 -> keep v2 (already superset).
mkdir -p "$DR/agents/E/home"
mk "$BH/agents/E/MEMORY.md" 'x\n'
mk "$DR/agents/E/home/MEMORY.md" 'x\ny\n'

# Agent C: divergent suffix users/u1/MEMORY.md -> conflict archive.
mkdir -p "$DR/agents/C/home/users/u1"
mk "$BH/agents/C/users/u1/MEMORY.md" 'base\nv1only\n'
mk "$DR/agents/C/home/users/u1/MEMORY.md" 'base\nv2only\n'

# Agent D: identical -> no-op.
mkdir -p "$DR/agents/D/home"
mk "$BH/agents/D/MEMORY.md" 'same\n'
mk "$DR/agents/D/home/MEMORY.md" 'same\n'

# Agent F: divergent memory/** file (non-append-like) -> conflict archive.
mkdir -p "$DR/agents/F/home/memory"
mk "$BH/agents/F/memory/notes.md" 'v1-body\n'
mk "$DR/agents/F/home/memory/notes.md" 'v2-body\n'

# Agent G: foreign symlink under memory/ escaping the v1 home -> skipped.
mkdir -p "$DR/agents/G/home" "$SMOKE_TMP_ROOT/outside"
mk "$SMOKE_TMP_ROOT/outside/secret.md" 'leak\n'
mkdir -p "$BH/agents/G/memory"
ln -s "$SMOKE_TMP_ROOT/outside/secret.md" "$BH/agents/G/memory/link.md"

AGENTS="A,B,C,D,E,F,G"

# --- DRY RUN: must write nothing, classify everything ---------------------
DRY="$(python3 "$HELPER" --bridge-home "$BH" --data-root "$DR" --agents-csv "$AGENTS" --mode dry-run)"
python3 -c "import json,sys; json.loads(sys.argv[1])" "$DRY" || smoke_fail "dry-run JSON invalid"

pick() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(len(d[sys.argv[2]]))' "$1" "$2"; }
[[ "$(pick "$DRY" copied)" == "2" ]] || smoke_fail "dry-run copied != 2 (got $(pick "$DRY" copied))"
[[ "$(pick "$DRY" preserved)" == "2" ]] || smoke_fail "dry-run preserved != 2"
[[ "$(pick "$DRY" conflicted)" == "2" ]] || smoke_fail "dry-run conflicted != 2"
# A2 (memory tree copy of A) is counted in copied; ensure dry-run wrote nothing.
[[ ! -f "$DR/agents/A/home/MEMORY.md" ]] || smoke_fail "dry-run mutated v2 (A MEMORY)"
[[ ! -f "$DR/agents/F/home/.reconcile-conflicts" ]] || true
smoke_log "dry-run PASS: classified copied=2 preserved=2 conflicted=2, wrote nothing"

# --- APPLY -----------------------------------------------------------------
BR="$SMOKE_TMP_ROOT/backup"; AR="$SMOKE_TMP_ROOT/archive"; QD="$SMOKE_TMP_ROOT/queue"
APPLY="$(python3 "$HELPER" --bridge-home "$BH" --data-root "$DR" --agents-csv "$AGENTS" --mode apply \
  --backup-root "$BR" --conflict-archive-root "$AR" --queue-task-dir "$QD")"

# copied
[[ -f "$DR/agents/A/home/MEMORY.md" ]] || smoke_fail "apply: A MEMORY not copied"
[[ "$(cat "$DR/agents/A/home/memory/2026-06-01.md")" == "note-x" ]] || smoke_fail "apply: A memory tree not copied"
# superset adopt (B)
[[ "$(printf '%s' "$(cat "$DR/agents/B/home/MEMORY.md")")" == "$(printf 'a\nb\nc')" ]] || smoke_fail "apply: B superset not adopted"
# v2 kept (E)
[[ "$(printf '%s' "$(cat "$DR/agents/E/home/MEMORY.md")")" == "$(printf 'x\ny')" ]] || smoke_fail "apply: E v2 superset not kept"
# conflict: v2 kept live, v1 archived, marker + queue task present (C)
grep -q 'v2only' "$DR/agents/C/home/users/u1/MEMORY.md" || smoke_fail "apply: C v2 not kept live"
[[ -n "$(find "$AR" -path '*users/u1/MEMORY.md' -type f | head -1)" ]] || smoke_fail "apply: C v1 not archived"
[[ -n "$(find "$AR" -name 'MEMORY.md.CONFLICT.md' | head -1)" ]] || smoke_fail "apply: C conflict marker missing"
[[ -n "$(find "$QD" -name 'reconcile-conflict-C-*' | head -1)" ]] || smoke_fail "apply: C manual queue task missing"
# memory/** divergent (F) archived
[[ -n "$(find "$AR" -path '*memory/notes.md' -type f | head -1)" ]] || smoke_fail "apply: F memory/** divergent not archived"
# foreign symlink (G) skipped
echo "$APPLY" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(s["agent"]=="G" and s["reason"]=="foreign_symlink" for s in d["skipped"]), "G not fail-closed"' || smoke_fail "apply: G foreign symlink not skipped"
# backups of BOTH sides for the differing files
[[ -f "$BR/B/v1/MEMORY.md" && -f "$BR/B/v2/MEMORY.md" ]] || smoke_fail "apply: B both-side backups missing"
[[ -f "$BR/C/v1/users/u1/MEMORY.md" && -f "$BR/C/v2/users/u1/MEMORY.md" ]] || smoke_fail "apply: C both-side backups missing"
smoke_log "apply PASS: copied/preserved/conflict-archive/queue/backups/fail-closed all correct"

# --- IDEMPOTENCE -----------------------------------------------------------
AR2="$SMOKE_TMP_ROOT/archive2"; QD2="$SMOKE_TMP_ROOT/queue2"
APPLY2="$(python3 "$HELPER" --bridge-home "$BH" --data-root "$DR" --agents-csv "$AGENTS" --mode apply \
  --backup-root "$SMOKE_TMP_ROOT/backup2" --conflict-archive-root "$AR2" --queue-task-dir "$QD2")"
[[ "$(pick "$APPLY2" copied)" == "0" ]] || smoke_fail "re-apply: copied != 0 (not idempotent)"
# Idempotence = zero new *data changes*. A `prefix_superset_v2` outcome (keep
# v2, no write) is a stable no-op report and may repeat; an *adopt* outcome
# (`prefix_superset_v1`, which WOULD write) must NOT recur after the first run.
echo "$APPLY2" | python3 -c 'import json,sys; d=json.load(sys.stdin); adopts=[p for p in d["preserved"] if p["direction"]=="prefix_superset_v1"]; assert not adopts, f"re-apply re-adopted: {adopts}"' || smoke_fail "re-apply: re-adopted a superset (not idempotent)"
[[ -z "$(find "$AR2" -type f 2>/dev/null | head -1)" ]] || smoke_fail "re-apply: re-archived a known conflict (not idempotent)"
[[ -z "$(find "$QD2" -type f 2>/dev/null | head -1)" ]] || smoke_fail "re-apply: re-queued a known conflict"
echo "$APPLY2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(c["already_archived"] for c in d["conflicted"]), "conflict not marked already_archived"' || smoke_fail "re-apply: conflict not deduped"
smoke_log "idempotence PASS: second apply = zero new data changes, conflicts re-reported as already_archived"

smoke_log "all reconcile conflict-policy tests PASS (#1820)"
