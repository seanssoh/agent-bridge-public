#!/usr/bin/env python3
"""Assertion helper for scripts/smoke/1985-operator-global-settings-hijack-cleanup.sh.

Lives as a tracked file (not a heredoc) so the smoke driver can extract fields
from the cleanup-residue JSON and run small filesystem checks without feeding a
python body through `<<'PY'` (footgun #11 mitigation).

Modes:
  <field>                         read .operator_global_settings_hijack.<field>
                                  from JSON on stdin (booleans -> Python repr).
  --cleanup-failures-for-step S   count of .cleanup_failures entries with step==S
                                  from JSON on stdin.
  --mode-of <path>                octal file mode (e.g. 600) of <path>.
  --json-eq <path> <json>         exit 0 iff json.load(<path>) == json.loads(<json>).
"""

import json
import os
import sys


def main() -> int:
    argv = sys.argv[1:]
    if not argv:
        sys.stderr.write("usage: helper.py <field>|--cleanup-failures-for-step S|"
                         "--mode-of P|--json-eq P J\n")
        return 2

    if argv[0] == "--mode-of":
        path = argv[1]
        st = os.lstat(path)
        sys.stdout.write(oct(st.st_mode & 0o777)[2:])
        return 0

    if argv[0] == "--json-eq":
        path, expected = argv[1], argv[2]
        with open(path, "r", encoding="utf-8") as handle:
            got = json.load(handle)
        return 0 if got == json.loads(expected) else 1

    raw = sys.stdin.read()
    data = json.loads(raw)

    if argv[0] == "--cleanup-failures-for-step":
        step = argv[1]
        fails = data.get("cleanup_failures") or []
        count = sum(1 for f in fails if f.get("step") == step)
        sys.stdout.write(str(count))
        return 0

    field = argv[0]
    hijack = data.get("operator_global_settings_hijack") or {}
    value = hijack.get(field, "")
    if isinstance(value, bool):
        sys.stdout.write("True" if value else "False")
    else:
        sys.stdout.write(str(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
