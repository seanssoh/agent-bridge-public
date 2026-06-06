#!/usr/bin/env python3
"""Helper for the 1594-rooms-fanout smoke (A2A Rooms whole-room fan-out).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). Imports the REAL
rooms / a2a / handoffd modules from the repo root so the smoke exercises the
canonical sender (`agb a2a send --room` -> `bridge-rooms.py send` -> the
OS-actor-anchored fan-out: membership proof from the local roster cache, the
same-node LOCAL-queue leg + the cross-node room-scoped A2A leg, self exclusion,
partial-failure collection) WITHOUT a live socket, Tailscale, or queue.

Both legs of the fan-out are stubbed via paired-flag test hooks (the same
prod-inert seam the existing P4.x smokes use):
  - REMOTE leg (`_post_room_talk`): the cross-node enqueue POST is captured by
    BRIDGE_ROOMS_TEST_POST_HOOK and (optionally) replayed through the REAL
    receiver `do_POST` to prove the cross-node delivery + the non-member gate.
  - LOCAL leg (`_post_room_local`): the would-be `bridge-task.sh create` is
    captured by BRIDGE_ROOMS_TEST_LOCAL_HOOK so the smoke can assert "delivered
    locally" without shelling out to a live queue.

Subcommands (argv[1]):
  post-hook <json>                 (BRIDGE_ROOMS_TEST_POST_HOOK target) — append
                                   the captured remote POST JSON to $POST_CAPTURE
                                   (one JSON object per line) and echo a stub.
  local-hook <json>               (BRIDGE_ROOMS_TEST_LOCAL_HOOK target) — append
                                   the captured local-queue create JSON to
                                   $LOCAL_CAPTURE (one per line). Exit non-zero
                                   for a target listed in $LOCAL_FAIL_FOR (CSV)
                                   to drive the partial-failure tooth.
  make-config <out> <this_node> <peer_node> <secret> <addr> [allowlist_csv]
                                   write a minimal handoff config.
  seed-cache <db> <room_id> <epoch> <from_node> <members_csv>
                                   write a leader-MAC roster cache row directly
                                   (members_csv = agent@node[:role],... ).
  count-lines <file>               print the number of non-empty lines.
  field-each <file> <key>          print body<key> for each captured line.
  deliver-remote-to-receiver <repo_root> <cfg_json> <captured_line_idx>
                                   <capture_file> [overrides]
                                   replay one captured remote POST through the
                                   REAL do_POST handler; print
                                   "status=<n> delivered=<bool> body=<json>".
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_a2a_common as a2a  # noqa: E402
import bridge_rooms_common as rooms  # noqa: E402


# ---------------------------------------------------------------------------
# capture hooks
# ---------------------------------------------------------------------------
def _append_line(path: str, text: str) -> None:
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(text.rstrip("\n") + "\n")


def cmd_post_hook(payload_json: str) -> int:
    """BRIDGE_ROOMS_TEST_POST_HOOK target — capture the remote POST, stub 200."""
    capture = os.environ.get("POST_CAPTURE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("POST_CAPTURE unset", file=sys.stderr)
        return 1
    _append_line(capture, payload_json)
    print(json.dumps({"ok": True, "task_id": "stub"}))
    return 0


def cmd_local_hook(payload_json: str) -> int:
    """BRIDGE_ROOMS_TEST_LOCAL_HOOK target — capture the local create.

    Exits non-zero (a simulated bridge-task.sh failure) for any target listed in
    $LOCAL_FAIL_FOR so the smoke can drive the partial-failure path.
    """
    capture = os.environ.get("LOCAL_CAPTURE")  # noqa: iso-helper-boundary - env var, not a .env file
    if not capture:
        print("LOCAL_CAPTURE unset", file=sys.stderr)
        return 1
    _append_line(capture, payload_json)
    fail_for = os.environ.get("LOCAL_FAIL_FOR", "")  # noqa: iso-helper-boundary - env var, not a .env file
    fail_set = {a.strip() for a in fail_for.split(",") if a.strip()}
    try:
        target = json.loads(payload_json).get("target_agent", "")
    except (ValueError, json.JSONDecodeError):
        target = ""
    if target in fail_set:
        print(f"simulated local-queue failure for {target}", file=sys.stderr)
        return 1
    print(f"created task #4242 for {target}")
    return 0


# ---------------------------------------------------------------------------
# config + cache helpers (mirror rooms-p4-3-room-talk-helper)
# ---------------------------------------------------------------------------
def cmd_make_config(out_path: str, this_node: str, peer_node: str,
                    peer_secret: str, address: str,
                    allowlist_csv: str = "") -> int:
    allowlist = [a for a in allowlist_csv.split(",") if a] if allowlist_csv else []
    cfg = {
        "bridge_id": this_node,
        "listen": {"host": "127.0.0.1", "port": 8787,
                   "enqueue_path": "/enqueue"},
        "timestamp_skew_seconds": 300,
        "timestamp_skew_grace_seconds": 3600,
        "peers": [
            {
                "id": peer_node,
                "address": address,
                "secret": peer_secret,
                "inbound_allowlist": allowlist,
            }
        ],
    }
    Path(out_path).write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    return 0


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


# ---------------------------------------------------------------------------
# capture readers
# ---------------------------------------------------------------------------
def _read_lines(path: str) -> list:
    if not os.path.isfile(path):
        return []
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(line)
    return out


def cmd_count_lines(path: str) -> int:
    print(len(_read_lines(path)))
    return 0


def cmd_add_peer(cfg_path: str, peer_id: str, secret: str, address: str,
                 allowlist_csv: str = "") -> int:
    """Append a second peer to an existing handoff config (no inline heredoc)."""
    allowlist = [a for a in allowlist_csv.split(",") if a] if allowlist_csv else []
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    cfg.setdefault("peers", []).append({
        "id": peer_id, "address": address, "secret": secret,
        "inbound_allowlist": allowlist,
    })
    with open(cfg_path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
    return 0


def cmd_nonmember_overrides(capture_file: str, line_idx: str,
                            bad_agent: str = "mallory") -> int:
    """Print a deliver-remote overrides JSON that rewrites the captured hop's
    envelope sender.agent to a NON-member + asks for a re-sign (so the receiver's
    membership gate, not the HMAC gate, is what rejects it). No inline heredoc."""
    captured = json.loads(_read_lines(capture_file)[int(line_idx)])
    env = json.loads(captured.get("body", "{}"))
    # The authenticated sender agent lives at env.sender.agent (the receiver's
    # room gate reads it there) — NOT a top-level field. Rewrite it to a
    # non-member so the membership gate, downstream of HMAC, is what rejects.
    env.setdefault("sender", {})["agent"] = bad_agent
    overrides = {"body": json.dumps(env, ensure_ascii=False,
                                    separators=(",", ":")),
                 "resign": True}
    print(json.dumps(overrides, separators=(",", ":")))
    return 0


def cmd_target_index(capture_file: str, want: str) -> int:
    """Print the 0-based line index of the captured remote hop targeting <want>
    (or empty if none). Lets the smoke pick a specific recipient's hop."""
    for i, line in enumerate(_read_lines(capture_file)):
        env = json.loads(json.loads(line).get("body", "{}"))
        if env.get("target_agent", "") == want:
            print(i)
            return 0
    print("")
    return 0


def cmd_field_each(path: str, key: str) -> int:
    """Print one value per captured line. key forms: top-level (local hook) or
    body:<k> (the remote POST envelope body) or header:<H>."""
    for line in _read_lines(path):
        doc = json.loads(line)
        if key.startswith("body:"):
            body = json.loads(doc.get("body", "{}"))
            val = body.get(key[len("body:"):], "")
        elif key.startswith("header:"):
            val = doc.get("headers", {}).get(key[len("header:"):], "")
        else:
            val = doc.get(key, "")
        if isinstance(val, (list, dict)):
            print(json.dumps(val, separators=(",", ":")))
        else:
            print(val)
    return 0


# ---------------------------------------------------------------------------
# receiver-side replay (a trimmed copy of the p4-3 helper's machinery)
# ---------------------------------------------------------------------------
def _load_handoffd(repo_root: str):
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "bridge_handoffd", os.path.join(repo_root, "bridge-handoffd.py"))
    hd = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(hd)
    return hd


class _FakeHeaders:
    def __init__(self, headers: dict):
        self._h = headers

    def get(self, key, default=None):
        return self._h.get(key, default)


class _FakeRFile:
    def __init__(self, data: bytes):
        self._data = data

    def read(self, n: int = -1) -> bytes:
        if n < 0 or n >= len(self._data):
            out, self._data = self._data, b""
            return out
        out, self._data = self._data[:n], self._data[n:]
        return out


class _FakeServer:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.config_path = ""


def cmd_deliver_remote_to_receiver(repo_root: str, cfg_json: str,
                                   capture_file: str, line_idx: str,
                                   overrides_json: str = "{}") -> int:
    """Replay ONE captured remote POST through the REAL do_POST handler.

    A trimmed mirror of the P4.3 helper's `deliver-talk-to-receiver`: the enqueue
    boundary is monkeypatched to CAPTURE the delivery decision (no bridge-task.sh
    shell-out / live queue). `overrides_json` mutates the captured request
    ({"client_ip","headers","body","resign"}); `resign` recomputes a valid HMAC
    for a mutated body so the membership gate can be driven downstream of auth.
    """
    hd = _load_handoffd(repo_root)
    cfg = json.loads(cfg_json)
    captured = json.loads(_read_lines(capture_file)[int(line_idx)])
    overrides = json.loads(overrides_json) if overrides_json else {}

    path = captured.get("path", "/enqueue")
    headers = dict(captured.get("headers", {}))
    body = captured.get("body", "{}")

    if "headers" in overrides:
        headers.update(overrides["headers"])
    if "body" in overrides:
        body = overrides["body"]
    body_bytes = body.encode("utf-8") if isinstance(body, str) else bytes(body)
    if overrides.get("resign"):
        peer_secret = ""
        for p in cfg.get("peers", []):
            if p.get("id") == headers.get("X-AGB-Peer", ""):
                peer_secret = p.get("secret", "")
                break
        body_hash = a2a.body_sha256(body_bytes)
        headers["X-AGB-Body-SHA256"] = body_hash
        canonical = a2a.canonical_string(
            "POST", path, headers.get("X-AGB-Peer", ""),
            headers.get("X-AGB-Message-Id", ""),
            headers.get("X-AGB-Timestamp", ""), body_hash)
        headers["X-AGB-Signature"] = a2a.sign(peer_secret, canonical)
    headers["Content-Length"] = str(len(body_bytes))

    peer_id = headers.get("X-AGB-Peer", "")
    peer_addr = ""
    for p in cfg.get("peers", []):
        if p.get("id") == peer_id:
            peer_addr = p.get("address", "")
            break
    client_ip = overrides.get("client_ip", peer_addr or "127.0.0.1")

    delivery: dict = {}

    def _fake_enqueue(*, target, sender_bridge, sender_agent, priority, title,
                      body_file):
        delivery.update({
            "target": target, "sender_bridge": sender_bridge,
            "sender_agent": sender_agent, "priority": priority, "title": title,
        })
        return True, "9999", "created task #9999", "created task #9999"

    hd.enqueue_via_bridge_task = _fake_enqueue  # type: ignore[assignment]

    handler = hd.HandoffHandler.__new__(hd.HandoffHandler)
    handler.path = path
    handler.headers = _FakeHeaders(headers)
    handler.rfile = _FakeRFile(body_bytes)
    handler.client_address = (client_ip, 0)
    handler.server = _FakeServer(cfg)

    captured_reply: dict = {}

    def _capture_reply(status, payload, extra_headers=None):
        captured_reply["status"] = status
        captured_reply["payload"] = payload

    handler._reply = _capture_reply  # type: ignore[assignment]
    handler.do_POST()

    status = captured_reply.get("status", 0)
    payload = captured_reply.get("payload", {})
    delivered = bool(delivery)
    print(f"status={status} delivered={delivered} "
          f"body={json.dumps(payload, separators=(',', ':'))} "
          f"delivery={json.dumps(delivery, separators=(',', ':'))}")
    return 0


# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
def main(argv: list) -> int:
    if not argv:
        print("usage: 1594-rooms-fanout-helper.py <cmd> ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "post-hook":
        return cmd_post_hook(rest[0])
    if cmd == "local-hook":
        return cmd_local_hook(rest[0])
    if cmd == "make-config":
        return cmd_make_config(*rest)
    if cmd == "add-peer":
        return cmd_add_peer(*rest)
    if cmd == "seed-cache":
        return cmd_seed_cache(*rest)
    if cmd == "count-lines":
        return cmd_count_lines(rest[0])
    if cmd == "field-each":
        return cmd_field_each(rest[0], rest[1])
    if cmd == "nonmember-overrides":
        return cmd_nonmember_overrides(*rest)
    if cmd == "target-index":
        return cmd_target_index(rest[0], rest[1])
    if cmd == "deliver-remote-to-receiver":
        return cmd_deliver_remote_to_receiver(*rest)
    print(f"unknown helper cmd: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
