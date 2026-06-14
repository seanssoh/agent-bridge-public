#!/usr/bin/env bash
# scripts/smoke/1900-dynamic-vanilla-refresh-noop.sh
#
# #1890 / PR #1900 Phase-4 BLOCKING 1 — the generic session-id refresh / resume
# / normalization paths must be a HARD NO-OP for a dynamic vanilla Claude agent.
#
# Root cause the reviewer reproduced: the launch BUILDERS already avoid
# `--resume`, but the production POST-START / freshness paths still called the
# generic detector. Because bridge_resolve_agent_claude_config_dir returns EMPTY
# for a dynamic vanilla Claude agent, bridge_detect_claude_session_id fell back
# to $HOME/.claude (the OPERATOR-global config), detected the operator's live
# session, and PERSISTED it into BRIDGE_AGENT_SESSION_ID. A dynamic vanilla
# Claude must resume purely via native `claude -c` and never carry a
# bridge-managed id.
#
# This smoke seeds an operator $HOME/.claude with a live transcript whose cwd is
# the agent workdir (the exact shape the detector scans), then drives the THREE
# production entry points for a dynamic vanilla agent:
#   - bridge_refresh_agent_session_id        (bridge-run.sh / bridge-start.sh)
#   - bridge_claude_resume_session_id_for_agent  (setup-freshness downgrade)
#   - bridge_normalize_agent_session_id      (resume-mode / safe-mode classify)
# and asserts each is a no-op that captures + persists NOTHING.
#
# A STATIC Claude agent in the SAME operator-HOME setup MUST still detect the id
# (proving the guard is class-scoped, not a blanket break of resume detection).
#
# Isolation: temp BRIDGE_HOME; temp workdir; HOME repointed at a temp operator
# home. Platform forced Darwin so linux-user isolation is never effective (the
# shared-mode shape #1890 targets). Footgun #11: plain printf/cat fixtures only.

set -euo pipefail

SMOKE_NAME="1900-dynamic-vanilla-refresh-noop"
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

OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
WORKDIR="$SMOKE_TMP_ROOT/agent-workdir"
mkdir -p "$OPERATOR_HOME" "$WORKDIR"
WORKDIR="$(cd -P "$WORKDIR" && pwd -P)"

# The operator-global session id we must NEVER capture for a dynamic vanilla
# agent. Seed it under the OPERATOR HOME's ~/.claude — the fallback root the
# detector reaches when the per-agent config-dir resolver returns empty.
OPERATOR_SID="0pera70r-1900-live-session-id-aaaa"
OP_CLAUDE="$OPERATOR_HOME/.claude"
SLUG="${WORKDIR//\//-}"
NOW_MS=$(( $(date +%s) * 1000 ))
mkdir -p "$OP_CLAUDE/sessions" "$OP_CLAUDE/projects/$SLUG"
# pid:$$ is this smoke's own (live) pid so the detector's pid-alive gate passes.
cat >"$OP_CLAUDE/sessions/$$.json" <<EOF
{"sessionId":"$OPERATOR_SID","cwd":"$WORKDIR","pid":$$,"startedAt":$NOW_MS}
EOF
printf '{"sessionId":"%s","cwd":"%s"}\n' "$OPERATOR_SID" "$WORKDIR" \
  >"$OP_CLAUDE/projects/$SLUG/$OPERATOR_SID.jsonl"

# lib_eval — source the full library, reset roster, register one Claude agent of
# the requested <source> for the shared workdir, then run <snippet>. Darwin-
# forced so isolation is never effective. HOME points at the operator home so
# the detector's fallback root is the seeded ~/.claude above.
lib_eval() {
  local agent="$1"
  local src="$2"
  local snippet="$3"
  # Unset any ambient CLAUDE_CONFIG_DIR so the detector's config-root fallback
  # is the operator $HOME/.claude — exactly the runtime a dynamic vanilla agent
  # sees (its launch env never exports CLAUDE_CONFIG_DIR). Without this the
  # smoke's own controller config-dir would leak in and mask the fallback.
  env -u CLAUDE_CONFIG_DIR \
  HOME="$OPERATOR_HOME" \
  BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" \
  "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_reset_roster_maps
    agent='$agent'
    BRIDGE_AGENT_IDS+=(\$agent)
    BRIDGE_AGENT_ENGINE[\$agent]=claude
    BRIDGE_AGENT_SESSION[\$agent]=\$agent
    BRIDGE_AGENT_WORKDIR[\$agent]='$WORKDIR'
    BRIDGE_AGENT_SOURCE[\$agent]='$src'
    BRIDGE_AGENT_ISOLATION_MODE[\$agent]=shared
    BRIDGE_AGENT_CONTINUE[\$agent]=1
    BRIDGE_AGENT_CREATED_AT[\$agent]=\$(( $(date +%s) - 60 ))
    BRIDGE_AGENT_SESSION_ID[\$agent]=''
    $snippet
  "
}

# ===========================================================================
# A — bridge_refresh_agent_session_id is a hard no-op for dynamic vanilla:
# returns rc!=0, captures nothing, persists nothing.
#
# Control (PROBE): the operator-global transcript IS genuinely detectable via
# the SAME fallback the dynamic agent would otherwise have taken — the detector
# called with an EMPTY config-dir arg (exactly what bridge_resolve_agent_claude_
# config_dir returns for a dynamic vanilla agent) falls back to $HOME/.claude and
# returns the operator id. This proves the BLOCKING-1 bug was real and the
# fixture realistic, so the dynamic no-op below is the guard, not a dead probe.
# ===========================================================================
test_a_refresh_noop() {
  local dyn_out probe_out
  dyn_out="$(lib_eval "dynr" dynamic '
    if bridge_refresh_agent_session_id dynr 3 0 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    printf "RC=%s\n" "$rc"
    printf "STORED=%s\n" "$(bridge_agent_session_id dynr)"
  ')" || smoke_fail "A dynamic lib_eval failed: $dyn_out"

  probe_out="$(lib_eval "probe" static '
    # Empty config-dir arg == what the resolver returns for dynamic vanilla.
    # The detector then falls back to $HOME/.claude (the operator-global root).
    since_ms=$(( ($(date +%s) - 3600) * 1000 ))
    printf "DETECTED=%s\n" "$(bridge_detect_claude_session_id "'"$WORKDIR"'" "$since_ms" "" "" "")"
  ')" || smoke_fail "A probe lib_eval failed: $probe_out"

  local dyn_rc dyn_stored probe_detected
  dyn_rc="$(printf '%s\n' "$dyn_out" | sed -n 's/^RC=//p' | head -n1)"
  dyn_stored="$(printf '%s\n' "$dyn_out" | sed -n 's/^STORED=//p' | head -n1)"
  probe_detected="$(printf '%s\n' "$probe_out" | sed -n 's/^DETECTED=//p' | head -n1)"

  smoke_assert_eq "$OPERATOR_SID" "$probe_detected" \
    "A PROBE: the operator-global session IS detectable via the empty-config-dir fallback (bug was real)"
  smoke_assert_eq "1" "$dyn_rc" "A refresh returns rc 1 (no id) for dynamic vanilla Claude"
  smoke_assert_eq "" "$dyn_stored" "A refresh persists NOTHING for dynamic vanilla Claude (operator id not captured)"
}

# ===========================================================================
# B — bridge_claude_resume_session_id_for_agent (setup-freshness downgrade path)
# emits nothing / rc!=0 for dynamic vanilla; static still resolves the id.
# ===========================================================================
test_b_resume_for_agent_noop() {
  local dyn_out
  dyn_out="$(lib_eval "dynf" dynamic '
    printf "PRED=%s\n" "$(bridge_agent_is_dynamic_vanilla_claude dynf && echo yes || echo no)"
    if id="$(bridge_claude_resume_session_id_for_agent dynf 2>/dev/null)"; then rc=0; else rc=$?; fi
    printf "RC=%s\n" "$rc"
    printf "ID=%s\n" "$id"
  ')" || smoke_fail "B dynamic lib_eval failed: $dyn_out"

  local pred dyn_rc dyn_id
  pred="$(printf '%s\n' "$dyn_out" | sed -n 's/^PRED=//p' | head -n1)"
  dyn_rc="$(printf '%s\n' "$dyn_out" | sed -n 's/^RC=//p' | head -n1)"
  dyn_id="$(printf '%s\n' "$dyn_out" | sed -n 's/^ID=//p' | head -n1)"

  smoke_assert_eq "yes" "$pred" "B agent is classified dynamic-vanilla-claude"
  smoke_assert_eq "1" "$dyn_rc" "B resume-for-agent returns rc 1 for dynamic vanilla Claude"
  smoke_assert_eq "" "$dyn_id" "B resume-for-agent emits NOTHING (operator id not resolved)"
}

# ===========================================================================
# C — bridge_normalize_agent_session_id is a no-op for dynamic vanilla even when
# a stale id is already present in state: it must NOT route through the resolver
# (which would re-detect / clear against the operator-global config). It leaves
# the pre-existing value untouched (the value is irrelevant — what matters is
# the resolver is never consulted, so a non-vanilla classification cannot occur).
# ===========================================================================
test_c_normalize_noop() {
  local dyn_out
  dyn_out="$(lib_eval "dynn" dynamic '
    BRIDGE_AGENT_SESSION_ID[dynn]="stale-1900-preexisting-id-0001"
    bridge_normalize_agent_session_id dynn >/dev/null 2>&1; rc=$?
    printf "RC=%s\n" "$rc"
    printf "STORED=%s\n" "$(bridge_agent_session_id dynn)"
  ')" || smoke_fail "C dynamic lib_eval failed: $dyn_out"

  local dyn_rc dyn_stored
  dyn_rc="$(printf '%s\n' "$dyn_out" | sed -n 's/^RC=//p' | head -n1)"
  dyn_stored="$(printf '%s\n' "$dyn_out" | sed -n 's/^STORED=//p' | head -n1)"

  smoke_assert_eq "0" "$dyn_rc" "C normalize returns 0 (no-op) for dynamic vanilla Claude"
  smoke_assert_eq "stale-1900-preexisting-id-0001" "$dyn_stored" \
    "C normalize does NOT touch the resolver for dynamic vanilla Claude (value left as-is)"
}

# ===========================================================================
# D — the daemon BACKFILL sweep (bridge-sync.sh refresh_missing_session_ids)
# calls bridge_detect_session_id DIRECTLY, bypassing the function-level guards
# above. It must skip a dynamic vanilla agent entirely so the operator-global
# session id is never detected + persisted by the daemon. Source bridge-sync.sh
# (functions only; main runs only when executed directly), stub the tmux-probe
# bridge_agent_is_active to true, register a dynamic vanilla agent + the seeded
# operator transcript, run the sweep, and assert NOTHING was stored.
# (Codex Phase-4 re-review: this is the sync bypass the function guards miss.)
# ===========================================================================
test_d_sync_backfill_noop() {
  local out
  out="$(env -u CLAUDE_CONFIG_DIR \
    HOME="$OPERATOR_HOME" \
    BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" \
    "$BASH4_BIN" -c "
      set -uo pipefail
      SCRIPT_DIR='$REPO_ROOT'
      source '$REPO_ROOT/bridge-sync.sh' >/dev/null 2>&1
      bridge_reset_roster_maps
      declare -A CLAIMED_SESSION_IDS=()
      declare -A PRUNED_DYNAMIC=()
      # Force the tmux-probe gate true so the agent is treated as active.
      bridge_agent_is_active() { return 0; }
      a=dynsync
      BRIDGE_AGENT_IDS+=(\$a)
      BRIDGE_AGENT_ENGINE[\$a]=claude
      BRIDGE_AGENT_SESSION[\$a]=\$a
      BRIDGE_AGENT_WORKDIR[\$a]='$WORKDIR'
      BRIDGE_AGENT_SOURCE[\$a]=dynamic
      BRIDGE_AGENT_ISOLATION_MODE[\$a]=shared
      BRIDGE_AGENT_CONTINUE[\$a]=1
      BRIDGE_AGENT_CREATED_AT[\$a]=\$(( $(date +%s) - 60 ))
      BRIDGE_AGENT_SESSION_ID[\$a]=''
      refresh_missing_session_ids >/dev/null 2>&1 || true
      printf 'STORED=%s\n' \"\$(bridge_agent_session_id dynsync)\"
    ")" || smoke_fail "D sync-backfill exec failed: $out"

  local stored; stored="$(printf '%s\n' "$out" | sed -n 's/^STORED=//p' | head -n1)"
  smoke_assert_eq "" "$stored" \
    "D daemon backfill sweep skips dynamic vanilla Claude (operator id never detected/persisted)"
}

# ===========================================================================
# E — the central resolver chokepoint (bridge_resolve_resume_session_id) drops
# a STALE NON-EMPTY candidate for dynamic vanilla: it resolves to EMPTY, never
# echoes the id back. This is the hydration/restart hardening — a stale id left
# in a pre-fix history env file or carried in via a restart snapshot must not be
# preserved (it would re-introduce a bridge-managed / operator-global id). The
# hydration loaders' `case 0|2)` arm then stores the empty result.
# ===========================================================================
test_e_resolver_drops_stale_candidate() {
  local out
  out="$(lib_eval "dynres" dynamic '
    cand="0pera70r-1900-live-session-id-aaaa"
    # rc must be 0 (kept-arm) and stdout EMPTY: the candidate is dropped.
    if resolved="$(bridge_resolve_resume_session_id claude dynres "'"$WORKDIR"'" "$cand" 2>/dev/null)"; then rc=0; else rc=$?; fi
    printf "RC=%s\n" "$rc"
    printf "RESOLVED=[%s]\n" "$resolved"
  ')" || smoke_fail "E lib_eval failed: $out"

  local rc resolved
  rc="$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | head -n1)"
  resolved="$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p' | head -n1)"

  smoke_assert_eq "0" "$rc" "E resolver returns rc 0 (kept-arm) for dynamic vanilla"
  smoke_assert_eq "[]" "$resolved" \
    "E resolver DROPS a stale non-empty candidate for dynamic vanilla (resolves to empty, never echoes the id)"
}

# ===========================================================================
# F — persist-time back door (#1305 empty-session-id-persist guard): when the
# in-memory id is empty, that guard rehydrates a persisted id to avoid clobbering
# a sibling write. For a dynamic vanilla agent an empty in-memory id is
# AUTHORITATIVE, so the guard must be SKIPPED — a stale persisted id (e.g. left
# in a pre-fix history env file) must be written through (cleared), not
# resurrected. We seed a persisted id by persisting a non-empty value, then set
# the in-memory map empty and persist again, and assert the persisted id is now
# EMPTY for the dynamic vanilla agent. A STATIC agent in the same flow KEEPS its
# id (the #1305 race guard rehydrates) — proving the skip is class-scoped.
# ===========================================================================
persist_roundtrip() {
  local agent="$1" src="$2"
  env -u CLAUDE_CONFIG_DIR \
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" \
  "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_reset_roster_maps
    a='$agent'
    BRIDGE_AGENT_IDS+=(\$a)
    BRIDGE_AGENT_ENGINE[\$a]=claude
    BRIDGE_AGENT_SESSION[\$a]=\$a
    BRIDGE_AGENT_WORKDIR[\$a]='$WORKDIR'
    BRIDGE_AGENT_SOURCE[\$a]='$src'
    BRIDGE_AGENT_ISOLATION_MODE[\$a]=shared
    BRIDGE_AGENT_CONTINUE[\$a]=1
    BRIDGE_AGENT_CREATED_AT[\$a]=\$(date +%s)
    # 1) Seed a persisted stale id (simulates a pre-fix history env file).
    BRIDGE_AGENT_SESSION_ID[\$a]='stale-1900-persisted-id-cafe'
    bridge_persist_agent_state \"\$a\" >/dev/null 2>&1 || true
    # 2) In-memory now empty; persist again. Dynamic vanilla must NOT rehydrate.
    BRIDGE_AGENT_SESSION_ID[\$a]=''
    bridge_persist_agent_state \"\$a\" >/dev/null 2>&1 || true
    printf 'PERSISTED=[%s]\n' \"\$(bridge_agent_persisted_session_id \"\$a\")\"
  "
}

test_f_persist_guard_skip() {
  local dyn_out stat_out
  dyn_out="$(persist_roundtrip dynp dynamic)" || smoke_fail "F dynamic persist failed: $dyn_out"
  stat_out="$(persist_roundtrip statp static)" || smoke_fail "F static persist failed: $stat_out"

  local dyn_persisted stat_persisted
  dyn_persisted="$(printf '%s\n' "$dyn_out" | sed -n 's/^PERSISTED=//p' | head -n1)"
  stat_persisted="$(printf '%s\n' "$stat_out" | sed -n 's/^PERSISTED=//p' | head -n1)"

  smoke_assert_eq "[]" "$dyn_persisted" \
    "F dynamic vanilla: empty in-memory id is written through (stale persisted id CLEARED, not rehydrated)"
  smoke_assert_eq "[stale-1900-persisted-id-cafe]" "$stat_persisted" \
    "F static: #1305 empty-persist guard STILL rehydrates the persisted id (unchanged)"
}

# --- run ------------------------------------------------------------------
smoke_run "A refresh hard no-op for dynamic vanilla (static still detects)" test_a_refresh_noop
smoke_run "B resume-for-agent no-op for dynamic vanilla (static unchanged)" test_b_resume_for_agent_noop
smoke_run "C normalize no-op for dynamic vanilla (resolver never consulted)" test_c_normalize_noop
smoke_run "D daemon backfill sweep (bridge-sync) no-op for dynamic vanilla" test_d_sync_backfill_noop
smoke_run "E central resolver drops stale candidate for dynamic vanilla" test_e_resolver_drops_stale_candidate
smoke_run "F persist-time guard skip for dynamic vanilla (static rehydrates)" test_f_persist_guard_skip

smoke_log "PASS — #1900 BLOCKING 1: dynamic vanilla Claude never runs the session detector (refresh/resume/normalize + daemon backfill sweep), the central resolver drops any stale candidate, the persist-time empty-guard clears (not rehydrates) a stale id, and no operator-global id is ever persisted; static/admin unchanged"
