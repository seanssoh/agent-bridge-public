#!/usr/bin/env bash
# shellcheck shell=bash
#
# admin-protocol-shared-link smoke
#
# Pins the wire-up that propagates docs/agent-runtime/admin-protocol.md
# into <bridge_home>/shared/ADMIN-PROTOCOL.md and links it from each
# agent home as ADMIN-PROTOCOL.md -> ../shared/ADMIN-PROTOCOL.md.
#
# Before this smoke landed, the agent CLAUDE.md managed block pointed
# admin sessions at `ADMIN-PROTOCOL.md` but `AGENT_SHARED_LINKS` did
# not list it and no shared renderer existed, so the file was never
# created and the symlink was missing from every agent home (admin
# included). This smoke fails fast if either half regresses.
#
# macOS-friendly. No heredocs / here-strings in this body (footgun #11).

set -euo pipefail

SMOKE_NAME="admin-protocol-shared-link"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

seed_agent_home() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  mkdir -p "$agent_home/.claude"
  printf '# patch soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: admin\n' >"$agent_home/SESSION-TYPE.md"
  # Minimal CLAUDE.md — bridge-docs.py apply will wrap the managed
  # block around it; we only care that the agent dir exists and is
  # recognized as a valid agent home.
  printf '# patch\n\nadmin smoke fixture\n' >"$agent_home/CLAUDE.md"
}

run_bridge_docs_apply() {
  python3 "$SMOKE_REPO_ROOT/bridge-docs.py" apply patch \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$BRIDGE_AGENT_HOME_ROOT" \
    --source-shared "$SMOKE_TMP_ROOT/nonexistent-source-shared" \
    >/dev/null
}

assert_shared_file_written() {
  local shared_file="$BRIDGE_HOME/shared/ADMIN-PROTOCOL.md"
  smoke_assert_file_exists "$shared_file" \
    "shared ADMIN-PROTOCOL.md must be written by render dispatch"

  local body
  body="$(cat "$shared_file")"
  smoke_assert_contains "$body" "Managed by agent-bridge" \
    "shared ADMIN-PROTOCOL.md must carry the managed header marker"
  smoke_assert_contains "$body" "Admin Protocol" \
    "shared ADMIN-PROTOCOL.md must include the canonical source body"
  smoke_assert_contains "$body" "Session Type" \
    "shared ADMIN-PROTOCOL.md must reference Session Type gating (source body sentinel)"
}

assert_agent_symlink_created() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/patch"
  local link="$agent_home/ADMIN-PROTOCOL.md"

  [[ -L "$link" ]] || smoke_fail \
    "agent home must contain ADMIN-PROTOCOL.md as a symlink (got non-symlink or missing)"

  local target
  target="$(readlink "$link")"
  smoke_assert_eq "../shared/ADMIN-PROTOCOL.md" "$target" \
    "ADMIN-PROTOCOL.md symlink must point to ../shared/ADMIN-PROTOCOL.md"

  # Resolve must succeed — broken symlinks would defeat the wire-up.
  [[ -f "$link" ]] || smoke_fail \
    "ADMIN-PROTOCOL.md symlink target must resolve to an existing file"

  # Companion symlinks must still be wired (regression guard so adding
  # ADMIN-PROTOCOL.md to AGENT_SHARED_LINKS did not displace the others).
  [[ -L "$agent_home/COMMON-INSTRUCTIONS.md" ]] || smoke_fail \
    "COMMON-INSTRUCTIONS.md symlink must remain wired alongside ADMIN-PROTOCOL.md"
  [[ -L "$agent_home/CHANGE-POLICY.md" ]] || smoke_fail \
    "CHANGE-POLICY.md symlink must remain wired alongside ADMIN-PROTOCOL.md"
  [[ -L "$agent_home/TOOLS.md" ]] || smoke_fail \
    "TOOLS.md symlink must remain wired alongside ADMIN-PROTOCOL.md"
}

assert_idempotent_rerun() {
  # Second apply must not break anything: shared file still present,
  # symlink still pointing at the right target.
  run_bridge_docs_apply
  assert_shared_file_written
  assert_agent_symlink_created
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "admin-protocol"
  seed_agent_home
  smoke_run "bridge-docs.py apply writes shared/ADMIN-PROTOCOL.md from source body" \
    run_bridge_docs_apply
  smoke_run "shared ADMIN-PROTOCOL.md exists with managed marker and source body" \
    assert_shared_file_written
  smoke_run "agent home links ADMIN-PROTOCOL.md -> ../shared/ADMIN-PROTOCOL.md" \
    assert_agent_symlink_created
  smoke_run "second apply is idempotent and preserves the wire-up" \
    assert_idempotent_rerun
  smoke_log "passed"
}

main "$@"
