#!/usr/bin/env bash
# Claude Code apiKeyHelper wrapper for the Agent Bridge OAT registry.

set -euo pipefail

# #1444 BLOCKING 1 (inherited-env leak): this wrapper reads the active OAT from
# the locked registry — it needs NOTHING from the environment. So before ANY
# command substitution (which would fork a child that inherits our env), derive
# SCRIPT_DIR with a Bash builtin (parameter expansion, no `dirname` subprocess)
# and UNSET the well-known ambient OAuth token. Without this, the old
# `$(cd -P "$(dirname ...)" ...)` and bridge-lib.sh's own `:33` `dirname`
# command substitution would leak `CLAUDE_CODE_OAUTH_TOKEN` into those children.
# `unset` strips both value and export attribute. Mirror of PR #1443's
# bridge-usage.sh top block.
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

# SCRIPT_DIR = grandparent dir of this file via builtins only. BASH_SOURCE[0]
# is `<repo>/scripts/<this>.sh`; strip the file then the `scripts` segment.
_helper_src="${BASH_SOURCE[0]}"
if [[ "$_helper_src" == */* ]]; then
  _helper_scripts_dir="${_helper_src%/*}"
else
  _helper_scripts_dir="."
fi
if [[ "$_helper_scripts_dir" == */* ]]; then
  SCRIPT_DIR="${_helper_scripts_dir%/*}"
else
  SCRIPT_DIR="."
fi
# Keep SCRIPT_DIR absolute via builtins only (no subprocess) — anchor a
# relative BASH_SOURCE to the launch CWD captured before any cd.
if [[ "$SCRIPT_DIR" != /* ]]; then
  SCRIPT_DIR="$PWD/$SCRIPT_DIR"
fi
unset _helper_src _helper_scripts_dir

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
