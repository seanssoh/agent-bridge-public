#!/usr/bin/env bash
# Test shim for bridge-auth.sh — emits a minimal `claude-token sync --json`
# envelope so the daemon helper's sync-status-parse subcommand returns "ok".
set -euo pipefail
# Drain argv; we only honor `claude-token sync --json` shape but do not
# enforce it here — the daemon callsite passes a fixed shape.
printf '{"status": "ok", "synced_agents": ["test-agent"]}\n'
