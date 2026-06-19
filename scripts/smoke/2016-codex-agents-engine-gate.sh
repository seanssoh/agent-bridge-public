#!/usr/bin/env bash
# 2016-codex-agents-engine-gate.sh -- Issue #2016: the upgrade migrate pass must
# NEVER emit the codex `codex/AGENTS.md` operating contract onto a non-codex
# agent home, in EITHER materialization location, and the existing residue scan
# must surface a pre-gate `codex/AGENTS.md` copy (the latent 2nd location).
#
# The bug: `migrate_agent_home`'s `template_root.rglob("*")` copied the
# codex-only `_template/codex/AGENTS.md` into EVERY agent home regardless of
# engine, producing a self-contradictory `home/codex/AGENTS.md` on a claude
# agent (codex identity line, claude runtime). That stray codex-contract file
# then makes the doc-backfill `detect_engine` heuristic keep flagging the agent
# as codex -> a benign-but-permanent `[hygiene] engine disagreement` hold that
# re-fires every upgrade/backfill pass. Past cleanups only removed the WORKDIR
# copy, so the `home/codex` copy survived (cm-prod 2-location finding).
#
# The fix engine-gates the codex subtree on the ROSTER engine (authoritative,
# independent of the detect_engine heuristic), so a claude agent never gets the
# file in the first place; codex agents keep their legitimate AGENTS.md.
#
#   P1  claude-roster agent (whose CLAUDE.md trips the OLD bare-substring
#       heuristic via the shipped `(예: Codex CLI)` prose) -> migrate emits NO
#       `codex/AGENTS.md` in its home. The roster engine gate fires even when the
#       filesystem heuristic mis-guesses codex (proves roster-authority).
#   P2  NEGATIVE CONTROL: a genuine codex-roster agent STILL gets its
#       `codex/AGENTS.md` materialized (no regression to a real codex agent).
#   P3  ROSTER-UNAVAILABLE FALLBACK: with no parseable roster the gate falls back
#       to the detect_engine heuristic; a plain claude profile (no codex signal
#       at all) still gets NO `codex/AGENTS.md`.
#   P4  RESIDUE FLAG (existing-file path): a claude-roster agent that ALREADY
#       carries a spurious `codex/AGENTS.md` (a pre-gate install) is surfaced in
#       the backfill pass's `engine_mismatch_docs` (doc=`codex/AGENTS.md`),
#       REPORT-ONLY — the file is byte-identical and never renamed/deleted.
#   P5  HAND-AUTHORED PRESERVE: a claude-roster agent with a hand-authored
#       `codex/AGENTS.md` that does NOT carry the codex contract marker is NOT
#       flagged (signature-scoped) and is left untouched.
#   P6  TSV-ONLY DYNAMIC AGENT: a claude agent present ONLY in
#       state/active-roster.tsv (engine in column 2, never in a shell roster)
#       whose CLAUDE.md trips the heuristic still gets NO codex/AGENTS.md — the
#       gate resolves the roster engine from the TSV too, not just shell rosters.
#
# Mutation check (non-vacuous): reverting the migrate gate (copy the codex
# subtree unconditionally) makes P1 emit `home/codex/AGENTS.md` and fail.
#
# Pure-python CLI surface (migrate-agents + backfill-codex-entrypoints) driven
# against a temp BRIDGE_HOME — the operator's live tree is never touched; runs
# identically on macOS and Linux. No heredoc-stdin / `<<<` / `< <()` procsub /
# `| grep -q` (lint-heredoc-ban H3 + #1813 SIGPIPE): printf-built fixtures +
# `python3 -c`, pure-bash `[[ == ]]`.

set -euo pipefail

SMOKE_NAME="2016-codex-agents-engine-gate"
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

# A single-agent roster with an explicit engine declaration.
write_roster() {
  local agent="$1"
  local engine="$2"
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="%s"\n' "$agent" "$engine"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
}

# Write state/active-roster.tsv with a single ACTIVE/dynamic agent row whose
# engine is declared in column 2 (the live layout: agent\tengine\tsession\t…).
# Used for the dynamic-agent case where the agent exists ONLY in this TSV and
# NOT in any shell roster (so collect_roster_engines alone would miss it).
write_active_roster_tsv() {
  local agent="$1"
  local engine="$2"
  mkdir -p "$BRIDGE_STATE_DIR"
  {
    printf 'agent\tengine\tsession\tcwd\tsource\tloop\tcontinue\tqueued\tclaimed\tsession_id\tupdated_at\n'
    printf '%s\t%s\tagb-%s\t%s\tdynamic\t0\t0\t0\t0\t-\t-\n' \
      "$agent" "$engine" "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_STATE_DIR/active-roster.tsv"
}

# A claude profile whose CLAUDE.md carries the shipped COMMON-INSTRUCTIONS prose
# `(예: Codex CLI)` that trips the OLD bare-substring detect_engine heuristic.
write_claude_profile_tripping_prose() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$profile"
  printf '# %s — Monitor\n\n' "$agent" >"$profile/CLAUDE.md"
  printf '%s\n' '런타임에 background subagent 기능이 없으면(예: Codex CLI) 이 섹션은 적용하지 않는다.' \
    >>"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

# A plain claude profile with NO codex signal anywhere (heuristic returns claude).
write_plain_claude_profile() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$profile"
  printf '# %s — Monitor (런타임: Claude Code CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

# A genuine codex profile: a RESOLVED `런타임: Codex CLI` declaration so the
# heuristic and roster agree on codex.
write_codex_profile() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$profile"
  printf '# %s — Worker\n\n- **런타임**: Codex CLI\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

# Write a stale Codex-contract AGENTS.md (the residue) at the given path. The
# identity line is the exact prose the codex AGENTS.md template materializes
# (CODEX_CONTRACT_AGENTS_MD_MARKER), so the content-signature detector flags it.
write_codex_contract_agents_md() {
  local dst="$1"
  mkdir -p "$(dirname "$dst")"
  {
    printf '%s\n' '<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->'
    printf '%s\n\n' '# Agent — Role'
    printf '%s\n' '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->'
    printf '%s\n' 'You are a Codex (gpt) agent running inside Agent Bridge. This file is your'
    printf '%s\n\n' 'operating contract. Read it top to bottom.'
    printf '%s\n' 'Your runtime: Codex CLI.'
    printf '%s\n' '<!-- END AGENT BRIDGE DOC MIGRATION -->'
  } >"$dst"
}

run_migrate() {
  local agent="$1"
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" 2>/dev/null
}

run_backfill() {
  local agent="$1"
  python3 "$REPO_ROOT/bridge-upgrade.py" backfill-codex-entrypoints \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" 2>/dev/null
}

json_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"
}

file_digest() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

# ===========================================================================
# P1 — claude-roster agent (heuristic-tripping prose) -> NO home/codex/AGENTS.md.
# ===========================================================================
test_claude_roster_no_codex_agents_md() {
  setup_bridge_fixture
  local agent=claudemonitor
  write_roster "$agent" claude
  write_claude_profile_tripping_prose "$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"

  run_migrate "$agent" >/dev/null

  [[ ! -e "$home/codex/AGENTS.md" ]] \
    || smoke_fail "P1: a claude-roster agent got a spurious home/codex/AGENTS.md (emission gate failed)"
  [[ ! -e "$home/AGENTS.md" ]] \
    || smoke_fail "P1: a claude-roster agent got a spurious home-ROOT AGENTS.md"
  # The claude entrypoint (CLAUDE.md) identity stays intact.
  smoke_assert_file_exists "$home/CLAUDE.md" \
    "P1: the claude agent's CLAUDE.md identity was lost by the migrate pass"
}

# ===========================================================================
# P2 — NEGATIVE CONTROL: genuine codex-roster agent STILL gets codex/AGENTS.md.
# ===========================================================================
test_codex_roster_keeps_codex_agents_md() {
  setup_bridge_fixture
  local agent=codexworker
  write_roster "$agent" codex
  write_codex_profile "$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"

  run_migrate "$agent" >/dev/null

  smoke_assert_file_exists "$home/codex/AGENTS.md" \
    "P2: a genuine codex agent lost its legitimate home/codex/AGENTS.md (regression)"
}

# ===========================================================================
# P3 — ROSTER-UNAVAILABLE FALLBACK: no roster -> heuristic gate; a plain claude
#      profile (no codex signal) still gets NO codex/AGENTS.md.
# ===========================================================================
test_roster_unavailable_heuristic_fallback() {
  setup_bridge_fixture
  local agent=fallbackclaude
  # Intentionally DO NOT write a roster (empty roster file -> unavailable).
  write_plain_claude_profile "$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"

  run_migrate "$agent" >/dev/null

  [[ ! -e "$home/codex/AGENTS.md" ]] \
    || smoke_fail "P3: roster-unavailable fallback emitted a codex/AGENTS.md onto a plain claude profile"
}

# ===========================================================================
# P6 — TSV-ONLY DYNAMIC AGENT: a claude agent present ONLY in active-roster.tsv
#      (engine in column 2, NOT in any shell roster) whose CLAUDE.md trips the
#      bare-substring heuristic still gets NO codex/AGENTS.md. The gate must
#      resolve the roster engine from the TSV, not just shell rosters (a dynamic
#      agent never appears in agent-roster.sh).
# ===========================================================================
test_tsv_only_dynamic_claude_agent_gated() {
  setup_bridge_fixture
  local agent=dynclaudemon
  # No shell roster (collect_roster_engines would return {} for this agent);
  # the engine signal must come from active-roster.tsv column 2.
  write_active_roster_tsv "$agent" claude
  write_claude_profile_tripping_prose "$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"

  run_migrate "$agent" >/dev/null

  [[ ! -e "$home/codex/AGENTS.md" ]] \
    || smoke_fail "P6: a TSV-only dynamic claude agent got a spurious home/codex/AGENTS.md (TSV engine not consulted)"
  [[ ! -e "$home/AGENTS.md" ]] \
    || smoke_fail "P6: a TSV-only dynamic claude agent got a spurious home-ROOT AGENTS.md (TSV engine not consulted)"
}

# ===========================================================================
# P4 — RESIDUE FLAG: a pre-gate spurious home/codex/AGENTS.md is surfaced in
#      engine_mismatch_docs (doc=codex/AGENTS.md), REPORT-ONLY (file untouched).
# ===========================================================================
test_existing_codex_residue_is_flagged_not_removed() {
  setup_bridge_fixture
  local agent=cosmax_sales_mdj
  write_roster "$agent" claude
  write_plain_claude_profile "$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  write_codex_contract_agents_md "$home/codex/AGENTS.md"

  local before_digest=""
  before_digest="$(file_digest "$home/codex/AGENTS.md")"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/p4.json"

  smoke_assert_contains "$summary" "\"codex/AGENTS.md\"" \
    "P4: residue scan did not name the codex/AGENTS.md location (the 2nd copy)"
  smoke_assert_contains "$summary" "$agent" \
    "P4: residue scan did not name the claude agent"
  smoke_assert_eq "1" "$(json_field "$SMOKE_TMP_ROOT/p4.json" engine_mismatch_docs_count)" \
    "P4: expected exactly one engine-mismatched doc (the home/codex copy)"

  # REPORT-ONLY: file byte-identical, no rename/backup created.
  smoke_assert_file_exists "$home/codex/AGENTS.md" \
    "P4: the flagged codex/AGENTS.md was removed (must be report-only)"
  smoke_assert_eq "$before_digest" "$(file_digest "$home/codex/AGENTS.md")" \
    "P4: the flagged codex/AGENTS.md was modified (must be byte-identical, report-only)"
  local stray_count=""
  stray_count="$(python3 -c 'import glob,sys; print(len(glob.glob(sys.argv[1]+"/codex/AGENTS.md.*")))' "$home")"
  smoke_assert_eq "0" "$stray_count" \
    "P4: a backup/rename of codex/AGENTS.md was created (the sweep must not touch the file)"
}

# ===========================================================================
# P5 — HAND-AUTHORED PRESERVE: a codex/AGENTS.md WITHOUT the codex contract
#      marker is NOT flagged (signature-scoped) and is untouched.
# ===========================================================================
test_hand_authored_codex_dir_file_not_flagged() {
  setup_bridge_fixture
  local agent=handauthored
  write_roster "$agent" claude
  write_plain_claude_profile "$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$home/codex"
  printf '# %s notes\nHand-authored codex notes, no bridge codex contract marker.\n' "$agent" \
    >"$home/codex/AGENTS.md"

  local before_digest=""
  before_digest="$(file_digest "$home/codex/AGENTS.md")"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/p5.json"

  smoke_assert_eq "0" "$(json_field "$SMOKE_TMP_ROOT/p5.json" engine_mismatch_docs_count)" \
    "P5: a hand-authored codex/AGENTS.md (no codex marker) was spuriously flagged"
  smoke_assert_eq "$before_digest" "$(file_digest "$home/codex/AGENTS.md")" \
    "P5: a hand-authored codex/AGENTS.md was modified (must be untouched)"
}

main() {
  smoke_run "P1 claude-roster agent gets NO home/codex/AGENTS.md (roster-authoritative gate)" \
    test_claude_roster_no_codex_agents_md
  smoke_run "P2 negative control: a genuine codex agent keeps its codex/AGENTS.md" \
    test_codex_roster_keeps_codex_agents_md
  smoke_run "P3 roster-unavailable fallback: a plain claude profile still gets no codex/AGENTS.md" \
    test_roster_unavailable_heuristic_fallback
  smoke_run "P6 a TSV-only dynamic claude agent (engine in active-roster.tsv) is gated" \
    test_tsv_only_dynamic_claude_agent_gated
  smoke_run "P4 a pre-gate codex/AGENTS.md residue is FLAGGED, not removed" \
    test_existing_codex_residue_is_flagged_not_removed
  smoke_run "P5 a hand-authored codex/AGENTS.md (no codex marker) is not flagged or touched" \
    test_hand_authored_codex_dir_file_not_flagged
  smoke_log "PASS: $SMOKE_NAME"
}

main "$@"
