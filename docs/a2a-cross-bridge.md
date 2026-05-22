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
  fails closed if the bind address is `0.0.0.0`, `::`, a loopback, or not
  in the local Tailscale address set (CGNAT `100.64.0.0/10` / ULA
  `fd7a:115c:a1e0::/48` are accepted as a structural fallback when the
  `tailscale` CLI is unavailable). `remote_addr == configured peer
  tailnet IP` is enforced before the request body is read.
- **HMAC-signed requests** (not raw bearer tokens — avoids replayable
  strings in process/log surfaces). The peer-pair secret is the HMAC key.
  - Headers: `X-AGB-Protocol: a2a-enqueue-v1`, `X-AGB-Peer`,
    `X-AGB-Message-Id`, `X-AGB-Timestamp`, `X-AGB-Body-SHA256`,
    `X-AGB-Signature: v1=<hex>`.
  - Canonical string (newline-delimited): method, path, peer id, message
    id, timestamp, body sha256.
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
