#!/usr/bin/env bash
# scripts/smoke/1900-dynamic-vanilla-v2-secret-env-scrub.sh
#
# #1890 / PR #1900 Phase-4 BLOCKING 2 — the v2 secret-env launch path must NOT
# leak a per-agent CLAUDE_CONFIG_DIR into a dynamic vanilla Claude child.
#
# Root cause the reviewer reproduced: on a v2-active host, bridge-run.sh selects
# credentials/launch-secrets.env for ANY v2-active agent when the file exists and
# runs bridge_isolation_v2_exec_with_secret_env BEFORE the shared-launch branch.
# That secrets file may carry a (non-secret) CLAUDE_CONFIG_DIR pointer left over
# from a prior managed-Claude config. The only post-loader scrub was Codex-only,
# so a dynamic Claude child inherited the private config-dir — defeating the
# #1890 "vanilla = operator-global ~/.claude" contract.
#
# The fix adds CLAUDE_CONFIG_DIR to the post-loader scrub list for the
# dynamic-vanilla case (mirroring the Codex ambient-key scrub). This smoke
# exercises the EXACT production helper bridge_isolation_v2_exec_with_secret_env:
#   - secrets file containing CLAUDE_CONFIG_DIR=<private-dir>
#   - launch cmd that echoes the inherited CLAUDE_CONFIG_DIR
#   - with the dynamic-vanilla scrub list -> child sees CLAUDE_CONFIG_DIR ABSENT;
#   - WITHOUT the scrub (the static/admin path) -> child STILL inherits it
#     (proving the scrub is class-scoped, not a blanket break).
#
# Isolation: temp BRIDGE_HOME; secrets file under SMOKE_TMP_ROOT at mode 0640
# (the loader refuses anything broader). Footgun #11: plain printf fixtures only.

set -euo pipefail

SMOKE_NAME="1900-dynamic-vanilla-v2-secret-env-scrub"
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

PRIVATE_CONFIG_DIR="$SMOKE_TMP_ROOT/agent-home/.claude"
SECRET_FILE="$SMOKE_TMP_ROOT/launch-secrets.env"  # noqa: iso-helper-boundary  (controller-only test fixture path, not a runtime boundary RW)
ERRFILE="$SMOKE_TMP_ROOT/errfile.log"
OUTFILE="$SMOKE_TMP_ROOT/child-out.log"
mkdir -p "$PRIVATE_CONFIG_DIR"
: >"$ERRFILE"

# Stale (non-secret) CLAUDE_CONFIG_DIR pointer in the launch-secrets.env — the
# exact leftover shape the reviewer reproduced. Mode 0640: the loader refuses
# anything broader (group-write / world-read).
printf 'CLAUDE_CONFIG_DIR=%s\n' "$PRIVATE_CONFIG_DIR" >"$SECRET_FILE"
chmod 0640 "$SECRET_FILE"

# eval_exec — source the lib, then drive the PRODUCTION exec helper with the
# given scrub-key list. The launch cmd writes the child's inherited
# CLAUDE_CONFIG_DIR (or the literal ABSENT) to OUTFILE so the parent can assert
# on it independently of the helper's own rc handling.
eval_exec() {
  local scrub_keys="$1"
  : >"$OUTFILE"
  env -u CLAUDE_CONFIG_DIR "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    BRIDGE_ISOLATION_V2_LAST_EXEC_RC=0
    launch_cmd='printf \"%s\\n\" \"\${CLAUDE_CONFIG_DIR:-ABSENT}\" > '\"'$OUTFILE'\"
    bridge_isolation_v2_exec_with_secret_env \
      '$SECRET_FILE' '$BASH4_BIN' \"\$launch_cmd\" '$ERRFILE' 'dynv' '$scrub_keys'
    printf 'EXEC_RC=%s\n' \"\$BRIDGE_ISOLATION_V2_LAST_EXEC_RC\"
  "
}

# ===========================================================================
# A — CONTROL (no scrub, the static/admin path): the loader exports the secrets
# file's CLAUDE_CONFIG_DIR and the child INHERITS it. Proves the leak is real
# and the fixture faithful.
# ===========================================================================
test_a_control_inherits() {
  eval_exec "" >/dev/null 2>&1 || smoke_fail "A control exec failed"
  local got; got="$(cat "$OUTFILE" 2>/dev/null || true)"
  smoke_assert_eq "$PRIVATE_CONFIG_DIR" "$got" \
    "A CONTROL (no scrub): child inherits the secrets-file CLAUDE_CONFIG_DIR (leak is real)"
}

# ===========================================================================
# B — dynamic-vanilla scrub (CLAUDE_CONFIG_DIR in the post-loader scrub list):
# the child does NOT inherit a per-agent config-dir — it resolves to ABSENT, so
# Claude falls back to the operator-global ~/.claude. This is the BLOCKING-2 fix.
# ===========================================================================
test_b_dynamic_scrubbed() {
  eval_exec "CLAUDE_CONFIG_DIR" >/dev/null 2>&1 || smoke_fail "B scrub exec failed"
  local got; got="$(cat "$OUTFILE" 2>/dev/null || true)"
  smoke_assert_eq "ABSENT" "$got" \
    "B dynamic-vanilla scrub: child does NOT inherit a per-agent CLAUDE_CONFIG_DIR (operator-global)"
}

# ===========================================================================
# C — Codex scrub keys are unaffected: passing the Codex ambient-key list still
# scrubs those and STILL leaves CLAUDE_CONFIG_DIR present (only the dynamic
# vanilla case adds the config-dir to the list). Guards against an over-broad fix.
# ===========================================================================
test_c_codex_list_keeps_config_dir() {
  eval_exec "OPENAI_API_KEY CODEX_ACCESS_TOKEN" >/dev/null 2>&1 || smoke_fail "C codex exec failed"
  local got; got="$(cat "$OUTFILE" 2>/dev/null || true)"
  smoke_assert_eq "$PRIVATE_CONFIG_DIR" "$got" \
    "C Codex scrub list does NOT scrub CLAUDE_CONFIG_DIR (static/Codex config-dir preserved)"
}

# --- run ------------------------------------------------------------------
smoke_run "A control: no scrub -> child inherits CLAUDE_CONFIG_DIR (leak real)" test_a_control_inherits
smoke_run "B dynamic-vanilla scrub -> child CLAUDE_CONFIG_DIR ABSENT" test_b_dynamic_scrubbed
smoke_run "C Codex-only scrub keeps CLAUDE_CONFIG_DIR (no over-broad fix)" test_c_codex_list_keeps_config_dir

smoke_log "PASS — #1900 BLOCKING 2: the v2 secret-env exec helper scrubs CLAUDE_CONFIG_DIR for the dynamic-vanilla case so a dynamic Claude child never inherits a per-agent config dir; static/admin + Codex paths keep theirs"
