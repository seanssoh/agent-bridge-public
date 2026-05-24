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

    #1178 (cycle 12 architectural root): a `lstat()` that raises
    `PermissionError` is itself a POSITIVE signal of isolated lineage —
    the controller is blind to the inode precisely BECAUSE the path is
    under a v2-mode/group-protected tree the controller user is not in.
    The pre-#1178 walker treated `OSError` uniformly as "skip and walk
    up", so a leaf-and-every-ancestor that all denied PermissionError
    fell through to return None — and the caller (e.g.
    `bridge-setup.py:_isolation_aware_mkdir`) then took the
    `owner is None` branch and ran a raw `path.mkdir(parents=True,
    exist_ok=True)` against the isolated tree, which immediately
    re-raised PermissionError and crashed `setup teams|telegram|discord`.
    The fix: when a `PermissionError` (subclass of `OSError`) interrupts
    lstat, recover via `sudo -n stat -c %U` (GNU `stat`) or
    `sudo -n stat -f %Su` (BSD `stat` on macOS dev hosts), which reads
    the owner under root. A successful sudo-stat that returns an
    `agent-bridge-*` name is the authoritative owner. The walker keeps
    climbing on FileNotFoundError and other plain OSError so a missing
    leaf still resolves via the existing parent.
    """
    if sys.platform != "linux":
        return None
    candidate: Path | None = path
    stat_result = None
    sudo_owner: str | None = None
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
        except PermissionError:
            # POSITIVE signal: controller is blind to this inode because
            # the tree is v2-mode/group-protected. Recover via sudo-stat
            # which runs under root and reads the owner regardless of
            # the controller's group set. A successful resolution wins
            # outright; otherwise fall through to walk up.
            sudo_owner = _sudo_stat_owner(candidate)
            if sudo_owner and sudo_owner.startswith("agent-bridge-"):
                return sudo_owner
            parent = candidate.parent
            if parent == candidate:
                return None
            candidate = parent
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

    #1178 (cycle 12 architectural root): `path.exists()` raising
    `PermissionError` is a POSITIVE signal of isolated lineage — the
    controller cannot stat the inode precisely BECAUSE the path lives
    under a v2-mode/group-protected tree. The pre-#1178 helper swallowed
    PermissionError under the broad `except OSError: pass` and walked up
    blindly, so on a chain where every ancestor denied PermissionError
    (e.g. `/data/.../workdir/.teams` where `workdir` is mode 2770 owned
    by the isolated UID and the controller is not in the per-agent
    group), the walker fell off the root and returned None. Callers then
    took the `owner is None` branch and ran raw mkdir/copy/unlink
    against the isolated tree, raising PermissionError before the sudo
    fallback ever fired. The fix: when PermissionError interrupts
    `exists()`, recover via `_sudo_stat_owner` (which uses `sudo -n stat`
    to read the owner under root) before walking up — that's the correct
    signal that the path IS isolated.
    """
    cur = path
    while True:
        try:
            if cur.exists():
                return isolated_workdir_owner(cur)
        except PermissionError:
            # POSITIVE signal: the controller is blind because the path
            # is isolated. Try sudo-stat at this level before walking up.
            owner = _sudo_stat_owner(cur)
            if owner and owner.startswith("agent-bridge-"):
                return owner
            # sudo-stat failed (no sudo, no NOPASSWD, path truly
            # missing). Fall through to walk up — a parent dir's
            # successful sudo-stat may still reveal the lineage.
        except OSError:
            pass
        parent = cur.parent
        if parent == cur:
            return None
        cur = parent


def _sudo_stat_owner(path: Path) -> str | None:
    """Return the owner username of `path` via `sudo -n stat`, or None.

    #1178: when the controller's pathlib probe raises PermissionError on
    an isolated tree, the controller IS blind to that inode but root
    still sees it. Escalate via `sudo -n stat` to read the owner — the
    answer is the authoritative `agent-bridge-<slug>` linux-user
    provisioned for that agent.

    Tries GNU `stat -c %U` first (Linux production hosts) and falls back
    to BSD `stat -f %Su` (macOS dev hosts that may surface a
    `PermissionError` via a different mechanism, e.g. SIP-restricted
    paths). Returns None on:
      - sudo not installed (`FileNotFoundError`)
      - sudo policy/auth failure (rc!=0 with `sudo:` stderr prefix)
      - both `stat` forms failing (path truly missing, or stat refused
        the call under root for an unrelated reason)
      - `TimeoutExpired` (PAM/NSS stuck — fail-closed)
      - empty stdout from a successful invocation (shouldn't happen but
        treat as no-info)

    The 5s timeout mirrors `safe_path_check`'s budget for the same
    PAM/NSS scenarios. stderr discrimination mirrors the same module's
    `sudo:`-prefix policy-failure detection so a NOPASSWD denial doesn't
    masquerade as "path absent".
    """
    for spec in ("-c", "-f"):
        # GNU: stat -c %U <path>
        # BSD: stat -f %Su <path>
        fmt = "%U" if spec == "-c" else "%Su"
        cmd = ["sudo", "-n", "stat", spec, fmt, str(path)]
        try:
            result = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, PermissionError):
            return None
        stderr = (result.stderr or "").strip()
        if result.returncode == 0:
            owner = (result.stdout or "").strip()
            if owner:
                return owner
            # rc=0 but empty stdout — shouldn't happen; try the next form.
            continue
        if stderr.startswith("sudo:"):
            # sudo policy/auth failure — no point trying the other format,
            # both will hit the same gate.
            return None
        # Non-sudo error (e.g. GNU `stat` rejecting BSD flags or vice
        # versa, or `stat` reporting the path missing). Try the next
        # format spec; if that also fails we return None below.
    return None


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
# Phase 2 lift — Realpath / ensure_dir / atomic write
# Consolidated from bridge-hooks.py (_safe_realpath, _ensure_dir_with_sudo)
# and bridge-setup.py (_sudo_write_as) so the helper layer has one canonical
# implementation. Pre-Phase 2: each consumer file carried near-identical
# private duplicates and a bug fixed in one didn't land in the other (the
# same class as cycle 9-12 cost).
# ---------------------------------------------------------------------------


def safe_realpath(path: Path, os_user: str | None) -> str:
    """PermissionError-safe `os.path.realpath` for isolated workdirs.

    `os.path.realpath` resolves symlinks by stat-ing each component;
    on an isolated workdir the controller can hit PermissionError mid-
    resolution. When `os_user` is provided, falls back to
    `sudo -n -u <agent-user> readlink -f`. Returns the original path
    string when the sudo fallback also fails (best-effort — callers
    compare two realpaths for equality, so falling back to the raw
    string just forces the "not equal" branch and re-creates whatever
    the caller wanted to recreate).

    Lifted from bridge-hooks.py:_safe_realpath (Phase 2). The hooks-
    side wrapper now delegates to this canonical implementation; the
    private name remains via the back-compat alias below for any
    legacy unit-test introspection.
    """
    try:
        return os.path.realpath(path)
    except PermissionError:
        if os_user is None:
            raise
        # captured-stdio so we can read the result back; rc-only would
        # discard the answer.
        result = sudo_run_as_capture(os_user, "readlink", "-f", str(path))
        if result.returncode == 0:
            return (result.stdout or "").strip() or str(path)
        return str(path)


def ensure_dir(path: Path, os_user: str | None) -> None:
    """`mkdir -p` with isolation awareness.

    When `os_user` is provided and is NOT the current process user,
    route through `sudo -n -u <os_user> mkdir -p <path>` FIRST. The
    isolated UID owns its workdir (mode 2770) so creating subdirs
    under it succeeds without controller intervention.

    Fallback: when sudo escalation is unavailable (rc=127 / non-Linux
    dev host) or fails, attempt the controller-direct
    `path.mkdir(parents=True, exist_ok=True)`. On v2 isolation that
    controller-direct mkdir will itself fail with PermissionError —
    re-raise so the caller sees a real error rather than silent
    partial state. The caller is responsible for try/except OSError
    to surface a structured warning (the #1145 / #1119 / PR #1124
    pattern).

    Lifted from bridge-hooks.py:_ensure_dir_with_sudo (Phase 2). The
    consumer's `os_user is None → resolve via _isolated_workdir_owner`
    fallback is preserved in the wrapper, not here — this canonical
    function takes the resolved owner as input so callers stay
    explicit about who they're escalating to.
    """
    current_user = ""
    try:
        import pwd
        current_user = pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, ImportError):
        current_user = ""
    if os_user is not None and os_user != current_user:
        rc = sudo_run_as(os_user, "mkdir", "-p", str(path))
        if rc == 0:
            return
        # Fall through — sudo failed (rc=127 missing, or sudo rc≠0).
        # The controller-direct attempt below will re-raise the real
        # PermissionError if the path is actually isolated.
    path.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — canonical fallback after sudo-first


# Inline bash that the atomic-write contract relies on. Same body as
# bridge-setup.py:_ISOLATED_WRITE_SCRIPT and
# bridge_isolation_write_file_as_agent_user_via_bash — mktemp in the
# DEST dir (so the final mv is rename-on-same-FS atomic), chmod
# before rename, mv -f. Argv positions:
#   $0  literal "bridge-isolation"  (for ps display only)
#   $1  dest_path
#   $2  mode (octal, no leading zero)
_ATOMIC_WRITE_SCRIPT = (
    'set -eo pipefail\n'
    'dest_path="$1"\n'
    'mode="$2"\n'
    'dest_dir="$(dirname "$dest_path")"\n'
    '[[ -d "$dest_dir" ]] || exit 5\n'
    'tmp="$(mktemp "$dest_dir/.$(basename "$dest_path").bridge-write-tmp.XXXXXX")" || exit 6\n'
    'trap \'rm -f "$tmp" 2>/dev/null\' EXIT INT TERM\n'
    'if ! cat - >"$tmp"; then exit 7; fi\n'
    'if ! chmod "$mode" "$tmp"; then exit 8; fi\n'
    'if ! mv -f "$tmp" "$dest_path"; then exit 9; fi\n'
    'trap - EXIT INT TERM\n'
    'exit 0\n'
)


def write_text_atomic_as_owner(
    os_user: str,
    dest_path: Path,
    content: str,
    mode: int = 0o600,
) -> "subprocess.CompletedProcess[str]":
    """Atomic write of `content` to `dest_path` as `os_user`.

    Streams `content` via stdin to `bash -c <inline-script>` running
    as `os_user` under `sudo -n`. The inline script writes via
    mktemp-in-target-dir + chmod-before-rename — same atomicity
    contract as `bridge_isolation_write_file_as_agent_user_via_bash`
    (the bash sibling in `lib/bridge-isolation-helpers.sh`).

    Returns the `CompletedProcess` so callers can inspect
    `returncode` / `stderr`. Does NOT raise on non-zero rc — caller
    is responsible for surfacing the failure shape. Mirrors the
    pre-Phase 2 `bridge-setup.py:_sudo_write_as` ergonomics.

    Exit codes from the inline script:
       5 — dest_dir does not exist (caller should mkdir parent first)
       6 — mktemp in dest_dir failed (permission / disk full)
       7 — cat stdin → tmp failed
       8 — chmod tmp failed
       9 — mv tmp → dest_path failed
     127 — sudo not installed (synthetic, from FileNotFoundError catch)

    Lifted from bridge-setup.py:_sudo_write_as (Phase 2). The setup-
    side wrapper now delegates here; the inline script lives in this
    module so both consumers share one bash body.
    """
    full = [
        "sudo", "-n", "-u", os_user, "bash", "-c", _ATOMIC_WRITE_SCRIPT,
        "bridge-isolation", str(dest_path), f"{mode:o}",
    ]
    try:
        return subprocess.run(
            full, input=content, check=False, capture_output=True, text=True
        )
    except FileNotFoundError:
        print(
            f"[bridge-iso-paths] sudo not available; cannot write {dest_path} "
            f"as '{os_user}'",
            file=sys.stderr,
        )
        return subprocess.CompletedProcess(
            args=full, returncode=127, stdout="", stderr=""
        )


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
# Phase 2 aliases — same back-compat shape so consumer-side wrappers
# (bridge-hooks.py:_safe_realpath / _ensure_dir_with_sudo,
# bridge-setup.py:_sudo_write_as) can route through these names if a
# test harness ever monkey-patches the module-level callable.
_safe_realpath = safe_realpath
_ensure_dir = ensure_dir
_write_text_atomic_as_owner = write_text_atomic_as_owner
# `_sudo_stat_owner` is #1178 private helper used by the cycle 12 entry
# points (resolve_isolated_owner_for_path + isolated_workdir_owner). It
# is named with a leading underscore at `def` time, so no separate
# alias is needed; the `__all__` entry below lets test harnesses
# monkey-patch `mod._sudo_stat_owner` if they want a no-sudo fixture.


__all__ = [
    "isolated_workdir_owner",
    "resolve_isolated_owner_for_path",
    "sudo_run_as",
    "sudo_run_as_capture",
    "safe_path_check",
    "safe_read_env",
    "safe_load_json",
    "parse_dotenv_text",
    # Phase 2 canonical names
    "safe_realpath",
    "ensure_dir",
    "write_text_atomic_as_owner",
    # back-compat aliases
    "_isolated_workdir_owner",
    "_resolve_isolated_owner_for_path",
    "_sudo_run_as",
    "_sudo_run_as_capture",
    "_safe_path_check",
    "_safe_read_env",
    "_safe_load_json",
    "_parse_dotenv_text",
    "_safe_realpath",
    "_ensure_dir",
    "_write_text_atomic_as_owner",
    # #1178 private helper (exposed for test introspection only)
    "_sudo_stat_owner",
]
