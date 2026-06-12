#!/usr/bin/env bash
# scripts/smoke/1826-cron-at-naive-tz.sh — Issue #1826 smoke.
#
# `cron create --at <naive-datetime>` used to interpret a NAIVE (no-offset)
# datetime in the HOST local zone (UTC on the live install) and SILENTLY drop
# `--tz` — so a one-shot fired hours off its intended wall-clock with no error.
#
# The fix anchors a naive `--at` in `--tz` (host-local when omitted), preserves
# an explicit offset / `Z` unchanged, errors loudly on an unhonorable `--tz`
# instead of dropping it, and echoes the resolved instant in BOTH local + UTC.
#
# The whole reproduction depends on the HOST zone NOT matching `--tz`, so this
# smoke pins `TZ=UTC` (the live-install surface) for every invocation. The
# expected absolute instant is then independent of the runner's machine zone.

set -euo pipefail

SMOKE_NAME="1826-cron-at-naive-tz"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
CRON_PY="$REPO_ROOT/bridge-cron.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home
JOBS_FILE="$BRIDGE_NATIVE_CRON_JOBS_FILE"

# Pin the host zone to UTC so a naive `--at` interpreted in the host zone (the
# old bug) is unambiguously distinct from one anchored in `--tz Asia/Seoul`.
export TZ="UTC"

# Helper: read the stored `at` / `tz` (and the schedule kind) for a job title.
stored_at() {
  local title="$1"
  "$PY_BIN" - "$JOBS_FILE" "$title" <<'PY'
import json, sys
jobs = json.load(open(sys.argv[1], encoding="utf-8")).get("jobs", [])
for job in jobs:
    if job.get("name") == sys.argv[2]:
        sched = job.get("schedule") or {}
        print(sched.get("at", ""))
        break
PY
}

# Helper: read the stored `tz` label for a job title.
stored_tz() {
  local title="$1"
  "$PY_BIN" - "$JOBS_FILE" "$title" <<'PY'
import json, sys
for job in json.load(open(sys.argv[1], encoding="utf-8")).get("jobs", []):
    if job.get("name") == sys.argv[2]:
        print((job.get("schedule") or {}).get("tz", "")); break
PY
}

# Helper: compute the absolute UTC epoch (seconds) the scheduler will honor for
# the stored `at` value, via the production scheduler's own enumeration path.
at_epoch() {
  local title="$1"
  "$PY_BIN" - "$REPO_ROOT" "$JOBS_FILE" "$title" <<'PY'
import importlib.util, json, sys
from datetime import datetime, timezone

repo, jobs_file, title = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "bridge_cron_scheduler", f"{repo}/bridge-cron-scheduler.py"
)
mod = importlib.util.module_from_spec(spec)
sys.modules["bridge_cron_scheduler"] = mod
spec.loader.exec_module(mod)

job = next(
    j for j in json.load(open(jobs_file, encoding="utf-8")).get("jobs", [])
    if j.get("name") == title
)
occ = mod.parse_iso((job.get("schedule") or {}).get("at"))
print(int(occ.astimezone(timezone.utc).timestamp()))
PY
}

# ---- 1. naive --at honors --tz (no longer host-UTC, no silent drop) ---------
smoke_log "case 1: naive --at is anchored in --tz Asia/Seoul, not host-UTC"

OUT1="$("$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-seoul \
  --at "2026-06-12T13:30:00" \
  --tz "Asia/Seoul" \
  --title "naive-seoul" \
  --payload "ping")"

# 13:30 Asia/Seoul (+09:00) == 04:30 UTC == epoch 1781238600.
smoke_assert_eq "2026-06-12T13:30:00+09:00" "$(stored_at "naive-seoul")" \
  "naive --at must be stored with the --tz offset, not the host offset"
smoke_assert_eq "1781238600" "$(at_epoch "naive-seoul")" \
  "scheduler must honor 13:30 Asia/Seoul == 04:30 UTC"

# The create echo must surface BOTH local and UTC so the operator can confirm.
smoke_assert_contains "$OUT1" "2026-06-12T13:30:00+09:00 (Asia/Seoul)" \
  "create must echo the resolved local wall-clock"
smoke_assert_contains "$OUT1" "2026-06-12T04:30:00+00:00 (UTC)" \
  "create must echo the resolved UTC instant"
smoke_log "ok: naive --at anchored in --tz, next_run echoed in local + UTC"

# ---- 2. naive --at with OMITTED --tz falls back to the REAL host-local zone --
# Issue #1826 regression (codex catch): the omitted-`--tz` path must anchor in
# the host's actual wall-clock zone, NOT UTC. The earlier version of this case
# passed `--tz UTC` explicitly, which masked the bug on a non-UTC host where
# default_tz_name() falls back to "UTC". Run it with --tz genuinely omitted.
smoke_log "case 2a: naive --at, --tz OMITTED, under TZ=UTC -> 13:30 UTC"

"$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-host \
  --at "2026-06-12T13:30:00" \
  --title "naive-host-utc" \
  --payload "ping" >/dev/null

# Under TZ=UTC with no --tz, 13:30 is host-local == 13:30 UTC == epoch 1781271000.
smoke_assert_eq "1781271000" "$(at_epoch "naive-host-utc")" \
  "naive --at in an omitted-tz UTC host must resolve to 13:30 UTC"
smoke_log "ok: omitted --tz on a UTC host resolves to host-local (UTC)"

smoke_log "case 2b: naive --at, --tz OMITTED, under a NON-UTC host (Asia/Seoul)"

# Re-run create under TZ=Asia/Seoul with --tz still omitted. The host zone on
# macOS/glibc surfaces as a bare abbreviation (KST) with no IANA .key — exactly
# the case where the buggy default_tz_name() returned "UTC" and mis-anchored.
SEOUL_JOBS="$BRIDGE_HOME/cron/jobs-seoul.json"
TZ="Asia/Seoul" "$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$SEOUL_JOBS" \
  --agent agent-seoul-host \
  --at "2026-06-12T13:30:00" \
  --title "naive-host-seoul" \
  --payload "ping" >/dev/null

# 13:30 Asia/Seoul (+09:00) == 04:30 UTC == epoch 1781238600, NOT 13:30 UTC.
SEOUL_EPOCH="$("$PY_BIN" - "$REPO_ROOT" "$SEOUL_JOBS" "naive-host-seoul" <<'PY'
import importlib.util, json, sys
from datetime import timezone
repo, jobs_file, title = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("bridge_cron_scheduler", f"{repo}/bridge-cron-scheduler.py")
mod = importlib.util.module_from_spec(spec); sys.modules["bridge_cron_scheduler"] = mod
spec.loader.exec_module(mod)
job = next(j for j in json.load(open(jobs_file, encoding="utf-8")).get("jobs", []) if j.get("name") == title)
print(int(mod.parse_iso((job.get("schedule") or {}).get("at")).astimezone(timezone.utc).timestamp()))
PY
)"
smoke_assert_eq "1781238600" "$SEOUL_EPOCH" \
  "omitted --tz on a non-UTC host must anchor in the host zone (+09:00), not UTC"
smoke_log "ok: omitted --tz on a non-UTC host honors the real host wall-clock"

# ---- 3. explicit-offset --at is UNCHANGED regardless of --tz ----------------
smoke_log "case 3: explicit-offset --at keeps its offset, --tz ignored"

"$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-offset \
  --at "2026-06-12T13:30:00+09:00" \
  --tz "America/New_York" \
  --title "explicit-offset" \
  --payload "ping" >/dev/null

smoke_assert_eq "2026-06-12T13:30:00+09:00" "$(stored_at "explicit-offset")" \
  "explicit +09:00 --at must be preserved verbatim, ignoring a conflicting --tz"
smoke_assert_eq "1781238600" "$(at_epoch "explicit-offset")" \
  "explicit-offset --at must resolve to its own instant (04:30 UTC)"

# `Z` suffix is also an explicit (UTC) offset and must be preserved.
"$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-zulu \
  --at "2026-06-12T04:30:00Z" \
  --tz "Asia/Seoul" \
  --title "explicit-zulu" \
  --payload "ping" >/dev/null

smoke_assert_eq "2026-06-12T04:30:00+00:00" "$(stored_at "explicit-zulu")" \
  "Z-suffixed --at must normalize to +00:00, ignoring --tz"
smoke_assert_eq "1781238600" "$(at_epoch "explicit-zulu")" \
  "Z-suffixed --at must resolve to its own UTC instant"
smoke_log "ok: explicit-offset / Z --at preserved, --tz not applied"

# ---- 4. unhonorable --tz on a naive --at ERRORS (never silent-dropped) -------
smoke_log "case 4: naive --at with an invalid --tz errors loudly, not silently"

set +e
ERR_OUT="$("$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-bad-tz \
  --at "2026-06-12T13:30:00" \
  --tz "Not/AZone" \
  --title "bad-tz" \
  --payload "ping" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || smoke_fail "naive --at with invalid --tz must exit non-zero (got rc=$RC)"
smoke_assert_contains "$ERR_OUT" "invalid --tz value: Not/AZone" \
  "the error must name the offending --tz, not silently drop it"
# And the broken job must NOT have been written.
smoke_assert_eq "" "$(stored_at "bad-tz")" \
  "a failed create must not persist a mis-scheduled job"
smoke_log "ok: unhonorable --tz errors loudly and writes nothing"

# An invalid --at value still errors (regression guard).
set +e
"$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-bad-at \
  --at "not-a-datetime" \
  --tz "Asia/Seoul" \
  --title "bad-at" \
  --payload "ping" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || smoke_fail "invalid --at value must exit non-zero (got rc=$RC)"
smoke_log "ok: invalid --at value still errors"

# ---- 5. DST boundary: offset follows ZoneInfo, not a fixed offset -----------
smoke_log "case 5: DST-safe anchoring (America/New_York EST vs EDT)"

"$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-est \
  --at "2026-01-15T12:00:00" \
  --tz "America/New_York" \
  --title "winter-est" \
  --payload "ping" >/dev/null
"$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$JOBS_FILE" \
  --agent agent-edt \
  --at "2026-07-15T12:00:00" \
  --tz "America/New_York" \
  --title "summer-edt" \
  --payload "ping" >/dev/null

# Jan 15 noon is EST (-05:00); Jul 15 noon is EDT (-04:00). A naive fixed-offset
# implementation would emit the same offset for both — proving DST-correctness.
smoke_assert_eq "2026-01-15T12:00:00-05:00" "$(stored_at "winter-est")" \
  "winter noon must anchor at EST (-05:00)"
smoke_assert_eq "2026-07-15T12:00:00-04:00" "$(stored_at "summer-edt")" \
  "summer noon must anchor at EDT (-04:00)"
smoke_log "ok: offset follows DST via ZoneInfo (no hand-rolled offset math)"

# Issue #1826 (codex r2, [P2]): the OMITTED-`--tz` host-local path must ALSO be
# DST-aware. LOCAL_TZ is a fixed offset captured at process start; resolving the
# real host IANA zone (host_zone) is what makes a January naive --at anchor at
# EST even when the runner's process started in summer. Run a fresh process per
# target month under TZ=America/New_York with --tz OMITTED.
DST_JOBS="$BRIDGE_HOME/cron/jobs-dst.json"
stored_at_file() {
  "$PY_BIN" - "$1" "$2" <<'PY'
import json, sys
for job in json.load(open(sys.argv[1], encoding="utf-8")).get("jobs", []):
    if job.get("name") == sys.argv[2]:
        print((job.get("schedule") or {}).get("at", "")); break
PY
}
TZ="America/New_York" "$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$DST_JOBS" --agent agent-host-est \
  --at "2026-01-15T12:00:00" --title "host-winter" --payload "ping" >/dev/null
TZ="America/New_York" "$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$DST_JOBS" --agent agent-host-edt \
  --at "2026-07-15T12:00:00" --title "host-summer" --payload "ping" >/dev/null
smoke_assert_eq "2026-01-15T12:00:00-05:00" "$(stored_at_file "$DST_JOBS" "host-winter")" \
  "omitted --tz winter noon must anchor at host EST (-05:00), not a frozen offset"
smoke_assert_eq "2026-07-15T12:00:00-04:00" "$(stored_at_file "$DST_JOBS" "host-summer")" \
  "omitted --tz summer noon must anchor at host EDT (-04:00)"
smoke_log "ok: omitted --tz host-local path is DST-aware (host_zone, not frozen LOCAL_TZ)"

# Issue #1826 (codex r4, [P2]): when --tz is omitted, $TZ is unset, AND the host
# tzinfo has no .key (macOS/glibc reading the /etc/localtime symlink), the host
# IANA zone must still be recovered from /etc/localtime so host_zone() stays
# DST-aware instead of degrading to the frozen-offset LOCAL_TZ. Verify the
# resolver contract portably (it works regardless of the runner's own zone).
LT_CHECK="$("$PY_BIN" - "$REPO_ROOT" <<'PY'
import importlib.util, sys, unittest.mock
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
spec = importlib.util.spec_from_file_location("bc", f"{sys.argv[1]}/bridge-cron.py")
bc = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc)
fake = "/private/var/db/timezone/tz/2026b/zoneinfo/America/New_York"
# No .key, no $TZ -> must resolve America/New_York from the /etc/localtime link.
with unittest.mock.patch.dict("os.environ", {}, clear=False) as env:
    import os
    os.environ.pop("TZ", None)
    with unittest.mock.patch.object(bc, "LOCAL_TZ", datetime.now(timezone.utc).astimezone().tzinfo), \
         unittest.mock.patch("os.path.realpath", return_value=fake):
        name = bc.host_iana_zone_name()
        zone = bc.host_zone()
assert name == "America/New_York", name
assert isinstance(zone, ZoneInfo) and zone.key == "America/New_York", zone
# And the zone is genuinely DST-aware (distinct winter/summer offsets).
jan = datetime(2026, 1, 15, 12, tzinfo=zone).utcoffset()
jul = datetime(2026, 7, 15, 12, tzinfo=zone).utcoffset()
assert jan != jul, (jan, jul)
print("OK")
PY
)"
smoke_assert_eq "OK" "$LT_CHECK" \
  "host zone must resolve from /etc/localtime when .key and \$TZ are absent (DST-aware)"
smoke_log "ok: /etc/localtime fallback keeps the omitted-tz path DST-aware"

# ---- 6. update path: re-parsing a stored explicit-offset --at is idempotent --
# run_native_update reuses build_native_job; updating an at-job WITHOUT touching
# --at must not shift the instant (the stored offset is re-parsed verbatim), and
# updating the --at to a new explicit-offset value must take effect cleanly.
smoke_log "case 6: update preserves the stored instant, honors a new explicit --at"

# Title-only edit on case 1's job: the instant must be unchanged.
"$PY_BIN" "$CRON_PY" native-update \
  --jobs-file "$JOBS_FILE" \
  --title "naive-seoul-renamed" \
  "naive-seoul" >/dev/null
smoke_assert_eq "2026-06-12T13:30:00+09:00" "$(stored_at "naive-seoul-renamed")" \
  "a title-only update must not re-anchor or shift the stored at instant"
smoke_assert_eq "1781238600" "$(at_epoch "naive-seoul-renamed")" \
  "the absolute instant must survive a non-schedule update"
# Issue #1826 (codex r2, [P2]): a title-only update must PRESERVE the stored tz
# label (case 1's job was created with --tz Asia/Seoul under TZ=UTC); it must not
# be clobbered to the host zone just because no new --at/--tz was supplied.
smoke_assert_eq "Asia/Seoul" "$(stored_tz "naive-seoul-renamed")" \
  "a title-only update must preserve the stored tz label, not clobber it"

# Change --at to a new explicit-offset value: it must take effect verbatim.
"$PY_BIN" "$CRON_PY" native-update \
  --jobs-file "$JOBS_FILE" \
  --at "2026-08-01T09:00:00-04:00" \
  "naive-seoul-renamed" >/dev/null
smoke_assert_eq "2026-08-01T09:00:00-04:00" "$(stored_at "naive-seoul-renamed")" \
  "an explicit-offset --at update must be stored verbatim"
smoke_log "ok: update preserves the instant and honors a new explicit --at"

# ---- 7. update CRON -> AT conversion honors host-local on omitted --tz --------
# Issue #1826 (codex r2, [P1]): converting a cron job to a one-shot via
# `native-update --at` with --tz OMITTED must anchor in the host zone, NOT
# default_tz_name()'s "UTC". Decide the tz fallback by the kind this invocation
# PRODUCES, not the existing job's kind. Run under TZ=Asia/Seoul.
smoke_log "case 7: update converts a cron job to a one-shot, omitted --tz, host-local"

CONV_JOBS="$BRIDGE_HOME/cron/jobs-convert.json"
TZ="Asia/Seoul" "$PY_BIN" "$CRON_PY" native-create \
  --jobs-file "$CONV_JOBS" --agent agent-conv \
  --schedule "0 3 * * *" --tz "Asia/Seoul" --title "to-convert" --payload "ping" >/dev/null
TZ="Asia/Seoul" "$PY_BIN" "$CRON_PY" native-update \
  --jobs-file "$CONV_JOBS" --at "2026-06-12T13:30:00" "to-convert" >/dev/null
smoke_assert_eq "2026-06-12T13:30:00+09:00" "$(stored_at_file "$CONV_JOBS" "to-convert")" \
  "cron->at conversion with omitted --tz must anchor host-local (+09:00), not UTC"
smoke_log "ok: cron->at conversion honors the real host zone, not default UTC"

smoke_log "all 1826-cron-at-naive-tz cases passed"
