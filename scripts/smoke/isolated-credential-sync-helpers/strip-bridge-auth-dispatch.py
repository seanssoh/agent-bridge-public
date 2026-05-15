#!/usr/bin/env python3
"""Strip the trailing argv-dispatch tail from bridge-auth.sh.

The isolated-credential-sync smoke imports bridge-auth.sh's helper
functions without triggering its top-level CLI dispatch. This script:

  1. Reads ``bridge-auth.sh`` from argv[1].
  2. Locates the ``command="${1:-}"`` marker and drops everything from
     that line onward.
  3. Drops the SCRIPT_DIR resolver + ``source bridge-lib.sh`` lines —
     the smoke caller pre-sources bridge-lib.sh from the real repo and
     re-anchors SCRIPT_DIR itself before sourcing the stripped copy.
  4. Drops the bootstrap calls (``bridge_load_roster``,
     ``bridge_require_python``) since the smoke runs in a pre-arranged
     environment.
  5. Writes the function-only body to argv[2].

Extracted out of scripts/smoke/isolated-credential-sync.sh to keep that
file free of embedded heredocs (footgun #11: heredoc/here-string into
bash variable contexts).
"""
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: strip-bridge-auth-dispatch.py <bridge-auth.sh> <out>",
            file=sys.stderr,
        )
        return 2
    src = Path(sys.argv[1]).read_text(encoding="utf-8")
    dst = Path(sys.argv[2])
    marker = '\ncommand="${1:-}"'
    idx = src.find(marker)
    if idx < 0:
        raise SystemExit("bridge-auth.sh dispatch marker not found")
    head = src[:idx]
    out_lines = []
    for line in head.splitlines():
        stripped_line = line.strip()
        if stripped_line.startswith("SCRIPT_DIR="):
            continue
        if stripped_line == 'source "$SCRIPT_DIR/bridge-lib.sh"':
            continue
        if stripped_line == "bridge_load_roster":
            continue
        if stripped_line == "bridge_require_python":
            continue
        if stripped_line in ("# shellcheck source=/dev/null",):
            continue
        out_lines.append(line)
    dst.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
