#!/usr/bin/env python3
"""1459-cron-dispatch-recovery-helper.py — assertion helper for the
cron-dispatch recovery/reconcile smoke (issue #1459).

Invoked file-as-argv (no heredoc-stdin) so the smoke never trips the
footgun #11 heredoc-ban scanner (scripts/smoke/*.sh are scanned too).

Subcommands:
    audit-count <audit_jsonl> <action> [contains]
        Print the number of audit rows whose `action` matches and whose
        full record JSON contains the optional `contains` substring.

    audit-detail <audit_jsonl> <action> <detail_key>
        Print the `detail.<detail_key>` of the LAST matching audit row
        (empty when none / missing). Used to assert field values.

    status-state <status_json>
        Print the `state` field of a cron run status.json (empty on any
        read/parse error).

    fail-if-action <audit_jsonl> <action>
        Exit 1 (with a message) if ANY audit row has `action`. Used to
        assert the human nudge/unclaimed taxonomy was NOT used.
"""

import json
import sys
from pathlib import Path


def _iter_rows(path_str):
    path = Path(path_str)
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            yield record


def _detail(record):
    detail = record.get("detail")
    return detail if isinstance(detail, dict) else {}


def cmd_audit_count(argv):
    audit_path, action = argv[0], argv[1]
    contains = argv[2] if len(argv) > 2 else ""
    count = 0
    for record in _iter_rows(audit_path):
        if record.get("action") != action:
            continue
        if contains and contains not in json.dumps(record, ensure_ascii=True, sort_keys=True):
            continue
        count += 1
    print(count)
    return 0


def cmd_audit_detail(argv):
    audit_path, action, key = argv[0], argv[1], argv[2]
    value = ""
    for record in _iter_rows(audit_path):
        if record.get("action") != action:
            continue
        detail = _detail(record)
        if key in detail:
            value = str(detail.get(key))
    print(value)
    return 0


def cmd_status_state(argv):
    path = Path(argv[0])
    if not path.is_file():
        print("")
        return 0
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        print("")
        return 0
    print(str(data.get("state") or "") if isinstance(data, dict) else "")
    return 0


def cmd_fail_if_action(argv):
    audit_path, action = argv[0], argv[1]
    for record in _iter_rows(audit_path):
        if record.get("action") == action:
            sys.stderr.write(
                "FAIL: forbidden audit action '{}' present: {}\n".format(
                    action, json.dumps(record, ensure_ascii=True, sort_keys=True)
                )
            )
            return 1
    return 0


_COMMANDS = {
    "audit-count": cmd_audit_count,
    "audit-detail": cmd_audit_detail,
    "status-state": cmd_status_state,
    "fail-if-action": cmd_fail_if_action,
}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        sys.stderr.write("usage: 1459-cron-dispatch-recovery-helper.py <subcommand> ...\n")
        return 2
    return _COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
