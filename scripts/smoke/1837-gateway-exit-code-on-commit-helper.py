#!/usr/bin/env python3
"""File-as-argv sidecar for scripts/smoke/1837-gateway-exit-code-on-commit.sh.

Footgun #11 / C1: the smoke shell drives every Python step through THIS helper
(file-as-argv) — never `python3 - <<'PY'` heredoc-stdin to a subprocess.

Each subcommand returns a single `ok-*` token on stdout for the shell to assert,
or a `FAIL: …` line + nonzero exit. The helper exercises the #1837/#1834
gateway-client contract by driving the `client` subcommand as a real subprocess
and simulating the daemon by (not) writing the response file. cmd_client runs
ONLY as an iso UID with BRIDGE_TASK_DB=/dev/null and no DB access, so the daemon's
response file is the ONLY authoritative outcome signal — these tests prove the
client waits for that real response (bounded retry) and returns its real exit
code, never fabricating a success.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GATEWAY_PY = REPO_ROOT / "bridge-queue-gateway.py"
HELPER = Path(__file__).resolve()


def _load_gateway():
    spec = importlib.util.spec_from_file_location("bridge_queue_gateway", GATEWAY_PY)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _agent_dirs(root: Path, agent: str) -> tuple[Path, Path]:
    req = root / agent / "requests"
    resp = root / agent / "responses"
    req.mkdir(parents=True, exist_ok=True)
    resp.mkdir(parents=True, exist_ok=True)
    return req, resp


def _client(
    root: Path,
    agent: str,
    *argv: str,
    timeout: float = 1.0,
    poll: float = 0.05,
    retries: int = 0,
    backoff: float = 0.0,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["BRIDGE_QUEUE_GATEWAY_READ_RETRIES"] = str(retries)
    env["BRIDGE_QUEUE_GATEWAY_READ_BACKOFF_SECONDS"] = str(backoff)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [
            sys.executable,
            str(GATEWAY_PY),
            "client",
            "--root",
            str(root),
            "--agent",
            agent,
            "--timeout",
            str(timeout),
            "--poll",
            str(poll),
            *argv,
        ],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def _spawn_delayed_writer(resp_dir: Path, delay: float, exit_code: int, stdout_marker: str) -> subprocess.Popen:
    """Background sidecar that simulates the daemon: after `delay` seconds, write a
    response carrying the given exit code + stdout marker for the pending request."""
    return subprocess.Popen(
        [
            sys.executable,
            str(HELPER),
            "delayed-response-writer",
            str(resp_dir),
            str(delay),
            str(exit_code),
            stdout_marker,
        ],
        env=dict(os.environ),
    )


# --------------------------------------------------------------------------- #
# Test subcommands
# --------------------------------------------------------------------------- #

def cmd_retry_absorbs_flap(_unused: str = "") -> None:
    """#1834: a transient flap whose response lands AFTER the base timeout but
    inside the bounded retry window → the client returns the daemon's real exit
    code (0) without the caller having to loop.

    cmd_client clamps the base timeout to a 1.0s minimum, so the response must
    land after ~1.0s to exercise the RETRY rather than the initial poll. We delay
    it to 1.4s (retry window 1 with backoff=0.5 spans 1.0–1.5s). If the retry
    loop were removed the response would never be read and the client would exit
    nonzero — this is the #1834 coverage."""
    root = Path(os.environ["GW_ROOT"])
    agent = "iso-a"
    _, resp_dir = _agent_dirs(root, agent)
    bg = _spawn_delayed_writer(resp_dir, delay=1.4, exit_code=0, stdout_marker="DELAYED-OK")
    started = time.monotonic()
    try:
        res = _client(root, agent, "done", "1", "--agent", agent, timeout=0.3, poll=0.05, retries=4, backoff=0.5)
    finally:
        bg.wait(timeout=15)
    elapsed = time.monotonic() - started
    if res.returncode != 0:
        raise SystemExit(f"FAIL: retry did not absorb the flap; exit={res.returncode} stderr={res.stderr!r}")
    if "DELAYED-OK" not in res.stdout:
        raise SystemExit(f"FAIL: daemon response stdout not delivered: {res.stdout!r}")
    if elapsed < 1.0:
        raise SystemExit(f"FAIL: response read before the base-timeout floor ({elapsed:.2f}s) — retry not exercised")
    print("ok-retry-absorbs-flap")


def cmd_returns_real_exit_code(_unused: str = "") -> None:
    """#1837: the client returns the daemon's REAL exit code, never a fabricated
    success. A delayed response carrying a NONZERO exit (a genuine queue failure
    the daemon reported) must propagate as that nonzero code — proving the client
    relays the authoritative outcome rather than assuming success on a late ack.
    Conversely an idempotent success response (exit 0) propagates as 0."""
    root = Path(os.environ["GW_ROOT"])
    agent = "iso-b"
    _, resp_dir = _agent_dirs(root, agent)

    # Late response carrying a genuine failure exit code (e.g. not-owner / not
    # claimable) must surface as that code, not be masked into 0.
    bg = _spawn_delayed_writer(resp_dir, delay=1.3, exit_code=3, stdout_marker="REAL-FAIL")
    try:
        res = _client(root, agent, "done", "9", "--agent", agent, timeout=0.3, poll=0.05, retries=4, backoff=0.5)
    finally:
        bg.wait(timeout=15)
    if res.returncode != 3:
        raise SystemExit(f"FAIL: daemon's real exit code 3 not propagated; got exit={res.returncode}")
    if "REAL-FAIL" not in res.stdout:
        raise SystemExit(f"FAIL: daemon failure stdout not delivered: {res.stdout!r}")
    print("ok-returns-real-exit-code")


def cmd_idempotent_success_returns_zero(_unused: str = "") -> None:
    """#1837 keystone: the canonical thrash case. The daemon committed the write
    and reports the idempotent success (exit 0) a little late; the client must
    return 0 from that real response — NOT a false exit 1 that would induce the
    retry storm. (This is the daemon-reported success path, not a fabricated one.)"""
    root = Path(os.environ["GW_ROOT"])
    agent = "iso-c"
    _, resp_dir = _agent_dirs(root, agent)
    bg = _spawn_delayed_writer(resp_dir, delay=1.3, exit_code=0, stdout_marker="ALREADY-DONE")
    try:
        res = _client(root, agent, "done", "1", "--agent", agent, timeout=0.3, poll=0.05, retries=4, backoff=0.5)
    finally:
        bg.wait(timeout=15)
    if res.returncode != 0:
        raise SystemExit(f"FAIL: committed-write late ack did not return 0; exit={res.returncode} stderr={res.stderr!r}")
    if "ALREADY-DONE" not in res.stdout:
        raise SystemExit(f"FAIL: committed response stdout not delivered: {res.stdout!r}")
    print("ok-idempotent-success-returns-zero")


def cmd_genuine_timeout_nonzero(_unused: str = "") -> None:
    """A daemon that NEVER responds (truly unresponsive) → honest nonzero timeout,
    no fabricated success, and the stale request is unlinked so the next call
    does not pile on a duplicate (the thrash guard)."""
    root = Path(os.environ["GW_ROOT"])
    agent = "iso-d"
    req_dir, _ = _agent_dirs(root, agent)
    # No response writer at all; bounded retry exhausts -> nonzero.
    res = _client(root, agent, "done", "1", "--agent", agent, timeout=0.3, poll=0.05, retries=2, backoff=0.2)
    if res.returncode == 0:
        raise SystemExit("FAIL: no-response timeout returned exit 0 (must be nonzero)")
    if "timed out" not in res.stderr:
        raise SystemExit(f"FAIL: expected timeout message: {res.stderr!r}")
    leftovers = list(req_dir.glob("*.request.json"))
    if leftovers:
        raise SystemExit(f"FAIL: genuine-timeout path left a stale request file (re-queue risk): {leftovers}")
    print("ok-genuine-timeout-nonzero")


def cmd_no_db_access_required(_unused: str = "") -> None:
    """The client must work with NO task-DB access (the real iso shape:
    BRIDGE_TASK_DB=/dev/null). With the sentinel set AND the proxy env present,
    a late daemon response is still read and its exit code returned — proving the
    fix never depends on a direct DB read (the iso UID cannot do one)."""
    root = Path(os.environ["GW_ROOT"])
    agent = "iso-e"
    _, resp_dir = _agent_dirs(root, agent)
    iso_env = {
        "BRIDGE_TASK_DB": "/dev/null",
        "BRIDGE_GATEWAY_PROXY": "1",
        "BRIDGE_AGENT_ID": agent,
        "BRIDGE_AGENT_ENV_FILE": str(root / "fake-agent-env"),
    }
    bg = _spawn_delayed_writer(resp_dir, delay=1.3, exit_code=0, stdout_marker="ISO-OK")
    try:
        res = _client(
            root, agent, "done", "1", "--agent", agent,
            timeout=0.3, poll=0.05, retries=4, backoff=0.5, extra_env=iso_env,
        )
    finally:
        bg.wait(timeout=15)
    if res.returncode != 0 or "ISO-OK" not in res.stdout:
        raise SystemExit(
            f"FAIL: client failed under the /dev/null-DB iso shape; exit={res.returncode} stdout={res.stdout!r}"
        )
    print("ok-no-db-access-required")


def _spawn_fake_daemon(home_dir: Path) -> subprocess.Popen:
    """Spawn a long-lived process launched as the GENUINE install daemon —
    `bash <home>/bridge-daemon.sh run`. The liveness guard path-anchors the
    `bridge-daemon.sh` token to <home>/bridge-daemon.sh, so the script MUST live
    under home (not an arbitrary tmp dir). The bash process stays alive sleeping
    (no `exec`, so its cmdline keeps the 'bash <home>/bridge-daemon.sh run'
    signature in both /proc/<pid>/cmdline and `ps -o args=')."""
    home_dir.mkdir(parents=True, exist_ok=True)
    fake = home_dir / "bridge-daemon.sh"
    fake.write_text("#!/usr/bin/env bash\nsleep 60\n", encoding="utf-8")
    fake.chmod(0o755)
    return subprocess.Popen(["bash", str(fake), "run"])


def cmd_daemon_liveness_primitive(_unused: str = "") -> None:
    """The daemon-down primitive tri-state:
      * `unknown` when the pid file is unreadable/absent (iso-UID false-down
        guard, #1837 symptom 3),
      * `up` for a live pid whose cmdline looks like the bridge daemon,
      * `down` for a dead pid OR a live RECYCLED pid that is NOT the daemon
        (the #1837 codex-r5 stale-pid guard),
      * honors BRIDGE_DAEMON_PID_FILE (relocated/custom installs).
    Also exercises the `daemon-liveness` subcommand A3 consumes."""
    gw = _load_gateway()
    home = os.environ["BRIDGE_HOME"]
    state_dir = Path(os.environ["BRIDGE_STATE_DIR"])
    tmp = Path(os.environ["SMOKE_TMP_ROOT"])
    pid_path = state_dir / "daemon.pid"

    # This is a bridge-managed session, so BRIDGE_DAEMON_PID_FILE may be inherited
    # and point at the OPERATOR's live daemon pid. Scrub it for the default-path
    # assertions so they exercise the isolated <state>/daemon.pid, then test the
    # override explicitly below. Subprocess calls below also pass a scrubbed env.
    os.environ.pop("BRIDGE_DAEMON_PID_FILE", None)
    base_env = dict(os.environ)

    fake_daemon = _spawn_fake_daemon(Path(home).expanduser())
    try:
        # 1. Absent pid file -> unknown (NOT down).
        if pid_path.exists():
            pid_path.unlink()
        if gw.gateway_daemon_liveness(home) != "unknown":
            raise SystemExit("FAIL: absent daemon.pid did not report 'unknown'")

        # 2. Live pid whose cmdline is the daemon -> up.
        pid_path.write_text(f"{fake_daemon.pid}\n", encoding="utf-8")
        if gw.gateway_daemon_liveness(home) != "up":
            raise SystemExit("FAIL: live daemon pid did not report 'up'")

        # 3a. Dead pid -> down.
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        pid_path.write_text(f"{child.pid}\n", encoding="utf-8")
        if gw.gateway_daemon_liveness(home) != "down":
            raise SystemExit("FAIL: dead pid did not report 'down'")

        # 3b. Recycled-pid guard (#1837 codex r5): a LIVE pid whose cmdline is NOT
        # the daemon (our own python helper) must be 'down', not a false 'up'.
        pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
        if gw.gateway_daemon_liveness(home) != "down":
            raise SystemExit("FAIL: a live non-daemon (recycled) pid false-reported 'up'")

        # 3c. Substring-bypass guard (#1840 regate codex): a LIVE pid whose argv
        # merely CONTAINS the string "bridge-daemon" (e.g. `not-a-bridge-daemon`)
        # but carries NO `bridge-daemon.sh` token must be 'down'. The prior bare
        # substring check false-reported this as 'up'.
        impostor = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)", "not-a-bridge-daemon"]
        )
        try:
            pid_path.write_text(f"{impostor.pid}\n", encoding="utf-8")
            if gw.gateway_daemon_liveness(home) != "down":
                raise SystemExit(
                    "FAIL: a live pid whose argv contains 'bridge-daemon' "
                    "substring (not the daemon script) false-reported 'up'"
                )
        finally:
            impostor.terminate()
            impostor.wait()

        # 3d. Run-shape guard (#1840 regate codex r2): a `bridge-daemon.sh` token
        # that is NOT in the daemon run shape must be 'down' — the script passed
        # as a bare arg, or with a non-`run` subcommand, is not the running
        # daemon. Only `bridge-daemon.sh run` is the live daemon.
        for bad_argv, label in (
            ([sys.executable, "-c", "import time; time.sleep(60)",
              "/tmp/bridge-daemon.sh"], "script as bare arg (no run)"),
            (["bash", "-c", "sleep 60", "bridge-daemon.sh", "status"],
             "bridge-daemon.sh wrong subcommand (status)"),
        ):
            bad = subprocess.Popen(bad_argv)
            try:
                pid_path.write_text(f"{bad.pid}\n", encoding="utf-8")
                if gw.gateway_daemon_liveness(home) != "down":
                    raise SystemExit(
                        f"FAIL: a live pid with {label} false-reported 'up' "
                        "(only `bridge-daemon.sh run` is the daemon)"
                    )
            finally:
                bad.terminate()
                bad.wait()

        # 3e. Path-anchor guard (#1840 regate patch-dev): a GENUINE
        # `bash <path>/bridge-daemon.sh run` whose script is NOT the install's
        # <home>/bridge-daemon.sh must be 'down'. A bridge-daemon.sh token in the
        # exact run shape but at a foreign path is not THIS install's daemon.
        foreign_dir = tmp / "foreign"
        foreign_dir.mkdir(parents=True, exist_ok=True)
        foreign = foreign_dir / "bridge-daemon.sh"
        foreign.write_text("#!/usr/bin/env bash\nsleep 60\n", encoding="utf-8")
        foreign.chmod(0o755)
        far = subprocess.Popen(["bash", str(foreign), "run"])
        try:
            pid_path.write_text(f"{far.pid}\n", encoding="utf-8")
            if gw.gateway_daemon_liveness(home) != "down":
                raise SystemExit(
                    "FAIL: a `bridge-daemon.sh run` at a non-<home> path "
                    "false-reported 'up' (must path-anchor to <home>/bridge-daemon.sh)"
                )
        finally:
            far.terminate()
            far.wait()

        # 3f. Position-anchor guard (#1840 regate codex #12972 + patch-dev #12973
        # CONVERGED): a LIVE non-daemon pid that carries the GENUINE
        # <home>/bridge-daemon.sh path + `run` as ordinary trailing DATA args
        # (not as the executed script) must be 'down'. The prior token-anywhere
        # path-anchor scanned every argv element, so `python3 -c '<code>'
        # <home>/bridge-daemon.sh run` false-reported 'up' even though python is
        # the program and the script is just a `-c` argument. The script must be
        # in the executed-script position (argv[0], or argv[1] behind a shell).
        home_script = Path(home).expanduser() / "bridge-daemon.sh"
        data_arg_cases = (
            # absolute genuine path as a trailing data arg to `python -c`
            ([sys.executable, "-c", "import time; time.sleep(60)",
              str(home_script), "run"], None,
             "genuine <home> script + run as `python -c` data args"),
            # relative `bridge-daemon.sh run` data args, cwd=<home> so it
            # realpath-resolves to the genuine script (patch-dev's cwd repro)
            ([sys.executable, "-c", "import time; time.sleep(60)",
              "bridge-daemon.sh", "run"], str(Path(home).expanduser()),
             "genuine script via cwd + run as `python -c` data args"),
        )
        for data_argv, cwd, label in data_arg_cases:
            dat = subprocess.Popen(data_argv, cwd=cwd, env=base_env)
            try:
                pid_path.write_text(f"{dat.pid}\n", encoding="utf-8")
                if gw.gateway_daemon_liveness(home) != "down":
                    raise SystemExit(
                        f"FAIL: a live non-daemon pid carrying the {label} "
                        "false-reported 'up' (script must be in the "
                        "executed-script position, not a data arg)"
                    )
            finally:
                dat.terminate()
                dat.wait()

        # 4. The `daemon-liveness` subcommand mirrors the primitive -> 'up'.
        pid_path.write_text(f"{fake_daemon.pid}\n", encoding="utf-8")
        out = subprocess.run(
            [sys.executable, str(GATEWAY_PY), "daemon-liveness", "--bridge-home", home],
            capture_output=True, text=True, check=False, env=base_env,
        )
        if out.returncode != 0 or out.stdout.strip() != "up":
            raise SystemExit(f"FAIL: daemon-liveness subcommand exit={out.returncode} stdout={out.stdout!r}")

        # 5. Honor BRIDGE_DAEMON_PID_FILE (relocated/custom installs): live daemon
        # pid ONLY at a custom path, default state path dead/absent -> still 'up'.
        custom_pid = state_dir / "custom-daemon.pid"
        custom_pid.write_text(f"{fake_daemon.pid}\n", encoding="utf-8")
        if pid_path.exists():
            pid_path.unlink()
        env_override = dict(base_env)
        env_override["BRIDGE_DAEMON_PID_FILE"] = str(custom_pid)
        out = subprocess.run(
            [sys.executable, str(GATEWAY_PY), "daemon-liveness", "--bridge-home", home],
            capture_output=True, text=True, check=False, env=env_override,
        )
        if out.returncode != 0 or out.stdout.strip() != "up":
            raise SystemExit(
                f"FAIL: liveness ignored BRIDGE_DAEMON_PID_FILE override; exit={out.returncode} stdout={out.stdout!r}"
            )
    finally:
        fake_daemon.terminate()
        try:
            fake_daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fake_daemon.kill()
    print("ok-daemon-liveness-primitive")


def cmd_delayed_response_writer(resp_dir_arg: str, delay_arg: str, exit_arg: str, marker_arg: str) -> None:
    """Background sidecar simulating the daemon: after `delay`s, write a response
    carrying `exit_code` + a stdout marker for the (single) pending request."""
    resp_dir = Path(resp_dir_arg)
    req_dir = resp_dir.parent / "requests"
    delay = float(delay_arg)
    exit_code = int(exit_arg)
    deadline = time.monotonic() + 12.0
    time.sleep(delay)
    while time.monotonic() < deadline:
        reqs = list(req_dir.glob("*.request.json")) + list(req_dir.glob("*.working.json"))
        if reqs:
            request_id = reqs[0].name.split(".", 1)[0]
            import json
            payload = json.dumps({
                "id": request_id,
                "exit_code": exit_code,
                "stdout": f"{marker_arg}\n",
                "stderr": "",
            })
            (resp_dir / f"{request_id}.json").write_text(payload, encoding="utf-8")
            return
        time.sleep(0.05)


DISPATCH = {
    "retry-absorbs-flap": cmd_retry_absorbs_flap,
    "returns-real-exit-code": cmd_returns_real_exit_code,
    "idempotent-success-returns-zero": cmd_idempotent_success_returns_zero,
    "genuine-timeout-nonzero": cmd_genuine_timeout_nonzero,
    "no-db-access-required": cmd_no_db_access_required,
    "daemon-liveness-primitive": cmd_daemon_liveness_primitive,
    "delayed-response-writer": cmd_delayed_response_writer,
}


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in DISPATCH:
        sys.stderr.write(f"usage: {argv[0]} <{'|'.join(DISPATCH)}> [arg ...]\n")
        return 2
    DISPATCH[argv[1]](*argv[2:])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
