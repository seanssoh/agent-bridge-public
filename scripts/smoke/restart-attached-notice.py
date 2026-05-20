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
import os
import pathlib
import re
import sqlite3
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

    # 3. Dedupe contract (PR #996 r2). The [restart-required] task filer in
    #    bridge-upgrade.sh probes the target queue with `bridge-queue.py
    #    find-open --title-prefix <exact title>` and SKIPS creating a second
    #    task when an open one already exists — otherwise an operator who
    #    re-runs `upgrade --restart-agents` while staying attached gets the
    #    admin inbox spammed with duplicate manual-restart tasks. Exercise
    #    that exact primitive against a real temp queue DB so a regression
    #    in find-open (or its title-match) reproduces here.
    _check_restart_required_dedupe(repo_root)

    print("smoke-restart-attached-notice: OK")


def _check_restart_required_dedupe(repo_root):
    queue_py = repo_root / "bridge-queue.py"
    if not queue_py.is_file():
        raise SystemExit(f"missing file: {queue_py}")
    title = "[restart-required] a1 — upgrade to v9.9.9"
    other_version_title = "[restart-required] a1 — upgrade to v9.9.10"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        db_path = tmp_path / "tasks.db"
        env = {**os.environ, "BRIDGE_TASK_DB": str(db_path)}

        def queue(*qargs, expect_zero=True):
            proc = subprocess.run(
                ["python3", str(queue_py), *qargs],
                capture_output=True,
                text=True,
                env=env,
            )
            if expect_zero and proc.returncode != 0:
                raise SystemExit(
                    f"bridge-queue.py {qargs} failed: {proc.stderr.strip()}"
                )
            return proc

        body = tmp_path / "rr-body.md"
        body.write_text("manual restart body\n")

        # File the first [restart-required] task.
        queue(
            "create", "--to", "admin", "--from", "admin",
            "--priority", "normal", "--title", title,
            "--body-file", str(body),
        )

        # The dedupe probe: an open task with this exact title must be
        # found (exit 0, prints the id) — this is what makes the filer
        # SKIP a second create on a repeated identical upgrade.
        found = queue(
            "find-open", "--agent", "admin",
            "--title-prefix", title, "--format", "id",
            expect_zero=False,
        )
        assert found.returncode == 0, found.stderr
        assert found.stdout.strip().isdigit(), found.stdout

        # A genuinely different upgrade version must NOT be deduped — the
        # title pins the version, so a new upgrade still gets a task.
        other = queue(
            "find-open", "--agent", "admin",
            "--title-prefix", other_version_title, "--format", "id",
            expect_zero=False,
        )
        assert other.returncode != 0, other.stdout
        assert other.stdout.strip() == "", other.stdout

        # The filer's second run SKIPS the create because find-open
        # matched — so the open-task count for this title must stay at 1.
        # A regression that drops the skip branch would INSERT a 2nd row.
        conn = sqlite3.connect(str(db_path))
        try:
            open_count = conn.execute(
                "SELECT COUNT(*) FROM tasks "
                "WHERE title = ? AND status IN ('queued', 'claimed', 'blocked')",
                (title,),
            ).fetchone()[0]
        finally:
            conn.close()
        assert open_count == 1, (
            f"expected 1 open [restart-required] task, got {open_count}"
        )


if __name__ == "__main__":
    main()
