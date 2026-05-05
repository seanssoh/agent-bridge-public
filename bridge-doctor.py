#!/usr/bin/env python3
"""bridge-doctor.py — read-only stuck-state detectors for admin self-healing (#511).

Surfaces cross-cutting "agent stuck" signals so an admin agent (e.g. `patch`)
can call existing primitives (agent restart, task update) to self-heal. Does
NOT execute any action; `suggested_action` is a string hint only.

Detectors:

- stale-stopped-with-queue : state=stopped AND loop_enabled AND (queued>0 OR blocked>0)
- stale-blocked-task       : task.status=blocked AND task.claimed_by.activity_state=idle
                             AND lease_age > BRIDGE_DOCTOR_BLOCKED_THRESHOLD_SECONDS (default 24h)
- cold-restart-suspect     : agent has fresh session_id but prior jsonl still on disk (#167)
- abnormal-session-pane    : tmux pane scrollback matches login/trust/blocker UI patterns
                             (placeholder — emits detector-error until pattern reuse from
                             bridge-stall.py is factored cleanly; see PR notes)
- daemon-log-split         : BRIDGE_DAEMON_LOG frozen while launchagent.log is active (#590)
- orphan-agent-dir         : directories under $BRIDGE_AGENT_HOME_ROOT that are not in
                             `agent registry --json` (#598 Track 2). Report-only;
                             emits a manual quarantine recipe in suggested_action.

Read-only contract: the CLI never mutates queue/state/tmux. `suggested_action`
is a string the admin agent LLM parses and decides whether to execute.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DETECTOR_KINDS = (
    "stale-stopped-with-queue",
    "stale-blocked-task",
    "cold-restart-suspect",
    "abnormal-session-pane",
    "daemon-log-split",
    "orphan-agent-dir",
)


# Issue #598 Track 2: directories under $BRIDGE_AGENT_HOME_ROOT whose
# basename starts with one of these prefixes (or ends with `-repro-<digits>`)
# are flagged `is_test_artifact: true` so the operator can triage in one
# pass. Mirrors lib/bridge-core.sh:BRIDGE_TEST_ARTIFACT_PREFIXES (Track 4)
# — keep the two lists in lockstep.
ORPHAN_TEST_ARTIFACT_PREFIXES = (
    "smoke-",
    "test-",
    "bootstrap-",
    "created-agent-",
    "pref-",
)
ORPHAN_TEST_ARTIFACT_REPRO_REGEX = re.compile(r"-repro-\d+$")

# Directory basenames under $BRIDGE_AGENT_HOME_ROOT that are bridge-managed
# infrastructure rather than per-agent homes; the detector skips them.
ORPHAN_SKIP_NAMES = frozenset({"_template", "shared"})


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def now_ts() -> int:
    return int(datetime.now(timezone.utc).timestamp())


def resolve_state_dir(arg_value: str | None) -> Path:
    if arg_value:
        return Path(arg_value).expanduser()
    explicit = os.environ.get("BRIDGE_STATE_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("BRIDGE_HOME", "").strip()
    base = Path(home).expanduser() if home else (Path.home() / ".agent-bridge")
    return base / "state"


def resolve_agent_home_root(arg_value: str | None) -> Path:
    """Resolve `BRIDGE_AGENT_HOME_ROOT` for the orphan-agent-dir detector.

    Mirrors `lib/bridge-agents.sh`: arg > $BRIDGE_AGENT_HOME_ROOT >
    $BRIDGE_HOME/agents > ~/.agent-bridge/agents. Does not require the
    directory to exist; the detector itself handles the missing-dir case
    (graceful skip, no findings).
    """
    if arg_value:
        return Path(arg_value).expanduser()
    explicit = os.environ.get("BRIDGE_AGENT_HOME_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("BRIDGE_HOME", "").strip()
    base = Path(home).expanduser() if home else (Path.home() / ".agent-bridge")
    return base / "agents"


def resolve_task_db(arg_value: str | None, state_dir: Path) -> Path:
    if arg_value:
        return Path(arg_value).expanduser()
    explicit = os.environ.get("BRIDGE_TASK_DB", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return state_dir / "tasks.db"


def parse_detectors(value: str) -> list[str]:
    if not value:
        return list(DETECTOR_KINDS)
    requested = [item.strip() for item in value.split(",") if item.strip()]
    invalid = [k for k in requested if k not in DETECTOR_KINDS]
    if invalid:
        raise SystemExit(f"unknown detector kind(s): {', '.join(invalid)}")
    return requested


def load_agent_list(args: argparse.Namespace) -> list[dict[str, Any]]:
    """Load the roster snapshot via `agent-bridge agent list --json`.

    Tests inject `--agent-list-json <file>` to skip the subprocess. Live
    invocations reuse the existing CLI so the doctor never duplicates the
    bash-side roster loader.
    """
    if args.agent_list_json:
        path = Path(args.agent_list_json).expanduser()
        if not path.is_file():
            raise SystemExit(f"--agent-list-json file not found: {path}")
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, list):
            raise SystemExit("--agent-list-json must contain a JSON array")
        return data

    binary = args.agent_bridge or os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", "").strip()
    if not binary:
        # Default: sibling to this script.
        sibling = Path(__file__).resolve().parent / "agent-bridge"
        if sibling.is_file():
            binary = str(sibling)
        else:
            located = shutil.which("agent-bridge")
            if not located:
                raise SystemExit(
                    "agent-bridge binary not found; pass --agent-bridge or "
                    "--agent-list-json"
                )
            binary = located

    try:
        proc = subprocess.run(
            [binary, "agent", "list", "--json"],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        raise SystemExit(
            f"agent-bridge agent list --json failed (rc={exc.returncode}): "
            f"{(exc.stderr or '').strip()}"
        ) from exc
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"agent-bridge agent list --json: invalid JSON ({exc})") from exc
    if not isinstance(data, list):
        raise SystemExit("agent-bridge agent list --json: expected JSON array")
    return data


def load_agent_registry(args: argparse.Namespace) -> list[dict[str, Any]]:
    """Load the agent registry snapshot via `agent-bridge agent registry --json`.

    Issue #598 Track 1 (PR #603) added the registry endpoint that exposes
    static + dynamic + system ids together with provenance. The orphan
    detector subtracts this set from the `BRIDGE_AGENT_HOME_ROOT` listing to
    decide what is unowned.

    Tests inject `--agent-registry-json <file>` to skip the subprocess.
    """
    if args.agent_registry_json:
        path = Path(args.agent_registry_json).expanduser()
        if not path.is_file():
            raise SystemExit(f"--agent-registry-json file not found: {path}")
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, list):
            raise SystemExit("--agent-registry-json must contain a JSON array")
        return data

    binary = args.agent_bridge or os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", "").strip()
    if not binary:
        sibling = Path(__file__).resolve().parent / "agent-bridge"
        if sibling.is_file():
            binary = str(sibling)
        else:
            located = shutil.which("agent-bridge")
            if not located:
                raise SystemExit(
                    "agent-bridge binary not found; pass --agent-bridge or "
                    "--agent-registry-json"
                )
            binary = located

    try:
        proc = subprocess.run(
            [binary, "agent", "registry", "--json"],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        raise SystemExit(
            f"agent-bridge agent registry --json failed (rc={exc.returncode}): "
            f"{(exc.stderr or '').strip()}"
        ) from exc
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"agent-bridge agent registry --json: invalid JSON ({exc})"
        ) from exc
    if not isinstance(data, list):
        raise SystemExit("agent-bridge agent registry --json: expected JSON array")
    return data


def db_connect_readonly(path: Path) -> sqlite3.Connection | None:
    if not path.is_file():
        return None
    # Open in read-only URI mode so a buggy doctor can never mutate state.
    uri = f"file:{path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def fetch_agent_state(conn: sqlite3.Connection | None) -> dict[str, dict[str, Any]]:
    if conn is None:
        return {}
    rows: dict[str, dict[str, Any]] = {}
    try:
        for row in conn.execute(
            "SELECT agent, session_activity_ts, last_seen_ts, last_heartbeat_ts, "
            "session, engine, workdir FROM agent_state"
        ):
            rows[str(row["agent"])] = {
                "session_activity_ts": row["session_activity_ts"],
                "last_seen_ts": row["last_seen_ts"],
                "last_heartbeat_ts": row["last_heartbeat_ts"],
                "session": row["session"] or "",
                "engine": row["engine"] or "",
                "workdir": row["workdir"] or "",
            }
    except sqlite3.OperationalError:
        return {}
    return rows


def fetch_blocked_tasks(conn: sqlite3.Connection | None) -> list[dict[str, Any]]:
    if conn is None:
        return []
    out: list[dict[str, Any]] = []
    try:
        for row in conn.execute(
            "SELECT id, claimed_by, assigned_to, status, updated_ts, claimed_ts, title "
            "FROM tasks WHERE status='blocked'"
        ):
            out.append(
                {
                    "id": int(row["id"]),
                    "claimed_by": str(row["claimed_by"] or ""),
                    "assigned_to": str(row["assigned_to"] or ""),
                    "updated_ts": int(row["updated_ts"] or 0),
                    "claimed_ts": int(row["claimed_ts"] or 0),
                    "title": str(row["title"] or ""),
                }
            )
    except sqlite3.OperationalError:
        return []
    return out


# --- detectors -------------------------------------------------------------


def detect_stale_stopped_with_queue(
    agents: list[dict[str, Any]],
    agent_state: dict[str, dict[str, Any]],
    ts: str,
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    now = now_ts()
    for agent in agents:
        name = str(agent.get("agent") or "")
        if not name:
            continue
        active = bool(agent.get("active"))
        activity_state = str(agent.get("activity_state") or "")
        loop_value = agent.get("loop")
        try:
            loop_enabled = int(loop_value) == 1
        except (TypeError, ValueError):
            loop_enabled = str(loop_value).strip() == "1"
        # `state=stopped` per the issue spec means the dashboard's stopped
        # state, which corresponds to active=False (no live tmux session).
        # `activity_state` is "stopped" in the same case for the snapshot
        # writer, but `agent list --json` only emits one of idle/working
        # for active agents — the dashboard derives "stopped" from active=0
        # (lib/bridge-state.sh:2872). Treat either signal as authoritative.
        is_stopped = (not active) or activity_state == "stopped"
        if not is_stopped or not loop_enabled:
            continue
        queue = agent.get("queue") or {}
        queued = int(queue.get("queued") or 0)
        blocked = int(queue.get("blocked") or 0)
        if queued <= 0 and blocked <= 0:
            continue
        state_row = agent_state.get(name, {})
        activity_ts = state_row.get("session_activity_ts") or state_row.get("last_seen_ts") or 0
        wake_stale = max(0, now - int(activity_ts)) if activity_ts else 0
        # tmux_alive is best-effort; if the source CLI says active=False the
        # tmux session is gone. Mirror that signal — admin agent can re-check.
        tmux_alive = bool(active)
        findings.append(
            {
                "ts": ts,
                "kind": "stale-stopped-with-queue",
                "agent": name,
                "evidence": {
                    "loop_enabled": loop_enabled,
                    "tmux_alive": tmux_alive,
                    "queued": queued,
                    "blocked": blocked,
                    "wake_stale_seconds": int(wake_stale),
                },
                "suggested_action": f"agent-bridge agent restart {name}",
            }
        )
    return findings


def detect_stale_blocked_task(
    agents: list[dict[str, Any]],
    blocked_tasks: list[dict[str, Any]],
    threshold_seconds: int,
    ts: str,
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    now = now_ts()
    by_name: dict[str, dict[str, Any]] = {
        str(agent.get("agent") or ""): agent for agent in agents if agent.get("agent")
    }
    for task in blocked_tasks:
        claimed_by = task["claimed_by"]
        if not claimed_by:
            continue
        owner = by_name.get(claimed_by) or {}
        owner_state = str(owner.get("activity_state") or "")
        # Spec: only emit when the claimer is `idle`. `stopped` agents are a
        # different recovery path (covered by stale-stopped-with-queue or by
        # admin escalation). `working` means the claimer is actively making
        # progress; the blocked task may legitimately be parked while the
        # claimer works on something else.
        if owner_state != "idle":
            continue
        updated_ts = int(task["updated_ts"] or 0)
        blocked_age = max(0, now - updated_ts) if updated_ts else 0
        if blocked_age < threshold_seconds:
            continue
        last_update = blocked_age  # `updated_ts` is the last status change
        suggested = f"agent-bridge update {task['id']} --status queued"
        if blocked_age > 7 * 86400:
            suggested = (
                f"agent-bridge update {task['id']} --status queued "
                "(escalate to operator — blocked >7d)"
            )
        findings.append(
            {
                "ts": ts,
                "kind": "stale-blocked-task",
                "agent": claimed_by,
                "evidence": {
                    "task_id": int(task["id"]),
                    "claimed_by": claimed_by,
                    "claimed_by_activity_state": owner_state,
                    "blocked_age_seconds": int(blocked_age),
                    "last_update_seconds": int(last_update),
                },
                "suggested_action": suggested,
            }
        )
    return findings


def workdir_slug_candidates(workdir: str) -> list[str]:
    """Mirror lib/bridge-state.sh workdir_slug_candidates() — the slug
    transformer Claude Code itself uses to pick `~/.claude/projects/<slug>/`.
    """
    if not workdir:
        return []
    slash_only = workdir.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", workdir)
    candidates = [slash_only]
    if slash_and_dot != slash_only:
        candidates.append(slash_and_dot)
    return candidates


def _is_clean_exit(prior_path: Path) -> bool:
    """Return True if the prior jsonl tail shows an operator-driven clean end.

    Reads up to the last 8 KiB of the file and looks for the slash-command
    marker Claude Code writes when the operator types `/exit`. That is a
    clean session end, not a cold restart (#588). Any I/O error is treated
    as "not clean" so the detector remains best-effort.
    """
    try:
        size = prior_path.stat().st_size
        with prior_path.open("rb") as fh:
            fh.seek(max(0, size - 8192))
            tail_bytes = fh.read()
    except OSError:
        return False
    return b"<command-name>/exit</command-name>" in tail_bytes


def detect_cold_restart_suspect(
    agents: list[dict[str, Any]],
    ts: str,
    projects_root: Path,
) -> list[dict[str, Any]]:
    """Best-effort: emit only when we are confident.

    Heuristic: the agent's current session has its own jsonl AND there is at
    least one prior jsonl in the same workdir-slug directory whose mtime is
    fresh (within the last 7 days) and whose stem differs from the active
    session_id. The 7d window keeps long-archived transcripts from triggering
    false positives. Prior transcripts ending in a `/exit` slash-command
    are skipped — those are clean operator-driven ends, not cold restarts
    (#588).
    """
    findings: list[dict[str, Any]] = []
    if not projects_root.is_dir():
        return findings
    now = now_ts()
    fresh_window = 7 * 86400
    for agent in agents:
        if str(agent.get("engine") or "") != "claude":
            continue
        if not agent.get("active"):
            continue
        name = str(agent.get("agent") or "")
        current_sid = str(agent.get("session_id") or "")
        workdir = str(agent.get("workdir") or "")
        if not name or not current_sid or not workdir:
            continue
        candidates = workdir_slug_candidates(workdir)
        prior: tuple[str, str, int] | None = None
        current_present = False
        for slug in candidates:
            slug_dir = projects_root / slug
            if not slug_dir.is_dir():
                continue
            try:
                entries = list(slug_dir.iterdir())
            except OSError:
                continue
            for entry in entries:
                if entry.suffix != ".jsonl":
                    continue
                stem = entry.stem
                if not stem:
                    continue
                try:
                    mtime = int(entry.stat().st_mtime)
                except OSError:
                    continue
                if stem == current_sid:
                    current_present = True
                    continue
                age = now - mtime
                if age < 0 or age > fresh_window:
                    continue
                if prior is None or mtime > prior[2]:
                    prior = (stem, str(entry), mtime)
        if not current_present or prior is None:
            continue
        prior_sid, prior_path, prior_mtime = prior
        if _is_clean_exit(Path(prior_path)):
            continue
        findings.append(
            {
                "ts": ts,
                "kind": "cold-restart-suspect",
                "agent": name,
                "evidence": {
                    "current_session_id": current_sid,
                    "previous_session_id": prior_sid,
                    "prior_jsonl_path": prior_path,
                    "prior_jsonl_age_seconds": int(max(0, now - prior_mtime)),
                },
                "suggested_action": (
                    f"agent-bridge agent restart {name} --no-continue"
                ),
            }
        )
    return findings


def detect_abnormal_session_pane(ts: str, explicit: bool) -> list[dict[str, Any]]:
    """Placeholder — best-effort detector that is not yet implemented.

    The pane-pattern set lives in bridge-stall.py and is tuned for the
    daemon's stall classifier. Reusing those patterns for an admin-facing
    detector would require either importing from a non-package script or
    extracting them into a shared module — both are larger than the spec's
    "smallest read-only CLI" scope. The brief explicitly authorizes shipping
    this detector as a placeholder so the other three deliver primary value
    now; a follow-up can lift the patterns when an operator hits the case.

    When the default detector set runs, this returns []: a healthy host
    should see an empty findings list, not a detector-error row that the
    admin agent must learn to ignore. When the operator explicitly opts in
    via `--detectors abnormal-session-pane`, we surface the
    not-yet-implemented gap as a detector-error so the request is not
    silently swallowed.
    """
    if not explicit:
        return []
    return [
        {
            "ts": ts,
            "kind": "detector-error",
            "agent": "",
            "evidence": {
                "detector": "abnormal-session-pane",
                "error": "abnormal-session-pane detector not implemented",
            },
            "suggested_action": "",
        }
    ]


def _daemon_pid_alive(state_dir: Path) -> bool:
    """Best-effort: True iff state/daemon.pid exists and the PID is alive."""
    pid_file = state_dir / "daemon.pid"
    try:
        raw = pid_file.read_text(encoding="utf-8").strip()
    except OSError:
        return False
    if not raw:
        return False
    try:
        pid = int(raw.split()[0])
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def detect_daemon_log_split(
    state_dir: Path,
    ts: str,
) -> list[dict[str, Any]]:
    """Issue #590: BRIDGE_DAEMON_LOG frozen while launchagent.log is active.

    Fires when ALL of the following hold:
    - daemon process is running (pid file present, PID alive)
    - the configured BRIDGE_DAEMON_LOG mtime is older than 7 days
    - launchagent.log exists in the same state dir AND its mtime is within
      the last 1 day

    Skipped when the configured BRIDGE_DAEMON_LOG already points at
    launchagent.log (the post-fix default on launchd installs) — there is
    no split to flag in that case.
    """
    findings: list[dict[str, Any]] = []
    if not state_dir.is_dir():
        return findings
    if not _daemon_pid_alive(state_dir):
        return findings
    env_log = os.environ.get("BRIDGE_DAEMON_LOG", "").strip()
    daemon_log = Path(env_log).expanduser() if env_log else (state_dir / "daemon.log")
    # Resolve launchagent log from installer-written marker when present
    # (issue #590 PR #599 r2). Falls back to the conventional path on
    # installs that have not yet run `install-daemon-launchagent.sh --apply`
    # under the new code.
    launchagent_log = state_dir / "launchagent.log"
    config_path = state_dir / "launchagent.config"
    if config_path.is_file():
        try:
            for line in config_path.read_text(encoding="utf-8").splitlines():
                if line.startswith("BRIDGE_LAUNCHAGENT_LOG="):
                    # shell-quoted via printf %q; shlex.split unquotes it.
                    # ValueError covers malformed quoting (e.g. an unclosed
                    # quote in the marker file) — a corrupted marker is a
                    # separate operational problem, so fall back to the
                    # conventional path rather than surface a detector-error.
                    parts = shlex.split(line.split("=", 1)[1])
                    if parts:
                        launchagent_log = Path(parts[0])
                    break
        except (OSError, ValueError):
            pass
    # No split possible if BRIDGE_DAEMON_LOG already points at the launchagent
    # stream; the new default does this on launchd-managed macOS installs.
    try:
        if daemon_log.resolve() == launchagent_log.resolve():
            return findings
    except OSError:
        pass
    if not daemon_log.is_file() or not launchagent_log.is_file():
        return findings
    now = now_ts()
    try:
        daemon_age = now - int(daemon_log.stat().st_mtime)
        launchagent_age = now - int(launchagent_log.stat().st_mtime)
    except OSError:
        return findings
    # Detector wants `daemon log >7 days old AND launchagent log <1 day old`.
    # Use strict inequalities so the boundary matches the literal threshold.
    if daemon_age < 7 * 86400:
        return findings
    if launchagent_age >= 86400:
        return findings
    daemon_age_days = daemon_age // 86400
    findings.append(
        {
            "ts": ts,
            "kind": "daemon-log-split",
            "agent": "",
            "evidence": {
                "bridge_daemon_log": str(daemon_log),
                "bridge_daemon_log_age_seconds": int(daemon_age),
                "launchagent_log": str(launchagent_log),
                "launchagent_log_age_seconds": int(launchagent_age),
            },
            "suggested_action": (
                f"BRIDGE_DAEMON_LOG ({daemon_log}) has not been written to in "
                f"{daemon_age_days} days; daemon appears launchd-managed and is "
                f"writing to {launchagent_log}. Set "
                f"BRIDGE_DAEMON_LOG={launchagent_log} or run "
                "'agent-bridge daemon status' to confirm both paths."
            ),
        }
    )
    return findings


def _is_test_artifact_name(name: str) -> bool:
    for prefix in ORPHAN_TEST_ARTIFACT_PREFIXES:
        if name.startswith(prefix):
            return True
    return bool(ORPHAN_TEST_ARTIFACT_REPRO_REGEX.search(name))


def _best_effort_dir_size(path: Path) -> int | None:
    """Walk `path` and sum file sizes. Returns None if the walk cannot start.

    Best-effort: errors on individual entries (permission denied on a single
    subdir) are swallowed so the detector still reports the orphan rather
    than crashing. A None return signals the operator that size_bytes could
    not be computed at all (top-level directory is unreadable).
    """
    total = 0
    try:
        iterator = os.walk(path, onerror=lambda _e: None)
    except OSError:
        return None
    saw_anything = False
    for root, _dirs, files in iterator:
        saw_anything = True
        for fname in files:
            fpath = os.path.join(root, fname)
            try:
                total += os.path.getsize(fpath)
            except OSError:
                continue
    if not saw_anything:
        # os.walk yielded nothing — either the path is unreadable or empty.
        # Distinguish: if path is a readable directory we report 0; otherwise
        # signal failure with None.
        try:
            if not os.access(path, os.R_OK | os.X_OK):
                return None
        except OSError:
            return None
        return 0
    return total


def _best_effort_last_active(path: Path) -> float | None:
    """Latest mtime under `path/{raw,memory,state}` recursively, fallback to
    the dir mtime. Returns None if even the dir mtime cannot be read."""
    candidates: list[float] = []
    for sub in ("raw", "memory", "state"):
        sub_path = path / sub
        if not sub_path.is_dir():
            continue
        try:
            for root, _dirs, files in os.walk(sub_path, onerror=lambda _e: None):
                for fname in files:
                    fpath = os.path.join(root, fname)
                    try:
                        candidates.append(os.path.getmtime(fpath))
                    except OSError:
                        continue
                # Also consider the dir mtime so empty subtrees still count.
                try:
                    candidates.append(os.path.getmtime(root))
                except OSError:
                    continue
        except OSError:
            continue
    if candidates:
        return max(candidates)
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def _format_size(size_bytes: int) -> str:
    if size_bytes < 1024:
        return f"{size_bytes}B"
    for unit in ("KB", "MB", "GB", "TB"):
        size_bytes /= 1024  # type: ignore[assignment]
        if size_bytes < 1024:
            return f"{size_bytes:.1f}{unit}"
    return f"{size_bytes:.1f}PB"


def _iso_from_epoch(epoch: float | None) -> str:
    if epoch is None:
        return ""
    try:
        return (
            datetime.fromtimestamp(int(epoch), tz=timezone.utc)
            .astimezone()
            .isoformat(timespec="seconds")
        )
    except (OSError, ValueError, OverflowError):
        return ""


def detect_orphan_agent_dir(
    registry: list[dict[str, Any]],
    home_root: Path,
    ts: str,
) -> list[dict[str, Any]]:
    """Issue #598 Track 2: surface directories under $BRIDGE_AGENT_HOME_ROOT
    that are not registered in `agent registry --json`.

    Report-only. Each finding includes a manual quarantine recipe in
    `suggested_action` (the eventual `agent retire` primitive — Track 3 —
    will replace the recipe when it lands). Test-artifact prefixes get
    `evidence.is_test_artifact = true` so an operator can triage in one
    pass.
    """
    findings: list[dict[str, Any]] = []
    if not home_root.is_dir():
        return findings

    known: set[str] = set()
    for row in registry:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or "").strip()
        if agent_id:
            known.add(agent_id)

    try:
        entries = sorted(home_root.iterdir(), key=lambda p: p.name)
    except OSError:
        return findings

    for entry in entries:
        name = entry.name
        if name in ORPHAN_SKIP_NAMES:
            continue
        if name.startswith(".claude") or name.startswith("."):
            continue
        # Per spec: match by basename, not by `home` equality (dynamic agents
        # can place their workdir anywhere). The registry `id` IS the
        # directory basename for any home-root-resident agent.
        if name in known:
            continue
        if not entry.is_dir():
            continue
        # Skip symlinks that don't point at an actual agent home (live
        # `shared/` link, stale convenience symlinks). A dir-shaped symlink
        # whose target is a real directory is still walked — that's the
        # `--prefer new` worktree case where the agent home is a real dir.
        try:
            if entry.is_symlink():
                resolved = entry.resolve(strict=False)
                if not resolved.is_dir():
                    continue
        except OSError:
            continue

        try:
            dir_mtime = os.path.getmtime(entry)
        except OSError:
            dir_mtime = None
        size_bytes = _best_effort_dir_size(entry)
        last_active = _best_effort_last_active(entry)
        is_test_artifact = _is_test_artifact_name(name)

        evidence: dict[str, Any] = {
            "dir": str(entry),
            "mtime": _iso_from_epoch(dir_mtime),
            "last_active_at": _iso_from_epoch(last_active),
            "is_test_artifact": is_test_artifact,
            "registry_checked": "agent registry --json",
        }
        if size_bytes is not None:
            evidence["size_bytes"] = int(size_bytes)
        size_human = _format_size(size_bytes) if size_bytes is not None else "unknown"
        mtime_iso = evidence["mtime"] or "unknown"
        # NOTE: Track 3's `agent retire <name> [--purge-home]` will replace
        # the manual recipe below. Until then, recommend a quarantine move
        # so the operator preserves the dir for postmortem and the orphan
        # set drops out of the next doctor run.
        suggested = (
            f"Orphan agent dir at {entry} (size {size_human}, mtime {mtime_iso}). "
            "Not registered in `agent registry --json`. Manual quarantine: "
            f'mv "{entry}" '
            f'"$BRIDGE_HOME/archive/orphans-$(date +%Y%m%d-%H%M%S)-{name}". '
            "If this is a test artifact (smoke-/test-/bootstrap-/"
            "created-agent-/pref-/*-repro-N), confirm via "
            "`--detectors orphan-agent-dir --json | jq` and quarantine in "
            "batch. `agent retire` (issue #598 Track 3) will replace this "
            "manual recipe when it lands."
        )

        findings.append(
            {
                "ts": ts,
                "kind": "orphan-agent-dir",
                "agent": name,
                "evidence": evidence,
                "suggested_action": suggested,
            }
        )
    return findings


# --- rendering -------------------------------------------------------------


def render_table(findings: list[dict[str, Any]]) -> str:
    if not findings:
        return "No stuck-state signals detected."
    lines: list[str] = []
    lines.append("kind                       agent           evidence")
    for finding in findings:
        kind = str(finding.get("kind") or "")
        agent = str(finding.get("agent") or "") or "-"
        evidence = finding.get("evidence") or {}
        if isinstance(evidence, dict):
            ev_str = " ".join(f"{k}={v}" for k, v in evidence.items())
        else:
            ev_str = str(evidence)
        lines.append(f"{kind:<26} {agent:<15} {ev_str}")
        suggested = str(finding.get("suggested_action") or "")
        if suggested:
            lines.append(f"  suggested: {suggested}")
    return "\n".join(lines)


# --- main ------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="bridge-doctor.py",
        description=(
            "Read-only stuck-state detectors for admin self-healing. "
            "Findings are hints; daemon does not act on them."
        ),
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON list of findings.")
    parser.add_argument(
        "--state-dir",
        default=None,
        help="Override BRIDGE_STATE_DIR (default: env / $BRIDGE_HOME/state / ~/.agent-bridge/state).",
    )
    parser.add_argument(
        "--task-db",
        default=None,
        help="Override BRIDGE_TASK_DB (default: env / <state-dir>/tasks.db).",
    )
    parser.add_argument(
        "--detectors",
        default="",
        help=(
            "Comma-separated allow-list of detector kinds. Default: all. "
            f"Valid: {','.join(DETECTOR_KINDS)}."
        ),
    )
    parser.add_argument(
        "--agent-list-json",
        default=None,
        help=(
            "Path to a JSON file with `agent-bridge agent list --json` output. "
            "Used by tests to skip the subprocess."
        ),
    )
    parser.add_argument(
        "--agent-bridge",
        default=None,
        help="Path to the agent-bridge binary (default: sibling to this script).",
    )
    parser.add_argument(
        "--projects-root",
        default=None,
        help=(
            "Override the Claude transcripts root for cold-restart-suspect "
            "(default: ~/.claude/projects)."
        ),
    )
    parser.add_argument(
        "--agent-registry-json",
        default=None,
        help=(
            "Path to a JSON file with `agent-bridge agent registry --json` "
            "output. Used by tests to skip the subprocess (Issue #598 Track 2)."
        ),
    )
    parser.add_argument(
        "--agent-home-root",
        default=None,
        help=(
            "Override BRIDGE_AGENT_HOME_ROOT (default: env / "
            "$BRIDGE_HOME/agents / ~/.agent-bridge/agents). Used by the "
            "orphan-agent-dir detector."
        ),
    )
    args = parser.parse_args()

    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    enabled = parse_detectors(args.detectors)
    state_dir = resolve_state_dir(args.state_dir)
    task_db = resolve_task_db(args.task_db, state_dir)
    projects_root = (
        Path(args.projects_root).expanduser()
        if args.projects_root
        else (Path.home() / ".claude" / "projects")
    )

    threshold_env = os.environ.get("BRIDGE_DOCTOR_BLOCKED_THRESHOLD_SECONDS", "").strip()
    try:
        blocked_threshold = int(threshold_env) if threshold_env else 86400
    except ValueError:
        blocked_threshold = 86400
    if blocked_threshold < 0:
        blocked_threshold = 86400

    ts = iso_now()
    findings: list[dict[str, Any]] = []

    # Each detector runs inside its own try/except so an internal exception
    # in one does not crash the whole CLI.
    try:
        agents = load_agent_list(args)
    except SystemExit:
        # Roster load failure is fatal — no detector can run without it.
        # Emit a single detector-error and exit 0 so the admin agent still
        # gets a parseable response.
        findings.append(
            {
                "ts": ts,
                "kind": "detector-error",
                "agent": "",
                "evidence": {
                    "detector": "roster",
                    "error": "agent list unavailable",
                },
                "suggested_action": "",
            }
        )
        agents = []

    conn = None
    try:
        conn = db_connect_readonly(task_db)
    except sqlite3.OperationalError as exc:
        findings.append(
            {
                "ts": ts,
                "kind": "detector-error",
                "agent": "",
                "evidence": {
                    "detector": "task-db",
                    "error": f"sqlite open failed: {exc}",
                },
                "suggested_action": "",
            }
        )

    try:
        agent_state = fetch_agent_state(conn)
    except Exception as exc:  # noqa: BLE001 — detector boundary
        agent_state = {}
        findings.append(
            {
                "ts": ts,
                "kind": "detector-error",
                "agent": "",
                "evidence": {
                    "detector": "agent_state",
                    "error": str(exc),
                },
                "suggested_action": "",
            }
        )

    try:
        blocked_tasks = fetch_blocked_tasks(conn)
    except Exception as exc:  # noqa: BLE001 — detector boundary
        blocked_tasks = []
        findings.append(
            {
                "ts": ts,
                "kind": "detector-error",
                "agent": "",
                "evidence": {
                    "detector": "tasks",
                    "error": str(exc),
                },
                "suggested_action": "",
            }
        )

    if conn is not None:
        conn.close()

    # Issue #598 Track 2: lazy-load `agent registry --json` only when the
    # orphan-agent-dir detector is enabled. The detector closure captures
    # the deferred loader so a registry failure surfaces as a per-detector
    # detector-error rather than failing the whole doctor run.
    enabled_set_pre = set(enabled)
    home_root = resolve_agent_home_root(args.agent_home_root)
    registry_load_failed = False
    if "orphan-agent-dir" in enabled_set_pre:
        try:
            registry = load_agent_registry(args)
        except SystemExit as exc:
            registry = []
            registry_load_failed = True
            findings.append(
                {
                    "ts": ts,
                    "kind": "detector-error",
                    "agent": "",
                    "evidence": {
                        "detector": "orphan-agent-dir",
                        "error": str(exc),
                    },
                    "suggested_action": "",
                }
            )
    else:
        registry = []

    abnormal_explicit = bool(args.detectors)
    detector_runs: list[tuple[str, Any]] = [
        (
            "stale-stopped-with-queue",
            lambda: detect_stale_stopped_with_queue(agents, agent_state, ts),
        ),
        (
            "stale-blocked-task",
            lambda: detect_stale_blocked_task(agents, blocked_tasks, blocked_threshold, ts),
        ),
        (
            "cold-restart-suspect",
            lambda: detect_cold_restart_suspect(agents, ts, projects_root),
        ),
        (
            "abnormal-session-pane",
            lambda: detect_abnormal_session_pane(ts, abnormal_explicit),
        ),
        (
            "daemon-log-split",
            lambda: detect_daemon_log_split(state_dir, ts),
        ),
        (
            "orphan-agent-dir",
            # Short-circuit when registry-load failed so we don't flood the
            # operator with every-dir-is-orphan false positives. The
            # detector-error row was already emitted above; the empty
            # known-set otherwise treats every dir under BRIDGE_AGENT_HOME_ROOT
            # as orphan.
            lambda: [] if registry_load_failed else detect_orphan_agent_dir(registry, home_root, ts),
        ),
    ]

    enabled_set = set(enabled)
    for kind, runner in detector_runs:
        if kind not in enabled_set:
            continue
        try:
            findings.extend(runner())
        except Exception as exc:  # noqa: BLE001 — detector boundary, spec-mandated
            findings.append(
                {
                    "ts": ts,
                    "kind": "detector-error",
                    "agent": "",
                    "evidence": {
                        "detector": kind,
                        "error": str(exc),
                    },
                    "suggested_action": "",
                }
            )

    # `--detectors` is also an allow-list against detector-error rows so the
    # admin agent can isolate one detector cleanly (D5 in the smoke matrix).
    if args.detectors:
        kept: list[dict[str, Any]] = []
        for finding in findings:
            kind = finding.get("kind")
            if kind in enabled_set:
                kept.append(finding)
                continue
            if kind == "detector-error":
                evidence = finding.get("evidence") or {}
                if isinstance(evidence, dict) and evidence.get("detector") in enabled_set:
                    kept.append(finding)
        findings = kept

    if args.json:
        print(json.dumps(findings, ensure_ascii=False, indent=2))
    else:
        print(render_table(findings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
