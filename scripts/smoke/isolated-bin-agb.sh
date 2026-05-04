#!/usr/bin/env bash
# scripts/smoke/isolated-bin-agb.sh — Issue #544 PR1 smoke.
#
# Validates the curated bin/agb shim that lets isolated agents call `agb`
# bare from a Bash tool subprocess. Three assertions:
#
# 1. The shim auto-sources BRIDGE_AGENT_ENV_FILE before delegating, so
#    flags emitted into the env file (BRIDGE_GATEWAY_PROXY=1, custom
#    BRIDGE_TASK_DB, peer-id arrays, etc.) reach the resulting agb
#    invocation even from a fresh non-login subshell.
# 2. The shim exec's the underlying ${BRIDGE_HOME}/agb script, not some
#    other agb on PATH.
# 3. The shim exits non-zero (bubbled from the underlying agb) when the
#    delegate fails — i.e. it doesn't swallow the exit code.

set -euo pipefail

SMOKE_NAME="isolated-bin-agb"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"
  FIXTURE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  mkdir -p "$FIXTURE_HOME/bin"
  # Copy the real shim from the source tree we're testing.
  cp "$SMOKE_REPO_ROOT/bin/agb" "$FIXTURE_HOME/bin/agb"
  chmod +x "$FIXTURE_HOME/bin/agb"

  # Stand in a stub root agb that just records its env + argv to a file
  # so we can introspect what the shim handed it. The real
  # ${BRIDGE_HOME}/agb just exec's agent-bridge; for this smoke we only
  # care that the shim delegates to *this* path with the env preserved.
  STUB_LOG="$SMOKE_TMP_ROOT/stub-agb.log"
  cat >"$FIXTURE_HOME/agb" <<EOF
#!/usr/bin/env bash
{
  printf 'argv:%s\n' "\$*"
  printf 'BRIDGE_HOME=%s\n' "\${BRIDGE_HOME:-<unset>}"
  printf 'BRIDGE_GATEWAY_PROXY=%s\n' "\${BRIDGE_GATEWAY_PROXY:-<unset>}"
  printf 'TEST_ENV_MARKER=%s\n' "\${TEST_ENV_MARKER:-<unset>}"
  printf 'STUB_AGB_PATH=%s\n' "\$0"
} >>"$STUB_LOG"
exit "\${STUB_EXIT_CODE:-0}"
EOF
  chmod +x "$FIXTURE_HOME/agb"

  # Fixture env file the shim must auto-source. Mirrors the shape
  # bridge_write_linux_agent_env_file emits for isolated agents.
  AGENT_ENV_FILE="$FIXTURE_HOME/agent-env.sh"
  cat >"$AGENT_ENV_FILE" <<EOF
export BRIDGE_HOME="$FIXTURE_HOME"
export BRIDGE_GATEWAY_PROXY=1
export TEST_ENV_MARKER=isolated-bin-agb-smoke
EOF
  chmod 600 "$AGENT_ENV_FILE"
}

assert_shim_sources_env_and_delegates() {
  : >"$STUB_LOG"
  # Run the shim from a fresh subshell that has BRIDGE_AGENT_ENV_FILE set
  # but no BRIDGE_HOME / BRIDGE_GATEWAY_PROXY / TEST_ENV_MARKER — the shim
  # must source the env file to get them.
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$SMOKE_TMP_ROOT" \
    BRIDGE_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
    bash "$FIXTURE_HOME/bin/agb" smoke-arg-1 smoke-arg-2

  smoke_assert_file_exists "$STUB_LOG" "stub agb invocation log written"
  local out
  out="$(cat "$STUB_LOG")"
  smoke_assert_contains "$out" "argv:smoke-arg-1 smoke-arg-2" \
    "shim forwards positional arguments verbatim"
  smoke_assert_contains "$out" "BRIDGE_HOME=$FIXTURE_HOME" \
    "shim exports BRIDGE_HOME from the sourced env file"
  smoke_assert_contains "$out" "BRIDGE_GATEWAY_PROXY=1" \
    "shim propagates BRIDGE_GATEWAY_PROXY=1 from the env file"
  smoke_assert_contains "$out" "TEST_ENV_MARKER=isolated-bin-agb-smoke" \
    "shim sources arbitrary env-file exports"
  smoke_assert_contains "$out" "STUB_AGB_PATH=$FIXTURE_HOME/agb" \
    "shim exec's the underlying \${BRIDGE_HOME}/agb (not some PATH lookup)"
}

assert_shim_works_without_env_file() {
  : >"$STUB_LOG"
  # When BRIDGE_AGENT_ENV_FILE is unset (operator-side invocation, no
  # isolation), the shim must still exec the underlying agb. BRIDGE_HOME
  # falls back to the shim's own ../ directory.
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$SMOKE_TMP_ROOT" \
    bash "$FIXTURE_HOME/bin/agb" plain-arg

  smoke_assert_file_exists "$STUB_LOG" "stub agb log written for env-less invocation"
  local out
  out="$(cat "$STUB_LOG")"
  smoke_assert_contains "$out" "argv:plain-arg" \
    "shim forwards args even with no env file present"
  smoke_assert_contains "$out" "BRIDGE_HOME=$FIXTURE_HOME" \
    "shim derives BRIDGE_HOME from its own location when env unset"
  smoke_assert_contains "$out" "STUB_AGB_PATH=$FIXTURE_HOME/agb" \
    "shim still delegates to the sibling agb when env unset"
}

assert_shim_propagates_exit_code() {
  : >"$STUB_LOG"
  local rc=0
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$SMOKE_TMP_ROOT" \
    BRIDGE_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
    STUB_EXIT_CODE=42 \
    bash "$FIXTURE_HOME/bin/agb" failing-call \
    || rc=$?
  smoke_assert_eq "42" "$rc" \
    "shim propagates underlying agb exit code (no swallow)"
}

main() {
  build_fixture

  smoke_run "shim sources env file and delegates" \
    assert_shim_sources_env_and_delegates
  smoke_run "shim works without env file" \
    assert_shim_works_without_env_file
  smoke_run "shim propagates exit code" \
    assert_shim_propagates_exit_code

  smoke_log "PASS"
}

main "$@"
