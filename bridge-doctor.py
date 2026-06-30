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
- settings-two-tree-drift  : a CLAUDE agent whose home + workdir `settings.json` resolve
                             to two real files with DIFFERENT CONTENT (#1455). A
                             preserved-user key like `enabledPlugins` drifting between
                             the trees was the root cause of #1453. Two distinct inodes
                             with IDENTICAL content is the renderer's intended dual-render
                             on shared-mode v2 non-iso hosts and is NOT flagged (#1788);
                             non-claude engines are skipped (#1788 Note).
- settings-multi-tree      : a CLAUDE agent whose effective settings file exists as a
                             real (non-symlink) file in MORE THAN ONE location — both
                             `home/.claude/` and `workdir/.claude/` — with DIVERGENT
                             content (#1455). Two byte-identical physical copies is the
                             renderer's intended dual-render on shared-mode v2 non-iso
                             hosts and is NOT flagged (#1788); non-claude engines are
                             skipped (#1788 Note).

Read-only contract: the CLI never mutates queue/state/tmux. `suggested_action`
is a string the admin agent LLM parses and decides whether to execute. The two
`settings-*` detectors are report-only by design — they NEVER re-point a symlink
or author policy; the operator runs `link-shared-settings` (bridge-hooks.py) to
remediate. See docs/settings-single-tree-invariant.md (#1455).
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

# Issue #1803: the action-safe agent-home-root classifier is the SSOT for
# "what is a child of agents/, and is it safe to touch?". The orphan-agent-dir
# detector below now consumes it (behavior-preserving) so the daemon GC,
# the status counter, and this read-only detector can never drift. The
# classifier is a repo-root sibling module (same import idiom as
# bridge_guard_common / bridge_reconcile_common).
from bridge_orphan_classifier import (
    KIND_ORPHAN,
    KIND_ORPHAN_UNVERIFIABLE,
    classify_agent_home_root,
)


DETECTOR_KINDS = (
    "stale-stopped-with-queue",
    "stale-blocked-task",
    "cold-restart-suspect",
    "abnormal-session-pane",
    "daemon-log-split",
    "daemon-launchd-disabled-drift",
    "orphan-agent-dir",
    "missing-agent-entrypoint",
    "settings-two-tree-drift",
    "settings-multi-tree",
    "tasks-db",
)

# Issue #2205: the EXACT key set a daemon-quiesce.intent marker carries (the writer
# is _bridge_upgrade_write_quiesce_marker in bridge-upgrade.sh). The disabled-drift
# detector's strict-schema validation rejects a marker carrying any OTHER key — an
# off-schema line is not the marker's content and must not authorize suppressing the
# finding. Mirrors the watcher's pre-source allowlist in
# scripts/bridge-daemon-liveness.sh; a future field must be added in lock-step.
_MARKER_KNOWN_KEYS = frozenset(
    {
        "BRIDGE_QUIESCE_UPGRADE_PID",
        "BRIDGE_QUIESCE_UPGRADE_PSID",
        "BRIDGE_QUIESCE_UPGRADE_UID",
        "BRIDGE_QUIESCE_PLATFORM",
        "BRIDGE_QUIESCE_TARGET",
        "BRIDGE_QUIESCE_REASON",
        "BRIDGE_QUIESCE_TS",
        "BRIDGE_QUIESCE_VERSION",
    }
)

# Issue #1455: the settings detectors share a registry-derived view of an
# agent's two trees. These names are the canonical leaves the
# single-tree invariant pins (see docs/settings-single-tree-invariant.md):
#   <home>/.claude/settings.json            → settings.effective.json (real)
#   <workdir>/.claude/settings.json         → relative symlink into home
# Both detectors read these via `agent registry --json` (home + workdir
# columns), never by re-deriving the layout — that keeps the doctor in
# lockstep with the bridge's own resolved paths.
SETTINGS_CLAUDE_DIR = ".claude"
SETTINGS_LINK_NAME = "settings.json"
SETTINGS_EFFECTIVE_NAME = "settings.effective.json"
# The set of detector kinds that consume `agent registry --json`. The
# registry is lazy-loaded in main() only when at least one of these (or
# orphan-agent-dir) is enabled.
SETTINGS_DETECTOR_KINDS = frozenset(
    {"settings-two-tree-drift", "settings-multi-tree"}
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


def probe_tasks_db_health(task_db: Path) -> dict[str, Any]:
    """Read-only health probe of the queue DB (Issue #1786).

    Returns a 3-state dict: ``state`` is one of ``ok`` / ``corrupt`` /
    ``unverifiable`` / ``missing``, plus a ``quick_check`` string and an
    ``open_mode`` showing which read path succeeded.

    This is the policy-blessed counterpart to ``bridge-upgrade.py
    verify-tasks-db``: the v0.16.8 tool-policy hook blocks a Bash command
    that directly references the queue DB path, but `agent-bridge doctor
    --detectors tasks-db` is an `agb` verb the hook allows, so the admin
    agent can run the same ro `PRAGMA quick_check` from inside its session.

    Why the ``mode=ro`` → ``immutable=1`` fallback ladder: the live queue is
    WAL-journaled (``bridge-queue.py`` sets ``PRAGMA journal_mode=WAL``). A
    plain ``mode=ro`` read of a WAL db from a separate process needs the
    ``-shm`` sidecar; when no live writer holds it open and the sidecar is
    absent (right after a checkpoint), sqlite cannot create ``-shm`` in
    read-only mode and the read fails SQLITE_CANTOPEN ("unable to open
    database file") — a FALSE negative on a healthy db. ``immutable=1``
    bypasses WAL/shm. The open succeeds lazily, so we probe-read each
    candidate before accepting it. An open that fails for an UNKNOWN reason
    reports ``unverifiable: <cause>`` and NEVER ``ok`` — distinct from
    ``corrupt`` (quick_check ran and failed).

    The ``immutable=1`` fallback is GATED on the WAL sidecar being empty or
    absent (codex r1 P2): immutable reads bypass the WAL, so a ``quick_check``
    over an immutable open would validate only the checkpointed main DB and
    silently skip committed-but-uncheckpointed pages in a non-empty ``-wal``,
    a false "ok". When ``mode=ro`` fails AND a non-empty ``-wal`` exists, we
    report ``unverifiable`` rather than risk a stale "ok". The WAL gate is
    re-evaluated at the fallback point (codex r2 P2): a live writer could
    create a non-empty ``-wal`` between an early stat and the immutable
    branch, so we stat fresh right before opting into the immutable read.
    """
    result: dict[str, Any] = {"target": str(task_db)}
    if not task_db.exists():  # noqa: raw-pathlib-controller-only — read-only existence probe of the controller's own queue DB; the doctor never runs inside an iso UID against another agent's tree.
        result["state"] = "missing"
        return result

    def _wal_has_unmerged_pages() -> bool:
        try:
            wal_sidecar = task_db.with_name(task_db.name + "-wal")
            return wal_sidecar.is_file() and wal_sidecar.stat().st_size > 0  # noqa: raw-pathlib-controller-only — read-only sidecar size probe on the controller's own queue DB; OSError-guarded.
        except OSError:
            # Can't stat the sidecar — assume it may hold unmerged pages so we
            # never silently skip them.
            return True

    last_err = ""
    saw_unmerged_wal = False
    for mode in ("mode=ro", "immutable=1"):
        if mode == "immutable=1" and _wal_has_unmerged_pages():
            # Re-stat'd here (not once up front) to close the TOCTOU race with
            # a live writer. Skipping the WAL would hide committed pages.
            saw_unmerged_wal = True
            last_err = last_err or "wal_unmerged: refusing immutable read that would bypass a non-empty -wal"
            break
        conn = None
        try:
            conn = sqlite3.connect(f"file:{task_db}?{mode}", uri=True)
            conn.execute("PRAGMA schema_version").fetchone()
            try:
                row = conn.execute("PRAGMA quick_check").fetchone()
            finally:
                conn.close()
            check = str(row[0]) if row else ""
            result["open_mode"] = mode
            result["quick_check"] = check
            result["state"] = "ok" if check == "ok" else "corrupt"
            return result
        except sqlite3.OperationalError as exc:
            # Open/access failure (unable to open, locked, disk I/O) — not a
            # statement about the db's integrity. Retry / fall through to
            # unverifiable.
            last_err = f"{type(exc).__name__}: {exc}"
            if conn is not None:
                conn.close()
        except sqlite3.DatabaseError as exc:
            # A non-Operational DatabaseError ("file is not a database",
            # "database disk image is malformed", "file is encrypted or is not
            # a database") IS corruption — the file opened far enough to be
            # read and the bytes are not a valid db. Classify corrupt, not
            # unverifiable (codex r3 P2): retrying with immutable would raise
            # the same error, and calling it "unverifiable" would tell the
            # operator NOT to treat real corruption as corruption.
            if conn is not None:
                conn.close()
            result["open_mode"] = mode
            result["quick_check"] = f"{type(exc).__name__}: {exc}"
            result["state"] = "corrupt"
            return result
    # Both read attempts failed (or the immutable fallback was unsafe) —
    # classify the open-failure cause so the operator/agent gets an actionable
    # "unverifiable: <cause>".
    cause = "wal_unmerged_unreadable" if saw_unmerged_wal else "open_failed"
    try:
        st = task_db.stat()  # noqa: raw-pathlib-controller-only — read-only cause classification on the controller's own queue DB; OSError-guarded, never crosses an iso boundary.
        if not os.access(task_db, os.R_OK):
            cause = "not_readable"
        elif not os.access(task_db.parent, os.X_OK | os.R_OK):
            cause = "dir_not_accessible"
        elif not saw_unmerged_wal and st.st_size == 0:
            cause = "empty_file"
    except OSError:
        cause = "stat_failed"
    result["state"] = "unverifiable"
    result["error"] = f"{cause}: {last_err}"
    return result


def detect_tasks_db(task_db: Path, ts: str) -> list[dict[str, Any]]:
    """Issue #1786 detector: queue DB integrity, agent-reachable.

    Emits a `tasks-db` finding ONLY when the db is unhealthy — corrupt,
    unverifiable, or missing-on-an-otherwise-live-install. A healthy db
    returns [] (the doctor convention: a finding means a problem). The
    `missing` case is reported (not silently dropped) because by the time an
    admin runs the upgrade-complete checklist the queue has already been
    exercised, so a missing tasks.db there is a real anomaly worth surfacing;
    the suggested action distinguishes it from corruption.
    """
    probe = probe_tasks_db_health(task_db)
    state = probe.get("state")
    if state == "ok":
        return []
    if state == "corrupt":
        suggested = (
            "Queue DB integrity check failed (quick_check error or the file is "
            "not a valid sqlite database). Stop the daemon, restore the latest "
            "SQL snapshot under state/backup-snapshots/ into a fresh tasks.db, "
            "then restart. See OPERATOR_ACTIONS_PENDING.md."
        )
    elif state == "missing":
        suggested = (
            "Queue DB is absent. On a fresh install this is expected until the "
            "first task is filed; on a live install it indicates the queue was "
            "moved/deleted — check BRIDGE_TASK_DB / state/ and restore if needed."
        )
    else:  # unverifiable
        suggested = (
            "Queue DB could not be opened read-only for an unknown reason "
            f"({probe.get('error', '')}). The live queue (agb inbox/claim/done) "
            "may still be healthy — verify there first. Do NOT treat this as "
            "corruption; check file/dir perms and the open cause before acting."
        )
    return [
        {
            "ts": ts,
            "kind": "tasks-db",
            "agent": "",
            "evidence": probe,
            "suggested_action": suggested,
        }
    ]


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


def _launchd_disabled_drift_evidence(
    state_dir: Path,
) -> dict[str, Any] | None:
    """Issue #2205: probe whether the launchd daemon job has drifted to a
    disabled / not-bootstrapped state WITHOUT a valid first-party
    non-operator-disable marker.

    Returns an evidence dict when an UNPROVABLE disabled-drift is present
    (the watcher will fail-closed skip it, so the operator must see it), or
    None when there is nothing to flag (job enabled+loaded, the daemon is
    running, no launchagent install, a valid recovery marker is present, or
    the disabled-state could not be read). Pure read; spawns only `launchctl`
    query verbs (print / print-disabled), never a mutation.

    The marker carve-out mirrors scripts/bridge-daemon-liveness.sh's recovery
    predicate: only a WELL-FORMED marker whose platform=launchd AND
    target=<label> AND recorded writer pid is DEAD is the watcher's recoverable
    case, so it is NOT unprovable drift and we stay quiet (the watcher owns it).
    A malformed / mismatched / missing-pid / LIVE-writer marker is NOT proof of
    recoverability and does NOT suppress the finding — the doctor errs toward
    MORE visibility, never less.
    """
    if shutil.which("launchctl") is None:
        return None
    # Resolve the launchd label from the installer-written marker (the same
    # "we are launchd-managed" signal the watcher uses). Absent → not a
    # launchd-managed install we can reason about.
    config_path = state_dir / "launchagent.config"
    label = ""
    try:
        for line in config_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("BRIDGE_LAUNCHAGENT_LABEL="):
                parts = shlex.split(line.split("=", 1)[1])
                if parts:
                    label = parts[0]
                break
    except (OSError, ValueError):
        return None
    if not label:
        return None
    # Only flag when the daemon is actually DOWN — an alive daemon is not a
    # drift worth an operator's attention here.
    if _daemon_pid_alive(state_dir):
        return None
    uid = str(os.getuid()) if hasattr(os, "getuid") else os.environ.get("UID", "")
    if not uid:
        return None

    def _launchctl(args: list[str]) -> subprocess.CompletedProcess[str] | None:
        try:
            return subprocess.run(
                ["launchctl", *args],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None

    # Disabled-state probe. `print-disabled gui/<uid>` lists labels with an
    # explicit override; modern macOS prints `"<label>" => disabled`, legacy
    # `=> true`. Absent line / command failure → cannot prove disabled.
    disabled = False
    pd = _launchctl(["print-disabled", f"gui/{uid}"])
    if pd is not None and pd.returncode == 0:
        pat = re.compile(
            r'"' + re.escape(label) + r'"\s*=>\s*(?:true|disabled)'
        )
        disabled = bool(pat.search(pd.stdout or ""))
    # Loaded-state probe. `print gui/<uid>/<label>` exits non-zero when the
    # job is not bootstrapped (unloaded). An unloaded job whose KeepAlive is
    # therefore inert is the other half of the drift.
    pr = _launchctl(["print", f"gui/{uid}/{label}"])
    unloaded = pr is not None and pr.returncode != 0
    if not disabled and not unloaded:
        return None

    # Marker carve-out: stay quiet ONLY on the watcher's genuinely-recoverable
    # case — a marker that PARSES, names THIS launchd label (platform+target
    # match), AND records a DEAD writer pid (the watcher will re-enable it). Any
    # weaker marker (codex r1) — unparseable, target/platform mismatch, missing
    # / non-numeric pid, or a LIVE writer pid — is NOT proof the drift is
    # recoverable, so it MUST NOT suppress the finding (the drift stays visible).
    # We deliberately do not reimplement the watcher's full reuse/age teeth here;
    # the doctor errs toward MORE visibility, never less.
    marker_env = os.environ.get("BRIDGE_UPGRADE_QUIESCE_MARKER_FILE", "").strip()
    marker_path = (
        Path(marker_env).expanduser()
        if marker_env
        else (state_dir / "upgrade" / "daemon-quiesce.intent")
    )
    marker_platform = ""
    marker_target = ""
    marker_pid = ""
    marker_seen = False
    marker_well_formed = True
    try:
        for line in marker_path.read_text(encoding="utf-8").splitlines():
            marker_seen = True
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            # ★ STRICT-SCHEMA validation (codex r2), mirroring the watcher's pre-source
            # allowlist in scripts/bridge-daemon-liveness.sh: every non-comment line
            # must be a `KEY=...` assignment whose KEY is one of the marker's OWN known
            # fields. A line that is off-schema — an unknown key, an extra sourceable
            # command, a malformed non-assignment line — is NOT this marker's content
            # and so is NOT a recoverability proof. A prefix-only match (the r1 form)
            # would let an unexpected `BRIDGE_QUIESCE_FOO=` slip through and suppress
            # the finding; require the EXACT key set instead (fail toward visibility).
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", stripped)
            if m is None or m.group(1) not in _MARKER_KNOWN_KEYS:
                marker_well_formed = False
                continue
            if line.startswith("BRIDGE_QUIESCE_PLATFORM="):
                p = shlex.split(line.split("=", 1)[1])
                marker_platform = p[0] if p else ""
            elif line.startswith("BRIDGE_QUIESCE_TARGET="):
                t = shlex.split(line.split("=", 1)[1])
                marker_target = t[0] if t else ""
            elif line.startswith("BRIDGE_QUIESCE_UPGRADE_PID="):
                v = shlex.split(line.split("=", 1)[1])
                marker_pid = v[0] if v else ""
    except (OSError, ValueError):
        # Unparseable / unreadable marker → treat as no proof (report the drift).
        marker_well_formed = False
        marker_seen = bool(marker_platform or marker_target) or marker_seen

    def _pid_dead(raw: str) -> bool:
        try:
            pid = int(raw)
        except (TypeError, ValueError):
            return False
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False  # alive (owned by another uid) — not a dead writer
        except OSError:
            return False
        return False  # kill(pid,0) succeeded → writer is alive

    recoverable = (
        marker_well_formed
        and marker_platform == "launchd"
        and marker_target == label
        and _pid_dead(marker_pid)
    )
    if recoverable:
        # The watcher can prove + recover this; not an unprovable drift.
        return None

    return {
        "label": label,
        "uid": uid,
        "launchd_disabled": disabled,
        "launchd_unloaded": unloaded,
        "recovery_marker_present": marker_seen,
    }


def detect_disabled_drift_no_marker(
    state_dir: Path,
    ts: str,
) -> list[dict[str, Any]]:
    """Issue #2205: launchd daemon job drifted to disabled/unloaded with NO
    valid first-party non-operator-disable marker.

    This is RCA cause #2 of the 2026-06-30 fleet-down: a non-operator
    disabled-drift with no proof marker is indistinguishable from an operator
    `agb daemon stop` by the disabled flag alone, so the liveness watcher
    correctly fail-closes (the operator-stop-outranks invariant is sacred) and
    the daemon stays down. The watcher cannot auto-recover it; this detector
    makes the otherwise-silent drift VISIBLE so an operator can re-arm it by
    hand. Report-only — never mutates launchd state.
    """
    findings: list[dict[str, Any]] = []
    if not state_dir.is_dir():
        return findings
    evidence = _launchd_disabled_drift_evidence(state_dir)
    if evidence is None:
        return findings
    label = evidence["label"]
    uid = evidence["uid"]
    if evidence["launchd_disabled"]:
        drift = "disabled"
    elif evidence["launchd_unloaded"]:
        drift = "not bootstrapped (unloaded)"
    else:
        drift = "drifted"
    findings.append(
        {
            "ts": ts,
            "kind": "daemon-launchd-disabled-drift",
            "agent": "",
            "evidence": evidence,
            "suggested_action": (
                f"launchd daemon job gui/{uid}/{label} is {drift} and the "
                "daemon is down, with NO recovery marker — the liveness "
                "watcher fail-closes here (it cannot tell this from an "
                "operator `agb daemon stop`). If this was NOT an intentional "
                "stop, re-arm it: "
                f"launchctl enable gui/{uid}/{label} && "
                f"launchctl bootstrap gui/{uid} <plist> "
                "(or rerun scripts/install-daemon-launchagent.sh --apply). "
                "If it WAS intentional, no action is needed."
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


def _registered_agent_dirs(registry: list[dict[str, Any]]) -> list[tuple[str, str]]:
    """Yield (agent_id, dir) for every registered agent's home + workdir.

    The orphan detector and `agent retire` both need the SET of directories
    that belong to a registered agent so a candidate dir can be checked
    case-insensitively (macOS APFS) via `os.path.samefile`, not just by a
    case-sensitive basename string compare. Skips empty paths.
    """
    out: list[tuple[str, str]] = []
    for row in registry:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or "").strip()
        if not agent_id:
            continue
        for key in ("home", "workdir"):
            base = str(row.get(key) or "").strip()
            if base:
                out.append((agent_id, base))
    return out


# Issue #1787 (codex r3): three-state identity result so a samefile that
# cannot be RESOLVED (stat failure) never silently degrades to "not a
# registered agent". The orphan detector and `agent retire` both fail SAFE on
# INDETERMINATE — neither reports an orphan nor proceeds with a destructive
# retire when identity could not be proven (the #1774/#1771 fail-closed
# pattern). Distinct from `None` (PROVEN no-match: every registered dir was
# statable and none is the same file).
_SAMEFILE_INDETERMINATE = "\0indeterminate\0"


def _path_lexists(path: Path) -> bool:
    """True if `path` exists (incl. a broken symlink), False ONLY when it is
    provably absent. A permission/other OSError errs toward True so the caller
    fails SAFE (indeterminate) rather than treating an unreadable registered
    dir as a clean no-match. `os.lstat` is the `os`-module call, not a
    pathlib metadata probe — it does not trip the raw-pathlib lint.
    """
    try:
        os.lstat(path)
        return True
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError:
        return True


def _samefiles_registered_agent(
    candidate: Path,
    registered_dirs: list[tuple[str, str]],
) -> str | None:
    """Return the registered agent id whose home/workdir IS `candidate`.

    Filesystem-aware identity (Issue #1787): on a case-insensitive volume
    (macOS APFS default) `agents/CRM-TEST-BSH` and the registry's
    `agents/crm-test-bsh` are the SAME directory, so a case-sensitive
    basename compare wrongly classifies a LIVE agent's dir as an orphan and
    guides a destructive `mv` / `retire` of its settings tree. Mirror the
    #1759 self-ref guard idiom: realpath string-compare first, then
    `os.path.samefile` as the inode-aware fallback against each registered
    home/workdir.

    Three-state return (codex r3 — fail SAFE on indeterminate):
      * the matching agent id  — `candidate` IS a registered agent's dir;
      * `_SAMEFILE_INDETERMINATE` — a `samefile()` raised (stat failure on the
        candidate or a registered dir) and NO confirmed match was found, so we
        could not PROVE the candidate is unregistered. The caller must NOT
        report an orphan / must NOT proceed with retire in this state;
      * `None` — PROVEN no-match: every registered dir resolved cleanly and
        none is the same file as `candidate`.

    Fail-safe rule (codex r3, the #1774/#1771 fail-closed pattern): a
    `samefile()` that RAISES must not silently become "no-match". But a
    registered `home`/`workdir` legitimately may NOT EXIST (a v2 agent's `home`
    resolves to data/agents/<a>/home, often not on disk; a registry-only agent
    has no scaffolded tree) — and samefile against a NON-EXISTENT registered
    dir is a CLEAN no-match for that pair (the existing candidate cannot be a
    path that does not exist). So `_SAMEFILE_INDETERMINATE` fires only when the
    probe could be MASKING a real match: (a) the CANDIDATE itself is
    unstatable, or (b) a registered dir EXISTS yet samefile still raised.
    Forcing `os.path.samefile` to raise must never yield an orphan report for a
    LIVE agent's dir. A proven match always wins over indeterminate.
    """
    indeterminate = False
    cand_exists = _path_lexists(candidate)
    if not cand_exists:
        indeterminate = True
    try:
        cand_real = os.path.realpath(candidate)
    except OSError:
        cand_real = None
    for agent_id, base in registered_dirs:
        reg_path = Path(base).expanduser()
        if cand_real is not None:
            try:
                reg_real = os.path.realpath(reg_path)
            except OSError:
                reg_real = None
            if reg_real is not None and cand_real == reg_real:
                return agent_id
        try:
            if os.path.samefile(candidate, reg_path):
                return agent_id
        except OSError:
            # samefile raised. Clean no-match for this pair ONLY when the
            # registered dir provably does not exist; otherwise the raised
            # probe could be masking the case-variant collision where samefile
            # WOULD have matched → fail safe to indeterminate (gated on the
            # candidate being statable; an unstatable candidate is already
            # indeterminate above). A later PROVEN match still wins.
            if cand_exists and _path_lexists(reg_path):
                indeterminate = True
            continue
    if indeterminate:
        return _SAMEFILE_INDETERMINATE
    return None


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

    Issue #1803: the classification substrate (registered / infra /
    referenced-symlink-target / orphan / unverifiable) was factored into the
    shared `bridge_orphan_classifier` module so the daemon GC and the status
    counter consume the SAME verdicts this read-only detector emits. This
    function now wraps `classify_agent_home_root` and renders the same two
    finding shapes it always did (orphan-agent-dir / -unverifiable) — a
    behavior-preserving refactor (scripts/smoke/orphan-agent-dir.sh T1-T10).
    The new `referenced-symlink-target` kind is a KEEP (skipped here, same as
    the prior `_template`/`shared` and stale-symlink skips), so the detector's
    reported set never grows on existing installs.
    """
    findings: list[dict[str, Any]] = []
    if not home_root.is_dir():
        return findings

    for row in classify_agent_home_root(registry, home_root):
        kind = row.get("kind")
        if kind == KIND_ORPHAN_UNVERIFIABLE:
            name = row.get("name", "")
            entry = row.get("path", "")
            findings.append(
                {
                    "ts": ts,
                    "kind": "orphan-agent-dir-unverifiable",
                    "agent": name,
                    "evidence": {
                        "dir": entry,
                        "reason": (
                            "could not verify against the registry "
                            "(os.path.samefile stat failure); not reported "
                            "as an orphan to avoid quarantining a possibly "
                            "live agent's tree"
                        ),
                        "registry_checked": "agent registry --json",
                    },
                    "suggested_action": (
                        f"Could not prove whether {entry} is a registered "
                        "agent's directory (a stat/samefile probe failed). "
                        "It is NOT being reported as an orphan (fail-safe). "
                        "Manually confirm with `agent-bridge agent registry "
                        "--json` and check whether any registered home/"
                        f"workdir resolves to {entry} before any cleanup."
                    ),
                }
            )
            continue
        if kind != KIND_ORPHAN:
            # registered / infra / referenced-symlink-target / detector-error
            # are all KEEPs — never reported as an orphan (the detector's
            # report-only set is unchanged from pre-#1803 behavior).
            continue

        name = row.get("name", "")
        entry = Path(row.get("path", ""))
        try:
            dir_mtime = os.path.getmtime(entry)
        except OSError:
            dir_mtime = None
        size_bytes = _best_effort_dir_size(entry)
        last_active = _best_effort_last_active(entry)
        is_test_artifact = bool(row.get("is_test_artifact"))

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


# --- missing codex AGENTS.md entrypoint (#1809) -----------------------------


def _engine_entrypoint_filename(engine: str) -> str:
    """The engine's instruction-entrypoint filename, mirroring the shell
    descriptor `bridge_engine_entrypoint_filename` and bridge-watchdog.py's
    `engine_entrypoint_filename`. codex → AGENTS.md; claude/antigravity →
    CLAUDE.md; unknown → "".
    """
    e = (engine or "").strip().lower()
    if e == "codex":
        return "AGENTS.md"
    if e in ("claude", "antigravity"):
        return "CLAUDE.md"
    return ""


def detect_missing_agent_entrypoint(
    registry: list[dict[str, Any]],
    ts: str,
) -> list[dict[str, Any]]:
    """Issue #1809: flag a CODEX agent whose AGENTS.md instruction entrypoint is
    missing from BOTH its identity home and its workdir.

    Codex agents created before the entrypoint-materialization existed (early
    admin-pair provisioning) have no AGENTS.md anywhere, and nothing in the
    runtime ever backfilled it before this issue — the watchdog flagged
    `missing_files: AGENTS.md` forever with no remediation hook. This read-only
    detector surfaces the gap with a `suggested_action` that names the supported
    one-command fix (`agb upgrade`, which now backfills the codex AGENTS.md
    home->workdir; the daemon doc-backfill hygiene pass does the same between
    upgrades).

    ENGINE-AWARE and codex-scoped: claude/antigravity agents are NEVER flagged
    (their CLAUDE.md entrypoint is a separate, long-settled concern and may
    legitimately live home-only). The presence check mirrors the watchdog's
    home-fallback: an entrypoint present in EITHER tree is not drift. A row with
    no resolvable engine or no home AND no workdir is skipped (nothing to
    prove) — fail-safe, never a false positive.
    """
    findings: list[dict[str, Any]] = []
    for agent_id, home, workdir, engine in _iter_registry_agents(registry):
        if (engine or "").strip().lower() != "codex":
            continue
        entrypoint = _engine_entrypoint_filename(engine)
        if not entrypoint:
            continue
        present = False
        checked: list[str] = []
        for base in (workdir, home):
            if not base:
                continue
            candidate = Path(base) / entrypoint
            checked.append(str(candidate))
            if _path_lexists(candidate):
                present = True
                break
        if present or not checked:
            continue
        findings.append(
            {
                "ts": ts,
                "kind": "missing-agent-entrypoint",
                "agent": agent_id,
                "evidence": {
                    "engine": "codex",
                    "entrypoint": entrypoint,
                    "checked_paths": checked,
                    "home": home,
                    "workdir": workdir,
                    "registry_checked": "agent registry --json",
                },
                "suggested_action": (
                    f"Codex agent {agent_id} has no {entrypoint} identity "
                    "contract in its home or workdir (a pre-materialization "
                    "agent the create-time materialize never reached). Run "
                    "`agent-bridge upgrade` to backfill it from the current "
                    "template (create-if-absent home->workdir; the managed "
                    "header tracks template evolution, any custom contract "
                    "below the marker is preserved). The daemon doc-backfill "
                    "hygiene pass performs the same fix automatically between "
                    "upgrades and files one `[hygiene]` admin task when it "
                    "backfills."
                ),
            }
        )
    return findings


# --- settings single-tree invariant (#1455) --------------------------------


def _settings_tree_paths(base: str) -> tuple[Path, Path] | None:
    """Resolve the (link, effective) settings paths under a tree root.

    `base` is an agent's `home` or `workdir` (from `agent registry --json`).
    Returns `(<base>/.claude/settings.json, <base>/.claude/settings.effective.json)`
    or None when `base` is empty. Does NOT require either path to exist —
    the callers handle the missing-file case so an agent that simply has
    no rendered settings yet never trips a false positive.
    """
    base = (base or "").strip()
    if not base:
        return None
    claude_dir = Path(base).expanduser() / SETTINGS_CLAUDE_DIR
    return (claude_dir / SETTINGS_LINK_NAME, claude_dir / SETTINGS_EFFECTIVE_NAME)


def _real_settings_target(link_path: Path) -> Path | None:
    """Return the resolved real file `link_path` points at, or None.

    `link_path` is `<tree>/.claude/settings.json`. When it is a symlink we
    follow it (the invariant requires the workdir link to resolve into the
    home effective tree); when it is a plain file we treat the file itself
    as the real target. A broken symlink or a missing path returns None so
    a not-yet-rendered tree never produces a finding.

    Read-only: only `os.path.realpath` / stat — never a write.
    """
    try:
        if not link_path.exists():  # noqa: raw-pathlib-controller-only — read-only diagnostic probe; the enclosing try/except OSError swallows a PermissionError on an iso tree (the doctor degrades to "skip this agent", never crashes), so the safe-wrapper sudo escalation the lint guards against is intentionally NOT wanted here.
            # Broken symlink or absent file: no real target to compare.
            return None
        return Path(os.path.realpath(link_path))
    except OSError:
        return None


def _iter_registry_agents(
    registry: list[dict[str, Any]],
) -> list[tuple[str, str, str, str]]:
    """Yield (agent_id, home, workdir, engine) from `agent registry --json`.

    Skips rows missing an id or lacking BOTH a home and a workdir (nothing
    to compare). Mirrors the orphan detector's tolerance for partial rows.
    `engine` lets a caller scope itself to one runtime (Issue #1788: the
    settings drift detectors are Claude-tree-specific).
    """
    out: list[tuple[str, str, str, str]] = []
    for row in registry:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or "").strip()
        if not agent_id:
            continue
        home = str(row.get("home") or "").strip()
        workdir = str(row.get("workdir") or "").strip()
        if not home and not workdir:
            continue
        engine = str(row.get("engine") or "").strip()
        out.append((agent_id, home, workdir, engine))
    return out


def _settings_effective_content(real_path: Path) -> str | None:
    """Return the text content of a resolved effective settings file, or None.

    Issue #1788: the two-tree-drift detector compares the CONTENT of the two
    rendered effective files, not just their inode identity. On a shared-mode
    v2 non-isolated host the renderer DELIBERATELY maintains two effective
    files (workdir-side + launched-config-dir-side, see
    `bridge_ensure_claude_shared_settings_for_managed_workdir` in
    lib/bridge-hooks.sh) rendered from the same base+overlay — so two distinct
    inodes with IDENTICAL content is the intended healthy end state, and only
    a CONTENT divergence is the #1453 drift hazard. Read-only; any OSError
    (unreadable iso tree, race) returns None so the caller degrades to
    skip-this-agent rather than crashing.
    """
    try:
        return real_path.read_text(encoding="utf-8")
    except OSError:
        return None
    except ValueError:
        # Undecodable bytes — treat as unreadable for comparison purposes.
        return None


def detect_settings_two_tree_drift(
    registry: list[dict[str, Any]],
    ts: str,
) -> list[dict[str, Any]]:
    """Issue #1455 detector (a): home + workdir `settings.json` CONTENT diverges.

    For every CLAUDE agent whose registry row carries BOTH a `home` and a
    `workdir`, resolve `<home>/.claude/settings.json` and
    `<workdir>/.claude/settings.json` to their real files and flag the
    agent when the two real files have DIFFERENT CONTENT — the silent drift
    that lets a stale `enabledPlugins[X]=false` survive in one tree (#1453
    root cause).

    Issue #1788 — aligned to the renderer's intended layout. The renderer
    (`bridge_ensure_claude_shared_settings_for_managed_workdir`,
    lib/bridge-hooks.sh) DELIBERATELY maintains two effective files for a
    shared-mode v2 non-isolated agent: the workdir-side effective file under
    `agents/<a>/.claude/` AND the launched-config-dir effective file under
    `data/agents/<a>/home/.claude/` (registry `home`).
    Both are rendered from the same base+overlay (same channels/class), so on
    a healthy host they are TWO DISTINCT INODES WITH IDENTICAL CONTENT. The
    pre-#1788 inode-only compare flagged that intended end state for every
    Claude agent on v0.16.8 — an always-on false finding the operator could
    neither execute the recipe for nor converge. Flagging on CONTENT instead
    of inode keeps the #1453 teeth (a real divergent value still fires) while
    treating the intended dual-render as healthy.

    Cases that are NOT flagged (no false positive):
      * non-claude engines (codex's vestigial Claude tree; see Issue #1788
        Note — `agent rerender-settings` refuses codex agents anyway);
      * either tree's `settings.json` missing / not-yet-rendered;
      * both resolve to the same real file (the classic single-tree symlink);
      * both real files exist with byte-identical content (the renderer's
        intended dual-render on shared-mode v2 non-iso hosts);
      * an agent with only one of {home, workdir} (no second tree to drift
        against — covered by settings-multi-tree if it ever grows one).

    Read-only. `suggested_action` points at `agent rerender-settings <a>
    --apply`; the detector never re-renders or re-points anything itself.
    """
    findings: list[dict[str, Any]] = []
    for agent_id, home, workdir, engine in _iter_registry_agents(registry):
        if not home or not workdir:
            continue
        # Issue #1788 Note: scope to Claude agents. The settings.effective
        # tree is a Claude runtime artifact; a codex agent's tree is
        # vestigial and `agent rerender-settings` refuses it, so a finding
        # would be unactionable. Empty/unknown engine is treated as claude
        # (back-compat: a registry that predates the engine column, or a
        # fixture that omits it, keeps the prior behavior).
        if engine and engine != "claude":
            continue
        home_paths = _settings_tree_paths(home)
        work_paths = _settings_tree_paths(workdir)
        if home_paths is None or work_paths is None:
            continue
        home_link, _home_eff = home_paths
        work_link, _work_eff = work_paths
        home_real = _real_settings_target(home_link)
        work_real = _real_settings_target(work_link)
        # Need BOTH sides resolvable to claim divergence. A missing/broken
        # side is left to settings-multi-tree or simply skipped — never a
        # two-tree finding (avoids flagging a half-rendered agent).
        if home_real is None or work_real is None:
            continue
        if home_real == work_real:
            # Same inode (classic single-tree symlink) — healthy.
            continue
        # Two distinct real files. Per #1788 this is only drift when their
        # CONTENT differs; the renderer's intended dual-render produces two
        # byte-identical files. If EITHER side is unreadable we cannot prove
        # divergence — fail safe and skip (never flag on an unprovable read).
        home_content = _settings_effective_content(home_real)
        work_content = _settings_effective_content(work_real)
        if home_content is None or work_content is None:
            continue
        if home_content == work_content:
            # Intended dual-render: distinct inodes, identical content.
            continue
        try:
            work_is_symlink = work_link.is_symlink()  # noqa: raw-pathlib-controller-only — read-only evidence probe; OSError-guarded so an iso-tree PermissionError degrades to a null evidence field rather than crashing the diagnostic.
        except OSError:
            work_is_symlink = None
        evidence = {
            "home_settings": str(home_link),
            "home_resolves_to": str(home_real),
            "workdir_settings": str(work_link),
            "workdir_resolves_to": str(work_real),
            "workdir_is_symlink": work_is_symlink,
            "content_diverged": True,
        }
        suggested = (
            f"Two-tree settings CONTENT drift for {agent_id}: "
            f"{work_link} resolves to {work_real} and {home_link} resolves to "
            f"{home_real} — two real effective files with DIFFERENT content, so "
            "a preserved-user key (e.g. enabledPlugins) can drift between the "
            "trees (the #1453 signature). Re-render and re-link both trees from "
            "the single source with "
            f"`agent-bridge agent rerender-settings {agent_id} --apply` "
            "(controller-owned render; never hand-copy). Verify the finding "
            "clears on the next `agent-bridge doctor --detectors "
            "settings-two-tree-drift` run."
        )
        findings.append(
            {
                "ts": ts,
                "kind": "settings-two-tree-drift",
                "agent": agent_id,
                "evidence": evidence,
                "suggested_action": suggested,
            }
        )
    return findings


def detect_settings_multi_tree(
    registry: list[dict[str, Any]],
    ts: str,
) -> list[dict[str, Any]]:
    """Issue #1455 detector (b): effective settings physically drift across trees.

    Flags a CLAUDE agent that has a REAL (non-symlink) effective file under
    BOTH its `home/.claude/` and its `workdir/.claude/` whose CONTENTS
    DIVERGE — two physical copies that have actually drifted apart.

    Issue #1788 — aligned to the renderer's intended layout. On a shared-mode
    v2 non-isolated host the renderer authors TWO physical effective files
    (workdir-side + launched-config-dir-side) from the same base+overlay; two
    byte-identical physical copies is therefore the intended end state, not a
    violation. The pre-#1788 count-only check flagged that for every Claude
    agent on v0.16.8 — an always-on false finding with no convergent verb.
    Flagging on CONTENT divergence keeps the #1453 teeth (a genuinely drifted
    second copy still fires) while treating the renderer's dual-render as
    healthy.

    Distinct from settings-two-tree-drift: that one compares the
    `settings.json` link resolution; this one counts physical effective
    settings files. The two together cover the
    promotion-time hazard described in the issue.

    Read-only.
    """
    findings: list[dict[str, Any]] = []
    for agent_id, home, workdir, engine in _iter_registry_agents(registry):
        # Issue #1788 Note: scope to Claude agents (see two-tree-drift).
        if engine and engine != "claude":
            continue
        # Map distinct PHYSICAL file (realpath) -> a display path. Keying by
        # realpath dedupes the case where `home` and `workdir` resolve to the
        # SAME tree (identical paths, or the workdir's `.claude` parent is a
        # symlink to home's) — there the same `settings.effective.json` would
        # otherwise be counted twice and produce a false multi-tree finding.
        # Only TWO OR MORE distinct physical files is a candidate violation.
        physical: dict[str, str] = {}
        for base in (home, workdir):
            paths = _settings_tree_paths(base)
            if paths is None:
                continue
            _link, eff = paths
            try:
                # A real, physical effective file = exists AND is not a
                # symlink. A symlinked effective.json (workdir pointing at
                # home) is the HEALTHY case and must not be counted.
                if eff.is_file() and not eff.is_symlink():  # noqa: raw-pathlib-controller-only — read-only diagnostic probe; OSError-guarded (PermissionError on an iso tree falls through to `continue`, never crashing the doctor), so the sudo-escalating safe wrapper the lint guards against is intentionally not used.
                    real = os.path.realpath(eff)
                    physical.setdefault(real, str(eff))
            except OSError:
                continue
        if len(physical) < 2:
            continue
        # Issue #1788: ≥2 distinct physical files is only a violation when
        # their CONTENT diverges; the renderer's dual-render produces
        # byte-identical copies. Read each once; an unreadable file leaves its
        # content None and is treated as "unknown" — if ANY content is unknown
        # we cannot prove divergence and fail safe (skip). Otherwise flag only
        # when more than one DISTINCT content blob exists.
        real_locations = sorted(physical.values())
        contents = {
            _settings_effective_content(Path(real)) for real in physical
        }
        if None in contents:
            continue
        if len(contents) < 2:
            # All physical copies are byte-identical — the intended
            # dual-render, not drift.
            continue
        evidence = {
            "real_effective_files": real_locations,
            "count": len(real_locations),
            "content_diverged": True,
        }
        suggested = (
            f"Multi-tree settings CONTENT drift for {agent_id}: real "
            f"effective settings files in {len(real_locations)} trees "
            f"({', '.join(sorted(real_locations))}) have DIVERGED in content. "
            "Re-render and re-link both trees from the single source with "
            f"`agent-bridge agent rerender-settings {agent_id} --apply` "
            "(controller-owned render; never hand-copy). Verify the finding "
            "clears on the next `agent-bridge doctor --detectors "
            "settings-multi-tree` run."
        )
        findings.append(
            {
                "ts": ts,
                "kind": "settings-multi-tree",
                "agent": agent_id,
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
    # Issue #598 Track 2 + #1455: `agent registry --json` backs the
    # orphan-agent-dir detector AND the two settings single-tree detectors
    # (they read the home + workdir columns). Lazy-load it once when ANY of
    # those is enabled; a load failure surfaces as one detector-error per
    # affected detector (emitted lazily below) rather than failing the run.
    registry_consumers = (
        {"orphan-agent-dir", "missing-agent-entrypoint"}
        | set(SETTINGS_DETECTOR_KINDS)
    )
    if enabled_set_pre & registry_consumers:
        try:
            registry = load_agent_registry(args)
        except SystemExit as exc:
            registry = []
            registry_load_failed = True
            for consumer in sorted(enabled_set_pre & registry_consumers):
                findings.append(
                    {
                        "ts": ts,
                        "kind": "detector-error",
                        "agent": "",
                        "evidence": {
                            "detector": consumer,
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
            # Issue #2205: launchd daemon job disabled/unloaded with NO
            # recovery marker — the un-recoverable half of the 06-30 outage.
            "daemon-launchd-disabled-drift",
            lambda: detect_disabled_drift_no_marker(state_dir, ts),
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
        (
            # Issue #1809: codex agent missing its AGENTS.md entrypoint in both
            # home and workdir. Short-circuit on registry-load failure (the
            # detector-error row was already emitted above) so we never flag
            # every codex agent when the registry could not be read.
            "missing-agent-entrypoint",
            lambda: [] if registry_load_failed else detect_missing_agent_entrypoint(registry, ts),
        ),
        (
            # Issue #1455 (a): home + workdir settings.json diverge.
            "settings-two-tree-drift",
            lambda: [] if registry_load_failed else detect_settings_two_tree_drift(registry, ts),
        ),
        (
            # Issue #1455 (b): effective settings physically present in >1 tree.
            "settings-multi-tree",
            lambda: [] if registry_load_failed else detect_settings_multi_tree(registry, ts),
        ),
        (
            # Issue #1786: queue DB integrity, reachable from an agent session
            # (the policy-blessed counterpart to `verify-tasks-db`).
            "tasks-db",
            lambda: detect_tasks_db(task_db, ts),
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
                continue
            # Issue #1787: the info-level "orphan-agent-dir-unverifiable" row is
            # emitted BY the orphan-agent-dir detector (a fail-safe note when
            # samefile could not prove registration), so it rides the same
            # allow-list as its parent detector.
            if (
                kind == "orphan-agent-dir-unverifiable"
                and "orphan-agent-dir" in enabled_set
            ):
                kept.append(finding)
        findings = kept

    if args.json:
        print(json.dumps(findings, ensure_ascii=False, indent=2))
    else:
        print(render_table(findings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
