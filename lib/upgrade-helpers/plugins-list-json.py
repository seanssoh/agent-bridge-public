#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-list-json.py — standalone helper for
`agb plugins list --json` (bridge-plugins.sh).

Reads the v2 shared-plugins catalog manifest
(`$BRIDGE_SHARED_ROOT/plugins-cache/installed_plugins.json`) and emits a
single JSON object enumerating the installed plugins. File-as-argv per
footgun #11 (no heredoc-stdin to subprocess); see KNOWN_ISSUES.md §26.

Output shape:

  {
    "plugins_cache": "<path>",
    "installed_plugins_json": "<path or empty>",
    "plugin_count": <int>,
    "plugins": [
      {
        "name": "teams",
        "marketplace": "agent-bridge",
        "spec": "teams@agent-bridge",
        "version": "...",
        "installPath": "...",
        "installedAt": "...",
        "lastUpdated": "...",
        "scope": "user"
      },
      ...
    ]
  }

Empty catalog (missing manifest) → `plugin_count: 0`, `plugins: []`,
exit 0.

Usage:
  python3 lib/upgrade-helpers/plugins-list-json.py \\
      <plugins_cache_dir> <installed_plugins.json>
"""

from __future__ import annotations

import json
import os
import sys


def _parse_spec(spec: str) -> tuple[str, str]:
    """Split `name@marketplace` into (name, marketplace).

    Defensive: tolerate keys without `@` by returning (spec, "").
    """
    if "@" in spec:
        name, _, marketplace = spec.rpartition("@")
        return name, marketplace
    return spec, ""


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(
            "usage: plugins-list-json.py <plugins_cache> <manifest>\n"
        )
        return 2
    plugins_cache, manifest = argv[1:3]
    out: dict = {
        "plugins_cache": plugins_cache,
        "installed_plugins_json": manifest if os.path.isfile(manifest) else "",
        "plugin_count": 0,
        "plugins": [],
    }
    if not os.path.isfile(manifest):
        # Empty catalog → empty list, exit 0 (per brief contract).
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
        return 0
    try:
        with open(manifest, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        out["error"] = f"manifest-unreadable: {exc}"
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
        return 0

    plugins_map = payload.get("plugins") or {}
    if not isinstance(plugins_map, dict):
        out["error"] = "manifest-shape-invalid: plugins field is not an object"
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
        return 0

    entries: list[dict] = []
    for spec in sorted(plugins_map.keys()):
        # Each value is a list of dicts (see
        # _update_installed_plugins_manifest in bridge-dev-plugin-cache.py).
        records = plugins_map.get(spec) or []
        if isinstance(records, list) and records:
            first = records[0] if isinstance(records[0], dict) else {}
        elif isinstance(records, dict):
            first = records
        else:
            first = {}
        name, marketplace = _parse_spec(spec)
        entries.append(
            {
                "name": name,
                "marketplace": marketplace,
                "spec": spec,
                "version": first.get("version", ""),
                "installPath": first.get("installPath", ""),
                "installedAt": first.get("installedAt", ""),
                "lastUpdated": first.get("lastUpdated", ""),
                "scope": first.get("scope", ""),
            }
        )

    out["plugin_count"] = len(entries)
    out["plugins"] = entries
    print(json.dumps(out, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
