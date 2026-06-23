#!/usr/bin/env bash
# shellcheck shell=bash
#
# 1816-managed-block-marker-stamp-backup smoke
#
# Pins three halves of issue #1816 (completing the ratified pointer-only block):
#
#  A. Version stamp — the block carries the engine version so a stale or foreign
#     block is mechanically detectable. Issue #2062: the stamp lives on a
#     SEPARATE in-block metadata line (`<!-- agent-bridge-managed-version: <v>
#     -->`), NOT on the BEGIN marker, so the BEGIN marker stays a stable literal
#     and every consumer (watchdog/upgrader/migrate) keeps matching it. Pre-stamp
#     blocks (no version line) must still be recognized/stripped (back-compat).
#  B. Unbalanced-marker guard (MUTATION-PROVEN) — a CLAUDE.md with an orphaned
#     BEGIN marker (END lost) must be SKIPPED and reported, NOT double-prepended
#     or corrupted. Non-vacuous: the md5 is unchanged and the BEGIN count stays
#     1 (a regression would double the block / eat the custom tail).
#  C. Changed-only backups — a no-op apply must deposit NO new CLAUDE.md backup
#     under state/doc-migration/backups/ (the old code backed up every pass).
#
# Also pins pointer-only completion: the inlined Queue & Delivery / Task
# Processing Protocol / Legacy Guardrails section *headings* are gone from the
# block (their bodies now live in the canon doc).
#
# macOS-friendly. No heredocs / here-strings in this body (footgun #11).

set -euo pipefail

SMOKE_NAME="1816-managed-block-marker-stamp-backup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

BEGIN_PREFIX="<!-- BEGIN AGENT BRIDGE DOC MIGRATION"
BEGIN_MARKER="<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
END_MARKER="<!-- END AGENT BRIDGE DOC MIGRATION -->"
# Issue #2062: the version stamp moved off the BEGIN marker to this in-block line.
VERSION_PREFIX="<!-- agent-bridge-managed-version:"

seed_agent_home() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/tester"
  mkdir -p "$agent_home"
  printf '# tester soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n' >"$agent_home/SESSION-TYPE.md"
  printf '# tester\n\ncustom content\n' >"$agent_home/CLAUDE.md"
}

run_apply() {
  python3 "$SMOKE_REPO_ROOT/bridge-docs.py" apply "$1" \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$BRIDGE_AGENT_HOME_ROOT" \
    --source-shared "$SMOKE_TMP_ROOT/nonexistent-source-shared" \
    >/dev/null
}

run_apply_json() {
  python3 "$SMOKE_REPO_ROOT/bridge-docs.py" apply "$1" \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$BRIDGE_AGENT_HOME_ROOT" \
    --source-shared "$SMOKE_TMP_ROOT/nonexistent-source-shared" \
    --json
}

count_str() {
  # count occurrences of $2 in file $1 (pure grep -c on fixed string)
  grep -cF "$2" "$1" 2>/dev/null || printf '0'
}

assert_version_stamp_emitted() {
  run_apply tester
  local block engine_version
  block="$(cat "$BRIDGE_AGENT_HOME_ROOT/tester/CLAUDE.md")"
  # #2062: the BEGIN marker is the stable literal — NO ` v=` stamp on it.
  smoke_assert_contains "$block" "$BEGIN_MARKER" \
    "BEGIN marker must be the stable literal (no stamp suffix) (#2062)"
  smoke_assert_not_contains "$block" "$BEGIN_PREFIX v=" \
    "BEGIN marker must NOT carry a ' v=' stamp suffix — the stamp moved off the marker (#2062)"
  # The version lives on a separate in-block metadata line.
  engine_version="$(head -n1 "$SMOKE_REPO_ROOT/VERSION" | tr -d '[:space:]')"
  smoke_assert_contains "$block" "$VERSION_PREFIX $engine_version -->" \
    "in-block version line must carry the engine VERSION ($engine_version) (#1816 audit goal, #2062 placement)"
}

assert_pointer_only_block() {
  local block
  block="$(cat "$BRIDGE_AGENT_HOME_ROOT/tester/CLAUDE.md")"
  # The hardcopied protocol section HEADINGS must be gone (bodies live in canon).
  smoke_assert_not_contains "$block" "## Queue & Delivery" \
    "block must not re-inline the Queue & Delivery body (#1816 pointer-only)"
  smoke_assert_not_contains "$block" "## Task Processing Protocol" \
    "block must not re-inline the Task Processing Protocol body (#1816 pointer-only)"
  smoke_assert_not_contains "$block" "## Legacy Guardrails" \
    "block must not re-inline the Legacy Guardrails body (#1816 pointer-only)"
  smoke_assert_contains "$block" "## Runtime Protocol Pointers" \
    "block must keep the pointer section that references the canon doc"
}

assert_changed_only_backup() {
  # tester already has a rendered block (in-block stamp) from the apply above. A no-op rerun must
  # NOT deposit another CLAUDE.md backup and must NOT list CLAUDE.md as changed.
  run_apply tester  # converge
  local before_count
  before_count="$(find "$BRIDGE_HOME/state/doc-migration/backups" -name CLAUDE.md 2>/dev/null | wc -l | tr -d '[:space:]')"
  local json
  json="$(run_apply_json tester)"
  # CLAUDE.md must not be in changed_paths on the no-op rerun.
  case "$json" in
    *tester/CLAUDE.md*) smoke_fail "no-op rerun must not list tester/CLAUDE.md as changed (#1816 changed-only)";;
  esac
  local after_count
  after_count="$(find "$BRIDGE_HOME/state/doc-migration/backups" -name CLAUDE.md 2>/dev/null | wc -l | tr -d '[:space:]')"
  smoke_assert_eq "$before_count" "$after_count" \
    "no-op apply must deposit NO new CLAUDE.md backup (#1816 changed-only backups)"
}

assert_unbalanced_marker_guard() {
  # Build a CLAUDE.md with an ORPHANED BEGIN marker (END lost) — the corruption
  # precondition. The guard must SKIP it: file unchanged, reported skipped,
  # BEGIN count stays 1 (not double-prepended), custom tail preserved.
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/broken"
  mkdir -p "$agent_home"
  printf '# broken soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n' >"$agent_home/SESSION-TYPE.md"
  {
    printf '# broken\n\n'
    printf '%s -->\n' "$BEGIN_PREFIX"
    printf '## Agent Bridge Runtime Canon\n- orphan content\n\n'
    printf 'custom tail content that must NOT be eaten\n'
  } >"$agent_home/CLAUDE.md"

  local before_md5 begin_before
  before_md5="$(python3 -c 'import hashlib,sys; print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$agent_home/CLAUDE.md")"
  begin_before="$(count_str "$agent_home/CLAUDE.md" "$BEGIN_PREFIX")"
  smoke_assert_eq "1" "$begin_before" "precondition: orphaned block has exactly 1 BEGIN marker"

  local json
  json="$(run_apply_json broken)"
  smoke_assert_contains "$json" "skipped-unbalanced:" \
    "unbalanced CLAUDE.md must be reported as skipped-unbalanced (#1816 guard)"

  local after_md5 begin_after tail
  after_md5="$(python3 -c 'import hashlib,sys; print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$agent_home/CLAUDE.md")"
  smoke_assert_eq "$before_md5" "$after_md5" \
    "GUARD: unbalanced CLAUDE.md must be left BYTE-IDENTICAL (not corrupted/double-prepended)"
  begin_after="$(count_str "$agent_home/CLAUDE.md" "$BEGIN_PREFIX")"
  smoke_assert_eq "1" "$begin_after" \
    "GUARD: BEGIN count must stay 1 (no double-prepend)"
  tail="$(cat "$agent_home/CLAUDE.md")"
  smoke_assert_contains "$tail" "custom tail content that must NOT be eaten" \
    "GUARD: custom tail content must be preserved"
}

assert_unstamped_block_back_compat() {
  # A pre-stamp (unstamped) BEGIN marker on disk must still be recognized and
  # re-rendered to the new shape (literal marker + in-block version line) —
  # back-compat for blocks already deployed.
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/legacy"
  mkdir -p "$agent_home"
  printf '# legacy soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n' >"$agent_home/SESSION-TYPE.md"
  {
    printf '# legacy\n\n'
    printf '%s -->\n' "$BEGIN_PREFIX"
    printf '## Agent Bridge Runtime Canon\n- old unstamped block\n'
    printf '%s\n\n' "$END_MARKER"
    printf 'preserved custom section\n'
  } >"$agent_home/CLAUDE.md"

  run_apply legacy
  local block
  block="$(cat "$agent_home/CLAUDE.md")"
  # #2062: re-render yields the literal marker + the in-block version line.
  smoke_assert_contains "$block" "$BEGIN_MARKER" \
    "unstamped block must be re-rendered to the literal-marker form (back-compat, #2062)"
  smoke_assert_contains "$block" "$VERSION_PREFIX " \
    "unstamped block must be re-rendered with the in-block version line (#1816/#2062)"
  smoke_assert_contains "$block" "preserved custom section" \
    "custom content outside markers must survive the re-render"
  local begin_count
  begin_count="$(count_str "$agent_home/CLAUDE.md" "$BEGIN_PREFIX")"
  smoke_assert_eq "1" "$begin_count" \
    "re-render of an unstamped block must yield exactly one BEGIN marker (no duplicate)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1816-marker-stamp"
  seed_agent_home
  smoke_run "version stamp lives on the in-block line; marker stays literal (#2062)" \
    assert_version_stamp_emitted
  smoke_run "block is pointer-only (no re-inlined protocol bodies)" \
    assert_pointer_only_block
  smoke_run "no-op apply deposits no new CLAUDE.md backup (changed-only)" \
    assert_changed_only_backup
  smoke_run "unbalanced-marker guard refuses to corrupt an orphaned-BEGIN file" \
    assert_unbalanced_marker_guard
  smoke_run "unstamped pre-existing block is re-rendered to the in-block-stamp form (back-compat)" \
    assert_unstamped_block_back_compat
  smoke_log "passed"
}

main "$@"
