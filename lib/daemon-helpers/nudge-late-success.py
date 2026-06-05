#!/usr/bin/env python3
"""nudge-late-success.py — extract the fields the late-nudge-success
sweep needs from a `session_nudge_dropped` audit row's detail JSON, and
compute the drop->now elapsed seconds in one consistent (UTC) pass.

Issue #1459 (cron-dispatch recovery/reconcile layer, nudge-drop late
success leg). The daemon's `bridge_daemon_sweep_nudge_late_success`
reads prior `session_nudge_dropped reason=submit_lost_post_grace` rows
and, for any whose task later became claimed/done, emits
`session_nudge_late_success`. This helper avoids per-field bash JSON
parsing and avoids tz drift between the audit row's UTC `ts` and a
local-time epoch conversion.

Footgun #11 (bridge-daemon.sh has a 0 heredoc-stdin ceiling): invoked
file-as-argv, never via `python3 - <<'PY'`.

Invocation contract (argv):
    1 detail_json   the audit row detail object (JSON string).
    2 drop_ts_iso   the audit row's own ISO-8601 `ts` field.
    3 now_epoch     integer now epoch seconds.

Output (TSV, single line, on stdout):
    task_id<TAB>title<TAB>fingerprint<TAB>elapsed_seconds<TAB>resolved_ts_iso

`task_id` is empty when the detail has no integer task id (caller skips
the row). `elapsed_seconds` is max(0, now - drop) using UTC; 0 when the
drop ts cannot be parsed. `resolved_ts_iso` is now in UTC ISO-8601.
"""

import datetime
import json
import sys


def _parse_iso_utc(value):
    if not value:
        return None
    try:
        dt = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def main() -> int:
    detail_json = sys.argv[1] if len(sys.argv) > 1 else ""
    drop_ts_iso = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        now_epoch = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    except ValueError:
        now_epoch = 0

    try:
        detail = json.loads(detail_json) if detail_json else {}
    except json.JSONDecodeError:
        detail = {}
    if not isinstance(detail, dict):
        detail = {}

    task_id_raw = detail.get("task_id")
    task_id = ""
    try:
        if task_id_raw is not None and int(task_id_raw) > 0:
            task_id = str(int(task_id_raw))
    except (TypeError, ValueError):
        task_id = ""

    title = str(detail.get("title") or "")
    fingerprint = str(detail.get("fingerprint") or detail.get("nudge_key") or "")

    now_dt = datetime.datetime.fromtimestamp(now_epoch, tz=datetime.timezone.utc)
    drop_dt = _parse_iso_utc(drop_ts_iso)
    if drop_dt is not None:
        elapsed = int(max(0, (now_dt - drop_dt).total_seconds()))
    else:
        elapsed = 0
    resolved_iso = now_dt.isoformat(timespec="seconds")

    # Sanitize tab/newline out of free-text fields so the TSV stays one
    # line per row.
    def _clean(value):
        return value.replace("\t", " ").replace("\n", " ").replace("\r", " ")

    sys.stdout.write(
        "{}\t{}\t{}\t{}\t{}\n".format(
            task_id,
            _clean(title),
            _clean(fingerprint),
            elapsed,
            resolved_iso,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
