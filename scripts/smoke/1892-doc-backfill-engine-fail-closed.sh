#!/usr/bin/env bash
# 1892-doc-backfill-engine-fail-closed.sh -- Issue #1892 codex AGENTS.md
# doc-backfill engine-detection FAIL-CLOSED when the authoritative engine signal
# (state/agents/<a>/agent-meta.env) is absent.
#
# The bug: when agent-meta.env is absent, the daemon doc-backfill +
# watchdog engine-detection lose the engine signal and the filesystem heuristic
# (`detect_engine`: a CLAUDE.md that mentions "Codex CLI") could materialize a
# spurious codex AGENTS.md onto an agent the roster declares engine=claude
# (observed: cosmax_sales_mdj — roster=claude, live Teams bot, got a 6 KB codex
# AGENTS.md backfilled). Destructive (wrong template) + a registry-map gap.
#
# The fix makes the ROSTER engine the source of truth (parsed statically from
# the roster shell files) and fails closed: absence of a positive claude signal
# must NEVER be inferred as a positive codex signal, and a roster/heuristic
# disagreement HOLDS (operator-visible warning) instead of materializing.
#
#   T1  claude-roster agent whose CLAUDE.md trips the codex heuristic ("Codex
#       CLI"), agent-meta.env ABSENT -> HELD, no AGENTS.md written, non-clean=1,
#       and the [hygiene] task body names the held agent + the disagreement.
#   T2  claude-roster agent with a clean CLAUDE.md (heuristic agrees claude) ->
#       skipped, no AGENTS.md, clean (non-clean=0, no spurious task).
#   T3  NEGATIVE CONTROL: a real codex-roster agent missing AGENTS.md still
#       backfills (the fail-closed gate does not over-block).
#   T4  agent with NO roster engine declaration + a codex-tripping CLAUDE.md ->
#       HELD (fail-closed on a bare filesystem guess), never materialized.
#   T5  AMBIGUOUS roster engine RHS — shell-expansion-tainted
#       (`="codex"$VAR`), trailing junk (`=codex extra`), ;-chained
#       multi-assignment (`=codex; ...=claude`), and whitespace-less `#`
#       (`=codex#junk` / `="codex"#junk`, value `codex#junk` not `codex`) —
#       must NOT be read as a positive codex declaration -> engine-unknown ->
#       HELD, never codex (guards the fail-closed whole-line RHS tokenization).
#   T6  multiple WHOLE-LINE assignments to the same agent honor shell last-wins:
#       a later claude line overrides an earlier codex line -> effective engine
#       claude -> HELD (not a codex backfill).
#
# Pure-python CLI surfaces (backfill-codex-entrypoints + daemon-helpers) driven
# against a temp BRIDGE_HOME — the operator's live tree is never touched and the
# test runs identically on macOS and Linux (no iso/daemon live paths needed).

set -euo pipefail

SMOKE_NAME="1892-doc-backfill-engine-fail-closed"
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

# Write a single-agent roster with an explicit engine declaration. Pass an
# empty engine to OMIT the BRIDGE_AGENT_ENGINE clause entirely (T4: no roster
# engine signal at all).
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

# A profile home whose CLAUDE.md TRIPS the codex filesystem heuristic (mentions
# "Codex CLI"), with NO agent-meta.env present anywhere (the absent-signal case).
write_codex_tripping_profile() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  # No SESSION-TYPE.md Session Type line that forces static-codex; the engine
  # signal must come from the roster, not the session type. The CLAUDE.md string
  # "Codex CLI" is exactly what would make detect_engine() guess codex.
  printf '# %s — Monitor (collab via Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
  # Affirmatively assert the absent-signal precondition.
  [[ ! -f "$BRIDGE_STATE_DIR/agents/$agent/agent-meta.env" ]] \
    || smoke_fail "precondition: agent-meta.env unexpectedly present for $agent"
}

# A profile home with a clean claude CLAUDE.md (heuristic agrees claude).
write_clean_claude_profile() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  printf '# %s — Monitor (런타임: Claude Code CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

# A genuine codex profile home missing its AGENTS.md (the negative control).
write_codex_profile_missing_agents_md() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$profile/SESSION-TYPE.md"
  printf '# %s — Monitor (런타임: Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "precondition: codex profile already has AGENTS.md for $agent"
}

run_backfill() {
  local agent="$1"
  python3 "$REPO_ROOT/bridge-upgrade.py" backfill-codex-entrypoints \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" 2>/dev/null
}

non_clean_of() {
  python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-non-clean "$1"
}

# ===========================================================================
# T1 — claude-roster agent, codex-tripping CLAUDE.md, agent-meta.env ABSENT:
#      HELD, NOT materialized; non-clean=1; task body names the held agent.
# ===========================================================================
test_claude_roster_codex_heuristic_is_held() {
  setup_bridge_fixture
  local agent=cosmax_sales_mdj
  write_roster "$agent" claude
  write_codex_tripping_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t1.json"

  # CRITICAL: no spurious codex AGENTS.md materialized on the claude agent.
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T1: claude-roster agent got a spurious codex AGENTS.md (fail-closed breach)"
  # Held, NOT backfilled.
  smoke_assert_contains "$summary" "\"held\"" "T1: summary missing the held list"
  smoke_assert_contains "$summary" "$agent" "T1: held summary did not name the claude agent"
  local backfilled_count=""
  backfilled_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("backfilled_count",0))' "$SMOKE_TMP_ROOT/t1.json")"
  smoke_assert_eq "0" "$backfilled_count" "T1: a claude agent was backfilled (must be held)"

  # Non-clean so the operator gets the warning task.
  smoke_assert_eq "1" "$(non_clean_of "$SMOKE_TMP_ROOT/t1.json")" \
    "T1: a held disagreement was not reported non-clean (operator would never see it)"

  # The [hygiene] task body names the held agent + the disagreement.
  local body=""
  body="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-task-body \
    "$SMOKE_TMP_ROOT/t1.json" testhost)"
  smoke_assert_contains "$body" "Held" "T1: task body missing the Held section"
  smoke_assert_contains "$body" "$agent" "T1: task body did not name the held agent"
  smoke_assert_contains "$body" "roster_engine=claude" \
    "T1: task body did not surface the roster engine for the held agent"
}

# ===========================================================================
# T2 — claude-roster agent, clean claude CLAUDE.md: skipped, no AGENTS.md,
#      clean pass (no spurious task).
# ===========================================================================
test_claude_roster_clean_is_skipped() {
  setup_bridge_fixture
  local agent=t2claude
  write_roster "$agent" claude
  write_clean_claude_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t2.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T2: clean claude agent received an AGENTS.md (codex-only breach)"
  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/t2.json")" \
    "T2: a clean claude-skip pass was reported non-clean (spurious [hygiene] task)"
  local held_count=""
  held_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("held_count",0))' "$SMOKE_TMP_ROOT/t2.json")"
  smoke_assert_eq "0" "$held_count" "T2: a clean claude agent was spuriously held"
}

# ===========================================================================
# T3 — NEGATIVE CONTROL: a genuine codex-roster agent missing AGENTS.md still
#      backfills (the fail-closed gate must not over-block real codex agents).
# ===========================================================================
test_codex_roster_still_backfills() {
  setup_bridge_fixture
  local agent=t3codex
  write_roster "$agent" codex
  write_codex_profile_missing_agents_md "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t3.json"

  smoke_assert_file_exists "$profile/AGENTS.md" \
    "T3: a genuine codex agent was NOT backfilled (fail-closed over-blocked)"
  smoke_assert_contains "$summary" "\"backfilled\"" "T3: summary missing the backfilled list"
  smoke_assert_contains "$summary" "$agent" "T3: backfilled summary did not name the codex agent"
  local held_count=""
  held_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("held_count",0))' "$SMOKE_TMP_ROOT/t3.json")"
  smoke_assert_eq "0" "$held_count" "T3: a genuine codex agent was spuriously held"
}

# ===========================================================================
# T4 — NO roster engine declaration + codex-tripping CLAUDE.md: HELD
#      (fail-closed on a bare filesystem guess), never materialized.
# ===========================================================================
test_no_roster_engine_codex_guess_is_held() {
  setup_bridge_fixture
  local agent=t4noengine
  write_roster "$agent" ""    # omit BRIDGE_AGENT_ENGINE entirely
  write_codex_tripping_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t4.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T4: an engine-unknown agent got a codex AGENTS.md from a filesystem guess"
  smoke_assert_contains "$summary" "$agent" "T4: held summary did not name the engine-unknown agent"
  smoke_assert_eq "1" "$(non_clean_of "$SMOKE_TMP_ROOT/t4.json")" \
    "T4: a held engine-unknown agent was not reported non-clean"
  local body=""
  body="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-task-body \
    "$SMOKE_TMP_ROOT/t4.json" testhost)"
  smoke_assert_contains "$body" "roster_engine=unknown" \
    "T4: task body did not surface roster_engine=unknown for the held agent"
}

# ===========================================================================
# T5 — an AMBIGUOUS / shell-expansion-tainted roster engine RHS (e.g.
#      `BRIDGE_AGENT_ENGINE["x"]="codex"$VAR`) must NOT resolve to a positive
#      codex declaration: the static parser rejects it (engine stays unknown),
#      so a codex-tripping CLAUDE.md alongside it is HELD, never materialized.
#      Guards the fail-closed tokenization (no expansion-tainted value is ever
#      read as an authoritative `codex`).
# ===========================================================================
# Assert a hand-written roster ENGINE clause does NOT resolve to a positive
# codex backfill: no AGENTS.md materialized, held non-clean, roster_engine=unknown.
assert_engine_clause_is_held() {
  local label="$1"
  local agent="$2"
  local engine_clause="$3"
  setup_bridge_fixture
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf '%s\n' "$engine_clause"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
  write_codex_tripping_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/$agent.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "$label: ambiguous engine clause materialized a codex AGENTS.md (fail-closed breach)"
  local backfilled_count=""
  backfilled_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("backfilled_count",0))' "$SMOKE_TMP_ROOT/$agent.json")"
  smoke_assert_eq "0" "$backfilled_count" "$label: an ambiguous-engine agent was backfilled as codex"
  smoke_assert_eq "1" "$(non_clean_of "$SMOKE_TMP_ROOT/$agent.json")" \
    "$label: the held ambiguous-engine agent was not reported non-clean"
  local body=""
  body="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-task-body \
    "$SMOKE_TMP_ROOT/$agent.json" testhost)"
  smoke_assert_contains "$body" "roster_engine=unknown" \
    "$label: the ambiguous clause was not treated as engine-unknown (must NOT count as codex)"
}

test_expansion_tainted_engine_never_resolves_codex() {
  # The scaffolder never emits these, but a hand-edited roster could. Each RHS
  # below has a runtime value that is NOT a bare, statically-resolvable `codex`,
  # so the parser must decline it (engine unknown -> held), never materialize.
  local agent=t5tainted
  # (a) shell-expansion-tainted: value is `codex<expansion>`.
  assert_engine_clause_is_held "T5a expansion-tainted" "${agent}a" \
    "BRIDGE_AGENT_ENGINE[\"${agent}a\"]=\"codex\"\$BRIDGE_ENGINE_SUFFIX"
  # (b) trailing junk after the value.
  assert_engine_clause_is_held "T5b trailing-junk" "${agent}b" \
    "BRIDGE_AGENT_ENGINE[\"${agent}b\"]=codex extra-token"
  # (c) ;-chained multi-assignment on one line: shell last-wins (claude) is NOT
  #     statically resolvable, so the whole line is declined (NOT read as the
  #     first `codex` clause).
  assert_engine_clause_is_held "T5c chained-multi-assign" "${agent}c" \
    "BRIDGE_AGENT_ENGINE[\"${agent}c\"]=codex; BRIDGE_AGENT_ENGINE[\"${agent}c\"]=claude"
  # (d) adjacent `#` with NO preceding whitespace is NOT a shell comment — the
  #     value is `codex#junk`, not `codex`, so it must be declined (held).
  assert_engine_clause_is_held "T5d unquoted-hash-adjacent" "${agent}d" \
    "BRIDGE_AGENT_ENGINE[\"${agent}d\"]=codex#junk"
  assert_engine_clause_is_held "T5e quoted-hash-adjacent" "${agent}e" \
    "BRIDGE_AGENT_ENGINE[\"${agent}e\"]=\"codex\"#junk"
}

# ===========================================================================
# T6 — multiple WHOLE-LINE assignments to the same agent: shell last-wins. A
#      later claude line must override an earlier codex line (the live roster +
#      local override both source in order). Codex-tripping CLAUDE.md present;
#      the effective engine is claude -> HELD (disagreement), never backfilled.
# ===========================================================================
test_multiline_last_assignment_wins() {
  setup_bridge_fixture
  local agent=t6lastwins
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="codex"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
  write_codex_tripping_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t6.json"

  # Effective engine is claude (last assignment) + the CLAUDE.md trips the codex
  # heuristic -> disagreement -> HELD, never a codex backfill.
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T6: last-wins claude was overridden by an earlier codex line (codex AGENTS.md materialized)"
  local body=""
  body="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-task-body \
    "$SMOKE_TMP_ROOT/t6.json" testhost)"
  smoke_assert_contains "$body" "roster_engine=claude" \
    "T6: the effective (last-assignment) roster engine was not claude"
}

smoke_run "T1 claude-roster + codex heuristic + absent agent-meta.env is HELD (not materialized)" \
  test_claude_roster_codex_heuristic_is_held
smoke_run "T2 claude-roster + clean CLAUDE.md is skipped (clean, no task)" \
  test_claude_roster_clean_is_skipped
smoke_run "T3 negative control: a genuine codex-roster agent still backfills" \
  test_codex_roster_still_backfills
smoke_run "T4 no roster engine + codex heuristic is HELD (fail-closed on a guess)" \
  test_no_roster_engine_codex_guess_is_held
smoke_run "T5 ambiguous codex RHS (expansion/junk/;-chained) never resolves codex (HELD)" \
  test_expansion_tainted_engine_never_resolves_codex
smoke_run "T6 multi-line same-agent assignment: shell last-wins (claude overrides codex)" \
  test_multiline_last_assignment_wins
smoke_log "PASS: $SMOKE_NAME"
