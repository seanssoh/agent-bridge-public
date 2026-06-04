#!/usr/bin/env python3
"""#1520c — assert ``classify_scan_error_category`` routes the create-time
publish gap to ``publish-gap`` and PRESERVES genuine ``controller-cache-
stale`` (no false-positive regression).

Loads bridge-watchdog.py as a module and drives ``classify_scan_error_
category`` through its test seams (``BRIDGE_WATCHDOG_TEST_PROFILE_META_JSON``
for the on-disk group:mode, ``BRIDGE_WATCHDOG_TEST_ISO_PROBE_JSON`` for the
iso-UID readability probe) so the metadata-aware classification path is
exercised on any host — no real Linux iso required.

Usage:  assert-watchdog-publish-gap.py <repo-root>

Exits 0 only when ALL cases pass.
"""
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve()
WATCHDOG = REPO_ROOT / "bridge-watchdog.py"

spec = importlib.util.spec_from_file_location("bw_under_test", WATCHDOG)
bw = importlib.util.module_from_spec(spec)
# Register before exec so the @dataclass __module__ lookup resolves under
# `from __future__ import annotations` (importlib quirk on some CPython).
sys.modules["bw_under_test"] = bw
spec.loader.exec_module(bw)

TD = tempfile.mkdtemp()
WD = Path(TD) / "workdir"
WD.mkdir()
ISO_USER = "agent-bridge-foo"  # → expected group ab-agent-foo
EXPECTED_GROUP = "ab-agent-foo"
WRONG_GROUP = "controllergrp"

# Create the on-disk fixtures the classifier will reference by path.
for name in ("SOUL.md", "CLAUDE.md", "TOOLS.md", "HEARTBEAT.md"):
    (WD / name).write_text("x")


def _seam(meta: dict, probe: dict) -> None:
    mf = Path(TD) / "meta.json"
    mf.write_text(json.dumps(meta))
    os.environ["BRIDGE_WATCHDOG_TEST_PROFILE_META_JSON"] = str(mf)
    pf = Path(TD) / "probe.json"
    pf.write_text(json.dumps(probe))
    os.environ["BRIDGE_WATCHDOG_TEST_ISO_PROBE_JSON"] = str(pf)


failures: list[str] = []


def check(name: str, got: str, exp: str) -> None:
    if got != exp:
        failures.append(f"{name}: got {got!r} expected {exp!r}")
    else:
        print(f"  [PASS] {name}: {got!r}")


soul = str(WD / "SOUL.md")
claude = str(WD / "CLAUDE.md")
heartbeat = str(WD / "HEARTBEAT.md")

# C6 — wrong-group profile file at 0600, BUT iso UID can read it. Without
# the metadata-first publish-gap check this would mislabel as
# controller-cache-stale. MUST be publish-gap.
_seam({soul: f"{WRONG_GROUP}:600"}, {soul: "readable"})
check(
    "C6 wrong-group + iso-readable",
    bw.classify_scan_error_category("permission_denied", soul, WD, ISO_USER),
    "publish-gap",
)

# C6b — correct group but owner-only mode (0600, group-read clear) →
# publish-gap (the group flip happened but the chmod did not, or vice
# versa — either way controller cannot read).
_seam({claude: f"{EXPECTED_GROUP}:600"}, {claude: "readable"})
check(
    "C6b correct-group + owner-only mode",
    bw.classify_scan_error_category("permission_denied", claude, WD, ISO_USER),
    "publish-gap",
)

# C7 — PRESERVE genuine controller-cache-stale: metadata MATCHES the
# published contract (ab-agent-foo:0660) AND iso UID can read. The only
# problem is the controller's stale supp-group cache. MUST stay
# controller-cache-stale (no false-positive publish-gap).
_seam({soul: f"{EXPECTED_GROUP}:660"}, {soul: "readable"})
check(
    "C7 contract-match + iso-readable (preserved)",
    bw.classify_scan_error_category("permission_denied", soul, WD, ISO_USER),
    "controller-cache-stale",
)

# C8 — negative control: HEARTBEAT.md is NOT in the profile-publish set, so
# even at wrong-group 0600 it must NOT be classified publish-gap (it is
# controller-owned 0600 by design). Falls through to the iso-probe verdict.
_seam({heartbeat: f"{WRONG_GROUP}:600"}, {heartbeat: "readable"})
check(
    "C8 HEARTBEAT.md negative control",
    bw.classify_scan_error_category(
        "permission_denied", heartbeat, WD, ISO_USER
    ),
    "controller-cache-stale",
)

# C9 — iso-uid-side preserved: a non-permission error stays iso-uid-side.
check(
    "C9 not_found stays iso-uid-side",
    bw.classify_scan_error_category("not_found", soul, WD, ISO_USER),
    "iso-uid-side",
)

# C10 — publish-gap requires the profile file be DIRECTLY under the
# workdir; a same-named file one level deeper is not the create-time gap.
nested = str(WD / "sub" / "SOUL.md")
_seam({nested: f"{WRONG_GROUP}:600"}, {nested: "readable"})
check(
    "C10 nested SOUL.md not publish-gap",
    bw.classify_scan_error_category("permission_denied", nested, WD, ISO_USER),
    "controller-cache-stale",
)

if failures:
    print("FAIL:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("PASS — watchdog publish-gap classification + cache-stale preservation")
sys.exit(0)
