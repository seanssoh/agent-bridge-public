#!/usr/bin/env python3
"""
lib/upgrade-helpers/plugins-marketplaces-json.py — standalone helper for
`agb plugins marketplaces --json` (bridge-plugins.sh).

Reads the v2 shared-plugins catalog
(`$BRIDGE_SHARED_ROOT/plugins-cache/known_marketplaces.json`) and emits
a single JSON object enumerating the known marketplaces. File-as-argv
per footgun #11 (no heredoc-stdin to subprocess); see KNOWN_ISSUES.md §26.

`known_marketplaces.json` shape (mirrors
`ensure_known_marketplace_for_root` in bridge-dev-plugin-cache.py):

  {
    "<marketplace-name>": {
      "source": {"source": "directory", "path": "<root>"},
      "installLocation": "<root>",
      "lastUpdated": "<iso>"
    },
    ...
  }

A future wrapping `marketplaces` key is tolerated (mirrors the
plugins-show-json.py defensive read).

Output shape:

  {
    "plugins_cache": "<path>",
    "known_marketplaces_json": "<path or empty>",
    "marketplace_count": <int>,
    "marketplaces": [
      {
        "id": "agent-bridge",
        "source": {"kind": "directory", "path": "..."},
        "installLocation": "...",
        "lastUpdated": "..."
      },
      ...
    ]
  }

Empty catalog (missing file) → `marketplace_count: 0`, `marketplaces: []`,
exit 0.

Usage:
  python3 lib/upgrade-helpers/plugins-marketplaces-json.py \\
      <plugins_cache_dir> <known_marketplaces.json>
"""

from __future__ import annotations

import json
import os
import sys


def _normalize_entry(name: str, value: object) -> dict:
    """Coerce a known_marketplaces.json entry into the output schema.

    Tolerates legacy shapes: the canonical writer emits
    `{"source": {"source": "directory", "path": ...}, "installLocation": ...}`,
    but defensive callers also see flat `{"path": ...}` from older code
    paths. Keep both readable.
    """
    if not isinstance(value, dict):
        return {
            "id": name,
            "source": {"kind": "", "path": ""},
            "installLocation": "",
            "lastUpdated": "",
        }
    src_obj = value.get("source")
    if isinstance(src_obj, dict):
        # Canonical: {"source": "directory", "path": "..."}.
        src_kind = src_obj.get("source") or src_obj.get("kind") or ""
        src_path = src_obj.get("path") or ""
    elif isinstance(src_obj, str):
        # Legacy: just a string identifier; no path.
        src_kind = src_obj
        src_path = ""
    else:
        src_kind = ""
        src_path = ""
    return {
        "id": name,
        "source": {"kind": src_kind, "path": src_path},
        "installLocation": value.get("installLocation", "") or "",
        "lastUpdated": value.get("lastUpdated", "") or "",
    }


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(
            "usage: plugins-marketplaces-json.py <plugins_cache> <known>\n"
        )
        return 2
    plugins_cache, known = argv[1:3]
    out: dict = {
        "plugins_cache": plugins_cache,
        "known_marketplaces_json": known if os.path.isfile(known) else "",
        "marketplace_count": 0,
        "marketplaces": [],
    }
    if not os.path.isfile(known):
        # Empty catalog → empty list, exit 0.
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
        return 0
    try:
        with open(known, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        out["error"] = f"known-marketplaces-unreadable: {exc}"
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
        return 0

    if not isinstance(payload, dict):
        out["error"] = "known-marketplaces-shape-invalid: top-level is not an object"
        print(json.dumps(out, ensure_ascii=False, sort_keys=True))
        return 0

    # Tolerate a future wrapping `marketplaces` key.
    if isinstance(payload.get("marketplaces"), dict):
        catalog = payload["marketplaces"]
    else:
        catalog = payload

    entries: list[dict] = []
    for name in sorted(k for k in catalog.keys() if isinstance(k, str)):
        entries.append(_normalize_entry(name, catalog[name]))

    out["marketplace_count"] = len(entries)
    out["marketplaces"] = entries
    print(json.dumps(out, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
