#!/usr/bin/env bash
# wiki-mention-scan — incremental rebuild of the wiki mention index
# (L1 observation layer for the entity-graph automation pipeline).
#
# Writes to $BRIDGE_WIKI_ROOT/_index/mentions.db. On each run:
#   1. Refreshes alias registry from frontmatter.
#   2. Rescans files modified since last successful scan.
#   3. Regenerates the distribution report snapshot.
#
# Cron: hourly ("cron 17 * * * *"). Offset :17 chosen to miss the
# top-of-hour cluster (memory-daily, wiki-daily-hygiene, etc.).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-mention-scan"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

SCAN_JSON="$(mktemp "${TMPDIR:-/tmp}/wiki-mention-scan.json.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$SCAN_JSON'; file_failure_task '$JOB' '$LOG'" ERR

if ! run_with_timeout 600 "$BRIDGE_PYTHON" "$HERE/wiki-mention-scan.py" \
      --wiki-root "$BRIDGE_WIKI_ROOT" --incremental \
      >"$SCAN_JSON" 2>>"$LOG"; then
  rc=$?
  log_audit "$JOB" "wiki-mention-scan.py FAILED rc=$rc" >/dev/null
  file_failure_task "$JOB" "$LOG"
  rm -f "$SCAN_JSON"
  exit "$rc"
fi

# Mirror the JSON scan summary to the audit log for trend visibility.
log_audit "$JOB" "scan-result $(cat "$SCAN_JSON")" >/dev/null

REPORT_PATH="$BRIDGE_WIKI_ROOT/_index/distribution-report-$(abs_date).md"
if ! run_with_timeout 120 "$BRIDGE_PYTHON" "$HERE/wiki-mention-scan.py" \
      --wiki-root "$BRIDGE_WIKI_ROOT" --report \
      --out "$REPORT_PATH" >>"$LOG" 2>&1; then
  rc=$?
  log_audit "$JOB" "report regeneration FAILED rc=$rc" >/dev/null
  # Scan itself succeeded — report failure is non-fatal for the cron.
fi

rm -f "$SCAN_JSON"
trap - ERR
log_audit "$JOB" "finished $JOB" >/dev/null
