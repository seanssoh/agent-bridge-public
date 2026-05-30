#!/usr/bin/env python3
"""Render a compact Agent Bridge dashboard from roster and queue state."""

from __future__ import annotations

import argparse
import csv
import json
import os
import signal
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


PRIORITY_ORDER = {"urgent": 0, "high": 1, "normal": 2, "low": 3}

# Issue #303 Track C — queue-gardening dashboard column. The `garden` column
# surfaces blocked tasks the assignee has not refreshed (or closed) recently,
# i.e. the admin's failure mode where blocked becomes a write-only parking
# lot. Thresholds are in seconds and intentionally tracked here so future
# tuning is one place; without an ANSI color path in this dashboard we emit
# the raw stale-blocked count + `d` suffix (the issue's "yellow at 1 day, red
# at 3 days" rendering degrades to plain text).
GARDEN_STALE_SECONDS = 86400        # 1 day — yellow tier; below this, render `-`
GARDEN_CRITICAL_SECONDS = 86400 * 3  # 3 days — red tier (informational only)


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def fmt_age(ts: int | None) -> str:
    if not ts:
        return "-"
    delta = max(0, int(datetime.now(timezone.utc).timestamp()) - int(ts))
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def fmt_idle(ts: int | None) -> str:
    return fmt_age(ts)


def fmt_remaining(ts: int | None) -> str:
    if not ts:
        return "-"
    delta = int(ts) - int(datetime.now(timezone.utc).timestamp())
    if delta <= 0:
        return "due"
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def fmt_garden(blocked_count: int, oldest_blocked_ts: int | None) -> str:
    """Render the queue-gardening signal for a single agent.

    Returns `-` when the agent has no blocked tasks aged past
    GARDEN_STALE_SECONDS, and `<N>d` otherwise where N is the count of
    blocked tasks the agent owns. The `d` suffix marks "stale-blocked"
    rather than the day count itself; without an ANSI color path the
    yellow/red tier (#303 Track C) collapses to one stale tier.
    """
    if not blocked_count or not oldest_blocked_ts:
        return "-"
    age = int(datetime.now(timezone.utc).timestamp()) - int(oldest_blocked_ts)
    if age < GARDEN_STALE_SECONDS:
        return "-"
    return f"{int(blocked_count)}d"


def classify_stale(
    active: bool,
    activity_ts: int | None,
    warn_seconds: int,
    critical_seconds: int,
    source: str | None = None,
) -> str:
    # Stale-health classification is only meaningful for agents that are
    # expected to be doing autonomous work — i.e. static-source roles
    # (librarian, patch, admin, …) whose long idle is a real "broken"
    # signal. Dynamic-source agents (crm-dev, agb-dev-claude, …) are
    # operator-driven containers that the human keeps running between
    # interactive sessions; classifying their idle time as warn/crit
    # produces a constant false-positive on every healthy host. Treat
    # active dynamic agents as not-applicable ("-") so the dashboard
    # `health warn/crit` counter and the per-row column stay focused on
    # static roles that actually need attention.
    if not active:
        return "-"
    if source == "dynamic":
        return "-"
    if not activity_ts:
        return "crit"
    age = max(0, int(datetime.now(timezone.utc).timestamp()) - int(activity_ts))
    if critical_seconds > 0 and age >= critical_seconds:
        return "crit"
    if warn_seconds > 0 and age >= warn_seconds:
        return "warn"
    return "ok"


def short_path(path: str) -> str:
    if not path:
        return "-"
    expanded = str(Path(path).expanduser())
    home = str(Path.home())
    if expanded == home:
        return "~"
    if expanded.startswith(home + os.sep):
        return "~" + expanded[len(home):]
    return expanded


def workdir_display(path: str) -> str:
    # Issue #305 Track C: surface a missing workdir at the dashboard layer so a
    # leaked smoke-fixture roster block (or any deleted/renamed/expired
    # registration) is visible without opening agent-roster.local.sh manually.
    #
    # v0.8.5 #694 (Wave-3): on Linux v2 partial-isolated-agent state, a
    # broken `agent create --isolate ...` leaves `data/agents/<agent>/`
    # as `root:ab-agent-<name> mode 2750`. The controller is in the
    # group on disk but its process credentials don't include the new
    # group until re-login, so `Path.is_dir()` raises `PermissionError`
    # (errno 13) when the kernel checks the cached group set against
    # the directory's group bits. That uncaught raise crashes the
    # entire `agent-bridge status --all-agents` render. Treat any
    # OSError (PermissionError is a subclass) as "unreadable" and tag
    # the row so operators see the partial state rather than losing
    # observability of every agent on the host. The same graceful
    # pattern PR #688 added to `pending_upgrade_conflict_count`'s
    # walk; this is the second site (`row.get('workdir')` per-agent
    # row render) that issue #694 surfaced.
    short = short_path(path)
    if not path or short == "-":
        return short
    expanded = str(Path(path).expanduser())
    try:
        if not Path(expanded).is_dir():
            return f"{short}  [missing]"
    except OSError:
        return f"{short}  [unreadable]"
    return short


def read_roster(path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if row.get("agent"):
                rows.append(row)
    # Preserve BRIDGE_AGENT_IDS order from the roster snapshot so that
    # active agent index numbers match agb kill/attach numbering.
    return rows


def db_connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row["name"]) for row in conn.execute(f"PRAGMA table_info({table})")}


def daemon_status(pid_file: str) -> tuple[bool, str]:
    try:
        pid = Path(pid_file).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return (False, "-")
    except Exception:
        return (False, "?")

    if not pid:
        return (False, "-")

    try:
        os.kill(int(pid), 0)
    except OSError:
        return (False, pid)
    return (True, pid)


def read_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("'").strip('"')
        values[key.strip()] = value
    return values


def telegram_token_from_state_dir(state_dir: Path) -> str:
    relay_token = state_dir / "relay-token"
    try:
        token = relay_token.read_text(encoding="utf-8").strip()
        if token:
            return token
    except OSError:
        pass
    env = read_dotenv(state_dir / ".env")
    for key in ("TELEGRAM_BOT_TOKEN", "BOT_TOKEN", "TOKEN"):
        value = env.get(key, "").strip()
        if value:
            return value
    return ""


def plugin_items_from_workdir(workdir: str) -> list[str]:
    path = Path(workdir).expanduser() / ".mcp.json"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    servers = payload.get("mcpServers") if isinstance(payload, dict) else {}
    if not isinstance(servers, dict):
        return []
    items: list[str] = []
    for name in servers:
        if not isinstance(name, str) or not name.strip():
            continue
        if "@" in name:
            items.append(f"plugin:{name}")
        else:
            items.append(f"plugin:{name}")
    return items


def configured_plugin_items(row: dict[str, str]) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for raw in (row.get("configured_channels") or "").split(","):
        item = raw.strip()
        if not item.startswith("plugin:") or item in seen:
            continue
        seen.add(item)
        items.append(item)
    for item in plugin_items_from_workdir(row.get("workdir", "")):
        if item not in seen:
            seen.add(item)
            items.append(item)
    return items


def plugin_identity(item: str) -> tuple[str, str, str]:
    spec = item[len("plugin:"):] if item.startswith("plugin:") else item
    if "@" in spec:
        name, marketplace = spec.split("@", 1)
    else:
        name, marketplace = spec, ""
    return name, marketplace, f"plugin:{spec}"


def plugins_for_agent(row: dict[str, str]) -> list[dict[str, object]]:
    plugins: list[dict[str, object]] = []
    for item in configured_plugin_items(row):
        name, marketplace, plugin_id = plugin_identity(item)
        plugins.append(
            {
                "name": name,
                "id": plugin_id,
                "marketplace": marketplace,
                "status": "unknown",
            }
        )
    return plugins


def _audit_input_files(base: Path) -> list[Path]:
    # Mirror bridge-audit.py rotation_candidates so the dashboard counts
    # rolled-over fragments alongside the live `audit.jsonl`. Without this,
    # operators on long-running hosts whose log just rotated would see the
    # FP rate snap to 0/0 (#338 Track C — observability counter).
    files: list[Path] = []
    if base.parent.exists():
        files.extend(
            sorted(
                base.parent.glob(f"{base.stem}.*{base.suffix}"),
                key=lambda item: item.name,
            )
        )
    if base.is_file():
        files.append(base)
    return files


def context_pressure_fp_rate(audit_log: str, window_days: int = 7) -> tuple[int, int]:
    """Compute the (false-positive count, critical task count) tuple over the
    last `window_days` for `agent-bridge status` to render. Both numbers are
    derived from the JSONL audit log written by `bridge-audit.py`.

    Numerator: rows with `action=context_pressure_false_positive` (one row per
    operator-marked false-positive done; emitted by bridge-task.sh on any
    `[context-pressure] <agent> (critical)` task whose --note matches the
    "false-positive" / "HUD says <85%" markers in #338 Track C).

    Denominator: unique `task_id` values from `action=context_pressure_report`
    rows whose detail carries `severity=critical`. Counting unique task ids
    deduplicates the rebroadcast/cooldown emissions the daemon writes for the
    same critical task across syncs (issue #184 cooldown semantics) so the
    rate reflects "1 task = 1 critical event".
    """
    if not audit_log:
        return (0, 0)
    base = Path(audit_log).expanduser()
    files = _audit_input_files(base)
    if not files:
        return (0, 0)
    cutoff = datetime.now(timezone.utc) - timedelta(days=max(1, int(window_days)))
    fp_count = 0
    critical_task_ids: set[str] = set()
    for path in files:
        try:
            with path.open("r", encoding="utf-8") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict):
                        continue
                    ts_raw = record.get("ts")
                    if not isinstance(ts_raw, str):
                        continue
                    try:
                        ts_str = ts_raw[:-1] + "+00:00" if ts_raw.endswith("Z") else ts_raw
                        ts = datetime.fromisoformat(ts_str)
                    except ValueError:
                        continue
                    if ts.tzinfo is None:
                        ts = ts.replace(tzinfo=timezone.utc)
                    if ts < cutoff:
                        continue
                    action = record.get("action")
                    detail = record.get("detail") if isinstance(record.get("detail"), dict) else {}
                    if action == "context_pressure_false_positive":
                        fp_count += 1
                        continue
                    if action == "context_pressure_report" and detail.get("severity") == "critical":
                        task_id = detail.get("task_id")
                        if isinstance(task_id, (str, int)) and str(task_id):
                            critical_task_ids.add(str(task_id))
        except OSError:
            continue
    return (fp_count, len(critical_task_ids))


def pending_upgrade_conflict_count(bridge_home: str) -> int:
    """Count `*.upgrade-conflict` files under `<BRIDGE_HOME>` excluding
    archived layers (`backups/...`). Renders as the `pending
    upgrade-conflicts` warning line on the dashboard so admin agents
    can prompt cleanup before the count grows past the operator's
    notice threshold (issue #394).

    Returns 0 if the path does not exist or is not a directory; the
    counter is purely additive on healthy hosts.

    v0.8.5 #681: tolerate `PermissionError`/`OSError` raised mid-walk
    when a partial isolated agent (e.g. broken `agent create
    --isolate`) leaves a `data/agents/<agent>/workdir` subtree the
    controller cannot read. Without this guard `Path.rglob` propagates
    the first such EACCES out and crashes `agent-bridge status
    --all-agents` — operators lose dashboard observability of the very
    state they need to triage. We walk manually so a single denied
    branch only excludes that subtree, not the whole count.
    """
    if not bridge_home:
        return 0
    home = Path(bridge_home).expanduser()
    if not home.is_dir():
        return 0
    count = 0
    stack: list[Path] = [home]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except (PermissionError, OSError):
            # Partial isolated-agent state, missing dir, or any other
            # filesystem drift. Skip this subtree only — keep counting.
            continue
        for entry in entries:
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                continue
            if is_dir:
                # Prune `backups/` at the BRIDGE_HOME root before
                # descending — same exclusion the rglob/relative_to
                # branch enforced previously.
                try:
                    rel = Path(entry.path).relative_to(home).as_posix()
                except ValueError:
                    rel = ""
                if rel == "backups" or rel.startswith("backups/"):
                    continue
                stack.append(Path(entry.path))
                continue
            if entry.name.endswith(".upgrade-conflict"):
                try:
                    rel = Path(entry.path).relative_to(home).as_posix()
                except ValueError:
                    continue
                if rel.startswith("backups/"):
                    continue
                try:
                    is_file = entry.is_file(follow_symlinks=False)
                except OSError:
                    continue
                if is_file:
                    count += 1
    return count


def _parse_shell_env(path: str) -> dict[str, str]:
    """Parse a daemon-written `KEY=value` shell-state file into a dict.

    Read-only, controller-local; uses os.path.isfile + builtin open (NOT
    pathlib probes) so it adds no new lint-raw-pathlib site. Values may be
    `printf %q`-quoted (the daemon writes them that way); we strip a single
    pair of surrounding single quotes and unescape the `\\` form %q uses for a
    plain token. Only KEY=value lines are honored; anything else is skipped.
    Returns {} on a missing/unreadable file.
    """
    out: dict[str, str] = {}
    if not path or not os.path.isfile(path):
        return out
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return out
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        # %q single-quotes a value containing shell-special chars; a bare
        # token (e.g. an integer) is emitted unquoted.
        if len(val) >= 2 and val[0] == "'" and val[-1] == "'":
            val = val[1:-1]
        out[key] = val
    return out


def read_handoffd_health(state_dir: str, bridge_home: str) -> dict[str, object]:
    """Read the A2A receiver supervisor's view for the status dashboard (#1405).

    Returns a dict the renderers consume:
      {
        "configured": bool,    # handoff.local.json present (gates rendering —
                               # the row is SILENT on non-A2A installs)
        "state": str,          # running | stopped | crashloop | disabled
        "restart_count": int,
        "max_restarts": int,
        "alarm": str,          # "" | "crashloop" | "bind_proof_failed"
        "last_reason": str,    # "" | healthy | process_gone | healthz_* | ...
        "last_exit_event": str,# terminal audit event mined at last death
        "last_pid": str,       # from receiver-exit.json when down
        "has_exit_cause": bool,# receiver-exit.json present
      }

    Pure read over state/handoff/receiver-supervise.env (+ receiver-exit.json),
    written by the daemon's process_a2a_receiver_supervise_tick. No python-in-
    python, no daemon coupling — the daemon owns the writes, status only reads.
    Tolerant of every-file-absent (fresh install / never-died receiver).
    """
    # config presence — env override mirrors bridge_a2a_config_path() in the
    # shell so a non-default BRIDGE_A2A_CONFIG path is honored.
    config_path = os.environ.get("BRIDGE_A2A_CONFIG", "")
    if not config_path and bridge_home:
        config_path = os.path.join(os.path.expanduser(bridge_home), "handoff.local.json")
    configured = bool(config_path) and os.path.isfile(config_path)

    handoff_dir = os.path.join(state_dir, "handoff") if state_dir else ""
    supervise_file = os.path.join(handoff_dir, "receiver-supervise.env") if handoff_dir else ""
    exit_json = os.path.join(handoff_dir, "receiver-exit.json") if handoff_dir else ""

    env = _parse_shell_env(supervise_file)
    try:
        restart_count = int(env.get("A2A_RECEIVER_RESTART_COUNT", "0") or 0)
    except ValueError:
        restart_count = 0
    alarm = env.get("A2A_RECEIVER_ALARM", "") or ""
    last_reason = env.get("A2A_RECEIVER_LAST_REASON", "") or ""
    last_exit_event = env.get("A2A_RECEIVER_LAST_EXIT_EVENT", "") or ""

    max_restarts_env = os.environ.get("BRIDGE_A2A_RECEIVER_MAX_RESTARTS", "5")
    try:
        max_restarts = int(max_restarts_env)
    except ValueError:
        max_restarts = 5

    last_pid = ""
    has_exit_cause = bool(exit_json) and os.path.isfile(exit_json)
    if has_exit_cause:
        try:
            with open(exit_json, "r", encoding="utf-8", errors="replace") as fh:
                cause = json.load(fh)
            if isinstance(cause, dict):
                last_pid = str(cause.get("last_pid", "") or "")
        except (OSError, ValueError):
            pass

    # Derive a coarse state. The supervise.env LAST_REASON is the authoritative
    # signal (the daemon writes "healthy" on a green probe and the failure
    # reason on a death). Absence of a supervise.env means the supervisor has
    # not yet run a non-trivial tick (treat as running if configured — the
    # receiver may simply be healthy and never observed down).
    if alarm:
        state = "crashloop"
    elif last_reason and last_reason != "healthy":
        state = "stopped"
    else:
        state = "running"

    return {
        "configured": configured,
        "state": state,
        "restart_count": restart_count,
        "max_restarts": max_restarts,
        "alarm": alarm,
        "last_reason": last_reason,
        "last_exit_event": last_exit_event,
        "last_pid": last_pid,
        "has_exit_cause": has_exit_cause,
    }


def config_drift_count(audit_log: str, window_days: int = 7) -> int:
    """Count `cron_human_config_drift` and `channel_health_miss` audit rows
    over the last `window_days`. Renders as the `config-drift` line on the
    `agent-bridge status` dashboard (issue #345 Track C). The audit actions
    are emitted by bridge-daemon's cron-followup classifier and the
    channel-health-miss helper when a per-agent surface problem cannot be
    resolved by admin acting on a queue task; surfacing the count on the
    dashboard moves human-config drift out of admin's noisy inbox.
    """
    if not audit_log:
        return 0
    base = Path(audit_log).expanduser()
    files = _audit_input_files(base)
    if not files:
        return 0
    cutoff = datetime.now(timezone.utc) - timedelta(days=max(1, int(window_days)))
    drift_actions = {"cron_human_config_drift", "channel_health_miss"}
    count = 0
    for path in files:
        try:
            with path.open("r", encoding="utf-8") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict):
                        continue
                    if record.get("action") not in drift_actions:
                        continue
                    ts_raw = record.get("ts")
                    if not isinstance(ts_raw, str):
                        continue
                    try:
                        ts_str = ts_raw[:-1] + "+00:00" if ts_raw.endswith("Z") else ts_raw
                        ts = datetime.fromisoformat(ts_str)
                    except ValueError:
                        continue
                    if ts.tzinfo is None:
                        ts = ts.replace(tzinfo=timezone.utc)
                    if ts < cutoff:
                        continue
                    count += 1
        except OSError:
            continue
    return count


def nudge_recheck_observability_counts(
    audit_log: str, window_days: int = 7
) -> dict[str, int]:
    """Aggregate operator-surface counters for the daemon nudge verify path
    over the last `window_days`. Renders as the `nudge-recheck` line on the
    `agent-bridge status` dashboard (issue #1323 Track G full-closure).

    The counters surface two adjacent silent-skip / false-positive paths
    the daemon used to bury before this PR:

    - `nudge_drop_total`: total `session_nudge_dropped` rows. Pre-fix
      operators only saw the daemon_info log line ("appears dropped after
      2s"); now the rate is observable.
    - `nudge_drop_stage2_used`: subset of `session_nudge_dropped` rows
      whose `stage2_used=1` — i.e. drops that survived BOTH the stage-1
      and stage-2 grace windows. Stage-2 drops are stronger evidence of
      a real lost submit; stage-1-only drops are a stricter operator
      knob (BRIDGE_NUDGE_RECHECK_STAGE_2_SECONDS<=STAGE_1, or the
      legacy BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2=0 fallback).
    - `recheck_timeout_total`: `nudge_eligibility_recheck_timeout` rows
      (per #1323 H5 audit-row commit). The companion escalation row
      `nudge_recheck_timeout_escalated` lives in the audit log itself —
      operators following the action filter from the dashboard see both.

    Returns 0 for every key when audit_log is missing/unreachable so the
    counter stays additive on healthy / freshly installed hosts.
    """
    counts = {
        "nudge_drop_total": 0,
        "nudge_drop_stage2_used": 0,
        "recheck_timeout_total": 0,
    }
    if not audit_log:
        return counts
    base = Path(audit_log).expanduser()
    files = _audit_input_files(base)
    if not files:
        return counts
    cutoff = datetime.now(timezone.utc) - timedelta(days=max(1, int(window_days)))
    tracked_actions = {
        "session_nudge_dropped",
        "nudge_eligibility_recheck_timeout",
    }
    for path in files:
        try:
            with path.open("r", encoding="utf-8") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict):
                        continue
                    action = record.get("action")
                    if action not in tracked_actions:
                        continue
                    ts_raw = record.get("ts")
                    if not isinstance(ts_raw, str):
                        continue
                    try:
                        ts_str = ts_raw[:-1] + "+00:00" if ts_raw.endswith("Z") else ts_raw
                        ts = datetime.fromisoformat(ts_str)
                    except ValueError:
                        continue
                    if ts.tzinfo is None:
                        ts = ts.replace(tzinfo=timezone.utc)
                    if ts < cutoff:
                        continue
                    detail = record.get("detail") if isinstance(record.get("detail"), dict) else {}
                    if action == "session_nudge_dropped":
                        counts["nudge_drop_total"] += 1
                        # stage2_used is a numeric "0"/"1" detail emitted
                        # by the post-#1323 nudge_agent_session path. Pre-fix
                        # rows have no stage2_used key — they remain in
                        # nudge_drop_total but do NOT inflate the stage-2
                        # subset.
                        stage2 = detail.get("stage2_used")
                        if str(stage2) == "1":
                            counts["nudge_drop_stage2_used"] += 1
                    elif action == "nudge_eligibility_recheck_timeout":
                        counts["recheck_timeout_total"] += 1
        except OSError:
            continue
    return counts


def fetch_agent_metrics(conn: sqlite3.Connection) -> dict[str, dict[str, int | str | None]]:
    agent_state_columns = table_columns(conn, "agent_state")
    nudge_fail_expr = (
        "COALESCE(agent_state.nudge_fail_count, 0) AS nudge_fail_count"
        if "nudge_fail_count" in agent_state_columns
        else "0 AS nudge_fail_count"
    )
    zombie_expr = (
        "COALESCE(agent_state.zombie, 0) AS zombie"
        if "zombie" in agent_state_columns
        else "0 AS zombie"
    )
    sql = """
      WITH assigned AS (
        SELECT
          assigned_to AS agent,
          SUM(CASE WHEN status = 'queued' THEN 1 ELSE 0 END) AS queued_count,
          SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) AS blocked_count,
          MIN(CASE WHEN status = 'blocked' THEN updated_ts END) AS oldest_blocked_ts
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
        agent_state.agent,
        COALESCE(assigned.queued_count, 0) AS queued_count,
        COALESCE(assigned.blocked_count, 0) AS blocked_count,
        assigned.oldest_blocked_ts AS oldest_blocked_ts,
        COALESCE(claimed.claimed_count, 0) AS claimed_count,
        COALESCE(agent_state.active, 0) AS active,
        agent_state.last_seen_ts,
        agent_state.last_heartbeat_ts,
        agent_state.session_activity_ts,
        agent_state.last_nudge_ts,
        {nudge_fail_expr},
        {zombie_expr}
      FROM agent_state
      LEFT JOIN assigned ON assigned.agent = agent_state.agent
      LEFT JOIN claimed ON claimed.agent = agent_state.agent
    """.format(nudge_fail_expr=nudge_fail_expr, zombie_expr=zombie_expr)
    data: dict[str, dict[str, int | str | None]] = {}
    for row in conn.execute(sql):
        data[row["agent"]] = {
            "queued_count": row["queued_count"],
            "blocked_count": row["blocked_count"],
            "oldest_blocked_ts": row["oldest_blocked_ts"],
            "claimed_count": row["claimed_count"],
            "active": row["active"],
            "last_seen_ts": row["last_seen_ts"],
            "last_heartbeat_ts": row["last_heartbeat_ts"],
            "session_activity_ts": row["session_activity_ts"],
            "last_nudge_ts": row["last_nudge_ts"],
            "nudge_fail_count": row["nudge_fail_count"],
            "zombie": row["zombie"],
        }
    return data


def fetch_totals(conn: sqlite3.Connection) -> dict[str, int]:
    sql = """
      SELECT
        SUM(CASE WHEN status = 'queued' THEN 1 ELSE 0 END) AS queued_count,
        SUM(CASE WHEN status = 'claimed' THEN 1 ELSE 0 END) AS claimed_count,
        SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) AS blocked_count,
        SUM(CASE WHEN status = 'queued' AND priority = 'urgent' THEN 1 ELSE 0 END) AS urgent_count,
        SUM(CASE WHEN status = 'claimed' AND lease_until_ts IS NOT NULL AND lease_until_ts < strftime('%s', 'now') THEN 1 ELSE 0 END) AS overdue_count
      FROM tasks
    """
    row = conn.execute(sql).fetchone()
    return {
        "queued_count": int(row["queued_count"] or 0),
        "claimed_count": int(row["claimed_count"] or 0),
        "blocked_count": int(row["blocked_count"] or 0),
        "urgent_count": int(row["urgent_count"] or 0),
        "overdue_count": int(row["overdue_count"] or 0),
    }


def fetch_open_tasks(conn: sqlite3.Connection, limit: int) -> list[sqlite3.Row]:
    sql = """
      SELECT id, assigned_to, status, priority, title, created_by, claimed_by, updated_ts, lease_until_ts
      FROM tasks
      WHERE status IN ('queued', 'claimed', 'blocked')
      ORDER BY
        CASE priority
          WHEN 'urgent' THEN 0
          WHEN 'high' THEN 1
          WHEN 'normal' THEN 2
          WHEN 'low' THEN 3
          ELSE 4
        END,
        CASE status
          WHEN 'claimed' THEN 0
          WHEN 'queued' THEN 1
          ELSE 2
        END,
        updated_ts DESC,
        id DESC
      LIMIT ?
    """
    return list(conn.execute(sql, (limit,)))


def render_bar(value: int, width: int = 10, char: str = "#") -> str:
    capped = min(max(0, value), width)
    return char * capped + "." * (width - capped)


def render_dashboard(args: argparse.Namespace) -> str:
    roster = read_roster(args.roster_snapshot)
    queue_db = Path(args.db)
    daemon_running, daemon_pid = daemon_status(args.daemon_pid_file)

    metrics: dict[str, dict[str, int | str | None]] = {}
    totals = {
        "queued_count": 0,
        "claimed_count": 0,
        "blocked_count": 0,
        "urgent_count": 0,
        "overdue_count": 0,
    }
    open_tasks: list[sqlite3.Row] = []

    if queue_db.exists():
        with db_connect(str(queue_db)) as conn:
            metrics = fetch_agent_metrics(conn)
            totals = fetch_totals(conn)
            open_tasks = fetch_open_tasks(conn, args.open_limit)

    full_total_agents = len(roster)
    full_active_count = sum(1 for row in roster if str(row.get("active", "0")) == "1")
    health_warn_count = 0
    health_critical_count = 0
    wake_missing_count = sum(1 for row in roster if row.get("wake") == "miss")
    channel_missing_count = sum(1 for row in roster if row.get("channels") == "miss")
    zombie_count = sum(1 for metric in metrics.values() if int(metric.get("zombie", 0) or 0) == 1)
    channel_warning_rows = [
        row
        for row in roster
        if row.get("channels") == "miss"
    ]
    # #1405: A2A receiver supervisor health. Read-only over the daemon-written
    # supervise state; rendered only on A2A-configured installs (silent
    # otherwise). `a2a_flag` is the header summary token (ALARM/DOWN), empty
    # when healthy/disabled so non-A2A hosts stay quiet.
    handoffd_health = read_handoffd_health(args.bridge_state_dir, args.bridge_home or "")
    a2a_flag = ""
    if handoffd_health["configured"]:
        if handoffd_health["state"] == "crashloop":
            a2a_flag = " | a2a=ALARM"
        elif handoffd_health["state"] == "stopped":
            a2a_flag = " | a2a=DOWN"

    for row in roster:
        metric = metrics.get(row["agent"], {})
        active = str(row.get("active", "0")) == "1"
        activity_ts = metric.get("session_activity_ts") or metric.get("last_seen_ts")
        stale = classify_stale(
            active,
            int(activity_ts) if activity_ts else None,
            args.stale_warn_seconds,
            args.stale_critical_seconds,
            source=str(row.get("source", "")) or None,
        )
        if stale == "warn":
            health_warn_count += 1
        elif stale == "crit":
            health_critical_count += 1

    if not args.all_agents:
        # Issue #714 (#6): static-source agents must remain visible in the
        # default dashboard even when they have no tmux session — otherwise a
        # post-upgrade host where every static restart failed silently looks
        # like total roster loss. Dynamic agents that have died still get
        # filtered out, so this only surfaces roster-declared static roles.
        roster = [
            row
            for row in roster
            if str(row.get("active", "0")) == "1"
            or str(row.get("source", "")) == "static"
            or int(metrics.get(row["agent"], {}).get("queued_count", 0) or 0) > 0
            or int(metrics.get(row["agent"], {}).get("claimed_count", 0) or 0) > 0
            or int(metrics.get(row["agent"], {}).get("blocked_count", 0) or 0) > 0
        ]

    plugins_by_agent = {
        row["agent"]: plugins_for_agent(row)
        for row in roster
    }
    visible_agents = len(roster)

    lines: list[str] = []
    title = "Agent Bridge Status"
    if args.version:
        title += f" v{args.version}"
    lines.append(title)
    lines.append(
        f"updated {iso_now()} | daemon {'running' if daemon_running else 'stopped'} pid={daemon_pid} | "
        f"active {full_active_count}/{full_total_agents} | shown {visible_agents} | "
        f"health warn={health_warn_count} crit={health_critical_count} | wake miss={wake_missing_count} | channel miss={channel_missing_count} | zombie={zombie_count}{a2a_flag} | db {queue_db}"
    )
    lines.append("")
    lines.append(
        "Totals  "
        f"queued {totals['queued_count']} [{render_bar(totals['queued_count'])}]  "
        f"claimed {totals['claimed_count']} [{render_bar(totals['claimed_count'])}]  "
        f"blocked {totals['blocked_count']} [{render_bar(totals['blocked_count'])}]  "
        f"urgent {totals['urgent_count']}  overdue {totals['overdue_count']}  "
        f"health warn>={fmt_age(int(datetime.now(timezone.utc).timestamp()) - args.stale_warn_seconds) if args.stale_warn_seconds > 0 else 'off'} "
        f"crit>={fmt_age(int(datetime.now(timezone.utc).timestamp()) - args.stale_critical_seconds) if args.stale_critical_seconds > 0 else 'off'}"
    )
    # Issue #338 Track C — observability counter for the context-pressure
    # analyzer. Hidden when the denominator is zero (no critical task in the
    # rolling window, nothing to report); operators on healthy hosts should
    # not see a noisy `0/0` line. When the denominator is non-zero the line
    # always renders, even with `0` numerator, so an analyzer that just
    # stopped mis-firing is visibly distinct from one that never has.
    fp_window_days = max(1, int(args.fp_window_days))
    fp_count, critical_count = context_pressure_fp_rate(args.audit_log, fp_window_days)
    if critical_count > 0:
        pct = int(round(100.0 * fp_count / critical_count))
        lines.append(
            f"context-pressure FP rate ({fp_window_days}d): "
            f"{fp_count}/{critical_count} ({pct}%)"
        )
    # Issue #345 Track C — config-drift counter. Aggregates
    # `cron_human_config_drift` and `channel_health_miss` audit rows over
    # the rolling `--config-drift-window-days` window so operators see
    # human-config drift without it polluting admin's queue.
    drift_window_days = max(1, int(args.config_drift_window_days))
    drift_count = config_drift_count(args.audit_log, drift_window_days)
    if drift_count > 0:
        lines.append(
            f"config-drift ({drift_window_days}d): {drift_count}"
        )
    # Issue #1323 (v0.15.0-beta5-2 Track G follow-up) — nudge verify
    # observability counters. Pre-fix the daemon's verify grace dropped
    # an info-level log line per false positive and never surfaced; the
    # operator was left guessing whether the agent was actually stalled.
    # Render the rolling-window count when ANY of the underlying audit
    # rows fired so a healthy host (zero of every signal) stays quiet.
    nudge_window_days = max(1, int(args.nudge_recheck_window_days))
    nudge_recheck = nudge_recheck_observability_counts(args.audit_log, nudge_window_days)
    if any(v > 0 for v in nudge_recheck.values()):
        lines.append(
            f"nudge-recheck ({nudge_window_days}d): "
            f"drop_total={nudge_recheck['nudge_drop_total']} "
            f"drop_stage2_used={nudge_recheck['nudge_drop_stage2_used']} "
            f"recheck_timeout={nudge_recheck['recheck_timeout_total']}"
        )
    # Issue #394: pending upgrade-conflict count. The dashboard threshold
    # defaults to 1 (any pending file → warn); operators on chronically
    # drift-heavy hosts can raise it via
    # BRIDGE_UPGRADE_CONFLICT_WARN_THRESHOLD or the explicit CLI flag.
    pending_conflict_threshold = max(1, int(args.upgrade_conflict_warn_threshold))
    pending_conflicts = pending_upgrade_conflict_count(args.bridge_home or "")
    if pending_conflicts >= pending_conflict_threshold:
        lines.append(
            f"WARNING: {pending_conflicts} pending upgrade-conflict file(s); "
            "review with 'agent-bridge upgrade conflicts list'"
        )
    lines.append("")
    lines.append("Agents")
    lines.append("  #  agent           eng     src     loop on  state           q   c   b   garden  idle  stale wake chan  nudge  load        session        workdir")

    active_index = 0
    for row in roster:
        agent = row["agent"]
        metric = metrics.get(agent, {})
        active = str(row.get("active", "0")) == "1"
        if active:
            active_index += 1
            idx_label = f"{active_index:>3}"
        else:
            idx_label = "  -"
        queued = int(metric.get("queued_count", 0) or 0)
        claimed = int(metric.get("claimed_count", 0) or 0)
        blocked = int(metric.get("blocked_count", 0) or 0)
        oldest_blocked_ts = metric.get("oldest_blocked_ts")
        garden_str = fmt_garden(
            blocked,
            int(oldest_blocked_ts) if oldest_blocked_ts else None,
        )
        activity_ts = metric.get("session_activity_ts") or metric.get("last_seen_ts")
        last_nudge_ts = metric.get("last_nudge_ts")
        zombie = int(metric.get("zombie", 0) or 0)
        activity_state = row.get("activity_state") or ("stopped" if not active else "working")
        channel_state = row.get("channels") or "-"
        stale = classify_stale(
            active,
            int(activity_ts) if activity_ts else None,
            args.stale_warn_seconds,
            args.stale_critical_seconds,
            source=str(row.get("source", "")) or None,
        )
        load_bar = f"q:{render_bar(queued, width=4, char='=')} c:{render_bar(claimed, width=4, char='*')}"
        wake_state = "zmb" if zombie else (row.get("wake") or "-")
        # Issue #835 Wave B: column width bumped from 7 to 8 chars so the
        # new "starting" state (tmux present, engine descendant not yet
        # spawned in pane process tree) renders without truncation
        # alongside the legacy "stopped"/"idle"/"working" values.
        # Issue #1319 (Lane κ v0.15.0-beta5-2): bumped from 8 to 14 chars
        # so the new "picker_blocked" state (rate-limit / summary picker
        # detected by bridge-stall.py) renders without truncation. The
        # header on line 731 was widened in lockstep so the column
        # boundary stays aligned with the underlying value width.
        lines.append(
            f"{idx_label}  {agent:<15} {row['engine']:<7} "
            f"{(row.get('source') or '-')[:7]:<7} "
            f"{str(row.get('loop') or '-')[:4]:<4} "
            f"{'yes' if active else 'no ':<3} "
            f"{activity_state:<14} "
            f"{queued:>2}  {claimed:>2}  {blocked:>2}  "
            f"{garden_str:>6}  "
            f"{fmt_idle(int(activity_ts) if activity_ts else None):>4}  "
            f"{stale:>5} "
            f"{wake_state:>6} "
            f"{channel_state:>4} "
            f"{fmt_age(int(last_nudge_ts) if last_nudge_ts else None):>5}  "
            f"{load_bar:<12}  "
            f"{(row.get('session') or '-')[:12]:<12}  {workdir_display(row.get('workdir', ''))}"
        )

    if channel_warning_rows:
        lines.append("")
        lines.append("Channel Warnings")
        for row in channel_warning_rows[:8]:
            reason = (row.get("channel_reason") or "unknown channel mismatch").strip()
            lines.append(f"- {row['agent']}: {reason}")
        if len(channel_warning_rows) > 8:
            lines.append(f"- ... +{len(channel_warning_rows) - 8} more")

    plugin_lines: list[str] = []
    for row in roster:
        plugins = plugins_by_agent.get(row["agent"], [])
        if not plugins:
            continue
        rendered = []
        for plugin in plugins:
            name = str(plugin.get("name") or plugin.get("id") or "plugin")
            status = str(plugin.get("status") or "unknown")
            extra = ""
            if plugin.get("token_hash"):
                clients = plugin.get("connected_clients", 0)
                extra = f" hash={plugin['token_hash']} clients={clients}"
            rendered.append(f"{name}={status}{extra}")
        if rendered:
            plugin_lines.append(f"- {row['agent']}: {', '.join(rendered)}")
    if plugin_lines:
        lines.append("")
        lines.append("Plugin Liveness")
        lines.extend(plugin_lines[:12])
        if len(plugin_lines) > 12:
            lines.append(f"- ... +{len(plugin_lines) - 12} more")

    # #1405: A2A receiver health row — rendered only when handoff.local.json
    # exists (silent on non-A2A installs, the common case). Surfaces the
    # silent "send-OK / receive-dead" half state the issue reported.
    if handoffd_health["configured"]:
        lines.append("")
        lines.append("A2A Receiver")
        hh = handoffd_health
        if hh["state"] == "crashloop":
            window = os.environ.get("BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS", "600")
            lines.append(
                f"  A2A receiver  !! ALARM crash-loop "
                f"({hh['restart_count']} restarts/{window}s) — "
                f"auto-restart STOPPED; see receiver-exit.json"
            )
        elif hh["state"] == "stopped":
            last_exit = f" last_exit={hh['last_exit_event']}" if hh["last_exit_event"] else ""
            pid_note = f" (last pid {hh['last_pid']})" if hh["last_pid"] else ""
            lines.append(
                f"  A2A receiver  !! DOWN — reason={hh['last_reason'] or 'unknown'}"
                f"{last_exit} restarts={hh['restart_count']}/{hh['max_restarts']}{pid_note}"
            )
        else:
            lines.append("  A2A receiver  running healthy")

    lines.append("")
    lines.append("Open Tasks")
    if not open_tasks:
        lines.append("(no queued or claimed tasks)")
    else:
        lines.append("id  pri     status   to              owner           age   lease  title")
        for task in open_tasks:
            owner = task["claimed_by"] or task["created_by"]
            lines.append(
                f"{task['id']:<3} {task['priority']:<7} {task['status']:<8} "
                f"{task['assigned_to']:<15} {owner:<14} {fmt_age(task['updated_ts']):>4}  "
                f"{fmt_remaining(task['lease_until_ts']):>5}  {task['title']}"
            )

    if args.footer:
        lines.append("")
        lines.append(args.footer)

    return "\n".join(lines)


def render_dashboard_json(args: argparse.Namespace) -> str:
    roster = read_roster(args.roster_snapshot)
    queue_db = Path(args.db)
    daemon_running, daemon_pid = daemon_status(args.daemon_pid_file)
    metrics: dict[str, dict[str, int | str | None]] = {}
    totals = {
        "queued_count": 0,
        "claimed_count": 0,
        "blocked_count": 0,
        "urgent_count": 0,
        "overdue_count": 0,
    }
    if queue_db.exists():
        with db_connect(str(queue_db)) as conn:
            metrics = fetch_agent_metrics(conn)
            totals = fetch_totals(conn)

    agents: dict[str, object] = {}
    for row in roster:
        agent = row["agent"]
        metric = metrics.get(agent, {})
        active = str(row.get("active", "0")) == "1"
        activity_ts = metric.get("session_activity_ts") or metric.get("last_seen_ts")
        agents[agent] = {
            "agent": agent,
            "engine": row.get("engine") or "",
            "session": row.get("session") or "",
            "workdir": row.get("workdir") or "",
            "source": row.get("source") or "",
            "loop": row.get("loop") or "",
            "active": active,
            "activity_state": row.get("activity_state") or ("stopped" if not active else "working"),
            "wake": row.get("wake") or "-",
            "channel_status": row.get("channels") or "-",
            "channel_reason": row.get("channel_reason") or "",
            "configured_channels": row.get("configured_channels") or "",
            "queue": {
                "queued": int(metric.get("queued_count", 0) or 0),
                "claimed": int(metric.get("claimed_count", 0) or 0),
                "blocked": int(metric.get("blocked_count", 0) or 0),
            },
            "activity": {
                "last_seen_ts": metric.get("last_seen_ts"),
                "last_heartbeat_ts": metric.get("last_heartbeat_ts"),
                "session_activity_ts": metric.get("session_activity_ts"),
                "stale": classify_stale(
                    active,
                    int(activity_ts) if activity_ts else None,
                    args.stale_warn_seconds,
                    args.stale_critical_seconds,
                    source=str(row.get("source", "")) or None,
                ),
            },
            "plugins": plugins_for_agent(row),
        }

    nudge_window_days = max(1, int(args.nudge_recheck_window_days))
    nudge_recheck = nudge_recheck_observability_counts(args.audit_log, nudge_window_days)
    payload = {
        "updated_at": iso_now(),
        "version": args.version,
        "daemon": {
            "running": daemon_running,
            "pid": daemon_pid,
        },
        "totals": totals,
        "agents": agents,
        # Issue #394: structured surface for the pending upgrade-conflict
        # count so JSON consumers (dashboard / admin-bot / smoke) can
        # observe the same number the human-facing warning line emits.
        "pending_upgrade_conflicts": pending_upgrade_conflict_count(args.bridge_home or ""),
        # Issue #1405: A2A receiver supervisor health. JSON consumers (the
        # 1405 smoke, admin-bot) observe the same state the human dashboard
        # renders. Always emitted; `configured: false` on non-A2A installs.
        "a2a_receiver": read_handoffd_health(args.bridge_state_dir, args.bridge_home or ""),
        # Issue #1323 Track G — same audit-derived nudge-verify counters
        # the human-facing dashboard renders. JSON consumers (smoke
        # `1323-nudge-eligibility-recheck-twostage.sh`, future admin-bot)
        # observe the same numbers so the regression contract is
        # observable end-to-end. window_days is always emitted so a
        # consumer parsing on a fresh install with zero rows sees a
        # well-formed payload.
        "nudge_recheck": {
            "window_days": nudge_window_days,
            **nudge_recheck,
        },
    }
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-status.py")
    parser.add_argument("--roster-snapshot", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--daemon-pid-file", required=True)
    parser.add_argument("--bridge-state-dir", required=True)
    parser.add_argument("--audit-log", default="")
    parser.add_argument(
        "--fp-window-days",
        type=int,
        default=7,
        help="Rolling window for the context-pressure FP-rate dashboard line (#338 Track C).",
    )
    parser.add_argument(
        "--config-drift-window-days",
        type=int,
        default=7,
        help="Rolling window for the config-drift dashboard line (#345 Track C).",
    )
    parser.add_argument(
        "--nudge-recheck-window-days",
        type=int,
        default=7,
        help=(
            "Rolling window for the nudge-recheck dashboard line "
            "(#1323 Track G — drop/stage2/recheck_timeout counters)."
        ),
    )
    parser.add_argument("--version", default="")
    parser.add_argument("--open-limit", type=int, default=8)
    parser.add_argument("--stale-warn-seconds", type=int, default=3600)
    parser.add_argument("--stale-critical-seconds", type=int, default=14400)
    # Issue #394: dashboard reaches into BRIDGE_HOME to count pending
    # `*.upgrade-conflict` files. Optional — when absent, the warning
    # line and JSON counter both report zero (counter falls back to no
    # scan rather than guessing the path).
    parser.add_argument("--bridge-home", default="")
    parser.add_argument(
        "--upgrade-conflict-warn-threshold",
        type=int,
        default=int(os.environ.get("BRIDGE_UPGRADE_CONFLICT_WARN_THRESHOLD", "1") or 1),
        help="Emit the pending upgrade-conflict warning when count >= this (default 1).",
    )
    parser.add_argument("--footer", default="")
    parser.add_argument("--all-agents", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if args.json:
        print(render_dashboard_json(args))
    else:
        print(render_dashboard(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
