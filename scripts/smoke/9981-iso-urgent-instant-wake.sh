#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/9981-iso-urgent-instant-wake.sh — Issue #9981.
#
# Live-observed by patch@cm-prod (2026-06-05): a controller running
# `agent-bridge urgent <iso-agent> "..."` against an iso v2-active always-on
# agent hit
#   mkdir: cannot create directory '<BRIDGE_HOME>/data/agents/<a>': Permission denied
#   [경고] pending-attention lock contention for '<a>'; giving up after 200 attempts
#   [..] !URGENT <a>: task #NNNN queued
# i.e. the durable urgent task is created (queue OK), but the instant-wake
# (pending-attention) marker write into the iso agent's data/agents/<a>/ dir
# FAILS because the controller is NOT the owner of that leaf and its live
# supplementary-group set may not include ab-agent-<a> → 200 retries →
# gives up → the urgent degrades to ~1-2min POLL latency.
#
# Root cause (identical class to #1378, which fixed the sibling
# session.lock): the pending-attention spool/lock resolved their dir via
# bridge_agent_runtime_state_dir, which for iso-v2 agents returns
# data/agents/<a>/runtime/ (owner=agent-bridge-<a>, group=ab-agent-<a>,
# under the 2750 root:ab-agent-<a> per-agent root). Every spool consumer is
# CONTROLLER-side (bridge-send.sh urgent, bridge_dispatch_notification
# booting branch, bridge-daemon.sh flush) — the iso UID never reads/writes
# this spool — so anchoring it in the iso data tree is wrong.
#
# Fix: bridge_agent_pending_attention_state_dir anchors the spool + lock on
# the CONTROLLER-OWNED state leaf (bridge_agent_idle_marker_dir →
# state/agents/<a>/, owner=controller mode 2770), exactly as #1378 did for
# session.lock. The controller is the OWNER of that leaf, so it can always
# create + write the spool regardless of its live group set; the iso
# boundary is untouched (nothing new granted into the iso home; the iso UID
# loses nothing). For non-iso/shared/non-Linux installs this is a no-op:
# bridge_agent_runtime_state_dir already returns bridge_agent_idle_marker_dir
# there.
#
# A second fail-soft hardening in bridge_tmux_pending_attention_with_lock:
# an EACCES on the spool dir used to masquerade as lock contention and burn
# all 200 retries with a misleading warning. It now fast-fails with ONE
# clear warning so the urgent keeps its durable-queue delivery without
# spamming the log — never blocking the send.
#
# Test plan (PATH RESOLUTION + permission LOGIC + a real append end-to-end,
# made deterministic without sudo/groups — the real Linux-host acceptance is
# patch's fresh-install re-verify; the macOS smoke proves the resolution +
# the denial-vs-success delta + the fail-soft fast-fail):
#   T1 iso resolution: with iso-v2 active, the spool file + lock dir anchor
#      on the controller-owned state leaf (state/agents/<a>/), NOT the iso
#      data tree (data/agents/<a>/runtime/).
#   T2 shared regression: with iso-v2 NOT active, both paths are
#      byte-identical to the legacy runtime_state_dir resolution.
#   T3 real append e2e: with iso-v2 active and a real (controller-writable)
#      state leaf, bridge_tmux_pending_attention_append SUCCEEDS, the marker
#      lands at the state-leaf spool file, and the lock does NOT spin (single
#      attempt). This is the instant-wake-lands assertion.
#   T4 fail-soft (privileged path unavailable): point the spool at a
#      controller-UNwritable dir (chmod 0500 stand-in for the iso-owned
#      leaf) and assert the append FAST-FAILS (rc 75) with NO 200-retry
#      spam — wall-clock proves it (a 200×0.05s spin would take ~10s; we
#      cap at well under that). Durable-queue delivery is the caller's
#      concern and is unaffected (the append rc is advisory only).
#   T5 grep teeth: pin both pending-attention resolvers to
#      bridge_agent_pending_attention_state_dir / bridge_agent_idle_marker_dir
#      and assert they do NOT reference bridge_agent_runtime_state_dir, so a
#      future refactor reverting the anchor to the iso data tree fails loud.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no command
# substitution feeding a heredoc stdin into bridge functions and no `<<<`
# here-strings into them; the append/lock probes call the real functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash 3.2.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:9981-iso-urgent-instant-wake] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="9981-iso-urgent-instant-wake"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "9981-iso-urgent-instant-wake"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

# Sanity checks.
for _fn in \
  bridge_agent_pending_attention_state_dir \
  bridge_agent_pending_attention_file \
  bridge_agent_pending_attention_lock_dir \
  bridge_agent_idle_marker_dir \
  bridge_agent_runtime_state_dir \
  bridge_isolation_v2_active \
  bridge_tmux_pending_attention_append \
  bridge_tmux_pending_attention_count; do
  if ! declare -F "$_fn" >/dev/null; then
    smoke_fail "$_fn not defined after sourcing bridge-lib.sh (sanity check)"
  fi
done

STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
AGENT="isobot"

# ---------------------------------------------------------------------
# T1 — iso path resolution: spool file + lock dir anchor on the
# controller-owned state leaf, NOT the iso data tree.
# ---------------------------------------------------------------------
test_iso_spool_resolves_to_controller_state_leaf() {
  smoke_log "T1: iso-v2 spool/lock paths resolve to controller-owned state leaf"

  if ! bridge_isolation_v2_active; then
    smoke_fail "T1: precondition failed — iso-v2 not active in harness (BRIDGE_LAYOUT='${BRIDGE_LAYOUT:-}' BRIDGE_DATA_ROOT='${BRIDGE_DATA_ROOT:-}')"
  fi

  local spool_file lock_dir state_leaf data_tree
  spool_file="$(bridge_agent_pending_attention_file "$AGENT")"
  lock_dir="$(bridge_agent_pending_attention_lock_dir "$AGENT")"
  state_leaf="$(bridge_agent_idle_marker_dir "$AGENT")"
  data_tree="$(bridge_agent_runtime_state_dir "$AGENT")"

  smoke_log "T1: spool_file=$spool_file"
  smoke_log "T1: lock_dir=$lock_dir"
  smoke_log "T1: state_leaf=$state_leaf  data_tree=$data_tree"

  if [[ "$state_leaf" == "$data_tree" ]]; then
    smoke_fail "T1: harness invariant broken — state leaf == data tree under iso-v2 ($state_leaf); cannot distinguish the fix"
  fi

  local expect_spool="$state_leaf/pending-attention.env"  # noqa: iso-helper-boundary (smoke fixture path assertion — string-equality on a resolved path, not a controller->iso boundary write)
  local expect_lock="$state_leaf/pending-attention.lock"
  smoke_assert_eq "$expect_spool" "$spool_file" \
    "T1: spool file must anchor on controller-owned state leaf"
  smoke_assert_eq "$expect_lock" "$lock_dir" \
    "T1: lock dir must anchor on controller-owned state leaf"
  smoke_assert_contains "$spool_file" "$BRIDGE_ACTIVE_AGENT_DIR/" \
    "T1: spool file under BRIDGE_ACTIVE_AGENT_DIR (state/agents)"
  smoke_assert_not_contains "$spool_file" "$data_tree" \
    "T1: spool file MUST NOT live in the iso data tree (data/agents/<a>/runtime)"
  smoke_assert_not_contains "$lock_dir" "/runtime/" \
    "T1: lock dir MUST NOT be under the iso runtime subtree"
}

# ---------------------------------------------------------------------
# T2 — regression: shared/non-iso paths byte-identical to legacy
# runtime_state_dir resolution (zero behaviour change off the iso path).
# ---------------------------------------------------------------------
test_shared_spool_path_byte_identical() {
  smoke_log "T2: shared/non-iso spool/lock paths byte-identical to legacy resolution"

  (
    BRIDGE_LAYOUT="v1"
    if bridge_isolation_v2_active; then
      smoke_fail "T2: precondition failed — iso-v2 still active after BRIDGE_LAYOUT=v1"
    fi
    local spool_file lock_dir runtime_dir idle_dir
    spool_file="$(bridge_agent_pending_attention_file "$AGENT")"
    lock_dir="$(bridge_agent_pending_attention_lock_dir "$AGENT")"
    runtime_dir="$(bridge_agent_runtime_state_dir "$AGENT")"
    idle_dir="$(bridge_agent_idle_marker_dir "$AGENT")"

    smoke_log "T2: spool_file=$spool_file  lock_dir=$lock_dir"
    smoke_log "T2: runtime_dir=$runtime_dir  idle_dir=$idle_dir"

    local legacy_spool="$runtime_dir/pending-attention.env"  # noqa: iso-helper-boundary (smoke fixture path assertion — legacy-path string-equality, not a controller->iso boundary write)
    local legacy_lock="$runtime_dir/pending-attention.lock"
    smoke_assert_eq "$runtime_dir" "$idle_dir" \
      "T2: non-iso runtime_dir must equal idle_dir (legacy invariant)"
    smoke_assert_eq "$legacy_spool" "$spool_file" \
      "T2: non-iso spool file byte-identical to the legacy runtime_dir spool path"
    smoke_assert_eq "$legacy_lock" "$lock_dir" \
      "T2: non-iso lock dir byte-identical to the legacy runtime_dir lock path"
  )
}

# ---------------------------------------------------------------------
# T3 — real append end-to-end: with a controller-writable state leaf, the
# append SUCCEEDS, the marker lands at the state-leaf spool file, and the
# lock does NOT spin. This is the instant-wake-lands assertion.
# ---------------------------------------------------------------------
test_append_lands_at_state_leaf() {
  smoke_log "T3: real append lands the wake marker at the controller-owned state leaf"

  local state_leaf spool_file
  state_leaf="$(bridge_agent_idle_marker_dir "$AGENT")"
  spool_file="$(bridge_agent_pending_attention_file "$AGENT")"
  # Controller-owned, writable — the path the fix resolves to.
  mkdir -p "$state_leaf"
  chmod 0770 "$state_leaf"

  if ! bridge_tmux_pending_attention_append "$AGENT" "!URGENT instant wake"; then
    smoke_fail "T3: append to the controller-owned state leaf FAILED — instant wake would be lost"
  fi

  smoke_assert_file_exists "$spool_file" "T3: spool file created at state leaf"
  if ! grep -q "URGENT instant wake" "$spool_file"; then
    smoke_fail "T3: wake marker not found in the state-leaf spool file"
  fi
  local count
  count="$(bridge_tmux_pending_attention_count "$AGENT")"
  smoke_assert_eq "1" "$count" "T3: exactly one spooled wake entry"

  # And the lock dir must have been released (no leaked holder).
  local lock_dir
  lock_dir="$(bridge_agent_pending_attention_lock_dir "$AGENT")"
  if [[ -d "$lock_dir" ]]; then
    smoke_fail "T3: lock dir leaked after a successful append ($lock_dir)"
  fi
  smoke_log "T3: append succeeded, marker landed, lock released cleanly"
}

# ---------------------------------------------------------------------
# T4 — fail-soft + teeth: a controller-UNwritable spool dir (chmod 0500
# stand-in for the iso-owned leaf the pre-fix code targeted) must FAST-FAIL
# with rc 75 and NO 200-retry spin. The wall-clock proves it — a 200×0.05s
# spin would take ~10s; the fast-fail returns near-instantly. This is BOTH
# the fail-soft contract (single warning, no spam, never blocks the send)
# AND the teeth (reverting the anchor to the iso-owned tree reproduces the
# perm-denied giveup the live incident showed).
# ---------------------------------------------------------------------
test_unwritable_spool_fast_fails() {
  smoke_log "T4: unwritable spool dir fast-fails (no 200-retry spin), durable delivery unaffected"

  if [[ "$(id -u)" == "0" ]]; then
    smoke_skip "T4" "running as root — mode 0500 does not deny root; the fast-fail repro is only meaningful as non-root"
    return 0
  fi

  # Build a separate agent whose state leaf we make controller-UNwritable,
  # standing in for the iso-owned data/agents/<a>/runtime/ leaf the pre-fix
  # resolver targeted (root:ab-agent-<a> 2770 + stale controller group set).
  local denied_agent denied_leaf
  denied_agent="deniedbot"
  denied_leaf="$(bridge_agent_idle_marker_dir "$denied_agent")"
  mkdir -p "$denied_leaf"
  chmod 0500 "$denied_leaf"

  # Time the append. A genuine 200-attempt spin at 0.05s/attempt is ~10s;
  # the fast-fail must return well under that. Use a generous 3s ceiling so
  # the test is not flaky on a slow CI box while still catching a 10s spin.
  local start_s end_s elapsed rc=0
  start_s="$(date +%s)"
  bridge_tmux_pending_attention_append "$denied_agent" "should-not-block" 2>/dev/null || rc=$?
  end_s="$(date +%s)"
  elapsed=$(( end_s - start_s ))

  smoke_log "T4: append rc=$rc elapsed=${elapsed}s"

  if (( rc == 0 )); then
    smoke_fail "T4: append to a 0500 (unwritable) spool dir UNEXPECTEDLY succeeded — denial stand-in invalid"
  fi
  if (( elapsed >= 3 )); then
    smoke_fail "T4: append took ${elapsed}s — the 200-retry spin was NOT short-circuited (fail-soft regression)"
  fi
  # The spool file must NOT have been created at the denied leaf.
  local denied_spool
  denied_spool="$(bridge_agent_pending_attention_file "$denied_agent")"
  if [[ -f "$denied_spool" ]]; then
    smoke_fail "T4: spool file created despite the unwritable dir — denial stand-in invalid"
  fi

  chmod 0700 "$denied_leaf" 2>/dev/null || true
  smoke_log "T4: append fast-failed (rc=$rc, ${elapsed}s) without a 200-retry spin"
}

# ---------------------------------------------------------------------
# T5 — grep teeth: pin both resolvers to the controller-owned anchor so a
# future refactor cannot silently revert them to the iso data tree.
# ---------------------------------------------------------------------
test_resolvers_anchor_on_controller_state_leaf() {
  smoke_log "T5: grep teeth — pending-attention resolvers anchor on controller state leaf"

  smoke_assert_file_exists "$STATE_LIB" "T5: bridge-state.sh exists"

  local state_dir_body file_body lock_body
  state_dir_body="$(awk '
    /^bridge_agent_pending_attention_state_dir\(\)[ \t]*\{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$STATE_LIB")"
  file_body="$(awk '
    /^bridge_agent_pending_attention_file\(\)[ \t]*\{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$STATE_LIB")"
  lock_body="$(awk '
    /^bridge_agent_pending_attention_lock_dir\(\)[ \t]*\{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$STATE_LIB")"

  if [[ -z "$state_dir_body" ]]; then
    smoke_fail "T5: could not isolate bridge_agent_pending_attention_state_dir body in $STATE_LIB"
  fi
  if [[ -z "$file_body" || -z "$lock_body" ]]; then
    smoke_fail "T5: could not isolate pending-attention file/lock resolver bodies in $STATE_LIB"
  fi

  smoke_assert_contains "$state_dir_body" "bridge_agent_idle_marker_dir" \
    "T5: state-dir resolver must use bridge_agent_idle_marker_dir (controller-owned state leaf)"
  smoke_assert_not_contains "$state_dir_body" "bridge_agent_runtime_state_dir" \
    "T5 (teeth): state-dir resolver MUST NOT use bridge_agent_runtime_state_dir (iso data tree) — #9981 regression"
  smoke_assert_contains "$file_body" "bridge_agent_pending_attention_state_dir" \
    "T5: spool-file resolver must route through bridge_agent_pending_attention_state_dir"
  smoke_assert_not_contains "$file_body" "bridge_agent_runtime_state_dir" \
    "T5 (teeth): spool-file resolver MUST NOT use bridge_agent_runtime_state_dir directly — #9981 regression"
  smoke_assert_contains "$lock_body" "bridge_agent_pending_attention_state_dir" \
    "T5: lock resolver must route through bridge_agent_pending_attention_state_dir"
  smoke_assert_not_contains "$lock_body" "bridge_agent_runtime_state_dir" \
    "T5 (teeth): lock resolver MUST NOT use bridge_agent_runtime_state_dir directly — #9981 regression"
}

smoke_run "T1 iso spool → controller state leaf" test_iso_spool_resolves_to_controller_state_leaf
smoke_run "T2 shared spool byte-identical" test_shared_spool_path_byte_identical
smoke_run "T3 real append lands at state leaf" test_append_lands_at_state_leaf
smoke_run "T4 unwritable spool fast-fails (fail-soft + teeth)" test_unwritable_spool_fast_fails
smoke_run "T5 grep teeth" test_resolvers_anchor_on_controller_state_leaf

smoke_log "PASS — #9981 iso urgent instant-wake spool anchored on controller-owned state leaf; shared path unchanged; unwritable-spool fast-fail proven"
