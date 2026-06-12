#!/usr/bin/env python3
"""Helper for scripts/smoke/1826-cron-at-naive-tz.sh (Issue #1826, codex r4 [P2]).

Verify the host-zone resolver's /etc/localtime fallback contract portably:
when `--tz` is omitted, `$TZ` is unset, AND the host tzinfo has no `.key`
(macOS/glibc reading the /etc/localtime symlink), the host IANA zone must still
be recovered from /etc/localtime so `host_zone()` stays DST-aware instead of
degrading to the frozen-offset LOCAL_TZ.

Replaces the in-smoke `LT_CHECK` heredoc-stdin Python (footgun #11): the repo
root arrives as a file-as-argv argument — never via heredoc stdin. The
resolver is exercised regardless of the runner's own zone via mocked
`os.path.realpath`, so the contract holds on any CI host.

Args:
    sys.argv[1]  repo_root  Agent Bridge source checkout root

Prints "OK" on success; raises AssertionError (non-zero exit) on any failure,
matching the original inline check.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import unittest.mock
from datetime import datetime, timezone
from zoneinfo import ZoneInfo


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: host-zone-localtime-fallback.py REPO_ROOT", file=sys.stderr)
        return 2
    repo = argv[1]

    spec = importlib.util.spec_from_file_location("bc", f"{repo}/bridge-cron.py")
    bc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bc)

    fake = "/private/var/db/timezone/tz/2026b/zoneinfo/America/New_York"
    # No .key, no $TZ -> must resolve America/New_York from the /etc/localtime link.
    with unittest.mock.patch.dict("os.environ", {}, clear=False):
        os.environ.pop("TZ", None)
        with unittest.mock.patch.object(
            bc, "LOCAL_TZ", datetime.now(timezone.utc).astimezone().tzinfo
        ), unittest.mock.patch("os.path.realpath", return_value=fake):
            name = bc.host_iana_zone_name()
            zone = bc.host_zone()
    assert name == "America/New_York", name
    assert isinstance(zone, ZoneInfo) and zone.key == "America/New_York", zone
    # And the zone is genuinely DST-aware (distinct winter/summer offsets).
    jan = datetime(2026, 1, 15, 12, tzinfo=zone).utcoffset()
    jul = datetime(2026, 7, 15, 12, tzinfo=zone).utcoffset()
    assert jan != jul, (jan, jul)
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
