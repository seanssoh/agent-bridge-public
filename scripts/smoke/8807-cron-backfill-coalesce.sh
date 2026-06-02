#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/8807-cron-backfill-coalesce.sh — incident #8807 P1.
#
# After daemon downtime, enumerate_due_runs() in bridge-cron-scheduler.py
# replayed up to BRIDGE_CRON_MAX_CATCHUP_OCCURRENCES_PER_JOB (default 12)
# missed occurrences PER JOB as a single enqueue burst — the "inbox flooding"
# the incident report flagged. For idempotent / picker-sweep families (where
# running the latest occurrence subsumes the missed ones), P1 coalesces the
# catch-up backlog to the most recent occurrence(s) BEFORE enqueue.
#
# This smoke drives bridge-cron-scheduler.py's enumerate_due_runs() directly
# (no daemon, no queue) and asserts the coalesce behaviour + that
# distinct-occurrence families are NOT coalesced + the env overrides + that the
# kept occurrence is the latest. It also pins the scheduler-state.json
# canonical / native-scheduler-state.json compat-copy documentation in
# bridge-cron.sh.

set -euo pipefail

SMOKE_NAME="8807-cron-backfill-coalesce"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

SCHED_PY="$SMOKE_REPO_ROOT/bridge-cron-scheduler.py"
CRON_SH="$SMOKE_REPO_ROOT/bridge-cron.sh"

smoke_log "A1: bridge-cron-scheduler.py compiles"
python3 -c "import py_compile; py_compile.compile('$SCHED_PY', doraise=True)" || \
  smoke_fail "bridge-cron-scheduler.py failed py_compile"

smoke_log "B: catch-up coalescing for idempotent / picker-sweep families"
python3 - "$SCHED_PY" <<'PY' || smoke_fail "catch-up coalesce behaviour failed"
import importlib.util, os, sys
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("bridge_cron_scheduler", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)

LOCAL = m.LOCAL_TZ
now = datetime(2026, 6, 3, 12, 0, 0, tzinfo=timezone.utc).astimezone(LOCAL)
# 3h of downtime → ~18 missed picker-sweep (*/10) slots, ~3 hourly briefings.
start = now - timedelta(hours=3)

picker = {"id": "j1", "name": "picker-sweep", "agentId": "patch", "enabled": True,
          "schedule": {"kind": "cron", "expr": "*/10 * * * *"}}
briefing = {"id": "j2", "name": "morning-briefing-patch", "agentId": "patch", "enabled": True,
            "schedule": {"kind": "cron", "expr": "0 * * * *"}}

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
os.environ["BRIDGE_CRON_COALESCE_CATCHUP_FAMILIES"] = "morning-briefing"
due_o, _ = m.enumerate_due_runs([briefing], start, now, 12)
assert len([d for d in due_o if d.family == "morning-briefing"]) == 1, "override set must coalesce the briefing"
# picker no longer listed → not coalesced.
due_p, _ = m.enumerate_due_runs([picker], start, now, 12)
assert len(due_p) > 1, "picker must NOT coalesce once removed from the override set"
del os.environ["BRIDGE_CRON_COALESCE_CATCHUP_FAMILIES"]

# Cap override: keep N most recent instead of 1.
os.environ["BRIDGE_CRON_COALESCE_CATCHUP_MAX"] = "2"
due_c, _ = m.enumerate_due_runs([picker], start, now, 12)
assert len(due_c) == 2, f"cap=2 must keep 2 picker occurrences, got {len(due_c)}"
del os.environ["BRIDGE_CRON_COALESCE_CATCHUP_MAX"]

# No downtime: a single in-window occurrence must not register a spurious
# coalesce (the normal steady-state path is byte-equivalent).
short = now - timedelta(minutes=5)
due_s, counters_s = m.enumerate_due_runs([picker], short, now, 12)
assert counters_s.get("coalesced_jobs", 0) == 0, "single-occurrence window must not coalesce"

print(f"[ok] picker coalesced {counters.get('coalesced_occurrences')} → 1; briefing kept {len(brief_runs)}; overrides + steady-state correct")
PY

smoke_log "C: scheduler-state.json canonical / native-scheduler-state.json compat-copy documented"
grep -q 'scheduler-state.json' "$CRON_SH" || smoke_fail "bridge-cron.sh lost the scheduler-state.json reference"
grep -qi 'COMPAT COPY' "$CRON_SH" || \
  smoke_fail "bridge-cron.sh does not document native-scheduler-state.json as a compat copy"
grep -qi 'NOT two active schedulers' "$CRON_SH" || \
  smoke_fail "bridge-cron.sh does not clarify there is a single active scheduler"

smoke_log "PASS: $SMOKE_NAME"
