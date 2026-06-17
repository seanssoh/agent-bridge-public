#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1955-daemon-rogue-warn.sh — Issue #1955.
#
# A live fleet daemon was found running detached (PPID=1) from an operator's
# dev checkout (an unreleased branch) with NO launchd job loaded — no
# KeepAlive auto-recovery. Root: `bash bridge-daemon.sh start/run` from the
# dev cwd daemonizes against the live ~/.agent-bridge with dev code, bypassing
# the init system. bridge_daemon_self_diagnose emits a one-line WARN at daemon
# start when the daemon is either (a) unsupervised (orphaned PPID=1 with no
# launchd/systemd marker) or (b) running from a non-canonical source root (not
# $BRIDGE_HOME and not the recorded source root). Detection/warn ONLY — it
# never auto-kills and never changes daemon behavior.
#
# Strategy: extract `daemon_warn` + `bridge_daemon_self_diagnose` from
# bridge-daemon.sh via awk and run the helper standalone, driving each branch
# by setting SCRIPT_DIR / BRIDGE_HOME / the supervisor env markers and the
# BRIDGE_DAEMON_DIAG_PPID test seam (PPID is read-only in bash). Host-agnostic:
# no real daemon is forked, no init system is touched, the live ~/.agent-bridge
# is never read (isolated BRIDGE_HOME via smoke_setup_bridge_home).
#
# Tests:
#   S1: non-canonical source root (dev checkout != BRIDGE_HOME, no recorded) → WARN.
#   S2: canonical == BRIDGE_HOME → no non-canonical WARN.
#   S3: canonical via AGENT_BRIDGE_SOURCE_DIR (recorded source root) → no WARN.
#   S4: canonical via state/upgrade/last-upgrade.json:source_root → no WARN.
#   S5: unsupervised (DIAG_PPID=1, no marker) → WARN.
#   S6: supervised systemd (INVOCATION_ID set) → no unsupervised WARN.
#   S7: supervised launchd (XPC_SERVICE_NAME contains agent-bridge) → no WARN.
#   S8: attached (DIAG_PPID != 1) → no unsupervised WARN.
#   S9: never-fail — a detection error path still returns 0 (helper guarded).
#   M1: mutation — force always-warn → the no-warn S2 case fails (non-vacuous).
#   M2: mutation — force never-warn → the warn S1 case fails (non-vacuous).
#
# Footgun #11: every helper/runner assembled with `printf '%s\n' >file`; no
# `<<<` here-string or `<<EOF` feeds into a subprocess capture.

set -uo pipefail

SMOKE_NAME="1955-daemon-rogue-warn"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
[[ -f "$DAEMON_SH" ]] || smoke_fail "bridge-daemon.sh missing at $DAEMON_SH"

# A stand-in "dev checkout" source root distinct from $BRIDGE_HOME. It carries
# a copy of the recorded-source-root helper so the S4 last-upgrade.json branch
# (which runs `python3 $SCRIPT_DIR/lib/upgrade-helpers/recorded-source-root.py`)
# resolves the helper relative to the dev SCRIPT_DIR.
DEV_CHECKOUT="$SMOKE_TMP_ROOT/dev-checkout"
mkdir -p "$DEV_CHECKOUT/lib/upgrade-helpers"
cp "$REPO_ROOT/lib/upgrade-helpers/recorded-source-root.py" \
   "$DEV_CHECKOUT/lib/upgrade-helpers/recorded-source-root.py"

# Extract daemon_warn + bridge_daemon_self_diagnose into a standalone runner
# that calls the helper and then `echo OK` (so we can assert non-fatal return).
# A $1 of "always" / "never" injects the mutation variants.
extract_runner() {
  local mode="${1:-real}"
  local out="$SMOKE_TMP_ROOT/runner-${mode}.sh"
  : >"$out"
  # shellcheck disable=SC2129  # per-line emit mirrors footgun #11 avoidance shape
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    awk '/^daemon_warn\(\) \{/,/^\}/' "$DAEMON_SH"
    printf '%s\n' ''
    awk '/^bridge_daemon_self_diagnose\(\) \{/,/^\}/' "$DAEMON_SH"
    printf '%s\n' ''
    case "$mode" in
      always)
        # Mutation: replace the helper with one that always warns on both axes.
        printf '%s\n' 'bridge_daemon_self_diagnose() {'
        printf '%s\n' '  daemon_warn "[self-diagnose] daemon running from a NON-CANONICAL source root: forced-always"'
        printf '%s\n' '  daemon_warn "[self-diagnose] daemon is UNSUPERVISED: forced-always"'
        printf '%s\n' '  return 0'
        printf '%s\n' '}'
        ;;
      never)
        # Mutation: replace the helper with a no-op (never warns).
        printf '%s\n' 'bridge_daemon_self_diagnose() { return 0; }'
        ;;
    esac
    printf '%s\n' 'bridge_daemon_self_diagnose || echo "[runner] helper returned non-zero rc=$?"'
    printf '%s\n' 'echo "RUNNER_OK"'
  } >>"$out"
  printf '%s\n' "$out"
}

RUNNER="$(extract_runner real)"
RUNNER_ALWAYS="$(extract_runner always)"
RUNNER_NEVER="$(extract_runner never)"

# run_diag <runner> — invoke a runner with the current SCRIPT_DIR/BRIDGE_HOME/
# env markers (set by each scenario in the parent shell). Captures stderr
# (where daemon_warn writes) + stdout into one stream. Sets DIAG_OUT / DIAG_RC.
#
# The runner is SOURCED in a subshell rather than exec'd via `bash` because
# macOS launchd re-stamps XPC_SERVICE_NAME=0 across a process exec, which would
# silently drop the launchd-marker env the S7 supervised case sets. A subshell
# inherits the parent env without the OS re-stamp, so the same harness exercises
# both the systemd and launchd supervised branches portably.
run_diag() {
  local runner="$1"
  # shellcheck disable=SC1090  # $runner is a generated, temp-only extract path
  DIAG_OUT="$( ( source "$runner" ) 2>&1 )"
  DIAG_RC=$?
}

# Common env for the non-canonical (source-root) tests: a supervisor marker is
# present so the unsupervised axis stays quiet and we isolate the source-root
# axis. DIAG_PPID is forced non-1 so the unsupervised branch cannot fire.
src_axis_env() {
  export SCRIPT_DIR="$DEV_CHECKOUT"
  export INVOCATION_ID="smoke-supervised"      # mark supervised
  export BRIDGE_DAEMON_DIAG_PPID="4242"        # attached (not orphaned)
  unset AGENT_BRIDGE_SOURCE_DIR XPC_SERVICE_NAME NOTIFY_SOCKET \
        BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE 2>/dev/null || true
  rm -rf "$BRIDGE_STATE_DIR/upgrade" 2>/dev/null || true
}

# Common env for the supervision tests: SCRIPT_DIR == BRIDGE_HOME so the
# source-root axis stays quiet and we isolate the supervision axis.
sup_axis_env() {
  export SCRIPT_DIR="$BRIDGE_HOME"
  export BRIDGE_DAEMON_DIAG_PPID="1"           # orphaned
  unset AGENT_BRIDGE_SOURCE_DIR INVOCATION_ID NOTIFY_SOCKET \
        BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE XPC_SERVICE_NAME 2>/dev/null || true
  rm -rf "$BRIDGE_STATE_DIR/upgrade" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# S1: non-canonical source root → WARN.
# ---------------------------------------------------------------------------
src_axis_env
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S1: helper must return 0 (warn-only), got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" == *"RUNNER_OK"* ]] || smoke_fail "S1: runner did not complete: $DIAG_OUT"
[[ "$DIAG_OUT" == *"NON-CANONICAL source root"* ]] \
  || smoke_fail "S1: expected NON-CANONICAL source-root WARN, got: $DIAG_OUT"
[[ "$DIAG_OUT" == *"$DEV_CHECKOUT"* ]] \
  || smoke_fail "S1: WARN must name the offending source root path, got: $DIAG_OUT"
[[ "$DIAG_OUT" != *"UNSUPERVISED"* ]] \
  || smoke_fail "S1: unsupervised axis must stay quiet (marker present, attached): $DIAG_OUT"
smoke_log "S1 PASS: non-canonical source root → WARN naming the dev-checkout path"

# ---------------------------------------------------------------------------
# S2: canonical == BRIDGE_HOME → no non-canonical WARN.
# ---------------------------------------------------------------------------
src_axis_env
export SCRIPT_DIR="$BRIDGE_HOME"
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S2: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" != *"NON-CANONICAL"* ]] \
  || smoke_fail "S2: SCRIPT_DIR == BRIDGE_HOME must NOT warn non-canonical, got: $DIAG_OUT"
smoke_log "S2 PASS: SCRIPT_DIR == \$BRIDGE_HOME → no non-canonical WARN"

# ---------------------------------------------------------------------------
# S3: canonical via AGENT_BRIDGE_SOURCE_DIR → no WARN.
# ---------------------------------------------------------------------------
src_axis_env
export AGENT_BRIDGE_SOURCE_DIR="$DEV_CHECKOUT"   # recorded source == dev checkout
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S3: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" != *"NON-CANONICAL"* ]] \
  || smoke_fail "S3: AGENT_BRIDGE_SOURCE_DIR matching SCRIPT_DIR must NOT warn, got: $DIAG_OUT"
smoke_log "S3 PASS: SCRIPT_DIR == recorded AGENT_BRIDGE_SOURCE_DIR → no WARN"

# ---------------------------------------------------------------------------
# S4: canonical via state/upgrade/last-upgrade.json:source_root → no WARN.
# ---------------------------------------------------------------------------
src_axis_env
mkdir -p "$BRIDGE_STATE_DIR/upgrade"
: >"$BRIDGE_STATE_DIR/upgrade/last-upgrade.json"
{
  printf '%s\n' '{'
  printf '  "source_root": "%s"\n' "$DEV_CHECKOUT"
  printf '%s\n' '}'
} >>"$BRIDGE_STATE_DIR/upgrade/last-upgrade.json"
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S4: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" != *"NON-CANONICAL"* ]] \
  || smoke_fail "S4: last-upgrade.json source_root matching SCRIPT_DIR must NOT warn, got: $DIAG_OUT"
smoke_log "S4 PASS: SCRIPT_DIR == recorded last-upgrade.json source_root → no WARN"

# ---------------------------------------------------------------------------
# S5: unsupervised (orphaned, no marker) → WARN.
# ---------------------------------------------------------------------------
sup_axis_env
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S5: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" == *"UNSUPERVISED"* ]] \
  || smoke_fail "S5: expected UNSUPERVISED WARN, got: $DIAG_OUT"
[[ "$DIAG_OUT" == *"PPID=1"* ]] \
  || smoke_fail "S5: WARN must name the offending PPID, got: $DIAG_OUT"
[[ "$DIAG_OUT" != *"NON-CANONICAL"* ]] \
  || smoke_fail "S5: source-root axis must stay quiet (SCRIPT_DIR == BRIDGE_HOME): $DIAG_OUT"
smoke_log "S5 PASS: orphaned daemon with no init marker → UNSUPERVISED WARN naming PPID"

# ---------------------------------------------------------------------------
# S6: supervised systemd (INVOCATION_ID set) → no unsupervised WARN.
# ---------------------------------------------------------------------------
sup_axis_env
export INVOCATION_ID="smoke-systemd-unit"
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S6: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" != *"UNSUPERVISED"* ]] \
  || smoke_fail "S6: INVOCATION_ID present (systemd) must NOT warn unsupervised, got: $DIAG_OUT"
smoke_log "S6 PASS: systemd INVOCATION_ID present → no unsupervised WARN"

# ---------------------------------------------------------------------------
# S7: supervised launchd (XPC_SERVICE_NAME contains agent-bridge) → no WARN.
# ---------------------------------------------------------------------------
sup_axis_env
export XPC_SERVICE_NAME="ai.agent-bridge.daemon"
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S7: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" != *"UNSUPERVISED"* ]] \
  || smoke_fail "S7: launchd XPC_SERVICE_NAME present must NOT warn unsupervised, got: $DIAG_OUT"
smoke_log "S7 PASS: launchd XPC_SERVICE_NAME (job label) present → no unsupervised WARN"

# ---------------------------------------------------------------------------
# S8: attached (DIAG_PPID != 1) → no unsupervised WARN.
# ---------------------------------------------------------------------------
sup_axis_env
export BRIDGE_DAEMON_DIAG_PPID="7777"
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S8: helper must return 0, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" != *"UNSUPERVISED"* ]] \
  || smoke_fail "S8: a non-orphaned daemon (PPID != 1) must NOT warn unsupervised, got: $DIAG_OUT"
smoke_log "S8 PASS: attached daemon (PPID != 1) → no unsupervised WARN"

# ---------------------------------------------------------------------------
# S9: never-fail — with a deliberately bogus BRIDGE_STATE_DIR (unreadable json
# path) the helper still returns 0 and the runner completes.
# ---------------------------------------------------------------------------
src_axis_env
export BRIDGE_STATE_DIR="/nonexistent/smoke-1955/state"
run_diag "$RUNNER"
[[ "$DIAG_RC" -eq 0 ]] || smoke_fail "S9: helper must still return 0 with a bogus state dir, got rc=$DIAG_RC: $DIAG_OUT"
[[ "$DIAG_OUT" == *"RUNNER_OK"* ]] \
  || smoke_fail "S9: runner must complete even on a detection-degraded path: $DIAG_OUT"
# restore a real state dir for any later code
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
smoke_log "S9 PASS: detection-degraded path (bogus state dir) → helper returns 0, never fails the start"

# ---------------------------------------------------------------------------
# M1: mutation — force-always-warn → the no-warn S2 case MUST now fail.
# ---------------------------------------------------------------------------
src_axis_env
export SCRIPT_DIR="$BRIDGE_HOME"   # canonical: real helper emits NO warn here
run_diag "$RUNNER_ALWAYS"
[[ "$DIAG_OUT" == *"NON-CANONICAL"* ]] \
  || smoke_fail "M1: force-always-warn runner must emit a NON-CANONICAL warn even on the canonical S2 input — the S2 assertion would be vacuous otherwise. Got: $DIAG_OUT"
smoke_log "M1 PASS (mutation): force-always-warn breaks the S2 no-warn case (S2 is non-vacuous)"

# ---------------------------------------------------------------------------
# M2: mutation — force-never-warn → the warn S1 case MUST now fail.
# ---------------------------------------------------------------------------
src_axis_env   # dev checkout: real helper WOULD warn non-canonical
run_diag "$RUNNER_NEVER"
[[ "$DIAG_OUT" != *"NON-CANONICAL"* ]] \
  || smoke_fail "M2: force-never-warn runner must NOT emit a warn — got one unexpectedly: $DIAG_OUT"
[[ "$DIAG_OUT" == *"RUNNER_OK"* ]] \
  || smoke_fail "M2: force-never-warn runner must still complete: $DIAG_OUT"
smoke_log "M2 PASS (mutation): force-never-warn suppresses the S1 warn (the WARN-firing assertions are real)"

smoke_log "OK"
