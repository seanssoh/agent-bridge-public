#!/usr/bin/env bash
# scripts/smoke/679-wiki-ingest-exclude-precompact.sh — Issue #679 smoke.
#
# scripts/wiki-daily-ingest.sh Lane B enumerates raw-capture envelopes under
# each agent's `<agent_home>/raw/captures/inbox/` and queues them for the
# librarian. The PreCompact hook routes through `bridge-memory.py capture`
# with `--title "pre-compact dump (auto|manual)"`, so each dump lands in that
# inbox as `<timestamp>-pre-compact-dump-{auto,manual}.json` on every context
# compaction; those carry no `suggested_slug/title`, so the librarian
# classifier falls through to DEFAULT_KIND and §9 rejects them — yet they keep
# piling up forever and generate a daily [librarian-ambiguous] escalation.
#
# Fix (#679): the Lane B raw `find` invocation excludes exactly the two dump
# shapes — `*-pre-compact-dump-auto.json` and `*-pre-compact-dump-manual.json`
# — so the hook's dumps are never eligible while every other raw envelope,
# including legitimate near-miss captures whose name merely contains the
# `pre-compact-dump` substring, still flows.
#
# This smoke runs the real wiki-daily-ingest.sh over an isolated BRIDGE_HOME
# with a fixture inbox, then asserts the Lane B "Raw envelopes" audit section.
#
# Five assertions:
# T1: a `<timestamp>-pre-compact-dump-auto.json` envelope is excluded.
# T2: a `<timestamp>-pre-compact-dump-manual.json` envelope is excluded.
# T3: positive control — a non-dump raw `.json` capture AND a raw `.md`
#     capture are STILL selected (the exclusion is not a blanket
#     raw-envelope disable).
# T4: near-miss control — captures whose basename merely CONTAINS the
#     `pre-compact-dump` substring but are NOT the hook's auto/manual dump
#     envelopes (`*-pre-compact-dump-research.json`,
#     `pre-compact-dump-reference.md`) STAY selected. The exclusion is a
#     precise shape match, not a bare substring match.
# T5: raw count is exactly 4 — the two near-miss files are counted IN.

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

  # Fixture inbox. Filenames mirror the real capture_id shape produced by
  # bridge-memory.py capture: `<15-char-timestamp>-<slug>.json`.
  #
  #   Excluded — the PreCompact hook's auto/manual dump envelopes:
  : >"$inbox/20260522T140455-pre-compact-dump-auto.json"
  : >"$inbox/20260522T141022-pre-compact-dump-manual.json"
  #   Selected — ordinary non-dump raw captures:
  : >"$inbox/20260522T142000-research-note.json"
  : >"$inbox/20260522T142500-decision-x.md"
  #   Selected — near-miss captures: the basename contains the
  #   `pre-compact-dump` substring but they are NOT the auto/manual dump
  #   envelopes. A bare `*pre-compact-dump*` match would wrongly drop these.
  : >"$inbox/20260522T143000-pre-compact-dump-research.json"
  : >"$inbox/pre-compact-dump-reference.md"

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

  smoke_assert_not_contains "$section" "20260522T140455-pre-compact-dump-auto.json" \
    "T1: auto dump envelope excluded from Lane B raw selection"
  smoke_assert_not_contains "$section" "20260522T141022-pre-compact-dump-manual.json" \
    "T2: manual dump envelope excluded from Lane B raw selection"
  smoke_assert_contains "$section" "20260522T142000-research-note.json" \
    "T3: non-dump raw .json capture still selected"
  smoke_assert_contains "$section" "20260522T142500-decision-x.md" \
    "T3: non-dump raw .md capture still selected"
  smoke_assert_contains "$section" "20260522T143000-pre-compact-dump-research.json" \
    "T4: near-miss .json (pre-compact-dump substring, not a dump) still selected"
  smoke_assert_contains "$section" "pre-compact-dump-reference.md" \
    "T4: near-miss .md (pre-compact-dump substring, not a dump) still selected"
  smoke_assert_contains "$section" "Raw envelopes (4)" \
    "T5: raw count is exactly 4 — near-miss files counted IN, only the 2 dumps dropped"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1-T5: Lane B excludes only auto/manual dumps, keeps raw + near-miss" \
    assert_lane_b_selection

  smoke_log "PASS"
}

main "$@"
