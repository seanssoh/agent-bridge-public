#!/usr/bin/env bash
# bridge-wave.sh — `agent-bridge wave <subcommand>` entry point.
#
# Phase 1.1: dispatch (state + brief), list, show, templates, close-issue
# (placeholder). Worker startup, queue tasks, codex adapter, PR
# automation, and close-issue validation are deferred to Phases 1.2-1.6.
# See docs/design/wave-orchestration-plugin.md for the full surface.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

bridge_load_roster

usage() {
  cat <<EOF
Usage:
  agent-bridge wave dispatch <issue|brief-file> [--tracks A,B] [--main-agent <agent>] [--worker-engine claude|codex|antigravity] [--reviewer <name>] [--dry-run] [--json]
  agent-bridge wave list [--all] [--json]
  agent-bridge wave show <wave-id> [--json]
  agent-bridge wave templates
  agent-bridge wave close-issue <issue> [--wave <wave-id>] [--force]

Phase 1.1 ships dispatch + list + show + templates. The other Phase 1
subcommands (watch, complete, cleanup) and full close-issue validation
land in Phases 1.2-1.6 — see docs/design/wave-orchestration-plugin.md.
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  dispatch)    bridge_wave_dispatch "$@" ;;
  list)        bridge_wave_list "$@" ;;
  show)        bridge_wave_show "$@" ;;
  templates)   bridge_wave_templates "$@" ;;
  close-issue) bridge_wave_close_issue "$@" ;;
  watch|complete|cleanup)
    bridge_die "wave $cmd: deferred to Phase 1.2+ (see docs/design/wave-orchestration-plugin.md)"
    ;;
  ""|help|-h|--help) usage; exit 0 ;;
  *) usage >&2; bridge_die "unknown wave subcommand: $cmd" ;;
esac
