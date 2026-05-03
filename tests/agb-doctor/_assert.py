#!/usr/bin/env python3
"""Named JSON predicates for tests/agb-doctor/smoke.sh.

Each subcommand reads the doctor's `--json` payload from argv[2] and exits 0
on pass / non-zero on fail. Smoke uses bash `if`-tests against the exit code
and prints its own pass/fail line, so this helper deliberately stays silent
on success and writes a one-line reason to stderr on failure.

Predicates are kept as tiny named functions so the smoke harness never has
to expand a test-controlled string into Python code. Each predicate has a
fixed argv schema documented in its docstring.
"""

from __future__ import annotations

import json
import sys
from typing import Any


REQUIRED_STALE_STOPPED_EVIDENCE = {
    "loop_enabled",
    "tmux_alive",
    "queued",
    "blocked",
    "wake_stale_seconds",
}


def _load(payload: str) -> list[dict[str, Any]]:
    return json.loads(payload)


def empty(payload: str, _args: list[str]) -> bool:
    findings = _load(payload)
    if findings != []:
        print(f"expected [], got {len(findings)} findings", file=sys.stderr)
        return False
    return True


def stale_stopped_emitted(payload: str, args: list[str]) -> bool:
    if not args:
        print("stale_stopped_emitted requires <agent-name>", file=sys.stderr)
        return False
    agent = args[0]
    findings = _load(payload)
    matches = [
        f for f in findings
        if f.get("kind") == "stale-stopped-with-queue" and f.get("agent") == agent
    ]
    if len(matches) != 1:
        print(
            f"expected exactly 1 stale-stopped-with-queue for {agent!r}, "
            f"got {len(matches)} (kinds={[f.get('kind') for f in findings]})",
            file=sys.stderr,
        )
        return False
    return True


def stale_stopped_evidence_shape(payload: str, _args: list[str]) -> bool:
    findings = _load(payload)
    target = next(
        (f for f in findings if f.get("kind") == "stale-stopped-with-queue"),
        None,
    )
    if target is None:
        print("no stale-stopped-with-queue finding present", file=sys.stderr)
        return False
    evidence = target.get("evidence") or {}
    keys = set(evidence.keys()) if isinstance(evidence, dict) else set()
    if keys != REQUIRED_STALE_STOPPED_EVIDENCE:
        print(
            f"evidence keys {sorted(keys)} != spec {sorted(REQUIRED_STALE_STOPPED_EVIDENCE)}",
            file=sys.stderr,
        )
        return False
    return True


def suggested_action_equals(payload: str, args: list[str]) -> bool:
    if len(args) < 2:
        print("suggested_action_equals requires <kind> <expected>", file=sys.stderr)
        return False
    kind, expected = args[0], args[1]
    findings = _load(payload)
    target = next((f for f in findings if f.get("kind") == kind), None)
    if target is None:
        print(f"no finding of kind {kind!r}", file=sys.stderr)
        return False
    if target.get("suggested_action") != expected:
        print(
            f"suggested_action {target.get('suggested_action')!r} != {expected!r}",
            file=sys.stderr,
        )
        return False
    return True


def kind_absent(payload: str, args: list[str]) -> bool:
    if not args:
        print("kind_absent requires <kind>", file=sys.stderr)
        return False
    kind = args[0]
    findings = _load(payload)
    leaks = [f for f in findings if f.get("kind") == kind]
    if leaks:
        print(f"unexpected {kind!r} findings present: {len(leaks)}", file=sys.stderr)
        return False
    return True


def stale_blocked_task_id(payload: str, args: list[str]) -> bool:
    if not args:
        print("stale_blocked_task_id requires <task-id>", file=sys.stderr)
        return False
    try:
        task_id = int(args[0])
    except ValueError:
        print(f"task-id {args[0]!r} is not an int", file=sys.stderr)
        return False
    findings = _load(payload)
    matches = [
        f for f in findings
        if f.get("kind") == "stale-blocked-task"
        and isinstance(f.get("evidence"), dict)
        and f["evidence"].get("task_id") == task_id
    ]
    if not matches:
        print(
            f"no stale-blocked-task finding for task_id={task_id}",
            file=sys.stderr,
        )
        return False
    return True


def stale_blocked_suggested_prefix(payload: str, args: list[str]) -> bool:
    if not args:
        print("stale_blocked_suggested_prefix requires <prefix>", file=sys.stderr)
        return False
    prefix = args[0]
    findings = _load(payload)
    target = next(
        (f for f in findings if f.get("kind") == "stale-blocked-task"),
        None,
    )
    if target is None:
        print("no stale-blocked-task finding present", file=sys.stderr)
        return False
    if not str(target.get("suggested_action") or "").startswith(prefix):
        print(
            f"suggested_action {target.get('suggested_action')!r} "
            f"does not start with {prefix!r}",
            file=sys.stderr,
        )
        return False
    return True


def abnormal_pane_placeholder(payload: str, _args: list[str]) -> bool:
    findings = _load(payload)
    if len(findings) != 1:
        print(f"expected exactly 1 finding, got {len(findings)}", file=sys.stderr)
        return False
    target = findings[0]
    if target.get("kind") != "detector-error":
        print(f"expected kind=detector-error, got {target.get('kind')}", file=sys.stderr)
        return False
    evidence = target.get("evidence") or {}
    if not isinstance(evidence, dict):
        print("evidence missing/not-dict", file=sys.stderr)
        return False
    if evidence.get("detector") != "abnormal-session-pane":
        print(
            f"expected detector=abnormal-session-pane, got {evidence.get('detector')}",
            file=sys.stderr,
        )
        return False
    return True


def kinds_superset(payload: str, args: list[str]) -> bool:
    expected = set(args)
    if not expected:
        print("kinds_superset requires at least one kind arg", file=sys.stderr)
        return False
    findings = _load(payload)
    actual = {f.get("kind") for f in findings}
    missing = expected - actual
    if missing:
        print(
            f"missing kinds: {sorted(missing)} (got {sorted(actual)})",
            file=sys.stderr,
        )
        return False
    return True


def only_kind(payload: str, args: list[str]) -> bool:
    if not args:
        print("only_kind requires <kind>", file=sys.stderr)
        return False
    kind = args[0]
    findings = _load(payload)
    if not findings:
        print("no findings — expected at least one", file=sys.stderr)
        return False
    bad = [f for f in findings if f.get("kind") != kind]
    if bad:
        print(
            f"unexpected non-{kind} findings: {[f.get('kind') for f in bad]}",
            file=sys.stderr,
        )
        return False
    return True


CHECKS = {
    "empty": empty,
    "stale_stopped_emitted": stale_stopped_emitted,
    "stale_stopped_evidence_shape": stale_stopped_evidence_shape,
    "suggested_action_equals": suggested_action_equals,
    "kind_absent": kind_absent,
    "stale_blocked_task_id": stale_blocked_task_id,
    "stale_blocked_suggested_prefix": stale_blocked_suggested_prefix,
    "abnormal_pane_placeholder": abnormal_pane_placeholder,
    "kinds_superset": kinds_superset,
    "only_kind": only_kind,
}


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: _assert.py <check> <payload-json> [args...]", file=sys.stderr)
        return 2
    check = sys.argv[1]
    payload = sys.argv[2]
    args = sys.argv[3:]
    fn = CHECKS.get(check)
    if fn is None:
        print(f"unknown check: {check!r} (valid: {sorted(CHECKS)})", file=sys.stderr)
        return 2
    return 0 if fn(payload, args) else 1


if __name__ == "__main__":
    sys.exit(main())
