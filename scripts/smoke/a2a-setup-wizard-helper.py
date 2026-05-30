#!/usr/bin/env python3
"""Helper for the a2a-setup-wizard smoke (#1415, design §5/§6/§7).

File-as-argv sidecar (never a heredoc fed into `python3 -`) so the smoke shell
never trips the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). Imports
`bridge_a2a_common` from the repo root so the smoke reads the SAME data-only
config loader + 0600 perm check the production code uses.

Scenarios (all read-only inspectors of the on-disk config / state — they never
write the config or start a daemon; the wizard itself does that, driven by the
shell):

  free-port                      print a free loopback TCP port
  wait-port <port>               exit 0 once <port> accepts connections (else 1)
  config-mode <config_path>      print the file mode as 4 octal digits (e.g. 0600)
  config-field <config_path> <dotted.key>
                                 print a scalar field from the config JSON
                                 (e.g. `bridge_id`, `listen.node_id`,
                                 `peers.0.id`); prints `<missing>` if absent
  peer-secret-set <config_path> <peer_id>
                                 print `yes` if the peer has a usable secret,
                                 else `no` (never prints the secret value)
  peer-count <config_path>       print the number of configured peers
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_a2a_common as a2a  # noqa: E402


def _free_port() -> int:
    import socket as _s
    sock = _s.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def _port_open(port: int) -> bool:
    import socket as _s
    sock = _s.socket()
    sock.settimeout(0.5)
    try:
        sock.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def _load_raw(config_path: str) -> dict[str, Any]:
    """Load the config JSON directly (bypassing the 0600 mode gate).

    The smoke asserts the mode separately via `config-mode`; this inspector
    just needs the parsed content so it can read fields even mid-test.
    """
    raw = Path(config_path).read_text(encoding="utf-8")
    doc = json.loads(raw)
    if not isinstance(doc, dict):
        raise ValueError("config root is not a JSON object")
    return doc


def _dotted(doc: dict[str, Any], key: str) -> Any:
    """Resolve a dotted key path; list indices are numeric segments."""
    cur: Any = doc
    for seg in key.split("."):
        if isinstance(cur, list):
            try:
                idx = int(seg)
            except ValueError:
                return None
            if idx < 0 or idx >= len(cur):
                return None
            cur = cur[idx]
        elif isinstance(cur, dict):
            if seg not in cur:
                return None
            cur = cur[seg]
        else:
            return None
    return cur


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: a2a-setup-wizard-helper.py <scenario> [args...]",
              file=sys.stderr)
        return 2
    scenario = argv[0]

    if scenario == "free-port":
        print(_free_port())
        return 0
    if scenario == "wait-port":
        return 0 if _port_open(int(argv[1])) else 1
    if scenario == "config-mode":
        try:
            mode = Path(argv[1]).stat().st_mode & 0o777
        except OSError as exc:
            print(f"ERR:stat:{exc}", file=sys.stderr)
            return 1
        print(f"{mode:04o}")
        return 0
    if scenario == "config-field":
        try:
            doc = _load_raw(argv[1])
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"ERR:load:{exc}", file=sys.stderr)
            return 1
        val = _dotted(doc, argv[2])
        if val is None:
            print("<missing>")
        elif isinstance(val, (dict, list)):
            print(json.dumps(val, ensure_ascii=False))
        else:
            print(val)
        return 0
    if scenario == "peer-secret-set":
        try:
            doc = _load_raw(argv[1])
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"ERR:load:{exc}", file=sys.stderr)
            return 1
        want = argv[2]
        for peer in doc.get("peers", []):
            if isinstance(peer, dict) and peer.get("id") == want:
                # Use the production helper so "usable secret" matches the
                # receiver's own definition (current + secret_next + list).
                print("yes" if a2a.peer_secrets(peer) else "no")
                return 0
        print("no")
        return 0
    if scenario == "peer-count":
        try:
            doc = _load_raw(argv[1])
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"ERR:load:{exc}", file=sys.stderr)
            return 1
        peers = doc.get("peers", [])
        print(len(peers) if isinstance(peers, list) else 0)
        return 0

    print(f"unknown scenario: {scenario}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
