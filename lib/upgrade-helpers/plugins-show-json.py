#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-show-json.py — standalone helper for
`agb plugins show --json` (bridge-plugins.sh).

Reads the v2 shared-plugins catalog state and emits a single JSON object
describing the cache root, populated flag, manifest plugin count, and
the sorted marketplace name list. File-as-argv per footgun #11 (no
heredoc-stdin to subprocess); see KNOWN_ISSUES.md §26.

Usage:
  python3 lib/upgrade-helpers/plugins-show-json.py \\
      <plugins_cache_dir> <installed_plugins.json> <known_marketplaces.json> <populated:true|false>
"""

from __future__ import annotations

import json
import os
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        sys.stderr.write(
            "usage: plugins-show-json.py <plugins_cache> <manifest> <known> <populated>\n"
        )
        return 2
    plugins_cache, manifest, known, populated = argv[1:5]
    out: dict = {
        "plugins_cache": plugins_cache,
        "populated": populated == "true",
        "installed_plugins_json": manifest if os.path.isfile(manifest) else "",
        "known_marketplaces_json": known if os.path.isfile(known) else "",
        "plugin_count": 0,
        "marketplaces": [],
    }
    if os.path.isfile(manifest):
        try:
            with open(manifest, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
            out["plugin_count"] = len(payload.get("plugins") or {})
        except Exception as exc:
            out["error"] = f"manifest-unreadable: {exc}"
    if os.path.isfile(known):
        try:
            with open(known, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
            # known_marketplaces.json is a flat {<marketplace-name>: <metadata>}
            # map at the top level (see bridge-dev-plugin-cache.py
            # ensure_known_marketplace_for_root). Tolerate a future wrapping
            # `marketplaces` key by falling back to it.
            if isinstance(payload, dict):
                if isinstance(payload.get("marketplaces"), dict):
                    out["marketplaces"] = sorted(payload["marketplaces"].keys())
                else:
                    out["marketplaces"] = sorted(
                        k for k in payload.keys() if isinstance(k, str)
                    )
        except Exception:
            pass
    print(json.dumps(out, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
