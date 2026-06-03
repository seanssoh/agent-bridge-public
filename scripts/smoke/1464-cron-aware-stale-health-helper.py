#!/usr/bin/env python3
"""Helper for scripts/smoke/1464-cron-aware-stale-health.sh (issue #1464).

Drives bridge-status.py's cadence-aware cron staleness directly — no daemon,
no queue, no live runtime. Builds a throwaway BRIDGE_HOME with a cron
`jobs.json` + timestamped run directories, then exercises the real
`last_cron_run_by_agent` / `add_cron_activity_to_metrics` /
`classify_agent_stale` functions.

Modes (file-as-argv, never heredoc-stdin — lint-heredoc-ban / footgun #11):

  classify <bridge-status.py>
      (a) a schedule-driven idle static agent whose cron fired WITHIN its
          cadence classifies healthy (`ok`), and
      (b) a schedule-driven static agent whose cron job is OVERDUE relative to
          its cadence (the review's hourly-job-last-run-35h-ago fixture) still
          classifies STALE (not `ok`).
      Plus daily-20h and weekly-3d healthy cases from the brief.

  teeth <bridge-status.py>
      Proves the smoke has teeth: re-running case (b) through the REVERTED
      blanket-window classifier ("any recent cron run -> ok") makes the
      overdue hourly agent wrongly read `ok`. If a future patch reverts the
      cadence gate, classify-mode case (b) flips to `ok` and fails — this mode
      asserts that the blanket logic genuinely produces the wrong answer the
      cadence gate guards against.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


def _fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_bridge_status(path: str):
    script = Path(path).resolve()
    spec = importlib.util.spec_from_file_location("_bridge_status_1464", str(script))
    if spec is None or spec.loader is None:
        _fail(f"cannot load bridge-status.py from {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["_bridge_status_1464"] = module
    spec.loader.exec_module(module)
    return module


def _run_id(prefix: str, ts: int) -> str:
    # Mirror the run-id format bridge-status.cron_run_timestamp_from_name parses:
    #   <prefix>--<YYYY-MM-DDTHH-MM>
    dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    return f"{prefix}--{dt.strftime('%Y-%m-%dT%H-%M')}"


def _recent_occurrence_at_or_before(bs, expr: str, target_ts: int, max_back_days: int = 8) -> int | None:
    """Most recent UTC occurrence of a cron expr at/before target_ts.

    Production cron runs are recorded at occurrence times, so smoke fixtures must
    anchor their run timestamps on real occurrences (not arbitrary now-Nh) or the
    next-due/overdue math is exercised against unrealistic inputs. Reuses the
    scheduler matcher bridge-status itself loads (no hand-rolled cron parser).
    """
    module = bs._load_cron_scheduler_module()
    if module is None or not hasattr(module, "cron_matches"):
        _fail("cannot load the cron scheduler matcher for fixture alignment")
    cur = datetime.fromtimestamp(target_ts, tz=timezone.utc).replace(second=0, microsecond=0)
    for _ in range(max_back_days * 24 * 60):
        if module.cron_matches(expr, cur):
            return int(cur.timestamp())
        cur -= timedelta(minutes=1)
    return None


def _build_fixture(home: Path, job: dict, run_ts: int) -> str:
    """Write jobs.json + a single timestamped run dir; return the state dir."""
    cron = home / "cron"
    cron.mkdir(parents=True, exist_ok=True)
    (cron / "jobs.json").write_text(json.dumps({"jobs": [job]}), encoding="utf-8")
    state = home / "state"
    runs = state / "cron" / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    (runs / _run_id(job["id"], run_ts)).mkdir(parents=True, exist_ok=True)
    return str(state)


def _classify(bs, home: Path, state_dir: str, agent: str, now_ts: int) -> tuple[str, dict]:
    metrics: dict[str, dict] = {}
    # critical_seconds matches the dashboard default (1d) — large enough that a
    # 10-day-idle session would be `crit` on the session-only path.
    bs.add_cron_activity_to_metrics(metrics, str(home), state_dir, 86400)
    metric = metrics.setdefault(agent, {})
    # Old interactive session (10 days) so the session-only classifier alone
    # would return `crit`; only the cadence-aware cron signal can rescue it.
    metric["session_activity_ts"] = now_ts - 10 * 86400
    stale = bs.classify_agent_stale(
        True,
        metric,
        6 * 3600,   # warn_seconds
        86400,      # critical_seconds
        source="static",
    )
    return stale, metric


def _hourly_overdue_job() -> dict:
    return {
        "id": "hourly-monitor",
        "name": "hourly-monitor",
        "agent": "schedmon",
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 * * * *", "tz": "UTC"},
    }


def _daily_job() -> dict:
    return {
        "id": "daily-report",
        "name": "daily-report",
        "agent": "schedmon",
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 9 * * *", "tz": "UTC"},
    }


def _weekly_job() -> dict:
    return {
        "id": "weekly-summary",
        "name": "weekly-summary",
        "agent": "schedmon",
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 22 * * 0", "tz": "UTC"},
    }


def _monthly_31_job() -> dict:
    # Sparse cron: the 31st of every month at 09:00. Only ~7 months have a 31st,
    # so the next valid run can be ~61 days out — the codex-r2 finding's case.
    return {
        "id": "monthly-31-report",
        "name": "monthly-31-report",
        "agent": "schedmon",
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 9 31 * *", "tz": "UTC"},
    }


def _irregular_job() -> dict:
    # Irregular cron: twice a day at 09:00 and 17:00 — uneven gaps (8h / 16h).
    # The codex-r2 case: a run at 09:00 that has since missed both its 17:00 and
    # next-09:00 slots must classify stale even though the inter-occurrence gap
    # is short relative to the elapsed idle.
    return {
        "id": "irregular-twice-daily",
        "name": "irregular-twice-daily",
        "agent": "schedmon",
        "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 9,17 * * *", "tz": "UTC"},
    }


def _most_recent_dom31_at_0900(now_ts: int) -> int | None:
    """Epoch of the most recent 31st-of-the-month 09:00 UTC at/before now."""
    cur = datetime.fromtimestamp(now_ts, tz=timezone.utc).replace(
        hour=9, minute=0, second=0, microsecond=0
    )
    for _ in range(70):  # at most ~2 months back to find a valid 31st
        if cur.day == 31 and int(cur.timestamp()) <= now_ts:
            return int(cur.timestamp())
        cur -= timedelta(days=1)
    return None


def _hourly_overdue_run_ts(bs, now_ts: int) -> int:
    # An hourly job (0 * * * *) last run 35h ago, anchored on a real :00.
    return _recent_occurrence_at_or_before(bs, "0 * * * *", now_ts - 35 * 3600)


def mode_classify(bs) -> None:
    now_ts = int(datetime.now(timezone.utc).timestamp())

    # Case (a) — within cadence: a daily job whose last run is its most recent
    # 09:00 occurrence (~within a day) -> healthy. Anchored on a real occurrence
    # so the next-due/overdue math sees production-shaped input.
    daily_run = _recent_occurrence_at_or_before(bs, "0 9 * * *", now_ts)
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        state = _build_fixture(home, _daily_job(), daily_run)
        stale, metric = _classify(bs, home, state, "schedmon", now_ts)
        if stale != "ok":
            _fail(f"(a) daily within-cadence agent should be ok, got {stale!r} "
                  f"(cadence={metric.get('cron_cadence_seconds')}, "
                  f"in_cadence={metric.get('cron_in_cadence')}, "
                  f"run_age_h={(now_ts - daily_run) / 3600:.1f})")
        print("ok (a): daily cron last-run on its most recent slot -> healthy/ok")

    # Weekly job whose last run is its most recent Sunday 22:00 -> healthy.
    weekly_run = _recent_occurrence_at_or_before(bs, "0 22 * * 0", now_ts)
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        state = _build_fixture(home, _weekly_job(), weekly_run)
        stale, metric = _classify(bs, home, state, "schedmon", now_ts)
        if stale != "ok":
            _fail(f"weekly within-cadence agent should be ok, got {stale!r} "
                  f"(cadence={metric.get('cron_cadence_seconds')}, "
                  f"run_age_h={(now_ts - weekly_run) / 3600:.1f})")
        print("ok: weekly cron last-run on its most recent slot -> healthy/ok")

    # Sparse monthly (0 9 31 * *) whose last run is the most recent valid 31st
    # -> healthy. Regression guard for the codex-r1 finding: a fixed 40d probe
    # returned no occurrence for the 31st-of-month expression (June has no 31st,
    # the next is ~61d out), forcing cron_in_cadence=False and a false stale. The
    # expanding probe + next-due model must keep this healthy.
    last_31 = _most_recent_dom31_at_0900(now_ts)
    if last_31 is None:
        _fail("could not derive a recent 31st-of-month fixture timestamp")
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        state = _build_fixture(home, _monthly_31_job(), last_31)
        stale, metric = _classify(bs, home, state, "schedmon", now_ts)
        if stale != "ok":
            _fail("sparse monthly (0 9 31 * *) whose last run is the most recent "
                  f"valid 31st should be ok, got {stale!r} "
                  f"(cadence={metric.get('cron_cadence_seconds')}, "
                  f"in_cadence={metric.get('cron_in_cadence')}) — the cadence "
                  "probe must resolve sparse monthly schedules, not false-stale")
        print("ok: sparse monthly cron last-run on the most recent 31st -> healthy/ok")

    # Case (b) — OVERDUE hourly (last run 35h ago, on a real :00) -> STILL STALE.
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        run_ts = _hourly_overdue_run_ts(bs, now_ts)
        state = _build_fixture(home, _hourly_overdue_job(), run_ts)
        stale, metric = _classify(bs, home, state, "schedmon", now_ts)
        if stale == "ok":
            _fail("(b) hourly cron last-run 35h ago is badly overdue but "
                  "classified ok — the false-healthy masking the cadence gate "
                  "must prevent (cadence="
                  f"{metric.get('cron_cadence_seconds')}, "
                  f"in_cadence={metric.get('cron_in_cadence')})")
        if metric.get("cron_in_cadence"):
            _fail("(b) hourly-35h overdue run must NOT be flagged cron_in_cadence")
        # The run is still recorded for observability even though it is overdue.
        if not metric.get("last_cron_run_ts"):
            _fail("(b) overdue run should still record last_cron_run_ts for JSON")
        print(f"ok (b): hourly cron last-run 35h ago -> still stale ({stale})")

    # Case (c) — IRREGULAR overdue (codex-r2 finding): a `0 9,17 * * *` run on a
    # real 09:00 slot ~25h ago has missed both its 17:00 and next-09:00 fires.
    # The inter-occurrence gap is short (8-16h) but the agent is overdue and must
    # classify stale — the next-due overdue check (not just the interval) catches
    # this. Anchor 25h back on a real 09:00 occurrence.
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        irregular_run = _recent_occurrence_at_or_before(bs, "0 9,17 * * *", now_ts - 25 * 3600)
        state = _build_fixture(home, _irregular_job(), irregular_run)
        stale, metric = _classify(bs, home, state, "schedmon", now_ts)
        if stale == "ok":
            _fail("(c) irregular cron (0 9,17 * * *) that has missed both its "
                  "next slots is overdue but classified ok — the next-due overdue "
                  "check must not be masked by the short inter-occurrence gap "
                  f"(cadence={metric.get('cron_cadence_seconds')}, "
                  f"in_cadence={metric.get('cron_in_cadence')}, "
                  f"run_age_h={(now_ts - irregular_run) / 3600:.1f})")
        print(f"ok (c): irregular cron run ~25h ago (missed both slots) -> still stale ({stale})")

    print("PASS: classify")


def mode_teeth(bs) -> None:
    """Show the reverted blanket logic produces the wrong answer for case (b)."""
    now_ts = int(datetime.now(timezone.utc).timestamp())
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        run_ts = _hourly_overdue_run_ts(bs, now_ts)
        state = _build_fixture(home, _hourly_overdue_job(), run_ts)
        metrics: dict[str, dict] = {}
        bs.add_cron_activity_to_metrics(metrics, str(home), state, 86400)
        metric = metrics.setdefault("schedmon", {})
        metric["session_activity_ts"] = now_ts - 10 * 86400

        # Reverted classifier: "any recent cron run -> ok" (pre-#1464 blanket
        # behaviour, ignoring cadence). This is exactly what a regression would
        # reintroduce.
        def reverted_classify(metric: dict) -> str:
            if bs.int_ts(metric.get("last_cron_run_ts")):
                return "ok"
            return bs.classify_stale(
                True,
                bs.session_activity_ts(metric),
                6 * 3600,
                86400,
                source="static",
            )

        reverted = reverted_classify(metric)
        if reverted != "ok":
            _fail("teeth precondition broken: the blanket revert should map the "
                  f"overdue hourly agent to ok, got {reverted!r} — the smoke "
                  "would not actually catch a cadence-gate revert")

        cadence_aware = bs.classify_agent_stale(
            True, metric, 6 * 3600, 86400, source="static"
        )
        if cadence_aware == "ok":
            _fail("teeth: the cadence-aware classifier ALSO returns ok for the "
                  "overdue hourly agent — the cadence gate is not protecting "
                  "case (b)")
        print(f"ok: blanket revert -> {reverted} (WRONG), cadence gate -> "
              f"{cadence_aware} (correct)")
    print("PASS: teeth")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        _fail("usage: 1464-cron-aware-stale-health-helper.py <mode> <bridge-status.py>")
    mode = argv[1]
    bs = load_bridge_status(argv[2])
    if mode == "classify":
        mode_classify(bs)
    elif mode == "teeth":
        mode_teeth(bs)
    else:
        _fail(f"unknown mode: {mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
