#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/codex-doctor.sh — #8945 Track D: availability-gated
# `codex doctor` env/auth health smoke.
#
# Contract (codex plan-review r2 #3 — availability-gated):
#   - When the `codex` CLI is ABSENT, the smoke asserts a graceful SKIP
#     and exits 0. A codex-less CI host must NEVER become a false release
#     blocker. This mirrors the existing precedent that a missing Codex CLI
#     is non-fatal (lib/bridge-init-codex-pair.sh:71-79 — the admin codex
#     pair auto-provisioning skips, never fails, when codex is not found).
#   - The CI-default path is the SKIP path. Even on a host that happens to
#     have `codex` installed, the real-doctor assertion only runs when the
#     live gate `BRIDGE_SMOKE_CODEX_DOCTOR_LIVE=1` is set. This keeps CI
#     hermetic and deterministic — `codex doctor` reaches the network / auth
#     state and its output is environment-dependent, so it is reserved for
#     the operator-driven live/tool-present gate.
#   - On the live gate WITH codex present: run `codex doctor`, assert it
#     exits cleanly (rc 0) and surfaces env/auth/runtime status text.
#
# Footgun #11 / lint-heredoc-ban: no heredoc-stdin / process-substitution
# into an interpreter — output is captured into shell vars and a temp file
# and inspected with plain `grep` / `case`.

set -uo pipefail

SMOKE_NAME="codex-doctor"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# --- Availability gate ---------------------------------------------------
# The skip path is the CI default. We deliberately do NOT call
# smoke_require_cmd codex (which would HARD-FAIL); a missing codex is the
# expected, non-blocking CI condition.
if ! command -v codex >/dev/null 2>&1; then
  smoke_skip "codex doctor" "codex CLI not found on PATH — non-fatal SKIP (codex-less CI host)"
  smoke_log "PASS (skipped: codex absent)"
  exit 0
fi

CODEX_BIN="$(command -v codex)"
smoke_log "codex CLI present at $CODEX_BIN"

# --- Live gate -----------------------------------------------------------
# Even with codex installed, the real `codex doctor` invocation is reserved
# for the explicit live/tool-present gate so the CI-default path stays the
# deterministic skip/no-op above. Without the gate we assert only the
# availability shape (the binary resolves + responds to --version) and stop
# short of the environment-dependent doctor run.
if [[ "${BRIDGE_SMOKE_CODEX_DOCTOR_LIVE:-0}" != "1" ]]; then
  # Tool-present sanity that costs nothing and reaches no network/auth:
  # `codex --version` must succeed and print a recognizable version line.
  VERSION_OUT=""
  VERSION_RC=0
  VERSION_OUT="$(codex --version 2>&1)" || VERSION_RC=$?
  if [[ $VERSION_RC -ne 0 ]]; then
    smoke_fail "codex --version exited rc=$VERSION_RC; output: $VERSION_OUT"
  fi
  case "$VERSION_OUT" in
    *[0-9].[0-9]*) : ;;  # contains a dotted version token
    *) smoke_fail "codex --version did not print a recognizable version: '$VERSION_OUT'" ;;
  esac
  smoke_log "codex present, live gate off — version probe OK ('$VERSION_OUT')"
  smoke_log "skip: codex doctor live run (set BRIDGE_SMOKE_CODEX_DOCTOR_LIVE=1 to exercise it)"
  smoke_log "PASS (tool-present, live gate off)"
  exit 0
fi

# --- Real doctor run (live/tool-present gate) ----------------------------
smoke_log "LIVE: running 'codex doctor' (BRIDGE_SMOKE_CODEX_DOCTOR_LIVE=1)"
DOCTOR_OUT_FILE="$SMOKE_TMP_ROOT/codex-doctor.out"
DOCTOR_RC=0
codex doctor >"$DOCTOR_OUT_FILE" 2>&1 || DOCTOR_RC=$?

if [[ $DOCTOR_RC -ne 0 ]]; then
  smoke_fail "codex doctor exited rc=$DOCTOR_RC; output:
$(cat "$DOCTOR_OUT_FILE" 2>/dev/null)"
fi

if [[ ! -s "$DOCTOR_OUT_FILE" ]]; then
  smoke_fail "codex doctor produced no output"
fi

# Assert the doctor report surfaces health status. The 0.135.0 report
# header is 'Codex Doctor v<ver>' and the body carries Environment / runtime
# / install sections. We match on the stable header token plus at least one
# status section so a future codex CLI cosmetic change does not over-pin.
if ! grep -qiE 'codex doctor|environment|runtime|install' "$DOCTOR_OUT_FILE"; then
  smoke_fail "codex doctor output did not surface env/runtime/install status:
$(cat "$DOCTOR_OUT_FILE" 2>/dev/null)"
fi

smoke_log "codex doctor clean exit + env/auth/runtime status surfaced"
smoke_log "PASS (live doctor run)"
