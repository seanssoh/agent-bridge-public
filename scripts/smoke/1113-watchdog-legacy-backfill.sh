#!/usr/bin/env bash
# Issue #1113 regression smoke — `bridge_isolation_v2_backfill_workdir_identity`
# must materialize the canonical identity markers from the tracked
# profile tree (`$BRIDGE_HOME/agents/<agent>/`) into the v2 runtime
# workspace (`$BRIDGE_DATA_ROOT/agents/<agent>/workdir/`) for
# roster-active agents whose workspace is missing those markers, AND
# the resulting workspace must classify as `status: ok` under the
# post-#1108 watchdog scan (the dual-tree consistency contract the
# whole fix exists to preserve).
#
# Bug shape on operator host (v0.14.5-beta6, 2026-05-23):
#   `librarian` agent scaffolded pre-#1108 OR migrated via the
#   marker-only v2 fast-path (PR #897 Track A). Identity markers live
#   only at `$BRIDGE_HOME/agents/librarian/*.md`. Post-beta6 watchdog
#   scans `$BRIDGE_DATA_ROOT/agents/librarian/workdir/`, sees no
#   markers, reports `status: error` + `missing_files: CLAUDE.md,
#   SOUL.md, MEMORY-SCHEMA.md, MEMORY.md, SESSION-TYPE.md` on every
#   cron tick.
#
# Asserts (all on a temp BRIDGE_HOME — operator's live tree never
# touched):
#   T1 — Synthesize a legacy-migrated agent shape (markers in profile
#        tree, only HEARTBEAT.md in workspace). Run the back-fill.
#        All five canonical identity markers (CLAUDE.md, SOUL.md,
#        SESSION-TYPE.md, MEMORY-SCHEMA.md, MEMORY.md) must now be
#        present in the workspace, byte-equal to the profile tree.
#   T2 — Re-run the back-fill on the same workspace. Idempotency
#        contract: the second pass must report `markers_copied: 0`
#        (no rewrites) and must NOT change the byte content of any
#        marker that already existed in the workspace.
#   T3 — End-to-end consistency with the watchdog: after back-fill, a
#        `bridge-watchdog.py scan --json --agent-registry-json` pass
#        with the agent's registry payload (workdir → v2 workspace)
#        must classify the agent as `status: ok` with empty
#        `missing_files`. This is the contract that closes #1113:
#        operator's watchdog scan output must return to clean. Runs
#        BEFORE T4 because T4 intentionally drops the managed-block
#        CLAUDE.md to prove the operator-edit-preservation contract.
#   T4 — When an operator has edited a workspace marker post-migration,
#        the back-fill must NOT overwrite it. Sentinel byte-content
#        round-trip: write a unique string into workspace/CLAUDE.md,
#        delete one OTHER marker, re-run the back-fill, assert the
#        sentinel survives and the missing marker gets copied.
#   T5 — Agents that exist on disk but are NOT in the roster are NOT
#        back-filled. Orphan / stale-profile tree must never be
#        promoted to a runtime workspace.
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock): no heredocs in
# subprocess pipelines; all driver bodies are emitted via printf-to-file.

set -uo pipefail

SMOKE_NAME="1113-watchdog-legacy-backfill"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="librarian"
ORPHAN_AGENT="claude-static"

LEGACY_PROFILE_DIR="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
V2_WORKSPACE_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"

# Seed the tracked profile tree with the full canonical marker set.
# The CLAUDE.md and SESSION-TYPE.md bodies follow the home-profile
# contract the watchdog asserts (`classify_status` checks for the
# managed-block markers in CLAUDE.md and a valid `Onboarding State`
# row in SESSION-TYPE.md). The other three (SOUL/MEMORY/MEMORY-SCHEMA)
# carry unique stable bodies so byte-equality can be asserted directly
# against the workspace post-back-fill.
mkdir -p "$LEGACY_PROFILE_DIR"
# CLAUDE.md — managed-block envelope so the post-back-fill watchdog
# can classify the workspace as `ok` end-to-end (T4).
{
  printf '%s\n' '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->'
  printf '%s\n' 'managed'
  printf '%s\n' '<!-- END AGENT BRIDGE DOC MIGRATION -->'
} >"$LEGACY_PROFILE_DIR/CLAUDE.md"
# SESSION-TYPE.md — onboarding complete + a static-claude session type,
# matching the home-profile contract the watchdog asserts.
{
  printf '%s\n' '# Session Type'
  printf '%s\n' ''
  printf '%s\n' '- Session Type: static-claude'
  printf '%s\n' '- Onboarding State: complete'
} >"$LEGACY_PROFILE_DIR/SESSION-TYPE.md"
# Plain stable bodies for byte-equality assertions in T1/T2.
printf '%s' 'profile-SOUL.md'          >"$LEGACY_PROFILE_DIR/SOUL.md"
printf '%s' 'profile-MEMORY-SCHEMA.md' >"$LEGACY_PROFILE_DIR/MEMORY-SCHEMA.md"
printf '%s' 'profile-MEMORY.md'        >"$LEGACY_PROFILE_DIR/MEMORY.md"

# Seed the v2 workspace with only HEARTBEAT.md — exactly the shape the
# operator host hit (legacy-migrated, marker-only-fast-path).
mkdir -p "$V2_WORKSPACE_DIR"
printf '%s' 'heartbeat-stub' >"$V2_WORKSPACE_DIR/HEARTBEAT.md"

# Seed an orphan: tracked tree only, NOT in roster. The back-fill must
# leave it alone (no workspace materialization, no warnings about a
# missing roster entry).
ORPHAN_PROFILE_DIR="$BRIDGE_AGENT_HOME_ROOT/$ORPHAN_AGENT"
mkdir -p "$ORPHAN_PROFILE_DIR"
printf '%s' 'orphan-CLAUDE.md' >"$ORPHAN_PROFILE_DIR/CLAUDE.md"

# Seed a minimal roster with ONLY the librarian agent — the back-fill
# is roster-scoped, and the orphan must NOT appear in BRIDGE_AGENT_IDS.
# `agent-roster.sh` is sourced by `bridge_load_roster`; only a few
# fields are required for our helper (the agent id in
# `BRIDGE_AGENT_IDS` and a non-empty `BRIDGE_AGENT_CLASS` entry so the
# downstream resolver does not bail). bridge-state.sh handles the rest.
ROSTER_FILE="$BRIDGE_ROSTER_FILE"
: >"$ROSTER_FILE"
{
  printf '%s\n' '# Smoke roster — issue #1113'
  printf 'BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$AGENT"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$AGENT"
} >>"$ROSTER_FILE"

# Build a one-shot driver that:
#   - exports BRIDGE_DATA_ROOT/BRIDGE_AGENT_ROOT_V2 to point at the
#     v2 workspace tree the smoke seeded;
#   - sources bridge-lib.sh + the back-fill helper directly;
#   - runs `bridge_isolation_v2_backfill_workdir_identity --json` and
#     prints the JSON to stdout.
DRIVER="$SMOKE_TMP_ROOT/run-backfill.sh"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_load_roster'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-isolation-v2-workdir-backfill.sh"'
  printf '%s\n' 'bridge_isolation_v2_backfill_workdir_identity --json'
} >"$DRIVER"
chmod +x "$DRIVER"

run_backfill() {
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" 2>"$SMOKE_TMP_ROOT/backfill.stderr"
}

# --- T1: first pass materializes all 5 markers ------------------------

OUT_JSON_R1="$(run_backfill)" || smoke_fail "T1: back-fill driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/backfill.stderr"))"

T1_RESULT="$("$PY_BIN" -c '
import json, sys
data = json.loads(sys.argv[1])
agents = data.get("agents", [])
print("examined=" + str(data.get("agents_examined", 0)))
print("with_writes=" + str(data.get("agents_with_writes", 0)))
print("copied=" + str(data.get("markers_copied", 0)))
print("agent_ids=" + ",".join(a["id"] for a in agents))
for a in agents:
    print("writes_" + a["id"] + "=" + ",".join(sorted(a["writes"])))
' "$OUT_JSON_R1")"

t1_examined=$(printf '%s\n' "$T1_RESULT" | sed -n 's/^examined=//p')
t1_with_writes=$(printf '%s\n' "$T1_RESULT" | sed -n 's/^with_writes=//p')
t1_copied=$(printf '%s\n' "$T1_RESULT" | sed -n 's/^copied=//p')
t1_writes="$(printf '%s\n' "$T1_RESULT" | sed -n 's/^writes_librarian=//p')"

smoke_assert_eq 1 "$t1_examined" "T1 agents_examined (roster has only librarian)"
smoke_assert_eq 1 "$t1_with_writes" "T1 agents_with_writes"
smoke_assert_eq 5 "$t1_copied" "T1 markers_copied (all 5 identity files)"
smoke_assert_eq "CLAUDE.md,MEMORY-SCHEMA.md,MEMORY.md,SESSION-TYPE.md,SOUL.md" "$t1_writes" "T1 per-agent writes (sorted)"

for marker in CLAUDE.md SOUL.md SESSION-TYPE.md MEMORY-SCHEMA.md MEMORY.md; do
  smoke_assert_file_exists "$V2_WORKSPACE_DIR/$marker" "T1 workspace has $marker post-back-fill"
  cmp -s "$LEGACY_PROFILE_DIR/$marker" "$V2_WORKSPACE_DIR/$marker" \
    || smoke_fail "T1 byte-equal: workspace/$marker does not match profile/$marker"
done

smoke_log "T1 PASS: first pass materialized all 5 canonical identity markers from profile tree to workspace"

# --- T2: second pass is idempotent (no rewrites) ----------------------

OUT_JSON_R2="$(run_backfill)" || smoke_fail "T2: second back-fill driver exited non-zero"

t2_copied="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.argv[1]).get("markers_copied", -1))' "$OUT_JSON_R2")"
smoke_assert_eq 0 "$t2_copied" "T2 markers_copied (idempotent re-run)"

t2_with_writes="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.argv[1]).get("agents_with_writes", -1))' "$OUT_JSON_R2")"
smoke_assert_eq 0 "$t2_with_writes" "T2 agents_with_writes (idempotent re-run)"

# Byte-equality of the workspace tree must be preserved.
for marker in CLAUDE.md SOUL.md SESSION-TYPE.md MEMORY-SCHEMA.md MEMORY.md; do
  cmp -s "$LEGACY_PROFILE_DIR/$marker" "$V2_WORKSPACE_DIR/$marker" \
    || smoke_fail "T2 byte-equal preserved on idempotent re-run: workspace/$marker drifted"
done

smoke_log "T2 PASS: idempotent re-run reported 0 copies + preserved byte-content"

# --- T3: watchdog now classifies the agent as ok ----------------------
# Runs BEFORE T4 (operator-sentinel) because T4 intentionally writes a
# non-managed-block sentinel into workspace/CLAUDE.md to prove the
# back-fill respects operator edits, and that sentinel would naturally
# trip `missing_managed_claude_block=true` in the watchdog — which is
# correct behavior but unrelated to the dual-tree gap #1113 closes.
# Testing the watchdog handshake while the workspace still holds the
# canonical managed-block CLAUDE.md is the contract we need to pin.

REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
{
  printf '[\n'
  printf '  {\n'
  printf '    "id": "%s",\n' "$AGENT"
  printf '    "class": "static",\n'
  printf '    "agent_source": "static",\n'
  printf '    "engine": "claude",\n'
  printf '    "workdir": "%s"\n' "$V2_WORKSPACE_DIR"
  printf '  }\n'
  printf ']\n'
} >"$REGISTRY_JSON"

WATCHDOG_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REGISTRY_JSON" 2>"$SMOKE_TMP_ROOT/watchdog.stderr")"

t3_status="$("$PY_BIN" -c '
import json, sys
data = json.loads(sys.argv[1])
items = data.get("agents", []) or data.get("items", [])
for it in items:
    if it.get("agent") == "librarian":
        print(it.get("status", "missing"))
        break
else:
    print("agent-not-found")
' "$WATCHDOG_JSON")"

t3_missing="$("$PY_BIN" -c '
import json, sys
data = json.loads(sys.argv[1])
items = data.get("agents", []) or data.get("items", [])
for it in items:
    if it.get("agent") == "librarian":
        print(",".join(it.get("missing_files", []) or []))
        break
' "$WATCHDOG_JSON")"

smoke_assert_eq "ok" "$t3_status" "T3 watchdog classifies librarian as ok post-back-fill"
smoke_assert_eq "" "$t3_missing" "T3 watchdog reports missing_files: [] post-back-fill"

smoke_log "T3 PASS: end-to-end watchdog scan returns clean after back-fill"

# --- T4: operator-edited marker is NOT overwritten --------------------

# Sentinel: operator edits workspace/CLAUDE.md post-migration.
SENTINEL='operator-edited-sentinel-do-not-overwrite'
printf '%s' "$SENTINEL" >"$V2_WORKSPACE_DIR/CLAUDE.md"
# Simultaneously delete workspace/MEMORY.md so the back-fill has at
# least one write to perform — and we can confirm the sentinel survives
# even while OTHER markers are being copied.
rm -f "$V2_WORKSPACE_DIR/MEMORY.md"

OUT_JSON_R4="$(run_backfill)" || smoke_fail "T4: back-fill driver exited non-zero"

t4_copied="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.argv[1]).get("markers_copied", -1))' "$OUT_JSON_R4")"
smoke_assert_eq 1 "$t4_copied" "T4 markers_copied (only the deleted MEMORY.md)"

t4_writes="$("$PY_BIN" -c '
import json, sys
data = json.loads(sys.argv[1])
agents = data.get("agents", [])
for a in agents:
    if a["id"] == "librarian":
        print(",".join(sorted(a["writes"])))
        break
' "$OUT_JSON_R4")"
smoke_assert_eq "MEMORY.md" "$t4_writes" "T4 per-agent writes (only MEMORY.md)"

# Operator's sentinel byte-content MUST survive.
smoke_assert_eq "$SENTINEL" "$(cat "$V2_WORKSPACE_DIR/CLAUDE.md")" "T4 sentinel preserved on workspace/CLAUDE.md"
# The deleted marker MUST be restored.
smoke_assert_eq "profile-MEMORY.md" "$(cat "$V2_WORKSPACE_DIR/MEMORY.md")" "T4 MEMORY.md restored from profile tree"

smoke_log "T4 PASS: operator-edited workspace marker preserved + missing marker restored"

# --- T5: orphan agent (not in roster) is left alone -------------------

# The orphan profile dir was never touched by the back-fill — there is
# no v2 workspace for it (the orphan was never created in
# data/agents/), and the helper iterates the roster, NOT the on-disk
# tracked tree. Assert the orphan's tracked-tree CLAUDE.md was not
# copied anywhere unexpected.
if [[ -e "$BRIDGE_AGENT_ROOT_V2/$ORPHAN_AGENT" ]]; then
  smoke_fail "T5: orphan agent '$ORPHAN_AGENT' got a v2 workspace dir from back-fill (orphan must be left alone)"
fi
# The orphan tracked tree itself must be untouched.
smoke_assert_eq "orphan-CLAUDE.md" "$(cat "$ORPHAN_PROFILE_DIR/CLAUDE.md")" "T5 orphan profile tree unchanged"

smoke_log "T5 PASS: orphan agent (not in roster) not back-filled"

smoke_log "all 5 tests PASS (#1113)"
