#!/usr/bin/env python3
"""SQLite-backed task queue for Agent Bridge."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


OPEN_STATUSES = ("queued", "claimed", "blocked")
PRIORITY_CHOICES = ("low", "normal", "high", "urgent")
STATUS_CHOICES = ("queued", "claimed", "blocked", "done", "cancelled")
OPEN_STATUS_ALIASES = {
    "in_progress": "claimed",
    "in-progress": "claimed",
    "progress": "claimed",
    "working": "claimed",
}
UPDATE_STATUS_CHOICES = (*OPEN_STATUSES, *OPEN_STATUS_ALIASES.keys())
FAMILY_RULES = (
    "memory-daily",
    "monthly-highlights",
    "morning-briefing",
    "evening-digest",
    "event-reminder",
    "weekly-review",
)

BLOCKED_REMINDER_TITLE_PREFIX = "[blocked-aging] task #"
BLOCKED_ESCALATION_TITLE_PREFIX = "[blocked-escalation] task #"

UNEXPANDED_SHELL_VAR_RE = re.compile(r"(?<!\\)(\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*)")


def now_ts() -> int:
    return int(time.time())


def isoformat_ts(value: int | None) -> str:
    if not value:
        return "-"
    return datetime.fromtimestamp(int(value), tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def get_db_path() -> Path:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    db_path = Path(os.environ.get("BRIDGE_TASK_DB", str(state_dir / "tasks.db")))
    db_path.parent.mkdir(parents=True, exist_ok=True)
    return db_path


def get_queue_gateway_root() -> Path:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    layout = os.environ.get("BRIDGE_LAYOUT", "").strip()
    agent_root_v2 = os.environ.get("BRIDGE_AGENT_ROOT_V2", "").strip()
    if layout == "v2" and agent_root_v2:
        return Path(agent_root_v2).expanduser()
    return state_dir / "queue-gateway"


def queue_gateway_proxy_agent() -> str:
    if os.environ.get("BRIDGE_QUEUE_GATEWAY_SERVER", "") == "1":
        return ""
    if os.environ.get("BRIDGE_GATEWAY_PROXY", "") != "1":
        return ""
    return os.environ.get("BRIDGE_AGENT_ID", "").strip()


def _running_under_queue_gateway_server() -> bool:
    """True when this bridge-queue.py invocation is the gateway-server child.

    The gateway socket-server sets BRIDGE_QUEUE_GATEWAY_SERVER=1 before
    spawning bridge-queue.py (see run_queue() in bridge-queue-gateway.py).
    Any direct handler that mutates a task can use this flag to demand a
    second-line ownership check, even if the gateway authorizer was wrong
    or future-bypassed (defense-in-depth, finding 2b r2 review).
    """
    return os.environ.get("BRIDGE_QUEUE_GATEWAY_SERVER", "") == "1"


def _gateway_server_authorize(task: sqlite3.Row, actor: str, op: str) -> None:
    """Server-side ownership re-check for cancel/update/handoff.

    The gateway authorizer (bridge-queue-gateway.py:authorize_and_rewrite)
    is the primary gate. This is a *second* gate: if the gateway parser
    is ever wrong (e.g. the round-1 argv-rewriting bypass that misread
    `done --note 60 12` as task 60), the server should still refuse to
    mutate a task whose ownership the actor cannot prove.

    Allow when actor is one of {assigned_to, created_by, claimed_by}.
    Deny otherwise with a recognizable error so smoke tests / audits can
    fingerprint the second-line refusal.
    """
    if not actor:
        raise SystemExit(f"queue gateway server denied {op}: empty actor")
    owners = {
        str(task["assigned_to"] or ""),
        str(task["created_by"] or ""),
        str(task["claimed_by"] or ""),
    }
    owners.discard("")
    if actor not in owners:
        raise SystemExit(
            f"queue gateway server denied {op}: actor {actor!r} is not an owner of "
            f"task #{task['id']}"
        )


def queue_gateway_float_env(name: str, default: str) -> str:
    raw = os.environ.get(name, default).strip()
    try:
        value = float(raw)
    except ValueError:
        return default
    if value <= 0:
        return default
    return raw


def queue_gateway_transport() -> str:
    transport = os.environ.get("BRIDGE_GATEWAY_TRANSPORT", "file").strip().lower()
    if transport not in {"file", "socket"}:
        return "file"
    return transport


def should_proxy_via_queue_gateway(argv: list[str]) -> bool:
    if not argv:
        return False
    if argv[0] in {"-h", "--help"}:
        return False
    if len(argv) == 2 and argv[1] in {"-h", "--help"}:
        return False
    return bool(queue_gateway_proxy_agent())


def proxy_via_queue_gateway(argv: list[str]) -> int:
    agent = queue_gateway_proxy_agent()
    if not agent:
        return 1
    gateway_script = Path(__file__).resolve().with_name("bridge-queue-gateway.py")
    if queue_gateway_transport() == "socket":
        command = [
            sys.executable,
            str(gateway_script),
            "socket-client",
            "--bridge-home",
            os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")),
            "--timeout",
            queue_gateway_float_env("BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS", "5"),
            *argv,
        ]
    else:
        command = [
            sys.executable,
            str(gateway_script),
            "client",
            "--root",
            str(get_queue_gateway_root()),
            "--agent",
            agent,
            "--timeout",
            queue_gateway_float_env("BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS", "45"),
            "--poll",
            queue_gateway_float_env("BRIDGE_QUEUE_GATEWAY_POLL_SECONDS", "0.2"),
            *argv,
        ]
    return int(subprocess.run(command, check=False).returncode)


def get_cron_state_dir() -> Path:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    cron_dir = Path(os.environ.get("BRIDGE_CRON_STATE_DIR", str(state_dir / "cron")))
    cron_dir.mkdir(parents=True, exist_ok=True)
    return cron_dir


def classify_family(name: str) -> str:
    for rule in FAMILY_RULES:
        if name.startswith(rule) or rule in name:
            return rule
    return name


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    with conn:
      conn.execute("PRAGMA journal_mode=WAL")
      conn.execute("PRAGMA foreign_keys=ON")
    init_db(conn)
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    with conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL,
              assigned_to TEXT NOT NULL,
              created_by TEXT NOT NULL,
              priority TEXT NOT NULL DEFAULT 'normal',
              status TEXT NOT NULL DEFAULT 'queued',
              created_ts INTEGER NOT NULL,
              updated_ts INTEGER NOT NULL,
              body_text TEXT,
              body_path TEXT,
              claimed_by TEXT,
              claimed_ts INTEGER,
              lease_until_ts INTEGER,
              closed_ts INTEGER
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS task_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
              event_type TEXT NOT NULL,
              actor TEXT NOT NULL,
              created_ts INTEGER NOT NULL,
              note_text TEXT,
              note_path TEXT,
              from_agent TEXT,
              to_agent TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_state (
              agent TEXT PRIMARY KEY,
              engine TEXT,
              session TEXT,
              workdir TEXT,
              active INTEGER NOT NULL DEFAULT 0,
              last_seen_ts INTEGER,
              last_heartbeat_ts INTEGER,
              session_activity_ts INTEGER,
              last_nudge_ts INTEGER,
              last_nudge_key TEXT,
              nudge_fail_count INTEGER NOT NULL DEFAULT 0,
              zombie INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        ensure_column(conn, "agent_state", "last_nudge_key", "TEXT")
        ensure_column(conn, "agent_state", "nudge_fail_count", "INTEGER NOT NULL DEFAULT 0")
        ensure_column(conn, "agent_state", "zombie", "INTEGER NOT NULL DEFAULT 0")
        # Issue #589: prompt-ready latch columns. The daemon writes these
        # via cmd_daemon_step from the session snapshot. The auto-stop
        # idle anchor in print_summary uses prompt_ready_ts in preference
        # to session_activity_ts so the boot window is not counted as
        # idle time.
        ensure_column(conn, "agent_state", "prompt_ready_ts", "INTEGER")
        ensure_column(conn, "agent_state", "prompt_ready_session", "TEXT")
        ensure_column(conn, "agent_state", "prompt_ready_source", "TEXT")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_assigned_status ON tasks(assigned_to, status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_claimed_status ON tasks(claimed_by, status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_lease ON tasks(status, lease_until_ts)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, created_ts)")


def ensure_column(conn: sqlite3.Connection, table: str, column: str, spec: str) -> None:
    existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
    if column in existing:
        return
    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {spec}")


def normalize_path(path_value: str | None) -> str | None:
    if not path_value:
        return None
    path = Path(path_value).expanduser()
    if not path.exists():
        raise SystemExit(f"file not found: {path_value}")
    return str(path.resolve())


SYSTEM_TMP_PREFIXES: tuple[str, ...] = (
    "/tmp",
    "/var/tmp",
    "/var/folders",
    "/private/tmp",
    "/private/var/tmp",
    "/private/var/folders",
)

MAX_INLINE_BODY_BYTES = 1 * 1024 * 1024


def get_queue_bodies_dir() -> Path:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    bodies_dir = state_dir / "queue" / "bodies"
    bodies_dir.mkdir(parents=True, exist_ok=True)
    return bodies_dir


def bridge_managed_roots() -> list[Path]:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    shared_dir = Path(os.environ.get("BRIDGE_SHARED_DIR", str(bridge_home / "shared")))
    roots: list[Path] = []
    for candidate in (bridge_home, state_dir, shared_dir):
        try:
            roots.append(candidate.resolve())
        except Exception:
            continue
    return roots


def ephemeral_tmp_roots() -> list[Path]:
    roots: list[Path] = []
    tmpdir_env = os.environ.get("TMPDIR", "").strip()
    if tmpdir_env:
        try:
            roots.append(Path(tmpdir_env).resolve())
        except Exception:
            pass
    for prefix in SYSTEM_TMP_PREFIXES:
        roots.append(Path(prefix))
    return roots


def is_ephemeral_body_path(path: Path) -> bool:
    try:
        resolved = path.resolve()
    except Exception:
        return False
    for root in bridge_managed_roots():
        try:
            resolved.relative_to(root)
            return False
        except ValueError:
            continue
    for root in ephemeral_tmp_roots():
        try:
            resolved.relative_to(root)
            return True
        except ValueError:
            continue
    return False


def stabilize_body_file(original: str | None) -> tuple[str | None, str | None]:
    if not original:
        return None, None

    source = Path(original)
    try:
        raw = source.read_bytes()
    except FileNotFoundError as exc:
        raise SystemExit(f"body file disappeared before read: {original}") from exc
    except OSError as exc:
        raise SystemExit(f"failed to read body file {original}: {exc}") from exc

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")

    inline_text: str | None = text if len(raw) <= MAX_INLINE_BODY_BYTES else None
    if not is_ephemeral_body_path(source):
        return inline_text, original

    bodies_dir = get_queue_bodies_dir()
    stem = source.stem or "body"
    suffix = source.suffix or ".md"
    target = bodies_dir / f"{now_ts()}-{os.getpid()}-{stem}{suffix}"
    counter = 0
    while target.exists():
        counter += 1
        target = bodies_dir / f"{now_ts()}-{os.getpid()}-{counter}-{stem}{suffix}"
    target.write_bytes(raw)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass
    return inline_text, str(target)


def normalize_open_status(status: str | None) -> str | None:
    if status is None:
        return None
    normalized = OPEN_STATUS_ALIASES.get(status, status)
    if normalized not in OPEN_STATUSES:
        raise SystemExit(
            f"invalid open task status: {status} "
            f"(choose from {', '.join(OPEN_STATUSES)}; alias in_progress maps to claimed)"
        )
    return normalized


def detect_unexpanded_shell_variable(body_text: str | None) -> str | None:
    if body_text is None:
        return None
    match = UNEXPANDED_SHELL_VAR_RE.search(body_text)
    if not match:
        return None
    return match.group(1)


def emit_event(
    conn: sqlite3.Connection,
    task_id: int,
    *,
    event_type: str,
    actor: str,
    created_ts: int,
    note_text: str | None = None,
    note_path: str | None = None,
    from_agent: str | None = None,
    to_agent: str | None = None,
) -> None:
    conn.execute(
        """
        INSERT INTO task_events (
          task_id, event_type, actor, created_ts, note_text, note_path, from_agent, to_agent
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (task_id, event_type, actor, created_ts, note_text, note_path, from_agent, to_agent),
    )


def touch_agent_activity(conn: sqlite3.Connection, agent: str, activity_ts: int) -> None:
    conn.execute(
        """
        INSERT INTO agent_state (agent, last_seen_ts, session_activity_ts, nudge_fail_count, zombie)
        VALUES (?, ?, ?, 0, 0)
        ON CONFLICT(agent) DO UPDATE SET
          last_seen_ts = CASE
            WHEN agent_state.last_seen_ts IS NULL OR agent_state.last_seen_ts < excluded.last_seen_ts THEN excluded.last_seen_ts
            ELSE agent_state.last_seen_ts
          END,
          session_activity_ts = CASE
            WHEN agent_state.session_activity_ts IS NULL OR agent_state.session_activity_ts < excluded.session_activity_ts THEN excluded.session_activity_ts
            ELSE agent_state.session_activity_ts
          END,
          nudge_fail_count = 0,
          zombie = 0
        """,
        (agent, activity_ts, activity_ts),
    )


def require_task(conn: sqlite3.Connection, task_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        raise SystemExit(f"task not found: {task_id}")
    return row


def priority_sort_sql() -> str:
    return """
      CASE priority
        WHEN 'urgent' THEN 0
        WHEN 'high' THEN 1
        WHEN 'normal' THEN 2
        WHEN 'low' THEN 3
        ELSE 4
      END
    """


def agent_summary_rows(conn: sqlite3.Connection, agents: Iterable[str] | None) -> list[sqlite3.Row]:
    names = [name for name in agents or [] if name]
    params: list[object] = []
    if names:
        values_sql = " UNION ALL ".join(["SELECT ? AS agent"] * len(names))
        params.extend(names)
        base_sql = f"WITH requested AS ({values_sql}) SELECT agent FROM requested"
    else:
        base_sql = """
            SELECT agent FROM agent_state
            UNION
            SELECT assigned_to AS agent FROM tasks
            UNION
            SELECT claimed_by AS agent FROM tasks WHERE claimed_by IS NOT NULL
        """

    sql = f"""
        WITH agent_names AS (
          {base_sql}
        ),
        assigned AS (
          SELECT
            assigned_to AS agent,
            SUM(CASE WHEN status = 'queued' AND title NOT LIKE '[cron-dispatch]%' THEN 1 ELSE 0 END) AS queued_count,
            SUM(CASE WHEN status = 'blocked' AND title NOT LIKE '[cron-dispatch]%' THEN 1 ELSE 0 END) AS blocked_count
          FROM tasks
          GROUP BY assigned_to
        ),
        claimed AS (
          SELECT claimed_by AS agent, COUNT(*) AS claimed_count
          FROM tasks
          WHERE status = 'claimed' AND claimed_by IS NOT NULL
          GROUP BY claimed_by
        )
        SELECT
          agent_names.agent,
          COALESCE(assigned.queued_count, 0) AS queued_count,
          COALESCE(assigned.blocked_count, 0) AS blocked_count,
          COALESCE(claimed.claimed_count, 0) AS claimed_count,
          COALESCE(agent_state.active, 0) AS active,
          agent_state.last_seen_ts,
          agent_state.last_heartbeat_ts,
          agent_state.session_activity_ts,
          agent_state.last_nudge_ts,
          agent_state.nudge_fail_count,
          agent_state.zombie,
          COALESCE(agent_state.session, '') AS session,
          COALESCE(agent_state.engine, '') AS engine,
          COALESCE(agent_state.workdir, '') AS workdir,
          agent_state.prompt_ready_ts,
          COALESCE(agent_state.prompt_ready_session, '') AS prompt_ready_session,
          COALESCE(agent_state.prompt_ready_source, '') AS prompt_ready_source
        FROM agent_names
        LEFT JOIN assigned ON assigned.agent = agent_names.agent
        LEFT JOIN claimed ON claimed.agent = agent_names.agent
        LEFT JOIN agent_state ON agent_state.agent = agent_names.agent
        ORDER BY agent_names.agent
    """
    return conn.execute(sql, params).fetchall()


def _row_get(row: sqlite3.Row, key: str, default: object = None) -> object:
    """Tolerantly read a column from a sqlite3.Row.

    Older rows (or rows from queries that pre-date a column add) may not
    expose newly added columns. Returning a default keeps the summary path
    backward-compatible during the rolling upgrade.
    """
    try:
        return row[key]
    except (IndexError, KeyError):
        return default


def _latched_idle_seconds(row: sqlite3.Row, current_ts: int) -> int:
    """Compute auto-stop idle seconds with the prompt-ready latch (issue #589).

    Effective anchor = max(session_activity_ts, prompt_ready_ts).
    When no latch has fired yet AND the boot window is still within the
    grace ceiling, idle is reported as 0 — the agent is still booting,
    so it has no pending idle time. Past the grace window without a
    latch, fall back to the legacy session_activity_ts anchor so a
    misconfigured or stuck agent still ages out instead of staying alive
    forever (worst-plausible-regression safety net per spec part D).

    Operators can disable the latch entirely with
    BRIDGE_DAEMON_IDLE_LATCH_DISABLED=1; in that case idle reverts to the
    legacy session_activity_ts anchor.
    """
    activity_ts = int(_row_get(row, "session_activity_ts", 0) or 0)
    last_seen_ts = int(_row_get(row, "last_seen_ts", 0) or 0)
    legacy_anchor = activity_ts or last_seen_ts or 0

    if os.environ.get("BRIDGE_DAEMON_IDLE_LATCH_DISABLED", "0") == "1":
        if not legacy_anchor:
            return -1
        return max(0, current_ts - legacy_anchor)

    prompt_ready_ts = int(_row_get(row, "prompt_ready_ts", 0) or 0)

    try:
        grace = int(os.environ.get("BRIDGE_IDLE_LATCH_GRACE_SECONDS", "3600"))
    except ValueError:
        grace = 3600
    if grace < 0:
        grace = 3600

    if prompt_ready_ts:
        # Latch already fired — anchor on whichever is newer (real activity
        # post-prompt-ready, or the latch itself).
        effective_anchor = max(legacy_anchor, prompt_ready_ts)
        return max(0, current_ts - effective_anchor)

    # No latch yet. If we're still within the boot grace window, suppress
    # idle accumulation — the agent is booting, not idling.
    if legacy_anchor and current_ts - legacy_anchor < grace:
        return 0
    if not legacy_anchor:
        return -1
    # Past the grace window without a latch. Fall back to legacy behavior
    # so a stuck agent eventually times out.
    return max(0, current_ts - legacy_anchor)


def print_summary(rows: list[sqlite3.Row], fmt: str) -> None:
    current_ts = now_ts()
    if fmt == "json":
        payload = []
        for row in rows:
            idle_seconds = _latched_idle_seconds(row, current_ts)
            payload.append(
                {
                    "agent": str(row["agent"] or ""),
                    "queued_count": int(row["queued_count"] or 0),
                    "claimed_count": int(row["claimed_count"] or 0),
                    "blocked_count": int(row["blocked_count"] or 0),
                    "active": int(row["active"] or 0),
                    "idle_seconds": int(idle_seconds),
                    "last_seen_ts": int(row["last_seen_ts"] or 0),
                    "last_nudge_ts": int(row["last_nudge_ts"] or 0),
                    "session": str(row["session"] or ""),
                    "engine": str(row["engine"] or ""),
                    "workdir": str(row["workdir"] or ""),
                    "prompt_ready_ts": int(_row_get(row, "prompt_ready_ts", 0) or 0),
                    "prompt_ready_source": str(_row_get(row, "prompt_ready_source", "") or ""),
                }
            )
        print(json.dumps(payload, ensure_ascii=False))
        return

    if fmt == "tsv":
        for row in rows:
            idle_seconds = _latched_idle_seconds(row, current_ts)
            fields = [
                row["agent"],
                str(row["queued_count"]),
                str(row["claimed_count"]),
                str(row["blocked_count"]),
                str(row["active"]),
                str(idle_seconds),
                str(row["last_seen_ts"] or 0),
                str(row["last_nudge_ts"] or 0),
                row["session"],
                row["engine"],
                row["workdir"],
            ]
            print("\t".join(fields))
        return

    if not rows:
        print("(agent summary empty)")
        return

    print("agent       queued  claimed  blocked  active  idle  session")
    for row in rows:
        idle_seconds = _latched_idle_seconds(row, current_ts)
        idle_label = "-" if idle_seconds < 0 else f"{idle_seconds}s"
        print(
            f"{row['agent']:<10} {row['queued_count']:>6}  {row['claimed_count']:>7}  "
            f"{row['blocked_count']:>7}  {row['active']:>6}  {idle_label:>5}  {row['session'] or '-'}"
        )


def maybe_cancel_cron_run(task: sqlite3.Row, current_ts: int) -> None:
    title = str(task["title"] or "")
    body_path_text = str(task["body_path"] or "").strip()
    if "[cron-dispatch]" not in title and "cron-dispatch" not in body_path_text:
        return

    run_id = Path(body_path_text).stem
    if not run_id:
        return

    run_dir = get_cron_state_dir() / "runs" / run_id
    request_path = run_dir / "request.json"
    result_path = run_dir / "result.json"
    status_path = run_dir / "status.json"

    request: dict[str, object] = {}
    status: dict[str, object] = {}
    if request_path.is_file():
        try:
            request = json.loads(request_path.read_text(encoding="utf-8"))
        except Exception:
            request = {}
    if status_path.is_file():
        try:
            status = json.loads(status_path.read_text(encoding="utf-8"))
        except Exception:
            status = {}

    payload = {
        "run_id": run_id,
        "state": "cancelled",
        "engine": str(status.get("engine") or request.get("target_engine") or ""),
        "updated_at": datetime.fromtimestamp(current_ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds"),
        "request_file": str(status.get("request_file") or request.get("request_file") or request_path),
        "result_file": str(status.get("result_file") or request.get("result_file") or result_path),
        "error": "cancelled via task queue",
    }

    status_path.parent.mkdir(parents=True, exist_ok=True)
    status_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def cmd_create(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    body_path = normalize_path(args.body_file)
    body_text = args.body
    created_ts = now_ts()

    if body_text is not None:
        shell_var = detect_unexpanded_shell_variable(body_text)
        if shell_var:
            print(
                f'warning: --body contains unexpanded shell variable "{shell_var}" - '
                "did you forget to export it, or should you use --body-file?",
                file=sys.stderr,
            )
        if not args.allow_empty_body and not body_text.strip():
            raise SystemExit(
                "empty --body after trimming whitespace; omit --body, use --body-file, "
                "or pass --allow-empty-body"
            )

    if body_path is not None:
        inline_text, body_path = stabilize_body_file(body_path)
        if body_text is None:
            body_text = inline_text

    with closing(connect()) as conn, conn:
        cursor = conn.execute(
            """
            INSERT INTO tasks (
              title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path
            ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?)
            """,
            (
                args.title.strip(),
                args.assigned_to,
                actor,
                args.priority,
                created_ts,
                created_ts,
                body_text,
                body_path,
            ),
        )
        task_id = int(cursor.lastrowid)
        emit_event(
            conn,
            task_id,
            event_type="created",
            actor=actor,
            created_ts=created_ts,
            note_text=body_text,
            note_path=body_path,
            to_agent=args.assigned_to,
        )

    if args.format == "shell":
        fields = {
            "TASK_ID": task_id,
            "TASK_TITLE": args.title.strip(),
            "TASK_ASSIGNED_TO": args.assigned_to,
            "TASK_CREATED_BY": actor,
            "TASK_PRIORITY": args.priority,
            "TASK_BODY_PATH": body_path or "",
            "TASK_BODY_TEXT": body_text or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    print(f"created task #{task_id} for {args.assigned_to} [{args.priority}] {args.title.strip()}")
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    statuses = list(args.status or [])
    if args.all:
        statuses = list(STATUS_CHOICES)
    if not statuses:
        statuses = list(OPEN_STATUSES)

    placeholders = ",".join(["?"] * len(statuses))
    params: list[object] = [args.agent, *statuses]
    sql = f"""
        SELECT id, status, priority, title, updated_ts, created_by, claimed_by, body_path
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ({placeholders})
        ORDER BY {priority_sort_sql()}, CASE status WHEN 'claimed' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END, id
    """

    with closing(connect()) as conn:
        rows = conn.execute(sql, params).fetchall()

    if not rows:
        print(f"(inbox empty for {args.agent})")
        return 0

    print(f"inbox: {args.agent}")
    print("id  status   priority  owner      title")
    for row in rows:
        owner = row["claimed_by"] or row["created_by"]
        print(f"{row['id']:<3} {row['status']:<8} {row['priority']:<8} {owner:<10} {row['title']}")
        if row["body_path"]:
            print(f"    file: {row['body_path']}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    with closing(connect()) as conn:
        task = require_task(conn, args.task_id)
        events = conn.execute(
            """
            SELECT event_type, actor, created_ts, note_text, note_path, from_agent, to_agent
            FROM task_events
            WHERE task_id = ?
            ORDER BY id
            """,
            (args.task_id,),
        ).fetchall()

    if args.format == "shell":
        fields = {
            "TASK_ID": task["id"],
            "TASK_TITLE": task["title"],
            "TASK_STATUS": task["status"],
            "TASK_ASSIGNED_TO": task["assigned_to"],
            "TASK_CREATED_BY": task["created_by"],
            "TASK_PRIORITY": task["priority"],
            "TASK_CLAIMED_BY": task["claimed_by"] or "",
            "TASK_BODY_PATH": task["body_path"] or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    print(f"task #{task['id']}: {task['title']}")
    print(f"status: {task['status']}")
    print(f"assigned_to: {task['assigned_to']}")
    print(f"created_by: {task['created_by']}")
    print(f"priority: {task['priority']}")
    print(f"created_at: {isoformat_ts(task['created_ts'])}")
    print(f"updated_at: {isoformat_ts(task['updated_ts'])}")
    print(f"claimed_by: {task['claimed_by'] or '-'}")
    print(f"lease_until: {isoformat_ts(task['lease_until_ts'])}")
    if task["body_text"]:
        print("body:")
        print(task["body_text"])
    if task["body_path"]:
        print(f"body_file: {task['body_path']}")
    print("")
    print("events:")
    for event in events:
        transfer = ""
        if event["from_agent"] or event["to_agent"]:
            transfer = f" ({event['from_agent'] or '-'} -> {event['to_agent'] or '-'})"
        print(f"- {isoformat_ts(event['created_ts'])} {event['event_type']} by {event['actor']}{transfer}")
        if event["note_text"]:
            print(f"  note: {event['note_text']}")
        if event["note_path"]:
            print(f"  file: {event['note_path']}")
    return 0


def cmd_find_open(args: argparse.Namespace) -> int:
    # PR1.7 — `--mode` selector for the cron-followup dedupe contract.
    #   refresh-by-job (default): the existing prefix-match behavior. Used
    #     by `delivery_intent=main_session_only` so consecutive runs
    #     refresh a single open task ("current state of this monitor").
    #   per-run: always returns nothing. Used by
    #     `delivery_intent=forward_to_user` so each distinct human-facing
    #     alert gets its own task and never overwrites an unread one.
    mode = getattr(args, "mode", "refresh-by-job") or "refresh-by-job"
    if mode == "per-run":
        if getattr(args, "all", False):
            print(json.dumps([], ensure_ascii=False))
        return 1

    params: list[object] = [args.agent]
    sql = """
        SELECT *
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ('queued', 'claimed', 'blocked')
    """
    if args.title_prefix:
        sql += " AND title LIKE ?"
        params.append(f"{args.title_prefix}%")
    sql += """
        ORDER BY
          CASE priority
            WHEN 'urgent' THEN 0
            WHEN 'high'   THEN 1
            WHEN 'normal' THEN 2
            WHEN 'low'    THEN 3
            ELSE 4
          END,
          id
    """
    if not getattr(args, "all", False):
        sql += " LIMIT 1"

    with closing(connect()) as conn:
        rows = conn.execute(sql, params).fetchall()

    if getattr(args, "all", False):
        payload = [
            {
                "id": int(r["id"]),
                "title": str(r["title"] or ""),
                "status": str(r["status"] or ""),
                "assigned_to": str(r["assigned_to"] or ""),
                "created_by": str(r["created_by"] or ""),
                "priority": str(r["priority"] or ""),
                "claimed_by": str(r["claimed_by"] or ""),
                "body_path": str(r["body_path"] or ""),
                "created_ts": int(r["created_ts"] or 0),
                "updated_ts": int(r["updated_ts"] or 0),
            }
            for r in rows
        ]
        print(json.dumps(payload, ensure_ascii=False))
        return 0 if payload else 1

    row = rows[0] if rows else None
    if row is None:
        return 1

    if args.format == "json":
        print(
            json.dumps(
                {
                    "id": int(row["id"]),
                    "title": str(row["title"] or ""),
                    "status": str(row["status"] or ""),
                    "assigned_to": str(row["assigned_to"] or ""),
                    "created_by": str(row["created_by"] or ""),
                    "priority": str(row["priority"] or ""),
                    "claimed_by": str(row["claimed_by"] or ""),
                    "body_path": str(row["body_path"] or ""),
                },
                ensure_ascii=False,
            )
        )
        return 0

    if args.format == "shell":
        fields = {
            "TASK_ID": row["id"],
            "TASK_TITLE": row["title"],
            "TASK_STATUS": row["status"],
            "TASK_ASSIGNED_TO": row["assigned_to"],
            "TASK_CREATED_BY": row["created_by"],
            "TASK_PRIORITY": row["priority"],
            "TASK_CLAIMED_BY": row["claimed_by"] or "",
            "TASK_BODY_PATH": row["body_path"] or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    if args.format == "id":
        print(row["id"])
        return 0

    print(f"task #{row['id']}: {row['title']}")
    print(f"status: {row['status']}")
    print(f"assigned_to: {row['assigned_to']}")
    print(f"priority: {row['priority']}")
    if row["body_path"]:
        print(f"body_file: {row['body_path']}")
    return 0


def cmd_claim(args: argparse.Namespace) -> int:
    agent = args.agent
    lease_seconds = int(args.lease_seconds)
    current_ts = now_ts()
    lease_until_ts = current_ts + lease_seconds

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] == "claimed" and task["claimed_by"] == agent:
            conn.execute(
                "UPDATE tasks SET lease_until_ts = ? WHERE id = ?",
                (lease_until_ts, args.task_id),
            )
            touch_agent_activity(conn, agent, current_ts)
            print(f"task #{args.task_id} already claimed by {agent}; lease extended")
            return 0

        if task["status"] != "queued":
            raise SystemExit(f"task #{args.task_id} is not claimable (status={task['status']})")
        if task["assigned_to"] != agent:
            raise SystemExit(f"task #{args.task_id} is assigned to {task['assigned_to']}, not {agent}")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'claimed',
                claimed_by = ?,
                claimed_ts = ?,
                lease_until_ts = ?,
                updated_ts = ?
            WHERE id = ?
            """,
            (agent, current_ts, lease_until_ts, current_ts, args.task_id),
        )
        emit_event(conn, args.task_id, event_type="claimed", actor=agent, created_ts=current_ts, to_agent=agent)
        touch_agent_activity(conn, agent, current_ts)

    print(f"claimed task #{args.task_id} as {agent} (lease={lease_seconds}s)")
    return 0


def cmd_done(args: argparse.Namespace) -> int:
    agent = args.agent
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] == "done":
            print(f"task #{args.task_id} already done")
            return 0
        if task["assigned_to"] != agent and task["claimed_by"] not in (None, agent):
            raise SystemExit(f"task #{args.task_id} is owned by {task['claimed_by']}, not {agent}")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'done',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?,
                closed_ts = ?
            WHERE id = ?
            """,
            (current_ts, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="done",
            actor=agent,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=agent,
            to_agent=task["assigned_to"],
        )
        touch_agent_activity(conn, agent, current_ts)

    print(f"completed task #{args.task_id} as {agent}")
    return 0


def cmd_cancel(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if _running_under_queue_gateway_server():
            # Defense-in-depth: even if the gateway authorizer is wrong,
            # the server refuses to cancel a task the actor does not own.
            _gateway_server_authorize(task, actor, "cancel")
        if task["status"] == "cancelled":
            print(f"task #{args.task_id} already cancelled")
            return 0
        if task["status"] == "done":
            raise SystemExit(f"task #{args.task_id} is already closed (status=done)")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'cancelled',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?,
                closed_ts = ?
            WHERE id = ?
            """,
            (current_ts, current_ts, args.task_id),
        )
        maybe_cancel_cron_run(task, current_ts)
        emit_event(
            conn,
            args.task_id,
            event_type="cancelled",
            actor=actor,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=task["claimed_by"] or task["assigned_to"],
            to_agent=task["assigned_to"],
        )

    print(f"cancelled task #{args.task_id} as {actor}")
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.body_file)
    stabilized_text: str | None = None
    if note_path is not None:
        stabilized_text, note_path = stabilize_body_file(note_path)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if _running_under_queue_gateway_server():
            # Defense-in-depth: refuse to mutate a task the actor does
            # not own, even if the gateway authorizer was wrong.
            _gateway_server_authorize(task, actor, "update")
        if task["status"] in ("done", "cancelled"):
            raise SystemExit(f"task #{args.task_id} is already closed (status={task['status']})")

        title = args.title.strip() if args.title is not None else task["title"]
        priority = args.priority or task["priority"]
        status = normalize_open_status(args.status) or task["status"]
        body_text = task["body_text"]
        body_path = task["body_path"]

        if args.body is not None:
            body_text = args.body
            body_path = None
        elif args.body_file is not None:
            body_text = stabilized_text
            body_path = note_path

        conn.execute(
            """
            UPDATE tasks
            SET title = ?,
                priority = ?,
                status = ?,
                body_text = ?,
                body_path = ?,
                updated_ts = ?
            WHERE id = ?
            """,
            (title, priority, status, body_text, body_path, current_ts, args.task_id),
        )
        event_note = args.body or args.note
        emit_event(
            conn,
            args.task_id,
            event_type="updated",
            actor=actor,
            created_ts=current_ts,
            note_text=event_note,
            note_path=note_path,
            to_agent=task["assigned_to"],
        )

    print(f"updated task #{args.task_id}")
    return 0


def cmd_handoff(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if _running_under_queue_gateway_server():
            # Defense-in-depth: refuse to hand off a task the actor does
            # not own. The gateway only allows assigned_to/claimed_by to
            # hand off; this re-check accepts created_by too because the
            # task creator can also redirect their own work — narrower
            # than the gateway's policy is fine, broader is not.
            owners = {
                str(task["assigned_to"] or ""),
                str(task["claimed_by"] or ""),
            }
            owners.discard("")
            if actor not in owners:
                raise SystemExit(
                    f"queue gateway server denied handoff: actor {actor!r} is not "
                    f"the assignee or claimer of task #{task['id']}"
                )
        if task["status"] in ("done", "cancelled"):
            raise SystemExit(f"task #{args.task_id} is already closed (status={task['status']})")

        conn.execute(
            """
            UPDATE tasks
            SET assigned_to = ?,
                status = 'queued',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?
            WHERE id = ?
            """,
            (args.assigned_to, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="handoff",
            actor=actor,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=task["assigned_to"],
            to_agent=args.assigned_to,
        )

    print(f"handed off task #{args.task_id} to {args.assigned_to}")
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    with closing(connect()) as conn:
        rows = agent_summary_rows(conn, args.agent)
    print_summary(rows, args.format)
    return 0


_COMPANION_FOCUS_HEADINGS = (
    "## focus checklist",
    "## focus list",
    "## focus",
    "### focus",
    "focus checklist:",
    "focus list:",
)
_COMPANION_OUTPUT_TOKENS = (
    "plan-ok",
    "implement-ok",
    "needs-more",
    "expected output",
)


def companion_title_prefix_match(title: str) -> bool:
    """Return True iff the title's first bracket matches a companion-role prefix.

    Matches `[plan]`, `[review]`, `[review r2]`, `[review r3]`, etc. Anything
    after the first whitespace following the bracket is the subject and is
    ignored. Case-insensitive.
    """
    stripped = (title or "").strip().lower()
    if not stripped.startswith("["):
        return False
    end = stripped.find("]")
    if end <= 0:
        return False
    inner = stripped[1:end].strip()
    if not inner:
        return False
    head = inner.split(None, 1)[0]
    return head in {"plan", "review"}


def companion_body_missing_sections(body_text: str) -> list[str]:
    """Return the list of missing companion-role brief sections.

    A companion-role review brief must contain (a) a focus checklist (or
    focus list / focus heading) AND (b) an explicit expected-output mention
    naming `plan-ok`, `implement-ok`, `needs-more`, or "expected output".
    Returns an empty list if both are present, otherwise the missing names.
    """
    missing: list[str] = []
    haystack = (body_text or "").lower()
    if not any(token in haystack for token in _COMPANION_FOCUS_HEADINGS):
        missing.append("focus checklist")
    if not any(token in haystack for token in _COMPANION_OUTPUT_TOKENS):
        missing.append("expected output shape")
    return missing


def cmd_validate_companion_body(args: argparse.Namespace) -> int:
    """Pure validator helper: prefix + body → OK or structured missing-list.

    Roster awareness lives in the shell caller (`bridge-task.sh cmd_create`),
    which knows the recipient engine/class. This helper is engine-agnostic
    and can be invoked from smoke tests directly.

    Exit codes:
      0 — body validates (or title prefix is not a companion-role prefix)
      2 — body is missing required sections
      1 — usage / IO error
    """
    title = args.title or ""
    body_text = ""
    if args.body_file:
        try:
            body_text = Path(args.body_file).expanduser().read_text(encoding="utf-8")
        except OSError as exc:
            print(f"error: cannot read body file: {exc}", file=sys.stderr)
            return 1
    elif args.body is not None:
        body_text = args.body
    else:
        body_text = sys.stdin.read() if not sys.stdin.isatty() else ""

    if not companion_title_prefix_match(title):
        if args.format == "json":
            print(json.dumps({"status": "skip", "reason": "title-not-companion-prefix"}))
        else:
            print("skip: title prefix is not a companion-role prefix")
        return 0

    missing = companion_body_missing_sections(body_text)
    if not missing:
        if args.format == "json":
            print(json.dumps({"status": "ok"}))
        else:
            print("ok")
        return 0

    payload = {
        "status": "missing",
        "missing": missing,
        "title": title.strip(),
    }
    if args.format == "json":
        print(json.dumps(payload))
    else:
        print(f"missing: {', '.join(missing)}", file=sys.stderr)
    return 2


def cmd_cron_ready(args: argparse.Namespace) -> int:
    sql = """
        SELECT id, assigned_to, priority, title, body_path, created_ts
        FROM tasks
        WHERE status = 'queued'
          AND title LIKE '[cron-dispatch]%'
        ORDER BY id
        LIMIT ?
    """

    with closing(connect()) as conn:
        rows = conn.execute(sql, (int(args.limit),)).fetchall()

    status_by_agent = load_roster_status(args.status_snapshot) if args.status_snapshot else {}
    defer_seconds = max(0, int(args.memory_daily_defer_seconds))
    current_ts = now_ts()
    ranked_rows = []
    for row in rows:
        family = dispatch_task_family(row)
        agent_state = status_by_agent.get(str(row["assigned_to"]), {})
        active = str(agent_state.get("active") or "0") == "1"
        activity_state = str(agent_state.get("activity_state") or ("idle" if not active else "working")).strip() or (
            "idle" if not active else "working"
        )
        created_ts = int(row["created_ts"] or current_ts)
        age_seconds = max(0, current_ts - created_ts)

        if family == "memory-daily" and active and activity_state == "working" and age_seconds < defer_seconds:
            continue

        rank = 1
        if family == "memory-daily":
            rank = 0 if (not active or activity_state != "working") else 2
        ranked_rows.append((rank, int(row["id"]), row))

    rows = [row for _, _, row in sorted(ranked_rows, key=lambda item: (item[0], item[1]))]

    if args.format == "tsv":
        for row in rows:
            print(
                "\t".join(
                    [
                        str(row["id"]),
                        str(row["assigned_to"]),
                        str(row["priority"]),
                        str(row["title"]),
                        str(row["body_path"] or ""),
                    ]
                )
            )
        return 0

    if not rows:
        print("(no queued cron-dispatch tasks)")
        return 0

    print("id  assigned_to  priority  title")
    for row in rows:
        print(f"{row['id']:<3} {row['assigned_to']:<11} {row['priority']:<8} {row['title']}")
        if row["body_path"]:
            print(f"    file: {row['body_path']}")
    return 0


def load_snapshot(path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if row.get("agent"):
                rows.append(row)
    return rows


def load_roster_status(path: str) -> dict[str, dict[str, str]]:
    rows: dict[str, dict[str, str]] = {}
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            agent = str(row.get("agent") or "").strip()
            if agent:
                rows[agent] = row
    return rows


def dispatch_task_family(row: sqlite3.Row) -> str:
    body_path = str(row["body_path"] or "").strip()
    if body_path and os.path.isfile(body_path):
        try:
            with open(body_path, "r", encoding="utf-8", errors="replace") as handle:
                for _index, line in enumerate(handle):
                    if _index > 40:
                        break
                    if line.startswith("- family:"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return classify_family(str(row["title"] or ""))


def latest_event_ts(conn: sqlite3.Connection, task_id: int, event_type: str) -> int:
    row = conn.execute(
        """
        SELECT MAX(created_ts) AS created_ts
        FROM task_events
        WHERE task_id = ? AND event_type = ?
        """,
        (task_id, event_type),
    ).fetchone()
    if not row:
        return 0
    value = row["created_ts"]
    return int(value or 0)


def find_open_task_by_prefix(conn: sqlite3.Connection, agent: str, title_prefix: str) -> sqlite3.Row | None:
    placeholders = ",".join(["?"] * len(OPEN_STATUSES))
    params: list[object] = [agent, *OPEN_STATUSES, f"{title_prefix}%"]
    return conn.execute(
        f"""
        SELECT *
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ({placeholders})
          AND title LIKE ?
        ORDER BY
          CASE priority
            WHEN 'urgent' THEN 0
            WHEN 'high'   THEN 1
            WHEN 'normal' THEN 2
            WHEN 'low'    THEN 3
            ELSE 4
          END,
          id
        LIMIT 1
        """,
        params,
    ).fetchone()


def create_queue_task(
    conn: sqlite3.Connection,
    *,
    title: str,
    assigned_to: str,
    actor: str,
    priority: str,
    created_ts: int,
    body_text: str | None = None,
    body_path: str | None = None,
) -> int:
    cursor = conn.execute(
        """
        INSERT INTO tasks (
          title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path
        ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?)
        """,
        (
            title,
            assigned_to,
            actor,
            priority,
            created_ts,
            created_ts,
            body_text,
            body_path,
        ),
    )
    task_id = int(cursor.lastrowid)
    emit_event(
        conn,
        task_id,
        event_type="created",
        actor=actor,
        created_ts=created_ts,
        note_text=body_text,
        note_path=body_path,
        to_agent=assigned_to,
    )
    return task_id


def refresh_queue_task(
    conn: sqlite3.Connection,
    *,
    task_id: int,
    title: str,
    priority: str,
    actor: str,
    updated_ts: int,
    body_text: str | None,
    note_text: str,
) -> None:
    conn.execute(
        """
        UPDATE tasks
        SET title = ?,
            priority = ?,
            body_text = ?,
            body_path = NULL,
            updated_ts = ?
        WHERE id = ?
        """,
        (title, priority, body_text, updated_ts, task_id),
    )
    emit_event(
        conn,
        task_id,
        event_type="updated",
        actor=actor,
        created_ts=updated_ts,
        note_text=note_text,
    )


def upsert_open_task(
    conn: sqlite3.Connection,
    *,
    agent: str,
    title_prefix: str,
    title: str,
    priority: str,
    actor: str,
    body_text: str,
    current_ts: int,
    refresh_note: str,
) -> tuple[int, bool]:
    existing = find_open_task_by_prefix(conn, agent, title_prefix)
    if existing:
        refresh_queue_task(
            conn,
            task_id=int(existing["id"]),
            title=title,
            priority=priority,
            actor=actor,
            updated_ts=current_ts,
            body_text=body_text,
            note_text=refresh_note,
        )
        return int(existing["id"]), False

    task_id = create_queue_task(
        conn,
        title=title,
        assigned_to=agent,
        actor=actor,
        priority=priority,
        created_ts=current_ts,
        body_text=body_text,
    )
    return task_id, True


def format_task_age(seconds: int) -> str:
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def blocked_reminder_title(task_id: int) -> str:
    return f"{BLOCKED_REMINDER_TITLE_PREFIX}{task_id} needs status refresh"


def blocked_escalation_title(task_id: int) -> str:
    return f"{BLOCKED_ESCALATION_TITLE_PREFIX}{task_id} needs admin review"


def blocked_task_reminder_body(task: sqlite3.Row, age_seconds: int, reminder_seconds: int) -> str:
    task_id = int(task["id"])
    title = str(task["title"] or "").strip()
    assigned_to = str(task["assigned_to"] or "").strip()
    claimed_by = str(task["claimed_by"] or "").strip()
    body_path = str(task["body_path"] or "").strip()
    lines = [
        "# Blocked Task Reminder",
        "",
        f"- original_task_id: {task_id}",
        f"- original_title: {title}",
        f"- assigned_to: {assigned_to}",
        f"- claimed_by: {claimed_by or '-'}",
        f"- blocked_age: {format_task_age(age_seconds)}",
        f"- last_updated_at: {isoformat_ts(int(task['updated_ts'] or 0))}",
        f"- reminder_interval: {format_task_age(reminder_seconds)}",
    ]
    if body_path:
        lines.append(f"- original_body_file: {body_path}")
    lines.extend(
        [
            "",
            "This task has stayed blocked without a status refresh.",
            "",
            "## Self-Cleanup Decision Tree",
            "",
            "(admin contract; see CLAUDE.md `## Admin Self-Cleanup of Own Queue`)",
            "",
            "Apply (a)-(f) in order, ruling each one out in writing in your refresh note "
            "before reaching `refresh blocked`. Refresh is the exception, not the equilibrium.",
            "",
            "(a) original premise satisfied / invalidated by later events",
            f"    → `agb done {task_id} --agent {assigned_to} --note \"stale: <why>\"`",
            "(b) source agent moved on / closed its driving cycle",
            f"    → `agb done {task_id} --agent {assigned_to} --note \"source moved on\"`",
            "(c) another active task already covers this work",
            f"    → `agb handoff {task_id} --to <agent> --note \"<cross-ref>\"`"
            f" OR `agb done {task_id} --agent {assigned_to} --note \"duplicate of #<id>\"`",
            "(d) doable in <15 minutes by you alone",
            "    → unblock and do it now; do NOT defer as `tech debt`",
            "(e) operator decision required AND obtainable on the shared channel today",
            "    → escalate via Discord/Telegram, then refresh blocked with deadline",
            "(f) none of the above",
            f"    → `agb update {task_id} --status blocked --note \"I will revisit when "
            "<verifiable trigger>. Decision tree: ruled out (a)-(e) because: <one line>.\"`",
            "",
            "The `note` on a refresh-blocked must include both the verifiable trigger AND "
            "the one-line summary of why (a)-(e) were ruled out. Empty notes and bare-refresh "
            "notes are rejected by the contract.",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def blocked_task_escalation_body(
    task: sqlite3.Row,
    age_seconds: int,
    reminder_seconds: int,
    escalation_seconds: int,
) -> str:
    task_id = int(task["id"])
    title = str(task["title"] or "").strip()
    assigned_to = str(task["assigned_to"] or "").strip()
    reminder_count = max(1, age_seconds // max(1, reminder_seconds))
    lines = [
        "# Blocked Task Escalation",
        "",
        f"- original_task_id: {task_id}",
        f"- original_title: {title}",
        f"- assigned_to: {assigned_to}",
        f"- blocked_age: {format_task_age(age_seconds)}",
        f"- escalation_threshold: {format_task_age(escalation_seconds)}",
        f"- last_updated_at: {isoformat_ts(int(task['updated_ts'] or 0))}",
        f"- reminder_cycles_elapsed: {reminder_count}",
        "",
        "This blocked task has gone stale past the escalation threshold.",
        "Please review whether the assignee needs intervention, handoff, or closure.",
        "",
        "## Self-Cleanup Decision Tree",
        "",
        "(admin contract; see CLAUDE.md `## Admin Self-Cleanup of Own Queue`)",
        "",
        "Apply (a)-(f) in order, ruling each one out in writing in your refresh note "
        "before reaching `refresh blocked`. Refresh is the exception, not the equilibrium.",
        "",
        "(a) original premise satisfied / invalidated by later events",
        f"    → `agb done {task_id} --agent {assigned_to} --note \"stale: <why>\"`",
        "(b) source agent moved on / closed its driving cycle",
        f"    → `agb done {task_id} --agent {assigned_to} --note \"source moved on\"`",
        "(c) another active task already covers this work",
        f"    → `agb handoff {task_id} --to <agent> --note \"<cross-ref>\"`"
        f" OR `agb done {task_id} --agent {assigned_to} --note \"duplicate of #<id>\"`",
        "(d) doable in <15 minutes by you alone",
        "    → unblock and do it now; do NOT defer as `tech debt`",
        "(e) operator decision required AND obtainable on the shared channel today",
        "    → escalate via Discord/Telegram, then refresh blocked with deadline",
        "(f) none of the above",
        f"    → `agb update {task_id} --status blocked --note \"I will revisit when "
        "<verifiable trigger>. Decision tree: ruled out (a)-(e) because: <one line>.\"`",
        "",
        "The `note` on a refresh-blocked must include both the verifiable trigger AND "
        "the one-line summary of why (a)-(e) were ruled out. Empty notes and bare-refresh "
        "notes are rejected by the contract.",
        "",
        "This is the second escalation cycle for this id. If you cannot reach (a)-(e) this "
        "round, the operator will be paged via the shared channel; do not bare-refresh.",
    ]
    return "\n".join(lines).rstrip() + "\n"


def process_blocked_task_aging(
    conn: sqlite3.Connection,
    *,
    current_ts: int,
    reminder_seconds: int,
    escalation_seconds: int,
    admin_agent: str,
) -> None:
    if reminder_seconds <= 0:
        return

    blocked_rows = conn.execute(
        """
        SELECT id, title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path,
               claimed_by, claimed_ts, lease_until_ts, closed_ts
        FROM tasks
        WHERE status = 'blocked'
          AND updated_ts < ?
          AND title NOT LIKE '[blocked-aging]%'
          AND title NOT LIKE '[blocked-escalation]%'
        ORDER BY updated_ts ASC, id ASC
        """,
        (current_ts - reminder_seconds,),
    ).fetchall()

    for task in blocked_rows:
        task_id = int(task["id"])
        age_seconds = max(0, current_ts - int(task["updated_ts"] or current_ts))

        last_reminder_ts = latest_event_ts(conn, task_id, "blocked_reminder")
        if last_reminder_ts == 0 or current_ts - last_reminder_ts >= reminder_seconds:
            title_prefix = f"{BLOCKED_REMINDER_TITLE_PREFIX}{task_id} "
            reminder_task_id, created = upsert_open_task(
                conn,
                agent=str(task["assigned_to"]),
                title_prefix=title_prefix,
                title=blocked_reminder_title(task_id),
                priority="normal",
                actor="daemon",
                body_text=blocked_task_reminder_body(task, age_seconds, reminder_seconds),
                current_ts=current_ts,
                refresh_note="daemon refreshed blocked-aging reminder",
            )
            emit_event(
                conn,
                task_id,
                event_type="blocked_reminder",
                actor="daemon",
                created_ts=current_ts,
                note_text=(
                    f"{'created' if created else 'refreshed'} reminder task #{reminder_task_id} "
                    f"for {task['assigned_to']}"
                ),
                to_agent=str(task["assigned_to"]),
            )

        if escalation_seconds <= 0 or age_seconds < escalation_seconds:
            continue
        if not admin_agent:
            continue

        last_escalated_ts = latest_event_ts(conn, task_id, "blocked_escalated")
        if last_escalated_ts != 0:
            continue

        title_prefix = f"{BLOCKED_ESCALATION_TITLE_PREFIX}{task_id} "
        escalation_task_id, created = upsert_open_task(
            conn,
            agent=admin_agent,
            title_prefix=title_prefix,
            title=blocked_escalation_title(task_id),
            priority="high",
            actor="daemon",
            body_text=blocked_task_escalation_body(task, age_seconds, reminder_seconds, escalation_seconds),
            current_ts=current_ts,
            refresh_note="daemon refreshed blocked-aging escalation",
        )
        emit_event(
            conn,
            task_id,
            event_type="blocked_escalated",
            actor="daemon",
            created_ts=current_ts,
            note_text=(
                f"{'created' if created else 'refreshed'} escalation task #{escalation_task_id} "
                f"for {admin_agent}"
            ),
            to_agent=admin_agent,
        )


def load_ready_agents(path: str | None) -> set[str]:
    if not path:
        return set()
    ready: set[str] = set()
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            agent = line.strip()
            if agent:
                ready.add(agent)
    return ready


def cmd_daemon_step(args: argparse.Namespace) -> int:
    snapshot_rows = load_snapshot(args.snapshot)
    ready_agents = load_ready_agents(getattr(args, "ready_agents_file", None))
    current_ts = now_ts()
    lease_seconds = int(args.lease_seconds)
    heartbeat_window = int(args.heartbeat_window)
    idle_threshold = int(args.idle_threshold)
    nudge_cooldown = int(args.nudge_cooldown)
    blocked_reminder_seconds = max(0, int(args.blocked_reminder_seconds))
    blocked_escalate_seconds = max(0, int(args.blocked_escalate_seconds))
    admin_agent = str(args.admin_agent or "").strip()
    queued_ids_by_agent: dict[str, list[int]] = {}

    with closing(connect()) as conn, conn:
        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            # Issue #589: prompt-ready latch propagation. The bash side writes
            # marker files; bridge_write_agent_snapshot mirrors them into the
            # snapshot row so we can upsert here. None values keep the column
            # NULL when no marker exists — _latched_idle_seconds treats that
            # as "no latch yet" and falls through to the grace window logic.
            prompt_ready_ts = int(row.get("prompt_ready_ts") or 0)
            prompt_ready_session = str(row.get("prompt_ready_session") or "")
            prompt_ready_source = str(row.get("prompt_ready_source") or "")
            conn.execute(
                """
                INSERT INTO agent_state (
                  agent, engine, session, workdir, active, last_seen_ts, last_heartbeat_ts, session_activity_ts,
                  prompt_ready_ts, prompt_ready_session, prompt_ready_source
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent) DO UPDATE SET
                  engine = excluded.engine,
                  session = excluded.session,
                  workdir = excluded.workdir,
                  active = excluded.active,
                  last_seen_ts = excluded.last_seen_ts,
                  last_heartbeat_ts = excluded.last_heartbeat_ts,
                  session_activity_ts = excluded.session_activity_ts,
                  prompt_ready_ts = excluded.prompt_ready_ts,
                  prompt_ready_session = excluded.prompt_ready_session,
                  prompt_ready_source = excluded.prompt_ready_source
                """,
                (
                    row["agent"],
                    row.get("engine", ""),
                    row.get("session", ""),
                    row.get("workdir", ""),
                    active,
                    current_ts if active else None,
                    current_ts,
                    activity_ts or None,
                    prompt_ready_ts or None,
                    prompt_ready_session or None,
                    prompt_ready_source or None,
                ),
            )

        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            if not active or not activity_ts:
                continue
            if current_ts - activity_ts > heartbeat_window:
                continue
            conn.execute(
                """
                UPDATE tasks
                SET lease_until_ts = CASE
                  WHEN lease_until_ts IS NULL OR lease_until_ts < ? THEN ?
                  ELSE lease_until_ts
                END
                WHERE status = 'claimed' AND claimed_by = ?
                """,
                (current_ts + lease_seconds, current_ts + lease_seconds, row["agent"]),
            )

        expired = conn.execute(
            """
            SELECT id, claimed_by
            FROM tasks
            WHERE status = 'claimed'
              AND lease_until_ts IS NOT NULL
              AND lease_until_ts < ?
            """,
            (current_ts,),
        ).fetchall()
        for row in expired:
            conn.execute(
                """
                UPDATE tasks
                SET status = 'queued',
                    claimed_by = NULL,
                    claimed_ts = NULL,
                    lease_until_ts = NULL,
                    updated_ts = ?
                WHERE id = ?
                """,
                (current_ts, row["id"]),
            )
            emit_event(
                conn,
                int(row["id"]),
                event_type="lease_expired",
                actor="daemon",
                created_ts=current_ts,
                note_text="lease expired after missing heartbeat",
                from_agent=row["claimed_by"],
            )

        # --- Compute idle agents (used by both cron dedup and stale requeue) ---
        max_claim_age = int(getattr(args, "max_claim_age", 900))
        idle_agents = set()
        active_agents = set()
        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            if active:
                active_agents.add(str(row["agent"]))
            if active and activity_ts and current_ts - activity_ts >= idle_threshold:
                idle_agents.add(str(row["agent"]))

        # --- Cron-dispatch dedup ---
        # For each (agent, cron-job-name) combo, keep only the newest open
        # dispatch and cancel older duplicates.  The newest one stays queued
        # (or gets requeued if claimed by an idle agent) so it still runs.
        # Single dispatches (e.g. one evening-digest) are untouched here;
        # the stale-claim requeue below handles them if the agent is idle.
        import re as _re
        _cron_name_re = _re.compile(r"^\[cron-dispatch\]\s*(\S+)")
        cron_open = conn.execute(
            """
            SELECT id, title, assigned_to, status, claimed_by, created_ts
            FROM tasks
            WHERE status IN ('queued', 'claimed')
              AND title LIKE '[cron-dispatch]%'
            ORDER BY created_ts DESC
            """,
        ).fetchall()
        _cron_groups: dict[tuple[str, str], list[sqlite3.Row]] = {}
        for row in cron_open:
            m = _cron_name_re.match(row["title"])
            job_name = m.group(1) if m else row["title"]
            key = (str(row["assigned_to"]), job_name)
            _cron_groups.setdefault(key, []).append(row)
        # Issue #266: in recovery scenarios (worker pool backlog, daemon hang
        # recovery), the newest slot itself often has not been fired by the
        # time the next cron tick adds a still-newer slot. The previous logic
        # cancelled every non-newest open slot, which meant a high-frequency
        # cron with worker latency > cron interval never actually ran — every
        # fresh slot got superseded by the next before a worker could claim it
        # (cs-line-poll-5m: zero successful runs across 144 slots in 36h).
        # Two layered guards: (1) preserve any sibling that is still inside
        # the grace window (worker may still pick it up); (2) if the newest
        # slot has not itself been fired yet, leave older un-claimed siblings
        # in place so the worker can pick whichever it reaches first instead
        # of seeing an empty queue while a stuck cron quietly drops fires.
        try:
            _supersede_grace = int(os.environ.get("BRIDGE_CRON_SUPERSEDE_GRACE_SECONDS", "60"))
        except (TypeError, ValueError):
            _supersede_grace = 60
        if _supersede_grace < 0:
            _supersede_grace = 0
        for _key, group in _cron_groups.items():
            if len(group) < 2:
                continue
            newest = group[0]
            newest_fired = bool(newest["claimed_by"]) or newest["status"] == "claimed"
            for row in group[1:]:
                created_ts = row["created_ts"] or 0
                if (current_ts - created_ts) < _supersede_grace and not row["claimed_by"]:
                    continue
                if not newest_fired and not row["claimed_by"]:
                    continue
                conn.execute(
                    """
                    UPDATE tasks
                    SET status = 'cancelled',
                        claimed_by = NULL,
                        lease_until_ts = NULL,
                        updated_ts = ?
                    WHERE id = ?
                    """,
                    (current_ts, row["id"]),
                )
                emit_event(
                    conn,
                    int(row["id"]),
                    event_type="cron_dedup_cancelled",
                    actor="daemon",
                    created_ts=current_ts,
                    note_text=f"superseded by newer dispatch #{group[0]['id']}",
                    from_agent=row["claimed_by"] or row["assigned_to"],
                )

        # --- Idle agent claimed task requeue ---
        # ALL claimed tasks (cron or not) older than max_claim_age from idle
        # agents get requeued.  An idle agent is at the prompt and not working
        # on anything — its claimed tasks should be released.
        stale_claimed = conn.execute(
            """
            SELECT id, claimed_by
            FROM tasks
            WHERE status = 'claimed'
              AND claimed_ts IS NOT NULL
              AND claimed_ts < ?
            """,
            (current_ts - max_claim_age,),
        ).fetchall()
        for row in stale_claimed:
            agent_name = str(row["claimed_by"])
            note_text = ""
            if agent_name not in active_agents:
                note_text = f"claimed for >{max_claim_age}s by inactive agent"
            elif agent_name in idle_agents:
                note_text = f"claimed for >{max_claim_age}s by idle agent"
            else:
                continue
            conn.execute(
                """
                UPDATE tasks
                SET status = 'queued',
                    claimed_by = NULL,
                    claimed_ts = NULL,
                    lease_until_ts = NULL,
                    updated_ts = ?
                WHERE id = ?
                """,
                (current_ts, row["id"]),
            )
            emit_event(
                conn,
                int(row["id"]),
                event_type="stale_claim_requeued",
                actor="daemon",
                created_ts=current_ts,
                note_text=note_text,
                from_agent=agent_name,
            )

        process_blocked_task_aging(
            conn,
            current_ts=current_ts,
            reminder_seconds=blocked_reminder_seconds,
            escalation_seconds=blocked_escalate_seconds,
            admin_agent=admin_agent,
        )

        # Issue #946 L4 / PR #952 r2: maintenance is complete (lease extend
        # / expire, cron de-dupe, stale-claim requeue, blocked-task aging).
        # If the caller passed --skip-nudges (the bash daemon's L4 fail-path
        # uses this when bridge_write_idle_ready_agents failed) return now
        # without consuming the ready-agents file or emitting nudge rows.
        # Production-side proof: tests/smoke gating reads the audit log for
        # the maintenance side-effects regardless of the skip flag.
        if getattr(args, "skip_nudges", False):
            if args.format == "text":
                print("(maintenance-only; nudges skipped)")
            return 0

        rows = conn.execute(
            """
            SELECT assigned_to, id
            FROM tasks
            WHERE status = 'queued'
              AND title NOT LIKE '[cron-dispatch]%'
            ORDER BY assigned_to, id
            """
        ).fetchall()
        for row in rows:
            queued_ids_by_agent.setdefault(str(row["assigned_to"]), []).append(int(row["id"]))

        rows = conn.execute(
            f"""
            WITH assigned AS (
              SELECT assigned_to AS agent, COUNT(*) AS queued_count
              FROM tasks
              WHERE status = 'queued'
                AND title NOT LIKE '[cron-dispatch]%'
              GROUP BY assigned_to
            ),
            claimed AS (
              SELECT claimed_by AS agent, COUNT(*) AS claimed_count
              FROM tasks
              WHERE status = 'claimed' AND claimed_by IS NOT NULL
              GROUP BY claimed_by
            )
            SELECT
              agent_state.agent,
              agent_state.session,
              COALESCE(assigned.queued_count, 0) AS queued_count,
              COALESCE(claimed.claimed_count, 0) AS claimed_count,
              agent_state.session_activity_ts,
              agent_state.last_seen_ts,
              agent_state.last_nudge_ts,
              agent_state.last_nudge_key,
              agent_state.nudge_fail_count,
              agent_state.zombie
            FROM agent_state
            LEFT JOIN assigned ON assigned.agent = agent_state.agent
            LEFT JOIN claimed ON claimed.agent = agent_state.agent
            WHERE agent_state.active = 1
              AND COALESCE(assigned.queued_count, 0) > 0
            ORDER BY agent_state.agent
            """
        ).fetchall()

    printed = False
    for row in rows:
        is_ready_agent = str(row["agent"]) in ready_agents
        activity_ts = row["session_activity_ts"] or row["last_seen_ts"] or 0
        if not activity_ts and not is_ready_agent:
            continue
        idle_seconds = max(0, current_ts - int(activity_ts)) if activity_ts else 0
        if not is_ready_agent and idle_seconds < idle_threshold:
            continue
        queue_ids = queued_ids_by_agent.get(str(row["agent"]), [])
        if not queue_ids:
            continue
        nudge_key = ",".join(str(task_id) for task_id in queue_ids)
        last_nudge_ts = int(row["last_nudge_ts"] or 0)
        last_nudge_key = row["last_nudge_key"] or ""
        zombie = int(row["zombie"] or 0)
        if zombie:
            continue
        last_nudged_ids = {item for item in last_nudge_key.split(",") if item}
        has_new_queue_ids = any(str(task_id) not in last_nudged_ids for task_id in queue_ids)
        if last_nudge_ts and current_ts - last_nudge_ts < nudge_cooldown and not has_new_queue_ids:
            continue
        # Suppress repeats for the same queue until the session shows activity again,
        # but allow a fresh nudge when new queued task ids arrive.
        if last_nudge_ts and int(activity_ts) and last_nudge_ts >= int(activity_ts) and not has_new_queue_ids:
            continue
        printed = True
        print(
            "\t".join(
                [
                    row["agent"],
                    row["session"],
                    str(row["queued_count"]),
                    str(row["claimed_count"]),
                    str(idle_seconds),
                    nudge_key,
                ]
            )
        )

    if args.format == "text" and not printed:
        print("(no nudge candidates)")
    return 0


def cmd_note_nudge(args: argparse.Namespace) -> int:
    current_ts = now_ts()
    with closing(connect()) as conn, conn:
        conn.execute(
            """
            INSERT INTO agent_state (agent, last_nudge_ts, last_nudge_key, nudge_fail_count, zombie)
            VALUES (?, ?, ?, 1, 0)
            ON CONFLICT(agent) DO UPDATE SET
              last_nudge_ts = excluded.last_nudge_ts,
              last_nudge_key = excluded.last_nudge_key,
              nudge_fail_count = COALESCE(agent_state.nudge_fail_count, 0) + 1,
              zombie = CASE
                WHEN COALESCE(agent_state.nudge_fail_count, 0) + 1 >= ? THEN 1
                ELSE agent_state.zombie
              END
            """,
            (args.agent, current_ts, args.key, args.zombie_threshold),
        )
    print(f"recorded nudge for {args.agent}")
    return 0


def cmd_events(args: argparse.Namespace) -> int:
    import json as _json

    after_id = args.after_id
    limit = args.limit
    event_type = args.event_type

    with closing(connect()) as conn:
        query = """
            SELECT
                e.id, e.task_id, e.event_type, e.actor, e.created_ts,
                e.note_text, e.note_path, e.from_agent, e.to_agent,
                t.title AS task_title, t.body_text AS task_body,
                t.body_path AS task_body_path,
                t.assigned_to, t.created_by AS task_created_by
            FROM task_events e
            LEFT JOIN tasks t ON t.id = e.task_id
            WHERE e.id > ?
        """
        params: list = [after_id]
        if event_type:
            query += " AND e.event_type = ?"
            params.append(event_type)
        query += " ORDER BY e.id ASC LIMIT ?"
        params.append(limit)
        rows = conn.execute(query, params).fetchall()

    if args.format == "json":
        events = []
        for row in rows:
            note_file_content = None
            note_path = row["note_path"]
            if note_path and os.path.isfile(note_path):
                try:
                    note_file_content = Path(note_path).read_text(
                        encoding="utf-8", errors="replace"
                    )[:4000]
                except OSError:
                    pass
            # Resolve task body: prefer body_text, fall back to body_path file
            task_body = row["task_body"]
            if not task_body:
                body_path = row["task_body_path"]
                if body_path and os.path.isfile(body_path):
                    try:
                        task_body = Path(body_path).read_text(
                            encoding="utf-8", errors="replace"
                        )[:4000]
                    except OSError:
                        pass
            events.append(
                {
                    "event_id": row["id"],
                    "task_id": row["task_id"],
                    "event_type": row["event_type"],
                    "actor": row["actor"],
                    "created_ts": row["created_ts"],
                    "note_text": row["note_text"],
                    "note_path": row["note_path"],
                    "note_file_content": note_file_content,
                    "from_agent": row["from_agent"],
                    "to_agent": row["to_agent"],
                    "task_title": row["task_title"],
                    "task_body": task_body,
                    "assigned_to": row["assigned_to"],
                    "task_created_by": row["task_created_by"],
                }
            )
        print(_json.dumps(events, ensure_ascii=False))
    else:
        for row in rows:
            ts = datetime.fromtimestamp(
                int(row["created_ts"]), tz=timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%S%z")
            print(
                f"#{row['id']}  task={row['task_id']}  {row['event_type']}  "
                f"actor={row['actor']}  {ts}  {row['note_text'] or ''}"
            )
    return 0


def build_parser() -> argparse.ArgumentParser:
    # PR #571 r3 finding 2a: every parser disables argparse's default
    # prefix-abbreviation. The queue gateway authorizer (bridge-queue-gateway.py
    # _extract_positional_task_id) walks argv with a *fixed* per-subcommand
    # value-flag table; a long option that argparse would silently expand
    # (e.g. `--note-f` → `--note-file`) is unknown to that walker, which
    # then misreads the would-be value as the positional task id while
    # this parser executes against a different positional. allow_abbrev=False
    # forces clients to spell flags exactly so the gateway and the inner
    # parser see the same shape.
    parser = argparse.ArgumentParser(prog="bridge-queue.py", allow_abbrev=False)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init", allow_abbrev=False)

    create_parser = subparsers.add_parser("create", allow_abbrev=False)
    create_parser.add_argument("--to", dest="assigned_to", required=True)
    create_parser.add_argument("--title", required=True)
    create_parser.add_argument("--from", dest="actor")
    create_parser.add_argument("--priority", choices=PRIORITY_CHOICES, default="normal")
    create_parser.add_argument("--format", choices=("text", "shell"), default="text")
    create_parser.add_argument("--allow-empty-body", action="store_true")
    body_group = create_parser.add_mutually_exclusive_group()
    body_group.add_argument("--body")
    body_group.add_argument("--body-file")
    create_parser.set_defaults(handler=cmd_create)

    inbox_parser = subparsers.add_parser("inbox", allow_abbrev=False)
    inbox_parser.add_argument("--agent", required=True)
    inbox_parser.add_argument("--status", action="append", choices=STATUS_CHOICES)
    inbox_parser.add_argument("--all", action="store_true")
    inbox_parser.set_defaults(handler=cmd_inbox)

    show_parser = subparsers.add_parser("show", allow_abbrev=False)
    show_parser.add_argument("task_id", type=int)
    show_parser.add_argument("--format", choices=("text", "shell"), default="text")
    show_parser.set_defaults(handler=cmd_show)

    find_open_parser = subparsers.add_parser("find-open", allow_abbrev=False)
    find_open_parser.add_argument("--agent", required=True)
    find_open_parser.add_argument("--title-prefix")
    find_open_parser.add_argument("--format", choices=("id", "text", "shell", "json"), default="id")
    find_open_parser.add_argument(
        "--all",
        action="store_true",
        help="return all matching open tasks as a JSON array (forces JSON output with created_ts/updated_ts)",
    )
    find_open_parser.add_argument(
        "--mode",
        choices=("refresh-by-job", "per-run"),
        default="refresh-by-job",
        help=(
            "PR1.7 cron-followup dedupe selector. refresh-by-job (default) "
            "matches prior open task by title prefix; per-run always "
            "returns nothing so each distinct alert lands as a new task."
        ),
    )
    find_open_parser.set_defaults(handler=cmd_find_open)

    claim_parser = subparsers.add_parser("claim", allow_abbrev=False)
    claim_parser.add_argument("task_id", type=int)
    claim_parser.add_argument("--agent", required=True)
    claim_parser.add_argument("--lease-seconds", default=os.environ.get("BRIDGE_TASK_LEASE_SECONDS", "900"))
    claim_parser.set_defaults(handler=cmd_claim)

    done_parser = subparsers.add_parser("done", allow_abbrev=False)
    done_parser.add_argument("task_id", type=int)
    done_parser.add_argument("--agent", required=True)
    note_group = done_parser.add_mutually_exclusive_group()
    note_group.add_argument("--note")
    note_group.add_argument("--note-file")
    done_parser.set_defaults(handler=cmd_done)

    cancel_parser = subparsers.add_parser("cancel", allow_abbrev=False)
    cancel_parser.add_argument("task_id", type=int)
    cancel_parser.add_argument("--actor")
    cancel_group = cancel_parser.add_mutually_exclusive_group()
    cancel_group.add_argument("--note")
    cancel_group.add_argument("--note-file")
    cancel_parser.set_defaults(handler=cmd_cancel)

    update_parser = subparsers.add_parser("update", allow_abbrev=False)
    update_parser.add_argument("task_id", type=int)
    update_parser.add_argument("--actor")
    update_parser.add_argument("--title")
    update_parser.add_argument("--status", choices=UPDATE_STATUS_CHOICES)
    update_parser.add_argument("--priority", choices=PRIORITY_CHOICES)
    update_parser.add_argument("--note")
    update_body_group = update_parser.add_mutually_exclusive_group()
    update_body_group.add_argument("--body")
    update_body_group.add_argument("--body-file")
    update_parser.set_defaults(handler=cmd_update)

    handoff_parser = subparsers.add_parser("handoff", allow_abbrev=False)
    handoff_parser.add_argument("task_id", type=int)
    handoff_parser.add_argument("--to", dest="assigned_to", required=True)
    handoff_parser.add_argument("--from", dest="actor")
    handoff_group = handoff_parser.add_mutually_exclusive_group()
    handoff_group.add_argument("--note")
    handoff_group.add_argument("--note-file")
    handoff_parser.set_defaults(handler=cmd_handoff)

    validate_companion_parser = subparsers.add_parser(
        "validate-companion-body",
        allow_abbrev=False,
        help="Validate a companion-role review brief body for required sections.",
    )
    validate_companion_parser.add_argument("--title", required=True)
    body_group = validate_companion_parser.add_mutually_exclusive_group()
    body_group.add_argument("--body")
    body_group.add_argument("--body-file")
    validate_companion_parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
    )
    validate_companion_parser.set_defaults(handler=cmd_validate_companion_body)

    summary_parser = subparsers.add_parser("summary", allow_abbrev=False)
    summary_parser.add_argument("--agent", action="append")
    summary_parser.add_argument("--format", choices=("text", "tsv", "json"), default="text")
    summary_parser.set_defaults(handler=cmd_summary)

    cron_ready_parser = subparsers.add_parser("cron-ready", allow_abbrev=False)
    cron_ready_parser.add_argument("--limit", type=int, default=50)
    cron_ready_parser.add_argument("--format", choices=("text", "tsv"), default="tsv")
    cron_ready_parser.add_argument("--status-snapshot")
    cron_ready_parser.add_argument("--memory-daily-defer-seconds", type=int, default=10800)
    cron_ready_parser.set_defaults(handler=cmd_cron_ready)

    daemon_parser = subparsers.add_parser("daemon-step", allow_abbrev=False)
    daemon_parser.add_argument("--snapshot", required=True)
    daemon_parser.add_argument("--lease-seconds", default=os.environ.get("BRIDGE_TASK_LEASE_SECONDS", "900"))
    daemon_parser.add_argument(
        "--heartbeat-window",
        default=os.environ.get("BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS", "300"),
    )
    daemon_parser.add_argument(
        "--idle-threshold",
        default=os.environ.get("BRIDGE_TASK_IDLE_NUDGE_SECONDS", "120"),
    )
    daemon_parser.add_argument(
        "--nudge-cooldown",
        default=os.environ.get("BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS", "900"),
    )
    daemon_parser.add_argument(
        "--zombie-threshold",
        type=int,
        default=int(os.environ.get("BRIDGE_ZOMBIE_NUDGE_THRESHOLD", "10")),
    )
    daemon_parser.add_argument(
        "--max-claim-age",
        default=os.environ.get("BRIDGE_TASK_MAX_CLAIM_AGE_SECONDS", "900"),
    )
    daemon_parser.add_argument(
        "--blocked-reminder-seconds",
        default=os.environ.get("BRIDGE_TASK_BLOCKED_REMINDER_SECONDS", "86400"),
    )
    daemon_parser.add_argument(
        "--blocked-escalate-seconds",
        default=os.environ.get("BRIDGE_TASK_BLOCKED_ESCALATE_SECONDS", str(7 * 86400)),
    )
    daemon_parser.add_argument(
        "--admin-agent",
        default=os.environ.get("BRIDGE_ADMIN_AGENT_ID", "patch"),
    )
    daemon_parser.add_argument("--ready-agents-file")
    # Issue #946 L4 / PR #952 r2: when the idle_ready writer fails the bash
    # caller still needs maintenance (lease extend/expire, cron de-dupe,
    # stale-claim requeue, blocked-task aging) to run; only the nudge
    # candidate enumeration depends on the ready-agents file. --skip-nudges
    # keeps the maintenance path intact and short-circuits before the
    # per-agent nudge selection loop, so the daemon never freezes queue
    # maintenance on a transient writer failure.
    daemon_parser.add_argument("--skip-nudges", action="store_true")
    daemon_parser.add_argument("--format", choices=("text", "tsv"), default="tsv")
    daemon_parser.set_defaults(handler=cmd_daemon_step)

    nudge_parser = subparsers.add_parser("note-nudge", allow_abbrev=False)
    nudge_parser.add_argument("--agent", required=True)
    nudge_parser.add_argument("--key")
    nudge_parser.add_argument(
        "--zombie-threshold",
        type=int,
        default=int(os.environ.get("BRIDGE_ZOMBIE_NUDGE_THRESHOLD", "10")),
    )
    nudge_parser.set_defaults(handler=cmd_note_nudge)

    events_parser = subparsers.add_parser("events", allow_abbrev=False)
    events_parser.add_argument("--type", dest="event_type")
    events_parser.add_argument("--after-id", type=int, default=0)
    events_parser.add_argument("--limit", type=int, default=100)
    events_parser.add_argument("--format", choices=("text", "json"), default="text")
    events_parser.set_defaults(handler=cmd_events)

    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if should_proxy_via_queue_gateway(argv):
        return proxy_via_queue_gateway(argv)
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "init":
        with closing(connect()):
            pass
        print(f"initialized task db at {get_db_path()}")
        return 0
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
