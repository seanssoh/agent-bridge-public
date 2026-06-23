#!/usr/bin/env bash
# 2062-watchdog-rendered-block-not-drift.sh -- Issue #2062 (#1816 blast radius):
# a Claude identity home whose CLAUDE.md carries the block AS THE RENDERER
# ACTUALLY EMITS IT must be reported `missing_managed_claude_block=false` /
# `status=ok` by the watchdog -- NOT drift.
#
# The regression this guards (the 4th #1816 marker-stamp consumer):
#   #1816 originally version-stamped the BEGIN marker itself
#   (`<!-- BEGIN AGENT BRIDGE DOC MIGRATION v=<version> -->`), but
#   bridge-watchdog.py tested the LITERAL unstamped marker
#   (`MANAGED_START in claude_text`). A stamping upgrade therefore flagged every
#   healthy stamped/refreshed Claude home as `missing_managed_claude_block` ->
#   fleet-wide false `[watchdog] agent profile drift` tasks on HEALTHY homes.
#
# #2062 root-cause fix: the version stamp moved OFF the BEGIN marker to a
# separate in-block metadata line, so the marker is the stable literal
# `MANAGED_START` again and the watchdog's substring match keeps matching.
#
# Why a NEW smoke (the existing 2018 smoke did not catch this): 2018 (and the
# other watchdog managed-block smokes) HAND-WRITE a literal `MANAGED_START`
# fixture, so they never exercise what the RENDERER emits -- the exact coverage
# gap that let the stamp-on-marker regression through. This smoke renders the
# block through `bridge-docs.py` (the real production path) and then scans it.
#
#   T1  RENDERED-BLOCK home: render the managed block via `bridge-docs.py apply`
#       into the identity home, then scan -> missing_managed_claude_block=false,
#       status=ok. (The whole point: the renderer's output must satisfy the
#       watchdog's matcher.)
#   T2  MUTATION CONTROL (non-vacuous): take the rendered block and move the
#       version stamp BACK onto the BEGIN marker (the pre-#2062 shape). The
#       watchdog's literal `MANAGED_START` match no longer matches ->
#       missing_managed_claude_block=true. This proves (a) the test is not
#       vacuous and (b) the stamp-on-marker shape is precisely what broke the
#       watchdog.
#   T3  IN-BLOCK VERSION readable: the rendered block carries the version on its
#       own metadata line and `parse_managed_block_version` reads it back (the
#       #1816 audit goal survives the move off the marker).
#
# Pure-python CLI surface (`bridge-watchdog.py scan --json`,
# `bridge-docs.py apply`) driven against a temp BRIDGE_HOME -- the operator's
# live tree is never touched; runs identically on macOS and Linux.
#
# macOS-friendly. No heredocs / here-strings in this body (footgun #11).

set -euo pipefail

SMOKE_NAME="2062-watchdog-rendered-block-not-drift"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

MANAGED_START="<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END="<!-- END AGENT BRIDGE DOC MIGRATION -->"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

seed_profile_files() {
  local dir="$1"
  : >"$dir/SOUL.md"
  : >"$dir/MEMORY-SCHEMA.md"
  : >"$dir/MEMORY.md"
  {
    printf '# Session Type\n\n'
    printf -- '- Session Type: static-claude\n'
    printf -- '- Onboarding State: complete\n'
  } >"$dir/SESSION-TYPE.md"
}

# Render the managed block into <home>/CLAUDE.md via the real engine path.
render_block_into_home() {
  local home="$1"
  # A static Claude home that has its required files + a seed CLAUDE.md; `apply`
  # splices the rendered managed block in.
  seed_profile_files "$home"
  printf '# agent\n\ncustom content\n' >"$home/CLAUDE.md"
  "$PY_BIN" "$REPO_ROOT/bridge-docs.py" apply "$(basename "$home")" \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$(dirname "$home")" \
    --source-shared "$SMOKE_TMP_ROOT/nonexistent-source-shared" \
    >/dev/null
}

# field_for <scan-json> <agent> <field> -> prints the field value (json repr).
field_for() {
  "$PY_BIN" -c '
import json, sys
d = json.load(open(sys.argv[1]))
agent, field = sys.argv[2], sys.argv[3]
for r in d.get("agents", []):
    if r.get("agent") == agent:
        print(json.dumps(r.get(field)))
        break
else:
    print("__AGENT_NOT_FOUND__")
' "$1" "$2" "$3"
}

run_scan() {
  local reg="$1"
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
    --agent-registry-json "$reg" 2>/dev/null >"$2"
}

# ===========================================================================
# T1 -- the rendered block satisfies the watchdog (not drift).
# ===========================================================================
test_rendered_block_is_not_drift() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=renderok
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  render_block_into_home "$home"

  # Confirm the rendered marker is the STABLE LITERAL (no ` v=` on the marker
  # line) -- the precondition that makes the watchdog substring match work.
  local block
  block="$(cat "$home/CLAUDE.md")"
  smoke_assert_contains "$block" "$MANAGED_START" \
    "rendered block must carry the literal BEGIN marker (stamp moved off the marker, #2062)"
  case "$block" in
    *"DOC MIGRATION v="*)
      smoke_fail "rendered BEGIN marker must NOT carry a ' v=' stamp suffix (the #2062 regression source)";;
  esac

  local reg="$SMOKE_TMP_ROOT/reg-t1.json"
  {
    printf '[ { "id": "%s", "class": "static", "agent_source": "static", ' "$agent"
    printf '"engine": "claude", "workdir": "%s", "home": "%s" } ]\n' "$home" "$home"
  } >"$reg"

  local out="$SMOKE_TMP_ROOT/out-t1.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "false" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T1: a Claude home carrying the RENDERED managed block was flagged missing_managed_claude_block (the #1816 stamp-on-marker watchdog false positive)"
  smoke_assert_eq '"ok"' "$(field_for "$out" "$agent" status)" \
    "T1: a Claude home carrying the RENDERED managed block must scan status=ok, not drift"
}

# ===========================================================================
# T2 -- MUTATION CONTROL: stamp the version BACK onto the marker -> drift.
# ===========================================================================
test_marker_stamped_block_is_flagged() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=markerstamp
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  render_block_into_home "$home"

  # Reproduce the pre-#2062 shape: drop the in-block version line and move the
  # stamp onto the BEGIN marker. The literal `MANAGED_START` no longer appears.
  "$PY_BIN" -c '
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
# Remove the in-block version metadata line.
t = re.sub(r"<!-- agent-bridge-managed-version:[^\n]*-->\n", "", t)
# Stamp the version onto the BEGIN marker (the regressed shape).
t = t.replace(
    "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->",
    "<!-- BEGIN AGENT BRIDGE DOC MIGRATION v=9.9.9-mut -->",
    1,
)
open(p, "w", encoding="utf-8").write(t)
' "$home/CLAUDE.md"

  # Sanity: the literal marker is gone (the regression precondition).
  local block
  block="$(cat "$home/CLAUDE.md")"
  case "$block" in
    *"$MANAGED_START"*)
      smoke_fail "mutation setup failed: literal marker still present after stamping it";;
  esac

  local reg="$SMOKE_TMP_ROOT/reg-t2.json"
  {
    printf '[ { "id": "%s", "class": "static", "agent_source": "static", ' "$agent"
    printf '"engine": "claude", "workdir": "%s", "home": "%s" } ]\n' "$home" "$home"
  } >"$reg"

  local out="$SMOKE_TMP_ROOT/out-t2.json"
  run_scan "$reg" "$out"

  smoke_assert_eq "true" "$(field_for "$out" "$agent" missing_managed_claude_block)" \
    "T2 (mutation): a version-stamped-MARKER block must trip the watchdog's literal match -- this is the exact #1816 regression #2062 fixes; if this is false the test is vacuous"
}

# ===========================================================================
# T3 -- the in-block version stamp is mechanically readable (#1816 audit goal).
# ===========================================================================
test_inblock_version_readable() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=verread
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  render_block_into_home "$home"

  local engine_version parsed
  engine_version="$(head -n1 "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
  parsed="$("$PY_BIN" -c '
import re, sys, types
mod = types.ModuleType("bdocs"); mod.__file__ = sys.argv[1]
import sys as _s; _s.modules["bdocs"] = mod
exec(compile(open(sys.argv[1]).read(), sys.argv[1], "exec"), mod.__dict__)
print(mod.__dict__["parse_managed_block_version"](open(sys.argv[2], encoding="utf-8").read()) or "")
' "$REPO_ROOT/bridge-docs.py" "$home/CLAUDE.md")"

  smoke_assert_eq "$engine_version" "$parsed" \
    "T3: the in-block version stamp must be parseable back to the engine VERSION ($engine_version) -- the #1816 audit goal survives the move off the marker"
}

# ===========================================================================
# T4 -- parse_managed_block_version is SCOPED to the managed block: a stray
# version comment in the agent's OWN custom content (outside the block) must not
# be mis-read as the managed stamp. Guards the parser-scope hardening (#2062 r2).
# ===========================================================================
test_version_parse_scoped_to_block() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  local agent=scoped
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  render_block_into_home "$home"

  # Inject a DECOY version comment ABOVE the managed block (agent custom content).
  "$PY_BIN" -c '
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
decoy = "<!-- agent-bridge-managed-version: 0.0.0-DECOY -->\n"
open(p, "w", encoding="utf-8").write(decoy + t)
' "$home/CLAUDE.md"

  local engine_version parsed
  engine_version="$(head -n1 "$REPO_ROOT/VERSION" | tr -d '[:space:]')"
  parsed="$("$PY_BIN" -c '
import sys, types
mod = types.ModuleType("bdocs"); mod.__file__ = sys.argv[1]
sys.modules["bdocs"] = mod
exec(compile(open(sys.argv[1]).read(), sys.argv[1], "exec"), mod.__dict__)
print(mod.__dict__["parse_managed_block_version"](open(sys.argv[2], encoding="utf-8").read()) or "")
' "$REPO_ROOT/bridge-docs.py" "$home/CLAUDE.md")"

  smoke_assert_eq "$engine_version" "$parsed" \
    "T4: a DECOY version comment outside the managed block must NOT be returned -- the parser must scope to the block and return the engine VERSION ($engine_version)"
}

main() {
  smoke_run "T1 rendered managed block scans status=ok (not drift)" \
    test_rendered_block_is_not_drift
  smoke_run "T2 mutation control: version-stamped-marker block trips the watchdog (non-vacuous)" \
    test_marker_stamped_block_is_flagged
  smoke_run "T3 in-block version stamp is mechanically readable" \
    test_inblock_version_readable
  smoke_run "T4 version parse is scoped to the block (decoy outside is ignored)" \
    test_version_parse_scoped_to_block
  smoke_log "PASS: $SMOKE_NAME"
}

main "$@"
