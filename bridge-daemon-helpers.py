#!/usr/bin/env python3
"""Daemon-loop subprocess helpers — issue #800 Track A.

Background
==========

The daemon main loop in ``bridge-daemon.sh`` historically had ~9 callsites of
the shape::

    foo="$(python3 - "$arg1" "$arg2" <<'PY'
    ... python body ...
    PY
    )"

Issue #800 documented a 34-hour silent hang of the daemon main loop traced to
nested ``$()`` command substitutions wedged in the bash ``heredoc_write``
plumbing — the leaf bash frame was blocked writing the heredoc body into a
pipe whose far end (a python3 subprocess that had stalled on sqlite or IO)
never drained. Wrapping the call in ``timeout(1)`` is necessary but NOT
sufficient: the external timeout(1) wraps the python child, but bash itself
can stall in ``do_redirection_internal → heredoc_write`` BEFORE the python
process ever launches.

The fix is to move every such body OUT of ``<<'PY'`` stdin and into either:

  - a checked-in helper subcommand (this file), invoked as
    ``python3 bridge-daemon-helpers.py <subcommand> <args...>``, OR
  - a ``python3 -c "$SCRIPT"`` invocation where the body is read into a
    shell variable via heredoc-assignment (which is synchronous and cannot
    deadlock with a concurrent reader).

The wrapping helper ``bridge_with_timeout`` (lib/bridge-state.sh) supplies
the ceiling and emits a ``daemon_subprocess_timeout`` audit row on hit.

Subcommand contract
===================

Each subcommand:

* Takes positional args matching the original ``python3 - "$a" "$b"`` shape.
* Prints the same stdout shape the original heredoc body produced (typically
  tab-separated rows, one per line).
* Exits 0 on success even when there is nothing to print (the bash side
  treats empty stdout as "no rows" via ``[[ -n ... ]]`` guards).
* Exits non-zero only when the caller should treat the invocation as
  failed — this preserves the existing ``|| true`` / ``|| return 1``
  semantics at the bash callsites.

The subcommands are intentionally tiny and pure-functional. They do not
import any agent-bridge runtime modules and they do not open the queue DB
unless the bash callsite already passed a DB path on argv.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Subcommand implementations.
# ---------------------------------------------------------------------------


def cmd_usage_alert_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1009 (process_usage_monitor).

    Extracts alert tuples from the usage-monitor JSON for shell consumption.
    Output: one tab-separated row per alert (9 cols):
      provider \\t account \\t window \\t bucket \\t used_percent \\t reset_at \\t source \\t agent \\t message

    Issue #831: `agent` is the new 8th column, inserted BEFORE message so the
    daemon callsite's existing `IFS=$'\\t' read ... source body` continues to
    work when treating message as the trailing free-form field — but the
    callsite must list `agent` between `source` and `body` to surface it.
    Placing `message` last keeps its existing role as the absorbed
    trailing-content slot in shell readers that mismatch the column count.
    """
    try:
        payload = json.loads(args.monitor_json)
    except Exception:
        return 1

    for alert in payload.get("alerts", []) or []:
        print(
            "\t".join(
                [
                    str(alert.get("provider", "")),
                    str(alert.get("account", "")),
                    str(alert.get("window", "")),
                    str(alert.get("bucket", "")),
                    str(alert.get("used_percent", "")),
                    str(alert.get("reset_at", "")),
                    str(alert.get("source", "")),
                    str(alert.get("agent", "")),
                    str(alert.get("message", "")),
                ]
            )
        )
    return 0


def cmd_release_alert_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1096 (process_release_monitor).

    Extracts the first release alert's headline fields. Output (a single row):
      latest_tag \\t latest_version \\t release_name \\t published_at \\t html_url
    Empty stdout when there are no alerts; the bash callsite treats that as
    "nothing to report" via a ``[[ -n "$alert_row" ]] || return 1`` guard.
    """
    payload = json.loads(args.monitor_json)
    alerts = payload.get("alerts") or []
    if not alerts:
        return 0
    alert = alerts[0]
    print(
        "\t".join(
            [
                str(alert.get("latest_tag") or ""),
                str(alert.get("latest_version") or ""),
                str(alert.get("release_name") or ""),
                str(alert.get("published_at") or ""),
                str(alert.get("html_url") or ""),
            ]
        )
    )
    return 0


def cmd_backup_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1210 (process_daily_backup).

    Parses the daily-backup-live JSON envelope. Output (a single row):
      outcome \\t error_detail \\t archive_path \\t pruned_count \\t free_bytes \\t needed_bytes

    On JSON-parse error the original emitted ``PARSE_ERROR\\t<repr>\\t...``
    rather than failing — the bash callsite then surfaces a parse failure
    reason through ``bridge_note_daily_backup_failure``. Preserved here.
    """
    try:
        payload = json.loads(args.backup_json)
    except Exception as exc:
        print(f"PARSE_ERROR\t{type(exc).__name__}: {exc}\t\t\t\t")
        return 0
    outcome = str(payload.get("outcome") or "")
    archive_path = str(payload.get("archive_path") or "")
    pruned = payload.get("pruned") or []
    free_bytes = payload.get("free_bytes") or 0
    needed_bytes = payload.get("needed_bytes") or 0
    error_detail = str(payload.get("error_detail") or "")
    print(
        "\t".join(
            [
                outcome,
                error_detail,
                archive_path,
                str(len(pruned)),
                str(free_bytes),
                str(needed_bytes),
            ]
        )
    )
    return 0


def cmd_stall_iso_format(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1455 (bridge_write_stall_report_body).

    Converts a POSIX timestamp (seconds) to a localized ISO-8601 string.
    Empty argv or non-numeric input → empty stdout (matches the original).
    """
    try:
        ts = int(args.first_detected_ts)
    except Exception:
        ts = 0
    if ts > 0:
        print(datetime.fromtimestamp(ts, timezone.utc).astimezone().isoformat())
    return 0


def cmd_permission_expire_scan(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1948 (permission task fanout).

    Filters the open-permission-tasks JSON to rows whose age exceeds the
    timeout. Output:
      task_id \\t age_seconds \\t created_by \\t status \\t title
    JSON parse failure exits 0 with empty stdout (matches original).
    """
    try:
        tasks = json.loads(args.tasks_json)
    except Exception:
        return 0
    try:
        now_ts = int(args.now_ts)
        timeout = int(args.timeout_seconds)
    except Exception:
        return 0
    for t in tasks or []:
        created_ts = int(t.get("created_ts", 0) or 0)
        if created_ts <= 0:
            continue
        age = now_ts - created_ts
        if age < timeout:
            continue
        tid = int(t.get("id", 0) or 0)
        title = str(t.get("title", "")).replace("\t", " ")
        status = str(t.get("status", ""))
        created_by = str(t.get("created_by", ""))
        print(f"{tid}\t{age}\t{created_by}\t{status}\t{title}")
    return 0


def cmd_watchdog_problem_count(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:2318 (process_watchdog_report).

    Extracts the integer ``problem_count`` field. Always prints a single
    integer to stdout — defaulting to 0 on parse error — so the bash side
    can read it unconditionally.
    """
    try:
        payload = json.loads(args.report_json)
        print(int(payload.get("problem_count", 0)))
    except Exception:
        print(0)
    return 0


def cmd_nudge_live_state(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:2728 (nudge_agent_session).

    HIGHEST-IMPACT site per #800. Reads the queue DB for an agent's live
    queued/claimed counts. Output (single row):
      queued_count \\t claimed_count \\t comma_separated_queued_ids

    sqlite errors fall through to a non-zero exit so the bash callsite's
    ``|| true`` keeps the loop intact; the wrapper applies a 15s timeout
    with audit-only fallback (no inline retry — next tick retries naturally).
    """
    db_path = args.db_path
    agent = args.agent
    with sqlite3.connect(db_path) as conn:
        queued_ids = [
            str(row[0])
            for row in conn.execute(
                """
                SELECT id
                FROM tasks
                WHERE assigned_to = ?
                  AND status = 'queued'
                  AND title NOT LIKE '[cron-dispatch]%'
                ORDER BY id
                """,
                (agent,),
            ).fetchall()
        ]
        claimed_count = conn.execute(
            "SELECT COUNT(*) FROM tasks WHERE claimed_by = ? AND status = 'claimed'",
            (agent,),
        ).fetchone()[0]
    print(f"{len(queued_ids)}\t{claimed_count}\t{','.join(queued_ids)}")
    return 0


def cmd_nudge_eligibility_recheck(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh::nudge_agent_session (issue #1106).

    Issue #1106 (beta7 follow-up from PR #1103): the Python daemon-step
    nudge candidate emitter applies a task-level age gate against
    ``BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS``, but the shell-side
    ``nudge_agent_session`` then re-queries the LIVE queued-id set via
    ``cmd_nudge_live_state`` to compute ``live_nudge_key`` and decide
    whether to dispatch. If, between the Python step and the shell
    fanout, the aged task that made the Python step emit a candidate
    is claimed/done by another worker AND a fresh queued task remains,
    the shell currently fires an ACTION REQUIRED nudge for a
    fresh-only live queue (race window narrower than #1099 but
    observable).

    This helper re-applies the task-level age gate at shell dispatch
    time. Output (single row):
      eligible_count \\t comma_separated_eligible_queued_ids

    ``eligible`` ≡ row in ``tasks`` with status='queued', assigned to
    the agent, title NOT LIKE '[cron-dispatch]%', AND
    ``created_ts <= (now - redelivery_seconds)``.

    Contract knob: ``redelivery_seconds <= 0`` disables the gate
    (preserves pre-#1019 behavior) — every queued id is reported
    eligible, matching the Python emitter's ``not eligible_queue_ids``
    short-circuit semantics.

    sqlite errors fall through to a non-zero exit so the bash
    callsite's ``|| true`` keeps the loop intact; the wrapper applies
    a 15s timeout with audit-only fallback.
    """
    db_path = args.db_path
    agent = args.agent
    try:
        redelivery_seconds = int(args.redelivery_seconds)
    except (TypeError, ValueError):
        redelivery_seconds = 0
    now_ts = int(datetime.now(timezone.utc).timestamp())
    cutoff_ts = now_ts - max(0, redelivery_seconds)
    with sqlite3.connect(db_path) as conn:
        if redelivery_seconds > 0:
            rows = conn.execute(
                """
                SELECT id
                FROM tasks
                WHERE assigned_to = ?
                  AND status = 'queued'
                  AND title NOT LIKE '[cron-dispatch]%'
                  AND created_ts <= ?
                ORDER BY id
                """,
                (agent, cutoff_ts),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT id
                FROM tasks
                WHERE assigned_to = ?
                  AND status = 'queued'
                  AND title NOT LIKE '[cron-dispatch]%'
                ORDER BY id
                """,
                (agent,),
            ).fetchall()
    eligible_ids = [str(row[0]) for row in rows]
    print(f"{len(eligible_ids)}\t{','.join(eligible_ids)}")
    return 0


def cmd_memory_daily_orphan_scan(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:4840 (process_memory_daily_orphan_sweep).

    Diffs the cron-inventory JSON against the in-process roster and emits
    one ``job_id\\tsource_agent`` row per orphaned ``memory-daily-<agent>``
    job whose source agent is no longer loaded.
    """
    raw_jobs = args.jobs_json or ""
    raw_roster = args.roster_stream or ""
    roster = {line.strip() for line in raw_roster.splitlines() if line.strip()}
    try:
        payload = json.loads(raw_jobs)
    except Exception:
        return 0

    jobs = payload.get("jobs") if isinstance(payload, dict) else payload
    if not isinstance(jobs, list):
        return 0

    prefix = "memory-daily-"
    for job in jobs:
        if not isinstance(job, dict):
            continue
        if (job.get("family") or "") != "memory-daily":
            continue
        name = job.get("name") or ""
        if not name.startswith(prefix):
            continue
        source_agent = name[len(prefix):].strip()
        if not source_agent:
            continue
        if source_agent in roster:
            continue
        job_id = job.get("id") or job.get("name") or ""
        if not job_id:
            continue
        print(f"{job_id}\t{source_agent}")
    return 0


def cmd_mcp_orphan_cleanup_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:4994 (process_mcp_orphan_cleanup_periodic).

    Reads the cleanup-report JSON FILE (not a string — caller passes the
    path) and prints summary counts as a single tab-separated row:
      killed_count \\t orphan_count \\t freed_mb_estimate \\t error_count
    """
    payload = json.loads(Path(args.report_file).read_text(encoding="utf-8"))
    print(
        "\t".join(
            [
                str(payload.get("killed_count", 0)),
                str(payload.get("orphan_count", 0)),
                str(payload.get("freed_mb_estimate", 0)),
                str(len(payload.get("errors", []))),
            ]
        )
    )
    return 0


# ---------------------------------------------------------------------------
# #800 regression follow-up — PR #799 introduced four NEW heredoc-stdin
# callsites on the cron auth / token rotation / quota recovery paths roughly
# 30 minutes after PR #801 (#800 Track A) closed nine sibling sites. The
# subcommands below are the Pattern-A wrapping for those four regressions,
# wired in by ``fix/daemon-heredoc-regression-rotation-recovery``.
# ---------------------------------------------------------------------------


def cmd_usage_rotation_candidates_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1069 (process_usage_monitor).

    Extracts ``rotation_candidates`` tuples from the usage-monitor JSON.
    Output: one tab-separated row per candidate (8 cols):
      provider \\t account \\t window \\t used_percent \\t reset_at \\t source \\t agent \\t message

    Issue #831: `agent` is inserted as the 7th column (before message) so the
    daemon shell loop can surface the triggering agent in its audit row. The
    bash callsite is updated in lockstep.
    JSON-parse error exits 1 so the bash callsite's ``|| rotation_rows=""``
    fallback fires and the loop continues with no candidates.
    """
    try:
        payload = json.loads(args.monitor_json)
    except Exception:
        return 1

    for item in payload.get("rotation_candidates", []) or []:
        # `agent` field on the candidate falls back to `worst_case_agent` for
        # consistency with the envelope-level field. Either may be empty for
        # legacy-single-cache rows.
        agent = item.get("agent") or item.get("worst_case_agent") or ""
        print(
            "\t".join(
                [
                    str(item.get("provider", "")),
                    str(item.get("account", "")),
                    str(item.get("window", "")),
                    str(item.get("used_percent", "")),
                    str(item.get("reset_at", "")),
                    str(item.get("source", "")),
                    str(agent),
                    str(item.get("message", "")),
                ]
            )
        )
    return 0


def cmd_rotation_status_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1128 (process_usage_monitor rotate branch).

    Parses the bridge-auth.sh claude-token rotate --json envelope. Output (a
    single row):
      status \\t reason \\t old_active_token_id \\t active_token_id \\t sync_status
    JSON-parse error degrades to ``error\\tinvalid_rotation_output\\t...`` so
    the downstream ``case "$rotation_status:$rotation_reason"`` branch can
    classify it under ``error:*``.
    """
    try:
        payload = json.loads(args.rotate_json)
    except Exception:
        payload = {"status": "error", "reason": "invalid_rotation_output"}
    sync = payload.get("sync") if isinstance(payload.get("sync"), dict) else {}
    print(
        "\t".join(
            [
                str(payload.get("status", "")),
                str(payload.get("reason", "")),
                str(payload.get("old_active_token_id", "")),
                str(payload.get("active_token_id", "")),
                str(sync.get("status", "")),
            ]
        )
    )
    return 0


def cmd_recovery_status_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1227 (process_claude_token_recovery).

    Parses the bridge-auth.sh claude-token recover-due --json envelope.
    Output (a single row):
      status \\t reason \\t checked_count \\t recovered_count \\t still_disabled_count \\t recovered_csv \\t sync_recommended
    JSON-parse error degrades to ``error\\tinvalid_recovery_output\\t...``;
    the bash callsite then audit-logs the failure reason.
    """
    try:
        payload = json.loads(args.recovery_json)
    except Exception:
        payload = {"status": "error", "reason": "invalid_recovery_output"}
    recovered = payload.get("recovered") if isinstance(payload.get("recovered"), list) else []
    print(
        "\t".join(
            [
                str(payload.get("status", "")),
                str(payload.get("reason", "")),
                str(payload.get("checked_count", 0)),
                str(payload.get("recovered_count", 0)),
                str(payload.get("still_disabled_count", 0)),
                ",".join(str(item) for item in recovered),
                "1" if payload.get("sync_recommended") else "0",
            ]
        )
    )
    return 0


def cmd_sync_status_parse(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:1257 (process_claude_token_recovery sync branch).

    Extracts the ``status`` field from a bridge-auth.sh claude-token sync
    --json envelope. Empty argv / parse failure prints ``error`` so the
    bash side surfaces a sync failure rather than silently treating it as
    success.
    """
    try:
        payload = json.loads(args.sync_json)
        print(str(payload.get("status", "")))
    except Exception:
        print("error")
    return 0


# ---------------------------------------------------------------------------
# CLI plumbing.
# ---------------------------------------------------------------------------


SUBCOMMANDS = {
    "usage-alert-parse": (
        cmd_usage_alert_parse,
        [("monitor_json", "JSON payload produced by bridge-usage.sh monitor --json")],
        "Tabular extract of usage-monitor alerts (8 cols / row).",
    ),
    "release-alert-parse": (
        cmd_release_alert_parse,
        [("monitor_json", "JSON payload produced by bridge-release.py monitor")],
        "Single-row tabular extract of the first release alert (5 cols).",
    ),
    "backup-parse": (
        cmd_backup_parse,
        [("backup_json", "JSON envelope from bridge-upgrade.py daily-backup-live")],
        "Single-row outcome / archive_path / counts (6 cols).",
    ),
    "stall-iso-format": (
        cmd_stall_iso_format,
        [("first_detected_ts", "POSIX timestamp (seconds, integer)")],
        "ISO-8601 localized timestamp (empty when ts <= 0).",
    ),
    "permission-expire-scan": (
        cmd_permission_expire_scan,
        [
            ("tasks_json", "JSON array of open [PERMISSION] tasks"),
            ("now_ts", "current epoch seconds"),
            ("timeout_seconds", "permission-task age threshold (seconds)"),
        ],
        "One tab-separated row per expired task (5 cols).",
    ),
    "watchdog-problem-count": (
        cmd_watchdog_problem_count,
        [("report_json", "JSON envelope from bridge-watchdog.sh scan --json")],
        "Single integer line (problem_count), defaulting to 0 on parse error.",
    ),
    "nudge-live-state": (
        cmd_nudge_live_state,
        [
            ("db_path", "path to the queue sqlite DB"),
            ("agent", "agent id to query"),
        ],
        "Single tab-separated row: queued_count, claimed_count, csv queued ids.",
    ),
    "nudge-eligibility-recheck": (
        cmd_nudge_eligibility_recheck,
        [
            ("db_path", "path to the queue sqlite DB"),
            ("agent", "agent id to query"),
            (
                "redelivery_seconds",
                "task-queued-age threshold (seconds); <=0 disables the gate",
            ),
        ],
        "Single tab-separated row: eligible_count, csv eligible queued ids.",
    ),
    "memory-daily-orphan-scan": (
        cmd_memory_daily_orphan_scan,
        [
            ("jobs_json", "JSON payload from agent-bridge cron list --json"),
            ("roster_stream", "newline-delimited roster of loaded agent ids"),
        ],
        "One tab-separated row per orphan job (2 cols).",
    ),
    "mcp-orphan-cleanup-parse": (
        cmd_mcp_orphan_cleanup_parse,
        [("report_file", "path to mcp-orphan-cleanup report JSON file")],
        "Single tab-separated row of summary counts (4 cols).",
    ),
    # #800 regression follow-up — PR #799 callsites.
    "usage-rotation-candidates-parse": (
        cmd_usage_rotation_candidates_parse,
        [("monitor_json", "JSON payload produced by bridge-usage.sh monitor --json")],
        "Tabular extract of usage-monitor rotation candidates (7 cols / row).",
    ),
    "rotation-status-parse": (
        cmd_rotation_status_parse,
        [("rotate_json", "JSON envelope from bridge-auth.sh claude-token rotate --json")],
        "Single-row rotation outcome: status / reason / from / to / sync_status (5 cols).",
    ),
    "recovery-status-parse": (
        cmd_recovery_status_parse,
        [("recovery_json", "JSON envelope from bridge-auth.sh claude-token recover-due --json")],
        "Single-row recovery outcome (7 cols).",
    ),
    "sync-status-parse": (
        cmd_sync_status_parse,
        [("sync_json", "JSON envelope from bridge-auth.sh claude-token sync --json")],
        "Single line — sync status string ('error' on parse failure).",
    ),
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bridge-daemon-helpers.py",
        description=(
            "Daemon-loop subprocess helpers (issue #800 Track A). Replaces "
            "heredoc-stdin python invocations inside bridge-daemon.sh so the "
            "bash 'heredoc_write' deadlock class can no longer wedge the main "
            "loop. Wrap each invocation in bridge_with_timeout."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True, metavar="SUBCOMMAND")

    for name, (handler, positional, help_text) in SUBCOMMANDS.items():
        sub = subparsers.add_parser(name, help=help_text)
        for arg_name, arg_help in positional:
            sub.add_argument(arg_name, help=arg_help)
        sub.set_defaults(_handler=handler)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    handler = getattr(args, "_handler", None)
    if handler is None:
        parser.print_help(sys.stderr)
        return 2
    return handler(args)


if __name__ == "__main__":
    sys.exit(main())
