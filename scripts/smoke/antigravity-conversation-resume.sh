#!/usr/bin/env bash
# scripts/smoke/antigravity-conversation-resume.sh — Antigravity wave Track A1.
#
# Validates the agy conversation-id detector / resolver / resume surface
# A1 owns in lib/bridge-state.sh:
#   - bridge_detect_antigravity_session_id parses the agy conversation
#     index (history.jsonl) + conversations/ state dir and returns the
#     freshest conversation id for the agent's workdir;
#   - bridge_resolve_resume_session_id (engine=antigravity) accepts a
#     fresh candidate (rc=0) and REJECTS a stale one (empty stdout, rc=1)
#     so the agent launches fresh instead of false-resuming a dead
#     conversation;
#   - the resolved id then flows into C1's bridge_antigravity_dynamic_launch_cmd
#     resume form (`agy --conversation <id>`).
#
# The agy config root honors GEMINI_HOME (bridge_antigravity_config_root,
# Track C1), so the whole fixture lives under an isolated temp tree.
#
# Assertions:
# T1: bridge_detect_antigravity_session_id returns the freshest in-workdir
#     conversation id, ignores a different-workdir conversation, and skips
#     a history row whose `<id>.pb` state file is missing.
# T2: bridge_resolve_resume_session_id accepts a fresh candidate as-is
#     (rc=0) and accepts the freshest id for an empty candidate (rc=0).
# T3: STALE-ID REJECTION — a conversation older than max_age_hours yields
#     empty stdout + rc=1 (caller launches fresh, never false-resumes).
# T4: the detected/resolved id carried into C1's launch builder produces
#     `agy --conversation <id>`; a stale (empty) resolution produces the
#     fresh `-i` bootstrap form instead.

set -euo pipefail

SMOKE_NAME="antigravity-conversation-resume"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

load_bridge_lib() {
  export BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT"
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
}

# Fixture conversation ids.
FRESH_ID="11111111-1111-4111-8111-111111111111"
OLDER_ID="22222222-2222-4222-8222-222222222222"
STALE_ID="33333333-3333-4333-8333-333333333333"
OTHERWD_ID="44444444-4444-4444-8444-444444444444"
GHOST_ID="55555555-5555-4555-8555-555555555555"

GEMINI_ROOT=""
AGY_WORKDIR=""
OTHER_WORKDIR=""

# epoch-ms helpers — agy history timestamps are epoch milliseconds.
now_ms() { printf '%s000' "$(date +%s)"; }
ms_hours_ago() {
  local hours="$1"
  printf '%s000' "$(( $(date +%s) - hours * 3600 ))"
}

seed_fixture() {
  GEMINI_ROOT="$SMOKE_TMP_ROOT/gemini"
  AGY_WORKDIR="$SMOKE_TMP_ROOT/agy-workdir"
  OTHER_WORKDIR="$SMOKE_TMP_ROOT/other-workdir"
  local cfg_dir="$GEMINI_ROOT/antigravity-cli"
  local conv_dir="$cfg_dir/conversations"
  mkdir -p "$conv_dir" "$AGY_WORKDIR" "$OTHER_WORKDIR"

  local history="$cfg_dir/history.jsonl"
  local fresh_ms older_ms stale_ms other_ms ghost_ms
  fresh_ms="$(now_ms)"
  older_ms="$(ms_hours_ago 5)"
  stale_ms="$(ms_hours_ago 240)"   # 10 days — far past the 48h window
  other_ms="$(now_ms)"
  ghost_ms="$(now_ms)"

  # history.jsonl — one JSON object per line (agy real shape: display,
  # timestamp [epoch ms], workspace, conversationId).
  {
    printf '{"display":"older task","timestamp":%s,"workspace":"%s","conversationId":"%s"}\n' \
      "$older_ms" "$AGY_WORKDIR" "$OLDER_ID"
    printf '{"display":"fresh task","timestamp":%s,"workspace":"%s","conversationId":"%s"}\n' \
      "$fresh_ms" "$AGY_WORKDIR" "$FRESH_ID"
    printf '{"display":"other-workdir task","timestamp":%s,"workspace":"%s","conversationId":"%s"}\n' \
      "$other_ms" "$OTHER_WORKDIR" "$OTHERWD_ID"
    # A row whose state file was never written / was pruned — not resumable.
    printf '{"display":"ghost task","timestamp":%s,"workspace":"%s","conversationId":"%s"}\n' \
      "$ghost_ms" "$AGY_WORKDIR" "$GHOST_ID"
    # A row with no conversationId at all (agy writes these) — must be skipped.
    printf '{"display":"no-conversation row","timestamp":%s,"workspace":"%s"}\n' \
      "$fresh_ms" "$AGY_WORKDIR"
  } >"$history"

  # conversation state files. The GHOST_ID intentionally has NO .pb.
  : >"$conv_dir/$FRESH_ID.pb"
  : >"$conv_dir/$OLDER_ID.pb"
  : >"$conv_dir/$STALE_ID.pb"
  : >"$conv_dir/$OTHERWD_ID.pb"

  # Backdate the stale conversation's .pb mtime AND give it a history row
  # so it is a fully-formed-but-old conversation. The resolver's freshness
  # anchor is max(history timestamp, .pb mtime) — both must be old for the
  # rejection to fire.
  printf '{"display":"stale task","timestamp":%s,"workspace":"%s","conversationId":"%s"}\n' \
    "$stale_ms" "$AGY_WORKDIR" "$STALE_ID" >>"$history"
  # touch -t needs [[CC]YY]MMDDhhmm — 10 days back.
  touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null \
    || date -d '10 days ago' +%Y%m%d%H%M)" "$conv_dir/$STALE_ID.pb"
}

assert_detect() {
  local detected
  detected="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_detect_antigravity_session_id "$AGY_WORKDIR" 0 "")"
  smoke_assert_eq "$FRESH_ID" "$detected" \
    "T1: detector returns the freshest in-workdir conversation id"

  # Exclude the freshest id -> detector falls back to the next in-workdir id.
  local detected_excl
  detected_excl="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_detect_antigravity_session_id "$AGY_WORKDIR" 0 "$FRESH_ID")"
  smoke_assert_eq "$OLDER_ID" "$detected_excl" \
    "T1: detector honors the exclude list (falls back to next id)"

  # A different workdir resolves to its own conversation, never the agy one.
  local detected_other
  detected_other="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_detect_antigravity_session_id "$OTHER_WORKDIR" 0 "")"
  smoke_assert_eq "$OTHERWD_ID" "$detected_other" \
    "T1: detector scopes by workspace (no cross-workdir bleed)"

  # The ghost row (no .pb on disk) must never be returned. Excluding both
  # real ids would surface it if the missing-state-file guard were absent.
  local detected_noghost
  detected_noghost="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_detect_antigravity_session_id "$AGY_WORKDIR" 0 \
    "$FRESH_ID,$OLDER_ID,$STALE_ID")"
  smoke_assert_eq "" "$detected_noghost" \
    "T1: detector skips a history row whose .pb state file is missing"
}

assert_resolve_fresh() {
  local accepted rc
  rc=0
  accepted="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_resolve_resume_session_id antigravity agyrole "$AGY_WORKDIR" \
    "$FRESH_ID" 2>/dev/null)" || rc=$?
  smoke_assert_eq "$FRESH_ID" "$accepted" \
    "T2: resolver accepts a fresh candidate as-is"
  smoke_assert_eq "0" "$rc" \
    "T2: resolver returns rc=0 for an accepted fresh candidate"

  # Empty candidate -> resolver picks the freshest eligible conversation.
  rc=0
  accepted="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_resolve_resume_session_id antigravity agyrole "$AGY_WORKDIR" \
    "" 2>/dev/null)" || rc=$?
  smoke_assert_eq "$FRESH_ID" "$accepted" \
    "T2: resolver picks the freshest id for an empty candidate"
  smoke_assert_eq "0" "$rc" \
    "T2: resolver returns rc=0 for an empty-candidate resolution"
}

assert_resolve_stale_rejected() {
  # The stale conversation id is 10 days old — well past BRIDGE_RESUME_MAX_AGE_HOURS
  # (48h). Run with ONLY that conversation visible (exclude every fresher id)
  # so the resolver cannot fall back to a fresh swap — it must reject outright.
  local accepted rc
  rc=0
  accepted="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_resolve_resume_session_id antigravity agyrole "$AGY_WORKDIR" \
    "$STALE_ID" 48 "$FRESH_ID,$OLDER_ID,$GHOST_ID" 2>/dev/null)" || rc=$?
  smoke_assert_eq "" "$accepted" \
    "T3: STALE-ID REJECTION — stale candidate resolves to empty"
  smoke_assert_eq "1" "$rc" \
    "T3: STALE-ID REJECTION — stale candidate returns rc=1 (launch fresh)"

  # With fresher conversations visible, a stale candidate is SWAPPED for the
  # freshest one (rc=2) — never accepted as-is.
  rc=0
  accepted="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_resolve_resume_session_id antigravity agyrole "$AGY_WORKDIR" \
    "$STALE_ID" 48 "" 2>/dev/null)" || rc=$?
  smoke_assert_eq "$FRESH_ID" "$accepted" \
    "T3: stale candidate with a fresher sibling swaps to the fresh id"
  smoke_assert_eq "2" "$rc" \
    "T3: stale-candidate swap returns rc=2"
}

assert_launch_cmd_carries_conversation() {
  # Fresh path: detect -> resolve -> launch builder must carry --conversation.
  local detected accepted resume_cmd
  detected="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_detect_antigravity_session_id "$AGY_WORKDIR" 0 "")"
  accepted="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_resolve_resume_session_id antigravity agyrole "$AGY_WORKDIR" \
    "$detected" 2>/dev/null)"
  resume_cmd="$(bridge_antigravity_dynamic_launch_cmd agyrole 1 "$accepted")"
  smoke_assert_contains "$resume_cmd" "--conversation $FRESH_ID" \
    "T4: resolved fresh id flows into agy --conversation <id>"

  # Stale path: resolver returns empty -> launch builder falls back to the
  # fresh `-i` bootstrap form (no --conversation).
  local stale_accepted rc fresh_cmd
  rc=0
  stale_accepted="$(GEMINI_HOME="$GEMINI_ROOT" \
    bridge_resolve_resume_session_id antigravity agyrole "$AGY_WORKDIR" \
    "$STALE_ID" 48 "$FRESH_ID,$OLDER_ID,$GHOST_ID" 2>/dev/null)" || rc=$?
  fresh_cmd="$(bridge_antigravity_dynamic_launch_cmd agyrole 1 "$stale_accepted")"
  smoke_assert_not_contains "$fresh_cmd" "--conversation" \
    "T4: a stale (empty) resolution does NOT produce --conversation"
  smoke_assert_contains "$fresh_cmd" " -i " \
    "T4: a stale (empty) resolution falls back to the fresh -i bootstrap"
}

assert_other_engines_unaffected() {
  # Regression guard: claude / codex still take their own resolution path,
  # not the new antigravity branch. Non-claude/non-antigravity engines keep
  # the historical passthrough behavior.
  local accepted rc
  rc=0
  accepted="$(bridge_resolve_resume_session_id codex codexrole \
    "$AGY_WORKDIR" "codex-candidate-xyz" 2>/dev/null)" || rc=$?
  smoke_assert_eq "codex-candidate-xyz" "$accepted" \
    "T5: codex engine still uses passthrough resolution (unaffected)"
  smoke_assert_eq "0" "$rc" \
    "T5: codex passthrough returns rc=0"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  load_bridge_lib
  seed_fixture

  smoke_run "T1: detector returns freshest in-workdir id"  assert_detect
  smoke_run "T2: resolver accepts a fresh candidate"        assert_resolve_fresh
  smoke_run "T3: resolver rejects a stale candidate"        assert_resolve_stale_rejected
  smoke_run "T4: resolved id flows into --conversation"     assert_launch_cmd_carries_conversation
  smoke_run "T5: claude/codex resolution unaffected"        assert_other_engines_unaffected

  smoke_log "PASS"
}

main "$@"
