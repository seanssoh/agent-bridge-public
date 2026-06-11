# Release Lines & LTS Policy

This file is the canonical policy for how Agent Bridge versions are branched, supported, and shipped. CLAUDE.md and AGENTS.md carry the headlines and point here. Operator-decided 2026-06-08 (with the v0.16.2 LTS cut); update this file when the policy changes.

## Model: one LTS line + a mainline

Agent Bridge runs a **Long-Term Support (LTS) line** for conservative/production installs plus a **mainline** for new development. An LTS is not a separate product — it is a blessed stable tag on a maintenance line that only receives vetted fixes. LTS and mainline share ~all code; they differ only in *what is allowed to land*.

- **`main`** — mainline development. After the first new feature lands it carries the next minor's beta (e.g. `v0.17.0-beta`). All new features and refactors go here first. **New features ship on a beta line first, never directly onto a stable/LTS line.**
- **`release/0.16-lts`** (created at fork time) — the LTS maintenance branch. Only backports that meet the criteria below land here, each cut as `v0.16.3`, `v0.16.4`, …

### One line until features diverge — do not fork prematurely

An LTS line and a mainline only pay off **once there is real feature divergence**. Until the first new *feature* exists, there is a single line (`main`), and the v0.16.x **hardening** sequence (v0.16.3, …) rides `main` and *is* the LTS line. Forking a maintenance branch before there is divergent work just creates two branches that must be kept in sync for no benefit.

### Fork trigger

The **first real new feature** is the fork point. At that moment:

1. Branch `release/0.16-lts` from the latest `v0.16.x` tag.
2. Bump `main` to `v0.17.0-beta` and start feature development there.

## Current LTS

- **Every v0.16.x release is an LTS release.** The whole v0.16 line is LTS; each patch is an LTS patch. When a new v0.16.x patch ships, it becomes the new line head but does NOT de-LTS the prior one — it supersedes it on the same line. GitHub release titles use `(LTS)` on every v0.16.x release. The LTS designation cannot be revoked retroactively for a prior v0.16.x patch.
- **v0.16.8 — current LTS-line head (2026-06-11).** GitHub release `v0.16.8` (Latest); session-resume + settings/CI reliability sweep (restart-resume both mechanisms #1769, static model/effort #1763, iso own-settings #1766, self-ref settings loop #1759, HUD seed #1753, ratchet anchoring #1764) + no-LLM picker auto-resolve (#1762). Supersedes v0.16.7 as line head; prior v0.16.x LTS designations remain valid.
- **v0.16.7 — prior LTS-line head (2026-06-10).** `trusted-routed` A2A transport (#1758 — operator-directed capability-add on the LTS line) + the #1755/#1756 hooks/settings pair. Restored the us↔cm-prod production A2A pair (bidirectional verify 2026-06-11).
- **v0.16.6 — prior LTS-line head (2026-06-10).** Mesh-robustness + read-guard hardening + reliability sweep (10 lanes).
- **v0.16.5 — prior LTS-line head (2026-06-09).** GitHub release `v0.16.5 (LTS)`; zero-touch A2A Rooms mesh — a k8s-controller-style reconcile control-loop on the daemon tick that self-heals the multi-node mesh (stable-address #1705 / tunnel-health #1706 / peer-reachability #1707 adapters), token-bootstrap room join + leader-relay + roster anti-entropy (#1695), and `agb a2a net-status` v2 as the control-loop status window (#1708); transport-agnostic (warp + tailscale). An LTS-line feature release — does not supersede the prior LTS designation. Supersedes v0.16.4 as line head; v0.16.4's LTS designation remains valid.
- **v0.16.4 — prior LTS-line head (2026-06-09).** GitHub release `v0.16.4 (LTS)`; guard over-block hardening wave (#1690/#1692/#1693/#1701/#1697). Superseded by v0.16.5 as line head; v0.16.4's LTS designation remains valid.
- **v0.16.2 — original LTS declaration (2026-06-08).** The first release on this line declared as LTS. Fleet convergence: macbook / SYRS mac-mini / cm-prod + ip-10-242 (AL2023) + orbstack Linux iso v2 VM-verify, zero new issues.
- An LTS is declared only on **proven convergence**: shipped + tagged, VM-verified on Linux iso v2, and a full fleet re-rollout surfacing zero new issues. (LTS declaration is delegated to the dev orchestrator when results are good — report, don't ask.)

## Support window

An LTS receives qualifying fixes **until the next LTS is declared** (operator, 2026-06-08). When the next LTS ships, the previous LTS support ends (optionally with a short overlap — decide per-cut; default is no overlap).

## Backport criteria (what may land on the LTS branch)

Land on the LTS branch **only**:

- Security fixes
- Data loss / corruption
- Upgrade / rollback breakage
- A regression that takes a fleet host down

**Not** on the LTS branch: new features, cosmetic fixes, performance-only changes (unless severe), refactors.

**Fix flow:** land on `main` first, then cherry-pick to the LTS branch **only if** it meets the criteria above. Most fixes are main-only; only qualifying fixes get backported.

## Versioning

- LTS line: **patch** bumps — `v0.16.3`, `v0.16.4`, …
- Mainline features: **minor** bump — `v0.17.0`, … The next LTS candidate is typically a later minor (e.g. `v0.18.0`).
- Bump size is the **operator's call** (standing preference: small bumps). A capability-add in a patch bump is allowed when the operator directs it (e.g. the `lts` channel in v0.16.3).
- Every release — LTS patch or mainline — still requires **explicit operator GO**, codex pair-review, and the README/docs sync (see CLAUDE.md "Releases require explicit operator permission").

## Upgrade-channel mapping (operational enforcement)

The LTS designation must be **enforced by the upgrader**, or it is only a label:

- Today `--channel stable` (the default) resolves to the **highest global `vX.Y.Z` tag** (`bridge_upgrade_latest_stable_tag` sorts all tags and takes the max). So the moment `v0.17.0` ships, every default-channel install would auto-jump **off** the v0.16 LTS on its next `upgrade --apply`. The LTS is currently **unenforced**.
- **v0.16.3 adds an `lts` channel** (a version-line pin that resolves to the latest `v0.16.x` tag). It **must ship on the v0.16.x line itself** so existing v0.16 installs can pin to their own line. The upgrader is a High-Risk area (CLAUDE.md High-Risk #3) → design it with codex direction-consensus first, leave the default channel behavior unchanged.
- **Channel guidance**: conservative / production installs (e.g. cm-prod) track `lts`. Adventurous installs track `stable` (latest stable), `dev` (main), or `current`/`--source` (the checkout).

## Agent ownership

- **One dev orchestrator** (`agb-dev-claude`) + **one codex pair** (`agb-dev-codex`) own **both** lines for now. The fleet patches (macbook / SYRS / cm-prod / ip-10-242) are **consumers** of releases, not co-developers.
- A **dedicated LTS agent** is warranted only **after the mainline fork**, when feature work on `main` and backporting to the LTS branch genuinely run concurrently and compete for one orchestrator's attention. Even then, use a **`git worktree` + an agent in the same repo** — **not** a separate clone/folder. Two working directories from one clone is the idiom; a second full checkout is only worth it for OS-user/credential isolation, which is not needed yet.
