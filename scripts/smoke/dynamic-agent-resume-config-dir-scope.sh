#!/usr/bin/env bash
# scripts/smoke/dynamic-agent-resume-config-dir-scope.sh
#
# Operator-session-hijack regression (SAFETY-CRITICAL).
#
# Live data-loss: launching a NEW dynamic agent in a folder where the operator
# has a vanilla (non-bridge) Claude session DESTROYED the operator's session —
# its transcript was moved to `.quarantined/` and vanished from `claude
# --resume`.
#
# #1889 fixed this by scoping dynamic-agent resume detection + quarantine to the
# agent's OWN private config dir. #1890 SUPERSEDES that for dynamic Claude: a
# dynamic Claude agent now runs as VANILLA Claude Code against the operator-
# global ~/.claude and NEVER uses bridge resume / quarantine at all (resume is
# native `claude --continue`, keyed by workdir). The safety property is the same
# — the operator's transcript is never resume-hijacked and never quarantined —
# but the mechanism flips from "scope to the agent's own private dir" to "no
# bridge resume/quarantine machinery for dynamic Claude".
#
# This smoke pins the #1890 dynamic-Claude contract with a differential fixture:
# an isolated BRIDGE_HOME + a FAKE operator HOME holding a vanilla transcript for
# the agent's workdir slug.
#
#   A1 (#1890) — for a dynamic Claude agent `bridge_resolve_agent_claude_config_
#     dir` returns EMPTY (operator-global passthrough; detection-dir == launch-
#     dir == $HOME/.claude, no private dir). The predicate
#     `bridge_agent_is_dynamic_vanilla_claude` is the only boundary.
#   A2 (#1890) — even if a transcript exists under the legacy per-agent dir, the
#     resolver still returns EMPTY for a dynamic Claude agent: the bridge no
#     longer keys resume off a private dir for these agents.
#   A3 (#1889 carry-over + #1890 guard) — a quarantine/archive attempt for the
#     operator session is REFUSED (the explicit dynamic-Claude guard fires before
#     any path resolution): the operator transcript is NOT moved and stays
#     present.
#   A4 (#1893 Finding 2) — a DYNAMIC CODEX agent (NOT dynamic-vanilla-claude, so
#     the F1 branch + F2 archive python actually run) whose <agent-home>/.claude
#     does NOT exist resolves to its OWN (empty) dir, not the operator HOME — the
#     F1 branch now sits ABOVE the `-d` guard. No operator-session fallback.
#   A5 (#1893 Finding 1) — a DYNAMIC CODEX agent whose <agent-home>/.claude is a
#     symlink to the operator's global ~/.claude: the F1 realpath compare + the
#     F2 archive's operator-HOME refuse mean the operator transcript is NEVER
#     moved (raw-string F1 used to return it as "own" and F2 then destroyed it).
#
# Plus the end-to-end safety invariant: across A1+A3+A4+A5 the operator-HOME
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
#
# Optional 3rd arg = engine (default `claude`). A4/A5 use a dynamic CODEX agent
# so the #1890 bridge_agent_is_dynamic_vanilla_claude early-return is NOT taken
# and the resolver's #1893 F1 branch + the F2 archive python actually run — that
# is the exact code #1893 hardens. (A dynamic CLAUDE agent on this Darwin shape
# is dynamic-vanilla-claude and short-circuits to EMPTY before F1/F2, which is
# the #1890 contract A1/A2/A3 already pin.) The Claude per-agent config dir
# resolver is engine-agnostic, so a dynamic codex agent still derives a
# <agent-home>/.claude path — the same path the sabotage targets.
# ---------------------------------------------------------------------------
lib_eval() {
  local agent="$1"
  local snippet="$2"
  local engine="${3:-claude}"
  HOME="$OPERATOR_HOME" \
  BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" \
  "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_reset_roster_maps

    agent='$agent'
    BRIDGE_AGENT_IDS+=(\$agent)
    BRIDGE_AGENT_ENGINE[\$agent]='$engine'
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
# A1 (#1890) — a dynamic Claude agent resolves to EMPTY (operator-global
# passthrough). The legacy per-agent dir is NOT used: detection-dir mirrors the
# launch-dir, which for dynamic Claude is $HOME/.claude (operator global). The
# resolver must return EMPTY so the python detect helper / quarantine resolver
# fall back to the operator HOME — and so the explicit predicate boundary is the
# one gate.
# ===========================================================================
A1_AGENT="dyn_fresh"

test_a1_dynamic_claude_resolves_empty() {
  local out=""
  out="$(lib_eval "$A1_AGENT" '
    # Materialize the (now-unused) legacy per-agent config dir to prove the
    # resolver ignores it for dynamic Claude.
    mkdir -p "$cfg/projects" "$cfg/sessions"
    is_vanilla="no"
    if bridge_agent_is_dynamic_vanilla_claude "$agent"; then is_vanilla="yes"; fi
    resolved="$(bridge_resolve_agent_claude_config_dir "$agent")"
    printf "CFG=%s\n" "$cfg"
    printf "ISVANILLA=%s\n" "$is_vanilla"
    printf "RESOLVED=%s\n" "$resolved"
  ')" || smoke_fail "A1 lib_eval failed: $out"

  local is_vanilla resolved
  is_vanilla="$(printf '%s\n' "$out" | sed -n 's/^ISVANILLA=//p' | head -n1)"
  resolved="$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p' | head -n1)"

  smoke_assert_eq "yes" "$is_vanilla" \
    "A1 a shared-mode dynamic Claude agent is classified dynamic-vanilla-claude (#1890 boundary)"
  # #1890: dynamic Claude resolves to EMPTY (operator-global passthrough).
  smoke_assert_eq "" "$resolved" \
    "A1 dynamic Claude config dir resolves EMPTY (operator-global ~/.claude passthrough, no private dir)"
}

# ===========================================================================
# A2 (#1890) — even WITH a transcript present under the legacy per-agent dir,
# the resolver still returns EMPTY for a dynamic Claude agent. The bridge no
# longer keys resume off a private dir for these agents (resume is native
# `claude --continue`).
# ===========================================================================
A2_AGENT="dyn_own_resume"

test_a2_dynamic_claude_ignores_private_transcript() {
  local out=""
  out="$(lib_eval "$A2_AGENT" '
    slug="'"$SLUG"'"
    own_sid="'"$AGENT_OWN_SESSION_ID"'"
    mkdir -p "$cfg/projects/$slug" "$cfg/sessions"
    # A prior transcript under the legacy per-agent dir — must NOT be resolved.
    printf "{\"sessionId\":\"%s\",\"type\":\"user\"}\n" "$own_sid" \
      >"$cfg/projects/$slug/$own_sid.jsonl"
    resolved="$(bridge_resolve_agent_claude_config_dir "$agent")"
    printf "RESOLVED=%s\n" "$resolved"
  ')" || smoke_fail "A2 lib_eval failed: $out"

  local resolved
  resolved="$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p' | head -n1)"

  smoke_assert_eq "" "$resolved" \
    "A2 dynamic Claude resolver returns EMPTY even with a legacy per-agent transcript present (#1890)"
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
# A4 (#1893 Finding 2) — a registered DYNAMIC agent whose <agent-home>/.claude
# does NOT exist on disk must resolve to its OWN (empty) dir — "fresh, scan my
# own dir" — NOT fall back to the operator HOME. Pre-#1893 the resolver returned
# EMPTY at the `-d` guard for a missing dir, which let detection fall back to the
# operator HOME and resume-SELECT an operator session. Uses a dynamic CODEX
# agent so the #1890 vanilla-claude short-circuit is not taken and the F1 branch
# (now hoisted above the `-d` guard) runs.
#   FAIL on un-fixed code: resolver returns "" (operator-HOME fallback path).
#   PASS on the fix:        resolver returns the agent's own dir ($cfg).
# ===========================================================================
A4_AGENT="dyn_missing_cfg"

test_a4_missing_isolated_claude_no_operator_fallback() {
  local out=""
  out="$(lib_eval "$A4_AGENT" '
    # Deliberately do NOT create "$cfg" — the isolated .claude is absent.
    [[ -e "$cfg" ]] && rm -rf "$cfg"
    ophome="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
    resolved="$(bridge_resolve_agent_claude_config_dir "$agent")"
    printf "CFG=%s\n" "$cfg"
    printf "OPCLAUDE=%s\n" "$ophome/.claude"
    printf "RESOLVED=%s\n" "$resolved"
  ' codex)" || smoke_fail "A4 lib_eval failed: $out"

  local cfg resolved opclaude
  cfg="$(printf '%s\n' "$out" | sed -n 's/^CFG=//p' | head -n1)"
  opclaude="$(printf '%s\n' "$out" | sed -n 's/^OPCLAUDE=//p' | head -n1)"
  resolved="$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p' | head -n1)"

  smoke_assert_eq "$cfg" "$resolved" \
    "A4 a missing isolated .claude resolves to the agent's OWN dir (fresh), not EMPTY (#1893 Finding 2 hoist)"
  smoke_assert_not_contains "$resolved" "$opclaude" \
    "A4 the resolved dir is NOT the operator HOME ~/.claude (no operator-session fallback)"
}

# ===========================================================================
# A5 (#1893 Finding 1) — a SABOTAGED <agent-home>/.claude symlinked to the
# operator's global ~/.claude must NOT cause the operator transcript to be
# moved. F1's raw-string exclusion was defeated by the symlink (path string-
# differs) → resolver returned it as the agent's "own" dir → F2 archive resolved
# projects_root INTO operator HOME and physically moved the operator transcript
# (DATA LOSS). The #1893 realpath compare (F1) + the F2 archive's operator-HOME
# refuse close it. Uses a dynamic CODEX agent (F1/F2 actually run).
#   FAIL on un-fixed code: F2 moves the operator transcript (archived != "",
#                          operator transcript GONE).
#   PASS on the fix:       F2 refuses (archived == ""), transcript survives.
# ===========================================================================
A5_AGENT="dyn_symlink_sabotage"

test_a5_symlinked_config_dir_refuses_move() {
  local out=""
  out="$(lib_eval "$A5_AGENT" '
    op_sid="'"$OPERATOR_SESSION_ID"'"
    ophome="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
    # Sabotage: replace the agent own .claude with a symlink to operator global.
    [[ -e "$cfg" ]] && rm -rf "$cfg"
    mkdir -p "$(dirname "$cfg")"
    ln -s "$ophome/.claude" "$cfg"
    # F1: the resolver must NOT short-circuit-return the symlink at the dynamic
    # branch (it realpaths into operator HOME ⇒ falls through). We cannot observe
    # the branch directly, but the data-loss guard is F2:
    archived="$(bridge_agent_resume_quarantine_archive_transcript "$agent" "$op_sid" 2>/dev/null \
      | tr "\n" "," | sed "s/,\$//")"
    printf "ARCHIVED=%s\n" "$archived"
  ' codex)" || smoke_fail "A5 lib_eval failed: $out"

  local archived
  archived="$(printf '%s\n' "$out" | sed -n 's/^ARCHIVED=//p' | head -n1)"

  smoke_assert_eq "" "$archived" \
    "A5 symlinked-to-operator config dir: F2 archive REFUSES the move (nothing moved, #1893 Finding 1)"
  smoke_assert_file_exists "$OPERATOR_TRANSCRIPT" \
    "A5 the operator transcript survives the symlink-sabotage archive attempt"
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
smoke_run "A1 dynamic Claude resolves EMPTY (operator-global passthrough)" \
  test_a1_dynamic_claude_resolves_empty
smoke_run "A2 dynamic Claude ignores legacy private transcript" \
  test_a2_dynamic_claude_ignores_private_transcript
smoke_run "A3 foreign-transcript quarantine refused" \
  test_a3_foreign_quarantine_refused
smoke_run "A4 missing isolated .claude => own (empty) dir, no operator fallback" \
  test_a4_missing_isolated_claude_no_operator_fallback
smoke_run "A5 symlinked-to-operator config dir => F2 refuses move" \
  test_a5_symlinked_config_dir_refuses_move
smoke_run "operator transcript survives untouched" \
  test_operator_transcript_survives

smoke_log "PASS — #1890 dynamic Claude = operator-global passthrough; #1893 realpath-harden (missing/symlinked config dir) never moves the operator session"
