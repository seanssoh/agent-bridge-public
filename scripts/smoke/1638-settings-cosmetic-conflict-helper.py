#!/usr/bin/env python3
"""Helper for scripts/smoke/1638-settings-cosmetic-conflict.sh (Issue #1638).

Footgun #11: this file is invoked file-as-argv so the smoke shell never pipes
a heredoc/here-string into a subprocess. Two subcommands:

  emit-settings <variant> <out-path>
      Write a settings.json fixture. Variants:
        base                  baseline 3-way `base` content
        upstream-order        upstream: Stop groups reordered vs base
        live-order-swapped    live: Stop groups in the cm-prod order (T1)
        upstream-pypath       upstream: bare `python3` interpreter (T2 base side)
        live-abs-pypath       live: `/usr/bin/python3` interpreter (T2)
        live-hook-added       live: an EXTRA hook group (T3, genuine conflict)
        plain-base/-upstream/-live
                              non-settings text file fixtures (T4)

  field <json-string> <dotted.key>
      Print a nested field from an apply-live JSON payload (counts.X etc.).
"""
from __future__ import annotations

import json
import sys


def _base_doc() -> dict:
    return {
        "autoMemoryEnabled": True,
        "hooks": {
            "Stop": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": "bash ~/.agent-bridge/hooks/mark-idle.sh",
                            "timeout": 3,
                        }
                    ]
                },
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": "/usr/bin/python3 ~/.agent-bridge/hooks/inbox-auto-drain.py",
                            "timeout": 10,
                        }
                    ]
                },
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": "/usr/bin/python3 ~/.agent-bridge/hooks/session-stop.py",
                            "timeout": 35,
                        }
                    ]
                },
            ],
            "UserPromptSubmit": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": "python3 ~/.agent-bridge/hooks/prompt_timestamp.py",
                            "timeout": 3,
                        }
                    ]
                }
            ],
        },
    }


def _write(path: str, doc: dict) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")


def emit_settings(variant: str, out_path: str) -> None:
    doc = _base_doc()
    if variant == "base":
        pass
    elif variant == "upstream-order":
        # Distinct from base AND from live-order-swapped at the byte level, but
        # the hook SET is identical to live-order-swapped. base differs from
        # both (it adds a marker only base carries) so the classifier reaches
        # merge_required. Here upstream keeps base's Stop order but flips a
        # neutral top-level value so it differs from base.
        doc["autoDreamEnabled"] = True
    elif variant == "live-order-swapped":
        # Operator's live file: same hook SET, Stop groups reordered
        # (session-stop before inbox-auto-drain) — cosmetic only vs upstream.
        stop = doc["hooks"]["Stop"]
        doc["hooks"]["Stop"] = [stop[0], stop[2], stop[1]]
        doc["autoDreamEnabled"] = True
    elif variant == "upstream-pypath":
        # Upstream side for T2: leave interpreters as base has them.
        doc["autoDreamEnabled"] = True
    elif variant == "live-abs-pypath":
        # Live side for T2: only the python interpreter prefix differs
        # (python3 -> /usr/bin/python3 on the UserPromptSubmit hook).
        doc["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"] = (
            "/usr/bin/python3 ~/.agent-bridge/hooks/prompt_timestamp.py"
        )
        doc["autoDreamEnabled"] = True
    elif variant == "live-bare-python":
        # Live side for T5: the UserPromptSubmit hook still uses bare `python`
        # (potentially Python 2 / missing) where upstream uses `python3`. This
        # is a REAL interpreter migration, NOT cosmetic — the pre-check must
        # leave it as a conflict (codex #1638 review). Pair with upstream `base`.
        doc["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"] = (
            "python ~/.agent-bridge/hooks/prompt_timestamp.py"
        )
        doc["autoDreamEnabled"] = True
    elif variant == "live-venv-python":
        # Live side for T6: a RELATIVE/virtualenv interpreter
        # (`.venv/bin/python3`) where upstream uses bare `python3`. This is a
        # real interpreter-PATH change, NOT cosmetic (codex #1638 round 2): the
        # path arm of the regex requires a leading `/`, so a venv-relative token
        # is left intact and the change must surface. Pair with upstream `base`.
        doc["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"] = (
            ".venv/bin/python3 ~/.agent-bridge/hooks/prompt_timestamp.py"
        )
        doc["autoDreamEnabled"] = True
    elif variant == "upstream-hook-different":
        # Upstream side for T3: appends ITS OWN new hook at the same trailing
        # position live appends a different one, so the line-merge overlaps and
        # `git merge-file` reports a real conflict. The cosmetic pre-check must
        # NOT swallow this (the hook SET genuinely diverges).
        doc["hooks"]["Stop"].append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": "python3 ~/.agent-bridge/hooks/UPSTREAM-only.py",
                        "timeout": 7,
                    }
                ]
            }
        )
        doc["autoDreamEnabled"] = True
    elif variant == "live-hook-added":
        # Genuine conflict: live adds a brand-new hook the SET does not contain,
        # at the same trailing position upstream-hook-different appends a
        # different one (overlapping append → real text conflict).
        doc["hooks"]["Stop"].append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": "python3 ~/.agent-bridge/hooks/NEW-hook.py",
                        "timeout": 5,
                    }
                ]
            }
        )
        doc["autoDreamEnabled"] = True
    else:
        raise SystemExit(f"unknown settings variant: {variant}")
    _write(out_path, doc)


def field(payload: str, dotted: str) -> None:
    obj = json.loads(payload)
    for part in dotted.split("."):
        obj = obj[part]
    print(obj)


def main(argv: list[str]) -> int:
    if not argv:
        raise SystemExit("usage: helper <emit-settings|field> ...")
    cmd = argv[0]
    if cmd == "emit-settings":
        emit_settings(argv[1], argv[2])
    elif cmd == "field":
        field(argv[1], argv[2])
    else:
        raise SystemExit(f"unknown subcommand: {cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
