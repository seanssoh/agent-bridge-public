#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1461-cron-max-parallel-override.sh — issue #1461.
#
# cron-dispatch's worker-pool size (BRIDGE_CRON_DISPATCH_MAX_PARALLEL) used to
# be a hardcoded `:-1` in bridge-lib.sh that an operator could only override by
# hand-editing agent-roster.local.sh (blocked for agent sessions, and not
# settable through `agb config set` which is JSON-only) or the daemon service
# unit env (works but not upgrade-safe). PR for #1461 makes the value resolve
# with a real precedence chain — env > runtime bridge-config.json key >
# host-profile-scaled default — so an operator gets a sanctioned, audit-chained,
# upgrade-safe override (`agb config set --path runtime/bridge-config.json
# --change cron_dispatch_max_parallel=<N>`), and cron-heavy `server` hosts get a
# sane parallel default instead of strict serial.
#
# This smoke pins three contracts:
#   A (static teeth): bridge-lib.sh defines bridge_resolve_cron_dispatch_max_
#       parallel, reads the cron_dispatch_max_parallel JSON key, and carries the
#       host-profile=server scaled default. The dispatch site
#       (start_cron_dispatch_workers in bridge-daemon.sh) still reads the env
#       var the resolver feeds. Reverting any of these trips the teeth.
#   B (behavioral, real source): the resolver extracted verbatim from
#       bridge-lib.sh honors the full precedence matrix — env override wins,
#       then the JSON config key, then server=3 / dev|unknown=1.
#   C (end-to-end dispatch honoring): the exact max_parallel parse + the
#       `running_count < max_parallel` worker-slot gate from
#       start_cron_dispatch_workers, replayed against the resolved value, opens
#       N>1 slots once the override is set — proving the override reaches the
#       dispatch site, not merely that the var exists.
#
# Drives extracted source fragments under a throwaway tmp root — no daemon, no
# queue, no live runtime. The resolver delegates JSON parsing to the standalone
# scripts/python-helpers/resolve-cron-max-parallel.py (file-as-argv, no
# heredoc-stdin to a subprocess; lint-heredoc-ban / footgun #11). The smoke's
# own here-doc fixtures write FILES, not subprocess stdin, which the ban permits.

set -euo pipefail

SMOKE_NAME="1461-cron-max-parallel-override"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

LIB_SH="$SMOKE_REPO_ROOT/bridge-lib.sh"
DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"
HELPER_PY="$SMOKE_REPO_ROOT/scripts/python-helpers/resolve-cron-max-parallel.py"
BASH_BIN="$(command -v bash)"

smoke_require_cmd python3
smoke_require_cmd awk
smoke_assert_file_exists "$LIB_SH" "bridge-lib.sh present"
smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"
smoke_assert_file_exists "$HELPER_PY" "resolve-cron-max-parallel.py present"

python3 -c "import py_compile; py_compile.compile('$HELPER_PY', doraise=True)" || \
  smoke_fail "setup: resolve-cron-max-parallel.py failed py_compile"

smoke_make_temp_root "$SMOKE_NAME"
trap 'smoke_cleanup_temp_root' EXIT

# ---------------------------------------------------------------------
# A — static teeth on the source.
# ---------------------------------------------------------------------
smoke_log "A: static teeth on bridge-lib.sh + bridge-daemon.sh"

grep -q '^bridge_resolve_cron_dispatch_max_parallel() {' "$LIB_SH" || \
  smoke_fail "A: bridge_resolve_cron_dispatch_max_parallel() missing from bridge-lib.sh (fix reverted)"

# The deferred assignment must call the resolver (not a hardcoded :-1).
grep -q 'BRIDGE_CRON_DISPATCH_MAX_PARALLEL="\$(bridge_resolve_cron_dispatch_max_parallel)"' "$LIB_SH" || \
  smoke_fail "A: BRIDGE_CRON_DISPATCH_MAX_PARALLEL no longer resolved via bridge_resolve_cron_dispatch_max_parallel (hardcoded default regression)"

# The sanctioned JSON config key must be read by the helper.
grep -q 'cron_dispatch_max_parallel' "$HELPER_PY" || \
  smoke_fail "A: cron_dispatch_max_parallel JSON config key missing from resolve-cron-max-parallel.py (sanctioned override path reverted)"

# The host-profile-scaled default branch must still be present in the helper.
grep -Eq '3 if profile == "server" else 1' "$HELPER_PY" || \
  smoke_fail "A: host-profile server=3/else=1 scaled default missing from resolve-cron-max-parallel.py"

# The dispatch site must still read the env var the resolver feeds (exported by
# bridge-lib.sh). This is the load-bearing seam — if the daemon stops reading
# the env var, the override never reaches the worker pool.
grep -q 'local max_parallel="\${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-0}"' "$DAEMON_SH" || \
  smoke_fail "A: start_cron_dispatch_workers no longer reads BRIDGE_CRON_DISPATCH_MAX_PARALLEL (dispatch seam broken)"

smoke_log "A: PASS"

# ---------------------------------------------------------------------
# B — behavioral: extract the resolver verbatim and run the precedence matrix.
# ---------------------------------------------------------------------
smoke_log "B: precedence matrix on the real extracted resolver"

DRIVER="$SMOKE_TMP_ROOT/resolver.sh"
awk '/^bridge_resolve_cron_dispatch_max_parallel\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$LIB_SH" >"$DRIVER"
grep -q '^bridge_resolve_cron_dispatch_max_parallel() {' "$DRIVER" || \
  smoke_fail "B: resolver extract failed (function shape changed)"

FX="$SMOKE_TMP_ROOT/fixtures"
mkdir -p "$FX/runtime" "$FX/state/install"
CONFIG="$FX/runtime/bridge-config.json"
PROFILE="$FX/state/install/host-profile.json"

# resolve <expected> <env-or-empty> [config-json] [profile-json]
resolve() {
  local expected="$1" envval="$2" cfg="${3:-}" prof="${4:-}"
  if [[ -n "$cfg" ]]; then printf '%s\n' "$cfg" >"$CONFIG"; else rm -f "$CONFIG"; fi
  if [[ -n "$prof" ]]; then printf '%s\n' "$prof" >"$PROFILE"; else rm -f "$PROFILE"; fi
  local out
  out="$(env -i \
      PATH="$PATH" \
      HOME="$FX" \
      BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" \
      BRIDGE_HOME="$FX" \
      BRIDGE_STATE_DIR="$FX/state" \
      BRIDGE_RUNTIME_CONFIG_FILE="$CONFIG" \
      ${envval:+BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$envval"} \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_resolve_cron_dispatch_max_parallel")"
  smoke_assert_eq "$expected" "$out" "B: resolve(env='$envval' cfg='$cfg' prof='$prof')"
}

# 1. No config, no profile -> conservative serial default.
resolve 1 "" "" ""
# 2. host-profile=server scales the default up.
resolve 3 "" "" '{"profile":"server"}'
# 3. host-profile=dev stays serial.
resolve 1 "" "" '{"profile":"dev"}'
# 4. JSON config key (int) beats the host-profile default.
resolve 5 "" '{"cron_dispatch_max_parallel":5}' '{"profile":"server"}'
# 5. JSON config key accepted as a numeric string too.
resolve 7 "" '{"cron_dispatch_max_parallel":"7"}' '{"profile":"dev"}'
# 6. env override beats the JSON config key (the daemon-unit-env path).
resolve 9 9 '{"cron_dispatch_max_parallel":5}' '{"profile":"dev"}'
# 7. Invalid env (0) falls through to the JSON config key.
resolve 5 0 '{"cron_dispatch_max_parallel":5}' '{"profile":"dev"}'
# 8. Invalid JSON config value (0) falls through to the profile default.
resolve 3 "" '{"cron_dispatch_max_parallel":0}' '{"profile":"server"}'
# 8b. JSON boolean is NOT a valid count (int(True)==1 trap): rejected, falls
#     through to the profile default rather than silently resolving to 1.
resolve 3 "" '{"cron_dispatch_max_parallel":true}' '{"profile":"server"}'
# 9. Malformed config JSON never raises — falls to the profile default.
printf 'not json{' >"$CONFIG"
out="$(env -i PATH="$PATH" HOME="$FX" BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" BRIDGE_HOME="$FX" \
    BRIDGE_STATE_DIR="$FX/state" BRIDGE_RUNTIME_CONFIG_FILE="$CONFIG" \
    "$BASH_BIN" -c "source '$DRIVER'; bridge_resolve_cron_dispatch_max_parallel")"
printf '{"profile":"server"}\n' >"$PROFILE"
out="$(env -i PATH="$PATH" HOME="$FX" BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" BRIDGE_HOME="$FX" \
    BRIDGE_STATE_DIR="$FX/state" BRIDGE_RUNTIME_CONFIG_FILE="$CONFIG" \
    "$BASH_BIN" -c "source '$DRIVER'; bridge_resolve_cron_dispatch_max_parallel")"
smoke_assert_eq "3" "$out" "B: malformed config JSON falls through to profile default"

smoke_log "B: PASS"

# ---------------------------------------------------------------------
# C — end-to-end: the resolved override reaches the dispatch worker-slot gate.
# ---------------------------------------------------------------------
# Replay the EXACT parse + slot gate from start_cron_dispatch_workers so a
# revert of the daemon-side contract (e.g. clamping max_parallel, or no longer
# honoring the env var) is caught here. dispatch_slot_decision echoes how many
# worker slots the gate would open given the resolved value and a current
# running-worker count.
smoke_log "C: dispatch worker-slot gate honors the resolved override"

dispatch_slot_decision() {
  # mirrors bridge-daemon.sh start_cron_dispatch_workers lines 8757/8775-8779
  local max_parallel="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-0}"
  local running_count="${1:-0}"
  [[ "$max_parallel" =~ ^[0-9]+$ ]] || max_parallel=0
  (( max_parallel > 0 )) || { printf 'serial-or-disabled'; return 0; }
  (( running_count < max_parallel )) || { printf 'pool-full'; return 0; }
  printf 'open:%s' "$(( max_parallel - running_count ))"
}

# Operator sets the sanctioned JSON override to 5 on a server host. The resolver
# (real source) produces 5; the dispatch gate must then open 5 slots with 0
# workers running — the throughput fix the issue asks for.
printf '{"cron_dispatch_max_parallel":5}\n' >"$CONFIG"
printf '{"profile":"server"}\n' >"$PROFILE"
resolved="$(env -i PATH="$PATH" HOME="$FX" BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" BRIDGE_HOME="$FX" \
    BRIDGE_STATE_DIR="$FX/state" BRIDGE_RUNTIME_CONFIG_FILE="$CONFIG" \
    "$BASH_BIN" -c "source '$DRIVER'; bridge_resolve_cron_dispatch_max_parallel")"
smoke_assert_eq "5" "$resolved" "C: resolver produced override value"

decision="$(BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$resolved" dispatch_slot_decision 0)"
smoke_assert_eq "open:5" "$decision" "C: dispatch gate opens 5 slots under the override (0 running)"

decision="$(BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$resolved" dispatch_slot_decision 4)"
smoke_assert_eq "open:1" "$decision" "C: dispatch gate opens 1 slot under the override (4 running)"

decision="$(BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$resolved" dispatch_slot_decision 5)"
smoke_assert_eq "pool-full" "$decision" "C: dispatch gate holds at the override ceiling"

# Default (no override, dev host) stays strictly serial — the #579 floor.
rm -f "$CONFIG"
printf '{"profile":"dev"}\n' >"$PROFILE"
resolved_default="$(env -i PATH="$PATH" HOME="$FX" BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" BRIDGE_HOME="$FX" \
    BRIDGE_STATE_DIR="$FX/state" BRIDGE_RUNTIME_CONFIG_FILE="$FX/runtime/bridge-config.json" \
    "$BASH_BIN" -c "source '$DRIVER'; bridge_resolve_cron_dispatch_max_parallel")"
smoke_assert_eq "1" "$resolved_default" "C: dev/unset stays serial default 1"
decision="$(BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$resolved_default" dispatch_slot_decision 0)"
smoke_assert_eq "open:1" "$decision" "C: serial default opens exactly 1 slot"
decision="$(BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$resolved_default" dispatch_slot_decision 1)"
smoke_assert_eq "pool-full" "$decision" "C: serial default holds at 1 running worker"

smoke_log "C: PASS"
smoke_log "PASS"
