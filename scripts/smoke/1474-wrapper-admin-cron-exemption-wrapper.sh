#!/usr/bin/env bash
# scripts/smoke/1474-wrapper-admin-cron-exemption-wrapper.sh — helper for
# 1474-wrapper-admin-cron-exemption.sh.
#
# Faithfully reproduces the `agent-bridge cron create` wrapper arm: source
# bridge-lib.sh, run `bridge_load_roster` (which resolves BRIDGE_ADMIN_AGENT_ID
# from the roster), then `exec` `bridge-cron.sh create ...` — exactly like the
# `cron)` dispatch in the `agent-bridge` CLI. The point of the fix under test is
# that `bridge_load_roster` must EXPORT BRIDGE_ADMIN_AGENT_ID so the resolved
# admin id survives this `exec` into the child.
#
# Inputs (env, set by the parent smoke):
#   WRAPPER_REPO_ROOT   — repo root (for bridge-lib.sh + bridge-cron.sh)
#   WRAPPER_BRIDGE_BASH — bash binary to exec the child with
#   WRAPPER_TARGET      — cross-agent --agent value
#   WRAPPER_KIND        — text | shell
#   plus BRIDGE_* (BRIDGE_AGENT_ID, layout, roster, jobs/staging paths)
#
# NOTE: BRIDGE_AGENT_ID is exported into THIS process by the parent (mirrors a
# live agent session). BRIDGE_ADMIN_AGENT_ID is NOT pre-exported — it only
# becomes available after `bridge_load_roster` sources the roster, and only
# survives the exec below because the fix exports it there.

set -uo pipefail

REPO_ROOT="${WRAPPER_REPO_ROOT:?WRAPPER_REPO_ROOT required}"
BRIDGE_BASH="${WRAPPER_BRIDGE_BASH:?WRAPPER_BRIDGE_BASH required}"
TARGET="${WRAPPER_TARGET:?WRAPPER_TARGET required}"
KIND="${WRAPPER_KIND:-text}"

# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh"

# The wrapper's roster load — this is the exact call agent-bridge makes at its
# `*)` dispatch arm before exec'ing the subcommand script. It sets (and, with
# the fix, EXPORTS) BRIDGE_ADMIN_AGENT_ID.
bridge_load_roster

# Build the create argv. text-kind goes through the staging path; shell-kind
# must still be refused at the CLI guard (text-only exemption).
create_args=(
  create
  --agent "$TARGET"
  --schedule "0 3 * * *"
  --tz "Asia/Seoul"
  --title "memory-daily-$TARGET"
)
if [[ "$KIND" == "shell" ]]; then
  create_args+=(--kind shell --run-as-agent "$TARGET" --script "$REPO_ROOT/bridge-cron.sh")
else
  create_args+=(--payload "admin cross-agent provision")
fi

# exec the child — across this boundary only EXPORTED vars survive. This is the
# crux of #1474: without the bridge_load_roster export, BRIDGE_ADMIN_AGENT_ID is
# empty in the child and the admin exemption cannot pass.
exec "$BRIDGE_BASH" "$REPO_ROOT/bridge-cron.sh" "${create_args[@]}"
