# A2A — Cross-Bridge Task Handoff

**Issue**: #1032 · **Status**: implemented (v0.15.0-class feature)

A2A lets an agent on one Agent Bridge install enqueue a task directly into
another install's inbox queue — secure, audited, and with no human in the
loop. It replaces the manual copy-paste / ssh `bridge-task create` relay
that the operator previously did by hand.

## Model

N independent Agent Bridge installs each own a private `state/tasks.db`
queue. A2A is a **direct-mesh push gateway**: every install runs a receiver
daemon and a sender delivery runner. There is no central relay.

```
[bridge A]                                    [bridge B]
 agent ──► agb a2a send                        bridge-handoffd (tailnet IP only)
            │                                   │  POST /enqueue  (a2a-enqueue-v1)
            ▼                                   ▼
   outbox.db (SQLite, durable)         HMAC verify · remote_addr==peer
            │  delivery runner                 · allowlist (peer,target) exact
            │  retry+backoff+jitter             · dedupe (inbox.db, message_id)
            └────── HTTP POST ──────────────►   · bridge-task.sh create --body-file
                    (tailnet)                   └─► local queue + existing daemon nudge
```

Three fixed decisions shape the design:

1. **Network substrate = Tailscale.** All nodes join a tailnet; the
   receiver binds to a tailnet IP only — zero public-internet surface.
   WireGuard provides transport encryption + node identity.
2. **Auth = peer-pair secret + receiver allowlist.** The HMAC secret is
   scoped to an ordered pair (A→B). Receiver B declares, per peer, the
   allowlist of local agents that peer may enqueue to.
3. **Protocol = symmetric fire-and-forget enqueue.** No correlation IDs,
   no result channel. A reply is just another A2A enqueue in reverse.

## Components

| File | Role |
|------|------|
| `bridge_a2a_common.py` | Shared module: wire protocol, HMAC scheme, config loader, `outbox.db` / `inbox.db` schemas. Imported by both sides. |
| `bridge-a2a.py` | CLI — `send` / `outbox` / `inbox-dedupe` / `peers` / `deliver`. Reached via `agent-bridge a2a ...`. |
| `bridge-handoffd.py` | Receiver daemon — tailnet-bound HTTP listener. |
| `bridge-handoff-daemon.sh` + `lib/bridge-a2a.sh` | Receiver/runner lifecycle (start/stop/status/tick). |
| `handoff.local.json` | Data-only JSON config (mode 0600, git-ignored). |

## Security model

- **Bind**: the receiver binds ONLY to the configured tailnet IP. Startup
  fails **closed** if the bind address is `0.0.0.0`, `::`, a loopback, or
  not proven to be in this node's actual local Tailscale address set
  (the exact output of `tailscale ip`). There is no CIDR-shape fallback:
  a "tailnet-shaped" address (e.g. inside `100.64.0.0/10`) does not prove
  it is a real Tailscale interface, since a host can have a non-Tailscale
  CGNAT interface. If the `tailscale` CLI / local Tailscale address set
  cannot be determined, the daemon refuses to serve. The `tailscale` CLI
  is located on `PATH` first, then in well-known install locations
  (`/opt/homebrew/bin`, `/usr/local/bin`,
  `/Applications/Tailscale.app/Contents/MacOS`, `/usr/bin`) — a receiver
  started from cron/launchd/systemd often has a minimal `PATH`. Set
  `BRIDGE_A2A_TAILSCALE_CLI` to an explicit path for a non-standard
  install. `remote_addr == configured peer tailnet IP` is enforced
  before the request body is read.
- **Self-heal (no manual restart on IP churn).** A running receiver
  re-resolves its own bind and re-reads `handoff.local.json` on a periodic
  reconcile (and on `SIGHUP`), so a local Tailscale-IP change (after a
  tailnet re-login) and config edits take effect **without** a
  `bridge-handoff-daemon.sh restart`:
  - **Bind reconcile (auto-rebind on local-IP drift).** When the proven
    bind address changes, the listener is torn down and re-created on the
    new address — through the **same** fail-closed proof as startup (the
    candidate must be in this node's `tailscale ip` set; wildcard/loopback
    and a Tailscale-unavailable query are refused). A reconcile that cannot
    re-prove a new bind **keeps the current proven bind** (never an unproven
    one) and logs a warning; the daemon does not crash. An actual rebind
    emits an audit line `rebind old=<addr>:<port> new=<addr>:<port>`.
  - **Config hot-reload.** A newly-added/removed peer, allowlist entry, or
    cap edit is picked up live. Hot-reload is fail-closed: a malformed or
    unprovisioned-peer reload is rejected, the last-good config is kept, and
    a warning is logged — the allowlist / peer table is never replaced by a
    half-parsed config.
  - **Cadence + trigger.** The reconcile interval defaults to 45s,
    overridable via `BRIDGE_A2A_RECONCILE_INTERVAL` (seconds; `0` disables
    the timer — `SIGHUP` still works). `agent-bridge a2a reconcile` (and
    `bridge-handoff-daemon.sh reconcile` / `tick`) trigger an immediate
    reconcile and print a fail-closed preview of what the daemon would
    bind/reload.
  - Per-request inbound source-address auth already resolves an
    identity-keyed peer's current IP, so inbound self-heals for identity-
    keyed peers with no restart; this reconcile additionally closes the
    local-bind-drift and added/removed-peer cases.
- **HMAC-signed requests** (not raw bearer tokens — avoids replayable
  strings in process/log surfaces). The peer-pair secret is the HMAC key.
  - Headers: `X-AGB-Protocol: a2a-enqueue-v1`, `X-AGB-Peer`,
    `X-AGB-Message-Id`, `X-AGB-Timestamp`, `X-AGB-Body-SHA256`,
    `X-AGB-Signature: v1=<hex>`.
  - **`X-AGB-Peer` is the SENDER's own `bridge_id`** — the authenticated
    sender identity the receiver looks up in its inbound peer table. It
    is *not* the destination peer id. The sender resolves routing
    (address/port) and which HMAC secret to sign with by the destination
    peer, but signs + sends its own `bridge_id` as the peer identity. The
    receiver additionally rejects (`422`) any request whose envelope
    `sender.bridge` does not match the authenticated `X-AGB-Peer`.
  - Canonical string (newline-delimited): method, path, sender bridge id,
    message id, timestamp, body sha256.
  - Signed **per HTTP attempt** (not at outbox creation) so retries after
    sleep carry fresh timestamps.
- **Replay defense**: the receiver durably dedupes on `message_id`. Same
  id + same body hash → idempotent success returning the original local
  task id. Same id + different hash → `409` + a security audit event. A
  timestamp window rejects stale signatures; clock-skew rejection is
  explicit and includes the receiver's clock in the response.
- **Allowlist**: receiver-owned, exact-match `(peer_id, target_agent)`,
  no wildcard default. Optional per-peer caps: body/title size, max open
  tasks per peer.
- **Config is data-only**: `handoff.local.json` is JSON — parsed, never
  executed (it is consulted while handling untrusted remote traffic). The
  loader refuses a file that is group/world readable; it must be 0600.
- **Secret rotation**: the receiver accepts `secret` + `secret_next`
  during a short overlap window.
- **Audit**: every accept/reject/retry is logged (`logs/a2a-handoff.jsonl`)
  with peer id, target, message id, reason, local task id. The secret,
  signature key material, and full body are never logged.

## Migrating existing raw-IP configs (`agb a2a migrate-identity`)

Configs written before identity keying (and the `listen` / peer entries in
today's `handoff.local.json`) key on a bare `address`, so they do **not**
self-heal — only an identity-keyed entry does. `agb a2a migrate-identity`
rewrites them in place so the runtime resolution above actually applies:

```bash
agb a2a migrate-identity            # DRY-RUN (default): prints before->after, writes nothing
agb a2a migrate-identity --apply    # write the migrated config (mode 0600 preserved)
agb a2a migrate-identity --apply --drop-address   # also remove the now-redundant raw IP
```

It queries `tailscale status --json` once and, for each entry that has a raw
`address` but no identity, **reverse-resolves** that IP to its Tailscale node
(matching the IP against each node's `TailscaleIPs`). When **exactly one** node
owns the IP it records that node's `node_id` (StableID) + `tailscale_name`
(MagicDNS / HostName). The raw `address` is **kept as a fallback** by default
(resolver precedence stays `node_id` > `tailscale_name` > `address`); pass
`--drop-address` to remove it.

Fail-closed and conservative — it never guesses:

- `tailscale status --json` unavailable → **exits nonzero, changes nothing**.
- An IP that matches **zero** nodes (stale/offline) is left untouched (warns).
- An IP that matches **multiple** nodes (ambiguous) is left untouched (warns).
- It is **idempotent**: re-running on an already-identity-keyed config is a no-op.
- It **never** touches `secret` / `secret_next` / `inbound_allowlist` / `caps`
  / `port` / `bridge_id` — only the identity fields (and, with `--drop-address`,
  the migrated `address`) change.

## Protocol — envelope

```json
{
  "protocol": "agent-bridge.a2a.enqueue.v1",
  "message_id": "<sender-bridge-id>:<uuid>",
  "sender": { "bridge": "<bridgeA>", "agent": "<agentX>" },
  "target_agent": "<local-agent-on-B>",
  "priority": "normal",
  "title": "...",
  "body": "...",
  "reply_to": { "peer": "<bridgeA>", "agent": "<agentX>" }
}
```

The receiver creates the local task with `--from
a2a:<sender_bridge>:<sender_agent>` and prepends a provenance block to the
body (remote peer/agent, remote message id, and a ready-to-paste reply
example). Fire-and-forget — there is no correlated response.

## Receiver enqueue boundary

The receiver stages the body to
`$BRIDGE_STATE_DIR/handoff/incoming/<message_id>.md` (mode 0600), then
invokes the **existing** `bridge-task.sh create` as an **argv array**
(never a shell string), body passed via `--body-file`:

```
bash bridge-task.sh create --to <target> --from a2a:<peer>:<agent> \
  --priority <p> --title <title> --body-file <staged>
```

`bridge-task.sh create` already does local target validation
(`bridge_require_agent`), companion-review validation, prompt-guard
scanning, queue insertion, and notification dispatch — calling
`bridge-queue.py` directly would bypass those. `--skip-companion-validate`
is **never** exposed to remote peers.

A non-zero `bridge-task.sh create` exit maps to a retryable `503` only for
lock/transient failures; validation/guard/allowlist/size failures map to a
permanent `4xx`.

## Sender outbox

SQLite `$BRIDGE_STATE_DIR/handoff/outbox.db`. The outbox entry is written
**before** the first network attempt. A per-entry lease prevents two
runner loops from double-sending.

- Retry only on timeout / connection-refused / `429` / `5xx`; honor
  `Retry-After`; exponential backoff with jitter + ceiling.
- Permanent-fail on `400/401/403/404/409/413/422` → dead-letter.
- **Crashed-runner reclaim**: a row left in `status='sending'` with an
  expired lease (the runner that claimed it died mid-attempt) is demoted
  back to `retry` at the start of the next `deliver` tick, so it is
  re-attempted instead of wedged forever.
- GC: max attempts or max age → `dead`. Caps on total outbox bytes +
  per-peer pending count; over-cap, new sends fail locally with a clear
  remediation message (no silent unbounded disk growth).

## Receiver dedupe / backpressure

SQLite `$BRIDGE_STATE_DIR/handoff/inbox.db` tracks `message_id`, `peer`,
`body_sha256`, `created_task_id`, and `delivery_count`. Dedupe retention
(`inbox-dedupe gc`, default 60 days) deliberately exceeds sender retry /
dead-letter retention. Optional per-peer `max_open_tasks` applies
backpressure: over quota → `429` with `Retry-After`.

## Failure modes

| Situation | Mitigation |
|-----------|-----------|
| Receiver asleep / unreachable | sender outbox retry with backoff |
| Sender sleeps post-enqueue | resumes on the next `a2a deliver` tick |
| Duplicate POST / lost ACK | `message_id` dedupe → idempotent `200` |
| Replay | HMAC + timestamp window + dedupe |
| Secret leak | blast radius = the ordered pair + allowlist + caps; rotate via `secret`/`secret_next` overlap |
| Clock skew | explicit reject, receiver clock returned |
| Queue locked | `503` + sender retry |
| Prompt-guard / companion block | permanent `422` |
| Oversized / invalid body | `413` / `422` + dead-letter |
| Outbox growth | caps + dead-letter + `a2a outbox gc` |

## CLI surface

- `agent-bridge a2a send --peer <peer> --to <agent> --title <t> [--body ...|--body-file ...] [--priority ...] [--dry-run]`
- `agent-bridge a2a outbox list|retry <id>|drop <id>|gc`
- `agent-bridge a2a inbox-dedupe list|gc`
- `agent-bridge a2a peers list|test <peer>`
- `agent-bridge a2a deliver` — drain the outbox once
- `agent-bridge a2a daemon start|stop|restart|status|tick` — receiver lifecycle

The delivery runner can be daemon-driven or cron-driven (`a2a daemon
tick` ensures the receiver is up, then drains the outbox once).

`a2a daemon start` launches the receiver with a POSIX double-fork detach
(`bridge-handoffd.py serve --detach`) **after** the tailnet bind succeeds,
so the listener is reparented into its own session and survives the
launching shell / managed agent tool session exiting — a bare background
job is not durable from such shells. The detached process owns the pid
file, so `a2a daemon status` reflects the real long-lived listener. A
fail-closed bind error still surfaces synchronously as a non-zero exit
from `start` (the bind happens before the detach).

## Configuration

Copy `handoff.local.example.json` to `$BRIDGE_HOME/handoff.local.json`,
edit it, and `chmod 0600` it. It carries peer-pair HMAC secrets and is
git-ignored. Each peer entry declares: `id`, `address` (tailnet IP),
`secret` (+ optional `secret_next`), `inbound_allowlist`, and optional
`caps`.

## Out of scope (v1)

Correlated request/response, status mirroring, a central relay, an
external SaaS queue, and N-host auto-discovery. Peers are always
explicitly configured. The outbox transport is kept behind a narrow
interface so a relay could later be added as just another peer target.
