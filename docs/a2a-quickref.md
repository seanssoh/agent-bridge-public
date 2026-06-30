# A2A Quick Reference — by task

**Audience**: an agent (or operator) who has an **agent id** or a **room** and
needs to *do* something — send a message, find which node an agent is on, view
the roster, broadcast to a room, onboard a new machine, approve a join, or
troubleshoot. It is task-first and copy-pasteable.

For the protocol, security model, transports, and wire format, read
[`a2a-cross-bridge.md`](./a2a-cross-bridge.md) and
[`design/a2a-rooms-design.md`](./design/a2a-rooms-design.md). This page is the
"how do I actually use it" companion to those.

Commands are shown as `agb …`; `agb` is a thin forwarder to `agent-bridge`, so
`agent-bridge a2a …` / `agent-bridge room …` are identical. Cross-bridge A2A
needs the receiver daemon configured and running (`agb a2a setup`,
`agb a2a daemon status`).

> Some ergonomic shortcuts named in issue #2025 are **not built yet** and are
> marked **(coming, #2025)** below. Do not assume they exist — every command
> *without* that tag is a verb that exists in the current CLI.

---

## Send to an agent by id (1:1 cross-bridge)

You need the target agent id (`--to`). The peer/node it lives on (`--peer`) is
now **auto-resolved** from the agent id when you omit it (or pass `--peer auto`):

```bash
# Auto-resolve the node from the agent id (the common case):
agb a2a send --to <agent-id> --title "<subject>" --body "<text>" \
  [--from <your-agent-id>] [--priority low|normal|high|urgent] [--dry-run]

# Explicit node — always honored verbatim (no whois lookup):
agb a2a send --peer <peer-bridge-id> --to <agent-id> \
  --title "<subject>" --body "<text>"
```

- `--body-file <path>` instead of `--body` for long / multi-line bodies.
- `--dry-run` does the **local** checks (the peer is configured and has a
  secret, priority is valid, the body/title resolve and fit the caps) and prints
  what *would* be sent — it writes nothing to the outbox and does **not** contact
  the peer. It does not live-resolve the peer's current address, and the
  receiver's `inbound_allowlist` is enforced at delivery, not at dry-run — so a
  green dry-run means "well-formed and the peer is configured", not "the remote
  will accept it".
- Delivery is durable: the send lands in the local outbox and a delivery runner
  retries with backoff. Force a drain with `agb a2a deliver`.

Don't know `<peer-bridge-id>` for that agent? You usually don't need it — the
auto-resolver finds it. See the next task to look it up yourself.

**`--peer` auto-resolve (#2025).** When `--peer` is omitted (or `--peer auto`),
the node is resolved from `--to` via the same `a2a whois` lookup (the shared
room roster). It **never guesses**: if the agent is unique it proceeds (and
prints `--peer auto-resolved: <agent> -> <node>`); if the agent lives on
**multiple** nodes it **fails with the candidate list** so you re-send with an
explicit `--peer <node>`. An explicit `--peer <node>` is always used verbatim —
no whois, no behavior change from before.

---

## Find which node / peer an agent is on

One command, from just the agent id (#2025):

```bash
agb a2a whois <agent-id>
# crm-dash-wdh -> doohyun-mac
```

It aggregates every shared room roster (where each member is recorded as
`agent@node`) and answers `<agent> -> <node>`. The node it prints is exactly the
`--peer` you would pass to `agb a2a send` (and what `--peer auto` resolves to).
Three cases are handled explicitly:

- **unique** — prints `<agent> -> <node>` (annotated `(self)` if the agent is on
  this very node); exit 0.
- **ambiguous** — the same agent id is on **more than one** node. whois lists
  **every** candidate and exits nonzero — it never picks one. Re-send with an
  explicit `--peer <node>`.
- **not-found** — no shared room places the agent; clear error + nonzero exit.
  (You only see agents in rooms you share — confirm with `agb room list`.)

Add `--json` for the structured `{agent, status, node, candidates, self}` result
(nonzero exit on anything but `unique`, so a script can branch on the rc).

```bash
agb a2a whois <agent-id> --json
```

**Where the answer comes from.** whois is read-only over the **room roster** —
the same `agent@node` membership `agb room show <room_id>` prints, aggregated
across rooms so you don't have to know a room id first. There is **no new
registry**: it reuses the leader-authoritative `room_members` data. So whois only
sees agents you share a room with; for an agent in no shared room, fall back to
an explicit `--peer <node>`. `agb room list` / `agb room show` remain the
per-room view (and work member-side from the local roster cache).

---

## View the roster / who is reachable

| Question | Command | What it shows today |
| --- | --- | --- |
| What peers am I configured to reach? | `agb a2a peers list` | One row per peer: `id  address  secret=yes/NO  inbound_allowlist=[…]  known_agents=<a,b,…>`. The `known_agents` column (#2025) lists the agents known to live on that peer node, derived read-only from the shared room roster (`-` when none / no shared room). `--json` adds a `known_agents` array per peer. |
| What's my transport / receiver state? | `agb a2a net-status` (alias `agb a2a status`) | Configured transport, this node's listen addr, receiver liveness, peers, room count, per-peer UP/SUSPECT/DOWN. |
| Which node is a single agent on? | `agb a2a whois <agent-id>` | `<agent> -> <node>` from the aggregated room roster (ambiguous → candidate list, never a guess). See *Find which node / peer an agent is on*. |
| Who is in a given room (the `agent@node` roster)? | `agb room show <room_id>` | Members as `agent@node`, the leader, epoch, and pending join requests. |

The `known_agents` column and `a2a whois` both read the same room-roster source
(`room_members`) — a hostname alone is no longer all `peers list` gives you.

---

## Send to a whole room (fan-out)

One message to **every other member** of a room — local same-node members via the
internal queue, remote member-nodes via room-scoped A2A (you are excluded):

```bash
agb room send <room_id> --title "<subject>" --body "<text>" \
  [--to <member>] [--priority …] [--allow-empty-body]
```

Equivalent forms (same machinery):

- `agb a2a send --room <room_id> --title … [--json]` — `--json` gives a
  machine-readable per-recipient result.
- `agb room talk <room_id> --title …` — cross-node members only by default; add
  `--fanout` to ALSO reach same-node members via the queue (this is what
  `room send` does).

`--to <member>` narrows a fan-out to one recipient (`agent` or `agent@node`).
`--room` and `--peer`/`--to` (1:1) are mutually exclusive.

---

## Onboard a new machine into a room (self-service invite)

The intended flow is **leader mints a signed invite → joiner requests with it →
leader approves**. The verbs exist today:

1. **Leader** — create the room (once) and mint an invite link:

   ```bash
   agb room create --name "<room-name>"          # you become leader; prints the link ONCE
   agb room invite <room_id> [--once] [--ttl <seconds>]
   ```

   `--once` = single-use token; `--ttl` = expiry in seconds (default `0` = no
   expiry). The command prints an `agbroom://…` link that carries the token.

2. **Joiner** (the new machine) — post a join request with that link:

   ```bash
   agb room join '<agbroom://…>'
   ```

3. **Leader** — approve (or deny) the pending request:

   ```bash
   agb room show <room_id>                        # see pending join requests
   agb room approve <room_id> <agent|agent@node>
   ```

### Self-service join is ON by default (opt-out available)

The "unregistered joiner's request is accepted into a *pending* state on a valid
invite token" step is guarded by an env gate on the **leader's receiver**,
`BRIDGE_A2A_ROOM_AUTOJOIN`. **Since #2024 B this gate is ON by default**: an
unset receiver admits a valid first-contact invite token to a (still
leader-approved) **pending** join. Only an explicit off-spelling
(`BRIDGE_A2A_ROOM_AUTOJOIN=0` / `off` / `false`) forces the conservative
**403 `room_autojoin_disabled`** posture. See `bridge-handoffd.py` (the
`room_join` unknown-peer path) and `bridge_a2a_common.room_autojoin_enabled`.

The approval gate is unchanged — even with auto-join ON, nobody joins without an
explicit leader `approve`. Auto-join being on by default only converts a hard
403 into a fully-checked pending row for a valid token; every other gate (per-
pair HMAC, `remote_addr` pin, token TTL/revocation, dedupe, leader-approval)
still runs and a forged/expired token is still rejected with no pending row.

**Opt out** (restore the conservative default-OFF posture on a leader receiver):

```bash
agb config set-env BRIDGE_A2A_ROOM_AUTOJOIN=0   # writes $BRIDGE_HOME/agent-env.local.sh
agb a2a daemon restart                          # re-sources the override (#15783; a direct bash start sources it too)
```

To re-enable after opting out, set it back to `1` and restart. See **#2024** for
the full self-service / autojoin design.

---

## Approve / list pending joins (leader-side)

```bash
agb room show <room_id>                  # the "pending join requests:" block lists agent@node
agb room approve <room_id> <agent|agent@node>
agb room deny    <room_id> <agent|agent@node>
```

Other leader-side membership verbs:

- `agb room kick <room_id> <agent|agent@node>` — remove a member (bumps the epoch).
- `agb room rotate-invite <room_id>` — invalidate the current invite token and mint a new one.
- `agb room leave <room_id>` — remove yourself from a room you are in.

Leader authority is derived from the process OS identity, not from `--as` — a
managed (iso) agent cannot pass `--as <leader>` to satisfy a leader-only verb.

---

## Troubleshoot

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `agb room join …` → **403 `room_autojoin_disabled`** | The leader explicitly opted OUT of auto-join (`BRIDGE_A2A_ROOM_AUTOJOIN=0`/`off`). Auto-join is ON by default since #2024 B. | Have the leader re-enable it (`agb config set-env BRIDGE_A2A_ROOM_AUTOJOIN=1` + `agb a2a daemon restart`), or use the manual peer-first path. |
| `agb room join …` → **403 `unknown peer`** | The token is invalid/expired/revoked, or the room is not led by the target node (opaque peer-facing reply; the precise reason is in the leader's audit). | Re-mint a fresh invite on the leader and retry; confirm the leader node actually leads the room. |
| 1:1 `send` rejected at the peer | The peer's `inbound_allowlist` doesn't include your `--to` agent, or the peer/secret isn't configured. | The allowlist is checked **on the receiver**, so confirm it there: `agb a2a peers list` on the *peer* node shows each inbound peer's `inbound_allowlist`. (`--dry-run` on your side only validates local config, not the remote allowlist.) |
| Can't reach a peer at all | Receiver not up, firewall blocking the listen port, or stale peer address. | `agb a2a peers test <peer>` (TCP-connect probe only — no enqueue); `agb a2a net-status` for receiver liveness + per-peer state; check the host firewall on the receiver's listen port. |
| Peer keyed on a raw IP, drifts after re-login | The peer entry has an `address` but no Tailscale identity. | `agb a2a peers list` warns on this; run `agb a2a migrate-identity --apply` to identity-key it. |
| Sends pile up in the outbox | Delivery runner stuck on backoff. | `agb a2a outbox list`; `agb a2a deliver` to drain once; `agb a2a diagnose-stuck` to classify backoff-waiting rows and reset backoff for peers whose probe recovered. |

---

## Verbs referenced on this page (all current)

`a2a send` · `a2a peers list` · `a2a peers test` · `a2a net-status` (alias
`a2a status`) · `a2a deliver` · `a2a outbox` · `a2a diagnose-stuck` ·
`a2a migrate-identity` · `a2a setup` · `a2a daemon {start|stop|restart|status|healthz}` ·
`room create` · `room list` · `room show` · `room invite` · `room rotate-invite` ·
`room join` · `room approve` · `room deny` · `room kick` · `room leave` ·
`room send` · `room talk`.

Tagged **(coming, #2025)**: `a2a whois`, `a2a send --to` peer auto-resolve, the
`peers list` / `net-status` agent-roster column.
