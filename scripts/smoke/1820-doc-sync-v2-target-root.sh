#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-doc-sync-v2-target-root.sh — Issue #1820 (writer 4).
#
# `bridge-docs.py apply` flat-iterates --target-root treating each child as the
# agent home. The upgrade doc-sync caller passed --target-root
# $BRIDGE_AGENT_HOME_ROOT (v1), so the docs engine groomed the v1 tree sessions
# no longer read. The new --home-subdir descends one level so the engine reaches
# the v2 per-agent home `<data>/agents/<a>/home`.
#
# Verdict gate: "the caller target root is layout-resolved for v2 agents, and no
# docs are groomed under the legacy v1 agent tree when v2 exists."
#
# Asserts (driving bridge-docs.py directly with the v2 target + --home-subdir):
#   T1 — list_agent_dirs(target=v2-agents-root, home_subdir=home) selects
#        `<data>/agents/<a>/home`, NOT `<bridge_home>/agents/<a>`.
#   T2 — a mid-scaffold v2 agent entry with no `home` child is skipped.
#   T3 — legacy mode (no --home-subdir) still selects the flat v1 layout.

set -uo pipefail
SMOKE_NAME="1820-doc-sync-v2-target-root"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
DOCS="$REPO_ROOT/bridge-docs.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"

V2AGENTS="$SMOKE_TMP_ROOT/data/agents"
V1AGENTS="$SMOKE_TMP_ROOT/bridge-home/agents"
mkdir -p "$V2AGENTS/acme/home" "$V2AGENTS/midscaffold" "$V1AGENTS/acme"

DRIVER="$SMOKE_TMP_ROOT/probe.py"
{
  printf '%s\n' 'import importlib.util, sys, json'
  printf 'spec = importlib.util.spec_from_file_location("docs", %s)\n' "\"$DOCS\""
  printf '%s\n' 'm = importlib.util.module_from_spec(spec)'
  # Register before exec so the module dataclasses resolve their own __module__
  # (importlib quirk on py3.9 with dataclass + from __future__ annotations).
  printf '%s\n' 'sys.modules["docs"] = m'
  printf '%s\n' 'spec.loader.exec_module(m)'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' 'target = Path(sys.argv[1]); subdir = sys.argv[2]'
  printf '%s\n' 'dirs = m.list_agent_dirs(target, [], True, subdir)'
  printf '%s\n' 'print(json.dumps(sorted(str(d) for d in dirs)))'
} >"$DRIVER"

# T1 — v2 target + home-subdir selects the v2 home, never the v1 tree.
OUT="$(python3 "$DRIVER" "$V2AGENTS" home)"
smoke_log "v2 selection: $OUT"
printf '%s' "$OUT" | python3 -c '
import json,sys
dirs=json.load(sys.stdin)
v2="'"$V2AGENTS"'/acme/home"
assert v2 in dirs, f"v2 home not selected: {dirs}"
assert all("'"$V1AGENTS"'" not in d for d in dirs), f"v1 tree leaked into selection: {dirs}"
assert all(d.endswith("/home") for d in dirs), f"non-home dir selected: {dirs}"
' || smoke_fail "T1 FAIL: v2 target/home-subdir selection wrong"
smoke_log "T1 PASS: v2 home selected, v1 tree never groomed"

# T2 — mid-scaffold v2 entry (no home child) is skipped.
printf '%s' "$OUT" | python3 -c '
import json,sys
dirs=json.load(sys.stdin)
assert all("midscaffold" not in d for d in dirs), f"mid-scaffold selected: {dirs}"
' || smoke_fail "T2 FAIL: mid-scaffold v2 entry not skipped"
smoke_log "T2 PASS: mid-scaffold v2 entry (no home child) skipped"

# T3 — legacy flat mode (no subdir) still selects v1 layout.
OUT3="$(python3 "$DRIVER" "$V1AGENTS" "")"
printf '%s' "$OUT3" | python3 -c '
import json,sys
dirs=json.load(sys.stdin)
v1="'"$V1AGENTS"'/acme"
assert v1 in dirs, f"legacy flat selection missing v1: {dirs}"
' || smoke_fail "T3 FAIL: legacy flat selection broken"
smoke_log "T3 PASS: legacy flat (no subdir) selects v1 layout"

smoke_log "all doc-sync v2 target-root tests PASS (#1820)"
