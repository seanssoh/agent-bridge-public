#!/usr/bin/env python3
"""Helper for scripts/smoke/v0165-l6-net-status-v2.sh (#1708).

Read-only assertions + fixture builders for the `agb a2a net-status --json` v2
control-loop status window. Pure stdin JSON inspection + non-mutating fixture
seeds — this helper NEVER touches LIVE A2A state and writes only into the smoke
temp roots it is handed.

Subcommands:

  has-keys <comma,sep,keys>        assert top-level keys all present (stdin JSON)
  field <dotted.path> <expected>   assert snapshot[path] == expected (str cmp)
  v1-shape-unchanged               assert the v1 #1697 fields are present with
                                   their v1 shape (additive proof)
  no-secrets <comma,sep,secrets>   assert none of the secret tokens appear
  reconcile-all-unknown            assert reconcile.steps are all status=unknown
                                   AND last_tick_ts is null (the pre-tick shape)
  per-peer-state <peer_id> <state> assert per_peer[peer_id].state == state
  seed-reconcile-db <db>           seed a populated reconcile.db (step attempts +
                                   a peer FSM row) at <db> (uses the REAL schema)
  seed-rooms-db <db> <room_id> <leader_agent> <leader_node> <members_csv>
                                   seed a leader rooms.db at <db>
  run-net-status <config> [reconcile_db] [rooms_db]
                                   run `agb a2a net-status --json` against the
                                   given config/db env, print the JSON snapshot

Exit 0 on pass, 1 on failure (prints the reason for the smoke log).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
A2A_CLI = REPO_ROOT / "bridge-a2a.py"

# The v1 #1697 top-level keys whose presence + shape MUST stay byte-stable.
V1_KEYS = ["bridge_id", "transport", "listen", "receiver", "substrate",
           "peers", "rooms"]
# The v2 #1708 additive top-level keys.
V2_KEYS = ["own_stable_address", "room_leader", "allowed_agents", "room_roster",
           "tunnel_freshness", "per_peer", "reconcile", "roster_epoch_converged"]


def _import_reconcile():
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    import bridge_reconcile_common as reconcile  # noqa: WPS433 - lazy import
    return reconcile


def _import_rooms():
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    import bridge_rooms_common as rooms  # noqa: WPS433 - lazy import
    return rooms


def _load_a2a_module():
    """Import bridge-a2a.py by file path (hyphenated name isn't import-able)."""
    import importlib.util
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    a2a_cli = REPO_ROOT / "bridge-a2a.py"
    spec = importlib.util.spec_from_file_location("bridge_a2a_l6_under_test",
                                                  str(a2a_cli))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _rooms_cli_wedged_degrades() -> int:
    """Prove a WEDGED bridge-rooms.py (TimeoutExpired) degrades — never raises.

    Unit-drives the codex r1 [P1] fix: `_run_subprocess` can raise
    `subprocess.TimeoutExpired` (NOT an OSError subclass). `_netstat_rooms_cli`
    must catch it and return `(None, <error>)`, AND the higher-level
    `_netstat_rooms_v2` must degrade to empty lists with an error — never let the
    exception unwind the read-only snapshot.
    """
    import subprocess
    mod = _load_a2a_module()

    def _raise_timeout(argv, *, timeout):  # noqa: ARG001 - signature match
        raise subprocess.TimeoutExpired(cmd=argv, timeout=timeout)

    mod._run_subprocess = _raise_timeout  # type: ignore[assignment]

    parsed, err = mod._netstat_rooms_cli("list")
    if parsed is not None or not err:
        print(f"_netstat_rooms_cli did not degrade on TimeoutExpired: ({parsed!r}, {err!r})")
        return 1
    # The higher-level rooms-v2 reader must also degrade to empty + error.
    rooms_v2 = mod._netstat_rooms_v2({})
    if rooms_v2.get("room_leader") != [] or not rooms_v2.get("error"):
        print(f"_netstat_rooms_v2 did not degrade on wedged CLI: {rooms_v2!r}")
        return 1
    # The V1 rooms reader (_netstat_rooms_count) runs FIRST in cmd_net_status and
    # must ALSO degrade (codex r2 [P1]): a TimeoutExpired here must not unwind.
    v1_rooms = mod._netstat_rooms_count()
    if v1_rooms.get("count") is not None or not v1_rooms.get("error"):
        print(f"_netstat_rooms_count did not degrade on wedged CLI: {v1_rooms!r}")
        return 1
    print("ok")
    return 0


def _net_status_full_wedged_rooms(config: str) -> int:
    """Drive the FULL cmd_net_status with a wedged rooms CLI — must NOT raise.

    The end-to-end proof (codex r2 [P1]): monkeypatch `_run_subprocess` to raise
    `subprocess.TimeoutExpired` for EVERY rooms subprocess, then call
    `cmd_net_status` exactly as the CLI does. It must return rc 0 with a complete
    snapshot (the rooms count error surfaced), never let the TimeoutExpired
    unwind the read-only command.
    """
    import argparse
    import subprocess
    mod = _load_a2a_module()
    real_run = mod._run_subprocess

    def _wedge_rooms_only(argv, *, timeout):
        # Wedge ONLY the rooms CLI (the realistic failure Codex flagged); let
        # every other subprocess (e.g. the healthz probe) behave normally so the
        # test isolates the rooms-reader degrade-safety, not unrelated v1 legs.
        if any("bridge-rooms.py" in str(a) for a in argv):
            raise subprocess.TimeoutExpired(cmd=argv, timeout=timeout)
        return real_run(argv, timeout=timeout)

    mod._run_subprocess = _wedge_rooms_only  # type: ignore[assignment]
    os.environ["BRIDGE_A2A_CONFIG"] = config  # noqa: iso-helper-boundary - smoke fixture env, not a .env file
    os.environ.setdefault("BRIDGE_A2A_TAILSCALE_CLI", "/nonexistent/ts-smoke")  # noqa: iso-helper-boundary - smoke fixture env, not a .env file
    args = argparse.Namespace(json=True, probe_timeout=2.0)
    # cmd_net_status prints the snapshot JSON to stdout; redirect it to devnull
    # so only this helper's verdict line reaches the caller.
    import contextlib
    import io
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = mod.cmd_net_status(args)
    except Exception as exc:  # noqa: BLE001 - the whole point: it must NOT raise
        print(f"cmd_net_status RAISED on a wedged rooms CLI (not degrade-safe): {exc!r}")
        return 1
    if rc != 0:
        print(f"cmd_net_status returned rc={rc} (expected 0 / degrade-safe)")
        return 1
    print("ok")
    return 0


def _load() -> dict:
    raw = sys.stdin.read()
    try:
        return json.loads(raw)
    except (ValueError, TypeError) as exc:  # pragma: no cover - smoke diagnostic
        print(f"not-json: {exc}: {raw[:200]!r}")
        sys.exit(1)


def _dig(doc, dotted: str):
    """Traverse a dotted path supporting both dict keys and list indices.

    A numeric path component indexes a list (e.g. `room_leader.0.room_id`); a
    non-numeric component keys a dict. Returns (value, found).
    """
    cur = doc
    for part in dotted.split("."):
        if isinstance(cur, list):
            try:
                idx = int(part)
            except ValueError:
                return ("__MISSING__", False)
            if idx < 0 or idx >= len(cur):
                return ("__MISSING__", False)
            cur = cur[idx]
        elif isinstance(cur, dict):
            if part not in cur:
                return ("__MISSING__", False)
            cur = cur[part]
        else:
            return ("__MISSING__", False)
    return (cur, True)


def _seed_reconcile_db(db: str) -> int:
    """Seed a populated reconcile.db via the REAL schema/record_attempt path.

    Records step attempts (so auto-recovery derivations are exercised) and a
    peer FSM row for `peer-a` (down/3). Uses BRIDGE_A2A_RECONCILE_DB so the seed
    targets exactly <db>; this writes to the smoke temp root only.
    """
    reconcile = _import_reconcile()
    os.environ["BRIDGE_A2A_RECONCILE_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    import time
    conn = reconcile.open_reconcile_db()
    try:
        # tunnel-health currently erroring (pending retry pressure); stable-addr
        # + peer-reachability converged (settled).
        reconcile.record_attempt(conn, reconcile.STEP_TUNNEL_HEALTH, "error")
        reconcile.record_attempt(conn, reconcile.STEP_STABLE_ADDR, "changed")
        reconcile.record_attempt(conn, reconcile.STEP_PEER_REACHABILITY, "changed")
        reconcile._ensure_peer_reachability_schema(conn)
        reconcile._write_peer_state(conn, "peer-a", reconcile.PEER_STATE_DOWN, 3,
                                    time.time(), state_changed=True)
        reconcile.record_attempt(conn, reconcile._peer_step_id("peer-a"), "error")
        conn.commit()
    finally:
        conn.close()
    print(f"reconcile-db seeded at {db}")
    return 0


def _seed_rooms_db(db: str, room_id: str, leader_agent: str,
                   leader_node: str, members_csv: str) -> int:
    """Seed a leader rooms.db (room + members + roster cache) at <db>."""
    rooms = _import_rooms()
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    conn = rooms.open_rooms()
    try:
        ts = rooms.now_ts()
        conn.execute(
            "INSERT OR REPLACE INTO rooms (room_id, name, leader_agent, "
            "leader_node, epoch, invite_token_sha256, invite_token_ts, "
            "invite_once, status, created_ts, updated_ts) "
            "VALUES (?, 'team', ?, ?, 2, '', 0, 0, 'active', ?, ?)",
            (room_id, leader_agent, leader_node, ts, ts),
        )
        for entry in [e for e in members_csv.split(";") if e.strip()]:
            parts = entry.split(":")
            agent = parts[0]
            node = parts[1] if len(parts) > 1 else ""
            role = parts[2] if len(parts) > 2 else "member"
            conn.execute(
                "INSERT OR REPLACE INTO room_members (room_id, agent, node, "
                "role, joined_ts) VALUES (?, ?, ?, ?, ?)",
                (room_id, agent, node, role, ts),
            )
        rooms._recompute_roster_cache(conn, room_id, commit=False)
        conn.commit()
    finally:
        conn.close()
    print(f"rooms-db seeded room={room_id} leader={leader_agent}@{leader_node}")
    return 0


def _run_net_status(config: str, reconcile_db: str | None,
                    rooms_db: str | None) -> int:
    """Run `agb a2a net-status --json` against the given config/db env."""
    env = dict(os.environ)  # noqa: iso-helper-boundary  # smoke fixture: copies the test process env to pass BRIDGE_A2A_* to the subprocess; not a controller->iso boundary write
    env["BRIDGE_A2A_CONFIG"] = config
    if reconcile_db:
        env["BRIDGE_A2A_RECONCILE_DB"] = reconcile_db
    if rooms_db:
        env["BRIDGE_A2A_ROOMS_DB"] = rooms_db
    # A non-existent tailscale CLI keeps the stable-addr/substrate probe
    # fail-soft (no real tailnet) without a mock — the v2 shape still renders.
    env.setdefault("BRIDGE_A2A_TAILSCALE_CLI", "/nonexistent/tailscale-smoke")
    proc = subprocess.run(
        [sys.executable, str(A2A_CLI), "net-status", "--json"],
        capture_output=True, text=True, timeout=60, env=env, check=False,
    )
    sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
    return 0 if proc.returncode == 0 else 1


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: <subcommand> [args...]")
        return 2
    cmd, rest = argv[0], argv[1:]

    if cmd == "seed-reconcile-db":
        return _seed_reconcile_db(rest[0])

    if cmd == "seed-rooms-db":
        return _seed_rooms_db(rest[0], rest[1], rest[2], rest[3], rest[4])

    if cmd == "run-net-status":
        config = rest[0]
        rdb = rest[1] if len(rest) > 1 and rest[1] else None
        roomsdb = rest[2] if len(rest) > 2 and rest[2] else None
        return _run_net_status(config, rdb, roomsdb)

    if cmd == "rooms-cli-wedged-degrades":
        return _rooms_cli_wedged_degrades()

    if cmd == "net-status-full-wedged-rooms":
        return _net_status_full_wedged_rooms(rest[0])

    if cmd == "has-keys":
        doc = _load()
        want = [k for k in rest[0].split(",") if k]
        missing = [k for k in want if k not in doc]
        if missing:
            print(f"missing top-level keys: {missing}")
            return 1
        print("ok")
        return 0

    if cmd == "field":
        doc = _load()
        dotted, expected = rest[0], rest[1]
        val, found = _dig(doc, dotted)
        if not found:
            print(f"path not found: {dotted}")
            return 1
        if str(val) != expected:
            print(f"{dotted}={val!r} != expected {expected!r}")
            return 1
        print("ok")
        return 0

    if cmd == "v1-shape-unchanged":
        doc = _load()
        missing = [k for k in V1_KEYS if k not in doc]
        if missing:
            print(f"v1 #1697 keys missing (additive contract broken): {missing}")
            return 1
        # Shape spot-checks: the v1 nested shapes the #1697 smoke relies on.
        if not isinstance(doc.get("listen"), dict) or "port" not in doc["listen"]:
            print("v1 listen shape changed (expected dict with port)")
            return 1
        if not isinstance(doc.get("substrate"), dict) or "checked" not in doc["substrate"]:
            print("v1 substrate shape changed (expected dict with checked)")
            return 1
        if not isinstance(doc.get("peers"), list):
            print("v1 peers shape changed (expected list)")
            return 1
        if not isinstance(doc.get("rooms"), dict) or "count" not in doc["rooms"]:
            print("v1 rooms shape changed (expected dict with count)")
            return 1
        # Each v1 peer keeps its v1 keys (id/address/transport/identity_keyed) —
        # the v2 per_peer FSM lives in the SEPARATE top-level `per_peer`, never
        # mixed into the v1 `peers` entries.
        for p in doc["peers"]:
            for key in ("id", "address", "transport", "identity_keyed"):
                if key not in p:
                    print(f"v1 peer entry lost key {key!r}: {p}")
                    return 1
            if "state" in p:
                print(f"v2 FSM 'state' leaked into a v1 peers entry: {p}")
                return 1
        print("ok")
        return 0

    if cmd == "no-secrets":
        raw = sys.stdin.read()
        secrets = [s for s in rest[0].split(",") if s]
        leaked = [s for s in secrets if s in raw]
        if leaked:
            print(f"SECRET LEAK: {leaked}")
            return 1
        print("ok")
        return 0

    if cmd == "reconcile-all-unknown":
        doc = _load()
        rec = doc.get("reconcile", {})
        if rec.get("last_tick_ts") is not None:
            print(f"reconcile.last_tick_ts != null (store materialized?): {rec.get('last_tick_ts')}")
            return 1
        steps = rec.get("steps", {})
        if not isinstance(steps, dict) or not steps:
            print(f"reconcile.steps empty/not-a-dict: {steps}")
            return 1
        bad = [s for s, v in steps.items()
               if not isinstance(v, dict) or v.get("status") != "unknown"]
        if bad:
            print(f"reconcile steps not all 'unknown' (pre-tick): {bad}")
            return 1
        print("ok")
        return 0

    if cmd == "per-peer-state":
        doc = _load()
        peer_id, want = rest[0], rest[1]
        for pp in doc.get("per_peer", []):
            if isinstance(pp, dict) and pp.get("id") == peer_id:
                if str(pp.get("state")) != want:
                    print(f"per_peer[{peer_id}].state={pp.get('state')!r} != {want!r}")
                    return 1
                print("ok")
                return 0
        print(f"per_peer entry for {peer_id!r} not found")
        return 1

    print(f"unknown subcommand: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
