#!/usr/bin/env python3
"""Helper for scripts/smoke/8807-cron-backfill-coalesce.sh (incident #8807 P1).

Extracted from the smoke's inline `python3 - <<'PY'` heredoc so the smoke
carries no heredoc-stdin site (lint-heredoc-ban C3 ban; see KNOWN_ISSUES.md
§26). The override assertions below set/unset process-environment knobs to
exercise the coalesce behaviour; the iso-helper-ratchet pattern matches the
"environ" substring, so each such code line carries an explicit
`# noqa: iso-helper-boundary` marker (this is test-local manipulation, not an
iso-boundary file access).

Invoked file-as-argv:

    python3 8807-cron-backfill-coalesce-helper.py coalesce <bridge-cron-scheduler.py>

Exits non-zero (with a message on stderr) on any assertion failure so the
calling smoke can `|| smoke_fail`.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from datetime import datetime, timedelta, timezone


def _load_scheduler(sched_path: str):
    spec = importlib.util.spec_from_file_location("bridge_cron_scheduler", sched_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def cmd_coalesce(sched_path: str) -> int:
    m = _load_scheduler(sched_path)

    local = m.LOCAL_TZ
    now = datetime(2026, 6, 3, 12, 0, 0, tzinfo=timezone.utc).astimezone(local)
    # 3h of downtime → ~18 missed picker-sweep (*/10) slots, ~3 hourly briefings.
    start = now - timedelta(hours=3)

    picker = {
        "id": "j1", "name": "picker-sweep", "agentId": "patch", "enabled": True,
        "schedule": {"kind": "cron", "expr": "*/10 * * * *"},
    }
    briefing = {
        "id": "j2", "name": "morning-briefing-patch", "agentId": "patch", "enabled": True,
        "schedule": {"kind": "cron", "expr": "0 * * * *"},
    }

    due, counters = m.enumerate_due_runs([picker, briefing], start, now, 12)
    picker_runs = [d for d in due if d.job_name == "picker-sweep"]
    brief_runs = [d for d in due if d.family == "morning-briefing"]

    assert len(picker_runs) == 1, f"picker-sweep backlog must coalesce to 1, got {len(picker_runs)}"
    assert counters.get("coalesced_jobs") == 1, f"expected coalesced_jobs=1, got {counters.get('coalesced_jobs')}"
    assert counters.get("coalesced_occurrences", 0) >= 10, "the picker backlog should have collapsed many occurrences"
    assert len(brief_runs) > 1, f"distinct-occurrence briefing must NOT coalesce, got {len(brief_runs)}"

    # The kept occurrence is the most recent — running it subsumes the missed ones.
    all_occ = m.enumerate_cron_occurrences(picker, start, now)
    assert picker_runs[0].occurrence_at == all_occ[-1], "coalesce must keep the LATEST occurrence"

    # Env override: extend the coalesce set to a normally-distinct family.
    # (test-local env manipulation, not iso-boundary access — see noqa below)
    os.environ["BRIDGE_CRON_COALESCE_CATCHUP_FAMILIES"] = "morning-briefing"  # noqa: iso-helper-boundary
    due_o, _ = m.enumerate_due_runs([briefing], start, now, 12)
    assert len([d for d in due_o if d.family == "morning-briefing"]) == 1, "override set must coalesce the briefing"
    # picker no longer listed → not coalesced.
    due_p, _ = m.enumerate_due_runs([picker], start, now, 12)
    assert len(due_p) > 1, "picker must NOT coalesce once removed from the override set"
    del os.environ["BRIDGE_CRON_COALESCE_CATCHUP_FAMILIES"]  # noqa: iso-helper-boundary

    # Cap override: keep N most recent instead of 1.
    os.environ["BRIDGE_CRON_COALESCE_CATCHUP_MAX"] = "2"  # noqa: iso-helper-boundary
    due_c, _ = m.enumerate_due_runs([picker], start, now, 12)
    assert len(due_c) == 2, f"cap=2 must keep 2 picker occurrences, got {len(due_c)}"
    del os.environ["BRIDGE_CRON_COALESCE_CATCHUP_MAX"]  # noqa: iso-helper-boundary

    # No downtime: a single in-window occurrence must not register a spurious
    # coalesce (the normal steady-state path is byte-equivalent).
    short = now - timedelta(minutes=5)
    _due_s, counters_s = m.enumerate_due_runs([picker], short, now, 12)
    assert counters_s.get("coalesced_jobs", 0) == 0, "single-occurrence window must not coalesce"

    print(
        f"[ok] picker coalesced {counters.get('coalesced_occurrences')} → 1; "
        f"briefing kept {len(brief_runs)}; overrides + steady-state correct"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] != "coalesce":
        print("usage: 8807-cron-backfill-coalesce-helper.py coalesce <bridge-cron-scheduler.py>", file=sys.stderr)
        return 2
    return cmd_coalesce(argv[2])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
