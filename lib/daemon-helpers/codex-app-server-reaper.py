#!/usr/bin/env python3
"""codex-app-server-reaper.py — periodic/standalone reaper for codex
`app-server` + `app-server-broker.mjs` process pairs that leak after a codex
session/host exit (issue #2196).

THE LEAK (macOS-scoped). Each codex session spawns a Node broker:

    node .../openai-codex/codex/<v>/scripts/app-server-broker.mjs serve \
      --endpoint unix:/var/folders/.../broker.sock --cwd <wd> \
      --pid-file /var/folders/.../broker.pid

which forks exactly one `codex app-server` child (1 broker : 1 app-server).
When the session (or the Claude Code / MCP host that launched it) exits, the
broker is NOT torn down: it is **reparented to launchd (`ppid == 1`)** and
keeps its `codex app-server` child alive indefinitely. Standard health checks
miss it (no zombie; the ppid==1 process is the broker, the app-server's parent
is the broker, so the count-orphans heuristic never fires). On a long-lived
admin host these accumulate without bound (146 pairs / ~9.3 GB in the incident
that motivated this).

This is the GLOBAL-ORPHAN counterpart to the per-session teardown reaper in
bridge-mcp-cleanup.py `subtree`: that path only reaps within a *known live*
pane's subtree at teardown and therefore cannot touch a broker that has
already reparented to launchd (it has no live pane ancestor). The #1567
upgrade-time reaper (lib/upgrade-helpers/codex-orphan-cleanup.py) only matches
brokers whose disposable-worktree `--cwd` is GONE — it does not catch a leaked
broker whose `--cwd` still exists or is not a disposable worktree, which is the
#2196 class.

REAP SIGNATURE (ALL must hold before any signal):
  1. platform is macOS (launchd reparenting is the orphan signal); on other
     platforms this reaper is a no-op.
  2. a Node `app-server-broker.mjs` process, AND
  3. that broker has `ppid == 1` (reparented to launchd — the orphan signal),
     AND
  4. the broker is NOT backed by a live registered codex session — it is not in
     the process subtree of any live codex pane (`--protect-root-pid`), its
     `--cwd` is not under any live codex agent workdir (`--protect-cwd`), and it
     is not an explicitly protected pid (`--protect-pid`). THIS IS THE CRITICAL
     SAFETY GATE: a live `patch-dev` / `agb-dev-codex` / `crm-dev-codex`
     app-server must never be reaped.  AND
  5. the broker is older than `--min-age-seconds` (default 6h) so a
     just-spawned session is never raced.

We reap the broker AND its `codex app-server` child together (SIGTERM the child
first, then the now-childless broker), with a SIGTERM -> grace -> SIGKILL
escalation and start-time-anchored PID-reuse revalidation immediately before
EVERY signal (same machinery shape as codex-orphan-cleanup.py / the #8807 /
#9770 reapers). When ANY gate is uncertain we DO NOT kill and log instead.

The live-session protection inputs (root pids / cwds) are computed by the
bridge caller (bridge-daemon.sh `process_codex_app_server_reaper` /
`cmd_reap_codex_orphans`) from the in-process roster and passed as argv.

Invocation (file-as-argv; no heredoc-stdin into a subprocess — footgun #11):

    codex-app-server-reaper.py scan [opts]   # detect + report, never signals
    codex-app-server-reaper.py reap [opts]    # detect then reap matched pairs

Options:
    --min-age-seconds N     orphan-broker age floor (default 21600 = 6h)
    --grace-seconds F       SIGTERM grace before SIGKILL (reap; default 5.0)
    --protect-root-pid PID  live codex pane pid; its whole subtree is spared
                            (repeatable)
    --protect-pid PID       explicit pid to spare (repeatable)
    --protect-cwd PATH      live codex agent workdir; a broker whose --cwd is at
                            or under PATH is spared (repeatable)
    --platform {auto,macos,any}
                            auto (default): run only on Darwin. macos: require
                            Darwin (skip otherwise). any: run regardless (tests).
    --ps-snapshot FILE      TEST SEAM: read the process table from FILE instead
                            of live `ps`. Lines are
                            `pid ppid age_seconds rss command...`. Used by the
                            smoke to fabricate ppid==1 / old-age / live process
                            tables deterministically; os.kill() still targets
                            the REAL pids in the file. Never used in production.
    --json                  emit the JSON report (default for shim consumption)

Exit code: 0 on success (including "nothing found" / platform-skip); 1 only if
a reap was requested and at least one matched orphan could not be signalled
(permission error). Detection-only never fails.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Optional


# Node app-server broker spawned by the openai-codex plugin. The `.mjs` anchor
# keeps this off any unrelated node process.
CODEX_BROKER_RE = re.compile(r"(?:^|/)app-server-broker\.mjs(?:\s|$)")

# The child `codex app-server`. We only ever reap one of these when it is a
# DIRECT child of a matched orphaned broker — never on the command alone. The
# `codex ` prefix keeps this off the broker's own `app-server-broker` command.
CODEX_APP_SERVER_RE = re.compile(r"(?:^|/)codex\s+app-server\b")

# --cwd <path> extractor. The path MAY contain spaces (an agent workdir like
# "/Users/op/Live Project"), so capture up to the NEXT ` --<flag>` token or
# end-of-string rather than the first whitespace. A `\S+` capture truncates a
# spaced path and would DEFEAT the cwd-based live-session protection — a live
# broker whose workdir has a space would parse to a non-matching prefix and be
# misclassified as an orphan, then killed (codex Phase-4 finding). The
# openai-codex broker argv is `... serve --cwd <path> [--pid-file <p>]
# [--endpoint <e>]`, so a following ` --<flag>` is the reliable right delimiter.
CWD_RE = re.compile(r"--cwd(?:=|\s+)(.+?)(?=\s+--|\s*$)")


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
    klass: str  # "codex-broker" | "codex-app-server"
    pattern: str
    cwd: str = ""
    lstart: str = ""
    reason: str = ""
    result: str = ""


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


# --- process table source -------------------------------------------------
#
# Production reads a single live `ps` snapshot. The smoke injects a fabricated
# table via --ps-snapshot so it can deterministically present ppid==1 / old-age
# / roster-backed processes without daemonizing or waiting 6h; os.kill() still
# targets the real pids listed, so the kill path is exercised for real.


def _live_ps_output() -> tuple[str, bool]:
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,etimes=,rss=,command="],
            check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return completed.stdout, True
    except subprocess.CalledProcessError:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,etime=,rss=,command="],
            check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return completed.stdout, False


def load_processes(snapshot_path: Optional[str]) -> dict[int, Proc]:
    if snapshot_path:
        with open(snapshot_path, encoding="utf-8", errors="replace") as handle:
            output = handle.read()
        age_is_seconds = True
    else:
        output, age_is_seconds = _live_ps_output()
    processes: dict[int, Proc] = {}
    for line in output.splitlines():
        if not line.strip():
            continue
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


def read_proc_identity(
    pid: int, snapshot: Optional[dict[int, Proc]]
) -> Optional[tuple[str, int, int]]:
    """Re-read a single pid's (command, ppid, age_seconds) immediately before a
    signal, for PID-reuse revalidation. In snapshot (test) mode this resolves
    from the injected table (and confirms the real pid is still alive); in
    production it re-reads live `ps`."""
    if snapshot is not None:
        proc = snapshot.get(pid)
        if proc is None or not alive(pid):
            return None
        return proc.command, proc.ppid, proc.age_seconds
    for age_flag, age_is_seconds in (("etimes=", True), ("etime=", False)):
        try:
            completed = subprocess.run(
                ["ps", "-p", str(pid), "-o", f"ppid=,{age_flag},command="],
                check=True, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
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


def read_proc_lstart(pid: int, snapshot: Optional[dict[int, Proc]]) -> str:
    """Absolute process start identity. pid + start-time uniquely identifies a
    process (a recycled pid is a NEW process with a different start). In
    snapshot (test) mode we synthesize a STABLE token from the injected command
    (equal across the two reads that bracket a signal) and treat a dead pid as
    unprovable ("")."""
    if snapshot is not None:
        proc = snapshot.get(pid)
        if proc is None or not alive(pid):
            return ""
        return f"snapshot::{proc.command}"
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
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


def _children_map(processes: dict[int, Proc]) -> dict[int, list[int]]:
    children: dict[int, list[int]] = {}
    for proc in processes.values():
        children.setdefault(proc.ppid, []).append(proc.pid)
    return children


def _subtree_pids(
    root_pid: int, children: dict[int, list[int]], max_nodes: int = 8192
) -> set[int]:
    """All pids at or below root_pid (inclusive), BFS-bounded."""
    seen: set[int] = {root_pid}
    queue: list[int] = list(children.get(root_pid, []))
    while queue and len(seen) < max_nodes:
        pid = queue.pop()
        if pid in seen:
            continue
        seen.add(pid)
        queue.extend(children.get(pid, []))
    return seen


def _cwd_protected(cwd: str, protect_cwds: list[str]) -> bool:
    if not cwd:
        return False
    norm = os.path.normpath(cwd)
    for base in protect_cwds:
        base_norm = os.path.normpath(base)
        if norm == base_norm or norm.startswith(base_norm + os.sep):
            return True
    return False


def compute_protected(
    processes: dict[int, Proc],
    protect_root_pids: list[int],
    protect_pids: list[int],
) -> set[int]:
    """The set of pids that must never be signalled: explicit protected pids
    plus the entire process subtree of each live codex pane root."""
    children = _children_map(processes)
    protected: set[int] = set(protect_pids)
    for root in protect_root_pids:
        if root in processes or root in children:
            protected |= _subtree_pids(root, children)
    return protected


def classify_orphans(
    processes: dict[int, Proc],
    min_age: int,
    protect_root_pids: list[int],
    protect_pids: list[int],
    protect_cwds: list[str],
) -> list[Candidate]:
    """Conservatively classify reapable codex broker+app-server orphan pairs
    from a single process snapshot. Returns app-server children BEFORE their
    brokers so a reap signals the child first, then the now-childless broker."""
    self_pid = os.getpid()
    children = _children_map(processes)
    protected = compute_protected(processes, protect_root_pids, protect_pids)

    broker_candidates: list[Candidate] = []
    orphan_broker_pids: set[int] = set()
    for proc in processes.values():
        if proc.pid == self_pid:
            continue
        if "codex-app-server-reaper" in proc.command:
            continue
        if not CODEX_BROKER_RE.search(proc.command):
            continue
        if proc.ppid != 1:
            # Still parented to a live session/launcher — not orphaned.
            continue
        if proc.age_seconds < min_age:
            continue
        if proc.pid in protected:
            # Backed by a live codex session (pane subtree / explicit) — spare.
            continue
        cwd = _first_group(CWD_RE, proc.command)
        if not cwd or cwd.startswith("-"):
            # FAIL-CLOSED: a broker with no confidently-parsed --cwd cannot be
            # proven detached from a live session, so we never kill it. The
            # leaked orphans always carry `--cwd <worktree>`; this only spares
            # the absent / malformed / ambiguous case (codex Phase-4 finding).
            continue
        if _cwd_protected(cwd, protect_cwds):
            # --cwd is at/under a live codex agent workdir — spare.
            continue
        broker_candidates.append(
            Candidate(
                pid=proc.pid, ppid=proc.ppid, age_seconds=proc.age_seconds,
                rss_kb=proc.rss_kb, command=proc.command,
                klass="codex-broker", pattern=CODEX_BROKER_RE.pattern,
                cwd=cwd,
                reason="broker ppid==1, not live-session-backed, age>=floor",
            )
        )
        orphan_broker_pids.add(proc.pid)

    app_server_candidates: list[Candidate] = []
    for broker_pid in orphan_broker_pids:
        for child_pid in children.get(broker_pid, []):
            child = processes.get(child_pid)
            if child is None or child.pid == self_pid:
                continue
            if child.pid in protected:
                continue
            if not CODEX_APP_SERVER_RE.search(child.command):
                continue
            app_server_candidates.append(
                Candidate(
                    pid=child.pid, ppid=child.ppid,
                    age_seconds=child.age_seconds, rss_kb=child.rss_kb,
                    command=child.command, klass="codex-app-server",
                    pattern=CODEX_APP_SERVER_RE.pattern,
                    reason="child app-server of orphaned broker",
                )
            )

    # Children first, then brokers — so SIGTERM hits the app-server before its
    # now-childless broker (mirrors the validated manual recipe in #2196).
    return app_server_candidates + broker_candidates


def still_killable(cand: Candidate, snapshot: Optional[dict[int, Proc]]) -> bool:
    """PID-reuse guard: confirm the pid is still the same orphan we classified,
    anchored on the absolute start-time. An empty/changed identity fails
    closed."""
    if not cand.lstart:
        return False
    identity = read_proc_identity(cand.pid, snapshot)
    if identity is None:
        return False
    command, _ppid, age = identity
    if not re.compile(cand.pattern).search(command):
        return False
    if command != cand.command:
        return False
    live_lstart = read_proc_lstart(cand.pid, snapshot)
    if not live_lstart or live_lstart != cand.lstart:
        return False
    # A reused pid is a fresh process -> strictly younger than our snapshot.
    if age < cand.age_seconds:
        return False
    return True


def reap_one(
    cand: Candidate, grace_seconds: float, snapshot: Optional[dict[int, Proc]]
) -> tuple[bool, str]:
    """SIGTERM -> grace -> SIGKILL with start-time-anchored PID-reuse
    revalidation before EVERY signal. ESRCH is success/no-op; an identity-
    changed pid is skipped; a permission error is reported (non-fatal)."""
    if not still_killable(cand, snapshot):
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

    if not still_killable(cand, snapshot):
        return True, "terminated"
    try:
        os.kill(cand.pid, signal.SIGKILL)
    except ProcessLookupError:
        return True, "terminated"
    except PermissionError as exc:
        return False, f"permission-denied: {exc}"
    return True, "killed"


def _report(candidates: list[Candidate], reaped: bool) -> dict:
    by_class: dict[str, int] = {}
    rss_total = 0
    for cand in candidates:
        by_class[cand.klass] = by_class.get(cand.klass, 0) + 1
        rss_total += cand.rss_kb
    return {
        "schema": "codex-app-server-reaper/v1",
        "dry_run": not reaped,
        "reaped": reaped,
        "counts": {"total": len(candidates), "by_class": by_class},
        "reclaimable_rss_kb": rss_total,
        "candidates": [
            {
                "pid": cand.pid, "ppid": cand.ppid, "class": cand.klass,
                "age_seconds": cand.age_seconds, "rss_kb": cand.rss_kb,
                "cwd": cand.cwd, "reason": cand.reason, "result": cand.result,
            }
            for cand in candidates
        ],
    }


def _human_summary(report: dict) -> str:
    lines: list[str] = []
    total = report["counts"]["total"]
    mode = "reap" if report["reaped"] else "dry-run"
    lines.append(
        f"[codex-app-server-reaper] {mode}: {total} orphan(s), "
        f"~{report['reclaimable_rss_kb']} KB reclaimable"
    )
    for klass, count in sorted(report["counts"]["by_class"].items()):
        lines.append(f"  - {klass}: {count}")
    for cand in report["candidates"]:
        result = f" -> {cand['result']}" if cand["result"] else ""
        lines.append(
            f"  pid={cand['pid']} ppid={cand['ppid']} class={cand['class']} "
            f"age={cand['age_seconds']}s rss={cand['rss_kb']}KB{result}"
        )
    return "\n".join(lines)


def _platform_skip(mode: str) -> bool:
    """True when this host is not in scope (the leak is launchd-reparenting,
    macOS only)."""
    if mode == "any":
        return False
    is_macos = platform.system() == "Darwin"
    return not is_macos


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    for name in ("scan", "reap"):
        p = sub.add_parser(name)
        p.add_argument("--min-age-seconds", type=int, default=21600,
                       help="orphan-broker age floor (default 21600 = 6h)")
        p.add_argument("--grace-seconds", type=float, default=5.0,
                       help="SIGTERM grace before SIGKILL (reap; default 5.0)")
        p.add_argument("--protect-root-pid", type=int, action="append",
                       default=[], help="live codex pane pid (repeatable)")
        p.add_argument("--protect-pid", type=int, action="append",
                       default=[], help="explicit pid to spare (repeatable)")
        p.add_argument("--protect-cwd", action="append", default=[],
                       help="live codex agent workdir (repeatable)")
        p.add_argument("--platform", choices=("auto", "macos", "any"),
                       default="auto", help="platform guard (default auto)")
        p.add_argument("--ps-snapshot", default="",
                       help="TEST SEAM: read ps table from FILE")
        p.add_argument("--json", action="store_true", help="emit JSON report")
    args = parser.parse_args(argv)

    reaped = args.mode == "reap"

    if _platform_skip(args.platform):
        report = _report([], reaped=reaped)
        report["skipped"] = "platform-not-macos"
        if args.json:
            print(json.dumps(report))
        else:
            print("[codex-app-server-reaper] skipped: non-macOS host")
        return 0

    snapshot_path = args.ps_snapshot or None
    processes = load_processes(snapshot_path)
    snapshot = processes if snapshot_path else None

    candidates = classify_orphans(
        processes, args.min_age_seconds,
        args.protect_root_pid, args.protect_pid, args.protect_cwd,
    )

    had_failure = False
    if reaped and candidates:
        for cand in candidates:
            cand.lstart = read_proc_lstart(cand.pid, snapshot)
        for cand in candidates:
            ok, result = reap_one(cand, args.grace_seconds, snapshot)
            cand.result = result
            if not ok:
                had_failure = True

    report = _report(candidates, reaped=reaped)
    if args.json:
        print(json.dumps(report))
    else:
        print(_human_summary(report))

    return 1 if had_failure else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
