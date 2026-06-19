#!/usr/bin/env bash
# 1930-detect-engine-placeholder.sh -- Issue #1930 (+ #1928): detect_engine must
# NOT substring-match "Codex CLI" in a non-codex CLAUDE.md.
#
# The bug: detect_engine() scanned the CLAUDE.md text for the bare substring
# "Codex CLI" and returned codex on any hit. A genuine *claude* profile carries
# that substring in two NON-codex places that every rendered template includes:
#   1. the unresolved placeholder line `- **런타임**: <Claude Code CLI | Codex CLI>`
#      (the angle-bracket runtime-choice line — both engine tokens present), and
#   2. prose that mentions Codex CLI as an EXAMPLE, e.g. the template's
#      background-subagent note `런타임에 ... 기능이 없으면(예: Codex CLI)`.
# Either one false-flagged a roster=claude agent as detected=codex, so the #1892
# fail-closed doc-backfill HELD it and re-enqueued a `[hygiene]` engine-disagreement
# alert every upgrade / daemon hygiene pass (#1928: it also materialized a codex
# AGENTS.md on installs before the #1892 hold landed — a smoke-T3 violation).
#
# The fix anchors detection on the RESOLVED runtime-label declaration
# (`런타임`/`runtime`: Codex CLI) instead of a bare substring.
#
#   P1  claude-roster agent whose CLAUDE.md carries the `<Claude Code CLI | Codex CLI>`
#       PLACEHOLDER line -> detected=claude -> SKIP: no AGENTS.md, clean pass
#       (non-clean=0, held=0). No recurring engine-disagreement alert.
#   P2  claude-roster agent whose CLAUDE.md only MENTIONS "Codex CLI" in prose
#       (the `(예: Codex CLI)` example) -> detected=claude -> same clean SKIP.
#   P3  NEGATIVE CONTROL: a genuine codex-roster agent with a RESOLVED
#       `런타임: Codex CLI` declaration still detects codex and backfills (the
#       tightened heuristic must not under-detect a real codex profile).
#   P4  SESSION-TYPE route: a NON-admin claude agent with no usable
#       SESSION-TYPE.md and a placeholder CLAUDE.md. detect_session_type ALSO
#       substring-scanned CLAUDE.md and returns "static-codex" on a hit, which
#       short-circuits detect_engine to codex BEFORE its own anchor runs — so the
#       false positive must be excluded on that path too. SKIP, not held.
#
# Mutation check (non-vacuous): reverting either heuristic to the bare-substring
# scan makes P1/P2/P4 flip to held=1 (engine disagreement) and fail these asserts.
#
# Pure-python CLI surface (backfill-codex-entrypoints) driven against a temp
# BRIDGE_HOME — the operator's live tree is never touched; runs identically on
# macOS and Linux. No heredoc-stdin / `<<<` / `< <()` procsub / `| grep -q`
# (lint-heredoc-ban H3 + #1813 SIGPIPE): printf-built fixtures + `python3 -c`.

set -euo pipefail

SMOKE_NAME="1930-detect-engine-placeholder"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures (mirror the 1892 fail-closed smoke's v2 scaffolding)
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

# A claude profile whose CLAUDE.md carries the unresolved runtime-choice
# PLACEHOLDER line (both engine tokens inside `<...>`). Pre-fix this tripped the
# bare-substring scan -> detected=codex.
write_claude_profile_placeholder() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  {
    printf '# %s — Monitor\n\n' "$agent"
    printf '%s\n' '- **런타임**: <Claude Code CLI | Codex CLI>'
  } >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

# A claude profile whose CLAUDE.md only MENTIONS "Codex CLI" in prose (the
# template's `(예: Codex CLI)` background-subagent example) with a resolved
# claude runtime line. Pre-fix the prose mention tripped the bare-substring scan.
write_claude_profile_prose_mention() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  {
    printf '# %s — Monitor\n\n' "$agent"
    printf '%s\n' '- **런타임**: Claude Code CLI'
    printf '%s\n' '- 런타임에 background subagent 기능이 없으면(예: Codex CLI) 이 섹션은 적용하지 않는다.'
  } >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
}

# A genuine codex profile (negative control): a RESOLVED `런타임: Codex CLI`
# declaration, missing its AGENTS.md so the backfill has work to do.
write_codex_profile_resolved() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  {
    printf '# %s — Monitor\n\n' "$agent"
    printf '%s\n' '- **런타임**: Codex CLI'
  } >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "precondition: codex profile already has AGENTS.md for $agent"
}

run_backfill() {
  local agent="$1"
  # When admin == agent the detect_session_type admin-shortcut returns "admin"
  # before the CLAUDE.md scan; pass an explicit admin to control that.
  local admin="${2:-$agent}"
  python3 "$REPO_ROOT/bridge-upgrade.py" backfill-codex-entrypoints \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$admin" 2>/dev/null
}

non_clean_of() {
  python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-non-clean "$1"
}

held_count_of() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("held_count",0))' "$1"
}

# ===========================================================================
# P1 — claude-roster + PLACEHOLDER line: clean SKIP, no AGENTS.md, not held.
# ===========================================================================
test_placeholder_line_is_not_codex() {
  setup_bridge_fixture
  local agent=p1claude
  write_roster "$agent" claude
  write_claude_profile_placeholder "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/p1.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "P1: claude agent with the placeholder line got a spurious codex AGENTS.md (#1928)"
  smoke_assert_eq "0" "$(held_count_of "$SMOKE_TMP_ROOT/p1.json")" \
    "P1: the placeholder line was misdetected as codex -> spurious engine-disagreement HOLD (#1930)"
  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/p1.json")" \
    "P1: a clean claude SKIP was reported non-clean (recurring [hygiene] alert)"
}

# ===========================================================================
# P2 — claude-roster + PROSE "Codex CLI" mention only: same clean SKIP.
# ===========================================================================
test_prose_mention_is_not_codex() {
  setup_bridge_fixture
  local agent=p2claude
  write_roster "$agent" claude
  write_claude_profile_prose_mention "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/p2.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "P2: claude agent with a prose 'Codex CLI' mention got a spurious codex AGENTS.md (#1928)"
  smoke_assert_eq "0" "$(held_count_of "$SMOKE_TMP_ROOT/p2.json")" \
    "P2: a prose 'Codex CLI' mention was misdetected as codex -> spurious HOLD (#1930)"
  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/p2.json")" \
    "P2: a clean claude SKIP was reported non-clean (recurring [hygiene] alert)"
}

# ===========================================================================
# P3 — NEGATIVE CONTROL: genuine codex profile (resolved declaration) still
#      detects codex and backfills (the tightened heuristic must not under-detect).
# ===========================================================================
test_resolved_codex_still_backfills() {
  setup_bridge_fixture
  local agent=p3codex
  write_roster "$agent" codex
  write_codex_profile_resolved "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  local summary=""
  summary="$(run_backfill "$agent")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/p3.json"

  smoke_assert_file_exists "$profile/AGENTS.md" \
    "P3: a genuine codex agent (resolved 런타임: Codex CLI) was NOT backfilled"
  smoke_assert_contains "$summary" "\"backfilled\"" "P3: summary missing the backfilled list"
  smoke_assert_contains "$summary" "$agent" "P3: backfilled summary did not name the codex agent"
  smoke_assert_eq "0" "$(held_count_of "$SMOKE_TMP_ROOT/p3.json")" \
    "P3: a genuine codex agent was spuriously held"
}

# ===========================================================================
# P4 — SESSION-TYPE route: a NON-admin claude agent (placeholder CLAUDE.md, no
#      usable SESSION-TYPE.md) must NOT be misdetected as static-codex/codex.
# ===========================================================================
test_session_type_route_is_not_codex() {
  setup_bridge_fixture
  local agent=p4claude
  write_roster "$agent" claude
  write_claude_profile_placeholder "$agent"   # no SESSION-TYPE.md written
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"

  # Drive with a DIFFERENT admin so detect_session_type's admin-shortcut does
  # not mask the CLAUDE.md scan for this agent.
  local summary=""
  summary="$(run_backfill "$agent" "some-other-admin")"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/p4.json"

  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "P4: a non-admin claude agent was misdetected codex via the session-type route (#1930)"
  smoke_assert_eq "0" "$(held_count_of "$SMOKE_TMP_ROOT/p4.json")" \
    "P4: session-type route misdetected the placeholder as codex -> spurious HOLD (#1930)"
  smoke_assert_eq "0" "$(non_clean_of "$SMOKE_TMP_ROOT/p4.json")" \
    "P4: a clean claude SKIP was reported non-clean (recurring [hygiene] alert)"
}

smoke_run "P1 placeholder <Claude Code CLI | Codex CLI> line is not a codex signal" \
  test_placeholder_line_is_not_codex
smoke_run "P2 prose 'Codex CLI' mention is not a codex signal" \
  test_prose_mention_is_not_codex
smoke_run "P3 negative control: a resolved 런타임: Codex CLI declaration still backfills" \
  test_resolved_codex_still_backfills
smoke_run "P4 session-type route: a non-admin claude placeholder profile is not codex" \
  test_session_type_route_is_not_codex
smoke_log "PASS: $SMOKE_NAME"
