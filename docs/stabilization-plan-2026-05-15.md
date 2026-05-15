# Stabilization Plan — 2026-05-15 (v0.13.10 post-ship)

**Status**: Active work in autonomous mode + Linux VM verification per stage.

**Operator directive (2026-05-15 22:08-22:20 KST)**:
1. Audit ENTIRE codebase (not just isolation-v2) for bugs, stability, refactor
2. Document findings so next session can resume
3. **Slow down version bumps** ("뭐 한것도 없는데 버전만 졸라 올라가요") — stabilization PRs do NOT bump VERSION/CHANGELOG; only true user-facing changes get a release
4. Use OrbStack VMs to verify each stage on Linux before next stage
5. Discuss with `agb-dev-codex` when ambiguous; proceed only on complete agreement

## Linux VM policy (codex-tightened)

### Available now

| VM | Distro | Bash | agb VERSION | Purpose |
|---|---|---|---|---|
| `agb-test` | Oracle Linux 9 (RedHat) | 5.1.8 | 0.8.4 | **Leap fixture** — kept on v0.8.4 to verify v0.7.x → v0.13.x → v0.14 upgrade paths end-to-end |
| `linux-systemd-test` | Debian bookworm | 5.2.15 | 0.8.5 | **Will be upgraded to v0.13.10 baseline** (S1 deliverable) — current-state Linux regression checks for each stage |

### Required additions

| VM | Purpose | When required |
|---|---|---|
| New: `bash-539-test` (any distro, Bash 5.3.9) | Reproduce footgun #11 wedge env where patch host originally failed; mandatory before claiming any heredoc-class closure | Before S10-late (heredoc cleanup wave). Optional but recommended before S5 (platform discriminator) to confirm no regression. |

### Per-stage VM verification matrix

| Stage class | VM(s) required |
|---|---|
| Doc-only PR | None (CI runs lint/syntax) |
| Code change touching macOS-specific paths only | macOS local + agb-test sanity check |
| Code change touching Linux-specific paths | linux-systemd-test (current baseline) + agb-test (leap fixture) |
| Heredoc / bash-stdin / upgrade-path code | linux-systemd-test + agb-test + bash-539-test |
| Platform discriminator (S3, S5, S6) | linux-systemd-test + agb-test (both) |

### Codex correction rationale

The previous draft listed VMs as "useful for testing" with no policy. Codex flagged that:
1. Outdated installs alone (v0.8.4, v0.8.5) can't represent current-state regression checks
2. Bash 5.3.9 reproduction is mandatory before claiming footgun #11 closure
3. Leap testing and current-state testing are distinct concerns

This split keeps `agb-test` as the leap fixture and upgrades `linux-systemd-test` to v0.13.10 as the current baseline.

## Audit summary (2026-05-15)

5 parallel audit subagents covered: bugs/error-handling (A), stability/fragile patterns (B), isolation-v2 follow-up + discriminator design (C), refactor/tech debt (D), test coverage + doc drift (E).

### Bug surface (Audit A)
- **0 P0** (no actively-blocked-by-this)
- **14 P1** (should-fix): silent error swallowing in daemon state writes, missing retries (mkdir-based lock, SQLite busy, flock with linear wait), races (atomic marker writes using `$$` instead of `mktemp`, SQLite without `busy_timeout`), resource leaks (`mktemp` without EXIT trap in heartbeat / token-recovery / refresh-stall), `set -u`/`set -e` traps in upgrade migration capturing the wrong rc, daemon state-file syntax validation surface
- **17 P2** (nice-to-have): brittle but currently OK

### Stability concerns (Audit B)
- **6 P1**: SQLite contention, channel-dotenv vs daemon races, daemon shutdown completeness, backup integrity on OOM/ENOSPC, marker-version missing field, watchdog cross-home reachability
- **11 P2**: tmux orphan reap, PID-file staleness, mktemp TMPDIR relative-path safety, symlink TOCTOU in memory-daily-reduce, clock skew in watermark writes, Sonoma extended-attribute residue, cron diagnostic on hang
- **Hardcoded-timeout catalog**: 9 important timeouts; most have env overrides; daemon `bridge_with_timeout` ceiling (120s) is the most concerning under SQLite contention

### Isolation-v2 (Audit C, follow-up to first-pass 275-touchpoint survey)
- Discriminator design: `BRIDGE_ISOLATION_REQUIRED=yes|no|auto` resolver
- `auto`: Linux=yes, macOS=no
- Two predicates: `bridge_isolation_v2_enforce()` (Bucket 2 enforcement; returns 0 on Linux, 1 on macOS) and `bridge_isolation_v2_require_linux()` (Bucket 3 contract; returns 0 on Linux, hard-fails with friendly error on macOS)
- 20 highest-impact sites enumerated with file:line + current behavior + proposed gate
- Backward compatibility: `BRIDGE_LAYOUT=legacy` env leak demoted from hard-die to warning (resolves Sean's mac stop-hook noise)
- New smoke `scripts/smoke/isolation-v2-platform-discriminator.sh` (T1-T10) sketched

### Refactor / tech debt (Audit D)
- **Bash 3.2 re-exec workaround**: still in 10+ files; ~80 LOC removable since Bash 4+ is documented requirement
- **Env var sprawl**: 500+ `BRIDGE_*` vars; inconsistent singular/plural; `V2`/`V3` embedded in names; need canonical registry
- **20k shellcheck disable annotations**: most legitimate, mass undocumented
- **Top duplicated patterns**: state-file source-and-validate (5+ callsites), JSON formatting (27 files), mktemp+trap boilerplate (15+ files), `sudo` escalation wrappers (20+ sites)
- **Large files**: bridge-daemon.sh (6617 LOC), bridge-agent.sh (4697), bridge-memory.py (4259), bridge-cron.py (3286), bridge-upgrade.py (2975) all mix multiple concerns
- **Naming inconsistency**: `bridge_isolation_v2_*` vs `bridge_isolated_*` vs `bridge_layout_*` vs `BRIDGE_LAYOUT_MARKER_*` vs `BRIDGE_ISOLATION_V2_MARKER_*`

### Test coverage + docs drift (Audit E)
- **False alarm corrected**: 3 v0.13.10 smoke files exist on `origin/main` (Audit E's local checkout was stale)
- **Actual gap**: bridge-upgrade.sh has 18 deferred python heredoc sites (v0.13.10 carry-over) with no current regression smoke; needs lint rule + cleanup wave
- **Hardening discipline**: `ci-select-smoke.sh` registration must be coupled to new-smoke PRs; Track A/B/C v0.13.10 r1 codex all caught it
- **Doc drift**: ARCHITECTURE.md missing 9 lib/ modules added since v0.8.0; CLAUDE.md, OPERATIONS.md, KNOWN_ISSUES.md missing v0.13.7-v0.13.10 patch wave summary; README.md lacks version context

## Version policy (operator directive, codex-clarified)

**Stabilization PRs never bump VERSION or add CHANGELOG entries.** Even when a stabilization PR changes operator-visible behavior (e.g., clearer error on Bash 3.2, suppressed stop-hook noise), the individual PR does NOT cut a release. Instead:

- **Release PR** (separate, batched): when the operator decides to ship a deploy-able tag, a release PR collects ALL operator-visible changes accumulated since the last release into ONE VERSION+CHANGELOG entry. The release PR is opened explicitly by the operator (or on operator's "ship" cue), not automatically per fix.
- **Per-stage labels**: each stabilization PR header MUST state `release-impact: <none|user-visible|migration>`. Examples:
  - S1 doc catch-up → `release-impact: none`
  - S2 stale-env unblock → `release-impact: user-visible` (operators with leaked `BRIDGE_LAYOUT=legacy` see different behavior)
  - S4 Bash 3.2 cleanup → `release-impact: user-visible` (clearer error)
  - S5 platform discriminator → `release-impact: migration` (new env semantic)
- **Release PR aggregation**: at release time, the release PR body lists all merged-since-last-release PRs with their `release-impact` labels. Only `user-visible` and `migration` items get a CHANGELOG bullet; `none` items are silently included for git-log completeness.
- **Major-minor reservation**: v0.14.0 is reserved for the platform-discriminator semantic milestone (S5 completion). v0.14.1+ are reserved for post-v0.14.0 cleanup releases, NOT pre-allocated to specific stages (codex correction: previous draft pre-declared v0.14.1 for S6, which contradicts the "batch at deploy time" principle).
- **What never bumps**: doc updates, test-only PRs, internal refactors with no behavior change, smoke coverage additions, lint fixes, ci-select-smoke registration follow-ups.

This is a behavior change from the v0.13.x cycle where 4 patches in one day each got VERSION+CHANGELOG entries despite each cycle having only one operator-visible change (the leap unblock progression).

## Stage plan

Each stage:
1. Implement on macOS (local dev)
2. Run macOS-side smokes
3. Push to PR (`fix/<slug>` or `chore/<slug>`) — PR header MUST include `release-impact: <none|user-visible|migration>`
4. Verify CI green (covers macOS smoke + lint)
5. Test on OrbStack Linux VM (per §"Linux VM policy" per-stage matrix)
6. Codex review via agb-dev-codex queue
7. Merge after Linux green + codex implement-ok
8. **Stabilization PRs NEVER bump VERSION/CHANGELOG.** Release PR is separate and batched at operator's deploy cue. See §"Version policy".

### Stage order (smallest → largest impact)

Codex r2 correction: S10-early (lint-only guard against NEW heredoc-stdin sites) MUST land before S2/S3/S5 touch upgrade-adjacent code. Hoisted as **S1.5** in the order below to make this explicit, ahead of S2.

**S0 — Bookkeeping (no code change)**
- Write this document (in progress)
- Sync local checkout with origin/main
- Verify OrbStack VMs reachable
- **Stage 0 completion criteria**: this doc on `main`

**S1 — Doc catch-up + audit ground truth (no code) [release-impact: none]**
- ARCHITECTURE.md: add 9 missing lib/ modules
- KNOWN_ISSUES.md: add "Fixed in v0.13.x wave" + "Outstanding v0.14.x" sections
- CLAUDE.md: brief recent-patches note + `lib/upgrade-helpers/` pattern reference
- OPERATIONS.md: consolidated v0.13.7-v0.13.10 hotfix wave operator follow-up
- README.md: version context + leap path warning
- **NEW MANDATORY DELIVERABLE**: `docs/audit-2026-05-15.md` archiving raw findings with structured rows: `id | severity (P0/P1/P2) | category | file:line | one-line | risk | owner-stage | status`. Covers the 14 P1 bug-surface + 6 P1 stability + 18 deferred python heredoc sites + isolation-v2 top-20 list. Without this, subsequent sessions cannot pick up from this plan alone (codex correction: the previous draft left audit details in conversation-only state which is not durable).
- No VERSION bump
- Linux VM: not strictly required (no code change), but smoke runs still pass
- Single PR: `docs/v0.13.x-catchup-and-audit-archive`

**S1.5 — Heredoc-stdin ban lint guard (BEFORE S2) [release-impact: none]**

Codex r2 promoted this from S10-early into the explicit stage order. Purpose: prevent S2-S5 stabilization stages from accidentally creating new footgun #11 sites in upgrade-adjacent code.

- Add grep-based pre-commit / CI check rejecting NEW `<<EOF`/`<<'PY'` heredoc-stdin patterns in bridge-upgrade.sh
- Existing 18 deferred sites grandfathered with inline `# heredoc-grandfathered` annotations
- No code migration in this stage — just regression prevention
- Linux VM verification: not required (lint-only change; CI runs the new check)
- PR: `chore/heredoc-ban-lint-guard-s1_5`

The full migration of the 18 grandfathered sites lives in S10-late (post-S6, with `bash-539-test` VM mandatory).

**S2 — Operator-visible blockers: macOS noise + stale BRIDGE_LAYOUT=legacy env unblock [release-impact: user-visible]**

Two narrowly-scoped operator-visible fixes (codex flagged the second as a current CLI blocker — codex itself hit it running the consensus check via `agb inbox`):

1. **macOS isolation-v2 matrix-path noise**:
   - Sean's stop-hook warning: `[경고] write_agent_state_marker: ensure_matrix_path failed for agent=... marker=idle-since`
   - Add macOS early-return to `bridge_isolation_v2_ensure_matrix_path` (lib/bridge-isolation-v2.sh:1772)
   - Add the same gate to `bridge_isolation_v2_apply_row` for setgid-related operations
   - Smoke: new `scripts/smoke/isolation-v2-macos-noise-suppression.sh` (1 test on Darwin)

2. **`BRIDGE_LAYOUT=legacy` env leak demoted from hard-die to warning**:
   - Currently `lib/bridge-layout-resolver.sh:140` hard-dies when env says `legacy` even if marker says `v2`
   - This is the leak that bit Sean's session AND codex's consensus check
   - Fix: when marker exists and is valid v2 but env says `legacy`, log warning and prefer marker
   - Smoke: new `scripts/smoke/layout-resolver-marker-over-env.sh` (3 cases: env=legacy + marker=v2 → use marker; env=v2 + no marker → use env; env+marker both set + agree → use marker)

S2 is hard-coded to these two narrow operator-visible blockers, NOT a general discriminator (that's S3's scope per codex correction).

- Linux VM verification: agb-test (sanity check that Linux enforcement still works) + linux-systemd-test (verify env-leak fix doesn't break v2-marker installs)
- PR: `fix/operator-visible-isolation-v2-blockers-s2`

**S3 — Platform discriminator foundation (medium) [release-impact: migration]**
- New `lib/bridge-isolation-discriminator.sh` with the 3 predicates from Audit C
- Re-wire S2's hardcoded gates into the discriminator
- 1-2 additional Bucket 2 sites converted as proof
- New smoke `scripts/smoke/isolation-v2-platform-discriminator.sh`
- ci-select-smoke registration
- Linux VM: agb-test + linux-systemd-test (both)
- PR: `feat/isolation-v2-platform-discriminator`

**S4 — Bash 3.2 re-exec removal — DEFERRED to post-S5 [release-impact: user-visible]**

Per codex correction: removing the Bash 3.2 re-exec is NOT pure cleanup. The re-exec is currently a load-bearing entry shim — operators on macOS who invoke `bridge-lib.sh` via system `/bin/bash` (Bash 3.2) reach a Bash 4+ candidate via the shim. Removing the shim changes the failure mode for those operators (clear error instead of working-via-detection). This is operator-visible and must wait until:
1. S5 platform-discriminator is stable on main
2. Operator docs (README, OPERATIONS) explicitly require Bash 4+ at install time
3. Codex checkpoint before dispatch (compatibility proof: any prod path still reaching via Bash 3.2 should be enumerated)

Move S4 to AFTER S5. New numbering: original S4 becomes S5.5 (post-discriminator, pre-Bucket-2-finalize cleanup).

**S5 — Bucket 2 enforcement gates (multi-track wave) [release-impact: migration]**
- 140 Linux-only enforcement sites gate-wrap with `bridge_isolation_v2_enforce()`
- Track A: lib/bridge-isolation-v2*.sh (~80 sites)
- Track B: bridge-daemon.sh + lib/bridge-channels.sh + lib/bridge-state.sh (~30 sites)
- Track C: bridge-agent.sh scaffold + bridge-init.sh (~15 sites)
- Track D: cross-platform smoke expansion (macOS no-op + Linux full)
- After all S5 tracks merge: **a separate release PR cuts v0.14.0** as the platform-discriminator semantic milestone. The S5 tracks themselves do NOT bump VERSION; the release PR aggregates them at operator's deploy cue per §"Version policy".

**S6 — Bucket 3 contract errors + Bucket 4 splits (multi-track) [release-impact: migration]**
- 35 Bucket 3 sites get `bridge_isolation_v2_require_linux()` early-error
- 55 Bucket 4 mixed sites get function-split refactor
- Track E: docs (OPERATIONS.md upgrade-on-macOS section; KNOWN_ISSUES.md updates)
- VERSION: NO pre-allocation. The next release PR after S5 v0.14.0 will batch any user-visible items from S6+. Codex correction: do NOT pre-declare v0.14.1 for cleanup; that contradicts the "batch at deploy time" policy.

**S7 — Audit A P1 cleanup wave**
- Silent error swallowing fixes (daemon state, marker writes)
- Tempfile cleanup discipline (mktemp + EXIT trap)
- Retry shapes (exponential backoff on SQLite busy, mkdir lock, flock)
- `set -u`/`set -e` trap-capture corrections
- VERSION: stabilization patches; do not bump

**S8 — Audit B P1 cleanup wave**
- SQLite `busy_timeout` PRAGMA + Python retry context
- Daemon shutdown completeness (post-stop validation + tmux pane reap)
- Backup integrity check (`tar -tzf` after creation)
- Marker version field add
- VERSION: still no bumps unless user-visible

**S9 — Audit D refactor wave (long-tail)**
- Env var registry (`lib/bridge-config-vars.sh` canonical doc)
- Bridge-daemon.sh split (3-way)
- Bridge-agent.sh split (3-way)
- Bridge-memory.py modularization
- Bridge-cron.py modularization
- Naming consolidation (`bridge_isolation_v2_*` → `bridge_marker_isolation_*`)
- Multi-cycle effort; pick 1-2 per cycle to avoid disruption

**S10 — Bash heredoc-stdin ban lint + remaining 18 sites [release-impact: none]**

Per codex correction: S10 was too late if broad stabilization touches upgrade-adjacent code first.

**Split into two phases**:

- **S10-early (BEFORE S4 / before any upgrade-adjacent stabilization touches bridge-upgrade.sh)**:
  - Lint-only guard: add a grep-based pre-commit / CI check rejecting NEW `<<EOF`/`<<'PY'` heredoc-stdin patterns in bridge-upgrade.sh
  - Existing 18 deferred sites grandfathered with an inline `# heredoc-grandfathered` annotation
  - No code migration yet — just regression prevention
  - Goal: prevent stabilization stages from accidentally creating new footgun #11 sites

- **S10-late (after S6, defensive cleanup wave)**:
  - Migrate the 18 grandfathered sites to standalone helpers under `lib/upgrade-helpers/` (extends v0.13.9 pattern)
  - Per-site verification on Bash 5.3.9 VM (see VM policy)
  - Drop grandfather annotations as sites move

- Requires Bash 5.3.9 VM (see §"Linux VM policy") before S10-late dispatch — codex flagged this as the only way to claim footgun #11 closure rigorously.

## Codex consensus checkpoints

Submit to `agb-dev-codex` queue when:
- **S0 → S1 transition**: confirm doc catch-up scope is right
- **S2 → S3 transition**: confirm discriminator design before wide gate rollout
- **S5 (any Track) ambiguity**: any time a "is this really Linux-only?" question comes up
- **S7+ P1 cleanup**: confirm priority order each cycle

For ambiguous scope decisions, the consensus rule (per operator directive): proceed only when codex agrees. If codex disagrees, surface to next operator session.

## Progress log

Append below as stages complete.

### Stage 0 — Plan write-up
- **Started**: 2026-05-15 22:30 KST
- **Status**: codex r1 needs-more (5 items) → r2 needs-more (3 doc consistency items) → r3 dispatched
- **PR**: #901, branch `chore/stabilization-plan-2026-05-15`
- **Next**: r3 implement-ok → merge → S1 dispatch

### Stage 1 — Doc catch-up + audit ground truth archive
- **Status**: pending S0 merge

### Stage 1.5 — Heredoc-ban lint guard
- **Status**: pending S1 (per codex r2 ordering)

### Stage 2 — Operator-visible blockers (macOS noise + env-leak)
- **Status**: pending S1.5

### Stage 3 — Platform discriminator foundation
- **Status**: pending S2

(remaining stages pending)

## Audit raw output — archived in S1

S1 must create `docs/audit-2026-05-15.md` with the structured row format (`id | severity | category | file:line | one-line | risk | owner-stage | status`). Until S1 lands, this section is intentionally incomplete and **S1 is blocked on archiving the evidence** (the audit subagent outputs only exist in this session's task notifications).

Next session: do NOT proceed past S1 without verifying `docs/audit-2026-05-15.md` exists and is non-empty.

## Recovery from misuse

If a stage breaks something:
1. **Linux VM regression**: revert the PR, codex post-mortem, re-dispatch with narrower scope
2. **macOS regression**: same, but Sean's local install is the canary
3. **Heredoc-class regression** on bridge-upgrade.sh: hold all further stages, dispatch heredoc-cleanup-first wave per S10
4. **CI gone bad**: investigate, NEVER force-merge a red CI in this stabilization cycle

## Next-session entry point

A new session can start from this file by:
1. Reading this doc end-to-end (single source of truth for stabilization)
2. Checking the **Progress log** for last completed stage
3. Resuming at the next stage
4. Updating the Progress log before committing
