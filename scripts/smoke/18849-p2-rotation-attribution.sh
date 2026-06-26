#!/usr/bin/env bash
# scripts/smoke/18849-p2-rotation-attribution.sh — #18849 Part 2 PR-1
# Daemon threshold-gated rotation: the monitor must NOT emit a preemptive
# rotation candidate from a REAL native-probe reading still attributed (via its
# one-way `_token_digest`) to a PREVIOUSLY-active token. That post-rotation
# leftover is the root cause of the operator-observed "rotation fires at ~41%
# usage": after an A->B rotation the probe serves A's not-yet-expired 99% cache,
# which re-rotated B even though B's real usage was ~41%.
#
# All scenarios run against the REAL `bridge-usage.py monitor` in an isolated
# BRIDGE_HOME (no live network, no live ~/.agent-bridge, mock caches only).

set -euo pipefail

SMOKE_NAME="18849-p2-rotation-attribution"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

USAGE_PY="$REPO_ROOT/bridge-usage.py"
USAGE_SH="$REPO_ROOT/bridge-usage.sh"
HELPER="$SCRIPT_DIR/18849-p2-rotation-attribution-helper.py"

# Isolated runtime root — never touch the live ~/.agent-bridge.
BRIDGE_HOME="$(mktemp -d)/bridge-home"
export BRIDGE_HOME
mkdir -p "$BRIDGE_HOME"

echo "[smoke:${SMOKE_NAME}] starting (BRIDGE_HOME=$BRIDGE_HOME)"

failed=0
ok() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; failed=1; }

# ---------------------------------------------------------------------------
# Behavioral — drive the real monitor through the repro + control scenarios.
# ---------------------------------------------------------------------------
echo "[behavioral] stale-token attribution gate (repro + legit + back-compat + reactive)"
if python3 "$HELPER"; then
  ok "behavioral helper: all rotation-attribution scenarios pass"
else
  fail "behavioral helper: one or more rotation-attribution scenarios failed"
fi

# ---------------------------------------------------------------------------
# Wiring guards (in-source) — the rotation-attribution gate is threaded
# end-to-end: bridge-usage.sh resolves + forwards the active-token digest, and
# bridge-usage.py carries the cache digest onto snapshots and gates the lane.
# ---------------------------------------------------------------------------
echo "[wiring] active-token-digest is resolved + forwarded + consumed end-to-end"

grep -q -- '--active-token-digest' "$USAGE_SH" \
  && ok "wiring: bridge-usage.sh forwards --active-token-digest to the monitor" \
  || fail "wiring: bridge-usage.sh does not forward --active-token-digest"

grep -q 'token_digest = payload.get("_token_digest")' "$USAGE_PY" \
  && ok "wiring: bridge-usage.py carries _token_digest onto each snapshot" \
  || fail "wiring: bridge-usage.py does not carry _token_digest onto snapshots"

grep -q 'rotation_attribution_ok' "$USAGE_PY" \
  && ok "wiring: bridge-usage.py gates the rotation lane on token attribution" \
  || fail "wiring: bridge-usage.py does not gate the rotation lane on attribution"

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAIL" >&2
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
