#!/usr/bin/env python3
"""recorded-source-root.py — read the recorded source_root from a previous
upgrade's last-upgrade.json. Used by bridge-upgrade.sh when SOURCE_ROOT and
TARGET_ROOT collapse to the same path so the upgrader can recover the
original source checkout.

Invocation contract:
    sys.argv[1] = path to <target_root>/state/upgrade/last-upgrade.json

Output: the recorded source_root string on stdout (empty string when the
        file is missing, unreadable, or has no source_root field).

Footgun #11 (task #4538): this body used to live as a `python3 - <<'PY' … PY`
heredoc-stdin inline in bridge-upgrade.sh. Moved to a standalone file to
remove the heredoc-stdin path that wedges Bash 5.3.9.
"""

import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)

source = str(payload.get("source_root") or "").strip()
print(source)
