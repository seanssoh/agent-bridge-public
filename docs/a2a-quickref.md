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

You need **two** things today: the target agent id (`--to`) **and** the peer
bridge it lives on (`--peer`). Both are required for a 1:1 send.

```bash
agb a2a send --peer <peer-bridge-id> --to <agent-id> \
  --title "<subject>" --body "<text>" \
  [--from <your-agent-id>] [--priority low|normal|high|urgent] [--dry-run]
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

Don't know `<peer-bridge-id>` for that agent? See the next task.

> **(coming, #2025)** `--peer` auto-resolve — when the target agent is unique in
> a room you share, `--to` alone will determine the peer (and prompt you if
> ambiguous). Until then, `--peer` is required.

---

## Find which node / peer an agent is on

There is **no one-shot agent→node lookup yet** (`a2a whois` is **coming,
#2025**). The current, working way is to read it off a **room roster**, because
the roster lists every member as `agent@node`:

1. List the rooms you can see and pick the one the agent should be in:

   ```bash
   agb room list
   ```

   Each line shows `room_id  epoch=…  leader=<agent>@<node>  …`.

2. Show that room — the roster prints one `agent@node` line per member:

   ```bash
   agb room show <room_id>
   ```

   ```
   room <room_id> (epoch N, leader <agent>@<node>)
   members:
     - crm-dash-wdh@doohyun-mac (member)
     - …@… (leader)
   ```

   The part after `@` is the **node**; that node's bridge id is the `--peer` you
   pass to `agb a2a send`.

`agb room list` / `agb room show` are read-only and also work member-side (a room
you *joined* but do not lead is shown from the local roster cache).

> **(coming, #2025)** `a2a whois <agent>` — aggregate rooms + peers and answer
> "`crm-dash-wdh → doohyun-mac`" in one command, so you don't have to know a
> room id first.

---

## View the roster / who is reachable

| Question | Command | What it shows today |
| --- | --- | --- |
| What peers am I configured to reach? | `agb a2a peers list` | One row per peer: `id  address  secret=yes/NO  inbound_allowlist=[…]`. **Hostnames/addresses only — no per-peer agent list.** |
| What's my transport / receiver state? | `agb a2a net-status` (alias `agb a2a status`) | Configured transport, this node's listen addr, receiver liveness, peers, room count, per-peer UP/SUSPECT/DOWN. |
| Who is in a given room (the `agent@node` roster)? | `agb room show <room_id>` | Members as `agent@node`, the leader, epoch, and pending join requests. |

`peers list` / `net-status` are **peer (node) level** — they don't enumerate the
agents on each peer, which is why agent→node discovery goes through `room show`
(above).

> **(coming, #2025)** a per-peer **agent-roster column** in `peers list` /
> `net-status`, so a hostname alone isn't all you get.

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

### Important: self-service join is gated OFF by default today

The "unregistered joiner's request is accepted into a *pending* state on a valid
invite token" step is guarded by an env gate on the **leader's receiver** that is
**off by default**: the receiver checks `BRIDGE_A2A_ROOM_AUTOJOIN` and, unless it
is `1`, rejects the request with **403 `unknown peer`** (the request never
becomes a pending row). See `bridge-handoffd.py` (the `room_join` unknown-peer
path). This is the live behavior tracked by **#2024**.

So **today**, unless the leader's receiver process was started with
`BRIDGE_A2A_ROOM_AUTOJOIN=1` in its environment, step 2 returns
`403 unknown peer` and onboarding falls back to the **manual peer-first** path:
the leader registers the joiner as a peer (shared HMAC secret out-of-band,
reciprocal `handoff.local.json`) *before* the join, then approves. The
approval gate itself is unchanged — even with auto-join enabled, nobody joins
without an explicit leader `approve`.

> **(coming, #2024)** a discoverable, first-class way to enable the gate (wizard
> prompt + runbook), an actionable rejection that distinguishes
> "auto-join disabled (enable on the leader)" from "invalid token" — surfaced as
> a `room_autojoin_disabled` reason instead of a flat `unknown peer` — and
> verification that the joiner side derives its per-pair key from the invite
> token. Until #2024 lands there is **no supported operator verb** to flip the
> gate (it is not in the `agb config set-env` allowlist), so treat the
> single-invite flow as "verbs present, gate off" and use the manual path for a
> new machine. See **#2024** for the full self-service / autojoin design.

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
| `agb room join …` → **403 `unknown peer`** | Self-service auto-join gate is off on the leader (`BRIDGE_A2A_ROOM_AUTOJOIN` ≠ `1`), or the token is invalid/expired. | Use the manual peer-first onboarding path, or have the leader enable auto-join (see #2024). |
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
`peers list` / `net-status` agent-roster column. Tagged **(coming, #2024)**: a
supported toggle + actionable rejection for room self-service auto-join.
