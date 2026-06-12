#!/usr/bin/env python3
import argparse
import json
import os
import re
import secrets
import shlex
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path


LOCAL_TZ = datetime.now().astimezone().tzinfo
FAMILY_RULES = (
    "memory-daily",
    "monthly-highlights",
    "morning-briefing",
    "evening-digest",
    "event-reminder",
    "weekly-review",
)

# Issue #533 — retention defaults for cron run-artifact GC.
RUN_ARTIFACTS_TIER_A_DEFAULT_DAYS = 7
RUN_ARTIFACTS_TIER_B_DEFAULT_DAYS = 30
ALWAYS_PRESERVE_FLOOR = 5

# Surface paths are relative to the BRIDGE_HOME target_root.
RUN_ARTIFACTS_TIER_A_SURFACES = (
    "state/cron/runs",
    "state/cron/workers",
    "state/cron/dispatch",
)
RUN_ARTIFACTS_TIER_B_SURFACES = (
    "shared/cron-dispatch",
    "shared/cron-result",
    "shared/cron-followup",
)

# Terminal state.json values for a cron run. "deferred" is intentionally NOT
# terminal — the runner asks for re-fire and the slot is still in flight.
_RUN_STATUS_TERMINAL_STATES = {"success", "error", "timed_out", "cancelled"}
# Failed runs (state="error") are retained on the longer Tier-B clock so the
# operator has time to triage even when the originating surface is Tier-A.
_RUN_STATUS_FAILED_STATES = {"error", "timed_out"}

# bridge-queue.py terminal statuses are "done" and "cancelled" only — there
# is no "failed" queue state. Source: bridge-queue.py status enum + #533.
_QUEUE_TERMINAL_STATUSES = {"done", "cancelled"}

# Issue #1843 (secondary footgun) — a recurring cron that fails on EVERY run
# accumulates `consecutiveErrors` silently with no human escalation. In the
# field this hid a 7-day, 1898-consecutive-error outage of a customer-facing
# pipeline. The primary tamper-check root cause is fixed under #1842; this is
# the blast-radius amplifier: sustained back-to-back failures must trip a
# human-visible escalation rather than climbing forever in the dashboard only.
#
# Escalate the FIRST time the counter reaches the threshold, then re-escalate
# on the same cadence (every Nth additional consecutive failure) so a job that
# stays broken keeps surfacing without spamming an alert every single run.
CRON_CONSECUTIVE_FAILURE_ESCALATE_AT = 5
CRON_CONSECUTIVE_FAILURE_RENOTIFY_EVERY = 25

SHELL_PAYLOAD_ENV_PREFIXES = ("POLL_", "SCRIPT_")
SHELL_PROTECTED_ENV_EXACT = {"HOME", "PATH"}
SHELL_PROTECTED_ENV_PREFIXES = ("BRIDGE_", "CRON_")
SHELL_ARG_FORBIDDEN_RE = re.compile(r"[\x00\r\n;&|<>`]")


# Canonical memory-daily prompt body template (issue #541 PR-A).
#
# Both `agb cron create --family memory-daily` (via title-detection) and
# `agb cron migrate-payloads --jsonl-aware` write this exact text, with
# `{agent}` substituted, into the memory-daily job payloads. Keep this in
# sync with bootstrap-memory-system.sh:step_memory_daily_cron_one and
# docs/agent-runtime/memory-daily-harvest.md §2.
#
# The first line is load-bearing: the cron runner forwards the payload text
# to a Claude subagent as the prompt body, and the subagent invokes the
# harvester via Bash (see docs/agent-runtime/memory-daily-harvest.md §3).
# The harvester itself runs scripts/daily-note-reconcile.py against the
# agent's most recent jsonl session before the harvest pass; the comment
# block exists so the subagent's pattern-matching surfaces the right
# context (jsonl / session_id / daily-note-reconcile keywords) and so
# operator-readers can audit jsonl-awareness from the cron payload alone.
# The "Do NOT re-interpret" pragma is also load-bearing — without it the
# subagent could paraphrase actions_taken and break the daemon
# refresh-gating contract documented in §7 of the same doc.
MEMORY_DAILY_JSONL_AWARE_PROMPT_TEMPLATE = (
    'bash "$BRIDGE_HOME/scripts/memory-daily-harvest.sh" --agent {agent}\n'
    "\n"
    "# This harvester reconciles the agent's most recent jsonl session\n"
    "# transcript (resolved via session_id under ~/.claude/projects/) into the\n"
    "# agent's daily note at memory/daily/<YYYY-MM-DD>.md by invoking\n"
    "# scripts/daily-note-reconcile.py before the harvest pass. The harvester\n"
    "# then writes the authoritative RESULT_SCHEMA JSON to\n"
    "# $CRON_REQUEST_DIR/authoritative-memory-daily.json. The runner reads that\n"
    "# file directly. Your structured_output is a secondary relay.\n"
    "# Do NOT re-interpret status / summary / actions_taken — the harvester is authoritative."
)


def render_memory_daily_jsonl_aware_prompt(agent):
    """Materialize MEMORY_DAILY_JSONL_AWARE_PROMPT_TEMPLATE for one agent."""
    return MEMORY_DAILY_JSONL_AWARE_PROMPT_TEMPLATE.format(agent=agent)


# Tokens that together prove a memory-daily payload is jsonl-aware. The
# canonical body above contains all three; hand-edited operator overrides
# that lack any of them are flagged for migration.
_MEMORY_DAILY_JSONL_AWARE_TOKENS = ("jsonl", "session_id", "daily-note-reconcile")


def memory_daily_payload_is_jsonl_aware(text):
    """True iff the payload text references jsonl + session_id + the
    canonical reconciler (daily-note-reconcile.py) — see issue #541 PR-A."""
    if not text:
        return False
    lowered = text.lower()
    return all(token in lowered for token in _MEMORY_DAILY_JSONL_AWARE_TOKENS)


def load_jobs_payload(path):
    raw = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    jobs = raw.get("jobs") if isinstance(raw, dict) else raw
    if not isinstance(jobs, list):
        raise ValueError("jobs.json must contain a top-level list or {jobs:[...]}")
    for job in jobs:
        if isinstance(job, dict):
            normalize_job_agent_fields(job)
    return raw, jobs


def load_jobs(path):
    _, jobs = load_jobs_payload(path)
    return jobs


def load_native_jobs_payload(path):
    jobs_path = Path(path).expanduser()
    if not jobs_path.exists():
        return {
            "format": "agent-bridge-cron-v1",
            "updatedAt": datetime.now().astimezone().isoformat(),
            "jobs": [],
        }, []
    return load_jobs_payload(jobs_path)


def normalize_job_agent_fields(job):
    agent_id = str(job.get("agentId") or "").strip()
    agent = str(job.get("agent") or "").strip()

    if agent_id and not agent:
        job["agent"] = agent_id
    elif agent and not agent_id:
        job["agentId"] = agent

    return job


def now_epoch_ms():
    return int(datetime.now(timezone.utc).timestamp() * 1000)


def default_tz_name():
    zone_name = getattr(LOCAL_TZ, "key", None)
    if zone_name:
        return zone_name
    zone_name = datetime.now().astimezone().tzname()
    if zone_name and "/" in zone_name:
        return zone_name
    return "UTC"


def parse_iso_datetime(value):
    if not value or not isinstance(value, str):
        return None
    text = value
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text).astimezone(LOCAL_TZ)
    except ValueError:
        return None


def parse_epoch_ms(value):
    if value in (None, "", 0):
        return None
    try:
        return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc).astimezone(LOCAL_TZ)
    except (TypeError, ValueError, OSError):
        return None


def format_dt(value):
    if value is None:
        return "-"
    return value.strftime("%Y-%m-%d %H:%M %Z")


def format_duration_ms(value):
    if value in (None, ""):
        return "-"
    try:
        remaining = int(value) // 1000
    except (TypeError, ValueError):
        return str(value)

    if remaining <= 0:
        return "0s"

    parts = []
    days, remaining = divmod(remaining, 86400)
    hours, remaining = divmod(remaining, 3600)
    minutes, seconds = divmod(remaining, 60)
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if seconds or not parts:
        parts.append(f"{seconds}s")
    return " ".join(parts[:2])


def preview_text(value, limit=120):
    if not value:
        return ""
    flattened = " ".join(str(value).splitlines()).strip()
    if len(flattened) <= limit:
        return flattened
    if limit <= 3:
        return flattened[:limit]
    return flattened[: limit - 3].rstrip() + "..."


def preview_shell_payload(payload, limit=120):
    script = str(payload.get("script") or "").strip()
    args = payload.get("args") if isinstance(payload.get("args"), list) else []
    flattened = " ".join([script, *[str(item) for item in args]]).strip()
    return preview_text(flattened, limit=limit)


def classify_family(name):
    for rule in FAMILY_RULES:
        if name.startswith(rule) or rule in name:
            return rule
    return name


def classify_kind(job):
    schedule = job.get("schedule") or {}
    if schedule.get("kind") == "at" or job.get("deleteAfterRun") is True:
        return "one-shot"
    return "recurring"


def schedule_text(schedule):
    kind = schedule.get("kind", "<unknown>")
    if kind == "cron":
        expr = schedule.get("expr", "?")
        tz_name = schedule.get("tz", "UTC")
        return f"cron {expr} {tz_name}"
    if kind == "every":
        return f"every {format_duration_ms(schedule.get('everyMs'))}"
    if kind == "at":
        return f"at {schedule.get('at', '-')}"
    return json.dumps(schedule, ensure_ascii=False, sort_keys=True)


def cron_field_bounds(index):
    if index == 0:
        return 0, 59
    if index == 1:
        return 0, 23
    if index == 2:
        return 1, 31
    if index == 3:
        return 1, 12
    return 0, 7


def expand_cron_atom(atom, minimum, maximum):
    step = 1
    base = atom
    if "/" in atom:
        base, step_text = atom.split("/", 1)
        step = int(step_text)
        if step <= 0:
            raise ValueError(f"invalid cron step: {atom}")

    if base == "*":
        start = minimum
        end = maximum
    elif "-" in base:
        start_text, end_text = base.split("-", 1)
        start = int(start_text)
        end = int(end_text)
    else:
        start = int(base)
        end = int(base)

    if start > end:
        raise ValueError(f"invalid cron range: {atom}")

    values = set()
    for value in range(start, end + 1, step):
        normalized = 0 if maximum == 7 and value == 7 else value
        if normalized < minimum or normalized > maximum:
            raise ValueError(f"cron value out of range: {atom}")
        values.add(normalized)
    return values


def validate_cron_expr(expr):
    fields = expr.split()
    if len(fields) != 5:
        raise ValueError("cron schedule must contain 5 fields")
    for index, field in enumerate(fields):
        minimum, maximum = cron_field_bounds(index)
        for atom in field.split(","):
            atom = atom.strip()
            if not atom:
                raise ValueError(f"invalid empty cron atom in field {index + 1}")
            expand_cron_atom(atom, minimum, maximum)
    return expr


def agent_matches(agent_id, expected):
    if not expected:
        return True
    if agent_id == expected:
        return True
    if agent_id.endswith(expected):
        return True
    return agent_id.endswith(f"-{expected}")


def is_error_record(record):
    # "deferred" is a deliberate skip (e.g. #263 Track B pre-flight memory
    # guard). It is not a failure; the next scheduler tick re-fires the slot.
    return record["consecutive_errors"] > 0 or record["last_status"] not in ("-", "ok", "success", "deferred")


def build_job_record(job):
    state = job.get("state") or {}
    schedule = job.get("schedule") or {}
    payload = job.get("payload") or {}
    delivery = job.get("delivery") or {}
    metadata = job.get("metadata") or {}
    next_run = parse_epoch_ms(state.get("nextRunAtMs"))
    if next_run is None and schedule.get("kind") == "at":
        next_run = parse_iso_datetime(schedule.get("at"))

    last_run = parse_epoch_ms(state.get("lastRunAtMs"))
    name = job.get("name", "<unnamed>")
    last_status = state.get("lastStatus") or state.get("lastRunStatus") or "-"
    consecutive_errors = int(state.get("consecutiveErrors") or 0)
    payload_kind = payload.get("kind", "-")
    payload_text = payload.get("text") or payload.get("message") or ""
    if payload_kind == "shell":
        payload_text = ""
        payload_preview = preview_shell_payload(payload)
    else:
        payload_preview = preview_text(payload_text)
    last_error = parse_epoch_ms(state.get("lastErrorAtMs"))
    if last_error is None and (consecutive_errors > 0 or last_status not in ("-", "ok", "success")):
        last_error = last_run

    return {
        "id": job.get("id", ""),
        "name": name,
        "agent": job.get("agentId") or job.get("agent") or "<unknown>",
        "family": classify_family(name),
        "kind": classify_kind(job),
        "enabled": bool(job.get("enabled", False)),
        "schedule_kind": schedule.get("kind", "<unknown>"),
        "schedule_text": schedule_text(schedule),
        "next_run_at": next_run,
        "last_run_at": last_run,
        "last_error_at": last_error,
        "last_status": last_status,
        "consecutive_errors": consecutive_errors,
        "last_duration_ms": state.get("lastDurationMs"),
        "last_delivery_status": state.get("lastDeliveryStatus") or "-",
        # PR2 — surface the cron-runner reporting trio so `agb cron show`
        # / `agb cron list --json` can trace cron → inbox → main-session
        # without the operator grepping `state/cron/runs/<run-id>/`.
        # Absence stays as None at this layer (Codex PR #500 r1 P2 #1):
        # JSON consumers must distinguish "never ran" (`null`) from a
        # legitimate "-" value, and `render_shell` already maps `None` →
        # empty string. The "-" fallback is applied only in the human
        # text renderer (`print_show`).
        "last_reporting_decision": state.get("lastReportingDecision") or None,
        "last_delivery_intent": state.get("lastDeliveryIntent") or None,
        "last_inbox_task_id": state.get("lastInboxTaskId"),
        "session_target": job.get("sessionTarget", "-"),
        "wake_mode": job.get("wakeMode", "-"),
        "payload_kind": payload_kind,
        "payload_shell_script": payload.get("script", ""),
        "payload_shell_args": payload.get("args") if isinstance(payload.get("args"), list) else [],
        "payload_shell_env": payload.get("env") if isinstance(payload.get("env"), dict) else {},
        "payload_shell_timeout_seconds": payload.get("timeoutSeconds", ""),
        "payload_shell_output_cap_bytes": payload.get("outputCapBytes", ""),
        "execution_run_as_agent": (job.get("execution") or {}).get("runAsAgent", ""),
        "job_delivery_mode": delivery.get("mode", ""),
        "job_delivery_channel": delivery.get("channel", ""),
        "job_delivery_target": delivery.get("to", ""),
        "allow_channel_delivery": bool(
            metadata.get("allowChannelDelivery")
            or metadata.get("allow_channel_delivery")
            or metadata.get("directChannelDelivery")
            or metadata.get("direct_channel_delivery")
        ),
        "disposable_needs_channels": bool(
            metadata.get("disposableNeedsChannels") or metadata.get("disposable_needs_channels")
        ),
        # #263: opt-in flag that tells the disposable cron child to launch
        # without any MCP servers. Eliminates per-fire MCP cold-start cost for
        # cron payloads that do not call MCP tools (the common case for
        # polling/reminder crons). Recognised aliases:
        #   metadata.disableMcp / disable_mcp
        #   metadata.disposableDisableMcp / disposable_disable_mcp
        "disable_mcp": bool(
            metadata.get("disableMcp")
            or metadata.get("disable_mcp")
            or metadata.get("disposableDisableMcp")
            or metadata.get("disposable_disable_mcp")
        ),
        # PR1.2 — per-job override on the default-silent cron reporting
        # policy. Allowed values per Sean Q-B 2026-05-02:
        #   default | always_main_session | always_silent
        # Anything else falls back to `default` at the runner side.
        "cron_reporting_policy": str(
            metadata.get("cronReportingPolicy")
            or metadata.get("cron_reporting_policy")
            or metadata.get("reportingPolicy")
            or metadata.get("reporting_policy")
            or ""
        ).strip(),
        # PR1.6 — priority hint for the cron-runner-created inbox task.
        # Allowed: normal | high | urgent. Default `normal` at runner side.
        "cron_urgency": str(
            metadata.get("cronUrgency")
            or metadata.get("cron_urgency")
            or metadata.get("urgency")
            or ""
        ).strip(),
        "payload_text": payload_text,
        "payload_preview": payload_preview,
        "raw": job,
    }


def inventory_rows(records):
    by_family = defaultdict(list)
    for record in records:
        by_family[record["family"]].append(record)

    rows = []
    for family, items in by_family.items():
        next_values = [item["next_run_at"] for item in items if item["next_run_at"] is not None]
        last_values = [item["last_run_at"] for item in items if item["last_run_at"] is not None]
        rows.append(
            {
                "family": family,
                "jobs": len(items),
                "recurring": sum(1 for item in items if item["kind"] == "recurring"),
                "one_shot": sum(1 for item in items if item["kind"] == "one-shot"),
                "agents": sorted({item["agent"] for item in items}),
                "next_run_at": min(next_values) if next_values else None,
                "last_run_at": max(last_values) if last_values else None,
            }
        )
    rows.sort(key=lambda row: (-row["jobs"], row["family"]))
    return rows


def summarize(records):
    now = datetime.now().astimezone()
    totals = {
        "total_jobs": len(records),
        "enabled_jobs": sum(1 for item in records if item["enabled"]),
        "disabled_jobs": sum(1 for item in records if not item["enabled"]),
        "recurring_jobs": sum(1 for item in records if item["kind"] == "recurring"),
        "one_shot_jobs": sum(1 for item in records if item["kind"] == "one-shot"),
        "future_one_shot_jobs": sum(
            1
            for item in records
            if item["kind"] == "one-shot" and item["next_run_at"] is not None and item["next_run_at"] >= now
        ),
        "expired_one_shot_jobs": sum(
            1
            for item in records
            if item["kind"] == "one-shot" and item["next_run_at"] is not None and item["next_run_at"] < now
        ),
        # Source of truth for the "is this an error?" predicate is
        # is_error_record(); summarize() must defer to it so deferred jobs
        # (#263 Track B pre-flight memory guard) are not over-counted in the
        # operator-visible inventory aggregate.
        "error_jobs": sum(1 for item in records if is_error_record(item)),
        "schedule_kinds": dict(Counter(item["schedule_kind"] for item in records)),
        "payload_kinds": dict(Counter(item["payload_kind"] for item in records)),
    }
    return totals


def filter_records(records, args):
    filtered = []
    for record in records:
        if args.mode != "all" and record["kind"] != args.mode:
            continue
        if args.enabled != "all":
            expected_enabled = args.enabled == "yes"
            if record["enabled"] != expected_enabled:
                continue
        if args.family and record["family"] != args.family:
            continue
        if args.agent and not agent_matches(record["agent"], args.agent):
            continue
        filtered.append(record)
    return filtered


def record_sort_key(record):
    next_sort = record["next_run_at"].timestamp() if record["next_run_at"] else float("inf")
    last_sort = -record["last_run_at"].timestamp() if record["last_run_at"] else float("inf")
    return (next_sort, last_sort, record["agent"], record["name"])


def trimmed_jobs(records, limit):
    ordered = sorted(records, key=record_sort_key)
    if limit == 0:
        return ordered
    return ordered[:limit]


def serialize_record(record, include_payload=False):
    payload = {
        "id": record["id"],
        "name": record["name"],
        "agent": record["agent"],
        "family": record["family"],
        "kind": record["kind"],
        "enabled": record["enabled"],
        "schedule_kind": record["schedule_kind"],
        "schedule_text": record["schedule_text"],
        "next_run_at": record["next_run_at"].isoformat() if record["next_run_at"] else None,
        "last_run_at": record["last_run_at"].isoformat() if record["last_run_at"] else None,
        "last_error_at": record["last_error_at"].isoformat() if record["last_error_at"] else None,
        "last_status": record["last_status"],
        "consecutive_errors": record["consecutive_errors"],
        "last_duration_ms": record["last_duration_ms"],
        "last_delivery_status": record["last_delivery_status"],
        # PR2 — inbox-only reporting contract surface; mirrors the trio
        # written by run_native_finalize(). JSON consumers see the raw
        # dash-or-value strings just like last_delivery_status.
        "last_reporting_decision": record["last_reporting_decision"],
        "last_delivery_intent": record["last_delivery_intent"],
        "last_inbox_task_id": record["last_inbox_task_id"],
        "session_target": record["session_target"],
        "wake_mode": record["wake_mode"],
        "payload_kind": record["payload_kind"],
        "payload_shell_script": record.get("payload_shell_script", ""),
        "payload_shell_args": record.get("payload_shell_args", []),
        "payload_shell_env": record.get("payload_shell_env", {}),
        "payload_shell_timeout_seconds": record.get("payload_shell_timeout_seconds", ""),
        "payload_shell_output_cap_bytes": record.get("payload_shell_output_cap_bytes", ""),
        "execution_run_as_agent": record.get("execution_run_as_agent", ""),
        "job_delivery_mode": record["job_delivery_mode"],
        "job_delivery_channel": record["job_delivery_channel"],
        "job_delivery_target": record["job_delivery_target"],
        "allow_channel_delivery": record["allow_channel_delivery"],
        "disposable_needs_channels": record["disposable_needs_channels"],
        "disable_mcp": record["disable_mcp"],
        # PR1.2 / PR1.6 — surface per-job reporting policy + urgency hints
        # so the dispatch path (`bridge-cron.sh`) can ferry them into the
        # request JSON consumed by the runner.
        "cron_reporting_policy": record.get("cron_reporting_policy", ""),
        "cron_urgency": record.get("cron_urgency", ""),
        "payload_preview": record["payload_preview"],
    }
    if include_payload:
        payload["payload_text"] = record["payload_text"]
        payload["raw"] = record["raw"]
    return payload


def render_shell(record):
    payload = serialize_record(record, include_payload=True)
    payload.pop("raw", None)
    lines = []
    for key, value in payload.items():
        shell_key = f"CRON_JOB_{key.upper()}"
        if isinstance(value, bool):
            text = "1" if value else "0"
        elif value is None:
            text = ""
        elif isinstance(value, (dict, list)):
            text = json.dumps(value, ensure_ascii=False, sort_keys=True)
        else:
            text = str(value)
        lines.append(f"{shell_key}={shlex.quote(text)}")
    return "\n".join(lines)


def job_prefix(name):
    if not name:
        return "<unnamed>"
    prefix = name.split("-", 1)[0].strip()
    return prefix or name.strip() or "<unnamed>"


def error_severity_bucket(record):
    if record["consecutive_errors"] >= 10:
        return "10+"
    if record["consecutive_errors"] >= 3:
        return "3-9"
    return "1-2"


def error_sort_key(record):
    last_error_sort = -record["last_error_at"].timestamp() if record["last_error_at"] else float("inf")
    return (-record["consecutive_errors"], last_error_sort, record["agent"], record["name"])


def error_records(records, args):
    filtered = []
    for record in records:
        if record["schedule_kind"] != "cron":
            continue
        if not is_error_record(record):
            continue
        if args.family and record["family"] != args.family:
            continue
        if args.agent and not agent_matches(record["agent"], args.agent):
            continue
        filtered.append(record)
    return filtered


def format_error_record(record):
    return (
        f"{record['agent']} | {record['name']} | "
        f"errors={record['consecutive_errors']} | "
        f"last_error={format_dt(record['last_error_at'])} | "
        f"duration={format_duration_ms(record['last_duration_ms'])} | "
        f"schedule={record['schedule_text']} | "
        f"payload={record['payload_preview'] or '-'}"
    )


def severity_summary(records):
    counts = Counter(error_severity_bucket(record) for record in records)
    return {
        "10+": counts.get("10+", 0),
        "3-9": counts.get("3-9", 0),
        "1-2": counts.get("1-2", 0),
    }


def print_errors_report(args, records):
    errors = sorted(error_records(records, args), key=error_sort_key)
    recurring_total = sum(1 for record in records if record["schedule_kind"] == "cron")
    severity_counts = severity_summary(errors)
    agent_counts = Counter(record["agent"] for record in errors)
    family_counts = Counter(record["family"] for record in errors)
    prefix_counts = Counter(job_prefix(record["name"]) for record in errors)
    limit = args.limit if args.limit is not None else (0 if args.json else 20)
    display_records = errors if limit == 0 else errors[:limit]

    if args.json:
        payload = {
            "source_file": str(Path(args.jobs_file).expanduser()),
            "generated_at": datetime.now().astimezone().isoformat(),
            "filters": {
                "agent": args.agent,
                "family": args.family,
                "limit": 0 if limit == 0 else limit,
            },
            "total_recurring_jobs": recurring_total,
            "error_jobs": len(errors),
            "by_severity": severity_counts,
            "by_agent": dict(agent_counts),
            "by_family": dict(family_counts),
            "by_job_prefix": dict(prefix_counts),
            "jobs": [serialize_record(record) for record in display_records],
            "jobs_total": len(errors),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print(f"generated_at: {datetime.now().astimezone().isoformat()}")
    print(f"filters: agent={args.agent or '-'} family={args.family or '-'} limit={limit}")
    print(f"total_recurring_jobs: {recurring_total}")
    print(f"error_jobs: {len(errors)}")
    print()
    print("by_severity:")
    for bucket, count in severity_counts.items():
        print(f"- {bucket}: {count}")
    print()
    print("by_agent:")
    if not agent_counts:
        print("- none")
    else:
        for agent, count in agent_counts.most_common():
            print(f"- {agent}: {count}")
    print()
    print("by_family:")
    if not family_counts:
        print("- none")
    else:
        for family, count in family_counts.most_common():
            print(f"- {family}: {count}")
    print()
    print("by_job_prefix:")
    if not prefix_counts:
        print("- none")
    else:
        for prefix, count in prefix_counts.most_common():
            print(f"- {prefix}: {count}")
    print()
    print("jobs:")
    if not display_records:
        print("- none")
    else:
        for record in display_records:
            print(f"- {format_error_record(record)}")
        if limit != 0 and len(errors) > len(display_records):
            print(f"- ... ({len(errors) - len(display_records)} more jobs)")
    return 0


def cleanup_candidates(records, mode):
    now = datetime.now().astimezone()
    # ``one-shot`` is the issue #533 alias for the legacy
    # ``expired-one-shot`` mode kept for backwards compat. ``all`` runs
    # both the legacy expired-one-shot pass *and* the new run-artifacts
    # pass; from the legacy pass's perspective ``all`` is just the
    # one-shot subset, hence the alias here.
    if mode not in ("expired-one-shot", "one-shot", "all"):
        raise ValueError(f"unsupported cleanup mode: {mode}")
    return [
        record
        for record in records
        if record["schedule_kind"] == "at"
        and record["next_run_at"] is not None
        and record["next_run_at"] < now
        and record["raw"].get("deleteAfterRun") is True
        and record["enabled"] is False
    ]


def format_cleanup_candidate(record):
    return (
        f"{record['agent']} | {record['name']} | "
        f"scheduled={format_dt(record['next_run_at'])} | "
        f"last={format_dt(record['last_run_at'])} | "
        f"status={record['last_status']}"
    )


# -----------------------------------------------------------------------------
# Issue #533 — run-artifact cleanup helpers.
#
# The 6 surfaces (3 Tier-A + 3 Tier-B) accumulate one entry per cron tick with
# no built-in retention. The helpers below implement the combined-AND deletion
# gate (queue-terminal AND status-terminal AND no-live-pid AND outside floor)
# plus the always-preserve floor that protects quiet weekly jobs from losing
# their only diagnostic.
# -----------------------------------------------------------------------------


def _rmtree_safe(path):
    """Recursively delete; refuse to follow symlinks; never cross a bind mount.

    Mirrors ``bridge-relay-cleanup.py:_rmtree_safe`` so the prune path matches
    the existing telegram-relay cleanup safety contract.
    """
    if path.is_symlink() or not path.is_dir():
        try:
            path.unlink()
        except (FileNotFoundError, IsADirectoryError):
            pass
        return
    for child in path.iterdir():
        _rmtree_safe(child)
    try:
        path.rmdir()
    except OSError:
        pass


def _iter_processes_psutil():
    """Try psutil; return None if unavailable so caller can fall back to ps."""
    try:
        import psutil  # type: ignore[import-not-found]
    except ImportError:
        return None
    items = []
    for proc in psutil.process_iter(["pid", "cmdline"]):
        try:
            cmdline = proc.info.get("cmdline") or []
            pid = int(proc.info["pid"])
        except (KeyError, TypeError, ValueError):
            continue
        if not cmdline:
            continue
        items.append((pid, list(cmdline)))
    return items


def _iter_processes_ps():
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid=,args="],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (
        FileNotFoundError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        OSError,
    ):
        return []
    items = []
    for raw_line in out.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        head, _, rest = line.partition(" ")
        try:
            pid = int(head)
        except ValueError:
            continue
        argv = rest.strip().split()
        if not argv:
            continue
        items.append((pid, argv))
    return items


def _iter_live_processes():
    procs = _iter_processes_psutil()
    if procs is None:
        procs = _iter_processes_ps()
    return procs


def _argv_run_id_match(argv, run_id, target_root):
    """Path-anchored match: argv must reference run_id under ``target_root``.

    Mirrors PR #527 / ``bridge-relay-cleanup.py:_stale_relay_match``: we
    REJECT bare-substring matches against ``run_id`` alone — a foreign
    install on the same host whose argv happens to mention the same
    run_id must NOT cause this install to skip cleanup. The matcher
    insists the run_id appears as a path component under either
    ``<target_root>/state/cron/...`` or ``<target_root>/shared/cron-...``.
    """
    if not argv or not run_id:
        return False
    target_str = str(target_root).rstrip("/")
    if not target_str:
        return False
    rooted_prefixes = (
        target_str + os.sep + "state" + os.sep + "cron" + os.sep,
        target_str + os.sep + "shared" + os.sep + "cron-",
    )
    for token in argv:
        if not token or run_id not in token:
            continue
        if any(token.startswith(prefix) for prefix in rooted_prefixes):
            return True
    return False


def has_live_pid_for_run(run_id, target_root):
    procs = _iter_live_processes()
    self_pid = os.getpid()
    for pid, argv in procs:
        if pid == self_pid:
            continue
        if _argv_run_id_match(argv, run_id, target_root):
            return True
    return False


def _queue_cli_path():
    """Path to the sibling ``bridge-queue.py`` CLI."""
    return Path(__file__).resolve().parent / "bridge-queue.py"


def _lookup_queue_status_via_cli(task_id, *, tasks_db_path):
    """Subprocess to ``bridge-queue.py show <task_id> --format shell`` and
    return the queue status string, or ``None`` when the row cannot be
    read (task not found / queue unavailable / parse error).

    PR #536 r2: keeps the cleanup pass on the queue-first contract
    (CLAUDE.md). The subprocess cost is bounded — GC runs are rare
    (daily-ish) and each artifact requires one short read.
    """
    cmd = [
        sys.executable,
        str(_queue_cli_path()),
        "show",
        str(task_id),
        "--format",
        "shell",
    ]
    env = dict(os.environ)
    # Force the direct (non-gateway) read path. The gateway adds a
    # round-trip we don't need for a status lookup, and would require an
    # operator agent context the cleanup pass doesn't have.
    env.pop("BRIDGE_GATEWAY_PROXY", None)
    env.pop("BRIDGE_AGENT_ID", None)
    if tasks_db_path is not None:
        env["BRIDGE_TASK_DB"] = str(tasks_db_path)
    try:
        completed = subprocess.run(
            cmd, capture_output=True, text=True, timeout=15, check=False, env=env
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    for line in completed.stdout.splitlines():
        if line.startswith("TASK_STATUS="):
            # Shell-format value is shlex-quoted; for a queue status enum
            # ("queued"/"claimed"/"done"/"cancelled"/"blocked"/"in_progress")
            # there are no shell-special characters so a simple strip is
            # sufficient. Use shlex.split to be safe against edge cases.
            try:
                parts = shlex.split(line[len("TASK_STATUS="):])
            except ValueError:
                return None
            return parts[0] if parts else None
    return None


def queue_dispatch_terminal(run_id, target_root, *, tasks_db_path=None, run_dir=None):
    """Return (terminal?, queue_status, dispatch_task_id) for the given run.

    PR #536 r2 contract:
      - The dispatch task_id is resolved from ``request.json`` first, then
        falls back to extracting ``<id>`` from a ``run_id`` of the form
        ``task-<id>`` (used by the worker-artifact surface). Without this
        fallback, a worker artifact whose run-dir was pruned would satisfy
        the queue gate vacuously — Codex r1 finding #1.
      - The status lookup goes through ``bridge-queue.py show --format
        shell`` rather than direct SQLite, honoring the queue-first
        contract in CLAUDE.md (Codex r1 finding #2).
      - When the task_id cannot be identified at all, the gate returns
        ``False`` (NOT terminal). Conservative-on-missing-context: a
        missing-context artifact stays around until the operator can
        investigate. This trades a small amount of long-tail orphan
        retention for safety against the active-artifact bypass.
    """
    if run_dir is None:
        run_dir = Path(target_root) / "state" / "cron" / "runs" / run_id
    request_path = Path(run_dir) / "request.json"

    dispatch_task_id = None
    request_present = request_path.is_file()
    request_parseable = True
    if request_present:
        try:
            request = json.loads(request_path.read_text(encoding="utf-8"))
            raw_task_id = request.get("dispatch_task_id")
            try:
                dispatch_task_id = (
                    int(raw_task_id) if raw_task_id is not None else None
                )
            except (TypeError, ValueError):
                dispatch_task_id = None
        except (OSError, ValueError):
            request_parseable = False

    # Worker-artifact fallback: ``state/cron/workers/task-<id>.{pid,log}``
    # entries are keyed by the queue task id directly (see
    # ``_run_id_from_worker_log``). When the run-dir is missing for these,
    # we still know the task_id — extract it from the run_id rather than
    # treating the missing request.json as "terminal".
    if dispatch_task_id is None and run_id.startswith("task-"):
        suffix = run_id[len("task-"):]
        if suffix.isdigit():
            try:
                dispatch_task_id = int(suffix)
            except (TypeError, ValueError):
                dispatch_task_id = None

    if dispatch_task_id is None:
        # Cannot identify the queue row. Refuse to consider the artifact
        # eligible — better a long-tail orphan than an active bypass.
        if not request_present:
            return False, "missing_task_id:no_request", None
        if not request_parseable:
            return False, "missing_task_id:unparseable_request", None
        return False, "missing_task_id:no_dispatch_task_id", None

    if tasks_db_path is None:
        tasks_db_path = Path(target_root) / "state" / "tasks.db"
    tasks_db_path = Path(tasks_db_path)
    if not tasks_db_path.is_file():
        # No queue DB on disk — be conservative.
        return False, "no_tasks_db", dispatch_task_id

    status = _lookup_queue_status_via_cli(
        dispatch_task_id, tasks_db_path=tasks_db_path
    )
    if status is None:
        # CLI read failed (timeout, parse error, row missing). Conservative
        # on missing context: NOT terminal.
        return False, "queue_lookup_failed", dispatch_task_id
    return status in _QUEUE_TERMINAL_STATUSES, status, dispatch_task_id


def run_status_terminal(run_id, target_root, *, run_dir=None):
    """Return (terminal?, final_state) from state/cron/runs/<run_id>/status.json.

    A run with NO status.json is NOT terminal — the runner has not finished
    writing it yet (or never started). Caller should skip such runs.
    """
    if run_dir is None:
        run_dir = Path(target_root) / "state" / "cron" / "runs" / run_id
    status_path = Path(run_dir) / "status.json"
    if not status_path.is_file():
        return False, None
    try:
        status = json.loads(status_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False, "unparseable_status"
    state_value = str(status.get("state") or "")
    return state_value in _RUN_STATUS_TERMINAL_STATES, state_value


def cron_family_from_run_id(run_id, *, run_dir=None, target_root=None):
    """Best-effort cron-family extraction.

    Strategy:
      1. If ``state/cron/runs/<run_id>/request.json`` exists and has a
         ``job_name`` we can classify, prefer that — it matches the family
         taxonomy used by ``classify_family``.
      2. Otherwise fall back to the run_id naming convention
         ``<safe_name>-<short_id>--<slot_token>``: the prefix before the
         ``--<slot_token>`` separator is the slug; strip the trailing
         ``-<short_id>`` and run that through ``classify_family``.

    Returns a non-empty string. ``"<unknown>"`` if neither approach yields
    a family — those entries land in the synthetic family of the same name
    so the always-preserve floor still applies.
    """
    if not run_id:
        return "<unknown>"
    if run_dir is None and target_root is not None:
        run_dir = Path(target_root) / "state" / "cron" / "runs" / run_id
    if run_dir is not None:
        request_path = Path(run_dir) / "request.json"
        if request_path.is_file():
            try:
                request = json.loads(request_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                request = {}
            job_name = str(
                request.get("job_name")
                or request.get("name")
                or (request.get("job") or {}).get("name")
                or ""
            ).strip()
            if job_name:
                return classify_family(job_name)
    base = run_id.split("--", 1)[0]
    if "-" in base:
        head, tail = base.rsplit("-", 1)
        if head and tail and re.fullmatch(r"[0-9a-fA-F]{4,}", tail):
            base = head
    return classify_family(base) if base else "<unknown>"


def _run_id_from_md(path):
    """For ``shared/cron-{dispatch,result,followup}/<run_id>.md`` surfaces."""
    name = path.name
    if name.endswith(".md"):
        return name[:-3]
    return name


def _run_id_from_worker_log(path):
    """``state/cron/workers/task-<id>.log|.pid`` — keyed by queue task_id."""
    name = path.name
    m = re.match(r"^task-(?P<task_id>\d+)\.(log|pid)$", name)
    if m:
        return f"task-{m.group('task_id')}"
    return name


def _entries_for_runs_dir(runs_root):
    if not runs_root.is_dir() or runs_root.is_symlink():
        return
    for child in sorted(runs_root.iterdir()):
        if child.is_symlink():
            yield {"path": child, "run_id": child.name, "is_symlink": True}
            continue
        if not child.is_dir():
            continue
        yield {"path": child, "run_id": child.name, "is_symlink": False}


def _entries_for_workers_dir(workers_root):
    if not workers_root.is_dir() or workers_root.is_symlink():
        return
    for child in sorted(workers_root.iterdir()):
        if child.is_symlink():
            yield {
                "path": child,
                "run_id": _run_id_from_worker_log(child),
                "is_symlink": True,
            }
            continue
        if not child.is_file():
            continue
        if not re.match(r"^task-\d+\.(log|pid)$", child.name):
            continue
        yield {
            "path": child,
            "run_id": _run_id_from_worker_log(child),
            "is_symlink": False,
        }


def _entries_for_dispatch_dir(dispatch_root):
    """``state/cron/dispatch/<job_slug>/<slot_token>.json`` — each manifest
    file is a per-slot artifact.  Empty parent slug dirs are pruned at the
    end of the cleanup pass."""
    if not dispatch_root.is_dir() or dispatch_root.is_symlink():
        return
    for slug_dir in sorted(dispatch_root.iterdir()):
        if slug_dir.is_symlink():
            yield {"path": slug_dir, "run_id": slug_dir.name, "is_symlink": True}
            continue
        if not slug_dir.is_dir():
            continue
        for manifest in sorted(slug_dir.iterdir()):
            if manifest.is_symlink():
                yield {
                    "path": manifest,
                    "run_id": f"{slug_dir.name}--{manifest.stem}",
                    "is_symlink": True,
                }
                continue
            if not manifest.is_file():
                continue
            yield {
                "path": manifest,
                "run_id": f"{slug_dir.name}--{manifest.stem}",
                "is_symlink": False,
            }


def _entries_for_shared_md_dir(md_root):
    if not md_root.is_dir() or md_root.is_symlink():
        return
    for child in sorted(md_root.iterdir()):
        if child.is_symlink():
            yield {
                "path": child,
                "run_id": _run_id_from_md(child),
                "is_symlink": True,
            }
            continue
        if not child.is_file() or child.suffix != ".md":
            continue
        yield {
            "path": child,
            "run_id": _run_id_from_md(child),
            "is_symlink": False,
        }


def _surface_entries(target_root, surface):
    full = Path(target_root) / surface
    if surface == "state/cron/runs":
        yield from _entries_for_runs_dir(full)
    elif surface == "state/cron/workers":
        yield from _entries_for_workers_dir(full)
    elif surface == "state/cron/dispatch":
        yield from _entries_for_dispatch_dir(full)
    elif surface in RUN_ARTIFACTS_TIER_B_SURFACES:
        yield from _entries_for_shared_md_dir(full)


def _entry_mtime(path):
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def collect_run_artifact_candidates(
    target_root,
    *,
    tier_a_days,
    tier_b_days,
    tasks_db_path=None,
    now_ts=None,
):
    """Walk all 6 surfaces and evaluate the combined deletion gate per entry.

    Returns a list of dicts; see ``_evaluate_entry`` for the shape.

    Eligibility is the combined-AND condition from the issue body:
      (1) queue terminal  AND  (2) status terminal
      AND  (3) no live PID  AND  (4) outside the always-preserve floor.
    Plus a tier-aware age check (Tier-A days vs Tier-B days). For runs in
    ``error`` state we apply only the longer Tier-B clock even on Tier-A
    surfaces — operators get more time to triage failures.
    The always-preserve floor is applied AFTER eligibility evaluation by
    grouping the eligible-by-other-means entries per (surface, family) and
    bumping the latest N=ALWAYS_PRESERVE_FLOOR back to ineligible.
    """
    if now_ts is None:
        now_ts = time.time()
    tier_a_cutoff = now_ts - (tier_a_days * 86400.0)
    tier_b_cutoff = now_ts - (tier_b_days * 86400.0)
    results = []
    for surface in RUN_ARTIFACTS_TIER_A_SURFACES:
        for entry in _surface_entries(target_root, surface):
            results.append(
                _evaluate_entry(
                    target_root,
                    surface,
                    "A",
                    tier_a_cutoff,
                    tier_b_cutoff,
                    entry,
                    tasks_db_path=tasks_db_path,
                )
            )
    for surface in RUN_ARTIFACTS_TIER_B_SURFACES:
        for entry in _surface_entries(target_root, surface):
            results.append(
                _evaluate_entry(
                    target_root,
                    surface,
                    "B",
                    tier_b_cutoff,
                    tier_b_cutoff,
                    entry,
                    tasks_db_path=tasks_db_path,
                )
            )
    _apply_preserve_floor(results)
    return results


def _evaluate_entry(
    target_root,
    surface,
    tier,
    age_cutoff,
    tier_b_cutoff,
    entry,
    *,
    tasks_db_path,
):
    path = entry["path"]
    run_id = entry["run_id"]
    is_symlink = bool(entry.get("is_symlink"))
    mtime = _entry_mtime(path)
    record = {
        "surface": surface,
        "path": path,
        "run_id": run_id,
        "family": "<unknown>",
        "tier": tier,
        "mtime": mtime,
        "is_symlink": is_symlink,
        "eligible": False,
        "skip_reason": None,
        "queue_status": None,
        "run_state": None,
    }
    if is_symlink:
        record["skip_reason"] = "symlink"
        return record
    run_dir = Path(target_root) / "state" / "cron" / "runs" / run_id
    record["family"] = cron_family_from_run_id(
        run_id, run_dir=run_dir, target_root=target_root
    )
    queue_terminal, queue_status, _ = queue_dispatch_terminal(
        run_id, target_root, tasks_db_path=tasks_db_path, run_dir=run_dir
    )
    record["queue_status"] = queue_status
    if not queue_terminal:
        record["skip_reason"] = f"queue_status:{queue_status}"
        return record
    status_terminal, run_state = run_status_terminal(
        run_id, target_root, run_dir=run_dir
    )
    record["run_state"] = run_state
    # If state/cron/runs/<run_id>/ does not exist (e.g. orphaned shared/*.md
    # whose run dir was already purged on a prior pass), treat status as
    # terminal — there is nothing for the runner to still be writing.
    if not run_dir.is_dir():
        status_terminal = True
    if not status_terminal:
        record["skip_reason"] = "run_state_not_terminal"
        return record
    effective_cutoff = age_cutoff
    if run_state in _RUN_STATUS_FAILED_STATES:
        effective_cutoff = min(age_cutoff, tier_b_cutoff)
    if mtime > effective_cutoff:
        record["skip_reason"] = "within_retention"
        return record
    if has_live_pid_for_run(run_id, target_root):
        record["skip_reason"] = "live_pid"
        return record
    record["eligible"] = True
    return record


def _apply_preserve_floor(records):
    """Bump the latest ALWAYS_PRESERVE_FLOOR entries per (surface, family) back
    to ineligible.  This guarantees quiet weekly jobs always have at least
    N=5 diagnostics on each surface, regardless of retention age."""
    groups = defaultdict(list)
    for record in records:
        groups[(record["surface"], record["family"])].append(record)
    for items in groups.values():
        items.sort(key=lambda r: r["mtime"], reverse=True)
        for record in items[:ALWAYS_PRESERVE_FLOOR]:
            if record["eligible"]:
                record["eligible"] = False
                record["skip_reason"] = "preserve_floor"


def _format_artifact_summary(records):
    eligible = [r for r in records if r["eligible"]]
    by_surface = Counter(r["surface"] for r in eligible)
    by_tier = Counter(r["tier"] for r in eligible)
    by_family = Counter(r["family"] for r in eligible)
    skip_counts = Counter(
        r["skip_reason"] for r in records if not r["eligible"] and r["skip_reason"]
    )
    return {
        "eligible_count": len(eligible),
        "scanned_count": len(records),
        "by_surface": dict(by_surface),
        "by_tier": dict(by_tier),
        "by_family": dict(by_family),
        "skip_reasons": dict(skip_counts),
    }


def _serialize_artifact_record(record, *, target_root):
    try:
        rel = str(Path(record["path"]).relative_to(target_root))
    except ValueError:
        rel = str(record["path"])
    return {
        "surface": record["surface"],
        "path": rel,
        "run_id": record["run_id"],
        "family": record["family"],
        "tier": record["tier"],
        "mtime": record["mtime"],
        "eligible": record["eligible"],
        "skip_reason": record["skip_reason"],
        "queue_status": record["queue_status"],
        "run_state": record["run_state"],
    }


def _rel_under(target_root, path):
    p = Path(path)
    try:
        return str(p.relative_to(target_root))
    except ValueError:
        return str(p)


def run_cleanup_run_artifacts(args, *, dry_run):
    """Apply path for ``cleanup-{report,prune} --mode run-artifacts``.

    Audit row policy: counts only + at most 5 sample paths. Payload contents
    are NEVER included — the issue body and the brief both pin this.
    """
    target_root_arg = getattr(args, "target_root", None) or os.environ.get("BRIDGE_HOME") or ""
    target_root = Path(target_root_arg).expanduser() if target_root_arg else Path("")
    if not target_root_arg or not target_root.is_dir():
        payload = {
            "status": "error",
            "mode": "run-artifacts",
            "error": "target_root_missing",
            "target_root": str(target_root),
        }
        if getattr(args, "json", False):
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: error")
            print(f"error: target_root_missing ({target_root})")
        return 2
    target_root = target_root.resolve()
    older_than_days = getattr(args, "older_than_days", None)
    if older_than_days is not None:
        tier_a_days = int(older_than_days)
        tier_b_days = int(older_than_days)
    else:
        tier_a_days = RUN_ARTIFACTS_TIER_A_DEFAULT_DAYS
        tier_b_days = RUN_ARTIFACTS_TIER_B_DEFAULT_DAYS
    tasks_db_path = getattr(args, "tasks_db", None)
    tasks_db_path = Path(tasks_db_path).expanduser() if tasks_db_path else None
    records = collect_run_artifact_candidates(
        target_root,
        tier_a_days=tier_a_days,
        tier_b_days=tier_b_days,
        tasks_db_path=tasks_db_path,
    )
    summary = _format_artifact_summary(records)
    eligible = [r for r in records if r["eligible"]]
    sample_paths = [_rel_under(target_root, r["path"]) for r in eligible[:5]]
    report_only = bool(getattr(args, "_report_only", False))

    payload = {
        "status": "report" if report_only else ("dry_run" if dry_run else "pruned"),
        "mode": "run-artifacts",
        "target_root": str(target_root),
        "tier_a_days": tier_a_days,
        "tier_b_days": tier_b_days,
        "always_preserve_floor": ALWAYS_PRESERVE_FLOOR,
        "summary": summary,
        "sample_paths": sample_paths,
    }

    deleted = 0
    delete_errors = []
    if not dry_run and not report_only:
        for record in eligible:
            path = Path(record["path"])
            try:
                if path.is_symlink():
                    # Defense-in-depth: we already filter symlinks during
                    # the walk, but if one slipped past, refuse.
                    continue
                if path.is_dir():
                    _rmtree_safe(path)
                else:
                    try:
                        path.unlink()
                    except FileNotFoundError:
                        pass
                deleted += 1
            except OSError as exc:
                delete_errors.append({"path": str(path), "error": str(exc)})
        # Best-effort: prune now-empty parent dirs under state/cron/dispatch.
        dispatch_root = target_root / "state" / "cron" / "dispatch"
        if dispatch_root.is_dir():
            for slug_dir in list(dispatch_root.iterdir()):
                if (
                    slug_dir.is_dir()
                    and not slug_dir.is_symlink()
                    and not any(slug_dir.iterdir())
                ):
                    try:
                        slug_dir.rmdir()
                    except OSError:
                        pass
        payload["deleted_count"] = deleted
        if delete_errors:
            payload["delete_errors"] = delete_errors[:10]
            payload["delete_error_count"] = len(delete_errors)

    if getattr(args, "json", False):
        payload["records"] = [
            _serialize_artifact_record(r, target_root=target_root)
            for r in records[:50]
        ]
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print("mode: run-artifacts")
    print(f"target_root: {target_root}")
    print(f"tier_a_days: {tier_a_days}")
    print(f"tier_b_days: {tier_b_days}")
    print(f"always_preserve_floor: {ALWAYS_PRESERVE_FLOOR}")
    print(f"scanned: {summary['scanned_count']}")
    print(f"eligible: {summary['eligible_count']}")
    if summary["by_surface"]:
        print("by_surface:")
        for surface, count in summary["by_surface"].items():
            print(f"- {surface}: {count}")
    if summary["skip_reasons"]:
        print("skip_reasons:")
        for reason, count in summary["skip_reasons"].items():
            print(f"- {reason}: {count}")
    if sample_paths:
        print("sample_paths:")
        for sample in sample_paths:
            print(f"- {sample}")
    if not dry_run and not report_only:
        print(f"deleted: {deleted}")
        if delete_errors:
            print(f"delete_errors: {len(delete_errors)}")
    print(f"status: {payload['status']}")
    return 0


def print_cleanup_report(args, records):
    candidates = sorted(cleanup_candidates(records, args.mode), key=record_sort_key)
    agent_counts = Counter(record["agent"] for record in candidates)
    prefix_counts = Counter(job_prefix(record["name"]) for record in candidates)
    sample_limit = args.limit if args.limit is not None else 20
    samples = candidates if sample_limit == 0 else candidates[:sample_limit]
    criteria = {
        "schedule_kind": "at",
        "scheduled_before_now": True,
        "delete_after_run": True,
        "enabled": False,
    }

    if args.json:
        payload = {
            "source_file": str(Path(args.jobs_file).expanduser()),
            "generated_at": datetime.now().astimezone().isoformat(),
            "mode": args.mode,
            "criteria": criteria,
            "candidate_count": len(candidates),
            "total_jobs": len(records),
            "by_agent": dict(agent_counts),
            "by_prefix": dict(prefix_counts),
            "samples": [serialize_record(record) for record in samples],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print(f"generated_at: {datetime.now().astimezone().isoformat()}")
    print(f"mode: {args.mode}")
    print("criteria: schedule.kind=at, at<now, deleteAfterRun=true, enabled=false")
    print(f"candidate_jobs: {len(candidates)}")
    print(f"total_jobs: {len(records)}")
    print()
    print("by_agent:")
    if not agent_counts:
        print("- none")
    else:
        for agent, count in agent_counts.most_common():
            print(f"- {agent}: {count}")
    print()
    print("by_prefix:")
    if not prefix_counts:
        print("- none")
    else:
        for prefix, count in prefix_counts.most_common():
            print(f"- {prefix}: {count}")
    print()
    print("sample_jobs:")
    if not samples:
        print("- none")
    else:
        for record in samples:
            print(f"- {format_cleanup_candidate(record)}")
        if sample_limit != 0 and len(candidates) > len(samples):
            print(f"- ... ({len(candidates) - len(samples)} more candidates)")
    return 0


def backup_path_for(jobs_path):
    timestamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    return jobs_path.with_name(f"{jobs_path.name}.bak-{timestamp}")


def atomic_write_jobs(jobs_path, raw_payload):
    if isinstance(raw_payload, dict):
        jobs = raw_payload.get("jobs")
        if isinstance(jobs, list):
            for job in jobs:
                if isinstance(job, dict):
                    normalize_job_agent_fields(job)
    suffix = f".{jobs_path.name}.tmp"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=jobs_path.parent, delete=False, suffix=suffix) as fh:
        json.dump(raw_payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
        temp_path = Path(fh.name)
    os.replace(temp_path, jobs_path)


def _audit_log_path():
    """Resolve the bridge audit log path.

    Mirrors `bridge-config.py:audit_log_path()` and the SSOT default in
    `lib/bridge-state.sh:1267` (`$BRIDGE_LOG_DIR/audit.jsonl`). Returns
    `None` only when neither `BRIDGE_AUDIT_LOG` nor `BRIDGE_HOME`/`BRIDGE_LOG_DIR`
    is set — in that case the caller should silently skip the emission so
    smoke fixtures and `--help` invocations do not fail.
    """
    explicit = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    log_dir = os.environ.get("BRIDGE_LOG_DIR", "").strip()
    if log_dir:
        return Path(log_dir).expanduser() / "audit.jsonl"
    home = os.environ.get("BRIDGE_HOME", "").strip()
    if home:
        return Path(home).expanduser() / "logs" / "audit.jsonl"
    return None


def _audit_actor():
    """Caller agent id for audit attribution.

    Prefers `BRIDGE_AGENT_ID` so multi-admin installs can disambiguate
    operator-driven mutations; falls back to `USER` so single-operator
    boxes still record something useful. Matches the convention used in
    `bridge-config.py:115` (`current_agent_id()`).
    """
    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if agent:
        return agent
    return os.environ.get("USER", "unknown") or "unknown"


def emit_cron_mutation_audit(action, target, detail):
    """Append a `cron.<verb>` row to the bridge audit log.

    Routes through `bridge-audit.py write` so the hash chain stays intact
    with hook / config / daemon rows. Best-effort: a failed audit write
    never raises, mirroring the contract documented in
    `bridge-watchdog-silence.py:emit_audit` and `bridge-config.py:write_audit`.

    Issue #628 — operator-driven cron CRUD (`create`, `edit`, `enable`,
    `disable`, `delete`) was previously absent from `audit.jsonl`,
    forcing transcript fishing to recover mutation provenance. Runner
    finalize and bulk admin paths (rebalance / migrate / import) stay
    out of scope; only the four operator verbs go through here.
    """
    audit_path = _audit_log_path()
    if audit_path is None:
        return
    actor = _audit_actor()
    detail_payload = dict(detail or {})
    detail_payload.setdefault("cron_id", target)
    audit_script = Path(__file__).resolve().parent / "bridge-audit.py"
    cmd = [
        sys.executable,
        str(audit_script),
        "write",
        "--file",
        str(audit_path),
        "--actor",
        actor,
        "--action",
        action,
        "--target",
        target,
        "--detail-json",
        json.dumps(detail_payload, ensure_ascii=True, sort_keys=True),
    ]
    try:
        subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=10)
    except (subprocess.SubprocessError, OSError):
        # Audit emission is best-effort — never let it crash a successful
        # cron mutation. Fall back to a direct append so a missing python
        # interpreter doesn't silently swallow the row (matches
        # bridge-config.py:write_audit's fallback contract).
        try:
            audit_path.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "actor": actor,
                "action": action,
                "target": target,
                "detail": detail_payload,
                "pid": os.getpid(),
            }
            with audit_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=True) + "\n")
        except OSError:
            pass


def slugify_title(value):
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip()).strip("-").lower()
    return slug or "job"


def read_payload_argument(payload_text, payload_file):
    if payload_text is not None:
        return payload_text
    if payload_file is not None:
        return Path(payload_file).expanduser().read_text(encoding="utf-8")
    return ""


def parse_shell_env(values):
    env = {}
    for raw in values or []:
        if "=" not in raw:
            raise ValueError("--script-env must be KEY=VALUE")
        key, value = raw.split("=", 1)
        if not re.match(r"^[A-Z_][A-Z0-9_]*$", key):
            raise ValueError(f"invalid --script-env key: {key}")
        if key in SHELL_PROTECTED_ENV_EXACT or key.startswith(SHELL_PROTECTED_ENV_PREFIXES):
            raise ValueError(f"protected env var cannot be set by shell cron payload: {key}")
        if not key.startswith(SHELL_PAYLOAD_ENV_PREFIXES):
            allowed = ", ".join(f"{prefix}*" for prefix in SHELL_PAYLOAD_ENV_PREFIXES)
            raise ValueError(f"shell cron env var must use one of these prefixes: {allowed}: {key}")
        env[key] = value
    return env


def resolve_shell_script(path_value):
    raw = str(path_value or "").strip()
    if not raw:
        raise ValueError("--script is required for --kind shell")
    bridge_home_value = os.environ.get("BRIDGE_HOME")
    if raw == "$BRIDGE_HOME" or raw.startswith("$BRIDGE_HOME/"):
        if not bridge_home_value:
            raise ValueError("--script uses $BRIDGE_HOME but BRIDGE_HOME is not set")
        raw = bridge_home_value + raw[len("$BRIDGE_HOME") :]
    elif "$" in raw:
        raise ValueError("--script contains an unresolved environment variable")
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise ValueError("--script must resolve to an absolute path")
    path = path.resolve()
    try:
        stat_result = path.stat()
    except OSError as exc:
        raise ValueError(f"--script is not accessible: {path}") from exc
    if not path.is_file():
        raise ValueError(f"--script must be a regular file: {path}")
    if not os.access(path, os.X_OK):
        raise ValueError(f"--script must be executable: {path}")
    if stat_result.st_mode & 0o022:
        raise ValueError(f"--script must not be group/other writable: {path}")
    return str(path)


def validate_shell_args(values):
    args = []
    for raw in values or []:
        value = str(raw)
        if SHELL_ARG_FORBIDDEN_RE.search(value):
            raise ValueError(f"--script-arg contains shell metacharacters: {value!r}")
        if "$(" in value or "${" in value:
            raise ValueError(f"--script-arg contains shell expansion syntax: {value!r}")
        args.append(value)
    return args


def build_native_job_shell_payload(args, existing_payload=None, existing_execution=None):
    existing_payload = existing_payload or {}
    existing_execution = existing_execution or {}
    script = args.script if args.script is not None else existing_payload.get("script")
    run_as_agent = args.run_as_agent or existing_execution.get("runAsAgent")
    env_values = args.script_env or []
    arg_values = args.script_arg if args.script_arg is not None else None
    timeout = args.timeout if args.timeout is not None else existing_payload.get("timeoutSeconds", 900)
    output_cap = args.output_cap if args.output_cap is not None else existing_payload.get("outputCapBytes", 65536)

    if not run_as_agent:
        raise ValueError("--run-as-agent is required for --kind shell")
    if str(run_as_agent).isdigit():
        raise ValueError("--run-as-agent must be an agent id, not a numeric UID/user")
    if timeout is None or int(timeout) <= 0:
        raise ValueError("--timeout must be a positive integer")
    if output_cap is None or int(output_cap) <= 0:
        raise ValueError("--output-cap must be a positive integer")

    payload = {
        "kind": "shell",
        "script": resolve_shell_script(script),
        "args": validate_shell_args(arg_values if arg_values is not None else existing_payload.get("args", [])),
        "env": parse_shell_env(env_values) if env_values else dict(existing_payload.get("env") or {}),
        "timeoutSeconds": int(timeout),
        "outputCapBytes": int(output_cap),
    }
    return payload, {"runAsAgent": run_as_agent}


def parse_at_datetime(value):
    parsed = parse_iso_datetime(value)
    if parsed is None:
        raise ValueError(f"invalid --at value: {value}")
    return parsed.isoformat(timespec="seconds")


def resolve_native_job(records, ref):
    return resolve_show_record(records, ref)


def native_job_payload(job):
    payload = job.get("payload") or {}
    return payload.get("text") or payload.get("message") or ""


def build_native_job(
    *,
    job_id,
    title,
    agent,
    schedule_expr,
    at_value,
    tz_name,
    payload_text,
    enabled,
    actor,
    delete_after_run,
    existing_job=None,
    payload=None,
    execution=None,
):
    now_ms_value = now_epoch_ms()
    if at_value is not None:
        schedule = {
            "kind": "at",
            "at": parse_at_datetime(at_value),
        }
    else:
        schedule = {
            "kind": "cron",
            "expr": validate_cron_expr(schedule_expr),
            "tz": tz_name or default_tz_name(),
        }
    job = dict(existing_job or {})
    if payload is None:
        payload = {
            "kind": "text",
            "text": payload_text,
        }
    if execution is None:
        execution = dict(job.get("execution") or {})
    job.update(
        {
            "id": job_id,
            "name": title,
            "agentId": agent,
            "enabled": bool(enabled),
            "createdAtMs": job.get("createdAtMs") or now_ms_value,
            "updatedAtMs": now_ms_value,
            "schedule": schedule,
            "deleteAfterRun": bool(delete_after_run),
            "payload": payload,
            "execution": execution,
            "sessionTarget": "agent-bridge",
            "wakeMode": "queue-dispatch",
            "state": dict(job.get("state") or {}),
            "metadata": {
                **dict(job.get("metadata") or {}),
                "source": "bridge-native",
                "createdBy": actor,
            },
        }
    )
    return job


def print_native_list(args, records):
    filtered = []
    for record in records:
        if args.agent and not agent_matches(record["agent"], args.agent):
            continue
        if args.enabled != "all":
            expected_enabled = args.enabled == "yes"
            if record["enabled"] != expected_enabled:
                continue
        filtered.append(record)

    filtered = sorted(filtered, key=record_sort_key)
    if args.limit not in (None, 0):
        filtered = filtered[: args.limit]

    if args.json:
        payload = {
            "source_file": str(Path(args.jobs_file).expanduser()),
            "generated_at": datetime.now().astimezone().isoformat(),
            "filters": {
                "agent": args.agent,
                "enabled": args.enabled,
                "limit": args.limit,
            },
            "jobs": [serialize_record(record, include_payload=True) for record in filtered],
            "jobs_total": len(filtered),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if not filtered:
        print("(no native cron jobs)")
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print("id  enabled  agent            schedule                title")
    for record in filtered:
        schedule_value = record["schedule_text"]
        if len(schedule_value) > 22:
            schedule_value = schedule_value[:19] + "..."
        print(
            f"{record['id']:<12} "
            f"{('yes' if record['enabled'] else 'no'):<7} "
            f"{record['agent']:<15} "
            f"{schedule_value:<22} "
            f"{record['name']}"
        )
    return 0


def run_native_create(args):
    raw_payload, jobs = load_native_jobs_payload(args.jobs_file)
    records = [build_job_record(job) for job in jobs]
    actor = args.actor or os.environ.get("USER", "unknown")
    title = args.title.strip()
    payload_text = ""
    payload = None
    execution = None
    payload_kind = args.kind or "text"
    if payload_kind == "shell":
        if args.payload is not None or args.payload_file is not None:
            raise ValueError("--payload/--payload-file cannot be used with --kind shell")
        payload, execution = build_native_job_shell_payload(args)
    else:
        payload_text = read_payload_argument(args.payload, args.payload_file)
    # Issue #541 PR-A — default memory-daily payloads to the canonical
    # jsonl-aware body when the operator did not supply one explicitly.
    # Operator-provided payloads (--payload / --payload-file) pass through
    # unchanged so existing override workflows keep working.
    if (
        payload_kind == "text"
        and
        args.payload is None
        and args.payload_file is None
        and classify_family(title) == "memory-daily"
    ):
        payload_text = render_memory_daily_jsonl_aware_prompt(args.agent)
    if payload_kind == "text":
        text_payload: dict = {"kind": "text", "text": payload_text}
        if args.timeout is not None:
            # #1625 r2 (codex BLOCKING): the text path must reject non-positive
            # timeouts too, mirroring the shell path's `--timeout must be a
            # positive integer` guard — otherwise `native-create --timeout 0`
            # persists timeoutSeconds=0 and the runner fails/behaves oddly.
            if int(args.timeout) <= 0:
                raise ValueError("--timeout must be a positive integer")
            text_payload["timeoutSeconds"] = int(args.timeout)
        payload = text_payload
    base_slug = slugify_title(title)
    job_id = f"{base_slug}-{secrets.token_hex(4)}"

    existing = [record for record in records if record["name"] == title and record["agent"] == args.agent]
    if existing:
        raise ValueError(f"native cron job already exists for agent/title: {args.agent} / {title}")

    job = build_native_job(
        job_id=job_id,
        title=title,
        agent=args.agent,
        schedule_expr=args.schedule,
        at_value=args.at,
        tz_name=args.tz,
        payload_text=payload_text,
        enabled=not args.disabled,
        actor=actor,
        delete_after_run=args.delete_after_run,
        payload=payload,
        execution=execution,
    )
    jobs.append(job)
    raw_payload["jobs"] = jobs
    raw_payload["updatedAt"] = datetime.now().astimezone().isoformat()
    jobs_path = Path(args.jobs_file).expanduser()
    jobs_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_jobs(jobs_path, raw_payload)

    # Issue #628 — emit operator-mutation audit row only after the write
    # succeeds so failed creates do not appear in the audit log.
    emit_cron_mutation_audit(
        "cron.create",
        job_id,
        {
            "agent": args.agent,
            "title": title,
            "schedule": dict(job.get("schedule") or {}),
            "enabled": bool(job.get("enabled", True)),
            "delete_after_run": bool(job.get("deleteAfterRun")),
        },
    )

    print(f"created native cron job {job_id} for {args.agent}")
    return 0


def run_native_update(args):
    raw_payload, jobs = load_native_jobs_payload(args.jobs_file)
    records = [build_job_record(job) for job in jobs]
    actor = args.actor or os.environ.get("USER", "unknown")
    try:
        record = resolve_native_job(records, args.job_ref)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    job_index = next((index for index, job in enumerate(jobs) if job.get("id") == record["id"]), -1)
    if job_index < 0:
        print(f"error: native job not found: {args.job_ref}", file=sys.stderr)
        return 2

    existing = dict(jobs[job_index])
    existing_payload = dict(existing.get("payload") or {})
    existing_payload_kind = existing_payload.get("kind") or "text"
    title = args.title.strip() if args.title is not None else existing.get("name", record["name"])
    agent = args.agent or existing.get("agentId") or existing.get("agent") or record["agent"]
    schedule = existing.get("schedule") or {}
    schedule_kind = schedule.get("kind") or "cron"
    schedule_expr = args.schedule or (schedule.get("expr") if schedule_kind == "cron" else "") or ""
    at_value = args.at or (schedule.get("at") if schedule_kind == "at" else None)
    tz_name = args.tz or schedule.get("tz") or default_tz_name()
    requested_kind = args.kind
    shell_fields_present = any(
        value is not None
        for value in (args.script, args.run_as_agent, args.output_cap)
    ) or bool(args.script_arg) or bool(args.script_env)
    text_fields_present = args.payload is not None or args.payload_file is not None
    if requested_kind is None:
        if shell_fields_present:
            requested_kind = "shell"
        elif text_fields_present:
            requested_kind = "text"
        else:
            requested_kind = existing_payload_kind
    if requested_kind != existing_payload_kind and not args.allow_kind_transition:
        raise ValueError(
            f"payload kind transition {existing_payload_kind!r} -> {requested_kind!r} requires --allow-kind-transition"
        )
    if requested_kind == "shell" and text_fields_present:
        raise ValueError("--payload/--payload-file cannot be used with --kind shell")
    if requested_kind == "text" and shell_fields_present:
        raise ValueError("shell payload options require --kind shell")

    payload_text = native_job_payload(existing)
    payload = None
    execution = None
    if requested_kind == "shell":
        payload, execution = build_native_job_shell_payload(
            args,
            existing_payload=existing_payload if existing_payload_kind == "shell" else None,
            existing_execution=existing.get("execution") or {},
        )
    else:
        execution = {}
        if text_fields_present:
            payload_text = read_payload_argument(args.payload, args.payload_file)
        text_timeout = args.timeout if args.timeout is not None else existing_payload.get("timeoutSeconds")
        # #1625 r2 (codex BLOCKING): validate the user-supplied --timeout on the
        # text update path (a positive-integer guard mirroring the shell path);
        # inherited existing values are left as-is so editing a legacy job that
        # predates this guard is not blocked.
        if args.timeout is not None and int(args.timeout) <= 0:
            raise ValueError("--timeout must be a positive integer")
        text_payload_: dict = {"kind": "text", "text": payload_text}
        if text_timeout is not None:
            text_payload_["timeoutSeconds"] = int(text_timeout)
        payload = text_payload_

    enabled = existing.get("enabled", True)
    if args.enable:
        enabled = True
    if args.disable:
        enabled = False
    delete_after_run = bool(existing.get("deleteAfterRun"))
    if args.delete_after_run:
        delete_after_run = True
    if args.keep_after_run:
        delete_after_run = False

    updated_job = build_native_job(
        job_id=record["id"],
        title=title,
        agent=agent,
        schedule_expr=schedule_expr,
        at_value=at_value,
        tz_name=tz_name,
        payload_text=payload_text,
        enabled=enabled,
        actor=actor,
        delete_after_run=delete_after_run,
        existing_job=existing,
        payload=payload,
        execution=execution,
    )
    jobs[job_index] = updated_job
    raw_payload["jobs"] = jobs
    raw_payload["updatedAt"] = datetime.now().astimezone().isoformat()
    atomic_write_jobs(Path(args.jobs_file).expanduser(), raw_payload)

    # Issue #628 — pick the audit verb based on what actually changed.
    # `--enable` / `--disable` flips alone get a dedicated `cron.enable`
    # or `cron.disable` row; everything else (schedule / title / payload /
    # tz / agent / delete-after-run) records as `cron.edit` with prev/next
    # snapshots so multi-admin installs can attribute the change.
    prev_enabled = bool(existing.get("enabled", True))
    next_enabled = bool(enabled)
    prev_schedule = dict(existing.get("schedule") or {})
    next_schedule = dict(updated_job.get("schedule") or {})
    prev_title = existing.get("name") or record.get("name") or ""
    next_title = updated_job.get("name") or title
    prev_agent = existing.get("agentId") or existing.get("agent") or record.get("agent") or ""
    next_agent = updated_job.get("agentId") or updated_job.get("agent") or agent
    prev_delete_after = bool(existing.get("deleteAfterRun"))
    next_delete_after = bool(updated_job.get("deleteAfterRun"))
    non_enable_changed = (
        prev_schedule != next_schedule
        or prev_title != next_title
        or prev_agent != next_agent
        or prev_delete_after != next_delete_after
        or args.payload is not None
        or args.payload_file is not None
    )
    if not non_enable_changed and prev_enabled != next_enabled:
        action = "cron.enable" if next_enabled else "cron.disable"
        emit_cron_mutation_audit(
            action,
            record["id"],
            {
                "agent": next_agent,
                "title": next_title,
                "prev_enabled": prev_enabled,
                "next_enabled": next_enabled,
            },
        )
    else:
        emit_cron_mutation_audit(
            "cron.edit",
            record["id"],
            {
                "agent": next_agent,
                "title": next_title,
                "prev": {
                    "schedule": prev_schedule,
                    "enabled": prev_enabled,
                    "title": prev_title,
                    "agent": prev_agent,
                    "delete_after_run": prev_delete_after,
                },
                "next": {
                    "schedule": next_schedule,
                    "enabled": next_enabled,
                    "title": next_title,
                    "agent": next_agent,
                    "delete_after_run": next_delete_after,
                },
            },
        )

    print(f"updated native cron job {record['id']}")
    return 0


def run_native_delete(args):
    raw_payload, jobs = load_native_jobs_payload(args.jobs_file)
    records = [build_job_record(job) for job in jobs]
    try:
        record = resolve_native_job(records, args.job_ref)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    remaining_jobs = [job for job in jobs if job.get("id") != record["id"]]
    if len(remaining_jobs) == len(jobs):
        print(f"error: native job not found: {args.job_ref}", file=sys.stderr)
        return 2

    deleted_job = next((job for job in jobs if job.get("id") == record["id"]), None) or {}
    raw_payload["jobs"] = remaining_jobs
    raw_payload["updatedAt"] = datetime.now().astimezone().isoformat()
    atomic_write_jobs(Path(args.jobs_file).expanduser(), raw_payload)

    # Issue #628 — capture the deleted job's identity in the audit row so
    # operators can reconstruct what was removed without re-reading the
    # backup file.
    emit_cron_mutation_audit(
        "cron.delete",
        record["id"],
        {
            "agent": deleted_job.get("agentId") or deleted_job.get("agent") or record.get("agent") or "",
            "title": deleted_job.get("name") or record.get("name") or "",
            "schedule": dict(deleted_job.get("schedule") or {}),
            "enabled": bool(deleted_job.get("enabled", True)),
        },
    )

    print(f"deleted native cron job {record['id']}")
    return 0


def run_native_rebalance_memory_daily(args):
    raw_payload, jobs = load_native_jobs_payload(args.jobs_file)
    updated_jobs = []
    changed = []
    unchanged = []
    actor = args.actor or os.environ.get("USER", "unknown")
    schedule_expr = validate_cron_expr(args.schedule)
    tz_name = args.tz or "Asia/Seoul"
    now_ms_value = now_epoch_ms()

    for job in jobs:
        name = str(job.get("name") or "")
        if classify_family(name) != "memory-daily":
            unchanged.append({"id": job.get("id"), "name": name})
            updated_jobs.append(job)
            continue

        schedule = dict(job.get("schedule") or {})
        before = {
            "kind": schedule.get("kind") or "",
            "expr": schedule.get("expr") or "",
            "tz": schedule.get("tz") or "",
        }
        after = {
            "kind": "cron",
            "expr": schedule_expr,
            "tz": tz_name,
        }
        if before == after:
            unchanged.append({"id": job.get("id"), "name": name})
            updated_jobs.append(job)
            continue

        updated = dict(job)
        updated["schedule"] = after
        updated["updatedAtMs"] = now_ms_value
        metadata = dict(updated.get("metadata") or {})
        metadata["updatedBy"] = actor
        updated["metadata"] = metadata
        updated_jobs.append(updated)
        changed.append(
            {
                "id": updated.get("id"),
                "name": name,
                "agent": updated.get("agentId") or updated.get("agent"),
                "before": before,
                "after": after,
            }
        )

    payload = {
        "jobs_file": str(Path(args.jobs_file).expanduser()),
        "schedule": schedule_expr,
        "tz": tz_name,
        "changed_jobs": changed,
        "changed_count": len(changed),
        "unchanged_count": len(unchanged),
        "dry_run": bool(args.dry_run),
    }

    if not args.dry_run and changed:
        raw_payload["jobs"] = updated_jobs
        raw_payload["updatedAt"] = datetime.now().astimezone().isoformat()
        atomic_write_jobs(Path(args.jobs_file).expanduser(), raw_payload)

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print(f"jobs_file: {payload['jobs_file']}")
    print(f"schedule: {schedule_expr} {tz_name}")
    print(f"changed_count: {len(changed)}")
    print(f"unchanged_count: {len(unchanged)}")
    if changed:
        print("changed_jobs:")
        for item in changed:
            before = item["before"]
            print(
                "  - {job_id} {name} ({agent}): {kind} {expr} {tz} -> cron {new_expr} {new_tz}".format(
                    job_id=item["id"],
                    name=item["name"],
                    agent=item["agent"],
                    kind=before["kind"] or "-",
                    expr=before["expr"] or "-",
                    tz=before["tz"] or "-",
                    new_expr=schedule_expr,
                    new_tz=tz_name,
                )
            )
    return 0


def run_migrate_payloads(args):
    """Rewrite memory-daily job payloads to the canonical jsonl-aware body.

    Issue #541 PR-A. Idempotent: jobs whose payload already passes
    memory_daily_payload_is_jsonl_aware() are counted as `unchanged` and
    are not modified. Non-memory-daily jobs are left strictly untouched
    (counted as `skipped_non_memory_daily`). On any mutation a
    jobs.json.bak-<timestamp> backup is written first, mirroring the
    cleanup-prune convention.
    """
    raw_payload, jobs = load_jobs_payload(args.jobs_file)
    jobs_path = Path(args.jobs_file).expanduser()

    migrated = []
    unchanged = []
    skipped_non_memory_daily = 0
    updated_jobs = []

    for job in jobs:
        name = str(job.get("name") or "")
        if classify_family(name) != "memory-daily":
            skipped_non_memory_daily += 1
            updated_jobs.append(job)
            continue

        payload = job.get("payload") or {}
        text = payload.get("text") or payload.get("message") or ""
        if memory_daily_payload_is_jsonl_aware(text):
            unchanged.append({"id": job.get("id"), "name": name})
            updated_jobs.append(job)
            continue

        agent = job.get("agentId") or job.get("agent") or ""
        canonical = render_memory_daily_jsonl_aware_prompt(agent)
        updated = dict(job)
        updated_payload = dict(payload)
        updated_payload["text"] = canonical
        # Preserve the original payload kind ("text") if it was set, else
        # default to "text" — the runner reads .text either way (see
        # native_job_payload()), but write the kind explicitly for parity
        # with build_native_job().
        if not updated_payload.get("kind"):
            updated_payload["kind"] = "text"
        updated["payload"] = updated_payload
        updated_jobs.append(updated)
        migrated.append({"id": updated.get("id"), "name": name, "agent": agent})

    backup_file = None
    will_write = bool(migrated) and not args.dry_run

    if will_write:
        backup_path = backup_path_for(jobs_path)
        backup_path.write_text(jobs_path.read_text(encoding="utf-8"), encoding="utf-8")
        backup_file = str(backup_path)
        if isinstance(raw_payload, dict):
            next_payload = dict(raw_payload)
            next_payload["jobs"] = updated_jobs
            next_payload["updatedAt"] = datetime.now().astimezone().isoformat()
        else:
            next_payload = updated_jobs
        atomic_write_jobs(jobs_path, next_payload)

    payload_out = {
        "migrated": len(migrated),
        "unchanged": len(unchanged),
        "skipped_non_memory_daily": skipped_non_memory_daily,
        "backup_file": backup_file,
        "dry_run": bool(args.dry_run),
    }

    if args.json:
        print(json.dumps(payload_out, ensure_ascii=False, indent=2))
        return 0

    print(f"jobs_file: {jobs_path}")
    print(f"migrated: {payload_out['migrated']}")
    print(f"unchanged: {payload_out['unchanged']}")
    print(f"skipped_non_memory_daily: {payload_out['skipped_non_memory_daily']}")
    print(f"dry_run: {'yes' if payload_out['dry_run'] else 'no'}")
    if backup_file:
        print(f"backup_file: {backup_file}")
    if migrated:
        print("migrated_jobs:")
        for item in migrated:
            print(f"  - {item['id']} {item['name']} ({item['agent']})")
    return 0


def _cron_consecutive_failure_escalation(consecutive_errors):
    """Decide whether this failure crosses the escalation threshold/cadence.

    Issue #1843 (secondary footgun). Returns True exactly when an alert
    should fire for `consecutive_errors`:

    - the first time the counter reaches CRON_CONSECUTIVE_FAILURE_ESCALATE_AT
      (so a chronically-broken job surfaces early), and
    - every CRON_CONSECUTIVE_FAILURE_RENOTIFY_EVERY failures thereafter (so a
      job that stays broken keeps surfacing without alerting on every run).

    Deterministic in the counter alone — no clock, no state read — so the
    smoke can pin every boundary. Below the threshold returns False.
    """
    try:
        n = int(consecutive_errors)
    except (TypeError, ValueError):
        return False
    if n < CRON_CONSECUTIVE_FAILURE_ESCALATE_AT:
        return False
    if n == CRON_CONSECUTIVE_FAILURE_ESCALATE_AT:
        return True
    return (n - CRON_CONSECUTIVE_FAILURE_ESCALATE_AT) % CRON_CONSECUTIVE_FAILURE_RENOTIFY_EVERY == 0


def _emit_cron_consecutive_failure_audit(job_id, agent, consecutive_errors, last_error, run_id):
    """Append a `cron_consecutive_failure_escalated` row to the audit log.

    Best-effort (reuses emit_cron_mutation_audit's never-raise contract). This
    is the durable, machine-agnostic escalation signal #1843 pins: a human /
    admin agent watching the audit chain sees the back-to-back-failure trip
    even when the run's own `delivery_intent` is `silent`.
    """
    emit_cron_mutation_audit(
        "cron_consecutive_failure_escalated",
        str(job_id),
        {
            "job_id": str(job_id),
            "agent": str(agent or "<unknown>"),
            "consecutive_errors": int(consecutive_errors),
            "threshold": CRON_CONSECUTIVE_FAILURE_ESCALATE_AT,
            "last_error": str(last_error or ""),
            "run_id": str(run_id or ""),
        },
    )


def run_native_finalize(args):
    jobs_path = Path(args.jobs_file).expanduser().resolve()
    request_path = Path(args.request_file).expanduser().resolve()
    if not request_path.is_file():
        raise FileNotFoundError(f"request file not found: {request_path}")

    request = json.loads(request_path.read_text(encoding="utf-8"))
    source_file = str(request.get("source_file") or "").strip()
    if not source_file:
        payload = {
            "status": "skipped",
            "reason": "missing_source_file",
            "request_file": str(request_path),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2) if args.json else "status: skipped\nreason: missing_source_file")
        return 0

    source_path = Path(source_file).expanduser().resolve()
    if source_path != jobs_path:
        payload = {
            "status": "skipped",
            "reason": "non_native_source",
            "request_file": str(request_path),
            "source_file": str(source_path),
            "jobs_file": str(jobs_path),
        }
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: skipped")
            print("reason: non_native_source")
            print(f"source_file: {source_path}")
            print(f"jobs_file: {jobs_path}")
        return 0

    raw_payload, jobs = load_native_jobs_payload(jobs_path)
    job_id = str(request.get("job_id") or "").strip()
    run_id = str(request.get("run_id") or request_path.parent.name).strip()
    result_file = Path(str(request.get("result_file") or "")).expanduser()
    status_file = Path(str(request.get("status_file") or "")).expanduser()
    result = json.loads(result_file.read_text(encoding="utf-8")) if result_file.is_file() else {}
    status = json.loads(status_file.read_text(encoding="utf-8")) if status_file.is_file() else {}

    job_index = next((index for index, job in enumerate(jobs) if job.get("id") == job_id), -1)
    if job_index < 0:
        payload = {
            "status": "skipped",
            "reason": "job_not_found",
            "job_id": job_id,
            "run_id": run_id,
        }
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: skipped")
            print("reason: job_not_found")
            print(f"job_id: {job_id}")
            print(f"run_id: {run_id}")
        return 0

    job = dict(jobs[job_index])
    schedule = job.get("schedule") or {}
    job_state = dict(job.get("state") or {})
    run_state = str(status.get("state") or "")
    result_status = str(result.get("status") or "")
    now_ms_value = now_epoch_ms()
    # Three terminal run states feed finalize:
    #   * "success"  — engine ran and produced a non-error result.
    #   * "deferred" — runner short-circuited (e.g. #263 Track B pre-flight
    #                  memory guard). NOT a failure; the slot must re-fire and
    #                  the consecutive-error counter must NOT advance.
    #   * anything else (incl. "error") — treated as failure.
    if run_state == "deferred":
        final_status = "deferred"
    elif run_state == "success" and result_status != "error":
        final_status = "success"
    else:
        final_status = "error"

    # #627: A deferral that lands after the operator disables the job
    # must not mutate state — disable should be idempotent. The dispatcher
    # contract says only enabled jobs get scheduled, so a deferred slot
    # finishing on a disabled job is an inflight-after-disable race.
    # Drop the deferral provenance update entirely (no lastDeferredAtMs,
    # nextRunAtMs, or updatedAtMs bump) so `agb cron show` keeps showing
    # the disable timestamp as the last mutation. The success/error paths
    # are intentionally NOT gated here — they carry consecutive-error
    # accounting that operators may still want recorded; #628 (audit gap)
    # tracks broader trace coverage separately.
    if final_status == "deferred" and not job.get("enabled", True):
        print(
            f"info: dropping deferred state writer for disabled job "
            f"{job_id} run={run_id}",
            file=sys.stderr,
        )
        payload = {
            "status": "skipped",
            "reason": "job_disabled",
            "job_id": job_id,
            "run_id": run_id,
            "final_status": final_status,
            "jobs_file": str(jobs_path),
        }
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: skipped")
            print("reason: job_disabled")
            print(f"job_id: {job_id}")
            print(f"run_id: {run_id}")
            print(f"final_status: {final_status}")
            print(f"jobs_file: {jobs_path}")
        return 0

    duration_ms = result.get("duration_ms")
    try:
        duration_ms = int(duration_ms) if duration_ms not in (None, "") else None
    except (TypeError, ValueError):
        duration_ms = None

    job_state["lastRunAtMs"] = now_ms_value
    job_state["lastStatus"] = final_status
    job_state["lastRunStatus"] = final_status
    if duration_ms is not None:
        job_state["lastDurationMs"] = duration_ms

    # PR2 — persist the cron-runner reporting trio onto the job state so
    # `agb cron show` / `agb cron list --json` can trace the most recent
    # cron → inbox → main flow without grepping `state/cron/runs/`.
    # Both result.json and status.json carry the trio (PR1's
    # write_status / result_payload writers); prefer result.json since
    # the runner finalises that one last and falls back to status.json
    # for runs that never produced a result.
    last_reporting_decision = str(
        result.get("reporting_decision") or status.get("reporting_decision") or ""
    ).strip()
    if last_reporting_decision:
        job_state["lastReportingDecision"] = last_reporting_decision
    last_delivery_intent = str(
        result.get("delivery_intent") or status.get("delivery_intent") or ""
    ).strip()
    if last_delivery_intent:
        job_state["lastDeliveryIntent"] = last_delivery_intent
    last_inbox_task_id = result.get("inbox_task_id")
    if last_inbox_task_id is None:
        last_inbox_task_id = status.get("inbox_task_id")
    if last_inbox_task_id is not None:
        try:
            job_state["lastInboxTaskId"] = int(last_inbox_task_id)
        except (TypeError, ValueError):
            # Non-int task ids should never reach here under PR1's writer
            # contract, but if they do we keep the string so the dashboard
            # can still render *something* identifying the task row.
            job_state["lastInboxTaskId"] = str(last_inbox_task_id)

    # Issue #1843 — escalation block surfaced to the shell wrapper; stays None
    # except on the failure branch when the threshold/cadence trips.
    finalize_escalation = None

    if final_status == "success":
        job_state["nextRunAtMs"] = 0
        job_state["consecutiveErrors"] = 0
        job_state.pop("lastErrorAtMs", None)
        job_state.pop("lastError", None)
        job_state.pop("lastEscalatedErrorCount", None)
        # Issue #614: clear deferred-retry provenance so the next deferral
        # captures a fresh original slot.
        job_state.pop("deferredRetryOfSlot", None)
        job_state.pop("deferredRetryOfOccurrenceAt", None)
        job_state.pop("deferredRetryAttempt", None)
        job_state.pop("deferredFirstAt", None)
    elif final_status == "deferred":
        # #263 Track B: the runner asked us to defer this slot for
        # `deferred_seconds`. Push nextRunAtMs forward by that window so
        # operators reading the dashboard see the actual re-fire time, and
        # leave the consecutive-error counter / lastError fields untouched.
        try:
            deferred_seconds = int(status.get("deferred_seconds") or 0)
        except (TypeError, ValueError):
            deferred_seconds = 0
        if deferred_seconds <= 0:
            deferred_seconds = 900  # mirror PRESSURE_DEFER_SECONDS default
        job_state["nextRunAtMs"] = now_ms_value + (deferred_seconds * 1000)
        job_state["lastDeferredAtMs"] = now_ms_value
        deferred_reason = str(status.get("deferred_reason") or "").strip()
        if deferred_reason:
            job_state["lastDeferredReason"] = deferred_reason

        # Issue #614: persist deferred-retry provenance so the scheduler can
        # re-fire the slot with a new transport identity (slot/run_id).
        # Reusing the original slot is unsafe — `bridge-cron.sh:516-575` keys
        # run_id, request.json, and the dispatch manifest off slot, and an
        # existing manifest with `dispatch_task_id` returns
        # `status: already_enqueued`. So the retry needs a *new* slot, but
        # the original slot/occurrence must be preserved as provenance for
        # audit and so the scheduler can clear nextRunAtMs cleanly on success.
        request_slot = str(request.get("slot") or "").strip()
        if request_slot and "deferredRetryOfSlot" not in job_state:
            job_state["deferredRetryOfSlot"] = request_slot
            job_state["deferredRetryOfOccurrenceAt"] = request_slot
        try:
            previous_attempt = int(job_state.get("deferredRetryAttempt") or 0)
        except (TypeError, ValueError):
            previous_attempt = 0
        job_state["deferredRetryAttempt"] = previous_attempt + 1
        if "deferredFirstAt" not in job_state:
            job_state["deferredFirstAt"] = datetime.now().astimezone().isoformat(timespec="seconds")
    else:
        job_state["nextRunAtMs"] = 0
        # Issue #614: clear deferred-retry provenance so a future deferral
        # captures a fresh original slot.
        job_state.pop("deferredRetryOfSlot", None)
        job_state.pop("deferredRetryOfOccurrenceAt", None)
        job_state.pop("deferredRetryAttempt", None)
        job_state.pop("deferredFirstAt", None)
        try:
            previous_errors = int(job_state.get("consecutiveErrors") or 0)
        except (TypeError, ValueError):
            previous_errors = 0
        consecutive_errors = previous_errors + 1
        job_state["consecutiveErrors"] = consecutive_errors
        job_state["lastErrorAtMs"] = now_ms_value
        job_state["lastError"] = (
            result.get("runner_error")
            or status.get("error")
            or result.get("summary")
            or "cron run failed"
        )
        # Issue #1843 (secondary footgun) — trip a human-visible escalation
        # when a recurring cron fails back-to-back past the threshold/cadence,
        # so a chronically-broken job (e.g. the iso text-payload tamper-check
        # failure that fixed under #1842) can no longer accumulate silently for
        # days. The audit row is the durable signal; `finalize_escalation` is
        # surfaced in the payload so the shell wrapper can also notify the
        # owning agent. `lastEscalatedErrorCount` records the last count we
        # alerted on for provenance / dashboard use.
        if _cron_consecutive_failure_escalation(consecutive_errors):
            finalize_escalation = {
                "kind": "consecutive_failure",
                "agent": job.get("agentId") or job.get("agent") or "<unknown>",
                "consecutive_errors": consecutive_errors,
                "threshold": CRON_CONSECUTIVE_FAILURE_ESCALATE_AT,
                "last_error": job_state["lastError"],
            }
            job_state["lastEscalatedErrorCount"] = consecutive_errors
            _emit_cron_consecutive_failure_audit(
                job_id,
                finalize_escalation["agent"],
                consecutive_errors,
                job_state["lastError"],
                run_id,
            )

    action = "updated"
    if schedule.get("kind") == "at":
        if final_status == "deferred":
            # One-shot "at" runs that deferred must stay enabled and pending so
            # the next scheduler pass re-fires the slot.
            job["state"] = job_state
            job["updatedAtMs"] = now_ms_value
            jobs[job_index] = job
        elif job.get("deleteAfterRun") is True:
            del jobs[job_index]
            action = "deleted"
        else:
            job["enabled"] = False
            job["state"] = job_state
            job["updatedAtMs"] = now_ms_value
            jobs[job_index] = job
            action = "disabled"
    else:
        job["state"] = job_state
        job["updatedAtMs"] = now_ms_value
        jobs[job_index] = job

    raw_payload["jobs"] = jobs
    raw_payload["updatedAt"] = datetime.now().astimezone().isoformat()
    atomic_write_jobs(jobs_path, raw_payload)

    payload = {
        "status": "ok",
        "action": action,
        "job_id": job_id,
        "run_id": run_id,
        "final_status": final_status,
        "jobs_file": str(jobs_path),
    }
    # Issue #1843 — surface the consecutive-failure escalation so the shell
    # wrapper (run_finalize) can notify the owning agent in addition to the
    # durable audit row already written above.
    if finalize_escalation is not None:
        payload["escalation"] = finalize_escalation
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print("status: ok")
        print(f"action: {action}")
        print(f"job_id: {job_id}")
        print(f"run_id: {run_id}")
        print(f"final_status: {final_status}")
        print(f"jobs_file: {jobs_path}")
        if finalize_escalation is not None:
            print(
                "escalation: consecutive_failure "
                f"agent={finalize_escalation['agent']} "
                f"consecutive_errors={finalize_escalation['consecutive_errors']} "
                f"threshold={finalize_escalation['threshold']}"
            )
    return 0


def run_native_import(args):
    source_path = Path(args.source_jobs_file).expanduser()
    target_path = Path(args.jobs_file).expanduser()
    raw_payload, jobs = load_jobs_payload(source_path)
    imported_jobs = [dict(job) for job in jobs if isinstance(job, dict)]
    result = {
        "source_file": str(source_path),
        "target_file": str(target_path),
        "total_jobs": len(jobs),
        "imported_jobs": len(imported_jobs),
    }
    if args.dry_run:
        result["status"] = "dry_run"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    target_path.parent.mkdir(parents=True, exist_ok=True)
    backup_file = None
    if target_path.exists():
        backup_file = backup_path_for(target_path)
        backup_file.write_text(target_path.read_text(encoding="utf-8"), encoding="utf-8")

    next_payload = raw_payload if isinstance(raw_payload, dict) else {"jobs": imported_jobs}
    next_payload["format"] = "agent-bridge-cron-v1"
    next_payload["updatedAt"] = datetime.now().astimezone().isoformat()
    next_payload["metadata"] = {
        **dict(next_payload.get("metadata") or {}),
        "source": "native-import",
        "importedFrom": str(source_path),
    }
    next_payload["jobs"] = imported_jobs
    atomic_write_jobs(target_path, next_payload)

    result["status"] = "imported"
    if backup_file is not None:
        result["backup_file"] = str(backup_file)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


# Issue #1459 — terminal cron run states. A run in any of these is "done"
# from the reconciler's point of view and is never re-touched.
_CRON_RECONCILE_TERMINAL_STATES = {"cancelled", "success", "error", "timed_out"}


def _cron_reconcile_path_present(path_str):
    """Best-effort `exists()` for a reconcile worker-evidence path.

    Controller-only helper (the reconciler runs as the controller, never
    as an iso UID), so the raw `os.path.exists` call is whitelisted for
    `lint-raw-pathlib-on-isolated`. Swallows any OSError so a permission
    or race surface degrades to "no evidence" rather than aborting the
    whole reconcile pass.
    """
    if not path_str:
        return False
    try:
        return os.path.exists(path_str)  # noqa: raw-pathlib-controller-only
    except OSError:
        return False


def _cron_reconcile_worker_evidence(request, runs_run_dir, worker_dir, dispatch_task_id):
    """Return True when there is live/recent worker evidence for a run.

    Evidence is any of: a worker pid/log file under `worker_dir`
    (`task-<id>.pid` / `task-<id>.log`), a terminal `result.json` for the
    run, or stdout/stderr logs the runner created. The reconciler uses
    the ABSENCE of all of these (past the grace window) to classify a
    queued/running run as lost rather than merely in-flight.
    """
    if worker_dir:
        if _cron_reconcile_path_present(os.path.join(worker_dir, f"task-{dispatch_task_id}.pid")):
            return True
        if _cron_reconcile_path_present(os.path.join(worker_dir, f"task-{dispatch_task_id}.log")):
            return True
    result_file = str(request.get("result_file") or os.path.join(str(runs_run_dir), "result.json"))
    if _cron_reconcile_path_present(result_file):
        return True
    for log_key, default_name in (("stdout_log", "stdout.log"), ("stderr_log", "stderr.log")):
        candidate = str(request.get(log_key) or os.path.join(str(runs_run_dir), default_name))
        if _cron_reconcile_path_present(candidate):
            return True
    return False


def _cron_reconcile_age_seconds(status, request, now_dt):
    """Best-effort age in seconds since the run's last known transition.

    Prefers status.json `updated_at`, then `started_at`, then the
    request's `created_at`. Returns None when no parseable timestamp is
    available so the caller can fall back to "no grace evidence" handling.
    """
    for source in (status.get("updated_at"), status.get("started_at"), request.get("created_at")):
        if not source:
            continue
        try:
            ts_dt = datetime.fromisoformat(str(source))
        except ValueError:
            continue
        if ts_dt.tzinfo is None:
            ts_dt = ts_dt.replace(tzinfo=timezone.utc)
        return max(0.0, (now_dt - ts_dt).total_seconds())
    return None


def _cron_reconcile_emit_audit(reason, run_id, task_id, queue_status, state_before, state_after, status_file, result_file):
    """Emit a `cron_dispatch_reconcile` audit row (best-effort).

    Distinct from the human-unclaimed/nudge taxonomy by design (#1459):
    split-brain run/queue repairs are NEVER reported as
    `task_unclaimed_escalated` or `session_nudge_*`.
    """
    emit_cron_mutation_audit(
        "cron_dispatch_reconcile",
        str(run_id),
        {
            "run_id": str(run_id),
            "task_id": task_id,
            "queue_status": queue_status,
            "run_state_before": state_before,
            "run_state_after": state_after,
            "reason": reason,
            "status_file": str(status_file),
            "result_file": str(result_file),
        },
    )


def run_reconcile_run_state(args):
    tasks_db = Path(args.tasks_db).expanduser().resolve()
    runs_dir = Path(args.runs_dir).expanduser().resolve()
    worker_dir = ""
    if getattr(args, "worker_dir", None):
        worker_dir = str(Path(args.worker_dir).expanduser())
    grace_seconds = float(getattr(args, "grace_seconds", 0) or 0)
    repaired = []
    scanned = 0

    if not tasks_db.is_file() or not runs_dir.is_dir():
        payload = {
            "status": "ok",
            "scanned_runs": 0,
            "repaired_runs": 0,
        }
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: ok")
            print("scanned_runs: 0")
            print("repaired_runs: 0")
        return 0

    now_dt = datetime.now(timezone.utc)

    with sqlite3.connect(tasks_db) as conn:
        conn.row_factory = sqlite3.Row
        for request_path in sorted(runs_dir.glob("*/request.json")):
            scanned += 1
            try:
                request = json.loads(request_path.read_text(encoding="utf-8"))
            except Exception:
                continue

            dispatch_task_id = request.get("dispatch_task_id")
            try:
                dispatch_task_id = int(dispatch_task_id)
            except (TypeError, ValueError):
                continue

            row = conn.execute("SELECT status FROM tasks WHERE id = ?", (dispatch_task_id,)).fetchone()
            if row is None:
                continue
            queue_status = str(row["status"] or "")

            status_path = Path(str(request.get("status_file") or request_path.parent / "status.json")).expanduser()
            status = {}
            if status_path.is_file():
                try:
                    status = json.loads(status_path.read_text(encoding="utf-8"))
                except Exception:
                    status = {}

            run_state = str(status.get("state") or "")
            run_id = str(request.get("run_id") or request_path.parent.name)
            engine = str(status.get("engine") or request.get("target_engine") or "")
            request_file = str(status.get("request_file") or request.get("request_file") or request_path)
            result_file = str(status.get("result_file") or request.get("result_file") or request_path.parent / "result.json")

            # ----- Existing case: queue cancelled, run non-terminal -----
            if queue_status == "cancelled":
                if run_state in _CRON_RECONCILE_TERMINAL_STATES:
                    continue
                payload = {
                    "run_id": run_id,
                    "state": "cancelled",
                    "engine": engine,
                    "updated_at": now_dt.astimezone().isoformat(timespec="seconds"),
                    "request_file": request_file,
                    "result_file": result_file,
                    "error": "cancelled via queue reconciliation",
                }
                status_path.parent.mkdir(parents=True, exist_ok=True)
                status_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
                repaired.append(
                    {
                        "run_id": run_id,
                        "task_id": dispatch_task_id,
                        "queue_status": queue_status,
                        "run_state_before": run_state,
                        "run_state_after": "cancelled",
                        "reason": "queue_cancelled_run_nonterminal",
                        "status_file": str(status_path),
                    }
                )
                continue

            # The split-brain cases below only apply while the run status
            # is still non-terminal — a finished run is authoritative.
            if run_state in _CRON_RECONCILE_TERMINAL_STATES:
                continue

            # ----- Case (a): queue done, run queued/running -----
            # #991-style interactive/foreign close. The inbox row was
            # claimed/done OUTSIDE the cron worker, so the run artifact is
            # stranded non-terminal. Mark it `orphaned_interactive_done`
            # and DO NOT re-dispatch a terminal queue row.
            if queue_status == "done" and run_state in {"queued", "running"}:
                payload = {
                    "run_id": run_id,
                    "state": "orphaned_interactive_done",
                    "engine": engine,
                    "updated_at": now_dt.astimezone().isoformat(timespec="seconds"),
                    "request_file": request_file,
                    "result_file": result_file,
                    "error": "queue task reached done outside the cron worker (run left non-terminal)",
                }
                status_path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only
                status_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
                _cron_reconcile_emit_audit(
                    "queue_done_run_nonterminal",
                    run_id,
                    dispatch_task_id,
                    queue_status,
                    run_state,
                    "orphaned_interactive_done",
                    status_path,
                    result_file,
                )
                repaired.append(
                    {
                        "run_id": run_id,
                        "task_id": dispatch_task_id,
                        "queue_status": queue_status,
                        "run_state_before": run_state,
                        "run_state_after": "orphaned_interactive_done",
                        "reason": "queue_done_run_nonterminal",
                        "status_file": str(status_path),
                    }
                )
                continue

            age_seconds = _cron_reconcile_age_seconds(status, request, now_dt)
            past_grace = grace_seconds <= 0 or (age_seconds is not None and age_seconds >= grace_seconds)
            has_worker_evidence = _cron_reconcile_worker_evidence(
                request, request_path.parent, worker_dir, dispatch_task_id
            )

            # ----- Case (b): queue queued, run queued, no worker, past grace -----
            # Submitted-but-lost before any worker claimed it. The daemon
            # backlog sweep owns the actual worker-start (bash side); the
            # reconciler only REPORTS `queued_dispatch_lost` so the row is
            # visible if recovery did not happen by the follow-up tick.
            # The auto-recovery audit (`cron_dispatch_auto_recovered`) is
            # emitted by the backlog sweep, NOT here.
            if queue_status == "queued" and run_state == "queued":
                if has_worker_evidence or not past_grace:
                    continue
                _cron_reconcile_emit_audit(
                    "queued_dispatch_lost",
                    run_id,
                    dispatch_task_id,
                    queue_status,
                    run_state,
                    "queued_dispatch_lost",
                    status_path,
                    result_file,
                )
                repaired.append(
                    {
                        "run_id": run_id,
                        "task_id": dispatch_task_id,
                        "queue_status": queue_status,
                        "run_state_before": run_state,
                        "run_state_after": "queued_dispatch_lost",
                        "reason": "queued_dispatch_lost",
                        "status_file": str(status_path),
                        "age_seconds": age_seconds,
                    }
                )
                continue

            # ----- Case (c): queue claimed, run running, stale worker -----
            # A lost running worker: the row is claimed and the run says
            # `running`, but there is no live pid/log/result and the lease
            # window elapsed. Mark `orphaned_worker_lost` so the operator
            # surface shows it and the lease can be reclaimed.
            if queue_status == "claimed" and run_state == "running":
                if has_worker_evidence or not past_grace:
                    continue
                payload = {
                    "run_id": run_id,
                    "state": "orphaned_worker_lost",
                    "engine": engine,
                    "updated_at": now_dt.astimezone().isoformat(timespec="seconds"),
                    "request_file": request_file,
                    "result_file": result_file,
                    "error": "running cron worker is lost (no live pid/log/result past grace)",
                }
                status_path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only
                status_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
                _cron_reconcile_emit_audit(
                    "running_worker_stale",
                    run_id,
                    dispatch_task_id,
                    queue_status,
                    run_state,
                    "orphaned_worker_lost",
                    status_path,
                    result_file,
                )
                repaired.append(
                    {
                        "run_id": run_id,
                        "task_id": dispatch_task_id,
                        "queue_status": queue_status,
                        "run_state_before": run_state,
                        "run_state_after": "orphaned_worker_lost",
                        "reason": "running_worker_stale",
                        "status_file": str(status_path),
                        "age_seconds": age_seconds,
                    }
                )
                continue

    payload = {
        "status": "ok",
        "scanned_runs": scanned,
        "repaired_runs": len(repaired),
        "repaired": repaired,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print("status: ok")
        print(f"scanned_runs: {scanned}")
        print(f"repaired_runs: {len(repaired)}")
    return 0


def run_cleanup_prune(args, raw_payload, records):
    candidates = sorted(cleanup_candidates(records, args.mode), key=record_sort_key)
    candidate_ids = {record["id"] for record in candidates}
    jobs_path = Path(args.jobs_file).expanduser()
    remaining_jobs = [job for job in (raw_payload.get("jobs") if isinstance(raw_payload, dict) else raw_payload) if job.get("id") not in candidate_ids]
    remaining_count = len(remaining_jobs)
    sample = [format_cleanup_candidate(record) for record in candidates[:10]]
    payload = {
        "status": "nothing_to_prune",
        "mode": args.mode,
        "candidate_jobs": len(candidates),
        "remaining_jobs_after_prune": remaining_count,
        "deleted_jobs": 0,
        "remaining_jobs": remaining_count,
        "source_file": str(jobs_path),
        "sample_jobs": sample,
    }

    if not args.json:
        print("warning: cleanup prune rewrites gateway jobs.json directly.")
        print("warning: run it between gateway cron ticks to reduce write collision risk.")
        print(f"mode: {args.mode}")
        print(f"candidate_jobs: {len(candidates)}")
        print(f"remaining_jobs_after_prune: {remaining_count}")

    if not candidates:
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: nothing_to_prune")
        return 0

    if not args.json:
        print("candidate_sample:")
        for entry in sample:
            print(f"- {entry}")
        if len(candidates) > 10:
            print(f"- ... ({len(candidates) - 10} more candidates)")

    if args.dry_run:
        payload["status"] = "dry_run"
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("status: dry_run")
        return 0

    backup_path = backup_path_for(jobs_path)
    backup_path.write_text(jobs_path.read_text(encoding="utf-8"), encoding="utf-8")
    if isinstance(raw_payload, dict):
        next_payload = dict(raw_payload)
        next_payload["jobs"] = remaining_jobs
    else:
        next_payload = remaining_jobs
    atomic_write_jobs(jobs_path, next_payload)
    payload["status"] = "pruned"
    payload["deleted_jobs"] = len(candidates)
    payload["backup_file"] = str(backup_path)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print("status: pruned")
        print(f"deleted_jobs: {len(candidates)}")
        print(f"remaining_jobs: {remaining_count}")
        print(f"backup_file: {backup_path}")
    return 0


def print_inventory(args, all_records, filtered_records):
    source_file = str(Path(args.jobs_file).expanduser())
    family_rows = inventory_rows(filtered_records)
    limit = args.limit if args.limit is not None else (0 if args.json else 30)
    display_records = trimmed_jobs(filtered_records, limit)

    if args.json:
        payload = {
            "source_file": source_file,
            "generated_at": datetime.now().astimezone().isoformat(),
            "filters": {
                "agent": args.agent,
                "family": args.family,
                "mode": args.mode,
                "enabled": args.enabled,
                "limit": 0 if limit == 0 else limit,
            },
            "totals": summarize(all_records),
            "filtered_totals": summarize(filtered_records),
            "families": [
                {
                    "family": row["family"],
                    "jobs": row["jobs"],
                    "recurring": row["recurring"],
                    "one_shot": row["one_shot"],
                    "agents": row["agents"],
                    "next_run_at": row["next_run_at"].isoformat() if row["next_run_at"] else None,
                    "last_run_at": row["last_run_at"].isoformat() if row["last_run_at"] else None,
                }
                for row in family_rows
            ],
            "jobs": [serialize_record(record) for record in display_records],
            "jobs_total": len(filtered_records),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    totals = summarize(all_records)
    filtered_totals = summarize(filtered_records)
    print(f"source_file: {source_file}")
    print(f"generated_at: {datetime.now().astimezone().isoformat()}")
    print(
        "filters: "
        f"mode={args.mode} "
        f"enabled={args.enabled} "
        f"agent={args.agent or '-'} "
        f"family={args.family or '-'} "
        f"limit={limit}"
    )
    print(f"total_jobs: {totals['total_jobs']}")
    print(f"enabled_jobs: {totals['enabled_jobs']}")
    print(f"recurring_jobs: {totals['recurring_jobs']}")
    print(f"one_shot_jobs: {totals['one_shot_jobs']}")
    print(f"future_one_shot_jobs: {totals['future_one_shot_jobs']}")
    print(f"expired_one_shot_jobs: {totals['expired_one_shot_jobs']}")
    print(f"error_jobs: {totals['error_jobs']}")
    print(f"filtered_jobs: {len(display_records)} of {filtered_totals['total_jobs']}")
    print()
    print("families:")
    family_limit = 12
    if not family_rows:
        print("- none")
    else:
        for row in family_rows[:family_limit]:
            print(
                "- "
                f"{row['family']} | jobs={row['jobs']} "
                f"recurring={row['recurring']} one_shot={row['one_shot']} "
                f"agents={len(row['agents'])} "
                f"next={format_dt(row['next_run_at'])} "
                f"last={format_dt(row['last_run_at'])}"
            )
        if len(family_rows) > family_limit:
            print(f"- ... ({len(family_rows) - family_limit} more families)")
    print()
    print("jobs:")
    if not display_records:
        print("- none")
    else:
        for record in display_records:
            print(
                "- "
                f"{record['kind']} | agent={record['agent']} | family={record['family']} "
                f"| name={record['name']} | schedule={record['schedule_text']} "
                f"| next={format_dt(record['next_run_at'])} "
                f"| last={format_dt(record['last_run_at'])} "
                f"| status={record['last_status']}"
            )
        if limit != 0 and len(filtered_records) > len(display_records):
            print(f"- ... ({len(filtered_records) - len(display_records)} more jobs)")
    return 0


def resolve_show_record(records, ref):
    exact = [record for record in records if record["id"] == ref or record["name"] == ref]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        raise ValueError(f"multiple jobs matched exactly for {ref!r}")

    partial = [record for record in records if ref in record["id"] or ref in record["name"]]
    if len(partial) == 1:
        return partial[0]
    if not partial:
        raise ValueError(f"no job matched {ref!r}")
    raise ValueError(f"{len(partial)} jobs matched {ref!r}; use the full id or exact name")


def print_show(args, records):
    try:
        record = resolve_show_record(records, args.job_ref)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.format == "json" or args.json:
        print(json.dumps(serialize_record(record, include_payload=True), ensure_ascii=False, indent=2))
        return 0

    if args.format == "shell":
        print(render_shell(record))
        return 0

    print(f"source_file: {Path(args.jobs_file).expanduser()}")
    print(f"id: {record['id']}")
    print(f"name: {record['name']}")
    print(f"agent: {record['agent']}")
    print(f"family: {record['family']}")
    print(f"kind: {record['kind']}")
    print(f"enabled: {'yes' if record['enabled'] else 'no'}")
    print(f"session_target: {record['session_target']}")
    print(f"wake_mode: {record['wake_mode']}")
    print(f"payload_kind: {record['payload_kind']}")
    print(f"schedule: {record['schedule_text']}")
    print(f"next_run: {format_dt(record['next_run_at'])}")
    print(f"last_run: {format_dt(record['last_run_at'])}")
    print(f"last_status: {record['last_status']}")
    print(f"consecutive_errors: {record['consecutive_errors']}")
    print(f"last_delivery_status: {record['last_delivery_status']}")
    # PR2 — human renderer applies the "-" fallback (record keeps None so
    # JSON / shell consumers can distinguish absence from a legit value).
    print(f"last_reporting_decision: {record['last_reporting_decision'] or '-'}")
    print(f"last_delivery_intent: {record['last_delivery_intent'] or '-'}")
    inbox_task_id = record["last_inbox_task_id"]
    print(f"last_inbox_task_id: {'-' if inbox_task_id in (None, '', 0) else inbox_task_id}")
    print()
    print("payload:")
    if record["payload_text"]:
        print(record["payload_text"])
    else:
        print("(empty)")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Cron inventory and native cron helpers for Agent Bridge.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("inventory", help="Summarize and filter cron jobs.")
    inventory_parser.add_argument("--jobs-file", required=True)
    inventory_parser.add_argument("--agent")
    inventory_parser.add_argument("--family")
    inventory_parser.add_argument("--mode", choices=("all", "recurring", "one-shot"), default="all")
    inventory_parser.add_argument("--enabled", choices=("all", "yes", "no"), default="all")
    inventory_parser.add_argument("--limit", type=int, default=None)
    inventory_parser.add_argument("--json", action="store_true")

    show_parser = subparsers.add_parser("show", help="Show one cron job in detail.")
    show_parser.add_argument("--jobs-file", required=True)
    show_parser.add_argument("job_ref")
    show_parser.add_argument("--format", choices=("text", "json", "shell"), default="text")
    show_parser.add_argument("--json", action="store_true")

    errors_report_parser = subparsers.add_parser("errors-report", help="Report recurring cron jobs that are currently in error.")
    errors_report_parser.add_argument("--jobs-file", required=True)
    errors_report_parser.add_argument("--agent")
    errors_report_parser.add_argument("--family")
    errors_report_parser.add_argument("--limit", type=int, default=None)
    errors_report_parser.add_argument("--json", action="store_true")

    cleanup_report_parser = subparsers.add_parser("cleanup-report", help="Report prune candidates for stale one-shot cron jobs and/or run artifacts.")
    # ``--jobs-file`` is required only for the legacy one-shot mode; the
    # run-artifacts mode operates on the BRIDGE_HOME tree instead. We drop
    # the required flag and validate per-mode in main().
    cleanup_report_parser.add_argument("--jobs-file")
    cleanup_report_parser.add_argument(
        "--mode",
        choices=("expired-one-shot", "one-shot", "run-artifacts", "all"),
        default="expired-one-shot",
    )
    cleanup_report_parser.add_argument("--limit", type=int, default=None)
    cleanup_report_parser.add_argument("--json", action="store_true")
    cleanup_report_parser.add_argument("--target-root", help="BRIDGE_HOME for --mode run-artifacts/all")
    cleanup_report_parser.add_argument("--tasks-db", help="tasks.db path for --mode run-artifacts/all")
    cleanup_report_parser.add_argument(
        "--older-than-days",
        type=int,
        default=None,
        help="single-knob retention override (overrides both Tier-A and Tier-B defaults)",
    )

    cleanup_prune_parser = subparsers.add_parser("cleanup-prune", help="Prune stale one-shot cron jobs from jobs.json and/or run artifacts.")
    cleanup_prune_parser.add_argument("--jobs-file")
    cleanup_prune_parser.add_argument(
        "--mode",
        choices=("expired-one-shot", "one-shot", "run-artifacts", "all"),
        default="expired-one-shot",
    )
    cleanup_prune_parser.add_argument("--dry-run", action="store_true")
    cleanup_prune_parser.add_argument("--json", action="store_true")
    cleanup_prune_parser.add_argument("--target-root", help="BRIDGE_HOME for --mode run-artifacts/all")
    cleanup_prune_parser.add_argument("--tasks-db", help="tasks.db path for --mode run-artifacts/all")
    cleanup_prune_parser.add_argument(
        "--older-than-days",
        type=int,
        default=None,
        help="single-knob retention override (overrides both Tier-A and Tier-B defaults)",
    )

    native_list_parser = subparsers.add_parser("native-list", help="List bridge-native cron jobs.")
    native_list_parser.add_argument("--jobs-file", required=True)
    native_list_parser.add_argument("--agent")
    native_list_parser.add_argument("--enabled", choices=("all", "yes", "no"), default="all")
    native_list_parser.add_argument("--limit", type=int, default=None)
    native_list_parser.add_argument("--json", action="store_true")

    native_create_parser = subparsers.add_parser("native-create", help="Create a bridge-native cron job.")
    native_create_parser.add_argument("--jobs-file", required=True)
    native_create_parser.add_argument("--agent", required=True)
    create_schedule_group = native_create_parser.add_mutually_exclusive_group(required=True)
    create_schedule_group.add_argument("--schedule")
    create_schedule_group.add_argument("--at")
    native_create_parser.add_argument("--title", required=True)
    native_payload_group = native_create_parser.add_mutually_exclusive_group()
    native_payload_group.add_argument("--payload")
    native_payload_group.add_argument("--payload-file")
    native_create_parser.add_argument("--kind", choices=("text", "shell"), default="text")
    native_create_parser.add_argument("--script")
    native_create_parser.add_argument("--script-arg", action="append", default=[])
    native_create_parser.add_argument("--script-env", action="append", default=[])
    native_create_parser.add_argument("--run-as-agent")
    native_create_parser.add_argument("--timeout", type=int)
    native_create_parser.add_argument("--output-cap", type=int)
    native_create_parser.add_argument("--tz", default=default_tz_name())
    native_create_parser.add_argument("--actor")
    native_create_parser.add_argument("--disabled", action="store_true")
    native_create_parser.add_argument("--delete-after-run", action="store_true")

    native_update_parser = subparsers.add_parser("native-update", help="Update a bridge-native cron job.")
    native_update_parser.add_argument("--jobs-file", required=True)
    native_update_parser.add_argument("job_ref")
    native_update_parser.add_argument("--agent")
    update_schedule_group = native_update_parser.add_mutually_exclusive_group()
    update_schedule_group.add_argument("--schedule")
    update_schedule_group.add_argument("--at")
    native_update_parser.add_argument("--title")
    native_update_payload_group = native_update_parser.add_mutually_exclusive_group()
    native_update_payload_group.add_argument("--payload")
    native_update_payload_group.add_argument("--payload-file")
    native_update_parser.add_argument("--kind", choices=("text", "shell"))
    native_update_parser.add_argument("--script")
    native_update_parser.add_argument("--script-arg", action="append")
    native_update_parser.add_argument("--script-env", action="append", default=[])
    native_update_parser.add_argument("--run-as-agent")
    native_update_parser.add_argument("--timeout", type=int)
    native_update_parser.add_argument("--output-cap", type=int)
    native_update_parser.add_argument("--allow-kind-transition", action="store_true")
    native_update_parser.add_argument("--tz")
    native_update_parser.add_argument("--actor")
    delete_after_run_group = native_update_parser.add_mutually_exclusive_group()
    delete_after_run_group.add_argument("--delete-after-run", action="store_true")
    delete_after_run_group.add_argument("--keep-after-run", action="store_true")
    enabled_group = native_update_parser.add_mutually_exclusive_group()
    enabled_group.add_argument("--enable", action="store_true")
    enabled_group.add_argument("--disable", action="store_true")

    native_delete_parser = subparsers.add_parser("native-delete", help="Delete a bridge-native cron job.")
    native_delete_parser.add_argument("--jobs-file", required=True)
    native_delete_parser.add_argument("job_ref")

    native_rebalance_parser = subparsers.add_parser("native-rebalance-memory-daily", help="Rebalance memory-daily jobs onto a shared overnight schedule.")
    native_rebalance_parser.add_argument("--jobs-file", required=True)
    native_rebalance_parser.add_argument("--schedule", default="0 3 * * *")
    native_rebalance_parser.add_argument("--tz", default="Asia/Seoul")
    native_rebalance_parser.add_argument("--actor")
    native_rebalance_parser.add_argument("--dry-run", action="store_true")
    native_rebalance_parser.add_argument("--json", action="store_true")

    # Issue #541 PR-A — rewrite memory-daily payloads to the canonical
    # jsonl-aware body. Idempotent; backs up jobs.json before any mutation.
    migrate_payloads_parser = subparsers.add_parser(
        "migrate-payloads",
        help="Migrate cron job payloads. Currently supports --jsonl-aware for memory-daily.",
    )
    migrate_payloads_parser.add_argument("--jobs-file", required=True)
    migrate_payloads_parser.add_argument(
        "--jsonl-aware",
        action="store_true",
        required=True,
        help="Rewrite memory-daily job payloads to the canonical jsonl-aware body.",
    )
    migrate_payloads_parser.add_argument("--dry-run", action="store_true")
    migrate_payloads_parser.add_argument("--json", action="store_true")

    native_import_parser = subparsers.add_parser("native-import", help="Import cron jobs into the bridge-native store.")
    native_import_parser.add_argument("--jobs-file", required=True)
    native_import_parser.add_argument("--source-jobs-file", required=True)
    native_import_parser.add_argument("--dry-run", action="store_true")

    native_finalize_parser = subparsers.add_parser("native-finalize-run", help="Finalize native cron state after a dispatch run.")
    native_finalize_parser.add_argument("--jobs-file", required=True)
    native_finalize_parser.add_argument("--request-file", required=True)
    native_finalize_parser.add_argument("--json", action="store_true")

    reconcile_parser = subparsers.add_parser("reconcile-run-state", help="Repair cron run state from queue state.")
    reconcile_parser.add_argument("--tasks-db", required=True)
    reconcile_parser.add_argument("--runs-dir", required=True)
    # Issue #1459 — optional worker-evidence + grace inputs for the
    # split-brain cases (b/c). Omitting them keeps the legacy
    # queue-cancelled-only behavior intact (no worker dir → no evidence
    # lookup; grace 0 → past-grace always true, but those cases still
    # gate on no-worker-evidence so a live in-flight run is never touched
    # without --grace-seconds set).
    reconcile_parser.add_argument("--worker-dir", default=None)
    reconcile_parser.add_argument("--grace-seconds", type=float, default=0)
    reconcile_parser.add_argument("--json", action="store_true")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "native-list":
        try:
            _, jobs = load_native_jobs_payload(args.jobs_file)
            records = [build_job_record(job) for job in jobs]
        except (ValueError, json.JSONDecodeError) as exc:
            print(f"error: failed to read jobs file: {exc}", file=sys.stderr)
            return 2
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        return print_native_list(args, records)

    if args.command == "native-create":
        try:
            return run_native_create(args)
        except FileNotFoundError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "native-update":
        try:
            return run_native_update(args)
        except FileNotFoundError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "native-delete":
        try:
            return run_native_delete(args)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "native-rebalance-memory-daily":
        try:
            return run_native_rebalance_memory_daily(args)
        except FileNotFoundError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "migrate-payloads":
        try:
            return run_migrate_payloads(args)
        except FileNotFoundError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except (ValueError, json.JSONDecodeError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "native-import":
        try:
            return run_native_import(args)
        except FileNotFoundError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "native-finalize-run":
        try:
            return run_native_finalize(args)
        except FileNotFoundError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if args.command == "reconcile-run-state":
        try:
            return run_reconcile_run_state(args)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    # Issue #533 — `cleanup-{report,prune} --mode run-artifacts` does not
    # touch jobs.json, so it must short-circuit before the jobs-file load.
    # `--mode all` runs both passes (one-shot first, then run-artifacts).
    if args.command in ("cleanup-report", "cleanup-prune"):
        mode = getattr(args, "mode", "expired-one-shot")
        if mode == "run-artifacts":
            args._report_only = args.command == "cleanup-report"  # noqa: SLF001
            dry_run = args._report_only or bool(getattr(args, "dry_run", False))
            return run_cleanup_run_artifacts(args, dry_run=dry_run)

    try:
        if not getattr(args, "jobs_file", None):
            print(
                "error: --jobs-file is required for this command/mode",
                file=sys.stderr,
            )
            return 2
        raw_payload, jobs = load_jobs_payload(args.jobs_file)
        records = [build_job_record(job) for job in jobs]
    except FileNotFoundError:
        print(f"error: jobs file not found: {args.jobs_file}", file=sys.stderr)
        return 2
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"error: failed to read jobs file: {exc}", file=sys.stderr)
        return 2

    if args.command == "inventory":
        filtered = filter_records(records, args)
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        return print_inventory(args, records, filtered)

    if args.command == "show":
        return print_show(args, records)

    if args.command == "errors-report":
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        return print_errors_report(args, records)

    if args.command == "cleanup-report":
        if args.limit is not None and args.limit < 0:
            print("error: --limit must be >= 0", file=sys.stderr)
            return 2
        rc = print_cleanup_report(args, records)
        if rc == 0 and getattr(args, "mode", "") == "all":
            args._report_only = True  # noqa: SLF001
            print()
            print("--- run-artifacts ---")
            rc = run_cleanup_run_artifacts(args, dry_run=True)
        return rc

    if args.command == "cleanup-prune":
        rc = run_cleanup_prune(args, raw_payload, records)
        if rc == 0 and getattr(args, "mode", "") == "all":
            print()
            print("--- run-artifacts ---")
            args._report_only = False  # noqa: SLF001
            rc = run_cleanup_run_artifacts(
                args, dry_run=bool(getattr(args, "dry_run", False))
            )
        return rc

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
