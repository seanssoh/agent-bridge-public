#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
TARGET="$REPO_ROOT/lib/bridge-agents.sh"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")


def body(name: str) -> str:
    marker = f"{name}() {{"
    start = text.find(marker)
    if start < 0:
        raise SystemExit(f"missing function: {name}")
    pos = start + len(marker)
    depth = 1
    while pos < len(text):
        ch = text[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:pos]
        pos += 1
    raise SystemExit(f"unterminated function: {name}")


helper = body("bridge_linux_repair_isolated_claude_read_lens")
required_helper_fragments = [
    'm::r-x',
    'd -m "m::r-X"',
    'find "$isolated_projects_dir" -type d',
    'find "$isolated_projects_dir" -type f',
    'm::r--',
]
missing = [fragment for fragment in required_helper_fragments if fragment not in helper]
if missing:
    raise SystemExit(f"read-lens helper missing fragments: {missing}")

cred = body("bridge_linux_grant_claude_credentials_access")
repair_call = (
    'bridge_linux_repair_isolated_claude_read_lens '
    '"$os_user" "$user_home" "$controller_user"'
)
repair_pos = cred.find(repair_call)
early_return_pos = cred.find('if [[ "$current_target" == "$controller_cred_file" ]]; then')
if repair_pos < 0:
    raise SystemExit("credential repair path does not restore isolated Claude read lens")
if early_return_pos < 0:
    raise SystemExit("credential symlink early-return guard not found")
if repair_pos > early_return_pos:
    raise SystemExit("read lens repair must run before credential symlink early return")

prepare = body("bridge_linux_prepare_agent_isolation")
if repair_call not in prepare:
    raise SystemExit("isolation prepare path does not use read-lens helper")

print("isolation Claude read-lens smoke passed")
PY
