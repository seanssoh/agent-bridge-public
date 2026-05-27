#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-epsilon-tmux-inject-busy.sh — Issue #1312.
#
# v0.15.0-beta5-2 Lane ε — patch comprehensive audit C6 flagged a
# CRITICAL data-loss class: BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 + agent
# processing busy. The chain was:
#
#   1. daemon nudge-on-busy → bridge_dispatch_notification → bridge_tmux_
#      send_and_submit (lib/bridge-tmux.sh:1156).
#   2. bridge_tmux_session_inject_busy returns busy (line 1193).
#   3. bridge_tmux_spool_enabled returns 1 because operator set =0.
#   4. bridge_warn + return 1.
#   5. Caller (bridge_dispatch_notification at lib/bridge-notify.sh:295,
#      called by bridge-daemon.sh:4451) ignores rc=1 — the message
#      never enters the queue, never retried, permanently lost.
#
# Lane ε fix (Option A per [[feedback-root-vs-symptom-framing]]): refuse
# to honor =0 on iso v2 installs unless the operator also sets
# BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=1 (documented escape hatch).
# Non-iso installs keep legacy behavior. The dropped-message audit row
# is emitted whenever the spool is actually disabled at the busy-branch
# (FORCE escape hatch active) so the rc=1 has operator-visible evidence.
#
# Test plan:
#   T1 — Refuse: iso v2 active + BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 (no
#        FORCE) → bridge_tmux_spool_enabled returns 0 (spool treated as
#        enabled, refusing the data-loss config). One bridge_warn line
#        emitted on stderr explaining the refusal.
#   T2 — Non-iso allowed: BRIDGE_LAYOUT cleared (legacy) +
#        BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 (no FORCE) → returns 1
#        (legacy honor =0). No refusal warn.
#   T3 — FORCE escape hatch: iso v2 active + =0 + FORCE=1 →
#        bridge_tmux_spool_enabled returns 1 (honored). FORCE warn
#        emitted exactly once per process.
#   T4 — Default-on healthy: iso v2 active + spool unset (default =1) →
#        returns 0 (enabled). No warn.
#   T5 — Teeth: grep-assert the refuse branch + warn-once sentinel are
#        present in lib/bridge-tmux.sh. A future PR that removes them
#        re-opens the CRITICAL data-loss class.
#   T6 — Teeth: grep-assert bridge-init.sh emits the startup-time warning
#        when iso v2 + =0 + no FORCE.
#   T7 — Teeth: grep-assert the busy-recheck retry-once + dropped-audit
#        row are present in bridge_tmux_send_and_submit.
#
# Footgun #11 (heredoc-stdin deadlock class): this fixture uses no
# heredoc-stdin into subprocess and no `<<<` here-strings into bridge
# functions. All command substitution is on plain string locals.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (matches sibling smokes).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:beta5-2-epsilon-tmux-inject-busy] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="beta5-2-epsilon-tmux-inject-busy"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "beta5-2-epsilon-tmux-inject-busy"

REPO_ROOT="$SMOKE_REPO_ROOT"

TMUX_LIB="$REPO_ROOT/lib/bridge-tmux.sh"
INIT_SH="$REPO_ROOT/bridge-init.sh"

smoke_assert_file_exists "$TMUX_LIB" "lib/bridge-tmux.sh present"
smoke_assert_file_exists "$INIT_SH" "bridge-init.sh present"

# Source bridge-lib.sh which pulls in bridge-tmux.sh helpers.
# smoke_setup_bridge_home already exported BRIDGE_LAYOUT=v2 +
# BRIDGE_DATA_ROOT so bridge_isolation_v2_active will be true.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_tmux_spool_enabled >/dev/null; then
  smoke_fail "bridge_tmux_spool_enabled not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_isolation_v2_active >/dev/null; then
  smoke_fail "bridge_isolation_v2_active not defined after sourcing bridge-lib.sh"
fi

# Sanity: iso v2 is active in the smoke environment.
if ! bridge_isolation_v2_active 2>/dev/null; then
  smoke_fail "expected iso v2 active in smoke env (BRIDGE_LAYOUT=$BRIDGE_LAYOUT, BRIDGE_DATA_ROOT=$BRIDGE_DATA_ROOT)"
fi

# ---------------------------------------------------------------------
# T1 — Refuse: iso v2 active + =0 (no FORCE) → returns 0 (refused).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t1_refuse_on_iso_v2() {
  smoke_log "T1: iso v2 + BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 (no FORCE) → refused"
  local stderr_file="$SMOKE_TMP_ROOT/t1.stderr"
  local rc=0
  # Reset the warn-once sentinel for a deterministic stderr capture.
  unset _BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED _BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED
  BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 \
  BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=0 \
    bridge_tmux_spool_enabled "smoke-agent" 2>"$stderr_file" || rc=$?
  smoke_assert_eq "0" "$rc" "T1: iso v2 + =0 must return 0 (spool active despite =0)"
  local stderr_text
  stderr_text="$(cat "$stderr_file")"
  smoke_assert_contains "$stderr_text" "refusing BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0" \
    "T1: refuse warning emitted"
  smoke_assert_contains "$stderr_text" "iso v2" \
    "T1: warn mentions iso v2"
}

# ---------------------------------------------------------------------
# T2 — Non-iso allowed: legacy install + =0 (no FORCE) → returns 1.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t2_non_iso_legacy_allowed() {
  smoke_log "T2: non-iso + BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 → legacy honor"
  local stderr_file="$SMOKE_TMP_ROOT/t2.stderr"
  local rc=0
  unset _BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED _BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED
  # Subshell so the BRIDGE_LAYOUT swap doesn't bleed back into T3/T4.
  (
    unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
    BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 \
    BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=0 \
      bridge_tmux_spool_enabled "smoke-agent" 2>"$stderr_file"
  ) || rc=$?
  # Non-iso + =0 → return 1 (legacy disabled). bridge_tmux_spool_enabled
  # returns 1 either by the trailing `return 1` (FORCE branch) or the
  # final fallthrough; either way the contract is "not enabled" and
  # downstream callers fall back to the warn+drop path on non-iso.
  smoke_assert_eq "1" "$rc" "T2: non-iso + =0 must return 1 (legacy)"
  local stderr_text
  stderr_text="$(cat "$stderr_file")"
  smoke_assert_not_contains "$stderr_text" "refusing BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0" \
    "T2: no refuse warn on non-iso"
}

# ---------------------------------------------------------------------
# T3 — FORCE escape hatch: iso v2 + =0 + FORCE=1 → returns 1 (allowed).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t3_force_escape_hatch() {
  smoke_log "T3: iso v2 + =0 + FORCE=1 → spool disable honored"
  local stderr_file="$SMOKE_TMP_ROOT/t3.stderr"
  local rc=0
  unset _BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED _BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED
  BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 \
  BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=1 \
    bridge_tmux_spool_enabled "smoke-agent" 2>"$stderr_file" || rc=$?
  smoke_assert_eq "1" "$rc" "T3: FORCE=1 must return 1 (legacy disable honored)"
  local stderr_text
  stderr_text="$(cat "$stderr_file")"
  smoke_assert_contains "$stderr_text" "FORCE=1" \
    "T3: FORCE escape-hatch warn emitted"
  smoke_assert_contains "$stderr_text" "may be silently dropped" \
    "T3: warn names the data-loss class"

  # Warn-once: second call must NOT re-emit.
  local stderr_file2="$SMOKE_TMP_ROOT/t3-second.stderr"
  BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 \
  BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE=1 \
    bridge_tmux_spool_enabled "smoke-agent" 2>"$stderr_file2" || true
  local stderr_text2
  stderr_text2="$(cat "$stderr_file2")"
  smoke_assert_not_contains "$stderr_text2" "FORCE=1" \
    "T3 (warn-once): second call must not re-emit"
}

# ---------------------------------------------------------------------
# T4 — Default healthy: iso v2 active + spool unset (=1 default) →
# returns 0 (enabled). No warn.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t4_default_healthy() {
  smoke_log "T4: iso v2 + spool default → enabled, no warn"
  local stderr_file="$SMOKE_TMP_ROOT/t4.stderr"
  local rc=0
  unset _BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED _BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED
  unset BRIDGE_TMUX_INJECT_SPOOL_ENABLED BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE
  bridge_tmux_spool_enabled "smoke-agent" 2>"$stderr_file" || rc=$?
  smoke_assert_eq "0" "$rc" "T4: default → spool enabled (rc=0)"
  local stderr_text
  stderr_text="$(cat "$stderr_file")"
  smoke_assert_not_contains "$stderr_text" "refusing" \
    "T4: no refuse warn on default"
  smoke_assert_not_contains "$stderr_text" "FORCE=1" \
    "T4: no FORCE warn on default"
}

# ---------------------------------------------------------------------
# T5 — Teeth: lib/bridge-tmux.sh hosts the refuse branch + warn-once
# sentinel + iso v2 active gating. A future PR that drops any of these
# re-opens the CRITICAL data-loss class.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t5_teeth_refuse_branch_present() {
  smoke_log "T5: lib/bridge-tmux.sh hosts refuse branch + warn-once sentinels"
  # Refuse path
  if ! grep -q "refusing BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0" "$TMUX_LIB"; then
    smoke_fail "T5: lib/bridge-tmux.sh missing refuse warning (refuse branch removed?)"
  fi
  # iso v2 gating
  if ! grep -q "bridge_isolation_v2_active" "$TMUX_LIB"; then
    smoke_fail "T5: lib/bridge-tmux.sh missing bridge_isolation_v2_active gate"
  fi
  # Warn-once sentinels
  if ! grep -q "_BRIDGE_TMUX_SPOOL_REFUSE_WARN_EMITTED" "$TMUX_LIB"; then
    smoke_fail "T5: refuse warn-once sentinel missing"
  fi
  if ! grep -q "_BRIDGE_TMUX_SPOOL_FORCE_WARN_EMITTED" "$TMUX_LIB"; then
    smoke_fail "T5: FORCE warn-once sentinel missing"
  fi
  # Escape-hatch env var name
  if ! grep -q "BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE" "$TMUX_LIB"; then
    smoke_fail "T5: BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE escape hatch missing"
  fi
}

# ---------------------------------------------------------------------
# T6 — Teeth: bridge-init.sh emits the startup-time refuse advisory.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t6_teeth_init_startup_warning() {
  smoke_log "T6: bridge-init.sh emits startup-time refuse advisory"
  if ! grep -q "BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0 detected on iso v2" "$INIT_SH"; then
    smoke_fail "T6: bridge-init.sh missing startup-time refuse advisory"
  fi
  if ! grep -q "BRIDGE_TMUX_INJECT_SPOOL_DISABLE_FORCE" "$INIT_SH"; then
    smoke_fail "T6: bridge-init.sh missing FORCE escape-hatch reference"
  fi
}

# ---------------------------------------------------------------------
# T7 — Teeth: bridge_tmux_send_and_submit hosts the busy-recheck retry
# + dropped-audit row. A future PR that drops either re-enables silent
# message loss when FORCE=1 (the only remaining drop path).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t7_teeth_send_and_submit_retries_and_audits() {
  smoke_log "T7: bridge_tmux_send_and_submit hosts busy-recheck + dropped-audit"
  # Recheck delay env var
  if ! grep -q "BRIDGE_TMUX_INJECT_BUSY_RECHECK_SECONDS" "$TMUX_LIB"; then
    smoke_fail "T7: BRIDGE_TMUX_INJECT_BUSY_RECHECK_SECONDS recheck delay env missing"
  fi
  # Dropped-audit row
  if ! grep -q "tmux_inject_dropped_spool_disabled" "$TMUX_LIB"; then
    smoke_fail "T7: tmux_inject_dropped_spool_disabled audit row missing"
  fi
  # The drop warn references KNOWN_ISSUES.md anchor for operator search.
  if ! grep -q "KNOWN_ISSUES.md" "$TMUX_LIB"; then
    smoke_fail "T7: drop warn missing KNOWN_ISSUES.md pointer"
  fi
}

smoke_run "T1: refuse on iso v2 (no FORCE)" test_t1_refuse_on_iso_v2
smoke_run "T2: non-iso legacy allowed" test_t2_non_iso_legacy_allowed
smoke_run "T3: FORCE escape hatch honored + warn-once" test_t3_force_escape_hatch
smoke_run "T4: default healthy (no warn)" test_t4_default_healthy
smoke_run "T5: teeth — refuse branch + sentinels in bridge-tmux.sh" test_t5_teeth_refuse_branch_present
smoke_run "T6: teeth — startup-time refuse advisory in bridge-init.sh" test_t6_teeth_init_startup_warning
smoke_run "T7: teeth — busy-recheck + dropped-audit in send_and_submit" test_t7_teeth_send_and_submit_retries_and_audits

smoke_log "all T1-T7 pass"
exit 0
