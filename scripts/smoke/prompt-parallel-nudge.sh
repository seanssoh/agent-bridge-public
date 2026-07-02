#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/prompt-parallel-nudge.sh
#
# Pins the Claude-only per-turn parallel-dispatch nudge hook
# (UserPromptSubmit additionalContext). Operator Sean directive + agb-dev-codex
# design-agreement: a NEW dedicated Claude-only UserPromptSubmit
# additionalContext hook (NOT the timestamp/guard hook) that prints a hardcoded
# 1-2 line reminder pointing at the COMMON-INSTRUCTIONS.md SSOT
# (§"Background Subagent Delegation" / §"Wave Orchestration"). Fail-open,
# idempotent, tiny. Never wired into any Codex hook path.
#
# Tests:
#   T1: after ensure-prompt-parallel-nudge-hook renders into a fresh Claude
#       settings.json, UserPromptSubmit contains EXACTLY ONE parallel-nudge hook
#       (prompt-parallel-nudge.py) with additionalContext=true.
#   T2 (idempotent): a second ensure re-render reports `unchanged` and still
#       leaves EXACTLY ONE parallel-nudge hook — no duplicate appended.
#   T3: the rendered hook COMMAND, when executed, prints the nudge wording
#       (stable substrings 병렬 점검 + fan-out) and exits 0.
#   T4 (Claude-only): the Codex ensure-codex-hooks render does NOT include the
#       parallel-nudge hook.
#   T5 (over-spawn guard present): the emitted string carries the anti-fan-out
#       terms (단일·순차 / 불필요한 fan-out 금지) so a future reword can't
#       silently drop the guardrail.
#
# Host-agnostic: no sudo, isolated BRIDGE_HOME, hermetic temp workdir.

set -uo pipefail

SMOKE_NAME="prompt-parallel-nudge"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Count UserPromptSubmit command hooks whose command mentions the nudge script.
count_nudge_hooks() {
  local settings_file="$1"
  python3 - "$settings_file" <<'PY'
import json
import sys
from pathlib import Path

settings_file = sys.argv[1]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
groups = payload.get("hooks", {}).get("UserPromptSubmit", [])
count = 0
for group in groups:
    for hook in group.get("hooks", []):
        if "prompt-parallel-nudge.py" in str(hook.get("command") or ""):
            count += 1
print(count)
PY
}

# Print the single parallel-nudge hook command (or empty).
nudge_hook_command() {
  local settings_file="$1"
  python3 - "$settings_file" <<'PY'
import json
import sys
from pathlib import Path

settings_file = sys.argv[1]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
groups = payload.get("hooks", {}).get("UserPromptSubmit", [])
for group in groups:
    for hook in group.get("hooks", []):
        if "prompt-parallel-nudge.py" in str(hook.get("command") or ""):
            print(str(hook.get("command") or ""))
            raise SystemExit(0)
PY
}

claude_render_and_dedup() {
  local workdir settings_file payload ensure_out ensure_out2 count count2 command nudge_out rc status_out

  workdir="$SMOKE_TMP_ROOT/claude-nudge-workdir"
  mkdir -p "$workdir"
  settings_file="$workdir/.claude/settings.json"

  # T1 — first render appends exactly one parallel-nudge hook.
  ensure_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-prompt-parallel-nudge-hook \
      --workdir "$workdir" \
      --bridge-home "$BRIDGE_HOME" \
      --python-bin "$(command -v python3)"
  )"
  smoke_assert_contains "$ensure_out" "prompt_parallel_nudge_hook: present" "ensure reports hook present"
  smoke_assert_file_exists "$settings_file" "Claude settings.json rendered"

  payload="$(cat "$settings_file")"
  smoke_assert_contains "$payload" "prompt-parallel-nudge.py" "settings include parallel-nudge hook command"
  smoke_assert_contains "$payload" "$BRIDGE_HOME/hooks/prompt-parallel-nudge.py" \
    "parallel-nudge hook uses absolute bridge-home path"

  count="$(count_nudge_hooks "$settings_file")"
  smoke_assert_eq "1" "$count" "T1: exactly one parallel-nudge hook after first render"

  # additionalContext=true on the nudge hook.
  local additional_context
  additional_context="$(
    python3 - "$settings_file" <<'PY'
import json
import sys
from pathlib import Path

settings_file = sys.argv[1]
payload = json.loads(Path(settings_file).read_text(encoding="utf-8"))
groups = payload.get("hooks", {}).get("UserPromptSubmit", [])
result = "false"
for group in groups:
    for hook in group.get("hooks", []):
        if "prompt-parallel-nudge.py" in str(hook.get("command") or ""):
            result = "true" if bool(hook.get("additionalContext")) is True else "false"
print(result)
PY
  )"
  smoke_assert_eq "true" "$additional_context" "T1: parallel-nudge hook sets additionalContext=true"

  # status verb agrees.
  status_out="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-prompt-parallel-nudge-hook \
      --workdir "$workdir" \
      --bridge-home "$BRIDGE_HOME" \
      --python-bin "$(command -v python3)"
  )"
  smoke_assert_contains "$status_out" "prompt_parallel_nudge_hook: present" "status reports hook present"

  # T2 — re-render is idempotent: unchanged + still exactly one.
  ensure_out2="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-prompt-parallel-nudge-hook \
      --workdir "$workdir" \
      --bridge-home "$BRIDGE_HOME" \
      --python-bin "$(command -v python3)" \
      --format shell
  )"
  smoke_assert_contains "$ensure_out2" "HOOK_STATUS=unchanged" "T2: re-render reports unchanged"
  count2="$(count_nudge_hooks "$settings_file")"
  smoke_assert_eq "1" "$count2" "T2: still exactly one parallel-nudge hook after re-render"

  # T3 — the rendered command, executed, prints the nudge and exits 0.
  command="$(nudge_hook_command "$settings_file")"
  [[ -n "$command" ]] || smoke_fail "T3: could not extract parallel-nudge hook command"
  # The rendered command points at $BRIDGE_HOME/hooks/... which is not
  # materialized in this isolated temp BRIDGE_HOME; execute the tracked source
  # script directly (the command shape is asserted above; this checks runtime
  # output of the shipped hook).
  nudge_out="$(python3 "$SMOKE_REPO_ROOT/hooks/prompt-parallel-nudge.py")"
  rc=$?
  smoke_assert_eq "0" "$rc" "T3: nudge hook exits 0"
  smoke_assert_contains "$nudge_out" "병렬 점검" "T3: nudge output carries the 병렬 점검 marker"
  smoke_assert_contains "$nudge_out" "fan-out" "T3: nudge output mentions fan-out"
  smoke_assert_contains "$nudge_out" "COMMON-INSTRUCTIONS.md" "T3: nudge points at the SSOT"

  # T5 — over-spawn guardrail terms present so a reword can't silently drop them.
  smoke_assert_contains "$nudge_out" "단일·순차" "T5: nudge keeps the single/sequential carve-out"
  smoke_assert_contains "$nudge_out" "불필요한 fan-out 금지" "T5: nudge keeps the anti-fan-out guardrail"
}

codex_render_excludes_nudge() {
  local hooks_file payload

  hooks_file="$SMOKE_TMP_ROOT/codex-home/.codex/hooks.json"
  python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
    --bridge-home "$BRIDGE_HOME" \
    --python-bin "$(command -v python3)" \
    --codex-hooks-file "$hooks_file" >/dev/null

  smoke_assert_file_exists "$hooks_file" "codex hooks file rendered"
  payload="$(cat "$hooks_file")"
  # T4 — Claude-only: the codex render must NOT carry the parallel-nudge hook.
  smoke_assert_not_contains "$payload" "prompt-parallel-nudge.py" \
    "T4: codex hooks render excludes the Claude-only parallel-nudge hook"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "prompt-parallel-nudge"
  # Point HOME at an empty temp dir so the stable-hooks-dir resolver keeps this
  # temp BRIDGE_HOME's own hooks path (no host canonical install to fence to),
  # matching the hermetic pattern in scripts/smoke/hooks.sh.
  HOME="$SMOKE_TMP_ROOT/fake-home"
  export HOME
  mkdir -p "$HOME"
  smoke_run "Claude parallel-nudge render + idempotent dedup + runtime output" claude_render_and_dedup
  smoke_run "Codex render excludes Claude-only parallel-nudge hook" codex_render_excludes_nudge
  smoke_log "passed"
}

main "$@"
