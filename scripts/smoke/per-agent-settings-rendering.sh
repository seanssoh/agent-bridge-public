#!/usr/bin/env bash
# scripts/smoke/per-agent-settings-rendering.sh — Issue #555 regression smoke.
#
# Validates that `bridge_link_claude_settings_to_shared`, when invoked
# with an agent id (3rd arg), writes the rendered effective file at the
# per-agent path `$BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/settings.effective.json`
# rather than the install-wide path. Mixed-model installs no longer
# last-rerender-wins on `autoCompactWindow` (or any future per-agent
# managed default).
#
# Sub-tests:
#   1. agent-A (launch_cmd contains '[1m]') gets autoCompactWindow=1_000_000
#      in its per-agent file.
#   2. agent-B (launch_cmd lacks '[1m]') gets autoCompactWindow=400_000 in
#      its per-agent file.
#   3. Each agent's workdir settings.json is a symlink to its own per-agent
#      effective file (NOT to the install-wide one).
#   4. Re-rendering agent-A AFTER agent-B does not touch agent-B's per-agent
#      file (independence proven — the original mixed-model bug).
#   5. Back-compat: when agent id is omitted, rendering still writes the
#      install-wide file at the legacy path.
#   6. Setup path (#555 r2): bridge-setup.sh's run_agent invokes
#      `bridge_ensure_claude_stop_hook` / `bridge_ensure_claude_prompt_hook`
#      after channel setup. Pre-fix it passed empty launch_cmd, clobbering
#      the per-agent effective file back to the legacy 400_000 default.
#      Post-fix it must resolve launch_cmd and preserve 1_000_000 for [1m]
#      agents.

set -euo pipefail

SMOKE_NAME="per-agent-settings-rendering"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

settings_value() {
  local settings_file="$1"
  local key="$2"
  python3 - "$settings_file" "$key" <<'PY'
import json
import sys
from pathlib import Path

settings_file, key = sys.argv[1:]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
print(payload.get(key))
PY
}

file_sha256() {
  local path="$1"
  python3 - "$path" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

invoke_link_for_agent() {
  # Drives `bridge_link_claude_settings_to_shared` from a child bash that
  # sources the helper library exactly the way the live callers do
  # (rerender loop, run_create, propagate-claude-hooks). This is the unit
  # under test — going through the real helper catches a regression in the
  # bash plumbing as well as the underlying Python renderer call.
  local agent="$1"
  local workdir="$2"
  local launch_cmd="$3"
  "$BRIDGE_BASH_BIN_OR_DEFAULT" -lc '
    set -euo pipefail
    source "$1/bridge-lib.sh"
    bridge_link_claude_settings_to_shared "$2" "$3" "$4"
  ' -- "$SMOKE_REPO_ROOT" "$workdir" "$launch_cmd" "$agent" >/dev/null
}

invoke_link_install_wide() {
  # Back-compat path: omit the agent id, expect the install-wide file.
  local workdir="$1"
  local launch_cmd="$2"
  "$BRIDGE_BASH_BIN_OR_DEFAULT" -lc '
    set -euo pipefail
    source "$1/bridge-lib.sh"
    bridge_link_claude_settings_to_shared "$2" "$3"
  ' -- "$SMOKE_REPO_ROOT" "$workdir" "$launch_cmd" >/dev/null
}

invoke_setup_ensure_helpers_for_agent() {
  # Issue #555 r2: simulates bridge-setup.sh:run_agent's post-channel
  # ensure block. Drives the same two helpers (`bridge_ensure_claude_stop_hook`
  # and `bridge_ensure_claude_prompt_hook`) the way the FIXED run_agent
  # does — with the resolved launch_cmd, so the post-ensure relink hits
  # the renderer with the right managed-default context. Pre-fix this
  # passed empty launch_cmd and clobbered [1m] agents back to 400_000.
  local agent="$1"
  local workdir="$2"
  local launch_cmd="$3"
  "$BRIDGE_BASH_BIN_OR_DEFAULT" -lc '
    set -euo pipefail
    source "$1/bridge-lib.sh"
    bridge_ensure_claude_stop_hook "$2" "$3" "$4" >/dev/null
    bridge_ensure_claude_prompt_hook "$2" "$3" "$4" >/dev/null
  ' -- "$SMOKE_REPO_ROOT" "$workdir" "$launch_cmd" "$agent" >/dev/null
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"

  BRIDGE_BASH_BIN_OR_DEFAULT="${BRIDGE_BASH_BIN:-$(command -v bash)}"

  local install_wide_dir agent_a_workdir agent_b_workdir
  install_wide_dir="$BRIDGE_AGENT_HOME_ROOT/.claude"
  agent_a_workdir="$BRIDGE_AGENT_HOME_ROOT/agent-a"
  agent_b_workdir="$BRIDGE_AGENT_HOME_ROOT/agent-b"
  mkdir -p "$install_wide_dir" "$agent_a_workdir/.claude" "$agent_b_workdir/.claude"

  # Minimal valid install-wide base + overlay so managed defaults
  # dominate the rendered effective file. Real installs carry hook wiring
  # in the base; we only assert on autoCompactWindow here, which the
  # managed-defaults layer always supplies. The renderer requires base to
  # be a valid JSON object (see ensure_settings_root in bridge-hooks.py);
  # an empty file would raise JSONDecodeError.
  printf '%s\n' '{}' >"$install_wide_dir/settings.json"
  printf '%s\n' '{}' >"$install_wide_dir/settings.local.json"

  smoke_log "case 1: agent-A ([1m] launch_cmd) renders per-agent file with autoCompactWindow=1_000_000"
  invoke_link_for_agent agent-a "$agent_a_workdir" "claude --model claude-opus-4-7[1m]"
  local agent_a_effective="$agent_a_workdir/.claude/settings.effective.json"
  smoke_assert_file_exists "$agent_a_effective" "agent-A per-agent effective file rendered"
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A autoCompactWindow=1_000_000 ([1m])"

  smoke_log "case 2: agent-B (non-[1m] launch_cmd) renders per-agent file with autoCompactWindow=400_000"
  invoke_link_for_agent agent-b "$agent_b_workdir" "claude --model claude-opus-4-6"
  local agent_b_effective="$agent_b_workdir/.claude/settings.effective.json"
  smoke_assert_file_exists "$agent_b_effective" "agent-B per-agent effective file rendered"
  smoke_assert_eq "400000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B autoCompactWindow=400_000 (pre-1M)"

  smoke_log "case 3: each agent's workdir settings.json is a symlink to its own per-agent effective file"
  local agent_a_link="$agent_a_workdir/.claude/settings.json"
  local agent_b_link="$agent_b_workdir/.claude/settings.json"
  [[ -L "$agent_a_link" ]] || smoke_fail "agent-A workdir settings.json should be a symlink"
  [[ -L "$agent_b_link" ]] || smoke_fail "agent-B workdir settings.json should be a symlink"
  local agent_a_target agent_b_target
  agent_a_target="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$agent_a_link")"
  agent_b_target="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$agent_b_link")"
  smoke_assert_eq "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$agent_a_effective")" "$agent_a_target" "agent-A symlink resolves to agent-A's per-agent effective file"
  smoke_assert_eq "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$agent_b_effective")" "$agent_b_target" "agent-B symlink resolves to agent-B's per-agent effective file"

  smoke_log "case 4: re-rendering agent-A does NOT touch agent-B's per-agent file (mixed-model independence)"
  local agent_b_sha_before
  agent_b_sha_before="$(file_sha256 "$agent_b_effective")"
  invoke_link_for_agent agent-a "$agent_a_workdir" "claude --model claude-opus-4-7[1m]"
  smoke_assert_eq "$agent_b_sha_before" "$(file_sha256 "$agent_b_effective")" "agent-B per-agent file unchanged after agent-A rerender"
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A still 1_000_000 after rerender"
  smoke_assert_eq "400000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B still 400_000 after agent-A rerender"

  smoke_log "case 5: back-compat — omitting agent id renders install-wide file"
  local install_wide_effective="$install_wide_dir/settings.effective.json"
  rm -f "$install_wide_effective"
  local back_compat_workdir="$BRIDGE_AGENT_HOME_ROOT/legacy-back-compat"
  mkdir -p "$back_compat_workdir/.claude"
  invoke_link_install_wide "$back_compat_workdir" "claude --model claude-opus-4-7[1m]"
  smoke_assert_file_exists "$install_wide_effective" "back-compat (no agent id) renders install-wide effective file"
  smoke_assert_eq "1000000" "$(settings_value "$install_wide_effective" autoCompactWindow)" "install-wide file picks up [1m] launch_cmd"
  # Per-agent files for agent-A/agent-B remain untouched by the back-compat call.
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A per-agent file unaffected by install-wide back-compat render"
  smoke_assert_eq "400000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B per-agent file unaffected by install-wide back-compat render"

  smoke_log "case 6: setup path preserves [1m] launch_cmd through ensure helpers (#555 r2)"
  # Pre-state: agent-A's per-agent file is already at 1_000_000 (from cases 1/4).
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A pre-setup baseline still 1_000_000"
  # Act: simulate bridge-setup.sh:run_agent invoking the ensure helpers
  # the way the FIX does — passing the resolved [1m] launch_cmd through.
  invoke_setup_ensure_helpers_for_agent agent-a "$agent_a_workdir" "claude --model claude-opus-4-7[1m]"
  # Assert: per-agent effective file STILL holds the [1m] managed default,
  # not the empty-launch_cmd legacy 400_000 fallback the renderer would
  # otherwise have written.
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A per-agent file STILL 1_000_000 after setup-style ensure (no clobber to 400_000)"
  # And agent-B (the non-[1m] sibling) remains untouched — no cross-agent leak.
  smoke_assert_eq "400000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B per-agent file unaffected by agent-A setup-style ensure"

  smoke_log "PASS: per-agent settings.effective.json rendering (#555)"
}

main "$@"
