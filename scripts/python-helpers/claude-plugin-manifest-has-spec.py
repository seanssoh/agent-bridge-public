#!/usr/bin/env python3
"""Check whether a Claude installed_plugins.json manifest declares a plugin spec.

Issue #852 (controller-blind plugin status): when an isolated agent's
plugin lives at an installPath inside a mode-700 isolated UID home, the
controller's `os.access` probe in `bridge_claude_plugin_status` false-
fails because the controller cannot traverse the isolated home. The
manifest itself is the source of truth — it is written by
`bridge_write_isolated_installed_plugins_manifest` at isolation-prepare
time and contains exactly the plugins the agent declared. Trusting that
key set without an additional filesystem probe is the documented contract
behind PR #348.

Lives as a standalone helper (rather than inline in
`lib/bridge-agents.sh`) for the same reason every other recent Python
extraction did: bash heredoc reads can wedge in `heredoc_write` on
recent Homebrew Bash builds when invoked inside a command substitution
from an absolute-path-sourced shell. Running the body as a real script
bypasses that read entirely. (Forbidden pattern strings intentionally
omitted from this comment so the footgun #11 self-audit grep recipe does
not flag a textual mention as a real callsite.)

Args (positional):
    sys.argv[1] — path to installed_plugins.json
    sys.argv[2] — plugin spec string ("<name>@<marketplace>" or bare id)

Stdout: "present" if the manifest exists, parses as a JSON object, and
declares the spec under the top-level `plugins` map; "absent" otherwise.
Always exits 0 — callers gate on stdout content rather than exit code so
a missing/corrupt manifest falls through to the existing legacy path
without bash error trapping.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    manifest_path = Path(sys.argv[1])
    spec = sys.argv[2]

    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("absent")
        return 0

    if not isinstance(payload, dict):
        print("absent")
        return 0

    plugins = payload.get("plugins") or {}
    if not isinstance(plugins, dict):
        print("absent")
        return 0

    print("present" if spec in plugins else "absent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
