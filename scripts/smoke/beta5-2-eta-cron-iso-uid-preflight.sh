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

# Stub 3: lie about `command -v setpriv` based on $SMOKE_SETPRIV_PRESENT.
# The host may have a real /usr/bin/setpriv (Linux CI does) which would
# otherwise leak into the "setpriv missing" test arm. By overriding the
# `command` builtin here we decouple the test from host setpriv install
# state. All other `command -v <X>` calls (e.g. `command -v sudo`) fall
# through to the bash builtin via `builtin command`.
command() {
  if [[ "${1:-}" == "-v" && "${2:-}" == "setpriv" ]]; then
    if [[ "${SMOKE_SETPRIV_PRESENT:-0}" == "1" ]]; then
      printf '%s\n' "${SMOKE_FAKE_SETPRIV_PATH:-/usr/bin/setpriv}"
      return 0
    fi
    return 1
  fi
  builtin command "$@"
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
# Build a PATH shim with a controllable `sudo` AND optional `setpriv`.
# The real `id` stays on PATH so the same-UID short-circuit works against
# actual `id -u` calls.
#
# `sudo` honors:
#   $SMOKE_SUDO_RESULT — 0 (success) or 1 (denial), default 1.
# `setpriv` honors:
#   $SMOKE_SETPRIV_RESULT — 0 (success) or 1, default 0.
#
# The setpriv shim is created lazily on demand: tests that want
# "setpriv present" call `enable_fake_setpriv`; tests that want
# "setpriv missing" use a PATH that excludes the fake bin entirely (we
# use a separate `FAKE_BIN_SUDO_ONLY` directory which only has sudo).
# ---------------------------------------------------------------------
FAKE_BIN="$SMOKE_TMP_ROOT/fake-bin"
FAKE_BIN_SUDO_ONLY="$SMOKE_TMP_ROOT/fake-bin-sudo-only"
mkdir -p "$FAKE_BIN" "$FAKE_BIN_SUDO_ONLY"
FAKE_SUDO="$FAKE_BIN/sudo"
FAKE_SUDO_SO="$FAKE_BIN_SUDO_ONLY/sudo"
FAKE_SETPRIV="$FAKE_BIN/setpriv"
SUDO_CALL_LOG="$SMOKE_TMP_ROOT/sudo-calls.log"
SETPRIV_CALL_LOG="$SMOKE_TMP_ROOT/setpriv-calls.log"

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
cp "$FAKE_SUDO" "$FAKE_SUDO_SO"

cat >"$FAKE_SETPRIV" <<'SETPRIV_EOF'
#!/usr/bin/env bash
# Fake setpriv. Records argv into $SMOKE_SETPRIV_CALL_LOG (if set), exits
# according to $SMOKE_SETPRIV_RESULT (default 0 — succeeds).
if [[ -n "${SMOKE_SETPRIV_CALL_LOG:-}" ]]; then
  printf '%s\0' "$@" >>"$SMOKE_SETPRIV_CALL_LOG"
  printf '\n' >>"$SMOKE_SETPRIV_CALL_LOG"
fi
exit "${SMOKE_SETPRIV_RESULT:-0}"
SETPRIV_EOF
chmod +x "$FAKE_SETPRIV"

# ---------------------------------------------------------------------
# Helper: invoke the driver with the desired stub config.
# Args: <test-label> <iso_effective> <os_user> <sudo_result> <expect_rc>
#       [force=0|1] [setpriv_present=0|1] [use_setpriv_flag=""|"0"|"1"]
#
# When setpriv_present=1, the FAKE_BIN PATH (which has both sudo+setpriv)
# is used; when 0, FAKE_BIN_SUDO_ONLY (sudo only) is used. The
# use_setpriv_flag value is exported as BRIDGE_CRON_USE_SETPRIV — empty
# string means "do not export at all" (unset).
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
  local setpriv_present="${7:-0}"
  local use_setpriv_flag="${8:-}"
  local out
  local rc=0
  local fake_bin_dir="$FAKE_BIN_SUDO_ONLY"

  if [[ "$setpriv_present" == "1" ]]; then
    fake_bin_dir="$FAKE_BIN"
  fi

  : >"$SUDO_CALL_LOG"
  : >"$SETPRIV_CALL_LOG"

  # Build env command piecewise so we can conditionally include
  # BRIDGE_CRON_USE_SETPRIV (or omit it to test the unset case). The
  # driver also overrides `command -v setpriv` to respect
  # $SMOKE_SETPRIV_PRESENT — that decouples the test from whether the
  # host has a real /usr/bin/setpriv installed (Linux CI typically does).
  local -a env_args=(
    "PATH=$fake_bin_dir:$PATH"
    "SMOKE_ISO_EFFECTIVE=$iso_effective"
    "SMOKE_OS_USER=$os_user"
    "SMOKE_SUDO_RESULT=$sudo_result"
    "SMOKE_SUDO_CALL_LOG=$SUDO_CALL_LOG"
    "SMOKE_SETPRIV_CALL_LOG=$SETPRIV_CALL_LOG"
    "SMOKE_SETPRIV_PRESENT=$setpriv_present"
  )
  if [[ -n "$use_setpriv_flag" ]]; then
    env_args+=("BRIDGE_CRON_USE_SETPRIV=$use_setpriv_flag")
  fi

  env -u BRIDGE_CRON_USE_SETPRIV "${env_args[@]}" \
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

# Cache file naming includes a flag suffix: <agent>.setpriv<0|1>.cache.
# All cache assertions in T1-T4 use the .setpriv0.cache slot (flag absent
# from env). T7-T9 exercise the .setpriv1.cache slot.
T_CACHE_FLAG0_PATH="$T_CACHE_ROOT/preflight-uid-drop/$T_AGENT.setpriv0.cache"
T_CACHE_FLAG1_PATH="$T_CACHE_ROOT/preflight-uid-drop/$T_AGENT.setpriv1.cache"

# ---------------------------------------------------------------------
# T1 — iso effective + sudo working → rc=0 (proceed).
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T1-iso-sudo-ok" "1" "$T_OS_USER" "0" "0"
# Confirm cache file was created with the success result (rc=0).
T1_CACHE="$T_CACHE_FLAG0_PATH"
smoke_assert_file_exists "$T1_CACHE" "T1 cache file written"
if ! grep -qE $'^[0-9]+\t0$' "$T1_CACHE"; then
  smoke_fail "T1: cache file should record '<expires>\t0', got: $(cat "$T1_CACHE")"
fi

# ---------------------------------------------------------------------
# T2 — iso effective + sudo broken (no setpriv) → rc=1 (refuse).
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
T2_CACHE="$T_CACHE_FLAG0_PATH"
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
if [[ -f "$T_CACHE_FLAG0_PATH" || -f "$T_CACHE_FLAG1_PATH" ]]; then
  smoke_fail "T3: non-iso path must NOT write cache file (flag0/flag1 slots both empty)"
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
T4_CACHE="$T_CACHE_FLAG0_PATH"
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
# T6 — flag contract: iso + sudo-broken + setpriv-PRESENT + flag ABSENT
#      → refuse (setpriv ignored without opt-in).
#      Codex r1 BLOCKING: brief said BRIDGE_CRON_USE_SETPRIV, impl used a
#      different name → flag did nothing. T6 catches a regression where
#      the flag check is removed or the name drifts again.
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T6-flag-absent-setpriv-present" "1" "$T_OS_USER" "1" "1" "0" "1" ""
T6_CACHE="$T_CACHE_FLAG0_PATH"
smoke_assert_file_exists "$T6_CACHE" "T6 cache file written (flag-0 slot)"
if ! grep -qE $'^[0-9]+\t1$' "$T6_CACHE"; then
  smoke_fail "T6: cache should record rc=1 (refuse) when flag absent, got: $(cat "$T6_CACHE")"
fi

# ---------------------------------------------------------------------
# T7 — flag contract: iso + sudo-broken + setpriv-PRESENT + flag=1
#      → ALLOW (operator opted in, fallback eligible).
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T7-flag1-setpriv-present" "1" "$T_OS_USER" "1" "0" "0" "1" "1"
T7_CACHE="$T_CACHE_FLAG1_PATH"
smoke_assert_file_exists "$T7_CACHE" "T7 cache file written (flag-1 slot)"
if ! grep -qE $'^[0-9]+\t0$' "$T7_CACHE"; then
  smoke_fail "T7: cache should record rc=0 (allow) when flag=1 + setpriv present, got: $(cat "$T7_CACHE")"
fi

# ---------------------------------------------------------------------
# T8 — runner consistency: with flag ABSENT + sudo missing/broken,
#      shell_command_for_execution must raise RuntimeError. We invoke
#      the runner's command-builder helper directly through Python.
# ---------------------------------------------------------------------
T8_OUT="$SMOKE_TMP_ROOT/T8.out"
T8_ERR="$SMOKE_TMP_ROOT/T8.err"
# Compose a Python harness that imports the runner and calls
# shell_command_for_execution with a synthetic cross-UID execution.
# Use a clean PATH (no sudo, no setpriv) to force the RuntimeError arm.
# /usr/bin/env, python3, and the python stdlib are reached via absolute
# python3 path so the empty PATH does not break the interpreter startup.
PY_BIN="$(command -v python3 || true)"
if [[ -z "$PY_BIN" ]]; then
  smoke_fail "T8: python3 not on host PATH; cannot drive runner consistency check"
fi
T8_HARNESS="$SMOKE_TMP_ROOT/t8_harness.py"
{
  printf '%s\n' "import importlib.util, os, sys"
  printf '%s\n' "spec = importlib.util.spec_from_file_location('bcr', '$REPO_ROOT/bridge-cron-runner.py')"
  printf '%s\n' "mod = importlib.util.module_from_spec(spec)"
  printf '%s\n' "spec.loader.exec_module(mod)"
  printf '%s\n' "current_uid = os.geteuid()"
  printf '%s\n' "synthetic_uid = current_uid + 1000  # ensure cross-UID branch"
  printf '%s\n' "execution = {'os_user': 'nobody', 'uid': synthetic_uid, 'gid': synthetic_uid}"
  printf '%s\n' "try:"
  printf '%s\n' "    mod.shell_command_for_execution(execution, {}, '/bin/true', [])"
  printf '%s\n' "except RuntimeError as e:"
  printf '%s\n' "    print('GOT_RUNTIME_ERROR', str(e))"
  printf '%s\n' "    sys.exit(0)"
  printf '%s\n' "print('NO_ERROR')"
  printf '%s\n' "sys.exit(1)"
} >"$T8_HARNESS"

# Strip sudo + setpriv from PATH; force BRIDGE_CRON_USE_SETPRIV absent.
# Use PATH= (empty) — python's `shutil.which` returns None for both.
if env -u BRIDGE_CRON_USE_SETPRIV PATH="" "$PY_BIN" "$T8_HARNESS" >"$T8_OUT" 2>"$T8_ERR"; then
  if grep -q '^GOT_RUNTIME_ERROR' "$T8_OUT"; then
    smoke_log "T8: runner raises RuntimeError when flag absent + sudo/setpriv missing"
  else
    smoke_fail "T8: expected GOT_RUNTIME_ERROR, got: $(cat "$T8_OUT") (stderr: $(cat "$T8_ERR"))"
  fi
else
  smoke_fail "T8: harness exit non-zero — stdout=$(cat "$T8_OUT") stderr=$(cat "$T8_ERR")"
fi

# ---------------------------------------------------------------------
# T9 — runner consistency: with flag=1 + setpriv present + sudo absent,
#      shell_command_for_execution must return the setpriv command
#      (NOT raise). We use a real `/usr/bin/setpriv` on Linux, or fall
#      back to a shim on PATH for macOS.
# ---------------------------------------------------------------------
T9_OUT="$SMOKE_TMP_ROOT/T9.out"
T9_ERR="$SMOKE_TMP_ROOT/T9.err"
T9_PATH_DIR="$SMOKE_TMP_ROOT/t9-bin"
mkdir -p "$T9_PATH_DIR"
# Provide a no-op `setpriv` (the helper only does shutil.which, not exec).
cat >"$T9_PATH_DIR/setpriv" <<'T9SP_EOF'
#!/usr/bin/env bash
exit 0
T9SP_EOF
chmod +x "$T9_PATH_DIR/setpriv"
T9_HARNESS="$SMOKE_TMP_ROOT/t9_harness.py"
{
  printf '%s\n' "import importlib.util, os, sys"
  printf '%s\n' "spec = importlib.util.spec_from_file_location('bcr', '$REPO_ROOT/bridge-cron-runner.py')"
  printf '%s\n' "mod = importlib.util.module_from_spec(spec)"
  printf '%s\n' "spec.loader.exec_module(mod)"
  printf '%s\n' "current_uid = os.geteuid()"
  printf '%s\n' "synthetic_uid = current_uid + 1000"
  printf '%s\n' "execution = {'os_user': 'nobody', 'uid': synthetic_uid, 'gid': synthetic_uid}"
  printf '%s\n' "cmd = mod.shell_command_for_execution(execution, {}, '/bin/true', [])"
  printf '%s\n' "print('COMMAND', cmd[0])"
} >"$T9_HARNESS"

# PATH has ONLY t9-bin → setpriv present, sudo absent. flag=1.
if env BRIDGE_CRON_USE_SETPRIV=1 PATH="$T9_PATH_DIR" "$PY_BIN" "$T9_HARNESS" >"$T9_OUT" 2>"$T9_ERR"; then
  cmd0="$(awk '/^COMMAND/ { print $2 }' "$T9_OUT")"
  case "$cmd0" in
    */setpriv|setpriv)
      smoke_log "T9: runner selects setpriv with flag=1 + setpriv present + sudo absent"
      ;;
    *)
      smoke_fail "T9: expected setpriv command, got: $(cat "$T9_OUT") (stderr: $(cat "$T9_ERR"))"
      ;;
  esac
else
  smoke_fail "T9: harness exit non-zero — stdout=$(cat "$T9_OUT") stderr=$(cat "$T9_ERR")"
fi

# ---------------------------------------------------------------------
# T_EDGE_1 — BRIDGE_CRON_USE_SETPRIV=0 explicitly behaves like unset.
#            iso + sudo-broken + setpriv-present + flag=0 → refuse.
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T_EDGE_1-flag-explicit-0" "1" "$T_OS_USER" "1" "1" "0" "1" "0"
T_EDGE_1_CACHE="$T_CACHE_FLAG0_PATH"
smoke_assert_file_exists "$T_EDGE_1_CACHE" "T_EDGE_1 cache file written (flag-0 slot)"
if ! grep -qE $'^[0-9]+\t1$' "$T_EDGE_1_CACHE"; then
  smoke_fail "T_EDGE_1: explicit flag=0 should refuse like unset, got cache: $(cat "$T_EDGE_1_CACHE")"
fi

# ---------------------------------------------------------------------
# T_EDGE_2 — setpriv MISSING + flag=1 → still refuse (cannot opt into a
#            tool that does not exist on the host).
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T_EDGE_2-flag1-setpriv-missing" "1" "$T_OS_USER" "1" "1" "0" "0" "1"
T_EDGE_2_CACHE="$T_CACHE_FLAG1_PATH"
smoke_assert_file_exists "$T_EDGE_2_CACHE" "T_EDGE_2 cache file written (flag-1 slot)"
if ! grep -qE $'^[0-9]+\t1$' "$T_EDGE_2_CACHE"; then
  smoke_fail "T_EDGE_2: flag=1 + setpriv missing should refuse, got cache: $(cat "$T_EDGE_2_CACHE")"
fi

# ---------------------------------------------------------------------
# T_EDGE_3 — sudo OK + setpriv-PRESENT + flag=1 → sudo wins (canonical
#            iso v2 path). The runner ALSO prefers sudo over setpriv;
#            preflight must match.
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
invoke_driver "T_EDGE_3-sudo-and-setpriv" "1" "$T_OS_USER" "0" "0" "0" "1" "1"
# Sudo must have been invoked (probe ran); setpriv must NOT have been
# invoked (preflight only `command -v`s it; the helper does not exec).
if [[ ! -s "$SUDO_CALL_LOG" ]]; then
  smoke_fail "T_EDGE_3: sudo MUST be probed when sudo OK + setpriv present"
fi
if [[ -s "$SETPRIV_CALL_LOG" ]]; then
  smoke_fail "T_EDGE_3: setpriv MUST NOT be invoked when sudo wins"
fi
# Cache should record rc=0 (allow) under flag-1 slot.
T_EDGE_3_CACHE="$T_CACHE_FLAG1_PATH"
smoke_assert_file_exists "$T_EDGE_3_CACHE" "T_EDGE_3 cache (flag-1 slot)"
if ! grep -qE $'^[0-9]+\t0$' "$T_EDGE_3_CACHE"; then
  smoke_fail "T_EDGE_3: cache should record rc=0 when sudo wins, got: $(cat "$T_EDGE_3_CACHE")"
fi

# Verify the runner ALSO selects sudo (not setpriv) for the same shape.
T_EDGE_3_OUT="$SMOKE_TMP_ROOT/T_EDGE_3.out"
T_EDGE_3_ERR="$SMOKE_TMP_ROOT/T_EDGE_3.err"
T_EDGE_3_BIN="$SMOKE_TMP_ROOT/t_edge_3-bin"
mkdir -p "$T_EDGE_3_BIN"
cat >"$T_EDGE_3_BIN/sudo" <<'TE3_SUDO_EOF'
#!/usr/bin/env bash
exit 0
TE3_SUDO_EOF
chmod +x "$T_EDGE_3_BIN/sudo"
cat >"$T_EDGE_3_BIN/setpriv" <<'TE3_SP_EOF'
#!/usr/bin/env bash
exit 0
TE3_SP_EOF
chmod +x "$T_EDGE_3_BIN/setpriv"
T_EDGE_3_HARNESS="$SMOKE_TMP_ROOT/t_edge_3_harness.py"
{
  printf '%s\n' "import importlib.util, os, sys"
  printf '%s\n' "spec = importlib.util.spec_from_file_location('bcr', '$REPO_ROOT/bridge-cron-runner.py')"
  printf '%s\n' "mod = importlib.util.module_from_spec(spec)"
  printf '%s\n' "spec.loader.exec_module(mod)"
  printf '%s\n' "current_uid = os.geteuid()"
  printf '%s\n' "synthetic_uid = current_uid + 1000"
  printf '%s\n' "execution = {'os_user': 'nobody', 'uid': synthetic_uid, 'gid': synthetic_uid}"
  printf '%s\n' "cmd = mod.shell_command_for_execution(execution, {}, '/bin/true', [])"
  printf '%s\n' "print('COMMAND', cmd[0])"
} >"$T_EDGE_3_HARNESS"
if env BRIDGE_CRON_USE_SETPRIV=1 PATH="$T_EDGE_3_BIN" "$PY_BIN" "$T_EDGE_3_HARNESS" >"$T_EDGE_3_OUT" 2>"$T_EDGE_3_ERR"; then
  cmd0="$(awk '/^COMMAND/ { print $2 }' "$T_EDGE_3_OUT")"
  case "$cmd0" in
    */sudo|sudo)
      smoke_log "T_EDGE_3: runner selects sudo when both sudo+setpriv present + flag=1 (matches preflight)"
      ;;
    *)
      smoke_fail "T_EDGE_3: runner did NOT prefer sudo over setpriv: got $cmd0"
      ;;
  esac
else
  smoke_fail "T_EDGE_3 runner harness exit non-zero: $(cat "$T_EDGE_3_ERR")"
fi

# ---------------------------------------------------------------------
# T_EDGE_4 — cache TTL flag-key. Same agent, two different flag values
#            → two distinct cache files; toggling the flag does NOT
#            serve the wrong-policy decision.
# ---------------------------------------------------------------------
rm -rf "$T_CACHE_ROOT"
mkdir -p "$T_CACHE_ROOT"
# Seed flag-absent + sudo-broken + setpriv-present → refuse (cache 1).
invoke_driver "T_EDGE_4a-seed-flag-absent" "1" "$T_OS_USER" "1" "1" "0" "1" ""
smoke_assert_file_exists "$T_CACHE_FLAG0_PATH" "T_EDGE_4a flag-0 cache present"
# Now invoke with flag=1 + setpriv-present + sudo-broken → ALLOW (cache 0).
invoke_driver "T_EDGE_4b-toggle-flag1" "1" "$T_OS_USER" "1" "0" "0" "1" "1"
smoke_assert_file_exists "$T_CACHE_FLAG1_PATH" "T_EDGE_4b flag-1 cache present"
# Verify each cache slot records its own policy outcome.
if ! grep -qE $'^[0-9]+\t1$' "$T_CACHE_FLAG0_PATH"; then
  smoke_fail "T_EDGE_4: flag-0 slot should still record rc=1 (refuse), got: $(cat "$T_CACHE_FLAG0_PATH")"
fi
if ! grep -qE $'^[0-9]+\t0$' "$T_CACHE_FLAG1_PATH"; then
  smoke_fail "T_EDGE_4: flag-1 slot should record rc=0 (allow), got: $(cat "$T_CACHE_FLAG1_PATH")"
fi
smoke_log "T_EDGE_4: cache flag-key isolation works"

# ---------------------------------------------------------------------
# T_TEETH_FLAG — revert-detector: assert the helper actually GATES on
#      BRIDGE_CRON_USE_SETPRIV (not the old name nor an ungated auto-
#      select). If a future PR drops the gate, this test fails.
# ---------------------------------------------------------------------
if ! grep -E '\$\{?BRIDGE_CRON_USE_SETPRIV(:-[01])?\}?' "$CRON_LIB" >/dev/null; then
  smoke_fail "T_TEETH_FLAG.1: lib/bridge-cron.sh must reference BRIDGE_CRON_USE_SETPRIV (opt-in flag gate)"
fi
if grep -E 'BRIDGE_CRON_UID_DROP_PREFLIGHT_SETPRIV_OK' "$CRON_LIB" >/dev/null; then
  smoke_fail "T_TEETH_FLAG.2: lib/bridge-cron.sh must NOT reference the legacy BRIDGE_CRON_UID_DROP_PREFLIGHT_SETPRIV_OK name (r1 BLOCKING)"
fi
if ! grep -E 'BRIDGE_CRON_USE_SETPRIV' "$RUNNER_PY" >/dev/null; then
  smoke_fail "T_TEETH_FLAG.3: bridge-cron-runner.py must gate setpriv arm on BRIDGE_CRON_USE_SETPRIV"
fi

# ---------------------------------------------------------------------
# T_TEETH_COMMENT — comment correction: dispatch site comment block
#      MUST say "audit-only" (NOT "admin task created").
# ---------------------------------------------------------------------
# Grep for the corrected comment phrasing. A future PR that re-introduces
# the inaccurate "admin task" claim trips here.
if grep -nE 'admin task instead of' "$DAEMON_SH" >/dev/null; then
  smoke_fail "T_TEETH_COMMENT.1: bridge-daemon.sh comment still claims an admin task is created on refusal (R2 SHOULD-FIX regression)"
fi
if grep -nE 'admin task with an actionable repro' "$RUNNER_PY" >/dev/null; then
  smoke_fail "T_TEETH_COMMENT.2: bridge-cron-runner.py comment still claims an admin task is created on refusal (R2 SHOULD-FIX regression)"
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
