#!/usr/bin/env python3
"""
scripts/python-helpers/admin-set-config.py — standalone helper for
`agent-bridge admin set ...` (issue #1247).

Reads / mutates the admin-set config file at
``$BRIDGE_STATE_DIR/admin-config.json``. Currently exposes one flag:

  auto_restart_on_membership_change : bool

Future PRs that wire the actual admin-set restart sequence will read
this flag and decide whether to queue `tmux cycle <admin>` +
`tmux cycle <admin>-dev` after a group-membership refresh.

File-as-argv: invoked with explicit positional args so the calling
shell never has to pipe a heredoc into Python (footgun #11 — Bash
5.3.9 deadlock; see KNOWN_ISSUES.md §26).

Usage:
  admin-set-config.py set-auto-restart \
      --admin <agent> \
      --config <path> \
      --value on|off

Output (stdout): single human-readable confirmation line. Exit 0 on
success, non-zero with stderr context on failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def _read_existing(config_path: Path) -> dict:
    if not config_path.is_file():
        return {}
    try:
        with config_path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        # Conservative: a corrupt file is replaced wholesale rather
        # than blocking the operator. The single field this helper
        # writes is the only one currently in the schema, so nothing
        # else is at risk of being lost.
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def _atomic_write(config_path: Path, payload: dict) -> None:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    body = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    tmp_path = config_path.with_name(f"{config_path.name}.tmp.{os.getpid()}")
    tmp_path.write_text(body, encoding="utf-8")
    try:
        os.chmod(tmp_path, 0o600)
    except OSError:
        # chmod is best-effort: a future iso v2 reconcile pass owns the
        # final perms canonicalization for `state/`-rooted files. The
        # write itself succeeded, so propagate success.
        pass
    os.replace(tmp_path, config_path)


def _cmd_set_auto_restart(args: argparse.Namespace) -> int:
    if args.value not in {"on", "off"}:
        sys.stderr.write(
            f"admin-set-config: --value must be on|off (got: {args.value!r})\n"
        )
        return 2
    config_path = Path(args.config).expanduser()
    data = _read_existing(config_path)
    data["admin_agent"] = args.admin
    data["auto_restart_on_membership_change"] = args.value == "on"
    try:
        _atomic_write(config_path, data)
    except OSError as exc:
        sys.stderr.write(f"admin-set-config: write failed: {exc}\n")
        return 1
    sys.stdout.write(
        f"[admin set] auto_restart_on_membership_change={args.value} "
        f"path={config_path} admin={args.admin}\n"
    )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="admin-set-config")
    sub = parser.add_subparsers(dest="cmd", required=True)

    set_ar = sub.add_parser("set-auto-restart")
    set_ar.add_argument("--admin", required=True)
    set_ar.add_argument("--config", required=True)
    set_ar.add_argument("--value", required=True)
    set_ar.set_defaults(handler=_cmd_set_auto_restart)

    args = parser.parse_args(argv[1:])
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
