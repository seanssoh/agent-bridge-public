# Release Lines & LTS Policy

This file is the **canonical, plain-language standard** for how Agent Bridge versions are
numbered, branched, soaked, supported, and shipped. It is the single source of truth;
`CLAUDE.md` and `AGENTS.md` carry only the headlines and point here. The audience is an
operator — not a release engineer — so the rules are stated in everyday terms with concrete
Agent Bridge examples (v0.16 / v0.17) throughout.

Policy first written from the operator decisions of 2026-06-08 (the v0.16.2 LTS cut), the
RC-soak rule of 2026-06-17, and the trunk+LTS clarification that followed. Update this file
whenever the policy changes — and only this file; the headline docs follow it.

---

## TL;DR — the decision cheatsheet

Read this first. The rest of the doc is the long form.

**Which number do I bump?** (we are pre-1.0, so the version is `0.y.z` = `0.MINOR.PATCH`)

| You are shipping… | Bump | Example |
|---|---|---|
| A **bug fix or hardening only** — no new behavior an install can newly rely on | `z` (PATCH) | `v0.16.15 → v0.16.16` |
| A **new feature**, backward-compatible | `y` (MINOR) | `v0.16 → v0.17` |
| A **breaking change**, or the deliberate **1.0** "we now promise API stability" milestone | `x` (MAJOR) | `0.x → 1.0` (not yet) |

While we are `0.x`, the **MINOR digit is the feature / break boundary** — a new feature line is
a minor bump, and that is also where any breaking change goes. `x` stays `0` until an explicit
operator decision to commit to 1.0 stability.

**beta or rc?** (the prerelease suffix)

| Situation | Suffix | Meaning |
|---|---|---|
| Still **adding** features to this line | `-beta1`, `-beta2`, … | "expect more change + bugs"; breaking changes between betas are OK |
| Feature-complete, **frozen**, only soaking + critical fixes left | `-rc1`, `-rc2`, … | "we believe THIS is the release"; **no new features** after the first rc |
| Soaked clean and ready | *(no suffix)* | the final release — relabel/promote the clean rc, do not re-cut |

Rule of thumb: **still adding features → beta; only stabilizing → rc.**

**Where does my change land?**

- **Everything lands on `main` first** — features *and* fixes. `main` is the forward trunk
  (the next minor's dev line).
- A fix is **cherry-picked out** to the frozen `release/X.Y-lts` branch **only if it qualifies
  for backport**: security · data-loss · upgrade/rollback breakage · fleet-host-down regression.
  Nothing else (no features, cosmetics, perf-only, refactors).
- You **never forward-port** and **never re-fork** — `main` already has everything.

**When do I fork a new line?** The **first real new feature** for the next minor. Hardening
alone never forks. At the fork: branch `release/X.Y-lts` from the latest `vX.Y.z` tag, and bump
`main` to `v0.(Y+1).0-beta1`.

**What is `Latest` / `lts` allowed to be?** Never a prerelease. Every beta and rc is a GitHub
**prerelease** that soaks for a few days on the dev hosts first, then is promoted **as-is** by
dropping the prerelease flag. (Exception: an urgent stability / daemon-down hotfix may go
straight to stable.)

---

## 1. Versioning — what `x` / `y` / `z` mean

Agent Bridge uses [semantic versioning](https://semver.org/), and is **pre-1.0** — every release
is `0.y.z`. Read the three positions as `0.MINOR.PATCH`:

- **`z` — PATCH.** Backward-compatible **bug fixes and hardening only — no new features.** An
  install can upgrade a patch and nothing it relied on changes; it just gets safer. Examples:
  `v0.16.15 → v0.16.16`, `v0.16.16 → v0.16.17`. The whole v0.16 hardening ladder is patch bumps.
- **`y` — MINOR.** A **new feature**, backward-compatible. This is a new feature *line*. Examples:
  `v0.16 → v0.17` carrying things like a Discord plugin, an Anthropic-outage fallback, or
  `a2a-whois`.
- **`x` — MAJOR.** A **backward-incompatible / breaking change**, or the deliberate **1.0**
  milestone where we commit to API stability. We are `0.x`; **`x` stays `0`** until an explicit
  operator decision promotes to 1.0.

> **0.x caveat.** Strict semver only special-cases `0.x` loosely, so we pin it down: while we
> are pre-1.0, the **MINOR position is our feature/break boundary**. New features bump minor;
> a breaking change (rare, pre-1.0) also bumps minor. The PATCH position stays purely "fixes,
> no new surface." This is why the LTS line can take fix after fix as patch bumps and never
> accidentally grow a feature.

Bump *size* is the **operator's call** (standing preference: small bumps). A capability-add in a
patch bump is allowed **only when the operator directs it** (e.g. the `lts` channel that shipped
as a patch). Every release — patch or minor — still requires explicit operator GO, codex
pair-review, and the README/docs sync (see `CLAUDE.md` "Releases require explicit operator
permission").

## 2. The prerelease ladder — beta vs rc

Every line climbs a ladder of prereleases before it becomes a bare version. The two rungs mean
different things, and the difference is the part worth internalizing:

- **`-beta` = "features are still landing."** A beta is **not** feature-complete. You cut betas
  while you are still *adding* capability to the line. Breaking changes **between betas are
  acceptable** — that's the whole point of a beta. The number just counts iterations:
  `v0.17.0-beta1 → v0.17.0-beta2 → …` as features land.
- **`-rc` (release candidate) = "we believe THIS is the release."** An rc is **feature-complete
  and frozen** — after the first rc, **no new features**, only final soak and critical-bug fixes.
  You only cut `rc2`, `rc3`, … if a blocking bug forces it. A clean rc is the release: you promote
  it by **dropping the suffix**, you do not re-cut.

**Rule of thumb:** still adding features → **beta**; only stabilizing → **rc**.

**Final promotion path:**

```
v0.17.0-beta1 → … → v0.17.0-beta_n  (features landing)
              → v0.17.0-rc1 → …     (frozen, soaking)
              → v0.17.0             (bare version = the release)
```

The bare `x.y.z` appears exactly when the beta→rc cycle completes — feature-complete **and**
soaked — and you relabel the clean rc to the final tag.

## 3. The prerelease-soak rule

This is an Agent Bridge house rule, adopted 2026-06-17, and it protects production installs:

- **Every prerelease — beta *and* rc — is a GitHub prerelease.** The `Latest` tag and the `lts`
  channel are **never** a prerelease. A build that has not soaked must never become `Latest`.
- Prereleases **soak for a few days on the dev hosts** (the macbook + cm-prod) before promotion.
  Soaking means running it live and watching for regressions, not just passing CI.
- **Promote as-is, by relabel.** When a prerelease soaks clean, you flip off the prerelease flag
  on that exact build — you **do not re-cut** a fresh tag. Re-cutting would ship an unsoaked
  artifact under a soaked name.
- **Exception — urgent stability / daemon-down hotfix.** A fix for an active outage (e.g. the
  daemon is down across the fleet, or a poison input is killing the queue) may ship **directly to
  the stable line**, skipping the soak ladder, because the risk of waiting outweighs the risk of
  the fix. This is the only bypass; everything else soaks.

Stability-*unrelated* findings discovered during a soak are deferred to the next version (which
goes through its own soak), rather than being slipped into the soaking build.

## 4. The trunk + LTS-branch model

This is the part that most often confuses someone new to OSS release management, so it is spelled
out in full. Agent Bridge runs **one forward trunk plus, when warranted, one frozen LTS branch** —
not a single moving tag.

- **`main` is the forward trunk — the *next minor's* dev line.** **All new work lands on `main`
  first** — features *and* fixes, no exceptions. `main` always has everything; it never waits for
  anything else to stabilize.
- **`release/X.Y-lts` is a frozen release branch**, cut from `main` at the feature-fork point. The
  `X.Y.z` patch/hardening releases — the soak ladder for *that* line — happen **on this branch**.
  It only ever takes vetted backports; it never grows features.

**The fix flow is one-directional: `main` → LTS cherry-pick.**

1. A fix lands on `main` first, so the forward line always has it.
2. It is **cherry-picked out** to `release/X.Y-lts` **only if it qualifies for backport**:
   - Security fixes
   - Data loss / corruption
   - Upgrade / rollback breakage
   - A regression that takes a fleet host down

   **Not** backported: new features, cosmetic fixes, performance-only changes (unless severe),
   refactors. Most fixes are main-only.

**You never re-fork, and you never forward-port.** Because `main` already contains everything,
there is nothing to carry *back up* into it. The LTS branch is simply the thing that "stabilizes
and soaks" on its own schedule while `main` keeps moving. This is exactly why the forward line
does not have to wait for the LTS to settle.

### Branch hygiene — the LTS branch is protected; force-pushes are CI-gated

`release/X.Y-lts` is updated far more often by **cherry-pick / rebase / force-push** than `main`
is, and it has historically been treated as a casual working branch. That is the wrong default:
**treat the LTS branch as protected, the same as `main`.** A `--force`/`--force-with-lease` push
to `release/X.Y-lts` whose resulting HEAD has **not** passed CI is prohibited.

- **Mechanism first (preferred):** branch protection on `release/X.Y-lts` — a required green CI
  status check plus a block (or gate) on force-pushes, so an un-verified HEAD cannot become the
  branch tip. A "let's be careful" memo is not enough.
- **Floor (until protection is configured):** hold the `git push` → confirm the resulting HEAD is
  **green on CI** → only then push. Put this in the LTS-cut preflight checklist.
- **Why it matters:** an un-CI-verified force-push leaves the *branch HEAD* broken even when the
  last tagged LTS release is fine (prod pins to the tag, not the branch HEAD), so it ships invisibly
  to the *next* patch cut. This class has recurred (e.g. a bad cherry-pick merge; a wholesale
  ci-select copy that referenced smoke files absent on the LTS branch; lint-baseline regressions
  inherited from a force-pushed commit). Each one only surfaced when the *next* LTS PR's CI failed.
  A green-gate on the branch HEAD removes the whole class.

> **Pre-fork phase.** Before there is any feature divergence, there is **only one line: `main`**,
> and the running `vX.Y.z` hardening sequence *is* the LTS line — it rides `main` directly. You do
> **not** fork a `release/X.Y-lts` branch early: two branches kept in sync for no divergent work is
> pure overhead. The dedicated `release/X.Y-lts` branch comes into existence **only at the fork
> trigger** below. So "the v0.16 hardening rides `main`" (pre-fork) and "the v0.16 LTS lives on
> `release/0.16-lts`" (post-fork) are the *same line at two life stages*, not a contradiction.

## 5. Fork trigger + mechanics

- **Trigger = the first real new FEATURE** destined for the next minor. Hardening alone does **not**
  fork a line — a single line rides `main` until features actually diverge.
- **Mechanics**, performed at that moment:
  1. Branch `release/X.Y-lts` from the **latest `vX.Y.z` tag** (this anchors the LTS line at a
     known-good point).
  2. Bump `main` to `v0.(Y+1).0-beta1` and start the new feature line there. Note the new line
     **starts at `beta1`, not rc** — features are still landing.
- After the fork, **new features go only to the beta line on `main`; never onto the LTS branch.**

## 6. Worked example — Agent Bridge's actual current state

This uses where the project really is, so the model is concrete:

- **v0.16 is the LTS line.** Its `release/0.16-lts` branch is anchored at the latest `v0.16.x` tag.
  The in-flight **v0.16.16** is the patch/hardening soak ladder on this line
  (`v0.16.16-rc1 → rc2 → rc3 → … → v0.16.16`). All future v0.16 fixes are **PATCH (`z`) bumps**,
  each one a fix that landed on `main` first and qualified for backport.
- **`main → v0.17.0-beta1` is the new MINOR feature line.** New capability — e.g. a Discord plugin,
  an Anthropic-outage fallback, `a2a-whois` — accumulates there via `beta1 → beta2 → …`. When the
  feature set is complete it freezes to `rc1`, soaks, and promotes to the bare **`v0.17.0`**.
- **A v0.16-eligible reliability fix** (for example, a reminder-noise regression that takes a host
  down) **lands on `main` first** (so it is in the v0.17 line) and is **cherry-picked to
  `release/0.16-lts`** for the next v0.16.16 patch, because it meets the backport criteria.

> The detailed per-release history of the v0.16 LTS line is kept in
> [§ The v0.16 LTS line — release log](#the-v016-lts-line--release-log) below, so the head pointer
> never has to be edited inline as the policy text.

## 7. Channels — what each upgrade channel resolves to

The LTS designation is only a label unless the **upgrader enforces it**. Channels are how an
install pins to the line it wants:

- **`lts` channel** — pins to the **highest `vX.Y.z` of the LTS line** (a version-line pin). This
  is what conservative / production installs (e.g. cm-prod) track: it follows v0.16 patches and
  does **not** jump to v0.17 when that ships.
- **`stable` channel** (the default) — resolves to the **highest *non-prerelease* global tag**.
  Adventurous installs that always want the newest stable line track this. Be aware: the moment a
  newer minor ships stable, a `stable`-channel install moves **off** the older LTS — which is
  exactly why production pins `lts`, not `stable`.
- **beta / rc prereleases are opt-in only** — they are **not** served on `stable` or `lts`. You
  reach them deliberately (e.g. a `dev`/checkout channel or an explicit prerelease pull) for soak
  testing.

Other channels for the adventurous: `dev` (tracks `main`) and `current` / `--source` (the local
checkout). The upgrader is a High-Risk area (`CLAUDE.md` High-Risk #3) — any channel-resolution
change is designed with codex direction-consensus first and leaves the default channel behavior
unchanged.

## 8. Support window

An LTS line receives qualifying backports **until the next LTS is declared** (operator,
2026-06-08). When the next LTS ships, the previous one's support ends — optionally with a short
overlap decided per-cut; the default is no overlap.

## 9. What "LTS" means here, and how it is declared

An LTS is **not a separate product** — it is a blessed stable tag on a line that only accepts
vetted fixes. LTS and mainline share ~all code; they differ only in *what is allowed to land*.

- **Every v0.16.x release is an LTS release.** The whole v0.16 line is LTS; each patch is an LTS
  patch. When a new v0.16.x patch ships it becomes the new line head but does **not** de-LTS the
  prior one — it *supersedes* it on the same line. GitHub release titles carry `(LTS)` on every
  v0.16.x release. An LTS designation is **never** revoked retroactively for a prior patch.
- An LTS is declared only on **proven convergence**: shipped + tagged, VM-verified on Linux iso v2,
  and a full fleet re-rollout surfacing zero new issues. (Declaration is delegated to the dev
  orchestrator when the results are good — report, don't ask.)

## 10. Agent ownership

- **One dev orchestrator** (`agb-dev-claude`) + **one codex pair** (`agb-dev-codex`) own **both**
  lines for now. The fleet patches (macbook / SYRS / cm-prod / ip-10-242) are **consumers** of
  releases, not co-developers.
- A **dedicated LTS agent** is warranted only **after the mainline fork**, when feature work on
  `main` and backporting to the LTS branch genuinely run concurrently and compete for one
  orchestrator's attention. Even then, use a **`git worktree` + an agent in the same repo** — **not**
  a separate clone/folder. Two working directories from one clone is the idiom; a second full
  checkout is only worth it for OS-user/credential isolation, which is not needed yet.

---

## The v0.16 LTS line — release log

The historical record of the current LTS line. Newest first. This is reference detail; the policy
above does not depend on keeping a head pointer inline.

- **v0.16.16 — in flight (RC soak).** The first release cut under the RC-soak rule: cuts as
  `v0.16.16-rc1 → rc2 → rc3 …` (GitHub prereleases; `v0.16.15` stays `Latest`/`lts`), soaks on the
  macbook + cm-prod, and promotes **as-is** to the bare `v0.16.16` once clean. Patch/hardening only.
- **v0.16.15 — LTS-line head at last sync (2026-06-17).** GitHub release `v0.16.15` (Latest, LTS); a
  **stability hotfix** — a single poison queue request silently killed the whole fleet's queue
  gateway: `bridge-queue-gateway.py serve-once` had no per-request guard and `run_queue` ran
  `subprocess.run(cwd=<client-recorded cwd>)`, so an iso agent running `agb` from a `0700` attachment
  dir recorded a cwd the controller couldn't `chdir` into → `PermissionError` aborted the whole batch
  + the promoted `.working.json` re-crashed every tick → fleet-wide silent queue death ~26h while the
  daemon reported healthy (cm-prod RCA finding F8, #1949). Fix: cwd fallback + per-request dead-letter
  so one poison can't kill the batch (smoke `1949-gateway-poison-request`). With F1 (v0.16.14), this
  **completes the F1/F8 daemon-stability P1 pair**; cut directly to official given the live impact on
  installs already on v0.16.13/14 (the urgent-stability soak exception). The remaining
  stability-unrelated cm-prod findings (#1943 F3 cron model-gate, #1947 F5 iso index-rebuild
  graceful-skip, #1945 F7 iso restart settings-perm, #1946 F4 headless config, #1944 F6 nudge backoff
  — root now removed by F8) are deferred to the next version via the RC-soak rule. Supersedes v0.16.14
  as line head; prior v0.16.x LTS designations remain valid.
- **v0.16.14 — prior LTS-line head (2026-06-17).** GitHub release `v0.16.14` (LTS); a **hotfix** — a
  sudo-self systemd-`--user` install bound the always-on reconcile daemon AND its liveness-backstop
  timer to the invoking login session without lingering, so a single session churn (a `--replace`
  restart) stopped both → a ~27h silent production outage + frozen Claude token auto-rotation (cm-prod
  v0.16.13 RCA finding F1; patch-dev code-side confirm #8756). The daemon installer now runs
  `loginctl enable-linger` on the `--apply` path (not only `--enable`, so `agb upgrade` reaches
  existing installs) with a sudo fallback + loud remediation. Companion cm-prod findings tracked
  fast-follow: #1943 (F3 cron model-gate), #1944 (F6 nudge churn), #1945 (F7 iso restart
  settings-perm), #1946 (F4 headless shared-UID config path), #1947 (F5 iso bootstrap graceful-skip);
  cm-prod has locally mitigated each. Supersedes v0.16.13 as line head; prior v0.16.x LTS designations
  remain valid.
- **v0.16.13 — prior LTS-line head (2026-06-17).** GitHub release `v0.16.13` (LTS); a **security +
  reliability hardening bundle**: config-mutation trust derived from an unspoofable
  controller-published pane-pid binding rather than forgeable env (#1738 — ownership store-writability
  fail-close, clean-allowlist tmux-liveness probe, kernel pane-owner-UID check, fail-safe daemon
  prune, indirection-aware hook gate), a tmux-socket single-point-of-failure guard so a destructive
  smoke run can no longer down the whole agent fleet (#1932/#1936), and canonical hook-path resolution
  + missing-hook self-heal so a transient `/tmp` BRIDGE_HOME render can no longer brick a production
  farm (#1934), plus the #1939 smoke-harness fix the cm-prod verification surfaced. Promoted from
  `v0.16.13-rc2` after a three-way re-test: macbook isolated smokes, a real OrbStack Linux iso-v2 `agb
  upgrade` (rc=0, 0 conflicts, systemd-aware #1905 quiesce fired, post-upgrade health warn=0 crit=0),
  and cm-prod production-host **isolated** verification (full bundle smokes + #1738's 11 security DENY
  teeth; the live customer-fleet upgrade was intentionally NOT run — cm-prod is stable-only and adopts
  this LTS via the `lts` channel). Supersedes v0.16.12 as line head; prior v0.16.x LTS designations
  remain valid.
- **v0.16.12 — prior LTS-line head (2026-06-15).** GitHub release `v0.16.12` (LTS); the **upgrade
  respawn-race fix** — the #1820 layout-v2 reconcile quiesce is now init-system-aware on both systemd
  (#1905) and launchd (#655), closing an `rc=3` half-applied-upgrade footgun that hit every
  systemd-managed install (the init system respawned the daemon inside the quiesce window → the
  fail-closed reconcile fence saw a live pid → abort); validated by cm-prod's #1905 host-acceptance
  passing 5/5. Also: iso transcript harvest via run-as-iso (#1894), resume config-dir
  realpath-hardening (#1893), and usage-probe CDN-edge classification (#1824). Superseded by v0.16.13
  as line head; its LTS designation remains valid.
- **v0.16.11 — prior LTS-line head (2026-06-15).** GitHub release `v0.16.11` (LTS); **dynamic agents
  become vanilla-equivalent** — a dynamic Claude/Codex agent runs like vanilla Claude Code / Codex CLI
  against the operator's global config + native resume, with the bridge layering only project-local
  comms hooks, superseding the private-config-dir isolation that was destroying operator sessions
  (#1900/#1901). Also: operator-session-hijack fix (#1889), iso-v2 create-path completeness — iso-owned
  `memory/` + always-create `agent-meta.env` (#1895), doc-backfill roster-first engine fail-closed
  (#1896), iso-boundary graceful-skip across controller scanners (#1878), watchdog/cron/channel fixes
  (#1872/#1880/#1881/#1888), and a 3-way-sharded unit/static CI smoke battery (#1898). Operator-directed
  capability-add on the LTS line; #1900/#1901 framed as operational convergence (dynamic agents
  behaving correctly), not a broad new mainline feature. Supersedes v0.16.10 as line head; prior
  v0.16.x LTS designations remain valid.
- **v0.16.10 — prior LTS-line head (2026-06-13).** GitHub release `v0.16.10` (LTS); a large reliability
  + migration train consolidating rc1→rc3, hardened through a fleet soak across sean-mac (macOS
  shared-mode) and cm-prod (first real Linux iso-v2 production host) — zero data loss / zero drift on
  both. Dynamic-agent restart relaunch + self-restart survival + provisioning preserve across recreate
  (#1852/#1853/#1857); gated layout-v2 four-writer migration with fail-closed v1→v2 reconciliation
  (#1820); iso-v2 reconcile graceful-skip + structured audit + cron-worker prod-mutation fence (rc3);
  reconcile observability (rc2); #1838 tool-policy security fix. Superseded by v0.16.11; its LTS
  designation remains valid.
- **v0.16.9 — prior LTS-line head (2026-06-12).** GitHub release `v0.16.9` (Latest at the time);
  fleet-reliability sweep from a day of live v0.16.8 field reports — idle-reaper policy fix
  (operator-created/loop dynamics never reaped #1795), doc-migration memory rollback (#1781), picker
  idle false-escalation (#1783), tasks-db blessed verb + WAL root cause + #1709-class env-assign guard
  (#1786), doctor case-insensitive orphan/retire + two-tree drift (#1787/#1788), cron scope fence +
  origin server-validation (#1792). Superseded by v0.16.10; its LTS designation remains valid.
- **v0.16.8 — prior LTS-line head (2026-06-11).** GitHub release `v0.16.8` (Latest at the time);
  session-resume + settings/CI reliability sweep (restart-resume both mechanisms #1769, static
  model/effort #1763, iso own-settings #1766, self-ref settings loop #1759, HUD seed #1753, ratchet
  anchoring #1764) + no-LLM picker auto-resolve (#1762). Superseded by v0.16.9; its LTS designation
  remains valid.
- **v0.16.7 — prior LTS-line head (2026-06-10).** `trusted-routed` A2A transport (#1758 —
  operator-directed capability-add on the LTS line) + the #1755/#1756 hooks/settings pair. Restored the
  us↔cm-prod production A2A pair (bidirectional verify 2026-06-11).
- **v0.16.6 — prior LTS-line head (2026-06-10).** Mesh-robustness + read-guard hardening + reliability
  sweep (10 lanes).
- **v0.16.5 — prior LTS-line head (2026-06-09).** GitHub release `v0.16.5 (LTS)`; zero-touch A2A Rooms
  mesh — a k8s-controller-style reconcile control-loop on the daemon tick that self-heals the
  multi-node mesh (stable-address #1705 / tunnel-health #1706 / peer-reachability #1707 adapters),
  token-bootstrap room join + leader-relay + roster anti-entropy (#1695), and `agb a2a net-status` v2
  as the control-loop status window (#1708); transport-agnostic (warp + tailscale). An LTS-line feature
  release — does not supersede the prior LTS designation. Supersedes v0.16.4 as line head; v0.16.4's
  LTS designation remains valid.
- **v0.16.4 — prior LTS-line head (2026-06-09).** GitHub release `v0.16.4 (LTS)`; guard over-block
  hardening wave (#1690/#1692/#1693/#1701/#1697). Superseded by v0.16.5 as line head; v0.16.4's LTS
  designation remains valid.
- **v0.16.2 — original LTS declaration (2026-06-08).** The first release on this line declared as LTS.
  Fleet convergence: macbook / SYRS mac-mini / cm-prod + ip-10-242 (AL2023) + orbstack Linux iso v2
  VM-verify, zero new issues.
