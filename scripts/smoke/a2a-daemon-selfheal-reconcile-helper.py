#!/usr/bin/env python3
"""Helper for a2a-daemon-selfheal-reconcile.sh — drives the running-daemon
self-heal reconcile DECISION (P-self-heal phase 1, #1403) against a mock
`tailscale` CLI, printing a single deterministic token per case.

Kept as a standalone file (file-as-argv, never heredoc-stdin) per footgun
#11 + the lint-heredoc-ban ratchet. Invoked as:
    a2a-daemon-selfheal-reconcile-helper.py <mode> <args...>

`reconcile_once` is a PURE decision step — it reads only the live server's
`bound_address` / `bound_port` / `cfg` and calls `swap_cfg`; it does NOT bind
a socket (the serve loop performs the actual socket swap). So this helper uses
a lightweight stub that mimics that surface WITHOUT binding a real socket,
keeping the smoke fully portable (no need to plumb 127.0.0.2/127.0.0.3
loopback aliases, which macOS does not assign by default). The real socket
rebind path (serve_with_reconcile) is exercised by the repo's live runtime;
this smoke pins the decision + the fail-closed proof under reconcile.

Modes (each runs ONE reconcile_once against an on-disk config + the mock
tailscale, and prints the outcome):

  rebind <bind_addr> <port> <config_path>
        REBIND:<new_bind>:<new_port>   a rebind to a NEW proven bind was decided
        NOREBIND:<bind>:<port>         the proven bind was unchanged
        BINDKEEP:<code>                the bind could not be re-proven; the
                                       current (proven) bind is kept — the
                                       bind-proof-preserved-under-reconcile +
                                       Tailscale-unavailable behavior

  config <bind_addr> <port> <config_path> <expect_peer_id>
        CFGRELOAD:ok | CFGKEPT:<code>
        CFGADD:present | CFGADD:absent
"""

from __future__ import annotations

import importlib.util
import sys
import threading
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import bridge_a2a_common as a2a  # noqa: E402,F401  (kept for parity)

_spec = importlib.util.spec_from_file_location(
    "bridge_handoffd", str(REPO_ROOT / "bridge-handoffd.py"))
handoffd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(handoffd)


class _StubServer:
    """Mimics the HandoffServer surface reconcile_once reads — without binding.

    reconcile_once only touches `bound_address`, `bound_port`, `cfg`, and
    `swap_cfg(new_cfg)`. A real HandoffServer would bind a socket on
    construction, which on macOS fails for non-127.0.0.1 loopbacks; this stub
    avoids that so the decision + proof can be tested portably.
    """

    def __init__(self, bound_address: str, bound_port: int, cfg: dict) -> None:
        self.bound_address = bound_address
        self.bound_port = bound_port
        self.cfg = cfg
        self._cfg_lock = threading.Lock()

    def swap_cfg(self, new_cfg: dict) -> None:
        with self._cfg_lock:
            self.cfg = new_cfg


def _start_cfg(bind_addr: str, port: str) -> dict:
    # A minimal valid receiver config: one provisioned peer so the secret
    # gate passes, plus the current (start) listen.
    return {
        "bridge_id": "test-self",
        "listen": {"address": bind_addr, "port": int(port)},
        "peers": [
            {
                "id": "peer-a",
                "address": "127.0.0.50",
                "secret": "x" * 48,
                "inbound_allowlist": ["agent-1"],
            }
        ],
    }


def _mode_rebind(bind_addr: str, port: str, config_path: str) -> int:
    srv = _StubServer(bind_addr, int(port), _start_cfg(bind_addr, port))
    result = handoffd.reconcile_once(srv, Path(config_path))
    if result.want_rebind:
        print(f"REBIND:{result.new_bind}:{result.new_port}")
    elif result.bind_error:
        print(f"BINDKEEP:{result.bind_error}")
    else:
        print(f"NOREBIND:{result.old_bind}:{result.old_port}")
    return 0


def _mode_config(bind_addr: str, port: str, config_path: str,
                 expect_peer: str) -> int:
    srv = _StubServer(bind_addr, int(port), _start_cfg(bind_addr, port))
    result = handoffd.reconcile_once(srv, Path(config_path))
    if result.config_reloaded:
        print("CFGRELOAD:ok")
    else:
        print(f"CFGKEPT:{result.config_error or 'unchanged'}")
    peer_ids = [p.get("id") for p in srv.cfg.get("peers", [])
                if isinstance(p, dict)]
    print("CFGADD:present" if expect_peer in peer_ids else "CFGADD:absent")
    return 0


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "rebind":
        return _mode_rebind(sys.argv[2], sys.argv[3], sys.argv[4])
    if mode == "config":
        return _mode_config(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    print(f"ERR:bad-mode:{mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
