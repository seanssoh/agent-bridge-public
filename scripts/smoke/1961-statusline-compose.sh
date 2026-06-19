#!/usr/bin/env bash
# scripts/smoke/1961-statusline-compose.sh — Issue #1961 regression smoke
# (DISPLAY-ONLY part: renderer-agnostic statusLine composition).
#
# Background (#1961): a bridge agent's project `.claude/settings.json`
# statusLine OVERRIDES the operator's user-global one (Claude Code
# precedence: project > user). On every agent start the bridge runs
# `bridge-hooks.py ensure-hud-usage-tap`, which used to ALWAYS install the
# usage tap STANDALONE (`python3 hud-usage-tap.py > /dev/null`) whenever the
# agent's statusLine slot was empty — suppressing whatever status display the
# operator had configured globally (claude-hud, ccstatusline, a custom
# script). So the operator could enable a plugin but never see its output.
#
# The fix: in the empty-slot branch, look up the operator's user-global
# `~/.claude/settings.json` `statusLine.command` (passed via
# `--operator-global-settings-file`, resolved by the same #11901 resolver the
# shared renderer uses). If the operator set a non-empty renderer, compose
# `tap | <renderer>` instead of the blank standalone tap. RENDERER-AGNOSTIC:
# no plugin-name knowledge — works for ANY renderer. If no global renderer is
# set, the blank standalone tap is installed exactly as before.
#
# Scope guard: this is DISPLAY-ONLY (statusLine). Behavior/security keys
# (hooks / permissions / env / credentials) are explicitly NOT touched here —
# that broad propagation design is tracked in #1964 (v0.17).
#
# Sub-tests:
#   1. non-claude-hud global renderer (a dummy `node`/`echo` command) + empty
#      agent slot => agent gets `tap | <that renderer>` (proves
#      renderer-agnostic; NO plugin-name hardcoding). REVERT TEETH: reverting
#      the compose wire-in makes this fall back to the blank tap = the bug.
#   2. claude-hud-shaped global renderer + empty slot => `tap | <claude-hud>`
#      (the #1961 instance).
#   3. global statusLine ABSENT => blank standalone tap (unchanged fallback).
#   4. global renderer ALREADY tap-composed => installed as-is, no double-tap.
#   5. idempotent: running the ensure command twice => second run is `present`,
#      no further mutation.
#   6. foreign per-agent statusLine (non-empty, non-tap) => never clobbered
#      (no-hud), even when a global renderer exists.

set -euo pipefail

SMOKE_NAME="1961-statusline-compose"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

HOOKS_PY=""
FIXTURE_BRIDGE_HOME=""

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"
  HOOKS_PY="$SMOKE_REPO_ROOT/bridge-hooks.py"
  FIXTURE_BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  mkdir -p "$FIXTURE_BRIDGE_HOME/scripts"
  # A real-looking tap path the composed command will reference.
  : >"$FIXTURE_BRIDGE_HOME/scripts/hud-usage-tap.py"
}

# Write an operator-global ~/.claude/settings.json with the given statusLine
# command JSON snippet ("" => no statusLine key at all). Echoes the path.
write_global_settings() {
  local dir="$1"
  local sl_json="$2"
  mkdir -p "$dir/.claude"
  local path="$dir/.claude/settings.json"
  if [[ -n "$sl_json" ]]; then
    printf '{\n  "statusLine": %s\n}\n' "$sl_json" >"$path"
  else
    printf '{\n  "model": "sonnet"\n}\n' >"$path"
  fi
  printf '%s' "$path"
}

# Write an agent project settings.json with the given statusLine snippet
# ("" => no statusLine key). Echoes the path.
write_agent_settings() {
  local dir="$1"
  local sl_json="$2"
  mkdir -p "$dir/.claude"
  local path="$dir/.claude/settings.json"
  if [[ -n "$sl_json" ]]; then
    printf '{\n  "enabledPlugins": {"x@y": true},\n  "statusLine": %s\n}\n' "$sl_json" >"$path"
  else
    printf '{\n  "enabledPlugins": {"x@y": true}\n}\n' >"$path"
  fi
  printf '%s' "$path"
}

run_ensure() {
  local agent_settings="$1"
  local global_settings="$2"
  python3 "$HOOKS_PY" ensure-hud-usage-tap \
    --settings-file "$agent_settings" \
    --bridge-home "$FIXTURE_BRIDGE_HOME" \
    --python-bin python3 \
    --operator-global-settings-file "$global_settings" \
    --format text
}

agent_command() {
  # Extract the rendered statusLine.command from an agent settings file.
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
sl = data.get("statusLine") or {}
print(sl.get("command", "") if isinstance(sl, dict) else "")
PY
}

assert_non_hud_renderer_composed() {
  local stage="$SMOKE_TMP_ROOT/t1"
  local global agent
  # A deliberately NON-claude-hud renderer: a plain node-runtime command.
  global="$(write_global_settings "$stage/op" \
    '{"type": "command", "command": "exec \"/usr/bin/node\" /opt/ccstatusline/index.js"}')"
  agent="$(write_agent_settings "$stage/agent" "")"

  run_ensure "$agent" "$global" >/dev/null

  local cmd
  cmd="$(agent_command "$agent")"
  # Composed: tap piped into the operator's own renderer. REVERT TEETH —
  # without the compose wire-in this would be the blank standalone tap.
  smoke_assert_contains "$cmd" "hud-usage-tap.py | " \
    "non-claude-hud renderer: tap composed into operator renderer (#1961 renderer-agnostic)"
  smoke_assert_contains "$cmd" "/opt/ccstatusline/index.js" \
    "non-claude-hud renderer preserved verbatim in the composed command"
  smoke_assert_not_contains "$cmd" "> /dev/null" \
    "composed command does NOT discard output (the renderer must render)"
}

assert_claude_hud_renderer_composed() {
  local stage="$SMOKE_TMP_ROOT/t2"
  local global agent
  global="$(write_global_settings "$stage/op" \
    '{"type": "command", "command": "exec \"$HOME/.claude/claude-hud/node_modules/.bin/bun\" \"$HOME/.claude/claude-hud/src/index.ts\""}')"
  agent="$(write_agent_settings "$stage/agent" "")"

  run_ensure "$agent" "$global" >/dev/null

  local cmd
  cmd="$(agent_command "$agent")"
  smoke_assert_contains "$cmd" "hud-usage-tap.py | " \
    "claude-hud renderer: tap composed into the HUD (#1961 visible instance)"
  smoke_assert_contains "$cmd" "claude-hud/src/index.ts" \
    "claude-hud renderer exec target preserved in the composed command"
}

assert_no_global_renderer_blank_standalone() {
  local stage="$SMOKE_TMP_ROOT/t3"
  local global agent
  # Global settings present but NO statusLine key => no renderer.
  global="$(write_global_settings "$stage/op" "")"
  agent="$(write_agent_settings "$stage/agent" "")"

  run_ensure "$agent" "$global" >/dev/null

  local cmd
  cmd="$(agent_command "$agent")"
  smoke_assert_contains "$cmd" "hud-usage-tap.py" \
    "no global renderer: tap still installed"
  smoke_assert_contains "$cmd" "> /dev/null" \
    "no global renderer: tap installed STANDALONE/blank (pre-#1961 fallback unchanged)"
}

assert_global_renderer_already_tapped_not_doubled() {
  local stage="$SMOKE_TMP_ROOT/t4"
  local global agent
  # Operator already hand-composed the tap into their global renderer.
  global="$(write_global_settings "$stage/op" \
    '{"type": "command", "command": "python3 /opt/agent-bridge/scripts/hud-usage-tap.py | exec \"/usr/bin/node\" /opt/ccstatusline/index.js"}')"
  agent="$(write_agent_settings "$stage/agent" "")"

  run_ensure "$agent" "$global" >/dev/null

  local cmd taps
  cmd="$(agent_command "$agent")"
  taps="$(grep -o "hud-usage-tap.py" <<<"$cmd" | wc -l | tr -d ' ')"
  smoke_assert_eq "$taps" "1" \
    "global renderer already tap-composed: installed as-is, NO double-tap (#1961 idempotency edge)"
  smoke_assert_contains "$cmd" "/opt/ccstatusline/index.js" \
    "already-tapped global renderer body preserved"
}

assert_idempotent_second_run_is_noop() {
  local stage="$SMOKE_TMP_ROOT/t5"
  local global agent
  global="$(write_global_settings "$stage/op" \
    '{"type": "command", "command": "exec \"/usr/bin/node\" /opt/ccstatusline/index.js"}')"
  agent="$(write_agent_settings "$stage/agent" "")"

  run_ensure "$agent" "$global" >/dev/null
  local first
  first="$(agent_command "$agent")"

  local out
  out="$(run_ensure "$agent" "$global")"
  smoke_assert_contains "$out" "present" \
    "second ensure run reports present (#1961 re-render is a stable no-op)"

  local second
  second="$(agent_command "$agent")"
  smoke_assert_eq "$second" "$first" \
    "second ensure run does not mutate the composed command (idempotent)"
}

assert_foreign_per_agent_statusline_untouched() {
  local stage="$SMOKE_TMP_ROOT/t6"
  local global agent
  # A global renderer exists, but the agent already has its OWN non-empty,
  # non-tap statusLine. The empty-slot branch must NOT fire — the foreign
  # per-agent statusLine is never clobbered.
  global="$(write_global_settings "$stage/op" \
    '{"type": "command", "command": "exec \"/usr/bin/node\" /opt/ccstatusline/index.js"}')"
  agent="$(write_agent_settings "$stage/agent" \
    '{"type": "command", "command": "/opt/custom/my-own-statusline.sh"}')"

  local out rc
  set +e
  out="$(run_ensure "$agent" "$global")"
  rc=$?
  set -e
  smoke_assert_contains "$out" "no-hud" \
    "foreign per-agent statusLine: left untouched (no-hud), even with a global renderer present"
  smoke_assert_eq "$rc" "1" \
    "no-hud branch returns rc=1 (foreign statusLine not adopted)"

  local cmd
  cmd="$(agent_command "$agent")"
  smoke_assert_eq "$cmd" "/opt/custom/my-own-statusline.sh" \
    "foreign per-agent statusLine.command preserved verbatim (never clobbered)"
}

assert_bad_global_path_degrades_to_blank() {
  # Defensive contract (#1961, codex r1): a malformed / unreadable / missing
  # operator-global settings file must NEVER fail the render — it degrades to
  # the blank standalone tap. The reader catches OSError / JSONDecodeError /
  # RuntimeError / ValueError (the last two cover Path.expanduser() raising on
  # a `~`-prefixed path with no resolvable home).
  local stage="$SMOKE_TMP_ROOT/t7"
  local agent
  agent="$(write_agent_settings "$stage/agent" "")"

  # (a) malformed JSON global => degrade to blank tap, render succeeds (rc 0).
  local bad="$stage/op/.claude/settings.json"
  mkdir -p "$stage/op/.claude"
  printf '{ this is not valid json' >"$bad"
  local out rc
  set +e
  out="$(run_ensure "$agent" "$bad")"
  rc=$?
  set -e
  smoke_assert_eq "$rc" "0" \
    "malformed operator-global settings: render still succeeds (never fails)"
  local cmd
  cmd="$(agent_command "$agent")"
  smoke_assert_contains "$cmd" "> /dev/null" \
    "malformed operator-global settings: degrades to blank standalone tap"

  # (b) missing global file path => same blank-tap degrade.
  local agent2
  agent2="$(write_agent_settings "$stage/agent2" "")"
  run_ensure "$agent2" "$stage/op/.claude/does-not-exist.json" >/dev/null
  local cmd2
  cmd2="$(agent_command "$agent2")"
  smoke_assert_contains "$cmd2" "> /dev/null" \
    "missing operator-global settings file: degrades to blank standalone tap"
}

main() {
  build_fixture

  smoke_run "non-claude-hud global renderer composed (renderer-agnostic + revert teeth)" \
    assert_non_hud_renderer_composed
  smoke_run "claude-hud global renderer composed (#1961 visible instance)" \
    assert_claude_hud_renderer_composed
  smoke_run "no global renderer => blank standalone tap (fallback unchanged)" \
    assert_no_global_renderer_blank_standalone
  smoke_run "global renderer already tap-composed => no double-tap" \
    assert_global_renderer_already_tapped_not_doubled
  smoke_run "idempotent: second ensure run is a stable no-op" \
    assert_idempotent_second_run_is_noop
  smoke_run "foreign per-agent statusLine never clobbered" \
    assert_foreign_per_agent_statusline_untouched
  smoke_run "bad/missing operator-global settings degrade to blank tap (never fails)" \
    assert_bad_global_path_degrades_to_blank

  smoke_log "PASS"
}

main "$@"
