#!/usr/bin/env python3
# scripts/smoke/1872-watchdog-unsupported-engine-info.py — direct callee for
# scripts/smoke/1872-watchdog-unsupported-engine-info.sh. Kept as a standalone
# file (not inlined as heredoc-stdin to python3) so the smoke is immune to
# footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock).
#
# Regression of record (#1872): an antigravity (engine has NO implemented
# contract) static agent that is otherwise HEALTHY — heartbeat ok, broken_links
# 0, onboarding complete — classifies as ``unsupported_engine_contract``. Before
# #1872 that status counted as a problem, so ``problem_count`` was >= 1 and the
# daemon regenerated a HIGH ``[watchdog] agent profile drift`` task on every
# scan (patch-agy noise). #1872 reclassifies ``unsupported_engine_contract`` to
# informational/advisory: the row STILL renders (it is in ``records``) but is
# excluded from the problem count and the HIGH drift-task gate.
#
# This smoke pins:
#   1. ``is_advisory_status`` truth table — only ``unsupported_engine_contract``
#      is advisory; ``warn`` / ``error`` / ``scan_error`` / ``ok`` are not.
#   2. POSITIVE: a healthy unsupported-engine agent → ``unsupported_engine_
#      contract`` row is VISIBLE in the rendered markdown, but the ``- problems:``
#      summary and the effective-problem tally are 0 (no HIGH drift task).
#   3. NEGATIVE CONTROL (proves the reclassify is scoped to the engine-contract
#      status ONLY): the SAME unsupported-engine agent with broken_links > 0
#      classifies ``warn`` (engine-agnostic drift), which is NOT advisory and
#      STILL pages — problem tally >= 1, row visible.
#
# The effective-problem tally mirrored here is the exact predicate the watchdog
# main() builds into ``problem_count`` (the daemon's ``watchdog-problem-count``
# helper reads that JSON field, and process_watchdog_report short-circuits the
# HIGH-task create when it is 0). Keeping the assertion at render_markdown +
# the same comprehension keeps the smoke decoupled from main()'s I/O while still
# pinning the operator-visible behavior.

import importlib.util
import pathlib
import sys


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    watchdog_path = repo_root / "bridge-watchdog.py"
    spec = importlib.util.spec_from_file_location(
        "bridge_watchdog_under_test", watchdog_path
    )
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {watchdog_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    # Register before exec_module so dataclass field resolution (AgentWatch)
    # can look the module up via sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    AgentWatch = module.AgentWatch
    classify_status = module.classify_status
    render_markdown = module.render_markdown
    is_advisory_status = module.is_advisory_status

    failures: list[str] = []

    def check(label: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")
        else:
            print(f"  PASS  {label} = {got!r}")

    # ------------------------------------------------------------------
    # 1. is_advisory_status truth table
    # ------------------------------------------------------------------
    check("advisory: unsupported_engine_contract", is_advisory_status("unsupported_engine_contract"), True)
    check("advisory: ok (not advisory)", is_advisory_status("ok"), False)
    check("advisory: warn (real drift, not advisory)", is_advisory_status("warn"), False)
    check("advisory: error (real drift, not advisory)", is_advisory_status("error"), False)
    check("advisory: scan_error (real failure, not advisory)", is_advisory_status("scan_error"), False)

    # ------------------------------------------------------------------
    # Sanity: classify_status produces the statuses this fix keys on, so the
    # positive/negative cases below are anchored to the real classifier, not a
    # hand-typed status string.
    #   - healthy unsupported engine, no broken links -> unsupported_engine_contract
    #   - SAME engine, broken links present           -> warn (engine-agnostic)
    # ------------------------------------------------------------------
    healthy_status = classify_status(
        [], [], "complete", False,
        session_type="unknown", agent_source="static", engine="antigravity",
    )
    check("classify: healthy antigravity -> unsupported_engine_contract",
          healthy_status, "unsupported_engine_contract")
    broken_status = classify_status(
        [], ["MEMORY.md -> missing"], "complete", False,
        session_type="unknown", agent_source="static", engine="antigravity",
    )
    check("classify: antigravity + broken_links -> warn (negative control)",
          broken_status, "warn")

    def make_record(status: str, broken_links: list[str]) -> object:
        return AgentWatch(
            agent="patch-agy",
            session_type="unknown",
            onboarding_state="complete",
            status=status,
            missing_files=[],
            broken_links=broken_links,
            missing_managed_claude_block=False,
            heartbeat_present=True,
            heartbeat_age_seconds=10,
            engine="antigravity",
            agent_source="static",
        )

    # Mirror of bridge-watchdog.py main()'s effective_problems predicate (the
    # one that drives the JSON problem_count the daemon reads). iso_skipped /
    # restart_in_progress are out of scope here (no iso boundary / no restart
    # marker in these synthetic rows) so the predicate reduces to: not ok and
    # not advisory.
    def effective_problem_count(records: list) -> int:
        return sum(
            1 for item in records
            if item.status != "ok"
            and not is_advisory_status(item.status)
            and not item.restart_in_progress
        )

    bridge_home = pathlib.Path("/tmp/bridge-home-1872-smoke")

    # ------------------------------------------------------------------
    # 2. POSITIVE: healthy unsupported-engine agent.
    #    Row is VISIBLE, but problem tally is 0 (no HIGH drift task).
    # ------------------------------------------------------------------
    healthy_records = [make_record("unsupported_engine_contract", [])]
    healthy_md = render_markdown(healthy_records, bridge_home)
    check("positive: row visible in markdown (status line rendered)",
          "- status: unsupported_engine_contract" in healthy_md, True)
    check("positive: agent block visible in markdown",
          "## patch-agy" in healthy_md, True)
    check("positive: markdown problem tally is 0 (no drift task)",
          "- problems: 0" in healthy_md, True)
    check("positive: effective problem_count is 0 (daemon gate -> no HIGH task)",
          effective_problem_count(healthy_records), 0)

    # ------------------------------------------------------------------
    # 3. NEGATIVE CONTROL: SAME unsupported-engine agent with broken_links > 0.
    #    classify_status returns warn (engine-agnostic drift) -> NOT advisory ->
    #    STILL pages. Proves the reclassify is scoped to the engine-contract
    #    status, not a blanket suppression of all unsupported-engine rows.
    # ------------------------------------------------------------------
    broken_records = [make_record("warn", ["MEMORY.md -> missing"])]
    broken_md = render_markdown(broken_records, bridge_home)
    check("negative-control: warn row still counted in markdown problem tally",
          "- problems: 1" in broken_md, True)
    check("negative-control: broken_links surfaced in markdown",
          "- broken_links: 1 found" in broken_md, True)
    check("negative-control: effective problem_count is 1 (STILL pages)",
          effective_problem_count(broken_records), 1)

    # ------------------------------------------------------------------
    # 4. Mixed report: one advisory row + one genuine warn row. Only the warn
    #    row counts; the advisory row stays visible. (Guards that the advisory
    #    exclusion does not accidentally swallow a co-located real problem.)
    # ------------------------------------------------------------------
    mixed_records = [
        make_record("unsupported_engine_contract", []),
        AgentWatch(
            agent="patch-agy-2",
            session_type="unknown",
            onboarding_state="complete",
            status="warn",
            missing_files=[],
            broken_links=["SOUL.md -> missing"],
            missing_managed_claude_block=False,
            heartbeat_present=True,
            heartbeat_age_seconds=10,
            engine="antigravity",
            agent_source="static",
        ),
    ]
    mixed_md = render_markdown(mixed_records, bridge_home)
    check("mixed: only the genuine warn row counts (problems: 1)",
          "- problems: 1" in mixed_md, True)
    check("mixed: advisory row still visible",
          "## patch-agy\n- status: unsupported_engine_contract" in mixed_md, True)
    check("mixed: effective problem_count is 1",
          effective_problem_count(mixed_records), 1)

    if failures:
        for f in failures:
            print(f"  FAIL  {f}", file=sys.stderr)
        return 1
    print("[smoke:1872-watchdog-unsupported-engine-info] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
