#!/usr/bin/env python3
"""Helper for scripts/smoke/1567-codex-orphan-upgrade-reaper.sh (issue #1567).

Drives the REAL upgrade-time orphan detector/reaper
(lib/upgrade-helpers/codex-orphan-cleanup.py) against lightweight stand-in
process trees that MIMIC the leaked codex `app-server-broker.mjs` (+ child node
app-server) and stale `bridge-queue-gateway.py socket-server` command names and
the ppid==1 orphan parentage — WITHOUT ever spawning a real codex broker, a real
queue-gateway, or a real bridge install. Invoked file-as-argv (no heredoc-stdin
— lint-heredoc-ban C3 ban; see KNOWN_ISSUES.md §26):

    1567-...-helper.py dry-run-kills-nothing <cleanup.py>
    1567-...-helper.py reap-orphans-only     <cleanup.py>
    1567-...-helper.py queue-gateway-staleness <cleanup.py>

Each subcommand exits non-zero (message on stderr) on failure so the calling
smoke can `|| smoke_fail`.

Stand-in shape: every orphan is a /bin/sleep child that we (a) reparent to init
via a double-fork + setsid so its ppid becomes 1 (matching the broker-orphan
signature), and (b) exec-rename via the bash `exec -a` builtin so its `ps`
command matches the detector's patterns. The exact RSS does not matter; the
identity (command + ppid + start-time) is what the detector keys on. We resolve
bash explicitly (NOT /bin/sh, which is dash on Ubuntu and lacks `exec -a`).
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


def _load_module(cleanup_path: str):
    spec = importlib.util.spec_from_file_location("codex_orphan_cleanup", cleanup_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def _resolve_bash() -> str:
    found = shutil.which("bash")
    if found:
        return found
    for candidate in ("/bin/bash", "/usr/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"):
        if os.path.exists(candidate):
            return candidate
    return "bash"


_BASH_BIN = _resolve_bash()


def _spawn_reparented(argv0: str, lifetime: int = 60) -> int:
    """Spawn a /bin/sleep child renamed to `argv0` and reparented to init.

    Double-fork + setsid: the intermediate process exits immediately so the
    grandchild's ppid becomes 1 (init). Returns the grandchild PID (read back
    from a pipe). The grandchild execs `bash -c 'exec -a "<argv0>" sleep N'`.
    """
    r_fd, w_fd = os.pipe()
    body = f'exec -a "{argv0}" /bin/sleep {lifetime}'
    mid = os.fork()
    if mid == 0:
        # Intermediate child.
        os.close(r_fd)
        os.setsid()  # new session -> detaches; grandchild reparents to init.
        grand = os.fork()
        if grand == 0:
            # Grandchild: become the renamed sleeper.
            os.close(w_fd)
            os.execv(_BASH_BIN, [_BASH_BIN, "-c", body])
            os._exit(127)  # unreachable
        # Intermediate: report grandchild pid, then exit so grandchild orphans.
        os.write(w_fd, f"{grand}".encode())
        os.close(w_fd)
        os._exit(0)
    # Parent.
    os.close(w_fd)
    raw = b""
    while True:
        chunk = os.read(r_fd, 64)
        if not chunk:
            break
        raw += chunk
    os.close(r_fd)
    os.waitpid(mid, 0)  # reap the intermediate so it doesn't linger as zombie
    return int(raw.decode().strip())


def _wait_reparented(pid: int, timeout: float = 3.0) -> bool:
    """Wait until `pid` exists and its ppid is 1 (reparented to init)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ppid = _read_ppid(pid)
        if ppid == 1:
            return True
        time.sleep(0.05)
    return False


def _read_ppid(pid: int) -> int:
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "ppid="],
            check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout.strip()
        return int(out) if out else -1
    except (subprocess.CalledProcessError, ValueError):
        return -1


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _kill(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


def _gone_worktree() -> str:
    """A `.claude/worktrees/agent-*` path that does NOT exist on disk."""
    return "/tmp/agb-1567-smoke-gone-XXXXXX/.claude/worktrees/agent-deadbeef"


def _make_smoke_bridge_home_gone() -> str:
    """A /tmp/agb-smoke-* --bridge-home that does NOT exist."""
    return "/tmp/agb-smoke-1567-q-does-not-exist"


# --- subcommands ---------------------------------------------------------


def cmd_dry_run_kills_nothing(cleanup_path: str) -> int:
    """A scan (dry-run) must NEVER signal any stand-in orphan."""
    mod = _load_module(cleanup_path)
    broker_pid = _spawn_reparented(
        f"node /x/openai-codex/app-server-broker.mjs --cwd {_gone_worktree()}"
    )
    pids = [broker_pid]
    try:
        if not _wait_reparented(broker_pid):
            raise RuntimeError(f"broker stand-in {broker_pid} did not reparent to init")
        # Run the REAL detector in scan mode (min-age 0 so the fresh stand-in
        # qualifies). It must classify the orphan but kill nothing.
        procs = mod.load_processes()
        cands = mod.classify_orphans(procs, 0)
        matched = [c for c in cands if c.pid == broker_pid]
        if not matched:
            raise RuntimeError("scan did not detect the orphaned broker stand-in")
        if matched[0].klass != "codex-broker":
            raise RuntimeError(f"orphan misclassified: {matched[0].klass}")
        # scan mode never reaps — assert the process is still alive after.
        time.sleep(0.3)
        if not _alive(broker_pid):
            raise RuntimeError("DRY-RUN scan killed the orphan (must not!)")
        return 0
    finally:
        for p in pids:
            _kill(p)


def cmd_reap_orphans_only(cleanup_path: str) -> int:
    """reap kills the ppid==1 orphan broker but leaves a LIVE (parented) broker;
    and the reap is idempotent (a 2nd reap finds nothing left)."""
    mod = _load_module(cleanup_path)
    orphan_pid = _spawn_reparented(
        f"node /x/openai-codex/app-server-broker.mjs --cwd {_gone_worktree()}"
    )
    # A LIVE broker: same command shape but parented to THIS process (ppid != 1),
    # so it must be EXCLUDED. Spawn it as a normal child.
    live = subprocess.Popen(
        [_BASH_BIN, "-c",
         f'exec -a "node /x/openai-codex/app-server-broker.mjs --cwd {os.getcwd()}/.claude/worktrees/agent-live" /bin/sleep 60'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    live_pid = live.pid
    try:
        if not _wait_reparented(orphan_pid):
            raise RuntimeError(f"orphan broker {orphan_pid} did not reparent to init")
        # The live broker's ppid is this process (not 1) -> classifier skips it.
        procs = mod.load_processes()
        cands = mod.classify_orphans(procs, 0)
        cand_pids = {c.pid for c in cands}
        if orphan_pid not in cand_pids:
            raise RuntimeError("reap classifier missed the orphaned broker")
        if live_pid in cand_pids:
            raise RuntimeError("reap classifier WRONGLY matched the live (parented) broker")
        # Reap the orphan via the real reaper path (TERM->grace->KILL).
        for c in cands:
            c.lstart = mod.read_proc_lstart(c.pid)
        for c in cands:
            mod.reap_one(c, 1.0)
        # Wait for the orphan to die.
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and _alive(orphan_pid):
            time.sleep(0.05)
        if _alive(orphan_pid):
            raise RuntimeError("reap did NOT kill the orphaned broker")
        if not _alive(live_pid):
            raise RuntimeError("reap KILLED the live broker (must not!)")
        # Idempotence: a 2nd classify over the new snapshot finds no orphan.
        procs2 = mod.load_processes()
        cands2 = mod.classify_orphans(procs2, 0)
        if any(c.pid == orphan_pid for c in cands2):
            raise RuntimeError("2nd scan still reports the reaped orphan")
        return 0
    finally:
        _kill(orphan_pid)
        _kill(live_pid)
        try:
            live.wait(timeout=2)
        except Exception:
            pass


def cmd_queue_gateway_staleness(cleanup_path: str) -> int:
    """A queue-gateway socket-server whose --bridge-home is a gone /tmp smoke
    dir is reaped; one whose --bridge-home is a LIVE existing dir is excluded."""
    mod = _load_module(cleanup_path)
    gone_home = _make_smoke_bridge_home_gone()
    live_home = os.getcwd()  # an existing dir
    stale_pid = _spawn_reparented(
        f"python3 /x/bridge-queue-gateway.py socket-server --bridge-home {gone_home} --queue-script /x/bridge-queue.py"
    )
    live = subprocess.Popen(
        [_BASH_BIN, "-c",
         f'exec -a "python3 /x/bridge-queue-gateway.py socket-server --bridge-home {live_home} --queue-script /x/bridge-queue.py" /bin/sleep 60'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    live_pid = live.pid
    try:
        if not _wait_reparented(stale_pid):
            raise RuntimeError(f"stale gateway {stale_pid} did not reparent to init")
        procs = mod.load_processes()
        cands = mod.classify_orphans(procs, 0)
        cand_pids = {c.pid for c in cands}
        if stale_pid not in cand_pids:
            raise RuntimeError("classifier missed the stale /tmp-smoke queue-gateway")
        stale_cand = next(c for c in cands if c.pid == stale_pid)
        if stale_cand.klass != "queue-gateway":
            raise RuntimeError(f"gateway misclassified: {stale_cand.klass}")
        if live_pid in cand_pids:
            raise RuntimeError("classifier WRONGLY matched the LIVE-bridge-home queue-gateway")
        return 0
    finally:
        _kill(stale_pid)
        _kill(live_pid)
        try:
            live.wait(timeout=2)
        except Exception:
            pass


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: 1567-...-helper.py <subcommand> <cleanup.py>", file=sys.stderr)
        return 2
    sub, cleanup_path = argv[0], argv[1]
    if not Path(cleanup_path).is_file():
        print(f"cleanup helper not found: {cleanup_path}", file=sys.stderr)
        return 2
    table = {
        "dry-run-kills-nothing": cmd_dry_run_kills_nothing,
        "reap-orphans-only": cmd_reap_orphans_only,
        "queue-gateway-staleness": cmd_queue_gateway_staleness,
    }
    fn = table.get(sub)
    if fn is None:
        print(f"unknown subcommand: {sub}", file=sys.stderr)
        return 2
    try:
        return fn(cleanup_path)
    except Exception as exc:  # noqa: BLE001 — surface any failure to the smoke
        print(f"{sub}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
