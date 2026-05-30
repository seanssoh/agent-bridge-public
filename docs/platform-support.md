# Platform Support

Agent Bridge runs on macOS and Linux, but the two platforms have
different support targets for multi-tenant isolation. Read this page
before choosing a production host.

## Summary

- **macOS is developer-only.** It is supported for building, smoke
  testing, and single-operator installs where every static agent is
  trusted at the same level as the logged-in user.
- **Linux is the production target for multi-tenant isolation.** Per-UID
  separation via `BRIDGE_AGENT_ISOLATION_MODE=linux-user` is Linux-only.
  macOS installs run in shared mode regardless of operator intent.

The rest of this document spells out what each platform does and does
not enforce, and why macOS does not ship an OS-user isolation backend.

## Multi-tenant isolation support matrix

| Capability | macOS | Linux |
|---|---|---|
| Hook-layer tool policy (`hooks/`, `bridge-hooks.py`) | Supported | Supported |
| Prompt guard (`bridge-guard.py`, `BRIDGE_PROMPT_GUARD_ENABLED`) | Supported | Supported |
| `audit.jsonl` daemon-side action log | Supported | Supported |
| `BRIDGE_AGENT_ISOLATION_MODE=shared` (default) | Supported | Supported |
| `BRIDGE_AGENT_ISOLATION_MODE=linux-user` (per-UID) | **Not supported** (silent no-op; see below) | Supported |
| `agent-bridge isolate <agent>` migration helper (see #85) | **Not supported** (exits with explanatory error) | Supported once #85 lands |
| Strict queue gateway audit trail with per-UID attribution | Not supported | Supported |

On a macOS host, the bridge treats every static Claude agent as one OS
principal. Enforcement is limited to the hook layer and operator
vigilance: Claude tool-policy hooks block writes to other agents' homes,
to `agent-roster.local.sh`, and to `state/tasks.db`, and every tool
call lands in `audit.jsonl`. That containment is useful against a
well-behaved model, but it is not a substitute for UID separation and
does not stop a process that bypasses Claude entirely.

## macOS behavior in detail

### Default isolation mode is shared

On macOS, a fresh install leaves `BRIDGE_AGENT_ISOLATION_MODE` unset,
which resolves to `shared` in `bridge_agent_isolation_mode` at
[`lib/bridge-agents.sh`](../lib/bridge-agents.sh). Every static agent
runs inside the same tmux server under the logged-in user's UID.

### linux-user requests fall back silently

`bridge_agent_linux_user_isolation_effective` in
[`lib/bridge-agents.sh`](../lib/bridge-agents.sh) requires all of:

1. The agent's roster declares `isolation_mode=linux-user`.
2. The host platform is Linux (`bridge_host_platform == Linux`).
3. A concrete `os_user` has been assigned.

On macOS, condition 2 always fails, so the bridge treats the agent as
shared even when the roster asks for `linux-user`. This is intentional
so that a roster synced from a Linux host does not crash a developer's
Mac — it just downgrades to the best available mode.

### `agent-bridge isolate` on macOS

The migration helper tracked by #85 (`agent-bridge isolate <agent>` /
`agent-bridge unisolate <agent>`) is Linux-only. Invoking it on macOS
exits with an explanatory error that points the operator at this page.
Do not bypass that check — the underlying operations (`useradd`,
`setfacl`, `sudo -u`) have no reliable macOS equivalent that preserves
Agent Bridge's per-agent home architecture.

### Why macOS does not ship an OS-user isolation backend

launchd's `User=` key is the nearest macOS analogue to systemd's
per-unit user isolation, but adopting it for Agent Bridge would
require:

- A sudo / setuid chain to drop privileges into each agent's UID from
  the operator's interactive shell, since launchd agents cannot be
  started interactively across users without elevation.
- A shared secrets store so every per-agent home can see the daemon's
  queue DB and shared wiki without each agent re-authenticating.
- Rewriting the per-agent home layout at `~/.agent-bridge/agents/<name>/`
  into a system-wide path that launchd can reach, breaking the single
  live-install root that `agb upgrade` depends on.

Those tradeoffs conflict with the core Agent Bridge design: one live
runtime under `$BRIDGE_HOME`, one operator-owned process tree, and no
system-wide daemon. Shipping a half-working macOS variant would create
the illusion of isolation without the guarantees, which is strictly
worse than documenting macOS as shared-mode-only.

See [#68](https://github.com/seanssoh/agent-bridge-public/issues/68) for
the full threat model and rationale, and [#85](https://github.com/seanssoh/agent-bridge-public/issues/85)
for the Linux-only migration helper.

## Recommendations

- **Personal Mac mini, single operator, trusted agents.** macOS with
  default shared mode is fine. Keep hook-layer tool policy and the
  prompt guard on.
- **Multi-operator production, untrusted external channel input.**
  Deploy on Linux and enable `linux-user` isolation for any agent that
  holds delegated credentials or external channel tokens. Audit the
  strict queue gateway (`bridge-queue-gateway.py`) and review
  `audit.jsonl` regularly.
- **Shared development host that straddles both.** Keep the source
  checkout portable, but do not assume that roster entries tagged
  `linux-user` enforce anything on your Mac.
