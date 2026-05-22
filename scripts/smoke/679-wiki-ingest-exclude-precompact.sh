#!/usr/bin/env bash
# scripts/smoke/679-wiki-ingest-exclude-precompact.sh — Issue #679 smoke.
#
# scripts/wiki-daily-ingest.sh Lane B enumerates raw-capture envelopes under
# each agent's `<agent_home>/raw/captures/inbox/` and queues them for the
# librarian. The PreCompact hook drops `*-pre-compact-dump-{auto,manual}.json`
# envelopes into that same inbox on every context compaction; those carry no
# `suggested_entities/slug/title`, so the librarian classifier falls through
# to DEFAULT_KIND and §9 rejects them — yet they keep piling up forever and
# generate a daily [librarian-ambiguous] escalation.
#
# Fix (#679): the Lane B raw `find` invocation now excludes
# `*pre-compact-dump*` so those envelopes are never eligible while every
# other raw envelope still flows.
#
# This smoke runs the real wiki-daily-ingest.sh over an isolated BRIDGE_HOME
# with a fixture inbox, then asserts the Lane B "Raw envelopes" audit section.
#
# Three assertions:
# T1: a `pre-compact-dump-auto-*.json` envelope is excluded from Lane B.
# T2: a `pre-compact-dump-manual-*.json` envelope is excluded from Lane B.
# T3: positive control — a non-dump raw `.json` capture AND a raw `.md`
#     capture are STILL selected (the exclusion is not a blanket
#     raw-envelope disable).

set -euo pipefail

SMOKE_NAME="679-wiki-ingest-exclude-precompact"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Resolve the Raw-envelopes section of the Lane B audit log produced by a
# fixture run. Returns the section body on stdout.
run_lane_b() {
  local agents_root="$BRIDGE_HOME/agents"
  local inbox="$agents_root/alpha/raw/captures/inbox"
  local wiki_root="$BRIDGE_HOME/shared/wiki"
  mkdir -p "$agents_root/alpha/memory" "$inbox" "$wiki_root/_audit"

  # Fixture inbox: two pre-compact-dump envelopes (must be excluded) plus a
  # non-dump raw .json capture and a raw .md capture (must stay selected).
  : >"$inbox/alpha-pre-compact-dump-auto.json"
  : >"$inbox/alpha-pre-compact-dump-manual.json"
  : >"$inbox/research-note.json"
  : >"$inbox/decision-x.md"

  # Force the legacy find-based enumeration: it walks $BRIDGE_AGENTS_ROOT/*
  # directly, which makes the Lane B raw walk fully deterministic against
  # the isolated fixture. The v2 path resolves agent workdirs via the live
  # roster, which is not what this smoke owns.
  local log
  log="$wiki_root/_audit/ingest-$(date +%Y-%m-%d).md"
  rm -f "$log"

  env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_SHARED_ROOT="$BRIDGE_HOME/shared" \
    BRIDGE_WIKI_ROOT="$wiki_root" \
    BRIDGE_AGENTS_ROOT="$agents_root" \
    BRIDGE_STATE_DIR="$BRIDGE_HOME/state" \
    BRIDGE_SCRIPTS_ROOT="$SMOKE_REPO_ROOT/scripts" \
    BRIDGE_AGB="$SMOKE_REPO_ROOT/agent-bridge" \
    bash "$SMOKE_REPO_ROOT/scripts/wiki-daily-ingest.sh" >/dev/null 2>&1 || true

  smoke_assert_file_exists "$log" "Lane B audit log written"
  # Emit just the "### Raw envelopes" section body.
  sed -n '/### Raw envelopes/,/^$/p' "$log"
}

assert_lane_b_selection() {
  local section
  section="$(run_lane_b)"

  smoke_assert_not_contains "$section" "pre-compact-dump-auto" \
    "T1: pre-compact-dump-auto envelope excluded from Lane B raw selection"
  smoke_assert_not_contains "$section" "pre-compact-dump-manual" \
    "T2: pre-compact-dump-manual envelope excluded from Lane B raw selection"
  smoke_assert_contains "$section" "research-note.json" \
    "T3: non-dump raw .json capture still selected"
  smoke_assert_contains "$section" "decision-x.md" \
    "T3: non-dump raw .md capture still selected"
  smoke_assert_contains "$section" "Raw envelopes (2)" \
    "T3: raw count is exactly 2 (no blanket raw-envelope disable)"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1-T3: Lane B excludes pre-compact-dump, keeps raw captures" \
    assert_lane_b_selection

  smoke_log "PASS"
}

main "$@"
