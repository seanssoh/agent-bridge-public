#!/usr/bin/env python3
"""Issue #1317-B (beta5-2 Lane ν) — extract reason_hint from a
broken-launch marker JSON.

Standalone helper because the parent shell uses `$()` command-
substitution to capture the hint for inline display in
bridge_agent_session_guidance_text; embedding a `python3 - <<'PY'`
heredoc inside that `$(...)` would re-trip the Bash 5.3.9
read_comsub / heredoc_write deadlock catalogued as footgun #11
(KNOWN_ISSUES §26). file-as-argv pattern keeps the heredoc out of
the parent shell entirely.

Usage:
  broken-launch-reason-hint.py <broken-launch-file>

Output:
  Single line on stdout — the trimmed `reason_hint` value if the
  file is a JSON object with that key, otherwise nothing.

Exit:
  Always 0 — best-effort; missing file / malformed JSON / missing
  key all degrade silently (the caller decides whether to print the
  hint line at all based on whether stdout was non-empty).
"""
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    path = Path(sys.argv[1])
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict):
        return 0
    hint = data.get("reason_hint")
    if not isinstance(hint, str):
        return 0
    hint = hint.strip()
    if hint:
        # No trailing newline — caller adds its own format.
        sys.stdout.write(hint)
    return 0


if __name__ == "__main__":
    sys.exit(main())
