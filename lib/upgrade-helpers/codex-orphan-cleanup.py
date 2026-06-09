#!/usr/bin/env python3
"""codex-orphan-cleanup.py — upgrade-time one-shot detector/reaper for
leaked codex broker + queue-gateway socket-server orphans (issue #1567).

Pre-0.16.0 installs leak two distinct classes of orphaned long-lived
processes that NOTHING reaps on subsequent upgrades:

  1. CODEX BROKER orphans — the openai-codex Claude plugin spawns an
     `app-server-broker.mjs` (parent node) + a child `node` app-server per
     disposable-agent / worktree session. On agent teardown the broker is
     not reaped on older versions and re-parents to init (`ppid==1`),
     holding ~100-160MB each. Reapable signature (ALL required):
     `app-server-broker.mjs` with `ppid==1` AND a `--cwd` that matches
     `.claude/worktrees/agent-*` AND no longer exists on disk (the
     disposable-worktree provenance proving the spawning session is gone).
     ppid==1 alone is intentionally NOT sufficient to kill — a broker with no
     `--cwd`, a non-worktree `--cwd`, or a still-present worktree is left
     alone. The prevention fix (#1560 per-teardown reap) stops NEW leaks but
     does nothing for the backlog already accumulated on a long-running
     server. Reaping the parent broker alone orphans the child node, so we
     reap the `ppid==1` broker AND its child `node` app-server together.

  2. QUEUE-GATEWAY socket-server orphans (#1567 follow-up comment) —
     smoke-test teardown leaks `bridge-queue-gateway.py socket-server
     --bridge-home <X>` processes whose `--bridge-home` is a long-gone
     `/tmp/agb-smoke-*` dir; they re-parent to systemd-user/init and survive
     indefinitely. Signature: command matches `bridge-queue-gateway.py
     socket-server` AND `--bridge-home <X>` where <X> does not resolve to an
     existing directory (and/or matches `/tmp/agb-smoke-*`).

This helper is invoked ONCE from bridge-upgrade.sh behind a migration marker
(state/upgrade/codex-orphan-cleanup.ts) so it runs exactly once on the first
upgrade that introduces it. Default posture is CONSERVATIVE per the issue:
DRY-RUN report only (nothing killed) unless `--reap` is passed. The .sh shim
turns the JSON report into a redacted audit line and enqueues a high-priority
admin cleanup task carrying the safe-kill recipe.

Process detection / PID-reuse defense reuses the field-tested machinery shape
from bridge-mcp-cleanup.py (#8807 / #9770): a single `ps` snapshot, an
lstart-anchored PID-reuse revalidation immediately before every signal, and a
bounded SIGTERM -> grace -> SIGKILL escalation. We NEVER signal a pid we cannot
re-prove the identity of (command + absolute start-time), and we NEVER touch a
broker/socket-server that is not provably orphaned.

Invocation (file-as-argv from the .sh shim; no heredoc-stdin into a
subprocess — footgun #11 / lint-heredoc-ban):

    codex-orphan-cleanup.py scan  [--min-age-seconds N] [--json]
    codex-orphan-cleanup.py reap  [--min-age-seconds N] [--grace-seconds F] [--json]

`scan` only detects + reports (never signals). `reap` detects then reaps the
matched orphans. Both print a JSON report to stdout when `--json` is given (the
default for shim consumption); a human summary otherwise.

Exit code: 0 on success (including "nothing found"); 1 only if a reap was
requested and at least one matched orphan could not be signalled (permission
error). Detection-only never fails the upgrade.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Iterable


# --- conservative detection patterns -------------------------------------
#
# Each pattern is specific to an Agent Bridge / openai-codex plugin process
# identity. We deliberately do NOT match a bare `node` or `codex` — a live
# `codex resume <hash>` is an attached agent pair and must never be killed.

# Codex broker: the openai-codex plugin's app-server broker. The `.mjs`
# anchor + the plugin path fragment keep this off any unrelated node process.
CODEX_BROKER_RE = re.compile(r"(?:^|/)app-server-broker\.mjs(?:\s|$)")

# The child node app-server the broker spawns. We only ever reap one of these
# when it is a descendant of a matched orphaned broker (see classify_codex),
# never on the command string alone.
CODEX_APP_SERVER_RE = re.compile(r"\bapp-server\b")

# Queue-gateway socket-server: bridge-queue-gateway.py socket-server ...
QUEUE_GATEWAY_RE = re.compile(r"bridge-queue-gateway\.py\s+socket-server\b")

# --bridge-home <path> extractor (handles `--bridge-home X` and
# `--bridge-home=X`).
BRIDGE_HOME_RE = re.compile(r"--bridge-home(?:=|\s+)(\S+)")

# --cwd <path> extractor for the codex broker worktree provenance.
CWD_RE = re.compile(r"--cwd(?:=|\s+)(\S+)")

# A finished disposable worktree the broker was launched against.
WORKTREE_RE = re.compile(r"\.claude/worktrees/agent-")

# Smoke-test bridge-home cruft.
SMOKE_HOME_RE = re.compile(r"^/tmp/agb-smoke-")


@dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    age_seconds: int
    rss_kb: int
    command: str


@dataclass
class Candidate:
    pid: int
    ppid: int
    age_seconds: int
    rss_kb: int
    command: str
    klass: str  # "codex-broker" | "codex-app-server" | "queue-gateway"
    pattern: str
    cwd: str = ""
    bridge_home: str = ""
    lstart: str = ""
    reason: str = ""  # why it was classified as a reapable orphan
    result: str = ""  # populated on reap


def parse_etime(value: str) -> int:
    days = 0
    if "-" in value:
        day_text, value = value.split("-", 1)
        try:
            days = int(day_text)
        except ValueError:
            days = 0
    parts = value.split(":")
    try:
        if len(parts) == 3:
            hours, minutes, seconds = (int(part) for part in parts)
        elif len(parts) == 2:
            hours = 0
            minutes, seconds = (int(part) for part in parts)
        elif len(parts) == 1:
            hours = 0
            minutes = 0
            seconds = int(parts[0])
        else:
            return 0
    except ValueError:
        return 0
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def ps_output() -> tuple[str, bool]:
    """Return (stdout, age_is_seconds). Prefer the numeric `etimes` form
    (Linux + recent macOS); fall back to `etime` (BSD/macOS) when the first
    form is unsupported."""
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,etimes=,rss=,command="],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed.stdout, True
    except subprocess.CalledProcessError:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,etime=,rss=,command="],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed.stdout, False


def load_processes() -> dict[int, Proc]:
    output, age_is_seconds = ps_output()
    processes: dict[int, Proc] = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 5:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            rss = int(parts[3])
        except ValueError:
            continue
        age = int(parts[2]) if age_is_seconds else parse_etime(parts[2])
        processes[pid] = Proc(
            pid=pid, ppid=ppid, age_seconds=age, rss_kb=rss, command=parts[4]
        )
    return processes


def read_proc_identity(pid: int) -> tuple[str, int, int] | None:
    """Re-read a single pid's (command, ppid, age_seconds) directly from ps.

    Returns None if the pid is gone or unreadable. Used for PID-reuse
    revalidation immediately before each signal so we never kill a process
    that has been replaced (same numeric pid, different program) since the
    snapshot that classified it as an orphan.
    """
    for age_flag, age_is_seconds in (("etimes=", True), ("etime=", False)):
        try:
            completed = subprocess.run(
                ["ps", "-p", str(pid), "-o", f"ppid=,{age_flag},command="],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except subprocess.CalledProcessError:
            if age_is_seconds:
                continue
            return None
        line = completed.stdout.strip()
        if not line:
            return None
        parts = line.split(None, 2)
        if len(parts) < 3:
            return None
        try:
            ppid = int(parts[0])
        except ValueError:
            return None
        age = int(parts[1]) if age_is_seconds else parse_etime(parts[1])
        return parts[2], ppid, age
    return None


def read_proc_lstart(pid: int) -> str:
    """Read a pid's ABSOLUTE process start timestamp via `ps -o lstart=`.

    pid + start-time is a unique process identity: a recycled pid is a NEW
    process with a different start time. Returns the whitespace-normalized
    timestamp, or "" if unreadable (callers treat "" as "cannot prove
    identity" -> refuse to signal).
    """
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError:
        return ""
    return " ".join(completed.stdout.split())


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _first_group(regex: re.Pattern[str], command: str) -> str:
    match = regex.search(command)
    return match.group(1) if match else ""


def classify_orphans(
    processes: dict[int, Proc], min_age: int
) -> list[Candidate]:
    """Conservatively classify reapable orphans from a single ps snapshot.

    Returns the codex broker orphans (ppid==1, finished worktree --cwd) plus
    their child node app-servers, and the queue-gateway socket-server orphans
    whose --bridge-home no longer exists (or is a /tmp smoke dir). Nothing
    that could be a live/owned process is included.
    """
    candidates: list[Candidate] = []
    self_pid = os.getpid()

    # --- codex broker orphans -------------------------------------------
    # A broker is reapable ONLY when ALL hold: it is orphaned (ppid==1), it is
    # past the idle floor, AND it carries POSITIVE disposable-worktree
    # provenance — a `--cwd` that matches `.claude/worktrees/agent-*` AND no
    # longer exists on disk. ppid==1 alone is NOT enough evidence to KILL: a
    # legit broker can reparent to init for benign reasons, and a broker with
    # no `--cwd` (or a `--cwd` that is not a disposable worktree, or one whose
    # worktree still exists) might belong to a live/owned session. Requiring the
    # gone-worktree `--cwd` is the provenance that proves the session that
    # spawned this broker has already torn down.
    orphan_broker_pids: set[int] = set()
    for proc in processes.values():
        if proc.pid == self_pid:
            continue
        if "codex-orphan-cleanup" in proc.command:
            continue
        if not CODEX_BROKER_RE.search(proc.command):
            continue
        if proc.ppid != 1:
            # Not orphaned — still parented to a live session/launcher.
            continue
        if proc.age_seconds < min_age:
            continue
        cwd = _first_group(CWD_RE, proc.command)
        if not cwd:
            # No --cwd to prove disposable-worktree provenance -> NOT enough
            # evidence to kill (could be a live/owned broker). Skip.
            continue
        if not WORKTREE_RE.search(cwd):
            # --cwd points somewhere that is NOT a disposable worktree;
            # could be an operator/live codex. Skip.
            continue
        if os.path.isdir(cwd):
            # Worktree still on disk -> may belong to a live session. Skip.
            continue
        reason = "broker ppid==1, finished worktree --cwd gone"
        candidates.append(
            Candidate(
                pid=proc.pid,
                ppid=proc.ppid,
                age_seconds=proc.age_seconds,
                rss_kb=proc.rss_kb,
                command=proc.command,
                klass="codex-broker",
                pattern=CODEX_BROKER_RE.pattern,
                cwd=cwd,
                reason=reason,
            )
        )
        orphan_broker_pids.add(proc.pid)

    # Child node app-servers of a matched orphaned broker. Reaping the broker
    # alone orphans the child, so we reap them together. We only ever capture
    # a DIRECT child of a broker we already classified as an orphan.
    for proc in processes.values():
        if proc.pid == self_pid:
            continue
        if proc.ppid not in orphan_broker_pids:
            continue
        if not CODEX_APP_SERVER_RE.search(proc.command):
            continue
        candidates.append(
            Candidate(
                pid=proc.pid,
                ppid=proc.ppid,
                age_seconds=proc.age_seconds,
                rss_kb=proc.rss_kb,
                command=proc.command,
                klass="codex-app-server",
                pattern=CODEX_APP_SERVER_RE.pattern,
                reason="child app-server of orphaned broker",
            )
        )

    # --- queue-gateway socket-server orphans ----------------------------
    for proc in processes.values():
        if proc.pid == self_pid:
            continue
        if "codex-orphan-cleanup" in proc.command:
            continue
        if not QUEUE_GATEWAY_RE.search(proc.command):
            continue
        if proc.age_seconds < min_age:
            continue
        bridge_home = _first_group(BRIDGE_HOME_RE, proc.command)
        if not bridge_home:
            # No --bridge-home to prove staleness against -> skip (cannot
            # prove it is orphaned cruft).
            continue
        is_smoke = bool(SMOKE_HOME_RE.search(bridge_home))
        home_exists = os.path.isdir(bridge_home)
        if home_exists and not is_smoke:
            # The --bridge-home still resolves and is not a /tmp smoke dir ->
            # could be a live gateway. Never touch it.
            continue
        reason = (
            "queue-gateway --bridge-home is /tmp smoke dir"
            if is_smoke
            else "queue-gateway --bridge-home no longer exists"
        )
        candidates.append(
            Candidate(
                pid=proc.pid,
                ppid=proc.ppid,
                age_seconds=proc.age_seconds,
                rss_kb=proc.rss_kb,
                command=proc.command,
                klass="queue-gateway",
                pattern=QUEUE_GATEWAY_RE.pattern,
                bridge_home=bridge_home,
                reason=reason,
            )
        )

    return candidates


def _capture_lstart(candidates: list[Candidate]) -> None:
    for cand in candidates:
        cand.lstart = read_proc_lstart(cand.pid)


def still_killable(cand: Candidate) -> bool:
    """PID-reuse guard: confirm the pid is still the same orphan we
    classified. Anchored on the absolute start-time (lstart) — a recycled pid
    is a fresh process with a later start time and is refused. Empty captured
    or live lstart fails closed."""
    if not cand.lstart:
        return False
    identity = read_proc_identity(cand.pid)
    if identity is None:
        return False
    command, _ppid, age = identity
    pattern = re.compile(cand.pattern)
    if not pattern.search(command):
        return False
    if command != cand.command:
        return False
    live_lstart = read_proc_lstart(cand.pid)
    if not live_lstart or live_lstart != cand.lstart:
        return False
    # A reused pid is a fresh process -> strictly younger than our snapshot.
    if age < cand.age_seconds:
        return False
    return True


def reap_one(cand: Candidate, grace_seconds: float) -> tuple[bool, str]:
    """SIGTERM -> grace -> SIGKILL with start-time-anchored PID-reuse
    revalidation before EVERY signal. Fail-soft + idempotent: ESRCH is
    success/no-op; a vanished or identity-changed pid is skipped."""
    if not still_killable(cand):
        return True, "skipped-pid-reuse"
    try:
        os.kill(cand.pid, signal.SIGTERM)
    except ProcessLookupError:
        return True, "already-gone"
    except PermissionError as exc:
        return False, f"permission-denied: {exc}"

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not alive(cand.pid):
            return True, "terminated"
        time.sleep(0.05)

    # Revalidate again before escalating — the pid may have exited and been
    # recycled during the grace window.
    if not still_killable(cand):
        return True, "terminated"
    try:
        os.kill(cand.pid, signal.SIGKILL)
    except ProcessLookupError:
        return True, "terminated"
    except PermissionError as exc:
        return False, f"permission-denied: {exc}"
    return True, "killed"


def _report(candidates: list[Candidate], reaped: bool, dry_run: bool) -> dict:
    by_class: dict[str, int] = {}
    rss_total = 0
    for cand in candidates:
        by_class[cand.klass] = by_class.get(cand.klass, 0) + 1
        rss_total += cand.rss_kb
    return {
        "schema": "codex-orphan-cleanup/v1",
        "dry_run": dry_run,
        "reaped": reaped,
        "counts": {
            "total": len(candidates),
            "by_class": by_class,
        },
        "reclaimable_rss_kb": rss_total,
        "candidates": [
            {
                "pid": cand.pid,
                "ppid": cand.ppid,
                "class": cand.klass,
                "age_seconds": cand.age_seconds,
                "rss_kb": cand.rss_kb,
                "cwd": cand.cwd,
                "bridge_home": cand.bridge_home,
                "reason": cand.reason,
                "result": cand.result,
            }
            for cand in candidates
        ],
    }


def _human_summary(report: dict) -> str:
    lines: list[str] = []
    total = report["counts"]["total"]
    mode = "reap" if report["reaped"] else "dry-run"
    lines.append(
        f"[codex-orphan-cleanup] {mode}: {total} orphan(s), "
        f"~{report['reclaimable_rss_kb']} KB reclaimable"
    )
    for klass, count in sorted(report["counts"]["by_class"].items()):
        lines.append(f"  - {klass}: {count}")
    for cand in report["candidates"]:
        result = f" -> {cand['result']}" if cand["result"] else ""
        lines.append(
            f"  pid={cand['pid']} ppid={cand['ppid']} class={cand['class']} "
            f"age={cand['age_seconds']}s rss={cand['rss_kb']}KB "
            f"reason='{cand['reason']}'{result}"
        )
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    for name in ("scan", "reap"):
        p = sub.add_parser(name)
        p.add_argument(
            "--min-age-seconds",
            type=int,
            default=7200,
            help="only consider orphans at least this old (default 7200 = 2h)",
        )
        p.add_argument(
            "--grace-seconds",
            type=float,
            default=3.0,
            help="SIGTERM grace before SIGKILL (reap only; default 3.0)",
        )
        p.add_argument("--json", action="store_true", help="emit JSON report")
    args = parser.parse_args(argv)

    processes = load_processes()
    candidates = classify_orphans(processes, args.min_age_seconds)

    reaped = args.mode == "reap"
    had_failure = False
    if reaped and candidates:
        _capture_lstart(candidates)
        for cand in candidates:
            ok, result = reap_one(cand, args.grace_seconds)
            cand.result = result
            if not ok:
                had_failure = True

    report = _report(candidates, reaped=reaped, dry_run=not reaped)
    if args.json:
        print(json.dumps(report))
    else:
        print(_human_summary(report))

    return 1 if had_failure else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
