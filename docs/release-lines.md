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

- **v0.16.2 — declared LTS 2026-06-08.** GitHub release titled `v0.16.2 (LTS)` (Latest); README current-stable line marked LTS. Converged across the fleet (macbook / SYRS mac-mini / cm-prod) + a 4th host (ip-10-242, AL2023) + orbstack Linux iso v2 VM-verify, zero new issues.
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
