#!/usr/bin/env bash
# scripts/smoke/dynamic-agent-resume-config-dir-scope.sh
#
# Operator-session-hijack regression (SAFETY-CRITICAL).
#
# Live data-loss: launching a NEW dynamic agent in a folder where the operator
# has a vanilla (non-bridge) Claude session DESTROYED the operator's session —
# its transcript was moved to `.quarantined/` and vanished from `claude
# --resume`. 2-stage root cause:
#
#   Defect A — resume detection scanned the WRONG config dir. For a fresh
#   dynamic agent whose isolated `<agent-home>/.claude/projects/` is empty,
#   `bridge_resolve_agent_claude_config_dir` returned EMPTY (the #1370
#   "stale scaffold ⇒ HOME fallback" heuristic). Empty config dir → detection
#   fell back to the operator HOME `~/.claude/projects/<slug>/`, sorted by
#   mtime, and picked the OPERATOR's newest session (no ownership filter).
#
#   Defect B — quarantine was not ownership-scoped. On the resume failure the
#   archive helper moved that OPERATOR-HOME transcript into `.quarantined/`.
#
# This smoke pins all three required fixes with a differential fixture: an
# isolated BRIDGE_HOME + a FAKE operator HOME holding a vanilla transcript for
# the agent's workdir slug.
#
#   A1 (F1) — a NEW dynamic agent with an EMPTY isolated config dir resolves to
#     its OWN config dir (NOT empty, NO operator-HOME fallthrough) → detection
#     finds nothing in the empty isolated dir → fresh start. The operator's
#     transcript is NOT selected for resume.
#   A2 (F1, legit-preserve) — a dynamic agent WHOSE OWN isolated projects/ holds
#     its prior transcript still resumes that transcript (#981/#1769 preserved).
#   A3 (F2) — a quarantine/archive attempt for a session whose transcript lives
#     ONLY in the operator HOME (outside the agent's config dir) is REFUSED: the
#     operator transcript is NOT moved and stays present.
#
# Plus the end-to-end safety invariant: across A1+A3 the operator-HOME
# transcript is never resume-selected AND never quarantined.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; a temp "operator
# HOME" stands in for `~`. The smoke never reads or writes the real operator
# `~/.claude`. The agent's own config dir path is resolved THROUGH the bridge
# function inside each lib subshell so it is correct regardless of the runtime
# layout (v2 anchors the per-agent home under BRIDGE_AGENT_ROOT_V2). Footgun
# #11: plain `printf` / `cat >file <<EOF` fixture writes only — no command
# substitution feeding a heredoc-stdin into bridge functions.

set -euo pipefail

SMOKE_NAME="dynamic-agent-resume-config-dir-scope"
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

# A Bash 4+ interpreter (assoc arrays). bridge-lib re-execs on Bash 3 but
# routing up front gives clearer output.
BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# ---------------------------------------------------------------------------
# Fixture: a FAKE operator HOME with a vanilla transcript for the workdir slug.
# Everything lives under SMOKE_TMP_ROOT so cleanup reaps it.
# ---------------------------------------------------------------------------
OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
WORKDIR="$SMOKE_TMP_ROOT/shared-project"
mkdir -p "$OPERATOR_HOME" "$WORKDIR"
WORKDIR="$(cd -P "$WORKDIR" && pwd -P)"

SLUG="${WORKDIR//\//-}"
OPERATOR_SESSION_ID="0pera70r-dead-beef-cafe-000000000001"
OPERATOR_TRANSCRIPT="$OPERATOR_HOME/.claude/projects/$SLUG/$OPERATOR_SESSION_ID.jsonl"
mkdir -p "$(dirname "$OPERATOR_TRANSCRIPT")"
# A "live-looking" vanilla operator transcript (fresh mtime, non-empty).
printf '{"sessionId":"%s","type":"user"}\n' "$OPERATOR_SESSION_ID" \
  >"$OPERATOR_TRANSCRIPT"
# Also drop a sessions/<pid>.json record so even the live-session detection
# path would otherwise pick the operator id if it scanned the operator HOME.
mkdir -p "$OPERATOR_HOME/.claude/sessions"
OPERATOR_NOW_MS=$(( $(date +%s) * 1000 ))
cat >"$OPERATOR_HOME/.claude/sessions/99999.json" <<EOF
{"sessionId":"$OPERATOR_SESSION_ID","cwd":"$WORKDIR","pid":99999,"startedAt":$OPERATOR_NOW_MS}
EOF

AGENT_OWN_SESSION_ID="a9en70wn-1111-2222-3333-444444444444"

# ---------------------------------------------------------------------------
# lib_eval — source the full library, reset roster, register a DYNAMIC
# shared-mode agent for the shared workdir, then evaluate the supplied snippet.
# HOME is repointed at OPERATOR_HOME so the helper's daemon-HOME fallback (the
# OLD destructive path) would resolve the operator transcript — proving the fix
# removes that fallback. Platform is forced to Darwin so linux-user isolation
# is never effective (the exact shared-mode macOS shape where the bug fired).
#
# The agent's OWN config dir is whatever bridge_agent_claude_config_dir
# resolves to in this layout; snippets reference it via $cfg (pre-computed in
# the subshell) so the fixture is layout-agnostic.
# ---------------------------------------------------------------------------
lib_eval() {
  local agent="$1"
  local snippet="$2"
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
    BRIDGE_AGENT_SOURCE[\$agent]=dynamic
    BRIDGE_AGENT_ISOLATION_MODE[\$agent]=shared
    BRIDGE_AGENT_CREATED_AT[\$agent]=\$(date +%s)
    BRIDGE_AGENT_SESSION_ID[\$agent]=''

    # The agent's own isolated config dir in this layout.
    cfg=\"\$(bridge_agent_claude_config_dir \"\$agent\")\"

    $snippet
  "
}

# ===========================================================================
# A1 (F1) — empty isolated config dir ⇒ fresh start; operator session NOT
# selected. The dynamic agent's <agent-home>/.claude exists but its projects/
# is empty. The resolver must return the agent's OWN config dir (so detection
# scans the empty isolated dir and finds nothing) — NOT empty (which would fall
# back to the operator HOME and pick the operator session).
# ===========================================================================
A1_AGENT="dyn_fresh"

test_a1_empty_isolated_is_fresh() {
  local out=""
  out="$(lib_eval "$A1_AGENT" '
    # Materialize the empty isolated config dir (fresh dynamic agent shape).
    mkdir -p "$cfg/projects" "$cfg/sessions"
    resolved="$(bridge_resolve_agent_claude_config_dir "$agent")"
    detected="$(bridge_detect_claude_session_id "'"$WORKDIR"'" 0 "" "$resolved" 2>/dev/null)"
    printf "CFG=%s\n" "$cfg"
    printf "RESOLVED=%s\n" "$resolved"
    printf "DETECTED=%s\n" "$detected"
  ')" || smoke_fail "A1 lib_eval failed: $out"

  local cfg resolved detected
  cfg="$(printf '%s\n' "$out" | sed -n 's/^CFG=//p' | head -n1)"
  resolved="$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p' | head -n1)"
  detected="$(printf '%s\n' "$out" | sed -n 's/^DETECTED=//p' | head -n1)"

  # F1: empty isolated projects/ ⇒ the AGENT'S OWN config dir, not empty.
  smoke_assert_eq "$cfg" "$resolved" \
    "A1 dynamic agent with empty isolated config dir resolves to its OWN dir (no operator-HOME fallthrough)"
  [[ -n "$resolved" ]] \
    || smoke_fail "A1 resolved config dir must be non-empty (got empty ⇒ operator-HOME fallback re-introduced)"
  # F1: the operator HOME must NOT be the resolved dir.
  smoke_assert_not_contains "$resolved" "$OPERATOR_HOME/.claude" \
    "A1 resolved dir must never be the operator HOME ~/.claude"
  # End-to-end: detection must NOT select the operator session — fresh start.
  smoke_assert_eq "" "$detected" \
    "A1 detection finds NO session (fresh start) — operator session not selected"
  smoke_assert_not_contains "$detected" "$OPERATOR_SESSION_ID" \
    "A1 operator session id is never returned by detection"
}

# ===========================================================================
# A2 (F1, legit-preserve) — a dynamic agent WHOSE OWN isolated projects/ holds
# its prior transcript still resumes it (#981/#1769). Only the operator-HOME
# fallback was removed; legitimate isolated resume must not regress.
# ===========================================================================
A2_AGENT="dyn_own_resume"

test_a2_own_transcript_resumes() {
  local out=""
  out="$(lib_eval "$A2_AGENT" '
    slug="'"$SLUG"'"
    own_sid="'"$AGENT_OWN_SESSION_ID"'"
    mkdir -p "$cfg/projects/$slug" "$cfg/sessions"
    # The agent'\''s OWN prior transcript (fresh, non-empty) under its isolated dir.
    printf "{\"sessionId\":\"%s\",\"type\":\"user\"}\n" "$own_sid" \
      >"$cfg/projects/$slug/$own_sid.jsonl"
    resolved="$(bridge_resolve_agent_claude_config_dir "$agent")"
    detected="$(bridge_detect_claude_session_id "'"$WORKDIR"'" 0 "" "$resolved" 2>/dev/null)"
    printf "CFG=%s\n" "$cfg"
    printf "RESOLVED=%s\n" "$resolved"
    printf "DETECTED=%s\n" "$detected"
  ')" || smoke_fail "A2 lib_eval failed: $out"

  local cfg resolved detected
  cfg="$(printf '%s\n' "$out" | sed -n 's/^CFG=//p' | head -n1)"
  resolved="$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p' | head -n1)"
  detected="$(printf '%s\n' "$out" | sed -n 's/^DETECTED=//p' | head -n1)"

  smoke_assert_eq "$cfg" "$resolved" \
    "A2 dynamic agent with its OWN populated isolated projects/ resolves its own dir"
  # The agent resumes its OWN prior session — NOT the operator's.
  smoke_assert_eq "$AGENT_OWN_SESSION_ID" "$detected" \
    "A2 detection resumes the agent's OWN isolated transcript (#981/#1769 legit resume preserved)"
  smoke_assert_not_contains "$detected" "$OPERATOR_SESSION_ID" \
    "A2 operator session id is never returned even with an own transcript present"
}

# ===========================================================================
# A3 (F2) — quarantine/archive of a transcript OUTSIDE the agent's config dir
# is refused. The operator's transcript (only in the operator HOME, NOT under
# the agent's config dir) must NOT be moved and must stay present.
# ===========================================================================
A3_AGENT="dyn_quarantine"

test_a3_foreign_quarantine_refused() {
  local out=""
  out="$(lib_eval "$A3_AGENT" '
    op_sid="'"$OPERATOR_SESSION_ID"'"
    mkdir -p "$cfg/projects" "$cfg/sessions"
    # Archive attempt for the OPERATOR session (transcript only in operator
    # HOME, outside the agent config dir) — F2 must refuse the move.
    archived="$(bridge_agent_resume_quarantine_archive_transcript "$agent" "$op_sid" 2>/dev/null \
      | tr "\n" "," | sed "s/,\$//")"
    # Add attempt for the same foreign session — F2 must refuse to record it.
    bridge_agent_resume_quarantine_add "$agent" "$op_sid" "no-conversation-found" >/dev/null 2>&1 || true
    ids="$(bridge_agent_resume_quarantine_ids "$agent" 2>/dev/null || true)"
    printf "ARCHIVED=%s\n" "$archived"
    printf "IDS=%s\n" "$ids"
  ')" || smoke_fail "A3 lib_eval failed: $out"

  local archived ids
  archived="$(printf '%s\n' "$out" | sed -n 's/^ARCHIVED=//p' | head -n1)"
  ids="$(printf '%s\n' "$out" | sed -n 's/^IDS=//p' | head -n1)"

  smoke_assert_eq "" "$archived" \
    "A3 archive of a foreign (operator-HOME) transcript is refused — nothing moved"
  smoke_assert_not_contains "$ids" "$OPERATOR_SESSION_ID" \
    "A3 add refuses to quarantine the foreign (operator) session id"
}

# ===========================================================================
# End-to-end safety invariant — the operator transcript survives untouched.
# ===========================================================================
test_operator_transcript_survives() {
  smoke_assert_file_exists "$OPERATOR_TRANSCRIPT" \
    "operator-HOME transcript is NEVER moved/quarantined (still present after all attempts)"
  local opq="$OPERATOR_HOME/.claude/projects/$SLUG/.quarantined"
  [[ ! -d "$opq" ]] \
    || smoke_fail "operator-HOME slug must have NO .quarantined dir (found $opq)"
}

# --- run ------------------------------------------------------------------
smoke_run "A1 empty isolated config ⇒ fresh, operator not selected" \
  test_a1_empty_isolated_is_fresh
smoke_run "A2 own isolated transcript still resumes (legit preserved)" \
  test_a2_own_transcript_resumes
smoke_run "A3 foreign-transcript quarantine refused" \
  test_a3_foreign_quarantine_refused
smoke_run "operator transcript survives untouched" \
  test_operator_transcript_survives

smoke_log "PASS — dynamic-agent resume detection + quarantine scoped to the agent's own config dir (operator-session hijack fixed)"
