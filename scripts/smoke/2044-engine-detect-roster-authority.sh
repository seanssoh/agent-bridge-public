#!/usr/bin/env bash
# 2044-engine-detect-roster-authority.sh -- Issue #2044: the codex-AGENTS.md
# doc-backfill engine-detection must TRUST the roster-authoritative engine over
# filesystem codex residue, and must NOT regenerate a recurring `[hygiene]` task
# for a roster-declared CLAUDE agent every pass.
#
# The bug: a roster-declared CLAUDE agent that carries filesystem codex residue
# (a resolved `런타임: Codex CLI` line in CLAUDE.md, or live codex-delegation
# tooling) was held NON-CLEAN every pass — `detect_engine` guessed `codex`, the
# roster said `claude`, and the disagreement filed a task-generating `[hygiene]`
# FYI. Because nothing ever resolves (the agent IS authoritatively claude; the
# residue is legitimate), the same task re-fired 4+ times on the live fleet.
#
# The fix makes a roster-AUTHORITATIVE non-codex declaration win over the
# filesystem heuristic: such an agent is HELD QUIETLY (held_quiet) — still
# fail-closed (no spurious codex AGENTS.md materialized), but never counted as
# non-clean, so it converges to a no-task steady state. A genuinely
# engine-UNKNOWN agent (no roster declaration) stays task-generating, and a
# genuine roster-codex agent still backfills.
#
#   T1  roster=claude + codex-residue CLAUDE.md -> HELD QUIETLY: no AGENTS.md
#       materialized, NOT re-classified codex (held_count=0, held_quiet_count=1),
#       and the pass is CLEAN (non-clean=0 — no recurring [hygiene] task).
#   T2  IDEMPOTENT: a second pass over the same roster-claude agent emits NO new
#       task either (non-clean stays 0; the agent never converges to codex).
#   T3  NEGATIVE CONTROL — real codex detection unbroken: a roster-codex agent
#       missing AGENTS.md still backfills (held_quiet stays 0).
#   T4  CONTRAST — engine genuinely UNKNOWN (no roster declaration) + codex
#       residue stays the TASK-GENERATING hold (held_count=1, non-clean=1): the
#       quiet path is reserved for roster-AUTHORITATIVE agents only.
#   T5  MUTATION GUARD: reverting the roster-authority precedence (treating the
#       roster-claude case like the unknown case) would make T1 non-clean again
#       — asserted by proving the roster-claude pass is distinguishable from the
#       engine-unknown pass (claude -> clean; unknown -> non-clean).
#
# Pure-python CLI surfaces (backfill-codex-entrypoints + daemon-helpers) driven
# against a temp BRIDGE_HOME — the operator's live tree is never touched and the
# test runs identically on macOS and Linux (no iso/daemon live paths needed).

set -euo pipefail

SMOKE_NAME="2044-engine-detect-roster-authority"
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

# Single-agent roster with an explicit engine declaration. Empty engine OMITS
# the BRIDGE_AGENT_ENGINE clause (the engine-genuinely-unknown case).
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

# A claude profile whose CLAUDE.md TRIPS the codex filesystem heuristic (carries
# a resolved `런타임: Codex CLI` runtime declaration — the exact residue that the
# six live fleet agents carried). Stands in for the legitimate codex-delegation
# tooling reference the issue calls out.
write_codex_residue_profile() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  printf '# %s — Monitor (런타임: Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
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

json_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],0))' "$1" "$2"
}

# ===========================================================================
# T1 — roster=claude + codex residue: HELD QUIETLY, CLEAN, not re-classified.
# ===========================================================================
test_roster_claude_codex_residue_held_quiet_clean() {
  setup_bridge_fixture
  local agent=mailbot
  write_roster "$agent" claude
  write_codex_residue_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t1.json"

  # Fail-closed preserved: no spurious codex AGENTS.md on the claude agent.
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T1: roster-claude agent got a spurious codex AGENTS.md (fail-closed breach)"
  # Not backfilled, not in the task-generating held; recorded under held_quiet.
  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/t1.json" backfilled_count)" \
    "T1: a roster-claude agent was backfilled (must be held quietly)"
  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/t1.json" held_count)" \
    "T1: a roster-authoritative claude agent landed in the task-generating held list"
  smoke_assert_eq "1" "$(json_field "$SMOKE_TMP_ROOT/t1.json" held_quiet_count)" \
    "T1: the roster-claude agent was not recorded under held_quiet"
  smoke_assert_contains "$summary" "$agent" "T1: held_quiet summary did not name the claude agent"
  # CLEAN — no recurring [hygiene] task is filed for a roster-authoritative claude.
  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/t1.json")" \
    "T1: a roster-authoritative claude agent was reported non-clean (recurring hygiene task)"
}

# ===========================================================================
# T2 — IDEMPOTENT: a SECOND pass over the same roster-claude agent files NO new
#      task (non-clean stays 0). This is the convergence the 4x recurrence broke.
# ===========================================================================
test_second_pass_is_idempotent() {
  setup_bridge_fixture
  local agent=syrs_fi
  write_roster "$agent" claude
  write_codex_residue_profile "$agent"

  local p1="" p2=""
  p1="$(run_backfill "$agent")"; printf '%s' "$p1" >"$SMOKE_TMP_ROOT/t2-pass1.json"
  p2="$(run_backfill "$agent")"; printf '%s' "$p2" >"$SMOKE_TMP_ROOT/t2-pass2.json"

  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/t2-pass1.json")" \
    "T2: pass 1 over a roster-claude agent was non-clean"
  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/t2-pass2.json")" \
    "T2: pass 2 regenerated a hygiene task for the same roster-claude agent (NOT idempotent)"
  # The agent is held_quiet on BOTH passes — it never converges to codex.
  smoke_assert_eq "1" "$(json_field "$SMOKE_TMP_ROOT/t2-pass2.json" held_quiet_count)" \
    "T2: the roster-claude agent stopped being held_quiet on the second pass"
}

# ===========================================================================
# T3 — NEGATIVE CONTROL: a genuine roster-codex agent missing AGENTS.md still
#      backfills (the quiet-hold path must not over-block real codex detection).
# ===========================================================================
test_real_codex_still_detected_and_backfilled() {
  setup_bridge_fixture
  local agent=realcodex
  write_roster "$agent" codex
  write_codex_profile_missing_agents_md "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t3.json"

  smoke_assert_file_exists "$profile/AGENTS.md" \
    "T3: a genuine codex agent was NOT backfilled (real codex detection broken)"
  smoke_assert_contains "$summary" "$agent" "T3: backfilled summary did not name the codex agent"
  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/t3.json" held_quiet_count)" \
    "T3: a genuine codex agent was spuriously held_quiet"
  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/t3.json" held_count)" \
    "T3: a genuine codex agent was spuriously held"
}

# ===========================================================================
# T4 — CONTRAST: engine genuinely UNKNOWN (no roster declaration) + codex
#      residue stays the TASK-GENERATING hold. The quiet path is reserved for
#      roster-AUTHORITATIVE agents only.
# ===========================================================================
test_engine_unknown_still_task_generating() {
  setup_bridge_fixture
  local agent=t4unknown
  write_roster "$agent" ""    # omit BRIDGE_AGENT_ENGINE entirely
  write_codex_residue_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t4.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T4: an engine-unknown agent got a codex AGENTS.md from a filesystem guess"
  smoke_assert_eq "1" "$(json_field "$SMOKE_TMP_ROOT/t4.json" held_count)" \
    "T4: an engine-unknown agent was not held (task-generating) — quiet path leaked to unknowns"
  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/t4.json" held_quiet_count)" \
    "T4: an engine-unknown agent was held_quiet (the quiet path must be roster-authoritative only)"
  smoke_assert_eq "1" "$(non_clean_of "$SMOKE_TMP_ROOT/t4.json")" \
    "T4: a genuinely-ambiguous engine-unknown agent was reported clean (operator would never see it)"
}

# ===========================================================================
# T5 — MUTATION GUARD: the roster-claude pass MUST be distinguishable from the
#      engine-unknown pass — claude is clean, unknown is non-clean. If the
#      roster-authority precedence is reverted (claude treated like unknown),
#      both would be non-clean and this assertion fails.
# ===========================================================================
test_roster_authority_distinguishes_claude_from_unknown() {
  # roster-claude -> clean
  setup_bridge_fixture
  local a=syrs_meta
  write_roster "$a" claude
  write_codex_residue_profile "$a"
  run_backfill "$a" >"$SMOKE_TMP_ROOT/t5-claude.json"
  local claude_nc=""; claude_nc="$(non_clean_of "$SMOKE_TMP_ROOT/t5-claude.json")"

  # engine-unknown -> non-clean
  setup_bridge_fixture
  local b=t5unknown
  write_roster "$b" ""
  write_codex_residue_profile "$b"
  run_backfill "$b" >"$SMOKE_TMP_ROOT/t5-unknown.json"
  local unknown_nc=""; unknown_nc="$(non_clean_of "$SMOKE_TMP_ROOT/t5-unknown.json")"

  smoke_assert_eq "0" "$claude_nc" \
    "T5: roster-authoritative claude was non-clean (roster-authority precedence reverted?)"
  smoke_assert_eq "1" "$unknown_nc" \
    "T5: engine-unknown was clean (the contrast that proves roster-authority is the discriminator)"
  [[ "$claude_nc" != "$unknown_nc" ]] \
    || smoke_fail "T5: roster-claude and engine-unknown are indistinguishable — roster authority is not enforced"
}

# ===========================================================================
# T6 — the ``unknown`` SENTINEL is not an authoritative engine: a roster that
#      literally declares engine=unknown + codex residue must stay the
#      TASK-GENERATING hold (held_count=1, held_quiet_count=0, non-clean=1), NOT
#      the quiet path. Guards the resolver's `unknown`->absent normalization so a
#      hand-edited / sentinel `unknown` never sneaks into the roster-authoritative
#      non-codex branch.
# ===========================================================================
test_unknown_sentinel_stays_task_generating() {
  setup_bridge_fixture
  local agent=t6unknownsentinel
  write_roster "$agent" unknown
  write_codex_residue_profile "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/t6.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T6: an engine=unknown-sentinel agent got a codex AGENTS.md"
  smoke_assert_eq "1" "$(json_field "$SMOKE_TMP_ROOT/t6.json" held_count)" \
    "T6: an engine=unknown-sentinel agent was not held (task-generating) — sentinel leaked into the authoritative branch"
  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/t6.json" held_quiet_count)" \
    "T6: an engine=unknown-sentinel agent was held_quiet (the quiet path must be a POSITIVE non-codex declaration only)"
  smoke_assert_eq "1" "$(non_clean_of "$SMOKE_TMP_ROOT/t6.json")" \
    "T6: an engine=unknown-sentinel agent was reported clean (genuinely-unresolved engine must stay operator-visible)"
}

smoke_run "T1 roster=claude + codex residue is held_quiet + CLEAN (no recurring task)" \
  test_roster_claude_codex_residue_held_quiet_clean
smoke_run "T2 idempotent: a 2nd pass over a roster-claude agent files no new task" \
  test_second_pass_is_idempotent
smoke_run "T3 negative control: a genuine roster-codex agent still backfills" \
  test_real_codex_still_detected_and_backfilled
smoke_run "T4 contrast: engine-unknown + codex residue stays task-generating" \
  test_engine_unknown_still_task_generating
smoke_run "T5 mutation guard: roster authority distinguishes claude (clean) from unknown (non-clean)" \
  test_roster_authority_distinguishes_claude_from_unknown
smoke_run "T6 unknown sentinel stays task-generating (not the quiet path)" \
  test_unknown_sentinel_stays_task_generating
smoke_log "PASS: $SMOKE_NAME"
