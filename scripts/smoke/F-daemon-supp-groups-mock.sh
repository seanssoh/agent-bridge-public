#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/F-daemon-supp-groups-mock.sh — Lane F (v0.15.0-beta1).
#
# Host-agnostic mock smoke for the autonomous daemon-side supplementary-
# group staleness poll + detached refresh-worker dispatch path in
# bridge-daemon.sh (refactored helper + new poll-and-dispatch + new
# `supp-refresh-worker` subcommand).
#
# Background — Issue #1178 cycle 12 / KNOWN_ISSUES.md §28:
#   When the controller user is added to a fresh `ab-agent-<agent>`
#   group via `usermod -aG`, the running daemon's kernel-side supp-
#   group set stays stale: SIGHUP/setgroups cannot refresh credentials
#   on a live process. The fix is process restart through the PAM/
#   initgroups boundary that the existing helper
#   `bridge_daemon_refresh_after_group_membership_change` already
#   drives. Lane F adds an AUTONOMOUS daemon-side poll that dispatches
#   that helper as a detached external process when the explicit
#   create/delete/isolate callers were missed or blocked.
#
# Tests (host-agnostic — every Linux behavior is stubbed via PATH shims):
#
#   T-detect-1: bridge_daemon_detect_stale_supp_groups emits the
#              missing `ab-agent-*` name (one per line, sorted).
#   T-detect-2: detector emits NOTHING on macOS (uname != Linux gate).
#   T-detect-3: detector emits NOTHING when no missing group is `ab-agent-*`
#              (a stale `wheel` or `staff` GID is irrelevant to Lane F).
#
#   T-throttle-1: should_refresh returns 0 on the first call (no state).
#   T-throttle-2: should_refresh returns 1 when state shows the SAME group
#                 with `manual-required-systemd-unit-stale` and elapsed <
#                 backoff (default 3600s).
#   T-throttle-3: should_refresh returns 1 when state shows a recent `ok`
#                 with elapsed < min-interval (default 300s).
#   T-throttle-4: should_refresh returns 0 when state shows `ok` and
#                 elapsed >= min-interval.
#   T-throttle-5: should_refresh returns 0 when state shows a recent
#                 manual-required-* for a DIFFERENT group AND elapsed
#                 >= min-interval (operator created a new isolated agent
#                 whose group is unrelated to the prior failure class).
#
#   T-dispatch-1: poll_and_dispatch on Linux + stale supp-groups writes
#                 the throttle state with status=dispatched + the target
#                 group, AND forks an external worker. The worker is
#                 stubbed (we replace SCRIPT_DIR/bridge-daemon.sh with a
#                 sentinel-writing script) so we observe the dispatch
#                 without running the real helper.
#   T-dispatch-2: poll_and_dispatch is a no-op on macOS (uname gate).
#
#   T-warn-byte-compat: the existing v0.14.5 warning-text shape is
#                 preserved by the wrapper that now delegates to the
#                 data helper — the 1178 smoke wording assertions still
#                 hold.
#
#   T-no-sighup: bridge-daemon.sh's SIGHUP trap still exits cleanly
#                (no setgroups/initgroups path attempted). Lane F MUST
#                NOT have added a SIGHUP-driven refresh path.
#
# Footgun #11: every Python/Bash harness file is built with `printf
# '%s\n' >file` and run as an external script — no `<<<` here-string
# or `<<EOF` heredoc-stdin feeds into subprocess capture.

set -uo pipefail

SMOKE_NAME="F-daemon-supp-groups-mock"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

# Build a PATH-shim directory with controlled `id` / `getent` / `uname`
# implementations. Re-used across detect / dispatch tests.
SHIM_DIR="$SMOKE_TMP_ROOT/shim-bin"
mkdir -p "$SHIM_DIR"

# Linux + stale supp-groups with `ab-agent-iso2` (GID 9001) missing
# from the process supp set.
write_linux_stale_shims() {
  : >"$SHIM_DIR/uname"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo Linux'
  } >>"$SHIM_DIR/uname"
  chmod +x "$SHIM_DIR/uname"

  : >"$SHIM_DIR/id"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '  "-un") echo "patch" ;;'
    printf '%s\n' '  "-G") echo "100 200 300" ;;'
    printf '%s\n' '  "-G patch") echo "100 200 300 9001" ;;'
    printf '%s\n' '  *) echo "id: unsupported invocation: $*" >&2; exit 1 ;;'
    printf '%s\n' 'esac'
  } >>"$SHIM_DIR/id"
  chmod +x "$SHIM_DIR/id"

  : >"$SHIM_DIR/getent"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '  "group 9001") echo "ab-agent-iso2:x:9001:patch" ;;'
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } >>"$SHIM_DIR/getent"
  chmod +x "$SHIM_DIR/getent"
}

# Linux + stale supp-groups where the missing GID is NOT an ab-agent-*
# group — Lane F must ignore it.
write_linux_unrelated_stale_shims() {
  : >"$SHIM_DIR/uname"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo Linux'
  } >>"$SHIM_DIR/uname"
  chmod +x "$SHIM_DIR/uname"

  : >"$SHIM_DIR/id"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '  "-un") echo "patch" ;;'
    printf '%s\n' '  "-G") echo "100 200 300" ;;'
    printf '%s\n' '  "-G patch") echo "100 200 300 42" ;;'
    printf '%s\n' '  *) echo "id: unsupported invocation: $*" >&2; exit 1 ;;'
    printf '%s\n' 'esac'
  } >>"$SHIM_DIR/id"
  chmod +x "$SHIM_DIR/id"

  : >"$SHIM_DIR/getent"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '  "group 42") echo "wheel:x:42:" ;;'
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } >>"$SHIM_DIR/getent"
  chmod +x "$SHIM_DIR/getent"
}

# macOS uname — assert detector and dispatcher early-return.
write_darwin_shims() {
  : >"$SHIM_DIR/uname"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo Darwin'
  } >>"$SHIM_DIR/uname"
  chmod +x "$SHIM_DIR/uname"

  # Defensive id/getent — must not be reached on macOS path.
  : >"$SHIM_DIR/id"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "id: macOS shim must not be reached" >&2'
    printf '%s\n' 'exit 99'
  } >>"$SHIM_DIR/id"
  chmod +x "$SHIM_DIR/id"

  : >"$SHIM_DIR/getent"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "getent: macOS shim must not be reached" >&2'
    printf '%s\n' 'exit 99'
  } >>"$SHIM_DIR/getent"
  chmod +x "$SHIM_DIR/getent"
}

# Extract just the Lane F helpers from bridge-daemon.sh so we can drive
# them in isolation without sourcing bridge-lib.sh (which would pull
# roster + audit + every other init path the daemon needs at runtime).
#
# Captures (in this order so forward references resolve):
#   daemon_warn / daemon_info / daemon_log_event   (used by detector/wrapper)
#   bridge_daemon_detect_stale_supp_groups          (new data helper)
#   bridge_daemon_warn_if_supp_groups_stale         (refactored wrapper)
#   bridge_daemon_supp_group_refresh_throttle_path  (state path)
#   bridge_daemon_supp_group_refresh_throttle_read  (state reader)
#   bridge_daemon_supp_group_refresh_throttle_write (state writer)
#   bridge_daemon_supp_groups_should_refresh        (throttle decision)
#   bridge_daemon_supp_groups_poll_and_dispatch     (main entry)
extract_lane_f_helpers() {
  local source="$REPO_ROOT/bridge-daemon.sh"
  local out="$SMOKE_TMP_ROOT/lane-f-extract.sh"
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    # Stub bridge_audit_log so the helpers can call it without the
    # real audit subsystem. Returns rc=0 silently.
    printf '%s\n' 'bridge_audit_log() { return 0; }'
    awk '/^daemon_log_event\(\) \{/,/^\}/' "$source"
    awk '/^daemon_info\(\) \{/,/^\}/'      "$source"
    awk '/^daemon_warn\(\) \{/,/^\}/'      "$source"
    awk '/^bridge_daemon_detect_stale_supp_groups\(\) \{/,/^\}/'                "$source"
    awk '/^bridge_daemon_warn_if_supp_groups_stale\(\) \{/,/^\}/'               "$source"
    awk '/^bridge_daemon_supp_group_refresh_throttle_path\(\) \{/,/^\}/'        "$source"
    awk '/^bridge_daemon_supp_group_refresh_throttle_read\(\) \{/,/^\}/'        "$source"
    awk '/^bridge_daemon_supp_group_refresh_throttle_write\(\) \{/,/^\}/'       "$source"
    awk '/^bridge_daemon_supp_groups_should_refresh\(\) \{/,/^\}/'              "$source"
    awk '/^bridge_daemon_supp_groups_poll_and_dispatch\(\) \{/,/^\}/'           "$source"
  } >>"$out"
  printf '%s\n' "$out"
}

LANE_F_LIB="$(extract_lane_f_helpers)"
chmod +x "$LANE_F_LIB"

# ---------------------------------------------------------------------------
# T-detect-1: detector emits ab-agent-iso2 when stale.
# ---------------------------------------------------------------------------
write_linux_stale_shims
DETECT1_OUT="$(
  PATH="$SHIM_DIR:$PATH" \
  /usr/bin/env bash -c "source '$LANE_F_LIB'; bridge_daemon_detect_stale_supp_groups" 2>/dev/null
)"
if [[ "$DETECT1_OUT" != *"ab-agent-iso2"* ]]; then
  smoke_fail "T-detect-1: expected detector stdout to contain 'ab-agent-iso2', got: '$DETECT1_OUT'"
fi
smoke_log "T-detect-1 PASS: detector emits ab-agent-iso2 on stale Linux supp set"

# ---------------------------------------------------------------------------
# T-detect-2: detector silent on macOS.
# ---------------------------------------------------------------------------
write_darwin_shims
DETECT2_OUT="$(
  PATH="$SHIM_DIR:$PATH" \
  /usr/bin/env bash -c "source '$LANE_F_LIB'; bridge_daemon_detect_stale_supp_groups" 2>/dev/null
)"
if [[ -n "$DETECT2_OUT" ]]; then
  smoke_fail "T-detect-2: detector must emit nothing on macOS, got: '$DETECT2_OUT'"
fi
smoke_log "T-detect-2 PASS: detector silent on macOS (uname != Linux)"

# ---------------------------------------------------------------------------
# T-detect-3: detector silent when missing group is NOT ab-agent-*.
# ---------------------------------------------------------------------------
write_linux_unrelated_stale_shims
DETECT3_OUT="$(
  PATH="$SHIM_DIR:$PATH" \
  /usr/bin/env bash -c "source '$LANE_F_LIB'; bridge_daemon_detect_stale_supp_groups" 2>/dev/null
)"
if [[ -n "$DETECT3_OUT" ]]; then
  smoke_fail "T-detect-3: detector must ignore non-ab-agent-* missing groups, got: '$DETECT3_OUT'"
fi
smoke_log "T-detect-3 PASS: detector ignores non-ab-agent-* missing GIDs"

# ---------------------------------------------------------------------------
# T-warn-byte-compat: refactored wrapper preserves the v0.14.5 warning text.
# ---------------------------------------------------------------------------
write_linux_stale_shims
WARN_OUT="$(
  PATH="$SHIM_DIR:$PATH" \
  /usr/bin/env bash -c "source '$LANE_F_LIB'; bridge_daemon_warn_if_supp_groups_stale" 2>&1
)"
if [[ "$WARN_OUT" != *"stale"* ]] || [[ "$WARN_OUT" != *"ab-agent-iso2"* ]]; then
  smoke_fail "T-warn-byte-compat: expected stale warning mentioning ab-agent-iso2, got: $WARN_OUT"
fi
if [[ "$WARN_OUT" != *"KNOWN_ISSUES.md"* ]] || [[ "$WARN_OUT" != *"§28"* ]]; then
  smoke_fail "T-warn-byte-compat: expected runbook pointer in warning, got: $WARN_OUT"
fi
smoke_log "T-warn-byte-compat PASS: refactored wrapper preserves v0.14.5 warning text"

# ---------------------------------------------------------------------------
# T-throttle-{1..5}: should_refresh decision matrix.
# ---------------------------------------------------------------------------
# Per-throttle test isolates a fresh BRIDGE_STATE_DIR so prior tests do
# not contaminate the state file path. We exercise should_refresh
# directly against canned state files (no detector / no shims needed —
# pure logic test).
run_throttle_case() {
  local label="$1"
  local now_ts="$2"
  local candidate_group="$3"
  local state_ts="$4"
  local state_status="$5"
  local state_group="$6"
  local expect_rc="$7"

  local case_state_dir="$SMOKE_TMP_ROOT/throttle/$label"
  mkdir -p "$case_state_dir"
  local case_state_file="$case_state_dir/daemon.supp-refresh.state"
  if [[ -n "$state_ts" ]]; then
    {
      printf 'last_attempt_ts=%s\n' "$state_ts"
      printf 'last_status=%s\n'     "$state_status"
      printf 'last_group=%s\n'      "$state_group"
    } >"$case_state_file"
  fi
  local rc=0
  BRIDGE_STATE_DIR="$case_state_dir" \
    /usr/bin/env bash -c \
      "source '$LANE_F_LIB'; bridge_daemon_supp_groups_should_refresh '$now_ts' '$candidate_group'" \
      >/dev/null 2>&1 || rc=$?
  if (( rc != expect_rc )); then
    smoke_fail "$label: expected rc=$expect_rc, got rc=$rc (state_ts=$state_ts state_status=$state_status state_group=$state_group)"
  fi
  smoke_log "$label PASS: rc=$rc"
}

# Fixed reference timestamp for deterministic elapsed math.
NOW=1700000000

# T-throttle-1: no prior state → eligible.
run_throttle_case "T-throttle-1" "$NOW" "ab-agent-iso2" "" "" "" 0

# T-throttle-2: same group + manual-required-* + recent → throttled.
run_throttle_case "T-throttle-2" "$NOW" "ab-agent-iso2" \
  "$((NOW - 60))" "manual-required-systemd-unit-stale" "ab-agent-iso2" 1

# T-throttle-3: ok + within min-interval → throttled.
run_throttle_case "T-throttle-3" "$NOW" "ab-agent-iso2" \
  "$((NOW - 30))" "ok" "ab-agent-iso2" 1

# T-throttle-4: ok + past min-interval → eligible.
run_throttle_case "T-throttle-4" "$NOW" "ab-agent-iso2" \
  "$((NOW - 600))" "ok" "ab-agent-iso2" 0

# T-throttle-5: manual-required-* for a DIFFERENT group + past min-interval
#               (default 300s) but within backoff (default 3600s) → eligible.
run_throttle_case "T-throttle-5" "$NOW" "ab-agent-iso2" \
  "$((NOW - 400))" "manual-required-systemd-unit-stale" "ab-agent-other" 0

# ---------------------------------------------------------------------------
# T-dispatch-1: poll_and_dispatch on Linux+stale → writes state + forks worker.
# ---------------------------------------------------------------------------
# Replace bridge-daemon.sh under a sentinel SCRIPT_DIR so the dispatched
# worker writes a sentinel file we can observe instead of running the
# real refresh. The detector still reads from PATH-shimmed id/getent.

DISPATCH_DIR="$SMOKE_TMP_ROOT/dispatch"
mkdir -p "$DISPATCH_DIR/state" "$DISPATCH_DIR/logs"
DISPATCH_SENTINEL="$DISPATCH_DIR/worker.sentinel"

# Write a fake bridge-daemon.sh that accepts `supp-refresh-worker <grp>`
# and writes the sentinel + a state file mirroring what the real
# worker would.
DISPATCH_SCRIPT="$DISPATCH_DIR/bridge-daemon.sh"
: >"$DISPATCH_SCRIPT"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'verb="${1:-}"; shift || true'
  printf '%s\n' 'case "$verb" in'
  printf '%s\n' '  supp-refresh-worker)'
  printf '%s\n' '    group="${1:-}"'
  printf '%s\n' "    printf '%s\\n' \"called_with_group=\$group\" >>'$DISPATCH_SENTINEL'"
  printf '%s\n' '    exit 0'
  printf '%s\n' '    ;;'
  printf '%s\n' '  *) exit 1 ;;'
  printf '%s\n' 'esac'
} >>"$DISPATCH_SCRIPT"
chmod +x "$DISPATCH_SCRIPT"

write_linux_stale_shims
# Drive poll_and_dispatch with SCRIPT_DIR set to DISPATCH_DIR so the
# detached worker invocation hits our fake script.
BRIDGE_STATE_DIR="$DISPATCH_DIR/state" \
BRIDGE_LOG_DIR="$DISPATCH_DIR/logs" \
PATH="$SHIM_DIR:$PATH" \
  /usr/bin/env bash -c "
    SCRIPT_DIR='$DISPATCH_DIR'
    source '$LANE_F_LIB'
    bridge_daemon_supp_groups_poll_and_dispatch
  " >/dev/null 2>&1 || true

# Wait briefly for the disowned worker to land (filesystem-bound fork).
wait_for_sentinel() {
  local target="$1"
  local tries=20
  local i=0
  while (( i < tries )); do
    [[ -s "$target" ]] && return 0
    sleep 0.1
    i=$(( i + 1 ))
  done
  return 1
}

if ! wait_for_sentinel "$DISPATCH_SENTINEL"; then
  smoke_fail "T-dispatch-1: expected disowned worker to write sentinel '$DISPATCH_SENTINEL' within 2s; missing or empty"
fi

SENTINEL_BODY="$(cat "$DISPATCH_SENTINEL" 2>/dev/null || true)"
if [[ "$SENTINEL_BODY" != *"called_with_group=ab-agent-iso2"* ]]; then
  smoke_fail "T-dispatch-1: expected sentinel to record 'called_with_group=ab-agent-iso2', got: $SENTINEL_BODY"
fi

DISPATCH_STATE_FILE="$DISPATCH_DIR/state/daemon.supp-refresh.state"
if [[ ! -r "$DISPATCH_STATE_FILE" ]]; then
  smoke_fail "T-dispatch-1: expected throttle state at $DISPATCH_STATE_FILE"
fi
DISPATCH_STATE_BODY="$(cat "$DISPATCH_STATE_FILE")"
if [[ "$DISPATCH_STATE_BODY" != *"last_status=dispatched"* ]]; then
  smoke_fail "T-dispatch-1: expected state last_status=dispatched, got: $DISPATCH_STATE_BODY"
fi
if [[ "$DISPATCH_STATE_BODY" != *"last_group=ab-agent-iso2"* ]]; then
  smoke_fail "T-dispatch-1: expected state last_group=ab-agent-iso2, got: $DISPATCH_STATE_BODY"
fi
smoke_log "T-dispatch-1 PASS: poll_and_dispatch writes state + forks detached worker"

# ---------------------------------------------------------------------------
# T-dispatch-2: poll_and_dispatch is a no-op on macOS.
# ---------------------------------------------------------------------------
DISPATCH2_DIR="$SMOKE_TMP_ROOT/dispatch2"
mkdir -p "$DISPATCH2_DIR/state" "$DISPATCH2_DIR/logs"
DISPATCH2_SENTINEL="$DISPATCH2_DIR/worker.sentinel"
DISPATCH2_SCRIPT="$DISPATCH2_DIR/bridge-daemon.sh"
: >"$DISPATCH2_SCRIPT"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "echo macos-worker-must-not-run >'$DISPATCH2_SENTINEL'"
  printf '%s\n' 'exit 0'
} >>"$DISPATCH2_SCRIPT"
chmod +x "$DISPATCH2_SCRIPT"

write_darwin_shims
BRIDGE_STATE_DIR="$DISPATCH2_DIR/state" \
BRIDGE_LOG_DIR="$DISPATCH2_DIR/logs" \
PATH="$SHIM_DIR:$PATH" \
  /usr/bin/env bash -c "
    SCRIPT_DIR='$DISPATCH2_DIR'
    source '$LANE_F_LIB'
    bridge_daemon_supp_groups_poll_and_dispatch
  " >/dev/null 2>&1 || true

sleep 0.5
if [[ -e "$DISPATCH2_SENTINEL" ]]; then
  smoke_fail "T-dispatch-2: macOS path must not fork a worker; sentinel exists: $(cat "$DISPATCH2_SENTINEL" 2>/dev/null)"
fi
if [[ -e "$DISPATCH2_DIR/state/daemon.supp-refresh.state" ]]; then
  smoke_fail "T-dispatch-2: macOS path must not write throttle state"
fi
smoke_log "T-dispatch-2 PASS: poll_and_dispatch no-op on macOS"

# ---------------------------------------------------------------------------
# T-no-sighup: bridge-daemon.sh's SIGHUP trap still exits cleanly.
# ---------------------------------------------------------------------------
# Codex caveat: a running process CANNOT refresh supp groups via SIGHUP/
# setgroups. Lane F must NOT have added a SIGHUP-driven refresh path —
# the daemon's HUP trap must still be the v0.14.5 exit-0 shape. We pin
# this by greping the source for the canonical trap line and asserting
# no `bridge_daemon_refresh_after_group_membership_change` call appears
# inside the SIGHUP handler.
DAEMON_SOURCE="$REPO_ROOT/bridge-daemon.sh"
HUP_TRAP_LINE="$(grep -nE "trap '_bridge_daemon_on_signal HUP" "$DAEMON_SOURCE" | head -n1 || true)"
if [[ -z "$HUP_TRAP_LINE" ]]; then
  smoke_fail "T-no-sighup: expected the v0.14.5 HUP trap line to remain present in bridge-daemon.sh"
fi
HUP_TRAP_BODY="$(grep -E "trap '_bridge_daemon_on_signal HUP" "$DAEMON_SOURCE" | head -n1 || true)"
case "$HUP_TRAP_BODY" in
  *"exit 0"*) : ;;
  *) smoke_fail "T-no-sighup: HUP trap must still terminate with 'exit 0'; got: $HUP_TRAP_BODY" ;;
esac
case "$HUP_TRAP_BODY" in
  *bridge_daemon_refresh_after_group_membership_change*|*supp-refresh-worker*|*setgroups*|*initgroups*)
    smoke_fail "T-no-sighup: HUP trap must not invoke refresh/setgroups/initgroups; got: $HUP_TRAP_BODY"
    ;;
esac
smoke_log "T-no-sighup PASS: SIGHUP trap retains v0.14.5 exit-only shape"

smoke_log "ALL Lane F mock tests passed"
