#!/usr/bin/env bash
# 22101-watchdog-managed-block-agent-root.sh -- Issue #22101 (#2018 blast radius):
# a static Claude agent whose registry `home` is the runtime `home/` SUBDIR
# (`.../agents/<a>/home`) carries its managed block at the agent ROOT one level
# up (`.../agents/<a>/CLAUDE.md`) -- where the scaffold writes it -- NOT inside
# the `home/` subdir. The watchdog's #2018 identity fall-back checked ONLY
# `agent_home_dir/CLAUDE.md` (= `.../home/CLAUDE.md`, which legitimately has no
# block), so it reported `missing_managed_claude_block=true` / `status=drift`
# and the librarian-watchdog cron re-created a false `[watchdog] agent profile
# drift` task EVERY cycle -- while `bridge-docs.py migrate docs audit`, which
# descends to the agent ROOT, reported the same agent clean.
#
# #22101 fix: when `agent_home_dir.name == "home"` the fall-back ALSO checks the
# agent ROOT (`agent_home_dir.parent/CLAUDE.md`). A block genuinely absent from
# the workdir AND the `home/` subdir AND the agent root still surfaces as drift.
#
#   T1  home-subdir registry + block at the agent ROOT -> not drift
#       (missing_managed_claude_block=false, status=ok). The regression fix.
#   T2  NON-VACUOUS control: same layout but the block is absent from the agent
#       root too (nowhere) -> missing_managed_claude_block=true. Proves the test
#       is not vacuous and that a genuinely-missing block still surfaces.
#   T3  GUARD PRECISION: a FLAT home (`home.name != "home"`) with a block only in
#       home's PARENT must NOT be suppressed -- the climb is scoped to the
#       `home/` layout, so an unrelated parent is never consulted -> still drift.
#
# Pure-python CLI surface (`bridge-watchdog.py scan --json`) driven against a
# temp BRIDGE_HOME -- the operator's live tree is never touched; runs identically
# on macOS and Linux. No heredocs / here-strings in this body (footgun #11).

set -euo pipefail

SMOKE_NAME="22101-watchdog-managed-block-agent-root"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

MANAGED_START="<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END="<!-- END AGENT BRIDGE DOC MIGRATION -->"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Seed the non-entrypoint Claude required files into a scanned workdir so the
# only variable under test is the managed-block path resolution.
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

# Write a CLAUDE.md carrying the literal managed block (path-resolution test;
# marker-content coverage is guarded by 2062-watchdog-rendered-block-not-drift).
write_block_claude() {
  local path="$1"
  {
    printf '# agent\n\ncustom content\n\n'
    printf '%s\n' "$MANAGED_START"
    printf 'managed doc migration content\n'
    printf '%s\n' "$MANAGED_END"
  } >"$path"
}

# A block-LESS CLAUDE.md (project-guidance only) -- the shape a real workdir has.
write_blockless_claude() {
  printf '# project\n\nproject guidance only, no identity block\n' >"$1"
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

# reg_row <agent> <workdir> <home> -> single-row registry json at $reg_path.
write_registry() {
  local reg_path="$1" agent="$2" workdir="$3" home="$4"
  {
    printf '[ { "id": "%s", "class": "static", "agent_source": "static", ' "$agent"
    printf '"engine": "claude", "workdir": "%s", "home": "%s" } ]\n' \
      "$workdir" "$home"
  } >"$reg_path"
}

# ===========================================================================
# T1 -- registry home = the `home/` subdir; block lives at the agent ROOT.
#       The #22101 fix must treat this as present (not drift).
# ===========================================================================
test_agent_root_block_is_not_drift() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=rootblock
  local root="$BRIDGE_AGENT_HOME_ROOT/$agent"   # agent ROOT (= home's parent)
  local home="$root/home"                        # registry `home` (name=="home")
  local workdir="$SMOKE_TMP_ROOT/proj-$agent"    # scanned workdir (block-less)
  mkdir -p "$root" "$home" "$workdir"

  # Block at the agent ROOT (where the scaffold writes it); NONE in home/.
  write_block_claude "$root/CLAUDE.md"
  # The `home/` subdir CLAUDE.md is legitimately ABSENT (matches production).
  # The scanned workdir has only a block-less project CLAUDE.md + profile files.
  write_blockless_claude "$workdir/CLAUDE.md"
  seed_profile_files "$workdir"

  local reg="$SMOKE_TMP_ROOT/reg-t1.json"
  write_registry "$reg" "$agent" "$workdir" "$home"
  local out="$SMOKE_TMP_ROOT/out-t1.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "false" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T1: a home-subdir agent whose managed block lives at the agent ROOT was flagged missing_managed_claude_block (the #22101 false positive #2018 missed)"
  smoke_assert_eq '"ok"' "$(field_for "$out" "$agent" status)" \
    "T1: agent-root managed block must scan status=ok, not drift"
}

# ===========================================================================
# T2 -- NON-VACUOUS control: block absent from workdir AND home/ AND the agent
#       root -> genuinely missing -> must still surface as drift.
# ===========================================================================
test_block_absent_everywhere_is_drift() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=noblock
  local root="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$root/home"
  local workdir="$SMOKE_TMP_ROOT/proj-$agent"
  mkdir -p "$root" "$home" "$workdir"

  # Block NOWHERE: a block-less CLAUDE.md at the agent root, none in home/, and
  # a block-less workdir CLAUDE.md.
  write_blockless_claude "$root/CLAUDE.md"
  write_blockless_claude "$workdir/CLAUDE.md"
  seed_profile_files "$workdir"

  local reg="$SMOKE_TMP_ROOT/reg-t2.json"
  write_registry "$reg" "$agent" "$workdir" "$home"
  local out="$SMOKE_TMP_ROOT/out-t2.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "true" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T2 (non-vacuous): a block absent from workdir + home/ + agent root must remain missing_managed_claude_block=true; if false the #22101 fix over-suppresses real drift"
}

# ===========================================================================
# T3 -- GUARD PRECISION: a FLAT home (home.name != "home") with a block only in
#       home's PARENT must NOT be suppressed. The climb is scoped to the
#       `home/` layout; an unrelated parent directory is never consulted.
# ===========================================================================
test_flat_home_does_not_climb() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=flathome
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"    # FLAT home (name == "$agent")
  local workdir="$SMOKE_TMP_ROOT/proj-$agent"
  mkdir -p "$home" "$workdir"

  # Block only in home's PARENT (the agents-root) -- an unrelated location the
  # climb must NOT reach because home.name != "home".
  write_block_claude "$BRIDGE_AGENT_HOME_ROOT/CLAUDE.md"
  # home/CLAUDE.md is block-less; workdir is block-less.
  write_blockless_claude "$home/CLAUDE.md"
  write_blockless_claude "$workdir/CLAUDE.md"
  seed_profile_files "$workdir"

  local reg="$SMOKE_TMP_ROOT/reg-t3.json"
  write_registry "$reg" "$agent" "$workdir" "$home"
  local out="$SMOKE_TMP_ROOT/out-t3.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "true" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T3 (precision): a flat home (name != 'home') must NOT climb to its parent -- a block only in an unrelated parent dir must stay missing_managed_claude_block=true"

  # Clean up the agents-root decoy so it can't leak into another test's scan.
  rm -f "$BRIDGE_AGENT_HOME_ROOT/CLAUDE.md"
}

# ===========================================================================
# T3b -- ALLOWED-NAME COLLISION (codex PR #2243 r1): an agent LITERALLY NAMED
#        "home" has a flat identity home at <agents-root>/home, so
#        `agent_home_dir.name == "home"` is true for the WRONG reason (the agent
#        NAME, not the v2 runtime `home/` subdir). Agent names allow "home" (only
#        help/version are reserved), so this is a valid registry shape. The climb
#        must NOT fire -- consulting the unrelated <agents-root>/CLAUDE.md would
#        falsely suppress real drift. The tightened guard requires the home's
#        PARENT basename to equal the resolved agent id (the generated v2 layout
#        `.../agents/<id>/home`), which a flat `.../agents/home` fails (its parent
#        basename is the agents root, not "home").
# ===========================================================================
test_allowed_name_home_does_not_climb() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=home                                # agent LITERALLY named "home"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"     # flat home == <agents-root>/home
  local workdir="$SMOKE_TMP_ROOT/proj-$agent"
  mkdir -p "$home" "$workdir"

  # Decoy managed block ONLY at the agents-root parent -- the unrelated dir a
  # basename-only climb would wrongly consult for an agent named "home".
  write_block_claude "$BRIDGE_AGENT_HOME_ROOT/CLAUDE.md"
  write_blockless_claude "$home/CLAUDE.md"
  write_blockless_claude "$workdir/CLAUDE.md"
  seed_profile_files "$workdir"

  local reg="$SMOKE_TMP_ROOT/reg-t3b.json"
  write_registry "$reg" "$agent" "$workdir" "$home"
  local out="$SMOKE_TMP_ROOT/out-t3b.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "true" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T3b (allowed-name collision): an agent named 'home' with a FLAT home must NOT climb to <agents-root>/CLAUDE.md -- a decoy block there must stay missing_managed_claude_block=true"

  # Clean up the agents-root decoy so it can't leak into another test's scan.
  rm -f "$BRIDGE_AGENT_HOME_ROOT/CLAUDE.md"
}

main() {
  smoke_run "T1 agent-root managed block (home-subdir registry) scans ok, not drift" \
    test_agent_root_block_is_not_drift
  smoke_run "T2 non-vacuous: block absent everywhere still surfaces as drift" \
    test_block_absent_everywhere_is_drift
  smoke_run "T3 guard precision: flat home does not climb to an unrelated parent" \
    test_flat_home_does_not_climb
  smoke_run "T3b allowed-name collision: agent named 'home' with flat home does not climb" \
    test_allowed_name_home_does_not_climb
  smoke_log "PASS: $SMOKE_NAME"
}

main "$@"
