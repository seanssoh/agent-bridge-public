#!/usr/bin/env bash
# 2018-watchdog-managed-block-identity-home.sh -- Issue #2018: the
# `missing_managed_claude_block` watchdog check must be satisfied when the
# managed block is present in the agent's IDENTITY HOME, even when the scanned
# registry `workdir` is a custom project folder whose CLAUDE.md legitimately
# carries only the project-guidance block.
#
# The bug shape (sean-mac, v0.16.2 -> v0.16.12): a static Claude agent whose
# `BRIDGE_AGENT_WORKDIR` is a real project folder (chosen so the agent's Claude
# `/resume` history, keyed on that folder, keeps working) has a workdir
# CLAUDE.md with only `<!-- AGENT BRIDGE PROJECT GUIDANCE -->`, never the
# identity `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` block. The watchdog
# scanned the workdir alone -> permanent `missing_managed_claude_block: yes` ->
# `status: warn` + a re-created `[watchdog] agent profile drift` task every
# cycle, while `agent-bridge migrate docs audit` (which checks the identity
# home) reported the same agent clean. The two tools disagreed.
#
# The fix mirrors the #1750 engine-entrypoint home fall-back: the block counts
# as present when it exists in EITHER the scanned dir OR the agent_home identity
# source. A block genuinely absent from BOTH still surfaces as drift.
#
#   T1  custom-workdir Claude agent: workdir CLAUDE.md has ONLY the project
#       guidance block; identity home CLAUDE.md HAS the managed block ->
#       missing_managed_claude_block=false (the false positive is gone).
#   T2  NEGATIVE CONTROL: the managed block is absent from BOTH the workdir AND
#       the identity home -> missing_managed_claude_block=true (real drift is
#       never masked).
#   T3  LEGACY/no-home: a registry row with NO `home` field (v1 install) and a
#       workdir CLAUDE.md lacking the block -> missing_managed_claude_block=true
#       (the single-tree behavior is unchanged when there is no identity home).
#
# Mutation check (non-vacuous): reverting the fix (scan the workdir only) makes
# T1 report missing_managed_claude_block=true and fail.
#
# Pure-python CLI surface (`bridge-watchdog.py scan --json`) driven against a
# temp BRIDGE_HOME — the operator's live tree is never touched; runs identically
# on macOS and Linux.

set -euo pipefail

SMOKE_NAME="2018-watchdog-managed-block-identity-home"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Seed a Claude profile fileset (required files) at <dir>. The CLAUDE.md content
# is the caller's responsibility (block present or not).
seed_profile_files() {
  local dir="$1"
  : >"$dir/SOUL.md"
  : >"$dir/MEMORY-SCHEMA.md"
  : >"$dir/MEMORY.md"
  {
    printf '# Session Type\n\n'
    printf -- '- Session Type: static-claude\n'
    printf -- '- Onboarding State: complete\n'
  } >"$dir/SESSION-TYPE.md"
}

write_project_guidance_claude() {
  # A real project-folder CLAUDE.md: project guidance block ONLY, no identity
  # managed block (the legitimate custom-workdir shape).
  {
    printf '%s\n' '<!-- AGENT BRIDGE PROJECT GUIDANCE -->'
    printf '%s\n' '# My Project'
    printf '%s\n' 'Real project guidance — intentionally NO identity managed block.'
  } >"$1"
}

write_managed_block_claude() {
  # An identity CLAUDE.md carrying the authoritative managed block.
  {
    printf '%s\n' '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->'
    printf '%s\n' 'managed identity block'
    printf '%s\n' '<!-- END AGENT BRIDGE DOC MIGRATION -->'
    printf '%s\n' '# identity'
  } >"$1"
}

write_no_block_claude() {
  # A CLAUDE.md with NO managed block at all (the genuine-drift control).
  {
    printf '%s\n' '# identity'
    printf '%s\n' 'No managed block anywhere.'
  } >"$1"
}

# field_for <scan-json> <agent> <field> -> prints the field value (json repr).
field_for() {
  "$PY_BIN" -c '
import json, sys
d = json.load(open(sys.argv[1]))
agent, field = sys.argv[2], sys.argv[3]
for r in d.get("agents", []):
    if r.get("agent") == agent:
        print(json.dumps(r.get(field)))
        break
else:
    print("__AGENT_NOT_FOUND__")
' "$1" "$2" "$3"
}

run_scan() {
  local reg="$1"
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
    --agent-registry-json "$reg" 2>/dev/null >"$2"
}

# ===========================================================================
# T1 — custom-workdir Claude agent: block in identity home -> not drift.
# ===========================================================================
test_block_in_identity_home_not_drift() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=custommon
  # Discovery anchor under $BRIDGE_AGENT_HOME_ROOT so the scan loop picks it up.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  # Custom project workdir (registry workdir): project guidance only.
  local proj="$SMOKE_TMP_ROOT/myproject"
  mkdir -p "$proj"
  write_project_guidance_claude "$proj/CLAUDE.md"
  seed_profile_files "$proj"
  # Identity home: carries the managed block (the authoritative target).
  local home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  mkdir -p "$home"
  write_managed_block_claude "$home/CLAUDE.md"
  seed_profile_files "$home"

  local reg="$SMOKE_TMP_ROOT/reg-t1.json"
  {
    printf '[ { "id": "%s", "class": "static", "agent_source": "static", ' "$agent"
    printf '"engine": "claude", "workdir": "%s", "home": "%s" } ]\n' "$proj" "$home"
  } >"$reg"

  local out="$SMOKE_TMP_ROOT/out-t1.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "false" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T1: a custom-workdir Claude agent with the block in its identity home was still flagged missing_managed_claude_block (the #2018 false positive)"
}

# ===========================================================================
# T2 — NEGATIVE CONTROL: block absent from BOTH workdir AND home -> drift.
# ===========================================================================
test_block_absent_from_both_is_drift() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=nodrifthidden
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  local proj="$SMOKE_TMP_ROOT/proj2"
  mkdir -p "$proj"
  write_project_guidance_claude "$proj/CLAUDE.md"
  seed_profile_files "$proj"
  local home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  mkdir -p "$home"
  write_no_block_claude "$home/CLAUDE.md"  # home ALSO lacks the block
  seed_profile_files "$home"

  local reg="$SMOKE_TMP_ROOT/reg-t2.json"
  {
    printf '[ { "id": "%s", "class": "static", "agent_source": "static", ' "$agent"
    printf '"engine": "claude", "workdir": "%s", "home": "%s" } ]\n' "$proj" "$home"
  } >"$reg"

  local out="$SMOKE_TMP_ROOT/out-t2.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "true" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T2: a genuinely-missing managed block (absent from BOTH workdir and home) was masked — real drift must still surface"
}

# ===========================================================================
# T3 — LEGACY/no-home registry row -> single-tree behavior unchanged.
# ===========================================================================
test_legacy_no_home_unchanged() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=legacyclaude
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  local proj="$SMOKE_TMP_ROOT/proj3"
  mkdir -p "$proj"
  write_project_guidance_claude "$proj/CLAUDE.md"  # workdir lacks the block
  seed_profile_files "$proj"

  # Registry row with NO `home` field (v1 install shape).
  local reg="$SMOKE_TMP_ROOT/reg-t3.json"
  {
    printf '[ { "id": "%s", "class": "static", "agent_source": "static", ' "$agent"
    printf '"engine": "claude", "workdir": "%s" } ]\n' "$proj"
  } >"$reg"

  local out="$SMOKE_TMP_ROOT/out-t3.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "true" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T3: a legacy registry row with no identity home regressed — the single-tree check must still flag a workdir missing the block"
}

main() {
  smoke_run "T1 custom-workdir Claude agent with the block in its identity home is not drift" \
    test_block_in_identity_home_not_drift
  smoke_run "T2 negative control: a block absent from BOTH workdir and home still surfaces as drift" \
    test_block_absent_from_both_is_drift
  smoke_run "T3 legacy/no-home registry row keeps the single-tree behavior" \
    test_legacy_no_home_unchanged
  smoke_log "PASS: $SMOKE_NAME"
}

main "$@"
