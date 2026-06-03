#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/8807-resource-guard-defer.sh — incident #8807 P0a fail-safe.
#
# Background: a long-lived runtime accumulated thousands of orphaned
# codex/mcp-server/node/bash processes; memory exhaustion made fork() itself
# fail and the daemon kept dispatching/spawning right up to the wall → forced
# reboot. P0a adds a pre-flight resource-guard that the daemon consults BEFORE
# every disposable-child fork so a pressured host DEFERS the spawn (leaving
# work queued) instead of pushing the host over fork().
#
# This smoke is static-by-design for the daemon wiring (grep pins, no live
# tmux) PLUS behavioral for the guard primitive itself — it sources
# lib/bridge-resource-guard.sh in an isolated BRIDGE_HOME and proves:
#   - a forced low threshold (BRIDGE_RESOURCE_PROC_PCT_LIMIT=0) DEFERS + audits
#     + does NOT run the protected action;
#   - a probe glitch (unknown platform) FAILS OPEN → PROCEED;
#   - the guard-disabled knob proceeds;
#   - the deferral warn is throttled to one per window across sites.

set -euo pipefail

SMOKE_NAME="8807-resource-guard-defer"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"
GUARD_LIB="$SMOKE_REPO_ROOT/lib/bridge-resource-guard.sh"
LIB_SH="$SMOKE_REPO_ROOT/bridge-lib.sh"

TMP_ROOT=""
cleanup() { [[ -z "$TMP_ROOT" ]] || rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agb-8807-XXXXXX")"

# ---------------------------------------------------------------------------
# Part A — syntax + source-order
# ---------------------------------------------------------------------------
smoke_log "A1: resource-guard lib is syntactically valid"
bash -n "$GUARD_LIB" || smoke_fail "lib/bridge-resource-guard.sh failed bash -n"

smoke_log "A2: bridge-daemon.sh is syntactically valid"
bash -n "$DAEMON_SH" || smoke_fail "bridge-daemon.sh failed bash -n"

smoke_log "A3: bridge-lib.sh sources the guard AFTER bridge-cron.sh (mem-pressure reuse)"
cron_line="$(grep -n 'bridge_source_module "bridge-cron.sh"' "$LIB_SH" | head -n1 | cut -d: -f1)"
guard_line="$(grep -n 'bridge_source_module "bridge-resource-guard.sh"' "$LIB_SH" | head -n1 | cut -d: -f1)"
[[ -n "$cron_line" && -n "$guard_line" ]] || smoke_fail "could not locate cron/guard source lines in bridge-lib.sh"
(( guard_line > cron_line )) || smoke_fail "resource-guard sourced before bridge-cron.sh (mem-pressure reuse would break)"

# ---------------------------------------------------------------------------
# Part B — behavioral: source the guard primitive in isolation
# ---------------------------------------------------------------------------
smoke_log "B0: guard exposes the daemon-facing wrapper + the should-defer primitive"
grep -q '^bridge_resource_guard_defer_or_proceed()' "$GUARD_LIB" || \
  smoke_fail "missing bridge_resource_guard_defer_or_proceed wrapper"
grep -q '^bridge_resource_guard_should_defer()' "$GUARD_LIB" || \
  smoke_fail "missing bridge_resource_guard_should_defer primitive"

# Harness: run a bash snippet that sources the guard with stub bridge_audit_log /
# bridge_warn so we can observe the side effects without the full lib stack.
# We isolate BRIDGE_STATE_DIR into TMP_ROOT so the throttle file never touches
# live runtime.
run_guard_probe() {
  # First args (until the literal `--`) are VAR=value env assignments passed
  # one-per-arg to `env` so values containing spaces (e.g. PATH) are safe;
  # the final arg is the bash body to run after sourcing the guard.
  local -a envv=()
  while [[ $# -gt 1 && "$1" != "--" ]]; do
    envv+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] && shift
  local body="$1"
  env BRIDGE_STATE_DIR="$TMP_ROOT/state" BRIDGE_HOME="$TMP_ROOT" "${envv[@]}" \
    bash -c '
      set -euo pipefail
      AUDIT_LOG="'"$TMP_ROOT"'/audit.calls"
      WARN_LOG="'"$TMP_ROOT"'/warn.calls"
      bridge_audit_log() { printf "%s\n" "$*" >>"$AUDIT_LOG"; }
      bridge_warn() { printf "%s\n" "$*" >>"$WARN_LOG"; }
      # shellcheck source=/dev/null
      source "'"$GUARD_LIB"'"
      '"$body"'
    '
}

smoke_log "B1: forced low proc-pct threshold DEFERS, audits, and skips the protected action"
rm -f "$TMP_ROOT/audit.calls" "$TMP_ROOT/warn.calls" "$TMP_ROOT/ran.marker"
defer_rc=0
run_guard_probe "BRIDGE_RESOURCE_PROC_PCT_LIMIT=0" -- '
  if bridge_resource_guard_defer_or_proceed "smoke-ctx"; then
    # DEFER branch — must NOT run the protected action.
    exit 0
  else
    # PROCEED branch — would have spawned.
    printf ran >"'"$TMP_ROOT"'/ran.marker"
    exit 0
  fi
' || defer_rc=$?
[[ "$defer_rc" -eq 0 ]] || smoke_fail "guard probe (defer) exited non-zero"
[[ ! -f "$TMP_ROOT/ran.marker" ]] || smoke_fail "guard DEFERRED but protected action still ran"
smoke_assert_file_exists "$TMP_ROOT/audit.calls" "B1 audit row"
grep -q "resource_guard_deferred" "$TMP_ROOT/audit.calls" || \
  smoke_fail "deferral did not emit a resource_guard_deferred audit row"

smoke_log "B2: probe glitch (unknown platform) FAILS OPEN → PROCEED (action runs)"
# Force an unknown platform by shadowing `uname` on PATH so the proc/mem probes
# both bail (return 1 = not pressured) → should_defer returns PROCEED.
mkdir -p "$TMP_ROOT/fakebin"
cat >"$TMP_ROOT/fakebin/uname" <<'FAKE'
#!/usr/bin/env bash
printf 'PlatypusOS\n'
FAKE
chmod +x "$TMP_ROOT/fakebin/uname"
rm -f "$TMP_ROOT/ran.marker"
proceed_rc=0
run_guard_probe "BRIDGE_RESOURCE_PROC_PCT_LIMIT=0" "PATH=$TMP_ROOT/fakebin:$PATH" -- '
  if bridge_resource_guard_defer_or_proceed "smoke-glitch"; then
    exit 0
  else
    printf ran >"'"$TMP_ROOT"'/ran.marker"
    exit 0
  fi
' || proceed_rc=$?
[[ "$proceed_rc" -eq 0 ]] || smoke_fail "guard probe (fail-open) exited non-zero"
[[ -f "$TMP_ROOT/ran.marker" ]] || \
  smoke_fail "probe glitch did NOT fail open — guard wedged the spawn (fork-storm risk inverted)"

smoke_log "B3: BRIDGE_RESOURCE_GUARD_ENABLED=0 always proceeds"
rm -f "$TMP_ROOT/ran.marker"
run_guard_probe "BRIDGE_RESOURCE_GUARD_ENABLED=0" "BRIDGE_RESOURCE_PROC_PCT_LIMIT=0" -- '
  if bridge_resource_guard_defer_or_proceed "smoke-disabled"; then
    exit 0
  else
    printf ran >"'"$TMP_ROOT"'/ran.marker"
    exit 0
  fi
'
[[ -f "$TMP_ROOT/ran.marker" ]] || smoke_fail "disabled guard still deferred"

smoke_log "B4: deferral warn is throttled to one emission per window"
rm -f "$TMP_ROOT/audit.calls" "$TMP_ROOT/warn.calls"
rm -rf "$TMP_ROOT/state"
run_guard_probe "BRIDGE_RESOURCE_PROC_PCT_LIMIT=0" "BRIDGE_RESOURCE_GUARD_WARN_THROTTLE_SECONDS=3600" -- '
  for _i in 1 2 3 4 5; do
    bridge_resource_guard_defer_or_proceed "smoke-throttle-$_i" || true
  done
  exit 0
'
audit_n="$(grep -c "resource_guard_deferred" "$TMP_ROOT/audit.calls" 2>/dev/null || printf 0)"
warn_n=0
[[ -f "$TMP_ROOT/warn.calls" ]] && warn_n="$(grep -c . "$TMP_ROOT/warn.calls" 2>/dev/null || printf 0)"
# Audit is per-deferral (forensic, file-only) → 5 rows. Warn throttled → exactly 1.
[[ "$audit_n" -eq 5 ]] || smoke_fail "expected 5 audit rows (one per deferral), got $audit_n"
[[ "$warn_n" -eq 1 ]] || smoke_fail "expected exactly 1 throttled warn, got $warn_n (channel/log spam risk)"

# ---------------------------------------------------------------------------
# Part C — daemon wiring pins: every spawn site must consult the guard
# ---------------------------------------------------------------------------
smoke_log "C1: start_cron_worker guards before the worker fork"
grep -q 'bridge_resource_guard_defer_or_proceed "cron-worker:' "$DAEMON_SH" || \
  smoke_fail "start_cron_worker does not consult the resource guard"

smoke_log "C2: cron-dispatch guards BEFORE the claim (leaves row queued)"
grep -q 'bridge_resource_guard_defer_or_proceed "cron-dispatch:' "$DAEMON_SH" || \
  smoke_fail "start_cron_dispatch_workers does not guard before the claim"

smoke_log "C3: cron-dispatch wake guards before bridge-start.sh spawn"
grep -q 'bridge_resource_guard_defer_or_proceed "cron-dispatch-wake:' "$DAEMON_SH" || \
  smoke_fail "bridge_daemon_cron_dispatch_wake does not guard the wake spawn"

smoke_log "C4: run-cron-worker guards before the run-subagent fork (and re-queues)"
grep -q 'bridge_resource_guard_defer_or_proceed "run-cron-worker:' "$DAEMON_SH" || \
  smoke_fail "cmd_run_cron_worker does not guard the run-subagent fork"
grep -q 'cron worker deferred: host near resource ceiling' "$DAEMON_SH" || \
  smoke_fail "cmd_run_cron_worker deferral does not hand the row back to the queue"

smoke_log "C5: supp-refresh worker guards before the detached fork"
grep -q 'bridge_resource_guard_defer_or_proceed "supp-refresh:' "$DAEMON_SH" || \
  smoke_fail "supp-refresh dispatch does not guard the detached fork"

smoke_log "C6: always-on AND queued-on-demand auto-start both guard the spawn"
grep -q 'bridge_resource_guard_defer_or_proceed "always-on:' "$DAEMON_SH" || \
  smoke_fail "always-on auto-start does not guard the spawn"
grep -q 'bridge_resource_guard_defer_or_proceed "on-demand:' "$DAEMON_SH" || \
  smoke_fail "queued-on-demand auto-start does not guard the spawn"

smoke_log "C7: at least 6 guard call sites wired in the daemon"
sites="$(grep -c 'bridge_resource_guard_defer_or_proceed ' "$DAEMON_SH")"
[[ "$sites" -ge 6 ]] || smoke_fail "expected >=6 daemon guard sites, found $sites"

smoke_log "PASS: $SMOKE_NAME"
