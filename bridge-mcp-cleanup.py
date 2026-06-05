#!/usr/bin/env python3
"""Detect and optionally kill orphaned MCP server processes.

The detector is intentionally conservative. It only treats a matching MCP
process as orphaned when its immediate parent is init/launchd, or when its
parent is another matching MCP process whose chain is already orphaned.
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
from dataclasses import dataclass
from typing import Iterable


# Incident #8807 P0b — provenance rules for every DEFAULT_PATTERN:
#   * Each pattern MUST be specific to an Agent Bridge MCP server identity —
#     a plugin npm/bun package name OR a bridge plugin-cache PATH. A bare
#     interpreter name (`node`, `bun`, `mcp-server`) is FORBIDDEN: this host
#     runs same-uid non-bridge processes that share interpreters, and
#     `mcp-server-darwin-arm64` on this fleet is Pencil.app (lethal
#     collateral if matched). When adding a signature, derive it from live
#     `ps -axo command=` provenance for the actual bridge MCP, not a guess.
#   * codex orphans are deliberately NOT reaped here (see incident notes):
#     `codex resume <hash>` is a LIVE agent pair and must never be killed,
#     and the disposable `codex exec --ephemeral` workers are a smaller
#     multiplier than the MCP fleet — codex reaping is deferred to a
#     follow-up with its own exact signature + negative control.
DEFAULT_PATTERNS = [
    r"npm(\s+exec)?\s+@upstash/context7-mcp",
    r"npm(\s+exec)?\s+@playwright/mcp",
    r"npm(\s+exec)?.*firebase-tools.*mcp",
    r"\bnode\b.*context7.*mcp",
    r"\bnode\b.*playwright.*mcp",
    r"\bnode\b.*firebase.*mcp",
    # Incident #8807 P0b (r2): Shopify dev MCP. Three forms, all anchored to
    # bridge/npx provenance so an unrelated same-uid `node` never matches:
    #   - `npm exec @shopify/dev-mcp` (launcher) and `node …/@shopify/dev-mcp/…`
    #     (scoped-package path) are inherently scoped by the package name.
    #   - the bare-basename `shopify-dev-mcp` form (live:
    #     `node …/.npm/_npx/<hash>/node_modules/.bin/shopify-dev-mcp`) is
    #     anchored on `node_modules/` so a developer's own
    #     `/tmp/.../shopify-dev-mcp` script is NOT reaped (codex r2).
    r"npm(\s+exec)?\s+@shopify/dev-mcp",
    r"\bnode\b.*@shopify/dev-mcp",
    r"\bnode\b.*node_modules/.*shopify-dev-mcp",
    # Incident #8807 P0b (r2): cosmax-crm MCP stdio proxy. Anchored on the
    # bridge plugin-cache provenance (live:
    # `node …/.claude/plugins/cache/cosmax-marketplace/cosmax-crm/<ver>/
    # scripts/crm-mcp-proxy.mjs`) — the prior `\bnode\b.*crm-mcp-proxy\.mjs`
    # was too broad and would have matched an unrelated same-uid
    # `node /tmp/x/crm-mcp-proxy.mjs` (codex r1 CRITICAL). r2 (codex): anchor on
    # the `/cache/` segment so a user's project-local `.claude/plugins/local/...`
    # dev tree is NOT reaped either.
    r"\.claude/plugins/cache/.*crm-mcp-proxy\.mjs",
    # Issue #223 + Incident #8807 P0b: bun plugin roots accumulate as PID-1
    # orphans across agent restarts (shared-mode + tmux-kill-session +
    # daemon reconcile all leave them reparented). The original
    # `\bbun\b.*server\.ts` was too broad — it matched an unrelated same-uid
    # `bun … server.ts` (a developer's own project). Anchor the server.ts
    # match on the bridge plugin-cache path so only Agent Bridge plugin
    # servers qualify; the parent `bun run --cwd .../plugins/<kind>` chain
    # patterns below keep is_orphan_candidate()'s parent-match happy.
    r"\bbun\b.*(?:\.agent-bridge/plugins/|/claude-plugins-official/).*server\.ts",
    r"\bbun\s+run\s+--cwd\s+.+?\.agent-bridge/plugins/",
    r"\bbun\s+run\s+--cwd\s+.+?/claude-plugins-official/",
]


# Incident #9770 Track 2 — codex app-server / Pencil MCP teardown leak.
#
# These patterns are used ONLY by the `subtree` subcommand (surgical
# per-session reap rooted at a known tmux pane PID). They are deliberately
# NOT part of DEFAULT_PATTERNS: the global orphan path (scan/cleanup) must
# stay PPID-orphan + DEFAULT_PATTERNS only, so a live roster `codex resume`
# (a descendant of its OWN live pane) is never a global-cleanup candidate.
#
# In `subtree` mode the allowlist is a WITHIN-SUBTREE filter, never a global
# match: the candidate set is already constrained to descendants of the
# torn-down session's pane PID, so matching `codex` here can only ever reach
# the codex the torn-down session itself spawned. A second live roster codex,
# the operator's interactive codex, and a non-codex child the user opened in
# the same pane are all excluded by construction (different pane subtree) or
# by name (the same-pane non-codex child).
#
# Provenance (live ps -axo command= on the Darwin leak host):
#   - `codex` / `codex resume <hash>` / `codex exec ...`  (the CLI itself)
#   - `codex app-server`                                  (the leaked child)
#   - `.../Pencil.app/.../mcp-server-darwin-arm64 ...`    (Pencil MCP grandchild)
SUBTREE_ALLOWLIST_PATTERNS = [
    r"(?:^|/)codex(?:\s|$)",
    r"(?:^|/)codex\s+app-server\b",
    r"\bmcp-server-darwin-arm64\b",
]


@dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    age_seconds: int
    rss_kb: int
    command: str


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
            hours, minutes, seconds = [int(part) for part in parts]
        elif len(parts) == 2:
            hours = 0
            minutes, seconds = [int(part) for part in parts]
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
        processes[pid] = Proc(pid=pid, ppid=ppid, age_seconds=age, rss_kb=rss, command=parts[4])
    return processes


def compile_patterns(patterns: Iterable[str]) -> list[re.Pattern[str]]:
    compiled = []
    for pattern in patterns:
        pattern = pattern.strip()
        if pattern:
            compiled.append(re.compile(pattern))
    return compiled


def matched_pattern(proc: Proc, patterns: list[re.Pattern[str]]) -> str:
    if proc.pid == os.getpid():
        return ""
    if "bridge-mcp-cleanup.py" in proc.command:
        return ""
    for pattern in patterns:
        if pattern.search(proc.command):
            return pattern.pattern
    return ""


def is_orphan_candidate(
    proc: Proc,
    processes: dict[int, Proc],
    matches: dict[int, str],
    min_age: int,
    seen: set[int] | None = None,
) -> bool:
    if proc.age_seconds < min_age:
        return False
    if not matches.get(proc.pid):
        return False
    if proc.ppid in {0, 1}:
        return True
    parent = processes.get(proc.ppid)
    if parent is None:
        return True
    if not matches.get(parent.pid):
        return False
    if seen is None:
        seen = set()
    if proc.pid in seen:
        return False
    seen.add(proc.pid)
    return is_orphan_candidate(parent, processes, matches, min_age, seen)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


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
            # Non-zero exit on the first (etimes) form may mean "no such
            # process" OR "unsupported field"; try the etime fallback before
            # concluding the process is gone.
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


def still_killable(
    pid: int,
    expected_command: str,
    expected_pattern: re.Pattern[str],
    expected_ppid: int,
    min_observed_age: int,
) -> bool:
    """PID-reuse guard: confirm the pid is still the same orphan we classified.

    Requires that the live process at `pid` (a) still exists, (b) still
    matches the same pattern, (c) has the same parent (so the orphan chain is
    unchanged), and (d) is at least as old as when we first saw it (a reused
    pid would be YOUNGER). Any mismatch → refuse to signal it.
    """
    identity = read_proc_identity(pid)
    if identity is None:
        return False
    command, ppid, age = identity
    if not expected_pattern.search(command):
        return False
    if command != expected_command:
        return False
    if ppid != expected_ppid:
        return False
    # A reused pid is a fresh process → strictly younger than our snapshot.
    if age < min_observed_age:
        return False
    return True


def kill_pid(
    pid: int,
    grace_seconds: float,
    expected_command: str,
    expected_pattern: re.Pattern[str],
    expected_ppid: int,
    min_observed_age: int,
) -> tuple[bool, str]:
    # PID-reuse revalidation IMMEDIATELY before SIGTERM.
    if not still_killable(pid, expected_command, expected_pattern, expected_ppid, min_observed_age):
        return True, "skipped-pid-reuse"
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True, "already-gone"
    except PermissionError as exc:
        return False, str(exc)

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not alive(pid):
            return True, "terminated"
        time.sleep(0.05)

    # PID-reuse revalidation AGAIN before the escalation to SIGKILL — the pid
    # may have exited and been recycled during the grace window.
    if not still_killable(pid, expected_command, expected_pattern, expected_ppid, min_observed_age):
        return True, "skipped-pid-reuse-pre-kill"
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return True, "terminated"
    except PermissionError as exc:
        return False, str(exc)
    return True, "killed"


def still_killable_subtree(
    pid: int,
    expected_command: str,
    expected_pattern: re.Pattern[str],
    min_observed_age: int,
) -> bool:
    """PID-reuse guard for the SUBTREE reap path (#9770 Track 2).

    Identical to `still_killable` EXCEPT it deliberately drops the parent-PID
    constraint. On the daemon idle-kill path we capture the codex/app-server/MCP
    descendants of a pane PID and reap them AFTER `tmux kill-session` — which
    tears the pane down, so the captured codex REPARENTS to init/launchd. That
    reparent is the expected, benign signal of the teardown we initiated, not a
    PID-reuse event, so a ppid check would wrongly refuse to reap the very leak
    we are trying to close. PID reuse is still defended by the triple (a) the
    pid still exists, (b) it still matches the within-subtree allowlist, (c) its
    command string is byte-identical to the captured command, and (d) it is no
    younger than when captured (a recycled pid is a fresh, younger process).
    """
    identity = read_proc_identity(pid)
    if identity is None:
        return False
    command, _ppid, age = identity
    if not expected_pattern.search(command):
        return False
    if command != expected_command:
        return False
    if age < min_observed_age:
        return False
    return True


def kill_pid_subtree(
    pid: int,
    grace_seconds: float,
    expected_command: str,
    expected_pattern: re.Pattern[str],
    min_observed_age: int,
) -> tuple[bool, str]:
    """SIGTERM→grace→SIGKILL with ppid-agnostic PID-reuse revalidation before
    every signal. Fail-soft + idempotent: ESRCH is success/no-op; a vanished or
    identity-changed pid is skipped rather than signalled."""
    # PID-reuse revalidation IMMEDIATELY before SIGTERM.
    if not still_killable_subtree(pid, expected_command, expected_pattern, min_observed_age):
        return True, "skipped-pid-reuse"
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True, "already-gone"
    except PermissionError as exc:
        return False, str(exc)

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not alive(pid):
            return True, "terminated"
        time.sleep(0.05)

    # Revalidate again before escalating to SIGKILL — the pid may have exited
    # (and possibly been recycled) during the grace window. A process that has
    # become a zombie (SIGTERM took effect, parent has not reaped it yet) no
    # longer matches the captured command, so this correctly reports it as
    # already-terminated rather than re-signalling a recycled pid.
    if not still_killable_subtree(pid, expected_command, expected_pattern, min_observed_age):
        return True, "terminated"
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return True, "terminated"
    except PermissionError as exc:
        return False, str(exc)
    return True, "killed"


def descendants_of(root_pid: int, processes: dict[int, Proc], max_nodes: int = 4096) -> list[Proc]:
    """BFS the live process map for every descendant of `root_pid`.

    The root itself is NOT included — we only ever reap the codex/app-server/
    MCP children the pane spawned, never the pane's shell/login process. Bounded
    by `max_nodes` so a pathological cycle (which `seen` already prevents) or a
    huge process table can never spin. Built from a single ps snapshot so the
    parent→child edges are internally consistent.
    """
    children: dict[int, list[int]] = {}
    for proc in processes.values():
        children.setdefault(proc.ppid, []).append(proc.pid)

    out: list[Proc] = []
    seen: set[int] = {root_pid}
    queue: list[int] = list(children.get(root_pid, []))
    while queue and len(seen) < max_nodes:
        pid = queue.pop(0)
        if pid in seen:
            continue
        seen.add(pid)
        proc = processes.get(pid)
        if proc is None:
            continue
        out.append(proc)
        queue.extend(children.get(pid, []))
    return out


def _subtree_matched_pattern(proc: Proc, patterns: list[re.Pattern[str]]) -> str:
    if proc.pid == os.getpid():
        return ""
    if "bridge-mcp-cleanup.py" in proc.command:
        return ""
    for pattern in patterns:
        if pattern.search(proc.command):
            return pattern.pattern
    return ""


def capture_subtree(root_pid: int, patterns: list[re.Pattern[str]]) -> list[dict[str, object]]:
    """Resolve the codex/app-server/MCP descendants of `root_pid` (the torn-down
    session's tmux pane PID), with per-PID metadata for later revalidation.

    Returns a leaf-to-root–ordered list (highest pid first as a cheap proxy) of
    {pid, ppid, age_seconds, rss_kb, pattern, command}. Only processes whose
    command matches the within-subtree allowlist are captured — a non-codex
    child the user opened in the same pane is intentionally left out.
    """
    processes = load_processes()
    captured: list[dict[str, object]] = []
    for proc in descendants_of(root_pid, processes):
        pattern = _subtree_matched_pattern(proc, patterns)
        if not pattern:
            continue
        captured.append(
            {
                "pid": proc.pid,
                "ppid": proc.ppid,
                "age_seconds": proc.age_seconds,
                "rss_kb": proc.rss_kb,
                "pattern": pattern,
                "command": proc.command,
            }
        )
    # Reap children before their parents: a parent that re-spawns a child
    # mid-reap is defended by per-signal revalidation, but leaf-first keeps the
    # common case clean. Highest pid first is a cheap, stable leaf-to-root proxy.
    captured.sort(key=lambda item: int(item["pid"]), reverse=True)
    return captured


def reap_captured(
    captured: list[dict[str, object]],
    patterns: list[re.Pattern[str]],
    grace_seconds: float,
) -> dict[str, list[dict[str, object]]]:
    """Reap a previously-captured subtree PID set, revalidating each PID against
    its captured metadata immediately before EVERY signal (PID-reuse defense).

    Fail-soft and idempotent: a vanished PID is success/no-op (ESRCH), a PID
    whose identity changed since capture is skipped, and a permission failure is
    recorded as an error without raising.
    """
    pattern_by_str = {pattern.pattern: pattern for pattern in patterns}
    killed: list[dict[str, object]] = []
    skipped: list[dict[str, object]] = []
    errors: list[dict[str, object]] = []
    self_pid = os.getpid()
    parent_pid = os.getppid()
    for item in captured:
        try:
            pid = int(item["pid"])
        except (KeyError, ValueError, TypeError):
            continue
        enriched = dict(item)
        # Never signal self or our own parent — a captured set should never
        # contain them, but this is the cheap structural guard the reviewer
        # asked for ("PID is not self/parent").
        if pid in (self_pid, parent_pid):
            enriched["kill_status"] = "skipped-self-or-parent"
            skipped.append(enriched)
            continue
        expected_pattern = pattern_by_str.get(str(item.get("pattern")))
        if expected_pattern is None:
            # Defensive: never signal a pid we cannot revalidate against a
            # within-subtree allowlist pattern.
            enriched["kill_status"] = "skipped-no-pattern"
            skipped.append(enriched)
            continue
        # ppid-agnostic revalidation: the captured codex reparents to init when
        # we tear its pane down on the daemon path, which is expected — see
        # kill_pid_subtree / still_killable_subtree.
        ok, status = kill_pid_subtree(
            pid,
            grace_seconds,
            str(item.get("command", "")),
            expected_pattern,
            int(item.get("age_seconds", 0)),
        )
        enriched["kill_status"] = status
        if status.startswith("skipped-"):
            skipped.append(enriched)
        elif ok:
            killed.append(enriched)
        else:
            errors.append(enriched)
    return {"killed": killed, "skipped": skipped, "errors": errors}


def build_subtree_report(args: argparse.Namespace) -> dict[str, object]:
    """`subtree` subcommand: surgical per-session reap of the codex/app-server/
    MCP descendants of a known tmux pane PID.

    Three shapes, all scoped to ONE torn-down session's pane subtree:
      * --capture-only --root-pid N   → emit the captured PID+metadata set
        (used on the daemon idle-kill path BEFORE `tmux kill-session`).
      * --pids-json '[...]'           → reap a previously-captured set (used
        AFTER the kill, so we never rediscover globally once the pane is gone).
      * --root-pid N (no flags)       → capture-then-reap in one shot (the
        clean-exit / kill-agent-session path, where the pane is still alive).
    """
    patterns = compile_patterns(args.pattern or SUBTREE_ALLOWLIST_PATTERNS)

    if args.pids_json is not None:
        try:
            captured = json.loads(args.pids_json)
        except (ValueError, TypeError):
            captured = []
        if not isinstance(captured, list):
            captured = []
        root_pid = int(args.root_pid) if args.root_pid is not None else -1
    else:
        if args.root_pid is None:
            return {
                "mode": "subtree",
                "root_pid": None,
                "captured_count": 0,
                "captured": [],
                "killed_count": 0,
                "skipped_count": 0,
                "killed": [],
                "skipped": [],
                "errors": [],
                "error": "no-root-pid",
            }
        root_pid = int(args.root_pid)
        captured = capture_subtree(root_pid, patterns)

    if args.capture_only:
        return {
            "mode": "subtree-capture",
            "root_pid": root_pid,
            "captured_count": len(captured),
            "captured": captured,
        }

    result = reap_captured(captured, patterns, args.grace_seconds)
    killed_rss_kb = sum(int(item.get("rss_kb") or 0) for item in result["killed"])
    return {
        "mode": "subtree",
        "trigger": args.trigger,
        "root_pid": root_pid,
        "captured_count": len(captured),
        "killed_count": len(result["killed"]),
        "skipped_count": len(result["skipped"]),
        "error_count": len(result["errors"]),
        "freed_mb_estimate": round(killed_rss_kb / 1024, 1),
        "captured": captured,
        "killed": result["killed"],
        "skipped": result["skipped"],
        "errors": result["errors"],
    }


def extract_captured_pids(report_text: str) -> str:
    """Parse a `subtree --capture-only` JSON report and re-emit its `captured`
    array as a compact JSON list (for `--pids-json`). Empty string on any
    parse failure so the bash caller can no-op without hand-rolling JSON."""
    try:
        report = json.loads(report_text)
    except (ValueError, TypeError):
        return ""
    if not isinstance(report, dict):
        return ""
    captured = report.get("captured")
    if not isinstance(captured, list):
        return ""
    return json.dumps(captured, ensure_ascii=False)


def subtree_audit_summary(report_text: str) -> str:
    """Render a redacted one-line `key=value` summary of a subtree reap report
    for the audit log. ONLY counts + the freed-MB estimate leave the process —
    never the captured command strings (which can carry cwd/paths). Returns ''
    when there was nothing worth recording (no captures and no skips/errors)."""
    try:
        report = json.loads(report_text)
    except (ValueError, TypeError):
        return ""
    if not isinstance(report, dict):
        return ""
    captured = int(report.get("captured_count") or 0)
    killed = int(report.get("killed_count") or 0)
    skipped = int(report.get("skipped_count") or 0)
    errors = int(report.get("error_count") or 0)
    if captured == 0 and killed == 0 and skipped == 0 and errors == 0:
        return ""
    freed = report.get("freed_mb_estimate") or 0
    return (
        f"captured={captured} killed={killed} "
        f"skipped={skipped} errors={errors} freed_mb={freed}"
    )


def build_report(args: argparse.Namespace) -> dict[str, object]:
    patterns = compile_patterns(args.pattern or DEFAULT_PATTERNS)
    processes = load_processes()
    matches = {pid: matched_pattern(proc, patterns) for pid, proc in processes.items()}
    matched = [
        {
            "pid": proc.pid,
            "ppid": proc.ppid,
            "age_seconds": proc.age_seconds,
            "rss_kb": proc.rss_kb,
            "pattern": matches[proc.pid],
            "command": proc.command,
        }
        for proc in processes.values()
        if matches.get(proc.pid)
    ]
    orphans = [
        item
        for item in matched
        if is_orphan_candidate(processes[int(item["pid"])], processes, matches, args.min_age)
    ]
    # Kill children before their orphan MCP parents.
    orphans.sort(key=lambda item: int(item["pid"]), reverse=True)

    # Map each pattern string back to its compiled object so the kill path can
    # re-match the (possibly re-read) command during PID-reuse revalidation.
    pattern_by_str = {pattern.pattern: pattern for pattern in patterns}

    killed = []
    errors = []
    skipped = []
    if args.kill:
        for item in orphans:
            pid = int(item["pid"])
            expected_pattern = pattern_by_str.get(str(item["pattern"]))
            if expected_pattern is None:
                # Should not happen (item["pattern"] came from this set), but
                # never signal a pid we cannot revalidate against a pattern.
                enriched = dict(item)
                enriched["kill_status"] = "skipped-no-pattern"
                skipped.append(enriched)
                continue
            ok, status = kill_pid(
                pid,
                args.grace_seconds,
                str(item["command"]),
                expected_pattern,
                int(item["ppid"]),
                int(item["age_seconds"]),
            )
            enriched = dict(item)
            enriched["kill_status"] = status
            if status.startswith("skipped-"):
                skipped.append(enriched)
            elif ok:
                killed.append(enriched)
            else:
                errors.append(enriched)

    killed_rss_kb = sum(int(item.get("rss_kb") or 0) for item in killed)
    return {
        "trigger": args.trigger,
        "dry_run": not args.kill,
        "min_age_seconds": args.min_age,
        "matched_count": len(matched),
        "orphan_count": len(orphans),
        "killed_count": len(killed),
        "skipped_count": len(skipped),
        "freed_mb_estimate": round(killed_rss_kb / 1024, 1),
        "matched": matched,
        "orphans": orphans,
        "killed": killed,
        "skipped": skipped,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-mcp-cleanup.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("scan", "cleanup"):
        child = subparsers.add_parser(name)
        child.add_argument("--json", action="store_true")
        child.add_argument("--min-age", type=int, default=300)
        child.add_argument("--pattern", action="append")
        child.add_argument("--trigger", default=name)
        child.add_argument("--grace-seconds", type=float, default=1.0)
        child.add_argument("--kill", action="store_true")
        child.add_argument("--dry-run", action="store_true")

    # Incident #9770 Track 2 — surgical per-session subtree reap.
    subtree = subparsers.add_parser("subtree")
    subtree.add_argument("--json", action="store_true")
    subtree.add_argument(
        "--root-pid",
        type=int,
        default=None,
        help="tmux pane PID of the torn-down session (subtree root)",
    )
    subtree.add_argument(
        "--pids-json",
        default=None,
        help="reap a previously-captured PID+metadata set (JSON list)",
    )
    subtree.add_argument(
        "--capture-only",
        action="store_true",
        help="emit the captured set without reaping (daemon pre-kill capture)",
    )
    subtree.add_argument("--pattern", action="append")
    subtree.add_argument("--trigger", default="subtree")
    subtree.add_argument("--grace-seconds", type=float, default=1.0)

    # Shell-side glue for the subtree reap: parse the captured array out of a
    # capture-only report (so bash never hand-rolls JSON), and render a redacted
    # one-line audit summary. Kept here (not a separate helper) so the whole
    # subtree contract lives in one file.
    extract = subparsers.add_parser("subtree-extract-captured")
    extract.add_argument("--report", required=True)
    audit = subparsers.add_parser("subtree-audit-summary")
    audit.add_argument("--report", required=True)

    args = parser.parse_args()

    if args.command == "subtree":
        report = build_subtree_report(args)
        if args.json:
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            print(f"mode: {report.get('mode')}")
            print(f"root_pid: {report.get('root_pid')}")
            print(f"captured: {report.get('captured_count', 0)}")
            print(f"killed: {report.get('killed_count', 0)}")
            print(f"skipped: {report.get('skipped_count', 0)}")
        return 0

    if args.command == "subtree-extract-captured":
        print(extract_captured_pids(args.report))
        return 0

    if args.command == "subtree-audit-summary":
        print(subtree_audit_summary(args.report))
        return 0

    if args.command == "scan":
        args.kill = False
    elif args.dry_run:
        args.kill = False

    report = build_report(args)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"matched: {report['matched_count']}")
        print(f"orphans: {report['orphan_count']}")
        print(f"killed: {report['killed_count']}")
        print(f"freed_mb_estimate: {report['freed_mb_estimate']}")
        for item in report["orphans"]:
            print(f"- pid={item['pid']} ppid={item['ppid']} age={item['age_seconds']} pattern={item['pattern']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
