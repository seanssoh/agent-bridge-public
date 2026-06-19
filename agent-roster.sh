#!/usr/bin/env bash
# shellcheck shell=bash
#
# Agent Bridge static roster
# - Fresh installs ship with no static roles.
# - Add role ids to BRIDGE_AGENT_IDS only if you want long-lived named agents.
# - Fill the metadata maps below for each role you add.
# - Optional actions are defined in BRIDGE_AGENT_ACTION using "<agent>:<action>".
# - Prefer creating machine-specific roles in agent-roster.local.sh.

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
BRIDGE_LOG_DIR="${BRIDGE_LOG_DIR:-$BRIDGE_HOME/logs}"
BRIDGE_SHARED_DIR="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
BRIDGE_MAX_MESSAGE_LEN="${BRIDGE_MAX_MESSAGE_LEN:-500}"
# shellcheck disable=SC2034
declare -ag BRIDGE_AGENT_IDS=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_DESC=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_ENGINE=()

# #1407/#1213/#1457 follow-up: SOURCE / PROVENANCE / PRECOMPACT_NOTIFY share
# ENGINE's associative-map contract but were added (accessors + populate code)
# without a declaration here. An undeclared map makes ${MAP[$agent]} evaluate
# the agent id as an arithmetic subscript and abort the launcher under `set -u`
# ("<agent>: unbound variable"). Declare them empty up front, exactly like the
# maps above, so element assignment and reads always hit a real assoc array.
# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_SOURCE=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_PROVENANCE=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_PRECOMPACT_NOTIFY=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_SESSION=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_WORKDIR=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_PROFILE_HOME=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_LAUNCH_CMD=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_ACTION=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_IDLE_TIMEOUT=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_NOTIFY_KIND=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_NOTIFY_TARGET=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_NOTIFY_ACCOUNT=()

# Optional Claude launch-flag overrides (issue #72).
# Leave all three unset to preserve the historical
# `claude --dangerously-skip-permissions` launch shape. Setting any one opts
# the agent into the new --model / --effort / --permission-mode launch shape,
# with claude-opus-4-8 / xhigh / auto applied as defaults for any field still
# unset. Use BRIDGE_AGENT_PERMISSION_MODE["agent"]="legacy" to explicitly pin
# the historical shape (e.g. for sandboxed roles that need the blanket bypass).
# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_MODEL=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_EFFORT=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_PERMISSION_MODE=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_WEBHOOK_PORT=()

# #2020 (same class as #1407/#1627): extra-runtime-skills map written by
# `agent roster materialize-fields --skills` / `agent create --skills` (#1427)
# as `BRIDGE_AGENT_SKILLS["<agent>"]=...` into agent-roster.local.sh. Without a
# prior `declare -A`, a bare source of these roster files (agent-roster.sh then
# agent-roster.local.sh) evaluates the non-numeric subscript arithmetically →
# index 0 → a broken INDEXED array. bridge_agent_skills_csv guards on
# bridge_var_is_assoc, so an indexed map reads back as empty and the runtime
# skill sync materializes NO configured skill for ANY agent — silently. Declare
# it associative up front, BEFORE agent-roster.local.sh is sourced, exactly like
# the sibling maps above. (The lib path also resets it in bridge_reset_roster_maps;
# this is the file-level half of that belt-and-suspenders, the only #1427 map
# previously missing it.)
# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_SKILLS=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_LEGACY_AGENT_TARGET=()
declare -Ag BRIDGE_OPENCLAW_AGENT_TARGET=()
