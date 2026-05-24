#!/usr/bin/env python3
"""Interactive Discord, Telegram, and Teams onboarding helpers for Agent Bridge."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class SetupError(Exception):
    """Raised when setup validation fails with a user-facing message."""




def plugin_port_range() -> tuple[int, int]:
    start_raw = os.environ.get("BRIDGE_PLUGIN_PORT_RANGE_START", "").strip() or "39800"
    end_raw = os.environ.get("BRIDGE_PLUGIN_PORT_RANGE_END", "").strip() or "39999"
    try:
        start = int(start_raw)
        end = int(end_raw)
    except ValueError as exc:
        raise SetupError(f"BRIDGE_PLUGIN_PORT_RANGE_* must be integers: {start_raw}-{end_raw}") from exc
    if start <= 0 or end <= 0 or end < start:
        raise SetupError(f"BRIDGE_PLUGIN_PORT_RANGE_* 범위가 유효하지 않습니다: {start}-{end}")
    return start, end


def port_is_free(port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        return False
    finally:
        sock.close()
    return True


def allocate_channel_port(agent: str, plugin_label: str, existing: str = "") -> int:
    start, end = plugin_port_range()
    span = end - start + 1
    existing_stripped = existing.strip()
    if existing_stripped.isdigit():
        current = int(existing_stripped)
        if start <= current <= end and port_is_free(current):
            return current
    digest = hashlib.sha1(f"{agent}|{plugin_label}".encode("utf-8")).hexdigest()
    offset = int(digest[:8], 16) % span
    for step in range(span):
        candidate = start + (offset + step) % span
        if port_is_free(candidate):
            return candidate
    raise SetupError(
        f"사용 가능한 plugin 포트를 찾지 못했습니다 (agent={agent}, plugin={plugin_label}, range={start}-{end})"
    )


def load_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def save_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


# Inline mirror of bridge_isolation_write_file_as_agent_user_via_bash
# (lib/bridge-isolation-helpers.sh:181). Used when the destination's
# parent dir is owned by an isolated agent-bridge-<slug> UID and the
# controller cannot write directly.
#
# Contract — MUST match the Bash helper exit-code band:
#   rc=0    success
#   rc=2    sudo missing / not allowed
#   rc=5    destination dir missing
#   rc=6    mktemp failed
#   rc=7    stdin write failed
#   rc=8    chmod failed
#   rc=9    rename failed
#
# DO NOT introduce heredoc / here-string at the call site (footgun #11 —
# see CLAUDE.md, [[feedback_bash_heredoc_write_class_recurrence]]).
# Content is streamed via subprocess stdin pipe.
_ISOLATED_WRITE_SCRIPT = (
    'dest_path="$1"\n'
    'mode="$2"\n'
    'dest_dir="$(dirname "$dest_path")"\n'
    'if [[ ! -d "$dest_dir" ]]; then exit 5; fi\n'
    'umask 0077\n'
    'tmp="$(mktemp "$dest_dir/.$(basename "$dest_path").bridge-write-tmp.XXXXXX")" || exit 6\n'
    'trap \'rm -f "$tmp" 2>/dev/null\' EXIT INT TERM\n'
    'if ! cat - >"$tmp"; then exit 7; fi\n'
    'if ! chmod "$mode" "$tmp"; then exit 8; fi\n'
    'if ! mv -f "$tmp" "$dest_path"; then exit 9; fi\n'
    'trap - EXIT INT TERM\n'
    'exit 0\n'
)


def _sudo_write_as(
    os_user: str,
    dest_path: Path,
    content: str,
    mode: int = 0o600,
) -> subprocess.CompletedProcess[str]:
    """Symmetric write counterpart to `_sudo_run_as`. Streams `content` via
    stdin to `bash -c <inline-script>` running as `os_user` under
    `sudo -n`. The inline script atomically writes to `dest_path` at
    `mode` using mktemp-in-target-dir + chmod-before-rename — same
    contract as `bridge_isolation_write_file_as_agent_user_via_bash`.

    Does NOT raise on non-zero rc — caller inspects `proc.returncode`
    against the contract above. Matches `_sudo_run_as` ergonomics.
    """
    full = [
        "sudo", "-n", "-u", os_user, "bash", "-c", _ISOLATED_WRITE_SCRIPT,
        "bridge-isolation", str(dest_path), f"{mode:o}",
    ]
    try:
        return subprocess.run(
            full, input=content, check=False, capture_output=True, text=True
        )
    except FileNotFoundError:
        print(
            f"[bridge-setup] sudo not available; cannot escalate to "
            f"'{os_user}' for write to {dest_path}",
            file=sys.stderr,
        )
        return subprocess.CompletedProcess(
            args=full, returncode=127, stdout="", stderr=""
        )


def _isolation_aware_save_text(path: Path, text: str, mode: int = 0o600) -> None:
    """save_text variant that delegates to sudo-as-isolated-UID when the
    destination's parent dir is owned by an isolated agent-bridge-<slug>
    UID. On non-isolated installs / non-Linux dev hosts, falls back to
    the standard `save_text` path unchanged.

    Probes ownership via `_resolve_isolated_owner_for_path` so the
    nearest existing ancestor is used; `path.parent` alone is not
    reliable because a caller (e.g. `cmd_<channel>`) may have already
    `mkdir`'d the parent as the controller, hiding the isolated lineage
    from a single-level lstat. The destination file itself may not
    exist yet on first setup.
    """
    owner = _resolve_isolated_owner_for_path(path)
    if owner is None:
        save_text(path, text)
        return
    proc = _sudo_write_as(owner, path, text, mode)
    if proc.returncode != 0:
        raise SetupError(
            f"isolation-aware save_text to {path} as {owner} failed "
            f"(rc={proc.returncode}): {proc.stderr.strip() or '(no stderr)'}"
        )


def _isolation_aware_save_json(path: Path, payload: Any, mode: int = 0o600) -> None:
    """save_json variant — same isolation-aware dispatch as
    `_isolation_aware_save_text`. Serializes the payload first, then
    streams via the same write contract.
    """
    owner = _resolve_isolated_owner_for_path(path)
    if owner is None:
        save_json(path, payload)
        return
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    proc = _sudo_write_as(owner, path, text, mode)
    if proc.returncode != 0:
        raise SetupError(
            f"isolation-aware save_json to {path} as {owner} failed "
            f"(rc={proc.returncode}): {proc.stderr.strip() or '(no stderr)'}"
        )


def load_dotenv(path: Path) -> dict[str, str]:
    payload: dict[str, str] = {}
    if not path.exists():
        return payload
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key.strip()] = value.strip()
    return payload


def _parse_dotenv_text(text: str) -> dict[str, str]:
    payload: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key.strip()] = value.strip()
    return payload


def _isolated_workdir_owner(path: Path) -> str | None:
    # Mirror of bridge-hooks.py `_isolated_workdir_owner` (#714 / #694
    # family). bridge-setup.py runs as the controller user during
    # `agent-bridge setup teams|telegram|discord <agent>` recovery; when
    # the plugin state files (`.teams/.env`, `.telegram/.env`,
    # `.discord/.env`) are owned by an isolated `agent-bridge-<slug>` UID
    # in 0600 mode, the controller's `.env` read raises PermissionError
    # before the recovery flow can reach `save_text` (#737 Q5). We fall
    # back to `sudo -n -u <agent-user> cat` for the read; this helper
    # picks the target user from the path's filesystem owner. Returns
    # None on non-Linux hosts and for non-isolated paths so the
    # fallback-only callers stay no-ops on dev machines.
    if sys.platform != "linux":
        return None
    try:
        stat_result = path.lstat()
    except OSError:
        return None
    try:
        import pwd

        owner = pwd.getpwuid(stat_result.st_uid).pw_name
    except (KeyError, ImportError):
        return None
    if stat_result.st_uid == os.getuid():
        return None
    if not owner.startswith("agent-bridge-"):
        return None
    return owner


def _resolve_isolated_owner_for_path(path: Path) -> str | None:
    """Walk up from `path` to find the nearest existing ancestor and
    return its isolated `agent-bridge-<slug>` owner via
    `_isolated_workdir_owner`. Returns None when the nearest existing
    ancestor is controller-owned, on non-Linux dev hosts, or when no
    ancestor exists.

    Use this in setup paths where the destination (channel dir or
    channel dotenv) may not exist yet — `path.parent` alone is not
    reliable because `mkdir` running as the controller would create a
    controller-owned dir, hiding the isolated lineage from a single-
    level lstat.
    """
    cur = path
    # Avoid an infinite loop on filesystem root.
    while True:
        try:
            if cur.exists():
                return _isolated_workdir_owner(cur)
        except OSError:
            pass
        parent = cur.parent
        if parent == cur:
            return None
        cur = parent


def _v2_agent_group_name(agent: str) -> str | None:
    """Pure-Python mirror of `bridge_isolation_v2_agent_group_name`
    (lib/bridge-isolation-v2.sh:406-460).

    The v2 prepare path creates `ab-agent-<agent>` as a SUPPLEMENTARY
    group of the isolated UID — `useradd -r` on a fresh user does NOT
    set `-g <ab-agent>`, so the isolated UID's PRIMARY group is whatever
    `useradd` defaulted to (often the system's `users` group or a
    per-UID equivalent). `id -gn <isolated-uid>` returns that primary
    group, NOT `ab-agent-<agent>` (#1165 r2 BLOCKING 1 — codex catch).
    The controller is added to `ab-agent-<agent>` as a supplementary
    member but NOT to the primary group, so a `chgrp <primary-group>`
    on `.teams/` would re-lock the controller out of every subsequent
    `os.stat`. This helper composes the deterministic `ab-agent-<slug>`
    group name the v2 grant path actually uses.

    Mirrors the bash helper's platform-branched length policy:
      - Linux: hard 32-char cap on group names; for `ab-agent-<agent>`
        compositions exceeding 32 chars, the agent segment is reduced
        to `<head>-<7-char-sha256(agent)>` so two long agent names with
        a shared head still resolve to distinct groups.
      - Darwin: `dseditgroup` tolerates 255-char group names; pass
        through unchanged up to that limit.

    Returns None for invalid agent names (groupadd accepts only
    [a-z_][a-z0-9_-]*) or when the macOS 255-char limit is exceeded —
    matching the bash helper's `return 1` paths.

    Cross-language pair: keep in lock-step with
    `bridge_isolation_v2_agent_group_name` in lib/bridge-isolation-v2.sh.
    Any change to one side (prefix override, length policy, hash width)
    MUST land on both sides in the same commit.
    """
    if not agent:
        return None
    if not re.match(r'^[a-z_][a-z0-9_-]*$', agent):
        return None
    prefix = os.environ.get("BRIDGE_AGENT_GROUP_PREFIX", "ab-agent-")
    composed = f"{prefix}{agent}"
    if sys.platform == "darwin":
        if len(composed) > 255:
            return None
        return composed
    # Linux: 32-char hard cap with hash-truncation on overflow.
    if len(composed) <= 32:
        return composed
    prefix_len = len(prefix)
    avail = 32 - prefix_len
    # Need at least 1 char + '-' + 7-char hash = 9 chars for the segment.
    if avail < 9:
        return None
    keep = avail - 1 - 7
    digest = hashlib.sha256(agent.encode("utf-8")).hexdigest()[:7]
    head = agent[:keep]
    return f"{prefix}{head}-{digest}"


def _isolation_aware_mkdir(
    path: Path,
    mode: int = 0o2750,
    group: str | None = None,
    agent: str | None = None,
) -> None:
    """`mkdir -p` with isolation awareness. If `path` does not exist and
    its nearest existing ancestor is owned by an isolated
    `agent-bridge-<slug>` UID, create the missing components as that
    UID via `sudo -n -u <owner> bash -c '...'`. Otherwise falls back to
    `Path.mkdir(parents=True, exist_ok=True)`.

    For isolated channel state dirs (`.teams/`, `.telegram/`, `.discord/`,
    `.mattermost/`) the default mode is `0o2750` (setgid + group r-x), so
    the controller (a member of the agent group `ab-agent-<slug>`) keeps
    traversal permission after the chown to the isolated UID lands.
    Pre-#1165 the helper used `umask 0077` which produced mode 0700 and
    locked the controller out of every subsequent `os.stat` against the
    channel state files (#1165 Gap 1 — `setup teams` then failed on the
    next `inspect_teams_dir` with PermissionError).

    Args:
      path: directory to create.
      mode: target mode for the new directory. Defaults to `0o2750`
        which matches the v2 isolation contract for channel state dirs.
      group: explicit group name to `chgrp` after the mkdir+chmod step.
        Highest priority when set; useful for tests that need to pin a
        non-default group.
      agent: the agent slug (e.g., `args.agent` in the channel setup
        commands). When set and `group` is None, the v2 `ab-agent-<slug>`
        group is computed via the local `_v2_agent_group_name` mirror
        of `bridge_isolation_v2_agent_group_name`. This is the correct
        group to chgrp to — see #1165 r2 BLOCKING 1: the v2 prepare
        path makes `ab-agent-<agent>` a SUPPLEMENTARY group of the
        isolated UID, and `id -gn <isolated-uid>` returns the PRIMARY
        group which the controller is NOT a member of, so falling back
        to `id -gn` re-locks the controller out of `.teams/`.
      (legacy) When both `group` and `agent` are None, falls back to
        `id -gn <isolated-uid>` as a last-resort probe. This fallback
        is unreliable on v2 hosts (returns the primary group, not the
        controller-readable supplementary group) and should not be
        relied on by new callers — pass `agent=` instead.
    """
    if path.exists():
        return
    owner = _resolve_isolated_owner_for_path(path)
    if owner is None:
        path.mkdir(parents=True, exist_ok=True)
        return
    # Resolve the target group. Priority: explicit `group=` >
    # v2-helper-via-`agent=` > `id -gn` legacy fallback. The v2 helper
    # is authoritative on a v2 install — it composes the same
    # `ab-agent-<slug>` group the bash grant path used to add the
    # controller as a supplementary member. `id -gn <isolated-uid>`
    # returns the isolated user's PRIMARY group, NOT the per-agent
    # supplementary group; using it would re-lock the controller out
    # of `.teams/` because the controller is not a member of the
    # isolated UID's primary group on v2 installs (#1165 r2 BLOCKING 1).
    resolved_group = group
    if resolved_group is None and agent is not None:
        resolved_group = _v2_agent_group_name(agent)
    if resolved_group is None:
        # Last-resort fallback: probe the isolated UID's primary group.
        # On a v2 install this is NOT the controller-readable group
        # (see docstring); kept for legacy callers that have no
        # `agent` handle. New callers must pass `agent=` so the v2
        # helper is exercised instead.
        try:
            id_proc = subprocess.run(
                ["id", "-gn", owner],
                check=False, capture_output=True, text=True,
            )
        except FileNotFoundError:
            id_proc = None
        if id_proc is not None and id_proc.returncode == 0:
            candidate = id_proc.stdout.strip()
            if candidate:
                resolved_group = candidate
    # Build the script with mode encoded in octal (e.g. 0o2750 -> "2750").
    # The mkdir runs under umask 0077 to guarantee a deterministic
    # starting point; the explicit chmod afterwards lands the target
    # mode regardless of the inherited umask. chgrp is best-effort on
    # the isolated UID's own primary group — failure does not abort
    # because the chmod alone restores controller traversal on the
    # common v2 case (group already matches the agent group).
    mode_oct = format(mode, 'o')
    script_lines = [
        'set -e',
        'umask 0077',
        'mkdir -p "$1"',
        'chmod "$2" "$1"',
    ]
    if resolved_group:
        script_lines.append('chgrp "$3" "$1" 2>/dev/null || true')
    script_lines.append('exit 0')
    script = '\n'.join(script_lines) + '\n'
    full = [
        "sudo", "-n", "-u", owner, "bash", "-c", script,
        "bridge-isolation", str(path), mode_oct,
    ]
    if resolved_group:
        full.append(resolved_group)
    try:
        proc = subprocess.run(
            full, check=False, capture_output=True, text=True
        )
    except FileNotFoundError:
        raise SetupError(
            f"sudo not available; cannot mkdir {path} as isolated user {owner}"
        )
    if proc.returncode != 0:
        raise SetupError(
            f"isolation-aware mkdir {path} as {owner} failed "
            f"(rc={proc.returncode}): {proc.stderr.strip() or '(no stderr)'}"
        )


def _sudo_run_as(os_user: str, *cmd: str) -> subprocess.CompletedProcess[str]:
    # Mirror of bridge-hooks.py `_sudo_run_as` (#714 / #694 family);
    # captures stdout/stderr so callers (`_safe_read_env`) can parse
    # the output instead of just inspecting the rc.
    full = ["sudo", "-n", "-u", os_user, *cmd]
    try:
        return subprocess.run(full, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        # sudo missing — non-Linux dev hosts don't ship it. Mirror
        # bridge-hooks.py: emit a one-line warn and synthesize a
        # non-zero CompletedProcess so the caller surfaces the original
        # PermissionError shape rather than a confusing FileNotFoundError.
        print(
            f"[bridge-setup] sudo not available; cannot escalate to "
            f"'{os_user}' for {cmd}",
            file=sys.stderr,
        )
        return subprocess.CompletedProcess(args=full, returncode=127, stdout="", stderr="")


def _safe_path_check(check: str, path: Path, os_user: str | None) -> bool:
    """PermissionError-safe filesystem predicate for isolated plugin state.

    Mirror of bridge-hooks.py `_safe_path_check` (PR #718 r2). On
    isolated installs, `path.exists()` may raise PermissionError before
    `load_dotenv`/`load_json` ever run (e.g. when the plugin dir's
    parent is mode 0700 owned by the agent user, leaving the controller
    without `+x` traversal). When `os_user` is provided, proactively
    runs `sudo -n -u <agent-user> test -e/-h <path>` first so the
    controller never trips a PermissionError it could have skipped —
    even with v2 Track A (`_isolation_aware_mkdir` mode 2750 +
    `ab-agent-<a>` group, PR #1166) the controller may still not be a
    member of the per-agent group (#1170). Falls through to the direct
    pathlib check on sudo unavailability (rc 127 / FileNotFoundError /
    TimeoutExpired); on the direct path a final PermissionError is
    swallowed and reported as "absent" (fail-closed) so callers like
    `_safe_read_env` skip the read instead of bubbling a traceback up
    to `setup teams|telegram|discord`.

    Issue #1078 F3/F5: when the caller could not resolve `os_user`
    upfront (every lstat in the ancestor chain hit PermissionError),
    the walker fallback in the PermissionError branch climbs ancestors
    until one with a readable lstat reveals the isolated UID. The
    walker only fires when the proactive sudo path was skipped
    (os_user was None going in).
    """
    if os_user:
        flag = "-e" if check == "exists" else "-h"
        result = _sudo_run_as(os_user, "test", flag, str(path))
        if result.returncode == 0:
            return True
        if result.returncode == 1:
            # `test` rc=1 → path does not exist (authoritative answer
            # from inside the isolated UID). Do not fall through.
            return False
        # rc=127 (sudo missing) / any other rc → fall through to direct
        # pathlib check below.
    try:
        if check == "exists":
            return path.exists()
        if check == "is_symlink":
            return path.is_symlink()
    except PermissionError:
        if os_user is None:
            os_user = _resolve_isolated_owner_for_path(path)
            if os_user is not None:
                flag = "-e" if check == "exists" else "-h"
                result = _sudo_run_as(os_user, "test", flag, str(path))
                if result.returncode in (0, 1):
                    return result.returncode == 0
        # Controller blind to isolated tree and sudo unavailable. Fail
        # closed: caller treats path as absent and either skips the read
        # (`_safe_read_env`) or surfaces a clean recovery prompt instead
        # of a raw traceback (#1170).
        return False
    return False


def _safe_read_env(path: Path) -> dict[str, str]:
    """PermissionError-safe `load_dotenv` for isolated plugin `.env` files.

    On a linux-user-isolated install, `agents/<agent>/workdir/.teams/.env`
    (and equivalents for telegram/discord) is `agent-bridge-<slug>:agent-group
    0600`. `agent-bridge setup teams <agent>` runs as the controller and
    its inspect_*_dir → load_dotenv → path.read_text() raises
    PermissionError before the recovery flow can rewrite the file —
    the documented recovery primitive cannot run on a file that exists
    but is owner-only (#737 Q5).

    Strategy mirrors PR #718 family: try direct read first (covers
    non-isolated installs and macOS dev hosts), then fall back to
    `sudo -n -u <agent-user> cat <path>` and parse the captured stdout
    with the same dotenv schema as `load_dotenv`. The metadata probe
    (`exists`) is also wrapped because the parent dir may itself be
    0700 owned by the agent user. Returns `{}` when the path doesn't
    exist (matches `load_dotenv`); re-raises the original PermissionError
    when no isolated owner can be identified (non-Linux, non-isolated,
    or sudo unavailable) so the caller surfaces the same error shape it
    had before.

    Issue #1078 F3: when the entire chain — `.teams/.env`, `.teams/`,
    and the workdir itself — is 0700-owned by the isolated UID, a
    single-level `lstat(path)` / `lstat(path.parent)` raises
    PermissionError (caught) and returns None, so the controller falls
    through to the plain `path.exists()` in `_safe_path_check` and
    re-raises. Use the walker (`_resolve_isolated_owner_for_path`) which
    climbs ancestors until it finds an existing dir whose lstat
    succeeds — that node's owner is the same isolated UID by
    construction, so the sudo fallback can identify the right user.
    """
    os_user = (
        _isolated_workdir_owner(path)
        or _isolated_workdir_owner(path.parent)
        or _resolve_isolated_owner_for_path(path)
    )
    if not _safe_path_check("exists", path, os_user):
        return {}
    try:
        return load_dotenv(path)
    except PermissionError as exc:
        if os_user is None:
            raise
        result = _sudo_run_as(os_user, "cat", str(path))
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
        return _parse_dotenv_text(result.stdout)


def _safe_load_json(path: Path, default: Any) -> Any:
    """PermissionError-safe `load_json` for isolated plugin state files.

    Companion to `_safe_read_env` for `access.json` / `state.json` that
    live alongside the `.env` in the same isolated plugin dir. Falls
    back to `sudo -n -u <agent-user> cat` and `json.loads` when the
    direct read fails. Returns `default` for missing files (matches
    `load_json`) or when the sudo fallback succeeds but the body is
    not valid JSON (best-effort — recovery flow rebuilds the doc from
    operator input).

    Issue #1078 F5: same chain-of-0700 wedge as F3. The walker is the
    backstop when single-level lstats hit PermissionError.
    """
    os_user = (
        _isolated_workdir_owner(path)
        or _isolated_workdir_owner(path.parent)
        or _resolve_isolated_owner_for_path(path)
    )
    if not _safe_path_check("exists", path, os_user):
        return default
    try:
        return load_json(path, default)
    except PermissionError as exc:
        if os_user is None:
            raise
        result = _sudo_run_as(os_user, "cat", str(path))
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


def normalize_id_list(values: list[str] | tuple[str, ...] | None, label: str) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for raw in values or []:
        for chunk in re.split(r"[\s,]+", str(raw).strip()):
            if not chunk:
                continue
            if not re.fullmatch(r"\d{6,}", chunk):
                raise SetupError(f"{label} must be Discord snowflake IDs: {chunk}")
            if chunk in seen:
                continue
            seen.add(chunk)
            results.append(chunk)
    return results


def normalize_teams_id_list(values: list[str] | tuple[str, ...] | None, label: str) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for raw in values or []:
        for chunk in re.split(r"[\s,]+", str(raw).strip()):
            if not chunk:
                continue
            if not re.fullmatch(r"[A-Za-z0-9._:@-]{3,256}", chunk):
                raise SetupError(f"{label} must be Teams/AAD ids without whitespace: {chunk}")
            if chunk in seen:
                continue
            seen.add(chunk)
            results.append(chunk)
    return results


def normalize_mattermost_id_list(values: list[str] | tuple[str, ...] | None, label: str) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for raw in values or []:
        for chunk in re.split(r"[\s,]+", str(raw).strip()):
            if not chunk:
                continue
            if not re.fullmatch(r"[A-Za-z0-9._:@-]{3,256}", chunk):
                raise SetupError(f"{label} must be Mattermost ids without whitespace: {chunk}")
            if chunk in seen:
                continue
            seen.add(chunk)
            results.append(chunk)
    return results


def prompt_text(prompt: str, default: str = "", secret: bool = False) -> str:
    if default:
        prompt_text_value = f"{prompt} [{default}]: "
    else:
        prompt_text_value = f"{prompt}: "
    if secret:
        value = getpass.getpass(prompt_text_value)
    else:
        value = input(prompt_text_value)
    value = value.strip()
    if value:
        return value
    return default.strip()


def prompt_yes_no(prompt: str, default: bool) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    value = input(f"{prompt} {suffix}: ").strip().lower()
    if not value:
        return default
    return value in {"y", "yes"}


def inspect_discord_dir(discord_dir: Path) -> dict[str, Any]:
    env_path = discord_dir / ".env"
    access_path = discord_dir / "access.json"
    # #737 Q5: isolated agent's `.env` is `agent-bridge-<slug>:agent-group
    # 0600`; controller-side `load_dotenv` raises PermissionError before
    # `agent-bridge setup discord <agent>` can recover. `_safe_read_env`
    # / `_safe_load_json` fall back to `sudo -n -u <agent-user> cat` on
    # Linux isolated installs; no-op on non-Linux dev hosts.
    env = _safe_read_env(env_path)
    access_payload = _safe_load_json(access_path, {})
    groups = access_payload.get("groups") or {}
    channels = [str(channel_id) for channel_id in groups.keys() if str(channel_id).strip()]
    allow_from = normalize_id_list(access_payload.get("allowFrom") or [], "allow_from")
    require_values = []
    for channel_id in channels:
        entry = groups.get(channel_id) or {}
        require_values.append(bool(entry.get("requireMention", False)))
    require_mention = bool(require_values and all(require_values))
    return {
        "env_path": env_path,
        "access_path": access_path,
        "token": env.get("DISCORD_BOT_TOKEN", "").strip(),
        "channels": channels,
        "allow_from": allow_from,
        "require_mention": require_mention,
        "access_payload": access_payload if isinstance(access_payload, dict) else {},
    }


def load_channel_accounts(config_path: Path, kind: str) -> dict[str, dict[str, Any]]:
    payload = load_json(config_path, {})
    channels = payload.get("channels") or {}
    channel_cfg = channels.get(kind) or {}
    accounts = channel_cfg.get("accounts") or {}
    if not isinstance(accounts, dict):
        return {}
    return {str(name): cfg for name, cfg in accounts.items() if isinstance(cfg, dict)}


def extract_token_from_text(text: str, kind: str) -> str:
    stripped = text.strip()
    if not stripped:
        return ""

    if kind == "telegram":
        keys = ("TELEGRAM_BOT_TOKEN", "BOT_TOKEN", "TOKEN")
    elif kind == "discord":
        keys = ("DISCORD_BOT_TOKEN", "BOT_TOKEN", "TOKEN")
    else:
        keys = ("TOKEN",)

    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    for key in keys:
        prefix = f"{key}="
        for line in lines:
            if line.startswith(prefix):
                return line.split("=", 1)[1].strip().strip("'").strip('"')

    if len(lines) == 1 and "=" not in lines[0]:
        return lines[0]

    return ""


def load_account_token(config_path: Path, kind: str, account: str) -> str:
    accounts = load_channel_accounts(config_path, kind)
    account_cfg = accounts.get(account)
    if not account_cfg:
        raise SetupError(f"Configured {kind} account not found: {account}")
    token = str(account_cfg.get("token") or "").strip()
    if token:
        return token
    token_file = str(account_cfg.get("tokenFile") or "").strip()
    if token_file:
        token_path = Path(token_file).expanduser()
        if token_path.exists():
            token = extract_token_from_text(token_path.read_text(encoding="utf-8"), kind)
            if token:
                return token
    raise SetupError(f"Configured {kind} account token is empty: {account}")


def load_claude_plugin_channel_token(kind: str) -> str:
    channels_home = Path(
        os.environ.get("BRIDGE_CLAUDE_CHANNELS_HOME", str(Path.home() / ".claude" / "channels"))
    ).expanduser()
    env_path = channels_home / kind / ".env"
    if not env_path.exists():
        return ""
    return extract_token_from_text(env_path.read_text(encoding="utf-8"), kind)


def read_secret_value(flag_value: str, flag_name: str, file_path: str, env_name: str) -> str:
    """Resolve a channel secret without requiring it on the command line.

    Precedence: a `--<name>-file <path>` (a path is safe to pass in argv) wins,
    then the env var, then the legacy `--<name> <secret>` flag. Passing the
    secret as a bare argv value still works for compatibility but emits a
    one-line warning, since it then lands in shell history and the process
    table (`ps`, `/proc/<pid>/cmdline`).
    """
    if file_path:
        path = Path(file_path).expanduser()
        if not path.is_file():
            raise SetupError(f"Secret file not found: {file_path}")
        return path.read_text(encoding="utf-8").strip()
    env_value = os.environ.get(env_name, "").strip()
    if env_value:
        return env_value
    flag_value = str(flag_value or "").strip()
    if flag_value:
        print(
            f"[warn] {flag_name} exposes the secret in shell history and process "
            f"argv; prefer {flag_name}-file <path> or the {env_name} env var.",
            file=sys.stderr,
        )
    return flag_value


def candidate_channel_accounts(agent: str, accounts: dict[str, dict[str, Any]]) -> list[str]:
    candidates = [agent]
    if "-" in agent:
        candidates.append(agent.rsplit("-", 1)[-1])
    candidates.append("default")

    ordered: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        candidate = str(candidate).strip()
        if not candidate or candidate in seen:
            continue
        if candidate in accounts:
            seen.add(candidate)
            ordered.append(candidate)
    return ordered


def inspect_telegram_dir(telegram_dir: Path) -> dict[str, Any]:
    env_path = telegram_dir / ".env"
    access_path = telegram_dir / "access.json"
    # #737 Q5: see inspect_discord_dir.
    env = _safe_read_env(env_path)
    access_payload = _safe_load_json(access_path, {})
    allow_from = normalize_id_list(access_payload.get("allowFrom") or [], "allow_from")
    default_chat = str(access_payload.get("defaultChatId") or "").strip()
    return {
        "env_path": env_path,
        "access_path": access_path,
        "token": env.get("TELEGRAM_BOT_TOKEN", "").strip(),
        "allow_from": allow_from,
        "default_chat": default_chat,
        "access_payload": access_payload if isinstance(access_payload, dict) else {},
    }


def inspect_teams_dir(teams_dir: Path) -> dict[str, Any]:
    env_path = teams_dir / ".env"
    access_path = teams_dir / "access.json"
    state_path = teams_dir / "state.json"
    # #737 Q5: see inspect_discord_dir. This is the path called out in
    # the issue body — `bridge-setup.py:inspect_teams_dir → load_dotenv`
    # was the first observed PermissionError on the documented recovery
    # primitive (`agent-bridge setup teams <agent>`).
    env = _safe_read_env(env_path)
    access_payload = _safe_load_json(access_path, {})
    state_payload = _safe_load_json(state_path, {})
    groups = access_payload.get("groups") or {}
    conversations = [str(key) for key in groups.keys() if str(key).strip()]
    allow_from = normalize_teams_id_list(access_payload.get("allowFrom") or [], "allow_from")
    require_values = []
    for conversation_id in conversations:
        entry = groups.get(conversation_id) or {}
        require_values.append(bool(entry.get("requireMention", False)))
    require_mention = bool(require_values and all(require_values))
    return {
        "env_path": env_path,
        "access_path": access_path,
        "state_path": state_path,
        "app_id": env.get("TEAMS_APP_ID", "").strip(),
        "app_password": env.get("TEAMS_APP_PASSWORD", "").strip(),
        "tenant_id": env.get("TEAMS_TENANT_ID", "").strip(),
        "service_url": env.get("TEAMS_SERVICE_URL", "").strip(),
        "webhook_host": env.get("TEAMS_WEBHOOK_HOST", "").strip(),
        "webhook_port": env.get("TEAMS_WEBHOOK_PORT", "").strip(),
        "conversations": conversations,
        "allow_from": allow_from,
        "require_mention": require_mention,
        "access_payload": access_payload if isinstance(access_payload, dict) else {},
        "state_payload": state_payload if isinstance(state_payload, dict) else {},
    }


def teams_login_base_url() -> str:
    return os.environ.get("BRIDGE_TEAMS_LOGIN_BASE_URL", "https://login.microsoftonline.com").rstrip("/")


def teams_validation_scope() -> str:
    return os.environ.get("BRIDGE_TEAMS_VALIDATION_SCOPE", "https://api.botframework.com/.default").strip()


def validate_teams_credentials(app_id: str, app_password: str, tenant_id: str) -> dict[str, Any]:
    tenant = tenant_id.strip()
    if not tenant:
        return {
            "status": "skipped",
            "reason": "tenant_id_unset",
        }

    scope = teams_validation_scope()
    token_url = f"{teams_login_base_url()}/{tenant}/oauth2/v2.0/token"
    body = urlencode(
        {
            "client_id": app_id,
            "client_secret": app_password,
            "grant_type": "client_credentials",
            "scope": scope,
        }
    ).encode("utf-8")
    request = Request(
        token_url,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "agent-bridge-setup/0.1",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8") or "{}")
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(details)
        except json.JSONDecodeError:
            parsed = {}
        error_detail = str(parsed.get("error_description") or parsed.get("error") or details).strip()
        raise SetupError(f"Teams credential validation failed: HTTP {exc.code}: {error_detail}") from exc
    except URLError as exc:
        raise SetupError(f"Teams credential validation failed: {exc.reason}") from exc

    access_token = str(payload.get("access_token") or "").strip()
    if not access_token:
        raise SetupError("Teams credential validation failed: token endpoint returned no access_token")

    return {
        "status": "ok",
        "tenant_id": tenant,
        "token_endpoint": token_url,
        "scope": scope,
        "expires_in": int(payload.get("expires_in") or 0),
    }


def probe_teams_messaging_endpoint(url: str) -> dict[str, Any]:
    endpoint = str(url or "").strip()
    if not endpoint:
        return {"status": "skipped"}

    request = Request(
        endpoint,
        data=b"{}",
        headers={
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-setup/0.1",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=10) as response:
            status_code = int(response.getcode() or 0)
            body = response.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        status_code = int(exc.code or 0)
        body = exc.read().decode("utf-8", errors="replace")
    except URLError as exc:
        return {
            "status": "unreachable",
            "detail": str(exc.reason),
        }

    if 200 <= status_code < 300:
        status = "ok"
    elif status_code in {401, 403, 404, 405, 500}:
        status = "backend_reached"
    elif status_code in {502, 503, 504}:
        status = "gateway_upstream_unreachable"
    else:
        status = f"http_{status_code}"

    return {
        "status": status,
        "http_status": status_code,
        "detail": body.strip()[:240],
    }


def summarize_teams_validation(
    credentials: dict[str, Any],
    endpoint_probe: dict[str, Any],
) -> str:
    credential_status = str(credentials.get("status") or "skipped")
    probe_status = str(endpoint_probe.get("status") or "skipped")

    if credential_status == "ok" and probe_status in {"ok", "backend_reached", "skipped"}:
        return "ok"
    if credential_status == "ok" and probe_status == "gateway_upstream_unreachable":
        return "warning"
    if credential_status == "ok" and probe_status == "unreachable":
        return "warning"
    if credential_status == "skipped" and probe_status in {"ok", "backend_reached"}:
        return "probe_only"
    if credential_status == "skipped" and probe_status == "skipped":
        return "local"
    return "warning"


def http_json(token: str, url: str, method: str = "GET", payload: dict[str, Any] | None = None) -> Any:
    body = None
    headers = {
        "Authorization": f"Bot {token}",
        "User-Agent": "agent-bridge-setup/0.1",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(request, timeout=15) as response:
            data = response.read().decode("utf-8")
            if not data:
                return {}
            return json.loads(data)
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SetupError(f"Discord API {method} {url} failed: HTTP {exc.code}: {details}") from exc
    except URLError as exc:
        raise SetupError(f"Discord API {method} {url} failed: {exc.reason}") from exc


def validate_discord(token: str, channels: list[str], api_base_url: str, send_test: bool, agent: str) -> dict[str, Any]:
    api_base = api_base_url.rstrip("/")
    bot = http_json(token, f"{api_base}/users/@me")
    channel_results = []

    for channel_id in channels:
        channel_info = http_json(token, f"{api_base}/channels/{channel_id}")
        result = {
            "id": channel_id,
            "name": str(channel_info.get("name") or channel_info.get("id") or channel_id),
            "read": "ok",
            "send": "skipped",
        }
        if send_test:
            payload = {
                "content": (
                    f"[Agent Bridge setup] {agent} write access check. "
                    "Safe to ignore."
                )
            }
            response = http_json(token, f"{api_base}/channels/{channel_id}/messages", method="POST", payload=payload)
            result["send"] = "ok"
            result["message_id"] = str(response.get("id") or "")
        channel_results.append(result)

    return {
        "status": "ok",
        "bot": {
            "id": str(bot.get("id") or ""),
            "username": str(bot.get("username") or ""),
        },
        "channels": channel_results,
    }


def http_telegram_json(token: str, api_base_url: str, method: str, payload: dict[str, Any] | None = None) -> Any:
    body = None
    headers = {
        "User-Agent": "agent-bridge-setup/0.1",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    base = api_base_url.rstrip("/")
    request = Request(
        f"{base}/bot{token}/{method}",
        data=body,
        headers=headers,
        method="POST" if payload is not None else "GET",
    )
    try:
        with urlopen(request, timeout=15) as response:
            data = response.read().decode("utf-8")
            if not data:
                return {}
            payload = json.loads(data)
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SetupError(f"Telegram API {method} failed: HTTP {exc.code}: {details}") from exc
    except URLError as exc:
        raise SetupError(f"Telegram API {method} failed: {exc.reason}") from exc

    if not payload.get("ok", False):
        raise SetupError(f"Telegram API {method} failed: {payload}")
    return payload.get("result") or {}


def validate_telegram(
    token: str,
    api_base_url: str,
    send_test: bool,
    agent: str,
    test_chat_id: str,
) -> dict[str, Any]:
    bot = http_telegram_json(token, api_base_url, "getMe")
    result: dict[str, Any] = {
        "status": "ok",
        "bot": {
            "id": str(bot.get("id") or ""),
            "username": str(bot.get("username") or ""),
        },
        "send": "skipped",
        "test_chat_id": test_chat_id,
    }
    if send_test and test_chat_id:
        response = http_telegram_json(
            token,
            api_base_url,
            "sendMessage",
            {
                "chat_id": test_chat_id,
                "text": f"[Agent Bridge setup] {agent} write access check. Safe to ignore.",
                "disable_web_page_preview": True,
            },
        )
        result["send"] = "ok"
        result["message_id"] = str(response.get("message_id") or "")
    return result


def build_access_payload(existing: dict[str, Any], channels: list[str], allow_from: list[str], require_mention: bool) -> dict[str, Any]:
    payload = dict(existing)
    old_groups = payload.get("groups") or {}
    groups: dict[str, Any] = {}
    for channel_id in channels:
        old_entry = old_groups.get(channel_id) or {}
        preserved_allow_from = normalize_id_list(old_entry.get("allowFrom") or [], "group allow_from")
        groups[channel_id] = {
            "requireMention": require_mention,
            "allowFrom": preserved_allow_from,
        }

    pending = payload.get("pending")
    if not isinstance(pending, dict):
        pending = {}

    payload["dmPolicy"] = "allowlist"
    payload["allowFrom"] = allow_from
    payload["groups"] = groups
    payload["pending"] = pending
    return payload


def print_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"discord_dir: {result['discord_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    print(f"access_file: {result['access_file']}", file=stream)
    print(f"token_source: {result['token_source']}", file=stream)
    print(f"channels: {', '.join(result['channels'])}", file=stream)
    if result["allow_from"]:
        print(f"allow_from: {', '.join(result['allow_from'])}", file=stream)
    else:
        print("allow_from: (none)", file=stream)
    print(f"require_mention: {'yes' if result['require_mention'] else 'no'}", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)

    validation = result.get("validation") or {}
    print(f"validation: {validation.get('status', 'skipped')}", file=stream)
    if validation.get("bot"):
        bot = validation["bot"]
        print(f"bot: {bot.get('username', '')} ({bot.get('id', '')})", file=stream)
    for channel in validation.get("channels") or []:
        line = f"channel {channel['id']}: read={channel.get('read', '-')}"
        send_status = channel.get("send")
        if send_status:
            line += f" send={send_status}"
        print(line, file=stream)

    for warning in result.get("warnings") or []:
        print(f"warning: {warning}", file=stream)

    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def print_telegram_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"telegram_dir: {result['telegram_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    print(f"access_file: {result['access_file']}", file=stream)
    print(f"token_source: {result['token_source']}", file=stream)
    if result["allow_from"]:
        print(f"allow_from: {', '.join(result['allow_from'])}", file=stream)
    else:
        print("allow_from: (none)", file=stream)
    if result["default_chat"]:
        print(f"default_chat: {result['default_chat']}", file=stream)
    else:
        print("default_chat: (unset)", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)

    validation = result.get("validation") or {}
    print(f"validation: {validation.get('status', 'skipped')}", file=stream)
    if validation.get("bot"):
        bot = validation["bot"]
        print(f"bot: {bot.get('username', '')} ({bot.get('id', '')})", file=stream)
    if validation.get("test_chat_id"):
        print(f"test_chat_id: {validation['test_chat_id']}", file=stream)
    if validation.get("send"):
        print(f"send: {validation['send']}", file=stream)

    for warning in result.get("warnings") or []:
        print(f"warning: {warning}", file=stream)

    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def print_teams_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"teams_dir: {result['teams_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    print(f"access_file: {result['access_file']}", file=stream)
    print(f"state_file: {result['state_file']}", file=stream)
    print(f"credential_source: {result['credential_source']}", file=stream)
    print(f"webhook_host: {result['webhook_host']}", file=stream)
    print(f"webhook_port: {result['webhook_port']}", file=stream)
    if result["ingress_port"]:
        print(f"ingress_port: {result['ingress_port']}", file=stream)
    else:
        print("ingress_port: (unset)", file=stream)
    if result["messaging_endpoint"]:
        print(f"messaging_endpoint: {result['messaging_endpoint']}", file=stream)
    else:
        print("messaging_endpoint: (unset)", file=stream)
    if result["allow_from"]:
        print(f"allow_from: {', '.join(result['allow_from'])}", file=stream)
    else:
        print("allow_from: (none)", file=stream)
    if result["conversations"]:
        print(f"conversations: {', '.join(result['conversations'])}", file=stream)
    else:
        print("conversations: (none)", file=stream)
    print(f"require_mention: {'yes' if result['require_mention'] else 'no'}", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)
    validation = result.get("validation") or {}
    print(f"validation: {validation.get('status', 'skipped')}", file=stream)
    credentials = validation.get("credentials") or {}
    print(f"credential_validation: {credentials.get('status', 'skipped')}", file=stream)
    if credentials.get("token_endpoint"):
        print(f"token_endpoint: {credentials['token_endpoint']}", file=stream)
    probe = validation.get("endpoint_probe") or {}
    print(f"endpoint_probe: {probe.get('status', 'skipped')}", file=stream)
    if probe.get("http_status"):
        print(f"endpoint_http_status: {probe['http_status']}", file=stream)
    for warning in result.get("warnings") or []:
        print(f"warning: {warning}", file=stream)
    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def cmd_discord(args: argparse.Namespace) -> int:
    discord_dir = Path(args.discord_dir).expanduser()
    inspected = inspect_discord_dir(discord_dir)
    access_payload = inspected["access_payload"]
    warnings: list[str] = []
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and not args.yes

    result: dict[str, Any] = {
        "agent": args.agent,
        "discord_dir": str(discord_dir),
        "env_file": str(inspected["env_path"]),
        "access_file": str(inspected["access_path"]),
        "token_source": "",
        "channels": [],
        "allow_from": [],
        "require_mention": False,
        "write_status": "pending",
        "validation": {"status": "skipped", "channels": []},
        "warnings": warnings,
    }

    try:
        accounts = load_channel_accounts(Path(args.runtime_config), "discord") if args.runtime_config else {}
        token = str(args.token or "").strip()
        token_source = ""
        if token:
            token_source = "flag"
        elif args.channel_account:
            token = load_account_token(Path(args.runtime_config), "discord", args.channel_account)
            token_source = f"channel:{args.channel_account}"
        elif inspected["token"]:
            token = inspected["token"]
            token_source = "existing:.discord/.env"
        elif accounts:
            candidates = candidate_channel_accounts(args.agent, accounts)
            if candidates and not interactive:
                choice = candidates[0]
                token = load_account_token(Path(args.runtime_config), "discord", choice)
                token_source = f"channel:{choice}"
            elif interactive and candidates:
                default_account = candidates[0]
                choice = prompt_text(
                    "Discord channel account to import (enter 'skip' to paste manually)",
                    default_account,
                )
                if choice.lower() not in {"skip", "none", "manual"}:
                    token = load_account_token(Path(args.runtime_config), "discord", choice)
                    token_source = f"channel:{choice}"
        elif not token:
            token = load_claude_plugin_channel_token("discord")
            if token:
                token_source = "claude-plugin:.claude/channels/discord/.env"

        if not token and interactive:
            token = prompt_text("Discord bot token", secret=True)
            token_source = "prompt"
        if not token:
            raise SetupError("Discord bot token is required. Pass --token or --channel-account, or run in an interactive TTY.")

        explicit_channels = normalize_id_list(args.channel or [], "channel ids")
        default_channels = explicit_channels or inspected["channels"]
        if not default_channels and args.suggested_channel:
            default_channels = normalize_id_list([args.suggested_channel], "suggested channel id")
        if interactive and not explicit_channels:
            default_csv = ",".join(default_channels)
            raw_channels = prompt_text("Discord channel id(s), comma-separated", default_csv)
            channels = normalize_id_list([raw_channels], "channel ids")
        else:
            channels = default_channels
        if not channels:
            raise SetupError("At least one Discord channel id is required. Pass --channel or set BRIDGE_AGENT_DISCORD_CHANNEL_ID for the agent.")

        explicit_allow_from = normalize_id_list(args.allow_from or [], "allow_from")
        if interactive and not explicit_allow_from:
            default_allow_csv = ",".join(inspected["allow_from"])
            raw_allow_from = prompt_text("Optional DM allowFrom user id(s), comma-separated", default_allow_csv)
            allow_from = normalize_id_list([raw_allow_from], "allow_from")
        else:
            allow_from = explicit_allow_from or inspected["allow_from"]

        require_mention = bool(args.require_mention or inspected["require_mention"])
        send_test = not args.skip_send_test
        if interactive and not args.skip_validate and not args.skip_send_test:
            send_test = prompt_yes_no("Send a Discord write-access test message now?", True)

        if not args.suggested_channel:
            warnings.append(
                f"BRIDGE_AGENT_DISCORD_CHANNEL_ID is unset for {args.agent}. "
                f"Add BRIDGE_AGENT_DISCORD_CHANNEL_ID[\"{args.agent}\"]=\"{channels[0]}\" to agent-roster.local.sh for wake relay metadata."
            )
        elif args.suggested_channel not in channels:
            warnings.append(
                f"Roster primary Discord channel ({args.suggested_channel}) is not in the configured access.json allowlist. "
                f"Update the roster or include that channel here."
            )

        result["token_source"] = token_source or "existing:.discord/.env"
        result["channels"] = channels
        result["allow_from"] = allow_from
        result["require_mention"] = require_mention

        access_doc = build_access_payload(access_payload, channels, allow_from, require_mention)

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["validation"] = {"status": "dry_run", "channels": []}
            print_result(result)
            return 0

        _isolation_aware_mkdir(discord_dir, agent=args.agent)
        _isolation_aware_save_text(inspected["env_path"], f"DISCORD_BOT_TOKEN={token}\n")
        _isolation_aware_save_json(inspected["access_path"], access_doc)
        result["write_status"] = "ok"

        if args.skip_validate:
            result["validation"] = {"status": "skipped", "channels": []}
            print_result(result)
            return 0

        validation = validate_discord(token, channels, args.api_base_url, send_test, args.agent)
        result["validation"] = validation
        print_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        if result["token_source"] == "":
            result["token_source"] = "(unset)"
        print_result(result, stream=sys.stderr)
        return 1


def cmd_telegram(args: argparse.Namespace) -> int:
    telegram_dir = Path(args.telegram_dir).expanduser()
    inspected = inspect_telegram_dir(telegram_dir)
    access_payload = inspected["access_payload"]
    warnings: list[str] = []
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and not args.yes

    result: dict[str, Any] = {
        "agent": args.agent,
        "telegram_dir": str(telegram_dir),
        "env_file": str(inspected["env_path"]),
        "access_file": str(inspected["access_path"]),
        "token_source": "",
        "allow_from": [],
        "default_chat": "",
        "write_status": "pending",
        "validation": {"status": "skipped"},
        "warnings": warnings,
    }

    try:
        accounts = load_channel_accounts(Path(args.runtime_config), "telegram") if args.runtime_config else {}
        token = str(args.token or "").strip()
        token_source = ""
        if token:
            token_source = "flag"
        elif args.channel_account:
            token = load_account_token(Path(args.runtime_config), "telegram", args.channel_account)
            token_source = f"channel:{args.channel_account}"
        elif inspected["token"]:
            token = inspected["token"]
            token_source = "existing:.telegram/.env"
        elif accounts:
            candidates = candidate_channel_accounts(args.agent, accounts)
            if candidates and not interactive:
                choice = candidates[0]
                token = load_account_token(Path(args.runtime_config), "telegram", choice)
                token_source = f"channel:{choice}"
            elif interactive and candidates:
                default_account = candidates[0]
                choice = prompt_text(
                    "Configured Telegram channel account to import (enter 'skip' to paste manually)",
                    default_account,
                )
                if choice.lower() not in {"skip", "none", "manual"}:
                    token = load_account_token(Path(args.runtime_config), "telegram", choice)
                    token_source = f"channel:{choice}"
        elif not token:
            token = load_claude_plugin_channel_token("telegram")
            if token:
                token_source = "claude-plugin:.claude/channels/telegram/.env"

        if not token and interactive:
            token = prompt_text("Telegram bot token", secret=True)
            token_source = "prompt"
        if not token:
            raise SetupError("Telegram bot token is required. Pass --token or --channel-account, or run in an interactive TTY.")

        explicit_allow_from = normalize_id_list(args.allow_from or [], "allow_from")
        if interactive and not explicit_allow_from:
            default_allow_csv = ",".join(inspected["allow_from"])
            raw_allow_from = prompt_text("Allowed Telegram user/chat id(s), comma-separated", default_allow_csv)
            allow_from = normalize_id_list([raw_allow_from], "allow_from")
        else:
            allow_from = explicit_allow_from or inspected["allow_from"]

        default_chat = str(args.default_chat or inspected["default_chat"]).strip()
        if interactive and not args.default_chat:
            default_chat = prompt_text("Default Telegram chat id for test messages / notify target (optional)", default_chat)

        test_chat_id = str(args.test_chat or default_chat or (allow_from[0] if allow_from else "")).strip()
        send_test = not args.skip_send_test and bool(test_chat_id)
        if interactive and not args.skip_validate and test_chat_id:
            send_test = prompt_yes_no("Send a Telegram write-access test message now?", True)
        if not allow_from:
            warnings.append(
                f"No Telegram allow_from ids configured for {args.agent}. Update {telegram_dir / 'access.json'} so the plugin can accept messages from intended users."
            )
        if not default_chat:
            warnings.append(
                f"No default Telegram chat id configured for {args.agent}. Set --default-chat if you want a stable notify/test target."
            )

        result["token_source"] = token_source or "existing:.telegram/.env"
        result["allow_from"] = allow_from
        result["default_chat"] = default_chat

        access_doc = dict(access_payload)
        access_doc["dmPolicy"] = "allowlist"
        access_doc["allowFrom"] = allow_from
        if default_chat:
            access_doc["defaultChatId"] = default_chat
        elif "defaultChatId" in access_doc:
            access_doc.pop("defaultChatId", None)
        pending = access_doc.get("pending")
        if not isinstance(pending, dict):
            access_doc["pending"] = {}

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["validation"] = {"status": "dry_run"}
            print_telegram_result(result)
            return 0

        _isolation_aware_mkdir(telegram_dir, agent=args.agent)
        _isolation_aware_save_text(inspected["env_path"], f"TELEGRAM_BOT_TOKEN={token}\n")
        _isolation_aware_save_json(inspected["access_path"], access_doc)
        result["write_status"] = "ok"

        if args.skip_validate:
            result["validation"] = {"status": "skipped"}
            print_telegram_result(result)
            return 0

        validation = validate_telegram(token, args.api_base_url, send_test, args.agent, test_chat_id)
        result["validation"] = validation
        print_telegram_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        if result["token_source"] == "":
            result["token_source"] = "(unset)"
        print_telegram_result(result, stream=sys.stderr)
        return 1


def cmd_teams(args: argparse.Namespace) -> int:
    teams_dir = Path(args.teams_dir).expanduser()
    inspected = inspect_teams_dir(teams_dir)
    access_payload = inspected["access_payload"]
    state_payload = inspected["state_payload"]
    warnings: list[str] = []
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and not args.yes

    result: dict[str, Any] = {
        "agent": args.agent,
        "teams_dir": str(teams_dir),
        "env_file": str(inspected["env_path"]),
        "access_file": str(inspected["access_path"]),
        "state_file": str(inspected["state_path"]),
        "credential_source": "",
        "webhook_host": "",
        "webhook_port": "",
        "ingress_port": "",
        "messaging_endpoint": "",
        "allow_from": [],
        "conversations": [],
        "require_mention": False,
        "write_status": "pending",
        "validation": {"status": "skipped"},
        "warnings": warnings,
    }

    try:
        accounts = load_channel_accounts(Path(args.runtime_config), "teams") if args.runtime_config else {}
        account_cfg: dict[str, Any] = {}
        credential_source = ""
        if args.channel_account:
            account_cfg = accounts.get(args.channel_account) or {}
            if not account_cfg:
                raise SetupError(f"Configured teams account not found: {args.channel_account}")
            credential_source = f"channel:{args.channel_account}"
        elif accounts:
            candidates = candidate_channel_accounts(args.agent, accounts)
            if candidates and not interactive:
                choice = candidates[0]
                account_cfg = accounts.get(choice) or {}
                credential_source = f"channel:{choice}"
            elif interactive and candidates:
                default_account = candidates[0]
                choice = prompt_text(
                    "Configured Teams channel account to import (enter 'skip' to paste manually)",
                    default_account,
                )
                if choice.lower() not in {"skip", "none", "manual"}:
                    account_cfg = accounts.get(choice) or {}
                    if not account_cfg:
                        raise SetupError(f"Configured teams account not found: {choice}")
                    credential_source = f"channel:{choice}"

        app_id = str(args.app_id or account_cfg.get("appId") or account_cfg.get("app_id") or inspected["app_id"]).strip()
        app_password_arg = read_secret_value(
            flag_value=args.app_password,
            flag_name="--app-password",
            file_path=args.app_password_file,
            env_name="BRIDGE_TEAMS_APP_PASSWORD",
        )
        app_password = str(
            app_password_arg
            or account_cfg.get("appPassword")
            or account_cfg.get("app_password")
            or account_cfg.get("clientSecret")
            or account_cfg.get("client_secret")
            or inspected["app_password"]
        ).strip()
        tenant_id = str(args.tenant_id or account_cfg.get("tenantId") or account_cfg.get("tenant_id") or inspected["tenant_id"]).strip()
        service_url = str(args.service_url or account_cfg.get("serviceUrl") or account_cfg.get("service_url") or inspected["service_url"]).strip()
        webhook_host = str(args.webhook_host or inspected["webhook_host"] or "127.0.0.1").strip()
        if args.webhook_port:
            webhook_port = str(args.webhook_port).strip()
        elif inspected["webhook_port"]:
            webhook_port = str(inspected["webhook_port"]).strip()
        else:
            webhook_port = str(allocate_channel_port(args.agent, "teams"))
        ingress_port = str(args.ingress_port or "").strip()
        messaging_endpoint = str(args.messaging_endpoint or "").strip()

        if not credential_source:
            if args.app_id or app_password_arg or args.tenant_id:
                credential_source = "flag"
            elif inspected["app_id"] or inspected["app_password"]:
                credential_source = "existing:.teams/.env"

        if not app_id and interactive:
            app_id = prompt_text("Teams Azure Bot Application ID", inspected["app_id"])
            credential_source = credential_source or "prompt"
        if not app_password and interactive:
            app_password = prompt_text("Teams Azure Bot client secret", secret=True)
            credential_source = credential_source or "prompt"
        if not tenant_id and interactive:
            tenant_id = prompt_text("Teams Azure tenant ID", inspected["tenant_id"])
            credential_source = credential_source or "prompt"
        if not service_url and interactive:
            service_url = prompt_text("Optional Teams service URL for proactive replies", inspected["service_url"])
        if interactive and not args.webhook_host and not inspected["webhook_host"]:
            webhook_host = prompt_text("Webhook listen host", webhook_host)
        if interactive and not args.webhook_port and not inspected["webhook_port"]:
            webhook_port = prompt_text("Webhook listen port", webhook_port)
        if interactive and not args.messaging_endpoint:
            messaging_endpoint = prompt_text("Optional public messaging endpoint URL", messaging_endpoint)
        if interactive and not args.ingress_port:
            ingress_port = prompt_text("Optional reverse proxy/backend target port", ingress_port)

        if not app_id or not app_password:
            raise SetupError("Teams app id and app password are required. Pass --app-id and one of --app-password-file/BRIDGE_TEAMS_APP_PASSWORD/--app-password, or --channel-account, or run in an interactive TTY.")
        if not re.fullmatch(r"\d{2,5}", webhook_port):
            raise SetupError(f"Webhook port must be a TCP port number: {webhook_port}")
        if ingress_port and not re.fullmatch(r"\d{2,5}", ingress_port):
            raise SetupError(f"Ingress port must be a TCP port number: {ingress_port}")
        if messaging_endpoint:
            parsed_endpoint = urlparse(messaging_endpoint)
            if parsed_endpoint.scheme not in {"http", "https"} or not parsed_endpoint.netloc:
                raise SetupError(f"Messaging endpoint must be a full http(s) URL: {messaging_endpoint}")

        explicit_allow_from = normalize_teams_id_list(args.allow_from or [], "allow_from")
        if interactive and not explicit_allow_from:
            default_allow_csv = ",".join(inspected["allow_from"])
            raw_allow_from = prompt_text("Allowed Teams AAD object/user id(s), comma-separated", default_allow_csv)
            allow_from = normalize_teams_id_list([raw_allow_from], "allow_from")
        else:
            allow_from = explicit_allow_from or inspected["allow_from"]

        explicit_conversations = normalize_teams_id_list(args.conversation or [], "conversation ids")
        if interactive and not explicit_conversations:
            default_conversation_csv = ",".join(inspected["conversations"])
            raw_conversations = prompt_text("Optional Teams conversation/channel id(s), comma-separated", default_conversation_csv)
            conversations = normalize_teams_id_list([raw_conversations], "conversation ids")
        else:
            conversations = explicit_conversations or inspected["conversations"]

        require_mention = bool(args.require_mention or inspected["require_mention"])
        if not allow_from and not conversations:
            warnings.append(
                f"No Teams allow_from ids or conversations configured for {args.agent}. The plugin will reject inbound messages until access.json is updated."
            )
        if not tenant_id:
            warnings.append("TEAMS_TENANT_ID is unset. Single-tenant Azure Bot deployments should set --tenant-id.")

        result["credential_source"] = credential_source or "existing:.teams/.env"
        result["webhook_host"] = webhook_host
        result["webhook_port"] = webhook_port
        result["ingress_port"] = ingress_port
        result["messaging_endpoint"] = messaging_endpoint
        result["allow_from"] = allow_from
        result["conversations"] = conversations
        result["require_mention"] = require_mention

        access_doc = dict(access_payload)
        access_doc["dmPolicy"] = "allowlist"
        access_doc["allowFrom"] = allow_from
        old_groups = access_doc.get("groups") or {}
        groups: dict[str, Any] = {}
        for conversation_id in conversations:
            old_entry = old_groups.get(conversation_id) or {}
            preserved_allow = normalize_teams_id_list(old_entry.get("allowFrom") or [], "group allow_from")
            groups[conversation_id] = {
                "requireMention": require_mention,
                "allowFrom": preserved_allow,
            }
        access_doc["groups"] = groups
        if not isinstance(access_doc.get("pending"), dict):
            access_doc["pending"] = {}
        if not isinstance(access_doc.get("routes"), dict):
            access_doc["routes"] = {}

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["validation"] = {"status": "dry_run"}
            print_teams_result(result)
            return 0

        _isolation_aware_mkdir(teams_dir, agent=args.agent)
        env_lines = [
            f"TEAMS_APP_ID={app_id}",
            f"TEAMS_APP_PASSWORD={app_password}",
            f"TEAMS_WEBHOOK_HOST={webhook_host}",
            f"TEAMS_WEBHOOK_PORT={webhook_port}",
        ]
        if tenant_id:
            env_lines.append(f"TEAMS_TENANT_ID={tenant_id}")
        if service_url:
            env_lines.append(f"TEAMS_SERVICE_URL={service_url}")
        _isolation_aware_save_text(inspected["env_path"], "\n".join(env_lines) + "\n")
        _isolation_aware_save_json(inspected["access_path"], access_doc)
        credential_validation = {"status": "skipped"}
        if not args.skip_validate:
            credential_validation = validate_teams_credentials(app_id, app_password, tenant_id)

        endpoint_probe = {"status": "skipped"}
        if messaging_endpoint and not args.skip_send_test:
            endpoint_probe = probe_teams_messaging_endpoint(messaging_endpoint)

        if webhook_host in {"127.0.0.1", "localhost"} and messaging_endpoint:
            warnings.append(
                "Webhook is listening on loopback only. External reverse proxies will not reach the plugin until TEAMS_WEBHOOK_HOST is set to 0.0.0.0 or another non-loopback interface."
            )
        if ingress_port and ingress_port != webhook_port:
            warnings.append(
                f"Reverse proxy target port {ingress_port} does not match Teams webhook port {webhook_port}. If your proxy cannot target {webhook_port} directly, add an iptables redirect such as: sudo iptables -t nat -I PREROUTING -p tcp --dport {ingress_port} -j REDIRECT --to-ports {webhook_port}"
            )
        if messaging_endpoint and endpoint_probe.get("status") == "unreachable":
            warnings.append(
                "Messaging endpoint did not respond. Check DNS, TLS, and reverse proxy reachability before restarting the agent."
            )
        if endpoint_probe.get("status") == "gateway_upstream_unreachable":
            warnings.append(
                "Messaging endpoint returned 502/503/504. The public proxy is up, but the backend listener or port mapping is not. Check TEAMS_WEBHOOK_HOST/PORT and any ALB/nginx/iptables wiring."
            )
        if endpoint_probe.get("status") == "backend_reached":
            warnings.append(
                "Messaging endpoint reached the backend. A 401/404/405/500 response is acceptable for the setup probe because it confirms traffic is arriving at the plugin path."
            )
        if messaging_endpoint and urlparse(messaging_endpoint).path.rstrip("/") != "/api/messages":
            warnings.append("Messaging endpoint path is not /api/messages. Azure Bot Service normally posts to /api/messages.")

        state_doc = dict(state_payload)
        validation_state = dict(state_doc.get("validation") or {})
        validation_state["last_checked_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        validation_state["credentials"] = credential_validation
        validation_state["endpoint_probe"] = endpoint_probe
        validation_state["status"] = summarize_teams_validation(credential_validation, endpoint_probe)
        validation_state["messaging_endpoint"] = messaging_endpoint
        state_doc["validation"] = validation_state
        _isolation_aware_save_json(inspected["state_path"], state_doc)
        result["write_status"] = "ok"
        result["validation"] = {
            "status": validation_state["status"],
            "credentials": credential_validation,
            "endpoint_probe": endpoint_probe,
        }
        print_teams_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        if result["credential_source"] == "":
            result["credential_source"] = "(unset)"
        print_teams_result(result, stream=sys.stderr)
        return 1


def build_mattermost_access(
    existing: dict[str, Any],
    channels: list[str],
    allow_from: list[str],
    require_mention: bool,
) -> dict[str, Any]:
    """Mattermost access.json schema differs from Teams: it uses
    `channels` (not `groups`) keyed by Mattermost channel_id."""
    payload = dict(existing)
    old_channels = payload.get("channels") or {}
    new_channels: dict[str, Any] = {}
    for channel_id in channels:
        old_entry = old_channels.get(channel_id) or {}
        preserved_allow_from = normalize_mattermost_id_list(old_entry.get("allowFrom") or [], "channel allow_from")
        new_channels[channel_id] = {
            "requireMention": require_mention,
            "allowFrom": preserved_allow_from,
        }

    pending = payload.get("pending")
    if not isinstance(pending, dict):
        pending = {}

    payload["dmPolicy"] = "allowlist"
    payload["allowFrom"] = allow_from
    payload["channels"] = new_channels
    payload["pending"] = pending
    return payload


def merge_mcp_json_mattermost(
    mcp_path: Path,
    server_url: str,
    bot_token: str,
    binary_path: str,
) -> dict[str, Any]:
    """Read existing .mcp.json (if any), upsert the `mattermost` MCP server,
    preserve other servers. Returns the merged document."""
    if mcp_path.exists():
        try:
            with mcp_path.open("r", encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError):
            doc = {}
    else:
        doc = {}
    if not isinstance(doc, dict):
        doc = {}
    servers = doc.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
    servers["mattermost"] = {
        "command": binary_path,
        "env": {
            "MM_SERVER_URL": server_url,
            "MM_ACCESS_TOKEN": bot_token,
        },
    }
    doc["mcpServers"] = servers
    return doc


def validate_mattermost(token: str, base_url: str, agent: str) -> dict[str, Any]:
    """Validate the bot token by calling GET /api/v4/users/me."""
    if not token:
        return {"status": "error", "error": "no token provided"}
    url = f"{base_url.rstrip('/')}/api/v4/users/me"
    req = Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": "agent-bridge-setup/0.1",
        },
        method="GET",
    )
    try:
        with urlopen(req, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return {
                "status": "ok",
                "agent": agent,
                "bot_user_id": str(payload.get("id") or ""),
                "bot_username": str(payload.get("username") or ""),
            }
    except HTTPError as exc:
        return {"status": "error", "error": f"HTTP {exc.code}: {exc.reason}"}
    except URLError as exc:
        return {"status": "error", "error": f"URL error: {exc.reason}"}
    except Exception as exc:
        return {"status": "error", "error": f"unexpected: {exc}"}


def print_mattermost_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"mattermost_dir: {result['mattermost_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    print(f"access_file: {result['access_file']}", file=stream)
    print(f"mcp_file: {result['mcp_file']}", file=stream)
    print(f"server_url: {result['server_url']}", file=stream)
    print(f"channels: {', '.join(result['channels']) if result['channels'] else '(none)'}", file=stream)
    print(
        f"allow_from: {', '.join(result['allow_from']) if result['allow_from'] else '(none)'}",
        file=stream,
    )
    print(f"require_mention: {'yes' if result['require_mention'] else 'no'}", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)
    validation = result.get("validation") or {}
    print(f"validation: {validation.get('status', 'skipped')}", file=stream)
    if validation.get("bot_username"):
        print(f"  bot: @{validation['bot_username']} ({validation.get('bot_user_id', '')})", file=stream)
    if validation.get("error"):
        print(f"  error: {validation['error']}", file=stream)
    for warning in result.get("warnings", []):
        print(f"warning: {warning}", file=stream)
    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def cmd_mattermost(args: argparse.Namespace) -> int:
    mattermost_dir = Path(args.mattermost_dir).expanduser()
    env_path = mattermost_dir / ".env"
    access_path = mattermost_dir / "access.json"
    # .mcp.json lives ONE LEVEL UP — at the agent's workdir, alongside CLAUDE.md.
    mcp_path = mattermost_dir.parent / ".mcp.json"
    warnings: list[str] = []

    server_url = str(args.url or "").strip().rstrip("/")
    bot_token = str(args.bot_token or "").strip()
    allow_from = normalize_mattermost_id_list(args.allow_from or [], "allow_from")
    channels = normalize_mattermost_id_list(args.channel or [], "channel")
    require_mention = bool(args.require_mention)
    mcp_binary = str(args.mcp_binary or "mattermost-mcp-server").strip()

    result: dict[str, Any] = {
        "agent": args.agent,
        "mattermost_dir": str(mattermost_dir),
        "env_file": str(env_path),
        "access_file": str(access_path),
        "mcp_file": str(mcp_path),
        "server_url": server_url,
        "channels": channels,
        "allow_from": allow_from,
        "require_mention": require_mention,
        "write_status": "pending",
        "validation": {"status": "skipped"},
        "warnings": warnings,
    }

    try:
        if not server_url:
            raise SetupError("--url is required (e.g. https://builders.cosmax.com)")
        if not bot_token:
            raise SetupError("--bot-token is required")
        if not allow_from and not channels:
            warnings.append(
                f"No allow_from or channels configured; the plugin will reject all incoming posts. "
                f"Edit {access_path} after setup if needed."
            )

        existing_access: dict[str, Any] = {}
        if access_path.exists():
            try:
                with access_path.open("r", encoding="utf-8") as f:
                    loaded = json.load(f)
                if isinstance(loaded, dict):
                    existing_access = loaded
            except (OSError, json.JSONDecodeError):
                existing_access = {}

        access_doc = build_mattermost_access(existing_access, channels, allow_from, require_mention)
        env_text = (
            f"MATTERMOST_URL={server_url}\n"
            f"MATTERMOST_BOT_TOKEN={bot_token}\n"
            f"BRIDGE_AGENT_ID={args.agent}\n"
        )
        mcp_doc = merge_mcp_json_mattermost(mcp_path, server_url, bot_token, mcp_binary)

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["validation"] = {"status": "dry_run"}
            print_mattermost_result(result)
            return 0

        _isolation_aware_mkdir(mattermost_dir, agent=args.agent)
        _isolation_aware_save_text(env_path, env_text)
        _isolation_aware_save_json(access_path, access_doc)
        _isolation_aware_save_json(mcp_path, mcp_doc)
        result["write_status"] = "ok"

        if args.skip_validate:
            print_mattermost_result(result)
            return 0

        result["validation"] = validate_mattermost(bot_token, server_url, args.agent)
        print_mattermost_result(result)
        if result["validation"].get("status") == "error":
            return 1
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        print_mattermost_result(result, stream=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-setup.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    discord_parser = subparsers.add_parser("discord")
    discord_parser.add_argument("--agent", required=True)
    discord_parser.add_argument("--discord-dir", required=True)
    discord_parser.add_argument("--suggested-channel", default="")
    discord_parser.add_argument("--runtime-config", default="")
    discord_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    discord_parser.add_argument("--channel-account")
    discord_parser.add_argument("--openclaw-account", dest="channel_account", help=argparse.SUPPRESS)
    discord_parser.add_argument("--token")
    discord_parser.add_argument("--channel", action="append", default=[])
    discord_parser.add_argument("--allow-from", action="append", default=[])
    discord_parser.add_argument("--require-mention", action="store_true")
    discord_parser.add_argument("--yes", action="store_true")
    discord_parser.add_argument("--skip-validate", action="store_true")
    discord_parser.add_argument("--skip-send-test", action="store_true")
    discord_parser.add_argument("--dry-run", action="store_true")
    discord_parser.add_argument("--api-base-url", default="https://discord.com/api/v10")
    discord_parser.set_defaults(handler=cmd_discord)

    telegram_parser = subparsers.add_parser("telegram")
    telegram_parser.add_argument("--agent", required=True)
    telegram_parser.add_argument("--telegram-dir", required=True)
    telegram_parser.add_argument("--runtime-config", default="")
    telegram_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    telegram_parser.add_argument("--channel-account")
    telegram_parser.add_argument("--openclaw-account", dest="channel_account", help=argparse.SUPPRESS)
    telegram_parser.add_argument("--token")
    telegram_parser.add_argument("--allow-from", action="append", default=[])
    telegram_parser.add_argument("--default-chat", default="")
    telegram_parser.add_argument("--test-chat", default="")
    telegram_parser.add_argument("--bridge-state-dir", default="")
    telegram_parser.add_argument("--yes", action="store_true")
    telegram_parser.add_argument("--skip-validate", action="store_true")
    telegram_parser.add_argument("--skip-send-test", action="store_true")
    telegram_parser.add_argument("--dry-run", action="store_true")
    telegram_parser.add_argument("--api-base-url", default="https://api.telegram.org")
    telegram_parser.set_defaults(handler=cmd_telegram)

    teams_parser = subparsers.add_parser("teams")
    teams_parser.add_argument("--agent", required=True)
    teams_parser.add_argument("--teams-dir", required=True)
    teams_parser.add_argument("--runtime-config", default="")
    teams_parser.add_argument("--channel-account")
    teams_parser.add_argument("--app-id", default="")
    teams_parser.add_argument("--app-password", default="")
    teams_parser.add_argument("--app-password-file", default="")
    teams_parser.add_argument("--tenant-id", default="")
    teams_parser.add_argument("--service-url", default="")
    teams_parser.add_argument("--messaging-endpoint", default="")
    teams_parser.add_argument("--webhook-host", default="")
    teams_parser.add_argument("--webhook-port", default="")
    teams_parser.add_argument("--ingress-port", default="")
    teams_parser.add_argument("--allow-from", action="append", default=[])
    teams_parser.add_argument("--conversation", action="append", default=[])
    teams_parser.add_argument("--require-mention", action="store_true")
    teams_parser.add_argument("--yes", action="store_true")
    teams_parser.add_argument("--skip-validate", action="store_true")
    teams_parser.add_argument("--skip-send-test", action="store_true")
    teams_parser.add_argument("--dry-run", action="store_true")
    teams_parser.set_defaults(handler=cmd_teams)

    mattermost_parser = subparsers.add_parser("mattermost")
    mattermost_parser.add_argument("--agent", required=True)
    mattermost_parser.add_argument("--mattermost-dir", required=True)
    mattermost_parser.add_argument("--url", default="")
    mattermost_parser.add_argument("--bot-token", default="")
    mattermost_parser.add_argument("--allow-from", action="append", default=[])
    mattermost_parser.add_argument("--channel", action="append", default=[])
    mattermost_parser.add_argument("--require-mention", action="store_true")
    mattermost_parser.add_argument("--mcp-binary", default="mattermost-mcp-server")
    mattermost_parser.add_argument("--yes", action="store_true")
    mattermost_parser.add_argument("--skip-validate", action="store_true")
    mattermost_parser.add_argument("--dry-run", action="store_true")
    mattermost_parser.set_defaults(handler=cmd_mattermost)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
