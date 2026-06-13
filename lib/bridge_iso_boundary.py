#!/usr/bin/env python3
"""bridge_iso_boundary.py — the ONE common iso-v2 controller-boundary
classifier shared across every controller-run scanner (#1820 rc4).

Background (cm-prod, the first real Linux iso-v2 production host)
----------------------------------------------------------------
A controller (the operator's normal UID running ``layout-v2-reconcile.py``,
``bridge-watchdog.py``, the wiki rebuild, …) cannot read an iso-v2 agent's
files. On a *properly* isolated agent the agent **home** is
``2770 owner=agent-bridge-<a>:ab-agent-<a>`` and the controller is NOT a
member of ``ab-agent-<a>`` — so ``os.scandir(home)`` / ``os.walk`` /
``is_dir()`` raise ``[Errno 13] Permission denied`` **before** any per-file
logic runs. That is BY DESIGN and harmless: the iso UID reads its own files
fine (zero data loss). It is pure controller-side observability noise.

The cm-prod rc3 soak proved the #1876 reconcile iso-skip only covered 2 of 8
iso bots: the other 6 were ABSENT from the iso registry map handed to the
engine, so they fell through to the home traversal and threw Errno13. The
SAME boundary fires in the watchdog scan (rows classified ``iso-uid-side``)
and latently in any other controller scanner. cm-prod's recommendation: a
single shared primitive every scanner uses, with two complementary
mechanisms.

The two mechanisms this module provides
---------------------------------------
(a) **Registry classification** — decide "the iso boundary applies to this
    agent" *purely from loaded roster metadata*: ``isolation_mode ==
    linux-user`` + a resolved ``os_user`` + host == Linux. NO filesystem read
    of the agent home is performed to make this decision (that read is exactly
    what throws Errno13). This mirrors the shell predicate
    ``bridge_agent_linux_user_isolation_effective`` in ``lib/bridge-agents.sh``
    so the shell and python sides agree on "this is an iso agent".

(b) **Defensive boundary catch** — when a controller scanner DOES attempt a
    read and gets ``PermissionError`` / Errno13 on an iso-UID-owned path on an
    iso-v2-active host, classify it as the EXPECTED iso boundary so the caller
    records a structured graceful-skip instead of an ``unexpected error`` /
    ``scan_error`` / problem. On a shared-mode / macOS / non-iso install this
    returns False, so a PermissionError there stays a genuine warning/problem
    (byte-identical legacy behavior — the helper is a no-op off-host).

This module performs NO filesystem mutation and NO direct read of an
iso-owned path. It is pure classification over already-known inputs. That is
deliberate: it can never itself trip the Errno13 it exists to absorb, and it
is out of scope for the raw-pathlib-on-isolated lint (no probe/mutator calls).
"""

from __future__ import annotations

import errno

# Canonical token for the isolation mode that triggers the v2 OS-user boundary.
LINUX_USER_ISOLATION_MODE = "linux-user"


def host_is_linux(platform: str | None) -> bool:
    """True iff ``platform`` (e.g. ``uname -s`` / ``platform.system()``) is
    Linux. The iso-v2 OS-user boundary only exists on Linux; macOS / other
    hosts never have it, so every classifier here is a no-op off Linux."""
    return (platform or "").strip() == "Linux"


def iso_boundary_applies(
    *,
    platform: str | None,
    isolation_mode: str | None,
    os_user: str | None,
) -> bool:
    """Registry classification (mechanism a).

    Return True iff this agent is an EFFECTIVELY iso-v2 isolated agent — the
    controller boundary applies to its home/files — decided purely from loaded
    registry metadata, with NO filesystem read:

      * host is Linux, AND
      * ``isolation_mode == "linux-user"`` (the agent requested OS-user
        isolation), AND
      * a non-empty ``os_user`` is resolved (the iso account actually exists /
        was provisioned).

    This is the exact triple the shell predicate
    ``bridge_agent_linux_user_isolation_effective`` checks
    (``bridge_agent_linux_user_isolation_requested`` + Linux host +
    non-empty ``bridge_agent_os_user``). Off Linux, or for a shared-mode
    agent, or when the os_user is unknown, it returns False and the caller
    takes its normal (legacy) path.
    """
    if not host_is_linux(platform):
        return False
    if (isolation_mode or "").strip() != LINUX_USER_ISOLATION_MODE:
        return False
    if not (os_user or "").strip():
        return False
    return True


def is_permission_error(exc: BaseException) -> bool:
    """True iff ``exc`` is a controller-side permission denial — a
    ``PermissionError`` or any ``OSError`` whose ``errno`` is ``EACCES`` /
    ``EPERM`` (the Errno13 / Errno1 the controller hits crossing the iso
    boundary). Non-OSError exceptions are never a permission boundary."""
    if isinstance(exc, PermissionError):
        return True
    if isinstance(exc, OSError) and exc.errno in (errno.EACCES, errno.EPERM):
        return True
    return False


def is_expected_iso_permission_boundary(
    *,
    platform: str | None,
    isolation_mode: str | None,
    os_user: str | None,
    error_kind: str | None,
    error_category: str | None = None,
) -> bool:
    """Defensive boundary catch (mechanism b), watchdog flavor.

    Decide whether a scanner row / caught error is the PURE expected iso
    controller-boundary — the controller could not read an iso-UID-owned path,
    but the iso UID owns and can read it (the agent is healthy). Only such
    rows are downgraded out of the problem count.

    Precise predicate (must satisfy ALL):
      * the agent is an effectively-iso agent (``iso_boundary_applies``), AND
      * ``error_kind == "permission_denied"`` — the boundary is a denial, not a
        ``not_found`` / ``os_error`` (those are GENUINE drift and must stay
        problems even on an iso agent), AND
      * ``error_category`` is either empty/None (caller did no category split)
        or one of the iso-boundary categories the watchdog already emits for a
        controller-can't-read-but-iso-UID-owns case
        (``iso-uid-side`` / ``controller-cache-stale``). A ``publish-gap`` is
        an operator-actionable create-time gap and is NOT downgraded.

    The cm-prod rows were ``permission_denied`` + ``iso-uid-side`` on a
    perfectly healthy iso bot, because the controller could not even ``stat``
    the 2770 home to run the iso-UID readability probe — so the category fell
    through to ``iso-uid-side``. Registry classification is what lets us
    downgrade those WITHOUT trusting the (already-failed) runtime probe, while
    still keeping ``not_found`` / ``os_error`` rows as real problems.
    """
    if not iso_boundary_applies(
        platform=platform, isolation_mode=isolation_mode, os_user=os_user
    ):
        return False
    if (error_kind or "").strip() != "permission_denied":
        return False
    cat = (error_category or "").strip()
    if cat and cat not in ("iso-uid-side", "controller-cache-stale"):
        # e.g. "publish-gap" — a real create-time gap, stays a problem.
        return False
    return True


def iso_skip_reason(error_kind: str | None) -> str:
    """The structured ``reason`` token for a graceful-skip record produced by
    the reconcile belt when a controller PermissionError is absorbed at an iso
    agent home. Distinct from the clean up-front ``iso-agent-private`` reason so
    last-apply.json can tell "skipped because classified iso up-front" from
    "skipped because the controller hit Errno13 reaching the iso home"."""
    return "home-unreadable-controller"
