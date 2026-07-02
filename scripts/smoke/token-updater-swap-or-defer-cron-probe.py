#!/usr/bin/env python3
"""#21895 sub-PR 3 smoke helper: drive bridge-cron-runner.py:maybe_reactive_rotate.

Imports the runner module by path (argv[1]) and calls maybe_reactive_rotate with
a synthetic quota-limited captured run so the rotate-routing decision fires. The
runner resolves its token CLI via BRIDGE_CLAUDE_TOKEN_CMD (the recorder stub the
smoke installs) and its lease-enabled probe via the same seam, so this harness
records WHICH verb the runner dispatched (lease-swap-or-defer when ENABLED,
rotate when DISABLED) without any live OAuth or bridge runtime.

Never touches real state: writes only under a tempdir it creates.
"""
from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path


def _load_runner(runner_path: str):
    spec = importlib.util.spec_from_file_location("bridge_cron_runner_probe", runner_path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load runner module from {runner_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: cron-probe.py <bridge-cron-runner.py>")
    runner = _load_runner(sys.argv[1])

    with tempfile.TemporaryDirectory(prefix="agb-cron-probe-") as tmp:
        run_dir = Path(tmp)
        stdout_log = run_dir / "stdout.log"
        stderr_log = run_dir / "stderr.log"
        # A captured run that classify_run_output will read as quota_limited: a
        # transport-qualified 429 with a reset window. quota_prefilter_hit runs
        # first over the text, then classify_run_output re-reads the log files.
        quota_text = (
            "API Error: 429 {\"type\":\"error\",\"error\":"
            "{\"type\":\"rate_limit_error\",\"message\":\"usage limit reached\"}}"
        )
        stdout_log.write_text(quota_text, encoding="utf-8")
        stderr_log.write_text(quota_text, encoding="utf-8")

        summary = runner.maybe_reactive_rotate(
            request={"job_id": "probe-job"},
            run_id="probe-run",
            run_dir=run_dir,
            stdout_log=stdout_log,
            stderr_log=stderr_log,
            stdout_text=quota_text,
            stderr_text=quota_text,
            returncode=1,
            stdout_truncated=False,
            stderr_truncated=False,
            target_agent="probe-agent",
        )
        # The verb ledger is what the smoke asserts on; print the summary for
        # debugging visibility only.
        print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
