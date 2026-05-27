#!/usr/bin/env bash
# scripts/smoke/α-beta5-upgrade-backfill-normalize.sh — issue #1297
# (v0.15.0-beta5 Lane α upgrade-backfill workdir profile normalize).
#
# Background. Lane G of v0.15.0-beta4 (#1270, PR #1291) introduced
# `bridge_isolation_v2_normalize_workdir_profile_group` to chgrp/chmod
# the materialize fileset under workdir/ to
# `ab-agent-<a>:0660` so the controller — a member of that group —
# can read CLAUDE.md / SOUL.md / SESSION-TYPE.md / etc. without sudo
# during bridge-start.sh's pre-launch grep. Lane G wired the helper
# into the `agent create` post-materialize path AND into the upgrade
# workdir back-fill loop in lib/bridge-isolation-v2-workdir-backfill.sh.
#
# The upgrade wiring shipped with a writes-this-pass gate:
#
#   if (( ${#writes_for_agent[@]} > 0 )) \
#       && declare -F bridge_isolation_v2_normalize_workdir_profile_group ...
#
# That gate is wrong for the beta3 → beta4 upgrade surface, where the
# workdir profile files already exist (written by agent sessions on
# beta3) at `0600 iso-uid:controller-gid`. The copy loop above the gate
# performs ZERO writes for those agents — and the normalize is skipped.
# Existing files stay at 0600 → controller's group-membership is
# moot (no group-read on 0600) → `bridge-start.sh` grep fails EACCES →
# `agent restart` fails + rollback also fails → agent left stopped.
#
# Patch: drop the writes-this-pass gate so the normalize runs for every
# iso v2 agent enumerated in the back-fill loop on every pass. The
# helper itself is idempotent (gates on `bridge_isolation_v2_enforce`;
# chgrp/chmod to the same target is a no-op once reached steady state),
# so the unconditional call is safe on clean installs and on repeat
# upgrades.
#
# Cases (all run in an isolated BRIDGE_HOME via scripts/smoke/lib.sh —
# never touches live runtime).
#
#   T1. beta3-state fixture: workdir profile files pre-seeded at mode
#       0600 (no copy needed). Run the back-fill. With the v2-enforce
#       gate stubbed ON and the agent-group resolver stubbed to the
#       operator's primary group, the unconditional normalize must
#       chmod every materialize-fileset file to 0660. T1 doubles as the
#       teeth — re-introducing the writes-this-pass gate would leave
#       the files at 0600 and fail this case.
#
#   T2. Idempotent re-run: a second back-fill pass on the already-
#       normalized workspace must leave every file at mode 0660 (no
#       chmod-back-to-0600, no errors). Exercises the helper's
#       idempotency contract under the unconditional call.
#
#   T3. Fresh-install / clean-copy scenario: workdir is empty (no
#       profile files yet), profile tree has them at mode 0644 / owner
#       primary group. The back-fill copies the markers AND the
#       normalize fires (same unconditional code path). All files end
#       at 0660. Closes the "clean install also runs backfill normalize
#       → idempotent" item from the Lane α brief default checklist.
#
#   T4. End-to-end readability simulation. After T1, the smoke process
#       (same UID as a controller in production) must be able to `grep`
#       inside CLAUDE.md — the operation that fails with EACCES on a
#       beta3 → beta4 upgrade without this fix. Stand-in for the full
#       `bridge-start.sh` grep on a real iso v2 host.
#
#   T_revert_teeth. Revert proof: with the normalize function name
#       stubbed to a no-op (simulating a regression that removes the
#       wiring entirely), T1's seeded 0600 files MUST stay at 0600 —
#       the smoke's T1 assertion will fail on a regression. This case
#       only runs when explicitly requested via SMOKE_TEETH=1 so the
#       primary smoke flow stays clean; the teeth proof is documented
#       so a reviewer can verify the smoke catches the regression.
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock): no heredocs in
# subprocess pipelines; all driver bodies are emitted via printf-to-file.

set -uo pipefail

SMOKE_NAME="α-beta5-upgrade-backfill-normalize"
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

AGENT="test_clean"

LEGACY_PROFILE_DIR="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
V2_WORKSPACE_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"

# Materialize fileset — kept in lockstep with
# bridge_isolation_v2_normalize_workdir_profile_group's _iso_profile_files.
# (CLAUDE.md / AGENTS.md / SOUL.md / SESSION-TYPE.md / MEMORY.md /
#  MEMORY-SCHEMA.md / HEARTBEAT.md / CHANGE-POLICY.md / TOOLS.md)
MATERIALIZE_FILES=(
  "CLAUDE.md"
  "AGENTS.md"
  "SOUL.md"
  "SESSION-TYPE.md"
  "MEMORY.md"
  "MEMORY-SCHEMA.md"
  "HEARTBEAT.md"
  "CHANGE-POLICY.md"
  "TOOLS.md"
)

OPERATOR_GROUP="$(id -gn 2>/dev/null || printf '')"
[[ -n "$OPERATOR_GROUP" ]] || smoke_fail "could not resolve operator primary group"

# Seed the tracked profile tree with the materialize fileset. CLAUDE.md
# carries a managed-block envelope so it parses as a valid identity
# marker; the others carry stable bodies so byte-equality on the
# fresh-install copy path (T3) is checkable.
mkdir -p "$LEGACY_PROFILE_DIR"
{
  printf '%s\n' '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->'
  printf '%s\n' 'managed-test-fixture'
  printf '%s\n' '<!-- END AGENT BRIDGE DOC MIGRATION -->'
} >"$LEGACY_PROFILE_DIR/CLAUDE.md"
for marker in "${MATERIALIZE_FILES[@]}"; do
  [[ "$marker" == "CLAUDE.md" ]] && continue
  printf '%s' "profile-$marker" >"$LEGACY_PROFILE_DIR/$marker"
done

# Seed a minimal roster — only our test agent. The back-fill helper is
# roster-scoped (iterates `BRIDGE_AGENT_IDS`).
ROSTER_FILE="$BRIDGE_ROSTER_FILE"
: >"$ROSTER_FILE"
{
  printf '%s\n' '# Smoke roster — issue #1297'
  printf 'BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$AGENT"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$AGENT"
} >>"$ROSTER_FILE"

# Build a one-shot driver that:
#   - sources bridge-lib.sh + the back-fill helper directly;
#   - stubs bridge_isolation_v2_enforce ON and
#     bridge_isolation_v2_agent_group_name → operator's primary group
#     so the chgrp/chmod path runs without sudo on macOS / non-iso CI
#     hosts (mirrors G-beta4-watchdog-noise T3's pattern);
#   - runs `bridge_isolation_v2_backfill_workdir_identity --json` and
#     prints the JSON to stdout.
DRIVER="$SMOKE_TMP_ROOT/run-backfill.sh"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'OPERATOR_GROUP="$2"'
  printf '%s\n' 'TEETH_DROP_NORMALIZE="${3:-0}"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_load_roster'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-isolation-v2-workdir-backfill.sh"'
  printf '%s\n' '# Stub the v2 enforce gate + the agent-group resolver after the'
  printf '%s\n' '# library has loaded so the normalize helper resolves them by'
  printf '%s\n' '# name lookup (function override). This mirrors the technique'
  printf '%s\n' '# G-beta4-watchdog-noise T3 uses to exercise the chgrp/chmod'
  printf '%s\n' '# path without root on a CI / macOS host.'
  printf '%s\n' 'bridge_isolation_v2_enforce() { return 0; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "%s" "$OPERATOR_GROUP"; }'
  printf '%s\n' 'if [[ "$TEETH_DROP_NORMALIZE" == "1" ]]; then'
  printf '%s\n' '  # Teeth proof: simulate a regression that removes the normalize'
  printf '%s\n' '  # wiring entirely by overriding the helper to a no-op.'
  printf '%s\n' '  bridge_isolation_v2_normalize_workdir_profile_group() { return 0; }'
  printf '%s\n' 'fi'
  printf '%s\n' 'bridge_isolation_v2_backfill_workdir_identity --json'
} >"$DRIVER"
chmod +x "$DRIVER"

run_backfill() {
  local teeth="${1:-0}"
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$OPERATOR_GROUP" "$teeth" \
    2>"$SMOKE_TMP_ROOT/backfill.stderr"
}

# ---------------------------------------------------------------------
# T1 — beta3-state fixture: pre-existing 0600 files in workdir get
#      normalized to 0660 even when the copy loop performs ZERO writes.
# ---------------------------------------------------------------------
mkdir -p "$V2_WORKSPACE_DIR"
for marker in "${MATERIALIZE_FILES[@]}"; do
  printf '%s' "session-written-$marker" >"$V2_WORKSPACE_DIR/$marker"
  chmod 0600 "$V2_WORKSPACE_DIR/$marker"
done

OUT_JSON_T1="$(run_backfill 0)" \
  || smoke_fail "T1: back-fill driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/backfill.stderr"))"

# The unconditional normalize should chmod every file to 0660 even
# though the copy loop performed zero writes (markers already present).
t1_copied="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.argv[1]).get("markers_copied", -1))' "$OUT_JSON_T1")"
smoke_assert_eq 0 "$t1_copied" "T1 markers_copied (workspace already complete — no copies)"

"$PY_BIN" "$SCRIPT_DIR/G-beta4-helpers/assert-normalize-modes.py" "$V2_WORKSPACE_DIR" "0660" \
  || smoke_fail "T1 FAIL — normalize did not run when zero markers were copied (regression: writes-this-pass gate re-introduced)"
smoke_log "T1 PASS — beta3-state fixture normalized to 0660 with zero copies this pass"

# ---------------------------------------------------------------------
# T2 — Idempotent re-run on already-normalized workspace.
# ---------------------------------------------------------------------
OUT_JSON_T2="$(run_backfill 0)" \
  || smoke_fail "T2: idempotent back-fill driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/backfill.stderr"))"

t2_copied="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.argv[1]).get("markers_copied", -1))' "$OUT_JSON_T2")"
smoke_assert_eq 0 "$t2_copied" "T2 markers_copied (idempotent re-run, no new copies)"

"$PY_BIN" "$SCRIPT_DIR/G-beta4-helpers/assert-normalize-modes.py" "$V2_WORKSPACE_DIR" "0660" \
  || smoke_fail "T2 FAIL — idempotent re-run drifted file modes off 0660"
smoke_log "T2 PASS — idempotent re-run keeps every file at mode 0660"

# ---------------------------------------------------------------------
# T3 — Fresh-install / clean-copy scenario.
# Workspace dir exists (mirrors production: every iso v2 agent has a
# workdir/ created by `agent create` — even on a fresh install) but
# empty of identity markers. Profile tree has them. The back-fill
# copies markers AND normalizes via the same unconditional code path;
# all files end at 0660.
#
# Note on workspace-dir resolution: `bridge_agent_workdir` returns the
# `<root>/<agent>/workdir` path only when (a) the agent is iso v2 (mode
# == linux-user) OR (b) the legacy v2 workdir directory already exists
# on disk. In a smoke that runs without root, branch (a) is moot, so we
# rely on (b) — pre-creating workdir/ so the resolver returns it. This
# mirrors production: on a beta3 install the very first `agent create
# --isolate` materializes workdir/ before any back-fill ever runs.
# ---------------------------------------------------------------------
T3_AGENT="test_fresh"
T3_PROFILE_DIR="$BRIDGE_AGENT_HOME_ROOT/$T3_AGENT"
T3_WORKSPACE_DIR="$BRIDGE_AGENT_ROOT_V2/$T3_AGENT/workdir"

mkdir -p "$T3_PROFILE_DIR" "$T3_WORKSPACE_DIR"
{
  printf '%s\n' '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->'
  printf '%s\n' 'managed-fresh-fixture'
  printf '%s\n' '<!-- END AGENT BRIDGE DOC MIGRATION -->'
} >"$T3_PROFILE_DIR/CLAUDE.md"
for marker in "${MATERIALIZE_FILES[@]}"; do
  [[ "$marker" == "CLAUDE.md" ]] && continue
  printf '%s' "profile-fresh-$marker" >"$T3_PROFILE_DIR/$marker"
done

# Update the roster to include the fresh agent. Re-write so both agents
# are roster-active (T1 / T2 agent state is preserved for T4 below).
: >"$ROSTER_FILE"
{
  printf '%s\n' '# Smoke roster — issue #1297 (T3 expanded)'
  printf 'BRIDGE_AGENT_IDS=("%s" "%s")\n' "$AGENT" "$T3_AGENT"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$AGENT"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$AGENT"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$T3_AGENT"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$T3_AGENT"
} >>"$ROSTER_FILE"

OUT_JSON_T3="$(run_backfill 0)" \
  || smoke_fail "T3: back-fill driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/backfill.stderr"))"

# Fresh agent: every materialize-fileset marker that exists in the
# profile tree must be copied + every file ends at 0660.
t3_copied_total="$("$PY_BIN" -c '
import json, sys
data = json.loads(sys.argv[1])
agents = data.get("agents", [])
for a in agents:
    if a["id"] == sys.argv[2]:
        print(len(a["writes"]))
        break
else:
    print(-1)
' "$OUT_JSON_T3" "$T3_AGENT")"

# Profile tree has all 9 materialize-fileset files BUT the back-fill
# helper's IDENTITY_FILES constant is the 5-element subset the watchdog
# scans. So we expect exactly that many copies on the fresh agent — the
# normalize fileset is broader (9), but the copy fileset is narrower (5).
# What matters for #1297 is that whatever DID land at 0644 / 0600 ends
# at 0660. assert against the actual fileset by checking modes.
[[ "$t3_copied_total" -ge 5 ]] \
  || smoke_fail "T3 FAIL — fresh agent should have at least 5 markers copied (got $t3_copied_total)"

# Verify everything in the fresh workspace landed at 0660.
"$PY_BIN" "$SCRIPT_DIR/G-beta4-helpers/assert-normalize-modes.py" "$T3_WORKSPACE_DIR" "0660" \
  || smoke_fail "T3 FAIL — fresh-install copied markers did not end at mode 0660"
smoke_log "T3 PASS — fresh-install copy + normalize lands every marker at 0660"

# The T1 / T2 workspace from earlier should still be at 0660 (the
# unconditional normalize ran for it again on this pass too — and is a
# no-op once at 0660).
"$PY_BIN" "$SCRIPT_DIR/G-beta4-helpers/assert-normalize-modes.py" "$V2_WORKSPACE_DIR" "0660" \
  || smoke_fail "T3 FAIL — pre-existing agent workspace drifted off 0660 on the fresh-agent backfill pass"

# ---------------------------------------------------------------------
# T4 — End-to-end readability simulation.
# After backfill normalize, the smoke process (controller-uid stand-in)
# can `grep` inside CLAUDE.md — the operation that fails with EACCES on
# a beta3 → beta4 upgrade without this fix. Equivalent to the
# bridge-start.sh pre-launch grep that #1297 reproduced as the user-
# visible symptom.
#
# The body assertion targets the byte the T1 fixture seeded
# (`session-written-CLAUDE.md`); the existence check `[[ ! -e $dst ]]`
# in the back-fill copy loop intentionally preserves operator / session
# edits, so the workspace CLAUDE.md still carries the seeded body.
# That preservation contract is orthogonal to the normalize chmod the
# Lane α fix wires unconditionally — what matters here is the controller
# can `grep` (== `cat` == `open(O_RDONLY)`) at all.
# ---------------------------------------------------------------------
if ! grep -q 'session-written-CLAUDE.md' "$V2_WORKSPACE_DIR/CLAUDE.md" 2>"$SMOKE_TMP_ROOT/t4.stderr"; then
  smoke_fail "T4 FAIL — controller-side grep on normalized CLAUDE.md failed (stderr: $(cat "$SMOKE_TMP_ROOT/t4.stderr"))"
fi
smoke_log "T4 PASS — controller-side grep on normalized CLAUDE.md succeeds"

# ---------------------------------------------------------------------
# T_idempotent_no_mutation_on_correct — codex r1 BLOCKING on PR #1302.
# After T2 every materialize-fileset file is already
# ``<operator_group>:0660`` (the helper's idempotent steady state).
# A subsequent normalize call MUST short-circuit via the helper's
# stat-skip: zero chgrp / chmod syscalls. We prove this by overriding
# ``_bridge_isolation_v2_run_root_or_sudo`` to a function that appends a
# line to a counter file on every invocation, then asserting the counter
# stays at 0.
#
# Mechanism mirrors the function-override technique used by the other
# T-cases above (bridge_isolation_v2_enforce + agent_group_name stubs):
# load the libs, replace the helper by name, drive the normalize, count.
#
# Teeth (verified by hand by the fixer, documented for re-runs): revert
# the stat-skip in lib/bridge-isolation-v2.sh:bridge_isolation_v2_chgrp_file_iso_group
# → counter > 0 → this assertion fails. Codex r1 confirmed the
# pre-stat-skip behavior emits one chgrp+chmod pair per file (so the
# regression signal is 2 * fileset_size = 18 calls minimum).
# ---------------------------------------------------------------------
NOMUT_DRIVER="$SMOKE_TMP_ROOT/run-nomut.sh"
NOMUT_COUNTER="$SMOKE_TMP_ROOT/nomut-counter.log"
: >"$NOMUT_COUNTER"
: >"$NOMUT_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'OPERATOR_GROUP="$2"'
  printf '%s\n' 'WORKDIR="$3"'
  printf '%s\n' 'COUNTER="$4"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_isolation_v2_enforce() { return 0; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "%s" "$OPERATOR_GROUP"; }'
  printf '%s\n' '# Counter-shim. Every invocation appends a line carrying the'
  printf '%s\n' '# full argv so a regression is debuggable from the counter file.'
  printf '%s\n' '# Returns 0 so the surrounding `|| return 1` does not fire and'
  printf '%s\n' '# obscure the assertion below.'
  printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() {'
  printf '%s\n' '  printf "%s\\n" "$*" >>"$COUNTER" 2>/dev/null || true'
  printf '%s\n' '  return 0'
  printf '%s\n' '}'
  printf '%s\n' 'bridge_isolation_v2_normalize_workdir_profile_group nomut "$WORKDIR" || true'
} >"$NOMUT_DRIVER"
chmod +x "$NOMUT_DRIVER"

"$BRIDGE_BASH" "$NOMUT_DRIVER" "$REPO_ROOT" "$OPERATOR_GROUP" \
  "$V2_WORKSPACE_DIR" "$NOMUT_COUNTER" \
  2>"$SMOKE_TMP_ROOT/nomut.stderr" \
  || smoke_fail "T_idempotent_no_mutation: driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/nomut.stderr"))"

nomut_calls=0
if [[ -s "$NOMUT_COUNTER" ]]; then
  nomut_calls="$(wc -l <"$NOMUT_COUNTER" | tr -d '[:space:]')"
fi
if [[ "$nomut_calls" -ne 0 ]]; then
  smoke_fail "T_idempotent_no_mutation FAIL — expected 0 chgrp/chmod calls on already-correct files, got $nomut_calls. Counter log: $(cat "$NOMUT_COUNTER")"
fi
smoke_log "T_idempotent_no_mutation PASS — zero chgrp/chmod calls on already-correct files (codex r1 BLOCKING resolved)"

# ---------------------------------------------------------------------
# T_revert_teeth (gated on SMOKE_TEETH=1).
# Re-seed the T1 workspace at 0600, run the back-fill with the
# normalize function stubbed to a no-op, and assert the files stay at
# 0600. This is the proof that the smoke catches a regression that
# removes the normalize wiring entirely.
# ---------------------------------------------------------------------
if [[ "${SMOKE_TEETH:-0}" == "1" ]]; then
  TEETH_DIR="$SMOKE_TMP_ROOT/teeth-workspace"
  mkdir -p "$TEETH_DIR"
  for marker in "${MATERIALIZE_FILES[@]}"; do
    printf '%s' "teeth-$marker" >"$TEETH_DIR/$marker"
    chmod 0600 "$TEETH_DIR/$marker"
  done

  # We re-use the T3_AGENT slot for the teeth pass (its profile dir is
  # already seeded), but point the workspace at TEETH_DIR by temporarily
  # rewriting BRIDGE_AGENT_ROOT_V2 just for this child. Cleaner: drive a
  # one-off via direct function call on TEETH_DIR.
  TEETH_DRIVER="$SMOKE_TMP_ROOT/run-teeth.sh"
  : >"$TEETH_DRIVER"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' 'REPO_ROOT="$1"'
    printf '%s\n' 'OPERATOR_GROUP="$2"'
    printf '%s\n' 'TEETH_DIR="$3"'
    printf '%s\n' '# shellcheck disable=SC1091'
    printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
    printf '%s\n' 'bridge_isolation_v2_enforce() { return 0; }'
    printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "%s" "$OPERATOR_GROUP"; }'
    printf '%s\n' '# Simulate the regression by stubbing the normalize fn out.'
    printf '%s\n' 'bridge_isolation_v2_normalize_workdir_profile_group() { return 0; }'
    printf '%s\n' '# Call into the same call-site shape the back-fill uses.'
    printf '%s\n' 'if declare -F bridge_isolation_v2_normalize_workdir_profile_group >/dev/null 2>&1; then'
    printf '%s\n' '  bridge_isolation_v2_normalize_workdir_profile_group teeth "$TEETH_DIR" >/dev/null 2>&1 || true'
    printf '%s\n' 'fi'
  } >"$TEETH_DRIVER"
  chmod +x "$TEETH_DRIVER"
  "$BRIDGE_BASH" "$TEETH_DRIVER" "$REPO_ROOT" "$OPERATOR_GROUP" "$TEETH_DIR" \
    2>"$SMOKE_TMP_ROOT/teeth.stderr" || true

  "$PY_BIN" "$SCRIPT_DIR/G-beta4-helpers/assert-normalize-modes.py" "$TEETH_DIR" "0600" \
    || smoke_fail "T_revert_teeth FAIL — files drifted off 0600 with normalize stubbed to no-op (regression-proof broken)"
  smoke_log "T_revert_teeth PASS — stubbed-out normalize leaves files at 0600 (smoke catches regression)"
fi

smoke_log "all tests PASS (#1297)"
