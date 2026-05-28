#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-seed-parse-sync-output.py — standalone helper
for `agb plugins seed` (bridge-plugins.sh, #1250 beta3).

Parses `bridge-dev-plugin-cache.py sync` text output and emits a TSV of
plugins that need a `bun install` pass:

  <plugin>\t<criticality>\t<source>\t<cache>

Only emits rows where:
  * status is `linked-verified` / `updated-verified` / `unchanged-verified`
    (otherwise the cache write didn't land; we don't try to install)
  * node_modules=missing (or node_modules_status=missing)
  * the plugin's SOURCE dir declares deps (package.json with non-empty
    `dependencies` / `peerDependencies`, OR a sibling bun.lock /
    package-lock.json / yarn.lock)

Plugins without declared deps are silent: the upstream codebase
intentionally ships some plugins without package.json (pure-Python
plugins, hook-only plugins) and node_modules=missing for those is the
expected steady state.

File-as-argv per footgun #11 (no heredoc-stdin); see KNOWN_ISSUES.md
§26.

Usage:
  python3 plugins-seed-parse-sync-output.py <sync-output-file>

Output (stdout): one TSV row per affected plugin. Empty output when
nothing needs an install.

Exit code: always 0 (the caller decides how to act on the rows).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


# bridge-dev-plugin-cache.py sync emits lines like:
#   <plugin>: <status> cache=<path> source=<path> node_modules=<status>
#       node_modules_target=<path> orphan_removed=<n> criticality=<level>
# We parse with a regex that tolerates variable whitespace and a missing
# orphan_removed field (the helper has added/removed fields over time).
_LINE_RE = re.compile(
    r"^(?P<plugin>[^:]+):\s+(?P<status>[\w-]+)\s+"
    r"cache=(?P<cache>\S+)\s+source=(?P<source>\S+)\s+"
    r"node_modules=(?P<node_modules>\S+)\b"
)
_CRITICALITY_RE = re.compile(r"criticality=(?P<crit>[\w-]+)")

_VERIFIED_STATUSES = frozenset(
    {"linked-verified", "updated-verified", "unchanged-verified"}
)


def _plugin_declares_deps(source: str) -> bool:
    """True when the plugin's source dir suggests it needs node_modules.

    Conservative heuristic. Returns True when ANY of:
      * package.json declares non-empty `dependencies` / `peerDependencies`
      * sibling bun.lock / package-lock.json / yarn.lock exists
    """
    try:
        src_path = Path(source)
    except (TypeError, ValueError):
        return False
    if not src_path.is_dir():
        return False
    # Lockfile presence is the strongest signal — a lockfile without a
    # corresponding install is almost always a missed step.
    for lock in ("bun.lock", "bun.lockb", "package-lock.json", "yarn.lock"):
        if (src_path / lock).is_file():
            return True
    pkg = src_path / "package.json"
    if not pkg.is_file():
        return False
    try:
        with pkg.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return False
    for key in ("dependencies", "peerDependencies"):
        deps = data.get(key)
        if isinstance(deps, dict) and deps:
            return True
    return False


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write(
            "usage: plugins-seed-parse-sync-output.py <sync-output-file>\n"
        )
        return 2
    src_path = argv[1]
    try:
        with open(src_path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except Exception as exc:
        sys.stderr.write(f"failed to read {src_path}: {exc}\n")
        return 1

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = _LINE_RE.match(line)
        if not match:
            continue
        if match.group("status") not in _VERIFIED_STATUSES:
            continue
        if match.group("node_modules") != "missing":
            continue
        crit_match = _CRITICALITY_RE.search(line)
        criticality = crit_match.group("crit") if crit_match else "channel-required"
        source = match.group("source")
        if not _plugin_declares_deps(source):
            continue
        plugin = match.group("plugin").strip()
        cache = match.group("cache")
        # Tab-separated; the caller is bash and parses with `IFS=$'\t'`.
        sys.stdout.write(f"{plugin}\t{criticality}\t{source}\t{cache}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
