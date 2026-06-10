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
        live-homebrew-abspath live: Homebrew python + ~-expanded abs hook paths
                              (#1675 + #1694 — render output, cosmetic only)
        live-abspath-usrbin   live: /usr/bin/python3 + ~-expanded abs hook paths
                              (#1694-only — path-arg axis, cosmetic only)
        live-genuine-edit-abspath
                              live: a REPLACED hook basename + Homebrew/abs
                              cosmetic axes (#1675/#1694 SAFETY — still conflict)
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
    elif variant == "live-homebrew-abspath":
        # Live side for #1675 + #1694 (the macOS/Homebrew render output): EVERY
        # python hook is rewritten to Homebrew's interpreter
        # (`/opt/homebrew/bin/python3`, #1675) AND the `~/.agent-bridge/hooks/`
        # prefix is `~`-expanded to an absolute home path (#1694). `bash` hooks
        # keep their interpreter but also get the absolute path arg. This is
        # exactly what `shared_settings_rerender` produces on a Homebrew macOS
        # host — a render-owned no-op — so the cosmetic pre-check must fire and
        # keep_live with NO conflict. Pair with upstream `base`.
        home = "/Users/example/.agent-bridge/hooks/"
        for event in ("Stop", "UserPromptSubmit"):
            for group in doc["hooks"][event]:
                for hook in group["hooks"]:
                    cmd = hook["command"]
                    interp, _, arg = cmd.partition(" ")
                    arg = arg.replace("~/.agent-bridge/hooks/", home)
                    if interp in ("/usr/bin/python3", "python3"):
                        interp = "/opt/homebrew/bin/python3"
                    hook["command"] = interp + " " + arg
        doc["autoDreamEnabled"] = True
    elif variant == "live-abspath-usrbin":
        # Live side for #1694-only: `/usr/bin/python3` is ALREADY allowlisted by
        # #1638, so the interpreter token matches upstream — the ONLY difference
        # is the `~`-expanded absolute hook path argument. Proves the path-arg
        # canonicalization closes the conflict independently of the interpreter
        # axis. Pair with upstream `base`.
        home = "/Users/example/.agent-bridge/hooks/"
        for event in ("Stop", "UserPromptSubmit"):
            for group in doc["hooks"][event]:
                for hook in group["hooks"]:
                    hook["command"] = hook["command"].replace(
                        "~/.agent-bridge/hooks/", home
                    )
        doc["autoDreamEnabled"] = True
    elif variant == "live-genuine-edit-abspath":
        # Live side for the #1675/#1694 SAFETY case: the operator genuinely
        # REPLACED a hook script (session-stop.py -> operator-custom.py) AND the
        # render expanded `~` to absolute + Homebrew python. The path-style /
        # interpreter axes are cosmetic, but the changed BASENAME is a real edit
        # the operator must still see. The pre-check must DECLINE (different hook
        # SET after canonicalization) so a real conflict still surfaces. Pair
        # with upstream `upstream-session-stop-edited`, which edits the SAME
        # session-stop line so the two edits overlap into a genuine conflict.
        home = "/Users/example/.agent-bridge/hooks/"
        for group in doc["hooks"]["Stop"]:
            for hook in group["hooks"]:
                cmd = hook["command"].replace(
                    "session-stop.py", "operator-custom.py"
                )
                interp, _, arg = cmd.partition(" ")
                arg = arg.replace("~/.agent-bridge/hooks/", home)
                if interp == "/usr/bin/python3":
                    interp = "/opt/homebrew/bin/python3"
                hook["command"] = interp + " " + arg
        doc["autoDreamEnabled"] = True
    elif variant == "upstream-session-stop-edited":
        # Upstream side for the #1675/#1694 SAFETY case (H3): upstream edits the
        # SAME session-stop hook COMMAND line that live replaces the basename of,
        # so the two edits overlap and `git merge-file` reports a real conflict.
        # Pairs with `live-genuine-edit-abspath` to prove the cosmetic pre-check
        # declining lets a genuine operator edit surface as a true conflict (not
        # just a coincidental clean merge). Stays on the template `~` form so the
        # ONLY non-cosmetic axis vs live is the replaced basename.
        for group in doc["hooks"]["Stop"]:
            for hook in group["hooks"]:
                if "session-stop.py" in hook["command"]:
                    hook["command"] = (
                        "/usr/bin/python3 ~/.agent-bridge/hooks/session-stop.py --upstream-flag"
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
