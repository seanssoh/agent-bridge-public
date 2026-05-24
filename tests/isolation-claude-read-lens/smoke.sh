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
required_prepare_fragments = [
    'local isolated_claude_dir="$user_home/.claude"',
    'bridge_linux_sudo_root mkdir -p "$isolated_claude_dir"',
    'bridge_linux_sudo_root chown "$os_user" "$isolated_claude_dir"',
    'bridge_linux_sudo_root chgrp "$_claude_v2_grp" "$isolated_claude_dir"',
    # #1165 Gap 2: widened from 2750 to 2770 so the SessionStart hook's
    # `mkdir .claude/session-env/` can succeed via the supplementary-
    # group path. The controller (group member of ab-agent-<name>) still
    # reaches ~/.claude/projects/ via group r-x; the group-write bit
    # only adds group writability, which is bounded by the v2 agent-
    # group composition (controller + the isolated UID itself).
    'bridge_linux_sudo_root chmod 2770 "$isolated_claude_dir"',
    # The "controller (group member of" string used to live on a single
    # source line; the #1165 Gap 2 comment expansion now wraps that
    # phrasing across two lines. The two halves below match the
    # post-expansion shape; reverting either to a single-line form
    # (which is fine) still satisfies the half-fragment assertion.
    'group member of ab-agent-<name>',
    'without any named-user ACL',
]
missing = [fragment for fragment in required_prepare_fragments if fragment not in prepare]
if missing:
    raise SystemExit(f"v2 read-lens prepare path missing fragments: {missing}")

for stale in [
    "bridge_linux_repair_isolated_claude_read_lens",
    "bridge_linux_grant_claude_credentials_access",
    "bridge_linux_sudo_root setfacl",
]:
    if stale in prepare:
        raise SystemExit(f"v2 read-lens prepare path still references stale ACL/credential helper: {stale}")

print("isolation Claude read-lens smoke passed")
PY
