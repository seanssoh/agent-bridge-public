#!/usr/bin/env python3
"""Helper for scripts/smoke/1437-reactive-cron-rotation.sh (#1437).

Loads bridge-cron-runner.py (hyphenated module name → importlib) and drives the
reactive Claude OAT rotation path against a fake 429 run output and a fake token
pool. No live OAuth, no daemon. Prints the returned reactive-rotation summary as
JSON so the bash smoke can assert the full chain.

Usage:
  1437-reactive-cron-rotation-helper.py \
    --run-dir <dir> --run-id <id> --job-id <id> \
    --stdout-file <path> --stderr-file <path> --returncode <n>

Relies on these env vars (set by the smoke) to keep everything hermetic:
  BRIDGE_CLAUDE_TOKEN_CMD            fake `claude-token` CLI (shlex-split)
  BRIDGE_CRON_REACTIVE_REDISPATCH_CMD  fake re-dispatch recorder (shlex-split)
  BRIDGE_CRON_STATE_DIR             isolated cron state root (attempt-cap state)
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


def load_runner():
    repo_root = Path(__file__).resolve().parents[2]
    runner_path = repo_root / "bridge-cron-runner.py"
    spec = importlib.util.spec_from_file_location("bridge_cron_runner_under_test", runner_path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load runner module from {runner_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--stdout-file", required=True)
    parser.add_argument("--stderr-file", required=True)
    parser.add_argument("--returncode", type=int, default=1)
    args = parser.parse_args()

    runner = load_runner()

    stdout_log = Path(args.stdout_file)
    stderr_log = Path(args.stderr_file)
    stdout_text = stdout_log.read_text(encoding="utf-8") if stdout_log.is_file() else ""
    stderr_text = stderr_log.read_text(encoding="utf-8") if stderr_log.is_file() else ""

    request = {"job_id": args.job_id, "job_name": "smoke-1437", "target_agent": "smoke-cron"}

    summary = runner.maybe_reactive_rotate(
        request=request,
        run_id=args.run_id,
        run_dir=Path(args.run_dir),
        stdout_log=stdout_log,
        stderr_log=stderr_log,
        stdout_text=stdout_text,
        stderr_text=stderr_text,
        returncode=args.returncode,
        stdout_truncated=False,
        stderr_truncated=False,
        target_agent="smoke-cron",
    )
    print(json.dumps(summary if summary is not None else {"detected": False}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
