#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# scripts/smoke/1639-post-restart-auto-wake-helpers/static-claude-roster.sh
#
# Roster fragment for the #1639 bridge-start.sh dry-run discriminator test.
# Synthesizes a single static claude agent so `bridge-start.sh <agent>
# --dry-run` reaches the SESSION_CMD env-prefix assembly and prints
# `tmux_command=...`. The smoke asserts that tmux_command carries
# BRIDGE_AUTO_RESTART_WAKE=1 on a non-attach (auto-restart) start and NOT on
# an interactive --attach start.
#
# Tracked as a real file (not heredoc-to-file inside the smoke) per the
# scripts/smoke/835-static-admin-launch-helpers/ convention (footgun #11).
#
# Reads from caller:
#   SMOKE1639_AGENT_ID   (default: smoke-1639)
#   SMOKE1639_WORKDIR    (default: $BRIDGE_AGENT_HOME_ROOT/$SMOKE1639_AGENT_ID)

: "${SMOKE1639_AGENT_ID:=smoke-1639}"
: "${SMOKE1639_WORKDIR:=$BRIDGE_AGENT_HOME_ROOT/$SMOKE1639_AGENT_ID}"

mkdir -p "$SMOKE1639_WORKDIR"

bridge_add_agent_id_if_missing "$SMOKE1639_AGENT_ID"
BRIDGE_AGENT_DESC["$SMOKE1639_AGENT_ID"]="Static claude agent (smoke #1639)"
BRIDGE_AGENT_ENGINE["$SMOKE1639_AGENT_ID"]="claude"
BRIDGE_AGENT_SOURCE["$SMOKE1639_AGENT_ID"]="static"
BRIDGE_AGENT_SESSION["$SMOKE1639_AGENT_ID"]="smoke-1639-session"
BRIDGE_AGENT_WORKDIR["$SMOKE1639_AGENT_ID"]="$SMOKE1639_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$SMOKE1639_AGENT_ID"]="claude --dangerously-skip-permissions"
BRIDGE_AGENT_LOOP["$SMOKE1639_AGENT_ID"]=1
BRIDGE_AGENT_CONTINUE["$SMOKE1639_AGENT_ID"]=0
