#!/usr/bin/env bash
# wiki-copy-full-backfill — weekly catch-all for Lane A daily-note copy.
#
# Issue #320 Track B. The daily wiki-daily-ingest.sh runs at 06:00 KST
# with a watermark-driven --since/--until window (issue #321). If an
# agent's per-day backfill task is never processed (long-running work,
# missed window) the daily note can be written to agent-home after the
# next morning's Lane A has already advanced its watermark past the
# stranded date. This weekly catch-all sweeps every date present under
# every agent's memory/ directory and copies any missing replicas into
# shared/wiki/agents/<agent>/daily/. wiki-daily-copy.py:93 (sha256)
# guarantees the pass is idempotent — unchanged sources are skipped.
#
# Cron: "cron 0 7 * * 0 Asia/Seoul" (Sundays 07:00 KST, one hour after
# the daily 06:00 stagger so it never overlaps with Lane A on the same
# wall-clock minute).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-copy-full-backfill"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

SUMMARY_JSON="$(mktemp "${TMPDIR:-/tmp}/wiki-copy-full-backfill.json.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$SUMMARY_JSON'; file_failure_task '$JOB' '$LOG'" ERR

# Capture rc *before* an `if` test — `if ! cmd` makes `$?` reflect the
# negated test, not the underlying command, so a real failure would be
# logged as `rc=0` and re-exited as success. Run the command bare, snap
# the status into rc, then branch on it. (#320 r2 codex)
run_with_timeout 1800 "$BRIDGE_PYTHON" "$HERE/wiki-daily-copy.py" \
    --all --json \
    >"$SUMMARY_JSON" 2>>"$LOG" \
  && rc=0 || rc=$?
if (( rc != 0 )); then
  log_audit "$JOB" "wiki-daily-copy.py --all FAILED rc=$rc" >/dev/null
  file_failure_task "$JOB" "$LOG"
  rm -f "$SUMMARY_JSON"
  exit "$rc"
fi

# Mirror the JSON summary to the audit log so trend reviews can see the
# weekly catch-all reach (agents_seen / files_seen / replaced).
log_audit "$JOB" "result $(cat "$SUMMARY_JSON")" >/dev/null

rm -f "$SUMMARY_JSON"
trap - ERR
log_audit "$JOB" "finished $JOB" >/dev/null
