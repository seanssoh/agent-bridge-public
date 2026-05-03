#!/usr/bin/env python3
"""Shared Agent Bridge hook helpers for Claude Code and Codex."""

from __future__ import annotations

import hashlib
import json
import os
import pwd
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PRIORITY_ORDER = {"urgent": 0, "high": 1, "normal": 2, "low": 3}


def bridge_task_db() -> Path:
    explicit = os.environ.get("BRIDGE_TASK_DB", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state" / "tasks.db"
    return Path.home() / ".agent-bridge" / "state" / "tasks.db"


def bridge_state_dir() -> Path:
    explicit = os.environ.get("BRIDGE_STATE_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state"
    return Path.home() / ".agent-bridge" / "state"


def bridge_active_agent_dir() -> Path:
    # Matches bridge-lib.sh:32 —
    #   BRIDGE_ACTIVE_AGENT_DIR="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_STATE_DIR/agents}"
    # Any bash helper that reaches runtime_state_dir goes through this root,
    # so Python must honour the same override to land files where the bash
    # reader will look.
    explicit = os.environ.get("BRIDGE_ACTIVE_AGENT_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return bridge_state_dir() / "agents"


def bridge_home_dir() -> Path:
    explicit = os.environ.get("BRIDGE_HOME", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".agent-bridge"


def bridge_script_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def audit_log_path() -> Path:
    explicit = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    agent = current_agent()
    if agent:
        return bridge_home_dir() / "logs" / "agents" / agent / "audit.jsonl"
    return bridge_home_dir() / "logs" / "audit.jsonl"


def agent_home_root() -> Path:
    explicit = os.environ.get("BRIDGE_AGENT_HOME_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return bridge_home_dir() / "agents"


def agent_default_home(agent: str) -> Path:
    return agent_home_root() / agent


def agent_workdir(agent: str) -> Path:
    explicit = os.environ.get("BRIDGE_AGENT_WORKDIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return agent_default_home(agent)


def current_agent() -> str:
    return os.environ.get("BRIDGE_AGENT_ID", "").strip()


def current_isolated_agent() -> str | None:
    agent = current_agent()
    if not agent:
        return None
    if os.environ.get("BRIDGE_AGENT_ISOLATION_MODE", "").strip() != "linux-user":
        return None
    return agent


def current_agent_workdir() -> Path:
    agent = current_agent()
    if not agent:
        return Path.cwd()
    return agent_workdir(agent)


def queue_cli_cwd() -> Path:
    candidates: list[Path] = []
    explicit_workdir = os.environ.get("BRIDGE_AGENT_WORKDIR", "").strip()
    if explicit_workdir:
        candidates.append(Path(explicit_workdir).expanduser())

    agent = current_agent()
    if agent:
        candidates.append(agent_default_home(agent))

    try:
        candidates.append(Path.cwd())
    except OSError:
        pass
    candidates.append(bridge_script_dir())

    for path in candidates:
        try:
            if path.is_dir():
                return path
        except OSError:
            continue
    return Path("/")


def path_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def truncate_text(text: str, limit: int = 400) -> str:
    cleaned = " ".join(str(text).split())
    if len(cleaned) <= limit:
        return cleaned
    return cleaned[: limit - 3].rstrip() + "..."


def _acting_os_user() -> str:
    try:
        return pwd.getpwuid(os.geteuid()).pw_name
    except (KeyError, OSError):
        pass
    try:
        return os.getlogin()
    except OSError:
        return ""


def _current_isolation_mode() -> str:
    mode = os.environ.get("BRIDGE_AGENT_ISOLATION_MODE", "").strip()
    return mode or "shared"


def write_audit(action: str, target: str, detail: dict[str, Any]) -> None:
    path = audit_log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "actor": "hook",
        "action": action,
        "target": target,
        "detail": detail,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "acting_os_uid": os.geteuid(),
        "acting_os_user": _acting_os_user(),
        "isolation_mode": _current_isolation_mode(),
    }
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=True) + "\n")


def queue_gateway_root() -> Path:
    return bridge_state_dir() / "queue-gateway"


def queue_cli(args: list[str]) -> subprocess.CompletedProcess[str]:
    isolated_agent = current_isolated_agent()
    if isolated_agent:
        cmd = [
            sys.executable,
            str(bridge_script_dir() / "bridge-queue-gateway.py"),
            "client",
            "--root",
            str(queue_gateway_root()),
            "--agent",
            isolated_agent,
            "--timeout",
            os.environ.get("BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS", "45"),
            "--poll",
            os.environ.get("BRIDGE_QUEUE_GATEWAY_POLL_SECONDS", "0.2"),
            *args,
        ]
    else:
        cmd = [sys.executable, str(bridge_script_dir() / "bridge-queue.py"), *args]
    return subprocess.run(
        cmd,
        cwd=str(queue_cli_cwd()),
        capture_output=True,
        text=True,
        check=False,
    )


def first_existing_path(candidates: list[Path]) -> Path | None:
    for path in candidates:
        if path.is_file():
            return path
    return None


def short_file_excerpt(path: Path, limit: int = 600) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    excerpt = "\n".join(lines[:6]).strip()
    if len(excerpt) > limit:
        excerpt = excerpt[: limit - 3].rstrip() + "..."
    return excerpt


def onboarding_state_from_file(path: Path | None) -> str:
    if path is None:
        return "missing"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return "missing"
    match = re.search(r"Onboarding\s+State:\s*([A-Za-z0-9._-]+)", text)
    if not match:
        return "missing"
    return match.group(1)


def _stamp_next_session_delivered(agent: str, next_session: Path) -> str | None:
    """Persist the SHA-1 digest of NEXT-SESSION.md into the per-agent marker.

    The bash-side `bridge_agent_maybe_expire_next_session` gates on
    `bridge_agent_next_session_is_delivered` (marker file equals the current
    file digest). Without this writer the auto-archive path is dead code — a
    regression introduced when `bridge_run_schedule_next_session_prompt` was
    removed in b38e584 in favour of the SessionStart hook. We restore the
    marker here so `bridge-run.sh`'s reconcile step can age out a stale
    handoff file the next time a Claude agent restarts.

    Returns the digest string on success so callers (e.g. the queue-route
    handoff path in #409 Track A) can use it as an idempotency key. Returns
    None when the file cannot be read or the marker cannot be written.

    Best-effort: any IO failure is swallowed so the hook never blocks agent
    startup over marker bookkeeping.
    """
    try:
        content = next_session.read_bytes()
    except OSError:
        return None
    # bridge_agent_next_session_digest (bash) pipes the file through
    # `bridge_sha1 "$(cat $file)"`. Command substitution strips trailing
    # newlines before the argument reaches Python's hashlib, so hashing
    # the raw bytes here would produce a different digest whenever
    # NEXT-SESSION.md ends in `\n` — which is virtually always. Strip
    # trailing newlines to match.
    content = content.rstrip(b"\n")
    digest = hashlib.sha1(content).hexdigest()
    # Mirror lib/bridge-state.sh::bridge_agent_next_session_marker_file,
    # which resolves to bridge_agent_runtime_state_dir/next-session.sha and
    # runtime_state_dir is BRIDGE_ACTIVE_AGENT_DIR/<agent>. Honour the env
    # override so a deployment that reroots its active-agent dir (e.g. for
    # linux-user isolation) gets the marker where bash will actually look.
    marker_file = bridge_active_agent_dir() / agent / "next-session.sha"
    try:
        marker_file.parent.mkdir(parents=True, exist_ok=True)
        marker_file.write_text(digest, encoding="utf-8")
    except OSError:
        return None
    return digest


def _enqueue_handoff_pending(agent: str, next_session: Path, digest: str) -> None:
    """Self-enqueue an urgent task so the queue contract enforces handoff priority.

    The hook's stdout-as-context surface (current behaviour) puts the handoff
    instruction on equal footing with whatever the operator types as the first
    user message. Empirically the operator's intent wins and the handoff is
    silently skipped. By creating a queued task on the agent's own inbox at
    the same time, the existing "claim highest-priority queued task first"
    contract turns the handoff into a hard precondition for any other work.

    Idempotency: title carries the digest so re-running for the same handoff
    file produces a duplicate-title task that bridge-task.sh's find-open path
    refuses to re-create. A new digest (handoff content changed) yields a new
    task; an unchanged digest is a no-op.

    Best-effort: any IO/subprocess failure is swallowed so the hook never
    blocks agent startup over enqueue bookkeeping. The stdout-as-context path
    still runs as a fallback regardless.
    """
    title = f"[bridge:handoff-pending] {next_session.name} ({digest[:8]})"
    body = (
        f"NEXT-SESSION.md handoff detected at {next_session}.\n"
        f"\n"
        f"Read this file in full and execute its checklist before any other work. "
        f"Reply briefly to the operator (\"handoff 처리부터 하겠습니다\") if a user "
        f"message is also pending; resume normal flow only after the file is "
        f"deleted by the agent.\n"
        f"\n"
        f"Auto-enqueued by bridge_hook_common._enqueue_handoff_pending.\n"
    )
    # find-open guard: skip if a same-digest handoff task is already open.
    # bridge-queue.py find-open --title-prefix uses SQL LIKE; passing the FULL
    # digest-bearing title as the prefix is the exact-match form (no other
    # title starts with this exact string since digest8 + ")" is terminal).
    # Codex r1 flagged the LIMIT 1 trap: a generic prefix like
    # "[bridge:handoff-pending]" matches an older different-digest row first
    # and suppresses the new enqueue, missing the current handoff.
    try:
        existing = queue_cli([
            "find-open",
            "--agent", agent,
            "--title-prefix", title,
            "--format", "json",
        ])
        if existing.returncode == 0 and existing.stdout.strip():
            try:
                row = json.loads(existing.stdout)
            except (json.JSONDecodeError, ValueError):
                row = None
            if isinstance(row, dict) and row.get("title", "") == title:
                return  # already enqueued for this exact digest
    except Exception:
        pass
    try:
        queue_cli([
            "create",
            "--to", agent,
            "--from", agent,
            "--priority", "urgent",
            "--title", title,
            "--body", body,
        ])
    except Exception:
        # Hook must not block agent startup on enqueue failure.
        return


DEFAULT_COMPACT_RECOVERY_FILES: tuple[str, ...] = (
    "SOUL.md",
    "SESSION-TYPE.md",
    "COMMON-INSTRUCTIONS.md",
    "TOOLS.md",
    "MEMORY.md",
)
_COMPACT_RECOVERY_DEFAULT_CAP = 5120
_COMPACT_RECOVERY_MIN_CAP = 256


def compact_recovery_enabled() -> bool:
    raw = os.environ.get("BRIDGE_COMPACT_RECOVERY", "").strip().lower()
    if not raw:
        return True
    return raw not in {"0", "false", "no", "off"}


def compact_recovery_files() -> tuple[str, ...]:
    raw = os.environ.get("BRIDGE_COMPACT_RECOVERY_FILES", "").strip()
    if not raw:
        return DEFAULT_COMPACT_RECOVERY_FILES
    parts = [piece.strip() for piece in raw.split(",") if piece.strip()]
    return tuple(parts) if parts else DEFAULT_COMPACT_RECOVERY_FILES


def compact_recovery_per_file_cap() -> int:
    raw = os.environ.get("BRIDGE_COMPACT_RECOVERY_MAX_BYTES", "").strip()
    if not raw:
        return _COMPACT_RECOVERY_DEFAULT_CAP
    try:
        value = int(raw)
    except ValueError:
        return _COMPACT_RECOVERY_DEFAULT_CAP
    return max(value, _COMPACT_RECOVERY_MIN_CAP)


def compact_snapshot_path(agent: str) -> Path:
    return bridge_state_dir() / "agents" / agent / "compact-snapshot.json"


def _read_canonical_file(home: Path, name: str, cap: int) -> str:
    candidate = home / name
    try:
        # read_text follows symlinks, so SHARED-symlinked files resolve
        # transparently (TOOLS.md → shared/TOOLS.md, etc.).
        if not candidate.exists():
            return ""
        text = candidate.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    text = text.strip("\n")
    if len(text) > cap:
        text = text[:cap].rstrip() + "\n[…truncated by compact-recovery cap…]"
    return text


def gather_canonical_files(agent: str) -> dict[str, str]:
    """Return ordered mapping of canonical filename → text content.

    Reads from the agent workdir first, then falls back to the agent
    default home for installations where the two diverge. Missing or
    unreadable files yield empty strings — the caller decides whether to
    skip or substitute a snapshot.
    """
    files = compact_recovery_files()
    cap = compact_recovery_per_file_cap()
    workdir = agent_workdir(agent)
    default_home = agent_default_home(agent)
    out: dict[str, str] = {}
    for name in files:
        text = _read_canonical_file(workdir, name, cap)
        if not text and workdir != default_home:
            text = _read_canonical_file(default_home, name, cap)
        out[name] = text
    return out


def write_compact_snapshot(agent: str, payload: dict[str, str]) -> Path | None:
    """Atomically persist canonical-file contents next to the agent state.

    The session-start hook reads this file as a fallback when the live
    canonical files have been moved/cleared between pre-compact and the
    post-compact session resume. Best-effort — IO failures are swallowed
    because pre-compact must never block compaction.
    """
    path = compact_snapshot_path(agent)
    envelope = {
        "agent": agent,
        "captured_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "files": payload,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(tmp, 0o600)
        tmp.replace(path)
        os.chmod(path, 0o600)
        return path
    except OSError:
        return None


def load_compact_snapshot(agent: str) -> dict[str, str]:
    path = compact_snapshot_path(agent)
    if not path.exists():
        return {}
    try:
        envelope = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(envelope, dict):
        return {}
    files = envelope.get("files")
    if not isinstance(files, dict):
        return {}
    return {str(k): str(v) for k, v in files.items() if isinstance(v, str)}


def compact_recovery_context(agent: str) -> str:
    """Return the `## Restored Context` block for compaction recovery.

    Reads canonical files live (resolves symlinks). When a file is missing
    or empty, falls back to the most recent pre-compact snapshot. Returns
    an empty string when the feature is disabled or no content survived.
    """
    if not compact_recovery_enabled():
        return ""
    live = gather_canonical_files(agent)
    snapshot = load_compact_snapshot(agent) if any(not v for v in live.values()) else {}
    sections: list[str] = []
    for name, text in live.items():
        if not text and snapshot.get(name):
            text = snapshot[name].rstrip() + "\n[restored from pre-compact snapshot]"
        if not text:
            continue
        sections.append(f"### {name}\n{text}")
    if not sections:
        return ""
    body = "\n\n".join(sections)
    return (
        "## Restored Context (post-compact)\n"
        "These canonical agent files were re-injected because the previous\n"
        "conversation was compacted. Treat them as the load-bearing identity\n"
        "anchors for this turn before reading queue/handoff state below.\n\n"
        + body
    )


def bootstrap_artifact_context(agent: str) -> str:
    workdir = agent_workdir(agent)
    default_home = agent_default_home(agent)
    lines: list[str] = []

    next_session = first_existing_path(
        [
            workdir / "NEXT-SESSION.md",
            default_home / "NEXT-SESSION.md",
        ]
    )
    if next_session is not None:
        lines.append(
            f"Handoff present: {next_session.name} exists at {next_session}. "
            "Read this file first and execute its checklist before anything else."
        )
        excerpt = short_file_excerpt(next_session)
        if excerpt:
            lines.append("Handoff excerpt:")
            lines.append(excerpt)
        digest = _stamp_next_session_delivered(agent, next_session)
        if digest is not None:
            _enqueue_handoff_pending(agent, next_session, digest)

    session_type = first_existing_path(
        [
            workdir / "SESSION-TYPE.md",
            default_home / "SESSION-TYPE.md",
        ]
    )
    if onboarding_state_from_file(session_type) == "pending":
        lines.append(
            f"Onboarding pending: {session_type} says Onboarding State: pending. "
            "Stay in onboarding flow until it is complete before doing unrelated work."
        )

    # Issue #132a: surface any pending-attention spool entries queued while the
    # agent was busy so the operator knows replays will follow once the input
    # box becomes idle. The spool path mirrors lib/bridge-state.sh.
    spool_path = (
        bridge_state_dir() / "agents" / agent / "pending-attention.env"
    )
    try:
        pending_count = sum(
            1
            for line in spool_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    except (OSError, UnicodeDecodeError):
        pending_count = 0
    if pending_count > 0:
        lines.append(
            f"Agent Bridge has {pending_count} queued external event(s); "
            "they will replay into this session as the input box becomes idle."
        )

    if not lines:
        return ""
    return "\n".join(lines)


def next_session_required_prompt_context(agent: str) -> str:
    workdir = agent_workdir(agent)
    default_home = agent_default_home(agent)
    next_session = first_existing_path(
        [
            workdir / "NEXT-SESSION.md",
            default_home / "NEXT-SESSION.md",
        ]
    )
    if next_session is None:
        return ""

    lines = [
        "<agent_bridge_next_session_required>",
        f"NEXT-SESSION.md is still present at {next_session}.",
        "Before answering the current user prompt or doing any other work, read this file in full and execute its checklist.",
        "If the current user prompt conflicts with the handoff, acknowledge that the handoff is being processed first.",
    ]
    excerpt = short_file_excerpt(next_session)
    if excerpt:
        lines.append("Handoff excerpt:")
        lines.append(excerpt)
    digest = _stamp_next_session_delivered(agent, next_session)
    if digest is not None:
        _enqueue_handoff_pending(agent, next_session, digest)
    lines.append("</agent_bridge_next_session_required>")
    return "\n".join(lines)


def timestamp_state_path(agent: str) -> Path:
    return bridge_state_dir() / "agents" / agent / "timestamp.json"


def load_timestamp_state(agent: str) -> dict[str, int]:
    path = timestamp_state_path(agent)
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    state: dict[str, int] = {}
    for key in ("session_started_at", "last_prompt_at"):
        value = payload.get(key)
        if isinstance(value, int):
            state[key] = value
    return state


def save_timestamp_state(agent: str, payload: dict[str, int]) -> None:
    path = timestamp_state_path(agent)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def agent_timestamp_enabled(agent: str) -> bool:
    raw = os.environ.get("BRIDGE_AGENT_INJECT_TIMESTAMP", "").strip().lower()
    if not raw:
        return True
    return raw not in {"0", "false", "no", "off"}


def format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "(first message)"
    if seconds < 0:
        seconds = 0
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def remember_session_start(agent: str, now_epoch: int | None = None) -> None:
    if not agent_timestamp_enabled(agent):
        return
    now_epoch = now_epoch or int(datetime.now(timezone.utc).timestamp())
    state = load_timestamp_state(agent)
    changed = False
    if "session_started_at" not in state:
        state["session_started_at"] = now_epoch
        changed = True
    if changed:
        save_timestamp_state(agent, state)


def prompt_timestamp_context(agent: str, now: datetime | None = None) -> str:
    now_dt = now or datetime.now().astimezone()
    now_epoch = int(now_dt.timestamp())
    state = load_timestamp_state(agent)
    session_started_at = state.get("session_started_at", now_epoch)
    last_prompt_at = state.get("last_prompt_at")
    context = (
        "<timestamp>\n"
        f"now: {now_dt.strftime('%Y-%m-%d %H:%M:%S %Z (%a)')}\n"
        f"since_last: {format_duration(None if last_prompt_at is None else now_epoch - last_prompt_at)}\n"
        f"session_age: {format_duration(now_epoch - session_started_at)}\n"
        "</timestamp>\n"
        "<question_escalation>\n"
        "If you are about to ask the user the same unanswered question a second time, escalate before asking again.\n"
        f"Run exactly: ~/.agent-bridge/agent-bridge escalate question --agent {agent} --question \"<question>\" --context \"<why you need the answer>\"\n"
        "Use --wait-seconds when the elapsed wait materially matters.\n"
        "</question_escalation>"
    )
    state["session_started_at"] = session_started_at
    state["last_prompt_at"] = now_epoch
    save_timestamp_state(agent, state)
    return context


def admin_blocked_self_cleanup_context(agent: str) -> str:
    """Return a single-line self-cleanup pressure note when admin starts a session
    with blocked tasks in its own queue. Empty string for non-admin agents or when
    the admin has no blocked tasks. Filename contract for the role spec is in
    docs/agent-runtime/handoff-protocol.md.
    """
    admin_id = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()
    if not admin_id or agent != admin_id:
        return ""
    summary_proc = queue_cli(["summary", "--agent", agent, "--format", "json"])
    if summary_proc.returncode != 0 or not summary_proc.stdout.strip():
        return ""
    try:
        rows = json.loads(summary_proc.stdout)
    except json.JSONDecodeError:
        return ""
    if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
        return ""
    blocked = int(rows[0].get("blocked_count", 0) or 0)
    if blocked <= 0:
        return ""
    return (
        f"[Self-cleanup] {blocked} blocked task(s) in your queue. "
        "Self-cleanup contract requires evaluating each per the role spec "
        "(CLAUDE.md `## Admin Self-Cleanup of Own Queue`) before any other work. "
        "If you cannot reach a close decision today, refresh with a verifiable trigger."
    )


def session_start_context(agent: str) -> str:
    queue_context = (
        f"Agent Bridge queue protocol applies to {agent}. "
        f"Queue DB is source of truth. "
        f"When a task boundary is reached or Agent Bridge asks for attention, "
        f"run exactly: ~/.agent-bridge/agb inbox {agent}. "
        f"If a task is queued, claim the highest-priority one first. "
        f"If a task is already claimed by you, continue that task."
    )
    self_cleanup = admin_blocked_self_cleanup_context(agent)
    if self_cleanup:
        queue_context = f"{self_cleanup}\n\n{queue_context}"
    bootstrap_context = bootstrap_artifact_context(agent)
    if bootstrap_context:
        return f"{bootstrap_context}\n\n{queue_context}"
    return queue_context


def queue_summary(agent: str) -> tuple[int, dict[str, Any] | None]:
    summary_proc = queue_cli(["summary", "--agent", agent, "--format", "json"])
    if summary_proc.returncode != 0 or not summary_proc.stdout.strip():
        return 0, None
    try:
        rows = json.loads(summary_proc.stdout)
    except json.JSONDecodeError:
        return 0, None
    if not isinstance(rows, list) or not rows:
        return 0, None
    row = rows[0] if isinstance(rows[0], dict) else None
    if not row:
        return 0, None
    pending = int(row.get("queued_count", 0)) + int(row.get("blocked_count", 0)) + int(row.get("claimed_count", 0))
    if pending <= 0:
        return 0, None

    top_proc = queue_cli(["find-open", "--agent", agent, "--format", "json"])
    if top_proc.returncode != 0 or not top_proc.stdout.strip():
        return pending, None
    try:
        top_row = json.loads(top_proc.stdout)
    except json.JSONDecodeError:
        return pending, None
    if not isinstance(top_row, dict):
        return pending, None
    return pending, top_row


def queue_attention_message(agent: str, pending: int, row: dict[str, Any] | None) -> str:
    lines = [f"[Agent Bridge] {pending} pending task(s) for {agent}."]
    if row is not None:
        lines.append(
            f"Highest priority: Task #{int(row.get('id', 0))} [{str(row.get('priority') or 'normal')}] {str(row.get('title') or '')}"
        )
    lines.append("ACTION REQUIRED: Use your Bash tool now. Do not acknowledge or reply conversationally first.")
    lines.append(f"Run exactly: ~/.agent-bridge/agb inbox {agent}")
    lines.append("If tasks are listed, show and claim the first one immediately.")
    lines.append("Queue DB is source of truth.")
    return "\n".join(lines)


def codex_stop_reason(agent: str, row: dict[str, Any]) -> str:
    task_id = int(row.get("id", 0))
    title = str(row.get("title") or "")
    priority = str(row["priority"] or "normal")
    status = str(row["status"] or "")
    if status == "claimed":
        return (
            f"Agent Bridge still has open claimed work for you: task #{task_id} "
            f"[{priority}] {title}. "
            f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
            f"and continue the claimed task instead of ending the session."
        )
    return (
        f"Agent Bridge queued work is waiting: task #{task_id} "
        f"[{priority}] {title}. "
        f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
        f"and claim the highest-priority queued task before ending the session."
    )
