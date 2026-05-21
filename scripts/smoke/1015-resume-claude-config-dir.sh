#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1015-resume-claude-config-dir.sh — Issue #1015.
#
# Pins the contract that the Claude session-id helpers resolve their
# `~/.claude/sessions` + `~/.claude/projects` roots from the *agent's*
# CLAUDE_CONFIG_DIR, not the daemon process's HOME.
#
# Root cause (issue #1015): static Claude agents launched by the
# isolation-v2 stack run with a custom HOME / CLAUDE_CONFIG_DIR, so the
# session JSON and transcripts land under `<agent-home>/.claude/`. Both
# python helpers expanded `~/.claude/...` against the daemon HOME, found
# nothing, returned rc=1, and `bridge_normalize_agent_session_id` then
# cleared the stored id — every restart launched a fresh session.
#
# The fix: both helpers resolve the config root from, in priority order,
# an explicit trailing argument > the CLAUDE_CONFIG_DIR env var >
# <HOME>/.claude > os.path.expanduser("~/.claude"). The last two preserve
# the pre-#1015 daemon-HOME behaviour for non-isolated agents.
#
# Test plan (all run directly against the two python helpers, no live
# tmux, no bridge runtime):
#   T1. detect-claude-session-id.py finds the live session id when the
#       agent's config dir is passed as the trailing argument.
#   T2. detect-claude-session-id.py finds it via the CLAUDE_CONFIG_DIR
#       env var when no argument is supplied.
#   T3. detect-claude-session-id.py with no config dir and no env var
#       falls back to the ambient HOME — the fixture lives elsewhere so
#       it must NOT be discovered (backward-compatible non-isolated path).
#   T4. resolve-claude-resume-session-id.py accepts the candidate id
#       (rc=0) when the agent's config dir is passed as the trailing arg.
#   T5. resolve-claude-resume-session-id.py accepts it via the
#       CLAUDE_CONFIG_DIR env var.
#   T6. resolve-claude-resume-session-id.py with no config dir and no env
#       var rejects the candidate (rc=1) — the daemon-HOME fallback finds
#       no transcript, exactly as before #1015.
#
# Isolation: a self-contained fixture dir under SMOKE_TMP_ROOT; the smoke
# never reads or writes the operator's live `~/.claude` or bridge runtime.
# Each "no config dir" case runs with HOME pointed at an empty temp dir so
# the operator's real `~/.claude` cannot mask the fallback assertion.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf` / `cat >file <<EOF` plain-body writes — no command
# substitution feeding a heredoc-stdin, no `<<<` here-strings into bridge
# functions.

set -euo pipefail

SMOKE_NAME="1015-resume-claude-config-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_make_temp_root "1015-resume-claude-config-dir"

REPO_ROOT="$SMOKE_REPO_ROOT"
DETECT_HELPER="$REPO_ROOT/scripts/python-helpers/detect-claude-session-id.py"
RESOLVE_HELPER="$REPO_ROOT/scripts/python-helpers/resolve-claude-resume-session-id.py"

[[ -f "$DETECT_HELPER" ]] || smoke_fail "missing helper: $DETECT_HELPER"
[[ -f "$RESOLVE_HELPER" ]] || smoke_fail "missing helper: $RESOLVE_HELPER"

# --- Fixture: an agent config dir with a live session + matching
#     transcript, mimicking what an isolation-v2 agent writes under
#     <agent-home>/.claude/ . -----------------------------------------
AGENT_CONFIG_DIR="$SMOKE_TMP_ROOT/agent-home/.claude"
WORKDIR="$SMOKE_TMP_ROOT/agent-workdir"
SESSION_ID="abc12345-1015-resume-fixture"
mkdir -p "$WORKDIR"

# Claude encodes the project dir by replacing "/" with "-".
WORKDIR_SLUG="${WORKDIR//\//-}"
mkdir -p "$AGENT_CONFIG_DIR/sessions" "$AGENT_CONFIG_DIR/projects/$WORKDIR_SLUG"

# Live `sessions/<pid>.json` — use this shell's own pid so pid_is_alive()
# returns true (the #827 live-session shortcut both helpers honour).
NOW_MS=$(( $(date +%s) * 1000 ))
cat >"$AGENT_CONFIG_DIR/sessions/$$.json" <<EOF
{"sessionId":"$SESSION_ID","cwd":"$WORKDIR","pid":$$,"startedAt":$NOW_MS}
EOF

# Matching fresh transcript so the transcript-scan path also resolves.
printf '{"sessionId":"%s"}\n' "$SESSION_ID" \
  >"$AGENT_CONFIG_DIR/projects/$WORKDIR_SLUG/$SESSION_ID.jsonl"

# An empty HOME for the "no config dir" fallback cases, so the operator's
# real ~/.claude cannot accidentally satisfy (or break) the assertion.
EMPTY_HOME="$SMOKE_TMP_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"

# T1 — detect helper picks up the agent config dir via the trailing arg.
test_detect_via_argument() {
  local out=""
  out="$(python3 "$DETECT_HELPER" "$WORKDIR" 0 "" "$AGENT_CONFIG_DIR")"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T1 detect helper resolves session via trailing config-dir argument"
}

# T2 — detect helper picks up the agent config dir via CLAUDE_CONFIG_DIR.
test_detect_via_env() {
  local out=""
  out="$(CLAUDE_CONFIG_DIR="$AGENT_CONFIG_DIR" \
    python3 "$DETECT_HELPER" "$WORKDIR" 0 "")"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T2 detect helper resolves session via CLAUDE_CONFIG_DIR env var"
}

# T3 — detect helper with no config dir falls back to the ambient HOME;
# the fixture lives elsewhere so nothing is found (non-isolated path,
# unchanged from pre-#1015).
test_detect_fallback_finds_nothing() {
  local out=""
  out="$(env -u CLAUDE_CONFIG_DIR HOME="$EMPTY_HOME" \
    python3 "$DETECT_HELPER" "$WORKDIR" 0 "")"
  smoke_assert_eq "" "$out" \
    "T3 detect helper daemon-HOME fallback finds no fixture session"
}

# T4 — resolve helper accepts the candidate (rc=0) via the trailing arg.
test_resolve_via_argument() {
  local out="" rc=0
  set +e
  out="$(python3 "$RESOLVE_HELPER" \
    "$WORKDIR" "$SESSION_ID" 48 testagent "" "$AGENT_CONFIG_DIR" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T4 resolve helper rc=0 when config dir passed as trailing argument"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T4 resolve helper returns the candidate session id"
}

# T5 — resolve helper accepts the candidate (rc=0) via CLAUDE_CONFIG_DIR.
test_resolve_via_env() {
  local out="" rc=0
  set +e
  out="$(CLAUDE_CONFIG_DIR="$AGENT_CONFIG_DIR" \
    python3 "$RESOLVE_HELPER" \
    "$WORKDIR" "$SESSION_ID" 48 testagent "" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T5 resolve helper rc=0 when config dir comes from CLAUDE_CONFIG_DIR"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T5 resolve helper returns the candidate session id via env var"
}

# T6 — resolve helper with no config dir falls back to the ambient HOME;
# no transcript exists there so the candidate is rejected (rc=1), exactly
# as before #1015 (the non-isolated path must not regress).
test_resolve_fallback_rejects() {
  local rc=0
  set +e
  env -u CLAUDE_CONFIG_DIR HOME="$EMPTY_HOME" \
    python3 "$RESOLVE_HELPER" \
    "$WORKDIR" "$SESSION_ID" 48 testagent "" >/dev/null 2>&1
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" \
    "T6 resolve helper daemon-HOME fallback rejects candidate (rc=1)"
}

smoke_run "T1 detect resolves via trailing argument"   test_detect_via_argument
smoke_run "T2 detect resolves via CLAUDE_CONFIG_DIR"    test_detect_via_env
smoke_run "T3 detect fallback finds no fixture"         test_detect_fallback_finds_nothing
smoke_run "T4 resolve accepts via trailing argument"    test_resolve_via_argument
smoke_run "T5 resolve accepts via CLAUDE_CONFIG_DIR"    test_resolve_via_env
smoke_run "T6 resolve fallback rejects candidate"       test_resolve_fallback_rejects

smoke_log "all checks passed"
