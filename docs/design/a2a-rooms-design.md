# A2A Rooms — unified room/team membership for internal + external agent comms

**Status:** design (2026-06-03, operator-converged). Supersedes the per-peer 1:1 mental model. Implements the operator's "방장(leader) + join-on-approval + roster-sync" vision, folding internal teams and external cross-bridge A2A into one **room** primitive.

## 1. Problem (today)

- **Internal A2A** (same server): every agent shares the SQLite queue; `bridge-task.sh create --to <agent>` is **unrestricted** (`bridge-queue.py cmd_create` — no membership ACL; only claim/done is actor-gated). All-to-all. No way to make a team that only talks among itself.
- **External A2A** (cross server): already node-to-node — a `peer` in `handoff.local.json` is a remote **bridge node** (`peer.id` + ordered-pair HMAC `secret`), and the envelope addresses `target_agent` on that node (`bridge_a2a_common.py:170,315`). But **every pair of nodes needs a hand-edited peer entry + shared secret on both sides** → M² node-link management burden, and connecting many agents across many servers is painful.
- Tailscale is hardwired as the only transport (`bridge_a2a_common.py:11` "Network substrate is Tailscale; the receiver binds to a tailnet IP only").

## 2. Target architecture — 3 layers

```
[3] Room / membership      logical ROOM (room_id) with a LEADER (방장 = agent@node),
                           a ROSTER (member agent@node list), join→approve→roster-sync,
                           explicit leave / leader-kick.  Internal team = a room whose
                           members are all on ONE node (enforced by the queue ACL).
        ▲ rides over
[2] Node-link (trust)      node(server)↔node HMAC trust link (today's `peer`, evolved):
                           ordered-pair secret, dedupe, allowlist. Established ONCE via a
                           human-mediated bootstrap-bundle exchange (patch↔patch). app-layer,
                           transport-agnostic.
        ▲ rides over
[1] Transport (pluggable)  tailscale | cloudflare-zt  (a node may declare one or both;
                           a link negotiates a common transport).
```

**Why the edge explosion goes away:** rooms are *logical* membership, not physical edges. You don't hand-configure node-pairs to add an agent — you **join a room** and receive its roster. Cross-node reach uses **existing node-links**, and where a direct node-link is absent the **leader's node relays** (so worst case you only need each node linked to the leader's node — hub-and-spoke, M node-links not M²), with an **auto-upgrade-to-direct** suggestion when relayed traffic is heavy.

## 3. Identity model

- **Node id** = the existing `bridge_id` (config root, `bridge_a2a_common.py:162`). Stable per install. (Bootstrap can auto-generate one if empty: `<hostname>-<rand>`.)
- **Agent address** = `agent@node` (e.g. `patch@cosmax-prod`). The envelope already carries `sender:{bridge,agent}` + `target_agent`; we extend addressing to the `agent@node` form derived from `target_agent` + the node-link.
- **Room id** = `room-<short-rand>` minted by the leader's node; globally unique enough for invite links.

## 4. Layer 1 — Transport abstraction (Tailscale + Cloudflare Zero Trust)

Introduce a transport interface consumed by `bridge-handoffd.py` (receiver bind/accept) and the delivery runner (sender connect):

- **`tailscale`** (refactor of today): receiver binds a tailnet IP; sender reaches the peer's tailnet addr; `remote_addr` must be in the tailnet CIDR. (Existing behavior, extracted behind the interface.)
- **`cloudflare-zt`** (new): receiver runs behind a **Cloudflare Tunnel** (`cloudflared`); inbound is gated by **Cloudflare Access** (a service-token: `CF-Access-Client-Id` + `CF-Access-Client-Secret`, or mTLS). The sender presents the service token; cloudflared routes to the local receiver bound on loopback. The Access identity is the transport-layer peer proof; the **HMAC envelope auth is unchanged** (app layer).

Node-link config gains `transports: [...]` with per-transport params:
```jsonc
"transports": [
  { "kind": "tailscale",     "listen_addr": "<tailnet-ip>:<port>" },
  { "kind": "cloudflare-zt", "hostname": "a2a.example.com", "access": { "client_id_env": "...", "client_secret_env": "..." } }
]
```
A node may declare one or both. A node-link negotiates a transport both sides support (priority: explicit `transport` on the link, else first common kind). **HMAC/dedupe/allowlist/skew checks are transport-independent** (stay in `bridge_a2a_common.py`).

## 5. Layer 2 — Node-link + the bootstrap-bundle flow

Evolve the `peers` config into `node_links` (keep `peers` as a back-compat alias; auto-migrate on load — a `peer` becomes a `node_link` with `transports:[{kind:tailscale,...}]` inferred from `listen`). A node-link: `{ id (remote node id), secret, secret_next?, transports, allow:[room_ids?], caps }`.

**Bootstrap (operator's flow, formalized):** `agb node-link bootstrap` is a 1-time human-mediated handshake:
1. **Node A** `agb node-link bootstrap --init` → mints a **bundle** = `{ node_id_A, transports_A (reach info), bootstrap_secret (single-use, short-TTL), nonce }`, prints it (copy/QR). The bootstrap_secret is **distinct** from the long-term node-link secret and only authorizes completing THIS handshake.
2. Human carries the bundle to **Node B**'s operator. `agb node-link bootstrap --accept <bundle>` → Node B configures its side, derives the long-term ordered-pair secret (HKDF over both node ids + a fresh contribution), reaches Node A over the declared transport with an HMAC proof keyed by `bootstrap_secret`.
3. **Node A** receiver validates the bootstrap proof (single-use, TTL, nonce) → finalizes the long-term node-link both sides → handshake ack → bootstrap_secret burned. Node-link is live.

This replaces hand-editing `handoff.local.json` + the #1415 wizard becomes the bootstrap driver.

## 6. Layer 3 — Rooms (the control plane) — NEW

### Data (new `rooms.db` SQLite under `state/handoff/`, leader-authoritative + member-cached)
```sql
rooms(room_id PK, name, leader_agent, leader_node, created_ts, invite_token, invite_token_ts, status)
room_members(room_id, agent, node, role TEXT /*leader|member*/, joined_ts, PRIMARY KEY(room_id,agent,node))
room_join_requests(room_id, agent, node, requested_ts, status /*pending|approved|denied*/, PRIMARY KEY(room_id,agent,node))
```
The **patch (node controller) keeps a registry of rooms whose leader is on its node** (the operator's "관리용 방 목록") — a view over `rooms` where `leader_node == this node`.

### Invite link + the secret-in-link question (operator Q1/Q2 — ANSWERED)
A room invite link carries a **capability join-token**, NOT a node-link secret:
```
agbroom://join?room=<room_id>&leader=<leader_node>&reach=<transport-hint>&t=<join_token>
```
- The `join_token` is **room-scoped, leader-revocable, optionally TTL'd**. It authorizes *requesting* to join — **two-factor: token → leader approval**. Link leak ≠ admission, because the **leader still approves** after verifying the requester is a genuine Agent Bridge agent (attested by the requester's node over the node-link HMAC; if no node-link yet, the join triggers the node-link bootstrap/relay path).
- **Reusable by default** (one rotatable invite-token per room, like a Discord invite but with an approval step). Leader `agb room rotate-invite` invalidates the old. No need to mint a new link per agent (friction without security gain, since approval is the real gate). Single-use tokens available via `agb room invite --once` for high-security cases.

### Flows
- **Create:** `agb room create --name <n>` (run as the leader agent) → mints `room_id`, leader row, invite token. Patch indexes it.
- **Join request:** joiner `agb room join <link>` → opens/uses the node-link to the leader's node (bootstrap or relay if none) → posts a join-request (room_id, agent@node, join_token).
- **Approve/deny:** leader `agb room approve <agent@node>` / `agb room deny ...` → on approve, add to `room_members` → **broadcast the updated roster to every member** (over node-links; relay where needed).
- **Talk:** a member reads the roster → addresses any member by `agent@node`. Internal members → the local queue (subject to the team ACL, §7). Remote members → the existing outbox/envelope, `target_agent`=their agent, peer=their node-link (or leader-relay).
- **Leave:** `agb room leave <room_id>` (explicit, operator's contract) → leader removes + roster re-broadcast. **Kick:** leader `agb room kick <agent@node>`.
- **Roster cache:** each member persists the roster locally (`room_members` rows for rooms it's in) so comms survive a leader outage; only NEW joins block while the leader is down (no auto-failover this phase — Phase-2 backlog: deputy succession).

### Relay → auto-upgrade-to-direct (operator Q4 — ANSWERED)
When member X@A sends to Y@C and there is **no A↔C node-link**: route via the **leader's node** (A→leader→C). The relaying patches detect sustained cross-node traffic and **emit an advisory to BOTH human operators**: "X@A ↔ Y@C is relaying through <leader>; establish a direct A↔C node-link for efficiency? [approve]". On **dual human approval**, the patches **auto-run the node-link bootstrap** (§5) A↔C → subsequent traffic goes direct.

## 7. Internal teams = single-node rooms + queue ACL (NEW, greenfield)

A **team** is just a room whose members are all on one node. Enforce it where it was previously open: `bridge-queue.py cmd_create` (and `bridge-task.sh create`) gains a **room-membership check** — `create --to <agent>` is allowed iff the actor and target **share at least one room** (or the actor is admin/controller — bypass). Default-open is preserved for installs with **no rooms defined** (back-compat: ACL only engages once teams exist). The ACL is **enforced** (hard block, per "팀끼리만 소통"), with a clear denial message + an audit row.

## 8. CLI surface (new verbs)
- `agb room create|list|show|rotate-invite|invite [--once]|approve|deny|kick|leave`
- `agb node-link bootstrap --init|--accept <bundle>|list|test`
- `agb a2a send` extended to accept `agent@node` / a room target (fan-out to all room members) in addition to today's `--peer/--to`.
- Back-compat: `agb a2a peers` keeps working (aliased to `node-link list`).

## 9. Security model (summary)
- Transport proof (tailnet membership OR Cloudflare Access token) + **app-layer HMAC node-link** (unchanged) = node trust.
- Room admission = **capability join-token (gets to the queue) + explicit leader approval (admits)**. Tokens room-scoped + revocable.
- Internal ACL = room-membership-gated `create --to`, admin/controller bypass, fail-open only when no rooms exist.
- Config files stay 0600 (`load_config` perms check). Secrets never logged (only signatures). Bootstrap secret single-use + TTL + nonce, burned on completion.

## 10. Migration / back-compat
- `peers[]` auto-reads as `node_links[]` (tailscale transport inferred). Existing 1:1 deployments keep working with zero config change; rooms are additive.
- No rooms defined → internal queue stays all-to-all (today's behavior).
- A `default` room can be auto-created spanning existing peers if the operator opts in (`agb room adopt-peers`).

## 11. Phasing (implementation order — each phase = its own PR(s), codex-gated)
- **P0** — this design doc + codex spec-review (converge architecture).
- **P1 (internal, most self-contained + testable):** `rooms.db` schema + room create/join/approve/leave/kick/roster on a SINGLE node + the internal-team queue ACL (`cmd_create` membership gate, admin bypass, fail-open-when-no-rooms) + `agb room` CLI + smokes (incl. ACL teeth: cross-team blocked, same-team allowed, admin bypass, no-rooms-open).
- **P2 (transport abstraction):** extract the transport interface; refactor tailscale behind it; add the cloudflare-zt backend (cloudflared + Access) + config `transports[]` + smokes (transport-negotiation, HMAC unchanged).
- **P3 (node-link bootstrap):** `agb node-link bootstrap --init/--accept` bundle flow + single-use bootstrap secret + the #1415 wizard re-pointed.
- **P4 (cross-node rooms):** roster spans nodes; roster-broadcast over node-links; relay-through-leader; relay→auto-upgrade-to-direct advisory + dual-approval auto-bootstrap.
- **P5:** docs (extend `docs/a2a-cross-bridge.md` + this doc → `docs/design/`), `agb a2a send` room fan-out, migration verbs, end-to-end smoke.

## 12. Test plan (per phase, teeth required)
1. **Internal ACL:** same-room create allowed; cross-room blocked (audit row); admin/controller bypass; no-rooms → open (back-compat); teeth: remove the ACL → cross-room create wrongly allowed.
2. **Join/approve:** join-request → pending; leader approve → roster updated + broadcast received by all members; leave/kick → removed + re-broadcast; link-leak-without-approval ≠ admission.
3. **Invite token:** room-scoped, rotate invalidates old, single-use burns after one use.
4. **Transport:** tailscale unchanged (regression); cloudflare-zt backend accepts a valid Access token + valid HMAC, rejects bad token OR bad HMAC; HMAC verification identical across transports.
5. **Bootstrap:** A--init→bundle→B--accept→A finalize→link live; bootstrap secret single-use (replay rejected), TTL'd, nonce-checked.
6. **Cross-node + relay:** member on a non-linked node reached via leader-relay; sustained relay → advisory to both operators; dual-approval → auto node-link → direct.
7. **Leader outage:** roster-cached members keep talking; new joins blocked; leader back → resumes.

## 13. Open items deferred (Phase-2 backlog, NOT this run)
- Leader auto-failover / deputy succession (this run: roster-cache survival + "leader back → resume" only).
- Simultaneous dual-transport on one link (config supports declaring both; runtime picks one — "both at once" left for later validation).
- Room federation (rooms-of-rooms).

---

## 14. Spec-review r1 — REVISED design (closes the 5 findings; this section supersedes §5–§7,§11 where they conflict)

Grounded in the verified seams: receiver routes by invoking `bridge-task.sh create --to <target> --from a2a:<sender_bridge>:<sender_agent> --body-file …` (`bridge-handoffd.py:256-300`); the receiver allowlist gate is the per-peer `inbound_allowlist` exact-match at `bridge-handoffd.py:560-567`; the internal `cmd_create` has zero ACL (`bridge-queue.py:885-955`); envelope build/parse at `bridge_a2a_common.py:315-363`.

### R1 — internal ACL: AUTHENTICATED actor + trusted-call-path bypass (closes finding 1 + r2-#1)
**The ACL actor is NOT the user-supplied `--from`** (which `bridge-task.sh:354-357,408-409` / `bridge-queue.py:885-920` accept verbatim — a room-restricted agent could pass `--from "$USER"`/`cron:x`/`bridge` to forge a bypass). The ACL decision uses an **authenticated actor**: the bridge-set `BRIDGE_AGENT_ID` present in a managed-agent session (a trusted, agent-controlled-process identity), resolved by the trusted CLI wrapper — NOT a flag. Under `rooms_acl=enforce`, a managed agent's `--from` is recorded for audit only and **cannot override** the authenticated `acl_actor`; explicit `--from` from a managed agent is rejected/downgraded so it cannot escalate. Bypass is **trusted-call-path based, not string-prefix based**:
- **Receiver-delivered creates** (`bridge-handoffd.py`→`create` with `--from a2a:*`) are gated at the RECEIVER by room membership (R2), so the internal ACL does not re-gate them — but they are identified by the *call path* (the handoffd trusted wrapper), not by trusting the `a2a:` string.
- **Daemon / cron internal creates** run on the daemon's own trusted process path → bypass (identified by call-path/process identity, not a `bridge`/`cron:` string a managed agent could type).
- **Human-operator CLI** with no `BRIDGE_AGENT_ID` set (interactive shell) → bypass (the operator is trusted at the terminal).

The gate **fires only** when: `rooms_acl=enforce` AND ≥1 enforced room exists AND the **authenticated `acl_actor` is a real roster agent** on a non-system call path AND the target is a roster agent → allow iff `acl_actor` and target **share an enforced room** (else hard-block + audit `acl_denied` + stderr reason). Migration `agb room adopt-all` auto-creates a default all-agents room so flipping `enforce` strands nothing. **`rooms.db` unreadable/absent:** fail-OPEN ONLY while `rooms_acl=off` (back-compat); under `enforce`, a managed-agent-actor create with an unreadable `rooms.db` **fails CLOSED** (deny + audit) — never fail-open for a real roster-agent actor once enforcement is on.

**Actor-auth boundary — the `acl_actor` must be OS-enforced, not env (closes r3-#1).** `BRIDGE_AGENT_ID` is only an env var (`bridge-run.sh:136-141,349-351`; the queue proxy reads it at `bridge-queue.py:75-80`), so a managed agent could run `BRIDGE_AGENT_ID=<other> bridge-task.sh create …` and forge it. Therefore the enforcement contract is **isolation-mode-dependent**, and the design is honest about it:
- **Linux iso v2 (per-agent OS UID) — ENFORCEABLE.** The queue gains a **gateway** that derives `acl_actor` from the **OS peer credential of the create**, never from client env: for a socket-transport queue, `SO_PEERCRED` uid → agent (the controller maps `agent-bridge-<a>` uid → agent `<a>`); for the file/request-dir transport, the **ownership/mode of the create-request file** (each iso UID can only write requests it owns). Client-supplied `BRIDGE_AGENT_ID`/`--from` are **ignored** for the ACL decision (audit-only). An iso agent cannot impersonate another iso agent because it cannot act as another UID. This is the OS boundary the v2 isolation stack already provides (`agent-bridge-<a>` / `ab-agent-<a>`).
- **Shared-mode (single UID, all agents the same OS user) — ADVISORY by default.** Same-UID agents are not OS-separable, so a hard team boundary is **not a real security control** there. Default in shared mode: the ACL is **advisory** (audit `acl_advisory_cross_room` + optional warn, no hard block) — useful for hygiene/observability, not isolation. An operator who needs enforcement in shared mode must route all managed-agent creates through a **trusted session gateway** that binds `acl_actor` to an immutable per-session record (e.g. a controller-owned create wrapper / a per-agent unix socket) and ignores caller-set env; absent that, enforcement is not claimed.
- **Fail-closed / operator bypass:** under `rooms_acl=enforce`, if the trusted `acl_actor` **cannot be established** for what is otherwise a roster-agent session (e.g. iso expected but the gateway credential is unavailable) → **fail CLOSED**. The human-operator bypass is reserved for a **proven controller shell** (the controller UID / an interactive non-managed session), NOT any process that merely cleared `BRIDGE_AGENT_ID`.

P1 ships the iso-v2 gateway-credential `acl_actor` derivation + the shared-mode-advisory default; the trusted-session-gateway-for-shared-mode is a documented opt-in (Phase-2 backlog if not in P1).

### R2 — receiver-enforced membership + signed-roster epoch (closes finding 2)
Membership is **receiver-enforced and fail-closed**, never sender-trusted. Schema (set in P1, even though cross-node enforcement fully activates in P4 — so no later rewrite):
- `rooms.epoch INTEGER` — monotonic, bumped on EVERY membership change (join/leave/kick).
- **Roster authenticated by the PAIRWISE node-link HMAC, NOT a shared room key** (closes r2-#2: a room-wide HMAC is symmetric → any verifier could forge). The leader broadcasts the epoch-bumped roster to EACH member node **over that node's existing node-link**, MAC'd with the **leader-node↔member-node ordered-pair secret** (`peer_secret`, the existing trust). A receiver verifies the roster came from the leader's node via that node-link HMAC. **Member X (node X) knows only the leader↔X secret, never leader↔Z, so X cannot forge a roster that node Z would accept** — no room-wide signing key is ever shared. (Pure-stdlib HMAC; reuses node-link trust; O(member-nodes) per-node broadcasts.) Table `room_roster_cache(room_id, epoch, members_json, from_node, mac, fetched_ts)` per member/receiver.
- **Envelope (extend `build_envelope`/`parse_envelope`):** optional `room_id` + `room_epoch` fields for room-scoped messages.
- **Receiver check (extend the `inbound_allowlist` seam, `bridge-handoffd.py:560`):** room-scoped enqueue FAIL-CLOSED (403) unless the receiver verifies, against the **leader-MAC'd roster for THIS node**, that BOTH `sender_agent@sender_node` AND `target_agent@<this_node>` are current members.
- **Revocation = freshness-bounded, fail-closed (NOT "immediate" — closes r2-#3):** a kicked member could replay its OLD `room_epoch` to a receiver that hasn't yet applied the kick. So the receiver enforces a **`roster_max_age`** (default ~60s): on a room-scoped enqueue, if the cached roster's `fetched_ts` is older than `roster_max_age` OR the message `room_epoch` > the cached epoch, the receiver **refreshes the leader-MAC'd roster from the leader over the node-link BEFORE deciding**. The refreshed roster (post-kick) excludes the kicked member → reject. **Leader outage** (refresh fails AND cache stale beyond `roster_max_age`): room-scoped delivery **fails CLOSED** (defined default; an operator may configure a bounded grace, but the safe default denies). Revocation is thus **effective within `roster_max_age`** (not instant), with a fail-closed stale-cache/outage contract — the honest claim. Roster broadcasts are durable + ack'd + retried so the steady-state window is small. The signed epoch is the split-brain tiebreaker (lower-epoch caches refresh before accepting).

### R3 — split bootstrap-interest from authenticated join; hash tokens; rate-limit (closes finding 3)
Two distinct steps:
1. **Bootstrap-interest (unauthenticated):** opening an `agbroom://` link when **no node-link to the leader's node exists** does NOT post a join-request. It surfaces a single, **rate-limited** "interest" signal that triggers the human-mediated node-link bootstrap (§5 / R4). `agent@node` is NOT materialized while unauthenticated.
2. **Authenticated join-request:** only AFTER the node-link HMAC is established (so `sender_node` is attested and the requester's `agent@node` is authenticated over the node-link) does the requester post a join-request. The leader stores join tokens as **`sha256(token)` only** (the link carries the token; the leader hashes-and-compares). **Rate-limit/quota per invite-token AND per source-node**; pending `room_join_requests` rows are created **only after node-link auth succeeds** — a leaked reusable token cannot mint arbitrary `(agent,node)` pending rows or spam the leader inbox. `agb room rotate-invite` invalidates the stored hash.

### R4 — bootstrap: intended-peer binding + A-side fingerprint confirm (closes finding 4)
Node A `--init` does NOT auto-finalize with the first presenter. When Node B `--accept`s and reaches back, Node A computes + **displays Node B's node fingerprint** (a hash over B's node id + B's transport identity + B's fresh contribution) and the **operator confirms it out-of-band** (the two humans compare fingerprints, SSH/Signal-safety-number style) BEFORE Node A finalizes the long-term node-link. A first-use-capture attacker presents a *different* fingerprint → mismatch → operator rejects. The long-term ordered-pair secret = HKDF over **both node ids + both fresh contributions**, bound to a transcript that authenticates both contributions; finalized only after mutual fingerprint confirmation. (Optionally A `--init --expect <B-fingerprint>` for a pre-shared expected id → fully automatic reject on mismatch.)

### R5 — relay→direct: leader excluded from key material; E2E fingerprint (closes finding 5)
The leader's role in the relay→direct upgrade is **suggestion only**: it notifies A's and C's operators that A↔C traffic is relaying and a direct link would help. The actual A↔C node-link bootstrap is a **direct A↔C handshake (R4)** — the **leader never sees the A↔C bootstrap secret, long-term contributions, or HKDF transcript** (they flow A↔C directly over a transport A and C share, or via a fresh bundle the two operators exchange out-of-band, NOT through the leader's relay channel). A and C operators confirm **each other's** fingerprints end-to-end. A compromised leader can suggest but can neither mint nor observe A↔C trust.

### R6 — P1 scope now includes the contract-setting schema (closes the phasing caveat)
**P1 MUST land:** `rooms.db` schema **with `epoch` + the leader-signed-roster table**, the `room_id`+`room_epoch` **envelope fields** (built/parsed even though single-node P1 doesn't cross a receiver yet), the **receiver-check seam** stubbed to the fail-closed contract (active for cross-node in P4, no-op/loopback in P1), and the **R1 ACL-activation model** (opt-in flag + bypass set + `adopt-all`). This freezes the wire/schema contract so P2–P4 add behavior without a schema/contract rewrite.

### Unchanged-and-affirmed by spec-review
3-layer split is the right model; hub-and-spoke relay reduces M² *iff* every member node has a verified link to the leader node and relay is durable/retryable (R2 covers durability); Cloudflare Access + app-HMAC is correct defense-in-depth **provided the cloudflare-zt receiver binds loopback-only behind cloudflared and ALL non-bootstrap endpoints still require app-HMAC** (P2 acceptance criterion).
