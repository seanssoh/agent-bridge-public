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


def _payload_atomic_write(path: Path, payload: Dict[str, Any], mode: int) -> None:
    tmp = path.parent / (path.name + ".tmp." + str(os.getpid()))
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


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

    request_uuid = uuid.uuid4().hex
    request_path = agent_dir / f"{request_uuid}.json"

    # Mode 0660 — group=ab-agent-<a> via setgid means only the actor
    # agent's iso UID has group-write. Other iso UIDs do not have
    # ab-agent-<a> membership, so cross-agent rewrites are blocked at
    # the group boundary even though every iso UID has --x on the
    # shared root (for traversal into its OWN subdir).
    _payload_atomic_write(request_path, payload, 0o660)

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
    # The owner=controller distinction means the iso UID falls through
    # to the group bits — group=ab-shared via the parent dir's setgid.
    _payload_atomic_write(result_path, payload, 0o660)


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
    if (
        payload_actor_uid is not None
        and int(payload_actor_uid) != file_owner_uid
    ):
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
    sys.stderr.write(f"staging.py: unsupported subcommand or arity: {sub} {args}\n")
    return 64


if __name__ == "__main__":
    sys.exit(main())
