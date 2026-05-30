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
  - **Bidirectional sync via a signed `peer-identity-update`.** A node whose
    bind reconciles (its own IP changed) pushes a signed control message to
    its peers so they auto-update that node's stored identity — closing the
    "peers don't know" gap. The receiver **re-corroborates the claim against
    its OWN `tailscale status --json` and never trusts the wire-asserted IP**,
    and only updates an **already-paired** peer. See
    "Signed `peer-identity-update` control message" below for the full
    fail-closed validation order.
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

## Signed `peer-identity-update` control message (`agb a2a announce-identity`)

Even with identity-keyed configs + per-request resolution, the
**first-contact / not-yet-migrated** gap remains: a peer that still has your
*raw IP* (or doesn't yet have your identity) won't self-heal, and **neither
side is notified** when the other's IP changes. The signed `peer-identity-update`
control message closes the bidirectional-sync gap — when a node's IP changes it
**notifies its peers**, and each peer auto-updates that peer's stored identity
**with no manual edit+restart on either side**.

```bash
agb a2a announce-identity              # push a signed update to ALL peers
agb a2a announce-identity --peer <id>  # to one peer
agb a2a announce-identity --dry-run    # resolve + show what would be sent, send nothing
```

The receiver daemon ALSO fires this automatically: when its self-heal reconcile
rebinds (i.e. this node's own Tailscale IP changed), it pushes the announce to
every configured peer as a fast-convergence step. This is the **single-flight
trigger** — the announce fires only on an actual local-IP change, not every tick.

**This is the A2A receiver's most security-sensitive surface — it MUTATES
stored peer identity in response to untrusted remote traffic.** It is built
strictly fail-closed:

- **Distinct protocol + endpoint.** The control message uses
  `X-AGB-Protocol: a2a-identity-update-v1` and is POSTed to a SEPARATE path
  (`/peer-identity-update`), routed to a dedicated receiver handler that never
  reaches the enqueue / allowlist / queue boundary. The signing path is part
  of the HMAC canonical string, so an enqueue signature can never be replayed
  against this endpoint and vice versa.
- **The receiver NEVER trusts the wire-asserted IP/identity.** The message only
  *prompts* a re-resolution the receiver independently verifies. The receiver's
  own `tailscale status --json` is the source of truth.

Receiver fail-closed validation **order** (every reject is audited with
`security=True`; **no mutation until all pass**):

1. **tailnet-only bind** — guaranteed at startup (`resolve_bind`).
2. **`remote_addr` == the authenticated sender peer's CURRENT resolved
   Tailscale IP** — resolved from the receiver's own view, checked **before the
   body is read** off the socket.
3. **HMAC signature verify** against that peer's secret(s) — `401` on mismatch
   (body-hash + constant-time signature compare, HMAC checked before any
   timestamp classification).
4. **`message_id` durable dedupe** (shared `inbox.db` ledger) — replay-safe;
   same id + same body → idempotent `200`; same id + different body → `409`.
5. **clock-skew window** — transient drift `503`, far-stale `401`.
6. **peer ALREADY PAIRED** — the sender must already be in the receiver's peer
   table with a matching secret; an unknown/unpaired peer → `403`. **This is
   NOT a discovery / trust-bootstrap channel.** The claimed `bridge_id` must
   match the authenticated `X-AGB-Peer` (a peer may only announce about itself).
7. **CRITICAL — corroborate against the receiver's OWN tailnet view.** The
   claimed (StableID / MagicDNS / IP) **must match what THIS receiver sees in
   its OWN `tailscale status --json`** for that peer's node, AND must resolve to
   the **same node** the receiver already has paired (the resolved StableID must
   equal the stored `node_id`; or, for a not-yet-migrated raw-IP peer, the
   resolved node must currently own the stored `address`). If the receiver's own
   status doesn't corroborate → **REJECT** (`409`, audited, fail-closed). The
   wire-asserted IP is never written on the strength of the wire alone.
8. **Scoped, idempotent, 0600-atomic apply.** On all checks passing, the
   receiver updates **only that peer's** identity in `handoff.local.json` to the
   **receiver-verified** values (read from its own status node, not copied from
   the wire), via the os.open-0600-from-start atomic write. It **never** touches
   `secret` / `secret_next` / `inbound_allowlist` / `caps` / `port` / other
   peers / `listen`. No-op when already current (idempotent). Then it
   **hot-reloads** the live config (the same fail-closed `swap_cfg` the
   reconcile uses) so the change takes effect with **no restart**.

## Receiver supervision (watchdog liveness + auto-restart) (#1405)

The self-heal reconcile above keeps a *running* receiver healed; it does
nothing when the process is **dead**. The receiver had no supervisor, so a
silent exit (no log line, no traceback) left the listen port unbound with no
auto-restart and no alarm — a "send-OK / receive-dead" half state the sender
retries into forever. The daemon now supervises the receiver as one more
managed lifecycle, alongside agents, cron workers, MCP liveness, and the two
existing A2A ticks.

Each `bridge-daemon` sync cycle runs a supervise tick (no-op without
`handoff.local.json`):

1. **Process gate** — `bridge_a2a_receiver_running` (pid + cmdline bound to
   this install's pidfile). Fail → dead, reason `process_gone`.
2. **Serve probe** — only when the process gate passes:
   `bridge-handoffd.py healthz` issues a read-only `GET /healthz` against the
   `resolve_bind`-proven address. Catches "pid alive but socket wedged /
   `serve_forever` deadlocked". One transient unhealthy probe is tolerated;
   two consecutive → dead (reason `healthz_timeout` / `healthz_status:<code>`).

On confirmed-dead, the supervisor captures an **exit-cause record** to
`state/handoff/receiver-exit.json` (mode 0600: the reason, last pid, a
secret-free tail of `logs/a2a-handoffd.log`, and the last terminal audit event
mined from `logs/a2a-handoff.jsonl`), emits an `a2a_receiver_died` audit row,
then **restarts via `bridge-handoff-daemon.sh start`** — which re-runs the
FULL fail-closed bind proof (synchronous preflight → `resolve_bind` → tailnet
membership → peer-secret gate). Restart NEVER shortcuts to a raw `serve`, so
resolve-then-prove cannot be bypassed, and the supervisor never sets the
`BRIDGE_A2A_ALLOW_TEST_BIND` / `BRIDGE_A2A_DEV_INSECURE_BIND` smoke-only
escape hatches.

**Alarm-and-hold, never hammer.** Two distinct give-up paths:

- **Crash-loop**: once restarts reach `BRIDGE_A2A_RECEIVER_MAX_RESTARTS`
  (default 5) within `BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS` (default
  600), auto-restart **STOPS**, the `crashloop` alarm is set, an
  `a2a_receiver_crashloop` audit row is emitted, and ONE cooldown-gated admin
  task is filed (`BRIDGE_A2A_RECEIVER_CRASHLOOP_ADMIN_COOLDOWN_SECONDS`,
  default 1800). A healthy probe (or the restart window elapsing) resets the
  counter and clears the alarm.
- **Persistent bind-proof failure**: if `bridge-handoff-daemon.sh start`
  returns non-zero (tailnet down, bind unresolvable, peer secret missing), the
  failure is a NON-retryable hold with the distinct `bind_proof_failed` reason
  — it counts toward the cap and stops, rather than re-probing Tailscale every
  30s.

**systemd defer.** On hosts where the `agb-handoffd.service` user unit owns
restart (`Restart=on-failure`; see `scripts/install-handoffd-systemd.sh`), the
supervisor detects the active unit and downgrades to **probe + alarm only** —
it never restarts, so two restart authorities can't fight over the pidfile.

The supervised state surfaces in `agent-bridge status` (an `A2A Receiver` row +
an `a2a=DOWN` / `a2a=ALARM` header flag, rendered only on A2A-configured
installs) and in `agb a2a daemon status` (restart count, alarm, last-exit
cause). `agb a2a daemon healthz` runs the same read-only probe by hand.

**Supervision env vars:**

| Variable | Default | Effect |
|----------|---------|--------|
| `BRIDGE_A2A_RECEIVER_SUPERVISE_INTERVAL_SECONDS` | `30` | Supervise-tick cadence. `0` disables supervision entirely (e.g. a host running the receiver under systemd that doesn't even want the daemon to probe). |
| `BRIDGE_A2A_RECEIVER_MAX_RESTARTS` | `5` | Restarts allowed within the window before the crash-loop alarm holds. |
| `BRIDGE_A2A_RECEIVER_RESTART_WINDOW_SECONDS` | `600` | Rolling window for the restart counter; elapsing it resets the counter + alarm. |
| `BRIDGE_A2A_RECEIVER_CRASHLOOP_ADMIN_COOLDOWN_SECONDS` | `1800` | Minimum gap between crash-loop admin tasks (the alarm itself stays set). |
| `BRIDGE_A2A_RECEIVER_HEALTHZ_TIMEOUT_SECONDS` | `3` | `GET /healthz` connect/read timeout. |

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
| Receiver silently dead / serve wedged | daemon supervise tick auto-restarts via the fail-closed `start`; crash-loop → alarm-and-hold + admin task + `status` flag (#1405) |
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
- `agent-bridge a2a announce-identity [--peer <id>] [--dry-run] [--timeout <s>]` — push a signed `peer-identity-update` to peers after an IP change
- `agent-bridge a2a daemon start|stop|restart|status|healthz|tick` — receiver lifecycle (`healthz` = read-only serve-liveness probe via `GET /healthz`)

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
