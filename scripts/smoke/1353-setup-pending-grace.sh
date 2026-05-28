#!/usr/bin/env bash
#
# scripts/smoke/1353-setup-pending-grace.sh — issue #1353 regression
# (v0.15.0-beta5-2 Track A).
#
# Pins the setup-pending grace window contract.
#
# Before this PR, a fresh `agent create --isolate --channels
# plugin:teams,plugin:ms365` registered an always-on static role. The
# daemon's first 4 auto-start ticks (~80s) emitted
#   [info] channel-health miss for <agent> recorded as audit + dashboard flag (...)
#   [info] auto-start backoff <agent> (failures=1, retry_in=5s, reason=channel-required-validator-miss: ...)
#   [info] auto-start backoff <agent> (failures=2, retry_in=5s, ...)
#   [info] auto-start backoff <agent> (failures=3, retry_in=30s, ...)
#   [info] auto-start backoff <agent> (failures=4, retry_in=30s, ...)
# BEFORE the operator had a chance to run `setup teams <a>` / `setup
# ms365 <a>`. The 4 bursts plus 2 channel-health audit rows masked real
# errors and confused first-install OOTB.
#
# This PR adds a setup-pending grace marker
# (`state/agents/<a>/setup-pending`) that the daemon's auto-start
# dispatcher silent-skips on (no audit, no failures counter, no
# log spam) for `BRIDGE_AGENT_SETUP_PENDING_GRACE_SECONDS` (default 900
# = 15 min) after `agent create`. Each `setup <channel> <agent>` verb
# touches the marker on entry (extends grace) and removes it on
# completion.
#
# Cases (all run in an isolated BRIDGE_HOME — never touches live
# runtime; reuses scripts/smoke/lib.sh):
#
#   T1. `bridge_agent_mark_setup_pending` writes the marker; the
#       marker file lives under `state/agents/<a>/setup-pending`.
#
#   T2. `bridge_agent_setup_pending_active` returns 0 (true) when the
#       marker is present + within the grace window. The production
#       gate `bridge_daemon_check_channel_status_or_hold` (extracted
#       verbatim from bridge-daemon.sh) short-circuits SILENTLY:
#       NO backoff state file write, NO `bridge_daemon_note_autostart_
#       failure` invocation, NO audit row.
#
#   T3. `bridge_agent_clear_setup_pending` removes the marker
#       (mirrors the END-of-setup hook in run_teams / run_ms365 /
#       run_telegram / run_discord). After clear, the same gate
#       reverts to the existing audit + backoff path.
#
#   T4. Marker-absent + status=miss: the existing backoff path applies
#       (audit row written, failures counter incremented, daemon log
#       gets the actionable `channel-required-validator-miss` reason).
#
#   T5. Teeth-revert: `BRIDGE_AGENT_SETUP_PENDING_GRACE_SECONDS=0`
#       disables the grace window entirely — even when the marker is
#       present, the gate falls through to the existing backoff path.
#       Without this teeth case, a future refactor that silently flips
#       the grace check to always-true would pass T2 and T3 but be a
#       silent regression.
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess —
# helper bodies are written to standalone driver files and invoked
# with `bash <driver>`, mirroring scripts/smoke/δ-1234-daemon-start-
# policy.sh.

_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:1353-setup-pending-grace] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="1353-setup-pending-grace"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd awk
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT="test_clean"

# Resolve a Bash 4+ interpreter for all inner `bash <driver>` invocations.
BRIDGE_BASH="${BASH4_BIN:-}"
if [[ -z "$BRIDGE_BASH" || ! -x "$BRIDGE_BASH" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  else
    BRIDGE_BASH="$(command -v bash)"
  fi
fi
"$BRIDGE_BASH" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1 || \
  smoke_fail "Bash 4+ interpreter not found (BASH4_BIN=${BASH4_BIN:-unset}); install homebrew bash"

# Extract the helper bodies we need from lib/bridge-state.sh:
#   bridge_agent_idle_marker_dir
#   bridge_agent_setup_pending_file
#   bridge_agent_setup_pending_active
#   bridge_agent_mark_setup_pending
#   bridge_agent_clear_setup_pending
HELPERS_STATE="$SMOKE_TMP_ROOT/state-helpers.sh"
{
  awk '
    /^bridge_agent_idle_marker_dir\(\) \{/      { capture=1 }
    /^bridge_agent_setup_pending_file\(\) \{/   { capture=1 }
    /^bridge_agent_setup_pending_active\(\) \{/ { capture=1 }
    /^bridge_agent_mark_setup_pending\(\) \{/   { capture=1 }
    /^bridge_agent_clear_setup_pending\(\) \{/  { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/lib/bridge-state.sh"
} >"$HELPERS_STATE"

for fn in bridge_agent_idle_marker_dir bridge_agent_setup_pending_file \
          bridge_agent_setup_pending_active bridge_agent_mark_setup_pending \
          bridge_agent_clear_setup_pending; do
  if ! grep -q "^${fn}() {" "$HELPERS_STATE"; then
    smoke_fail "Could not extract helper $fn from lib/bridge-state.sh — check for rename"
  fi
done

# Extract the daemon-side helpers we need:
#   bridge_daemon_autostart_state_file
#   bridge_daemon_note_autostart_failure
#   bridge_daemon_clear_autostart_failure
#   bridge_daemon_check_channel_status_or_hold
HELPERS_DAEMON="$SMOKE_TMP_ROOT/daemon-helpers.sh"
{
  awk '
    /^bridge_daemon_autostart_state_file\(\) \{/      { capture=1 }
    /^bridge_daemon_note_autostart_failure\(\) \{/    { capture=1 }
    /^bridge_daemon_clear_autostart_failure\(\) \{/   { capture=1 }
    /^bridge_daemon_check_channel_status_or_hold\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/bridge-daemon.sh"
} >"$HELPERS_DAEMON"

for fn in bridge_daemon_autostart_state_file bridge_daemon_note_autostart_failure \
          bridge_daemon_clear_autostart_failure bridge_daemon_check_channel_status_or_hold; do
  if ! grep -q "^${fn}() {" "$HELPERS_DAEMON"; then
    smoke_fail "Could not extract helper $fn from bridge-daemon.sh — check for rename"
  fi
done

# Confirm the daemon-side gate actually references the new
# setup-pending helper. If a future refactor drops the silent-skip
# branch from bridge_daemon_check_channel_status_or_hold (e.g. by
# moving the gate to an outer layer), this assertion fails fast and
# the smoke surfaces the regression.
if ! grep -q 'bridge_agent_setup_pending_active' "$HELPERS_DAEMON"; then
  smoke_fail "bridge_daemon_check_channel_status_or_hold no longer references bridge_agent_setup_pending_active — #1353 grace gate has been removed or moved"
fi

# Also confirm the bridge_report_channel_health_miss path carries the
# same gate, so the audit row doesn't fire during grace either.
if ! grep -q 'bridge_agent_setup_pending_active' "$REPO_ROOT/bridge-daemon.sh"; then
  smoke_fail "bridge-daemon.sh no longer references bridge_agent_setup_pending_active anywhere — full grace surface removed"
fi
# At least 3 call sites: the autostart check (inside
# bridge_daemon_check_channel_status_or_hold), the channel-health miss
# report (bridge_report_channel_health_miss), AND the cron-dispatch
# wake path (bridge_daemon_cron_dispatch_wake) which emits its own
# warn + audit row on a generic hold and so needs its own grace probe
# (codex r1 BLOCKING #1353).
GRACE_REFS="$(grep -c 'bridge_agent_setup_pending_active' "$REPO_ROOT/bridge-daemon.sh" 2>/dev/null || echo 0)"
if (( GRACE_REFS < 3 )); then
  smoke_fail "bridge-daemon.sh references bridge_agent_setup_pending_active only $GRACE_REFS time(s); expected >=3 (autostart gate + channel-health miss report + cron-dispatch wake)"
fi

# Confirm `agent create` writes the marker.
if ! grep -q 'bridge_agent_mark_setup_pending' "$REPO_ROOT/bridge-agent.sh"; then
  smoke_fail "bridge-agent.sh no longer marks setup_pending on agent create"
fi

# Confirm the setup verbs clear the marker.
SETUP_CLEAR_SITES="$(grep -c 'bridge_agent_clear_setup_pending' "$REPO_ROOT/bridge-setup.sh" 2>/dev/null || echo 0)"
if (( SETUP_CLEAR_SITES < 4 )); then
  smoke_fail "bridge-setup.sh has $SETUP_CLEAR_SITES bridge_agent_clear_setup_pending sites; expected >=4 (run_discord + run_telegram + run_teams + run_ms365)"
fi
# Mark sites: discord + telegram + teams + ms365 entry = 4
SETUP_MARK_SITES="$(grep -c 'bridge_agent_mark_setup_pending' "$REPO_ROOT/bridge-setup.sh" 2>/dev/null || echo 0)"
if (( SETUP_MARK_SITES < 4 )); then
  smoke_fail "bridge-setup.sh has $SETUP_MARK_SITES bridge_agent_mark_setup_pending sites; expected >=4 (run_discord + run_telegram + run_teams + run_ms365)"
fi

# Confirm bridge-start.sh clears the marker on explicit operator start.
if ! grep -q 'bridge_agent_clear_setup_pending' "$REPO_ROOT/bridge-start.sh"; then
  smoke_fail "bridge-start.sh no longer clears setup-pending marker on operator-driven start"
fi

# ---------------------------------------------------------------------------
# T1 — bridge_agent_mark_setup_pending writes the marker.
# ---------------------------------------------------------------------------
step_t1_marker_written() {
  smoke_log "T1: bridge_agent_mark_setup_pending writes state/agents/<a>/setup-pending"

  local driver="$SMOKE_TMP_ROOT/t1-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$1"\n'
    printf 'AGENT="$2"\n'
    # Stubs the production helpers wouldn't have access to in the
    # smoke fixture. We deliberately skip the iso-v2 branch so the
    # fallback `mkdir -p + : >file` path is exercised — that path is
    # the one all non-Linux + non-iso installs take.
    printf 'bridge_isolation_v2_active() { return 1; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'bridge_agent_mark_setup_pending "$AGENT"\n'
    printf 'bridge_agent_setup_pending_file "$AGENT"\n'
  } >"$driver"

  local marker_path
  marker_path="$("$BRIDGE_BASH" "$driver" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT")"
  smoke_assert_file_exists "$marker_path" "T1: setup-pending marker must exist after mark"

  # Path discipline: marker lives under state/agents/<a>/.
  local expected_dir="$BRIDGE_ACTIVE_AGENT_DIR/$AGENT"
  case "$marker_path" in
    "$expected_dir"/setup-pending) ;;
    *) smoke_fail "T1: marker path '$marker_path' is not under '$expected_dir/'" ;;
  esac

  smoke_log "T1 PASS — marker file landed at $marker_path"
}

# ---------------------------------------------------------------------------
# T2 — Production gate silent-skips when marker is active + status=miss.
#      NO state file write, NO failures counter, NO audit row.
# ---------------------------------------------------------------------------
step_t2_silent_skip_during_grace() {
  smoke_log "T2: production gate silent-skips channel-validator-miss during grace"

  local state_dir="$SMOKE_TMP_ROOT/t2-state"
  mkdir -p "$state_dir/daemon-autostart"
  export BRIDGE_STATE_DIR="$state_dir"
  local daemon_log="$SMOKE_TMP_ROOT/t2-daemon.log"
  : >"$daemon_log"

  local driver="$SMOKE_TMP_ROOT/t2-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$2"\n'
    printf 'AGENT="$3"\n'
    printf 'DAEMON_LOG="$4"\n'
    # Stubs.
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'daemon_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_audit_log() { printf "audit: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_isolation_v2_active() { return 1; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 1; }\n'
    # Stub the escalation helper that bridge_daemon_note_autostart_
    # failure invokes when fail_count >= threshold. The production
    # function is in bridge-daemon.sh too but isn't part of the gate
    # contract this smoke pins — keep the stub a no-op return 0.
    printf 'bridge_daemon_maybe_escalate_always_on_fail() { return 0; }\n'
    # Stub daemon_source_state_file: the production helper sources
    # the autostart state file with a constrained allowlist; the smoke
    # only needs it to read the file as plain shell.
    printf 'daemon_source_state_file() { [[ -f "$1" ]] && source "$1" 2>/dev/null || true; }\n'
    printf 'bridge_agent_channel_status() { printf "%%s" "miss"; }\n'
    printf 'bridge_agent_channel_status_reason() { printf "%%s" "missing Teams access.json"; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    printf 'bridge_agent_mark_setup_pending "$AGENT"\n'
    printf 'if bridge_daemon_check_channel_status_or_hold "$AGENT"; then\n'
    printf '  echo "HOLD"\n'
    printf 'else\n'
    printf '  echo "FALLTHROUGH"\n'
    printf 'fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT" "$daemon_log")"

  # Production gate returns 0 ("hold this row this tick") regardless
  # of grace vs no-grace. Both branches return 0. The DIFFERENCE is:
  #   - With grace (T2): silent — no state file, no log.
  #   - Without grace (T4): backoff state file + actionable reason.
  smoke_assert_contains "$out" "HOLD" "T2: gate must return 0 (hold) under grace"

  # T2.a — NO backoff state file was written.
  local state_count
  state_count="$(find "$state_dir/daemon-autostart" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | awk '{print $1}')"
  smoke_assert_eq "0" "$state_count" "T2.a: grace silent-skip must NOT write a backoff state file"

  # T2.b — NO daemon_info / audit lines about channel-required-validator-miss.
  local validator_lines
  validator_lines="$(grep -c 'channel-required-validator-miss' "$daemon_log" 2>/dev/null || true)"
  smoke_assert_eq "0" "$validator_lines" "T2.b: grace silent-skip must NOT emit daemon_info line"
  local audit_lines
  audit_lines="$(grep -c '^audit:' "$daemon_log" 2>/dev/null || true)"
  smoke_assert_eq "0" "$audit_lines" "T2.b: grace silent-skip must NOT emit audit log row"

  # T2.c — Five back-to-back hold ticks: log stays clean of backoff
  # noise. This is the patch-measured reproducer's pain point — the
  # 4-burst noise spam BEFORE setup.
  local i
  for (( i = 0; i < 5; i++ )); do
    "$BRIDGE_BASH" "$driver" "$state_dir" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT" "$daemon_log" >/dev/null
  done
  local total_backoff
  total_backoff="$(grep -c 'auto-start backoff' "$daemon_log" 2>/dev/null || true)"
  smoke_assert_eq "0" "$total_backoff" "T2.c: 5 consecutive grace ticks must produce 0 'auto-start backoff' log lines"

  smoke_log "T2 PASS — grace gate silent-skips validator miss without audit/state/log noise"
}

# ---------------------------------------------------------------------------
# T3 — bridge_agent_clear_setup_pending removes the marker; after clear,
#      the gate reverts to the normal backoff path.
# ---------------------------------------------------------------------------
step_t3_clear_reverts_to_normal_path() {
  smoke_log "T3: setup completion clears marker; gate reverts to normal backoff"

  local state_dir="$SMOKE_TMP_ROOT/t3-state"
  mkdir -p "$state_dir/daemon-autostart"
  local daemon_log="$SMOKE_TMP_ROOT/t3-daemon.log"
  : >"$daemon_log"

  local driver="$SMOKE_TMP_ROOT/t3-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$2"\n'
    printf 'AGENT="$3"\n'
    printf 'DAEMON_LOG="$4"\n'
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'daemon_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_audit_log() { printf "audit: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_isolation_v2_active() { return 1; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 1; }\n'
    # Stub the escalation helper that bridge_daemon_note_autostart_
    # failure invokes when fail_count >= threshold. The production
    # function is in bridge-daemon.sh too but isn't part of the gate
    # contract this smoke pins — keep the stub a no-op return 0.
    printf 'bridge_daemon_maybe_escalate_always_on_fail() { return 0; }\n'
    # Stub daemon_source_state_file: the production helper sources
    # the autostart state file with a constrained allowlist; the smoke
    # only needs it to read the file as plain shell.
    printf 'daemon_source_state_file() { [[ -f "$1" ]] && source "$1" 2>/dev/null || true; }\n'
    printf 'bridge_agent_channel_status() { printf "%%s" "miss"; }\n'
    printf 'bridge_agent_channel_status_reason() { printf "%%s" "missing MS365 client id"; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    # Mark, then clear, then probe the active fn.
    printf 'bridge_agent_mark_setup_pending "$AGENT"\n'
    printf 'if bridge_agent_setup_pending_active "$AGENT"; then printf "before_clear=active\\n"; else printf "before_clear=inactive\\n"; fi\n'
    printf 'bridge_agent_clear_setup_pending "$AGENT"\n'
    printf 'if bridge_agent_setup_pending_active "$AGENT"; then printf "after_clear=active\\n"; else printf "after_clear=inactive\\n"; fi\n'
    # Now run the gate; with grace cleared, expect the backoff path.
    printf 'if bridge_daemon_check_channel_status_or_hold "$AGENT"; then printf "gate=hold\\n"; else printf "gate=fallthrough\\n"; fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT" "$daemon_log")"

  smoke_assert_contains "$out" "before_clear=active" "T3: marker active immediately after mark"
  smoke_assert_contains "$out" "after_clear=inactive" "T3: marker inactive after clear"
  smoke_assert_contains "$out" "gate=hold" "T3: gate returns 0 (hold) even after clear — but writes backoff this time"

  # Cleared-path side effect: backoff state file IS written this time.
  local state_count
  state_count="$(find "$state_dir/daemon-autostart" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | awk '{print $1}')"
  smoke_assert_eq "1" "$state_count" "T3: cleared-marker path MUST write the backoff state file"

  # Cleared-path side effect: daemon log carries the actionable reason.
  if ! grep -q 'channel-required-validator-miss' "$daemon_log" 2>/dev/null; then
    smoke_fail "T3: cleared-marker path MUST emit channel-required-validator-miss daemon_info line"
  fi

  # Marker file actually deleted from disk.
  local marker_path="$BRIDGE_ACTIVE_AGENT_DIR/$AGENT/setup-pending"
  if [[ -e "$marker_path" ]]; then
    smoke_fail "T3: marker file still present after clear: $marker_path"
  fi

  smoke_log "T3 PASS — clear removes marker, gate reverts to normal backoff path"
}

# ---------------------------------------------------------------------------
# T4 — Marker-absent + status=miss: existing backoff path applies
#      (control). This is the pre-#1353 behavior the grace window
#      replaces during the first 15 min, and the post-grace fallback
#      after the marker expires or is cleared.
# ---------------------------------------------------------------------------
step_t4_marker_absent_normal_backoff() {
  smoke_log "T4: marker absent + status=miss uses existing actionable backoff path"

  local state_dir="$SMOKE_TMP_ROOT/t4-state"
  mkdir -p "$state_dir/daemon-autostart"
  local daemon_log="$SMOKE_TMP_ROOT/t4-daemon.log"
  : >"$daemon_log"

  local driver="$SMOKE_TMP_ROOT/t4-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$2"\n'
    printf 'AGENT="$3"\n'
    printf 'DAEMON_LOG="$4"\n'
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'daemon_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_audit_log() { printf "audit: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_isolation_v2_active() { return 1; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 1; }\n'
    # Stub the escalation helper that bridge_daemon_note_autostart_
    # failure invokes when fail_count >= threshold. The production
    # function is in bridge-daemon.sh too but isn't part of the gate
    # contract this smoke pins — keep the stub a no-op return 0.
    printf 'bridge_daemon_maybe_escalate_always_on_fail() { return 0; }\n'
    # Stub daemon_source_state_file: the production helper sources
    # the autostart state file with a constrained allowlist; the smoke
    # only needs it to read the file as plain shell.
    printf 'daemon_source_state_file() { [[ -f "$1" ]] && source "$1" 2>/dev/null || true; }\n'
    printf 'bridge_agent_channel_status() { printf "%%s" "miss"; }\n'
    printf 'bridge_agent_channel_status_reason() { printf "%%s" "missing Teams access.json"; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    # NO mark call — confirm marker absent.
    printf 'if bridge_agent_setup_pending_active "$AGENT"; then printf "marker=active\\n"; else printf "marker=inactive\\n"; fi\n'
    printf 'if bridge_daemon_check_channel_status_or_hold "$AGENT"; then printf "gate=hold\\n"; else printf "gate=fallthrough\\n"; fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT" "$daemon_log")"

  smoke_assert_contains "$out" "marker=inactive" "T4: marker must be absent at start of T4"
  smoke_assert_contains "$out" "gate=hold" "T4: gate still returns hold for miss status, but takes backoff path"

  # Backoff state file written.
  local state_file
  state_file="$(find "$state_dir/daemon-autostart" -maxdepth 1 -name '*.env' | head -n 1)"
  if [[ -z "$state_file" ]]; then
    smoke_fail "T4: no backoff state file written — the existing actionable backoff path was skipped"
  fi

  # State file carries the actionable reason.
  local last_reason
  last_reason="$(grep '^AUTO_START_LAST_REASON=' "$state_file" | head -n 1 | sed 's/^AUTO_START_LAST_REASON=//')"
  smoke_assert_contains "$last_reason" "channel-required-validator-miss" \
    "T4: backoff state reason must name validator miss (got: $last_reason)"

  # Daemon log carries the same actionable token.
  if ! grep -q 'channel-required-validator-miss' "$daemon_log" 2>/dev/null; then
    smoke_fail "T4: daemon_info backoff line must mention channel-required-validator-miss"
  fi

  smoke_log "T4 PASS — marker-absent path is the existing actionable backoff path"
}

# ---------------------------------------------------------------------------
# T5 — Teeth-revert: BRIDGE_AGENT_SETUP_PENDING_GRACE_SECONDS=0 disables
#      grace entirely; the marker exists but the gate falls through to
#      the backoff path. Catches future regressions where the grace
#      check is silently reduced to "if marker exists, skip".
# ---------------------------------------------------------------------------
step_t5_teeth_revert_grace_disabled() {
  smoke_log "T5 (teeth): grace=0 must disable the silent-skip even when marker exists"

  local state_dir="$SMOKE_TMP_ROOT/t5-state"
  mkdir -p "$state_dir/daemon-autostart"
  local daemon_log="$SMOKE_TMP_ROOT/t5-daemon.log"
  : >"$daemon_log"

  local driver="$SMOKE_TMP_ROOT/t5-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$2"\n'
    printf 'AGENT="$3"\n'
    printf 'DAEMON_LOG="$4"\n'
    printf 'export BRIDGE_AGENT_SETUP_PENDING_GRACE_SECONDS=0\n'
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'daemon_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_audit_log() { printf "audit: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_isolation_v2_active() { return 1; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 1; }\n'
    # Stub the escalation helper that bridge_daemon_note_autostart_
    # failure invokes when fail_count >= threshold. The production
    # function is in bridge-daemon.sh too but isn't part of the gate
    # contract this smoke pins — keep the stub a no-op return 0.
    printf 'bridge_daemon_maybe_escalate_always_on_fail() { return 0; }\n'
    # Stub daemon_source_state_file: the production helper sources
    # the autostart state file with a constrained allowlist; the smoke
    # only needs it to read the file as plain shell.
    printf 'daemon_source_state_file() { [[ -f "$1" ]] && source "$1" 2>/dev/null || true; }\n'
    printf 'bridge_agent_channel_status() { printf "%%s" "miss"; }\n'
    printf 'bridge_agent_channel_status_reason() { printf "%%s" "missing Teams access.json"; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    # Mark, then probe with grace=0.
    printf 'bridge_agent_mark_setup_pending "$AGENT"\n'
    printf 'if [[ -e "$(bridge_agent_setup_pending_file "$AGENT")" ]]; then printf "marker_file=present\\n"; else printf "marker_file=absent\\n"; fi\n'
    printf 'if bridge_agent_setup_pending_active "$AGENT"; then printf "active=true\\n"; else printf "active=false\\n"; fi\n'
    printf 'if bridge_daemon_check_channel_status_or_hold "$AGENT"; then printf "gate=hold\\n"; else printf "gate=fallthrough\\n"; fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT" "$daemon_log")"

  # Marker file IS on disk (mark wrote it).
  smoke_assert_contains "$out" "marker_file=present" "T5: marker file MUST exist (mark was called)"
  # But active=false because grace=0 disables the window.
  smoke_assert_contains "$out" "active=false" "T5 teeth: grace=0 must make active=false even with marker present"
  # Gate still returns hold (status=miss) but takes the backoff path,
  # NOT the silent-skip path.
  smoke_assert_contains "$out" "gate=hold" "T5: gate returns hold under miss"

  # Backoff state file IS written (proving the silent-skip branch was
  # NOT taken).
  local state_count
  state_count="$(find "$state_dir/daemon-autostart" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | awk '{print $1}')"
  smoke_assert_eq "1" "$state_count" "T5 teeth: grace=0 must take the backoff state path (not silent-skip)"

  # Daemon log has the actionable reason.
  if ! grep -q 'channel-required-validator-miss' "$daemon_log" 2>/dev/null; then
    smoke_fail "T5 teeth: grace=0 path must emit channel-required-validator-miss"
  fi

  smoke_log "T5 PASS — grace=0 teeth-revert disables silent-skip; existing backoff path applies"
}

step_t1_marker_written
step_t2_silent_skip_during_grace
step_t3_clear_reverts_to_normal_path
step_t4_marker_absent_normal_backoff
step_t5_teeth_revert_grace_disabled

smoke_log "ALL PASS — #1353 setup-pending grace window contract upheld"
