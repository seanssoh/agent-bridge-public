#!/usr/bin/env python3
"""Helper for the rooms-p4-5-polish smoke (A2A Rooms P4.5).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). Imports the REAL
`bridge_rooms_common` so the member-side roster cache the smoke seeds uses the
canonical schema + the canonical insert the P4.2 broadcast would have written.

Subcommands (argv[1]):
  seed-cache <db> <room_id> <epoch> <from_node> <members_csv>
        write a leader-MAC roster cache row directly (the applied P4.2 outcome),
        WITHOUT a matching `rooms` row — i.e. the exact state of a NON-leader
        node that joined + was approved into a room. members_csv entries are
        `agent@node[:role]`, comma-separated.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_rooms_common as rooms  # noqa: E402


def _parse_members_csv(members_csv: str) -> list:
    members: list = []
    for entry in members_csv.split(","):
        entry = entry.strip()
        if not entry:
            continue
        role = "member"
        if ":" in entry:
            entry, role = entry.rsplit(":", 1)
        agent, _, node = entry.partition("@")
        members.append({"agent": agent.strip(), "node": node.strip(),
                        "role": role.strip() or "member"})
    members.sort(key=lambda m: (m["agent"], m["node"]))
    return members


def cmd_seed_cache(db: str, room_id: str, epoch: str, from_node: str,
                   members_csv: str) -> int:
    """Seed a member-side leader-MAC roster cache row (the P4.2 outcome).

    No `rooms` row is written — this is exactly a NON-leader node's state, so
    `cmd_show`/`cmd_list` must consult `room_roster_cache` to see the room.
    """
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db  # noqa: iso-helper-boundary - env var, not a .env file
    members = _parse_members_csv(members_csv)
    members_json = json.dumps(members, separators=(",", ":"))
    conn = rooms.open_rooms()
    try:
        conn.execute(
            "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, "
            "members_json, from_node, mac, fetched_ts) VALUES (?, ?, ?, ?, ?, ?)",
            (room_id, int(epoch), members_json, from_node, "leader-mac",
             rooms.now_ts()),
        )
        conn.commit()
    finally:
        conn.close()
    print(f"seeded cache room={room_id} epoch={epoch} members={len(members)}")
    return 0


def main(argv: list) -> int:
    if len(argv) < 2:
        print("usage: rooms-p4-5-helper.py <subcommand> ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "seed-cache":
        return cmd_seed_cache(argv[2], argv[3], argv[4], argv[5], argv[6])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
