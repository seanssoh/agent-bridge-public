#!/usr/bin/env python3
"""Build the canonical static-Claude launch command for an agent.

Extracted from
`lib/bridge-state.sh::bridge_build_static_claude_launch_cmd` as part of
issue #835 (Wave A). This is the function that wedged in `heredoc_write`
for the static admin agent `patch` on macOS Bash 5.3.9 during the
2026-05-14 incident: `bridge_agent_launch_cmd patch` never returned, so
the tmux pane existed (`bridge-run.sh patch --continue`) but no
`claude` child was ever spawned. Living in a real script bypasses the
bash read entirely. (Forbidden pattern strings intentionally omitted
from this comment so the footgun #11 self-audit grep recipe does not
flag a textual mention as a real callsite.)

Args (positional, order-sensitive):
    sys.argv[1] — agent name (becomes `--name <agent>`)
    sys.argv[2] — continue_mode ("1" or "0")
    sys.argv[3] — session_id (may be empty)
    sys.argv[4] — continue_fallback ("1" or "0"; falls back to bare
                  `--continue` when continue_mode=1 and no session_id
                  but the workdir has a resumable transcript)
    sys.argv[5] — original (the roster-provided LAUNCH_CMD fallback)
    sys.argv[6] — model (BRIDGE_AGENT_MODEL[<a>]; may be empty). When
                  non-empty, the roster-materialized value WINS: any
                  `--model <x>` already baked into the LAUNCH_CMD extras
                  is stripped and `--model <model>` re-emitted. When
                  empty, a baked `--model` is preserved byte-for-byte.
                  Optional for back-compat — defaults to empty.
    sys.argv[7] — effort (BRIDGE_AGENT_EFFORT[<a>]; may be empty). Same
                  roster-wins / preserve-when-empty contract as model.
                  Optional for back-compat — defaults to empty.

Baked `--model`/`--effort` strip contract (when the roster overrides):
    - Joined form `--model=x`: the value rides the same token; drop 1.
    - Space form `--model x`: consume the following token as the value
      slot ONLY when it is a plain value (does not start with `-`).
    - Malformed/valueless space form — the follower is option-shaped
      (`--model --settings ...`) or there is no follower (`--model` last):
      treat the baked flag as valueless, drop only the flag, and PRESERVE
      the following token. This guarantees an unrelated flag is never
      eaten as the model value and no stray positional is stranded.

Stdout: rewritten launch_cmd with `--dangerously-skip-permissions`,
`--name <agent>`, the appropriate resume mode pinned, and (when the
roster provides them) `--model` / `--effort`. Existing `-c`,
`--continue`, `--dangerously-skip-permissions`, `--resume`, and
`--name` tokens are stripped to avoid double-emit; `--model` /
`--effort` are stripped only when the roster overrides them (issue
#1763 — `agent update --model/--effort` was a silent no-op for static
Claude agents because this builder never read those roster vars).
Always exits 0.

Behavior (preserved byte-for-byte from the pre-extraction body):
    Includes the `false` → `claude` repair (handles a stale-roster
    artifact where the engine token was rewritten to `false` by a prior
    bug; if the leading env-prefix tokens are well-formed assignments
    and the first non-env token is the literal `false`, swap it to
    `claude` before further processing).
"""

import re
import shlex
import sys


def repair_false_command(value: str) -> str:
    try:
        tokens = shlex.split(value)
    except ValueError:
        return value
    if not tokens:
        return value
    idx = 0
    while idx < len(tokens):
        key = tokens[idx].split("=", 1)[0]
        if "=" not in tokens[idx] or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key) or tokens[idx].startswith("-"):
            break
        idx += 1
    if idx < len(tokens) and tokens[idx] == "false":
        tokens[idx] = "claude"
        return " ".join(shlex.quote(token) for token in tokens)
    return value


def main() -> int:
    agent, continue_mode, session_id, continue_fallback, original = sys.argv[1:6]
    # #1763: model/effort are optional positional tails for back-compat with
    # any caller still passing the pre-#1763 5-arg shape (defaults to empty,
    # which preserves the historical "do not touch model/effort" behavior).
    model = sys.argv[6] if len(sys.argv) > 6 else ""
    effort = sys.argv[7] if len(sys.argv) > 7 else ""

    original = repair_false_command(original)
    match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
    if not match:
        print(original)
        return 0

    env_prefix = match.group("prefix")
    args = shlex.split(match.group("command"))
    if not args or args[0] != "claude":
        print(original)
        return 0

    # #1763: when the roster supplies a value, the materialized value WINS over
    # a stale baked flag — strip the baked `--model`/`--effort` from the extras
    # so the roster value is the single emission. Both the space-separated
    # (`--model x`) and joined (`--model=x`) baked forms are stripped, so a
    # re-render stays single-emission regardless of how the workaround flag was
    # authored. When the roster var is empty, the baked flag is left untouched
    # in extras (preserves the documented `--set-launch-cmd` workaround
    # byte-for-byte).
    override_flags = set()
    if model:
        override_flags.add("--model")
    if effort:
        override_flags.add("--effort")

    def _is_override_token(tok: str) -> bool:
        # Match `--model` / `--effort` exactly or their `--model=<x>` joined form.
        return tok in override_flags or tok.split("=", 1)[0] in override_flags

    rest = args[1:]
    extras: list[str] = []
    j = 0
    while j < len(rest):
        token = rest[j]
        if token in {"-c", "--continue", "--dangerously-skip-permissions"}:
            j += 1
            continue
        if token in {"--resume", "--name"}:
            j += 2 if j + 1 < len(rest) else 1
            continue
        if _is_override_token(token):
            # Drop the baked flag. The joined `--model=x` form carries its value
            # in the same token (drop 1). For the space-separated `--model x`
            # form, consume the FOLLOWING token as the value slot ONLY when it is
            # a plain value (does not itself start with `-`). When the follower
            # is option-shaped (e.g. a baked `--model --settings /tmp/x.json`) or
            # absent, the baked flag is treated as malformed/valueless: drop only
            # the flag and preserve the following token, so an unrelated flag is
            # never eaten and no stray positional is stranded. The roster value
            # is re-emitted below either way.
            if "=" in token:
                j += 1
            elif j + 1 < len(rest) and not rest[j + 1].startswith("-"):
                j += 2
            else:
                j += 1
            continue
        extras.append(token)
        if token.startswith("--") and j + 1 < len(rest) and not rest[j + 1].startswith("-"):
            extras.append(rest[j + 1])
            j += 2
            continue
        j += 1

    base = ["claude"]
    if continue_mode == "1" and session_id:
        base.extend(["--resume", session_id])
    elif continue_mode == "1" and continue_fallback == "1":
        base.append("--continue")
    base.extend(["--dangerously-skip-permissions", "--name", agent])
    # #1763: mirror the dynamic builder's `--model`/`--effort` emission so a
    # static agent's roster-materialized model/effort actually reach the
    # launched `claude` process. Only emit when the roster supplies a value.
    if model:
        base.extend(["--model", model])
    if effort:
        base.extend(["--effort", effort])
    base.extend(extras)

    quoted = " ".join(shlex.quote(token) for token in base)
    if env_prefix:
        print(f"{env_prefix}{quoted}")
    else:
        print(quoted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
