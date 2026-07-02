#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/prompt-parallel-nudge.sh
#
# Pins the Claude-only per-turn operating-reminders hook (UserPromptSubmit
# additionalContext). Operator Sean directive + agb-dev-codex design-agreement:
# a dedicated Claude-only UserPromptSubmit additionalContext hook (NOT the
# timestamp/guard hook) that prints short hardcoded reminders pointing at the
# COMMON-INSTRUCTIONS.md SSOT — (1) parallel-dispatch of independent work
# (§"Background Subagent Delegation" / §"Wave Orchestration") and (2) an early
# "starting" signal for long-running requests (§"Long-running 작업"). Fail-open,
# idempotent, tiny. Never wired into any Codex hook path. (Hook file/verb name
# stays prompt-parallel-nudge.* to avoid rename churn on a just-shipped hook.)
#
# Heredoc-free by design: settings.json is inspected with `grep` + the
# `status-prompt-parallel-nudge-hook` CLI verb (--format shell), NOT an inline
# python-stdin heredoc, so this smoke adds no new heredoc-stdin subprocess
# site (scripts/lint-heredoc-ban.sh baseline stays flat).
#
# Tests:
#   T1: after ensure-prompt-parallel-nudge-hook renders into a fresh Claude
#       settings.json, UserPromptSubmit contains EXACTLY ONE parallel-nudge hook
#       (prompt-parallel-nudge.py) with additionalContext=true.
#   T2 (idempotent): a second ensure re-render reports `unchanged` and still
#       leaves EXACTLY ONE parallel-nudge hook — no duplicate appended.
#   T3: the shipped hook script, when executed, prints the nudge wording
#       (stable substrings 병렬 점검 + fan-out + the SSOT pointer) and exits 0.
#   T4 (Claude-only): the Codex ensure-codex-hooks render does NOT include the
#       parallel-nudge hook.
#   T5 (over-spawn guard present): the emitted string carries the anti-fan-out
#       terms (단일·순차 / 불필요한 fan-out 금지) so a future reword can't
#       silently drop the guardrail.
#   T6 (long-running ack reminder): the SAME hook also carries the
#       second operating reminder (응답 지연 방지 + the Long-running SSOT
#       pointer) with its no-over-ack (즉답·trivial) + exact-first (먼저 실행)
#       carve-outs, so a reword can't silently drop them.
#   T7 (autonomous inbox-progress reminder): the SAME hook carries the THIRD
#       operating reminder ([자율 진행] + the Autonomy & Anti-Stall SSOT
#       pointer). Pins the confirm-first gate guardrails (confirm-first,
#       게이트를 건너뛰라는 뜻이 절대 아니다, 명시적 사전 승인) so a reword can
#       never turn "keep progressing the inbox" into "skip approvals".
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

# Count UserPromptSubmit command hooks that reference the nudge script. Plain
# grep -o (occurrence count, formatting-agnostic) — no heredoc, no JSON parse.
count_nudge_hooks() {
  local settings_file="$1"
  grep -o 'prompt-parallel-nudge.py' "$settings_file" 2>/dev/null | wc -l | tr -d '[:space:]'
}

claude_render_and_dedup() {
  local workdir settings_file payload ensure_out ensure_out2 count count2 nudge_out rc status_out status_shell

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

  # additionalContext=true — read via the status verb's shell payload (no heredoc).
  status_shell="$(
    python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" status-prompt-parallel-nudge-hook \
      --workdir "$workdir" \
      --bridge-home "$BRIDGE_HOME" \
      --python-bin "$(command -v python3)" \
      --format shell
  )"
  smoke_assert_contains "$status_shell" "HOOK_ADDITIONAL_CONTEXT=true" \
    "T1: parallel-nudge hook sets additionalContext=true"
  smoke_assert_contains "$status_shell" "HOOK_STATUS=present" "T1: status verb reports present"

  # status verb (text format) agrees.
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

  # T3 — the shipped hook script, executed, prints the nudge and exits 0.
  # The rendered command points at $BRIDGE_HOME/hooks/... which is not
  # materialized in this isolated temp BRIDGE_HOME; the command shape is
  # asserted above, so here we execute the tracked source script directly.
  nudge_out="$(python3 "$SMOKE_REPO_ROOT/hooks/prompt-parallel-nudge.py")"
  rc=$?
  smoke_assert_eq "0" "$rc" "T3: nudge hook exits 0"
  smoke_assert_contains "$nudge_out" "병렬 점검" "T3: nudge output carries the 병렬 점검 marker"
  smoke_assert_contains "$nudge_out" "fan-out" "T3: nudge output mentions fan-out"
  smoke_assert_contains "$nudge_out" "COMMON-INSTRUCTIONS.md" "T3: nudge points at the SSOT"

  # T5 — over-spawn guardrail terms present so a reword can't silently drop them.
  smoke_assert_contains "$nudge_out" "단일·순차" "T5: nudge keeps the single/sequential carve-out"
  smoke_assert_contains "$nudge_out" "불필요한 fan-out 금지" "T5: nudge keeps the anti-fan-out guardrail"

  # T6 — the SECOND operating reminder (long-running ack) rides the same hook,
  # with its no-over-ack + exact-first-precedence carve-outs, so a reword can't
  # silently drop the guardrails.
  smoke_assert_contains "$nudge_out" "응답 지연 방지" "T6: nudge carries the long-task ack reminder"
  smoke_assert_contains "$nudge_out" "Long-running 작업" "T6: ack points at the Long-running SSOT section"
  smoke_assert_contains "$nudge_out" "즉답·trivial" "T6: ack keeps the no-over-ack carve-out"
  smoke_assert_contains "$nudge_out" "먼저 실행" "T6: ack keeps the exact-first/no-ack precedence carve-out"

  # T7 — the THIRD operating reminder (autonomous inbox-progress) rides the same
  # hook. Its confirm-first gate guardrails must survive any reword so the "keep
  # progressing" nudge can never be read as "skip approvals".
  smoke_assert_contains "$nudge_out" "[자율 진행]" "T7: nudge carries the autonomous-progress reminder"
  smoke_assert_contains "$nudge_out" "confirm-first" "T7: autonomy keeps the confirm-first gate"
  smoke_assert_contains "$nudge_out" "게이트를 건너뛰라는 뜻이 절대 아니다" "T7: autonomy keeps the anti-bulldoze clause"
  smoke_assert_contains "$nudge_out" "명시적 사전 승인" "T7: autonomy keeps the explicit-prior-approval requirement"
  smoke_assert_contains "$nudge_out" "기준: COMMON-INSTRUCTIONS.md Autonomy & Anti-Stall" "T7: autonomy points at the SSOT section"
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
