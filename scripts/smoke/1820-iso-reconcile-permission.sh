#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-iso-reconcile-permission.sh
#
# Issue #1820 rc3 — the layout-v2 v1->v2 reconcile must NOT controller-direct-
# read an iso v2 agent's agent-private memory.
#
# Symptom (cm-prod real-Linux iso-v2 production soak of v0.16.10-rc2): the
# reconcile runs as the CONTROLLER. For an iso v2 agent each agent-private
# MEMORY.md is owned by `agent-bridge-<a>` at mode 0600 — the controller CANNOT
# read it. The pre-mutation backup's shutil.copy2 then raised
#   "backup failed for v1:MEMORY.md: [Errno 13] Permission denied"
# (8 such warnings across 4 iso bots), and the expected iso permission pass was
# ENTIRELY ABSENT from last-apply.json — it degraded to unstructured perm-
# warnings instead of a structured step. Data loss was 0 (the controller could
# not read so could not modify the agent-private memory → live intact), but the
# reconcile is architecturally wrong for iso agents and lacked observability.
#
# Fix (option b — graceful-skip): for an agent passed in --iso-agents-json the
# reconcile engine GRACEFUL-SKIPS the controller-side backup + v1->v2 memory
# pass (no Errno13 direct-read) and records a STRUCTURED isolation_v2_migration
# entry (action: skipped-iso-private). Agent-private 0600 memory is owned and
# managed by the agent; controller backup of it is the wrong contract (same
# class as the #1635 / #1827 iso-home graceful-skips). The fencing/conflict
# DATA logic is byte-identical — it is simply not entered for iso agents.
#
# Asserts:
#   T1 — engine WITH --iso-agents-json over an UNREADABLE (chmod 000, simulating
#        a 0600-not-owner) iso agent-private MEMORY.md: NO Errno13 perm-warning,
#        a structured isolation_v2_migration entry (skipped-iso-private) is
#        present, and the agent's v2 memory is UNTOUCHED (drift 0).
#   T2 — CONTROL: the SAME unreadable fixture WITHOUT the iso map reproduces the
#        cm-prod symptom (an Errno13 perm-warning, empty isolation_v2_migration)
#        — proving the iso map is what suppresses it, not the chmod.
#   T3 — CONTROL (shared-mode, no iso agents): a normal readable v1-superset
#        agent reconciles exactly as before (prefix_superset_v1 preserved, empty
#        isolation_v2_migration, no warnings) — the DATA path is unchanged.
#   T4 — the wrapper's iso-agents-json builder emits {agent:os_user} when the iso
#        predicate says isolated, and {} when not (stubbed predicates — no real
#        iso UID needed).
#   T5 — static tripwires bind the behavior to source.
#
# Portability note (macOS / CI have no real cross-UID iso boundary): we simulate
# the controller-blind 0600 read with `chmod 000` on the agent-private file (a
# non-root user then gets the same [Errno 13] as the real iso boundary). Root
# can read 000 files, so the iso-trigger tooth is skipped when run as uid 0; the
# LINUX RE-GATE on a real iso install is documented in the PR.
#
# Footgun #11: NO heredoc-stdin to any subprocess — fixtures via printf, JSON
# probed file-as-argv. Run under Bash 5.x (macOS system bash is 3.2).

set -uo pipefail
SMOKE_NAME="1820-iso-reconcile-permission"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
ENGINE="$REPO_ROOT/lib/upgrade-helpers/layout-v2-reconcile.py"
RECONCILE_SH="$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh"

UNREADABLE_FILE=""
cleanup() {
  # Restore read on any chmod-000 fixture before rm -rf can trip on it.
  [[ -n "$UNREADABLE_FILE" && -e "$UNREADABLE_FILE" ]] && chmod 0644 "$UNREADABLE_FILE" 2>/dev/null || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd bash
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
fi
smoke_make_temp_root "$SMOKE_NAME"

IS_ROOT=0
[[ "$(id -u 2>/dev/null || echo 1)" == "0" ]] && IS_ROOT=1

# A small python probe over a result-JSON file: prints space-separated
#   <warnings_have_errno13> <iso_count> <iso_first_action> <v2_memory_drift>
# where v2_memory_drift is 1 if the v2 MEMORY.md content changed from baseline.
probe_result() {
  local json_file="$1" v2_mem="$2" baseline="$3"
  python3 "$REPO_ROOT/scripts/smoke/1820-iso-reconcile-permission-probe.py" \
    "$json_file" "$v2_mem" "$baseline"
}

# Write the probe helper file-as-argv (NO heredoc-stdin to a subprocess).
PROBE="$REPO_ROOT/scripts/smoke/1820-iso-reconcile-permission-probe.py"
# (Shipped alongside the smoke; assert it exists rather than generating it.)
smoke_assert_file_exists "$PROBE" "iso-reconcile probe helper"

run_engine() {
  # run_engine <bridge_home> <data_root> <agents_csv> <backup_root> [iso_json]
  local bh="$1" dr="$2" agents="$3" bkp="$4" iso="${5:-}"
  local -a argv=(
    "$ENGINE"
    --bridge-home "$bh"
    --data-root "$dr"
    --agents-csv "$agents"
    --mode apply
    --backup-root "$bkp"
  )
  [[ -n "$iso" ]] && argv+=(--iso-agents-json "$iso")
  python3 "${argv[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixture: one iso agent `isobot` whose v1 agent-private MEMORY.md is
# UNREADABLE (chmod 000) — the controller-blind 0600 stand-in. v2 home present
# with its own memory.
# ---------------------------------------------------------------------------
ISO_BH="$SMOKE_TMP_ROOT/iso/bh"
ISO_DR="$SMOKE_TMP_ROOT/iso/data"
mkdir -p "$ISO_BH/agents/isobot" "$ISO_DR/agents/isobot/home"
printf 'shared-line\nv1-only-line\n' >"$ISO_BH/agents/isobot/MEMORY.md"
printf 'shared-line\n' >"$ISO_DR/agents/isobot/home/MEMORY.md"
ISO_V2_MEM="$ISO_DR/agents/isobot/home/MEMORY.md"
# Snapshot the v2 memory to a baseline FILE (byte-exact, trailing-newline
# preserved) so the drift check is a file-vs-file compare, not a $(cat)
# string compare that would strip the trailing newline and false-positive.
ISO_V2_BASELINE="$SMOKE_TMP_ROOT/iso/v2-baseline.md"
cp "$ISO_V2_MEM" "$ISO_V2_BASELINE"
printf '{"isobot":"agent-bridge-isobot"}' >"$SMOKE_TMP_ROOT/iso/iso-agents.json"
ISO_MAP="$SMOKE_TMP_ROOT/iso/iso-agents.json"

# Make the v1 agent-private file unreadable to this (non-root) user.
chmod 000 "$ISO_BH/agents/isobot/MEMORY.md"
UNREADABLE_FILE="$ISO_BH/agents/isobot/MEMORY.md"

# ---------------------------------------------------------------------------
# T1 — WITH the iso map: graceful-skip, structured section, drift 0.
# ---------------------------------------------------------------------------
if [[ "$IS_ROOT" == "1" ]]; then
  smoke_log "T1/T2 SKIP: running as root (chmod 000 does not block root reads; needs a non-root run or a real iso install — see Linux re-gate)"
else
  T1_OUT="$(run_engine "$ISO_BH" "$ISO_DR" isobot "$SMOKE_TMP_ROOT/iso/bkp-with" "$ISO_MAP")"
  printf '%s' "$T1_OUT" >"$SMOKE_TMP_ROOT/iso/t1.json"
  read -r T1_ERRNO T1_ISOCOUNT T1_ACTION T1_DRIFT < <(probe_result "$SMOKE_TMP_ROOT/iso/t1.json" "$ISO_V2_MEM" "$ISO_V2_BASELINE")
  [[ "$T1_ERRNO" == "0" ]] || smoke_fail "T1 FAIL: an Errno13 perm-warning was emitted WITH the iso map (expected none)\n$T1_OUT"
  [[ "$T1_ISOCOUNT" == "1" ]] || smoke_fail "T1 FAIL: expected exactly 1 isolation_v2_migration entry, got $T1_ISOCOUNT\n$T1_OUT"
  [[ "$T1_ACTION" == "skipped-iso-private" ]] || smoke_fail "T1 FAIL: expected action skipped-iso-private, got '$T1_ACTION'\n$T1_OUT"
  [[ "$T1_DRIFT" == "0" ]] || smoke_fail "T1 FAIL: iso agent's v2 memory DRIFTED (must be untouched / drift 0)"
  smoke_log "T1 PASS: iso agent graceful-skipped — no Errno13, structured isolation_v2_migration(skipped-iso-private), v2 memory drift 0"

  # -------------------------------------------------------------------------
  # T2 — CONTROL: SAME fixture WITHOUT the iso map reproduces the cm-prod
  # symptom (Errno13 perm-warning + empty isolation_v2_migration).
  # -------------------------------------------------------------------------
  T2_OUT="$(run_engine "$ISO_BH" "$ISO_DR" isobot "$SMOKE_TMP_ROOT/iso/bkp-without")"
  printf '%s' "$T2_OUT" >"$SMOKE_TMP_ROOT/iso/t2.json"
  read -r T2_ERRNO T2_ISOCOUNT _T2A _T2D < <(probe_result "$SMOKE_TMP_ROOT/iso/t2.json" "$ISO_V2_MEM" "$ISO_V2_BASELINE")
  [[ "$T2_ERRNO" == "1" ]] || smoke_fail "T2 FAIL: WITHOUT the iso map the controller-blind read should still raise Errno13 (the symptom the fix removes); got none\n$T2_OUT"
  [[ "$T2_ISOCOUNT" == "0" ]] || smoke_fail "T2 FAIL: WITHOUT the iso map there must be no isolation_v2_migration entry, got $T2_ISOCOUNT"
  smoke_log "T2 PASS: control reproduces the cm-prod Errno13 symptom WITHOUT the iso map (so the iso map — not the chmod — is what suppresses it)"
fi

# ---------------------------------------------------------------------------
# T3 — CONTROL (shared-mode): a normal readable v1-superset agent reconciles
# exactly as before. Independent of root-ness (no chmod-000 here).
# ---------------------------------------------------------------------------
SH_BH="$SMOKE_TMP_ROOT/shared/bh"
SH_DR="$SMOKE_TMP_ROOT/shared/data"
mkdir -p "$SH_BH/agents/bot" "$SH_DR/agents/bot/home"
printf 'a\nb\n' >"$SH_BH/agents/bot/MEMORY.md"     # v1 superset
printf 'a\n' >"$SH_DR/agents/bot/home/MEMORY.md"    # v2 prefix
SH_OUT="$(run_engine "$SH_BH" "$SH_DR" bot "$SMOKE_TMP_ROOT/shared/bkp")"
printf '%s' "$SH_OUT" >"$SMOKE_TMP_ROOT/shared/out.json"
python3 "$PROBE" --shared-control "$SMOKE_TMP_ROOT/shared/out.json" "$SH_DR/agents/bot/home/MEMORY.md" \
  || smoke_fail "T3 FAIL: shared-mode reconcile DATA path changed (expected prefix_superset_v1 adopt, empty isolation_v2_migration, no warnings)\n$SH_OUT"
smoke_log "T3 PASS: shared-mode (non-iso) reconcile unchanged — v1-superset adopted into v2, isolation_v2_migration empty, no warnings"

# ---------------------------------------------------------------------------
# T4 — the wrapper's iso-agents-json builder. Stub the iso predicate + os-user
# resolver so no real iso UID is required: `iso-yes` is classified iso with a
# known os_user; `plain` is not. Assert the emitted JSON object.
# ---------------------------------------------------------------------------
T4_JSON="$("$BRIDGE_BASH" -c "
  cd '$REPO_ROOT'
  source lib/bridge-layout-v2-reconcile.sh >/dev/null 2>&1
  bridge_agent_linux_user_isolation_effective() { [[ \"\$1\" == 'iso-yes' ]]; }
  bridge_agent_os_user() { [[ \"\$1\" == 'iso-yes' ]] && printf 'agent-bridge-iso-yes'; }
  bridge_layout_v2_reconcile_iso_agents_json 'iso-yes,plain'
" 2>/dev/null)"
[[ "$T4_JSON" == '{"iso-yes":"agent-bridge-iso-yes"}' ]] \
  || smoke_fail "T4 FAIL: iso-agents-json builder wrong; expected {\"iso-yes\":\"agent-bridge-iso-yes\"}, got: $T4_JSON"
# And empty when nothing is iso.
T4_EMPTY="$("$BRIDGE_BASH" -c "
  cd '$REPO_ROOT'
  source lib/bridge-layout-v2-reconcile.sh >/dev/null 2>&1
  bridge_agent_linux_user_isolation_effective() { return 1; }
  bridge_agent_os_user() { return 0; }
  bridge_layout_v2_reconcile_iso_agents_json 'plain,other'
" 2>/dev/null)"
[[ "$T4_EMPTY" == '{}' ]] || smoke_fail "T4 FAIL: builder should emit {} when no agent is iso, got: $T4_EMPTY"
smoke_log "T4 PASS: iso-agents-json builder maps only effectively-iso agents to their os_user, {} otherwise"

# ---------------------------------------------------------------------------
# T5 — static tripwires bind the behavior to source.
# ---------------------------------------------------------------------------
grep -q '"isolation_v2_migration": self.isolation_v2_migration' "$ENGINE" \
  || smoke_fail "T5 FAIL: engine result no longer carries the isolation_v2_migration structured section"
grep -q 'skipped-iso-private' "$ENGINE" \
  || smoke_fail "T5 FAIL: engine lost the graceful-skip (skipped-iso-private) iso branch"
grep -q 'iso_agents.get(agent)' "$ENGINE" \
  || smoke_fail "T5 FAIL: engine no longer consults the iso-agents map before the controller-side memory pass"
grep -q -- '--iso-agents-json' "$RECONCILE_SH" \
  || smoke_fail "T5 FAIL: wrapper no longer passes --iso-agents-json to the engine"
grep -q 'bridge_layout_v2_reconcile_iso_agents_json' "$RECONCILE_SH" \
  || smoke_fail "T5 FAIL: wrapper lost the iso-agents-json builder"
smoke_log "T5 PASS: static tripwires — engine iso-skip branch + structured section + wrapper --iso-agents-json wiring all present"

smoke_log "all 1820-iso-reconcile-permission tests PASS"
