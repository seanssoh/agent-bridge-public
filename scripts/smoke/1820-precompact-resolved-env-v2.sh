#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-precompact-resolved-env-v2.sh — Issue #1820 (writer 2).
#
# hooks/pre-compact.py::_agent_home() read the bare BRIDGE_AGENT_WORKDIR /
# BRIDGE_AGENT_HOME names, which collide with associative arrays in
# lib/bridge-agents.sh and never reach the hook child — so it always fell
# through to the v1 `<BRIDGE_HOME>/agents/<a>` fallback and dumped compact
# envelopes into v1.
#
# Verdict gate: "when BRIDGE_AGENT_HOME_RESOLVED and/or
# BRIDGE_AGENT_WORKDIR_RESOLVED are exported, hook output lands in the
# v2-resolved tree and not <BRIDGE_HOME>/agents/<a>."
#
# Asserts:
#   T1 — with BRIDGE_AGENT_WORKDIR_RESOLVED set, _agent_home() returns the v2
#        workdir, NOT the v1 legacy fallback.
#   T2 — with only BRIDGE_AGENT_HOME_RESOLVED set, _agent_home() returns the v2
#        identity home.
#   T3 — with neither resolved alias, legacy v1 existence-gated fallback holds.

set -uo pipefail
SMOKE_NAME="1820-precompact-resolved-env-v2"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
HOOK="$REPO_ROOT/hooks/pre-compact.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"

BH="$SMOKE_TMP_ROOT/bridge-home"
V2WORK="$SMOKE_TMP_ROOT/data/agents/acme/workdir"
V2HOME="$SMOKE_TMP_ROOT/data/agents/acme/home"
V1HOME="$BH/agents/acme"
mkdir -p "$BH" "$V2WORK" "$V2HOME" "$V1HOME"

DRIVER="$SMOKE_TMP_ROOT/probe.py"
{
  printf '%s\n' 'import importlib.util, sys'
  printf 'spec = importlib.util.spec_from_file_location("pc", %s)\n' "\"$HOOK\""
  printf '%s\n' 'm = importlib.util.module_from_spec(spec)'
  printf '%s\n' 'spec.loader.exec_module(m)'
  printf '%s\n' 'h = m._agent_home()'
  printf '%s\n' 'print(str(h) if h is not None else "")'
} >"$DRIVER"

run_probe() { env -i PATH="$PATH" "$@" python3 "$DRIVER"; }

# T1 — workdir resolved alias wins, lands in v2 workdir, not v1.
OUT="$(run_probe BRIDGE_HOME="$BH" BRIDGE_AGENT_ID=acme BRIDGE_AGENT_WORKDIR_RESOLVED="$V2WORK")"
[[ "$OUT" == "$V2WORK" ]] || smoke_fail "T1 FAIL: _agent_home='$OUT', expected v2 workdir '$V2WORK'"
[[ "$OUT" != "$V1HOME" ]] || smoke_fail "T1 FAIL: resolved to v1 legacy fallback"
smoke_log "T1 PASS: BRIDGE_AGENT_WORKDIR_RESOLVED -> v2 workdir"

# T2 — only home resolved alias -> v2 identity home.
OUT="$(run_probe BRIDGE_HOME="$BH" BRIDGE_AGENT_ID=acme BRIDGE_AGENT_HOME_RESOLVED="$V2HOME")"
[[ "$OUT" == "$V2HOME" ]] || smoke_fail "T2 FAIL: _agent_home='$OUT', expected v2 home '$V2HOME'"
smoke_log "T2 PASS: BRIDGE_AGENT_HOME_RESOLVED -> v2 identity home"

# T3 — no resolved aliases -> legacy v1 existence-gated fallback.
OUT="$(run_probe BRIDGE_HOME="$BH" BRIDGE_AGENT_ID=acme)"
[[ "$OUT" == "$V1HOME" ]] || smoke_fail "T3 FAIL: _agent_home='$OUT', expected v1 legacy '$V1HOME'"
smoke_log "T3 PASS: no resolved alias -> v1 legacy fallback preserved"

smoke_log "all pre-compact resolved-env v2 tests PASS (#1820)"
