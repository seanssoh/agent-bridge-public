#!/usr/bin/env python3
"""Apply typed launch_cmd mutations for `agent-bridge agent update`.

Extracted from `lib/bridge-agent-update.sh` as part of issue #815 (Wave A):
the previous source-time `$(cat <<'PY' ... PY)` capture caused Bash to block
in `heredoc_write` while sourcing the module on a stale runtime, which
hung the CLI hot path. Living in a real file removes the source-time
read entirely.

Reads BRIDGE_AGENT_UPDATE_LC_CURRENT from the environment for the
starting launch_cmd value, and TSV mutation ops on stdin:

    set-launch-cmd\t<value>
    add-env\tKEY=VALUE
    remove-env\tKEY
    add-dev-channel\t<spec>
    remove-dev-channel\t<spec>

Stdout: two lines.
    line 1: <new launch_cmd>
    line 2: <JSON array of action strings that changed the value>
"""

import json
import os
import re
import sys


def split_env_prefix(value: str) -> tuple[list[str], list[str]]:
    """Return (env_prefix_tokens, argv_tokens).

    env_prefix is the leading run of ``KEY=VALUE`` tokens (no leading
    dash, must contain ``=``, key matches ``[A-Za-z_][A-Za-z0-9_]*``).
    Everything from the first non-env token onwards is argv. We
    tokenize whitespace-naively: the launch_cmd is operator-authored
    in roster.local.sh and is shell-quoted on emission, so a single
    space split is sufficient for the env/argv boundary.
    """
    tokens = value.split()
    env_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    env: list[str] = []
    argv: list[str] = []
    boundary_seen = False
    for tok in tokens:
        if not boundary_seen and not tok.startswith("-") and env_re.match(tok):
            env.append(tok)
        else:
            boundary_seen = True
            argv.append(tok)
    return env, argv


def reassemble(env: list[str], argv: list[str]) -> str:
    pieces: list[str] = []
    pieces.extend(env)
    pieces.extend(argv)
    return " ".join(pieces).strip()


def env_key(token: str) -> str:
    return token.split("=", 1)[0]


def add_env(env: list[str], pair: str) -> bool:
    """Idempotent prepend of KEY=VALUE.

    No-op if the same KEY=VALUE token is already in the env prefix
    (in any position). If a different value for KEY is present, the
    contract is "prepend" — we add the new pair at the front; the
    operator removed-then-added if they wanted to change a value.
    """
    if pair in env:
        return False
    env.insert(0, pair)
    return True


def remove_env(env: list[str], key: str) -> bool:
    """Remove every ``KEY=...`` token from the env prefix."""
    keep: list[str] = []
    removed = False
    for tok in env:
        if env_key(tok) == key:
            removed = True
            continue
        keep.append(tok)
    env[:] = keep
    return removed


def add_dev_channel(argv: list[str], spec: str) -> bool:
    """Append ``--dangerously-load-development-channels <spec>`` to argv.

    Idempotent: skip if the option-paired form (whitespace OR ``=``)
    is already present anywhere in argv.
    """
    pair_ws = ["--dangerously-load-development-channels", spec]
    pair_eq = f"--dangerously-load-development-channels={spec}"
    # Whitespace form: option followed immediately by spec.
    for i in range(len(argv) - 1):
        if argv[i] == pair_ws[0] and argv[i + 1] == pair_ws[1]:
            return False
    # = form: option=spec as a single token.
    if pair_eq in argv:
        return False
    argv.append(pair_ws[0])
    argv.append(pair_ws[1])
    return True


def remove_dev_channel(argv: list[str], spec: str) -> bool:
    """Strip the option/spec pair (whitespace + ``=`` forms) and any
    dangling bare ``spec`` token left behind by an operator partial
    edit. Mirrors the cleanup logic in bridge-relay-cleanup.py
    (RELAY_DEV_CHANNEL_RE / RELAY_BARE_TOKEN_RE) but parameterised on
    the user-supplied spec rather than hard-coded telegram-relay.
    """
    pair_eq = f"--dangerously-load-development-channels={spec}"
    new: list[str] = []
    removed = False
    i = 0
    while i < len(argv):
        tok = argv[i]
        nxt = argv[i + 1] if i + 1 < len(argv) else None
        if tok == "--dangerously-load-development-channels" and nxt == spec:
            removed = True
            i += 2
            continue
        if tok == pair_eq:
            removed = True
            i += 1
            continue
        if tok == spec:
            # Dangling bare token (operator hand-edited only the
            # option half away). Cleaning this matches the
            # bridge-relay-cleanup contract for parity.
            removed = True
            i += 1
            continue
        new.append(tok)
        i += 1
    argv[:] = new
    return removed


def main() -> int:
    current = os.environ.get("BRIDGE_AGENT_UPDATE_LC_CURRENT", "")

    value = current
    env, argv = split_env_prefix(value)
    actions: list[str] = []

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        op, payload = parts[0], parts[1]
        if op == "set-launch-cmd":
            new_value = payload
            if new_value != value:
                value = new_value
                env, argv = split_env_prefix(value)
                actions.append("set-launch-cmd")
            continue
        if op == "add-env":
            if "=" not in payload:
                print(
                    f"--launch-cmd-add-env requires KEY=VALUE, got: {payload}",
                    file=sys.stderr,
                )
                return 2
            if add_env(env, payload):
                actions.append(f"add-env {payload}")
            value = reassemble(env, argv)
            continue
        if op == "remove-env":
            if remove_env(env, payload):
                actions.append(f"remove-env {payload}")
            value = reassemble(env, argv)
            continue
        if op == "add-dev-channel":
            if add_dev_channel(argv, payload):
                actions.append(f"add-dev-channel {payload}")
            value = reassemble(env, argv)
            continue
        if op == "remove-dev-channel":
            if remove_dev_channel(argv, payload):
                actions.append(f"remove-dev-channel {payload}")
            value = reassemble(env, argv)
            continue
        print(f"unknown launch-cmd op: {op}", file=sys.stderr)
        return 2

    print(value)
    print(json.dumps(actions, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
