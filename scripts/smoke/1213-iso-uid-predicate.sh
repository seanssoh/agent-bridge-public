#!/usr/bin/env bash
# scripts/smoke/1213-iso-uid-predicate.sh — issue #1213.
#
# Pins the contract closed by #1213 — both `_under_isolated_uid()` and
# `current_isolated_agent()` in `hooks/bridge_hook_common.py` must
# decide isolation status from the UID-side data
# (`BRIDGE_AGENT_ID` + `BRIDGE_CONTROLLER_UID` + `os.geteuid() !=
# controller_uid`), NOT from the mode-string env var
# `BRIDGE_AGENT_ISOLATION_MODE`.
#
# Root cause (issue body): bash silently no-ops a scalar export of a
# name bound to an associative array. The `BRIDGE_AGENT_ISOLATION_MODE`
# assoc array declared in `lib/bridge-agents.sh:3410` collides with
# the scalar export at `bridge-run.sh:212`, so iso v2 child processes
# inherit `BRIDGE_AGENT_ISOLATION_MODE=<unset>` even though every other
# bridge env var propagates fine.
#
# Tests:
#   T1 (positive)            — BRIDGE_AGENT_ID set, BRIDGE_CONTROLLER_UID
#                              set to a synthetic value ≠ os.geteuid() →
#                              under_isolated_uid()=True and
#                              current_isolated_agent() returns the slug.
#                              Critically: NO BRIDGE_AGENT_ISOLATION_MODE
#                              env var is set — this is the iso v2 shape
#                              that the pre-#1213 predicate missed.
#   T2 (controller negative) — BRIDGE_AGENT_ID set,
#                              BRIDGE_CONTROLLER_UID == os.geteuid() →
#                              both predicates return False/None
#                              (controller re-exporting agent env still
#                              runs as controller UID; do not mis-attribute
#                              as iso).
#   T3 (missing-agent)       — no BRIDGE_AGENT_ID → both False/None.
#   T4 (missing-controller)  — no BRIDGE_CONTROLLER_UID → both False/None
#                              (fail-closed; controller-side path raises
#                              real PermissionError instead of silently
#                              swallowing).
#   T5 (invalid-controller)  — non-numeric BRIDGE_CONTROLLER_UID →
#                              both False/None.
#   T6 (source guard A)      — `_under_isolated_uid` must NOT call
#                              `current_isolated_agent` and must NOT
#                              inspect `BRIDGE_AGENT_ISOLATION_MODE` in
#                              its body. Grep assertion guards against
#                              reintroduction.
#   T7 (source guard B)      — `current_isolated_agent` must NOT inspect
#                              `BRIDGE_AGENT_ISOLATION_MODE`.
#   T8 (bash collision)      — replicates the exact bash shape the issue
#                              body documents (assoc array declared,
#                              scalar `export` no-ops). Verifies child
#                              process env lacks ISOLATION_MODE while
#                              BRIDGE_AGENT_ID / BRIDGE_CONTROLLER_UID
#                              still propagate, and the Python predicate
#                              returns True under that env.
#
# Footgun #11: pipe/argv stdin only.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1213-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

if ! command -v python3 >/dev/null 2>&1; then
  printf '[FAIL] python3 not on PATH\n' >&2
  exit 1
fi

HOOK_COMMON="$REPO_ROOT/hooks/bridge_hook_common.py"
if [[ ! -f "$HOOK_COMMON" ]]; then
  printf '[FAIL] hooks/bridge_hook_common.py not found at %s\n' "$HOOK_COMMON" >&2
  exit 1
fi

CURRENT_EUID="$(python3 -c 'import os; print(os.geteuid())')"
# Synthetic non-matching UID that cannot be the current process's euid.
SYNTHETIC_NON_MATCH_UID="999999"
if [[ "$CURRENT_EUID" == "$SYNTHETIC_NON_MATCH_UID" ]]; then
  SYNTHETIC_NON_MATCH_UID="999998"
fi

# Driver loads bridge_hook_common as a module and prints
# "UID=<bool> AGENT=<str|None>".
DRIVER="$SMOKE_DIR/driver.py"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Invoke bridge_hook_common predicates with a controlled env."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import importlib.util'
  printf '%s\n' 'import os'
  printf '%s\n' 'import sys'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'def load_module(path):'
  printf '%s\n' '    spec = importlib.util.spec_from_file_location("bridge_hook_common", str(path))'
  printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
  printf '%s\n' '    spec.loader.exec_module(module)'
  printf '%s\n' '    return module'
  printf '%s\n' ''
  printf '%s\n' 'def main() -> int:'
  printf '%s\n' '    common_path = Path(os.environ["DRIVER_HOOK_COMMON_PATH"])'  # noqa: iso-helper-boundary
  printf '%s\n' '    module = load_module(common_path)'
  printf '%s\n' '    uid_pred = module.under_isolated_uid()'
  printf '%s\n' '    iso_agent = module.current_isolated_agent()'
  printf '%s\n' '    iso_mode = module._current_isolation_mode()'
  printf '%s\n' '    print("UID=" + str(uid_pred) + " AGENT=" + str(iso_agent) + " MODE=" + str(iso_mode))'
  printf '%s\n' '    return 0'
  printf '%s\n' ''
  printf '%s\n' 'if __name__ == "__main__":'
  printf '%s\n' '    raise SystemExit(main())'
} >>"$DRIVER"
chmod +x "$DRIVER"

run_driver() {
  # Args: extra env assignments as separate `NAME=VAL` strings.
  env -i \
    PATH="$PATH" \
    DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
    "$@" \
    python3 "$DRIVER"
}

# ---------------------------------------------------------------------------
# T1 — positive: iso v2 env shape (BRIDGE_AGENT_ID + BRIDGE_CONTROLLER_UID
# mismatch, NO BRIDGE_AGENT_ISOLATION_MODE).
# ---------------------------------------------------------------------------
T1_OUT="$(run_driver \
  BRIDGE_AGENT_ID="test_iso_v25" \
  BRIDGE_CONTROLLER_UID="$SYNTHETIC_NON_MATCH_UID")"
if [[ "$T1_OUT" == "UID=True AGENT=test_iso_v25 MODE=linux-user" ]]; then
  _pass "T1: positive — iso v2 env (no MODE string) → UID=True, AGENT set, MODE diagnostic = linux-user"
else
  _fail "T1" "expected 'UID=True AGENT=test_iso_v25 MODE=linux-user', got: '$T1_OUT'"
fi

# ---------------------------------------------------------------------------
# T2 — controller negative: BRIDGE_AGENT_ID set + controller UID matches.
# ---------------------------------------------------------------------------
T2_OUT="$(run_driver \
  BRIDGE_AGENT_ID="test_iso_v25" \
  BRIDGE_CONTROLLER_UID="$CURRENT_EUID")"
if [[ "$T2_OUT" == "UID=False AGENT=None MODE=shared" ]]; then
  _pass "T2: controller — agent env + matching UID → UID=False, AGENT=None, MODE=shared"
else
  _fail "T2" "expected 'UID=False AGENT=None MODE=shared', got: '$T2_OUT'"
fi

# ---------------------------------------------------------------------------
# T3 — missing agent.
# ---------------------------------------------------------------------------
T3_OUT="$(run_driver \
  BRIDGE_CONTROLLER_UID="$SYNTHETIC_NON_MATCH_UID")"
if [[ "$T3_OUT" == "UID=False AGENT=None MODE=shared" ]]; then
  _pass "T3: missing-agent — no BRIDGE_AGENT_ID → UID=False, AGENT=None"
else
  _fail "T3" "expected 'UID=False AGENT=None MODE=shared', got: '$T3_OUT'"
fi

# ---------------------------------------------------------------------------
# T4 — missing controller UID.
# ---------------------------------------------------------------------------
T4_OUT="$(run_driver \
  BRIDGE_AGENT_ID="test_iso_v25")"
if [[ "$T4_OUT" == "UID=False AGENT=None MODE=shared" ]]; then
  _pass "T4: missing-controller — fail-closed → UID=False, AGENT=None"
else
  _fail "T4" "expected 'UID=False AGENT=None MODE=shared', got: '$T4_OUT'"
fi

# ---------------------------------------------------------------------------
# T5 — invalid (non-numeric) controller UID.
# ---------------------------------------------------------------------------
T5_OUT="$(run_driver \
  BRIDGE_AGENT_ID="test_iso_v25" \
  BRIDGE_CONTROLLER_UID="not-a-number")"
if [[ "$T5_OUT" == "UID=False AGENT=None MODE=shared" ]]; then
  _pass "T5: invalid-controller — non-numeric → UID=False, AGENT=None"
else
  _fail "T5" "expected 'UID=False AGENT=None MODE=shared', got: '$T5_OUT'"
fi

# ---------------------------------------------------------------------------
# T6 — source guard A: `_under_isolated_uid` body must NOT reference
# `current_isolated_agent` or `BRIDGE_AGENT_ISOLATION_MODE`.
# Extract the function body via awk (between the `def` line and the next
# top-level `def`).
# ---------------------------------------------------------------------------
T6_BODY="$(awk '
  /^def _under_isolated_uid\b/ { capture=1; next }
  capture && /^def [A-Za-z_]/ { capture=0 }
  capture { print }
' "$HOOK_COMMON")"

T6_ERRORS=""
if grep -E '^[^#]*\bcurrent_isolated_agent\(' <<<"$T6_BODY" >/dev/null; then
  T6_ERRORS+="_under_isolated_uid body references current_isolated_agent(); "
fi
if grep -E '^[^#]*BRIDGE_AGENT_ISOLATION_MODE' <<<"$T6_BODY" >/dev/null; then
  T6_ERRORS+="_under_isolated_uid body references BRIDGE_AGENT_ISOLATION_MODE; "
fi
if [[ -z "$T6_ERRORS" ]]; then
  _pass "T6: source guard A — _under_isolated_uid body free of mode-string deps"
else
  _fail "T6" "$T6_ERRORS"
fi

# ---------------------------------------------------------------------------
# T7 — source guard B: `current_isolated_agent` body must NOT reference
# `BRIDGE_AGENT_ISOLATION_MODE`.
# ---------------------------------------------------------------------------
T7_BODY="$(awk '
  /^def current_isolated_agent\b/ { capture=1; next }
  capture && /^def [A-Za-z_]/ { capture=0 }
  capture { print }
' "$HOOK_COMMON")"

if grep -E '^[^#]*BRIDGE_AGENT_ISOLATION_MODE' <<<"$T7_BODY" >/dev/null; then
  _fail "T7" "current_isolated_agent body still references BRIDGE_AGENT_ISOLATION_MODE"
else
  _pass "T7: source guard B — current_isolated_agent body free of mode-string deps"
fi

# ---------------------------------------------------------------------------
# T8 — bash collision reproducer. Declare BRIDGE_AGENT_ISOLATION_MODE as
# an associative array, try `export` of a scalar value (silent no-op),
# spawn the Python driver, and assert the predicate still works because
# it does NOT depend on the mode string.
# ---------------------------------------------------------------------------
T8_REPRO="$SMOKE_DIR/t8-repro.sh"
: >"$T8_REPRO"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Mimic lib/bridge-agents.sh:3410 declaration.
  printf '%s\n' 'declare -g -A BRIDGE_AGENT_ISOLATION_MODE=()'
  # Populate one slot (simulating `bridge_load_roster`).
  printf '%s\n' 'BRIDGE_AGENT_ISOLATION_MODE[test_iso_v25]=linux-user'
  # Mimic bridge-run.sh:212 scalar export — silently no-ops.
  printf '%s\n' 'export BRIDGE_AGENT_ISOLATION_MODE="$(printf %s "linux-user")"'
  printf '%s\n' 'export BRIDGE_AGENT_ID="test_iso_v25"'
  # Verify the assoc array still works in this shell:
  printf '%s\n' 'echo "shell ARR[test_iso_v25]=${BRIDGE_AGENT_ISOLATION_MODE[test_iso_v25]}"'
  # Confirm the scalar export did NOT propagate to child env.
  printf '%s\n' 'python3 -c "import os, sys; sys.stderr.write(\"child MODE=\" + os.environ.get(\"BRIDGE_AGENT_ISOLATION_MODE\", \"<UNSET>\") + chr(10))"'  # noqa: iso-helper-boundary
  # Now run the predicate driver under the same env. The child python
  # process sees an empty BRIDGE_AGENT_ISOLATION_MODE but iso-uid
  # predicate must still return True because BRIDGE_AGENT_ID +
  # BRIDGE_CONTROLLER_UID + euid-mismatch are all present.
  printf 'BRIDGE_CONTROLLER_UID="%s" DRIVER_HOOK_COMMON_PATH="%s" python3 "%s"\n' \
    "$SYNTHETIC_NON_MATCH_UID" "$HOOK_COMMON" "$DRIVER"
} >>"$T8_REPRO"
chmod +x "$T8_REPRO"

T8_OUT="$(/opt/homebrew/bin/bash "$T8_REPRO" 2>"$SMOKE_DIR/t8.err" || /usr/bin/env bash "$T8_REPRO" 2>"$SMOKE_DIR/t8.err")"
T8_RC=$?
# stderr line should report `<UNSET>` proving the export collision.
if ! grep -q "child MODE=<UNSET>" "$SMOKE_DIR/t8.err"; then
  _fail "T8" "expected stderr to show child MODE=<UNSET>; got: $(cat "$SMOKE_DIR/t8.err")"
elif [[ "$T8_OUT" == *"UID=True AGENT=test_iso_v25 MODE=linux-user"* ]]; then
  _pass "T8: bash assoc-array collision reproduced; predicate still True via UID side"
else
  _fail "T8" "expected predicate to return True under collision env (rc=$T8_RC); got: $T8_OUT"
fi

printf '[%s] %d/%d passed\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
