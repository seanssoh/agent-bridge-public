#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1181-modal-blocker-detect.sh — Issue #1181.
#
# A long-running static Claude agent goes silently deaf when Claude Code's
# post-session feedback survey ("How is Claude doing this session? ... 0:
# Dismiss") is drawn into its input pane: the composer never consumes pasted
# nudges, yet `agb status` reports wake=ok / idle / active. The Layer 1 fix
# (detection + status/audit, NO key-sending) adds:
#
#   1. New bridge_tmux_claude_blocker_state_from_text branches for the feedback
#      survey + permission_grant / overwrite_confirm / context_pressure modals,
#      preserving the trailing `none` default (no caller breakage).
#   2. A shared bridge_tmux_claude_blocker_state_is_block predicate, the SINGLE
#      source of truth for the wake=block modal list, called from BOTH the
#      status-snapshot writer and the agent-show/wake path so the list can't
#      drift between surfaces.
#   3. A trailing `wake_reason` column on the roster status snapshot TSV
#      (header + row in lockstep), surfaced by bridge-status.py as a named
#      --json field and a "Wake Blocked" human block.
#
# This smoke is detection/status/audit only — it never drives a tmux submit
# path. It covers: the matcher mapping (all existing + new signatures), the
# is_block predicate (block list vs. the intentionally-excluded devchannels /
# none), the snapshot header/row lockstep, and the bridge-status.py wake_reason
# surfaces (--json + human "Wake Blocked" block).
#
# Footgun #11: no heredoc-stdin into a subprocess; fixtures use printf/Write.

set -euo pipefail

# Re-exec under Bash 4+ for the matcher's `[[ == ]]` glob semantics + the
# associative-array sourcing in bridge-lib.sh (matches sibling smokes).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1181-modal-blocker-detect] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1181-modal-blocker-detect"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1181-modal-blocker-detect"

REPO_ROOT="$SMOKE_REPO_ROOT"
TMUX_SH="$REPO_ROOT/lib/bridge-tmux.sh"
STATE_SH="$REPO_ROOT/lib/bridge-state.sh"
AGENTS_SH="$REPO_ROOT/lib/bridge-agents.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
STATUS_PY="$REPO_ROOT/bridge-status.py"

smoke_assert_file_exists "$TMUX_SH" "lib/bridge-tmux.sh present"
smoke_assert_file_exists "$STATE_SH" "lib/bridge-state.sh present"
smoke_assert_file_exists "$AGENTS_SH" "lib/bridge-agents.sh present"
smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"
smoke_assert_file_exists "$STATUS_PY" "bridge-status.py present"
smoke_require_cmd python3

# ---------------------------------------------------------------------------
# Source only the two pure-text helpers under test, so the smoke does not pull
# the whole bridge-lib.sh dependency graph (the matcher is pure string logic).
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^bridge_tmux_claude_blocker_state_from_text\(\)/,/^}/' "$TMUX_SH")
# shellcheck disable=SC1090
source <(awk '/^bridge_tmux_claude_blocker_state_is_block\(\)/,/^}/' "$TMUX_SH")

declare -F bridge_tmux_claude_blocker_state_from_text >/dev/null \
  || smoke_fail "bridge_tmux_claude_blocker_state_from_text not defined after source"
declare -F bridge_tmux_claude_blocker_state_is_block >/dev/null \
  || smoke_fail "bridge_tmux_claude_blocker_state_is_block not defined (shared predicate missing)"

# ---------------------------------------------------------------------------
# A) matcher mapping — existing signatures preserved + new ones detected;
#    a non-modal / empty pane returns the safe `none`.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_a_matcher_mapping() {
  local FEEDBACK="How is Claude doing this session? (optional)
  1: Bad    2: Fine   3: Good   0: Dismiss"
  local PERM="Allow Bash command for this session? (y/n)"
  local OVERWRITE="dest.txt already exists. Overwrite? (y/n)"
  local CONTEXT="Approaching context pressure limit. Press Enter to compact."
  local TRUST="Quick safety check: Do you trust this folder? Yes, I trust this folder"
  local SUMMARY="Resume from summary (recommended)
Resume full session as-is"
  local DEVCH="WARNING: Loading development channels
I am using this for local development"
  local IDLE="❯ waiting for your input"

  smoke_assert_eq "feedback_survey" \
    "$(bridge_tmux_claude_blocker_state_from_text "$FEEDBACK")" "feedback survey detected"
  smoke_assert_eq "permission_grant" \
    "$(bridge_tmux_claude_blocker_state_from_text "$PERM")" "permission grant detected"
  smoke_assert_eq "overwrite_confirm" \
    "$(bridge_tmux_claude_blocker_state_from_text "$OVERWRITE")" "overwrite confirm detected"
  smoke_assert_eq "context_pressure" \
    "$(bridge_tmux_claude_blocker_state_from_text "$CONTEXT")" "context pressure detected"

  # Existing signatures must be untouched (no caller breakage).
  smoke_assert_eq "trust" \
    "$(bridge_tmux_claude_blocker_state_from_text "$TRUST")" "trust still detected"
  smoke_assert_eq "summary" \
    "$(bridge_tmux_claude_blocker_state_from_text "$SUMMARY")" "summary still detected"
  smoke_assert_eq "devchannels" \
    "$(bridge_tmux_claude_blocker_state_from_text "$DEVCH")" "devchannels still detected"

  # Safe direction: a missed match returns none.
  smoke_assert_eq "none" \
    "$(bridge_tmux_claude_blocker_state_from_text "$IDLE")" "non-modal pane returns none"
  smoke_assert_eq "none" \
    "$(bridge_tmux_claude_blocker_state_from_text "")" "empty pane returns none"
}

# ---------------------------------------------------------------------------
# B) is_block predicate — the centralised wake=block list. trust/summary +
#    the four new modals block; devchannels and none/unknown do NOT (the
#    conservative, behaviour-preserving direction).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_b_is_block_predicate() {
  local s
  for s in trust summary feedback_survey permission_grant overwrite_confirm context_pressure; do
    bridge_tmux_claude_blocker_state_is_block "$s" \
      || smoke_fail "is_block($s) should be a wake=block state"
  done
  for s in devchannels none "" bogus_state; do
    if bridge_tmux_claude_blocker_state_is_block "$s"; then
      smoke_fail "is_block('${s}') must NOT be a wake=block state"
    fi
  done
}

# ---------------------------------------------------------------------------
# C) snapshot writer header/row lockstep — the wake_reason column must be the
#    SAME trailing position in both the TSV header and the data row, and the
#    writer must route the blocker state through the shared is_block predicate
#    (not the old trust|summary-only case arm).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_c_snapshot_lockstep() {
  # The header line and the data row are emitted by the same writer. Confirm
  # both end with the wake_reason field so a future refactor cannot widen one
  # without the other (which would shift every column for the DictReader).
  # The roster status snapshot header is the one carrying the channels column
  # (a SEPARATE idle-ready snapshot writer in the same file has no channels).
  local header_line row_line
  header_line="$(grep -n 'echo -e "agent\\tengine.*\\tchannels\\t' "$STATE_SH" | head -n 1)"
  [[ -n "$header_line" ]] || smoke_fail "could not find roster status snapshot TSV header in bridge-state.sh"
  smoke_assert_contains "$header_line" 'wake_reason' "snapshot header has trailing wake_reason column"

  row_line="$(grep -n 'echo -e "\${agent}\\t\${engine}.*\${channels}' "$STATE_SH" | head -n 1)"
  [[ -n "$row_line" ]] || smoke_fail "could not find roster status snapshot TSV data row in bridge-state.sh"
  smoke_assert_contains "$row_line" '${wake_reason}' "snapshot data row has trailing wake_reason field"

  # Both lines must reference wake_reason as their LAST tab-field so the
  # header and row stay in lockstep.
  smoke_assert_match "$header_line" 'wake_reason"$' "wake_reason is the last header column"
  smoke_assert_match "$row_line" '\$\{wake_reason\}"$' "wake_reason is the last row field"

  # The writer must call the shared predicate, not the old hardcoded arm.
  grep -q 'bridge_tmux_claude_blocker_state_is_block' "$STATE_SH" \
    || smoke_fail "snapshot writer no longer routes through the shared is_block predicate"

  # The agent-show / wake path must use the SAME predicate (centralised list).
  grep -q 'bridge_tmux_claude_blocker_state_is_block' "$AGENTS_SH" \
    || smoke_fail "bridge_agent_wake_status no longer uses the shared is_block predicate"
}

# ---------------------------------------------------------------------------
# D) daemon nudge-drop audit — the dropped-nudge emission must probe the live
#    blocker state and tag reason=modal_<state> while keeping
#    submit_lost_post_grace reserved for the #331 composer race. Detection
#    only: it must NOT route through bridge_tmux_send_and_submit.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_d_daemon_audit_reason() {
  grep -q 'modal_\${_blocker_state}' "$DAEMON_SH" \
    || smoke_fail "daemon nudge-drop does not tag reason=modal_<state>"
  # The composer-race reason stays the reserved default the modal probe only
  # overrides when a live blocker is detected.
  grep -q '_nudge_drop_reason="submit_lost_post_grace"' "$DAEMON_SH" \
    || smoke_fail "submit_lost_post_grace reason must remain reserved for the #331 race"
  # Fence: Layer 1 is detection only — the drop probe must NOT route through the
  # high-risk submit path. Confirm the modal-detect region (from the reserved
  # default to the audit emission) uses the read-only blocker-state capture, not
  # bridge_tmux_send_and_submit.
  # Region = from the reserved-default assignment up to (and including) the
  # `--detail reason=` line. Anchored on the unique _nudge_drop_reason marker so
  # it cannot trip over the earlier session_nudge_dropped_stale emission.
  local region
  region="$(awk '/local _nudge_drop_reason=/{f=1} f{print} f&&/--detail reason=/{exit}' "$DAEMON_SH")"
  [[ -n "$region" ]] || smoke_fail "could not extract the nudge-drop modal-probe region"
  smoke_assert_contains "$region" "bridge_tmux_claude_blocker_state" "modal probe uses read-only blocker-state capture"
  smoke_assert_not_contains "$region" "bridge_tmux_send_and_submit" "Layer 1 must not route through the submit path"
}

# ---------------------------------------------------------------------------
# E) bridge-status.py surfaces — drive the real renderer against a synthesized
#    snapshot so wake=block + wake_reason flows through to both --json and the
#    human "Wake Blocked" block. Detection/status only; no live runtime.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
build_min_db() {
  local db="$1"
  # NOTE: inline via `python3 -c` (single-quoted body, no single quotes inside)
  # rather than a `python3 - <<PY` heredoc — heredoc-stdin to a subprocess is the
  # Bash 5.3.9 footgun #11 deadlock surface the lint-heredoc-ban ratchet rejects.
  python3 -c '
import sqlite3, sys, time
db = sys.argv[1]
conn = sqlite3.connect(db)
conn.executescript(
    """
    CREATE TABLE tasks (
      id INTEGER PRIMARY KEY,
      assigned_to TEXT,
      claimed_by TEXT,
      status TEXT,
      priority TEXT,
      title TEXT,
      created_by TEXT,
      updated_ts INTEGER,
      lease_until_ts INTEGER
    );
    CREATE TABLE agent_state (
      agent TEXT PRIMARY KEY,
      active INTEGER,
      last_seen_ts INTEGER,
      last_heartbeat_ts INTEGER,
      session_activity_ts INTEGER,
      last_nudge_ts INTEGER
    );
    """
)
now = int(time.time())
conn.execute(
    "INSERT INTO agent_state (agent, active, last_seen_ts, last_heartbeat_ts, session_activity_ts, last_nudge_ts)"
    " VALUES (?, 1, ?, ?, ?, ?)",
    ("watcher", now, now, now, now),
)
conn.commit()
conn.close()
' "$db"
}

# shellcheck disable=SC2329
test_e_status_surfaces() {
  local stage="$SMOKE_TMP_ROOT/status-stage"
  mkdir -p "$stage"
  local snapshot="$stage/roster-snapshot.tsv"
  local db="$stage/tasks.db"
  local pidfile="$stage/daemon.pid"
  : >"$pidfile"

  # Synthesized snapshot row: the wake_reason column is the SAME trailing
  # position the writer emits (12 leading columns + wake_reason). The agent is
  # active+idle with wake=block / wake_reason=feedback_survey — exactly the
  # silently-deaf state from the issue.
  {
    printf 'agent\tengine\tsession\tworkdir\tsource\tloop\tactive\twake\tchannels\tchannel_reason\tactivity_state\tconfigured_channels\twake_reason\n'
    printf 'watcher\tclaude\tagb-watcher\t/tmp/wd\tstatic\t1\t1\tblock\tok\t\tidle\tdiscord\tfeedback_survey\n'
  } >"$snapshot"

  build_min_db "$db"

  local json_out
  json_out="$(python3 "$STATUS_PY" \
    --roster-snapshot "$snapshot" \
    --db "$db" \
    --daemon-pid-file "$pidfile" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --json 2>/dev/null)" \
    || smoke_fail "bridge-status.py --json exited non-zero"

  # Named --json field carries the modal class. Inline via `python3 -c`
  # (single-quoted body) rather than heredoc-stdin — see build_min_db NOTE.
  # f-strings precompute their values so the body stays single-quote-free.
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
agents = data.get("agents", {})
w = agents.get("watcher")
assert w is not None, "watcher agent missing from --json"
wake = w.get("wake")
assert wake == "block", f"expected wake=block, got {wake!r}"
reason = w.get("wake_reason")
assert reason == "feedback_survey", f"expected wake_reason=feedback_survey, got {reason!r}"
' "$json_out" || smoke_fail "wake_reason not surfaced in --json for the blocked agent"

  # Human render names the modal in the "Wake Blocked" block.
  local human_out
  human_out="$(python3 "$STATUS_PY" \
    --roster-snapshot "$snapshot" \
    --db "$db" \
    --daemon-pid-file "$pidfile" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" 2>/dev/null)" \
    || smoke_fail "bridge-status.py human render exited non-zero"

  smoke_assert_contains "$human_out" "Wake Blocked" "human render shows the Wake Blocked block"
  smoke_assert_contains "$human_out" "watcher: feedback_survey" "Wake Blocked block names the modal class"
}

smoke_run "A: matcher mapping (existing preserved + new modals + safe none)" test_a_matcher_mapping
smoke_run "B: is_block predicate (block list vs. excluded devchannels/none)" test_b_is_block_predicate
smoke_run "C: snapshot header/row lockstep + shared predicate" test_c_snapshot_lockstep
smoke_run "D: daemon nudge-drop tags reason=modal_<state>" test_d_daemon_audit_reason
smoke_run "E: bridge-status.py surfaces wake_reason (--json + human block)" test_e_status_surfaces

smoke_log "all #1181 modal-blocker detection / is_block / snapshot / audit / status-surface checks pass"
exit 0
