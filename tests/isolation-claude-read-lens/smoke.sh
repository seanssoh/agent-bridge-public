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


prepare = body("bridge_linux_prepare_agent_isolation")
# Phase 3 (#1186): inline `.claude/` mkdir + chown + chgrp + chmod block
# moved into `bridge_linux_normalize_isolated_home_contract`. Prepare
# path now delegates via a helper call; the contract operations
# themselves are exercised inside the helper body below.
required_prepare_fragments = [
    'local isolated_claude_dir="$user_home/.claude"',
    'bridge_linux_normalize_isolated_home_contract',
    'without any named-user ACL',
]
missing = [fragment for fragment in required_prepare_fragments if fragment not in prepare]
if missing:
    raise SystemExit(f"v2 read-lens prepare path missing fragments: {missing}")

helper = body("bridge_linux_normalize_isolated_home_contract")
required_helper_fragments = [
    # mode 3770 default (Phase 3 codex design: sticky + setgid). Fallback
    # 2770 via BRIDGE_ISO_HOME_CONTRACT_MODE override remains available.
    'BRIDGE_ISO_HOME_CONTRACT_MODE',
    'claude_mode="3770"',
    'home_mode="2750"',
    # mkdir + chown + chmod via bridge_linux_sudo_root — same primitives
    # the prepare path used inline pre-#1186 (sites now in `_bridge_normalize_one`).
    'bridge_linux_sudo_root mkdir -p',
    'bridge_linux_sudo_root chown',
    'bridge_linux_sudo_root chmod',
    # ab-agent-<name> resolved via bridge_isolation_v2_agent_group_name
    # (replaces the prior inline chgrp "$_claude_v2_grp").
    'bridge_isolation_v2_agent_group_name',
]
missing_helper = [fragment for fragment in required_helper_fragments if fragment not in helper]
if missing_helper:
    raise SystemExit(f"v2 read-lens helper missing fragments: {missing_helper}")

for stale in [
    "bridge_linux_repair_isolated_claude_read_lens",
    "bridge_linux_grant_claude_credentials_access",
    "bridge_linux_sudo_root setfacl",
]:
    if stale in prepare:
        raise SystemExit(f"v2 read-lens prepare path still references stale ACL/credential helper: {stale}")

print("isolation Claude read-lens smoke passed")
PY
