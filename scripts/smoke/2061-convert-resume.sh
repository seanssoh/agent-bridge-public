#!/usr/bin/env bash
# scripts/smoke/2061-convert-resume.sh — FR #2061 Track C: the `--carry-session
# live|none` resume-id pin in run_convert (bridge-agent.sh), built on the
# Track A migration engine + Track B verb.
#
# Track B (2061-convert-verb) pins the verb orchestration; Track A
# (2061-convert-migration) pins the pure migration engine. THIS smoke pins the
# RESUME-PIN layer: capturing the dynamic agent's last-active transcript id from
# the SOURCE config dir before migration, pinning it atomically post-flip, and
# validating it against the TARGET config dir — never a silent fresh-start.
#
#   T1  --carry-session live (default) pins the dynamic agent's last-active
#       session id; after convert bridge_agent_persisted_session_id returns it
#       AND it transcript-validates against the TARGET config dir.
#   T2  a deliberately transcript-absent carried id is REJECTED — convert fails
#       loudly + rolls back (no static role, no stranded pinned id). This is the
#       #1248-class silent-fresh-start the feature exists to prevent.
#   T3  --carry-session none clears the resume state (no id pinned even when the
#       source held a resumable session).
#   T4  daemon-recapture acceptance (§0.3): a daemon sync pass (the ~5s
#       refresh_missing_session_ids re-capture) during the stopped/held window
#       does NOT overwrite the pinned id with a fresher different one.
#
# NOT smoke-coverable (flagged for the orchestrator's live check): the actual
# `start` / `--resume <pinned-id>` of the converted static agent (tmux + Claude
# submit semantics are not exercised here).

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:2061-convert-resume][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="2061-convert-resume"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# The operator-global ~/.claude the dynamic-vanilla agent reads. Pin it via
# HOME + BRIDGE_CONTROLLER_HOME so bridge_agent_operator_home_dir resolves here.
OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OPERATOR_HOME/.claude"

slug_of() { local p="$1"; p="${p//\//-}"; printf '%s' "$p"; }

init_roster() {
  printf '#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n' > "$BRIDGE_ROSTER_LOCAL_FILE"
}
seed_dynamic_agent() {
  local agent="$1" workdir="$2"
  mkdir -p "$workdir/.claude"
  {
    printf '\n# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$agent"
    printf 'bridge_add_agent_id_if_missing %q\n' "$agent"
    printf 'BRIDGE_AGENT_DESC["%s"]=%q\n' "$agent" "$agent convert resume test"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]=%q\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]=%q\n' "$agent" "$workdir"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="dynamic"\n' "$agent"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$agent"
  } >> "$BRIDGE_ROSTER_LOCAL_FILE"
}

# Seed a transcript under the operator ~/.claude for <agent>'s workdir cwd so the
# detect helper (and the migration manifest) finds <sid>.
seed_operator_state() {
  local workdir="$1" sid="$2"
  local sl; sl="$(slug_of "$workdir")"
  mkdir -p "$OPERATOR_HOME/.claude/projects/$sl"
  printf '{"cwd":"%s","sessionId":"%s"}\n' "$workdir" "$sid" \
    > "$OPERATOR_HOME/.claude/projects/$sl/$sid.jsonl"
}

convert_cli() {
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_CALLER_SOURCE="${BRIDGE_CALLER_SOURCE:-operator-trusted-id}" \
    "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" convert "$@"
}

# Read the persisted resume id straight from the authoritative on-disk state
# (history env) via a one-shot bridge-lib eval.
persisted_sid() {
  local agent="$1"
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    "$BASH4_BIN" -c "
      source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
      bridge_load_roster >/dev/null 2>&1 || true
      bridge_agent_persisted_session_id '$agent' 2>/dev/null || true
    "
}

lib_eval() {
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    "$BASH4_BIN" -c "source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1; bridge_load_roster >/dev/null 2>&1 || true; $1"
}

# Run a real daemon sync sweep (refresh_missing_session_ids) against the
# isolated roster, then print the persisted id. Sourcing bridge-sync.sh defines
# the sweep without running bridge_sync_main (the BASH_SOURCE==$0 guard).
run_sweep_then_read() {
  local agent="$1"
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    "$BASH4_BIN" -c "
      source '$REPO_ROOT/bridge-sync.sh' >/dev/null 2>&1
      bridge_load_roster >/dev/null 2>&1 || true
      record_claimed_ids >/dev/null 2>&1 || true
      refresh_missing_session_ids >/dev/null 2>&1 || true
      bridge_load_roster >/dev/null 2>&1 || true
      bridge_agent_persisted_session_id '$agent' 2>/dev/null || true
    "
}

roster_has() { grep -Fq "$1" "$BRIDGE_ROSTER_LOCAL_FILE"; }

# ===========================================================================
# T1 — --carry-session live pins the last-active id; it transcript-validates
# against the TARGET config dir after convert.
# ===========================================================================
test_t1_live_pins_validated_id() {
  init_roster
  local agent="carrylive" workdir="$SMOKE_TMP_ROOT/carrylive-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sidLIVE"
  local sl; sl="$(slug_of "$workdir")"
  local target="$BRIDGE_AGENT_ROOT_V2/$agent/home/.claude"

  local out
  out="$(convert_cli "$agent" --to static --json)" \
    || smoke_fail "T1: convert --carry-session live exited non-zero: $out"

  # JSON surfaces the pinned id.
  printf '%s' "$out" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["carry_session"] == "live", m
assert m["resumed_session_id"] == "sidLIVE", "expected resumed_session_id=sidLIVE, got %r" % m.get("resumed_session_id")
' || smoke_fail "T1: convert JSON did not report resumed_session_id=sidLIVE: $out"

  # The transcript was migrated into the TARGET config dir.
  smoke_assert_file_exists "$target/projects/$sl/sidLIVE.jsonl" \
    "T1: transcript not migrated into the target config dir"

  # Persisted resume id == the carried id.
  local got; got="$(persisted_sid "$agent")"
  smoke_assert_eq "sidLIVE" "$got" "T1: persisted resume id is not the carried live id"

  # It transcript-validates against the TARGET (post-flip the agent is static,
  # so bridge_claude_session_id_exists resolves the target config dir).
  lib_eval "bridge_claude_session_id_exists sidLIVE '$workdir' '$agent'" \
    || smoke_fail "T1: carried id does NOT transcript-validate against the target config dir"
  smoke_log "T1 OK — --carry-session live pinned sidLIVE; persisted + transcript-validated against target"
}

# ===========================================================================
# T2 — a transcript-absent carried id is REJECTED: convert fails loudly and
# rolls back (no static role, no stranded pinned id). No silent fresh-start.
# ===========================================================================
test_t2_absent_id_rejected() {
  init_roster
  local agent="ghostpin" workdir="$SMOKE_TMP_ROOT/ghostpin-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sidREAL"

  # Force the carried id to one with NO transcript anywhere (the migration still
  # carries sidREAL, but the forced id is transcript-absent in target) so the
  # post-flip validate gate must reject it — the default-off test seam, analogous
  # to T4/T7 in 2061-convert-verb.
  local rc=0
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_CALLER_SOURCE="operator-trusted-id" \
  BRIDGE_CONVERT_FORCE_CARRY_SESSION_ID="ghost-no-transcript" \
    "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" convert "$agent" --to static \
      --carry-session live >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "T2: a transcript-absent carried id was NOT rejected (convert succeeded — silent fresh-start)"

  # Rolled back: no static role survives (the flip was excised).
  if roster_has 'BRIDGE_AGENT_SOURCE["ghostpin"]="static"'; then
    smoke_fail "T2: a static role survived a failed resume-pin validation"
  fi
  local n
  n="$(grep -c '# BEGIN AGENT BRIDGE MANAGED ROLE: ghostpin' "$BRIDGE_ROSTER_LOCAL_FILE" || true)"
  smoke_assert_eq "0" "$n" "T2: the flipped managed block was not excised on validation-reject rollback"

  # No stranded pinned id (the bad id was cleared before rollback).
  local got; got="$(persisted_sid "$agent")"
  smoke_assert_eq "" "$got" "T2: a transcript-absent id was left stranded in the persisted resume state"
  smoke_log "T2 OK — transcript-absent carried id rejected loudly; flip rolled back; no stranded pinned id"
}

# ===========================================================================
# T3 — --carry-session none clears the resume state (no id pinned even when a
# resumable session existed in the source).
# ===========================================================================
test_t3_none_clears() {
  init_roster
  local agent="freshstart" workdir="$SMOKE_TMP_ROOT/freshstart-wd"
  seed_dynamic_agent "$agent" "$workdir"
  # A resumable session DOES exist in the source — `none` must still not pin it.
  seed_operator_state "$workdir" "sidAVAIL"

  local out
  out="$(convert_cli "$agent" --to static --carry-session none --json)" \
    || smoke_fail "T3: convert --carry-session none exited non-zero: $out"
  printf '%s' "$out" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["carry_session"] == "none", m
assert m["resumed_session_id"] == "", "expected empty resumed_session_id for none, got %r" % m.get("resumed_session_id")
' || smoke_fail "T3: convert JSON pinned a session id under --carry-session none: $out"

  local got; got="$(persisted_sid "$agent")"
  smoke_assert_eq "" "$got" "T3: --carry-session none left a persisted resume id"
  smoke_log "T3 OK — --carry-session none cleared the resume state (no id pinned despite an available session)"
}

# ===========================================================================
# T4 — daemon-recapture acceptance (§0.3): a daemon sync sweep during the
# stopped/held window does NOT overwrite the pinned id with a fresher different
# one. The converted agent is stopped (start_policy=hold) — exactly the window
# the pin races refresh_missing_session_ids in.
# ===========================================================================
test_t4_recapture_no_overwrite() {
  init_roster
  local agent="recap" workdir="$SMOKE_TMP_ROOT/recap-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sidPIN"
  local sl; sl="$(slug_of "$workdir")"
  local target="$BRIDGE_AGENT_ROOT_V2/$agent/home/.claude"

  convert_cli "$agent" --to static >/dev/null \
    || smoke_fail "T4: convert exited non-zero"
  local before; before="$(persisted_sid "$agent")"
  smoke_assert_eq "sidPIN" "$before" "T4: pinned id was not persisted before the sweep"

  # The converted agent is stopped/held — assert that so the protection under
  # test is the documented stopped/held window (not a vacuous skip of some
  # other shape).
  local active; active="$(lib_eval "if bridge_agent_is_active '$agent'; then echo active; else echo inactive; fi")"
  smoke_assert_eq "inactive" "$active" "T4: the converted agent is not in the stopped/held window (unexpectedly active)"

  # Plant a FRESHER, DIFFERENT transcript in the TARGET config dir — a naive
  # re-detect would prefer it. The sweep must NOT swap to it.
  printf '{"cwd":"%s","sessionId":"sidNEWER"}\n' "$workdir" \
    > "$target/projects/$sl/sidNEWER.jsonl"
  touch "$target/projects/$sl/sidNEWER.jsonl"

  local after; after="$(run_sweep_then_read "$agent")"
  smoke_assert_eq "sidPIN" "$after" \
    "T4: the daemon sync sweep OVERWROTE the pinned id during the stopped/held window"
  smoke_log "T4 OK — daemon sync sweep left the pinned id intact during the stopped/held window"
}

# ===========================================================================
# T5 — clear-failure postcondition: if the resume-state clear does NOT land
# (lock/write failure leaving a stale id persisted), --carry-session none fails
# LOUDLY rather than reporting a fresh start while a wrong-resume id survives.
# ===========================================================================
test_t5_none_clear_failure_fails_loud() {
  init_roster
  local agent="staleclear" workdir="$SMOKE_TMP_ROOT/staleclear-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sidKEEP"

  # First: a clean live convert so the now-static agent carries a persisted
  # resume id (sidKEEP) — the stale id a later `none` clear must remove.
  convert_cli "$agent" --to static >/dev/null \
    || smoke_fail "T5: initial live convert exited non-zero"
  smoke_assert_eq "sidKEEP" "$(persisted_sid "$agent")" \
    "T5: initial live convert did not persist the resume id"

  # Re-run with --carry-session none under the clear-noop fault seam: the clear
  # is skipped, so sidKEEP survives. The postcondition guard must fail loudly
  # instead of reporting a (false) fresh start.
  local rc=0
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_CALLER_SOURCE="operator-trusted-id" \
  BRIDGE_CONVERT_FORCE_CLEAR_NOOP=1 \
    "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" convert "$agent" --to static \
      --carry-session none >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "T5: --carry-session none reported success while a stale resume id remained persisted"
  smoke_log "T5 OK — a non-landing resume-state clear under --carry-session none fails loudly (no wrong-resume static role)"
}

# --- run -------------------------------------------------------------------
smoke_run "T1 --carry-session live pins a transcript-validated id" test_t1_live_pins_validated_id
smoke_run "T2 transcript-absent carried id rejected (no silent fresh-start)" test_t2_absent_id_rejected
smoke_run "T3 --carry-session none clears the resume state" test_t3_none_clears
smoke_run "T4 daemon-recapture acceptance during the stopped/held window" test_t4_recapture_no_overwrite
smoke_run "T5 --carry-session none fails loud if the clear does not land" test_t5_none_clear_failure_fails_loud

smoke_log "PASS — #2061 Track C resume-pin: live pins a transcript-validated id, transcript-absent id rejected with rollback, none clears (and fails loud if the clear does not land), daemon recapture cannot overwrite the pin in the stopped/held window"
