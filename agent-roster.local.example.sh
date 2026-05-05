#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# Copy this file to agent-roster.local.sh and adjust it for your machine.
# This file is sourced after agent-roster.sh, so you can add roles here.

# Example: add a common four-role setup.
bridge_add_agent_id_if_missing "tester"
bridge_add_agent_id_if_missing "developer"
bridge_add_agent_id_if_missing "codex-tester"
bridge_add_agent_id_if_missing "codex-developer"

BRIDGE_AGENT_DESC["tester"]="Test role (Claude Code)"
BRIDGE_AGENT_DESC["developer"]="Development role (Claude Code)"
BRIDGE_AGENT_DESC["codex-tester"]="Test role (Codex)"
BRIDGE_AGENT_DESC["codex-developer"]="Development role (Codex)"

BRIDGE_AGENT_ENGINE["tester"]="claude"
BRIDGE_AGENT_ENGINE["developer"]="claude"
BRIDGE_AGENT_ENGINE["codex-tester"]="codex"
BRIDGE_AGENT_ENGINE["codex-developer"]="codex"

BRIDGE_AGENT_SESSION["tester"]="tester"
BRIDGE_AGENT_SESSION["developer"]="developer"
BRIDGE_AGENT_SESSION["codex-tester"]="codex-tester"
BRIDGE_AGENT_SESSION["codex-developer"]="codex-developer"

# Optional: standard long-lived roles can live under $BRIDGE_HOME/agents/<agent>.
# If you follow that layout, you can omit BRIDGE_AGENT_WORKDIR entirely and the
# bridge will default to $BRIDGE_AGENT_HOME_ROOT/<agent>.
# BRIDGE_AGENT_HOME_ROOT="$HOME/.agent-bridge/agents"
#
# Optional: designate one static role as the bridge admin role. Then
# `agent-bridge admin` / `agb admin` will always open that role in its own
# configured home regardless of the current directory.
# BRIDGE_ADMIN_AGENT_ID="developer"

# Optional: override workdirs when a role should launch inside another repo or
# directory instead of the standard live home root.
# BRIDGE_AGENT_WORKDIR["tester"]="$HOME/project-test"
# BRIDGE_AGENT_WORKDIR["developer"]="$HOME/project-app"
# BRIDGE_AGENT_WORKDIR["codex-tester"]="$HOME/project-test"
# BRIDGE_AGENT_WORKDIR["codex-developer"]="$HOME/project-app"

# Optional: tracked profile deploy target. If omitted for a tracked agent, the
# bridge defaults to $BRIDGE_AGENT_HOME_ROOT/<agent>. Override this only when
# the live CLI home differs from the workdir.
# BRIDGE_AGENT_PROFILE_HOME["tester"]="$HOME/project-test"
# BRIDGE_AGENT_PROFILE_HOME["developer"]="$HOME/project-app"

# Optional external notification transport. This is not the primary A2A
# delivery path for Claude roles; Claude wake currently uses idle-gated local
# tmux sends. Use these only when you explicitly want out-of-band
# Discord/Telegram posts.
# BRIDGE_AGENT_NOTIFY_KIND["tester"]="discord-webhook"
# BRIDGE_AGENT_NOTIFY_TARGET["tester"]="<discord-webhook-url>"
# BRIDGE_AGENT_NOTIFY_ACCOUNT["tester"]="default"
# BRIDGE_AGENT_NOTIFY_KIND["developer"]="telegram"
# BRIDGE_AGENT_NOTIFY_TARGET["developer"]="<telegram-chat-or-thread-id>"
# BRIDGE_AGENT_NOTIFY_ACCOUNT["developer"]="default"
# BRIDGE_AGENT_DISCORD_CHANNEL_ID["tester"]="<channel-id>"
# The channel id is still useful for Discord wake relay / metadata.
# Optional: declare required Claude plugin channels separately from the raw
# launch command so the bridge can validate and inject them consistently.
# BRIDGE_AGENT_CHANNELS["tester"]="plugin:discord@claude-plugins-official"
# BRIDGE_AGENT_CHANNELS["developer"]="plugin:telegram@claude-plugins-official"
#
# Optional: per-agent plugin allowlist (issue #272). When set, every globally-
# installed Claude plugin (per ~/.claude/plugins/installed_plugins.json) that
# is NOT in the allowlist (and is not declared as a channel above) is
# disabled in this agent's `agents/<agent>/.claude/settings.local.json` so
# the Claude session does not spawn that plugin's MCP server. Plugins from
# BRIDGE_AGENT_CHANNELS are auto-included so allowlist mistakes do not break
# a declared channel. Agents without this key inherit the legacy "all
# plugins enabled" behaviour (no regression for existing rosters).
# Tokens are space- or comma-separated, with or without a `plugin:` prefix.
# BRIDGE_AGENT_PLUGINS["tester"]="syrs-shopify@syrs-local syrs-gmail@syrs-local"
# BRIDGE_AGENT_PLUGINS["developer"]="superpowers@claude-plugins-official"
# Optional: declare extra runtime skills to symlink into managed Claude homes.
# These should match directories under ~/.agent-bridge/runtime/skills/.
# BRIDGE_AGENT_SKILLS["tester"]="shopify-api tracx-logis-api"
# BRIDGE_AGENT_SKILLS["developer"]="agent-db"
#
# Optional/backlog: dormant custom channel port. The runtime path does not use
# this today because development channels require an interactive trust prompt.
# Keep it unset on normal installs.
# BRIDGE_AGENT_WEBHOOK_PORT["tester"]="9001"
#
# After setting the primary channel id, scaffold the runtime Discord files with:
#   agent-bridge setup discord tester
#   agent-bridge setup agent tester

# Optional: map source cron agent ids to bridge agents for cron enqueue.
# Prefer BRIDGE_CRON_AGENT_TARGET; BRIDGE_LEGACY_AGENT_TARGET remains as a
# compatibility alias for older local configs. BRIDGE_OPENCLAW_AGENT_TARGET is
# still accepted as a hidden legacy alias.
# BRIDGE_CRON_AGENT_TARGET["legacy-agent"]="tester"
# BRIDGE_CRON_AGENT_TARGET["legacy-ops"]="developer"
# BRIDGE_CRON_FALLBACK_AGENT="developer"

# The bridge-owned recurring scheduler is on by default. Uncomment the line
# below (setting to 0) to opt out on machines that should not actively enqueue
# recurring jobs.
# BRIDGE_CRON_SYNC_ENABLED=0

BRIDGE_AGENT_LAUNCH_CMD["tester"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["developer"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["codex-tester"]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
BRIDGE_AGENT_LAUNCH_CMD["codex-developer"]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'

# Optional: per-agent Claude launch-flag overrides (issue #72).
#
# Leave all three fields unset (the default for legacy rosters) and the
# bridge keeps emitting `claude --dangerously-skip-permissions --name <agent>`
# byte-for-byte as before. Set ANY one field to opt the agent into the new
# launch shape `claude --model <model> --effort <effort> --permission-mode
# <mode> --name <agent>`; any field still unset on that agent falls back to
# the fleet defaults shown below.
#
# BRIDGE_AGENT_MODEL["developer"]="claude-opus-4-7"            # default: claude-opus-4-7
# BRIDGE_AGENT_EFFORT["developer"]="xhigh"                      # default: xhigh
# BRIDGE_AGENT_PERMISSION_MODE["developer"]="auto"              # default: auto
#
# To pin an agent to the historical blanket-bypass shape (e.g. a sandboxed
# offline role) without removing the model/effort hints, set permission_mode
# explicitly to "legacy":
# BRIDGE_AGENT_PERMISSION_MODE["sandboxed"]="legacy"

# Optional: auto-stop timeout in seconds. Set this only for roles you
# explicitly want the daemon to stop after inactivity. An explicit `0` marks a
# static role as always-on: the daemon will keep it running and restart it if
# its tmux session disappears.
# BRIDGE_AGENT_IDLE_TIMEOUT["tester"]="900"
# BRIDGE_AGENT_IDLE_TIMEOUT["always-on-role"]="0"
# BRIDGE_AGENT_IDLE_TIMEOUT["codex-tester"]="300"

BRIDGE_AGENT_ACTION["tester:resume"]="/resume"
BRIDGE_AGENT_ACTION["tester:clear"]="/clear"
BRIDGE_AGENT_ACTION["developer:resume"]="/resume"
BRIDGE_AGENT_ACTION["developer:clear"]="/clear"

# Optional: dashboard health-check thresholds for active sessions.
# BRIDGE_HEALTH_WARN_SECONDS=3600
# BRIDGE_HEALTH_CRITICAL_SECONDS=14400

# Issue #597 Track B: PreCompact channel auto-notify (Claude /compact only).
#
# When Claude Code starts an auto-compact on a static, channel-bound agent,
# the daemon can post a "I'm compacting now, back in ~Ns" message in the
# most recently active bound channel and a "back online" follow-up once the
# session returns. Default is OFF for every agent — opt in here.
#
# Eligibility requires ALL of:
#   - BRIDGE_AGENT_PRECOMPACT_NOTIFY[<agent>]="1"
#   - agent is engine=claude AND source=static (declared in this file)
#   - BRIDGE_AGENT_CHANNELS[<agent>] resolves to >=1 plugin channel
#   - the trigger is "auto" (operator /compact is intentionally silent)
#   - the most recent inbound user message is within
#     BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS (default 1800s).
#
# BRIDGE_AGENT_PRECOMPACT_NOTIFY["developer"]="1"
# BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG["developer"]="ko"
#
# Global controls (env or roster):
#   BRIDGE_PRECOMPACT_NOTIFY_DISABLED=1        # kill switch (overrides per-agent)
#   BRIDGE_PRECOMPACT_NOTIFY_LANG="ko"         # fleet default language (en|ko)
#   BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS=1800
#   BRIDGE_PRECOMPACT_NOTICE_DEDUP_SECONDS=300

# Optional: agent class — privilege boundary consumed by hooks/tool-policy.py
# (issue #539). The closed value space is { user, system }; an unknown class
# is a hard error at roster load.
#
#   user   - default. Per-agent isolation; cross-agent reads denied.
#   system - read-only access to other agents' memory/{projects,decisions,
#            shared}/ trees plus shared/* (excluding shared/private/ and
#            shared/secrets/). Bash/Edit/Write outside the agent's own
#            home stay denied even for class=system. Every cross-agent
#            read emits a `system_cross_agent_read` row to audit.jsonl.
#
# Class is intended for ingestion/supervisory roles (e.g., a librarian
# that harvests every agent's memory tree into a shared wiki, or a
# patch/doctor that diagnoses other agents). The shipped public roster
# declares no system-class agents — operators opt in locally.
#
# Example (uncomment and replace the agent name with your local role):
# BRIDGE_AGENT_CLASS["librarian"]="system"
# BRIDGE_AGENT_CLASS["patch"]="system"

# Example: add another long-lived role.
# bridge_add_agent_id_if_missing "reviewer"
# BRIDGE_AGENT_DESC["reviewer"]="Code review role (Claude Code)"
# BRIDGE_AGENT_ENGINE["reviewer"]="claude"
# BRIDGE_AGENT_SESSION["reviewer"]="reviewer"
# BRIDGE_AGENT_WORKDIR["reviewer"]="$HOME/some-project"
# BRIDGE_AGENT_LAUNCH_CMD["reviewer"]='claude --dangerously-skip-permissions'
# BRIDGE_AGENT_ACTION["reviewer:resume"]="/resume"
