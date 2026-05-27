#!/usr/bin/env python3
"""G-beta4 T1-teeth — flip the payload's fresh_install_only flag to
False and write the result to a new file. Used to prove the
daemon-helper watchdog-fresh-install-only command gates on the actual
field value (returning 0 when False), not silently returning 1.

Usage:
  flip-fresh-install-flag.py <input-json> <output-json>
"""
import json
import sys
from pathlib import Path

src, dst = sys.argv[1], sys.argv[2]
payload = json.loads(Path(src).read_text(encoding="utf-8"))
payload["fresh_install_only"] = False
Path(dst).write_text(json.dumps(payload), encoding="utf-8")
print("OK")
