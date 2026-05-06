#!/usr/bin/env python3
"""Issue #614 — regression coverage for scheduler deferred-retry enumerator.

Three scenarios:

1. ``daily_cron_deferred`` — daily 06:00 cron deferred at fire time with
   ``nextRunAtMs = 06:15``. Retry must show up exactly once with
   ``occurrence_at == 06:15``, original 06:00 slot stays past the cursor,
   and the synthetic retry's slot uses the deferred-retry marker.

2. ``deferred_at_job`` — one-shot ``schedule.kind=at`` job that deferred.
   Same retry behaviour as the daily cron; the bug existed there too
   despite the comment in ``bridge-cron.py:2145-2148``.

3. ``retry_collides_with_natural_occurrence`` — same scheduler tick yields
   both a deferred retry AND the next natural occurrence. Both must be
   emitted exactly once each, no collapse.

These exercise the new ``enumerate_pending_retries`` plus the dedup logic
in ``cmd_sync``. They run the scheduler module by import, not by
subprocess, so the assertions stay focused on the scheduling decision
without spinning up a real queue / runner / worker.

Usage:  python3 tests/cron-deferred-retry/test_pending_retries.py
        Exit 0 = pass, exit 1 = fail.
"""

from __future__ import annotations

import importlib.util
import sys
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEDULER_PATH = REPO_ROOT / "bridge-cron-scheduler.py"


def load_scheduler():
    spec = importlib.util.spec_from_file_location("bridge_cron_scheduler", SCHEDULER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load scheduler module at {SCHEDULER_PATH}")
    module = importlib.util.module_from_spec(spec)
    # Register in sys.modules BEFORE exec — dataclass field type resolution
    # walks `sys.modules.get(cls.__module__)` and crashes if the module is
    # absent (Python 3.9 dataclasses internals).
    sys.modules["bridge_cron_scheduler"] = module
    spec.loader.exec_module(module)
    return module


def epoch_ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def make_daily_cron_job(now_dt: datetime) -> dict:
    occurrence_at = now_dt.replace(hour=6, minute=0, second=0, microsecond=0)
    next_retry_at = occurrence_at + timedelta(minutes=15)
    return {
        "id": "daily-job-id",
        "name": "morning-briefing-test",
        "agentId": "patch",
        "enabled": True,
        "schedule": {
            "kind": "cron",
            "expr": "0 6 * * *",
            "tz": "Asia/Seoul",
        },
        "state": {
            "lastStatus": "deferred",
            "lastRunStatus": "deferred",
            "nextRunAtMs": epoch_ms(next_retry_at),
            "deferredRetryOfSlot": occurrence_at.isoformat(timespec="minutes"),
            "deferredRetryOfOccurrenceAt": occurrence_at.isoformat(timespec="minutes"),
            "deferredRetryAttempt": 1,
        },
    }


def make_at_job(now_dt: datetime) -> dict:
    occurrence_at = now_dt.replace(hour=8, minute=0, second=0, microsecond=0)
    next_retry_at = occurrence_at + timedelta(minutes=15)
    return {
        "id": "at-job-id",
        "name": "event-reminder-test",
        "agentId": "jjujju",
        "enabled": True,
        "schedule": {
            "kind": "at",
            "at": occurrence_at.isoformat(),
            "tz": "Asia/Seoul",
        },
        "state": {
            "lastStatus": "deferred",
            "nextRunAtMs": epoch_ms(next_retry_at),
            "deferredRetryOfSlot": occurrence_at.isoformat(timespec="minutes"),
            "deferredRetryOfOccurrenceAt": occurrence_at.isoformat(timespec="minutes"),
            "deferredRetryAttempt": 1,
        },
    }


def make_high_freq_cron_job(now_dt: datetime) -> dict:
    """Every-15min job that deferred at :00, retry at :15. By :15 the next
    natural cron occurrence ALSO fires. Both must come through."""
    deferred_slot = now_dt.replace(minute=0, second=0, microsecond=0)
    retry_at = deferred_slot + timedelta(minutes=15)
    return {
        "id": "freq-job-id",
        "name": "every15-test",
        "agentId": "patch",
        "enabled": True,
        "schedule": {
            "kind": "cron",
            "expr": "*/15 * * * *",
            "tz": "Asia/Seoul",
        },
        "state": {
            "lastStatus": "deferred",
            "nextRunAtMs": epoch_ms(retry_at),
            "deferredRetryOfSlot": deferred_slot.isoformat(timespec="minutes"),
            "deferredRetryOfOccurrenceAt": deferred_slot.isoformat(timespec="minutes"),
            "deferredRetryAttempt": 1,
        },
    }


def assert_eq(actual, expected, label):
    if actual != expected:
        print(f"FAIL: {label}: expected {expected!r}, got {actual!r}")
        return False
    print(f"PASS: {label}")
    return True


def assert_true(value, label):
    if not value:
        print(f"FAIL: {label}: expected truthy, got {value!r}")
        return False
    print(f"PASS: {label}")
    return True


def test_daily_cron_deferred(scheduler):
    now_dt = datetime(2026, 5, 6, 6, 20, 0, tzinfo=scheduler.LOCAL_TZ)
    job = make_daily_cron_job(now_dt)
    retries, counters = scheduler.enumerate_pending_retries([job], now_dt)
    ok = True
    ok &= assert_eq(len(retries), 1, "daily_cron: one pending retry")
    if retries:
        retry = retries[0]
        ok &= assert_eq(retry.job_id, "daily-job-id", "daily_cron: retry.job_id")
        ok &= assert_eq(retry.schedule_kind, "cron", "daily_cron: schedule_kind preserved")
        # Retry occurrence_at == nextRunAtMs (06:15), NOT the original 06:00.
        ok &= assert_eq(
            retry.occurrence_at.replace(microsecond=0),
            now_dt.replace(hour=6, minute=15, second=0, microsecond=0),
            "daily_cron: retry occurrence_at = nextRunAtMs",
        )
        ok &= assert_true(
            retry.slot.startswith(scheduler.RETRY_SLOT_PREFIX),
            "daily_cron: retry slot uses deferred-retry- prefix",
        )
    ok &= assert_eq(counters.get("retry_due"), 1, "daily_cron: counter retry_due=1")
    return ok


def test_deferred_at_job(scheduler):
    now_dt = datetime(2026, 5, 6, 8, 20, 0, tzinfo=scheduler.LOCAL_TZ)
    job = make_at_job(now_dt)
    retries, counters = scheduler.enumerate_pending_retries([job], now_dt)
    ok = True
    ok &= assert_eq(len(retries), 1, "at_job: one pending retry")
    if retries:
        retry = retries[0]
        ok &= assert_eq(retry.schedule_kind, "at", "at_job: schedule_kind=at")
        ok &= assert_eq(retry.job_id, "at-job-id", "at_job: retry.job_id")
        ok &= assert_eq(
            retry.occurrence_at.replace(microsecond=0),
            now_dt.replace(hour=8, minute=15, second=0, microsecond=0),
            "at_job: retry occurrence_at = nextRunAtMs",
        )
    ok &= assert_eq(counters.get("retry_due"), 1, "at_job: counter retry_due=1")
    return ok


def test_retry_and_natural_occurrence_collide(scheduler):
    # Tick at 12:18. Job deferred at 12:00, retry due at 12:15.
    # Next natural occurrence (every-15min) is 12:15. Both must be present
    # exactly once each — no collapse.
    now_dt = datetime(2026, 5, 6, 12, 18, 0, tzinfo=scheduler.LOCAL_TZ)
    start_dt = datetime(2026, 5, 6, 12, 5, 0, tzinfo=scheduler.LOCAL_TZ)
    job = make_high_freq_cron_job(now_dt)

    natural_due, natural_counters = scheduler.enumerate_due_runs(
        [job], start_dt, now_dt, per_job_limit=0
    )
    pending_retries, retry_counters = scheduler.enumerate_pending_retries([job], now_dt)

    # Replicate dedup: combine, drop duplicate keys, sort.
    existing_keys = {scheduler.due_run_sort_key(r) for r in natural_due}
    merged = list(natural_due)
    for retry in pending_retries:
        if scheduler.due_run_sort_key(retry) in existing_keys:
            continue
        merged.append(retry)
        existing_keys.add(scheduler.due_run_sort_key(retry))

    ok = True
    # The natural occurrence at 12:15 must be present.
    natural_at_1215 = [
        r
        for r in merged
        if r.occurrence_at.replace(microsecond=0)
        == now_dt.replace(minute=15, second=0, microsecond=0)
        and not r.slot.startswith(scheduler.RETRY_SLOT_PREFIX)
    ]
    ok &= assert_eq(
        len(natural_at_1215), 1, "collision: natural 12:15 cron occurrence present"
    )
    # The retry at 12:15 must also be present.
    retries_at_1215 = [
        r
        for r in merged
        if r.occurrence_at.replace(microsecond=0)
        == now_dt.replace(minute=15, second=0, microsecond=0)
        and r.slot.startswith(scheduler.RETRY_SLOT_PREFIX)
    ]
    ok &= assert_eq(
        len(retries_at_1215), 1, "collision: deferred retry at 12:15 present"
    )
    # No duplicate keys.
    keys = [scheduler.due_run_sort_key(r) for r in merged]
    ok &= assert_eq(len(keys), len(set(keys)), "collision: no duplicate due_run keys")
    return ok


def main():
    scheduler = load_scheduler()
    results = [
        ("daily_cron_deferred", test_daily_cron_deferred(scheduler)),
        ("deferred_at_job", test_deferred_at_job(scheduler)),
        ("retry_and_natural_occurrence_collide", test_retry_and_natural_occurrence_collide(scheduler)),
    ]
    print()
    print("=== summary ===")
    failed = [name for name, ok in results if not ok]
    for name, ok in results:
        print(f"  {name}: {'PASS' if ok else 'FAIL'}")
    if failed:
        print(f"\n{len(failed)} test(s) failed: {', '.join(failed)}")
        sys.exit(1)
    print("\nAll tests passed.")


if __name__ == "__main__":
    main()
