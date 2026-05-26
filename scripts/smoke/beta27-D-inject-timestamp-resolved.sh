#!/usr/bin/env bash
# scripts/smoke/beta27-D-inject-timestamp-resolved.sh — issue #1217 Track D.
#
# Pins the contract closed by beta27 Track D — bridge-run.sh exports
# `BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED` as a distinctly-named scalar
# alias because the bare `BRIDGE_AGENT_INJECT_TIMESTAMP` collides with
# the associative array of the same name declared in
# lib/bridge-core.sh:867 (bash silently no-ops a scalar export of a
# name bound to an assoc array). The Python hook
# `agent_timestamp_enabled()` reads `_RESOLVED` first, with a
# fallback to the bare name for manual / non-bridge launches.
#
# Tests:
#   T1 (assoc-array collision) — replicates the exact bash shape:
#                                declare -g -A on the bare name, attempt
#                                scalar export (silent no-op), spawn a
#                                child python and assert the bare name
#                                is absent (<UNSET>) from child env while
#                                BRIDGE_AGENT_ID still propagates.
#   T2 (RESOLVED True path)    — RESOLVED="1" exported → child sees it
#                                → agent_timestamp_enabled() returns True.
#   T3 (RESOLVED False path)   — RESOLVED="0" exported → child sees it
#                                → agent_timestamp_enabled() returns False
#                                (covers every off-token via T3a/T3b/T3c).
#   T4 (RESOLVED precedence)   — both RESOLVED and bare set, RESOLVED
#                                wins (RESOLVED="0", bare="1" → False).
#   T5 (bare-fallback)         — only bare name set (manual/non-bridge
#                                launch shape) → fallback path reads bare
#                                → returns expected boolean.
#   T6 (default True)          — neither var set → agent_timestamp_enabled
#                                returns True (default-on contract).
#   T7 (source guard)          — agent_timestamp_enabled body reads
#                                BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED
#                                before the bare name (grep assertion
#                                against future regressions).
#
# Footgun #11: pipe/argv stdin only. Drivers written via `printf >>file`.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-beta27-D-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

if ! command -v python3 >/dev/null 2>&1; then
  printf '[FAIL] python3 not on PATH\n' >&2
  exit 1
fi

HOOK_COMMON="$REPO_ROOT/hooks/bridge_hook_common.py"
BRIDGE_RUN="$REPO_ROOT/bridge-run.sh"
if [[ ! -f "$HOOK_COMMON" ]]; then
  printf '[FAIL] hooks/bridge_hook_common.py not found at %s\n' "$HOOK_COMMON" >&2
  exit 1
fi
if [[ ! -f "$BRIDGE_RUN" ]]; then
  printf '[FAIL] bridge-run.sh not found at %s\n' "$BRIDGE_RUN" >&2
  exit 1
fi

# Driver loads bridge_hook_common as a module and prints
# `ENABLED=<bool>`. The smoke env controls which env vars are set.
DRIVER="$SMOKE_DIR/driver.py"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Invoke bridge_hook_common.agent_timestamp_enabled with a controlled env."""'
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
  printf '%s\n' '    agent = os.environ.get("DRIVER_AGENT", "smoke_agent")'  # noqa: iso-helper-boundary
  printf '%s\n' '    result = module.agent_timestamp_enabled(agent)'
  printf '%s\n' '    print("ENABLED=" + str(bool(result)))'
  printf '%s\n' '    return 0'
  printf '%s\n' ''
  printf '%s\n' 'if __name__ == "__main__":'
  printf '%s\n' '    raise SystemExit(main())'
} >>"$DRIVER"
chmod +x "$DRIVER"

# ---------------------------------------------------------------------------
# T1 — bash assoc-array collision reproducer. Declare BRIDGE_AGENT_INJECT_
# TIMESTAMP as an associative array (mirrors lib/bridge-core.sh:867),
# attempt scalar `export` of a value, spawn the python child, and assert
# the child sees the bare name as <UNSET> (proving the silent no-op).
# This is the bug Track D fixes.
# ---------------------------------------------------------------------------
T1_REPRO="$SMOKE_DIR/t1-repro.sh"
: >"$T1_REPRO"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Mimic lib/bridge-core.sh:867 declaration.
  printf '%s\n' 'declare -g -A BRIDGE_AGENT_INJECT_TIMESTAMP=()'
  # Populate one slot (simulating bridge_load_roster).
  printf '%s\n' 'BRIDGE_AGENT_INJECT_TIMESTAMP[smoke_agent]=0'
  # Mimic bridge-run.sh bare-name export — silently no-ops.
  printf '%s\n' 'export BRIDGE_AGENT_INJECT_TIMESTAMP="0"'
  printf '%s\n' 'export BRIDGE_AGENT_ID="smoke_agent"'
  # Confirm the scalar export did NOT propagate to child env.
  printf '%s\n' 'python3 -c "import os, sys; sys.stderr.write(\"child BARE=\" + os.environ.get(\"BRIDGE_AGENT_INJECT_TIMESTAMP\", \"<UNSET>\") + chr(10))"'  # noqa: iso-helper-boundary
} >>"$T1_REPRO"
chmod +x "$T1_REPRO"

if /opt/homebrew/bin/bash "$T1_REPRO" 2>"$SMOKE_DIR/t1.err"; then
  :
elif /usr/bin/env bash "$T1_REPRO" 2>"$SMOKE_DIR/t1.err"; then
  :
else
  printf '[warn] T1 bash repro returned non-zero; continuing\n'
fi
if grep -q "child BARE=<UNSET>" "$SMOKE_DIR/t1.err"; then
  _pass "T1: bash assoc-array collision reproduced — bare export silently no-ops"
else
  _fail "T1" "expected child env BARE=<UNSET>; got: $(cat "$SMOKE_DIR/t1.err")"
fi

# ---------------------------------------------------------------------------
# T2 — RESOLVED="1" → child agent_timestamp_enabled() returns True.
# ---------------------------------------------------------------------------
T2_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED="1" \
  python3 "$DRIVER" 2>&1)"
if [[ "$T2_OUT" == "ENABLED=True" ]]; then
  _pass "T2: RESOLVED=1 → agent_timestamp_enabled returns True"
else
  _fail "T2" "expected 'ENABLED=True', got: '$T2_OUT'"
fi

# ---------------------------------------------------------------------------
# T3 — RESOLVED="0" → False. Cover each off-token.
# ---------------------------------------------------------------------------
for token in 0 false no off; do
  OUT="$(env -i \
    PATH="$PATH" \
    DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
    DRIVER_AGENT="smoke_agent" \
    BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED="$token" \
    python3 "$DRIVER" 2>&1)"
  if [[ "$OUT" == "ENABLED=False" ]]; then
    _pass "T3[$token]: RESOLVED=$token → agent_timestamp_enabled returns False"
  else
    _fail "T3[$token]" "expected 'ENABLED=False', got: '$OUT'"
  fi
done

# ---------------------------------------------------------------------------
# T4 — RESOLVED precedence. Both set: RESOLVED="0", bare="1" → False
# (RESOLVED wins). Bare="0", RESOLVED="1" → True (RESOLVED wins).
# ---------------------------------------------------------------------------
T4A_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED="0" \
  BRIDGE_AGENT_INJECT_TIMESTAMP="1" \
  python3 "$DRIVER" 2>&1)"
if [[ "$T4A_OUT" == "ENABLED=False" ]]; then
  _pass "T4a: RESOLVED=0 wins over bare=1 → False"
else
  _fail "T4a" "expected 'ENABLED=False', got: '$T4A_OUT'"
fi

T4B_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED="1" \
  BRIDGE_AGENT_INJECT_TIMESTAMP="0" \
  python3 "$DRIVER" 2>&1)"
if [[ "$T4B_OUT" == "ENABLED=True" ]]; then
  _pass "T4b: RESOLVED=1 wins over bare=0 → True"
else
  _fail "T4b" "expected 'ENABLED=True', got: '$T4B_OUT'"
fi

# ---------------------------------------------------------------------------
# T5 — bare-name fallback (manual / non-bridge launch shape). Only bare
# name set; agent_timestamp_enabled must fall back and read it.
# ---------------------------------------------------------------------------
T5A_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_INJECT_TIMESTAMP="0" \
  python3 "$DRIVER" 2>&1)"
if [[ "$T5A_OUT" == "ENABLED=False" ]]; then
  _pass "T5a: bare-fallback (manual launch) BARE=0 → False"
else
  _fail "T5a" "expected 'ENABLED=False', got: '$T5A_OUT'"
fi

T5B_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_INJECT_TIMESTAMP="1" \
  python3 "$DRIVER" 2>&1)"
if [[ "$T5B_OUT" == "ENABLED=True" ]]; then
  _pass "T5b: bare-fallback (manual launch) BARE=1 → True"
else
  _fail "T5b" "expected 'ENABLED=True', got: '$T5B_OUT'"
fi

# ---------------------------------------------------------------------------
# T6 — default-True: neither var set → agent_timestamp_enabled returns True
# (default-on contract preserved across the refactor).
# ---------------------------------------------------------------------------
T6_OUT="$(env -i \
  PATH="$PATH" \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON" \
  DRIVER_AGENT="smoke_agent" \
  python3 "$DRIVER" 2>&1)"
if [[ "$T6_OUT" == "ENABLED=True" ]]; then
  _pass "T6: neither var set → default-True preserved"
else
  _fail "T6" "expected 'ENABLED=True', got: '$T6_OUT'"
fi

# ---------------------------------------------------------------------------
# T7 — source guard. agent_timestamp_enabled body must reference
# BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED before the bare name. Extract
# the function body via awk and grep for ordering.
# ---------------------------------------------------------------------------
T7_BODY_FILE="$SMOKE_DIR/t7-body.txt"
awk 'BEGIN{capture=0}
  /^def agent_timestamp_enabled\(/ { capture=1; next }
  capture && /^def [A-Za-z_]/ { capture=0 }
  capture { print }
' "$HOOK_COMMON" >"$T7_BODY_FILE"

if ! grep -q 'BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED' "$T7_BODY_FILE"; then
  _fail "T7" "agent_timestamp_enabled body does not reference BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED"
else
  RESOLVED_LINE="$(grep -n 'BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED' "$T7_BODY_FILE" | head -1 | cut -d: -f1)"
  BARE_LINE="$(grep -nE 'BRIDGE_AGENT_INJECT_TIMESTAMP[^_]' "$T7_BODY_FILE" | head -1 | cut -d: -f1)"
  if [[ -z "$BARE_LINE" ]]; then
    BARE_LINE="$(grep -nE 'BRIDGE_AGENT_INJECT_TIMESTAMP$' "$T7_BODY_FILE" | head -1 | cut -d: -f1)"
  fi
  if [[ -n "$BARE_LINE" && "$RESOLVED_LINE" -gt "$BARE_LINE" ]]; then
    _fail "T7" "agent_timestamp_enabled reads bare name (line $BARE_LINE) before RESOLVED (line $RESOLVED_LINE)"
  else
    _pass "T7: source guard — agent_timestamp_enabled reads RESOLVED first"
  fi
fi

# ---------------------------------------------------------------------------
# T8 — source guard B: bridge-run.sh exports the RESOLVED scalar alias.
# Grep assertion against future regressions removing the alias.
# ---------------------------------------------------------------------------
if grep -qE '^export BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED=' "$BRIDGE_RUN"; then
  _pass "T8: source guard — bridge-run.sh exports BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED"
else
  _fail "T8" "bridge-run.sh does not export BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED"
fi

printf '[%s] %d/%d passed\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
