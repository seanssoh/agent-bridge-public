#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/9770-codex-teardown-reap.sh — incident #9770 Track 2.
#
# Codex launches in a tmux pane and internally spawns a `codex app-server`
# child + Pencil `mcp-server-darwin-arm64` grandchildren whose PIDs are tracked
# nowhere. On teardown the global MCP orphan cleaner (DEFAULT_PATTERNS) does NOT
# match codex — a live roster `codex resume` must never be a global-kill
# candidate — so on macOS the app-server reparents to a non-PPID-1 ancestor and
# survives → a linear memory leak.
#
# The fix is a SURGICAL per-session subtree reap rooted at the torn-down
# session's known tmux pane PID (bridge-mcp-cleanup.py `subtree` subcommand,
# wired into bridge-run.sh clean exit + bridge_kill_agent_session + the daemon
# idle/orphan-session kill). This smoke proves the #1 invariant — a live roster
# codex / in-progress review is NEVER killed — using lightweight stand-in
# processes that MIMIC the codex/app-server/MCP command names + pane parentage.
# It does NOT spawn a real codex, real tmux, or a real bridge daemon.
#
# CI-faithful + self-contained: it drives the REAL bridge-mcp-cleanup.py subtree
# logic + sources the REAL lib/bridge-state.sh glue, and grep-pins the three
# teardown seam call sites + the two new audit actions.

set -euo pipefail

SMOKE_NAME="9770-codex-teardown-reap"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REAPER_PY="$SMOKE_REPO_ROOT/bridge-mcp-cleanup.py"
HELPER_PY="$SCRIPT_DIR/9770-codex-teardown-reap-helper.py"
RUN_SH="$SMOKE_REPO_ROOT/bridge-run.sh"
DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"
STATE_SH="$SMOKE_REPO_ROOT/lib/bridge-state.sh"
AGENTS_SH="$SMOKE_REPO_ROOT/lib/bridge-agents.sh"

smoke_require_cmd ps
smoke_require_cmd python3

smoke_log "A1: bridge-mcp-cleanup.py compiles + subtree subcommand wired"
python3 -c "import py_compile; py_compile.compile('$REAPER_PY', doraise=True)" || \
  smoke_fail "bridge-mcp-cleanup.py failed py_compile"
python3 "$REAPER_PY" subtree --root-pid $$ --capture-only --json >/dev/null || \
  smoke_fail "subtree subcommand not callable"

smoke_log "A2: changed shell files are syntactically valid (bash 4+)"
# lib/bridge-agents.sh uses `[[ -v assoc[key] ]]` (bash 4.3+), so the `-n` parse
# must run under a bash 4+ interpreter — the same contract smoke-test.sh enforces
# for the whole suite. Resolve one (prefer the interpreter already running this
# smoke), and fail loudly rather than silently passing under macOS bash 3.2.
BASH4_BIN=""
for candidate in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  major="$("$candidate" -c 'printf %s "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || printf 0)"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 4 )); then
    BASH4_BIN="$candidate"
    break
  fi
done
[[ -n "$BASH4_BIN" ]] || smoke_fail "no bash 4+ interpreter available for bash -n"
for f in "$RUN_SH" "$DAEMON_SH" "$STATE_SH" "$AGENTS_SH"; do
  "$BASH4_BIN" -n "$f" || smoke_fail "$(basename "$f") failed bash -n"
done

# ---------------------------------------------------------------------------
# The crux: the #1 invariant + negative controls, driven against the real
# subtree reaper with stand-in process trees.
# ---------------------------------------------------------------------------
smoke_log "B: (a) clean-exit reap + (c) 2nd live codex survives + (d) non-bridge codex survives + (e) same-pane non-codex survives"
python3 "$HELPER_PY" reap-survival "$REAPER_PY" || \
  smoke_fail "reap-survival assertions failed (#1 invariant or negative control)"

smoke_log "C: (b) daemon idle-kill — capture BEFORE kill, reap captured set AFTER"
python3 "$HELPER_PY" capture-then-reap "$REAPER_PY" || \
  smoke_fail "capture-then-reap (daemon ordering) failed"

smoke_log "D: (f) unresolvable pane → skip, no global sweep"
python3 "$HELPER_PY" no-pane-skip "$REAPER_PY" || \
  smoke_fail "no-pane-skip (global-sweep guard) failed"

smoke_log "E: (g) idempotent 2nd reap pass is ESRCH-clean"
python3 "$HELPER_PY" idempotent "$REAPER_PY" || \
  smoke_fail "idempotent 2nd pass failed"

# ---------------------------------------------------------------------------
# DEFAULT_PATTERNS must stay codex-free: the global orphan path is untouched, so
# a live roster `codex resume` can never become a global-cleanup candidate.
# ---------------------------------------------------------------------------
smoke_log "F: DEFAULT_PATTERNS does NOT include codex / app-server / Pencil MCP"
python3 "$HELPER_PY" default-patterns-codex-free "$REAPER_PY" || \
  smoke_fail "DEFAULT_PATTERNS now matches codex/app-server/Pencil MCP — global orphan path must stay codex-free"

# ---------------------------------------------------------------------------
# Shell glue: source the real lib stack in an isolated BRIDGE_HOME and exercise
# the audit-summary redaction (no command strings leak) + extract round-trip.
# ---------------------------------------------------------------------------
smoke_log "G: audit summary is redacted (counts only, no command strings)"
audit_summary="$(python3 "$REAPER_PY" subtree-audit-summary --report \
  '{"mode":"subtree","captured_count":2,"killed_count":2,"skipped_count":0,"error_count":0,"freed_mb_estimate":3.3,"captured":[{"command":"codex app-server --cwd /Users/secret/path"}]}')"
smoke_assert_contains "$audit_summary" "captured=2" "audit summary captured count"
smoke_assert_contains "$audit_summary" "killed=2" "audit summary killed count"
smoke_assert_not_contains "$audit_summary" "/Users/secret/path" "audit summary must NOT leak command paths"
smoke_assert_not_contains "$audit_summary" "codex app-server" "audit summary must NOT leak command strings"

empty_summary="$(python3 "$REAPER_PY" subtree-audit-summary --report \
  '{"captured_count":0,"killed_count":0,"skipped_count":0,"error_count":0}')"
smoke_assert_eq "" "$empty_summary" "audit summary empty when no activity"

# ---------------------------------------------------------------------------
# Seam coverage: all three central teardown paths invoke the subtree reap, and
# the two new audit actions exist.
# ---------------------------------------------------------------------------
smoke_log "H: all three teardown seams wire the subtree reap"
grep -q 'bridge_codex_subtree_reap_for_session' "$RUN_SH" || \
  smoke_fail "bridge-run.sh clean-exit does not call bridge_codex_subtree_reap_for_session"
grep -q 'bridge_codex_subtree_capture' "$AGENTS_SH" || \
  smoke_fail "bridge_kill_agent_session does not capture the codex subtree before kill"
grep -q 'bridge_codex_subtree_reap_captured' "$AGENTS_SH" || \
  smoke_fail "bridge_kill_agent_session does not reap the captured codex subtree after kill"
grep -q 'bridge_codex_subtree_capture' "$DAEMON_SH" || \
  smoke_fail "daemon idle/orphan kill does not capture the codex subtree before kill"
grep -q 'bridge_codex_subtree_reap_captured' "$DAEMON_SH" || \
  smoke_fail "daemon idle/orphan kill does not reap the captured codex subtree after kill"

smoke_log "I: capture happens BEFORE the tmux kill on both external-kill seams"
# In bridge_kill_agent_session the capture line must precede bridge_tmux_kill_session.
cap_ln="$(grep -n 'bridge_codex_subtree_capture' "$AGENTS_SH" | head -n1 | cut -d: -f1)"
kill_ln="$(awk '/bridge_kill_agent_session\(\)/{f=1} f&&/bridge_tmux_kill_session "\$session"/{print NR; exit}' "$AGENTS_SH")"
[[ -n "$cap_ln" && -n "$kill_ln" ]] || smoke_fail "could not locate capture/kill lines in bridge_kill_agent_session"
(( cap_ln < kill_ln )) || smoke_fail "codex subtree capture must precede tmux kill in bridge_kill_agent_session"

smoke_log "J: the two new audit actions are emitted"
grep -q 'codex_session_subtree_reaped' "$STATE_SH" || \
  smoke_fail "codex_session_subtree_reaped audit action missing"
grep -rq 'codex_subtree_reap_skipped_no_pane' "$STATE_SH" "$AGENTS_SH" "$DAEMON_SH" || \
  smoke_fail "codex_subtree_reap_skipped_no_pane audit action missing"

smoke_log "PASS: $SMOKE_NAME"
