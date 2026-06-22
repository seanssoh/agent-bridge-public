# A2A Rooms (beta) — operator usage

A2A **Rooms** is a room / leader(방장) / join-on-approval membership model that
unifies internal-team and cross-bridge agent messaging under one boundary. A
*leader* creates a room and hands out a one-time invite link; each agent posts a
join request with that link, and the leader approves or denies it. The same room
membership can then back an **opt-in internal-queue ACL** so inter-agent queue
creates are restricted to agents that share a room.

This page is the **operator usage** reference. The full design rationale,
schema, and security derivation live in
[`docs/design/a2a-rooms-design.md`](./design/a2a-rooms-design.md) — this page
does not duplicate it.

> **Scope (as of `v0.16.0-rc1`): cross-node rooms (P4) are wired and
> multi-node-verified.** The single-node control plane (P1: `rooms.db`, the
> `agb room` CLI, the OS-enforced leader ACL) and the **cross-node** layer (P4:
> roster broadcast over the node-link, join-on-approval across nodes,
> relay-through-leader) are both live. A room created on node A reaches an agent
> on node B: `agb room create / join / approve / show`, the `agbroom://` invite,
> the per-room epoch bumps, and the P4.2 leader roster-broadcast were all
> confirmed cross-node on a live 2- and 3-node Tailscale mesh. What was verified:
> single-leader rooms with invite/join/approve, leader roster-broadcast, and
> multi-node delivery for both 1:1 and room-scoped messages. Treat rooms as an
> internal-team OR cross-bridge boundary.
>
> **As of `v0.16.5` the multi-node mesh is self-healing** — a reconcile
> control-loop on the daemon tick converges actual network state toward desired
> membership without operator intervention. See
> [Zero-touch mesh](#zero-touch-mesh--the-reconcile-control-loop-v0165) below.

The CLI is `agb room <verb>` (equivalently `agent-bridge room <verb>`). All
verbs accept `--json` for machine-readable output; mutating verbs accept `--as`
(see [Acting identity](#acting-identity--the---as-flag) below). Data lives in
`state/handoff/rooms.db` (mode `0600`), preserved across `agb upgrade` like the
rest of `state/handoff/`.

---

## Quick reference

| Verb | Who | What |
|---|---|---|
| `agb room create --name <n>` | any agent | Create a room; you become its leader. Prints the invite link **once**. |
| `agb room list [--owned]` | any | List rooms (`--owned` = only rooms this node leads). |
| `agb room show <room_id>` | any | Show roster + epoch + pending join requests. |
| `agb room invite <room_id> [--once]` | leader | Mint a fresh invite token (`--once` = single-use). Invalidates the old one. |
| `agb room rotate-invite <room_id>` | leader | Rotate the invite token (always reusable), invalidating the old one. |
| `agb room join <link>` | joining agent | Post a join request using a token-bearing `agbroom://` link. |
| `agb room approve <room_id> <agent[@node]>` | leader | Approve a pending join (adds the member + bumps the epoch). |
| `agb room deny <room_id> <agent[@node]>` | leader | Deny a pending join request. |
| `agb room kick <room_id> <agent[@node]>` | leader | Remove a member (bumps the epoch). |
| `agb room leave <room_id>` | member | Leave a room you are in (bumps the epoch). |
| `agb room adopt-all [--name <n>]` | any | Create a default room containing **every current roster agent** (the migration before `acl enforce`). |
| `agb room acl [off\|enforce] [--force]` | controller/operator | Show or set the internal-queue ACL mode (default **off**). |

---

## Rooms lifecycle

### 1. Create a room (you become the leader)

```bash
agb room create --name "frontend-team"
```

Output (the invite link is printed **once** — only its sha256 hash is stored in
`rooms.db`, so copy it now):

```
[rooms] created room <room_id> (leader <you>@<node>, epoch 0)
Invite link (shown ONCE — store it now, only its hash is kept):
agbroom://join?room=<room_id>&leader=<node>&t=<token>
```

`--name` is optional (defaults to empty). On a single-node install `<node>` is
the A2A config `bridge_id`, or empty if no A2A config is present — both are fine.
Across nodes, `<node>` is the peer's `bridge_id` and the invite link carries it
so a member on another node can route its join request back to the leader.

### 2. Share the link, then each agent joins

The leader shares the `agbroom://` link with the agent they want to admit. That
agent posts a join request:

```bash
agb room join 'agbroom://join?room=<room_id>&leader=<node>&t=<token>'
```

A join is **two-factor**: the token gets the request *to* the leader, and the
leader's explicit approval *admits*. A leaked link by itself does not grant
membership. Join attempts are rate-limited per token + source, and the token is
verified by hash compare — an invalid token is rejected. The request lands as
`pending`.

> **Cross-node first-contact** (joining from a node the leader has never paired
> with) additionally needs the leader to have **room auto-join enabled** — see
> [Enabling first-contact room auto-join](#enabling-first-contact-room-auto-join-bridge_a2a_room_autojoin--runbook-2024).
> Without it the join returns `403 code=room_autojoin_disabled`. That response
> only proves the leader's auto-join gate is off (it is returned *before* any
> token check) — so do not rotate the invite for it; have the leader enable +
> restart, then retry.

### 3. Leader approves (or denies)

```bash
agb room show <room_id>          # see pending join requests
agb room approve <room_id> <agent>     # admit (bumps the epoch)
agb room deny    <room_id> <agent>     # reject the request
```

The target is `agent` or `agent@node` (a bare `agent` uses the local node). On a
single-node install `agent` is sufficient. Approving against a room whose invite
was minted with `--once` **burns** the invite token after that one approval.

### 4. Inspect rooms

```bash
agb room list            # all rooms: room_id, epoch, leader, name, status
agb room list --owned    # only rooms this node leads
agb room show <room_id>  # roster (members + roles), epoch, pending requests
```

### 5. Membership changes

```bash
agb room kick  <room_id> <agent[@node]>   # leader removes a member
agb room leave <room_id>                  # an agent removes itself
```

Both bump the room's epoch (the monotonic membership version).

### 6. Rotating / replacing invites

```bash
agb room invite <room_id>              # mint a fresh reusable token (old one dies)
agb room invite <room_id> --once       # mint a single-use token (burned on first approval)
agb room rotate-invite <room_id>       # rotate to a fresh reusable token
```

`invite` and `rotate-invite` both **invalidate the previous token** — any link
holding the old token stops working. `rotate-invite` is `invite` without
`--once` (always reusable). Both are leader-only.

---

## Internal-queue ACL (`rooms_acl`)

Rooms can gate the **internal queue**: with the ACL in `enforce` mode, an
inter-agent durable queue create (`create --to <target>`) is only allowed when
the sender and the target share a room. This is **off by default** — a fresh
install behaves exactly as before (all-to-all queue), so enabling rooms changes
nothing until you explicitly flip the ACL.

### Show / set the mode

```bash
agb room acl              # show the current mode (off | enforce)
agb room acl enforce      # turn enforcement on
agb room acl off          # turn it back off
```

Flipping the mode is an **operator / controller** action — a managed iso agent
cannot turn enforcement on or off (it is rejected hard under iso v2). See
[Acting identity](#acting-identity--the---as-flag).

### Migration: `adopt-all` before `enforce`

Flipping straight to `enforce` with **no rooms defined** would wall off every
inter-agent create. To make the migration safe, `agb room acl enforce` **refuses
to engage when no room exists** and points you at `adopt-all`:

```bash
# 1. Seed a default room with EVERY current roster agent, so nobody is stranded:
agb room adopt-all                 # default room name "default"
agb room adopt-all --name "all"    # or choose the name

# 2. Now enforcement is safe — existing agents already share the default room:
agb room acl enforce
```

`adopt-all` enumerates the live roster via `agb agent list --json` and adds every
agent (including you, as leader) to one room, then bumps the epoch so the cached
roster is fresh. After it, every existing agent shares a room, so `enforce`
strands no one.

If you genuinely want a fully locked-down install where only the
controller/daemon path can create tasks (no inter-agent traffic at all), you can
force enforcement without any room:

```bash
agb room acl enforce --force   # controller/daemon traffic still flows
```

### What `enforce` actually does

The decision is evaluated at the real queue-create paths (the iso-v2 queue
gateway as the primary OS-enforced gate, plus `bridge-queue.py` create as
defense-in-depth):

- **mode `off`** → always allow (true no-op, zero behavior change — the default).
- **controller / daemon / cron / receiver** → allow (they run as the controller
  OS user; this is the non-spoofable system exemption).
- **sender == target** (self-message) → allow.
- **no rooms defined** → allow (back-compat; `adopt-all` is the migration that
  makes the gate engage).
- **target is in no enforced room** → allow + audit (the gate is roster↔roster).
- **sender and target share a room** → allow.
- **otherwise (cross-room)** → **deny** under iso v2 (the hard team boundary);
  **advisory** (warn + audit, no block) in shared single-UID mode.

---

## Acting identity & the `--as` flag

Every mutating verb resolves the *acting agent* from the **process OS identity**,
not from a client-supplied flag. The behavior depends on the install's isolation
regime:

- **Linux-user isolation (iso v2)** — the acting agent is derived from the
  process OS uid and is **unspoofable**. `--as` is **ignored** for leader-auth:
  a managed agent cannot pass `--as <leader>` to impersonate the leader, and a
  managed agent cannot flip `rooms_acl`. Leader-only actions check the process's
  actual OS user against the leader's expected iso OS user.
- **Controller / operator shell** — a proven operator shell (the UID that owns
  `rooms.db` and the task DB) may use `--as <agent>` as the recorded acting
  identity. This is the operator override.
- **Shared mode (single UID)** — the OS cannot separate agents, so leader-auth is
  **advisory**: a non-leader action warns + audits but is not hard-blocked.
- **Unresolved** — on an iso host where the process is neither a known iso agent
  nor the controller, every mutation **fails closed**.

---

## Security model (honest summary)

- **Leader / controller authorization is OS-enforced**, not advisory, *only*
  under linux-user isolation (iso v2): the acting identity comes from the process
  OS uid, so a managed agent cannot impersonate the leader or flip the ACL.
- **The controller is trusted by construction.** Whoever owns the real
  `rooms.db` / task DB (the controller OS user — operator, daemon, cron,
  receiver) **bypasses** the room ACL. This is intentional (the system /
  operator exemption); rooms are an agent-to-agent boundary, not a sandbox
  against the controller.
- **Shared-mode (single-UID) installs are advisory.** With no per-agent OS
  separation there is no hard boundary to enforce — cross-room creates warn and
  audit but are not blocked. For a hard team boundary, run agents under iso v2.
- **`enforce` fails closed**, not open: a present-but-unreadable `rooms.db`, or
  an actor that cannot be OS-established on an iso host, results in a **deny**
  for a real OS-enforced sender (never a silent fall-open). Shared mode degrades
  such a fault to advisory because it claims no hard boundary anyway.
- **Invite tokens are never stored in the clear** — only the sha256 hash is
  persisted; the raw token lives only in the `agbroom://` link, shown once.
  Tokens are room-scoped, rotatable, and optionally single-use; join attempts
  are rate-limited per token + source.

For the threat model, the trusted-call-path bypass, and the per-regime
derivation, see
[`docs/design/a2a-rooms-design.md`](./design/a2a-rooms-design.md) §9 and §14 R1.

---

## Cross-node status (P4)

Cross-node rooms (P4) are **wired and multi-node-verified as of `v0.16.0-rc1`**.
A room spans nodes, the leader's roster is broadcast over the node-link, and a
join is approved across nodes. The following were confirmed on a live 2- and
3-node Tailscale mesh:

- **Single-leader rooms** with `agb room create / join / approve / show`.
- **`agbroom://` invite links** + per-room `epoch` bumps on membership change.
- **P4.2 leader roster-broadcast** — the leader's canonical roster reaches member
  nodes over the node-link.
- **Multi-node delivery** for both 1:1 (`agb a2a send`) and room-scoped messages.

Still maturing (covered by the `rooms-p4-*` smokes with a stubbed transport, not
yet part of the live-mesh verification above):

- **Cloudflare Zero Trust transport** — only the Tailscale transport is exercised
  on the live mesh; the transport-negotiation seam exists but ZT is unverified.

---

## Zero-touch mesh — the reconcile control-loop (`v0.16.5`)

As of `v0.16.5` the multi-node mesh is **self-healing**. The single human input
is the **desired state** — room membership (set with the `agb room` verbs above)
plus the per-node transport config. Everything else — each node's reachable
address, tunnel health, peer reachability, and the applied roster epoch — is the
*actual state* the system continuously drives back toward desired, the way a
Kubernetes controller reconciles a deployment.

### How it works

A **reconcile control-loop** runs on the handoff daemon's tick. On each pass it
compares the desired state (membership + transport config) against the observed
actual state and, where they diverge, runs a small finite-state-machine step to
converge them. Steps are **idempotent** and use **durable backoff** — a step that
can't complete (peer down, tunnel flapping) is retried with growing delay,
persisted in `reconcile.db`, so a transient fault doesn't wedge the loop and a
recovered peer rejoins without operator action. The loop never *creates*
membership; it only enacts the membership you set with `agb room`.

### The three self-heal adapters

Convergence work that is transport-specific lives behind three per-transport
adapters, so the control-loop logic itself stays transport-agnostic:

- **Stable-address adapter (#1705)** — acquires/re-acquires this node's stable
  reachable address via the active transport, so peers can always find it after a
  re-tunnel or address change.
- **Tunnel-health adapter (#1706)** — probes the transport tunnel and bounces it
  when the handshake goes stale, restoring connectivity without a manual restart.
- **Peer-reachability adapter (#1707)** — tracks which peers are actually
  reachable and feeds that FSM state back into the loop (and into `net-status`),
  driving retries for peers that have gone dark.

### Token-bootstrap room join, leader-relay, roster anti-entropy (#1695)

- **Token-bootstrap join (P1)** — a new node joins a room straight from a room
  token: only `sha256(token)` crosses the wire, an HKDF-derived per-pair key
  secures the pair channel, and the existing **two-factor admission** still
  applies (the token gets you *to* the leader; the leader's approval *admits*).
  A leaked token alone still does not grant membership.
- **Leader-relay (P2)** — the leader relays member↔member traffic, so members
  that can each reach the leader can exchange messages without a direct
  member-to-member tunnel.
- **Roster anti-entropy (P2)** — member nodes converge on the leader's canonical
  roster epoch automatically; a node that missed a membership change catches up
  on the next reconcile pass instead of drifting.

### Enabling first-contact room auto-join (`BRIDGE_A2A_ROOM_AUTOJOIN`) — runbook (#2024)

Token-bootstrap join (above) is **gated OFF by default** on the leader's A2A
receiver. With the gate off, a brand-new node's first `agb room join '<signed
invite>'` is rejected with **HTTP 403 `code=room_autojoin_disabled`** — the
leader has not opted in to first-contact auto-join. This code is **posture
only**: the gate fires *before* any token or room check, so it tells you the
gate is off but says **nothing** about whether the invite itself is valid (an
expired/revoked/wrong-room invite gets the same code while the gate is off).
Opt-in is deliberate: auto-join only ever creates a **pending, leader-approved**
join (it admits nobody automatically), but it is the only place the receiver
does any pre-auth work for an *unknown* peer.

`agb room invite` and `agb a2a setup --show-state` both warn the leader when
this gate is off. To turn it on:

**Leader** (enable once, then hand out invites):

```bash
agb config set-env BRIDGE_A2A_ROOM_AUTOJOIN=1   # writes $BRIDGE_HOME/agent-env.local.sh
agb a2a daemon restart                          # re-sources the override into the receiver
agb room invite <room_id>                       # mint the signed invite to hand out
```

> The receiver spawn sources the install-wide `agent-env.local.sh` override
> directly before launch (#15783), so a restart picks up
> `BRIDGE_A2A_ROOM_AUTOJOIN` whether you go through `agb a2a daemon restart`
> or a direct `bash bridge-handoff-daemon.sh start`. To turn the gate back
> **off**, remove the key from `agent-env.local.sh` and restart.

**Joiner** (single signed link completes onboarding):

```bash
agb room join '<signed invite link>'
```

**If the joiner gets `room_autojoin_disabled`**: this response proves *only*
that the leader's auto-join gate is disabled (it is returned before any token
check, so it does not confirm the invite is valid). Ask the leader to run the
two commands above and restart the receiver, then retry. **Do not rotate the
invite** for this error; rotation does not change the leader's gate posture. If
the retry *still* fails after the leader has enabled + restarted, then
troubleshoot token validity / leader routing — once the gate is on, a genuinely
invalid/expired token or a non-leader node is rejected with the opaque
`unknown peer` (the gate only ever reveals the leader's posture, never room
existence or token validity).

### `agb a2a net-status` — the control-loop status window (v2, #1708)

`agb a2a net-status` (alias `agb a2a status`) is the **read-only** window into
the mesh control-loop. It is **active-transport-only**, performs **zero state
mutation** (it never creates or writes `rooms.db` / `reconcile.db`; it opens
reconcile state read-only), prints **no secrets**, and emits **stable JSON** with
`--json`. v2 surfaces, on top of the v1 fields:

- **bridge_id / transport / listen addr** — this node's identity and active
  transport.
- **receiver healthz** — reuses the #1701-hardened liveness path (a socket-held
  WARP-mesh receiver reads healthy).
- **substrate health** — the transport tunnel's own health.
- **reconcile FSM step state** — per-step last result + pending-retry counts for
  the stable-address, tunnel-health, and peer-reachability steps, so you can see
  what the loop is currently working on.
- **peers + room membership** — the reachable peer set and this node's room
  roster view.

```bash
agb a2a net-status            # human-readable mesh status
agb a2a net-status --json     # stable JSON for scripting / cron
agb a2a status                # ergonomic alias
```

Use it as the first stop when a peer looks unreachable: the reconcile step state
tells you whether the loop has already detected the problem and is retrying
(usually it has — zero-touch), or whether the desired membership/transport config
itself is wrong (operator input).

### ★ Local test mesh isolation — override `BRIDGE_STATE_DIR`, not just `BRIDGE_HOME`

> **Stand up a local multi-node test mesh and you can clobber the LIVE
> `state/handoff/rooms.db` if you only override `BRIDGE_HOME`.** This is the
> single most important gotcha when testing the mesh locally (finding #1728).

The A2A handoff working directory is resolved as
`$BRIDGE_STATE_DIR/handoff` — `handoff_dir()` consults **`BRIDGE_STATE_DIR`
first** and only falls back to `BRIDGE_HOME/state` when `BRIDGE_STATE_DIR` is
**unset**. So if your live environment exports `BRIDGE_STATE_DIR` (most do), a
test node that overrides only `BRIDGE_HOME` will still write its rooms /
reconcile / inbox / outbox state into the **live** `state/handoff/`, corrupting
or churning the real `rooms.db`.

To isolate a local test mesh, point **all** of these at your test home — not just
`BRIDGE_HOME`:

```bash
export BRIDGE_HOME="$TEST_HOME"
export BRIDGE_STATE_DIR="$TEST_HOME/state"          # the one that actually wins
export BRIDGE_A2A_ROOMS_DB="$TEST_HOME/state/handoff/rooms.db"
export BRIDGE_A2A_RECONCILE_DB="$TEST_HOME/state/handoff/reconcile.db"
export BRIDGE_A2A_INBOX_DB="$TEST_HOME/state/handoff/inbox.db"
export BRIDGE_A2A_OUTBOX_DB="$TEST_HOME/state/handoff/outbox.db"
```

(Each `BRIDGE_A2A_*_DB` also has an individual override that wins over the
derived path, so setting them explicitly is belt-and-suspenders against any one
of them leaking back to the live tree.) Reference issue **#1728**; a guard that
refuses to run a test mesh against the live state dir is planned for `v0.16.6`.

---

## Whole-room fan-out (`a2a send --room`)

Sending the same message to *every* member of a room — without naming each
recipient — is a first-class verb:

```bash
# fan a message out to every OTHER member of the room (you are excluded):
agb a2a send --room <room_id> --title "standup" --body "what's blocking you?"

# equivalently:
agb room send <room_id> --title "standup" --body "..."
agb room talk <room_id> --fanout --title "standup" --body "..."
```

What it does:

- **You must be a member of the room.** Membership is proven from *this node's
  own* leader-MAC roster cache / authoritative `rooms.db` — never from the flags
  you pass — so an agent that belongs to room A cannot address room B unless it
  is also a member of B. A non-member send is refused before anything leaves.
- **You are excluded** from the recipient set (no self-delivery).
- **The room roster decides the recipients.** Members on **this same node** are
  delivered through the **local internal queue** (`bridge-task.sh create`, the
  same durable boundary every inter-agent task uses); members on **other nodes**
  are delivered via the **cross-node room-scoped A2A** path (node-link + HMAC +
  the room epoch — exactly what `room talk` uses). The receiver on each remote
  node independently re-checks membership against its own cached roster (the
  sender-side check is an *additive* gate, it does not replace the receiver's).
- **Partial failures don't abort the rest.** Each recipient is attempted
  independently; failures are collected and reported per recipient.

`--to <agent[@node]>` narrows a fan-out to a single member; `--priority`,
`--body-file`, and `--allow-empty-body` work as they do for a 1:1 send. `--peer`
(1:1 cross-bridge) and `--room` (fan-out) are mutually exclusive.

With `--json`, the result is machine-readable:

```json
{
  "room_id": "<room_id>",
  "epoch": 7,
  "sender": "alice@nodeA",
  "delivered": [
    {"agent": "dave", "node": "nodeA", "leg": "local"},
    {"agent": "bob",  "node": "nodeB", "leg": "remote"}
  ],
  "failed": [
    {"agent": "carol", "node": "nodeC", "leg": "remote",
     "status": 403, "detail": "..."}
  ],
  "legs": {"local": true, "remote": true}
}
```

`delivered`/`failed` each tag the recipient with the **leg** used (`local` vs
`remote`), and `legs` records which legs fired at all. A fully-delivered send
exits `0`; any partial failure exits non-zero (`2`) so cron/callers notice.

> `room talk` (without `--fanout`) is unchanged: it stays cross-node only (it
> skips same-node members). The fan-out is the additive whole-room surface over
> the same machinery.
