# Stabilization Plan — 2026-05-15 (v0.13.10 post-ship)

**Status**: Active work in autonomous mode + Linux VM verification per stage.

**Operator directive (2026-05-15 22:08-22:20 KST)**:
1. Audit ENTIRE codebase (not just isolation-v2) for bugs, stability, refactor
2. Document findings so next session can resume
3. **Slow down version bumps** ("뭐 한것도 없는데 버전만 졸라 올라가요") — stabilization PRs do NOT bump VERSION/CHANGELOG; only true user-facing changes get a release
4. Use OrbStack VMs to verify each stage on Linux before next stage
5. Discuss with `agb-dev-codex` when ambiguous; proceed only on complete agreement

## Available Linux test infrastructure

| VM | Distro | Bash | agb VERSION | Purpose |
|---|---|---|---|---|
| `agb-test` | Oracle Linux 9 (RedHat) | 5.1.8 | 0.8.4 | RedHat ecosystem + RHEL semantics; v0.8.4 → v0.14 leap testing |
| `linux-systemd-test` | Debian bookworm | 5.2.15 | 0.8.5 | Debian ecosystem; systemd unit interaction |

Both VMs are useful for:
- Per-stage Linux behavior verification (the macOS dev path can't catch Linux-only regressions)
- Cross-distro coverage (RedHat vs Debian path differences)
- v0.7.x → v0.13.x leap testing (predates the 4 hotfix cycles)

A future Bash 5.3.9 VM may be added to reproduce the exact bash version where patch host (operator's prod) hit footgun #11.

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

## Version policy (operator directive)

**Default**: stabilization changes do NOT bump VERSION or add CHANGELOG entries.

**Patch bumps** (v0.13.11, v0.13.12, ...): ONLY when operator-visible change ships
- New CLI behavior
- Bug fix that resolves a user-reported issue
- Migration step required

**Minor bumps** (v0.14.0): ONLY when the platform-discriminator refactor completes (Bucket 2 + 3 gates fully landed). The minor bump signals a real semantic milestone, not accumulated patches.

**No bumps for**: doc updates, test-only PRs, internal refactors with no behavior change, smoke coverage additions, lint fixes.

This is a behavior change from the v0.13.x cycle where 4 patches in one day each got VERSION+CHANGELOG entries.

## Stage plan

Each stage:
1. Implement on macOS (local dev)
2. Run macOS-side smokes
3. Push to PR (`fix/<slug>` or `chore/<slug>`)
4. Verify CI green (covers macOS smoke + lint)
5. Test on OrbStack Linux VM (agb-test first; linux-systemd-test for systemd-touching stages)
6. Codex review via agb-dev-codex queue
7. Merge after Linux green + codex implement-ok
8. NO VERSION bump unless stage produces user-facing change

### Stage order (smallest → largest impact)

**S0 — Bookkeeping (no code change)**
- Write this document (in progress)
- Sync local checkout with origin/main
- Verify OrbStack VMs reachable
- **Stage 0 completion criteria**: this doc on `main`

**S1 — Doc catch-up (no code)**
- ARCHITECTURE.md: add 9 missing lib/ modules
- KNOWN_ISSUES.md: add "Fixed in v0.13.x wave" + "Outstanding v0.14.x" sections
- CLAUDE.md: brief recent-patches note + `lib/upgrade-helpers/` pattern reference
- OPERATIONS.md: consolidated v0.13.7-v0.13.10 hotfix wave operator follow-up
- README.md: version context + leap path warning
- No VERSION bump
- Linux VM: not strictly required (no code change), but smoke runs still pass
- Single PR: `docs/v0.13.x-catchup-and-stabilization-plan`

**S2 — macOS isolation noise fix (small code change)**
- Sean's stop-hook warning: `[경고] write_agent_state_marker: ensure_matrix_path failed for agent=... marker=idle-since`
- Add macOS early-return to `bridge_isolation_v2_ensure_matrix_path` (lib/bridge-isolation-v2.sh:1772)
- Add the same gate to `bridge_isolation_v2_apply_row` for setgid-related operations
- Smoke: new `scripts/smoke/isolation-v2-macos-noise-suppression.sh` (1 test on Darwin)
- Linux VM verification: agb-test smoke run (verify no regression to Linux enforcement)
- No VERSION bump (operator-internal noise; not a CLI behavior change)
- PR: `fix/isolation-v2-macos-quiet`

**S3 — Platform discriminator foundation (medium)**
- New `lib/bridge-isolation-discriminator.sh` with the 3 predicates from Audit C
- Wire S2's hardcoded gate into the discriminator
- 1-2 additional Bucket 2 sites converted as proof
- New smoke `scripts/smoke/isolation-v2-platform-discriminator.sh`
- ci-select-smoke registration
- Linux VM: agb-test + linux-systemd-test (both)
- No VERSION bump (still no user-facing change)
- PR: `feat/isolation-v2-platform-discriminator`

**S4 — Bash 3.2 re-exec removal (small refactor)**
- Remove the 30-line Bash 4 candidate re-exec from bridge-lib.sh + bootstrap-memory-system.sh + 8 test scripts
- Replace with `[[ ${BASH_VERSINFO[0]} -lt 4 ]] && bridge_die "Bash 4+ required"`
- Verify on Linux VM (Bash 5.x default, should be no-op)
- Verify on macOS (`/opt/homebrew/bin/bash`, Bash 4+, should be no-op)
- No VERSION bump (operator behavior unchanged unless they were stuck on Bash 3.2, in which case the new error is clearer)
- PR: `chore/remove-bash-3.2-re-exec`

**S5 — Bucket 2 enforcement gates (multi-track wave)**
- 140 Linux-only enforcement sites gate-wrap with `bridge_isolation_v2_enforce()`
- Track A: lib/bridge-isolation-v2*.sh (~80 sites)
- Track B: bridge-daemon.sh + lib/bridge-channels.sh + lib/bridge-state.sh (~30 sites)
- Track C: bridge-agent.sh scaffold + bridge-init.sh (~15 sites)
- Track D: cross-platform smoke expansion (macOS no-op + Linux full)
- VERSION bump: v0.14.0 (this is the platform-discriminator semantic milestone)
- PR: per-track + bundle release

**S6 — Bucket 3 contract errors + Bucket 4 splits (multi-track)**
- 35 Bucket 3 sites get `bridge_isolation_v2_require_linux()` early-error
- 55 Bucket 4 mixed sites get function-split refactor
- Track E: docs (OPERATIONS.md upgrade-on-macOS section; KNOWN_ISSUES.md updates)
- VERSION: v0.14.1 (post-v0.14.0 cleanup)

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

**S10 — Bash heredoc-stdin ban lint + remaining 18 sites**
- Add a custom lint rule or shellcheck wrapper rejecting `<<EOF`/`<<'PY'` to subprocess in bridge-upgrade.sh
- Migrate the remaining 18 deferred python heredoc sites (post-apply / alternate subcommand paths)
- VERSION: no bump (defensive cleanup)

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
- **Status**: in-progress
- **Next**: commit this doc + S1 dispatch

### Stage 1 — Doc catch-up
- **Status**: pending S0

### Stage 2 — macOS noise fix
- **Status**: pending S1

### Stage 3 — Platform discriminator
- **Status**: pending S2

(remaining stages pending)

## Audit raw output

The 5 audit subagents produced detailed enumeration. Key files cited inline above. For each finding's file:line, see the in-memory audit transcripts (this session's task notifications); summarize-and-archive into a separate `docs/audit-2026-05-15.md` if it grows beyond conversation scope.

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
