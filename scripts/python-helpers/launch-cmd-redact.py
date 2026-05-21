#!/usr/bin/env python3
"""launch-cmd-redact.py — single shared redaction surface for the
`agent-bridge agent update --launch-cmd-*` output path (issue #1023).

`agent update` echoes the full `before_launch_cmd` / `after_launch_cmd`
values, the operation summary, the recorded `add-env` actions, the audit
detail, the `--json` envelope, and the plain-text result. A launch
command's leading env-prefix routinely carries credential-bearing values
(OAuth / MS365 client secrets, bearer tokens, session cookies). Echoing
the raw value leaks the secret into terminal output, logs, transcripts,
and task reports.

This module is the ONE place the sensitive-key pattern set lives. Every
surface that renders a launch command or a launch-cmd op routes through
it so no surface is missed. It redacts the **value only** and keeps the
env **key name** visible — `MS365_CLIENT_SECRET=supersecret` becomes
`MS365_CLIENT_SECRET=***REDACTED***`. It is an output-rendering
transform only: the stored/applied launch command is never mutated.

Importable API:
    redact_launch_cmd(value)         -> str
    redact_action(action)            -> str
    redact_actions(actions)          -> list[str]
    redact_operation_summary(summary)-> str
    is_sensitive_key(key)            -> bool

CLI (file-as-argv, no heredoc-stdin — footgun #11 / KNOWN_ISSUES.md §26):
    launch-cmd-redact.py launch-cmd  <value>
    launch-cmd-redact.py action      <action>
    launch-cmd-redact.py op-summary  <summary>
Each prints the redacted form on stdout.
"""

import re
import sys

REDACTED = "***REDACTED***"

# Codex r1 pattern set: a key is sensitive if it contains any of these
# substrings, case-insensitively. Covers the issue's explicit list
# (SECRET / TOKEN / PASSWORD / KEY / CLIENT_SECRET / ACCESS_TOKEN /
# REFRESH_TOKEN — the latter three are caught by SECRET / TOKEN) plus
# the common launch-env secret names AUTHORIZATION / BEARER / COOKIE /
# SESSION / JWT, so `AUTHORIZATION=Bearer ...` and `SESSION_COOKIE=...`
# also redact.
_SENSITIVE_SUBSTRINGS = (
    "SECRET",
    "TOKEN",
    "PASSWORD",
    "KEY",
    "CREDENTIAL",
    "AUTH",
    "AUTHORIZATION",
    "BEARER",
    "COOKIE",
    "SESSION",
    "JWT",
)

# A leading env-prefix token: KEY=VALUE where KEY is a shell-style
# identifier. Mirrors agent-update-apply-launch-cmd.py's env_re so the
# env/argv boundary is identified identically.
_ENV_TOKEN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)


def is_sensitive_key(key: str) -> bool:
    """True if the env key name matches any sensitive substring."""
    upper = key.upper()
    return any(sub in upper for sub in _SENSITIVE_SUBSTRINGS)


def _redact_env_token(token: str) -> str:
    """Redact one ``KEY=VALUE`` token if KEY is sensitive; else verbatim.

    A token without ``=`` or with a non-identifier key is returned
    unchanged — only matched env assignments are touched.
    """
    m = _ENV_TOKEN_RE.match(token)
    if not m:
        return token
    key, value = m.group(1), m.group(2)
    if not is_sensitive_key(key):
        return token
    if value == "":
        # Nothing to leak; leave an empty assignment untouched.
        return token
    return f"{key}={REDACTED}"


def redact_launch_cmd(value: str) -> str:
    """Redact sensitive env values in a launch command string.

    Only the leading run of ``KEY=VALUE`` env-prefix tokens is
    considered — once a non-env token is seen, the rest is argv and is
    left verbatim (matches the env/argv split in
    agent-update-apply-launch-cmd.py). Whitespace runs are collapsed to
    single spaces, consistent with the applier's reassembly.
    """
    if not value:
        return value
    tokens = value.split()
    out: list[str] = []
    in_env_prefix = True
    env_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    for tok in tokens:
        if in_env_prefix and not tok.startswith("-") and env_re.match(tok):
            out.append(_redact_env_token(tok))
        else:
            in_env_prefix = False
            out.append(tok)
    return " ".join(out)


def redact_action(action: str) -> str:
    """Redact a recorded launch-cmd action string.

    The only action that embeds a value is ``add-env KEY=VALUE``
    (agent-update-apply-launch-cmd.py). ``remove-env KEY`` /
    ``set-launch-cmd`` / dev-channel actions carry no env value, except
    ``set-launch-cmd`` whose payload is not part of the action string.
    """
    prefix = "add-env "
    if action.startswith(prefix):
        return prefix + _redact_env_token(action[len(prefix):])
    return action


def redact_actions(actions: list) -> list:
    """Redact every action string in an actions array."""
    return [
        redact_action(a) if isinstance(a, str) else a
        for a in actions
    ]


def redact_operation_summary(summary: str) -> str:
    """Redact a comma-joined operation summary.

    The launch-cmd chunks have the shape ``launch:add-env=KEY=VALUE``
    (bridge-agent.sh builds them with ``sed 's/\\t/=/'`` over the TSV
    op list). Only the ``launch:add-env=`` chunk embeds a value; the
    rest of the summary (``chan:*``, ``desc=set``, ``engine=*``, …) is
    left verbatim.
    """
    if not summary:
        return summary
    chunks = summary.split(",")
    redacted: list[str] = []
    add_env_prefix = "launch:add-env="
    for chunk in chunks:
        if chunk.startswith(add_env_prefix):
            redacted.append(
                add_env_prefix
                + _redact_env_token(chunk[len(add_env_prefix):])
            )
        else:
            redacted.append(chunk)
    return ",".join(redacted)


def _main(argv: list) -> int:
    if len(argv) != 3:
        print(
            "usage: launch-cmd-redact.py "
            "<launch-cmd|action|op-summary> <value>",
            file=sys.stderr,
        )
        return 2
    mode, value = argv[1], argv[2]
    if mode == "launch-cmd":
        print(redact_launch_cmd(value))
    elif mode == "action":
        print(redact_action(value))
    elif mode == "op-summary":
        print(redact_operation_summary(value))
    else:
        print(f"launch-cmd-redact.py: unknown mode: {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
