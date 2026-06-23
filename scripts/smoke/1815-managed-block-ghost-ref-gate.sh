#!/usr/bin/env bash
# shellcheck shell=bash
#
# 1815-managed-block-ghost-ref-gate smoke
#
# Pins issue #1815 — the managed block must not tell every agent, every
# session, to consult files that do not exist where they look:
#
#  1. HEARTBEAT.md — a daemon-written status artifact in the agent *workdir*,
#     never an identity-home doc. The block must NOT emit a "read HEARTBEAT.md"
#     bullet (present in 0 homes).
#  2. CHECKLIST.md — a dead AGENT_RUNTIME_REWRITE_FILES entry from a retired
#     generation; dropped from the rewrite tuple.
#  3. HEARTBEAT.md likewise dropped from AGENT_RUNTIME_REWRITE_FILES — the doc
#     engine has no business rewriting a daemon-owned status file.
#
# Contrast: the ACTIVE-PREFERENCES.md bullet IS existence-gated and must still
# appear only when the file exists — that precedent must not regress.
#
# macOS-friendly. No heredocs / here-strings in this body (footgun #11).

set -euo pipefail

SMOKE_NAME="1815-managed-block-ghost-ref-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

seed_agent_home() {
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/tester"
  mkdir -p "$agent_home"
  printf '# tester soul\n' >"$agent_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n' >"$agent_home/SESSION-TYPE.md"
  printf '# tester\n\ncustom content\n' >"$agent_home/CLAUDE.md"
}

run_bridge_docs_apply() {
  python3 "$SMOKE_REPO_ROOT/bridge-docs.py" apply tester \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$BRIDGE_AGENT_HOME_ROOT" \
    --source-shared "$SMOKE_TMP_ROOT/nonexistent-source-shared" \
    >/dev/null
}

assert_block_has_no_heartbeat_ghost() {
  local block
  block="$(cat "$BRIDGE_AGENT_HOME_ROOT/tester/CLAUDE.md")"
  # The block must NOT instruct the agent to read HEARTBEAT.md as a home doc.
  smoke_assert_not_contains "$block" "HEARTBEAT.md" \
    "managed block must NOT emit a HEARTBEAT.md ghost reference (#1815)"
}

assert_shared_common_instructions_has_no_heartbeat_ghost() {
  # Issue #1814 propagates docs/agent-runtime/common-instructions.md VERBATIM
  # into <bridge_home>/shared/COMMON-INSTRUCTIONS.md and symlinks it into every
  # home — so the canon body is a second surface where a HEARTBEAT.md ghost
  # reference would reach all agents. The #1815 ghost-ref fix is only complete
  # if the rendered shared doc (and thus the home symlink target) is clean too.
  local shared_doc="$BRIDGE_HOME/shared/COMMON-INSTRUCTIONS.md"
  smoke_assert_file_exists "$shared_doc" \
    "shared COMMON-INSTRUCTIONS.md must be rendered from the canon body (#1814)"
  local body
  body="$(cat "$shared_doc")"
  smoke_assert_not_contains "$body" "HEARTBEAT.md" \
    "rendered shared COMMON-INSTRUCTIONS.md must carry no HEARTBEAT.md ghost reference (#1815 + #1814 propagation)"
  # The home symlink resolves to this shared doc, so an agent reading
  # COMMON-INSTRUCTIONS.md in its home gets the same clean body. Assert the
  # resolved content directly to pin the end-to-end contract.
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/tester"
  if [[ -e "$agent_home/COMMON-INSTRUCTIONS.md" ]]; then
    local resolved_body
    resolved_body="$(cat "$agent_home/COMMON-INSTRUCTIONS.md")"
    smoke_assert_not_contains "$resolved_body" "HEARTBEAT.md" \
      "home COMMON-INSTRUCTIONS.md (resolved via symlink) must carry no HEARTBEAT.md ghost reference"
  fi
}

assert_rewrite_tuple_pruned() {
  # AGENT_RUNTIME_REWRITE_FILES must no longer carry HEARTBEAT.md / CHECKLIST.md.
  local probe
  probe="$(python3 "$SMOKE_REPO_ROOT/scripts/smoke/1815-rewrite-tuple-probe.py")"
  smoke_assert_contains "$probe" "SOUL.md=present" \
    "SOUL.md must remain a doc-rewrite target"
  smoke_assert_contains "$probe" "HEARTBEAT.md=absent" \
    "HEARTBEAT.md must be dropped from AGENT_RUNTIME_REWRITE_FILES (#1815)"
  smoke_assert_contains "$probe" "CHECKLIST.md=absent" \
    "CHECKLIST.md must be dropped from AGENT_RUNTIME_REWRITE_FILES (#1815)"
}

assert_active_preferences_gate_intact() {
  # The ACTIVE-PREFERENCES.md existence-gate precedent must not regress: the
  # bullet appears only when the file exists.
  local agent_home="$BRIDGE_AGENT_HOME_ROOT/tester"
  local block_absent block_present
  block_absent="$(cat "$agent_home/CLAUDE.md")"
  smoke_assert_not_contains "$block_absent" "ACTIVE-PREFERENCES.md" \
    "ACTIVE-PREFERENCES bullet must be ABSENT when the file does not exist"
  printf '# prefs\n' >"$agent_home/ACTIVE-PREFERENCES.md"
  run_bridge_docs_apply
  block_present="$(cat "$agent_home/CLAUDE.md")"
  smoke_assert_contains "$block_present" "ACTIVE-PREFERENCES.md" \
    "ACTIVE-PREFERENCES bullet must APPEAR once the file exists (gate precedent)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "1815-ghost-ref"
  seed_agent_home
  smoke_run "bridge-docs.py apply renders the managed block" \
    run_bridge_docs_apply
  smoke_run "managed block carries no HEARTBEAT.md ghost reference" \
    assert_block_has_no_heartbeat_ghost
  smoke_run "rendered shared COMMON-INSTRUCTIONS.md carries no HEARTBEAT.md ghost reference" \
    assert_shared_common_instructions_has_no_heartbeat_ghost
  smoke_run "AGENT_RUNTIME_REWRITE_FILES drops HEARTBEAT.md and CHECKLIST.md" \
    assert_rewrite_tuple_pruned
  smoke_run "ACTIVE-PREFERENCES existence-gate precedent is intact" \
    assert_active_preferences_gate_intact
  smoke_log "passed"
}

main "$@"
