#!/usr/bin/env python3
"""Resolve the cron-dispatch worker-pool size (issue #1461).

Invoked file-as-argv from bridge-lib.sh's
bridge_resolve_cron_dispatch_max_parallel (NOT heredoc-stdin — keeps the
resolver clear of the Bash 5.3.9 footgun #11 deadlock class and the
lint-heredoc-ban ratchet).

Resolution order, highest wins. The env override (precedence 1) is handled
in shell before this helper is reached; this helper covers precedence 2 and 3:

    2. `cron_dispatch_max_parallel` in the runtime bridge-config.json — the
       sanctioned, audit-chained, `agb config set`-writable override.
    3. host-profile-scaled default: profile=server -> 3, else (dev / unknown /
       missing) -> 1 (the conservative serial floor from issue #579).

Args:
    sys.argv[1]  runtime bridge-config.json path (may be empty / missing)
    sys.argv[2]  host-profile.json path          (may be empty / missing)

Stdout:
    The resolved positive integer worker-pool size.

Never raises on a missing/malformed file — any read error falls through to
the serial-1 floor, so a corrupt config can never wedge the daemon.
"""

from __future__ import annotations

import json
import sys


def load(path: str) -> dict:
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def main(argv: list[str]) -> int:
    config_path = argv[1] if len(argv) > 1 else ""
    profile_path = argv[2] if len(argv) > 2 else ""

    config = load(config_path)
    profile_doc = load(profile_path)

    # 2. Sanctioned JSON override. Accept int or numeric string; must be >= 1.
    # Reject JSON booleans explicitly — `int(True)` is `1`, so a stray
    # `"cron_dispatch_max_parallel": true` would otherwise silently resolve
    # to the serial floor as if it were a real `1`. Treat it as "unset" so
    # resolution falls through to the host-profile default instead.
    raw = config.get("cron_dispatch_max_parallel")
    if raw is not None and not isinstance(raw, bool):
        try:
            n = int(raw)
            if n >= 1:
                print(n)
                return 0
        except (TypeError, ValueError):
            pass

    # 3. Host-profile-scaled default.
    profile = profile_doc.get("profile", "")
    print(3 if profile == "server" else 1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
