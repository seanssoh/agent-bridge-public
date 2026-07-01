#!/usr/bin/env python3
# scripts/smoke/2090-cron-reconcile-helpers/report-query.py — file-as-argv
# helper for the #2090 reconcile smoke. Reads a bootstrap-memory report JSON
# and prints one field from it. Extracted from three inline `python3 - <<'PY'`
# heredoc-stdin blocks in the smoke so the heredoc-ban ratchet
# (scripts/lint-heredoc-ban.sh) stays green — file-as-argv, no heredoc-stdin.
#
# Usage:
#   report-query.py status <report> <step-substr>
#       print the `status` of the first record whose `step` contains <step-substr>
#   report-query.py note   <report> <step-substr>
#       print the `note` of the first record whose `step` contains <step-substr>
#   report-query.py field  <report> <field>
#       print a top-level report field (bool → true/false, None → empty)
import json
import sys


def _load(report):
    try:
        with open(report, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def _record_by_step(data, step_sub, key):
    for r in data.get("records", []):
        if step_sub in (r.get("step") or ""):
            return r.get(key) or ""
    return ""


def main():
    if len(sys.argv) < 4:
        return 0
    mode = sys.argv[1]
    data = _load(sys.argv[2])
    if data is None:
        return 0
    if mode == "status":
        print(_record_by_step(data, sys.argv[3], "status"))
    elif mode == "note":
        print(_record_by_step(data, sys.argv[3], "note"))
    elif mode == "field":
        val = data.get(sys.argv[3])
        print("true" if val is True else "false" if val is False else ("" if val is None else val))
    return 0


if __name__ == "__main__":
    sys.exit(main())
