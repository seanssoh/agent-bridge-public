#!/usr/bin/env python3
"""restart-attached-notice.py — issue #980 regression check.

Verifies that the upgrade agent-restart path surfaces an explicit
manual-restart notice when `--restart-agents` skips an agent whose tmux
session the operator has attached (reason="attached"). Without the notice
the upgrade completes silently and the operator never learns their own
attached agent is still running the OLD code.

Lives as a tracked file under scripts/smoke/ (alongside the other
standalone smoke test helpers) and is invoked file-as-argv by
scripts/smoke-test.sh — NOT fed through a heredoc — so it does not add a
heredoc-stdin subprocess site to the smoke harness (the heredoc-ban
ratchet, footgun #11).

Invocation:
    python3 restart-attached-notice.py <repo_root>

Exits 0 on success; raises AssertionError / SystemExit on failure so the
shell `die` path fires.

What it exercises:
  1. lib/upgrade-helpers/agent-restart-json.py — the JSON aggregator must
     populate `skipped_attached_agents` from `reason="attached"` rows.
  2. bridge_upgrade_print_agent_restart_summary (the text summary heredoc
     body in bridge-upgrade.sh) — must print an `agent_restart_warning:`
     block listing the attached agent(s) + the restart command when an
     attached row is present, and must NOT print it when none is.
"""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

TAB = "\t"


def _row(agent, status, reason, attached, session, exit_code, log_b64):
    return TAB.join(
        [agent, status, reason, attached, session, exit_code, log_b64]
    )


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke-restart-attached-notice.py <repo_root>")
    repo_root = pathlib.Path(sys.argv[1]).resolve()
    json_helper = repo_root / "lib" / "upgrade-helpers" / "agent-restart-json.py"
    upgrade_sh = repo_root / "bridge-upgrade.sh"
    if not json_helper.is_file():
        raise SystemExit(f"missing helper: {json_helper}")
    if not upgrade_sh.is_file():
        raise SystemExit(f"missing file: {upgrade_sh}")

    # Synthetic 7-column reports (see bridge_upgrade_collect_agent_restart_report).
    attached_report = "\n".join(
        [
            _row("a1", "skipped", "attached", "1", "s1", "", ""),
            _row("a2", "restarted", "eligible", "0", "s2", "0", ""),
            _row("a3", "skipped", "inactive", "0", "", "", ""),
        ]
    )
    noattach_report = _row("a2", "restarted", "eligible", "0", "s2", "0", "")

    def run_json(report):
        out = subprocess.run(
            ["python3", str(json_helper), "1", "0", report],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        return json.loads(out)

    # 1. JSON aggregator must carry the per-agent attached list.
    attached_payload = run_json(attached_report)
    assert attached_payload["skipped_attached_agents"] == ["a1"], attached_payload
    assert attached_payload["skipped_reasons"].get("attached") == 1, attached_payload
    noattach_payload = run_json(noattach_report)
    assert noattach_payload["skipped_attached_agents"] == [], noattach_payload

    # 2. Extract the live text-summary heredoc body from bridge-upgrade.sh so
    #    the actual summary logic is the thing under test (mirrors the GAP1
    #    aggregator-extraction pattern already in smoke-test.sh).
    src = upgrade_sh.read_text()
    pattern = re.compile(
        r"bridge_upgrade_print_agent_restart_summary\(\) \{.*?"
        r"python3 - \"\$payload\" <<'PY'\n"
        r"(?P<body>.*?)\nPY\n",
        re.DOTALL,
    )
    match = pattern.search(src)
    if not match:
        raise SystemExit(
            "restart-summary heredoc not located in bridge-upgrade.sh"
        )
    summary_body = match.group("body")

    def run_summary(payload):
        with tempfile.NamedTemporaryFile(
            "w", suffix=".py", delete=False
        ) as fh:
            fh.write(summary_body)
            body_path = fh.name
        try:
            return subprocess.run(
                ["python3", body_path, json.dumps(payload)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        finally:
            pathlib.Path(body_path).unlink(missing_ok=True)

    attached_summary = run_summary(attached_payload)
    assert (
        "agent_restart_warning: the following agent(s) are running OLD code"
        in attached_summary
    ), attached_summary
    assert (
        "a1  (skipped: active tmux session attached)" in attached_summary
    ), attached_summary
    assert (
        "agent_restart_warning: when ready, run: agent-bridge agent restart a1"
        in attached_summary
    ), attached_summary

    noattach_summary = run_summary(noattach_payload)
    assert "agent_restart_warning:" not in noattach_summary, noattach_summary

    print("smoke-restart-attached-notice: OK")


if __name__ == "__main__":
    main()
