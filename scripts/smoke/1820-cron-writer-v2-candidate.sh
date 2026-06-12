#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-cron-writer-v2-candidate.sh — Issue #1820 (writer 1).
#
# The cron disposable worker resolved every shared agent's Claude config dir to
# the v1 `<bridge_home>/agents/<a>` tree because `bridge_data_root()` fell back
# to `bridge_home()` when BRIDGE_DATA_ROOT was absent from the daemon env — so
# it wrote MEMORY.md / memory/ dailies to v1 while interactive sessions used v2.
#
# Verdict gate: "with only BRIDGE_HOME in the daemon environment,
# `_shared_agent_claude_config_candidates` must prefer the v2
# `<data>/agents/<a>/home/.claude` path when v2 exists; legacy v1-only installs
# must still resolve."
#
# This smoke drives the runner's resolver with ONLY BRIDGE_HOME exported (the
# layout marker is the sole source of the data root) and asserts:
#   T1 — v2 candidate `<data>/agents/<a>/home/.claude` is FIRST.
#   T2 — legacy install (no marker) still resolves v1 candidates.

set -uo pipefail
SMOKE_NAME="1820-cron-writer-v2-candidate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
RUNNER="$REPO_ROOT/bridge-cron-runner.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"

# --- T1: v2 install, ONLY BRIDGE_HOME in env (marker carries data root) -----
V2HOME="$SMOKE_TMP_ROOT/v2/bridge-home"
V2DATA="$SMOKE_TMP_ROOT/v2/data"
mkdir -p "$V2HOME/state" "$V2DATA/agents/acme/home/.claude" "$V2HOME/agents/acme/.claude"
{ printf 'BRIDGE_LAYOUT=v2\n'; printf "BRIDGE_DATA_ROOT=%s\n" "$V2DATA"; } >"$V2HOME/state/layout-marker.sh"
chmod 0644 "$V2HOME/state/layout-marker.sh"

DRIVER="$SMOKE_TMP_ROOT/probe.py"
{
  printf '%s\n' 'import importlib.util, sys, json'
  printf 'spec = importlib.util.spec_from_file_location("ccr", %s)\n' "\"$RUNNER\""
  printf '%s\n' 'm = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(m)'
  printf '%s\n' 'cands = [str(p) for p in m._shared_agent_claude_config_candidates("acme")]'
  printf '%s\n' 'print(json.dumps(cands))'
} >"$DRIVER"

# Export ONLY BRIDGE_HOME (and PATH) — strip BRIDGE_DATA_ROOT / v2 roots so the
# resolver must discover the data root from the marker alone.
OUT="$(env -i PATH="$PATH" BRIDGE_HOME="$V2HOME" python3 "$DRIVER")"
smoke_log "v2 candidates (BRIDGE_HOME-only): $OUT"
FIRST="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
EXPECT_V2="$V2DATA/agents/acme/home/.claude"
[[ "$FIRST" == "$EXPECT_V2" ]] \
  || smoke_fail "T1 FAIL: first candidate is '$FIRST', expected v2 '$EXPECT_V2'"
# v2 path must be ranked ahead of the v1 path.
printf '%s' "$OUT" | python3 -c '
import json,sys
c=json.load(sys.stdin)
v2="'"$EXPECT_V2"'"; v1="'"$V2HOME"'/agents/acme/.claude"
assert v1 in c, f"v1 candidate missing: {c}"
assert c.index(v2) < c.index(v1), f"v2 not ahead of v1: {c}"
' || smoke_fail "T1 FAIL: v2 candidate not ranked ahead of v1"
smoke_log "T1 PASS: v2 candidate first + ahead of v1, from BRIDGE_HOME-only env"

# --- T2: legacy install (no marker) still resolves v1 -----------------------
L1HOME="$SMOKE_TMP_ROOT/legacy/bridge-home"
mkdir -p "$L1HOME/state" "$L1HOME/agents/acme/.claude"
OUT2="$(env -i PATH="$PATH" BRIDGE_HOME="$L1HOME" python3 "$DRIVER")"
smoke_log "legacy candidates: $OUT2"
printf '%s' "$OUT2" | python3 -c '
import json,sys
c=json.load(sys.stdin)
v1="'"$L1HOME"'/agents/acme/.claude"
assert v1 in c, f"legacy v1 candidate missing: {c}"
' || smoke_fail "T2 FAIL: legacy install did not resolve the v1 candidate"
smoke_log "T2 PASS: legacy install still resolves v1 candidate"

smoke_log "all cron-writer v2-candidate tests PASS (#1820)"
