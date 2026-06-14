#!/usr/bin/env bash
# scripts/smoke/1899-dynamic-vanilla-codex-v2-secret-env-repin.sh
#
# #1899 PR #1901 Phase-4 BLOCKING — the v2 secret-env launch path must NOT leak
# a per-agent CODEX_HOME into a dynamic vanilla Codex child, and (unlike the
# #1900 CLAUDE_CONFIG_DIR case) must RE-PIN the operator-global value.
#
# Root cause the reviewer reproduced at PR head 4bed692e: on a v2-active host,
# bridge-run.sh selects credentials/launch-secrets.env for ANY v2-active agent
# and runs bridge_isolation_v2_exec_with_secret_env BEFORE the shared-launch
# branch. bridge_run_export_codex_launch_env pins HOME/CODEX_HOME in the PARENT,
# but the v2 loader runs AFTER that and exports launch-secrets.env rows verbatim.
# A stale file carrying a per-agent CODEX_HOME (left from a prior managed-Codex
# config) re-pointed the dynamic Codex child away from the operator-global
# ~/.codex the #1899 contract requires.
#
# Why scrub-alone is insufficient (the #1900 fix could just unset
# CLAUDE_CONFIG_DIR — falling back to operator-global ~/.claude — but Codex has
# no such fallback): CODEX_HOME / HOME must be SET to the operator values, not
# merely unset. So the fix SCRUBS the stale row AND RE-PINS the operator values
# inside the loader+exec subshell (after the loader, before exec).
#
# This smoke drives the EXACT PRODUCTION helper
# bridge_isolation_v2_exec_with_secret_env (the wrapper after the parent export,
# which the existing 1899-dynamic-vanilla-codex smoke does NOT exercise):
#   A CONTROL (no scrub, no re-pin = static/admin path): the loader exports the
#     secrets-file CODEX_HOME and the child INHERITS it -> proves the leak real.
#   B FIX (scrub HOME/CODEX_HOME + re-pin operator values = dynamic-vanilla path):
#     the child sees CODEX_HOME=<operator_home>/.codex, NOT the secret-env value.
#   C SCOPE (managed-Codex scrub-only, no re-pin): CODEX_HOME is scrubbed and the
#     child sees it ABSENT -> the re-pin is class-scoped to dynamic-vanilla, not
#     a blanket break of the managed path (which keeps its own CODEX_HOME via the
#     managed launch env, unaffected by this re-pin).
#
# Isolation: temp BRIDGE_HOME; secrets file under SMOKE_TMP_ROOT at mode 0640
# (the loader refuses anything broader). Footgun #11: plain printf fixtures only.

set -euo pipefail

SMOKE_NAME="1899-dynamic-vanilla-codex-v2-secret-env-repin"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
PRIVATE_CODEX_HOME="$SMOKE_TMP_ROOT/agent-home/.codex"
SECRET_FILE="$SMOKE_TMP_ROOT/launch-secrets.env"  # noqa: iso-helper-boundary  (controller-only test fixture path, not a runtime boundary RW)
ERRFILE="$SMOKE_TMP_ROOT/errfile.log"
OUTFILE="$SMOKE_TMP_ROOT/child-out.log"
mkdir -p "$OPERATOR_HOME/.codex" "$PRIVATE_CODEX_HOME"
: >"$ERRFILE"

EXPECTED_OPERATOR_CODEX_HOME="$OPERATOR_HOME/.codex"

# Stale (non-secret) per-agent CODEX_HOME pointer in the launch-secrets.env —
# the exact leftover shape the reviewer reproduced. Mode 0640: the loader
# refuses anything broader (group-write / world-read).
printf 'CODEX_HOME=%s\n' "$PRIVATE_CODEX_HOME" >"$SECRET_FILE"
chmod 0640 "$SECRET_FILE"

# eval_exec — source the lib, then drive the PRODUCTION exec helper with the
# given scrub-key list and re-pin pairs. The launch cmd writes the child's
# inherited CODEX_HOME (or the literal ABSENT) to OUTFILE so the parent can
# assert on it independently of the helper's own rc handling.
#   $1 scrub_keys   space-separated env var NAMES to unset post-loader
#   $2 repin_pairs  newline-separated KEY=VALUE to export post-scrub
eval_exec() {
  local scrub_keys="$1"
  local repin_pairs="$2"
  : >"$OUTFILE"
  env -u CODEX_HOME "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    BRIDGE_ISOLATION_V2_LAST_EXEC_RC=0
    launch_cmd='printf \"%s\\n\" \"\${CODEX_HOME:-ABSENT}\" > '\"'$OUTFILE'\"
    bridge_isolation_v2_exec_with_secret_env \
      '$SECRET_FILE' '$BASH4_BIN' \"\$launch_cmd\" '$ERRFILE' 'dynv-codex' \"$scrub_keys\" \"$repin_pairs\"
    printf 'EXEC_RC=%s\n' \"\$BRIDGE_ISOLATION_V2_LAST_EXEC_RC\"
  "
}

# ===========================================================================
# A — CONTROL (no scrub, no re-pin; the static/admin path): the loader exports
# the secrets file's CODEX_HOME and the child INHERITS it. Proves the leak is
# real and the fixture faithful (load-bearing leak control).
# ===========================================================================
test_a_control_inherits() {
  eval_exec "" "" >/dev/null 2>&1 || smoke_fail "A control exec failed"
  local got; got="$(cat "$OUTFILE" 2>/dev/null || true)"
  smoke_assert_eq "$PRIVATE_CODEX_HOME" "$got" \
    "A CONTROL (no scrub/re-pin): child inherits the secrets-file CODEX_HOME (leak is real)"
}

# ===========================================================================
# B — dynamic-vanilla fix (scrub HOME/CODEX_HOME + re-pin operator values): the
# child sees the operator-global CODEX_HOME, NOT the secret-env value. This is
# the BLOCKING fix — scrub clears the stale row, re-pin SETS the operator value.
# ===========================================================================
test_b_dynamic_repinned() {
  eval_exec "HOME CODEX_HOME" \
    "$(printf 'HOME=%s\nCODEX_HOME=%s' "$OPERATOR_HOME" "$EXPECTED_OPERATOR_CODEX_HOME")" \
    >/dev/null 2>&1 || smoke_fail "B re-pin exec failed"
  local got; got="$(cat "$OUTFILE" 2>/dev/null || true)"
  smoke_assert_eq "$EXPECTED_OPERATOR_CODEX_HOME" "$got" \
    "B dynamic-vanilla scrub+re-pin: child sees operator CODEX_HOME, NOT the secret-env value"
}

# ===========================================================================
# C — SCOPE: the managed-Codex scrub list (no re-pin) still scrubs CODEX_HOME so
# the child sees it ABSENT — proving the re-pin is class-scoped to dynamic
# vanilla, not a blanket override. (A managed Codex agent keeps its CODEX_HOME
# via the managed launch env, unaffected by this dynamic-vanilla re-pin path.)
# ===========================================================================
test_c_managed_scrub_no_repin() {
  eval_exec "OPENAI_API_KEY CODEX_ACCESS_TOKEN CODEX_HOME" "" >/dev/null 2>&1 \
    || smoke_fail "C managed exec failed"
  local got; got="$(cat "$OUTFILE" 2>/dev/null || true)"
  smoke_assert_eq "ABSENT" "$got" \
    "C managed scrub list (no re-pin): CODEX_HOME scrubbed -> ABSENT (re-pin is dynamic-vanilla-scoped)"
}

# --- run ------------------------------------------------------------------
smoke_run "A control: no scrub/re-pin -> child inherits CODEX_HOME (leak real)" test_a_control_inherits
smoke_run "B dynamic-vanilla scrub+re-pin -> child sees operator CODEX_HOME" test_b_dynamic_repinned
smoke_run "C managed scrub-only -> CODEX_HOME ABSENT (re-pin class-scoped)" test_c_managed_scrub_no_repin

smoke_log "PASS — #1899 BLOCKING: the v2 secret-env exec helper scrubs AND re-pins HOME/CODEX_HOME for the dynamic vanilla Codex case so the child runs against operator-global ~/.codex; static/admin + managed Codex paths unaffected"
