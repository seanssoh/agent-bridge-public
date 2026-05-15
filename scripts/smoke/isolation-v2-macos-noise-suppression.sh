#!/usr/bin/env bash
# S2 regression smoke — macOS isolation-v2 noise suppression.
#
# Reproduces the operator-visible blocker on Sean's mac (v0.13.10 audit
# B17 / C-S1):
#   `[경고] write_agent_state_marker: ensure_matrix_path failed for
#    agent=... marker=idle-since`
#
# Root cause: on Darwin the isolation-v2 enforcement primitives (POSIX
# setgid groups, `agent-bridge-*` OS users) are not the security model;
# the upgrade flow does not create them. But `ensure_matrix_path` /
# `apply_row` would still run the chown/chmod path and fail loudly,
# spamming the warning log on every daemon state-marker write.
#
# Fix (lib/bridge-isolation-v2.sh): both functions now return 0 silently
# on Darwin. This smoke is the regression guard.
#
# Coverage (Darwin-only):
#   T1 — ensure_matrix_path returns 0 on Darwin without invoking the
#        matrix lookup or emitting warnings.
#   T2 — apply_row with mechanism=group_setgid returns 0 on Darwin
#        without invoking chown/chmod.
#
# On Linux this smoke skip-passes (the gates don't engage and the
# normal v2 enforcement path runs — that's covered by other smokes).

set -uo pipefail

SMOKE_NAME="isolation-v2-macos-noise-suppression"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

if [[ "$(uname -s 2>/dev/null || printf '')" != "Darwin" ]]; then
  smoke_log "non-Darwin host; this smoke is a Darwin-only regression guard — PASS (skipped)"
  exit 0
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ -x /opt/homebrew/bin/bash ]]; then
  BRIDGE_BASH=/opt/homebrew/bin/bash
elif [[ -x /usr/local/bin/bash ]]; then
  BRIDGE_BASH=/usr/local/bin/bash
fi

run_isolation_call() {
  # Invoke a v2 helper in a clean subshell and capture stdout+stderr.
  # Args: $1 = call snippet, $2 = out_file
  local snippet="$1"
  local out_file="$2"
  local driver="$SMOKE_TMP_ROOT/driver-$$.sh"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_HOME=%q\n' "$SMOKE_TMP_ROOT/bh"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$SMOKE_TMP_ROOT/bh/state"
    printf 'export BRIDGE_LAYOUT=v2\n'
    printf 'export BRIDGE_DATA_ROOT=%q\n' "$SMOKE_TMP_ROOT/bh/data"
    printf 'export BRIDGE_LAYOUT_RESOLVER_BYPASS_NONCE=smoke-noise\n'
    printf '%s\n' 'mkdir -p "$BRIDGE_HOME/state" "$BRIDGE_DATA_ROOT"'
    printf '%s\n' 'source "$0_REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
    printf '%s\n' "$snippet"
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$driver"
  chmod +x "$driver"

  "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1
  local rc=$?
  rm -f "$driver"
  return $rc
}

# T1 — ensure_matrix_path on Darwin returns 0 silently.
smoke_log "T1: ensure_matrix_path Darwin no-op"
T1_OUT="$SMOKE_TMP_ROOT/t1.out"
run_isolation_call \
  'bridge_isolation_v2_ensure_matrix_path state-agent-dir testagent; echo "RC=$?"' \
  "$T1_OUT" || true

if ! grep -q '^RC=0$' "$T1_OUT"; then
  smoke_log "T1 output:"; cat "$T1_OUT"
  smoke_fail "T1: ensure_matrix_path did not return 0 on Darwin"
fi
if grep -qE 'ensure_matrix_path.*(failed|not found|required)' "$T1_OUT"; then
  smoke_log "T1 output:"; cat "$T1_OUT"
  smoke_fail "T1: ensure_matrix_path emitted a warning on Darwin (must be silent no-op)"
fi
smoke_log "T1 PASS"

# T2 — apply_row group_setgid on Darwin returns 0 silently without chown/chmod.
smoke_log "T2: apply_row group_setgid Darwin no-op"
T2_OUT="$SMOKE_TMP_ROOT/t2.out"
T2_PATH="$SMOKE_TMP_ROOT/t2-target-dir"
run_isolation_call \
  "mkdir -p \"$T2_PATH\"; bridge_isolation_v2_apply_row apply test-row \"$T2_PATH\" dir root ab-shared 2750 0640 1 group_setgid required; echo \"RC=\$?\"" \
  "$T2_OUT" || true

if ! grep -q '^RC=0$' "$T2_OUT"; then
  smoke_log "T2 output:"; cat "$T2_OUT"
  smoke_fail "T2: apply_row group_setgid did not return 0 on Darwin"
fi
if grep -qE 'chown:|chmod:|operation not permitted|cannot resolve|unknown grant' "$T2_OUT"; then
  smoke_log "T2 output:"; cat "$T2_OUT"
  smoke_fail "T2: apply_row group_setgid invoked chown/chmod (must be silent no-op on Darwin)"
fi
smoke_log "T2 PASS"

smoke_log "PASS — macOS noise suppression intact"
exit 0
