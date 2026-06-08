#!/usr/bin/env python3
"""Helper for scripts/smoke/1659-cron-status-walk-perf.sh (issue #1659).

Drives bridge-status.py's cron cadence-health walk directly — no daemon, no
queue, no live runtime. Builds throwaway BRIDGE_HOME fixtures (cron jobs.json +
timestamped run dirs) and exercises the real `last_cron_run_by_agent` /
`add_cron_activity_to_metrics` functions.

Two modes (file-as-argv, never heredoc-stdin — lint-heredoc-ban / footgun #11):

  scale <bridge-status.py>
      Pins the #1659 fix: the dashboard render must scale with the number of
      DISTINCT jobs/schedules, not the total number of historical run rows. The
      pre-fix code ran one occurrence-walk per run record (O(run-records)), so a
      backlog with 25x more rows over the SAME few jobs took ~25x longer. With
      the per-(agent, job-key) reduction + memoized matcher, the two render
      times must be comparable. Compares a small (200-row) vs large (5000-row)
      backlog over the same handful of distinct jobs and asserts the time ratio
      stays well under the linear-in-rows blowup a regression would reintroduce.

  multijob <bridge-status.py>
      Negative control / correctness: an agent owning TWO jobs — an older
      healthy low-frequency job (in cadence) and a newer high-frequency job that
      is stale/overdue. Asserts the per-(job/schedule) reduction did NOT regress
      aggregation: `cron_in_cadence=True` is STILL set (the healthy low-freq job
      keeps the agent in cadence) and the surfaced most-recent timestamp is the
      NEWER (overdue) run. Proves keeping only the latest-run-per-schedule (not
      latest-run-per-agent) preserves the bit-for-bit "ANY owned job in cadence"
      latch + most-recent-timestamp surfacing.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


def _fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_bridge_status(path: str):
    script = Path(path).resolve()
    spec = importlib.util.spec_from_file_location("_bridge_status_1659", str(script))
    if spec is None or spec.loader is None:
        _fail(f"cannot load bridge-status.py from {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["_bridge_status_1659"] = module
    spec.loader.exec_module(module)
    return module


def _run_id(prefix: str, ts: int) -> str:
    # Mirror the run-id format bridge-status.cron_run_timestamp_from_name parses:
    #   <prefix>--<YYYY-MM-DDTHH-MM>
    dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    return f"{prefix}--{dt.strftime('%Y-%m-%dT%H-%M')}"


def _recent_occurrence_at_or_before(
    bs, expr: str, target_ts: int, max_back_days: int = 8
) -> int | None:
    """Most recent UTC occurrence of a cron expr at/before target_ts.

    Production cron runs are recorded at occurrence times, so smoke fixtures must
    anchor their run timestamps on real occurrences. Reuses the scheduler matcher
    bridge-status itself loads (no hand-rolled cron parser).
    """
    module = bs._load_cron_scheduler_module()
    if module is None or not hasattr(module, "cron_matches"):
        _fail("cannot load the cron scheduler matcher for fixture alignment")
    cur = datetime.fromtimestamp(target_ts, tz=timezone.utc).replace(
        second=0, microsecond=0
    )
    for _ in range(max_back_days * 24 * 60):
        if module.cron_matches(expr, cur):
            return int(cur.timestamp())
        cur -= timedelta(minutes=1)
    return None


# A handful of distinct jobs, all owned by ONE agent. Mix of cadences so the
# cadence probe runs a real occurrence walk for each (the work the fix bounds).
def _scale_jobs() -> list[dict]:
    schedules = [
        ("0 * * * *", "hourly-a"),
        ("15 * * * *", "hourly-b"),
        ("0 9 * * *", "daily-a"),
        ("30 18 * * *", "daily-b"),
        ("0 22 * * 0", "weekly-a"),
    ]
    return [
        {
            "id": name,
            "name": name,
            "agent": "perfmon",
            "enabled": True,
            "schedule": {"kind": "cron", "expr": expr, "tz": "UTC"},
        }
        for expr, name in schedules
    ]


def _build_backlog(
    bs, home: Path, jobs: list[dict], rows_per_job: int, now_ts: int
) -> str:
    """Write jobs.json + `rows_per_job` timestamped run dirs PER job.

    Run timestamps are real occurrences of each job's schedule, marching back
    from `now`, so every run row is a production-shaped input the cadence walk
    must judge. Returns the state dir.
    """
    cron = home / "cron"
    cron.mkdir(parents=True, exist_ok=True)
    (cron / "jobs.json").write_text(json.dumps({"jobs": jobs}), encoding="utf-8")
    state = home / "state"
    runs = state / "cron" / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    for job in jobs:
        expr = job["schedule"]["expr"]
        # March a cursor back through real occurrences; each iteration finds the
        # previous occurrence so the rows for a job are distinct minutes.
        cursor = now_ts
        made = 0
        while made < rows_per_job:
            occ = _recent_occurrence_at_or_before(bs, expr, cursor, max_back_days=400)
            if occ is None:
                break
            (runs / _run_id(job["id"], occ)).mkdir(parents=True, exist_ok=True)
            made += 1
            cursor = occ - 60  # step before this occurrence for the next one
    return str(state)


def _time_render(bs, home: Path, state_dir: str) -> float:
    """Wall-time (seconds) of one cron cadence-health render pass."""
    # Reset the matcher LRU between the two backlogs so the large-backlog run
    # cannot ride a warm cache the small run primed — a fair scaling comparison
    # measures the per-render cost, not cache warmth.
    module = bs._load_cron_scheduler_module()
    if module is not None and hasattr(module, "allowed_values"):
        module.allowed_values.cache_clear()
    start = time.perf_counter()
    metrics: dict[str, dict] = {}
    bs.add_cron_activity_to_metrics(metrics, str(home), state_dir, 86400)
    return time.perf_counter() - start


def mode_scale(bs) -> None:
    now_ts = int(datetime.now(timezone.utc).timestamp())
    jobs = _scale_jobs()
    n_jobs = len(jobs)

    small_rows = 40   # per job  -> ~200 total rows over n_jobs jobs
    large_rows = 1000  # per job -> ~5000 total rows over the SAME n_jobs jobs

    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        state = _build_backlog(bs, home, jobs, small_rows, now_ts)
        # Warm-up + measure best-of to damp scheduler/CI jitter.
        small_t = min(_time_render(bs, home, state) for _ in range(3))

    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        state = _build_backlog(bs, home, jobs, large_rows, now_ts)
        large_t = min(_time_render(bs, home, state) for _ in range(3))

    total_small = small_rows * n_jobs
    total_large = large_rows * n_jobs
    row_ratio = total_large / max(total_small, 1)
    # Guard against a div-by-zero on a too-fast small render (sub-ms): floor it.
    time_ratio = large_t / max(small_t, 1e-4)

    # The pre-fix code was O(run-records): a `row_ratio`x bigger backlog took
    # ~`row_ratio`x longer. The fix makes render scale with DISTINCT jobs (here
    # identical between the two backlogs), so the time ratio must stay far below
    # the linear-in-rows blowup. Bound generously (4x) to tolerate CI jitter
    # while still failing hard if the per-record walk returns (row_ratio = 25x).
    bound = 4.0
    print(
        f"rows {total_small} -> {total_large} ({row_ratio:.0f}x), "
        f"render {small_t * 1000:.1f}ms -> {large_t * 1000:.1f}ms "
        f"({time_ratio:.2f}x); jobs={n_jobs} (identical both backlogs)"
    )
    if time_ratio >= bound:
        _fail(
            f"render time scaled {time_ratio:.2f}x for a {row_ratio:.0f}x row "
            f"increase over the SAME {n_jobs} jobs — expected < {bound}x. The "
            "cadence walk is still O(run-records); the per-(agent,job-key) "
            "reduction is not in effect."
        )
    print(f"PASS: scale (time ratio {time_ratio:.2f}x < {bound}x for {row_ratio:.0f}x rows)")


def mode_multijob(bs) -> None:
    """One agent, two jobs: healthy weekly + overdue hourly. Aggregation intact.

    DETERMINISTIC + WEEKDAY-INDEPENDENT (issue #1683). The fixture run
    timestamps are derived at FIXED offsets from ``now`` — NOT anchored to the
    real most-recent Sunday-22:00 occurrence — so the ``hourly_run > weekly_run``
    relationship holds no matter what weekday ``now`` falls on. The earlier
    version anchored ``weekly_run`` to the actual last Sunday 22:00, which drifts
    0-7 days with the weekday of ``now``; in the ~35h after every Sunday 22:00
    UTC that real occurrence was NEWER than the fixed-offset 35h-old hourly run,
    inverting the precondition and red-failing the required-static smoke job ~35h
    every week. Note ``cron_run_in_cadence`` derives the next-due from the cron
    EXPR (not from the stored run row), so a run timestamp need not land exactly
    on a schedule occurrence for the cadence verdict to be correct — only the
    intended healthy/overdue verdict matters, which the offsets below guarantee.
    """
    now_ts = int(datetime.now(timezone.utc).timestamp())
    agent = "multimon"

    # Overdue high-frequency job: hourly, last run ~35h ago (badly overdue).
    # Anchored on a real top-of-hour occurrence (a fixed offset from now, so
    # weekday-independent). 35h > the hourly cadence's grace window (interval 1h,
    # slack max(1h, CRON_CADENCE_MIN_WINDOW_SECONDS=2h) -> overdue past run+3h),
    # so this job is always overdue. It is the NEWEST run, so it must surface as
    # last_cron_run_ts while the weekly job keeps the agent cron_in_cadence=True.
    hourly = {
        "id": "hourly-monitor",
        "name": "hourly-monitor",
        "agent": agent,
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 * * * *", "tz": "UTC"},
    }
    hourly_run = _recent_occurrence_at_or_before(bs, "0 * * * *", now_ts - 35 * 3600)
    if hourly_run is None:
        _fail("could not derive fixture occurrence timestamps")

    # Healthy low-frequency job: weekly. Its last run is pinned a FIXED 4 days
    # BEFORE the hourly run (so OLDER than it by construction, regardless of the
    # weekday of now). At ~5-6 days old it is well inside the weekly cadence's
    # grace (interval 7d, slack 7d -> healthy until run+14d), so it always stays
    # cron_in_cadence=True. The 4-day gap (>> the 35h hourly offset) guarantees
    # hourly_run > weekly_run on every weekday, killing the Sunday-night flake.
    weekly = {
        "id": "weekly-summary",
        "name": "weekly-summary",
        "agent": agent,
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 22 * * 0", "tz": "UTC"},
    }
    weekly_run = hourly_run - 4 * 86400

    # Precondition is now structural (4-day fixed gap) — assert it anyway so any
    # future offset edit that breaks the ordering fails loudly here.
    if not hourly_run > weekly_run:
        _fail(
            "fixture precondition: the overdue hourly run must be NEWER than the "
            f"healthy weekly run (hourly={hourly_run}, weekly={weekly_run})"
        )

    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        cron = home / "cron"
        cron.mkdir(parents=True, exist_ok=True)
        (cron / "jobs.json").write_text(
            json.dumps({"jobs": [weekly, hourly]}), encoding="utf-8"
        )
        state = home / "state"
        runs = state / "cron" / "runs"
        runs.mkdir(parents=True, exist_ok=True)
        # Several DISTINCT historical rows for EACH job so the per-schedule
        # reduction has to collapse them to one candidate per schedule (not per
        # agent). Both rows of each job stay inside the run-dir scan window: the
        # multijob call's 86400 arg is dominated by the weekly job's field-based
        # lookback hint (7d * CRON_CADENCE_GRACE_MULTIPLE=2 -> a 14-day window),
        # so a ~5.6-day-old latest weekly + a 7-day-older second weekly (~12.6d,
        # < 14d) are both counted; the reduction must keep only the newest
        # (weekly_run) as the weekly job's candidate.
        for back_weeks in range(2):
            (runs / _run_id(weekly["id"], weekly_run - back_weeks * 7 * 86400)).mkdir(
                parents=True, exist_ok=True
            )
        # Distinct older hourly rows + the latest overdue one; the reduction must
        # keep only the newest (hourly_run) as the hourly job's candidate.
        for back in range(5):
            older = _recent_occurrence_at_or_before(
                bs, "0 * * * *", hourly_run - back * 3600
            )
            (runs / _run_id(hourly["id"], older)).mkdir(parents=True, exist_ok=True)

        result = bs.last_cron_run_by_agent(str(home), str(state), 86400)

    record = result.get(agent)
    if record is None:
        _fail(f"agent {agent!r} missing from last_cron_run_by_agent result")

    # The healthy weekly job must keep the agent in cadence even though the
    # hourly job is overdue (this is the latest-run-per-AGENT collapse the brief
    # forbids — taking only the newest run would drop the weekly signal).
    if record.get("cron_in_cadence") is not True:
        _fail(
            "multi-job aggregation regressed: cron_in_cadence must be True (the "
            "healthy weekly job keeps the agent in cadence), got "
            f"{record.get('cron_in_cadence')!r}. The per-schedule reduction must "
            "NOT collapse to latest-run-per-agent."
        )

    # The surfaced most-recent timestamp must be the NEWER (overdue hourly) run,
    # preserving the old loop's max-across-owned-runs behavior.
    if record.get("last_cron_run_ts") != hourly_run:
        _fail(
            "most-recent timestamp regressed: expected the newer overdue hourly "
            f"run {hourly_run}, got {record.get('last_cron_run_ts')!r}"
        )

    print(
        "ok: agent with healthy-weekly + overdue-hourly -> cron_in_cadence=True "
        f"(weekly latch) and last_cron_run_ts={hourly_run} (newer overdue run)"
    )
    print("PASS: multijob")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        _fail("usage: 1659-cron-status-walk-perf-helper.py <mode> <bridge-status.py>")
    mode = argv[1]
    bs = load_bridge_status(argv[2])
    if mode == "scale":
        mode_scale(bs)
    elif mode == "multijob":
        mode_multijob(bs)
    else:
        _fail(f"unknown mode: {mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
