# Fleet-Credential Architecture — Design

**Umbrella:** [#1470](https://github.com/seanssoh/agent-bridge-public/issues/1470) (tracking/design)
**In focus:** [#1467](https://github.com/seanssoh/agent-bridge-public/issues/1467) (central registry + adapter + fleet sync for Codex/Gemini), [#1469](https://github.com/seanssoh/agent-bridge-public/issues/1469) (post-rotation set-scoped fleet re-wake)
**Status:** Phase 1 landed (engine-auth descriptor seam + cred-generation groundwork). Phase 2 (Codex adapter) and the L5 re-wake wiring are NOT yet built.
**Security class:** HIGH-RISK — this is the most security-sensitive surface in the repo after the A2A receiver (see `CLAUDE.md` High-Risk #5/#6). The token store and the sync path must be locked down on every engine.

This doc is the durable home for the agreed model. It supersedes the ephemeral `/tmp/fleet-credential-plan.md` and the codex plan-agreement note that resolved the six open questions.

---

## 1. The reframe (settled, codex-converged) — read this first

**True multi-engine rotation parity is impossible.** The three engines have fundamentally different auth contracts:

| Engine | Auth artifact | Rotation? | Usage signal | Verdict |
|---|---|---|---|---|
| **Claude** (Anthropic) | OAuth setup token (OAT) in a central registry | YES — full multi-token pool rotation, already built | native OAuth usage probe (#1437/#1443/#1468) + reactive 429 | **rotatable** |
| **Codex** (OpenAI) | subscription OAuth token in `<home>/.codex/auth.json` (mode 0600), refreshed in-place by the `codex` binary | NO — single subscription login; the binary self-refreshes; no rotation/failover protocol | observable (`bridge-usage.py` `codex_snapshots`) but **not actionable** | **static / fleet-sync-only** |
| **Gemini** (Antigravity / `agy`) | no stable auth contract exposed | n/a | n/a | **deferred** |

Therefore the design is **NOT "generalized rotation."** It is an **engine adapter** where each engine implements only the capabilities it actually has, all routed through ONE iso-safe write/sync seam. For Codex the deliverable is **central register-once → fleet-shared sync of the `auth.json` file** — NOT rotation, NOT multi-key, NOT failover-pool.

---

## 2. Layered model (L0–L5)

`#1470` defines a single engine-agnostic fleet-auth pipeline in six layers; the two focus issues own two of them.

- **L0 — engine descriptor** (#1013/#1060): the extension point. `lib/bridge-engine-descriptor.sh` is the single source for per-engine branching. Phase 1 added the **auth accessors** here (§4).
- **L1 — central credential registry + adapter** (#1467): the per-engine `register / activate / rotate / recover / sync / verify` contract, each engine implementing only what it has.
- **L2 — usage detection** (#1437/#1468): the #1468 429-positive-signal fix shipped in v0.15.4.
- **L3 — rotation policy** (#1437/#1468): Claude-only; Codex/Gemini have nothing to rotate.
- **L4 — fleet propagation / sync** (#1467): write the source credential into every agent home through the iso-safe primitive.
- **L5 — post-rotation set-scoped re-wake** (#1469): after a rotation atomically swaps the whole fleet, re-wake exactly the stranded set (in-flight/pending work on the vacated credential), token-health-gated, no human nudge.

**The two focus issues compose:** #1467 emits a uniform rotation/sync audit event for every engine; #1469 subscribes to that event to resume the fleet. Filed separately they would be solved Claude-only and incompatibly; the umbrella forces them onto a shared seam.

---

## 3. The central register-once → fleet-sync model

### 3.1 Claude (the working template — build ON, do not rewrite)

- **Central register:** `runtime/secrets/claude-oauth-tokens.json` (`BRIDGE_CLAUDE_TOKEN_REGISTRY`, resolved by `bridge_auth_registry_path`). A multi-token pool with one active token.
- **Registry ops (`bridge-auth.py`):** `cmd_add` / `cmd_list` / `cmd_activate` / `cmd_rotate` / `cmd_check` / `cmd_recover_due` / `cmd_auto_rotate` / `cmd_sync_agent`, all guarded by `registry_lock`.
- **Fleet sync (`bridge-auth.sh`):** `bridge_auth_sync_agents` → `bridge_auth_selected_agents` (static/all/csv) → per-agent write into `<agent_home>/.claude/.credentials.json`. The iso-safe write primitive is **`write_private_file_atomic`** — tmp + fsync, `os.chmod` then **`os.chown` to the target UID/GID BEFORE `os.replace`** (PR #799 r2), so the credential is never root-owned at its final path and an iso agent can always read its own file. **This primitive is already engine-agnostic.**
- **#1075 controller-fallback:** when no OAT is registered, `cmd_sync_agent` falls through to `source="controller_credentials"` and copies the controller's `~/.claude/.credentials.json`. **#1261 (v0.15.4):** `controller_credentials_aliveness` gates the fallback on a min-TTL so a stale controller token is no longer propagated fleet-wide.
- **Rotation trigger:** daemon `process_usage_monitor` runs the native usage probe and on a quota/usage threshold calls `bridge-auth.sh claude-token rotate --if-auto-enabled --sync --agents …`, then writes a `claude_token_rotation` audit row. **This is the event #1469 keys on.**

### 3.2 Codex (Phase 2 — the new capability, #1467)

Operator decision: **subscription login, not API key.** Operator manually runs `codex login` on a designated source agent; the bridge propagates that to every Codex agent.

- **Source of truth:** the designated source agent's `<agent_home>/.codex/auth.json` (the OAuth subscription token, mode 0600, refreshed in place by the `codex` binary).
- **Destination:** every other Codex agent's `<agent_home>/.codex/auth.json`.
- **Sync = generalize the #1075 controller-fallback to a designated source agent**, through the same `write_private_file_atomic` + per-agent iso-aware machinery. Handles: (a) in-place refresh re-propagation, (b) the iso boundary (the fleet-sync **MUST include Linux iso v2 agents**), (c) operator re-login.
- **No registry pool, no rotation, no failover.** The Codex adapter implements `register` (point at the source), `sync`, and `verify` only; `activate/rotate/recover` are **clean no-ops that return a "not-supported-for-this-engine" status**.
- **CLEAN SLATE:** the bridge does NOT manage Codex auth today (no `auth.json` injection in tracked code). Phase 2 is a NEW capability, not an env-injection migration — but a legacy ambient-key precedence guard must still exist defensively (§6/Q6).

### 3.3 Gemini (Antigravity / `agy`) — deferred

No stable auth contract. The descriptor reserves the engine slot but answers `auth_supported = no`; L1/L4 for Gemini are out of scope until an engine-native contract exists. The adapter degrades cleanly rather than erroring.

---

## 4. The engine-auth descriptor seam (L0 → L1) — **Phase 1, landed**

`lib/bridge-engine-descriptor.sh` (#1060) was a minimal layout/hook descriptor with no auth fields. Phase 1 added the auth accessors so `bridge-auth.sh` / `bridge-auth.py` dispatch credential operations **by engine** instead of hardcoding Claude.

### 4.1 The bash accessors (`lib/bridge-engine-descriptor.sh`)

| Accessor | claude | codex | antigravity |
|---|---|---|---|
| `bridge_engine_auth_supported` | rc 0 | rc 0 | rc 1 |
| `bridge_engine_auth_model` | `rotating-pool` | `single-source-sync` | `none` |
| `bridge_engine_cred_dest_path <agent>` | `.claude/.credentials.json` | `.codex/auth.json` | rc 1 |
| `bridge_engine_cred_source` | `registry` | `agent-source` | `none` |
| `bridge_engine_supports_rotation` | rc 0 | rc 1 | rc 1 |
| `bridge_engine_usage_source` | `native-oauth-probe` | `codex-snapshots` | `none` |
| `bridge_engine_cred_payload_key` | `claudeAiOauth` | `` (opaque copy, rc 0) | rc 1 |

All accessors are pure case-tables (no external deps) and never touch the network or filesystem, so they can be sourced and called from a bare subshell exactly like the existing layout/hook accessors. `bridge_engine_cred_dest_path` returns the **home-relative tail**; the auth stack resolves the agent's real (iso-aware) home separately.

### 4.2 The Python mirror (`bridge-auth.py`)

`ENGINE_AUTH_DESCRIPTOR` is the data table; `engine_auth_descriptor(engine)` returns a row and **raises `ValueError` for an unknown engine** (a typo can never silently fall through to Claude). Each row carries `auth_supported`, `auth_model`, `cred_dest_tail`, `cred_source`, `supports_rotation`, `usage_source`, `cred_payload_key`.

### 4.3 Claude seams lifted (behavior-preserving)

- `claude_oauth_credentials_payload` sources the payload key from the descriptor (`claudeAiOauth` — byte-identical).
- `bridge_auth_claude_credentials_file_for_agent` resolves the dest tail via `bridge_engine_cred_dest_path` (byte-identical to the old `.claude/.credentials.json` literal), with a Claude fallback if the descriptor is unsourced.
- `bridge_auth_selected_agents` filters by an explicit `$BRIDGE_AUTH_CLAUDE_ENGINE` binding (`claude`) rather than a bare string literal — same behavior, engine-parameterized shape.
- `cmd_sync_agent` gained an `--engine` arg (default `claude`) so every existing caller is byte-compatible and Phase 2's Codex adapter passes `--engine codex`.

**Phase 1 is a behavior-preserving refactor.** Claude must behave identically; only the abstraction boundary moves. The shared iso-safe write seam (`write_private_file_atomic`, `bridge_auth_selected_agents`, aliveness/TTL gating) is already engine-agnostic and is reused as-is. **Proof:** the existing Claude auth/rotation/credential smoke suite passes byte-identically (`F-beta4-oauth-bootstrap`, `daemon-periodic-token-sync`, `1437-*`, `1468-*`, `1358-*`, `picker-sweep-concurrent-rotation`, `1520b-*`) plus the new `1470-engine-auth-seam` smoke.

---

## 5. Credential-generation state (Q4 groundwork) — **Phase 1, landed**

A later #1469 set-scoped re-wake must answer *"which agents were running under the credential generation a rotation just vacated?"* The queue / daemon state recorded no such field. Phase 1 lays the schema + a stamp-at-sync hook; it does NOT wire the full re-wake yet.

- **Store:** a single JSON document at `state/auth/cred-state.json` (`BRIDGE_AUTH_CRED_STATE_FILE` override) mapping `agent → { engine, source_digest, cred_generation, synced_at }`.
- **`cred_generation`** is a monotone per-agent counter that **bumps only when `source_digest` changes** — an idempotent re-sync of the same credential does NOT bump it, so a no-op periodic sync never looks like a rotation to #1469.
- **`source_digest`** is a one-way SHA-256 of the credential material. **The secret is NEVER written to state** — only the digest.
- **Idempotent migration:** `load_cred_state` tolerates a missing / legacy / corrupt / wrong-shape file by returning a fresh default; it never raises on read (the sync is the source of truth; the state is a derived stamp).
- **Fail-closed write:** `save_cred_state` routes through `write_private_file_atomic` (0600, atomic replace, chown-before-replace). A partial write can never leave a half-written or world-readable state file.
- **Best-effort at the call site:** `cmd_sync_agent` stamps after a successful credential sync; a stamp failure emits a `warning:` to stderr and reports `cred_generation: 0` but never turns a good credential sync into a reported failure.

The future #1469 L5 re-wake reads this stamp: on a rotation event, compute the stranded set = agents whose `cred_generation` predates the rotation AND had in-flight/pending work, re-wake exactly that set, token-health-gated, emit a `fleet_rewake` audit row. (Design detail in §7.)

---

## 6. Security model (the token store + sync path)

The store and sync path must be locked down on every engine:

1. **Credential never in child env (#1444), uniformly.** Claude delivers the token over an unlinked-0600 fd transit + an `apiKeyHelper` on the keychain-free Darwin path; never an env var. The **Codex adapter MUST preserve this** — `auth.json` is delivered as a file the `codex` binary reads from `CODEX_HOME`, never as an `OPENAI_API_KEY`/`CODEX_*` env var.
2. **#1454 ambient-secret-scrub primitive is the gate.** `lib/bridge-secret-scrub.sh` (v0.15.4) is the shared `harden_hooks` → `capture` → privileged `bash -p` re-exec primitive. Any new Codex/Gemini secret-bearing path MUST route through it, not hand-roll the dance. The documented launch-environment-control boundary stays out of scope (consistent with the #1443 ruling) — do not chase an impossible unspoofable re-exec.
3. **Iso boundary integrity — published-write, never world-read.** Every cross-class write goes through `write_private_file_atomic` chown-before-replace at mode 0600 owned by `agent-bridge-<a>:ab-agent-<a>`. Reading a source iso agent's 0600 file uses `sudo -n -u <owner> cat` (Issue #1280); if that fails, **fail LOUD** (audit + `agent-bridge status`), never silently fall back to a world-readable copy.
4. **Registry/source file permissions + locking.** `runtime/secrets/` stays 0600/0700. The Codex source `auth.json` read + every dest write must read an atomic snapshot (do NOT rely on an advisory lock against the `codex` binary — it will not take one).
5. **Never propagate a stale/bad credential (L4 guard, #1261 generalized).** The Codex sync must verify the source `auth.json` is well-formed and not obviously expired before fanning it out.
6. **Never symlink credentials.** Codex's atomic tmp+rename on refresh would replace a managed symlink with a regular file and silently de-sync the fleet. **Write-through / copy only**, owner/mode 0600 preserved, the existing chown-before-replace atomic writer shape.

---

## 7. The six resolved open questions (codex plan-agreement)

1. **Q1 — Codex source binding.** Make the Codex source **configurable and admin/controller-owned, not hardcoded and not env-overridable.** Default may be `<admin>-dev` if present; the selected source is persisted in protected config/descriptor state and validated as an existing Codex agent that is not stopped/quarantined. If the source is iso-owned and the controller cannot read it through the approved sudo/cat path, **fail loud with no fallback.** *(Phase 1: the descriptor's `cred_source` for codex is `agent-source` — a slot, not a binding. The concrete binding is Phase 2 config.)*
2. **Q2 — refresh detection.** Use **digest/generation, not TTL alone.** On each daemon tick, read an atomic snapshot of the source auth file, validate JSON/schema, compute a content digest, and propagate only when the digest changes. Do not rely on an advisory lock against the Codex binary. Invalid/unstable reads fail loud and do not propagate. *(Phase 1: the cred-generation store already keys on digest-change.)*
3. **Q3 — Codex aliveness.** No proven side-effect-free live Codex aliveness probe exists (`codex login status` on 0.135.0 mutates `CODEX_HOME`). Use offline well-formedness/expiry/path checks; optionally run CLI status only against a scratch copy. **Codex L4 is documented as weaker than Claude** until a side-effect-free native probe exists.
4. **Q4 — stranded-set precision.** Add **credential-generation stamping.** Do not accept "re-wake all agents with work" except as an explicitly temporary Phase-0 tactical fallback. Store per-agent `engine/source_digest/cred_generation/synced_at`; stamp at sync; the #1469 re-wake targets only work running under a vacated generation. *(Phase 1: landed — §5.)*
5. **Q5 — rollout.** Ship **Phase 1 as a separate beta from Phase 2.** The auth descriptor/refactor is high-risk enough to prove Claude no-regression first; add the Codex adapter only after the seam is stable. *(This is why this PR is Phase 1 only.)*
6. **Q6 — ambient env.** **Active-scrub for managed Codex.** `OPENAI_API_KEY` and `CODEX_ACCESS_TOKEN` must be removed at true `bridge-run.sh` process entry before any child fork, from the iso-v2 secret loader / final launch path, and from any managed Codex child environment. Warn-only is acceptable only for explicitly unmanaged/operator-owned Codex runs. Never log token values. *(Phase 2.)*

**Extra build constraints (Phase 2):**
- Prove the real Codex auth path before copying credentials — a verifier showing the launched Codex process reads the intended `<home>/.codex/auth.json` in both shared and iso-v2 modes, or deliberately set that path before sync. The default Codex command has no `CODEX_HOME` pin and the non-Claude shared launch does not obviously export `HOME`/`CODEX_HOME`.
- Never symlink credentials — write-through only, owner/mode 0600 preservation, chown-before-replace.
- Rollback must restore a same-owner/same-mode last-known-good file keyed by generation/source digest, and must never roll back to a known-expired or wrong-source credential.

---

## 8. Phase plan (SEQUENTIAL; operator checkpoint before each)

| Phase | Scope | Status |
|---|---|---|
| **Phase 0** | Claude lane + the #1454 security gate; #1468 429-signal; #1261 stale-guard; #1469 Claude-tactical re-wake | mostly DONE in v0.15.4 (re-wake pending) |
| **Phase 1** | engine-auth descriptor + seam generalization (Claude behavior-preserving); cred-generation schema groundwork | **THIS WORK — landed** |
| **Phase 2** | Codex adapter against the Phase-1 seam: `register`/`sync`/`verify`; iso-inclusive write-through; ambient-key scrub; daemon tick wiring; uniform sync audit row | NOT STARTED |
| **Phase 5 / Gemini** | re-wake generalization for non-Claude wake mechanisms; Gemini L1/L4 | deferred |

---

## 9. Verification teeth

- **Static (required before any PR):** `bash -n` + `shellcheck` over touched `*.sh`/root scripts + `py_compile` + `./scripts/smoke-test.sh` (isolated) + `lint-heredoc-ban --baseline-check` + `lint-raw-pathlib-on-isolated` + `iso-helper-ratchet`.
- **Phase-1 regression gate:** the existing Claude auth + usage + rotation smokes pass **byte-identically** — Phase 1 is behavior-preserving. Register each new smoke at the `bridge-auth.py|bridge-auth.sh` and `lib/bridge-engine-descriptor.sh` `ci-select-smoke.sh` sites + the master required list.
- **Phase-1 new smoke:** `scripts/smoke/1470-engine-auth-seam.sh` — descriptor dispatches Claude through the seam byte-identically (Part A), and the cred-generation schema is idempotent + fail-closed + 0600 + never records the secret (Part B).
- **Phase-2 smokes (future):** Codex write-through to shared + iso v2 (dest 0600 owner-correct, no symlink, run on Linux), in-place-refresh re-propagation, symlink-hazard guard, ambient-key precedence guard, no-token-in-child-env assertion, plus the #1469 L5 stranded-set/idle-not-woken/token-health-gate/`fleet_rewake`-audit smoke.
- **codex pair-review at every gate** + a read-only adversarial-verify sweep on the security paths before pair-review (Phase 2 especially).

---

## 10. Load-bearing source anchors

- `lib/bridge-engine-descriptor.sh` — the L0 descriptor + the Phase-1 auth accessors (§4.1).
- `bridge-auth.py` — `ENGINE_AUTH_DESCRIPTOR` / `engine_auth_descriptor`, `claude_oauth_credentials_payload` (descriptor-keyed), `cred_state_path` / `load_cred_state` / `save_cred_state` / `stamp_cred_generation` (§5), `write_private_file_atomic` (the iso-safe write seam), `controller_credentials_aliveness` (#1261), `cmd_sync_agent` (the `--engine` dispatch + stamp call).
- `bridge-auth.sh` — `BRIDGE_AUTH_CLAUDE_ENGINE`, `bridge_auth_engine_cred_file_tail`, `bridge_auth_claude_credentials_file_for_agent`, `bridge_auth_selected_agents`.
- `bridge-daemon.sh` — `process_usage_monitor` → `claude-token rotate --if-auto-enabled --sync` → `claude_token_rotation` audit row (the L5 trigger).
- `lib/bridge-secret-scrub.sh` — the #1454 shared scrub/transit primitive any new secret path must use.
- `bridge-run.sh` — #1444 fd credential transit + child-env scrub (extend for Codex, don't weaken).
