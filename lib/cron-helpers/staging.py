#!/usr/bin/env python3
"""staging.py — Issue #1359 tactical staging delegation for `agb cron create`
from an iso v2 agent UID.

The controller owns `cron/jobs.json` (mode 0640, group=controller_group),
so an iso v2 agent UID cannot write the file directly. This helper bridges
the boundary by serializing the mutation request to a staging file under
`$BRIDGE_STATE_DIR/cron-staging/<uuid>.json` (mode 0660, owner=iso UID,
group=ab-shared). The daemon picks up staging files on its cron-sync
tick, validates the caller, applies the mutation via
`bridge-cron.py native-create`, and writes the result back to
`<uuid>.result.json` for the iso UID poller.

Root scope (daemon IPC Unix socket) is OUT OF SCOPE for this PR — a
follow-up issue tracks the sync RPC contract.

Subcommands
-----------
- write-request <staging-dir> <payload-json>
    Iso UID side. Allocate a uuid, write `<staging-dir>/<uuid>.json` mode
    0660 with the payload JSON, and print the uuid. Caller polls for the
    `.result.json` sibling.

- read-result <staging-dir> <uuid>
    Iso UID side. Print the result.json content if present, else exit
    non-zero. The bash poller decides timeout.

- scan-pending <staging-dir>
    Controller / daemon side. Print one JSON object per pending staging
    file (one per line): `{"uuid": ..., "path": ..., "owner_uid": ...,
    "result_path": ..., "mtime_age_seconds": ...}`. Files with an
    existing `.result.json` are skipped (already applied). Files older
    than `BRIDGE_CRON_STAGING_STALE_SECONDS` (default 300) are emitted
    with `stale: true` so the daemon can audit + sweep them.

- apply <staging-dir> <uuid> <jobs-file>
    Controller / daemon side. Validate the staging file's owner UID
    matches the agent's iso UID (`actor_uid` in payload matches the
    file owner AND the actor_agent's roster os_user resolves to the
    same UID), then build a `bridge-cron.py native-create` argv from
    the payload, run it as a subprocess (controller permissions), and
    write the result file. Result schema:

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


def cmd_write_request(staging_dir: str, payload_json: str) -> int:
    payload = json.loads(payload_json)
    payload.setdefault("schema_version", SCHEMA_VERSION)
    payload.setdefault("submitted_at", _iso_now())
    payload.setdefault("actor_uid", os.geteuid())

    staging_root = Path(staging_dir).expanduser()
    staging_root.mkdir(parents=True, exist_ok=True)

    request_uuid = uuid.uuid4().hex
    request_path = staging_root / f"{request_uuid}.json"

    # Mode 0660 so the controller (in ab-shared via the per-agent
    # grant) can read what the iso UID writes. Default umask in the iso
    # UID context can otherwise strip group bits.
    _payload_atomic_write(request_path, payload, 0o660)

    print(request_uuid)
    return 0


def cmd_read_result(staging_dir: str, request_uuid: str) -> int:
    result_path = Path(staging_dir).expanduser() / f"{request_uuid}.result.json"
    if not result_path.is_file():
        return 2
    sys.stdout.write(result_path.read_text(encoding="utf-8"))
    if not str(result_path.read_text(encoding="utf-8")).endswith("\n"):
        sys.stdout.write("\n")
    return 0


def _staging_files(staging_dir: Path):
    if not staging_dir.is_dir():
        return
    for entry in sorted(staging_dir.iterdir()):
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


def cmd_scan_pending(staging_dir: str) -> int:
    staging_root = Path(staging_dir).expanduser()
    stale_secs = int(os.environ.get("BRIDGE_CRON_STAGING_STALE_SECONDS", "300") or "300")
    now = time.time()
    for entry in _staging_files(staging_root):
        request_uuid = entry.stem
        result_path = staging_root / f"{request_uuid}.result.json"
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


def cmd_apply(staging_dir: str, request_uuid: str, jobs_file: str) -> int:
    """Validate + apply the staged mutation. Caller emits audit on the
    audit_action field in the result.
    """
    staging_root = Path(staging_dir).expanduser()
    request_path = staging_root / f"{request_uuid}.json"
    result_path = staging_root / f"{request_uuid}.result.json"

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
            actor_agent="<unparseable>",
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
            actor_agent=actor_agent or "<unknown>",
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
            actor_agent="<missing>",
            status="error",
            cron_id=None,
            error="missing_actor_agent",
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


def cmd_sweep_stale(staging_dir: str, stale_seconds: str) -> int:
    staging_root = Path(staging_dir).expanduser()
    try:
        stale_secs = int(stale_seconds)
    except (TypeError, ValueError):
        stale_secs = 300
    now = time.time()
    for entry in _staging_files(staging_root):
        request_uuid = entry.stem
        result_path = staging_root / f"{request_uuid}.result.json"
        # Only sweep when there is no result yet — if a result exists,
        # the iso UID may still be polling. The daemon should clean
        # those up via a separate retention pass.
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
    if sub == "write-request" and len(args) == 2:
        return cmd_write_request(args[0], args[1])
    if sub == "read-result" and len(args) == 2:
        return cmd_read_result(args[0], args[1])
    if sub == "scan-pending" and len(args) == 1:
        return cmd_scan_pending(args[0])
    if sub == "apply" and len(args) == 3:
        return cmd_apply(args[0], args[1], args[2])
    if sub == "sweep-stale" and len(args) == 2:
        return cmd_sweep_stale(args[0], args[1])
    sys.stderr.write(f"staging.py: unsupported subcommand or arity: {sub} {args}\n")
    return 64


if __name__ == "__main__":
    sys.exit(main())
