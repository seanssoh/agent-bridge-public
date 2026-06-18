#!/usr/bin/env python3
"""Interactive Discord, Telegram, and Teams onboarding helpers for Agent Bridge."""

from __future__ import annotations

import argparse
import getpass
import grp
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlencode, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# Canonical isolation-aware pathlib helpers. Issue #1175: previously
# duplicated in both bridge-setup.py and bridge-hooks.py; consolidated
# to a single source of truth so a single fix lands in both files.
_BRIDGE_SETUP_LIB_DIR = Path(__file__).resolve().parent / "lib"
if _BRIDGE_SETUP_LIB_DIR.is_dir() and str(_BRIDGE_SETUP_LIB_DIR) not in sys.path:  # noqa: raw-pathlib-controller-only — import-time controller-side lib dir probe
    sys.path.insert(0, str(_BRIDGE_SETUP_LIB_DIR))

from bridge_iso_paths import (  # noqa: E402
    isolated_workdir_owner as _isolated_workdir_owner,
    resolve_isolated_owner_for_path as _resolve_isolated_owner_for_path,
    sudo_run_as_capture as _sudo_run_as,
    safe_path_check as _safe_path_check,
    safe_read_env as _safe_read_env,
    safe_load_json as _safe_load_json,
    parse_dotenv_text as _parse_dotenv_text,
    # Phase 2 lift: pull canonical atomic-write helper. The local
    # `_sudo_write_as` wrapper now delegates here, so the inline bash
    # body lives in lib/bridge_iso_paths.py (one source of truth, same
    # contract as bridge_isolation_write_file_as_agent_user_via_bash).
    write_text_atomic_as_owner as _write_text_atomic_as_owner_canonical,
)


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
    path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — controller-owned scaffold; callers that target an isolated tree route through _isolation_aware_mkdir first
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def save_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — controller-owned scaffold; callers that target an isolated tree route through _isolation_aware_mkdir first
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
    """Atomic write of `content` to `dest_path` as `os_user`.

    Phase 2: thin delegating wrapper around
    `bridge_iso_paths.write_text_atomic_as_owner`. The inline atomic-
    write bash body lives in `lib/bridge_iso_paths.py` so a fix to
    the contract (mktemp position, chmod-before-mv, trap shape) lands
    in ONE place. The local `_ISOLATED_WRITE_SCRIPT` constant above
    is kept for reference / unit-test introspection.

    Does NOT raise on non-zero rc — caller inspects `proc.returncode`.
    """
    return _write_text_atomic_as_owner_canonical(
        os_user, dest_path, content, mode
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


def _iso_v2_effective_host() -> bool:
    """Return True iff the host is iso-v2 effective right now.

    Mirrors `_bridge_isolation_discriminator_primitives_ready` in
    lib/bridge-isolation-discriminator.sh — the canonical v2 primitives-
    ready signal is the existence of the `ab-shared` POSIX group, which
    `agent-bridge migrate isolation v2 --apply` creates and which is
    absent on:
      * macOS dev hosts (v2 is a no-op there per the discriminator).
      * Linux fresh installs that have not yet run v2 migrate.
      * Any host where the operator explicitly disabled isolation.

    The optional `BRIDGE_ISO_V2_EFFECTIVE_OVERRIDE` env hook lets the
    smoke harness synth-iso2 the host without provisioning real POSIX
    groups; values `yes` / `1` / `true` force True, `no` / `0` / `false`
    force False, anything else falls through to the group probe. The
    override exists only for unit smokes and is intentionally not
    documented as a public knob.

    Returns False on non-Linux to match the bash discriminator's
    auto-resolve. A False return is the safe default: the caller skips
    any cred-mutation entirely and the file stays at controller-owned
    0600 (correct posture on a non-iso host).
    """
    override = os.environ.get("BRIDGE_ISO_V2_EFFECTIVE_OVERRIDE", "").strip().lower()
    if override in {"yes", "1", "true"}:
        return True
    if override in {"no", "0", "false"}:
        return False
    if sys.platform != "linux":
        return False
    shared_group = os.environ.get("BRIDGE_SHARED_GROUP", "").strip() or "ab-shared"
    try:
        grp.getgrnam(shared_group)
    except KeyError:
        return False
    except OSError:
        # /etc/group unreadable / NSS service down — conservative skip.
        return False
    return True


def _audit_normalize_skipped(
    path: Path,
    agent: str,
    reason: str,
    group: str | None = None,
    *,
    rc: int | None = None,
    stderr: str | None = None,
) -> None:
    """Best-effort audit emission for a channel-cred normalize skip.

    Routes through `bridge-audit.py write` so the row joins the hash
    chain alongside `cron.*` / `daemon.*` rows. Mirrors the silent-
    failure contract documented in `bridge-cron.py:emit_cron_mutation_audit`
    — a failed audit write NEVER raises out of this helper, because we
    are sitting on the post-write security path and an audit hiccup
    must not flip the file's mode.

    `reason` is one of `non_iso_v2_host` / `group_missing` /
    `chgrp_failed`. The detail payload records the path, agent, group
    name (where resolved), and chgrp rc / stderr (where applicable) so
    an operator triaging "iso UID cannot read .teams/.env" has a
    machine-readable trail.
    """
    try:
        audit_path_str = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
        if not audit_path_str:
            log_dir = os.environ.get("BRIDGE_LOG_DIR", "").strip()
            if log_dir:
                audit_path_str = str(Path(log_dir).expanduser() / "audit.jsonl")
            else:
                home = os.environ.get("BRIDGE_HOME", "").strip()
                if home:
                    audit_path_str = str(Path(home).expanduser() / "logs" / "audit.jsonl")
        if not audit_path_str:
            return
        actor = os.environ.get("BRIDGE_AGENT_ID", "").strip() \
            or os.environ.get("USER", "").strip() \
            or "unknown"
        detail = {
            "path": str(path),
            "agent": agent,
            "reason": reason,
        }
        if group is not None:
            detail["group"] = group
        if rc is not None:
            detail["rc"] = rc
        if stderr:
            detail["stderr"] = stderr[:200]
        audit_script = Path(__file__).resolve().parent / "bridge-audit.py"
        # Controller-only: audit_script is repo-resident (next to this
        # file via __file__), never under an isolated agent's tree, so a
        # raw exists() cannot trip the iso PermissionError class.
        if not audit_script.exists():  # noqa: raw-pathlib-controller-only
            return
        subprocess.run(
            [
                sys.executable,
                str(audit_script),
                "write",
                "--file", audit_path_str,
                "--actor", actor,
                "--action", "channel_cred_normalize_skipped",
                "--target", agent,
                "--detail-json", json.dumps(detail, ensure_ascii=True, sort_keys=True),
            ],
            check=False, capture_output=True, text=True, timeout=10,
        )
    except (subprocess.SubprocessError, OSError, ValueError):
        return


def _audit_ms365_redirect_probe_skipped(
    redirect_uri: str,
    reason: str,
    *,
    agent: str | None = None,
    detail_extra: dict[str, Any] | None = None,
) -> None:
    """Best-effort audit emission for an MS365 redirect-URI probe skip.

    Routes through `bridge-audit.py write` so the row joins the hash
    chain alongside `channel_cred_normalize_skipped` rows. Mirrors the
    silent-failure contract: an audit hiccup must NEVER raise out of
    this helper because we are on the wizard's hot path and an audit
    write failure cannot be allowed to flip a successful ms365 setup
    into an error.

    `reason` is one of the probe's `skipped` reason codes — most
    importantly `insufficient_permission` (Graph 403), but the
    helper also accepts `creds_missing`, `unreachable`, `no_access_token`,
    `app_not_found`, `token_error`, `missing_inputs`, `exception`,
    `redirect_uri_empty`, and `probe_error`. We hash the redirect_uri
    rather than logging it verbatim because the operator-supplied URI
    can carry an oauth code / state parameter when typed wrong; the
    hash is sufficient to correlate audit rows with the wizard run that
    emitted them without leaking the URI itself.
    """
    try:
        audit_path_str = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
        if not audit_path_str:
            log_dir = os.environ.get("BRIDGE_LOG_DIR", "").strip()
            if log_dir:
                audit_path_str = str(Path(log_dir).expanduser() / "audit.jsonl")
            else:
                home = os.environ.get("BRIDGE_HOME", "").strip()
                if home:
                    audit_path_str = str(Path(home).expanduser() / "logs" / "audit.jsonl")
        if not audit_path_str:
            return
        actor = os.environ.get("BRIDGE_AGENT_ID", "").strip() \
            or os.environ.get("USER", "").strip() \
            or "unknown"
        uri_hash = hashlib.sha256(
            (redirect_uri or "").encode("utf-8")
        ).hexdigest()[:16]
        detail: dict[str, Any] = {
            "reason": reason,
            "redirect_uri_sha256_prefix": uri_hash,
        }
        if agent:
            detail["agent"] = agent
        if detail_extra:
            for key, value in detail_extra.items():
                if key in detail:
                    continue
                detail[key] = value
        audit_script = Path(__file__).resolve().parent / "bridge-audit.py"
        # Controller-only: audit_script is repo-resident (next to this
        # file via __file__), never under an isolated agent's tree, so a
        # raw exists() cannot trip the iso PermissionError class.
        if not audit_script.exists():  # noqa: raw-pathlib-controller-only
            return
        target = agent or "ms365"
        subprocess.run(
            [
                sys.executable,
                str(audit_script),
                "write",
                "--file", audit_path_str,
                "--actor", actor,
                "--action", "ms365_redirect_uri_probe_skipped",
                "--target", target,
                "--detail-json", json.dumps(detail, ensure_ascii=True, sort_keys=True),
            ],
            check=False, capture_output=True, text=True, timeout=10,
        )
    except (subprocess.SubprocessError, OSError, ValueError):
        return


def _post_write_normalize_channel_cred_group(path: Path, agent: str | None) -> None:
    """Post-write normalization for channel credential files (#1329, Lane μ M6).

    When the iso-aware write path falls through to controller-side
    `save_json` / `save_text` (e.g. fresh-install agent create window
    where `_resolve_isolated_owner_for_path` returned None, or
    no-sudo-NOPASSWD hosts where the sudo dispatch is impossible), the
    file lands at `controller:controller-primary-group 0600`. On iso v2
    hosts the iso UID then EACCES on read and the channel plugin fails
    silently.

    This helper performs a best-effort post-write normalize to
    `controller:ab-agent-<agent> 0640`:

      * group  →  `ab-agent-<agent>` via `chgrp` (controller is a
        supplementary member of this group on iso v2 hosts, so direct
        chgrp succeeds without sudo).
      * mode   →  `0o640` (owner-rw, group-r, world-none). The brief
        explicitly chose 0640 NOT 0644 — narrowest grant that lets the
        iso UID read via group, no world-read widening.

    Security contract (r2, codex r1 BLOCKING):

      The chmod 0640 widening is only safe AFTER a successful chgrp to
      the per-agent `ab-agent-<a>` group. If chgrp fails — because the
      host is not iso-v2 effective, the agent group does not exist
      yet, the controller is not a supplementary member of it, or any
      other ENOENT/EPERM — running chmod 0640 alone would widen secrets
      to the controller's primary group (`staff` on macOS dev hosts,
      a per-user group on Linux, etc.). r2 enforces strict gating:

        1. iso-v2 effective host (`ab-shared` group exists) — else skip.
        2. `ab-agent-<a>` group resolvable AND exists on host — else
           audit skip + return WITHOUT chmod.
        3. chgrp returncode is 0 — else audit skip + return WITHOUT chmod.

      Any gate failure leaves the file at its prior mode (caller wrote
      it at 0600). The controller-side fallback fileset on a non-iso-v2
      install therefore stays at 0600, matching the controller-only
      threat model on that host class.

    No-op on:
      * non-iso-v2 hosts (no `ab-shared` group).
      * shared-mode agents (no `ab-agent-<a>` group).
      * `agent` arg missing.
      * file missing.

    Failures past the gates (chmod errors after a successful chgrp) are
    silently swallowed — the upgrade-time backfill in
    `bridge_isolation_v2_normalize_workdir_profile_group`
    (lib/bridge-isolation-v2.sh) is the second-line catch-all, so a
    transient chmod failure here does not leave the operator blocked.
    The contract here is best-effort write-time freshness.
    """
    try:
        if agent is None:
            return
        if not isinstance(path, Path):
            return
        # The channel-cred file may live under an isolated agent's tree
        # (the docstring's iso-v2 case), so a raw `path.exists()` could
        # trip PermissionError before the gates below run. Route through
        # the canonical safe wrapper — same pattern as `load_dotenv`
        # (line ~530) — so the controller gets the proactive sudo
        # `test -e` escalation instead of relying on the outer
        # PermissionError swallow to mask a path it could have observed.
        if not _safe_path_check(
            "exists", path, _resolve_isolated_owner_for_path(path)
        ):
            return
        # Gate 1: iso-v2 effective host. Skipping here leaves the file
        # at its caller-written 0600 — correct posture on non-iso-v2.
        if not _iso_v2_effective_host():
            return
        group = _v2_agent_group_name(agent)
        if not group:
            return
        # Gate 2: target ab-agent-<a> group must exist on host. Without
        # it `chgrp` would either fail or — worse, on platforms that
        # tolerate a name-to-gid miss — leave the file at the controller
        # primary group, and the subsequent chmod 0640 would widen
        # secrets. Skip + audit.
        try:
            grp.getgrnam(group)
        except KeyError:
            _audit_normalize_skipped(path, agent, "group_missing", group)
            return
        except OSError as exc:
            _audit_normalize_skipped(
                path, agent, "group_lookup_oserror", group,
                stderr=str(exc),
            )
            return
        # Gate 3: chgrp must succeed before any chmod widening. A
        # failed chgrp here is the codex r1 BLOCKING case — running
        # chmod 0640 alone would widen secrets to the controller's
        # primary group (e.g. `staff` on macOS / `<user>` on Linux).
        proc = subprocess.run(
            ["chgrp", group, str(path)],
            check=False, capture_output=True, text=True, timeout=5,
        )
        if proc.returncode != 0:
            _audit_normalize_skipped(
                path, agent, "chgrp_failed", group,
                rc=proc.returncode,
                stderr=(proc.stderr or "").strip(),
            )
            return
        # chgrp landed `ab-agent-<a>` — safe to widen mode to 0640.
        # chmod failure here is non-fatal; the v2 upgrade backfill
        # picks it up on the next reapply pass.
        subprocess.run(
            ["chmod", "0640", str(path)],
            check=False, capture_output=True, text=True, timeout=5,
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired, OSError):
        # All non-fatal — the upgrade backfill in
        # bridge_isolation_v2_normalize_workdir_profile_group is the
        # second-line recovery. Never raise out of a post-write hook.
        return


def load_dotenv(path: Path) -> dict[str, str]:
    # #1175: existence probe routes through the canonical safe wrapper so a
    # direct caller (kept as a public back-compat entry point even though
    # bridge-setup.py's internal flow now uses `_safe_read_env`) does not
    # raise PermissionError on isolated `.env` paths. The body read itself
    # can still raise; callers needing the sudo-cat fallback should call
    # `_safe_read_env` instead.
    payload: dict[str, str] = {}
    if not _safe_path_check("exists", path, _resolve_isolated_owner_for_path(path)):
        return payload
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key.strip()] = value.strip()
    return payload


# #1175: `_parse_dotenv_text`, `_isolated_workdir_owner`,
# `_resolve_isolated_owner_for_path`, `_sudo_run_as`, `_safe_path_check`,
# `_safe_read_env`, `_safe_load_json` were duplicated between bridge-setup.py
# and bridge-hooks.py with subtly different shapes (rc-int vs CompletedProcess,
# walker vs non-walker, etc.). Consolidated into `lib/bridge_iso_paths.py`
# and imported at the top of this file. Existing private-name call sites
# keep working through the import aliases.


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
    # #1175: route the idempotent existence probe through the canonical
    # safe wrapper. On a re-run against a pre-existing isolated channel
    # dir (e.g. `.teams/` on test_iso2 mid-recovery, beta15 next-
    # reproducer), the controller may have lost +x traversal on the
    # parent dir even with the v2 mode-2750 + `ab-agent-<a>` group
    # contract — `path.exists()` then raises PermissionError before
    # `_resolve_isolated_owner_for_path` ever runs. The safe wrapper
    # sudo-escalates to the isolated UID first when an owner can be
    # resolved upfront, or fail-closes on the direct-pathlib branch.
    owner = _resolve_isolated_owner_for_path(path)
    if _safe_path_check("exists", path, owner):
        return
    if owner is None:
        # #1178 (cycle 12): post-helper-A `owner is None` is now an
        # authoritative signal of non-isolated lineage — the helper
        # uses `_sudo_stat_owner` to recover the isolated owner when
        # PermissionError fires (the cycle 12 root cause was that
        # `except OSError: pass` silently mapped "path IS isolated"
        # to None, producing this raw mkdir at L368 → PermissionError
        # → operator-visible traceback). With #1178 in place, this raw
        # mkdir only runs on truly controller-owned trees.
        path.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only — owner is None means non-isolated per #1178 helper contract
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


# #1175: `_sudo_run_as` + `_safe_path_check` + `_safe_read_env` +
# `_safe_load_json` (along with `_isolated_workdir_owner`,
# `_resolve_isolated_owner_for_path`, `_parse_dotenv_text`) now live in
# `lib/bridge_iso_paths.py`; the private names remain available via the
# top-of-file `from bridge_iso_paths import ... as _...` so existing
# call sites and module-level introspection (e.g. the #1170 smoke that
# stubs `mod._sudo_run_as`) keep working unchanged.


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
        if token_path.exists():  # noqa: raw-pathlib-controller-only — operator-supplied token-file path
            token = extract_token_from_text(token_path.read_text(encoding="utf-8"), kind)
            if token:
                return token
    raise SetupError(f"Configured {kind} account token is empty: {account}")


def load_claude_plugin_channel_token(kind: str) -> str:
    channels_home = Path(
        os.environ.get("BRIDGE_CLAUDE_CHANNELS_HOME", str(Path.home() / ".claude" / "channels"))
    ).expanduser()
    env_path = channels_home / kind / ".env"
    if not env_path.exists():  # noqa: raw-pathlib-controller-only — $HOME/.claude/channels/<kind>/.env is controller-owned by design
        return ""
    return extract_token_from_text(env_path.read_text(encoding="utf-8"), kind)


def read_secret_value(
    flag_value: str,
    flag_name: str,
    file_path: Optional[str],
    env_name: str,
    stdin_flag: bool = False,
    stdin_flag_name: str = "",
) -> str:
    """Resolve a channel secret without requiring it on the command line.

    Precedence: `--<name>-stdin` (read once from process stdin) wins, then
    `--<name>-file <path>` (a path is safe to pass in argv), then the env var,
    then the legacy `--<name> <secret>` flag. Passing the secret as a bare argv
    value still works for compatibility but emits a one-line warning, since it
    then lands in shell history and the process table (`ps`, `/proc/<pid>/cmdline`).

    FD-aware file ingestion (Issue #1354): `--<name>-file` accepts any path the
    process can open and read — regular files, `/dev/fd/N` (Bash process
    substitution `<(...)`), named pipes (FIFOs), and character/socket specials.
    The old `Path.is_file()` gate refused everything except regular files,
    which broke the documented `<(printf '%s' "$secret")` pattern because
    `/dev/fd/63` is a character device. We now try-open-and-read; if the read
    fails we surface a hint that names the process-substitution + sudo subshell
    interaction and the `--<name>-stdin` / tempfile alternatives.

    Mutex defense (Issue #1354 R2): the argparse layer guards the
    common-case `--<name>-file FOO --<name>-stdin`. This handler-side
    check is a belt-and-suspenders second line in case a future caller
    (programmatic invocation, refactor that drops the mutex group)
    reaches this function with both signals set. Non-empty file_path +
    stdin_flag both being live is unambiguously a mis-use.
    """
    if stdin_flag and file_path:
        file_flag = f"{flag_name}-file"
        stdin_flag_label = stdin_flag_name or f"{flag_name}-stdin"
        raise SetupError(
            f"{file_flag} and {stdin_flag_label} are mutually exclusive — "
            f"pass only one."
        )
    if stdin_flag:
        # stdin path: read everything once. Single trailing newline (the shape
        # tools like `printf %s\\n` and `cat` produce) is stripped; any embedded
        # newlines AND any second trailing newline stay verbatim so multi-line
        # key material and operator-meaningful trailing whitespace are preserved.
        data = sys.stdin.read()
        if data.endswith("\n"):
            secret = data[:-1]
        else:
            secret = data
        if not secret:
            stdin_label = stdin_flag_name or f"{flag_name}-stdin"
            raise SetupError(
                f"{stdin_label} read an empty secret from stdin "
                f"(no input received before EOF — check the producer wrote bytes)."
            )
        return secret
    if file_path:
        path = Path(file_path).expanduser()
        # File-path companion flag is always `<flag_name>-file`; the
        # stdin companion is `<flag_name>-stdin`. Naming both in the
        # error keeps the operator from re-typing the bare `<flag_name>`
        # form (which lands the secret in argv).
        file_flag = f"{flag_name}-file"
        stdin_flag_label = stdin_flag_name or f"{flag_name}-stdin"
        # noqa: raw-pathlib-controller-only — operator-supplied secret-file path.
        # Issue #1354: try-open-and-read instead of stat-fail-then-abort so
        # `/dev/fd/N` (Bash process substitution `<(...)`), named pipes, and
        # character/socket specials all work. The error path below names the
        # process-substitution + sudo-subshell interaction as the most common
        # cause and points at the regular-file / stdin alternatives.
        try:
            with path.open("r", encoding="utf-8") as handle:
                data = handle.read()
        except FileNotFoundError as exc:
            raise SetupError(
                f"{file_flag} path stat failed: {file_path} "
                f"(file does not exist; use {file_flag} <regular-file> "
                f"or {stdin_flag_label} and pipe the secret on stdin). "
                "Note: process substitution `<(...)` → /dev/fd/N is not "
                "preserved across sudo / subshell wrappers."
            ) from exc
        except (PermissionError, OSError) as exc:
            # Includes EACCES, EISDIR, ENXIO (FIFO closed), and the
            # process-substitution-across-sudo case where `/dev/fd/63`
            # exists in the parent shell but not inside the sudo subshell
            # the wizard wraps the python call in.
            hint = (
                f"{file_flag} path could not be opened: {file_path} "
                f"({exc.__class__.__name__}: {exc}). "
                "Process substitution (`<(...)` → /dev/fd/N) is not preserved across sudo / subshell "
                f"wrappers; use {file_flag} <regular-file> or "
                f"{stdin_flag_label} and pipe the secret on stdin."
            )
            raise SetupError(hint) from exc
        # Single trailing newline strip (some tools add it); leave interior
        # whitespace and any second trailing newline alone so multi-line keys
        # and operator-meaningful trailing whitespace are preserved.
        if data.endswith("\n"):
            secret = data[:-1]
        else:
            secret = data
        if not secret:
            raise SetupError(
                f"{file_flag} path opened but yielded an empty secret: {file_path} "
                f"(producer wrote zero bytes before EOF)."
            )
        return secret
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


def inspect_ms365_dir(ms365_dir: Path) -> dict[str, Any]:
    """Read existing `.ms365/.env` (if any) so the wizard preserves
    operator-set credentials when only `--messaging-endpoint` is
    being added on a re-run.

    Same isolation-aware probe shape as `inspect_teams_dir`: route
    through `_safe_read_env` which sudo-escalates to the isolated
    UID's view when the controller cannot directly read the file.

    PR #1220 codex r1 (#1209 follow-up): `allow_localhost` is also
    inspected so `cmd_ms365` can preserve the documented local-dev
    escape hatch (`MS365_REDIRECT_URI_ALLOW_LOCALHOST=1`) across
    reruns. Without this, an operator who set the allow flag once
    would have it silently dropped on the next
    `agent-bridge setup ms365 <agent>` invocation, breaking the
    next `pair_start` call.
    """
    env_path = ms365_dir / ".env"
    env = _safe_read_env(env_path)
    return {
        "env_path": env_path,
        "tenant_id": env.get("MS365_TENANT_ID", "").strip(),
        "client_id": env.get("MS365_CLIENT_ID", "").strip(),
        "client_secret": env.get("MS365_CLIENT_SECRET", "").strip(),
        "default_upn": env.get("MS365_DEFAULT_UPN", "").strip(),
        "redirect_uri": env.get("MS365_REDIRECT_URI", "").strip(),
        "default_scopes": env.get("MS365_DEFAULT_SCOPES", "").strip(),
        "allow_localhost": env.get("MS365_REDIRECT_URI_ALLOW_LOCALHOST", "").strip(),
    }


def derive_ms365_redirect_uri(messaging_endpoint: str) -> str:
    """Derive an `/auth/callback` redirect URI from a Teams messaging
    endpoint URL. Issue #1209: the Teams plugin multiplexes
    `/auth/callback` through its existing webhook listener, so the
    MS365 OAuth redirect URI is the same host + scheme as the Teams
    `--messaging-endpoint` (typically `/api/messages`).

    Raises `SetupError` if the input is not a valid http(s) URL.
    """
    raw = (messaging_endpoint or "").strip()
    if not raw:
        raise SetupError("Cannot derive MS365_REDIRECT_URI: no Teams messaging endpoint available")
    parsed = urlparse(raw)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SetupError(
            f"Cannot derive MS365_REDIRECT_URI from messaging endpoint (must be a full http(s) URL): {raw}"
        )
    return f"{parsed.scheme}://{parsed.netloc}/auth/callback"


# Issue #1355: protocol-convention default scope set for MS Graph.
# Mail+Calendar are the de-facto MS365/Graph baseline — keeping this as
# wizard-required cost wizard friction with no default benefit. Site-
# specific values (client-id, secret, tenant, redirect-uri, default-upn)
# stay wizard-required; default-scopes is the lone protocol-convention
# exception and gets surfaced with `default_scopes_source: convention-default`
# so the operator can see exactly what was applied without digging into
# `.ms365/.env`.
MS365_CONVENTION_DEFAULT_SCOPES = (
    "https://graph.microsoft.com/Mail.Read "
    "https://graph.microsoft.com/Mail.Send "
    "https://graph.microsoft.com/Calendars.ReadWrite "
    "offline_access"
)


def ms365_normalize_redirect_uri_for_compare(uri: str) -> str:
    """Normalize a redirect URI for Entra registration comparison.

    The Microsoft identity platform matches redirect URIs against the
    Entra app registration's `web.redirectUris` array verbatim — the
    sent value (including scheme, host, port, path, **query string**,
    and **fragment**) must equal one of the registered entries character
    for character. AADSTS50011 fires for anything else, including a
    `?code=abc` query added by the operator's reverse proxy or a
    `#fragment` typo. The earlier version of this helper stripped
    query+fragment "to avoid spurious mismatches", but that was the
    OPPOSITE of what #1356 needs — the whole point of the probe is to
    catch every divergence the runtime would catch.

    Verbatim, with whitespace trimmed (operator input artifact). We do
    not lower-case the host either: Entra is case-sensitive on path
    and forgiving on host case, but the operator typed exactly what
    they typed and the strictest probe is the safest probe.
    """
    return (uri or "").strip()


def ms365_acquire_graph_token(
    tenant_id: str,
    client_id: str,
    client_secret: str,
    *,
    timeout: float = 15.0,
) -> dict[str, Any]:
    """Acquire a client_credentials access_token for Microsoft Graph.

    Issue #1356: the redirect URI probe needs an app-only Graph token
    (Application.Read.All or Directory.Read.All) to list the Entra
    application's `web.redirectUris`. Returns a structured payload:

      {"status": "ok",   "access_token": "..."}
      {"status": "skipped", "reason": "creds_missing"|"unreachable"|...}
      {"status": "error", "detail": "<message>"}

    Caller is responsible for surfacing the skip reason in the wizard
    output. This function NEVER raises — every transport or
    application-layer failure routes through the structured return so
    `cmd_ms365` can decide whether to fail-loud or annotate skipped.
    """
    tenant = (tenant_id or "").strip()
    cid = (client_id or "").strip()
    secret = (client_secret or "").strip()
    if not tenant or not cid or not secret:
        return {"status": "skipped", "reason": "creds_missing"}

    base = os.environ.get(
        "BRIDGE_MS365_LOGIN_BASE_URL", teams_login_base_url()
    ).rstrip("/")
    token_url = f"{base}/{tenant}/oauth2/v2.0/token"
    body = urlencode(
        {
            "client_id": cid,
            "client_secret": secret,
            "grant_type": "client_credentials",
            "scope": "https://graph.microsoft.com/.default",
        }
    ).encode("utf-8")
    request = Request(
        token_url,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "agent-bridge-setup/ms365-redirect-probe",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8") or "{}")
    except HTTPError as exc:
        try:
            parsed = json.loads(exc.read().decode("utf-8", errors="replace") or "{}")
        except json.JSONDecodeError:
            parsed = {}
        return {
            "status": "error",
            "detail": str(parsed.get("error_description") or parsed.get("error") or exc.reason or "").strip(),
            "http_status": int(exc.code or 0),
        }
    except URLError as exc:
        return {"status": "skipped", "reason": "unreachable", "detail": str(exc.reason)}
    except Exception as exc:  # noqa: BLE001 — best-effort probe, never bubble
        return {"status": "skipped", "reason": "exception", "detail": repr(exc)}

    access_token = str(payload.get("access_token") or "").strip()
    if not access_token:
        return {"status": "skipped", "reason": "no_access_token"}
    return {"status": "ok", "access_token": access_token}


def ms365_fetch_entra_redirect_uris(
    access_token: str,
    client_id: str,
    *,
    timeout: float = 15.0,
) -> dict[str, Any]:
    """List the Entra application's registered `web.redirectUris`.

    Microsoft Graph endpoint:
      GET /v1.0/applications?$filter=appId eq '<client_id>'&$select=appId,web

    Returns:
      {"status": "ok",       "redirect_uris": [...]}
      {"status": "skipped",  "reason": "insufficient_permission"|"unreachable"|...}
      {"status": "error",    "detail": "<message>"}

    A 403 with `Authorization_RequestDenied` or `Insufficient privileges`
    surfaces as `skipped: insufficient_permission` so the wizard can
    annotate `redirect_uri_check: skipped (insufficient app permission)`
    instead of fail-loud. Any other transport/HTTP failure returns
    `skipped` so the operator never gets blocked by a probe issue.
    """
    cid = (client_id or "").strip()
    token = (access_token or "").strip()
    if not cid or not token:
        return {"status": "skipped", "reason": "missing_inputs"}

    base = os.environ.get(
        "BRIDGE_MS365_GRAPH_BASE_URL", "https://graph.microsoft.com"
    ).rstrip("/")
    filt = urlencode({"$filter": f"appId eq '{cid}'", "$select": "appId,web"})
    url = f"{base}/v1.0/applications?{filt}"
    request = Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "agent-bridge-setup/ms365-redirect-probe",
        },
        method="GET",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8") or "{}")
    except HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", errors="replace")
            parsed = json.loads(body or "{}")
        except json.JSONDecodeError:
            parsed = {}
            body = ""
        code = int(exc.code or 0)
        error_obj = parsed.get("error") if isinstance(parsed, dict) else None
        error_code = ""
        error_msg = ""
        if isinstance(error_obj, dict):
            error_code = str(error_obj.get("code") or "").strip()
            error_msg = str(error_obj.get("message") or "").strip()
        if code in {401, 403} or error_code in {
            "Authorization_RequestDenied",
            "Authorization_IdentityNotFound",
            "Forbidden",
        }:
            return {
                "status": "skipped",
                "reason": "insufficient_permission",
                "detail": (error_msg or body)[:240],
            }
        return {
            "status": "error",
            "http_status": code,
            "detail": (error_msg or body or str(exc.reason))[:240],
        }
    except URLError as exc:
        return {"status": "skipped", "reason": "unreachable", "detail": str(exc.reason)}
    except Exception as exc:  # noqa: BLE001 — best-effort probe, never bubble
        return {"status": "skipped", "reason": "exception", "detail": repr(exc)}

    values = []
    if isinstance(payload, dict):
        items = payload.get("value")
        if isinstance(items, list):
            values = items
    # The filter is an equality match, so the array is either empty
    # (app not found in this tenant — the app-id is wrong, or the app
    # registration lives in a different tenant) or one element.
    if not values:
        return {"status": "skipped", "reason": "app_not_found"}
    first = values[0]
    redirect_uris: list[str] = []
    if isinstance(first, dict):
        web = first.get("web")
        if isinstance(web, dict):
            raw_uris = web.get("redirectUris")
            if isinstance(raw_uris, list):
                redirect_uris = [str(u) for u in raw_uris if isinstance(u, str)]
    return {"status": "ok", "redirect_uris": redirect_uris}


def ms365_check_redirect_uri_registered(
    redirect_uri: str,
    tenant_id: str,
    client_id: str,
    client_secret: str,
    *,
    timeout: float = 15.0,
) -> dict[str, Any]:
    """Combined token + Graph fetch + verbatim match. Issue #1356.

    Returns one of:
      {"status": "registered",   "redirect_uris": [...]}
      {"status": "not_registered","redirect_uris": [...]}
      {"status": "skipped",       "reason": "<reason>", "detail"?: "..."}
      {"status": "error",         "detail": "..."}

    "skipped" is the safe default whenever a transport, permission, or
    credential precondition prevents the lookup; callers annotate
    `redirect_uri_check: skipped` and continue (do not abort the
    wizard). "not_registered" is the only fail-loud signal.
    """
    target = (redirect_uri or "").strip()
    if not target:
        return {"status": "skipped", "reason": "redirect_uri_empty"}

    token_result = ms365_acquire_graph_token(
        tenant_id, client_id, client_secret, timeout=timeout
    )
    if token_result.get("status") != "ok":
        # Map "error" → skipped for the wizard surface (the probe is
        # best-effort; an Entra token failure should not block setup).
        if token_result.get("status") == "error":
            return {
                "status": "skipped",
                "reason": "token_error",
                "detail": str(token_result.get("detail") or ""),
            }
        return token_result

    fetch_result = ms365_fetch_entra_redirect_uris(
        token_result["access_token"], client_id, timeout=timeout
    )
    if fetch_result.get("status") != "ok":
        return fetch_result

    registered = list(fetch_result.get("redirect_uris") or [])
    target_norm = ms365_normalize_redirect_uri_for_compare(target)
    registered_norm = {ms365_normalize_redirect_uri_for_compare(u) for u in registered}
    if target_norm in registered_norm or target in registered:
        return {"status": "registered", "redirect_uris": registered}
    return {"status": "not_registered", "redirect_uris": registered}


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
        # Issue #1995: the send test exercises OUTBOUND only (bridge -> Telegram
        # via getMe + sendMessage). It does NOT verify the inbound MCP injection
        # path (operator -> session). Do not let a green "send: ok" read as
        # "channel OK" — state precisely what was and was not verified so a
        # broken inbound path is not masked by a false-green. (The actual
        # inbound round-trip check is deferred to a later enhancement.)
        if validation.get("send") == "ok":
            print(
                "verified: outbound send only (bridge -> Telegram). "
                "Inbound (operator -> session MCP injection) NOT tested — "
                "send a message TO the bot and confirm the session receives it.",
                file=stream,
            )

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

        # Issue #1215: pass explicit `mode=0o2770` so the channel state
        # dir gets the setgid + rwx-for-group bits, not the helper's
        # legacy `0o2750` default. Without the group write/exec bit
        # the controller-side `agent start` channel-required validator
        # cannot stat `.discord/.env` under the v2 isolation contract
        # (drw-r-S--- on a long-running shell with stale supp-groups
        # surfaced as `missing` on `agent start`).
        _isolation_aware_mkdir(discord_dir, mode=0o2770, agent=args.agent)
        _isolation_aware_save_text(inspected["env_path"], f"DISCORD_BOT_TOKEN={token}\n")
        _isolation_aware_save_json(inspected["access_path"], access_doc)
        # #1329 (v0.15.0-beta5-2 Lane μ M6): post-write normalize so a
        # controller-side fallback write (no iso owner resolvable) does
        # not leave the iso UID EACCESing on read.
        _post_write_normalize_channel_cred_group(inspected["env_path"], args.agent)
        _post_write_normalize_channel_cred_group(inspected["access_path"], args.agent)
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

        # Issue #1215: explicit `mode=0o2770` for the v2 isolation
        # channel-state-dir contract (see discord_dir above for the
        # rationale).
        _isolation_aware_mkdir(telegram_dir, mode=0o2770, agent=args.agent)
        _isolation_aware_save_text(inspected["env_path"], f"TELEGRAM_BOT_TOKEN={token}\n")
        _isolation_aware_save_json(inspected["access_path"], access_doc)
        # #1329 (Lane μ M6): see discord post-write normalize comment.
        _post_write_normalize_channel_cred_group(inspected["env_path"], args.agent)
        _post_write_normalize_channel_cred_group(inspected["access_path"], args.agent)
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
            stdin_flag=bool(getattr(args, "app_password_stdin", False)),
            stdin_flag_name="--app-password-stdin",
        )
        # Issue #1354 R2 (codex r1 BLOCKING #2): do NOT `.strip()` the
        # secret here. `read_secret_value` already strips at most one
        # trailing newline (the canonical contract — multi-line key
        # material and operator-meaningful trailing whitespace are
        # preserved). A handler-level `.strip()` greedily removes leading
        # AND trailing whitespace including a second trailing newline,
        # silently truncating valid secrets. The fallback paths
        # (account_cfg, inspected) are configuration JSON / existing .env
        # values; preserve them verbatim too — if `appPassword` in the
        # account JSON has stray trailing whitespace the operator put it
        # there and the .env round-trip already preserves it.
        if app_password_arg:
            app_password = app_password_arg
        else:
            app_password = (
                account_cfg.get("appPassword")
                or account_cfg.get("app_password")
                or account_cfg.get("clientSecret")
                or account_cfg.get("client_secret")
                or inspected["app_password"]
                or ""
            )
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

        # Issue #1215: explicit `mode=0o2770` for the v2 isolation
        # channel-state-dir contract (see discord_dir above for the
        # rationale).
        _isolation_aware_mkdir(teams_dir, mode=0o2770, agent=args.agent)
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
        # #1329 (Lane μ M6): see discord post-write normalize comment.
        _post_write_normalize_channel_cred_group(inspected["env_path"], args.agent)
        _post_write_normalize_channel_cred_group(inspected["access_path"], args.agent)
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
        # #1329 (Lane μ M6): see discord post-write normalize comment.
        _post_write_normalize_channel_cred_group(inspected["state_path"], args.agent)
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


def print_ms365_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"ms365_dir: {result['ms365_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    if result["redirect_uri"]:
        print(f"redirect_uri: {result['redirect_uri']}", file=stream)
    else:
        print("redirect_uri: (unset)", file=stream)
    print(f"redirect_uri_source: {result['redirect_uri_source']}", file=stream)
    # Issue #1356: tactical first-line elevation — the warning printer
    # below puts the "Register this redirect URI" cue dead-last in the
    # output, after every other field. Operators piping stdout into a
    # log usually only see the LAST few lines and miss the call to
    # action. Surface the Entra-registration verification status
    # IMMEDIATELY after the redirect URI so the action lives next to
    # the value it applies to.
    redirect_uri_check = result.get("redirect_uri_check") or ""
    if redirect_uri_check:
        print(f"redirect_uri_check: {redirect_uri_check}", file=stream)
    redirect_uri_registered = result.get("redirect_uri_registered") or ""
    if redirect_uri_registered:
        print(f"redirect_uri_registered: {redirect_uri_registered}", file=stream)
    if result["messaging_endpoint"]:
        print(f"messaging_endpoint: {result['messaging_endpoint']}", file=stream)
    if result.get("tenant_id"):
        print(f"tenant_id: {result['tenant_id']}", file=stream)
    if result.get("client_id"):
        print(f"client_id: {result['client_id']}", file=stream)
    if result.get("default_upn"):
        print(f"default_upn: {result['default_upn']}", file=stream)
    # Issue #1355: surface the chosen scope set + its source so an
    # operator can tell at a glance whether the wizard applied the
    # protocol-convention default, preserved an existing value, or
    # used an explicit --default-scopes flag.
    default_scopes = result.get("default_scopes") or ""
    default_scopes_source = result.get("default_scopes_source") or ""
    if default_scopes:
        print(f"default_scopes: {default_scopes}", file=stream)
    if default_scopes_source:
        print(f"default_scopes_source: {default_scopes_source}", file=stream)
    # PR #1220 codex r1: surface the allow-localhost state so an
    # operator who set the local-dev escape hatch can see at a glance
    # that the wizard preserved it on rerun.
    if result.get("allow_localhost") == "1":
        print("allow_localhost: yes (MS365_REDIRECT_URI_ALLOW_LOCALHOST=1)", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)
    for warning in result.get("warnings") or []:
        print(f"warning: {warning}", file=stream)
    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def cmd_ms365(args: argparse.Namespace) -> int:
    """Issue #1209: `agent-bridge setup ms365 <agent>` wizard.

    Persists `MS365_REDIRECT_URI` (and optional CLIENT_ID / SECRET /
    TENANT_ID / DEFAULT_UPN) to `.ms365/.env`. The redirect URI is
    derived from the Teams plugin's already-configured messaging
    endpoint (`.teams/state.json.validation.messaging_endpoint`)
    unless `--messaging-endpoint` overrides it. This pairs with the
    fail-loud `resolveRedirectUri()` in plugins/ms365/server.ts so
    the operator never sees a silent `http://localhost:3978/...`
    default that produces guaranteed AADSTS50011 failures.
    """
    ms365_dir = Path(args.ms365_dir).expanduser()
    inspected = inspect_ms365_dir(ms365_dir)
    warnings: list[str] = []
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and not args.yes

    result: dict[str, Any] = {
        "agent": args.agent,
        "ms365_dir": str(ms365_dir),
        "env_file": str(inspected["env_path"]),
        "redirect_uri": "",
        "redirect_uri_source": "",
        "messaging_endpoint": "",
        "tenant_id": "",
        "client_id": "",
        "default_upn": "",
        "allow_localhost": "",
        # Issue #1355: default_scopes + provenance — when the operator
        # neither passes --default-scopes nor has an existing value,
        # the wizard applies MS365_CONVENTION_DEFAULT_SCOPES and
        # surfaces `default_scopes_source: convention-default`.
        "default_scopes": "",
        "default_scopes_source": "",
        # Issue #1356: redirect URI Entra-registration probe. Both
        # fields are empty when --skip-entra-probe is in effect (the
        # operator opted out of the Graph round-trip).
        "redirect_uri_check": "",
        "redirect_uri_registered": "",
        "write_status": "pending",
        "warnings": warnings,
    }

    try:
        # Resolve the source for the redirect URI.
        # Priority:
        #   1. --redirect-uri (explicit)
        #   2. --messaging-endpoint + /auth/callback
        #   3. Existing .teams/state.json validation.messaging_endpoint
        #      + /auth/callback
        #   4. Interactive prompt with the best default we have
        #   5. Existing .ms365/.env MS365_REDIRECT_URI (re-run preservation)
        explicit_redirect = (args.redirect_uri or "").strip()
        explicit_endpoint = (args.messaging_endpoint or "").strip()
        teams_endpoint = ""
        if args.teams_state_file:
            teams_state_path = Path(args.teams_state_file).expanduser()
            teams_state_doc = _safe_load_json(teams_state_path, {})
            if isinstance(teams_state_doc, dict):
                validation = teams_state_doc.get("validation") or {}
                if isinstance(validation, dict):
                    teams_endpoint = str(validation.get("messaging_endpoint") or "").strip()

        redirect_uri = ""
        redirect_uri_source = ""
        if explicit_redirect:
            redirect_uri = explicit_redirect
            redirect_uri_source = "flag:--redirect-uri"
        elif explicit_endpoint:
            redirect_uri = derive_ms365_redirect_uri(explicit_endpoint)
            redirect_uri_source = "derived:flag:--messaging-endpoint"
            result["messaging_endpoint"] = explicit_endpoint
        elif teams_endpoint:
            redirect_uri = derive_ms365_redirect_uri(teams_endpoint)
            redirect_uri_source = "derived:teams_state"
            result["messaging_endpoint"] = teams_endpoint
        elif interactive:
            default = inspected["redirect_uri"]
            redirect_uri = prompt_text(
                "MS365 OAuth redirect URI (https://<bot-host>/auth/callback)",
                default,
            ).strip()
            if redirect_uri:
                redirect_uri_source = "prompt"
        elif inspected["redirect_uri"]:
            redirect_uri = inspected["redirect_uri"]
            redirect_uri_source = "existing:.ms365/.env"

        if not redirect_uri:
            raise SetupError(
                "MS365 redirect URI is required. Pass --redirect-uri or --messaging-endpoint, "
                "or run in an interactive TTY, or pre-set MS365_REDIRECT_URI in .ms365/.env."
            )

        # Validate the chosen redirect URI shape.
        parsed = urlparse(redirect_uri)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise SetupError(
                f"MS365_REDIRECT_URI must be a full http(s) URL: {redirect_uri}"
            )
        if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1"}:
            warnings.append(
                "MS365_REDIRECT_URI uses plain http on a non-localhost host. "
                "Entra app registrations require https for public redirect URIs."
            )
        # Note: the allow-localhost effective value is computed below
        # (after credential merge); the warning here is harmless when
        # the allow flag IS set because it just restates the local-dev
        # opt-in contract. Operators get one clear line either way.
        if parsed.hostname in {"localhost", "127.0.0.1"}:
            warnings.append(
                "MS365_REDIRECT_URI points at localhost. The MS365 plugin will reject "
                "this at pair_start unless MS365_REDIRECT_URI_ALLOW_LOCALHOST=1 is also "
                "set (intended for local dev only — production OAuth clicks happen on "
                "the user's machine which has no listener on this loopback)."
            )

        # Merge optional credentials.
        tenant_id = (args.tenant_id or inspected["tenant_id"]).strip()
        client_id = (args.client_id or inspected["client_id"]).strip()
        client_secret_arg = read_secret_value(
            flag_value=args.client_secret,
            flag_name="--client-secret",
            file_path=args.client_secret_file,
            env_name="BRIDGE_MS365_CLIENT_SECRET",
            stdin_flag=bool(getattr(args, "client_secret_stdin", False)),
            stdin_flag_name="--client-secret-stdin",
        )
        # Issue #1354 R2 (codex r1 BLOCKING #2): same shape as the teams
        # handler — do NOT `.strip()` the secret. read_secret_value
        # already does the canonical single-trailing-newline strip;
        # handler-level `.strip()` would greedily eat operator-meaningful
        # trailing whitespace and a legitimate second newline.
        if client_secret_arg:
            client_secret = client_secret_arg
        else:
            client_secret = inspected["client_secret"] or ""
        default_upn = (args.default_upn or inspected["default_upn"]).strip()

        # Issue #1355: protocol-convention default for --default-scopes.
        # Precedence (r2, codex r1 BLOCKING 1):
        #   1. --default-scopes "X Y" → flag (source: flag)
        #   2. --default-scopes ""    → explicit empty (error — no Graph
        #      call ever succeeds without at least one scope; silently
        #      expanding an explicit-empty operator input to the broad
        #      Mail.Read/Mail.Send/Calendars.ReadWrite/offline_access
        #      default would silently grant permissions the operator
        #      tried to refuse)
        #   3. existing .ms365/.env MS365_DEFAULT_SCOPES → preserved
        #      (source: existing:.ms365/.env)
        #   4. otherwise → MS365_CONVENTION_DEFAULT_SCOPES
        #      (source: convention-default)
        # The argparse parser uses `default=None` as a sentinel so we
        # can distinguish "flag omitted" (args.default_scopes is None →
        # case 3/4) from `--default-scopes ""` (args.default_scopes is
        # "" → case 2 error).
        raw_default_scopes = args.default_scopes
        existing_default_scopes = inspected["default_scopes"].strip()
        if raw_default_scopes is None:
            # Flag omitted entirely → fall through to existing-env or
            # convention default.
            if existing_default_scopes:
                default_scopes = existing_default_scopes
                default_scopes_source = "existing:.ms365/.env"
            else:
                default_scopes = MS365_CONVENTION_DEFAULT_SCOPES
                default_scopes_source = "convention-default"
        else:
            # Flag supplied — distinguish explicit-empty (error) from a
            # whitespace-only value (also error, identical reason).
            flag_default_scopes = raw_default_scopes.strip()
            if not flag_default_scopes:
                raise SetupError(
                    "--default-scopes was supplied with an empty value; "
                    "Microsoft Graph rejects token requests with zero "
                    "scopes. Either supply a space-separated scope list "
                    "(e.g. --default-scopes \"https://graph.microsoft.com/Mail.Read offline_access\") "
                    "or omit the flag to use the protocol convention "
                    "default (Mail.Read / Mail.Send / Calendars.ReadWrite / offline_access)."
                )
            default_scopes = flag_default_scopes
            default_scopes_source = "flag:--default-scopes"

        # PR #1220 codex r1: preserve the local-dev escape hatch
        # `MS365_REDIRECT_URI_ALLOW_LOCALHOST=1` across reruns.
        # CLI flag `--allow-localhost` takes priority (writes "1");
        # otherwise the existing value (if any) survives. Runtime
        # check in plugins/ms365/server.ts is strict `=== '1'` so we
        # only persist "1" — any truthy-looking pre-existing value is
        # treated as enabled and re-normalized to "1" on write.
        if args.allow_localhost:
            allow_localhost = "1"
        else:
            existing_allow = inspected["allow_localhost"]
            # Strict equality with the runtime check: only "1" is
            # honored. Any other pre-existing value is dropped on
            # rewrite (would not have been honored at runtime anyway).
            allow_localhost = "1" if existing_allow == "1" else ""

        result["redirect_uri"] = redirect_uri
        result["redirect_uri_source"] = redirect_uri_source
        result["tenant_id"] = tenant_id
        result["client_id"] = client_id
        result["default_upn"] = default_upn
        result["allow_localhost"] = allow_localhost
        result["default_scopes"] = default_scopes
        result["default_scopes_source"] = default_scopes_source

        # Issue #1356 root: run the Entra Graph probe BEFORE warnings
        # so a confirmed mismatch fails fast and the operator gets a
        # clean abort instead of a "wrote .env, now go fix Entra"
        # confused tail. Probe respects --skip-entra-probe and any
        # missing credential precondition (which short-circuits to
        # `skipped: creds_missing`) so OOTB / air-gapped / CI runs
        # never see a network call. --dry-run also skips the probe to
        # match the existing dry-run contract of "no external state
        # is touched".
        skip_probe = bool(getattr(args, "skip_entra_probe", False)) or bool(args.dry_run)
        if skip_probe:
            # Distinguish "operator opted out" from "dry-run" for the
            # audit surface, but use one stable `redirect_uri_check`
            # vocabulary so smoke pins stay stable.
            if args.dry_run:
                result["redirect_uri_check"] = "skipped (dry-run)"
            else:
                result["redirect_uri_check"] = "skipped (--skip-entra-probe)"
        else:
            probe = ms365_check_redirect_uri_registered(
                redirect_uri, tenant_id, client_id, client_secret
            )
            probe_status = str(probe.get("status") or "")
            if probe_status == "registered":
                result["redirect_uri_check"] = "ok"
                result["redirect_uri_registered"] = "yes"
            elif probe_status == "not_registered":
                # Fail-loud: this is the whole point of #1356. Surface
                # the list Entra DID return so the operator can spot a
                # typo (trailing slash, wrong host, http vs https).
                registered = probe.get("redirect_uris") or []
                listing = ", ".join(registered) if registered else "(none registered)"
                result["redirect_uri_check"] = "not_registered"
                result["redirect_uri_registered"] = "no"
                raise SetupError(
                    "redirect URI가 Entra app에 등록돼 있지 않습니다. "
                    "Authentication → Redirect URIs에 추가한 뒤 다시 실행하세요. "
                    f"(target: {redirect_uri}; 조회 결과: [{listing}]) "
                    "Probe를 건너뛰려면 --skip-entra-probe."
                )
            elif probe_status == "skipped":
                reason = str(probe.get("reason") or "unknown")
                # Map the internal skip reasons to a single operator-
                # facing line that names the root cause without leaking
                # the full Graph error body.
                reason_map = {
                    "creds_missing": "missing credentials (client_id/secret/tenant)",
                    "unreachable": "Graph endpoint unreachable",
                    "insufficient_permission": "insufficient app permission (need Application.Read.All)",
                    "no_access_token": "token endpoint returned no access_token",
                    "app_not_found": "appId not found in tenant",
                    "token_error": "client_credentials token request failed",
                    "missing_inputs": "internal: missing inputs to fetch",
                    "exception": "transport exception",
                    "redirect_uri_empty": "redirect_uri unresolved",
                }
                friendly = reason_map.get(reason, reason)
                result["redirect_uri_check"] = f"skipped ({friendly})"
                # Issue #1356 r2 (codex r1 BLOCKING 2): emit a durable
                # audit row for every probe skip. The 403 (Graph
                # `Authorization_RequestDenied`) path was previously
                # only visible on the wizard's stdout — an operator
                # triaging "wizard wrote .env without verifying the
                # redirect URI" had no machine-readable trail. Wire all
                # skipped reasons through audit so the chain stays
                # complete; the BLOCKING surface is `insufficient_permission`
                # but the same vocabulary is the right place to record
                # `unreachable` / `creds_missing` / etc.
                _audit_ms365_redirect_probe_skipped(
                    redirect_uri,
                    reason,
                    agent=getattr(args, "agent", None),
                )
            elif probe_status == "error":
                detail = str(probe.get("detail") or "").strip()
                # Any "error" surface from the probe layer is non-
                # fatal — best-effort contract. Annotate and continue.
                result["redirect_uri_check"] = "skipped (probe error)"
                if detail:
                    warnings.append(f"Entra redirect URI probe error: {detail}")
                # Same r2 audit emit as the skipped branch — the probe
                # said "error" rather than "skipped", but from the
                # operator's perspective the wizard still proceeded
                # without a verified registration, so the audit trail
                # must show it.
                _audit_ms365_redirect_probe_skipped(
                    redirect_uri,
                    "probe_error",
                    agent=getattr(args, "agent", None),
                    detail_extra={"probe_detail": detail[:200]} if detail else None,
                )

        if not tenant_id:
            warnings.append(
                "MS365_TENANT_ID is unset. The ms365 plugin exits at startup until "
                "MS365_TENANT_ID is present in .ms365/.env."
            )
        if not client_id:
            warnings.append(
                "MS365_CLIENT_ID is unset. The ms365 plugin exits at startup until "
                "MS365_CLIENT_ID is present in .ms365/.env."
            )
        if not client_secret:
            warnings.append(
                "MS365_CLIENT_SECRET is unset. The ms365 plugin exits at startup until "
                "MS365_CLIENT_SECRET is present in .ms365/.env."
            )

        # Issue #1356 tactical: when the probe was registered, the
        # "register this URI" cue would only confuse. When it wasn't,
        # the SetupError above already aborted. The cue is only useful
        # in the skipped + no-write paths. Always emit it (the no-op
        # cost on the registered path is trivial — one extra line),
        # but insert it at the FRONT of the warning list so the
        # operator-facing "next action" lives above the
        # MS365_TENANT_ID-unset family of plugin-readiness reminders.
        warnings.insert(
            0,
            "Register this redirect URI on the Entra app's Authentication → "
            f"Redirect URIs page: {redirect_uri}",
        )
        # And surface the explicit verification-skipped reminder when
        # the probe did not return a positive "registered" signal so
        # the operator knows the wizard could not auto-verify.
        if result.get("redirect_uri_registered") != "yes":
            warnings.append(
                "verification: Entra Authentication 페이지에서 redirect URI 등록 여부를 확인하세요. "
                "미등록 상태라면 다음 pair_start가 redirect_uri_mismatch로 실패합니다."
            )

        if args.dry_run:
            result["write_status"] = "dry_run"
            print_ms365_result(result)
            return 0

        # Issue #1215: explicit `mode=0o2770` for the v2 isolation
        # channel-state-dir contract (see discord_dir / teams_dir).
        _isolation_aware_mkdir(ms365_dir, mode=0o2770, agent=args.agent)
        env_lines = [f"MS365_REDIRECT_URI={redirect_uri}"]
        # PR #1220 codex r1: write the allow-localhost flag IMMEDIATELY
        # after MS365_REDIRECT_URI so the env file's localhost pair is
        # visually together for the operator inspecting the file by
        # hand. Only persisted when "1" — any other value would not be
        # honored by the runtime check anyway.
        if allow_localhost == "1":
            env_lines.append("MS365_REDIRECT_URI_ALLOW_LOCALHOST=1")
        if tenant_id:
            env_lines.append(f"MS365_TENANT_ID={tenant_id}")
        if client_id:
            env_lines.append(f"MS365_CLIENT_ID={client_id}")
        if client_secret:
            env_lines.append(f"MS365_CLIENT_SECRET={client_secret}")
        if default_upn:
            env_lines.append(f"MS365_DEFAULT_UPN={default_upn}")
        if default_scopes:
            env_lines.append(f"MS365_DEFAULT_SCOPES={default_scopes}")
        # mode=0o600 (the default). Explicit to match #1215 contract:
        # secret env files stay tight; only the parent dir gets 02770.
        _isolation_aware_save_text(inspected["env_path"], "\n".join(env_lines) + "\n", mode=0o600)
        # #1329 (Lane μ M6): see discord post-write normalize comment.
        _post_write_normalize_channel_cred_group(inspected["env_path"], args.agent)
        result["write_status"] = "ok"
        print_ms365_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        print_ms365_result(result, stream=sys.stderr)
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
    preserve other servers. Returns the merged document.

    #1175: existence probe routes through `_safe_load_json` (which itself
    sudo-escalates the existence check + the read), so a re-run against
    an isolated mattermost agent's `<workdir>/.mcp.json` does not raise
    PermissionError before the recovery flow's `_isolation_aware_save_*`
    can rewrite the file. Returns `{}` when the path is missing, just
    like the legacy `path.exists()` branch.
    """
    doc = _safe_load_json(mcp_path, {})
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

        # #1175: route through `_safe_load_json` so a re-run against a
        # preserved `access.json` under an isolated mattermost agent's
        # workdir does not raise PermissionError before the
        # preserve-and-merge flow can read the existing payload. The
        # safe wrapper returns the `default` ({}) for missing files,
        # matching the legacy `path.exists()` branch.
        existing_access_raw = _safe_load_json(access_path, {})
        existing_access: dict[str, Any] = (
            existing_access_raw if isinstance(existing_access_raw, dict) else {}
        )

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

        # Issue #1215: explicit `mode=0o2770` for the v2 isolation
        # channel-state-dir contract (see discord_dir above for the
        # rationale).
        _isolation_aware_mkdir(mattermost_dir, mode=0o2770, agent=args.agent)
        _isolation_aware_save_text(env_path, env_text)
        _isolation_aware_save_json(access_path, access_doc)
        _isolation_aware_save_json(mcp_path, mcp_doc)
        # #1329 (Lane μ M6): see discord post-write normalize comment.
        _post_write_normalize_channel_cred_group(env_path, args.agent)
        _post_write_normalize_channel_cred_group(access_path, args.agent)
        _post_write_normalize_channel_cred_group(mcp_path, args.agent)
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


# ---------------------------------------------------------------------------
# Issue #1427 Lane B — `setup template-sync`.
#
# Seed new (and optionally existing) agents from a reference agent's
# ROSTER-resident config. The hard contracts (see docs/template-sync-
# design.md):
#   * Reference read is ROSTER-ONLY — this command consumes the reference
#     agent's raw `BRIDGE_AGENT_*` values that the bash dispatch sourced
#     and forwarded via `--ref-*`. It never opens the reference's
#     $HOME/.claude, plugin cache, settings, env, .mcp.json, or any channel
#     secret file.
#   * Hard security redaction — channels are copied as DECLARATIONS only
#     (`plugin:teams@mkt`); no creds/tokens/MCP secrets/.env/access.json
#     ever appear in the candidate, diff, profile, or metadata.
#   * `permission_mode=legacy` is NEVER inherited — refused + omitted + warn.
#   * No guessing — a dimension the reference never set is surfaced as
#     "unset / reference missing", not a fabricated default.
# ---------------------------------------------------------------------------

# Canonical dimension order. model/effort/permission_mode are scalar;
# plugins/skills/channels are token lists (space/comma separated in the
# roster, normalized to a sorted, de-duped list here for determinism).
_TEMPLATE_SYNC_DIMENSIONS = (
    "model",
    "effort",
    "permission_mode",
    "plugins",
    "skills",
    "channels",
)

_TEMPLATE_SYNC_LIST_DIMENSIONS = frozenset({"plugins", "skills", "channels"})

# Roster variable name per dimension (Contract-I).
_TEMPLATE_SYNC_PROFILE_VARS = {
    "model": "BRIDGE_TEMPLATE_DEFAULT_MODEL",
    "effort": "BRIDGE_TEMPLATE_DEFAULT_EFFORT",
    "permission_mode": "BRIDGE_TEMPLATE_DEFAULT_PERMISSION_MODE",
    "plugins": "BRIDGE_TEMPLATE_DEFAULT_PLUGINS",
    "skills": "BRIDGE_TEMPLATE_DEFAULT_SKILLS",
    "channels": "BRIDGE_TEMPLATE_DEFAULT_CHANNELS",
}

# Runtime-affecting dimensions — any change to these on an existing agent
# requires a restart for the launch/plugin/skill/channel materialization to
# take effect.
_TEMPLATE_SYNC_RESTART_DIMENSIONS = frozenset(_TEMPLATE_SYNC_DIMENSIONS)

_TEMPLATE_SYNC_BEGIN_MARKER = "# === agb:template-defaults v1 (managed by `setup template-sync`) ==="
_TEMPLATE_SYNC_END_MARKER = "# === end agb:template-defaults ==="


def _template_sync_normalize_list(raw: str) -> list[str]:
    """Split a roster list value (space/comma separated) into a sorted,
    de-duped token list. Order is normalized so the candidate hash and
    diff are deterministic regardless of the reference's token order."""
    tokens: list[str] = []
    seen: set[str] = set()
    for chunk in re.split(r"[\s,]+", raw.strip()):
        token = chunk.strip()
        if not token or token in seen:
            continue
        seen.add(token)
        tokens.append(token)
    return sorted(tokens)


def _template_sync_channel_setup_hint(channel_decl: str) -> str | None:
    """Map a channel declaration (`plugin:teams@mkt`, `plugin:ms365`) to its
    per-channel setup-pending next-action. Declarations only — the operator
    re-populates credentials via the per-channel `setup` wizard. Returns
    None for declarations with no known credential wizard."""
    label = channel_decl
    if label.startswith("plugin:"):
        label = label[len("plugin:"):]
    # Strip the `@marketplace` qualifier.
    label = label.split("@", 1)[0].strip().lower()
    known = {"teams", "ms365", "discord", "telegram", "mattermost"}
    if label in known:
        return f"agb setup {label} <agent>"
    return None


def _template_sync_build_candidate(args: argparse.Namespace) -> dict[str, Any]:
    """Compute the redacted sync candidate from the reference's raw roster
    values (forwarded via `--ref-*`). Each dimension entry records:
      value   — the redacted candidate value (scalar str or token list)
      source  — "reference" | "bridge-default" | "unset"
      status  — "ok" | "unset / reference missing" | "refused: legacy"
    No secret material is ever read or emitted — channels stay declarations.
    """
    raw = {
        "model": args.ref_model,
        "effort": args.ref_effort,
        "permission_mode": args.ref_permission_mode,
        "plugins": args.ref_plugins,
        "skills": args.ref_skills,
        "channels": args.ref_channels,
    }
    candidate: dict[str, Any] = {}
    warnings: list[str] = []

    for dim in _TEMPLATE_SYNC_DIMENSIONS:
        ref_val = raw[dim]
        # `None` (the argparse sentinel) == reference never declared this
        # dimension. An explicit empty string == declared-but-empty, also
        # treated as "unset" (no token / no scalar to inherit).
        if ref_val is None or ref_val.strip() == "":
            if dim == "model":
                # Only model has a meaningful built-in default to fall back
                # to (the new-shape launch default). effort/pm/lists do not
                # — a missing list is genuinely empty, not "the default".
                candidate[dim] = {
                    "value": args.default_model,
                    "source": "bridge-default",
                    "status": "ok",
                }
            elif dim == "effort":
                candidate[dim] = {
                    "value": args.default_effort,
                    "source": "bridge-default",
                    "status": "ok",
                }
            else:
                candidate[dim] = {
                    "value": [] if dim in _TEMPLATE_SYNC_LIST_DIMENSIONS else "",
                    "source": "unset",
                    "status": "unset / reference missing",
                }
            continue

        if dim == "permission_mode" and ref_val.strip().lower() == "legacy":
            # Hard invariant: legacy is NEVER inherited.
            candidate[dim] = {
                "value": "",
                "source": "reference",
                "status": "refused: legacy",
            }
            warnings.append(
                "permission_mode=legacy on the reference agent is NEVER "
                "inherited — dimension omitted from the defaults profile."
            )
            continue

        if dim in _TEMPLATE_SYNC_LIST_DIMENSIONS:
            tokens = _template_sync_normalize_list(ref_val)
            candidate[dim] = {
                "value": tokens,
                "source": "reference",
                "status": "ok" if tokens else "unset / reference missing",
            }
        else:
            candidate[dim] = {
                "value": ref_val.strip(),
                "source": "reference",
                "status": "ok",
            }

    return {"dimensions": candidate, "warnings": warnings}


def _template_sync_parse_exclude(exclude_csv: str) -> tuple[set[str], dict[str, set[str]]]:
    """Parse `--exclude` into (excluded-dimensions, per-item-excludes).
    Entries: `model` (whole dimension) or `plugins:foo@mkt` (single item).
    Unknown dimension names raise SetupError so a typo never silently
    includes a dimension the operator meant to drop."""
    dims_out: set[str] = set()
    items_out: dict[str, set[str]] = {}
    for chunk in exclude_csv.split(","):
        entry = chunk.strip()
        if not entry:
            continue
        if ":" in entry:
            dim, item = entry.split(":", 1)
            dim = dim.strip()
            item = item.strip()
            if dim not in _TEMPLATE_SYNC_DIMENSIONS:
                raise SetupError(f"--exclude references unknown dimension: {dim!r}")
            if dim not in _TEMPLATE_SYNC_LIST_DIMENSIONS:
                raise SetupError(
                    f"--exclude per-item form (dim:item) only applies to "
                    f"list dimensions {sorted(_TEMPLATE_SYNC_LIST_DIMENSIONS)}; "
                    f"got {entry!r}"
                )
            items_out.setdefault(dim, set()).add(item)
        else:
            if entry not in _TEMPLATE_SYNC_DIMENSIONS:
                raise SetupError(f"--exclude references unknown dimension: {entry!r}")
            dims_out.add(entry)
    return dims_out, items_out


def _template_sync_apply_exclude(
    candidate: dict[str, Any],
    excluded_dims: set[str],
    excluded_items: dict[str, set[str]],
) -> tuple[dict[str, Any], list[str]]:
    """Apply the opt-out exclude set to the candidate. Returns the included
    map (dim -> entry, only dims that survive with a usable value) plus the
    ordered list of excluded dimension names (for metadata)."""
    included: dict[str, Any] = {}
    excluded_order: list[str] = []
    for dim in _TEMPLATE_SYNC_DIMENSIONS:
        entry = candidate["dimensions"][dim]
        if dim in excluded_dims:
            excluded_order.append(dim)
            continue
        # Drop dimensions with nothing usable: unset scalars/lists and the
        # legacy-refused permission_mode never reach the profile.
        if entry["status"].startswith("unset") or entry["status"].startswith("refused"):
            excluded_order.append(dim)
            continue
        if dim in _TEMPLATE_SYNC_LIST_DIMENSIONS:
            drop = excluded_items.get(dim, set())
            kept = [tok for tok in entry["value"] if tok not in drop]
            if not kept:
                excluded_order.append(dim)
                continue
            included[dim] = {**entry, "value": kept}
        else:
            included[dim] = entry
    return included, excluded_order


def _template_sync_candidate_hash(included: dict[str, Any]) -> str:
    """Stable hash of the REDACTED candidate summary (dimension -> value).
    Channels are declarations only, so this hash carries no secret bytes —
    it is safe to persist in the profile metadata."""
    parts = []
    for dim in _TEMPLATE_SYNC_DIMENSIONS:
        if dim not in included:
            continue
        val = included[dim]["value"]
        if isinstance(val, list):
            rendered = " ".join(val)
        else:
            rendered = str(val)
        parts.append(f"{dim}={rendered}")
    payload = "\n".join(parts)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _template_sync_render_profile(
    source_agent: str,
    included: dict[str, Any],
    excluded_order: list[str],
    updated_at: str,
    candidate_hash: str,
) -> str:
    """Render the Contract-I defaults-profile block (sourceable bash +
    machine-parseable). Only included dimensions emit a var; excluded /
    legacy-refused dimensions are documented in the meta line + a comment."""
    included_names = [d for d in _TEMPLATE_SYNC_DIMENSIONS if d in included]
    lines = [
        _TEMPLATE_SYNC_BEGIN_MARKER,
        (
            f"# meta: source_agent={source_agent} updated_at={updated_at} "
            f"included={','.join(included_names) or '(none)'} "
            f"excluded={','.join(excluded_order) or '(none)'} "
            f"hash={candidate_hash}"
        ),
    ]
    for dim in _TEMPLATE_SYNC_DIMENSIONS:
        var = _TEMPLATE_SYNC_PROFILE_VARS[dim]
        if dim not in included:
            continue
        val = included[dim]["value"]
        if isinstance(val, list):
            rendered = " ".join(val)
        else:
            rendered = str(val)
        lines.append(f'{var}="{rendered}"')
    if "permission_mode" in excluded_order:
        lines.append("# permission_mode intentionally omitted (legacy refused / excluded)")
    lines.append(_TEMPLATE_SYNC_END_MARKER)
    return "\n".join(lines) + "\n"


def _template_sync_read_existing_block(roster_text: str) -> str:
    """Extract the current template-defaults block from roster text (for the
    before/after diff). Empty string when no block exists yet."""
    start = roster_text.find(_TEMPLATE_SYNC_BEGIN_MARKER)
    if start == -1:
        return ""
    end = roster_text.find(_TEMPLATE_SYNC_END_MARKER, start)
    if end == -1:
        return ""
    return roster_text[start:end + len(_TEMPLATE_SYNC_END_MARKER)] + "\n"


def _template_sync_splice_block(roster_text: str, new_block: str) -> str:
    """Replace an existing template-defaults block in place, or append it.
    Idempotent shape: the markers always delimit exactly one block."""
    start = roster_text.find(_TEMPLATE_SYNC_BEGIN_MARKER)
    if start != -1:
        end = roster_text.find(_TEMPLATE_SYNC_END_MARKER, start)
        if end != -1:
            end_full = end + len(_TEMPLATE_SYNC_END_MARKER)
            # Swallow a single trailing newline so re-splicing does not
            # accumulate blank lines.
            if end_full < len(roster_text) and roster_text[end_full] == "\n":
                end_full += 1
            return roster_text[:start] + new_block + roster_text[end_full:]
    base = roster_text
    if base and not base.endswith("\n"):
        base += "\n"
    if base and not base.endswith("\n\n"):
        base += "\n"
    return base + new_block


def _template_sync_splice_into_roster_file(roster_path: Path, new_block: str) -> None:
    """Read the roster file (or seed a fresh shebang header when absent),
    splice the template-defaults block in place, and write the result via
    the isolation-aware save path. The single splice+write implementation
    shared by the wizard's gated `roster write-template-profile` call and
    any direct invocation — so the idempotent block shape (T8) can never
    drift between callers."""
    if _safe_path_check("exists", roster_path, _resolve_isolated_owner_for_path(roster_path)):
        roster_text = roster_path.read_text(encoding="utf-8")
    else:
        roster_text = "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"
    new_roster_text = _template_sync_splice_block(roster_text, new_block)
    _isolation_aware_save_text(roster_path, new_roster_text, mode=0o600)


def _detect_operator_caller_source() -> str:
    """Resolve the caller's trust bucket — the SAME contract as the bash
    `bridge_agent_update_caller_source` (lib/bridge-agent-update.sh) and the
    python `bridge-config.py:detect_caller_source`. Returns one of
    operator-tui / operator-trusted-id / agent-direct.

    `BRIDGE_CALLER_SOURCE` is the documented explicit override a verified
    channel handler (or the gated bash verb, after its own check) declares;
    an admin session whose BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID is
    auto-promoted (issue #1122); an interactive TTY is operator-tui;
    everything else is agent-direct."""
    explicit = os.environ.get("BRIDGE_CALLER_SOURCE", "").strip().lower()  # noqa: iso-helper-boundary — plain env read (trust-bucket override), not an iso file access
    if explicit in {"operator-tui", "operator-trusted-id"}:
        return explicit
    if explicit:
        return "agent-direct"
    session_agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()  # noqa: iso-helper-boundary — plain env read, not an iso file access
    admin_agent = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()  # noqa: iso-helper-boundary — plain env read, not an iso file access
    if session_agent and admin_agent and session_agent == admin_agent:
        return "operator-trusted-id"
    try:
        if sys.stdin.isatty() and sys.stdout.isatty():
            return "operator-tui"
    except (OSError, ValueError):
        pass
    return "agent-direct"


def cmd_template_profile_write(args: argparse.Namespace) -> int:
    """Splice a pre-rendered template-defaults block into the roster file.

    This is the WRITE half of `setup template-sync`, deliberately split out
    so it is reached only through the gated+audited
    `agent-bridge agent roster write-template-profile` bash verb — which
    captures the before/after sha + emits the system_config_mutation audit
    row. The block text is rendered upstream by `cmd_template_sync` and
    handed over via --block-file; this command performs no candidate logic
    and never inspects a reference agent.

    Defense-in-depth: this command independently enforces the SAME
    operator-tui / operator-trusted-id caller-source gate the bash verb
    applies (via the canonical BRIDGE_CALLER_SOURCE / admin-session / TTY
    contract — NOT a forgeable bespoke sentinel), so a direct
    `python3 bridge-setup.py template-profile-write ...` invocation by an
    agent-direct caller is denied and CANNOT mutate the roster un-gated."""
    caller_source = _detect_operator_caller_source()
    if caller_source not in {"operator-tui", "operator-trusted-id"}:
        print(
            f"deny: caller source {caller_source} is not allowed to mutate "
            "system config (need operator-tui or operator-trusted-id). "
            "Invoke `agent-bridge agent roster write-template-profile`.",
            file=sys.stderr,
        )
        return 1
    roster_path = Path(args.roster_file)
    block_text = Path(args.block_file).read_text(encoding="utf-8")
    _template_sync_splice_into_roster_file(roster_path, block_text)
    return 0


def _template_sync_profile_writer_cmd() -> list[str]:
    """Resolve the gated profile-write verb. Defaults to the canonical
    `agent-bridge agent roster write-template-profile` (the same `agent
    roster` sub-dispatch that hosts materialize-fields); overridable via
    BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD for tests that need to point at
    an absolute bridge-agent.sh path."""
    override = os.environ.get("BRIDGE_TEMPLATE_SYNC_PROFILE_WRITER_CMD", "").strip()  # noqa: iso-helper-boundary — plain env read (os.environ matches the `.env` ratchet pattern), not an iso file access
    if override:
        return override.split()
    agb = os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", "").strip() or "agent-bridge"  # noqa: iso-helper-boundary — plain env read (os.environ matches the `.env` ratchet pattern), not an iso file access
    return [agb, "agent", "roster", "write-template-profile"]


def _template_sync_materialize_cmd() -> list[str]:
    """Resolve the Contract-II writer command. Defaults to Lane A's
    canonical `agent-bridge agent roster materialize-fields` verb (the
    `roster` sub-dispatch lives under the `agent` subcommand — there is no
    top-level `agent-bridge roster`); overridable via
    BRIDGE_TEMPLATE_SYNC_MATERIALIZE_CMD so the unit smoke can stub the
    writer without an end-to-end roster mutation."""
    override = os.environ.get("BRIDGE_TEMPLATE_SYNC_MATERIALIZE_CMD", "").strip()  # noqa: iso-helper-boundary — plain env read (os.environ matches the `.env` ratchet pattern), not an iso file access
    if override:
        return override.split()
    agb = os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", "").strip() or "agent-bridge"  # noqa: iso-helper-boundary — plain env read (os.environ matches the `.env` ratchet pattern), not an iso file access
    return [agb, "agent", "roster", "materialize-fields"]


def _template_sync_backfill_target(
    target: str,
    included: dict[str, Any],
    dry_run: bool,
) -> dict[str, Any]:
    """Apply the included defaults to an existing agent via Contract-II.
    Builds the materialize-fields argv from the included dimensions (legacy
    is already excluded upstream), invokes the writer, and reports the
    structured result + restart-required flag. Never writes settings.json —
    the writer is a roster-only contract."""
    cmd = _template_sync_materialize_cmd()
    cmd += [target]
    for dim in _TEMPLATE_SYNC_DIMENSIONS:
        if dim not in included:
            continue
        val = included[dim]["value"]
        rendered = " ".join(val) if isinstance(val, list) else str(val)
        cmd += [f"--{dim.replace('_', '-')}", rendered]
    if dry_run:
        cmd.append("--dry-run")
    cmd.append("--json")
    restart_required = any(
        dim in _TEMPLATE_SYNC_RESTART_DIMENSIONS for dim in included
    )
    entry: dict[str, Any] = {
        "agent": target,
        "restart_required": restart_required,
        "writer_cmd": cmd[0],
    }
    try:
        proc = subprocess.run(  # noqa: raw-subprocess — Contract-II writer call
            cmd,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        entry["status"] = "writer_missing"
        entry["error"] = str(exc)
        return entry
    entry["rc"] = proc.returncode
    entry["status"] = "ok" if proc.returncode == 0 else "error"
    if proc.returncode != 0:
        entry["error"] = (proc.stderr or proc.stdout or "").strip()
    return entry


def _template_sync_print_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    """Structured result to stdout (machine-parseable JSON). The human
    before/after summary is written separately to stderr by the caller so
    the stdout stream stays clean for the admin agent to parse."""
    print(json.dumps(result, ensure_ascii=False, indent=2), file=stream)


def cmd_template_sync(args: argparse.Namespace) -> int:
    source_agent = args.from_agent
    result: dict[str, Any] = {
        "command": "template-sync",
        "source_agent": source_agent,
        "roster_file": args.roster_file,
        "write_status": "pending",
        "dry_run": bool(args.dry_run),
    }
    # ROOT caller-source gate: `setup template-sync` mutates system config
    # (the controller-owned defaults profile + the --targets backfill) and
    # resolves caller-overridable writer commands
    # (BRIDGE_TEMPLATE_SYNC_{PROFILE_WRITER,MATERIALIZE}_CMD). Gate the WHOLE
    # command up front — before any candidate compute / reference read /
    # dry-run / writer resolution — so an agent-direct caller cannot reach ANY
    # override-resolving path, including the dry-run backfill that runs the
    # materialize override despite --dry-run (#1432 r2 BLOCKING). The write
    # verbs keep their own gate as defense-in-depth.
    caller_source = _detect_operator_caller_source()
    if caller_source not in {"operator-tui", "operator-trusted-id"}:
        result["write_status"] = "denied"
        result["error"] = (
            f"deny: caller source {caller_source} is not allowed to run "
            "setup template-sync (need operator-tui or operator-trusted-id)"
        )
        _template_sync_print_result(result, stream=sys.stderr)
        return 1
    try:
        # v1 Claude-only. A non-claude reference cannot supply these
        # dimensions in a portable way (codex-engine launch semantics
        # differ), so fail loud rather than synthesize a bogus candidate.
        ref_engine = (args.ref_engine or "").strip().lower()
        if ref_engine and ref_engine != "claude":
            raise SetupError(
                f"template-sync v1 supports Claude reference agents only; "
                f"reference '{source_agent}' engine is {ref_engine!r}."
            )

        excluded_dims, excluded_items = _template_sync_parse_exclude(args.exclude)

        candidate = _template_sync_build_candidate(args)
        result["warnings"] = candidate["warnings"]
        # Surface the full per-dimension candidate (redacted) so the
        # operator/admin sees reference-vs-default and unset status.
        result["candidate"] = {
            dim: {
                "value": candidate["dimensions"][dim]["value"],
                "source": candidate["dimensions"][dim]["source"],
                "status": candidate["dimensions"][dim]["status"],
            }
            for dim in _TEMPLATE_SYNC_DIMENSIONS
        }

        included, excluded_order = _template_sync_apply_exclude(
            candidate, excluded_dims, excluded_items
        )
        result["included_dimensions"] = [
            d for d in _TEMPLATE_SYNC_DIMENSIONS if d in included
        ]
        result["excluded_dimensions"] = excluded_order

        # Per-channel setup-pending next-actions (declarations only).
        channel_next_actions: list[dict[str, str]] = []
        if "channels" in included:
            for decl in included["channels"]["value"]:
                hint = _template_sync_channel_setup_hint(decl)
                channel_next_actions.append(
                    {
                        "channel": decl,
                        "next_action": hint or "(no credential wizard — declaration only)",
                        "state": "setup-pending",
                    }
                )
        result["channel_next_actions"] = channel_next_actions

        updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        candidate_hash = _template_sync_candidate_hash(included)
        result["candidate_hash"] = candidate_hash

        new_block = _template_sync_render_profile(
            source_agent, included, excluded_order, updated_at, candidate_hash
        )
        result["profile_block"] = new_block

        roster_path = Path(args.roster_file)
        if _safe_path_check("exists", roster_path, _resolve_isolated_owner_for_path(roster_path)):
            roster_text = roster_path.read_text(encoding="utf-8")
        else:
            roster_text = "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"
        existing_block = _template_sync_read_existing_block(roster_text)
        result["before_block"] = existing_block
        result["after_block"] = new_block

        # Before/after human summary to STDERR (stdout stays structured).
        _template_sync_emit_summary(result, stream=sys.stderr)

        targets = [t.strip() for t in args.targets.split(",") if t.strip()]
        result["targets"] = targets

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["backfill"] = [
                _template_sync_backfill_target(t, included, dry_run=True)
                for t in targets
            ]
            _template_sync_print_result(result)
            return 0

        # The profile write goes through the gated+audited
        # `agent-bridge agent roster write-template-profile` verb — the same
        # operator-tui / operator-trusted-id system-config boundary that
        # `agent create` enforces, plus a system-config audit row. The
        # profile drives every future `agent create`, so it must NOT be a
        # weaker write path than the per-agent materialize writer.
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", suffix=".block", delete=False
        ) as block_fh:
            block_fh.write(new_block)
            block_path = block_fh.name
        try:
            writer_cmd = _template_sync_profile_writer_cmd()
            writer_cmd += [
                "--source-agent", source_agent,
                "--roster-file", str(roster_path),
                "--block-file", block_path,
            ]
            proc = subprocess.run(  # noqa: raw-subprocess — gated profile-write verb call
                writer_cmd,
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            try:
                os.unlink(block_path)  # noqa: raw-pathlib-controller-only — controller-owned tempfile in TMPDIR, never an isolated tree
            except OSError:
                pass
        if proc.returncode != 0:
            result["write_status"] = "profile_write_error"
            result["error"] = (
                "profile write verb failed (rc="
                f"{proc.returncode}): "
                + ((proc.stderr or proc.stdout or "").strip() or "(no output)")
            )
            _template_sync_print_result(result, stream=sys.stderr)
            return 1
        result["write_status"] = "ok"

        # Apply to existing --targets via Contract-II (Lane A's writer).
        result["backfill"] = [
            _template_sync_backfill_target(t, included, dry_run=False)
            for t in targets
        ]

        # A backfill writer failure (non-zero rc, writer missing) must NOT
        # be swallowed: the profile block landed, but one or more selected
        # existing agents were NOT materialized. Surface it as a non-zero
        # exit so an operator/admin sees the partial failure instead of
        # trusting a rc=0 that contradicts the per-target JSON.
        failed = [
            entry for entry in result["backfill"]
            if entry.get("status") != "ok"
        ]
        if failed:
            result["write_status"] = "backfill_error"
            result["error"] = (
                "backfill writer failed for: "
                + ", ".join(str(entry.get("agent", "?")) for entry in failed)
            )
            _template_sync_print_result(result)
            return 1

        _template_sync_print_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        _template_sync_print_result(result, stream=sys.stderr)
        return 1


def _template_sync_emit_summary(result: dict[str, Any], *, stream: Any = sys.stderr) -> None:
    """Human before/after summary to stderr."""
    print("[setup template-sync] candidate (reference: "
          f"{result['source_agent']})", file=stream)
    for dim in _TEMPLATE_SYNC_DIMENSIONS:
        entry = result["candidate"][dim]
        val = entry["value"]
        rendered = " ".join(val) if isinstance(val, list) else (val or "(empty)")
        included = dim in result.get("included_dimensions", [])
        mark = "include" if included else "exclude"
        print(f"  [{mark}] {dim}: {rendered}  ({entry['source']} / {entry['status']})",
              file=stream)
    for warning in result.get("warnings", []):
        print(f"  ! {warning}", file=stream)
    for action in result.get("channel_next_actions", []):
        print(f"  channel {action['channel']}: {action['state']} -> {action['next_action']}",
              file=stream)


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
    # Issue #1354 R2 (codex r1 BLOCKING #1): `--app-password-file` and
    # `--app-password-stdin` are mutually exclusive. argparse raises a
    # non-zero exit when both are passed; pre-R2 the wizard silently
    # preferred stdin and dropped the file value (precedence in
    # `read_secret_value`), making it possible to leak the wrong secret
    # without any signal to the operator.
    #
    # `default=None` (not `default=""`) so argparse can distinguish "user
    # passed `--app-password-file ''`" from "user did not pass the flag
    # at all". With `default=""`, argparse treats an explicit empty
    # value as a no-op and lets `--app-password-file '' --app-password-stdin`
    # bypass the mutex group (codex r2 review surfaced this argparse
    # quirk). `read_secret_value` already treats `None` and `""` as the
    # same "no file path" signal downstream.
    teams_password_source = teams_parser.add_mutually_exclusive_group()
    teams_password_source.add_argument("--app-password-file", default=None)
    # Issue #1354: explicit stdin path for the secret. Bash process
    # substitution `<(...)` lands as `/dev/fd/N` which is portable when the
    # wizard does NOT cross a sudo boundary, but breaks when it does.
    # `--app-password-stdin` is the unambiguous escape hatch — pipe the
    # secret into stdin and the wizard reads it once.
    teams_password_source.add_argument("--app-password-stdin", action="store_true")
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

    # Issue #1209: ms365 channel setup wizard. Pairs with the fail-loud
    # `resolveRedirectUri()` in `plugins/ms365/server.ts` so the
    # operator never has to discover `MS365_REDIRECT_URI` by Azure AD
    # error after a failed first OAuth click.
    ms365_parser = subparsers.add_parser("ms365")
    ms365_parser.add_argument("--agent", required=True)
    ms365_parser.add_argument("--ms365-dir", required=True)
    ms365_parser.add_argument(
        "--teams-state-file",
        default="",
        help="Path to .teams/state.json to derive redirect URI from validation.messaging_endpoint (optional)",
    )
    ms365_parser.add_argument("--redirect-uri", default="")
    ms365_parser.add_argument("--messaging-endpoint", default="")
    ms365_parser.add_argument("--tenant-id", default="")
    ms365_parser.add_argument("--client-id", default="")
    ms365_parser.add_argument("--client-secret", default="")
    # Issue #1354 R2 (codex r1 BLOCKING #1): `--client-secret-file` and
    # `--client-secret-stdin` are mutually exclusive. See teams parser
    # `--app-password-*` mutex for rationale (including the `default=None`
    # choice that avoids the argparse default-equivalence quirk).
    ms365_secret_source = ms365_parser.add_mutually_exclusive_group()
    ms365_secret_source.add_argument("--client-secret-file", default=None)
    # Issue #1354: explicit stdin path for the secret. See teams parser
    # `--app-password-stdin` for rationale (process substitution + sudo
    # subshell drops the `/dev/fd/N` mapping).
    ms365_secret_source.add_argument("--client-secret-stdin", action="store_true")
    ms365_parser.add_argument("--default-upn", default="")
    # Issue #1355 r2 (codex r1 BLOCKING 1): argparse `default=""` cannot
    # distinguish "flag omitted" from `--default-scopes ""` — both land
    # as the empty string. Use `default=None` as a sentinel so the
    # cmd_ms365 branch can tell the two apart and treat an explicit
    # empty as an error (no Graph call ever succeeds without at least
    # one scope) instead of silently expanding to the broad convention
    # default. See cmd_ms365's `flag_default_scopes` branch.
    ms365_parser.add_argument("--default-scopes", default=None)
    # PR #1220 codex r1: explicit opt-in for local-dev redirect URIs.
    # When set, persists `MS365_REDIRECT_URI_ALLOW_LOCALHOST=1` to
    # `.ms365/.env`. Without this flag, the wizard preserves any
    # pre-existing allow value but does not introduce one.
    ms365_parser.add_argument(
        "--allow-localhost",
        action="store_true",
        help="Persist MS365_REDIRECT_URI_ALLOW_LOCALHOST=1 (local-dev opt-in; the runtime plugin rejects localhost redirect URIs without this flag).",
    )
    # Issue #1356: opt out of the Entra Graph round-trip that verifies
    # the operator-supplied redirect URI is registered on the Entra app
    # registration. Useful for OOTB / air-gapped / CI runs where the
    # Graph endpoint is unreachable or the app lacks Application.Read.All.
    # The probe ALREADY short-circuits on missing credentials so an
    # OOTB operator without client-id/secret never sees a Graph call;
    # this flag is for the rarer "have credentials, do not call Graph"
    # case (CI smoke).
    ms365_parser.add_argument(
        "--skip-entra-probe",
        action="store_true",
        help="Skip the Entra app redirect URI registration probe (#1356).",
    )
    ms365_parser.add_argument("--yes", action="store_true")
    ms365_parser.add_argument("--dry-run", action="store_true")
    ms365_parser.set_defaults(handler=cmd_ms365)

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

    # Issue #1427 Lane B: `setup template-sync` — seed new (and optionally
    # existing) agents from a reference agent's roster-resident config.
    # The bash dispatch sources the roster and passes the reference
    # agent's RAW `BRIDGE_AGENT_*` values via `--ref-*`. Stage 2 computes
    # the redacted candidate, diffs it against the existing defaults
    # profile, applies the opt-out exclude set, writes the Contract-I
    # block into agent-roster.local.sh, and (for --targets) calls Lane A's
    # `agent-bridge agent roster materialize-fields` per target.
    #
    # `--ref-*` use `default=None` (not "") as the sentinel so the
    # candidate compute can tell "reference did not set this dimension"
    # (→ "unset / reference missing", never guessed) apart from an
    # explicit empty value. The reference read is ROSTER-ONLY by
    # contract: this command NEVER opens the reference's $HOME/.claude,
    # plugin cache, settings, env, .mcp.json, or any channel secret file.
    template_sync_parser = subparsers.add_parser("template-sync")
    template_sync_parser.add_argument("--from", dest="from_agent", required=True)
    template_sync_parser.add_argument("--roster-file", required=True)
    template_sync_parser.add_argument("--ref-engine", default=None)
    template_sync_parser.add_argument("--ref-model", default=None)
    template_sync_parser.add_argument("--ref-effort", default=None)
    template_sync_parser.add_argument("--ref-permission-mode", default=None)
    template_sync_parser.add_argument("--ref-plugins", default=None)
    template_sync_parser.add_argument("--ref-skills", default=None)
    template_sync_parser.add_argument("--ref-channels", default=None)
    # Built-in bridge defaults (new-shape launch fallback) — surfaced so
    # the candidate can label a value "reference" vs "bridge default" and
    # so dim 1's opus-4-7->opus-4-8 refresh shows up in the dry-run diff.
    template_sync_parser.add_argument("--default-model", default="claude-opus-4-8")
    template_sync_parser.add_argument("--default-effort", default="xhigh")
    # CSV of dimension names (model,effort,permission_mode,plugins,skills,
    # channels) and/or `dim:item` per-item exclusions (opt-out wizard auto
    # mode). Accept-all is the default when omitted.
    template_sync_parser.add_argument("--exclude", default="")
    # CSV of EXISTING agents to backfill via Contract-II.
    template_sync_parser.add_argument("--targets", default="")
    template_sync_parser.add_argument("--yes", action="store_true")
    template_sync_parser.add_argument("--dry-run", action="store_true")
    template_sync_parser.set_defaults(handler=cmd_template_sync)

    # Internal write half of template-sync, reached only via the gated
    # `agent-bridge agent roster write-template-profile` bash verb.
    template_profile_write_parser = subparsers.add_parser("template-profile-write")
    template_profile_write_parser.add_argument("--roster-file", required=True)
    template_profile_write_parser.add_argument("--block-file", required=True)
    template_profile_write_parser.set_defaults(handler=cmd_template_profile_write)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
