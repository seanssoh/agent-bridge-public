#!/usr/bin/env python3
# scripts/smoke/tool-policy-process-dump-regex.py — regression for the
# hooks/tool-policy.py process-environment-dump regex tightening
# (2026-05-16, operator-flagged false positive).
#
# Earlier `_ENV_DUMP_PATTERNS` had:
#   re.compile(r"(?<![A-Za-z0-9_/])env(?![A-Za-z0-9_])"),
#   re.compile(r"(?<![A-Za-z0-9_/])printenv(?![A-Za-z0-9_])"),
# Both regexes false-positived on natural-language English/Korean text
# whenever the word `env` or `printenv` appeared as a standalone word.
# Real-world trigger:
#   ~/.agent-bridge/agent-bridge task create --title
#     "[noise] BRIDGE_LAYOUT=legacy stale env override 출처 영구 제거"
# The title contained `env` as a noun and the hook denied the task
# creation as if the operator were dumping the process environment.
#
# This test pins:
#   - True positives: every dangerous shape still matches.
#   - False positives: every natural-language and identifier-style
#     occurrence no longer matches.

import importlib.util
import pathlib
import sys


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    policy_path = repo_root / "hooks" / "tool-policy.py"
    spec = importlib.util.spec_from_file_location(
        "tool_policy_under_test", policy_path
    )
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {policy_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    dumps = module._raw_dumps_process_environment

    # (raw text, expected — True if it should be flagged as env dump)
    cases: list[tuple[str, bool]] = [
        # ---- True positives (must still be caught) ----
        ("env", True),                                         # bare
        ("env\n", True),                                       # bare with newline
        ("env | grep CLAUDE", True),                           # piped
        ("env > /tmp/dump", True),                             # redirected
        (";env", True),                                        # after semi
        ("&& env", True),                                      # after &&
        ("$(env)", True),                                      # comsub
        ("`env`", True),                                       # backtick
        ("printenv", True),                                    # bare printenv
        ("printenv CLAUDE_CODE_OAUTH_TOKEN", True),            # specific var
        ("printenv | head", True),                             # piped
        ("&& printenv", True),                                 # after &&
        ("$(printenv)", True),                                 # comsub
        ("set\n", True),                                       # bare set still caught
        ("set | head", True),                                  # set piped
        ("declare -p", True),                                  # declare -p
        ("typeset -px", True),                                 # typeset
        ("export -p", True),                                   # export -p
        ("compgen -e", True),                                  # compgen
        ("/proc/self/environ", True),                          # procfs path
        ("cat /proc/12345/environ", True),                     # procfs cat

        # ---- False positives (must NOT match after tightening) ----
        ("stale env override", False),                         # the operator trigger
        ("[noise] BRIDGE_LAYOUT=legacy stale env override 출처 영구 제거", False),
        ("env-regex false positive", False),                   # `env-` identifier
        ("show-env cleanup", False),                           # tmux show-env name
        ("tmux show-env -g", False),                           # tmux command with `env`
        (".env file location", False),                         # dotenv reference
        ("env-token delivery path", False),                    # phrase
        ("environment variable", False),                       # `env` as prefix of word — already excluded
        # Note: a raw string that *starts* with `printenv` (e.g. a title
        # "printenv documentation update") is intentionally still
        # flagged. We cannot distinguish "literal command at offset 0"
        # from "natural word that happens to be the first token" without
        # parsing the shell, and the latter is rare enough that we
        # prefer to keep the conservative catch. The realistic
        # false-positive surface — `printenv` appearing mid-sentence —
        # is fixed:
        ("use printenv to check the value", False),
        ("kubectl set image deployment/app", False),           # set in middle
        ("set -e", False),                                     # set -e
        ("set -o pipefail", False),                            # set -o
        ("setfacl -m u:foo:rwx /tmp", False),                  # setfacl
        ("git remote set-url origin git@x", False),            # set-url
        ("env -i bash -c 'echo hi'", False),                   # env -i CLEARS env (not dump)
        ("env VAR=value cmd", False),                          # env VAR= (not dump)
        ("env -u CLAUDE_VAR cmd", False),                      # env -u (unset, not dump)
    ]

    failures: list[str] = []
    for raw, want in cases:
        got = bool(dumps(raw))
        if got != want:
            tag = "false-positive" if got else "missed-detection"
            failures.append(f"  FAIL  [{tag}] dumps({raw!r}) = {got}, want {want}")
        else:
            print(f"  PASS  dumps({raw!r}) = {got}")

    if failures:
        print(f"\n{len(failures)} failure(s):", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print(
        f"\n[smoke:tool-policy-process-dump-regex] all {len(cases)} cases passed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
