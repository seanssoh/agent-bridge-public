#!/usr/bin/env bash
# shellcheck shell=bash
#
# Agent Bridge health / hygiene scanners. `agent-bridge diagnose <subcommand>`.
#
# Historical note (issue #1283): the `acl` subcommand was retired in
# v0.15.0-beta4. ACL-based cross-UID grants are no longer the recommended
# isolation mechanism — `linux-user isolation` (iso v2) uses group-based
# permissions instead. The scanner that walked /, /home, BRIDGE_HOME and
# BRIDGE_AGENT_HOME_ROOT for named-user ACL residue is removed; any
# remaining residue should be cleaned via the iso v2 reconcile path
# (`agent-bridge isolation reconcile --apply --agent <agent>`).
#
# This shim preserves the `agent-bridge diagnose` verb entry point so
# operator muscle-memory still gets a useful pointer instead of "command
# not found", and emits a non-zero exit so scripts that branched on the
# old verb fail loudly.

set -euo pipefail

bridge_diagnose_usage() {
  cat <<'USAGE'
Usage:
  agent-bridge diagnose [help]

The `acl` subcommand was retired in v0.15.0-beta4 (issue #1283).
ACL-based cross-UID grants are no longer the recommended isolation
mechanism. Use `agent-bridge isolation reconcile --apply --agent <agent>`
to drain residue, and `agent-bridge isolation status --agent <agent>`
to inspect the current group/UID layout.

No other diagnose subcommands are currently published.
USAGE
}

bridge_diagnose_acl_deprecation_notice() {
  cat >&2 <<'NOTICE'
[deprecated] `agent-bridge diagnose acl` was retired in v0.15.0-beta4
(issue #1283). ACL-based cross-UID grants are no longer the recommended
isolation mechanism — `linux-user isolation` (iso v2) uses group-based
permissions instead.

To inspect / repair an isolated agent's group + UID layout, use:
  agent-bridge isolation status   --agent <agent>
  agent-bridge isolation reconcile --apply --agent <agent>
NOTICE
}

bridge_diagnose_cli() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    acl)
      bridge_diagnose_acl_deprecation_notice
      return 2
      ;;
    ""|-h|--help|help)
      bridge_diagnose_usage
      ;;
    *)
      printf 'unknown diagnose subcommand: %s\n' "$subcommand" >&2
      bridge_diagnose_usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bridge_diagnose_cli "$@"
fi
