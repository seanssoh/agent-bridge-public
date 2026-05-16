#!/usr/bin/env bash
# wiki-repair-links — walk the shared wiki and auto-apply unambiguous
# wikilink fixes. Structured log captures fixed/skipped-zero-cand/skipped-multi-cand/errors
# counts so trends are observable week-to-week.
#
# Cron: Saturday 05:00 KST ("cron 0 5 * * 6 Asia/Seoul").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-repair-links"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

REPORT_JSON="$(mktemp "${TMPDIR:-/tmp}/wiki-repair-links.json.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$REPORT_JSON'; file_failure_task '$JOB' '$LOG'" ERR

if ! run_with_timeout 600 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-wiki.py" repair-links \
      --shared-root "$BRIDGE_SHARED_ROOT" --apply --json \
      >"$REPORT_JSON" 2>>"$LOG"; then
  rc=$?
  log_audit "$JOB" "bridge-wiki.py repair-links FAILED rc=$rc" >/dev/null
  file_failure_task "$JOB" "$LOG"
  rm -f "$REPORT_JSON"
  exit 1
fi

# Parse report and tally structured counters.
"$BRIDGE_PYTHON" - "$REPORT_JSON" "$LOG" <<'PY'
import json, sys, pathlib
report_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])
try:
    data = json.loads(report_path.read_text(encoding="utf-8"))
except Exception as e:
    log_path.open("a").write(f"parse-error: {e}\n")
    sys.exit(0)
fixed = int(data.get("files_rewritten") or 0)
suggestions = data.get("suggestions") or []
zero_cand = sum(1 for s in suggestions if not s.get("candidates"))
multi_cand = sum(1 for s in suggestions if s.get("ambiguous"))
unambiguous_no_apply = sum(
    1 for s in suggestions
    if s.get("suggested") and not s.get("ambiguous")
)
errors = 0
line = (
    f"metrics "
    f"fixed={fixed} "
    f"skipped_zero_cand={zero_cand} "
    f"skipped_multi_cand={multi_cand} "
    f"unambiguous_still_visible={unambiguous_no_apply} "
    f"errors={errors} "
    f"suggestion_total={len(suggestions)}"
)
with log_path.open("a") as f:
    f.write(line + "\n")
print(line)
PY

rm -f "$REPORT_JSON"
log_audit "$JOB" "done" >/dev/null
exit 0
