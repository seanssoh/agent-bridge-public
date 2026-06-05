#!/usr/bin/env python3
"""Helper for scripts/smoke/9770-codex-teardown-reap.sh (incident #9770 Track 2).

Drives the surgical per-session codex-subtree reap in bridge-mcp-cleanup.py
against lightweight stand-in process trees that MIMIC the codex / codex
app-server / Pencil mcp-server-darwin-arm64 command names and the pane→child
parentage — without ever spawning a real codex. Invoked file-as-argv (no
heredoc-stdin — lint-heredoc-ban C3 ban; see KNOWN_ISSUES.md §26):

    9770-...-helper.py reap-survival     <reaper.py>   # (a)(c)(d)(e)
    9770-...-helper.py capture-then-reap <reaper.py>   # (b) daemon ordering
    9770-...-helper.py no-pane-skip      <reaper.py>   # (f)
    9770-...-helper.py idempotent        <reaper.py>   # (g)

Each subcommand exits non-zero (message on stderr) on failure so the calling
smoke can `|| smoke_fail`.

Stand-in shape: a `/bin/sh` "pane root" that exec-renames /bin/sleep children
to the codex/app-server/MCP names (and one unrelated non-codex child), then
blocks. We treat the `/bin/sh` PID as the tmux pane PID and pass it as
--root-pid. A SECOND such pane root models a live roster codex in a different
pane; a detached `setsid` codex-named sleep models the operator's non-bridge
codex outside any pane.
"""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def _load_module(reaper_path: str):
    spec = importlib.util.spec_from_file_location("bridge_mcp_cleanup", reaper_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


# --- stand-in process-tree primitives ------------------------------------

# Each pane is a /bin/sh that renames sleep children via `exec -a`. We capture
# the child PIDs by having the shell print them, then read them back.
_PANE_SH = (
    'exec -a "codex app-server" /bin/sleep 600 & echo "codex=$!"; '
    'exec -a "mcp-server-darwin-arm64 --stdio" /bin/sleep 600 & echo "mcp=$!"; '
    'exec -a "some-editor --file x" /bin/sleep 600 & echo "editor=$!"; '
    'echo "root=$$"; '
    "sleep 600"
)


class Pane:
    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            ["/bin/sh", "-c", _PANE_SH],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self.pids: dict[str, int] = {}
        # Read the four announced PIDs (codex / mcp / editor / root).
        assert self.proc.stdout is not None
        for _ in range(4):
            line = self.proc.stdout.readline().strip()
            if not line or "=" not in line:
                continue
            key, val = line.split("=", 1)
            try:
                self.pids[key] = int(val)
            except ValueError:
                pass

    @property
    def root(self) -> int:
        # The /bin/sh root PID == the Popen child PID.
        return self.proc.pid

    def teardown(self) -> None:
        for pid in list(self.pids.values()) + [self.proc.pid]:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        try:
            self.proc.wait(timeout=2)
        except Exception:
            pass


def _dead(pid: int) -> bool:
    """True iff pid is gone OR a zombie (<defunct>) — both mean the process was
    successfully terminated. A non-reaping stand-in parent leaves a zombie that
    `os.kill(pid,0)` still reports as alive, so we must check the ps state."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    try:
        out = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout.strip()
    except OSError:
        return False
    if not out:
        return True
    return out.startswith("Z")


def _alive_running(pid: int) -> bool:
    return not _dead(pid)


def _wait_started(pids: list[int], timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if all(_alive_running(p) for p in pids):
            return True
        time.sleep(0.05)
    return False


def _reap(mod, root_pid: int) -> dict:
    """Invoke the reaper's one-shot subtree reap (capture+reap) in-process via the
    module API, mirroring `subtree --root-pid N`."""
    args = type("A", (), {})()
    args.pattern = None
    args.root_pid = root_pid
    args.pids_json = None
    args.capture_only = False
    args.trigger = "smoke"
    args.grace_seconds = 0.4
    return mod.build_subtree_report(args)


# --- subcommands ----------------------------------------------------------


def cmd_reap_survival(reaper_path: str) -> int:
    """(a) clean-exit reaps A's codex+MCP subtree; (c) a 2nd live roster codex in
    a DIFFERENT pane survives; (d) a non-bridge codex outside any pane survives;
    (e) a same-pane non-codex child survives (name-scoped within-subtree filter).
    """
    mod = _load_module(reaper_path)
    pane_a = Pane()
    pane_b = Pane()
    # Operator-style non-bridge codex outside ANY pane (detached new session).
    nb = subprocess.Popen(
        ["codex", "600"],
        executable="/bin/sleep",
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        need = [
            pane_a.pids["codex"], pane_a.pids["mcp"], pane_a.pids["editor"],
            pane_b.pids["codex"], pane_b.pids["mcp"], nb.pid,
        ]
        if not _wait_started(need):
            print("stand-in processes did not all start", file=sys.stderr)
            return 1

        report = _reap(mod, pane_a.root)

        # (a) pane A's codex + MCP captured (2) and reaped; editor NOT captured.
        if report["captured_count"] != 2:
            print(f"expected 2 captured (codex+mcp), got {report['captured_count']}: {report.get('captured')}", file=sys.stderr)
            return 1
        captured_cmds = " ".join(str(c.get("command", "")) for c in report["captured"])
        if "some-editor" in captured_cmds:
            print(f"(e) same-pane non-codex editor was captured — within-subtree filter not name-scoped: {captured_cmds}", file=sys.stderr)
            return 1

        time.sleep(0.5)
        # (a) pane A codex + MCP dead.
        if not _dead(pane_a.pids["codex"]):
            print("(a) pane A codex NOT reaped", file=sys.stderr)
            return 1
        if not _dead(pane_a.pids["mcp"]):
            print("(a) pane A MCP NOT reaped", file=sys.stderr)
            return 1
        # (e) pane A's non-codex editor SURVIVES.
        if not _alive_running(pane_a.pids["editor"]):
            print("(e) pane A same-pane non-codex editor was killed (must survive)", file=sys.stderr)
            return 1
        # (c) pane B codex + MCP SURVIVE — the #1 invariant.
        if not _alive_running(pane_b.pids["codex"]):
            print("(c) #1 INVARIANT VIOLATION: pane B live codex was killed by pane A teardown", file=sys.stderr)
            return 1
        if not _alive_running(pane_b.pids["mcp"]):
            print("(c) #1 INVARIANT VIOLATION: pane B MCP was killed by pane A teardown", file=sys.stderr)
            return 1
        # (d) non-bridge codex SURVIVES.
        if not _alive_running(nb.pid):
            print("(d) operator non-bridge codex outside any pane was killed (must survive)", file=sys.stderr)
            return 1

        print("[ok] (a) A's codex+MCP reaped; (c) pane B codex survives; (d) non-bridge codex survives; (e) same-pane editor survives")
        return 0
    finally:
        pane_a.teardown()
        pane_b.teardown()
        try:
            nb.kill()
            nb.wait(timeout=2)
        except Exception:
            pass


def cmd_capture_then_reap(reaper_path: str) -> int:
    """(b) daemon idle-kill ordering: capture the subtree BEFORE the pane dies,
    then reap the captured set AFTER — and prove that rediscovery after the pane
    is gone would find nothing (so capture-before-kill is load-bearing)."""
    mod = _load_module(reaper_path)
    pane = Pane()
    pane_b = Pane()
    try:
        need = [pane.pids["codex"], pane.pids["mcp"], pane_b.pids["codex"]]
        if not _wait_started(need):
            print("stand-in processes did not start", file=sys.stderr)
            return 1

        # Capture BEFORE the kill (the pane root is still alive).
        cap_args = type("A", (), {})()
        cap_args.pattern = None
        cap_args.root_pid = pane.root
        cap_args.pids_json = None
        cap_args.capture_only = True
        cap_args.trigger = "smoke"
        cap_args.grace_seconds = 0.4
        cap_report = mod.build_subtree_report(cap_args)
        captured = cap_report["captured"]
        if len(captured) != 2:
            print(f"capture-before-kill expected 2, got {len(captured)}", file=sys.stderr)
            return 1

        # Kill the pane root (mimics `tmux kill-session`). The codex/mcp children
        # reparent away from the now-dead /bin/sh.
        os.kill(pane.root, signal.SIGKILL)
        try:
            pane.proc.wait(timeout=2)
        except Exception:
            pass
        time.sleep(0.3)

        # Rediscovery AFTER the pane is gone finds nothing under the (dead) root
        # — this is exactly why capture-before-kill is required.
        post_args = type("A", (), {})()
        post_args.pattern = None
        post_args.root_pid = pane.root
        post_args.pids_json = None
        post_args.capture_only = True
        post_args.trigger = "smoke"
        post_args.grace_seconds = 0.4
        post_report = mod.build_subtree_report(post_args)
        if post_report["captured_count"] != 0:
            print(f"post-kill rediscovery unexpectedly found {post_report['captured_count']} (pane root dead)", file=sys.stderr)
            return 1

        # Reap the PRE-captured set after the kill.
        reap_args = type("A", (), {})()
        reap_args.pattern = None
        reap_args.root_pid = pane.root
        reap_args.pids_json = json.dumps(captured)
        reap_args.capture_only = False
        reap_args.trigger = "smoke"
        reap_args.grace_seconds = 0.4
        reap_report = mod.build_subtree_report(reap_args)

        time.sleep(0.5)
        if not _dead(pane.pids["codex"]):
            print("(b) captured-before-kill codex NOT reaped after kill", file=sys.stderr)
            return 1
        if not _dead(pane.pids["mcp"]):
            print("(b) captured-before-kill MCP NOT reaped after kill", file=sys.stderr)
            return 1
        # #1 invariant still holds across the daemon path.
        if not _alive_running(pane_b.pids["codex"]):
            print("(b) #1 INVARIANT VIOLATION: pane B codex killed by daemon path", file=sys.stderr)
            return 1
        reaped = reap_report["killed_count"] + reap_report["skipped_count"]
        if reaped < 2:
            print(f"(b) reap report did not act on the 2 captured pids: {reap_report}", file=sys.stderr)
            return 1
        print("[ok] (b) captured-before-kill subtree reaped after kill; post-kill rediscovery empty; pane B survives")
        return 0
    finally:
        pane.teardown()
        pane_b.teardown()


def cmd_no_pane_skip(reaper_path: str) -> int:
    """(f) unresolvable pane → skip, no global sweep, no error. A negative
    root-pid never resolves to a real pane; the report must show 0 captured /
    0 killed and never touch unrelated codex processes."""
    mod = _load_module(reaper_path)
    # A live codex-named process that MUST NOT be touched by a no-pane reap.
    bystander = subprocess.Popen(
        ["codex app-server", "600"],
        executable="/bin/sleep",
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        if not _wait_started([bystander.pid]):
            print("bystander codex did not start", file=sys.stderr)
            return 1
        # root_pid=-1 models "pane PID unresolvable"; descendants_of finds none.
        report = _reap(mod, -1)
        if report["captured_count"] != 0 or report["killed_count"] != 0:
            print(f"(f) unresolvable-pane reap was not a no-op: {report}", file=sys.stderr)
            return 1
        time.sleep(0.3)
        if not _alive_running(bystander.pid):
            print("(f) unresolvable-pane reap KILLED an unrelated codex (global-sweep regression!)", file=sys.stderr)
            return 1
        print("[ok] (f) unresolvable pane → no-op, no global sweep, bystander codex survives")
        return 0
    finally:
        try:
            bystander.kill()
            bystander.wait(timeout=2)
        except Exception:
            pass


def cmd_idempotent(reaper_path: str) -> int:
    """(g) a 2nd reap pass over the same pane finds nothing / is ESRCH-clean."""
    mod = _load_module(reaper_path)
    pane = Pane()
    try:
        if not _wait_started([pane.pids["codex"], pane.pids["mcp"]]):
            print("stand-in processes did not start", file=sys.stderr)
            return 1
        first = _reap(mod, pane.root)
        if first["captured_count"] != 2:
            print(f"(g) first pass expected 2 captured, got {first['captured_count']}", file=sys.stderr)
            return 1
        time.sleep(0.5)
        # Second pass: children are dead/zombie; capture finds nothing, no error.
        second = _reap(mod, pane.root)
        if second["captured_count"] != 0:
            print(f"(g) 2nd pass should find nothing, found {second['captured_count']}: {second.get('captured')}", file=sys.stderr)
            return 1
        if second["killed_count"] != 0 or second.get("error_count", 0) != 0:
            print(f"(g) 2nd pass not clean: {second}", file=sys.stderr)
            return 1
        print("[ok] (g) idempotent — 2nd reap pass finds nothing, ESRCH-clean")
        return 0
    finally:
        pane.teardown()


def cmd_default_patterns_codex_free(reaper_path: str) -> int:
    """Assert DEFAULT_PATTERNS (the GLOBAL orphan path) still does NOT match
    codex / app-server / Pencil MCP — the codex allowlist lives only in the
    subtree path, so a live roster `codex resume` can never become a
    global-cleanup candidate."""
    src = Path(reaper_path).read_text(encoding="utf-8")
    tree = ast.parse(src)
    patterns: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "DEFAULT_PATTERNS":
                    patterns = [ast.literal_eval(elt) for elt in node.value.elts]
    if not patterns:
        print("could not extract DEFAULT_PATTERNS", file=sys.stderr)
        return 1
    joined = " ".join(patterns)
    for needle in ("codex", "app-server", "mcp-server-darwin-arm64"):
        if needle in joined:
            print(f"DEFAULT_PATTERNS now matches '{needle}' — global orphan path must stay codex-free", file=sys.stderr)
            return 1
    print("[ok] DEFAULT_PATTERNS stays codex/app-server/Pencil-MCP free")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: 9770-codex-teardown-reap-helper.py <subcommand> <reaper.py>", file=sys.stderr)
        return 2
    command, reaper = argv[1], argv[2]
    table = {
        "reap-survival": cmd_reap_survival,
        "capture-then-reap": cmd_capture_then_reap,
        "no-pane-skip": cmd_no_pane_skip,
        "idempotent": cmd_idempotent,
        "default-patterns-codex-free": cmd_default_patterns_codex_free,
    }
    fn = table.get(command)
    if fn is None:
        print(f"unknown subcommand: {command}", file=sys.stderr)
        return 2
    return fn(reaper)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
