#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1968-forget-session-fresh.sh — Issue #1968.
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` directly (matches
# scripts/smoke/1015-resume-claude-config-dir.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1968-forget-session-fresh][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# `agb agent forget-session <agent>` clears the persisted AGENT_SESSION_ID but
# the resolver (bridge_resolve_resume_session_id, #1769) falls back to the
# project dir's most-recent in-window `.jsonl` transcript and resumes IT when
# the persisted id is empty. The on-disk transcript ids were never added to the
# per-agent resume-quarantine, so forget-session was INERT while a transcript
# remained: `bridge-run.sh <agent> --dry-run` still emitted `claude --resume
# <old-id>` even after a "successful" forget (cm-prod live evidence). A reseeded
# SKILL bot kept resuming the pre-reseed conversation.
#
# The fix: the EXPLICIT forget-session path now enumerates the agent's OWN
# in-window transcripts (all of them, not just the newest) and quarantines their
# session-ids via the guarded bridge_agent_resume_quarantine_add, so the
# resolver's auto-exclude has nothing stale left to re-select → genuinely fresh.
# A normal restart's recovery fallback (no forget) is untouched, and the
# add-side foreign-transcript guard still refuses an operator-global session.
#
# Test plan:
#   E2E teeth (the exact issue repro, via real bridge-run.sh / bridge-agent.sh
#   subprocesses against a synthesized roster-local + on-disk transcripts):
#     E1. BEFORE forget (non-vacuous): empty persisted id + continue=1 + an
#         on-disk transcript → `bridge-run.sh --dry-run` launch HAS `--resume
#         <id>` (the bug exists for real, so the AFTER assertion is meaningful).
#     E2. forget-session reports transcripts_quarantined >= 1.
#     E3. AFTER forget: `bridge-run.sh --dry-run` launch has session_id="" AND
#         NO `--resume` at all (the teeth — fresh launch).
#
#   Library-level coverage (sourced shims, deterministic):
#     L1. enumeration lists ALL in-window transcripts newest-first.
#     L2. multiple in-window transcripts → ALL quarantined; the resolver
#         fallback resolves EMPTY (can't walk to a surviving sibling).
#     L3. a transcript created AFTER the forget enumeration is NOT quarantined
#         (next restart resumes it) — proves forget only affects pre-forget ids.
#     L4. a foreign/operator-global transcript is NOT quarantined (the existing
#         add-side foreign guard holds).
#     L5. NON-forget recovery path intact: with NO quarantine, the resolver
#         fallback still resolves the freshest transcript (the legitimate crash/
#         restart recovery #1769 must not regress).
#
#   Mutation teeth:
#     T1. the forget-session quarantine hook is present in bridge-agent.sh AND
#         the enumeration helper is present in lib/bridge-state.sh — removing
#         either re-opens the bug (E3 would regain `--resume`).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout). The smoke
# never reads or writes the operator's live ~/.claude or bridge runtime.
#
# Footgun #11: plain `printf` / argv-driven writers only — no command
# substitution feeding a heredoc-stdin into a bridge function.

set -euo pipefail

SMOKE_NAME="1968-forget-session-fresh"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Seed a transcript `.jsonl` under <config_dir>/projects/<slug>/ with a chosen
# age (mtime older-by N seconds) so newest-first ordering is deterministic.
seed_transcript() {
  local config_dir="$1" workdir="$2" sid="$3" age_secs="${4:-0}"
  local slug="${workdir//\//-}"
  mkdir -p "$config_dir/projects/$slug"
  local f="$config_dir/projects/$slug/$sid.jsonl"
  printf '{"sessionId":"%s"}\n' "$sid" >"$f"
  if (( age_secs > 0 )); then
    # Backdate mtime so a later-seeded transcript sorts newer.
    touch -t "$(date -v-"${age_secs}"S '+%Y%m%d%H%M.%S' 2>/dev/null \
      || date -d "@$(( $(date +%s) - age_secs ))" '+%Y%m%d%H%M.%S')" "$f"
  fi
}

# =====================================================================
# E2E layer — real bridge-run.sh / bridge-agent.sh subprocesses.
# =====================================================================
#
# A synthesized roster-local declares a real static Claude agent (NO stub of
# the resolver — we want the genuine transcript-scan fallback). HOME is pinned
# at the agent's config root so the resolver's daemon-HOME fallback lands on
# our seeded transcripts (non-isolated path: claude_config_dir resolves empty,
# helper uses $HOME/.claude).
E2E_AGENT="fsf-e2e"
E2E_HOME="$SMOKE_TMP_ROOT/e2e-home"
E2E_WORKDIR="$SMOKE_TMP_ROOT/e2e-work"
mkdir -p "$E2E_HOME/.claude" "$E2E_WORKDIR"
E2E_WORKDIR="$(cd -P "$E2E_WORKDIR" && pwd -P)"
E2E_SID_OLD="aaaa1111-1968-old-transcript"
E2E_SID_NEW="bbbb2222-1968-new-transcript"
# Two in-window transcripts; NEW is freshest (the resolver would pick it).
seed_transcript "$E2E_HOME/.claude" "$E2E_WORKDIR" "$E2E_SID_OLD" 120
seed_transcript "$E2E_HOME/.claude" "$E2E_WORKDIR" "$E2E_SID_NEW" 10

# Roster-local: a static Claude agent with continue=1 and EMPTY persisted id —
# exactly the post-forget / lost-state shape that triggers the resolver
# fallback. No resolver override: the real bridge_claude_resume_session_id_for_agent
# scans HOME/.claude transcripts. BRIDGE_AGENT_LAUNCH_CMD is required for the
# static builder to run (and to carry the --resume the bug appends).
{
  printf '%s\n' "bridge_add_agent_id_if_missing \"$E2E_AGENT\""
  printf '%s\n' "BRIDGE_AGENT_DESC[\"$E2E_AGENT\"]=\"1968 forget-session e2e fixture\""
  printf '%s\n' "BRIDGE_AGENT_ENGINE[\"$E2E_AGENT\"]=\"claude\""
  printf '%s\n' "BRIDGE_AGENT_SESSION[\"$E2E_AGENT\"]=\"${E2E_AGENT}-sess\""
  printf '%s\n' "BRIDGE_AGENT_WORKDIR[\"$E2E_AGENT\"]=\"$E2E_WORKDIR\""
  printf '%s\n' "BRIDGE_AGENT_LOOP[\"$E2E_AGENT\"]=0"
  printf '%s\n' "BRIDGE_AGENT_CONTINUE[\"$E2E_AGENT\"]=1"
  printf '%s\n' "BRIDGE_AGENT_SOURCE[\"$E2E_AGENT\"]=\"static\""
  printf '%s\n' "BRIDGE_AGENT_LAUNCH_CMD[\"$E2E_AGENT\"]=\"claude\""
} >"$BRIDGE_ROSTER_LOCAL_FILE"

# launch.history present => the resume gate takes the LOST-STATE branch (the
# bug), not the fresh-first-wake carve-out: empty persisted id + an on-disk
# transcript → the resolver fallback re-selects the freshest transcript.
mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR/$E2E_AGENT"
: >"$BRIDGE_ACTIVE_AGENT_DIR/$E2E_AGENT/launch.history"

# Run a bridge-run.sh dry-run for the e2e agent under the pinned HOME; capture
# the `launch=` and `session_id=` lines. continue stays 1; an empty persisted
# id drives the resolver fallback.
e2e_dry_run() {
  HOME="$E2E_HOME" \
    bash "$REPO_ROOT/bridge-run.sh" "$E2E_AGENT" --dry-run 2>/dev/null
}

case_e1_before_forget_has_resume() {
  local out launch
  out="$(e2e_dry_run)"
  launch="$(printf '%s\n' "$out" | sed -n 's/^launch=//p' | head -n1)"
  smoke_assert_contains "$launch" "--resume" \
    "E1 (non-vacuous): BEFORE forget the dry-run launch resumes a transcript"
}

case_e2_forget_reports_quarantine() {
  local out qn
  out="$(HOME="$E2E_HOME" \
    bash "$REPO_ROOT/bridge-agent.sh" forget-session "$E2E_AGENT" 2>/dev/null)"
  qn="$(printf '%s\n' "$out" | sed -n 's/^transcripts_quarantined: //p' | head -n1)"
  [[ "$qn" =~ ^[0-9]+$ ]] || smoke_fail "E2: transcripts_quarantined not numeric: '$qn'"
  (( qn >= 1 )) || smoke_fail "E2: forget-session quarantined $qn transcripts (expected >= 1)"
}

case_e3_after_forget_no_resume() {
  local out launch sid
  out="$(e2e_dry_run)"
  launch="$(printf '%s\n' "$out" | sed -n 's/^launch=//p' | head -n1)"
  sid="$(printf '%s\n' "$out" | sed -n 's/^session_id=//p' | head -n1)"
  smoke_assert_eq "" "$sid" \
    "E3: AFTER forget the resolved session_id is empty"
  smoke_assert_not_contains "$launch" "--resume" \
    "E3 (teeth): AFTER forget the dry-run launch has NO --resume — fresh"
}

# E4 (codex review BLOCKING r1+r2 — cap completeness): forget-session must
# neutralize EVERY in-window transcript even when their count exceeds the
# resume-quarantine cap. A naive newest-first feed would evict the freshest id;
# a bounded ceiling (an earlier fix iteration) would leave the over-ceiling
# oldest entries unrecorded and the resolver would resume the freshest of those
# stale survivors. The cap fix (raise the forget cap to fit the WHOLE set, no
# ceiling + oldest-first safety net) must leave NO `--resume` regardless of how
# many transcripts exist. This fixture seeds CAP_N (24) transcripts under a LOW
# default cap (2): 24 > the old ceiling (cap*10 = 20), so it is non-vacuous
# against BOTH the newest-first-evicts-freshest regression AND the ceiling-
# leaves-oldest-stale regression.
CAP_AGENT="fsf-cap"
CAP_HOME="$SMOKE_TMP_ROOT/cap-home"
CAP_WORKDIR="$SMOKE_TMP_ROOT/cap-work"
CAP_N=24
mkdir -p "$CAP_HOME/.claude" "$CAP_WORKDIR"
CAP_WORKDIR="$(cd -P "$CAP_WORKDIR" && pwd -P)"
# CAP_N in-window transcripts, each a distinct age (oldest first) so newest-
# first ordering is fully defined. Newest gets the smallest backdate.
cap_i=0
while (( cap_i < CAP_N )); do
  # age in seconds: oldest = CAP_N*10, newest = 10. Zero-padded id for sort sanity.
  cap_age=$(( (CAP_N - cap_i) * 10 ))
  cap_sid="$(printf 'cap%04d-1968-transcript' "$cap_i")"
  seed_transcript "$CAP_HOME/.claude" "$CAP_WORKDIR" "$cap_sid" "$cap_age"
  cap_i=$(( cap_i + 1 ))
done
{
  printf '%s\n' "bridge_add_agent_id_if_missing \"$CAP_AGENT\""
  printf '%s\n' "BRIDGE_AGENT_DESC[\"$CAP_AGENT\"]=\"1968 cap fixture\""
  printf '%s\n' "BRIDGE_AGENT_ENGINE[\"$CAP_AGENT\"]=\"claude\""
  printf '%s\n' "BRIDGE_AGENT_SESSION[\"$CAP_AGENT\"]=\"${CAP_AGENT}-sess\""
  printf '%s\n' "BRIDGE_AGENT_WORKDIR[\"$CAP_AGENT\"]=\"$CAP_WORKDIR\""
  printf '%s\n' "BRIDGE_AGENT_LOOP[\"$CAP_AGENT\"]=0"
  printf '%s\n' "BRIDGE_AGENT_CONTINUE[\"$CAP_AGENT\"]=1"
  printf '%s\n' "BRIDGE_AGENT_SOURCE[\"$CAP_AGENT\"]=\"static\""
  printf '%s\n' "BRIDGE_AGENT_LAUNCH_CMD[\"$CAP_AGENT\"]=\"claude\""
} >>"$BRIDGE_ROSTER_LOCAL_FILE"
mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR/$CAP_AGENT"
: >"$BRIDGE_ACTIVE_AGENT_DIR/$CAP_AGENT/launch.history"

case_e4_cap_keeps_freshest_quarantined() {
  # Sanity: BEFORE forget the dry-run resumes the freshest (the bug shape).
  local before
  before="$(HOME="$CAP_HOME" bash "$REPO_ROOT/bridge-run.sh" "$CAP_AGENT" --dry-run 2>/dev/null \
    | sed -n 's/^launch=//p' | head -n1)"
  smoke_assert_contains "$before" "--resume" \
    "E4 (non-vacuous): BEFORE forget the cap agent resumes a transcript"

  # forget-session under a LOW default cap (2) with CAP_N(24) transcripts →
  # 24 > old ceiling(20): exercises the no-ceiling completeness path.
  HOME="$CAP_HOME" BRIDGE_RESUME_QUARANTINE_CAP=2 \
    bash "$REPO_ROOT/bridge-agent.sh" forget-session "$CAP_AGENT" >/dev/null 2>&1

  # AFTER forget the dry-run must have NO --resume: every in-window transcript
  # (all 24) was quarantined, so the resolver fallback has nothing to resume.
  local after
  after="$(HOME="$CAP_HOME" bash "$REPO_ROOT/bridge-run.sh" "$CAP_AGENT" --dry-run 2>/dev/null \
    | sed -n 's/^launch=//p' | head -n1)"
  smoke_assert_not_contains "$after" "--resume" \
    "E4 (teeth): forget with >>cap transcripts still leaves NO --resume (cap completeness)"
}

# =====================================================================
# Library layer — sourced shims, deterministic fine-grained coverage.
# =====================================================================
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

declare -F bridge_agent_list_resumable_transcripts >/dev/null \
  || smoke_fail "bridge_agent_list_resumable_transcripts not defined (#1968 helper missing)"
declare -F bridge_agent_resume_quarantine_add >/dev/null \
  || smoke_fail "bridge_agent_resume_quarantine_add not defined"
declare -F bridge_claude_resume_session_id_for_agent >/dev/null \
  || smoke_fail "bridge_claude_resume_session_id_for_agent not defined"

# Register a library-level agent whose config dir is the daemon HOME (pinned at
# a temp dir) so enumeration + quarantine + resolve all key off seeded files.
LIB_AGENT="fsf-lib"
LIB_HOME="$SMOKE_TMP_ROOT/lib-home"
LIB_WORKDIR="$SMOKE_TMP_ROOT/lib-work"
mkdir -p "$LIB_HOME/.claude" "$LIB_WORKDIR"
LIB_WORKDIR="$(cd -P "$LIB_WORKDIR" && pwd -P)"
export HOME="$LIB_HOME"

bridge_reset_roster_maps
BRIDGE_AGENT_IDS=("$LIB_AGENT")
BRIDGE_AGENT_DESC["$LIB_AGENT"]="$LIB_AGENT 1968 lib fixture"
BRIDGE_AGENT_ENGINE["$LIB_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$LIB_AGENT"]="$LIB_AGENT"
BRIDGE_AGENT_WORKDIR["$LIB_AGENT"]="$LIB_WORKDIR"
BRIDGE_AGENT_LOOP["$LIB_AGENT"]="0"
BRIDGE_AGENT_CONTINUE["$LIB_AGENT"]="1"
BRIDGE_AGENT_SOURCE["$LIB_AGENT"]="static"
BRIDGE_AGENT_CREATED_AT["$LIB_AGENT"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$LIB_AGENT"]=""

LIB_SID_A="cccc1111-1968-lib-a"   # oldest
LIB_SID_B="dddd2222-1968-lib-b"   # middle
LIB_SID_C="eeee3333-1968-lib-c"   # newest
seed_transcript "$LIB_HOME/.claude" "$LIB_WORKDIR" "$LIB_SID_A" 180
seed_transcript "$LIB_HOME/.claude" "$LIB_WORKDIR" "$LIB_SID_B" 90
seed_transcript "$LIB_HOME/.claude" "$LIB_WORKDIR" "$LIB_SID_C" 5

case_l1_enumeration_lists_all_newest_first() {
  local listed
  listed="$(bridge_agent_list_resumable_transcripts "$LIB_AGENT" 2>/dev/null)"
  # Newest-first: C, B, A.
  local expected
  expected="$(printf '%s\n%s\n%s' "$LIB_SID_C" "$LIB_SID_B" "$LIB_SID_A")"
  smoke_assert_eq "$expected" "$listed" \
    "L1: enumeration lists ALL in-window transcripts newest-first"
}

case_l2_all_quarantined_resolver_empty() {
  local sid
  bridge_agent_resume_quarantine_clear "$LIB_AGENT" 2>/dev/null || true
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    bridge_agent_resume_quarantine_add "$LIB_AGENT" "$sid" "forget-session" 2>/dev/null || true
  done < <(bridge_agent_list_resumable_transcripts "$LIB_AGENT" 2>/dev/null)

  # All three must be in the quarantine.
  local ids
  ids="$(bridge_agent_resume_quarantine_ids "$LIB_AGENT" 2>/dev/null)"
  smoke_assert_contains "$ids" "$LIB_SID_A" "L2: oldest transcript quarantined"
  smoke_assert_contains "$ids" "$LIB_SID_B" "L2: middle transcript quarantined"
  smoke_assert_contains "$ids" "$LIB_SID_C" "L2: newest transcript quarantined"

  # The resolver fallback must now resolve EMPTY — it cannot walk to a
  # surviving sibling because every in-window transcript is quarantined.
  BRIDGE_AGENT_SESSION_ID["$LIB_AGENT"]=""
  local resolved rc=0
  set +e
  resolved="$(bridge_claude_resume_session_id_for_agent "$LIB_AGENT" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "" "$resolved" \
    "L2 (teeth): all transcripts quarantined → resolver fallback resolves EMPTY"
}

case_l3_post_forget_transcript_not_quarantined() {
  # A transcript created AFTER the forget enumeration (the new fresh session)
  # is NOT in the quarantine, so a later restart resumes it normally.
  local fresh_sid="ffff4444-1968-post-forget"
  seed_transcript "$LIB_HOME/.claude" "$LIB_WORKDIR" "$fresh_sid" 0
  local ids
  ids="$(bridge_agent_resume_quarantine_ids "$LIB_AGENT" 2>/dev/null)"
  smoke_assert_not_contains "$ids" "$fresh_sid" \
    "L3: a transcript created after forget is NOT quarantined"
  # And the resolver now resolves it (the legitimate next-restart resume).
  BRIDGE_AGENT_SESSION_ID["$LIB_AGENT"]=""
  local resolved
  resolved="$(bridge_claude_resume_session_id_for_agent "$LIB_AGENT" 2>/dev/null || true)"
  smoke_assert_eq "$fresh_sid" "$resolved" \
    "L3: resolver resumes the post-forget transcript (next restart unaffected)"
}

case_l4_foreign_transcript_not_quarantined() {
  # The add-side foreign guard refuses an operator-global session: a transcript
  # whose `.jsonl` exists in the operator/controller HOME projects dir but NOT
  # under the agent's OWN config dir. Pin a controlled controller HOME
  # (BRIDGE_CONTROLLER_HOME) and seed the transcript ONLY there, under the
  # agent's workdir slug — the agent's own config dir (non-iso → resolves empty)
  # does not contain it, so the id is proven-foreign and the add must refuse it.
  local foreign_agent="fsf-foreign"
  local foreign_workdir="$SMOKE_TMP_ROOT/foreign-work"
  local op_home="$SMOKE_TMP_ROOT/operator-home"
  mkdir -p "$foreign_workdir" "$op_home/.claude"
  foreign_workdir="$(cd -P "$foreign_workdir" && pwd -P)"
  op_home="$(cd -P "$op_home" && pwd -P)"
  local _saved_controller_home="${BRIDGE_CONTROLLER_HOME:-}"
  export BRIDGE_CONTROLLER_HOME="$op_home"

  BRIDGE_AGENT_IDS+=("$foreign_agent")
  BRIDGE_AGENT_DESC["$foreign_agent"]="$foreign_agent foreign-guard fixture"
  BRIDGE_AGENT_ENGINE["$foreign_agent"]="claude"
  BRIDGE_AGENT_SESSION["$foreign_agent"]="$foreign_agent"
  BRIDGE_AGENT_WORKDIR["$foreign_agent"]="$foreign_workdir"
  BRIDGE_AGENT_SOURCE["$foreign_agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$foreign_agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$foreign_agent"]=""

  # Seed the transcript ONLY in the controller HOME (foreign), under the agent's
  # resolved workdir slug — never under the agent's own config dir.
  local foreign_sid="9999dead-1968-operator-global"
  local wd
  wd="$(bridge_agent_workdir "$foreign_agent")"
  seed_transcript "$op_home/.claude" "$wd" "$foreign_sid" 0

  # Sanity: the guard must classify it foreign (so the add refuses).
  bridge_resume_quarantine_id_is_foreign "$foreign_agent" "$foreign_sid" "$wd" \
    || smoke_fail "L4 fixture: id not classified foreign — guard precondition wrong"

  bridge_agent_resume_quarantine_clear "$foreign_agent" 2>/dev/null || true
  bridge_agent_resume_quarantine_add "$foreign_agent" "$foreign_sid" "forget-session" 2>/dev/null || true
  local ids
  ids="$(bridge_agent_resume_quarantine_ids "$foreign_agent" 2>/dev/null)"
  smoke_assert_not_contains "$ids" "$foreign_sid" \
    "L4: a foreign/operator-global transcript is NOT quarantined (guard holds)"

  if [[ -n "$_saved_controller_home" ]]; then
    export BRIDGE_CONTROLLER_HOME="$_saved_controller_home"
  else
    unset BRIDGE_CONTROLLER_HOME
  fi
}

case_l5_non_forget_recovery_intact() {
  # The legitimate crash/restart recovery (#1769): with NO quarantine, the
  # resolver fallback still resolves the freshest transcript. This is the path
  # forget MUST NOT regress — only the explicit forget quarantines.
  local rec_agent="fsf-recover"
  local rec_workdir="$SMOKE_TMP_ROOT/recover-work"
  mkdir -p "$rec_workdir"
  rec_workdir="$(cd -P "$rec_workdir" && pwd -P)"
  BRIDGE_AGENT_IDS+=("$rec_agent")
  BRIDGE_AGENT_DESC["$rec_agent"]="$rec_agent recovery fixture"
  BRIDGE_AGENT_ENGINE["$rec_agent"]="claude"
  BRIDGE_AGENT_SESSION["$rec_agent"]="$rec_agent"
  BRIDGE_AGENT_WORKDIR["$rec_agent"]="$rec_workdir"
  BRIDGE_AGENT_LOOP["$rec_agent"]="0"
  BRIDGE_AGENT_CONTINUE["$rec_agent"]="1"
  BRIDGE_AGENT_SOURCE["$rec_agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$rec_agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$rec_agent"]=""

  local rec_sid="abcd5678-1968-recover"
  seed_transcript "$LIB_HOME/.claude" "$rec_workdir" "$rec_sid" 0
  # No forget, no quarantine: the resolver recovers the transcript.
  local resolved
  resolved="$(bridge_claude_resume_session_id_for_agent "$rec_agent" 2>/dev/null || true)"
  smoke_assert_eq "$rec_sid" "$resolved" \
    "L5: NON-forget restart still resolves the transcript (recovery intact)"
}

case_t1_mutation_teeth_hook_present() {
  # The E3 freshness depends on (a) the forget-session quarantine loop in
  # bridge-agent.sh and (b) the enumeration helper in lib/bridge-state.sh.
  # Removing either re-opens the #1968 bug; pin both textually so a silent
  # removal fails this smoke loudly.
  local agent_src="$REPO_ROOT/bridge-agent.sh"
  local state_src="$REPO_ROOT/lib/bridge-state.sh"
  grep -q 'bridge_agent_list_resumable_transcripts' "$agent_src" \
    || smoke_fail "T1: forget-session no longer enumerates transcripts (bridge-agent.sh) — #1968 regressed"
  grep -q 'bridge_agent_resume_quarantine_add "\$agent" "\${_resumable\[\$_i\]}" "forget-session"' "$agent_src" \
    || smoke_fail "T1: forget-session no longer quarantines enumerated ids — #1968 regressed"
  # The cap fix feeds OLDEST-first (reverse loop) + raises the forget cap; pin
  # both so a refactor cannot silently revert to the newest-first-evicts-freshest
  # regression codex caught.
  grep -q 'for (( _i = \${#_resumable\[@\]} - 1; _i >= 0; _i-- ))' "$agent_src" \
    || smoke_fail "T1: forget-session no longer feeds the quarantine oldest-first — cap-eviction fix regressed"
  grep -q 'BRIDGE_RESUME_QUARANTINE_CAP="\$_forget_cap"' "$agent_src" \
    || smoke_fail "T1: forget-session no longer raises the cap for its adds — cap-completeness fix regressed"
  grep -q '^bridge_agent_list_resumable_transcripts()' "$state_src" \
    || smoke_fail "T1: enumeration helper removed from lib/bridge-state.sh — #1968 regressed"
  grep -q -- '--list-resumable' "$REPO_ROOT/scripts/python-helpers/resolve-claude-resume-session-id.py" \
    || smoke_fail "T1: --list-resumable mode removed from resolver helper — #1968 regressed"
}

main() {
  smoke_run "E1 before-forget dry-run has --resume (non-vacuous)" \
    case_e1_before_forget_has_resume
  smoke_run "E2 forget-session reports transcripts_quarantined" \
    case_e2_forget_reports_quarantine
  smoke_run "E3 after-forget dry-run has NO --resume (teeth)" \
    case_e3_after_forget_no_resume
  smoke_run "E4 cap eviction keeps freshest quarantined (>cap)" \
    case_e4_cap_keeps_freshest_quarantined
  smoke_run "L1 enumeration lists all newest-first" \
    case_l1_enumeration_lists_all_newest_first
  smoke_run "L2 all transcripts quarantined → resolver empty" \
    case_l2_all_quarantined_resolver_empty
  smoke_run "L3 post-forget transcript not quarantined" \
    case_l3_post_forget_transcript_not_quarantined
  smoke_run "L4 foreign transcript not quarantined (guard holds)" \
    case_l4_foreign_transcript_not_quarantined
  smoke_run "L5 non-forget recovery path intact" \
    case_l5_non_forget_recovery_intact
  smoke_run "T1 mutation teeth: forget hook + helper present" \
    case_t1_mutation_teeth_hook_present
  smoke_log "all checks passed"
}

main "$@"
