#!/usr/bin/env python3
"""Sudo-escalating pathlib wrappers for v2-isolation-aware Python helpers.

Shared canonical implementations consumed by `bridge-setup.py` and
`bridge-hooks.py`. Both files have historically grown near-identical
private helpers (`_safe_path_check`, `_safe_read_env`, `_safe_load_json`,
`_isolated_workdir_owner`, `_resolve_isolated_owner_for_path`,
`_sudo_run_as`) — each cycle's whack-a-mole bug surfaced one site at a
time because the canonical sudo-first shape lived in only one file at a
time. Issue #1175 consolidates them here so a single fix lands in both
files at once.

The Python module is stdlib-only by design — the controller runtime is
allowed no third-party deps. Both consumer scripts add `<repo>/lib/` to
`sys.path` and `from bridge_iso_paths import ...` the canonical names.

## Public API

### Ownership discovery

- `isolated_workdir_owner(path: Path) -> str | None` —
  return the `agent-bridge-<slug>` linux-user that owns `path` (or its
  nearest existing ancestor when the leaf is missing). Returns None on
  non-Linux dev hosts, when stat fails on every ancestor, when the
  owner looks like root or the controller, or when /etc/passwd lookup
  fails.

- `resolve_isolated_owner_for_path(path: Path) -> str | None` —
  walk up `path` until an existing ancestor's lstat succeeds, then
  hand off to `isolated_workdir_owner`. Use this in setup paths where
  the destination may not exist yet.

### Sudo escalation

- `sudo_run_as(os_user: str, *cmd: str) -> int` —
  inherit-stdio variant. Returns the subprocess return code. Used by
  `bridge-hooks.py` callers that previously consumed
  `subprocess.run(..., check=False).returncode`. On
  `FileNotFoundError` (sudo not installed) returns rc=127 and emits a
  one-line warn so the operator sees *why* fallback is impossible.

- `sudo_run_as_capture(os_user: str, *cmd: str) -> CompletedProcess[str]`
  — captured-stdio variant. Returns the full `CompletedProcess` so
  callers can parse stdout (used by `safe_read_env` / `safe_load_json`).
  On `FileNotFoundError` returns a synthetic rc=127 result.

### Safe filesystem predicates

- `safe_path_check(check: str, path: Path, os_user: str | None) -> bool`
  — PermissionError-safe `path.exists()` / `path.is_symlink()`. On
  isolated installs, `path.exists()` may raise PermissionError before
  the caller's recovery flow ever runs (the plugin dir's parent may
  be mode 0700 owned by the isolated UID; even mode 2750 +
  `ab-agent-<a>` group doesn't help when the controller is not in the
  group, #1170). When `os_user` is provided, proactively runs
  `sudo -n -u <agent-user> test -e/-h <path>` first so the controller
  never trips a PermissionError it could have skipped.

  Sudo result discrimination (PR #1172 r2 — preserved verbatim):
    rc=0 → True
    rc=1 + stderr starts with 'sudo:' → policy/auth failure
                                         (e.g. "sudo: a password is required"),
                                         fall through to direct pathlib
    rc=1 + clean stderr → authoritative False (test rc=1: path absent)
    TimeoutExpired / FileNotFoundError → fall through

  Falls through to the direct pathlib check on sudo unavailability;
  on the direct path a final PermissionError is swallowed and reported
  as "absent" (fail-closed) so callers like `safe_read_env` skip the
  read instead of bubbling a traceback up to setup teams|telegram|discord.

- `safe_read_env(path: Path) -> dict[str, str]` —
  PermissionError-safe `load_dotenv` for isolated plugin `.env` files.
  Falls back to `sudo -n -u <agent-user> cat <path>` when the direct
  read raises PermissionError, parses the captured stdout with the
  same dotenv schema.

- `safe_load_json(path: Path, default: Any) -> Any` —
  PermissionError-safe `load_json` for isolated plugin JSON state
  files. Same sudo-cat fallback shape; returns `default` for missing
  files or unparseable bodies.

### Dotenv helpers

- `parse_dotenv_text(text: str) -> dict[str, str]` — shared dotenv parser
  used by `safe_read_env` to interpret captured sudo-cat output.

## Back-compat aliases

The shared module also exports `_isolated_workdir_owner`,
`_resolve_isolated_owner_for_path`, `_sudo_run_as`, `_safe_path_check`,
`_safe_read_env`, `_safe_load_json`, `_parse_dotenv_text` as aliases
of the public names — so legacy unit-test harnesses that introspected
the private helpers via module attributes (e.g. the #1170 smoke that
stubs `mod._sudo_run_as`) keep working without churn.

## Footgun #11 (heredoc-stdin deadlock)

No `<<EOF` / `<<'PY'` heredoc-stdin feeds any subprocess in this module.
All scripts are inline string literals passed via `bash -c <script>`
with argv-only arguments.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Ownership discovery
# ---------------------------------------------------------------------------


def isolated_workdir_owner(path: Path) -> str | None:
    """Return `agent-bridge-<slug>` linux-user owning `path` or its nearest
    existing ancestor; None on non-Linux / non-isolated.

    Mirror of the historical `bridge-hooks.py:_isolated_workdir_owner`
    walker shape (#714 / #694 family). bridge-setup.py / bridge-hooks.py
    both run as the controller user; when an agent's workdir/home is
    owned by a linux-user-isolated account (`agent-bridge-<name>:agent-group
    mode 0750` from `bridge_isolation_v2_migrate_normalize_layout`),
    controller `mkdir` / `unlink` / `symlink_to` / `shutil.copy2` raise
    PermissionError. We don't have the agent name in every entry-point's
    argv, so derive the target user from the path's filesystem owner —
    that's the account the isolated UID was provisioned as.

    Walks up to deepest existing ancestor (sub-A / #1120) so a leaf
    that does not yet exist still resolves via the parent dir's group
    signature. uid-first lookup (#1139 sub-A) returns the
    `agent-bridge-*` name directly when the inode is owned by it,
    bypassing the gid-based enumeration entirely. Falls back to a
    /etc/passwd scan for the user whose primary gid matches the
    inode's gid AND whose name starts with `agent-bridge-` — the
    truncation-strategy mismatch (codex r1 #5726 BLOCKING #2 finding)
    means string-replacing `ab-agent-` → `agent-bridge-` is wrong for
    long agent names; the gid linkage avoids it.
    """
    if sys.platform != "linux":
        return None
    candidate: Path | None = path
    stat_result = None
    while candidate is not None:
        try:
            # lstat (not stat): a workdir that is itself a symlink (rare
            # but possible when a dynamic agent's worktree is symlinked
            # into ~/.agent-bridge/agents/<name>) must report the link's
            # owner, not the dereferenced target — the sudo fallback only
            # escalates to `sudo -n -u agent-bridge-<slug>`, so reading
            # the link itself is the right signal.
            stat_result = candidate.lstat()
            break
        except OSError:
            parent = candidate.parent
            if parent == candidate:
                return None
            candidate = parent
    if stat_result is None:
        return None
    try:
        import pwd
        owner = pwd.getpwuid(stat_result.st_uid).pw_name
        if owner.startswith("agent-bridge-"):
            return owner
    except (KeyError, ImportError):
        pass
    if stat_result.st_uid != os.getuid():
        try:
            import pwd
            for entry in pwd.getpwall():
                if (
                    entry.pw_gid == stat_result.st_gid
                    and entry.pw_name.startswith("agent-bridge-")
                ):
                    return entry.pw_name
        except (KeyError, ImportError):
            pass
    return None


def resolve_isolated_owner_for_path(path: Path) -> str | None:
    """Walk up `path` to the nearest existing ancestor and call
    `isolated_workdir_owner` on it. Returns None when no isolated
    ancestor is found.

    Use this in setup paths where the destination (channel dir or
    channel dotenv) may not exist yet — `path.parent` alone is not
    reliable because `mkdir` running as the controller would create a
    controller-owned dir, hiding the isolated lineage from a single-
    level lstat.
    """
    cur = path
    while True:
        try:
            if cur.exists():
                return isolated_workdir_owner(cur)
        except OSError:
            pass
        parent = cur.parent
        if parent == cur:
            return None
        cur = parent


# ---------------------------------------------------------------------------
# Sudo escalation — two shapes (rc-only vs captured)
# ---------------------------------------------------------------------------


def sudo_run_as(os_user: str, *cmd: str) -> int:
    """`sudo -n -u <os_user> <cmd...>` with inherit-stdio. Returns rc.

    Returns 127 with a one-line warn when sudo is not installed
    (`FileNotFoundError`). Mirrors the pre-refactor
    `bridge-hooks.py:_sudo_run_as` shape so legacy hooks-side callers
    that test `rc == 0` / `rc == 127` keep working unchanged.
    """
    full = ["sudo", "-n", "-u", os_user, *cmd]
    try:
        return subprocess.run(full, check=False).returncode
    except FileNotFoundError:
        # sudo missing — non-Linux dev hosts don't ship it. Emit a
        # one-line warn so the operator sees *why* fallback is
        # impossible (would otherwise be a silent 127 → caller
        # re-raises the original PermissionError without context).
        print(
            f"[bridge-iso-paths] sudo not available; cannot escalate to "
            f"'{os_user}' for {cmd}",
            file=sys.stderr,
        )
        return 127


def sudo_run_as_capture(
    os_user: str, *cmd: str
) -> "subprocess.CompletedProcess[str]":
    """`sudo -n -u <os_user> <cmd...>` with captured stdout/stderr.

    Used by callers that need to parse the captured output
    (`safe_read_env` / `safe_load_json` parse the dotenv / JSON body
    out of `sudo cat <file>` stdout). On `FileNotFoundError` returns a
    synthetic rc=127 `CompletedProcess` and emits a one-line warn so
    callers can re-raise the original PermissionError without losing
    context.
    """
    full = ["sudo", "-n", "-u", os_user, *cmd]
    try:
        return subprocess.run(
            full, check=False, capture_output=True, text=True
        )
    except FileNotFoundError:
        print(
            f"[bridge-iso-paths] sudo not available; cannot escalate to "
            f"'{os_user}' for {cmd}",
            file=sys.stderr,
        )
        return subprocess.CompletedProcess(
            args=full, returncode=127, stdout="", stderr=""
        )


# ---------------------------------------------------------------------------
# Safe filesystem predicates
# ---------------------------------------------------------------------------


def safe_path_check(check: str, path: Path, os_user: str | None) -> bool:
    """PermissionError-safe filesystem predicate for isolated plugin state.

    `check` ∈ {"exists", "is_symlink"}.

    On isolated installs, `path.exists()` may raise PermissionError
    before `load_dotenv`/`load_json` ever run (e.g. when the plugin
    dir's parent is mode 0700 owned by the agent user, leaving the
    controller without `+x` traversal). When `os_user` is provided,
    proactively runs `sudo -n -u <agent-user> test -e/-h <path>` first
    so the controller never trips a PermissionError it could have
    skipped — even with v2 Track A (`_isolation_aware_mkdir` mode 2750
    + `ab-agent-<a>` group, PR #1166) the controller may still not be
    a member of the per-agent group (#1170). Falls through to the
    direct pathlib check on sudo unavailability (rc 127 /
    FileNotFoundError / TimeoutExpired); on the direct path a final
    PermissionError is swallowed and reported as "absent" (fail-closed)
    so callers like `safe_read_env` skip the read instead of bubbling
    a traceback up to `setup teams|telegram|discord`.

    Sudo result discrimination (#1170 r2 — preserved verbatim):
      rc=0  → True
      rc=1 + stderr starts with "sudo:" → policy failure, fall through
      rc=1 + clean stderr → authoritative False
      TimeoutExpired / FileNotFoundError → fall through

    Issue #1078 F3/F5: when the caller could not resolve `os_user`
    upfront (every lstat in the ancestor chain hit PermissionError),
    the walker fallback in the PermissionError branch climbs ancestors
    until one with a readable lstat reveals the isolated UID. The
    walker only fires when the proactive sudo path was skipped
    (os_user was None going in).
    """
    if os_user:
        flag = "-e" if check == "exists" else "-h"
        # Direct subprocess.run (NOT sudo_run_as_capture) so we can plumb
        # timeout= and inspect stderr. The 5s budget bounds a stuck PAM /
        # NSS lookup; the stderr discrimination prevents a policy failure
        # ("sudo: a password is required") from being confused with a
        # clean `test` rc=1.
        try:
            result = subprocess.run(
                ["sudo", "-n", "-u", os_user, "test", flag, str(path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, PermissionError):
            result = None
        if result is not None:
            if result.returncode == 0:
                return True
            stderr = (result.stderr or "").strip()
            if stderr.startswith("sudo:"):
                # `sudo -n` policy/auth failure (e.g. "sudo: a password
                # is required"). The underlying `test` never ran, so
                # rc=1 here is NOT an authoritative "path absent" —
                # fall through to direct pathlib so an already-readable
                # path is still observed.
                pass
            elif result.returncode == 1:
                # Clean `test` rc=1 from inside the isolated UID — path
                # does not exist. Authoritative; do not fall through.
                return False
            # rc=2 / rc=127 / any other rc → fall through to pathlib.
    try:
        if check == "exists":
            return path.exists()
        if check == "is_symlink":
            return path.is_symlink()
    except PermissionError:
        if os_user is None:
            os_user = resolve_isolated_owner_for_path(path)
            if os_user is not None:
                flag = "-e" if check == "exists" else "-h"
                result = sudo_run_as_capture(
                    os_user, "test", flag, str(path)
                )
                if result.returncode in (0, 1):
                    return result.returncode == 0
        # Controller blind to isolated tree and sudo unavailable.
        # Fail closed: caller treats path as absent.
        return False
    return False


# ---------------------------------------------------------------------------
# Dotenv reader
# ---------------------------------------------------------------------------


def parse_dotenv_text(text: str) -> dict[str, str]:
    """Parse a dotenv body to a flat key/value dict.

    Matches `bridge-setup.py:load_dotenv`'s parse rules: strip
    surrounding whitespace; skip blank lines, lines beginning with `#`,
    and lines without `=`; split on the first `=` only.
    """
    payload: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key.strip()] = value.strip()
    return payload


def _load_dotenv_direct(path: Path) -> dict[str, str]:
    """Internal: read+parse `path` via direct pathlib.

    Separate from the public `safe_read_env` so the direct-read path is
    exercise-able in unit tests (the smoke harness stubs subprocess but
    not `Path.read_text`).
    """
    return parse_dotenv_text(path.read_text(encoding="utf-8"))


def safe_read_env(path: Path) -> dict[str, str]:
    """PermissionError-safe `load_dotenv` for isolated plugin `.env` files.

    Returns `{}` when the path doesn't exist (matches `load_dotenv`);
    re-raises the original PermissionError when no isolated owner can
    be identified (non-Linux, non-isolated, or sudo unavailable) so the
    caller surfaces the same error shape it had before.

    Issue #1078 F3: when the entire chain — `.teams/.env`, `.teams/`,
    and the workdir itself — is 0700-owned by the isolated UID, a
    single-level `lstat(path)` / `lstat(path.parent)` raises
    PermissionError (caught) and returns None, so the controller falls
    through to the plain `path.exists()` in `safe_path_check` and
    re-raises. The walker (`resolve_isolated_owner_for_path`) climbs
    ancestors until it finds an existing dir whose lstat succeeds —
    that node's owner is the same isolated UID by construction.
    """
    os_user = (
        isolated_workdir_owner(path)
        or isolated_workdir_owner(path.parent)
        or resolve_isolated_owner_for_path(path)
    )
    if not safe_path_check("exists", path, os_user):
        return {}
    try:
        return _load_dotenv_direct(path)
    except PermissionError as exc:
        if os_user is None:
            raise
        result = sudo_run_as_capture(os_user, "cat", str(path))
        rc = result.returncode
        if rc == 127:
            raise PermissionError(
                f"sudo not available; cannot read {path} as {os_user}. "
                f"Recovery requires either installing sudo or running this "
                f"command directly as {os_user}."
            ) from exc
        if rc != 0:
            raise PermissionError(
                f"sudo cat failed for {path} as {os_user} (rc={rc})"
            ) from exc
        return parse_dotenv_text(result.stdout)


def safe_load_json(path: Path, default: Any) -> Any:
    """PermissionError-safe `load_json` for isolated plugin state files.

    Companion to `safe_read_env` for `access.json` / `state.json` that
    live alongside the `.env` in the same isolated plugin dir. Falls
    back to `sudo -n -u <agent-user> cat` and `json.loads` when the
    direct read fails. Returns `default` for missing files (matches
    the public `load_json` shape in bridge-setup.py) or when the sudo
    fallback succeeds but the body is not valid JSON (best-effort —
    recovery flow rebuilds the doc from operator input).

    Issue #1078 F5: same chain-of-0700 wedge as F3. The walker is the
    backstop when single-level lstats hit PermissionError.
    """
    os_user = (
        isolated_workdir_owner(path)
        or isolated_workdir_owner(path.parent)
        or resolve_isolated_owner_for_path(path)
    )
    if not safe_path_check("exists", path, os_user):
        return default
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default
    except PermissionError as exc:
        if os_user is None:
            raise
        result = sudo_run_as_capture(os_user, "cat", str(path))
        rc = result.returncode
        if rc == 127:
            raise PermissionError(
                f"sudo not available; cannot read {path} as {os_user}. "
                f"Recovery requires either installing sudo or running this "
                f"command directly as {os_user}."
            ) from exc
        if rc != 0:
            raise PermissionError(
                f"sudo cat failed for {path} as {os_user} (rc={rc})"
            ) from exc
        try:
            return json.loads(result.stdout or "null") or default
        except json.JSONDecodeError:
            return default


# ---------------------------------------------------------------------------
# Back-compat aliases for legacy private-name introspection
# (e.g. unit-test harnesses that stub `mod._sudo_run_as` after a
# from-import). The aliases point to the same callable, so swapping
# either name on the *module* still works as expected.
# ---------------------------------------------------------------------------

_isolated_workdir_owner = isolated_workdir_owner
_resolve_isolated_owner_for_path = resolve_isolated_owner_for_path
_sudo_run_as = sudo_run_as
_sudo_run_as_capture = sudo_run_as_capture
_safe_path_check = safe_path_check
_safe_read_env = safe_read_env
_safe_load_json = safe_load_json
_parse_dotenv_text = parse_dotenv_text


__all__ = [
    "isolated_workdir_owner",
    "resolve_isolated_owner_for_path",
    "sudo_run_as",
    "sudo_run_as_capture",
    "safe_path_check",
    "safe_read_env",
    "safe_load_json",
    "parse_dotenv_text",
    # back-compat aliases
    "_isolated_workdir_owner",
    "_resolve_isolated_owner_for_path",
    "_sudo_run_as",
    "_sudo_run_as_capture",
    "_safe_path_check",
    "_safe_read_env",
    "_safe_load_json",
    "_parse_dotenv_text",
]
