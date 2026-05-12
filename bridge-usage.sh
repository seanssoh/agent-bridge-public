#!/usr/bin/env bash
# bridge-usage.sh — inspect and monitor Claude/Codex usage windows

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-usage.sh <status|monitor|alerts> [options...]
EOF
}

command="${1:-}"
[[ -n "$command" ]] || {
  usage
  exit 1
}
shift || true

claude_usage_cache="${BRIDGE_CLAUDE_USAGE_CACHE:-$HOME/.claude/plugins/claude-hud/.usage-cache.json}"
codex_sessions_dir="${BRIDGE_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
usage_state_file="${BRIDGE_USAGE_MONITOR_STATE_FILE:-$BRIDGE_STATE_DIR/usage/monitor-state.json}"
rotation_threshold="${BRIDGE_CLAUDE_TOKEN_ROTATION_PERCENT:-99}"
claude_token_registry="${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"

if [[ -f "$claude_token_registry" ]]; then
  registry_rotation_threshold="$(python3 - "$claude_token_registry" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    value = float(payload.get("rotation_threshold") or 0)
except Exception:
    value = 0
if 0 < value <= 100:
    print(value)
PY
)"
  if [[ "$registry_rotation_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    rotation_threshold="$registry_rotation_threshold"
  fi
fi

case "$command" in
  status)
    exec python3 "$SCRIPT_DIR/bridge-usage.py" status \
      --claude-usage-cache "$claude_usage_cache" \
      --codex-sessions-dir "$codex_sessions_dir" \
      "$@"
    ;;
  monitor)
    exec python3 "$SCRIPT_DIR/bridge-usage.py" monitor \
      --claude-usage-cache "$claude_usage_cache" \
      --codex-sessions-dir "$codex_sessions_dir" \
      --state-file "$usage_state_file" \
      --rotation-threshold "$rotation_threshold" \
      "$@"
    ;;
  alerts)
    exec python3 "$SCRIPT_DIR/bridge-usage.py" alerts \
      --audit-file "$BRIDGE_AUDIT_LOG" \
      "$@"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
