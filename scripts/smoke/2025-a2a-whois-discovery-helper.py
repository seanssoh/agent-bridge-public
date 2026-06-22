#!/usr/bin/env python3
"""Helper for scripts/smoke/2025-a2a-whois-discovery.sh (#2025).

File-as-argv sidecar (NOT a heredoc fed into `python3 -`) so the smoke shell
never trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). It imports the
real rooms module so the smoke seeds the CANONICAL room_members schema — the
same authoritative agent->node source `agb a2a whois` aggregates read-only via
`bridge-rooms.py list/show --json`. The smoke then drives the REAL `agb a2a
whois` / `agb a2a send` CLI; this helper only seeds the rooms.db and makes
read-only JSON assertions over their output.

Subcommands (argv[1]):
  seed-rooms                 seed a multi-room, multi-node rooms.db in the
                             current isolated BRIDGE_HOME:
                               room "core":  leader app-lead@node-a,
                                             member reviewer@node-b
                               room "ops":   leader ops-lead@node-a,
                                             member reviewer@node-c   (DUP node!)
                             => `reviewer` is AMBIGUOUS (node-b + node-c);
                                `app-lead` is UNIQUE on node-a; `ghost` is
                                absent (not-found).
  field <dotted> <expected>  read stdin JSON, assert top-level/dotted field eq
  status-is <expected>       read stdin JSON, assert .status == expected
  candidates-include <node>  read stdin JSON, assert <node> in .candidates
  known-agents-for <peer> <agent>
                             read stdin `peers list --json`, assert <agent> is
                             in the known_agents column of peer <peer>
  no-secrets <csv>           read stdin, assert none of the secret tokens appear
  partial-roster-fail-closed import bridge-a2a.py, monkeypatch the read-only
                             rooms-CLI delegation so `list` returns 2 rooms but
                             one room's `show` FAILS (the race/unreadable case),
                             then assert _collect_agent_node_map + resolve_agent_node
                             FAIL CLOSED (registry_error, node=None) instead of
                             routing on a partial map (codex #2025 BLOCKING)

Exit 0 on pass, 1 on failure (prints the reason for the smoke log).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


def _fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


def _read_stdin_json() -> object:
    raw = sys.stdin.read()
    try:
        return json.loads(raw)
    except (ValueError, TypeError) as exc:  # pragma: no cover - smoke diag
        print(f"FAIL: stdin is not JSON ({exc}); got: {raw[:200]!r}",
              file=sys.stderr)
        sys.exit(1)


def _dotted(doc: object, path: str) -> object:
    cur = doc
    for part in path.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def seed_rooms() -> int:
    """Seed a deterministic multi-node rooms.db via the REAL rooms module."""
    import bridge_rooms_common as rooms

    conn = rooms.open_rooms()
    try:
        # Room "core": leader app-lead@node-a, member reviewer@node-b.
        core = rooms.create_room(
            conn, name="core", leader_agent="app-lead",
            leader_node="node-a", token="seed-token-core",
        )
        rooms.add_member(conn, core, "reviewer", node="node-b")
        # Room "ops": leader ops-lead@node-a, member reviewer@node-c.
        # `reviewer` is now AMBIGUOUS across node-b (core) + node-c (ops).
        ops = rooms.create_room(
            conn, name="ops", leader_agent="ops-lead",
            leader_node="node-a", token="seed-token-ops",
        )
        rooms.add_member(conn, ops, "reviewer", node="node-c")
    finally:
        conn.close()
    print(f"seeded rooms core={core} ops={ops}")
    return 0


def field(path: str, expected: str) -> int:
    doc = _read_stdin_json()
    got = _dotted(doc, path)
    if str(got) != expected:
        return _fail(f"field {path!r}: expected {expected!r}, got {got!r}")
    return 0


def status_is(expected: str) -> int:
    doc = _read_stdin_json()
    got = doc.get("status") if isinstance(doc, dict) else None
    if got != expected:
        return _fail(f".status: expected {expected!r}, got {got!r}")
    return 0


def candidates_include(node: str) -> int:
    doc = _read_stdin_json()
    cands = doc.get("candidates") if isinstance(doc, dict) else None
    if not isinstance(cands, list) or node not in cands:
        return _fail(f".candidates missing {node!r}; got {cands!r}")
    return 0


def known_agents_for(peer: str, agent: str) -> int:
    doc = _read_stdin_json()
    if not isinstance(doc, list):
        return _fail(f"peers list --json not a list; got {type(doc).__name__}")
    for p in doc:
        if isinstance(p, dict) and str(p.get("id")) == peer:
            ka = p.get("known_agents")
            if isinstance(ka, list) and agent in ka:
                return 0
            return _fail(
                f"peer {peer!r} known_agents missing {agent!r}; got {ka!r}")
    return _fail(f"peer {peer!r} not present in peers list")


def no_secrets(csv: str) -> int:
    raw = sys.stdin.read()
    for token in [t for t in csv.split(",") if t]:
        if token in raw:
            return _fail(f"secret token {token!r} leaked into output")
    return 0


def partial_roster_fail_closed() -> int:
    """Prove the auto-resolver FAILS CLOSED on a partial room roster (codex
    #2025 BLOCKING focus item (a)).

    The hole: `_collect_agent_node_map` walked `list` then `show <rid>` per
    room. If it silently SKIPPED a listed room whose `show` failed, an agent on
    node-b (room r1) + node-c (room r2) could collapse to a spurious "unique
    node-b" when r2's show raced out — letting `send --peer auto` route on
    incomplete data. We import the CLI module and monkeypatch the read-only
    rooms-CLI delegation so `list` returns BOTH rooms but the SECOND room's
    `show` fails, then assert the map + resolver return registry_error (NOT a
    unique node).
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "bridge_a2a_cli_undertest", str(REPO_ROOT / "bridge-a2a.py"))
    if spec is None or spec.loader is None:
        return _fail("could not load bridge-a2a.py for the fail-closed unit")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    def fake_rooms_cli(verb, *extra):
        if verb == "list":
            return ([{"room_id": "r1", "epoch": 0},
                     {"room_id": "r2", "epoch": 0}], None)
        if verb == "show" and extra and extra[0] == "r1":
            return ({"members": [
                {"agent": "reviewer", "node": "node-b", "role": "member"}]},
                None)
        # r2 show FAILS — the race/unreadable case that must poison the map.
        return (None, "simulated unreadable room")

    mod._netstat_rooms_cli = fake_rooms_cli  # type: ignore[attr-defined]

    amap, err = mod._collect_agent_node_map()
    if err is None:
        return _fail(
            f"partial roster did NOT fail closed: map={amap!r} err=None "
            "(a listed-room show failure must poison the whole map)")
    if amap:
        return _fail(f"fail-closed map must be empty; got {amap!r}")
    res = mod.resolve_agent_node("reviewer")
    if res.get("status") != "registry_error":
        return _fail(
            f"resolve_agent_node must be registry_error on a partial roster; "
            f"got status={res.get('status')!r} node={res.get('node')!r} "
            "(routing on a partial map would violate never-guess)")
    if res.get("node") is not None:
        return _fail(f"fail-closed resolve must not pick a node; got {res!r}")
    print("partial-roster fail-closed OK")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        return _fail("no subcommand")
    cmd, rest = argv[0], argv[1:]
    if cmd == "seed-rooms":
        return seed_rooms()
    if cmd == "field":
        return field(rest[0], rest[1])
    if cmd == "status-is":
        return status_is(rest[0])
    if cmd == "candidates-include":
        return candidates_include(rest[0])
    if cmd == "known-agents-for":
        return known_agents_for(rest[0], rest[1])
    if cmd == "no-secrets":
        return no_secrets(rest[0])
    if cmd == "partial-roster-fail-closed":
        return partial_roster_fail_closed()
    return _fail(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
