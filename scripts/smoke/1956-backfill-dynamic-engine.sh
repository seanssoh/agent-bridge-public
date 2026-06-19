#!/usr/bin/env bash
# 1956-backfill-dynamic-engine.sh -- Issue #1956 codex AGENTS.md doc-backfill
# resolves a DYNAMIC agent's engine authoritatively from the registry, not just
# the static roster.
#
# The bug (follow-up to #1892): the doc-backfill resolves engine authority ONLY
# from the static roster (BRIDGE_AGENT_ENGINE in the roster shell files). A
# DYNAMIC agent (`agb-dev-codex`, `crm-dev-codex`: source=dynamic) is never in
# that roster, so the #1892 fail-closed resolver sees roster_engine=unknown and
# HOLDS it forever — even when the agent genuinely lacks AGENTS.md and its engine
# is known authoritatively. The daemon publishes that authority in
# state/active-roster.tsv (the `engine` column = bridge_agent_engine, recorded
# from the agent's --codex/--claude launch flag).
#
# The fix: read state/active-roster.tsv as a strict FALLBACK below the static
# roster. The roster stays the source of truth for any id it declares; the
# registry only fills the dynamic-agent gap. The lookup is exact per-id (no
# heuristic), so the #1928 / #1892-T3 claude-agent guard is preserved exactly.
#
#   T1  DYNAMIC CODEX agent (registry engine=codex, NOT in the static roster,
#       no AGENTS.md) -> gets the AGENTS.md backfill (no longer held).
#   T2  DYNAMIC CLAUDE agent (registry engine=claude, NOT in the static roster)
#       with a codex-tripping CLAUDE.md -> does NOT get a codex AGENTS.md; the
#       registry engine=claude resolves to a non-codex skip/hold (T3 preserved).
#   T3  REGRESSION GUARD: the static roster still wins. A roster=claude agent
#       whose active-roster.tsv row says engine=codex must follow the ROSTER
#       (held/skip, never materialized) — the registry is a fallback, not an
#       override.
#   T4  MUTATION CONTROL: with NO active-roster.tsv at all, the dynamic codex
#       agent of T1 reverts to the #1892 fail-closed HOLD (proves T1's pass is
#       caused by the registry read, not by some unconditional backfill).
#
# Pure-python CLI surface (backfill-codex-entrypoints) driven against a temp
# BRIDGE_HOME — the operator's live tree is never touched and the test runs
# identically on macOS and Linux (no iso/daemon live paths needed).

set -euo pipefail

SMOKE_NAME="1956-backfill-dynamic-engine"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

setup_bridge_fixture() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_DATA_ROOT/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2"
}

# Write a static roster with an explicit engine declaration for $agent. Pass an
# empty engine to OMIT the BRIDGE_AGENT_ENGINE clause entirely (the dynamic case:
# the agent is NOT roster-declared, only registry-published).
write_roster() {
  local agent="$1"
  local engine="$2"
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    if [[ -n "$engine" ]]; then
      printf 'BRIDGE_AGENT_ENGINE["%s"]="%s"\n' "$agent" "$engine"
    fi
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
}

# Publish a state/active-roster.tsv row exactly as bridge_render_active_roster
# would: agent<TAB>engine<TAB>session<TAB>cwd<TAB>source<TAB>... The engine
# column (index 1) is the authoritative registry signal #1956 trusts. Appends so
# multiple dynamic agents can coexist; writes the header on first call.
write_active_roster_row() {
  local agent="$1"
  local engine="$2"
  local source="${3:-dynamic}"
  local tsv="$BRIDGE_STATE_DIR/active-roster.tsv"
  if [[ ! -f "$tsv" ]]; then
    printf 'agent\tengine\tsession\tcwd\tsource\tloop\tcontinue\tqueued\tclaimed\tsession_id\tupdated_at\n' >"$tsv"
  fi
  printf '%s\t%s\tagb-%s\t%s\t%s\t0\tauto\t0\t0\tsid-%s\t2026-06-17T00:00:00+00:00\n' \
    "$agent" "$engine" "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir" "$source" "$agent" >>"$tsv"
}

# A codex profile home missing its AGENTS.md (the thing the backfill should
# materialize). Codex-by-CLAUDE.md so detect_engine corroborates, but the
# authority under test is the registry engine, not the heuristic.
write_codex_profile_missing_agents_md() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  printf '# %s — Monitor (런타임: Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "precondition: profile already has AGENTS.md for $agent"
}

# A profile home whose CLAUDE.md TRIPS the codex filesystem heuristic ("Codex
# CLI") even though the agent's authoritative engine is claude — the T3 trap.
write_codex_tripping_profile() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  printf '# %s — Monitor (collab via Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

run_backfill() {
  local admin="$1"
  python3 "$REPO_ROOT/bridge-upgrade.py" backfill-codex-entrypoints \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$admin" 2>/dev/null
}

json_int() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],0))' "$1" "$2"
}

# ===========================================================================
# T1 — DYNAMIC CODEX agent (registry engine=codex, NOT roster-declared, no
#      AGENTS.md) gets the AGENTS.md backfill (no longer held).
# ===========================================================================
test_dynamic_codex_gets_backfill() {
  setup_bridge_fixture
  local agent=agb-dev-codex
  # NOT in the static roster (omit the engine clause; the roster declares an
  # unrelated admin so roster-filtering stays "active").
  write_roster admin-placeholder ""
  write_active_roster_row "$agent" codex dynamic
  write_codex_profile_missing_agents_md "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill admin-placeholder)"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t1.json"

  smoke_assert_file_exists "$profile/AGENTS.md" \
    "T1: a dynamic codex agent (registry engine=codex) was NOT backfilled (held forever)"
  smoke_assert_contains "$summary" "\"backfilled\"" "T1: summary missing the backfilled list"
  smoke_assert_contains "$summary" "$agent" "T1: backfilled summary did not name the dynamic codex agent"
  smoke_assert_eq "0" "$(json_int "$SMOKE_TMP_ROOT/t1.json" held_count)" \
    "T1: a registry-codex dynamic agent was spuriously held"
}

# ===========================================================================
# T2 — DYNAMIC CLAUDE agent (registry engine=claude) with a codex-tripping
#      CLAUDE.md does NOT get a codex AGENTS.md (T3 / #1928 guard preserved).
# ===========================================================================
test_dynamic_claude_not_backfilled() {
  setup_bridge_fixture
  local agent=crm-dev
  write_roster admin-placeholder ""
  write_active_roster_row "$agent" claude dynamic
  write_codex_tripping_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill admin-placeholder)"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t2.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T2: a dynamic claude agent got a spurious codex AGENTS.md (#1928 / T3 breach)"
  smoke_assert_eq "0" "$(json_int "$SMOKE_TMP_ROOT/t2.json" backfilled_count)" \
    "T2: a dynamic claude agent was codex-backfilled"
}

# ===========================================================================
# T3 — REGRESSION GUARD: the static roster wins over the registry. A
#      roster=claude agent whose active-roster.tsv row says engine=codex must
#      follow the ROSTER (held, never a codex backfill) — registry is a fallback,
#      not an override.
# ===========================================================================
test_static_roster_wins_over_registry() {
  setup_bridge_fixture
  local agent=t3rosterclaude
  write_roster "$agent" claude          # static roster: engine=claude
  write_active_roster_row "$agent" codex static   # registry disagrees (codex)
  write_codex_tripping_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t3.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T3: the registry codex row overrode the roster claude SoT (codex AGENTS.md materialized)"
  smoke_assert_eq "0" "$(json_int "$SMOKE_TMP_ROOT/t3.json" backfilled_count)" \
    "T3: a roster=claude agent was codex-backfilled because the registry said codex"
}

# ===========================================================================
# T4 — MUTATION CONTROL: remove active-roster.tsv entirely; the T1 dynamic codex
#      agent reverts to the #1892 fail-closed HOLD. Proves T1's backfill is
#      caused by the registry read, not by an unconditional backfill (the smoke
#      is non-vacuous).
# ===========================================================================
test_no_registry_reverts_to_hold() {
  setup_bridge_fixture
  local agent=agb-dev-codex
  write_roster admin-placeholder ""
  # Deliberately do NOT publish active-roster.tsv — no registry signal at all.
  write_codex_profile_missing_agents_md "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  # active-roster.tsv must be absent for this agent to fall through to #1892.
  # collect_roster_ids needs SOME roster source to keep filtering "active";
  # publish a header-only TSV (no rows) so the file exists but holds no engine.
  printf 'agent\tengine\tsession\tcwd\tsource\tloop\tcontinue\tqueued\tclaimed\tsession_id\tupdated_at\n' \
    >"$BRIDGE_STATE_DIR/active-roster.tsv"
  # The agent is still discoverable via aggregate so roster-filtering keeps it.
  printf 'agent\tactive\tactivity_state\tupdated_at\n%s\t1\tidle\t2026-06-17T00:00:00+00:00\n' \
    "$agent" >"$BRIDGE_STATE_DIR/agents-aggregate.tsv"

  local summary=""
  summary="$(run_backfill admin-placeholder)"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t4.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T4: without a registry engine the agent was backfilled anyway (T1 was vacuous)"
  smoke_assert_eq "0" "$(json_int "$SMOKE_TMP_ROOT/t4.json" backfilled_count)" \
    "T4: backfilled with no authoritative engine (registry read is not what drove T1)"
  smoke_assert_eq "1" "$(json_int "$SMOKE_TMP_ROOT/t4.json" held_count)" \
    "T4: an engine-unknown dynamic agent was not held (fail-closed regressed)"
}

smoke_run "T1 dynamic codex agent (registry engine=codex) gets the AGENTS.md backfill" \
  test_dynamic_codex_gets_backfill
smoke_run "T2 dynamic claude agent (registry engine=claude) is NOT codex-backfilled (T3 guard)" \
  test_dynamic_claude_not_backfilled
smoke_run "T3 static roster wins over the registry (roster=claude beats registry=codex)" \
  test_static_roster_wins_over_registry
smoke_run "T4 mutation control: no active-roster.tsv -> #1892 fail-closed HOLD (non-vacuous)" \
  test_no_registry_reverts_to_hold
smoke_log "PASS: $SMOKE_NAME"
