#!/usr/bin/env bash
# shellcheck shell=bash
# runtime-templates/scripts/lib/singleton-channel-suppression.sh
#
# Shared bash-side channel-off overlay for bridge-spawned disposable / short
# `claude -p` children (#17957 path B). A disposable / non-interactive child
# that runs in — or inherits — the agent's *real* config-dir also inherits
# `enabledPlugins["telegram@claude-plugins-official"]=true`. Claude Code then
# auto-loads the telegram plugin inside the child, which SIGTERMs the admin's
# live `getUpdates` poller and grabs `bot.pid`; the child exits ~27s later and
# orphans the stolen poller, leaving the admin's interactive Telegram
# permanently dead. Discord's gateway websocket is the same
# one-holder-per-token shape.
#
# Fix: splice `"${SINGLETON_CHANNEL_SUPPRESSION_ARGS[@]}"` into the command
# right after `-p` / `-c -p`. The overlay is a per-invocation `--settings` JSON
# layer that sets ONLY the two singleton channel plugins to false and carries
# NO `mcpServers` key, so Claude's per-key settings merge (the same contract
# `scripts/apply-channel-policy.sh` relies on) disables just the singletons and
# preserves every other plugin and every MCP server the child legitimately
# needs. It never mutates the agent's interactive `.claude/settings.json`.
#
# `--strict-mcp-config` is deliberately NOT used here: it would over-broadly
# drop the functional MCP these launchers depend on (that flag is correct only
# for the cron runner's no-MCP child).
#
# This is the bash sibling of `lib/bridge_disposable_claude.py`. KEEP THE
# CHANNEL LIST IN SYNC with that module's `SINGLETON_CHANNEL_PLUGINS` —
# `scripts/smoke/17957-disposable-no-poller.sh` (T5) parses this overlay and
# fails CI if it drifts from the Python constant.

SINGLETON_CHANNEL_SUPPRESSION_OVERLAY='{"enabledPlugins":{"telegram@claude-plugins-official":false,"discord@claude-plugins-official":false}}'

# Splice this array right after `-p` / `-c -p`; flag order is irrelevant to the
# CLI and the prompt stays the trailing positional.
# shellcheck disable=SC2034  # consumed by the sourcing launcher, not this file
SINGLETON_CHANNEL_SUPPRESSION_ARGS=(--settings "$SINGLETON_CHANNEL_SUPPRESSION_OVERLAY")
