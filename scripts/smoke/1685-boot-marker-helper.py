#!/usr/bin/env python3
"""1685-boot-marker-helper.py — smoke driver for write_receiver_boot_marker.

Loads bridge-handoffd.py (dash in the name → importlib by path, NOT a regular
import) and calls write_receiver_boot_marker() so the 1685 smoke can verify the
receiver-owned boot marker is written atomically at mode 0600 AND that a write
failure is non-fatal (the contract: a marker-write failure must NOT prevent the
receiver from serving). Invoked file-as-argv (footgun #11: no heredoc-stdin).

Usage:
  1685-boot-marker-helper.py <repo_root> <pidfile>

Prints "OK" on a clean call (including when the marker write itself fails — that
is the non-fatal contract). Exits non-zero ONLY if write_receiver_boot_marker
raised (a contract violation).
"""

import importlib.util
import os
import sys


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: 1685-boot-marker-helper.py <repo_root> <pidfile>\n")
        return 2
    repo_root, pidfile = sys.argv[1], sys.argv[2]
    # bridge-handoffd.py does `import bridge_a2a_common` (+ best-effort
    # bridge_rooms_common); both live beside it in repo_root, so it must be on
    # the path before exec_module.
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    spec = importlib.util.spec_from_file_location(
        "bridge_handoffd", os.path.join(repo_root, "bridge-handoffd.py"))
    if spec is None or spec.loader is None:
        sys.stderr.write("could not load bridge-handoffd.py\n")
        return 2
    mod = importlib.util.module_from_spec(spec)
    sys.modules["bridge_handoffd"] = mod
    spec.loader.exec_module(mod)
    # Contract: this must NEVER raise, even on an unwritable handoff dir.
    mod.write_receiver_boot_marker(pidfile)
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
