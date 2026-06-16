#!/usr/bin/env python3
"""Extract a single shell function definition from a Bash source file.

Used by scripts/smoke/1738-config-caller-binding.sh to pull JUST the
`bridge_daemon_prune_orphan_config_caller_bindings` function out of
bridge-daemon.sh so the smoke can `eval` it standalone (and drive it with a
controlled `tmux` shell function) without booting the whole daemon.

Usage: extract-shell-fn.py <bash-file> <function-name-with-parens>

File-as-argv only (footgun #11 / lint-heredoc-ban): the path + name come in on
argv, never stdin. Emits the function definition verbatim to stdout (real
newlines), or nothing if the function is not found.
"""

from __future__ import annotations

import sys


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    path = sys.argv[1]
    name = sys.argv[2]
    with open(path, encoding="utf-8") as fh:
        src = fh.read().splitlines()
    out: list[str] = []
    depth = 0
    capture = False
    for line in src:
        if not capture and line.startswith(name):
            capture = True
        if capture:
            out.append(line)
            depth += line.count("{") - line.count("}")
            if depth <= 0 and line.strip() == "}":
                break
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
