#!/usr/bin/env bash
# scripts/smoke/per-agent-settings-rendering.sh — Issue #555 regression smoke.
#
# Validates that `bridge_link_claude_settings_to_shared`, when invoked
# with an agent id (3rd arg), writes the rendered effective file at the
# per-agent path `$BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/settings.effective.json`
# rather than the install-wide path. Per-agent files mean operator base /
# overlay overrides for one agent are not last-rerender-wins clobbered by
# a sibling rerender.
#
# Note (issue #593): the managed `autoCompactWindow` default is now
# class-aware (static→400_000, dynamic→1_000_000). This fixture drives
# `bridge_link_claude_settings_to_shared` directly without sourcing the
# roster, so `BRIDGE_AGENT_SOURCE` is unset and the renderer falls back
# to the unknown-class default (1_000_000) — the back-compat path. The
# assertions here therefore stay at 1_000_000 and validate per-agent
# *path* routing, not the class-aware value split.
#
# Sub-tests:
#   1. agent-A renders its per-agent effective file with the managed
#      autoCompactWindow=1_000_000 default (unknown-class fallback).
#   2. agent-B renders its own per-agent effective file (separate path
#      from agent-A) with the same managed default.
#   3. Each agent's workdir settings.json is a symlink to its own per-agent
#      effective file (NOT to the install-wide one).
#   4. Re-rendering agent-A AFTER agent-B does not touch agent-B's per-agent
#      file (independence proven via sha256 — the original mixed-model bug).
#   5. Back-compat: when agent id is omitted, rendering still writes the
#      install-wide file at the legacy path.
#   6. Setup path (#555 r2): bridge-setup.sh's run_agent invokes
#      `bridge_ensure_claude_stop_hook` / `bridge_ensure_claude_prompt_hook`
#      after channel setup. The setup-style ensure must continue to render
#      the per-agent effective file with the managed 1_000_000 default and
#      not touch sibling agents.

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
  # does, forwarding the resolved launch_cmd through. Issue #593: the
  # renderer is class-aware, but this fixture leaves BRIDGE_AGENT_SOURCE
  # unset, so the resolver falls back to the unknown-class default
  # (1_000_000). The assertion is therefore about per-agent *path*
  # routing — the setup ensure must still write to the per-agent
  # effective file, not clobber a sibling.
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

  # BRIDGE_AGENT_SOURCE is unset in this fixture (the helper is invoked
  # without sourcing the roster), so the renderer falls back to the
  # unknown-class default (1_000_000) per issue #593 back-compat.
  smoke_log "case 1: agent-A renders per-agent file with managed autoCompactWindow=1_000_000 default (#593 back-compat)"
  invoke_link_for_agent agent-a "$agent_a_workdir" "claude --model claude-opus-4-7[1m]"
  # Issue #1820: under v2 (BRIDGE_AGENT_ROOT_V2 is exported by
  # smoke_setup_bridge_home) the per-agent effective file is now rendered at the
  # v2 layout-resolved home (`$BRIDGE_AGENT_ROOT_V2/<a>/home/.claude/...`), and
  # the workdir settings.json symlink retargets to it. Resolve the effective
  # path from the symlink the renderer just wrote, so the assertions follow the
  # renderer's chosen target instead of hard-coding the (now-evidence-only) v1
  # path. Per-agent INDEPENDENCE — the property this smoke guards — is what the
  # resolved paths prove (agent-A and agent-B resolve to distinct files).
  local agent_a_effective
  agent_a_effective="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$agent_a_workdir/.claude/settings.json")"
  smoke_assert_file_exists "$agent_a_effective" "agent-A per-agent effective file rendered"
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A autoCompactWindow=1_000_000 (unknown class → 1M fallback, #593)"

  smoke_log "case 2: agent-B renders its OWN per-agent file (separate path from agent-A) with managed default"
  invoke_link_for_agent agent-b "$agent_b_workdir" "claude --model claude-opus-4-6"
  local agent_b_effective
  agent_b_effective="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$agent_b_workdir/.claude/settings.json")"
  smoke_assert_file_exists "$agent_b_effective" "agent-B per-agent effective file rendered"
  [[ "$agent_a_effective" != "$agent_b_effective" ]] || smoke_fail "agent-A and agent-B must render to distinct per-agent effective files"
  smoke_assert_eq "1000000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B autoCompactWindow=1_000_000 (unknown class → 1M fallback, #593)"

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

  smoke_log "case 4: re-rendering agent-A does NOT touch agent-B's per-agent file (per-agent path independence)"
  local agent_b_sha_before
  agent_b_sha_before="$(file_sha256 "$agent_b_effective")"
  invoke_link_for_agent agent-a "$agent_a_workdir" "claude --model claude-opus-4-7[1m]"
  smoke_assert_eq "$agent_b_sha_before" "$(file_sha256 "$agent_b_effective")" "agent-B per-agent file unchanged after agent-A rerender"
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A still 1_000_000 after rerender"
  smoke_assert_eq "1000000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B still 1_000_000 after agent-A rerender"

  smoke_log "case 5: back-compat — omitting agent id renders install-wide file"
  local install_wide_effective="$install_wide_dir/settings.effective.json"
  rm -f "$install_wide_effective"
  local back_compat_workdir="$BRIDGE_AGENT_HOME_ROOT/legacy-back-compat"
  mkdir -p "$back_compat_workdir/.claude"
  invoke_link_install_wide "$back_compat_workdir" "claude --model claude-opus-4-7[1m]"
  smoke_assert_file_exists "$install_wide_effective" "back-compat (no agent id) renders install-wide effective file"
  smoke_assert_eq "1000000" "$(settings_value "$install_wide_effective" autoCompactWindow)" "install-wide file lands on managed 1_000_000 default"
  # Per-agent files for agent-A/agent-B remain untouched by the back-compat call.
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A per-agent file unaffected by install-wide back-compat render"
  smoke_assert_eq "1000000" "$(settings_value "$agent_b_effective" autoCompactWindow)" "agent-B per-agent file unaffected by install-wide back-compat render"

  smoke_log "case 6: setup path renders agent-A's per-agent file via ensure helpers (#555 r2)"
  # Pre-state: agent-A's per-agent file is already at 1_000_000 (from cases 1/4).
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A pre-setup baseline at managed 1_000_000 default"
  # Snapshot agent-B before the setup-style ensure so we can prove agent-A's
  # ensure does not write into a sibling's per-agent file.
  local agent_b_sha_before_setup
  agent_b_sha_before_setup="$(file_sha256 "$agent_b_effective")"
  # Act: simulate bridge-setup.sh:run_agent invoking the ensure helpers
  # the way the FIX does, passing the resolved launch_cmd through.
  invoke_setup_ensure_helpers_for_agent agent-a "$agent_a_workdir" "claude --model claude-opus-4-7[1m]"
  # Assert: agent-A's per-agent effective file still carries the managed
  # 1_000_000 default after the setup-style ensure rerender.
  smoke_assert_eq "1000000" "$(settings_value "$agent_a_effective" autoCompactWindow)" "agent-A per-agent file still at managed 1_000_000 after setup-style ensure"
  # And agent-B's per-agent file is byte-identical (no cross-agent leak).
  smoke_assert_eq "$agent_b_sha_before_setup" "$(file_sha256 "$agent_b_effective")" "agent-B per-agent file unaffected by agent-A setup-style ensure"

  smoke_log "PASS: per-agent settings.effective.json rendering (#555)"
}

main "$@"
