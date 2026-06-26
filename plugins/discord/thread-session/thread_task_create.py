#!/usr/bin/env python3
"""Thread-session producer shim.

This is the only local egress command a thread child should use in v3. It
creates a bridge task addressed to the parent main agent and records an
idempotent correlation row before the queue write, so Discord retry / dispatch
retry cannot mint duplicate main tasks.
"""
from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterator


SCHEMA_VERSION = 1
# The parent (main-leg) agent is resolved at runtime from BRIDGE_AGENT_ID /
# BRIDGE_THREAD_PARENT_AGENT (see trusted_parent_agent()); there is no hardcoded
# default — if neither is set the producer shim fails closed rather than guess.
DEFAULT_TRANSPORT = "discord"
DEFAULT_KIND = "thread_task"
# #14577 / #14641: thread-lifecycle awareness signals delivered to the MAIN leg.
# thread_created is a one-time body-free awareness row; thread_archived is a
# "summarize & absorb" trigger whose body directs main to recall its OWN thread
# corpus (the thread conversation text is never carried in the signal — same-agent
# boundary). The --kind arg stays free-form (no choices= enforcement) so these
# flow through create_or_get → run_queue_create → post_fresh_arrival_marker
# unchanged; this map only gives them a stable, human-legible default title.
LIFECYCLE_KIND_TITLES = {
    "thread_created": "[thread-created]",
    "thread_archived": "[thread-archived]",
}
CRED_DIR_NAMES = {".discord", ".telegram", "launch-secrets"}
CRED_FILE_NAMES = {"access.json"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def trusted_parent_agent() -> str:
    """Resolve the main-leg agent id from the trusted launch environment.

    The Discord plugin spawns the thread leg with the channel-owning agent's
    BRIDGE_AGENT_ID / BRIDGE_THREAD_PARENT_AGENT, so the producer shim attributes
    thread→main tasks to whichever agent owns the channel (no hardcoded agent).
    These env vars are set by the dispatcher, not by the (untrusted) inbound
    Discord message, so honoring them is safe. If BOTH are set they must agree —
    a mismatch indicates tampering and is rejected. Fail-closed: if neither is
    set, refuse rather than attribute the thread→main task to a placeholder
    agent that no one will claim.
    """
    values = {}
    for key in ("BRIDGE_AGENT_ID", "BRIDGE_THREAD_PARENT_AGENT"):
        value = os.environ.get(key, "").strip()
        if value:
            values[key] = value
    distinct = set(values.values())
    if len(distinct) > 1:
        raise RuntimeError(f"conflicting parent-agent env: {values}")
    if distinct:
        return next(iter(distinct))
    raise RuntimeError(
        "thread-session: cannot resolve parent agent — neither BRIDGE_AGENT_ID "
        "nor BRIDGE_THREAD_PARENT_AGENT is set; refusing to create thread→main "
        "task (fail-closed)."
    )


def default_workdir() -> Path:
    # Prefer the bridge-injected agent workdir; the __file__-relative fallback
    # only points at the agent workdir under the legacy in-workdir layout (not
    # when bundled inside a shared plugin dir). default_root() prefers
    # THREAD_SESSION_ROOT first, so this is the deep fallback.
    env_wd = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_wd:
        return Path(env_wd)
    return Path(__file__).resolve().parents[1]


def default_root() -> Path:
    env = os.environ.get("THREAD_SESSION_ROOT")
    if env:
        return Path(env)
    return default_workdir() / ".threads"


def default_bridge_home() -> Path:
    return Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge"))).expanduser()


def safe_id(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in value)[:180]


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


@contextlib.contextmanager
def file_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a+") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def ledger_path(root: Path) -> Path:
    return root / "correlation.json"


def ledger_lock_path(root: Path) -> Path:
    return root / "correlation.lock"


def load_ledger(root: Path) -> dict[str, Any]:
    path = ledger_path(root)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema_version": SCHEMA_VERSION, "created_at": utc_now(), "events": {}}
    except json.JSONDecodeError as exc:
        corrupt = path.with_suffix(f".corrupt-{int(datetime.now().timestamp())}.json")
        path.rename(corrupt)
        raise RuntimeError(f"correlation ledger was corrupt and moved to {corrupt}: {exc}") from exc
    if not isinstance(data.get("events"), dict):
        raise RuntimeError(f"unsupported correlation ledger shape: {path}")
    data.setdefault("schema_version", SCHEMA_VERSION)
    data.setdefault("created_at", utc_now())
    return data


def write_ledger(root: Path, ledger: dict[str, Any]) -> None:
    ledger["schema_version"] = SCHEMA_VERSION
    ledger["updated_at"] = utc_now()
    atomic_write_json(ledger_path(root), ledger)


def key_parts(args: argparse.Namespace) -> dict[str, str]:
    return {
        "parent_agent": args.parent_agent,
        "transport": args.transport,
        "thread_id": args.thread_id,
        "message_id": args.message_id,
        "producer_kind": args.kind,
    }


def event_id_for(parts: dict[str, str]) -> str:
    raw = "\x1f".join(parts[k] for k in ("parent_agent", "transport", "thread_id", "message_id", "producer_kind"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def read_body(args: argparse.Namespace) -> str:
    if args.body_file:
        body_file = Path(args.body_file).expanduser()
        reject_credential_body_file(body_file)
        return body_file.read_text(encoding="utf-8")
    return args.body or ""


def reject_credential_body_file(path: Path) -> None:
    real = Path(os.path.realpath(path.expanduser()))
    parts = {part.casefold() for part in real.parts}
    name = real.name.casefold()
    if parts.intersection(CRED_DIR_NAMES) or name in CRED_FILE_NAMES:
        raise RuntimeError(f"refusing credential body file: {real}")


def reply_target(args: argparse.Namespace) -> dict[str, str]:
    thread_id = args.reply_thread_id or args.thread_id
    return {
        "transport": args.transport,
        "channel_id": args.reply_channel_id or thread_id,
        "thread_id": thread_id,
        "parent_channel_id": args.parent_channel_id or "",
        "source_message_id": args.message_id,
    }


def task_title(args: argparse.Namespace) -> str:
    title = args.title.strip() if args.title else ""
    if title:
        return title
    # #14577: lifecycle signals get a stable, prefixed default title so the main
    # leg can recognize the one-time awareness row at a glance. The title is
    # operator metadata only (kind + thread_id), never the thread message body.
    lifecycle_prefix = LIFECYCLE_KIND_TITLES.get(args.kind)
    if lifecycle_prefix:
        return f"{lifecycle_prefix} {args.thread_id}"
    return f"[thread-session] {args.thread_id} {args.kind}"


def task_body(args: argparse.Namespace, event_id: str, body: str) -> str:
    meta = {
        "source_leg": "thread",
        "source_transport": args.transport,
        "parent_agent": args.parent_agent,
        "thread_id": args.thread_id,
        "message_id": args.message_id,
        "producer_kind": args.kind,
        "source_user": args.source_user or "",
        "risk": args.risk,
        "approval_provenance": "none",
        "thread_event_id": event_id,
        "reply_target": reply_target(args),
    }
    return (
        "[Thread-session task metadata]\n"
        f"{json.dumps(meta, ensure_ascii=False, sort_keys=True)}\n\n"
        "[Thread-session task body]\n"
        f"{body}"
    )


def parse_task_id(output: str) -> int:
    match = re.search(r"created task #(\d+)", output)
    if not match:
        raise RuntimeError(f"could not parse created task id from: {output.strip()}")
    return int(match.group(1))


def run_queue_create(args: argparse.Namespace, event_id: str, body: str) -> tuple[int, str]:
    if args.mock_task_id:
        return int(args.mock_task_id), f"created task #{int(args.mock_task_id)} for {args.parent_agent} [mock]"
    bridge = args.bridge_home / "agent-bridge"
    if not bridge.exists():
        raise RuntimeError(f"agent-bridge not found: {bridge}")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix="thread-task-", suffix=".md", delete=False) as fh:
        fh.write(body)
        body_path = Path(fh.name)
    os.chmod(body_path, 0o600)
    try:
        cmd = [
            str(bridge),
            "task",
            "create",
            "--from",
            args.parent_agent,
            "--to",
            args.parent_agent,
            "--priority",
            args.priority,
            "--title",
            task_title(args),
            "--body-file",
            str(body_path),
        ]
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"queue create rc={proc.returncode}")
        return parse_task_id(proc.stdout), proc.stdout.strip()
    finally:
        with contextlib.suppress(OSError):
            body_path.unlink()


def post_fresh_arrival_marker(bridge_home: Path, task_id: int) -> None:
    """STOPGAP (#11946 / upstream #2045): post the daemon fast-wake fresh-arrival marker
    for a loopback/self thread-task enqueue.

    A loopback `task create --from X --to X` does NOT traverse the A2A receiver, which is
    the only path that posts this marker (bridge-handoffd.post_fresh_arrival_marker). Without
    it the assignee's re-nudge stays under the ~60s redelivery-age gate and the self-task is
    only woken by the slow periodic scan (observed ~6min on #11945).

    Writes `<state>/queue/fresh-arrival/<task_id>` (content = epoch ts, informational; the
    daemon staleness sweep uses mtime). The daemon nudge_scan consumes it (claim-by-delete)
    to exempt this task from ONLY the redelivery-AGE gate for one tick — never auth / dedupe /
    queue / idle / cooldown (bridge-queue.py L88-167). Path resolution mirrors the daemon
    reader EXACTLY: BRIDGE_STATE_DIR override else <bridge_home>/state, where bridge_home ==
    the daemon's operator_home() ($BRIDGE_HOME or ~/.agent-bridge).

    Best-effort by contract: any failure leaves the pre-stopgap latency and NEVER fails the
    enqueue (the task is already durably queued). REMOVE when upstream #2045 (marker on local
    enqueue in create_queue_task) ships.
    """
    try:
        tid = str(task_id).strip()
        if not tid.isdigit():
            return
        state_dir = os.environ.get("BRIDGE_STATE_DIR") or str(Path(bridge_home) / "state")
        marker_dir = Path(state_dir) / "queue" / "fresh-arrival"
        marker_dir.mkdir(parents=True, exist_ok=True)
        marker_path = marker_dir / tid
        tmp_path = marker_path.with_name(marker_path.name + ".tmp")
        tmp_path.write_text(f"{int(datetime.now(timezone.utc).timestamp())}\n", encoding="utf-8")
        os.replace(tmp_path, marker_path)
    except OSError:
        return


def create_or_get(args: argparse.Namespace) -> dict[str, Any]:
    root = args.root
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    parts = key_parts(args)
    event_id = event_id_for(parts)
    body = read_body(args)
    rendered = task_body(args, event_id, body)
    body_sha = hashlib.sha256(body.encode("utf-8")).hexdigest()

    with file_lock(ledger_lock_path(root)):
        ledger = load_ledger(root)
        events = ledger.setdefault("events", {})
        existing = events.get(event_id)
        if existing:
            now = utc_now()
            existing["last_seen_at"] = now
            if existing.get("task_id"):
                write_ledger(root, ledger)
                return {"ok": True, "deduped": True, "event_id": event_id, "task_id": existing["task_id"], "event": existing}
            existing["updated_at"] = now
            existing["duplicate_suppressed_at"] = now
            existing["duplicate_suppressed_count"] = int(existing.get("duplicate_suppressed_count") or 0) + 1
            existing["duplicate_suppressed_reason"] = "existing correlation row without task_id"
            if existing.get("body_sha256") and existing.get("body_sha256") != body_sha:
                existing["retry_body_sha256"] = body_sha
            write_ledger(root, ledger)
            return {
                "ok": True,
                "deduped": True,
                "in_flight": existing.get("status") == "creating",
                "event_id": event_id,
                "task_id": existing.get("task_id"),
                "event": existing,
                "warning": "duplicate queue create suppressed for existing correlation row without task_id",
            }

        event = {
            "event_id": event_id,
            "idempotency_key": parts,
            "status": "creating",
            "created_at": existing.get("created_at") if existing else utc_now(),
            "updated_at": utc_now(),
            "task_id": None,
            "risk": args.risk,
            "source_leg": "thread",
            "source_user": args.source_user or "",
            "source_transport": args.transport,
            "approval_provenance": "none",
            "reply_target": reply_target(args),
            "body_sha256": body_sha,
        }
        events[event_id] = event
        write_ledger(root, ledger)

        try:
            task_id, queue_output = run_queue_create(args, event_id, rendered)
        except Exception as exc:
            event["status"] = "create_failed"
            event["updated_at"] = utc_now()
            event["error"] = str(exc)
            write_ledger(root, ledger)
            raise

        event["status"] = "queued"
        event["updated_at"] = utc_now()
        event["task_id"] = task_id
        event["queue_output"] = queue_output
        write_ledger(root, ledger)
        # STOPGAP (#11946 / upstream #2045): fast-wake this loopback self-task. The daemon's
        # fresh-arrival marker is otherwise posted ONLY by the A2A receiver, so a thread→main
        # self enqueue would wait out the ~60s age gate + slow periodic scan. Best-effort:
        # never raises, never affects this return.
        post_fresh_arrival_marker(args.bridge_home, task_id)
        return {"ok": True, "deduped": False, "event_id": event_id, "task_id": task_id, "event": event}


def command_create(args: argparse.Namespace) -> int:
    args.parent_agent = trusted_parent_agent()
    result = create_or_get(args)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


def command_selftest(_args: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory(prefix="thread-task-create-") as tmp:
        root = Path(tmp) / ".threads"
        body = Path(tmp) / "body.md"
        body.write_text("Please ask patch to verify this.", encoding="utf-8")
        cred_dir = Path(tmp) / ".discord"
        cred_dir.mkdir()
        cred_body = cred_dir / ".env"
        cred_body.write_text("DISCORD_BOT_TOKEN=secret\n", encoding="utf-8")
        args = argparse.Namespace(
            root=root,
            bridge_home=Path(tmp),
            parent_agent="test-agent",
            transport="discord",
            thread_id="thread-1",
            message_id="msg-1",
            kind="thread_task",
            source_user="tester",
            risk="low",
            priority="normal",
            title="selftest",
            body=None,
            body_file=body,
            reply_channel_id="thread-1",
            reply_thread_id="thread-1",
            parent_channel_id="parent-1",
            mock_task_id=101,
        )
        first = create_or_get(args)
        second = create_or_get(args)
        assert first["task_id"] == 101
        assert second["deduped"] is True
        ledger = load_ledger(root)
        assert len(ledger["events"]) == 1
        event = next(iter(ledger["events"].values()))
        assert event["reply_target"]["thread_id"] == "thread-1"
        assert event["approval_provenance"] == "none"

        stuck_args = argparse.Namespace(**{**vars(args), "message_id": "msg-crash", "mock_task_id": 202})
        stuck_event_id = event_id_for(key_parts(stuck_args))
        ledger = load_ledger(root)
        ledger["events"][stuck_event_id] = {
            "event_id": stuck_event_id,
            "idempotency_key": key_parts(stuck_args),
            "status": "creating",
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "task_id": None,
            "body_sha256": "seeded-crash-window",
        }
        write_ledger(root, ledger)
        stuck = create_or_get(stuck_args)
        assert stuck["deduped"] is True
        assert stuck["task_id"] is None
        assert stuck["in_flight"] is True
        ledger = load_ledger(root)
        assert ledger["events"][stuck_event_id]["task_id"] is None
        assert ledger["events"][stuck_event_id]["duplicate_suppressed_count"] == 1

        cred_args = argparse.Namespace(**{**vars(args), "message_id": "msg-cred", "body_file": cred_body, "mock_task_id": 303})
        try:
            create_or_get(cred_args)
            raise AssertionError("credential body file should be rejected")
        except RuntimeError as exc:
            assert "credential body file" in str(exc)

        with contextlib.redirect_stderr(io.StringIO()):
            try:
                build_parser().parse_args(["create", "--thread-id", "t", "--message-id", "m", "--body-f", "x"])
                raise AssertionError("argparse abbreviation should be rejected")
            except SystemExit as exc:
                assert int(exc.code or 0) == 2

        # #14577: lifecycle kinds + synthetic-message_id idempotency. Use a fresh
        # ledger root so the lifecycle rows are isolated from the cases above.
        life_root = Path(tmp) / ".threads-lifecycle"
        created_args = argparse.Namespace(
            **{
                **vars(args),
                "root": life_root,
                "thread_id": "thread-life",
                "message_id": "lifecycle-create",
                "kind": "thread_created",
                "title": "",  # exercise the lifecycle default title
                "mock_task_id": 401,
            }
        )
        # The two new kinds flow through unchanged (free-form --kind, no choices=).
        created_first = create_or_get(created_args)
        assert created_first["task_id"] == 401
        assert created_first["deduped"] is False
        # Default title is stable lifecycle metadata, NOT the thread message body.
        assert task_title(created_args) == "[thread-created] thread-life"

        # I1: a second identical thread_created (same synthetic message_id) dedupes
        # to ONE task — re-delivery (Discord/listener retry) cannot mint a dup row.
        created_second = create_or_get(created_args)
        assert created_second["deduped"] is True
        assert created_second["task_id"] == 401

        # L1: thread_archived with its OWN stable synthetic message_id is a DISTINCT
        # ledger row (create vs archive stay separate), and re-running it dedupes.
        archived_args = argparse.Namespace(
            **{
                **vars(created_args),
                "message_id": "lifecycle-archive",
                "kind": "thread_archived",
                "mock_task_id": 402,
            }
        )
        archived_first = create_or_get(archived_args)
        assert archived_first["task_id"] == 402
        assert archived_first["deduped"] is False
        assert task_title(archived_args) == "[thread-archived] thread-life"
        archived_second = create_or_get(archived_args)
        assert archived_second["deduped"] is True
        assert archived_second["task_id"] == 402

        life_ledger = load_ledger(life_root)
        # Two distinct rows: one for create, one for archive (kind is part of the key).
        assert len(life_ledger["events"]) == 2
        created_event_id = event_id_for(key_parts(created_args))
        archived_event_id = event_id_for(key_parts(archived_args))
        assert created_event_id != archived_event_id
        assert life_ledger["events"][created_event_id]["task_id"] == 401
        assert life_ledger["events"][archived_event_id]["task_id"] == 402
    print(json.dumps({"ok": True, "selftest": "passed"}, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Create an idempotent thread-session task for the parent main agent.",
        allow_abbrev=False,
    )
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--bridge-home", type=Path, default=default_bridge_home())
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create", allow_abbrev=False)
    create.add_argument("--transport", default=os.environ.get("BRIDGE_THREAD_TRANSPORT", DEFAULT_TRANSPORT))
    create.add_argument("--thread-id", required=True)
    create.add_argument("--message-id", required=True)
    create.add_argument("--kind", default=DEFAULT_KIND)
    create.add_argument("--source-user", default="")
    create.add_argument("--risk", choices=("low", "gated"), default="low")
    create.add_argument("--priority", choices=("low", "normal", "high", "urgent"), default="normal")
    create.add_argument("--title", default="")
    body = create.add_mutually_exclusive_group(required=True)
    body.add_argument("--body")
    body.add_argument("--body-file", type=Path)
    create.add_argument("--reply-channel-id", default="")
    create.add_argument("--reply-thread-id", default="")
    create.add_argument("--parent-channel-id", default="")
    create.add_argument("--mock-task-id", type=int)
    create.set_defaults(func=command_create)

    selftest = sub.add_parser("selftest", allow_abbrev=False)
    selftest.set_defaults(func=command_selftest)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not hasattr(args, "root"):
        args.root = default_root()
    try:
        return args.func(args)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
