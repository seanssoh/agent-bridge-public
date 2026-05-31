#!/usr/bin/env bash
# Claude Code apiKeyHelper wrapper for the Agent Bridge OAT registry.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_require_python

if ! bridge_claude_keychain_free_auth_enabled; then
  printf '[bridge-auth] Claude keychain-free auth is disabled\n' >&2
  exit 1
fi

exec python3 "$BRIDGE_SCRIPT_DIR/bridge-auth.py" \
  --registry "$(bridge_claude_token_registry_path)" \
  api-key-helper
