#!/usr/bin/env python3
"""Assertion helper for scripts/smoke/antigravity-settings-preseed.sh.

Extracted to a standalone file (invoked file-as-argv) rather than an inline
`python3 - <<'PY'` heredoc-stdin so the smoke test does not reintroduce the
Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock class (footgun #11) —
the smoke captures this helper's output in `$(...)`, which is exactly the
parent-comsub + child-heredoc-stdin shape that deadlocks.

Usage:
  antigravity-settings-preseed-assert.py preserve <settings.json> <workdir>
  antigravity-settings-preseed-assert.py counts   <settings.json> <workdir>

`preserve` prints space-joined `key=value` checks proving the preseed kept
every pre-existing key and added the expected entries. `counts` prints the
occurrence counts that prove the preseed is idempotent on re-run.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write(
            "usage: antigravity-settings-preseed-assert.py "
            "<preserve|counts> <settings.json> <workdir>\n"
        )
        return 2
    mode, settings, workdir = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(settings, encoding="utf-8") as fh:
        data = json.load(fh)
    allow = data.get("permissions", {}).get("allow", [])

    if mode == "preserve":
        checks = [
            "colorScheme=%s" % data.get("colorScheme"),
            "enableTelemetry=%s" % data.get("enableTelemetry"),
            "preExistingTrust=%s"
            % ("/pre/existing/dir" in data.get("trustedWorkspaces", [])),
            "workdirTrust=%s" % (workdir in data.get("trustedWorkspaces", [])),
            "preExistingAllow=%s" % ("command(/usr/bin/git)" in allow),
            "denyPreserved=%s"
            % ("command(/bin/rm)" in data.get("permissions", {}).get("deny", [])),
            "agbAllow=%s" % any(e.endswith("/agb)") for e in allow),
            "agentBridgeAllow=%s"
            % any(e.endswith("/agent-bridge)") for e in allow),
            "altScreenMode=%s" % data.get("altScreenMode"),
        ]
        print(" ".join(checks))
        return 0

    if mode == "counts":
        trusted = data.get("trustedWorkspaces", [])
        print(
            "trustWorkdir=%d allowAgb=%d allowBridge=%d"
            % (
                trusted.count(workdir),
                sum(1 for e in allow if e.endswith("/agb)")),
                sum(1 for e in allow if e.endswith("/agent-bridge)")),
            )
        )
        return 0

    sys.stderr.write("unknown mode: %s\n" % mode)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
