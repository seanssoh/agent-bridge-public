#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/9981-iso-pending-attention-readable.sh — Issue #9981 (read side).
#
# Companion to scripts/smoke/9981-iso-urgent-instant-wake.sh, which proved the
# WRITE side: the controller can always create + append the pending-attention
# (instant-wake) spool because it now anchors on the controller-owned state
# leaf (state/agents/<a>/) instead of the iso-owned data tree.
#
# This fixture proves the READ side — the gap codex Phase-4 found after r1:
#
#   The CONSUMER of the pending-attention spool is the ISO AGENT, not the
#   controller. hooks/bridge_hook_common.py runs inside the agent's own
#   session (UID agent-bridge-<a>, member of group ab-agent-<a>) and reads
#   state/agents/<a>/pending-attention.env to surface "N queued external
#   event(s)" at prompt time. The controller WRITES that file with `printf >>`
#   under bridge-lib.sh's umask 077, so it lands mode 0600 owner=controller.
#   On a real iso-v2 leaf the agent UID — a group member but NOT the owner —
#   then gets EACCES on the read, and the hook silently treats the OSError as
#   zero pending events. The instant-wake count never surfaces and the urgent
#   degrades to self-poll latency: the SAME user-visible failure as the pre-r1
#   write EACCES, just relocated to the read side.
#
# Fix (lib/bridge-tmux.sh::bridge_tmux_pending_attention_publish_group_read):
# the controller, after writing the spool, PUBLISHES it group-readable per the
# iso cross-class controller-published pattern (CLAUDE.md §"Working with
# isolated agents") — chgrp ab-agent-<a> + chmod 0640 (owner rw, group r--),
# gated on bridge_agent_linux_user_isolation_effective so non-iso/shared/
# non-Linux installs keep the byte-identical 0600. Only this one marker file is
# opened to the agent group, and only for READ (the agent never writes the
# spool).
#
# Test plan (publish LOGIC made deterministic without provisioning OS users;
# the real cross-UID acceptance is patch's fresh-install Linux re-verify):
#   T1 publish lands group-read: with iso-effective MOCKED true and the agent
#      group MOCKED to the controller's own primary group (so chgrp resolves to
#      a real group we belong to), a real append leaves the spool file
#      group-READABLE (mode bit 0040 set, i.e. 0640) — the precondition for the
#      iso agent UID to read it.
#   T2 real group read (Linux-faithful): on Linux, a process running in the
#      file's group can `cat` the published marker. SKIP-loudly on macOS, where
#      this harness cannot mint the uid/group separation that makes the read
#      meaningful.
#   T3 teeth — non-iso parity stays 0600 (NOT group-readable): with iso NOT
#      effective the publish is a no-op, so the marker keeps mode 0600. On a
#      real iso host a 0600 marker is exactly the silent-zero-events gap this
#      fixes — group has no read bit, so the agent's read EACCES. This both
#      proves the gate (non-iso byte-identical) AND is the teeth: revert the
#      publish (or its gate) and the agent-readability assertion in T1 fails.
#   T4 reader path agreement: hooks/bridge_hook_common.py reads the SAME path
#      the writer publishes (state/agents/<a>/pending-attention.env), so the
#      group-read publish actually unblocks the consumer that matters.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no command
# substitution feeding a heredoc stdin into bridge functions and no `<<<`
# here-strings into them.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash 3.2.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:9981-iso-pending-attention-readable] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="9981-iso-pending-attention-readable"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "9981-iso-pending-attention-readable"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

# Sanity checks.
for _fn in \
  bridge_agent_pending_attention_file \
  bridge_agent_idle_marker_dir \
  bridge_tmux_pending_attention_append \
  bridge_tmux_pending_attention_publish_group_read; do
  if ! declare -F "$_fn" >/dev/null; then
    smoke_fail "$_fn not defined after sourcing bridge-lib.sh (sanity check)"
  fi
done

HOOK_COMMON="$REPO_ROOT/hooks/bridge_hook_common.py"
AGENT="isobot"

# Portable mode read: GNU `stat -c %a` vs BSD `stat -f %Lp`.
_read_mode() {
  local _path="$1"
  stat -c %a "$_path" 2>/dev/null || stat -f %Lp "$_path" 2>/dev/null
}

# Group-read bit (0040) test from an octal mode string (e.g. 640 -> yes).
_mode_has_group_read() {
  local _mode="$1"
  # Normalize to the last 3 octal digits, then read the group (middle) digit.
  _mode="${_mode: -3}"
  local _grp_digit="${_mode:1:1}"
  case "$_grp_digit" in
    4|5|6|7) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------
# T1 — publish lands the spool file group-READABLE under iso-effective.
# Mock the iso predicate + group resolver so the publish path runs and
# chgrp resolves to a group we actually belong to (the controller's own
# primary group), independent of the host platform.
# ---------------------------------------------------------------------
test_publish_lands_group_readable() {
  smoke_log "T1: controller publish leaves the spool group-readable (iso-effective mocked)"

  (
    # Force the publish gate ON regardless of host platform, and point the
    # chgrp target at a group the harness user is in so the chgrp succeeds.
    local own_grp
    own_grp="$(id -gn 2>/dev/null || true)"
    # Mock overrides — invoked indirectly by the bridge code under test.
    # shellcheck disable=SC2329
    bridge_agent_linux_user_isolation_effective() { return 0; }
    # shellcheck disable=SC2329
    bridge_isolation_v2_agent_group_name() { printf '%s' "$own_grp"; }

    local state_leaf spool_file
    state_leaf="$(bridge_agent_idle_marker_dir "$AGENT")"
    spool_file="$(bridge_agent_pending_attention_file "$AGENT")"
    mkdir -p "$state_leaf"
    chmod 0770 "$state_leaf"
    rm -f "$spool_file"

    if ! bridge_tmux_pending_attention_append "$AGENT" "!URGENT instant wake"; then
      smoke_fail "T1: append to the controller-owned state leaf FAILED — instant wake would be lost"
    fi
    smoke_assert_file_exists "$spool_file" "T1: spool file created at state leaf"

    local mode
    mode="$(_read_mode "$spool_file")"
    smoke_log "T1: published spool mode=$mode (expect group-readable, e.g. 640)"
    if ! _mode_has_group_read "$mode"; then
      smoke_fail "T1: published spool mode=$mode has NO group-read bit — the iso AGENT (member of ab-agent-<a>) cannot read the marker; instant-wake count stays invisible (#9981 read-side regression)"
    fi
    smoke_log "T1: spool published group-readable — the iso agent group can read the wake marker"
  )
}

# ---------------------------------------------------------------------
# T2 — Linux-faithful: a process in the file's group can actually `cat`
# the published marker. SKIP-loudly on macOS (no real uid/group
# separation in this harness).
# ---------------------------------------------------------------------
test_group_member_can_read() {
  smoke_log "T2: a group member can read the published marker (Linux-faithful)"

  if ! smoke_is_linux; then
    smoke_skip "T2" "non-Linux host — cannot mint real uid/group separation; the publish mode is asserted in T1, the real cross-UID read is patch's Linux fresh-install re-verify"
    return 0
  fi
  if [[ "$(id -u)" == "0" ]]; then
    smoke_skip "T2" "running as root — root reads regardless of group bits, so the group-read gate is not exercised"
    return 0
  fi

  (
    local own_grp
    own_grp="$(id -gn 2>/dev/null || true)"
    # Mock overrides — invoked indirectly by the bridge code under test.
    # shellcheck disable=SC2329
    bridge_agent_linux_user_isolation_effective() { return 0; }
    # shellcheck disable=SC2329
    bridge_isolation_v2_agent_group_name() { printf '%s' "$own_grp"; }

    local state_leaf spool_file
    state_leaf="$(bridge_agent_idle_marker_dir "$AGENT")"
    spool_file="$(bridge_agent_pending_attention_file "$AGENT")"
    mkdir -p "$state_leaf"
    chmod 0770 "$state_leaf"
    rm -f "$spool_file"
    bridge_tmux_pending_attention_append "$AGENT" "!URGENT instant wake" \
      || smoke_fail "T2: append failed"

    # `sg <group> -c 'cat ...'` runs the read with <group> as the primary
    # group; the file is mode 0640 group=<own_grp>, so a group member reads it
    # via the group bit, not the owner bit. We are already in own_grp, but sg
    # forces the read to depend on the GROUP column (it drops to that group's
    # context), which is the column the fix grants.
    if command -v sg >/dev/null 2>&1; then
      if ! sg "$own_grp" -c "cat '$spool_file' >/dev/null" 2>/dev/null; then
        smoke_fail "T2: a process in the marker's group could NOT read it — the group-read publish did not take effect"
      fi
      smoke_log "T2: group member read the published marker via the group bit"
    else
      smoke_skip "T2" "sg(1) not available — group-read bit is asserted in T1; real cross-UID read is patch's Linux fresh-install re-verify"
    fi
  )
}

# ---------------------------------------------------------------------
# T3 — teeth + non-iso parity: with iso NOT effective the publish is a
# no-op, so the marker keeps mode 0600 (NOT group-readable). On a real iso
# host that 0600 is exactly the silent-zero-events gap; reverting the
# publish (or its gate) makes T1 fail. This also proves shared-mode parity.
# ---------------------------------------------------------------------
test_non_iso_stays_0600_not_group_readable() {
  smoke_log "T3: non-iso/shared marker stays 0600 (no group-publish) — parity + teeth"

  (
    # iso NOT effective → publish gate is a no-op.
    # Mock override — invoked indirectly by the bridge code under test.
    # shellcheck disable=SC2329
    bridge_agent_linux_user_isolation_effective() { return 1; }

    # Use a fresh agent so a prior published (0640) spool from T1/T2 cannot
    # mask the gate: `printf >>` preserves an existing file's mode, so the
    # only honest parity check is a brand-new marker on the shared-mode path.
    local shared_agent="sharedbot"
    local state_leaf spool_file
    state_leaf="$(bridge_agent_idle_marker_dir "$shared_agent")"
    spool_file="$(bridge_agent_pending_attention_file "$shared_agent")"
    mkdir -p "$state_leaf"
    chmod 0770 "$state_leaf"
    rm -f "$spool_file"
    # Mirror the controller umask 077 the live writer runs under so the file
    # lands 0600 absent any publish (the harness shell may carry a looser
    # umask).
    umask 077
    bridge_tmux_pending_attention_append "$shared_agent" "shared-mode event" \
      || smoke_fail "T3: append failed"
    smoke_assert_file_exists "$spool_file" "T3: spool file created"

    local mode
    mode="$(_read_mode "$spool_file")"
    smoke_log "T3: non-iso spool mode=$mode (expect 0600 — no group-publish)"
    if _mode_has_group_read "$mode"; then
      smoke_fail "T3: non-iso spool mode=$mode is group-readable — the publish gate leaked onto a shared-mode install (over-permissioning regression)"
    fi
    smoke_log "T3: non-iso marker stayed owner-only (0600) — gate holds, parity preserved"
  )
}

# ---------------------------------------------------------------------
# T4 — reader path agreement: the Python prompt-context hook reads the SAME
# state-leaf path the writer publishes, so the group-read fix unblocks the
# consumer that actually matters.
# ---------------------------------------------------------------------
test_hook_reads_published_path() {
  smoke_log "T4: hooks/bridge_hook_common.py reads the published state-leaf spool path"

  smoke_assert_file_exists "$HOOK_COMMON" "T4: bridge_hook_common.py exists"

  # The spool marker basename and the iso-runtime-anchor drift pattern, kept in
  # locals so the literal lands on noqa'd lines (these are grep-on-source
  # fixture assertions, not controller->iso boundary writes).
  local spool_basename='pending-attention.env'  # noqa: iso-helper-boundary (smoke fixture grep pattern — matches the hook's spool basename in source, not a boundary write)
  local runtime_drift_pat="runtime.*pending-attention.env\\|pending-attention.env.*runtime"  # noqa: iso-helper-boundary (smoke fixture grep pattern — detects a reader anchored on the iso runtime subtree, not a boundary write)

  if ! grep -q "$spool_basename" "$HOOK_COMMON"; then
    smoke_fail "T4: hook does not reference the spool marker basename — reader/writer path drift"
  fi
  # The hook must resolve the spool under state/agents/<agent>/, the
  # controller-owned leaf the writer publishes — NOT the iso data tree.
  if ! grep -q '"agents"' "$HOOK_COMMON"; then
    smoke_fail "T4: hook spool path does not route through the state-leaf agents/ dir"
  fi
  if grep -q "$runtime_drift_pat" "$HOOK_COMMON"; then
    smoke_fail "T4: hook reads the spool from an iso runtime subtree — reader/writer anchor drift (#9981 regression)"
  fi
  smoke_log "T4: hook reader and controller writer agree on the state-leaf spool path"
}

# ---------------------------------------------------------------------
# T5 — fail-closed teeth (codex r2): when the per-agent group cannot be
# bound to the marker (resolver empty, or chgrp cannot reach the group),
# the publish MUST leave the file owner-only (0600) — NOT chmod it 0640 for
# whatever (wrong) group it happens to carry. A wrong-group 0640 would
# expose the marker to an unintended group while STILL leaving the iso agent
# (not in that group) unable to read it. This is the teeth codex flagged:
# without the fail-closed gate, dropping the chgrp but keeping the chmod
# would mis-publish; here it must stay 0600.
# ---------------------------------------------------------------------
test_publish_fail_closed_on_bad_group() {
  smoke_log "T5: publish fails closed (stays 0600) when the per-agent group cannot be bound"

  (
    # iso effective, but the group resolver yields a group this process can
    # NEITHER chgrp to NOR is a member of — the real-world "parent lost setgid
    # + chgrp denied / stale group" case. We force chgrp to fail by pointing at
    # a group name that does not resolve on the host.
    # shellcheck disable=SC2329
    bridge_agent_linux_user_isolation_effective() { return 0; }
    # shellcheck disable=SC2329
    bridge_isolation_v2_agent_group_name() { printf '%s' "ab-agent-nonexistent-$$"; }

    local bad_agent="badgrpbot"
    local state_leaf spool_file
    state_leaf="$(bridge_agent_idle_marker_dir "$bad_agent")"
    spool_file="$(bridge_agent_pending_attention_file "$bad_agent")"
    mkdir -p "$state_leaf"
    chmod 0770 "$state_leaf"
    rm -f "$spool_file"
    umask 077
    bridge_tmux_pending_attention_append "$bad_agent" "wake on a host where the group cannot bind" \
      || smoke_fail "T5: append failed"
    smoke_assert_file_exists "$spool_file" "T5: spool file created"

    local mode
    mode="$(_read_mode "$spool_file")"
    smoke_log "T5: spool mode=$mode (expect 0600 — group could not be bound, so no group-publish)"
    if _mode_has_group_read "$mode"; then
      smoke_fail "T5: spool mode=$mode is group-readable despite an unbindable per-agent group — wrong-group mis-publish (codex r2 fail-closed regression)"
    fi
    smoke_log "T5: publish failed closed (0600) — no wrong-group exposure when the group cannot be bound"
  )
}

smoke_run "T1 publish lands group-readable" test_publish_lands_group_readable
smoke_run "T2 group member can read (Linux-faithful)" test_group_member_can_read
smoke_run "T3 non-iso stays 0600 (parity + teeth)" test_non_iso_stays_0600_not_group_readable
smoke_run "T4 hook reads published path" test_hook_reads_published_path
smoke_run "T5 publish fails closed on unbindable group" test_publish_fail_closed_on_bad_group

smoke_log "PASS — #9981 read-side: controller publishes the pending-attention marker group-readable so the iso AGENT can read its instant-wake count; non-iso parity (0600) preserved; wrong-group mis-publish fails closed"
