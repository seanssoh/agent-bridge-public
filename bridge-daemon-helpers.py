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


def cmd_release_downgrade_classify(args: argparse.Namespace) -> int:
    """v0.15.0-beta4 Lane J (#1267).

    Classify a release-monitor payload as a downgrade-skip case.

    Input: the JSON envelope produced by ``bridge-release.py monitor``.
    Output (a single tab-separated row, or empty):
      installed_version \\t latest_version

    Emits a row IFF: there is no alert AND the installed version's
    core (major.minor.patch) is >= the latest tag's core. Empty stdout
    otherwise. Parse errors are non-fatal and produce empty output —
    the caller treats empty as "not a downgrade; do nothing".
    """
    try:
        payload = json.loads(args.monitor_json)
    except Exception:
        return 0
    alerts = payload.get("alerts") or []
    if alerts:
        # An alert was emitted → not a downgrade-skip case.
        return 0
    release = payload.get("release") or {}
    installed = str(release.get("installed_version") or "").strip()
    latest = str(release.get("latest_version") or "").strip()
    if not installed or not latest:
        return 0
    # Issue #1267 (Lane J r2 BLOCKING from codex r1): use full semver
    # 2.0.0 comparison including prerelease ordering. The r1 fix used
    # core-only compare, which classified ``0.14.5-beta1`` vs
    # ``0.14.5`` (a legitimate beta→stable upgrade) as
    # ``installed_core >= latest_core`` → emitted
    # ``release_notification_downgrade_skip`` and silently swallowed
    # the upgrade prompt. Per semver 2.0.0 §11 a prerelease has LOWER
    # precedence than the corresponding final, so the same-core
    # beta→stable case MUST classify as "real upgrade", not downgrade.
    #
    # We re-implement the parser inline here so this helper has no
    # import-side dependency on bridge-release.py (which is the
    # producer; importing consumer-side risks a circular load order via
    # subprocess invocation).
    import re as _re
    _full_re = _re.compile(
        r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$"
    )
    # Lane J r3 (codex r2 BLOCKING): mirror bridge-release.py's
    # undotted-prerelease normalization. Project tags use the undotted
    # ``betaN`` / ``rcN`` / ``alphaN`` form; without normalization the
    # downstream identifier compare falls into the alphanumeric (lexical)
    # branch and orders ``beta10 < beta9`` because "1" < "9". By rewriting
    # ``betaN`` → ``beta.N`` (letter-run + digit-run → dotted) we surface
    # the digit run as a numeric identifier so ``beta.9 < beta.10``
    # compares correctly. Same logic and same regex shape as
    # ``bridge-release.py:_normalize_prerelease_identifier`` — kept inline
    # here for the same anti-coupling reason as the rest of this helper
    # (no producer/consumer import cycle).
    _undotted_ident_re = _re.compile(r"^([A-Za-z]+)(\d+)$")

    def _normalize_prerelease(pre: str) -> str:
        if not pre:
            return pre
        out = []
        for p in pre.split("."):
            m = _undotted_ident_re.match(p)
            if m:
                out.append(f"{m.group(1)}.{m.group(2)}")
            else:
                out.append(p)
        return ".".join(out)

    def _full(text: str):
        match = _full_re.fullmatch(text)
        if not match:
            return None
        major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
        return ((major, minor, patch), _normalize_prerelease(match.group(4) or ""))

    def _cmp_pre(a: str, b: str) -> int:
        a_parts = a.split(".") if a else []
        b_parts = b.split(".") if b else []
        for ai, bi in zip(a_parts, b_parts):
            a_num = ai.isdigit()
            b_num = bi.isdigit()
            if a_num and b_num:
                an, bn = int(ai), int(bi)
                if an != bn:
                    return -1 if an < bn else 1
                continue
            if a_num and not b_num:
                return -1
            if not a_num and b_num:
                return 1
            if ai != bi:
                return -1 if ai < bi else 1
        if len(a_parts) == len(b_parts):
            return 0
        return -1 if len(a_parts) < len(b_parts) else 1

    def _cmp(installed_v, latest_v) -> int:
        if installed_v[0] != latest_v[0]:
            return -1 if installed_v[0] < latest_v[0] else 1
        ip, lp = installed_v[1], latest_v[1]
        if ip == lp:
            return 0
        if not ip and lp:
            return 1  # installed final > latest prerelease
        if ip and not lp:
            return -1  # installed prerelease < latest final (beta→stable upgrade)
        return _cmp_pre(ip, lp)

    installed_full = _full(installed)
    latest_full = _full(latest)
    if installed_full is None or latest_full is None:
        return 0
    if _cmp(installed_full, latest_full) >= 0:
        # Downgrade or no-op case — emit the classification row.
        # NOTE: same-core beta→stable (e.g. 0.14.5-beta1 vs 0.14.5)
        # returns -1 from _cmp and FALLS THROUGH to silence here, which
        # is correct: that pair is a real upgrade, not a downgrade.
        print(f"{installed}\t{latest}")
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


def cmd_watchdog_fresh_install_only(args: argparse.Namespace) -> int:
    """v0.15.0-beta4 Lane G #1266: emit ``1`` when every effective
    problem row in the watchdog report is a fresh-install candidate
    (``fresh_install=true``), ``0`` otherwise.

    The daemon's ``process_watchdog_report`` reads this token to decide
    whether to enqueue the drift task at priority=low (fresh-install
    only) or priority=high (the existing path). Parse error / missing
    field defaults to ``0`` so a malformed report cannot accidentally
    downgrade real drift to low.
    """
    try:
        payload = json.loads(args.report_json)
        # ``fresh_install_only`` is True only when there is at least one
        # effective problem AND every effective problem is fresh-install.
        # An empty problem set (problem_count=0) reports False here; the
        # bash side already short-circuits on problem_count=0 before
        # reading this token.
        print(1 if bool(payload.get("fresh_install_only", False)) else 0)
    except Exception:
        print(0)
    return 0


def _connect_queue_db_readonly(db_path: str) -> sqlite3.Connection:
    """Open the central queue DB read-only without ever creating it.

    Issue #1631 (A2A audit R4 — fail-OPEN read-path mirror of #1623).
    The nudge-eligibility helpers below classify an agent's LIVE queued
    set so the daemon can decide whether a pending nudge is still real.
    A plain ``sqlite3.connect(db_path)`` CREATES an empty DB when the
    path is missing/unresolved (a transient ``BRIDGE_TASK_DB`` glitch),
    which then reports ``queued=0`` and the shell caller actively DROPS
    a legitimately-queued task's nudge, mislabeling it "stale".

    Mirror the sibling ``cmd_task_status`` guard so a missing/unreadable
    DB raises (helpers exit non-zero) instead of silently fabricating an
    empty queue: ``Path(db_path).is_file()`` first, then open via the
    ``file:...?mode=ro`` URI so a bad path can never create a fresh DB.
    The shell call sites treat the non-zero exit as "skip this tick"
    (the next tick retries naturally), never as a stale-drop.
    """
    path = Path(db_path)
    if not path.is_file():  # noqa: raw-pathlib-controller-only — db_path is always the controller's central queue DB ($BRIDGE_TASK_DB), passed only by the daemon-side nudge fanout (bridge-daemon.sh::nudge_agent_session); never an iso-agent path.
        raise sqlite3.OperationalError(f"queue DB not found: {db_path}")
    # Build the file: URI from the already-validated absolute path via
    # ``Path.as_uri()`` so URI metacharacters in the path (e.g. ``?`` / ``#``,
    # valid in filesystem names and reachable through a custom ``BRIDGE_HOME``)
    # are percent-encoded. A naive ``f"file:{path}?mode=ro"`` lets the sqlite
    # URI parser split the path at the first raw ``?``/``#`` and open/create a
    # DIFFERENT prefix path than the one ``is_file()`` just checked — which would
    # silently bypass this read-only/no-create guard. ``as_uri()`` requires an
    # absolute path; the queue DB path is always absolute, but resolve defensively.
    abs_path = path if path.is_absolute() else path.resolve()
    uri = f"{abs_path.as_uri()}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def cmd_nudge_live_state(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh:2728 (nudge_agent_session).

    HIGHEST-IMPACT site per #800. Reads the queue DB for an agent's live
    queued/claimed counts. Output (single row):
      queued_count \\t claimed_count \\t comma_separated_queued_ids

    With ``with_top_task=1`` (Issue #1425): three more columns are appended
    in the SAME bounded read so the flush-time spool rederive
    (lib/bridge-tmux.sh) needs exactly ONE timeout-bounded queue read for
    both the count and the highest-priority queued task's header metadata —
    no second, unbounded queue CLI call on the daemon/flusher path:
      … \\t top_id \\t top_priority \\t top_title
    The top task is the highest-priority QUEUED task (urgent>high>normal>low,
    then lowest id), matching the queued set the count is computed over.
    top_id/top_priority/top_title are empty strings when nothing is queued.
    The title is sanitized of tab/newline so the TSV row stays single-line.

    sqlite errors fall through to a non-zero exit so the bash callsite's
    ``|| true`` keeps the loop intact; the wrapper applies a 15s timeout
    with audit-only fallback (no inline retry — next tick retries naturally).
    """
    db_path = args.db_path
    agent = args.agent
    with_top_task = str(getattr(args, "with_top_task", "0")) == "1"
    with _connect_queue_db_readonly(db_path) as conn:
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
        top_id = ""
        top_priority = ""
        top_title = ""
        if with_top_task:
            top_row = conn.execute(
                """
                SELECT id, priority, title
                FROM tasks
                WHERE assigned_to = ?
                  AND status = 'queued'
                  AND title NOT LIKE '[cron-dispatch]%'
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
                (agent,),
            ).fetchone()
            if top_row is not None:
                top_id = str(top_row[0])
                top_priority = str(top_row[1] or "normal")
                # Sanitize the title so an embedded tab/newline cannot
                # corrupt the TSV row the bash caller parses by tab.
                top_title = (
                    str(top_row[2] or "")
                    .replace("\t", " ")
                    .replace("\r", " ")
                    .replace("\n", " ")
                )
    if with_top_task:
        print(
            f"{len(queued_ids)}\t{claimed_count}\t{','.join(queued_ids)}"
            f"\t{top_id}\t{top_priority}\t{top_title}"
        )
    else:
        print(f"{len(queued_ids)}\t{claimed_count}\t{','.join(queued_ids)}")
    return 0


def cmd_task_status(args: argparse.Namespace) -> int:
    """Read one task status from the queue DB.

    Original site: lib/bridge-tmux.sh::bridge_tmux_pending_attention_flush
    (#1952). The pending-attention flusher uses this to decide whether a
    spooled ``[task-complete]`` notification task is already closed and can be
    dropped instead of replayed later as a stale deferred interrupt.

    Output: the task status string.

    Fail-safe contract: missing DB, invalid id, missing row, sqlite errors,
    and any other read failure exit non-zero so the shell caller preserves the
    original spooled payload. The DB is opened read-only so a bad path cannot
    create a fresh empty queue DB while trying to classify a replay.
    """
    try:
        task_id = int(args.task_id)
    except (TypeError, ValueError):
        return 1
    if task_id <= 0:
        return 1

    db_path = Path(args.db_path)
    if not db_path.is_file():  # noqa: raw-pathlib-controller-only — db_path is always the controller's central queue DB ($BRIDGE_TASK_DB), passed only by the daemon-side pending-attention flusher (bridge-daemon.sh::flush_pending_attention_spools → lib/bridge-tmux.sh); never an iso-agent path.
        return 1

    uri = f"file:{db_path}?mode=ro"
    with sqlite3.connect(uri, uri=True) as conn:
        row = conn.execute(
            "SELECT status FROM tasks WHERE id = ?",
            (task_id,),
        ).fetchone()
    if row is None:
        return 1
    status = str(row[0] or "").strip()
    if not status:
        return 1
    print(status)
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
    with _connect_queue_db_readonly(db_path) as conn:
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


def _tsv_clean(value: object) -> str:
    return str(value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ")


def _read_task_body(row: sqlite3.Row) -> str:
    body_text = row["body_text"]
    if body_text:
        return str(body_text)

    body_path = str(row["body_path"] or "").strip()
    if not body_path:
        return ""
    try:
        return Path(body_path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _parse_cron_followup_frontmatter(body: str) -> dict[str, object] | None:
    lines = body.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    end_index = -1
    for index, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end_index = index
            break
    if end_index <= 1:
        return None
    try:
        payload = json.loads("\n".join(lines[1:end_index]))
    except (TypeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    if payload.get("schema_version") != 1:
        return None
    if payload.get("kind") != "cron-followup":
        return None
    return payload


def _legacy_needs_human_followup(body: str) -> bool:
    normalized = "".join(str(body or "").lower().split())
    return (
        "needs_human_followup=true" in normalized
        or '"needs_human_followup":true' in normalized
        or "'needs_human_followup':true" in normalized
        or "delivery_intent=forward_to_user" in normalized
        or '"delivery_intent":"forward_to_user"' in normalized
    )


def _parse_id_csv(id_csv: str) -> list[int]:
    ids: list[int] = []
    seen: set[int] = set()
    for item in str(id_csv or "").split(","):
        item = item.strip()
        if not item.isdigit():
            continue
        task_id = int(item)
        if task_id in seen:
            continue
        seen.add(task_id)
        ids.append(task_id)
    return ids


def cmd_human_followup_queued_state(args: argparse.Namespace) -> int:
    """Classify queued tasks that need human-facing followup.

    Issue #1936 / gap #4: attached live-idle sessions deliberately skip tmux
    nudge injection (#1411), but `[cron-followup]` tasks with
    `delivery_intent=forward_to_user` are human-facing and should trigger a
    faster operator-visible escalation than the generic unclaimed-task sweep.

    Output (single TSV row, always):
      count \\t first_id \\t csv_ids \\t first_title \\t first_created_ts
            \\t intent \\t channel \\t target_ref \\t format
    """
    db_path = args.db_path
    agent = args.agent
    input_csv = str(getattr(args, "queued_ids_csv", "") or "")
    queued_ids = _parse_id_csv(input_csv)
    if input_csv.strip() and not queued_ids:
        print("0\t\t\t\t\t\t\t\t")
        return 0

    where = [
        "assigned_to = ?",
        "status = 'queued'",
        "title NOT LIKE '[cron-dispatch]%'",
    ]
    params: list[object] = [agent]
    if queued_ids:
        placeholders = ",".join("?" for _ in queued_ids)
        where.append(f"id IN ({placeholders})")
        params.extend(queued_ids)

    with _connect_queue_db_readonly(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            f"""
            SELECT id, title, created_ts, body_text, body_path
            FROM tasks
            WHERE {' AND '.join(where)}
            ORDER BY id
            """,
            params,
        ).fetchall()

    matches: list[dict[str, object]] = []
    for row in rows:
        title = str(row["title"] or "")
        if not title.startswith("[cron-followup]"):
            continue
        body = _read_task_body(row)
        payload = _parse_cron_followup_frontmatter(body)
        intent = ""
        forward_target: dict[str, object] = {}
        if payload is not None:
            intent = str(payload.get("delivery_intent") or "")
            if intent != "forward_to_user":
                continue
            raw_target = payload.get("forward_target")
            if isinstance(raw_target, dict):
                forward_target = raw_target
        elif _legacy_needs_human_followup(body):
            intent = "legacy_needs_human_followup"
        else:
            continue

        matches.append(
            {
                "id": int(row["id"]),
                "title": title,
                "created_ts": int(row["created_ts"] or 0),
                "intent": intent,
                "channel": forward_target.get("channel", ""),
                "target_ref": forward_target.get("target_ref", ""),
                "format": forward_target.get("format", ""),
            }
        )

    if not matches:
        print("0\t\t\t\t\t\t\t\t")
        return 0

    first = matches[0]
    print(
        "\t".join(
            [
                str(len(matches)),
                str(first["id"]),
                ",".join(str(match["id"]) for match in matches),
                _tsv_clean(first["title"]),
                str(first["created_ts"]),
                _tsv_clean(first["intent"]),
                _tsv_clean(first["channel"]),
                _tsv_clean(first["target_ref"]),
                _tsv_clean(first["format"]),
            ]
        )
    )
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


def cmd_usage_probe_result_parse(args: argparse.Namespace) -> int:
    """Issue #1468: classify the native usage-probe `--json` result for audit.

    Input: the token-free JSON result dict printed by `bridge-usage-probe.py
    probe --json`. Output: a SINGLE tab-separated row IFF the outcome is
    NOTEWORTHY (worth an audit row) — empty stdout otherwise (so the daemon /
    wrapper emits nothing on the common fresh/written/cooldown ticks):
      status \\t reset_at \\t retry_after \\t http_status

    Noteworthy statuses:
      - rate-limited-signal     — a genuine 429 → proactive near-limit signal
                                  persisted (the #1468 catch-22 break).
      - rate-limited-suppressed — a genuine 429 already signalled this window
                                  (idempotent; no re-rotate).
      - degraded / scope-degraded / no-token — a probe FAILURE (was silent
                                  best-effort; now observable per #1468 §5).

    fresh / written / cooldown are the healthy/no-op ticks and produce empty
    output. A parse error produces empty output (the wrapper emits no audit).
    """
    try:
        payload = json.loads(args.probe_json)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0
    status = str(payload.get("status") or "")
    noteworthy = {
        "rate-limited-signal",
        "rate-limited-suppressed",
        "degraded",
        "scope-degraded",
        "no-token",
    }
    if status not in noteworthy:
        return 0
    print(
        "\t".join(
            [
                status,
                str(payload.get("reset_at") or ""),
                str(payload.get("retry_after") if payload.get("retry_after") is not None else ""),
                str(payload.get("http_status") if payload.get("http_status") is not None else ""),
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


def cmd_sync_aliveness_parse(args: argparse.Namespace) -> int:
    """Codex r1 BLOCKING #1 (v0.15.0-beta4 Lane F r2, 2026-05-27).

    Extracts per-agent ``aliveness`` + ``remaining_ms`` from a
    bridge-auth.sh claude-token sync --json envelope. The wrapper now
    produces ``agents: [{agent, aliveness, remaining_ms}, ...]`` instead
    of a flat list of names, so the daemon's periodic-sync tick
    (bridge-daemon.sh process_claude_token_periodic_sync_tick) can audit
    each row's token freshness.

    Output shape: one tab-separated row per agent, ``agent\\taliveness
    \\tremaining_ms``. Empty stdout means no agents synced (skipped /
    no_matching_claude_agents / failed-everything). Parse errors print
    nothing — bash callsite treats that as "no rows to audit".

    Backward-compat: tolerates the legacy list[str] shape (``agents``
    being a list of names) by emitting ``agent\\t\\t0`` for each entry,
    so a hybrid wrapper/daemon during rollout never crashes.
    """
    try:
        payload = json.loads(args.sync_json)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0
    agents = payload.get("agents") or []
    if not isinstance(agents, list):
        return 0
    for row in agents:
        if isinstance(row, dict):
            name = str(row.get("agent", "") or "")
            aliveness = str(row.get("aliveness", "") or "")
            try:
                remaining_ms = int(row.get("remaining_ms", 0) or 0)
            except (TypeError, ValueError):
                remaining_ms = 0
        elif isinstance(row, str):
            # Legacy list[str] shape — name only, no aliveness signal.
            name = row
            aliveness = ""
            remaining_ms = 0
        else:
            continue
        if not name:
            continue
        print(f"{name}\t{aliveness}\t{remaining_ms}")
    return 0


def cmd_a2a_stuck_decide(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh process_a2a_outbox_stuck_scan_tick.

    Issue #1262 Gap 3 (v0.15.0-beta4 Lane I, 2026-05-27).
    Codex r1 BLOCKING (v0.15.0-beta4 Lane I r2, 2026-05-27): split
    decide vs ack/stamp so the ledger is only updated AFTER the admin
    task has been filed successfully. Otherwise a transient
    bridge-task.sh failure starts the reemit cooldown without any
    admin task existing — the operator never learns about the stuck
    row.

    Decide which outbox rows have been stuck long enough to deserve an
    admin task, honoring the per-message re-emit cooldown ledger.
    Pure read — does NOT modify the ledger; the daemon shell calls
    ``a2a-stuck-ack`` AFTER successfully creating the admin task to
    stamp the ledger atomically.

    Input:
      now            — current epoch seconds (int)
      stuck_secs     — threshold (row.age_seconds > this → candidate)
      reemit_secs    — re-emit cooldown per message_id
      ledger_path    — JSON file: { message_id: last_emitted_ts }
      outbox_json_path — JSON array from `agb a2a outbox list --json`

    Output (stdout, one TSV row per row to alert):
      message_id \\t peer \\t target_agent \\t status \\t attempts \\t
      age_seconds \\t last_error

    Errors are swallowed (return 0 with no output) — the daemon tick
    must not crash on a malformed ledger or JSON parse failure;
    operator visibility through audit + log is the recovery path.
    """
    try:
        now = int(args.now)
        stuck_secs = int(args.stuck_secs)
        reemit_secs = int(args.reemit_secs)
    except Exception:
        return 0

    ledger_path = args.ledger_path
    outbox_json_path = args.outbox_json_path

    ledger: dict = {}
    try:
        with open(ledger_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            for k, v in data.items():
                try:
                    ledger[str(k)] = int(v)
                except Exception:
                    continue
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        ledger = {}

    try:
        with open(outbox_json_path, "r", encoding="utf-8") as fh:
            rows = json.load(fh)
        if not isinstance(rows, list):
            rows = []
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        rows = []

    # `age_seconds` is enriched by bridge-a2a.py cmd_outbox already; we
    # fall back to (now - created_ts) when the field is absent so the
    # helper stays robust to upstream shape drift.
    seen_ids = set()
    emitted_now = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        message_id = str(row.get("message_id") or "")
        if not message_id:
            continue
        seen_ids.add(message_id)
        status = str(row.get("status") or "")
        # Only pending/retry rows are alert-worthy. acked = success,
        # sending = currently being attempted, dead = the retry loop
        # already gave up — separate signal not to confuse with stuck.
        if status not in ("pending", "retry"):
            continue
        # #1732 class-aware noise policy. The `outbox list --json` rows carry the
        # peer's class-keyed policy (enriched in bridge-a2a.py cmd_outbox). For a
        # transient peer (alarm_on_unreachable=False) an expected disconnect is
        # NOT an incident — suppress the `[A2A] outbox stuck` admin task entirely.
        # The field defaults to True (alarm on) for any persistent / unknown peer,
        # so existing installs are byte-identical. `alarm_on_unreachable` is read
        # explicitly as a bool: only the literal `False` suppresses (a missing /
        # non-bool field falls through to alarming — fail-safe, never silently
        # quiet a server-class peer).
        if row.get("alarm_on_unreachable") is False:
            continue
        # Per-peer grace-window override (#1732): a peer may set a LONGER
        # `stuck_alert_secs` (e.g. a flaky-but-still-alarmed laptop) so the alarm
        # only fires after a generous grace window. Only a positive int override
        # is honored; otherwise the daemon's global `stuck_secs` default applies.
        row_stuck_secs = stuck_secs
        raw_override = row.get("stuck_alert_secs")
        if isinstance(raw_override, int) and not isinstance(raw_override, bool) \
                and raw_override > 0:
            row_stuck_secs = raw_override
        try:
            age = int(row.get("age_seconds") or 0)
        except Exception:
            age = 0
        if age <= 0:
            try:
                created_ts = int(row.get("created_ts") or 0)
            except Exception:
                created_ts = 0
            if created_ts > 0:
                age = max(0, now - created_ts)
        if age < row_stuck_secs:
            continue
        last_emit = ledger.get(message_id, 0)
        if last_emit and (now - last_emit) < reemit_secs:
            continue
        emitted_now.append({
            "message_id": message_id,
            "peer": str(row.get("peer") or ""),
            "target_agent": str(row.get("target_agent") or ""),
            "status": status,
            "attempts": int(row.get("attempts") or 0),
            "age_seconds": age,
            "last_error": str(row.get("last_error") or "").replace("\t", " ").replace("\n", " "),
        })

    for r in emitted_now:
        print(
            f"{r['message_id']}\t{r['peer']}\t{r['target_agent']}\t"
            f"{r['status']}\t{r['attempts']}\t{r['age_seconds']}\t{r['last_error']}"
        )

    # NOTE (r2 split, codex r1 BLOCKING): we DO NOT modify the ledger
    # here. The daemon shell calls ``a2a-stuck-ack`` after each
    # successful admin task create. Ledger stamping + pruning lives
    # in ``cmd_a2a_stuck_ack``.

    return 0


def cmd_a2a_stuck_ack(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh process_a2a_outbox_stuck_scan_tick.

    Issue #1262 Gap 3 / v0.15.0-beta4 Lane I r2 (codex r1 BLOCKING).

    Stamp the stuck-alert ledger ONLY for outbox rows whose admin task
    was successfully filed by the daemon shell. Without this split, a
    transient `bridge-task.sh create` failure would advance the
    re-emit cooldown for a row that never produced an admin task —
    the operator silently loses the alert until the cooldown lapses.

    Input (positional):
      now              — current epoch seconds (int)
      ledger_path      — JSON file: { message_id: last_emitted_ts }
      row_keys_file    — UTF-8 text file with one message_id per
                         non-empty line. The shell writes successful
                         task-create message_ids here; empty file is
                         legal (no rows to stamp, but pruning still
                         runs).
      outbox_json_path — JSON array from `agb a2a outbox list --json`
                         used for ledger pruning (entries whose
                         message_id is no longer in the outbox are
                         dropped so the ledger does not grow
                         unboundedly).

    Atomic rewrite via tempfile + os.replace. Errors are swallowed —
    worst case is a duplicate alert next tick.

    rc=0 on every path so the daemon loop never crashes on a
    malformed ledger / row-keys file.
    """
    try:
        now = int(args.now)
    except Exception:
        return 0

    ledger_path = args.ledger_path
    row_keys_file = args.row_keys_file
    outbox_json_path = args.outbox_json_path

    ledger: dict = {}
    try:
        with open(ledger_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            for k, v in data.items():
                try:
                    ledger[str(k)] = int(v)
                except Exception:
                    continue
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        ledger = {}

    # Successful task-create keys (one per line, blank lines skipped).
    ack_keys: list = []
    try:
        with open(row_keys_file, "r", encoding="utf-8") as fh:
            for raw in fh:
                key = raw.strip()
                if key:
                    ack_keys.append(key)
    except (FileNotFoundError, OSError):
        ack_keys = []

    # Current outbox for pruning. Missing/malformed → skip prune (keep
    # ledger as-is) rather than wipe entries we still care about.
    seen_ids: set = set()
    prune_known = False
    try:
        with open(outbox_json_path, "r", encoding="utf-8") as fh:
            rows = json.load(fh)
        if isinstance(rows, list):
            prune_known = True
            for row in rows:
                if not isinstance(row, dict):
                    continue
                message_id = str(row.get("message_id") or "")
                if message_id:
                    seen_ids.add(message_id)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        prune_known = False

    new_ledger: dict = {}
    if prune_known:
        for k, v in ledger.items():
            if k in seen_ids:
                new_ledger[k] = v
    else:
        new_ledger = dict(ledger)

    for key in ack_keys:
        new_ledger[str(key)] = now

    # Atomic rewrite — tmp-write + os.replace so a crash mid-write
    # cannot leave the ledger in a half-state.
    try:
        import os
        import tempfile
        ledger_dir = os.path.dirname(ledger_path) or "."
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=ledger_dir,
            prefix=".stuck-alerts.", suffix=".tmp", delete=False,
        ) as tmp:
            json.dump(new_ledger, tmp, ensure_ascii=False)
            tmp_path = tmp.name
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, ledger_path)
    except OSError:
        # Ledger update failure is non-fatal — worst case is a
        # duplicate alert next tick (cooldown not respected once).
        pass

    return 0


def cmd_a2a_diag_lookup(args: argparse.Namespace) -> int:
    """Original site: bridge-daemon.sh process_a2a_outbox_stuck_scan_tick.

    Issue #1563 PR-8 (A2A diagnostic + recovery hardening).

    Extract the directional-diagnosis fields for a single peer from the
    `bridge-a2a.py diagnose-stuck --json` report so the daemon shell can
    enrich the stuck-alert body without an inline jq/python heredoc (footgun
    #11). One peer's entry → one TSV row; no entry → no output (empty), which
    the shell treats as "no diagnosis available for this peer".

    Input (positional):
      peer            — the destination peer id to look up.
      diag_json_path  — JSON array file from `a2a diagnose-stuck --json`.

    Output (stdout, single TSV row when the peer is present):
      classification \\t tcp_probe \\t local_healthz \\t
      next_attempt_in_seconds \\t backoff_reset(0|1) \\t
      tcp_healthy_backoff_waiting(0|1)

    Errors are swallowed (rc=0, no output) — a malformed/absent report must
    never crash the daemon tick; the alert just falls back to the un-enriched
    body.
    """
    peer = str(args.peer or "")
    diag_path = args.diag_json_path
    if not peer:
        return 0
    try:
        with open(diag_path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
        if not isinstance(report, list):
            return 0
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return 0

    for entry in report:
        if not isinstance(entry, dict):
            continue
        if str(entry.get("peer") or "") != peer:
            continue
        classification = str(entry.get("classification") or "").replace("\t", " ")
        tcp_probe = str(entry.get("tcp_probe") or "").replace("\t", " ")
        local_healthz = str(entry.get("local_healthz") or "").replace("\t", " ")
        try:
            next_in = int(entry.get("next_attempt_in_seconds") or 0)
        except (TypeError, ValueError):
            next_in = 0
        backoff_reset = "1" if entry.get("backoff_reset") else "0"
        tcp_healthy = "1" if entry.get("tcp_healthy_backoff_waiting") else "0"
        print(
            f"{classification}\t{tcp_probe}\t{local_healthz}\t"
            f"{next_in}\t{backoff_reset}\t{tcp_healthy}"
        )
        return 0
    return 0


# ---------------------------------------------------------------------------
# CLI plumbing.
# ---------------------------------------------------------------------------


def _load_json_file(path: str) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001 — helper boundary; caller treats as empty
        return None


def cmd_orphan_gc_non_clean(args: argparse.Namespace) -> int:
    """Issue #1803 — decide whether an orphan-dir GC pass is "non-clean"
    (worth a `[hygiene]` admin task). Non-clean iff the quarantine summary has
    any actually-moved, would-quarantine, kept-indeterminate, or error entry,
    OR the prune summary actually pruned / refused something.

    Prints ``1`` (non-clean) or ``0`` (clean). A fully clean pass — nothing
    actionable, nothing held back — emits no task (prints 0).
    """
    quarantine = _load_json_file(args.quarantine_json) or {}
    prune = _load_json_file(args.prune_json) or {}
    non_clean = False
    if isinstance(quarantine, dict):
        for key in ("quarantined", "would_quarantine", "kept_indeterminate", "errors"):
            if quarantine.get(key):
                non_clean = True
                break
    if not non_clean and isinstance(prune, dict):
        for key in ("pruned", "refused"):
            if prune.get(key):
                non_clean = True
                break
    print("1" if non_clean else "0")
    return 0


def cmd_orphan_gc_task_body(args: argparse.Namespace) -> int:
    """Issue #1803 — render the `[hygiene]` admin task body from the quarantine
    summary JSON. Lists what was quarantined (or WOULD be, when auto is off)
    and what was kept-because-indeterminate, with the recovery/enable hints.
    """
    summary = _load_json_file(args.quarantine_json)
    host = args.hostname or "host"
    if not isinstance(summary, dict):
        print(f"# orphan agent-dir GC on {host}\n\n(no summary available)")
        return 0

    auto = bool(summary.get("auto_quarantine"))
    quarantined = summary.get("quarantined") or []
    would = summary.get("would_quarantine") or []
    kept = summary.get("kept_indeterminate") or []
    too_young = summary.get("skipped_too_young") or []
    errors = summary.get("errors") or []
    home_root = summary.get("home_root") or ""

    lines: list[str] = []
    lines.append(f"# orphan agent-dir GC on {host}")
    lines.append("")
    lines.append(
        "The daemon scanned the agent-home root for `agents/<name>` homes that "
        "are not in `agent registry --json` and not protected by the keep-set "
        "(registered / `_template` / `shared` / any resolved symlink target). "
        "Only `orphan-agent-dir` is actionable; everything else is kept."
    )
    lines.append("")
    lines.append(f"- Home root: `{home_root}`")
    lines.append(f"- Auto-quarantine: **{'ON' if auto else 'OFF'}** "
                 "(`BRIDGE_ORPHAN_GC_AUTO_QUARANTINE`)")
    lines.append("")

    if auto and quarantined:
        lines.append(f"## Quarantined ({len(quarantined)}) — moved to `backups/orphan-agents-<date>/`")
        for e in quarantined:
            lines.append(
                f"- `{e.get('name', '')}` → `{e.get('quarantine_path', '')}` "
                f"(age {e.get('age_seconds', '?')}s"
                f"{', test-artifact' if e.get('is_test_artifact') else ''})"
            )
        lines.append("")
        lines.append("These were MOVED, never deleted. A separate prune pass "
                     "removes them after the retain window "
                     "(`BRIDGE_ORPHAN_QUARANTINE_RETAIN_DAYS`, default 30d).")
        lines.append("")

    if not auto and would:
        lines.append(f"## Would quarantine ({len(would)}) — DRY RUN (auto-quarantine is OFF)")
        for e in would:
            lines.append(
                f"- `{e.get('name', '')}` at `{e.get('path', '')}` "
                f"(age {e.get('age_seconds', '?')}s"
                f"{', test-artifact' if e.get('is_test_artifact') else ''})"
            )
        lines.append("")
        lines.append(
            "Nothing was moved. To enable automatic quarantine on this host, set "
            "`BRIDGE_ORPHAN_GC_AUTO_QUARANTINE=1` in the daemon environment and "
            "restart the daemon. Quarantine MOVES (never deletes) to "
            "`backups/orphan-agents-<date>/`."
        )
        lines.append("")

    if kept:
        lines.append(f"## Kept — could not verify, fail-safe ({len(kept)})")
        for e in kept:
            lines.append(
                f"- `{e.get('name', '')}` ({e.get('kind', '')}): {e.get('reason', '')}"
            )
        lines.append("")
        lines.append("These were NOT touched. Verify by hand with "
                     "`agent-bridge agent registry --json` before any cleanup.")
        lines.append("")

    if too_young:
        lines.append(f"## Below the age gate ({len(too_young)}) — not yet eligible")
        for e in too_young:
            lines.append(f"- `{e.get('name', '')}` (age {e.get('age_seconds', '?')}s)")
        lines.append("")

    if errors:
        lines.append(f"## Errors ({len(errors)})")
        for e in errors:
            if isinstance(e, dict):
                lines.append(f"- `{e.get('name', '')}`: {e.get('error', '')}")
            else:
                lines.append(f"- {e}")
        lines.append("")

    print("\n".join(lines).rstrip() + "\n")
    return 0


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
    "release-downgrade-classify": (
        cmd_release_downgrade_classify,
        [("monitor_json", "JSON payload produced by bridge-release.py monitor")],
        "Single-row downgrade-skip classification (installed \\t latest), "
        "or empty when not a downgrade case (Issue #1267).",
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
    "watchdog-fresh-install-only": (
        cmd_watchdog_fresh_install_only,
        [("report_json", "JSON envelope from bridge-watchdog.sh scan --json")],
        "Single integer line (1 = every effective problem is fresh-install; 0 otherwise).",
    ),
    "nudge-live-state": (
        cmd_nudge_live_state,
        [
            ("db_path", "path to the queue sqlite DB"),
            ("agent", "agent id to query"),
            (
                "with_top_task",
                "1 = also append the highest-priority queued task's "
                "id/priority/title (3 extra cols) in the SAME bounded read; "
                "0 (default) keeps the legacy 3-col output",
                "0",
            ),
        ],
        "Single tab-separated row: queued_count, claimed_count, csv queued "
        "ids. With with_top_task=1, three more cols are appended: top_id, "
        "top_priority, top_title.",
    ),
    "task-status": (
        cmd_task_status,
        [
            ("db_path", "path to the queue sqlite DB"),
            ("task_id", "task id to query"),
        ],
        "Single line: task status. Non-zero when the status cannot be confirmed.",
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
    "human-followup-queued-state": (
        cmd_human_followup_queued_state,
        [
            ("db_path", "path to the queue sqlite DB"),
            ("agent", "agent id to query"),
            (
                "queued_ids_csv",
                "optional comma-separated queued task ids to restrict classification",
                "",
            ),
        ],
        "Single tab-separated row describing queued human-facing cron followups.",
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
    # Issue #1468: classify a native usage-probe --json result for an audit row.
    "usage-probe-result-parse": (
        cmd_usage_probe_result_parse,
        [("probe_json", "JSON result from bridge-usage-probe.py probe --json")],
        "Single noteworthy-outcome row (status/reset_at/retry_after/http_status) or empty.",
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
    "sync-aliveness-parse": (
        cmd_sync_aliveness_parse,
        [("sync_json", "JSON envelope from bridge-auth.sh claude-token sync --json")],
        "Per-agent aliveness/remaining_ms (3 tab-separated cols / row). Empty on parse failure.",
    ),
    # Issue #1262 Gap 3 (v0.15.0-beta4 Lane I): outbox stuck-alert
    # decision helper. See cmd_a2a_stuck_decide.
    "a2a-stuck-decide": (
        cmd_a2a_stuck_decide,
        [
            ("now", "current epoch seconds (int)"),
            ("stuck_secs", "row.age_seconds threshold above which the row is candidate"),
            ("reemit_secs", "per-message re-emit cooldown in seconds"),
            ("ledger_path", "JSON file recording last-emitted-ts per message_id"),
            ("outbox_json_path", "JSON file containing `agb a2a outbox list --json` output"),
        ],
        "One tab-separated row per stuck row that crossed the threshold and cooldown.",
    ),
    # Issue #1262 Gap 3 / v0.15.0-beta4 Lane I r2 (codex r1 BLOCKING):
    # stamp the ledger ONLY after the daemon shell successfully filed
    # the admin task. See cmd_a2a_stuck_ack.
    "a2a-stuck-ack": (
        cmd_a2a_stuck_ack,
        [
            ("now", "current epoch seconds (int)"),
            ("ledger_path", "JSON file recording last-emitted-ts per message_id"),
            (
                "row_keys_file",
                "UTF-8 text file with one successful-task-create message_id per line",
            ),
            (
                "outbox_json_path",
                "JSON file containing `agb a2a outbox list --json` output (for prune)",
            ),
        ],
        "Stamp ledger for successful task-create rows + prune entries missing from outbox.",
    ),
    # Issue #1563 PR-8 (A2A diagnostic + recovery hardening): per-peer
    # directional-diagnosis lookup for the stuck-alert body. See
    # cmd_a2a_diag_lookup.
    "a2a-diag-lookup": (
        cmd_a2a_diag_lookup,
        [
            ("peer", "destination peer id to look up"),
            (
                "diag_json_path",
                "JSON array file from `bridge-a2a.py diagnose-stuck --json`",
            ),
        ],
        "Single TSV row (classification / tcp_probe / local_healthz / "
        "next_attempt_in_seconds / backoff_reset / tcp_healthy_backoff_waiting) "
        "for the peer, or empty when the peer is not backoff-waiting.",
    ),
    # Issue #1803: orphan agent-dir GC — daemon-loop helpers.
    "orphan-gc-non-clean": (
        cmd_orphan_gc_non_clean,
        [
            ("quarantine_json", "bridge-orphan-gc.py quarantine summary JSON file"),
            ("prune_json", "bridge-orphan-gc.py prune summary JSON file"),
        ],
        "Prints 1 when the GC pass is non-clean (file a [hygiene] task), else 0.",
    ),
    "orphan-gc-task-body": (
        cmd_orphan_gc_task_body,
        [
            ("quarantine_json", "bridge-orphan-gc.py quarantine summary JSON file"),
            ("hostname", "short hostname for the task title/body"),
        ],
        "Render the [hygiene] admin task body (quarantined / would-quarantine / kept).",
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
        for spec in positional:
            # 2-tuple (name, help) → required positional (the common case).
            # 3-tuple (name, help, default) → OPTIONAL trailing positional
            # with a default, so a new arg can be appended to an existing
            # subcommand without breaking callers that omit it (e.g. the
            # daemon's existing `nudge-live-state <db> <agent>` invocation).
            arg_name, arg_help = spec[0], spec[1]
            if len(spec) >= 3:
                sub.add_argument(
                    arg_name, help=arg_help, nargs="?", default=spec[2]
                )
            else:
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
