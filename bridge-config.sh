#!/usr/bin/env bash
# bridge-config.sh — operator-gated system-config mutations (issue #341)

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

usage() {
  cat <<EOF
Usage:
  $(basename "$0") set --path <p> --change <expr> [--from <agent>]
  $(basename "$0") get --path <p>
  $(basename "$0") list-protected [--json]

Change expressions:
  key=value                top-level set
  a.b.c=value              nested set (creates intermediate dicts)
  a.b.append=value         append to list at a.b
  a.b.remove=value         remove first occurrence from a.b list

Trust model (issue #341):
  - Caller must be the admin agent (\$BRIDGE_ADMIN_AGENT_ID) or the
    human operator at a TTY without \$BRIDGE_AGENT_ID set.
  - Caller source must be operator-tui (TTY-detected) or
    operator-trusted-id (set via \$BRIDGE_CALLER_SOURCE by a verified
    channel handler).

Examples:
  $(basename "$0") list-protected
  $(basename "$0") get  --path \$BRIDGE_HOME/data/agents/foo/workdir/.discord/access.json
  $(basename "$0") set  --path \$BRIDGE_HOME/data/agents/foo/workdir/.discord/access.json \\
                         --change groups.append=12345
EOF
}

case "${1:-}" in
  ""|-h|--help|help)
    usage
    [[ "${1:-}" == "" ]] && exit 1
    exit 0
    ;;
esac

exec python3 "$SCRIPT_DIR/bridge-config.py" "$@"
