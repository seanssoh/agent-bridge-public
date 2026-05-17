#!/usr/bin/env python3
"""safe-component.py — slugify an arbitrary string into a filesystem-safe
component for cron job/run directory names.

Invocation contract:
    sys.argv[1] = arbitrary string to slugify.

Output: kebab-style slug on stdout, falling back to "item" when the
input contains only filtered characters.

Footgun #11 (refs queue task #4807): this body used to live as a
`python3 - "$value" <<'PY'` heredoc-stdin in bridge_cron_safe_component.
The slugifier is called multiple times per dispatch (job slug + slot
token); moved to a standalone file invoked as
`python3 safe-component.py <value>` to remove the heredoc-stdin path —
same precedent as lib/upgrade-helpers/agent-restart-json.py.
"""

import re
import sys


def main() -> int:
    text = sys.argv[1] if len(sys.argv) > 1 else ""
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")
    print(slug or "item")
    return 0


if __name__ == "__main__":
    sys.exit(main())
