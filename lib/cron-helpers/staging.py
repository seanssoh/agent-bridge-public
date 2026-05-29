#!/usr/bin/env python3
"""staging.py — Issue #1359 tactical staging delegation for `agb cron create`
from an iso v2 agent UID.

The controller owns `cron/jobs.json` (mode 0640, group=controller_group),
so an iso v2 agent UID cannot write the file directly. This helper bridges
the boundary by serializing the mutation request to a staging file under
`$BRIDGE_STATE_DIR/cron-staging/<actor_agent>/<uuid>.json` (mode 0660,
owner=iso UID, group=ab-agent-<actor_agent>). The daemon picks up
staging files on its cron-sync tick, validates the caller, applies the
mutation via `bridge-cron.py native-create`, and writes the result
back to `<uuid>.result.json` for the iso UID poller.

Root scope (daemon IPC Unix socket) is OUT OF SCOPE for this PR — a
follow-up issue tracks the sync RPC contract.

Per-agent staging boundary (codex r1 #1)
----------------------------------------
The staging tree is rooted per-agent: `<staging-root>/<actor_agent>/`.
The matrix grants each per-agent subdir mode 2770 owner=controller
group=ab-agent-<actor_agent>, so only that agent's iso UID has
group-write. The shared dir (`<staging-root>`) is mode 2770
group=ab-shared so every iso UID can `cd` into it to reach its own
subdir, but inter-agent file writes (write into a peer agent's
subdir, pre-create a peer's result.json, rewrite a peer's request
file) are blocked at the group-write boundary.

The daemon scans `<staging-root>/<agent>/*.json` and recovers the
actor_agent from the path — not from the payload — so a payload that
lies about actor_agent in its body still gets resolved to the
directory-owning agent for the iso UID check.

Subcommands
-----------
- write-request <staging-root> <actor-agent> <payload-json>
    Iso UID side. Allocate a uuid, write
    `<staging-root>/<actor-agent>/<uuid>.json` mode 0660 with the
    payload JSON, and print the uuid. Caller polls for the
    `.result.json` sibling. The per-agent subdir is created if
    missing (under iso UID umask, but the matrix-grant path tightens
    perms idempotently).

    #1379: the staging file is explicitly `chgrp`-ed to the shared
    cross-class group `ab-agent-<actor-agent>` (resolved from the
    optional `AGB_STAGE_FILE_GROUP` env the matrix-aware bash caller
    sets, the per-agent dir's own group, or `<BRIDGE_AGENT_GROUP_PREFIX>
    <actor-agent>`) BEFORE the atomic rename, and the per-agent subdir
    is self-healed to 2770+setgid. Without this the file lands with the
    iso UID's user-private group `agent-bridge-<a>` (fresh-install path,
    no setgid on the dir), the controller is not a member, and the
    daemon's read is denied → 30s pickup timeout → silent skip.

- read-result <staging-root> <actor-agent> <uuid>
    Iso UID side. Print the result.json content if present, else
    exit non-zero. The bash poller decides timeout.

- scan-pending <staging-root>
    Controller / daemon side. Walk every per-agent subdir and emit one
    JSON object per pending staging file (one per line): `{"uuid": ...,
    "actor_agent": ..., "path": ..., "owner_uid": ..., "result_path": ...,
    "mtime_age_seconds": ..., "stale": ...}`. Files with an existing
    `.result.json` are skipped (already applied). Files older than
    `BRIDGE_CRON_STAGING_STALE_SECONDS` (default 300) are emitted
    with `stale: true` so the daemon can audit + sweep them.

- apply <staging-root> <actor-agent> <uuid> <jobs-file>
    Controller / daemon side. Validate the staging file's owner UID
    matches the agent's iso UID (`actor_uid` in payload matches the
    file owner AND the actor_agent's roster os_user resolves to the
    same UID), then build a `bridge-cron.py native-create` argv from
    the payload, run it as a subprocess (controller permissions), and
    write the result file. The actor_agent is taken from the CLI
    arg (which the daemon resolves from the staging path), so a payload
    that contradicts the dirname is rejected with actor_agent_mismatch.

    #1383: the daemon-written `<uuid>.result.json` is explicitly
    `chgrp`-ed to the canonical `ab-agent-<actor>` group (mode 0660)
    before the atomic rename, so the iso UID owner of the request can
    read its OWN result. Without this the controller's write lands in the
    controller's default group on a fresh-install path (no setgid on the
    subdir yet) and the iso UID gets `PermissionError [Errno 13]`. The
    result-leg chgrp is fail-loud-but-publish (logs loud on a verify
    failure but still publishes — the result file is the only channel
    back to the iso poller; refusing to write it would strand the poller
    and turn the request into a poison-retry).
    Result schema:

        {
          "schema_version": 1,
          "uuid": "...",
          "action": "create",
          "actor_agent": "...",
          "status": "ok"|"error",
          "cron_id": "..." | null,
          "error": null | "string",
          "applied_at": "<iso ts>",
          "audit_action": "cron_staging_applied" | "cron_staging_rejected"
        }

    The exit code is 0 on apply, non-zero on validation failure so the
    daemon caller can emit the matching audit row.

- sweep-stale <staging-dir> <stale-seconds>
    Controller / daemon side. Remove staging files (and any sibling
    `.result.json`) older than `<stale-seconds>` AND without a paired
    `.result.json`. Prints one JSON line per swept file. Used by the
    daemon to bound runaway disk usage when an iso UID writes a payload
    and crashes before reading the result.

- parse-row <json-string>
    Controller / daemon side. Parse a `scan-pending` JSON row and print
    the `uuid=`/`actor_agent=`/`owner_uid=`/`stale=` lines the daemon's
    apply loop greps for. Extracted from the inline heredoc-stdin at
    bridge-daemon.sh:8997 (footgun #11). Emits nothing + exit 0 on a
    parse error so the bash `|| continue` skips the row.

- parse-result <result-path>
    Controller / daemon side. Parse a `<uuid>.result.json` file and print
    the `audit_action=`/`actor_agent=`/`status=`/`cron_id=`/`error=` lines
    the daemon's audit emitter greps for. Extracted from the inline
    heredoc-stdin at bridge-daemon.sh:9077 (footgun #11). Emits nothing +
    exit 0 on a read/parse error so the bash `|| _result_parsed=""` holds.

- parse-swept <json-string>
    Controller / daemon side. Parse a `sweep-stale` JSON row and print
    the `uuid=`/`age=` lines (age from `mtime_age_seconds`) the daemon's
    sweep audit emitter greps for. Extracted from the inline heredoc-stdin
    at bridge-daemon.sh:9130 (footgun #11). Emits nothing + exit 0 on a
    parse error so the bash `|| continue` skips the row.

Payload schema (canonical, schema_version=1)
--------------------------------------------
{
  "schema_version": 1,
  "action": "create",
  "actor_agent": "<agent name>",
  "actor_uid": <int>,
  "submitted_at": "<iso ts>",
  "agent": "<target cron agent — must equal actor_agent>",
  "schedule": "0 5 * * *" | null,
  "at": "<iso datetime>" | null,
  "tz": "Asia/Seoul",
  "title": "...",
  "payload": null | "...",
  "payload_file": null | "...",
  "kind": "text" | "shell",
  "disabled": false,
  "delete_after_run": false
}

Schedule vs at: exactly one of `schedule`/`at` must be non-null.
Payload vs payload_file: at most one is non-null (text kind only).

Isolation guarantee
-------------------
Per the issue body's "격리 보장" requirement:
- `actor_agent == payload.agent` (an iso UID cannot create a cron for
  another agent).
- File owner UID matches the iso UID for `actor_agent` (resolved via
  the agent's `os_user` roster field). Defeats a forged staging file
  written by a non-iso UID or by a different agent's UID.
- `payload.actor_uid == os.stat(path).st_uid` (defense-in-depth — a
  process that drops privileges between writing the payload and the
  daemon's apply tick still has its identity pinned in the payload).
"""

import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

SCHEMA_VERSION = 1


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class StagingGroupError(Exception):
    """Raised when the requested staging-file group could not be applied
    AND verified before publish (#1379 codex r2 BLOCKING). The caller
    must surface this as an explicit error rather than printing a
    success uuid — a file published with the wrong (user-private) group
    reproduces the very daemon-read-denied pickup-timeout this fix
    closes, but silently."""


def _payload_atomic_write(
    path: Path, payload: Dict[str, Any], mode: int, gid: Optional[int] = None
) -> None:
    tmp = path.parent / (path.name + ".tmp." + str(os.getpid()))
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, mode)
    # #1379: chgrp the temp file BEFORE the atomic rename so the final
    # file is never visible to a scanner with the wrong (user-private)
    # group. The caller pre-checks membership in `_resolve_staging_gid`,
    # so the chown should succeed; but a chgrp can still fail or no-op
    # under an NSS/group race, a read-only/odd FS, or a stale group.
    #
    # codex r2 BLOCKING: this MUST be fail-loud, NOT best-effort. If the
    # chown raises OR the post-chown stat does not confirm the requested
    # gid, raise StagingGroupError and unlink the temp WITHOUT publishing
    # — otherwise the file lands with the user-private group and the
    # caller still prints a success uuid, silently re-creating the
    # 30s pickup-timeout bug this fix exists to close.
    if gid is not None:
        try:
            os.chown(tmp, -1, gid)
            # chown may clear the setgid/setuid bits on some platforms;
            # re-assert the requested mode.
            os.chmod(tmp, mode)
            applied_gid = int(os.stat(tmp).st_gid)
        except OSError as exc:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise StagingGroupError(
                f"chgrp staging file to gid={gid} failed: {exc!r}"
            ) from exc
        if applied_gid != gid:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise StagingGroupError(
                f"chgrp staging file verify mismatch: requested gid={gid} "
                f"observed gid={applied_gid}"
            )
    os.replace(tmp, path)


def _result_atomic_write(
    path: Path, payload: Dict[str, Any], mode: int, gid: Optional[int] = None
) -> None:
    """Atomic write for the daemon→iso `<uuid>.result.json` leg (Issue
    #1383). Like `_payload_atomic_write` it chgrp+verifies before the
    rename, BUT the fail-loud contract is different by design:

    - Request leg (`_payload_atomic_write`, #1379): a chgrp failure raises
      StagingGroupError and REFUSES to publish — the iso caller sees the
      error directly and never polls a daemon-unreadable request.

    - Result leg (here): the result file is the ONLY channel back to the
      iso poller. Refusing to publish would (a) strand the poller until
      its 30s timeout AND (b) leave the request file un-applied so the
      daemon re-applies the same payload every tick (the "daemon retry
      poison" foot-gun). So when the canonical-group chgrp cannot be
      applied + verified we log LOUD to stderr (the daemon surfaces it in
      its tick log / audit) but STILL publish the result so the poller
      terminates. The loud log — not a silent best-effort no-op — is the
      #1383 fail-loud signal: a controller-grouped result that the iso UID
      cannot read is a defect worth a visible warning, but it must not
      escalate into a stranded poller + poison-retry loop.

    When `gid is None` (non-iso / shared mode / no canonical group) the
    write is plain best-effort, identical to the pre-#1383 behavior — the
    controller-owned result file is fine when there is no iso reader."""
    tmp = path.parent / (path.name + ".tmp." + str(os.getpid()))
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, mode)
    if gid is not None:
        # Fail-loud-but-publish: a chgrp/verify failure logs LOUD to stderr
        # (the #1383 signal) but we deliberately fall through to publish in
        # EVERY branch below — never raise, never skip the os.replace — so
        # the iso poller is not stranded and the request does not become a
        # poison-retry. Contrast _payload_atomic_write (request leg), which
        # raises StagingGroupError and refuses to publish.
        try:
            os.chown(tmp, -1, gid)
            # chown may clear setgid/setuid bits on some platforms.
            os.chmod(tmp, mode)
            applied_gid = int(os.stat(tmp).st_gid)
            if applied_gid != gid:
                sys.stderr.write(
                    "staging.py write-result: chgrp result file verify "
                    f"mismatch (requested gid={gid} observed gid={applied_gid}) "
                    f"for {path.name} — iso UID may be unable to read its "
                    "result (Issue #1383). Publishing anyway to avoid a "
                    "stranded poller + poison-retry loop.\n"
                )
        except OSError as exc:
            sys.stderr.write(
                "staging.py write-result: chgrp result file to "
                f"gid={gid} failed: {exc!r} for {path.name} — iso UID may be "
                "unable to read its result (Issue #1383). Publishing anyway "
                "to avoid a stranded poller + poison-retry loop.\n"
            )
    os.replace(tmp, path)


def _user_private_gid() -> Optional[int]:
    """The writer's user-private GID — the group a fresh useradd assigns
    as the primary group (e.g. `agent-bridge-<a>`). A staging file that
    lands with THIS group is exactly the #1379 bug: the controller is
    not a member, so the daemon's read is denied. Returns the effective
    GID, or None if it cannot be resolved.
    """
    try:
        return os.getegid()
    except OSError:
        return None


def _gid_for_group_name(group_name: str) -> Optional[int]:
    """Resolve a group NAME to its GID via the group database. Returns
    None when the group does not exist (fresh-install before groupadd)
    or `grp` is unavailable (non-POSIX). Pure lookup — no privilege."""
    if not group_name:
        return None
    try:
        import grp

        return grp.getgrnam(group_name).gr_gid
    except KeyError:
        return None
    except Exception:
        return None


def _writer_in_group(gid: int) -> bool:
    """True when the current process is a member of `gid` (primary or
    supplementary). `os.chgrp`/`os.chown` to a group succeeds only when
    the unprivileged caller is a member of the target group, so we
    pre-check membership to avoid a guaranteed-to-fail chown that would
    surface a confusing PermissionError."""
    try:
        if os.getegid() == gid or os.getgid() == gid:
            return True
    except OSError:
        pass
    try:
        return gid in os.getgroups()
    except OSError:
        return False


def _gid_to_group_name(gid: int) -> Optional[int]:
    """Resolve a GID back to its group NAME (for the actor-specific
    name gate). Returns None when the gid has no group entry."""
    try:
        import grp

        return grp.getgrgid(gid).gr_name
    except KeyError:
        return None
    except Exception:
        return None


def _canonical_actor_group_names(actor_agent: str) -> set:
    """The set of group NAMES that ARE the actor's OWN per-agent group —
    derived PURELY from the actor name + the group-name prefix, NEVER
    from any caller-supplied env value. This is the security allow-list
    (codex r2 BLOCKING): `AGB_STAGE_FILE_GROUP` is treated as a candidate
    *hint* for which gid to look up, but the gid's resolved group name
    must still equal one of THESE canonical names to be accepted. An iso
    process that sets `AGB_STAGE_FILE_GROUP=ab-shared` (a group it is a
    member of) therefore cannot smuggle a shared group past the gate —
    `ab-shared` is not in this set. Selecting `ab-shared` for the
    per-agent staging leaf would reopen the cross-agent write/read
    surface the matrix avoids (lib/bridge-isolation-v2.sh grants the
    per-agent subdir `ab-agent-<a>` 2770, NOT `ab-shared`).

    Members (mirroring `bridge_isolation_v2_agent_group_name`):
    - `<prefix><actor_agent>` (the un-truncated common case).
    - the hash-truncated Linux form `<prefix><first-N>-<7-hex-sha256
      (actor)>` clamped to 32 chars (groupadd cap), so a long agent name
      still matches the bash-resolved name.
    """
    prefix = os.environ.get("BRIDGE_AGENT_GROUP_PREFIX", "ab-agent-")
    names = {f"{prefix}{actor_agent}"}
    # Hash-truncated variant — mirror bridge_isolation_v2_agent_group_name
    # (Linux groupadd 32-char cap: `<prefix><head>-<7-hex-sha256>`).
    composed = f"{prefix}{actor_agent}"
    if len(composed) > 32:
        avail = 32 - len(prefix)
        if avail >= 9:
            import hashlib

            short = hashlib.sha256(actor_agent.encode("utf-8")).hexdigest()[:7]
            keep = avail - 1 - 7
            names.add(f"{prefix}{actor_agent[:keep]}-{short}")
    return names


def _resolve_staging_gid(actor_agent: str, agent_dir: Path) -> Optional[int]:
    """Resolve the GID the staging file MUST carry so the controller
    (daemon) can read it: the actor's OWN per-agent cross-class group
    `ab-agent-<actor>` (NOT the writer's user-private group, and NOT any
    OTHER group the writer happens to belong to such as `ab-shared`).

    Candidate sources, in priority order:
    1. `AGB_STAGE_FILE_GROUP` — a group-name HINT (the matrix-aware bash
       caller passes the resolved actor group, possibly hash-truncated).
       Treated as untrusted: it only selects WHICH gid to look up; the
       resolved name must still pass the canonical-name gate below.
    2. The per-agent dir's OWN group (setgid inheritance target) — useful
       on a matrix-applied install; we still chgrp the file explicitly to
       repair fresh-install files written before the matrix ran.
    3. `ab-agent-<actor_agent>` derived from `BRIDGE_AGENT_GROUP_PREFIX`.

    Each candidate is accepted ONLY when ALL hold:
      (a) it resolves to a real GID;
      (b) it differs from the writer's user-private GID;
      (c) the writer is a member of it (an unprivileged chgrp to a
          non-member group fails); AND
      (d) **its resolved group NAME is in `_canonical_actor_group_names`**
          (codex r2 BLOCKING security gate) — purely actor-derived, never
          env-derived, so `ab-shared` / any other group the iso UID
          belongs to is rejected, preserving the #1359 per-agent write
          boundary.

    Returns None when no safe candidate is found — the caller then leaves
    the setgid-inherited group in place (best-effort, matching the
    pre-#1379 behavior on the matrix-applied path)."""
    private_gid = _user_private_gid()
    canonical_names = _canonical_actor_group_names(actor_agent)

    def _accept(gid: Optional[int]) -> Optional[int]:
        if gid is None:
            return None
        if private_gid is not None and gid == private_gid:
            return None
        if not _writer_in_group(gid):
            return None
        # Security gate: the gid's group name MUST be the actor's own
        # per-agent group (actor-derived, NOT env-derived), never a
        # shared group the writer also belongs to (e.g. ab-shared).
        name = _gid_to_group_name(gid)
        if name is None or name not in canonical_names:
            return None
        return gid

    # (1) `AGB_STAGE_FILE_GROUP` hint — only used to pick a gid; the
    # canonical-name gate still decides accept/reject, so a forged
    # `AGB_STAGE_FILE_GROUP=ab-shared` cannot widen the file group.
    explicit = os.environ.get("AGB_STAGE_FILE_GROUP", "").strip()
    if explicit:
        accepted = _accept(_gid_for_group_name(explicit))
        if accepted is not None:
            return accepted

    # (2) the per-agent dir's current group, when it is the actor's own.
    try:
        dir_gid = int(agent_dir.stat().st_gid)
    except OSError:
        dir_gid = None
    accepted = _accept(dir_gid)
    if accepted is not None:
        return accepted

    # (3) derive `<prefix><actor_agent>` (un-truncated common case).
    prefix = os.environ.get("BRIDGE_AGENT_GROUP_PREFIX", "ab-agent-")
    accepted = _accept(_gid_for_group_name(f"{prefix}{actor_agent}"))
    if accepted is not None:
        return accepted

    return None


def _writer_can_chown(gid: int) -> bool:
    """True when the CURRENT process can `os.chown(..., -1, gid)`. The
    daemon (controller) side differs from the iso UID side: in iso v2 the
    daemon usually runs as root, which can chgrp a file to ANY group
    regardless of membership; a non-root controller (shared-mode install,
    test harness) can only chgrp to a group it is a member of. We accept
    both — root (euid 0) unconditionally, others only when they are a
    member — so the canonical-group chgrp is not pre-rejected for the
    privileged daemon yet does not attempt a guaranteed-to-fail chown for
    an unprivileged controller (the membership check mirrors
    `_writer_in_group`)."""
    try:
        if os.geteuid() == 0:
            return True
    except OSError:
        pass
    return _writer_in_group(gid)


def _resolve_result_gid(actor_agent: str, agent_dir: Path) -> Optional[int]:
    """Resolve the GID the daemon-written `<uuid>.result.json` MUST carry
    so the iso UID owner of the matching request can read its OWN result:
    the actor's per-agent cross-class group `ab-agent-<actor>` — the SAME
    canonical group #1379 forces onto the request file, NEVER the
    controller's default/user-private group and NEVER `ab-shared`.

    Issue #1383 (daemon→iso result-read leg, follow-up to #1379's
    iso→daemon request-read leg): the daemon writes the result file as the
    controller. On the fresh-install path the per-agent staging subdir has
    no setgid bit yet, so the controller's write lands with the
    controller's own default group (e.g. `awfmanager:awfmanager`), which
    the iso UID is neither owner nor member of → `PermissionError [Errno
    13]` when the iso poller reads its result. Mirroring #1379, we chgrp
    the result file to the canonical actor group.

    This is the controller-side twin of `_resolve_staging_gid`. It shares
    the SAME security gate (`_canonical_actor_group_names` — purely
    actor-name-derived, so `ab-shared` / any other group is rejected) and
    the SAME candidate priority, but with TWO daemon-side differences:
      - The "writer's user-private group" exclusion is replaced by the
        controller's own default group (`os.getegid()`): the daemon must
        not leave the result file in the controller group — that IS the
        #1383 bug — so a candidate equal to the controller's egid is
        rejected (it is never the canonical actor group anyway, but the
        explicit guard documents intent).
      - Membership is checked with `_writer_can_chown` (root → always
        accepted; non-root controller → must be a member) instead of
        `_writer_in_group`, because the iso v2 daemon is normally root and
        root can chgrp to a non-member group.

    Returns None when no safe candidate is found (shared-mode / non-iso /
    fresh install before groupadd) — the caller then leaves the result
    file in the controller-owned group (best-effort, matching the
    pre-#1383 behavior). gid=None is a legitimate non-iso outcome, NOT an
    error: there is no iso reader to strand."""
    controller_gid = _user_private_gid()  # the daemon's own egid here
    canonical_names = _canonical_actor_group_names(actor_agent)

    def _accept(gid: Optional[int]) -> Optional[int]:
        if gid is None:
            return None
        if controller_gid is not None and gid == controller_gid:
            # The controller's own group is exactly the #1383 bug group —
            # never the canonical actor group, reject explicitly.
            return None
        if not _writer_can_chown(gid):
            return None
        # Security gate (shared with the request leg): the gid's group
        # name MUST be the actor's own per-agent group, never a shared
        # group — preserves the #1359/#1379 per-agent boundary.
        name = _gid_to_group_name(gid)
        if name is None or name not in canonical_names:
            return None
        return gid

    # (1) the per-agent dir's current group, when it is the actor's own
    # (the setgid target on a matrix-applied install).
    try:
        dir_gid = int(agent_dir.stat().st_gid)
    except OSError:
        dir_gid = None
    accepted = _accept(dir_gid)
    if accepted is not None:
        return accepted

    # (2) derive `<prefix><actor_agent>` (un-truncated common case + the
    # hash-truncated Linux variant resolved inside _gid_for_group_name via
    # the canonical-name set membership check).
    prefix = os.environ.get("BRIDGE_AGENT_GROUP_PREFIX", "ab-agent-")
    accepted = _accept(_gid_for_group_name(f"{prefix}{actor_agent}"))
    if accepted is not None:
        return accepted

    # (3) the hash-truncated canonical name (long agent names, Linux
    # groupadd 32-char cap). `_canonical_actor_group_names` already
    # computed it; resolve each remaining canonical name to a gid.
    for cand_name in canonical_names:
        accepted = _accept(_gid_for_group_name(cand_name))
        if accepted is not None:
            return accepted

    # (4) `AGB_STAGE_FILE_GROUP` hint LAST (the daemon does not normally
    # set it, but accept it symmetrically with the request leg; the
    # canonical-name gate still decides accept/reject, so a stray
    # `AGB_STAGE_FILE_GROUP=ab-shared` cannot widen the result group).
    explicit = os.environ.get("AGB_STAGE_FILE_GROUP", "").strip()
    if explicit:
        accepted = _accept(_gid_for_group_name(explicit))
        if accepted is not None:
            return accepted

    return None


_AGENT_NAME_RE = None


def _validate_agent_name(name: str) -> bool:
    """Conservative whitelist for the per-agent subdir name. Same shape
    as the bridge roster accepts: lowercase alnum / dot / dash / underscore,
    1..64 chars. Rejecting weird names defeats `..` traversal and
    accidental writes into the staging-root parent.
    """
    global _AGENT_NAME_RE
    if _AGENT_NAME_RE is None:
        import re

        _AGENT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    return bool(_AGENT_NAME_RE.match(name))


def cmd_write_request(staging_root_arg: str, actor_agent: str, payload_json: str) -> int:
    if not _validate_agent_name(actor_agent):
        sys.stderr.write(f"staging.py write-request: bad actor_agent {actor_agent!r}\n")
        return 64
    payload = json.loads(payload_json)
    payload.setdefault("schema_version", SCHEMA_VERSION)
    payload.setdefault("submitted_at", _iso_now())
    payload.setdefault("actor_uid", os.geteuid())

    staging_root = Path(staging_root_arg).expanduser()
    agent_dir = staging_root / actor_agent
    # The matrix-grant path is what enforces 2770 + ab-agent-<a>; the
    # mkdir here is best-effort so a fresh-install path that hasn't
    # run the matrix yet still allows the iso UID to drop the request.
    # In that case the iso UID's umask 077 yields 0700; the daemon
    # (controller) cannot list the dir but CAN traverse via the staging
    # root + subdir name AND read the request via the parent dir's
    # group-x grant. The result.json write back through the daemon will
    # still land at mode 0660 owner=controller group=ab-agent-<a>.
    agent_dir.mkdir(parents=True, exist_ok=True)

    # #1379: resolve the shared cross-class group the staging file MUST
    # carry so the controller (daemon) can read it. Without this, a file
    # created on the fresh-install path (subdir made by the iso UID's
    # `mkdir` under umask 077, no setgid, user-private group) lands with
    # group `agent-bridge-<a>` — which the controller is NOT a member of
    # → daemon read denied → 30s pickup timeout → silent skip.
    staging_gid = _resolve_staging_gid(actor_agent, agent_dir)

    # Best-effort: self-heal the per-agent subdir so future files inherit
    # the shared group via setgid (2770) rather than the user-private
    # group. The matrix grant does this canonically at agent prepare;
    # repeating it here closes the fresh-install gap idempotently. An
    # unprivileged caller can chgrp/chmod a dir it owns; failures are
    # swallowed (the explicit per-file chgrp below is the load-bearing
    # fix, the dir setgid is the belt-and-suspenders).
    if staging_gid is not None:
        try:
            st_dir = agent_dir.stat()
            if int(st_dir.st_gid) != staging_gid:
                os.chown(agent_dir, -1, staging_gid)
            # 2770 + setgid: owner+group rwx, setgid so children inherit
            # the dir group. Mirrors the matrix `state-cron-staging-
            # agent-dir` row (2770 group_setgid).
            os.chmod(agent_dir, 0o2770)
        except OSError:
            pass

    request_uuid = uuid.uuid4().hex
    request_path = agent_dir / f"{request_uuid}.json"

    # Mode 0660 — group=ab-agent-<a> (explicit chgrp via `staging_gid`,
    # NOT merely setgid-inherited) means the controller can read the
    # staged file even on a fresh-install path where the dir setgid
    # has not yet been applied. Only the actor agent's iso UID has
    # group-write; other iso UIDs lack ab-agent-<a> membership, so
    # cross-agent rewrites stay blocked at the group boundary even
    # though every iso UID has --x on the shared root (for traversal
    # into its OWN subdir).
    #
    # codex r2 BLOCKING: when we resolved a `staging_gid`, the chgrp is
    # fail-loud — if it cannot be applied + verified, _payload_atomic_write
    # raises StagingGroupError and does NOT publish. Surface it as an
    # explicit error (no uuid on stdout) so the iso caller sees a clear
    # failure instead of polling a file the daemon can never read (the
    # silent 30s pickup-timeout class). When staging_gid is None (no
    # canonical group resolvable — fresh install before groupadd, or the
    # writer's effective group already IS the actor group) the write is
    # best-effort, matching the pre-#1379 inherited-group behavior.
    try:
        _payload_atomic_write(request_path, payload, 0o660, gid=staging_gid)
    except StagingGroupError as exc:
        sys.stderr.write(
            "staging.py write-request: refusing to publish staging request "
            f"for actor_agent={actor_agent!r} — {exc}\n"
        )
        return 73  # EX_CANTCREAT-class: could not create a usable file

    print(request_uuid)
    return 0


def cmd_read_result(staging_root_arg: str, actor_agent: str, request_uuid: str) -> int:
    if not _validate_agent_name(actor_agent):
        sys.stderr.write(f"staging.py read-result: bad actor_agent {actor_agent!r}\n")
        return 64
    result_path = Path(staging_root_arg).expanduser() / actor_agent / f"{request_uuid}.result.json"
    if not result_path.is_file():
        return 2
    body = result_path.read_text(encoding="utf-8")
    sys.stdout.write(body)
    if not body.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def _staging_files(agent_dir: Path):
    if not agent_dir.is_dir():
        return
    for entry in sorted(agent_dir.iterdir()):
        if entry.suffix != ".json":
            continue
        if entry.name.endswith(".result.json"):
            continue
        if entry.name.endswith(".tmp"):
            continue
        # tmp files from atomic_write have ".tmp.<pid>" suffix —
        # filter on `.tmp.` anywhere in name as a defense.
        if ".tmp." in entry.name:
            continue
        yield entry


def cmd_scan_pending(staging_root_arg: str) -> int:
    staging_root = Path(staging_root_arg).expanduser()
    stale_secs = int(os.environ.get("BRIDGE_CRON_STAGING_STALE_SECONDS", "300") or "300")
    now = time.time()
    if not staging_root.is_dir():
        return 0
    for agent_entry in sorted(staging_root.iterdir()):
        if not agent_entry.is_dir():
            continue
        actor_agent = agent_entry.name
        if not _validate_agent_name(actor_agent):
            # Surface an audit-visible hint when the daemon picks up a
            # subdir name that fails the validator (operator created
            # it manually, fresh-install drift). We don't emit a
            # pending row for it.
            sys.stderr.write(
                f"staging.py scan-pending: skipping non-conforming agent dir {agent_entry}\n"
            )
            continue
        for entry in _staging_files(agent_entry):
            request_uuid = entry.stem
            result_path = agent_entry / f"{request_uuid}.result.json"
            if result_path.exists():
                # Already applied — caller can skip.
                continue
            try:
                st = entry.stat()
            except FileNotFoundError:
                continue
            age = max(0, int(now - st.st_mtime))
            row = {
                "uuid": request_uuid,
                "actor_agent": actor_agent,
                "path": str(entry),
                "owner_uid": int(st.st_uid),
                "result_path": str(result_path),
                "mtime_age_seconds": age,
                "stale": age > stale_secs,
            }
            print(json.dumps(row, ensure_ascii=False, sort_keys=True))
    return 0


def _resolve_agent_iso_uid(agent: str, jobs_file: str) -> Optional[int]:
    """Resolve the iso UID for `agent`.

    The daemon side runs as the controller and does NOT source the
    bridge roster Bash. Instead we consult the controller-rooted
    `state/agents/<agent>/agent-meta.env` snippet (written at agent
    create/prepare by `bridge_isolation_v2_write_agent_metadata`) so
    we can read `BRIDGE_AGENT_OS_USER` without re-entering Bash.

    Returns the UID or None when:
    - The agent has no metadata snippet (shared mode / non-iso agent).
    - The OS user does not resolve to a real UID (sentinel staleness).
    """
    bridge_home = os.environ.get("BRIDGE_HOME") or str(Path.home() / ".agent-bridge")
    state_dir = os.environ.get("BRIDGE_STATE_DIR") or str(Path(bridge_home) / "state")
    meta_path = Path(state_dir) / "agents" / agent / "agent-meta.env"
    if not meta_path.is_file():
        return None
    os_user = None
    try:
        for line in meta_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            if key.strip() == "BRIDGE_AGENT_OS_USER":
                os_user = value.strip()
                # Strip surrounding quotes if any.
                if (
                    len(os_user) >= 2
                    and os_user[0] == os_user[-1]
                    and os_user[0] in ('"', "'")
                ):
                    os_user = os_user[1:-1]
                break
    except OSError:
        return None
    if not os_user:
        return None
    try:
        import pwd

        return pwd.getpwnam(os_user).pw_uid
    except KeyError:
        return None
    except Exception:
        return None


def _write_result(
    result_path: Path,
    request_uuid: str,
    actor_agent: str,
    status: str,
    cron_id: Optional[str],
    error: Optional[str],
    audit_action: str,
) -> None:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "uuid": request_uuid,
        "action": "create",
        "actor_agent": actor_agent,
        "status": status,
        "cron_id": cron_id,
        "error": error,
        "applied_at": _iso_now(),
        "audit_action": audit_action,
    }
    # Mode 0660 so the iso UID owner of the request file can read it.
    # The owner=controller distinction means the iso UID falls through to
    # the group bits — which MUST be the canonical `ab-agent-<actor>`.
    #
    # Issue #1383 (follow-up to #1379, daemon→iso result-read leg): the
    # daemon writes the result as the controller. On a fresh-install path
    # the per-agent staging subdir has no setgid bit yet, so the write
    # lands in the controller's OWN default group (e.g.
    # `awfmanager:awfmanager`) — which the iso UID is neither owner nor
    # member of → `PermissionError [Errno 13]` when the iso poller reads
    # its result. Mirror #1379's request-write chgrp onto the result file:
    # resolve the canonical actor group (purely actor-name-derived, NEVER
    # `ab-shared`) and chgrp+verify before the atomic rename.
    #
    # _resolve_result_gid returns None for non-iso / shared-mode / fresh
    # install before groupadd — in that case the result stays
    # controller-owned, which is fine (no iso reader to strand). When a
    # canonical gid IS resolved, the chgrp is fail-loud-but-publish (see
    # _result_atomic_write): a verify failure logs LOUD to stderr (daemon
    # surfaces it) but still publishes, so the iso poller never strands and
    # the request never becomes a poison-retry.
    agent_dir = result_path.parent
    result_gid = _resolve_result_gid(actor_agent, agent_dir)
    _result_atomic_write(result_path, payload, 0o660, gid=result_gid)


def cmd_apply(
    staging_root_arg: str,
    canonical_actor_agent: str,
    request_uuid: str,
    jobs_file: str,
) -> int:
    """Validate + apply the staged mutation. Caller emits audit on the
    audit_action field in the result.

    The caller (daemon) recovers `canonical_actor_agent` from the
    staging path (dirname). The payload's `actor_agent` field MUST
    match — a payload that claims to be from agent X but sits in
    agent Y's subdir is the symptom of a forge attempt or a buggy
    writer and gets rejected at the actor_agent_mismatch gate.
    """
    if not _validate_agent_name(canonical_actor_agent):
        sys.stderr.write(
            f"staging.py apply: bad actor_agent {canonical_actor_agent!r}\n"
        )
        return 64
    staging_root = Path(staging_root_arg).expanduser()
    agent_dir = staging_root / canonical_actor_agent
    request_path = agent_dir / f"{request_uuid}.json"
    result_path = agent_dir / f"{request_uuid}.result.json"

    if not request_path.is_file():
        # Caller raced — surface to stderr but do not bail the whole
        # daemon tick. Exit 2 so caller can audit + move on.
        sys.stderr.write(f"staging.py apply: missing request {request_path}\n")
        return 2

    try:
        st = request_path.stat()
        file_owner_uid = int(st.st_uid)
    except OSError as exc:
        sys.stderr.write(f"staging.py apply: stat failed: {exc}\n")
        return 2

    # codex r2 review escalation (BLOCKING #1 race): scan-pending
    # captured the `stale` flag at scan time; the daemon then iterates
    # rows in sequence. A row aged just under the threshold at scan
    # time can cross the threshold before its apply turn. Without an
    # apply-time re-stat, that row would still be applied; the later
    # sweep-stale pass would then no-op because we wrote a result.json
    # sibling. Re-check the file age inside the lock holder and short-
    # circuit as `cron_staging_stale_rejected` if it crossed the
    # threshold, unlinking the request inline so the iso UID poller
    # sees the explicit reject result.
    try:
        stale_secs = int(
            os.environ.get("BRIDGE_CRON_STAGING_STALE_SECONDS", "300") or "300"
        )
    except (TypeError, ValueError):
        stale_secs = 300
    age_seconds = max(0, int(time.time() - st.st_mtime))
    if age_seconds > stale_secs:
        # Race-window stale: write the explicit reject result FIRST so
        # the iso UID poller observes the close, then unlink the
        # request so the next sweep-stale pass does not re-emit it.
        # _write_result lives in the agent_dir which has setgid =
        # ab-agent-<X>; the iso UID owner of the request can read its
        # own result via the group bits.
        _write_result(
            result_path,
            request_uuid,
            actor_agent=canonical_actor_agent,
            status="error",
            cron_id=None,
            error=(
                "stale_at_apply: "
                f"age_seconds={age_seconds} stale_secs={stale_secs}"
            ),
            audit_action="cron_staging_stale_rejected",
        )
        try:
            request_path.unlink()
        except OSError:
            pass
        return 5

    try:
        payload = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        # Malformed payload. Treat as rejected. Write a rejected
        # result so the iso UID poller does not spin forever.
        _write_result(
            result_path,
            request_uuid,
            actor_agent=canonical_actor_agent,
            status="error",
            cron_id=None,
            error=f"unparseable_payload: {exc!r}",
            audit_action="cron_staging_rejected",
        )
        return 3

    actor_agent = str(payload.get("actor_agent") or "")
    target_agent = str(payload.get("agent") or "")
    payload_actor_uid = payload.get("actor_uid")

    # Validation 1: payload schema sanity.
    if payload.get("schema_version") != SCHEMA_VERSION:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=canonical_actor_agent,
            status="error",
            cron_id=None,
            error=f"unsupported_schema_version: {payload.get('schema_version')!r}",
            audit_action="cron_staging_rejected",
        )
        return 4
    if not actor_agent:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=canonical_actor_agent,
            status="error",
            cron_id=None,
            error="missing_actor_agent",
            audit_action="cron_staging_rejected",
        )
        return 4

    # Validation 1b (codex r1 #1): payload's actor_agent MUST match the
    # path-derived canonical actor_agent. The canonical comes from the
    # dirname of the staging file (`<root>/<actor_agent>/<uuid>.json`)
    # which the matrix grants exclusively to `ab-agent-<actor_agent>`,
    # so a payload that lies about the actor field gets rejected here
    # — protecting against the cross-agent forge path.
    if actor_agent != canonical_actor_agent:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=canonical_actor_agent,
            status="error",
            cron_id=None,
            error=(
                "payload_actor_agent_mismatch: "
                f"payload={actor_agent!r} dirname={canonical_actor_agent!r}"
            ),
            audit_action="cron_staging_rejected",
        )
        return 4

    # Validation 2: actor_agent == target agent. An iso UID may not
    # mutate cron for another agent. This is the per-issue 격리 보장.
    if target_agent != actor_agent:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=f"actor_agent_mismatch: actor={actor_agent!r} target={target_agent!r}",
            audit_action="cron_staging_rejected",
        )
        return 4

    # Validation 3: file owner UID matches the agent's iso UID. This
    # catches a forged staging file written by a non-iso UID or by a
    # different agent's UID. Also defeats a controller-side helper
    # that wrote on behalf of another caller (the controller's own UID
    # would not match the agent's iso UID).
    expected_uid = _resolve_agent_iso_uid(actor_agent, jobs_file)
    if expected_uid is None:
        # No iso UID for this agent → either the agent is not iso v2,
        # or the metadata snippet is missing. Fail closed: an iso v2
        # boundary must have an iso UID.
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=f"actor_agent_not_iso_v2: {actor_agent!r}",
            audit_action="cron_staging_rejected",
        )
        return 4
    if file_owner_uid != expected_uid:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=(
                "file_owner_uid_mismatch: "
                f"file_uid={file_owner_uid} expected_uid={expected_uid}"
            ),
            audit_action="cron_staging_rejected",
        )
        return 4

    # Validation 4: payload's self-declared actor_uid agrees with the
    # file owner. Defense-in-depth: a malicious iso UID cannot pretend
    # to be another iso UID inside the payload — the daemon trusts the
    # filesystem owner over the payload field, but a mismatch is still
    # an integrity signal worth rejecting.
    #
    # codex r1 BLOCKING #2: a forged `actor_uid` field that is not
    # parseable as an int (e.g. "not-int", a list, a dict) would crash
    # the bare `int()` cast with ValueError/TypeError. Without a result
    # file, the iso UID poller timeouts and the daemon retries the same
    # poison file on every tick — exactly the "daemon retry poison"
    # foot-gun. Catch the cast failure and emit an explicit reject
    # result with audit_action=cron_staging_rejected, reason
    # `malformed_actor_uid`, so the poller exits cleanly and the daemon
    # never re-applies the same file.
    if payload_actor_uid is not None:
        try:
            parsed_actor_uid = int(payload_actor_uid)
        except (TypeError, ValueError):
            _write_result(
                result_path,
                request_uuid,
                actor_agent=actor_agent,
                status="error",
                cron_id=None,
                error=(
                    "malformed_actor_uid: "
                    f"payload_actor_uid={payload_actor_uid!r}"
                ),
                audit_action="cron_staging_rejected",
            )
            return 4
        if parsed_actor_uid != file_owner_uid:
            _write_result(
                result_path,
                request_uuid,
                actor_agent=actor_agent,
                status="error",
                cron_id=None,
                error=(
                    "payload_actor_uid_mismatch: "
                    f"payload_uid={payload_actor_uid} file_uid={file_owner_uid}"
                ),
                audit_action="cron_staging_rejected",
            )
            return 4

    # Build native-create argv. Only `create` is supported in this
    # tactical PR — `update` / `delete` follow a separate root design.
    action = str(payload.get("action") or "create")
    if action != "create":
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=f"unsupported_action: {action!r} (tactical scope is create only)",
            audit_action="cron_staging_rejected",
        )
        return 4

    repo_root = Path(__file__).resolve().parent.parent.parent
    cron_py = repo_root / "bridge-cron.py"
    argv = [
        sys.executable,
        str(cron_py),
        "native-create",
        "--jobs-file",
        jobs_file,
        "--agent",
        actor_agent,
        "--title",
        str(payload.get("title") or "").strip(),
    ]
    schedule = payload.get("schedule")
    at = payload.get("at")
    if schedule:
        argv.extend(["--schedule", str(schedule)])
    elif at:
        argv.extend(["--at", str(at)])
    else:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error="missing_schedule_or_at",
            audit_action="cron_staging_rejected",
        )
        return 4

    tz_value = payload.get("tz")
    if tz_value:
        argv.extend(["--tz", str(tz_value)])
    kind = str(payload.get("kind") or "text")
    if kind != "text":
        # Shell payloads need controller-side script validation that
        # this tactical path deliberately omits. Operators that need
        # iso-driven shell cron should wait for the root daemon IPC.
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=f"unsupported_kind: {kind!r} (tactical scope is kind=text only)",
            audit_action="cron_staging_rejected",
        )
        return 4

    payload_text = payload.get("payload")
    payload_file = payload.get("payload_file")
    if payload_text is not None and payload_file is not None:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error="payload_and_payload_file_both_set",
            audit_action="cron_staging_rejected",
        )
        return 4
    if payload_text is not None:
        argv.extend(["--payload", str(payload_text)])
    elif payload_file is not None:
        # The iso UID's payload_file must be readable by the controller.
        # An iso UID-only-readable file would fail at native-create's
        # argparse-time open. Caller is responsible for staging the
        # body somewhere the controller can read (mode 0644 or
        # ab-shared group-readable).
        argv.extend(["--payload-file", str(payload_file)])

    if bool(payload.get("disabled")):
        argv.append("--disabled")
    if bool(payload.get("delete_after_run")):
        argv.append("--delete-after-run")

    # `actor` field on native-create surfaces the caller in the cron
    # mutation audit row — set it to the actor_agent so audit
    # attribution stays correct.
    argv.extend(["--actor", actor_agent])

    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=f"subprocess_failed: {exc!r}",
            audit_action="cron_staging_rejected",
        )
        return 5

    if completed.returncode != 0:
        err_tail = (completed.stderr or completed.stdout or "").strip()
        # Truncate to keep result file bounded.
        if len(err_tail) > 2048:
            err_tail = err_tail[:2048] + "...[truncated]"
        _write_result(
            result_path,
            request_uuid,
            actor_agent=actor_agent,
            status="error",
            cron_id=None,
            error=f"native_create_failed: rc={completed.returncode}: {err_tail}",
            audit_action="cron_staging_rejected",
        )
        return 6

    # Parse the cron id from `created native cron job <id> for <agent>`.
    cron_id = None
    for line in (completed.stdout or "").splitlines():
        line = line.strip()
        if line.startswith("created native cron job "):
            # Format: "created native cron job <id> for <agent>"
            tail = line[len("created native cron job ") :].strip()
            cron_id = tail.split(" ", 1)[0]
            break

    _write_result(
        result_path,
        request_uuid,
        actor_agent=actor_agent,
        status="ok",
        cron_id=cron_id,
        error=None,
        audit_action="cron_staging_applied",
    )
    return 0


def cmd_sweep_stale(staging_root_arg: str, stale_seconds: str) -> int:
    staging_root = Path(staging_root_arg).expanduser()
    try:
        stale_secs = int(stale_seconds)
    except (TypeError, ValueError):
        stale_secs = 300
    now = time.time()
    if not staging_root.is_dir():
        return 0
    for agent_entry in sorted(staging_root.iterdir()):
        if not agent_entry.is_dir():
            continue
        actor_agent = agent_entry.name
        if not _validate_agent_name(actor_agent):
            continue
        for entry in _staging_files(agent_entry):
            request_uuid = entry.stem
            result_path = agent_entry / f"{request_uuid}.result.json"
            # Only sweep when there is no result yet — if a result
            # exists, the iso UID may still be polling. The daemon
            # should clean those up via a separate retention pass.
            if result_path.exists():
                continue
            try:
                age = max(0, int(now - entry.stat().st_mtime))
            except FileNotFoundError:
                continue
            if age <= stale_secs:
                continue
            row = {
                "uuid": request_uuid,
                "actor_agent": actor_agent,
                "path": str(entry),
                "mtime_age_seconds": age,
            }
            try:
                entry.unlink()
            except OSError:
                row["sweep_error"] = "unlink_failed"
            else:
                row["swept"] = True
            print(json.dumps(row, ensure_ascii=False, sort_keys=True))
    return 0


def cmd_parse_row(row_json: str) -> int:
    """Parse a `scan-pending` JSON row and emit the `key=value` lines the
    daemon's apply loop greps for. Extracted from the inline
    `python3 - <<'PY'` heredoc-stdin at bridge-daemon.sh:8997 to clear
    footgun #11 (Bash 5.3.9 heredoc-stdin + command-sub deadlock).

    Output contract (byte-identical to the prior heredoc body): one line
    each for uuid / actor_agent / owner_uid / stale. On a parse error,
    emit NOTHING and exit 0 — the caller does `|| continue`, so a silent
    empty parse skips the row exactly as the heredoc's `sys.exit(0)` did.
    """
    try:
        data = json.loads(row_json)
    except Exception:
        return 0
    print("uuid=" + str(data.get("uuid") or ""))
    print("actor_agent=" + str(data.get("actor_agent") or ""))
    print("owner_uid=" + str(data.get("owner_uid") or ""))
    print("stale=" + ("1" if data.get("stale") else "0"))
    return 0


def cmd_parse_result(result_path_arg: str) -> int:
    """Parse a `<uuid>.result.json` file and emit the `key=value` lines the
    daemon's audit emitter greps for. Extracted from the inline
    `python3 - <<'PY'` heredoc-stdin at bridge-daemon.sh:9077.

    Output contract (byte-identical to the prior heredoc body): one line
    each for audit_action / actor_agent / status / cron_id / error. On a
    read or parse error, emit NOTHING and exit 0 — the caller does
    `|| _result_parsed=""`, matching the heredoc's `sys.exit(0)`.
    """
    try:
        with open(result_path_arg, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return 0
    print("audit_action=" + str(data.get("audit_action") or ""))
    print("actor_agent=" + str(data.get("actor_agent") or ""))
    print("status=" + str(data.get("status") or ""))
    print("cron_id=" + str(data.get("cron_id") or ""))
    print("error=" + str(data.get("error") or ""))
    return 0


def cmd_parse_swept(row_json: str) -> int:
    """Parse a `sweep-stale` JSON row and emit the `key=value` lines the
    daemon's sweep audit emitter greps for. Extracted from the inline
    `python3 - <<'PY'` heredoc-stdin at bridge-daemon.sh:9130.

    Output contract (byte-identical to the prior heredoc body): one line
    each for uuid / age (sourced from `mtime_age_seconds`). On a parse
    error, emit NOTHING and exit 0 — the caller does `|| continue`,
    matching the heredoc's `sys.exit(0)`.
    """
    try:
        data = json.loads(row_json)
    except Exception:
        return 0
    print("uuid=" + str(data.get("uuid") or ""))
    print("age=" + str(data.get("mtime_age_seconds") or ""))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: staging.py <subcommand> [args]\n")
        return 64
    sub = sys.argv[1]
    args = sys.argv[2:]
    if sub == "write-request" and len(args) == 3:
        return cmd_write_request(args[0], args[1], args[2])
    if sub == "read-result" and len(args) == 3:
        return cmd_read_result(args[0], args[1], args[2])
    if sub == "scan-pending" and len(args) == 1:
        return cmd_scan_pending(args[0])
    if sub == "apply" and len(args) == 4:
        return cmd_apply(args[0], args[1], args[2], args[3])
    if sub == "sweep-stale" and len(args) == 2:
        return cmd_sweep_stale(args[0], args[1])
    if sub == "parse-row" and len(args) == 1:
        return cmd_parse_row(args[0])
    if sub == "parse-result" and len(args) == 1:
        return cmd_parse_result(args[0])
    if sub == "parse-swept" and len(args) == 1:
        return cmd_parse_swept(args[0])
    sys.stderr.write(f"staging.py: unsupported subcommand or arity: {sub} {args}\n")
    return 64


if __name__ == "__main__":
    sys.exit(main())
