#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-eta-cron-iso-uid-preflight.sh — Issue #1314 (C8).
#
# v0.15.0-beta5-2 Lane η — CRITICAL/security: bridge-cron-runner.py:481
# raises `RuntimeError("no supported UID drop helper found (sudo or
# setpriv)")` when an iso v2 shell-cron request lands at the runner with
# misconfigured sudoers/setpriv. The RuntimeError is the last-resort seal,
# but no PRE-FLIGHT validation exists at dispatch time. Without pre-flight,
# every cron tick attempts a dispatch that ultimately fails inside the
# runner, producing opaque tracebacks instead of an actionable
# `cron_dispatch_refused` audit row (operator-visible via dashboard /
# audit grep — audit-only, no admin task created; see
# `cron_human_config_drift` follow-up audit).
#
# This smoke pins the two-layer defense added by PR #beta5-2-eta:
#
#   Layer 1 (NEW, dispatch-time): bridge_cron_uid_drop_preflight in
#     lib/bridge-cron.sh validates UID-drop capability before the daemon
#     invokes bridge-cron.sh run-subagent. Refuses dispatch on iso v2 +
#     sudo/setpriv failure with rc=1; passes (rc=0) on non-iso, same-UID,
#     and sudo-OK.
#
#   Layer 2 (KEPT, runner-internal): bridge-cron-runner.py:481 RuntimeError
#     stays untouched. The Python compile check guards the comment block
#     that calls out the two-layer relationship.
#
# Test plan:
#   T1 — iso v2 effective + sudo working → pre-flight returns 0 (proceed).
#   T2 — iso v2 effective + sudo broken → pre-flight returns 1 (refuse).
#   T3 — non-iso agent (effective probe returns 1) → pre-flight returns 0
#        (controller UID execution is expected; no refusal).
#   T4 — TTL cache: repeat T2 invocation within window uses cached rc=1
#        WITHOUT re-running the sudo probe. Then expire TTL and verify a
#        re-probe happens.
#   T5 (teeth) — revert: extract the helper body and assert it contains the
#        EXACT runner argv shape `sudo -n -H -u <user> env -i` so a future
#        PR that loosens the probe (e.g. drops `-H` or `env -i`) trips this
#        check. Also assert the daemon dispatch site contains the
#        `cron_dispatch_refused` audit token + `reason=iso_uid_drop_
#        unavailable` so a refactor that drops the gate is caught.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf '%s\n' ... >>file` lines AND plain `cat >file <<EOF` bodies on
# flat strings — no command substitution feeding a heredoc stdin, no `<<<`
# here-strings into bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (the lib helper bodies
# `source` from lib/bridge-cron.sh require them via the larger lib stack).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:beta5-2-eta-cron-iso-uid-preflight] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="beta5-2-eta-cron-iso-uid-preflight"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap EXIT below
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
CRON_LIB="$REPO_ROOT/lib/bridge-cron.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
RUNNER_PY="$REPO_ROOT/bridge-cron-runner.py"

smoke_assert_file_exists "$CRON_LIB" "lib/bridge-cron.sh present"
smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"
smoke_assert_file_exists "$RUNNER_PY" "bridge-cron-runner.py present"

# ---------------------------------------------------------------------
# Build a self-contained driver that sources just the helper definitions
# (extracted via awk) and stubs the iso-effective / os_user predicates.
# This keeps the smoke insulated from the full bridge-lib bootstrap.
# ---------------------------------------------------------------------
DRIVER="$SMOKE_TMP_ROOT/driver.sh"
EXTRACT="$SMOKE_TMP_ROOT/helper-fns.sh"

# Extract three helper bodies + the cache-file/cache-dir helpers + the
# safe-component helper they depend on. We pull the exact `function() {` to
# next `^}` slice for each. Doing this via awk keeps the smoke aligned to
# the live source — any rename/move trips T5 grep below.
{
  awk '
    /^bridge_cron_uid_drop_cache_dir\(\) \{/,/^\}/ { print }
  ' "$CRON_LIB"
  awk '
    /^bridge_cron_uid_drop_cache_file\(\) \{/,/^\}/ { print }
  ' "$CRON_LIB"
  awk '
    /^bridge_cron_uid_drop_preflight\(\) \{/,/^\}/ { print }
  ' "$CRON_LIB"
  awk '
    /^bridge_cron_safe_component\(\) \{/,/^\}/ { print }
  ' "$CRON_LIB"
} >"$EXTRACT"

# Sanity: each extract block must be non-empty AND contain the closing brace
# (otherwise awk silently emitted just the opener and the eval would syntax-
# fail at runtime).
for fn in bridge_cron_uid_drop_cache_dir bridge_cron_uid_drop_cache_file bridge_cron_uid_drop_preflight bridge_cron_safe_component; do
  if ! grep -q "^${fn}() {" "$EXTRACT"; then
    smoke_fail "extract missing ${fn}() opener"
  fi
done

# bridge_cron_safe_component delegates to a python helper via
# bridge_cron_helper_python, but the cache-file path is a stable
# alphanumeric agent name in this smoke (no shell metacharacters), so we
# stub bridge_cron_safe_component to identity.
SAFE_STUB="$SMOKE_TMP_ROOT/safe-stub.sh"
cat >"$SAFE_STUB" <<'EOF'
bridge_cron_safe_component() {
  # Identity stub for smoke — input agent names are alphanumeric.
  printf '%s' "$1"
}
EOF

# Build the driver.
cat >"$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$1"
EXTRACT="$2"
SAFE_STUB="$3"
AGENT="$4"
CACHE_ROOT="$5"
FORCE="${6:-0}"

# Stub 1: bridge_agent_linux_user_isolation_effective reads
# $SMOKE_ISO_EFFECTIVE. 1=iso effective, 0=non-iso.
bridge_agent_linux_user_isolation_effective() {
  [[ "${SMOKE_ISO_EFFECTIVE:-0}" == "1" ]] && return 0
  return 1
}

# Stub 2: bridge_agent_os_user reads $SMOKE_OS_USER.
bridge_agent_os_user() {
  printf '%s' "${SMOKE_OS_USER:-}"
}

# BRIDGE_CRON_STATE_DIR drives the cache root.
export BRIDGE_CRON_STATE_DIR="$CACHE_ROOT"

# BRIDGE_BASH_BIN: anchor to the running bash so the helper's sudo probe
# reaches a real interpreter. The sudo shim (below in PATH) wraps it.
export BRIDGE_BASH_BIN="$(command -v bash)"

# shellcheck source=/dev/null
source "$EXTRACT"

# Stub identity safe-component AFTER the extract so it overrides the real
# definition (which would invoke bridge_cron_helper_python and silently
# return empty in the smoke's stub-only environment).
# shellcheck source=/dev/null
source "$SAFE_STUB"

# Force=1 bypasses the TTL cache (smoke T4 reuses with force=0 to test
# cache hit, then force=1 to test bypass).
bridge_cron_uid_drop_preflight "$AGENT" "$FORCE"
rc=$?
echo "RC=$rc"
exit "$rc"
DRIVER_EOF
chmod +x "$DRIVER"

# ---------------------------------------------------------------------
# Build a PATH shim with a controllable `sudo`. The real `id` stays on
# PATH so the same-UID short-circuit works against actual `id -u` calls.
# `sudo` honors:
#   $SMOKE_SUDO_RESULT — 0 (success) or 1 (denial), default 1.
# ---------------------------------------------------------------------
FAKE_BIN="$SMOKE_TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
FAKE_SUDO="$FAKE_BIN/sudo"
SUDO_CALL_LOG="$SMOKE_TMP_ROOT/sudo-calls.log"

cat >"$FAKE_SUDO" <<'SUDO_EOF'
#!/usr/bin/env bash
# Fake sudo. Records argv into $SMOKE_SUDO_CALL_LOG (if set), exits
# according to $SMOKE_SUDO_RESULT (default 1 — passwordless sudo refused).
if [[ -n "${SMOKE_SUDO_CALL_LOG:-}" ]]; then
  printf '%s\0' "$@" >>"$SMOKE_SUDO_CALL_LOG"
  printf '\n' >>"$SMOKE_SUDO_CALL_LOG"
fi
exit "${SMOKE_SUDO_RESULT:-1}"
SUDO_EOF
chmod +x "$FAKE_SUDO"

# ---------------------------------------------------------------------
# Helper: invoke the driver with the desired stub config.
# Args: <test-label> <iso_effective> <os_user> <sudo_result> <expect_rc>
#       [force=0|1]
# ---------------------------------------------------------------------
T_CACHE_ROOT="$SMOKE_TMP_ROOT/cache"
mkdir -p "$T_CACHE_ROOT"
T_AGENT="smoketestagent"

invoke_driver() {
  local label="$1"
  local iso_effective="$2"
  local os_user="$3"
  local sudo_result="$4"
  local expect_rc="$5"
  local force="${6:-0}"
  local out
  local rc=0

  : >"$SUDO_CALL_LOG"
  PATH="$FAKE_BIN:$PATH" \
    SMOKE_ISO_EFFECTIVE="$iso_effective" \
    SMOKE_OS_USER="$os_user" \
    SMOKE_SUDO_RESULT="$sudo_result" \
    SMOKE_SUDO_CALL_LOG="$SUDO_CALL_LOG" \
    "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$EXTRACT" "$SAFE_STUB" \
      "$T_AGENT" "$T_CACHE_ROOT" "$force" \
    2>"$SMOKE_TMP_ROOT/${label}.err" || rc=$?
  out="$(cat "$SMOKE_TMP_ROOT/${label}.err" 2>/dev/null || true)"
  if [[ "$rc" -ne "$expect_rc" ]]; then
    smoke_fail "${label}: expected rc=${expect_rc}, got rc=${rc} (stderr=${out})"
  fi
  smoke_log "${label} PASS (rc=${rc})"
}

# Resolve BRIDGE_BASH for driver invocations.
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]]; then
      BRIDGE_BASH="$_candidate"
      break
    fi
  done
fi

# Pick an os_user that is GUARANTEED to differ from the current UID, so
# the same-UID short-circuit (bridge-cron-runner.py:473) does NOT mask
# the sudo-probe arm. `id -u "root"` ≠ current UID unless the smoke is
# running as root, which our pre-check below rejects.
CURRENT_UN="$(id -un 2>/dev/null || printf '')"
CURRENT_UID="$(id -u 2>/dev/null || printf '')"
T_OS_USER="root"
if [[ "$CURRENT_UN" == "root" || "$CURRENT_UID" == "0" ]]; then
  # If the smoke happens to run as root, pick `nobody` instead — guaranteed
  # to exist on Linux/macOS and to differ from root's UID.
  T_OS_USER="nobody"
fi
# Confirm target user exists; if neither root nor nobody is queryable
# (which would be exotic), bail with a clear skip-style message.
if ! id -u "$T_OS_USER" >/dev/null 2>&1; then
  smoke_log "SKIP: host has no '$T_OS_USER' user for same-UID-differs probe"
  exit 0
fi

# Confirm same-UID divergence so T1/T2 actually exercise the sudo arm.
TARGET_UID="$(id -u "$T_OS_USER" 2>/dev/null || printf '')"
if [[ "$TARGET_UID" == "$CURRENT_UID" ]]; then
  smoke_log "SKIP: target os_user '$T_OS_USER' (uid=$TARGET_UID) equals current UID — same-UID short-circuit would mask the probe"
  exit 0
fi

# ---------------------------------------------------------------------
# T1 — iso effective + sudo working → rc=0 (proceed).
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T1-iso-sudo-ok" "1" "$T_OS_USER" "0" "0"
# Confirm cache file was created with the success result (rc=0).
T1_CACHE="$T_CACHE_ROOT/preflight-uid-drop/$T_AGENT.cache"
smoke_assert_file_exists "$T1_CACHE" "T1 cache file written"
if ! grep -qE $'^[0-9]+\t0$' "$T1_CACHE"; then
  smoke_fail "T1: cache file should record '<expires>\t0', got: $(cat "$T1_CACHE")"
fi

# ---------------------------------------------------------------------
# T2 — iso effective + sudo broken → rc=1 (refuse).
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T2-iso-sudo-broken" "1" "$T_OS_USER" "1" "1"
# Confirm the sudo argv shape recorded matches the EXACT runner shape:
# sudo -n -H -u <os_user> env -i HOME=/tmp <bash_bin> -c 'exit 0'
# (the call log is null-delimited; convert and check for the key flags).
if [[ ! -s "$SUDO_CALL_LOG" ]]; then
  smoke_fail "T2: expected sudo to be invoked but call log is empty"
fi
sudo_argv_txt="$(tr '\0' ' ' <"$SUDO_CALL_LOG")"
case "$sudo_argv_txt" in
  *"-n"*"-H"*"-u "*"$T_OS_USER"*" env "*"-i"*)
    smoke_log "T2: sudo argv shape matches runner expectations"
    ;;
  *)
    smoke_fail "T2: sudo argv does NOT match runner shape ('-n -H -u <user> env -i'). Got: $sudo_argv_txt"
    ;;
esac
T2_CACHE="$T_CACHE_ROOT/preflight-uid-drop/$T_AGENT.cache"
smoke_assert_file_exists "$T2_CACHE" "T2 cache file written"
if ! grep -qE $'^[0-9]+\t1$' "$T2_CACHE"; then
  smoke_fail "T2: cache file should record '<expires>\t1', got: $(cat "$T2_CACHE")"
fi

# ---------------------------------------------------------------------
# T3 — non-iso agent → rc=0 (proceed, no probe required).
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T3-non-iso" "0" "$T_OS_USER" "1" "0"
# Confirm sudo was NOT invoked (short-circuit before probe).
if [[ -s "$SUDO_CALL_LOG" ]]; then
  smoke_fail "T3: non-iso path must NOT invoke sudo, but call log is non-empty: $(tr '\0' ' ' <"$SUDO_CALL_LOG")"
fi
# Confirm NO cache file was written (no result to cache for short-circuit).
T3_CACHE="$T_CACHE_ROOT/preflight-uid-drop/$T_AGENT.cache"
if [[ -f "$T3_CACHE" ]]; then
  smoke_fail "T3: non-iso path must NOT write cache file, but $T3_CACHE exists"
fi

# ---------------------------------------------------------------------
# T4 — TTL cache. Two scenarios:
#   T4a: repeat T2 invocation with force=0 — should use cached rc=1
#        WITHOUT re-invoking sudo.
#   T4b: expire the cache (rewrite with past timestamp) — should re-probe
#        and re-invoke sudo.
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
# First call: populate cache (sudo broken → rc=1).
invoke_driver "T4-seed" "1" "$T_OS_USER" "1" "1"
T4_CACHE="$T_CACHE_ROOT/preflight-uid-drop/$T_AGENT.cache"
smoke_assert_file_exists "$T4_CACHE" "T4 seed cache present"
seed_sudo_size="$(wc -c <"$SUDO_CALL_LOG" | tr -d ' ')"

# T4a — second call should hit the cache and NOT invoke sudo again.
: >"$SUDO_CALL_LOG"
invoke_driver "T4a-cache-hit" "1" "$T_OS_USER" "1" "1"
if [[ -s "$SUDO_CALL_LOG" ]]; then
  smoke_fail "T4a: cache hit MUST NOT re-invoke sudo, but call log is non-empty: $(tr '\0' ' ' <"$SUDO_CALL_LOG")"
fi

# T4b — expire the cache by rewriting the timestamp to a past epoch, then
# re-invoke (force=0) and confirm sudo WAS invoked (cache miss).
printf '%s\t%s\n' "1" "1" >"$T4_CACHE"  # expires=1 (1970) — definitely past
: >"$SUDO_CALL_LOG"
invoke_driver "T4b-cache-expired" "1" "$T_OS_USER" "1" "1"
if [[ ! -s "$SUDO_CALL_LOG" ]]; then
  smoke_fail "T4b: expired cache MUST re-probe sudo, but call log is empty"
fi

# T4c (force) — force=1 bypasses the cache even when fresh.
# Reset cache to a fresh "success" so a NORMAL call (force=0) would short-
# circuit via cache and NOT invoke sudo. Then call with force=1 and confirm
# sudo IS invoked.
future_ts=$(( $(date +%s) + 86400 ))
printf '%s\t%s\n' "$future_ts" "0" >"$T4_CACHE"
: >"$SUDO_CALL_LOG"
# We pass force=1 + sudo_result=0 (sudo will succeed when probed). Expect
# rc=0 (sudo OK) AND sudo IS invoked.
invoke_driver "T4c-force-bypass" "1" "$T_OS_USER" "0" "0" "1"
if [[ ! -s "$SUDO_CALL_LOG" ]]; then
  smoke_fail "T4c: force=1 MUST bypass cache and re-probe sudo, but call log is empty"
fi

# ---------------------------------------------------------------------
# T5 (teeth) — assert the EXACT runner argv shape lives in the helper,
# AND that the dispatch site emits cron_dispatch_refused with the
# iso_uid_drop_unavailable reason. A future PR that loosens the probe
# shape OR drops the gate fails here.
# ---------------------------------------------------------------------
# T5.1 — helper preserves the runner-mirroring sudo invocation.
if ! grep -E 'sudo -n -H -u "?\$os_user"? env -i' "$CRON_LIB" >/dev/null; then
  smoke_fail "T5.1: lib/bridge-cron.sh must contain the exact runner sudo shape ('sudo -n -H -u \$os_user env -i')"
fi

# T5.2 — runner-internal seal (RuntimeError) is INTACT.
if ! grep -E 'no supported UID drop helper found \(sudo or setpriv\)' "$RUNNER_PY" >/dev/null; then
  smoke_fail "T5.2: bridge-cron-runner.py RuntimeError seal must remain intact"
fi

# T5.3 — dispatch site emits the new audit row.
if ! grep -E 'cron_dispatch_refused' "$DAEMON_SH" >/dev/null; then
  smoke_fail "T5.3: bridge-daemon.sh must emit 'cron_dispatch_refused' audit row at dispatch time"
fi
if ! grep -E 'reason=iso_uid_drop_unavailable' "$DAEMON_SH" >/dev/null; then
  smoke_fail "T5.3b: bridge-daemon.sh must emit 'reason=iso_uid_drop_unavailable' detail on refusal"
fi

# T5.4 — dispatch site gates on CRON_PAYLOAD_KIND == "shell" so agentTurn
# is never refused by this pre-flight (agentTurn does not hit the runner's
# UID-drop construction; gating prevents false-positive refusals).
if ! grep -E 'CRON_PAYLOAD_KIND.*==.*"shell"|"shell".*==.*CRON_PAYLOAD_KIND' "$DAEMON_SH" >/dev/null; then
  smoke_fail "T5.4: bridge-daemon.sh must gate pre-flight on CRON_PAYLOAD_KIND==\"shell\""
fi

# T5.5 — load-run-shell.py surfaces CRON_PAYLOAD_KIND.
LOAD_RUN_SHELL="$REPO_ROOT/lib/cron-helpers/load-run-shell.py"
smoke_assert_file_exists "$LOAD_RUN_SHELL" "T5.5: load-run-shell helper present"
if ! grep -E 'CRON_PAYLOAD_KIND' "$LOAD_RUN_SHELL" >/dev/null; then
  smoke_fail "T5.5: lib/cron-helpers/load-run-shell.py must surface CRON_PAYLOAD_KIND"
fi

smoke_log "ALL TESTS PASS"
exit 0
