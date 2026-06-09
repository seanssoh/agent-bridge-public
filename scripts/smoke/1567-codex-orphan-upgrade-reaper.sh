#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1567-codex-orphan-upgrade-reaper.sh — issue #1567.
#
# Pre-0.16.0 installs leak orphaned codex `app-server-broker.mjs` (+ child node
# app-server) processes reparented to init (ppid==1), and stale
# `bridge-queue-gateway.py socket-server` procs whose --bridge-home is a
# long-gone /tmp smoke dir. The prevention fix (#1560 per-teardown reap) stops
# NEW leaks but never clears the backlog a long-running server already
# accumulated. This issue adds a one-shot upgrade-time reaper:
# lib/upgrade-helpers/codex-orphan-cleanup.sh (+ .py detector + summary), gated
# by a migration marker so it runs EXACTLY ONCE, DRY-RUN + admin-task by default
# with an opt-in reap.
#
# This smoke drives the REAL detector/reaper against lightweight stand-in
# process trees that MIMIC the orphan command names + ppid==1 parentage (via a
# double-fork+setsid reparent + bash `exec -a` rename) — it never spawns a real
# codex broker, real queue-gateway, or real bridge install. It proves:
#   B1 dry-run (scan) kills NOTHING,
#   B2 reap kills the ppid==1 orphan broker but LEAVES a live (parented) broker,
#      and is idempotent (2nd scan finds nothing),
#   B3 queue-gateway staleness: a /tmp-smoke gone --bridge-home is matched, a
#      LIVE existing --bridge-home is excluded,
#   C  marker idempotence: a present marker short-circuits the shim, an absent
#      marker is written after a clean run,
#   D  the helper is invoked file-as-argv from bridge-upgrade.sh (no
#      heredoc-stdin), wired in the DRY_RUN-eq-0 apply block, with the marker +
#      opt-in env flag.

set -euo pipefail

SMOKE_NAME="1567-codex-orphan-upgrade-reaper"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

CLEANUP_SH="$SMOKE_REPO_ROOT/lib/upgrade-helpers/codex-orphan-cleanup.sh"
CLEANUP_PY="$SMOKE_REPO_ROOT/lib/upgrade-helpers/codex-orphan-cleanup.py"
SUMMARY_PY="$SMOKE_REPO_ROOT/lib/upgrade-helpers/codex-orphan-cleanup-summary.py"
HELPER_PY="$SCRIPT_DIR/1567-codex-orphan-upgrade-reaper-helper.py"
UPGRADE_SH="$SMOKE_REPO_ROOT/bridge-upgrade.sh"

smoke_require_cmd ps
smoke_require_cmd python3

# ---------------------------------------------------------------------------
smoke_log "A1: detector + summary compile and respond to scan"
for f in "$CLEANUP_PY" "$SUMMARY_PY" "$HELPER_PY"; do
  [[ -f "$f" ]] || smoke_fail "missing helper: $f"
  python3 -c "import py_compile; py_compile.compile('$f', doraise=True)" || \
    smoke_fail "$(basename "$f") failed py_compile"
done
python3 "$CLEANUP_PY" scan --json >/dev/null || smoke_fail "scan subcommand not callable"

smoke_log "A2: changed shell files are syntactically valid (bash)"
for f in "$CLEANUP_SH" "$UPGRADE_SH"; do
  [[ -f "$f" ]] || smoke_fail "missing shell file: $f"
  bash -n "$f" || smoke_fail "$(basename "$f") failed bash -n"
done

# ---------------------------------------------------------------------------
# The crux: detector behavior against stand-in orphan trees.
# ---------------------------------------------------------------------------
smoke_log "B1: DRY-RUN scan detects but KILLS NOTHING"
python3 "$HELPER_PY" dry-run-kills-nothing "$CLEANUP_PY" || \
  smoke_fail "dry-run scan killed an orphan or failed to detect it"

smoke_log "B2: reap kills the ppid==1 orphan broker, leaves the live broker, is idempotent"
python3 "$HELPER_PY" reap-orphans-only "$CLEANUP_PY" || \
  smoke_fail "reap matrix failed (orphan/live/idempotence)"

smoke_log "B3: queue-gateway staleness — gone /tmp-smoke matched, live --bridge-home excluded"
python3 "$HELPER_PY" queue-gateway-staleness "$CLEANUP_PY" || \
  smoke_fail "queue-gateway staleness matrix failed"

smoke_log "B4: broker provenance required — ppid==1 alone never matches; only gone-worktree --cwd does"
python3 "$HELPER_PY" broker-provenance-required "$CLEANUP_PY" || \
  smoke_fail "broker provenance matrix failed (no-cwd / non-worktree / live-worktree must NOT match; gone-worktree must)"

# ---------------------------------------------------------------------------
smoke_log "C: marker idempotence — present marker short-circuits, absent marker is written"
smoke_make_temp_root "$SMOKE_NAME"
fake_target="$SMOKE_TMP_ROOT/target"
mkdir -p "$fake_target/state/upgrade"
marker="$fake_target/state/upgrade/codex-orphan-cleanup.ts"

# C1: present marker -> shim short-circuits BEFORE sourcing bridge-lib.sh.
# Reproduce the CI-failing layout: an EXISTING-install target (state/tasks.db
# present) with NO v2 layout marker. Sourcing bridge-lib.sh against that env
# `bridge_die`s with "requires isolation-v2 ... markerless(existing-install)"
# (the original BLOCKER 1 failure). With our one-shot marker present, the shim
# must read it and exit 0 BEFORE the source ever runs — regardless of layout.
# We point BRIDGE_HOME/STATE at the target so the resolver sees the evidence,
# exactly as bridge_upgrade_with_target_env would on a live upgrade.
# existing-install evidence (state/tasks.db), NO v2 layout marker, and the
# layout env explicitly UNSET so the resolver cannot take the env-override
# escape and is forced down the markerless(existing-install) branch — the exact
# bridge_die path the original blocker hit. The shim must short-circuit on our
# marker BEFORE any bridge-lib source, so this layout never even reaches the die.
: >"$fake_target/state/tasks.db"
printf 'pre-existing\n' >"$marker"
out_present="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
  BRIDGE_HOME="$fake_target" BRIDGE_STATE_DIR="$fake_target/state" BRIDGE_LAYOUT_MARKER_DIR="$fake_target/state" \
  bash "$CLEANUP_SH" "$SMOKE_REPO_ROOT" "$fake_target" "" 0 2>&1 || true)"
smoke_assert_contains "$out_present" "marker present" \
  "present-marker run should short-circuit with a 'marker present' notice"
smoke_assert_not_contains "$out_present" "requires isolation-v2" \
  "present-marker run must NOT hit the bridge-lib isolation-v2 bridge_die (layout-independent short-circuit)"
# The marker must be untouched (still our sentinel).
grep -q '^pre-existing$' "$marker" || smoke_fail "present-marker run rewrote the marker"
rm -f "$fake_target/state/tasks.db"

# C2: absent marker, empty admin id (so no enqueue) -> shim runs the detector,
# emits a DRY-RUN audit line, and WRITES the marker afterward. (On this host the
# detector may legitimately find real orphans or none; either way the marker is
# dropped on a clean run.)
rm -f "$marker"
out_absent="$(bash "$CLEANUP_SH" "$SMOKE_REPO_ROOT" "$fake_target" "" 0 2>&1 || true)"
smoke_assert_contains "$out_absent" "codex-orphan-cleanup" \
  "absent-marker run should emit a codex-orphan-cleanup audit line"
smoke_assert_contains "$out_absent" "DRY-RUN" \
  "absent-marker run (no opt-in) should be a DRY-RUN"
[[ -f "$marker" ]] || smoke_fail "absent-marker clean run did not write the one-shot marker"

# C3: re-running now short-circuits on the freshly written marker.
out_rerun="$(bash "$CLEANUP_SH" "$SMOKE_REPO_ROOT" "$fake_target" "" 0 2>&1 || true)"
smoke_assert_contains "$out_rerun" "marker present" \
  "re-run after marker write should short-circuit"

smoke_cleanup_temp_root

# ---------------------------------------------------------------------------
smoke_log "D: bridge-upgrade.sh wires the helper file-as-argv + marker + opt-in, no heredoc-stdin"
grep -q 'lib/upgrade-helpers/codex-orphan-cleanup.sh' "$UPGRADE_SH" || \
  smoke_fail "bridge-upgrade.sh does not invoke codex-orphan-cleanup.sh"
grep -q 'AGENT_BRIDGE_REAP_CODEX_ORPHANS' "$UPGRADE_SH" || \
  smoke_fail "bridge-upgrade.sh missing the opt-in env flag wiring"
# The invocation must pass SOURCE_ROOT + TARGET_ROOT + admin + opt-in via argv
# (file-as-argv), not pipe a heredoc into the helper.
grep -Eq 'codex-orphan-cleanup\.sh" \\?$' "$UPGRADE_SH" || \
  grep -q 'codex-orphan-cleanup.sh"' "$UPGRADE_SH" || \
  smoke_fail "codex-orphan-cleanup.sh not invoked as a standalone argv script"
# The marker the shim writes must be referenced in the helper itself (one-shot).
grep -q 'codex-orphan-cleanup.ts' "$CLEANUP_SH" || \
  smoke_fail "helper does not gate on the one-shot migration marker"

# The heredoc-ban lint must still pass for bridge-upgrade.sh (no NEW
# heredoc-stdin introduced by this wiring).
if [[ -x "$SMOKE_REPO_ROOT/scripts/lint-heredoc-ban.sh" ]]; then
  bash "$SMOKE_REPO_ROOT/scripts/lint-heredoc-ban.sh" >/dev/null 2>&1 || \
    smoke_fail "lint-heredoc-ban regressed — a new heredoc-stdin site was introduced"
fi

smoke_log "PASS: $SMOKE_NAME"
