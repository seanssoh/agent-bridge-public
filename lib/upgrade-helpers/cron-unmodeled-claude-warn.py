#!/usr/bin/env python3
"""cron-unmodeled-claude-warn.py — read-only upgrade-time detector for Claude
crons that the issue #1880 model-gate will SILENTLY refuse after upgrade.

Background (issue #1943, cm-prod F3): the #1880 cron runner refuses to spawn a
Claude cron child that has no stable model source (per-job → cronDefaults →
roster → BRIDGE_CRON_DEFAULT_MODEL) WHILE the agent's interactive
`.claude/settings.json` pins a model — because an unmodeled `claude -p` would
silently inherit that interactive model and 404 the whole cron surface if the
interactive model loses cron-token entitlement. The gate is correct; the
regression is that on upgrade the breakage is SILENT (the queue floods with
error followups and the operator has no warning + no remediation).

This helper converts the silent breakage into a LOUD, actionable warning. It is
strictly READ-ONLY: it never mutates jobs.json, never pins a model (auto-pinning
is a usage/entitlement decision the operator must make), and never fails the
upgrade. On ANY error it emits nothing and exits 0.

Invocation contract (footgun #11 — file-as-argv, no heredoc-stdin):
    sys.argv[1] = path to the native cron jobs.json
    sys.argv[2] = bridge root (dir holding bridge-cron-runner.py); optional,
                  defaults to two levels up from this file.

Output: a markdown warning block on stdout listing the affected agent(s)/job(s)
        + the exact remediation, ONLY when at least one Claude cron would fail
        the gate. Empty stdout (exit 0) when nothing is affected or anything
        goes wrong. The caller appends stdout to the [upgrade-complete] task
        body verbatim.

Precedence is NOT re-implemented here: the canonical
`resolve_cron_child_model_effort` and `interactive_settings_model_for_request`
are imported from bridge-cron-runner.py so the warning can never drift from the
gate it predicts.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def _fail_quiet() -> None:
    """Best-effort contract: emit nothing, never fail the upgrade."""
    raise SystemExit(0)


def _load_runner(bridge_root: Path):
    """Import the canonical cron-runner so precedence mirrors the live gate.

    Returns the module, or None when it cannot be imported (a stripped-down
    install): the caller then degrades to silence rather than re-implementing
    the precedence and risking drift.
    """
    runner_path = bridge_root / "bridge-cron-runner.py"
    if not runner_path.is_file():
        return None
    import importlib.util

    spec = importlib.util.spec_from_file_location("bridge_cron_runner", str(runner_path))
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception:
        return None
    return module


def _roster_engines(bridge_root: Path, agents: list[str]) -> dict[str, str]:
    """Map each agent id → roster engine via the canonical bash accessor.

    Sources the roster stack once (bridge-lib.sh → bridge_load_roster) and
    prints `bridge_agent_engine <a>` for every agent on its own line, mirroring
    the runner's `_roster_model_effort` invocation shape (plain `bash -c` argv,
    NOT a heredoc / process-substitution). Any failure degrades to an empty map,
    which makes every job's engine `unknown` and so warns about none — the safe,
    no-false-positive direction.
    """
    lib = bridge_root / "bridge-lib.sh"
    if not lib.is_file() or not agents:
        return {}
    script = (
        "set +e; "
        'source "$1" >/dev/null 2>&1 || exit 0; '
        "bridge_load_roster >/dev/null 2>&1 || true; "
        "shift; "
        'for a in "$@"; do printf "%s\\n" "$(bridge_agent_engine "$a" 2>/dev/null)"; done'
    )
    try:
        completed = subprocess.run(
            ["bash", "-c", script, "cron-unmodeled-warn", str(lib), *agents],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if completed.returncode != 0:
        return {}
    lines = completed.stdout.splitlines()
    engines: dict[str, str] = {}
    for idx, agent in enumerate(agents):
        engines[agent] = lines[idx].strip() if idx < len(lines) else ""
    return engines


def main() -> int:
    if len(sys.argv) < 2:
        _fail_quiet()
    jobs_path = Path(sys.argv[1]).expanduser()
    if len(sys.argv) >= 3 and sys.argv[2].strip():
        bridge_root = Path(sys.argv[2]).expanduser()
    else:
        bridge_root = Path(__file__).resolve().parent.parent.parent

    try:
        raw = json.loads(jobs_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError):
        _fail_quiet()
    if isinstance(raw, list):
        raw = {"jobs": raw}
    if not isinstance(raw, dict):
        _fail_quiet()
    jobs = raw.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        _fail_quiet()

    runner = _load_runner(bridge_root)
    if runner is None:
        _fail_quiet()

    # Collect the candidate jobs first (enabled, with an agent id) so we can
    # resolve every agent's engine in a single roster source.
    candidates: list[tuple[str, str, str]] = []  # (agent, job_id, job_name)
    seen_agents: list[str] = []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        if not bool(job.get("enabled", False)):
            continue
        agent = str(job.get("agentId") or job.get("agent") or "").strip()
        if not agent:
            continue
        job_id = str(job.get("id") or "").strip()
        job_name = str(job.get("name") or "<unnamed>").strip()
        candidates.append((agent, job_id, job_name))
        if agent not in seen_agents:
            seen_agents.append(agent)

    if not candidates:
        _fail_quiet()

    engines = _roster_engines(bridge_root, seen_agents)

    source_file = str(jobs_path)
    # affected[agent] = list of "<job_name> (<job_id>)"
    affected: dict[str, list[str]] = {}
    for agent, job_id, job_name in candidates:
        # Only Claude crons hit the #1880 gate. An agent whose roster engine is
        # not 'claude' (codex, or unknown/unresolved) is never spawned via
        # run_claude, so it cannot fail this gate — do NOT warn about it.
        if engines.get(agent, "") != "claude":
            continue
        request = {
            "target_agent": agent,
            "source_file": source_file,
            "job_id": job_id,
        }
        try:
            model, _effort, _src = runner.resolve_cron_child_model_effort(request, "claude")
        except Exception:
            continue
        if model:
            # A stable model resolves → the gate passes. No warning.
            continue
        try:
            interactive_model = runner.interactive_settings_model_for_request(request)
        except Exception:
            interactive_model = ""
        if not interactive_model:
            # No model resolves AND no interactive model is pinned → no #1880
            # coupling exists; the child proceeds on the account default exactly
            # as before. No warning (matches run_claude's no-raise branch).
            continue
        label = f"`{job_name}` (id `{job_id or '?'}`)"
        affected.setdefault(agent, []).append(label)

    if not affected:
        _fail_quiet()

    total_jobs = sum(len(v) for v in affected.values())
    lines_out: list[str] = []
    lines_out.append("## Action required: unmodeled Claude cron(s) will be REFUSED (#1880 / #1943)")
    lines_out.append("")
    lines_out.append(
        f"After this upgrade, {total_jobs} enabled Claude cron job(s) across "
        f"{len(affected)} agent(s) resolve NO stable cron-child model "
        "(per-job, cronDefaults.model, roster BRIDGE_AGENT_MODEL, and "
        "BRIDGE_CRON_DEFAULT_MODEL are all unset) while the agent's interactive "
        "`.claude/settings.json` pins a model. The #1880 gate refuses to spawn "
        "these children — they would silently inherit the interactive model and "
        "404 the whole cron surface if that model loses cron-token entitlement. "
        "**These crons will fail until you pin an explicit model.** Nothing was "
        "auto-changed: pinning a model is a usage/entitlement decision only you "
        "can make."
    )
    lines_out.append("")
    lines_out.append("Affected:")
    lines_out.append("")
    for agent in sorted(affected):
        lines_out.append(f"- agent `{agent}`:")
        for label in affected[agent]:
            lines_out.append(f"  - {label}")
    lines_out.append("")
    lines_out.append("Remediation — pick ONE (verify with `agb cron --help`):")
    lines_out.append("")
    lines_out.append(
        "1. Pin a per-job model on each affected job (most targeted):"
    )
    lines_out.append("   ```")
    lines_out.append("   agb cron update <job-id> --model <model>")
    lines_out.append("   ```")
    lines_out.append(
        "2. Or set the jobs-file cron-default model (applies to every cron job "
        "with no per-job `--model`):"
    )
    lines_out.append("   ```")
    lines_out.append("   agb cron update <job-id> --cron-default-model <model>")
    lines_out.append("   ```")
    lines_out.append(
        "3. Or set a host-wide stable fallback in the roster / environment: "
        "`BRIDGE_CRON_DEFAULT_MODEL=<model>` (or roster "
        "`BRIDGE_AGENT_MODEL[<agent>]=<model>`)."
    )
    lines_out.append("")
    lines_out.append(
        "Choose a model your cron token is entitled to (e.g. a cheaper model for "
        "scheduled jobs) — do NOT just re-pin your interactive model, which is "
        "the coupling #1880 prevents."
    )

    sys.stdout.write("\n".join(lines_out) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception:
        # Hard guarantee: a cron-scan failure must NEVER fail the upgrade.
        os._exit(0)
