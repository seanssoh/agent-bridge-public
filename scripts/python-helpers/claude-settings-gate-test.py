#!/usr/bin/env python3
"""Settings-gate test helper for the keychain-free apiKeyHelper rollback (#1444).

File-as-argv (footgun #11): every subcommand takes explicit positional /
flag args so the calling smoke never has to pipe a heredoc into Python.
Pure JSON manipulation + assertions on a Claude ``settings.json``; never
reads, prints, or persists a credential token.

Subcommands:
  set-runtime-flag  --config <runtime-config.json> --key <k> --value true|false
      Write/overwrite a single top-level boolean (and any extra
      ``--also-set k=v`` ints) in the controller runtime config JSON so a
      later ``auth claude-token sync`` reads the desired gate state.

  set-apikeyhelper  --settings <settings.json> --value <path>
      Seed an operator-owned ``apiKeyHelper`` value into an existing
      settings.json (used to prove an operator value survives disable).

  remove-apikeyhelper  --settings <settings.json>
      Drop the ``apiKeyHelper`` key (mirrors the post-disable state where
      the gate has removed the managed helper).

  assert-apikeyhelper  --settings <settings.json> (--equals <p> | --absent | --present)
      Assert the rendered ``apiKeyHelper`` state. Exit 0 on match, 1 on
      mismatch (with a stderr reason), 2 on usage error.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _dump(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def cmd_set_runtime_flag(args: argparse.Namespace) -> int:
    path = Path(args.config)
    payload = _load(path)
    payload[args.key] = args.value == "true"
    for pair in args.also_set or []:
        if "=" not in pair:
            print(f"--also-set needs key=value, got: {pair}", file=sys.stderr)
            return 2
        key, raw = pair.split("=", 1)
        try:
            payload[key] = int(raw)
        except ValueError:
            payload[key] = raw
    _dump(path, payload)
    return 0


def cmd_set_apikeyhelper(args: argparse.Namespace) -> int:
    path = Path(args.settings)
    payload = _load(path)
    payload["apiKeyHelper"] = args.value
    _dump(path, payload)
    return 0


def cmd_remove_apikeyhelper(args: argparse.Namespace) -> int:
    path = Path(args.settings)
    payload = _load(path)
    payload.pop("apiKeyHelper", None)
    _dump(path, payload)
    return 0


def cmd_assert_apikeyhelper(args: argparse.Namespace) -> int:
    path = Path(args.settings)
    payload = _load(path)
    actual = payload.get("apiKeyHelper")
    if args.absent:
        if "apiKeyHelper" in payload:
            print(f"apiKeyHelper still present: {actual!r}", file=sys.stderr)
            return 1
        return 0
    if args.present:
        if not isinstance(actual, str) or not actual:
            print("apiKeyHelper missing or empty", file=sys.stderr)
            return 1
        return 0
    # --equals path: compare resolved absolute paths.
    if not isinstance(actual, str) or not actual:
        print("apiKeyHelper missing or empty", file=sys.stderr)
        return 1
    if Path(actual).expanduser().resolve(strict=False) != Path(
        args.equals
    ).expanduser().resolve(strict=False):
        print(f"apiKeyHelper mismatch: {actual!r} != {args.equals!r}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_flag = sub.add_parser("set-runtime-flag")
    p_flag.add_argument("--config", required=True)
    p_flag.add_argument("--key", required=True)
    p_flag.add_argument("--value", required=True, choices=("true", "false"))
    p_flag.add_argument("--also-set", action="append", default=[])
    p_flag.set_defaults(handler=cmd_set_runtime_flag)

    p_set = sub.add_parser("set-apikeyhelper")
    p_set.add_argument("--settings", required=True)
    p_set.add_argument("--value", required=True)
    p_set.set_defaults(handler=cmd_set_apikeyhelper)

    p_rm = sub.add_parser("remove-apikeyhelper")
    p_rm.add_argument("--settings", required=True)
    p_rm.set_defaults(handler=cmd_remove_apikeyhelper)

    p_assert = sub.add_parser("assert-apikeyhelper")
    p_assert.add_argument("--settings", required=True)
    group = p_assert.add_mutually_exclusive_group(required=True)
    group.add_argument("--equals")
    group.add_argument("--absent", action="store_true")
    group.add_argument("--present", action="store_true")
    p_assert.set_defaults(handler=cmd_assert_apikeyhelper)

    args = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
