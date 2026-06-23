#!/usr/bin/env bash
# shellcheck shell=bash
#
# 1814-memory-schema-symlink-clobber-guard smoke (DATA-LOSS)
#
# Pins two halves of issue #1814:
#
#  A. SSOT unify — MEMORY-SCHEMA.md is propagated from the canon doc
#     (docs/agent-runtime/memory-schema.md) into <bridge_home>/shared/ and
#     symlinked from each agent home, exactly like ADMIN-PROTOCOL.md /
#     COMMON-INSTRUCTIONS.md. The old per-home template fork is retired.
#
#  B. Symlink-clobber guard (the data-loss fix) — sync_memory_schema_from_template
#     must NEVER write through a symlink. The migration guide / canon header
#     describe a `MEMORY-SCHEMA.md -> <canon>` symlink wiring; the old
#     `target.write_bytes(template_bytes)` followed that link and would have
#     overwritten the *canonical* doc with the smaller template fork fleet-wide
#     in one apply pass. This smoke MUTATION-PROVES the guard: with the guard
#     the canon target survives; the same write WITHOUT the guard (the old
#     vulnerable line, exercised inline) destroys it — so the test is
#     non-vacuous, not green-by-skip.
#
# macOS-friendly. No heredocs / here-strings in this body (footgun #11).

set -euo pipefail

SMOKE_NAME="1814-memory-schema-symlink-clobber-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PRECIOUS_CANON=""

seed_agent_home() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/tester"
  mkdir -p "$agent_home" "$BRIDGE_AGENT_HOME_ROOT/_template"
  printf '# tester soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n' >"$agent_home/SESSION-TYPE.md"
  printf '# tester\n\ncustom content\n' >"$agent_home/CLAUDE.md"
  # The diverged template fork (smaller body) that the legacy sync would copy.
  printf '# SMALL TEMPLATE FORK\nold drift body\n' >"$BRIDGE_AGENT_HOME_ROOT/_template/MEMORY-SCHEMA.md"
  # A template-copy MEMORY-SCHEMA.md in the home (pre-first-apply state): a
  # regular file, the fork. ensure_agent_shared_links must replace it with a
  # symlink to the shared canon body.
  printf '# SMALL TEMPLATE FORK\nold drift body\n' >"$agent_home/MEMORY-SCHEMA.md"
}

run_bridge_docs_apply() {
  python3 "$SMOKE_REPO_ROOT/bridge-docs.py" apply tester \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$BRIDGE_AGENT_HOME_ROOT" \
    --source-shared "$SMOKE_TMP_ROOT/nonexistent-source-shared" \
    >/dev/null
}

assert_shared_canon_written() {
  local shared_file="$BRIDGE_HOME/shared/MEMORY-SCHEMA.md"
  smoke_assert_file_exists "$shared_file" \
    "shared MEMORY-SCHEMA.md must be written from the canon body (#1814)"
  local body
  body="$(cat "$shared_file")"
  smoke_assert_contains "$body" "Managed by agent-bridge" \
    "shared MEMORY-SCHEMA.md must carry the managed-source header"
  smoke_assert_contains "$body" "Source: docs/agent-runtime/memory-schema.md" \
    "shared MEMORY-SCHEMA.md header must name the canon source doc"
  smoke_assert_contains "$body" "Agent Runtime — Memory Schema" \
    "shared MEMORY-SCHEMA.md must carry the canon body (source sentinel)"
  # The diverged fork's sentinel must NOT have leaked into the shared canon.
  smoke_assert_not_contains "$body" "SMALL TEMPLATE FORK" \
    "shared MEMORY-SCHEMA.md must be the canon body, not the template fork"
}

assert_home_symlink_resolves_to_shared() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/tester"
  local link="$agent_home/MEMORY-SCHEMA.md"
  [[ -L "$link" ]] || smoke_fail \
    "home MEMORY-SCHEMA.md must be a symlink after apply (#1814 SSOT unify), got non-symlink"
  local resolved expected
  resolved="$(cd -P "$agent_home" 2>/dev/null && python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "MEMORY-SCHEMA.md")"
  expected="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BRIDGE_HOME/shared/MEMORY-SCHEMA.md")"
  smoke_assert_eq "$expected" "$resolved" \
    "home MEMORY-SCHEMA.md symlink must resolve to <bridge_home>/shared/MEMORY-SCHEMA.md"
  [[ -f "$link" ]] || smoke_fail \
    "home MEMORY-SCHEMA.md symlink target must resolve to an existing file"
}

# --- Clobber guard: the data-loss core. -------------------------------------

setup_symlinked_victim() {
  # A fresh home whose MEMORY-SCHEMA.md is a SYMLINK to a precious canon file
  # (simulating the documented MEMORY-SCHEMA -> canon wiring). The legacy
  # template-sync must refuse to write through it.
  local victim="$BRIDGE_AGENT_HOME_ROOT/victim"
  mkdir -p "$victim"
  printf '# victim soul\n' >"$victim/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n' >"$victim/SESSION-TYPE.md"
  printf '# victim\n\ncustom\n' >"$victim/CLAUDE.md"
  PRECIOUS_CANON="$SMOKE_TMP_ROOT/PRECIOUS-CANON.md"
  printf 'PRECIOUS CANON BODY — irreplaceable schema\n' >"$PRECIOUS_CANON"
  ln -s "$PRECIOUS_CANON" "$victim/MEMORY-SCHEMA.md"
}

assert_guard_preserves_canon() {
  # Call sync_memory_schema_from_template DIRECTLY (isolating the guard from
  # ensure_agent_shared_links, which would otherwise re-point the link first).
  python3 "$SMOKE_REPO_ROOT/scripts/smoke/1814-clobber-probe.py" \
    "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT/victim" guarded >/dev/null
  local after
  after="$(cat "$PRECIOUS_CANON")"
  smoke_assert_contains "$after" "PRECIOUS CANON BODY" \
    "GUARD: canon target must SURVIVE the guarded template-sync (no clobber)"
  [[ -L "$BRIDGE_AGENT_HOME_ROOT/victim/MEMORY-SCHEMA.md" ]] || smoke_fail \
    "GUARD: home MEMORY-SCHEMA.md must remain a symlink (guard must not unlink it)"
}

assert_unguarded_write_destroys_canon() {
  # Non-vacuous half: the OLD vulnerable write (write_bytes through the symlink)
  # MUST destroy the canon. If this no longer clobbers, the precondition is
  # wrong and the guard test above would be meaningless.
  printf 'PRECIOUS CANON BODY — irreplaceable schema\n' >"$PRECIOUS_CANON"
  python3 "$SMOKE_REPO_ROOT/scripts/smoke/1814-clobber-probe.py" \
    "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT/victim" unguarded >/dev/null
  local after
  after="$(cat "$PRECIOUS_CANON")"
  smoke_assert_not_contains "$after" "PRECIOUS CANON BODY" \
    "NON-VACUOUS: the unguarded write_bytes MUST clobber the canon (proves the guard matters)"
  smoke_assert_contains "$after" "SMALL TEMPLATE FORK" \
    "NON-VACUOUS: the unguarded write replaces the canon with the template fork"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1814-memory-schema"
  seed_agent_home
  smoke_run "bridge-docs.py apply propagates the canon MEMORY-SCHEMA into shared/" \
    run_bridge_docs_apply
  smoke_run "shared/MEMORY-SCHEMA.md is the canon body, not the template fork" \
    assert_shared_canon_written
  smoke_run "home MEMORY-SCHEMA.md is a symlink resolving to the shared canon" \
    assert_home_symlink_resolves_to_shared
  smoke_run "set up a symlinked-to-canon victim home" \
    setup_symlinked_victim
  smoke_run "GUARD: guarded template-sync leaves the symlinked canon intact" \
    assert_guard_preserves_canon
  smoke_run "NON-VACUOUS: the old unguarded write destroys the canon" \
    assert_unguarded_write_destroys_canon
  smoke_log "passed"
}

main "$@"
