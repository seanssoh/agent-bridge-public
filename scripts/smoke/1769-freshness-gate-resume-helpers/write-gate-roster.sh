#!/usr/bin/env bash
# scripts/smoke/1769-freshness-gate-resume-helpers/write-gate-roster.sh
#
# Issue #1769 mechanism 2 — sidecar roster writer for the setup-freshness
# gate smoke. Emits a synthesized agent-roster.local.sh that bridge-start.sh
# sources (via bridge_load_roster) so the smoke can drive the REAL gate code
# in bridge-start.sh deterministically without invoking the production
# hook-status python helpers, skill bootstrap, or plugin provisioning.
#
# The roster body redefines the seven setup-freshness check functions, their
# re-ensure counterparts, and bridge_claude_resume_session_id_for_agent. A
# roster-local function definition wins because bridge_load_roster sources the
# file AFTER lib/*.sh, and the source is in the script's own shell (not a
# subshell), so the overrides persist for the rest of bridge-start.sh.
#
# Shipped as a tracked argv-driven file (rather than a heredoc-to-file body
# inside the parent smoke) per the repo footgun #11 / KNOWN_ISSUES.md §26
# anti-heredoc-stdin convention.
#
# Usage:
#   write-gate-roster.sh <roster_local_file> <workdir> <agent> \
#                        <guidance_needed_rc> <resume_id>
#
#   guidance_needed_rc : 0 => bridge_project_claude_guidance_needed trips
#                            (returns 0 = "needs guidance" = stale CLAUDE.md);
#                        1 => clean (no trip).
#   resume_id          : non-empty => a resolvable resume id is present;
#                        empty     => no resumable session.

set -euo pipefail

roster_file="${1:?roster_local_file required}"
workdir="${2:?workdir required}"
agent="${3:?agent required}"
guidance_rc="${4:?guidance_needed_rc required}"
resume_id="${5-}"

{
  printf '%s\n' "bridge_add_agent_id_if_missing \"$agent\""
  printf '%s\n' "BRIDGE_AGENT_DESC[\"$agent\"]=\"1769 gate smoke\""
  printf '%s\n' "BRIDGE_AGENT_ENGINE[\"$agent\"]=\"claude\""
  printf '%s\n' "BRIDGE_AGENT_SESSION[\"$agent\"]=\"${agent}-sess\""
  printf '%s\n' "BRIDGE_AGENT_WORKDIR[\"$agent\"]=\"$workdir\""
  printf '%s\n' "BRIDGE_AGENT_LAUNCH_CMD[\"$agent\"]=\"claude\""
  printf '%s\n' "BRIDGE_AGENT_LOOP[\"$agent\"]=0"
  printf '%s\n' "BRIDGE_AGENT_CONTINUE[\"$agent\"]=1"
  # Setup-freshness checks. guidance_needed honors the requested rc; the rest
  # pass (return 0 from a status fn = "configured"; the gate trips on `!`).
  printf '%s\n' "bridge_project_claude_guidance_needed() { return $guidance_rc; }"
  printf '%s\n' 'bridge_project_skill_bootstrap_needed() { return 0; }'
  printf '%s\n' 'bridge_claude_stop_hook_status() { return 0; }'
  printf '%s\n' 'bridge_claude_session_start_hook_status() { return 0; }'
  printf '%s\n' 'bridge_claude_prompt_hook_status() { return 0; }'
  printf '%s\n' 'bridge_claude_prompt_guard_hook_status() { return 0; }'
  printf '%s\n' 'bridge_claude_tool_policy_hooks_status() { return 0; }'
  # Re-ensure + side helpers — stubbed to no-ops so the dry-run gate path is
  # hermetic (the production bodies render settings/skills/trust on disk).
  printf '%s\n' 'bridge_ensure_project_claude_guidance() { return 0; }'
  printf '%s\n' 'bridge_bootstrap_project_skill() { return 0; }'
  printf '%s\n' 'bridge_bootstrap_claude_shared_skills() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_first_run_config() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_project_trust() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_stop_hook() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_session_start_hook() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_prompt_hook() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_prompt_guard_hook() { return 0; }'
  printf '%s\n' 'bridge_ensure_claude_tool_policy_hooks() { return 0; }'
  printf '%s\n' 'bridge_ensure_hud_usage_tap() { return 0; }'
  printf '%s\n' 'bridge_disable_claude_webhook_channel() { return 0; }'
  printf '%s\n' 'bridge_agent_channel_status_reason() { printf ""; }'
  # Resolvable resume id (empty string => no resumable session).
  printf '%s\n' "bridge_claude_resume_session_id_for_agent() { printf '%s' '$resume_id'; }"
} >"$roster_file"
