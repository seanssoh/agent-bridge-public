#!/usr/bin/env python3
"""Regression check for issue #2229 — memory-daily backfill self-perpetuation.

The self-signal sender-gate (issue #728) must catch the two sender shapes that
let a backfill re-emit itself every day on zero-activity slots:

  gap #1  the harvester's own cron wake, stamped ``cron:memory-daily-<agent>``
          (bridge-cron.sh uses ``cron:$CRON_JOB_NAME``) — a colon-prefixed form
          the plain "cron-dispatch"/"cron-followup" prefixes never matched.
  gap #2  the backfill task itself, now created ``--from memory-daily`` (was
          ``--from <agent>``, which made ``_is_system_sender`` short-circuit to
          False so the ``^[memory-daily] backfill `` title was never checked).

It must NOT regress issue #728: a human / other-agent task is never a self-signal
even if its title looks placeholder-ish.

Loads bridge-memory.py by path (argv[1]) since the module name has a hyphen.
Exits 0 on success, 1 with a diagnostic on any failed assertion.
"""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path


def load_module(path):
    spec = importlib.util.spec_from_file_location("bridge_memory_2229", path)
    mod = importlib.util.module_from_spec(spec)
    # Register before exec so @dataclass annotations (e.g. UserSpec) can resolve
    # cls.__module__ via sys.modules — otherwise exec_module raises AttributeError.
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: self_signal_2229_check.py <path-to-bridge-memory.py>\n")
        return 2
    m = load_module(sys.argv[1])
    fails = []

    def check(cond, label):
        if not cond:
            fails.append(label)

    # ---- gap #1: cron-dispatch colon-prefix sender is a recognized self-signal
    check(
        m._is_system_sender("cron:memory-daily-erp-cli-ajh-it") is True,
        "gap#1 _is_system_sender('cron:memory-daily-<agent>') should be True",
    )
    check(
        m._is_self_signal_event(
            {
                "title": "[cron-dispatch] memory-daily-erp-cli-ajh-it",
                "created_by": "cron:memory-daily-erp-cli-ajh-it",
            }
        )
        is True,
        "gap#1 cron-dispatch memory-daily wake should classify as self-signal",
    )

    # ---- gap #2 (reader half): a backfill stamped --from memory-daily is caught
    check(
        m._is_self_signal_event(
            {
                "title": "[memory-daily] backfill erp-cli-ajh-it / 2026-06-28",
                "from": "memory-daily",
            }
        )
        is True,
        "gap#2 [memory-daily] backfill from=memory-daily should be self-signal",
    )

    # ---- gap #2 (writer half): _queue_backfill must STAMP --from memory-daily.
    # Monkeypatch subprocess.run to capture the argv; task_cli must exist, so the
    # smoke harness stubs $BRIDGE_HOME/bridge-task.sh before invoking this check.
    captured = {}

    def fake_run(cmd, *args, **kwargs):
        captured["cmd"] = list(cmd)

        class _Result:
            returncode = 0
            stdout = "task #999 created"
            stderr = ""

        return _Result()

    bridge_home = Path(os.environ.get("BRIDGE_HOME") or "/nonexistent")
    task_cli = bridge_home / "bridge-task.sh"
    if task_cli.exists():
        real_run = m.subprocess.run
        real_body = m._render_backfill_body
        m.subprocess.run = fake_run
        m._render_backfill_body = lambda *a, **k: "body"
        try:
            m._queue_backfill(
                "erp-cli-ajh-it",
                "2026-06-28",
                bridge_home,
                str(bridge_home),
                {"strong": {"transcript_sessions": ["s1"]}, "medium": {}, "weak": {}},
                {},
                False,
            )
        finally:
            m.subprocess.run = real_run
            m._render_backfill_body = real_body
        cmd = captured.get("cmd", [])
        frm = cmd[cmd.index("--from") + 1] if "--from" in cmd else None
        check(
            frm == "memory-daily",
            "gap#2 _queue_backfill should stamp --from memory-daily, got %r" % (frm,),
        )
    else:
        sys.stderr.write("note: skipped writer-argv check (no task_cli stub)\n")

    # ---- #728 invariant: a non-system sender is never a self-signal ----------
    check(
        m._is_system_sender("erp-cli-ajh-it") is False,
        "#728 bare agent id must NOT be a system sender",
    )
    check(
        m._is_self_signal_event(
            {"title": "weekly recap — checked ok", "from": "erp-cli-ajh-it"}
        )
        is False,
        "#728 human task with placeholder-ish title must NOT be suppressed",
    )
    # The pre-fix leak itself: an agent-stamped backfill title must NOT be a
    # self-signal — proving the fix lives in the WRITER's sender stamp, not a
    # title-only reader bypass that would reopen #728.
    check(
        m._is_self_signal_event(
            {
                "title": "[memory-daily] backfill erp-cli-ajh-it / 2026-06-28",
                "from": "erp-cli-ajh-it",
            }
        )
        is False,
        "agent-stamped backfill must NOT be self-signal (fix belongs at the writer)",
    )

    if fails:
        sys.stderr.write("FAIL:\n  " + "\n  ".join(fails) + "\n")
        return 1
    print("issue #2229 self-signal regression checks: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
