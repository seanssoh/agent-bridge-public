#!/usr/bin/env python3
"""Helper for the 2073-autojoin-stale-peer-selfheal smoke (#2073).

File-as-argv sidecar (never a heredoc-stdin — footgun #11). The bulk of the
smoke reuses v0165-l4-token-join-helper.py; this file adds the verbs the
self-heal + bound tests need.

Subcommands (argv[1]):
  plant-peer <cfg> <peer_id> <addr> <secret>
      Add (or replace) a leader peer in the JOINER cfg with a caller-chosen
      secret + a leader_agent allowlist, so the bound test can prove the
      self-heal never clobbers a legit hand-provisioned (non-token) secret.
  seq-post-hook <payload_json>
      BRIDGE_ROOMS_TEST_POST_HOOK target that returns a SEQUENCED status, so the
      smoke can drive the acceptance-anchored self-heal retry in-process: the
      first in-process POST (signed with the stale secret) returns the 1st status
      in $SEQ_POST_STATUSES, the retry (signed with the candidate key) returns the
      2nd, etc. Each POST's signed request is captured to
      $SEQ_CAPTURE_DIR/post-<n>.json (n = 1-based call index) so the smoke can
      inspect WHICH key each attempt signed with. Falls back to 200 once the
      sequence is exhausted.
  peer-field <cfg> <peer_id> <key>
      print one peers[] field (re-exported for convenience).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def cmd_plant_peer(cfg_path: str, peer_id: str, addr: str, secret: str) -> int:
    p = Path(cfg_path)
    cfg = json.loads(p.read_text(encoding="utf-8"))
    peers = cfg.setdefault("peers", [])
    if not isinstance(peers, list):
        peers = []
        cfg["peers"] = peers
    entry = {
        "id": peer_id,
        "address": addr,
        "secret": secret,
        "inbound_allowlist": ["operator"],
        "port": 8787,
    }
    replaced = False
    for i, existing in enumerate(peers):
        if isinstance(existing, dict) and existing.get("id") == peer_id:
            peers[i] = entry
            replaced = True
            break
    if not replaced:
        peers.append(entry)
    p.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    try:
        os.chmod(cfg_path, 0o600)
    except OSError:
        pass
    print("planted")
    return 0


def cmd_seq_post_hook(payload_json: str) -> int:
    """Sequenced-status test post hook (#2073). Captures each in-process POST and
    returns the next status from $SEQ_POST_STATUSES so the smoke can exercise the
    acceptance-anchored self-heal retry (reject the stale-key attempt, accept the
    candidate-key retry). A non-2xx status is signaled by writing the status to
    stderr + exiting non-zero ONLY for the cross-node sender's own error mapping;
    instead we return the status precisely by printing a marker the smoke parses.

    The sender maps a non-zero exit to HTTP 503 and a zero exit to HTTP 200 (see
    _invoke_test_post_hook). To return an ARBITRARY status we cannot use stdout
    (that is the body). So we model just the two outcomes the self-heal retry
    needs: a REJECT (exit non-zero → the sender sees a non-2xx) and an ACCEPT
    (exit 0 → 200). $SEQ_POST_STATUSES is a comma list of `reject`/`accept`."""
    seq_dir = os.environ.get("SEQ_CAPTURE_DIR", "")
    statuses = os.environ.get("SEQ_POST_STATUSES", "")
    if not seq_dir:
        print("SEQ_CAPTURE_DIR unset", file=sys.stderr)
        return 1
    base = Path(seq_dir)
    base.mkdir(parents=True, exist_ok=True)
    # Determine this call's 1-based index from how many captures already exist.
    n = len(list(base.glob("post-*.json"))) + 1
    doc = json.loads(payload_json)
    client_ip = os.environ.get("CLIENT_IP")
    if client_ip:
        doc["client_ip"] = client_ip
    (base / f"post-{n}.json").write_text(json.dumps(doc), encoding="utf-8")
    verdicts = [s.strip() for s in statuses.split(",") if s.strip()]
    verdict = verdicts[n - 1] if n - 1 < len(verdicts) else "accept"
    if verdict == "reject":
        # Non-zero exit → the sender maps it to a 503 (a non-2xx the self-heal
        # retry treats as a rejection of the attempted key).
        print("rejected (sequenced test verdict)", file=sys.stderr)
        return 7
    print("{}")  # accept → exit 0 → the sender reports 200
    return 0


def cmd_peer_field(cfg_path: str, peer_id: str, key: str) -> int:
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
    for p in cfg.get("peers", []):
        if isinstance(p, dict) and p.get("id") == peer_id:
            print(p.get(key, ""))
            return 0
    print("", end="")
    return 0


def cmd_probe_no_bootstrap_persist(repo_root: str, cfg_path: str,
                                   leader_node: str, room: str,
                                   token: str) -> int:
    """#2073 r3 INVARIANT (codex): an override_secret join PROBE must be
    intrinsically non-persistent — it must NEVER bootstrap/persist a peer. We call
    `_post_room_join_request(override_secret=...)` against a cfg with NO peer for
    `leader_node` and assert it RAISES (override_probe_no_peer) and writes NOTHING
    to the config. Prints `ok` on the expected behavior, `LEAK ...` on a violation."""
    import importlib.util

    # bridge-rooms.py imports bridge_rooms_common / bridge_a2a_common as siblings,
    # so the repo root must be on sys.path before we exec it.
    if repo_root not in sys.path:
        sys.path.insert(0, repo_root)
    spec = importlib.util.spec_from_file_location(
        "bridge_rooms_cli", os.path.join(repo_root, "bridge-rooms.py"))
    mod = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    os.environ["BRIDGE_A2A_CONFIG"] = cfg_path
    spec.loader.exec_module(mod)
    before = Path(cfg_path).read_text(encoding="utf-8")
    raised = ""
    try:
        mod._post_room_join_request(
            leader_node=leader_node, room_id=room, token=token,
            joiner_agent="probe", bootstrap_reach={"address": "127.0.0.1",
                                                   "port": 8787},
            override_secret="deadbeef" * 8)
    except Exception as exc:  # noqa: BLE001 - we EXPECT a raise
        raised = getattr(exc, "code", "") or type(exc).__name__
    after = Path(cfg_path).read_text(encoding="utf-8")
    if before != after:
        print("LEAK: the override_secret probe PERSISTED a peer (config changed)")
        return 1
    if leader_node in after:
        print(f"LEAK: the leader peer {leader_node} was written by the probe")
        return 1
    if not raised:
        print("LEAK: the override_secret probe did NOT raise on a missing peer")
        return 1
    print(f"ok raised={raised} no_persist=1")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: 2073-...-helper.py "
              "<plant-peer|seq-post-hook|peer-field|probe-no-bootstrap-persist> ...",
              file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "plant-peer":
        return cmd_plant_peer(rest[0], rest[1], rest[2], rest[3])
    if cmd == "seq-post-hook":
        return cmd_seq_post_hook(rest[0])
    if cmd == "peer-field":
        return cmd_peer_field(rest[0], rest[1], rest[2])
    if cmd == "probe-no-bootstrap-persist":
        return cmd_probe_no_bootstrap_persist(
            rest[0], rest[1], rest[2], rest[3], rest[4])
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
