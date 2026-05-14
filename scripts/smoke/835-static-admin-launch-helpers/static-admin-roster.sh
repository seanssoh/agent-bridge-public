#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# scripts/smoke/835-static-admin-launch-helpers/static-admin-roster.sh
#
# Roster fragment sourced by the launch-cmd driver below (and ultimately
# by the production `bridge_load_roster` via $BRIDGE_ROSTER_LOCAL_FILE).
# Synthesizes a single static claude admin agent with the minimal set of
# keys the launch-cmd assembly chain reads:
#
#   - engine=claude (selects the `bridge_build_static_claude_launch_cmd`
#     branch inside `bridge_agent_launch_cmd`)
#   - explicit launch command (the static branch returns rc=1 without
#     `BRIDGE_AGENT_LAUNCH_CMD[$agent]` set, falling back to the resume
#     branch — we want the static branch exercised)
#   - workdir under $BRIDGE_AGENT_HOME_ROOT so the resume-state probes
#     in `bridge_claude_has_resumable_session_state` resolve cleanly
#     under the hermetic temp BRIDGE_HOME
#   - BRIDGE_ADMIN_AGENT_ID set to this agent so it qualifies as the
#     "static admin" the #835 incident wedged on
#
# Reads from caller:
#   STATIC_ADMIN_AGENT_ID   (default: smoke-static-admin)
#   STATIC_ADMIN_WORKDIR    (default: $BRIDGE_AGENT_HOME_ROOT/$STATIC_ADMIN_AGENT_ID)
#
# Tracked as a real file (not heredoc-to-file inside the smoke) to keep
# Wave C's regression coverage off the same Bash 5.3.9 heredoc_write
# class that the production fix in PR #845 / PR #846 addresses, and to
# match the convention established by
# scripts/smoke/heredoc-regression-helpers/. (Forbidden pattern strings
# intentionally omitted from this comment so the footgun #11 self-audit
# grep recipe does not flag a textual mention as a real callsite.)

: "${STATIC_ADMIN_AGENT_ID:=smoke-static-admin}"
: "${STATIC_ADMIN_WORKDIR:=$BRIDGE_AGENT_HOME_ROOT/$STATIC_ADMIN_AGENT_ID}"

mkdir -p "$STATIC_ADMIN_WORKDIR"

bridge_add_agent_id_if_missing "$STATIC_ADMIN_AGENT_ID"
BRIDGE_AGENT_DESC["$STATIC_ADMIN_AGENT_ID"]="Static claude admin (smoke #835 Wave C)"
BRIDGE_AGENT_ENGINE["$STATIC_ADMIN_AGENT_ID"]="claude"
BRIDGE_AGENT_SESSION["$STATIC_ADMIN_AGENT_ID"]="smoke-static-admin-session"
BRIDGE_AGENT_WORKDIR["$STATIC_ADMIN_AGENT_ID"]="$STATIC_ADMIN_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STATIC_ADMIN_AGENT_ID"]="claude --dangerously-skip-permissions"
BRIDGE_AGENT_LOOP["$STATIC_ADMIN_AGENT_ID"]=0
BRIDGE_AGENT_CONTINUE["$STATIC_ADMIN_AGENT_ID"]=0

# Designate this agent as the bridge admin role — the 2026-05-14 wedge
# manifested on the operator's static admin `patch`. Marking this synthesized
# agent the same way exercises any admin-specific branches in the launch-cmd
# assembly chain.
BRIDGE_ADMIN_AGENT_ID="$STATIC_ADMIN_AGENT_ID"
