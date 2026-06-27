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

# Admin/system role description examples (v0.15.0-beta1 Lane I).
#
# BRIDGE_AGENT_DESC is the human-readable IDENTITY of each agent. Downstream
# agents (cosmax-* installs, A2A peers, etc.) read this string from
# `agent show <name>` / `agent describe <name>` to decide how to address the
# agent and what kind of work to route. A one-line role+ownership sentence is
# the sweet spot — terse enough to be queue-renderable, concrete enough that a
# stranger reading the roster knows who owns onboarding vs who reviews PRs.
#
# Note: BRIDGE_AGENT_DESC is IDENTITY, not AUTHORIZATION. The privilege
# boundary lives in BRIDGE_AGENT_CLASS (see further down this file). A
# `librarian` agent class=system describes its job here; the class line
# downstream is the access boundary.
#
# Recommended one-liners per role family:
#
# BRIDGE_AGENT_DESC["patch"]="Agent Bridge admin/coordinator for this install. Owns onboarding, roster/queue triage, upgrade/release waves, and operator-facing decisions."
# BRIDGE_AGENT_DESC["patch-dev"]="Codex dev/review pair for patch. Reviews PRs, proposes code changes, and verifies smoke/runtime checks assigned through Agent Bridge."
# BRIDGE_AGENT_DESC["patch-agy"]="Antigravity/alternate-engine pair for patch. Handles cross-engine implementation or UI/runtime verification tasks assigned through Agent Bridge."
# BRIDGE_AGENT_DESC["librarian"]="Memory ingestion/supervisory role. Harvests every agent's memory tree into the shared wiki (access boundary set via BRIDGE_AGENT_CLASS=system)."

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
# Optional: restart-peer for supervised mutual-restart (#2051). `agent restart
# <self>` (caller BRIDGE_AGENT_ID == target) is a split-brain foot-gun — the
# controller dies mid-restart, so two live instances of one identity can race.
# The guard REFUSES a self-restart and redirects to the peer named here (or
# tells the operator to restart manually when unset). Paired admin/dev agents
# restart EACH OTHER, never themselves (e.g. patch <-> patch-dev).
# BRIDGE_AGENT_RESTART_PEER["patch"]="patch-dev"
# BRIDGE_AGENT_RESTART_PEER["patch-dev"]="patch"
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
# BRIDGE_AGENT_MODEL["developer"]="claude-opus-4-8"            # default: claude-opus-4-8
# BRIDGE_AGENT_EFFORT["developer"]="xhigh"                      # default: xhigh
# BRIDGE_AGENT_PERMISSION_MODE["developer"]="auto"              # default: auto
#
# To pin an agent to the historical blanket-bypass shape (e.g. a sandboxed
# offline role) without removing the model/effort hints, set permission_mode
# explicitly to "legacy":
# BRIDGE_AGENT_PERMISSION_MODE["sandboxed"]="legacy"

# Template-sync defaults profile (issue #1427, controller-managed — do NOT hand-edit).
#
# `agb setup template-sync [--from <ref>]` writes a delimited, controller-owned
# block into agent-roster.local.sh that seeds NEW agents created afterward (and
# any existing agents you explicitly backfill) from a reference agent's roster
# fields. `agent create <new>` reads this profile and MATERIALIZES the included
# dimensions as EXPLICIT per-agent roster rows on the new role — it is not a
# live accessor fallback, so existing agents with unset fields keep their
# intentional legacy-launch contract until you explicitly backfill them.
# Precedence: explicit per-agent fields > materialized defaults > the built-in
# inline launch defaults (claude-opus-4-8 / xhigh / auto, new-shape rows only).
#
# The block is managed by the wizard; this is what it looks like (do not copy a
# real one by hand — re-run the wizard instead). It is the literal Contract-I
# format from docs/template-sync-design.md §"Shared contracts (I)": the leading
# meta comment carries NO secrets (source agent, timestamp, the included/excluded
# dimension lists, and a hash of the redacted candidate summary only), and ONLY
# the included dimensions are emitted as vars — excluded dimensions are omitted,
# not written as empty vars. Available vars: BRIDGE_TEMPLATE_DEFAULT_{MODEL,
# EFFORT,PERMISSION_MODE,PLUGINS,SKILLS,CHANNELS}.
#
# # === agb:template-defaults v1 (managed by `setup template-sync`) ===
# # meta: source_agent=patch updated_at=2026-05-31T12:00:00Z included=model,effort,plugins,skills excluded=channels,permission_mode hash=<sha256-of-redacted-summary>
# BRIDGE_TEMPLATE_DEFAULT_MODEL="claude-opus-4-8"
# BRIDGE_TEMPLATE_DEFAULT_EFFORT="xhigh"
# BRIDGE_TEMPLATE_DEFAULT_PLUGINS="cosmax-crm,playwright"
# BRIDGE_TEMPLATE_DEFAULT_SKILLS="agent-db"
# # permission_mode intentionally omitted (legacy is NEVER inherited)
# # channels intentionally omitted here; when included, channels carry the
# # declaration only (e.g. plugin:teams@mkt) — re-run `setup teams <agent>` to
# # populate credentials, then restart the agent to apply.
# # === end agb:template-defaults ===

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

# Optional: Codex companion-role hooks (audit-only by default).
#
# codex-task-mode-policy.py (PreToolUse) blocks source writes during
# [plan]/[review] tasks. codex-review-output-shape.py (Stop) enforces that
# review responses start with `plan-ok` / `implement-ok` / `needs-more`.
# Both hooks ship in audit-only mode: they emit per-agent audit rows but
# never block. Promote to blocking after observing a week of audit traffic
# with zero unintended denials.
#
# Set both env vars to `block`, or leave unset / set to `audit` (default).
# Restart codex agents (`agent-bridge agent restart <agent>`) after changing.
#
# export BRIDGE_CODEX_TASK_MODE_POLICY=block
# export BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE=block

# --- Operator plugin display-config seeding (#1753) ---------------------------
# At Claude-agent scaffold / start time, the bridge seeds-if-absent the
# operator's per-plugin display config into each fresh agent home:
#   <operator-home>/.claude/plugins/<plugin>/config.json
#     -> <agent-home>/.claude/plugins/<plugin>/config.json
# so a new agent inherits the operator's HUD intent (e.g. claude-hud rows that
# ship OFF by default) instead of rendering the abbreviated view. The copy is
# seed-if-absent — it NEVER overwrites an agent that has its own config.
#
# Only plugins in this allowlist are seeded (a generic copy would risk carrying
# secret-bearing plugin config across agent boundaries). Default is exactly
# `claude-hud`. Extend with a space- or comma-separated plugin-id list, or set
# it to empty to disable seeding entirely. Claude agents only (Codex skipped).
#
# export BRIDGE_SEED_PLUGIN_CONFIG_ALLOWLIST="claude-hud"

# --- Operator-global seamless token rotation for dynamic Claude (#18849) -------
# HIGH-RISK, default-OFF. When ENABLED, a Claude token rotation also PATCHes the
# operator-global `~/.claude/.credentials.json` (the file a dynamic-vanilla
# Claude agent reads: HOME=operator-global, no CLAUDE_CONFIG_DIR) with the new
# active token, so a running dynamic agent picks up the rotation seamlessly
# without a restart. The write PATCHes (never overwrites) — it preserves
# `refreshToken` and every other field of the operator's real login — takes a
# rollback preimage, holds a `.credentials.json.lock` flock, and FAILS CLOSED if
# the writer is root.
#
# This is double-gated: it fires ONLY when token auto-rotation is enabled AND
# this opt-in is ON. It writes the operator's PERSONAL credential file, so it is
# OFF by default and an existing auto-rotate install never starts touching
# `~/.claude` after an upgrade — you must opt in explicitly. Account identity
# (`oauthAccount` email) is NOT synced in Part 1; `agent-bridge auth claude-token
# global-auth-status` DETECTS and warns on a displayed-identity mismatch.
#
# Prefer the sanctioned, audited verb — it writes a persisted runtime-config
# opt-in the daemon inherits, is headless-safe, and reports the effective state:
#   agent-bridge auth claude-token global-auth-sync enable     # turn ON
#   agent-bridge auth claude-token global-auth-sync status     # show effective state
#   agent-bridge auth claude-token global-auth-sync disable    # clear the persisted opt-in
#
# A live BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 env override is a secondary route that
# takes PRECEDENCE (effective = persisted OR env=="1"); `status` surfaces it. To
# turn the gate back OFF, run `... global-auth-sync disable` AND remove any env
# override — `agent-bridge config unset-env BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC` (or
# delete the export below). There is no `=0` disable form: only "1" enables.
#
# export BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1
