#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1769-restart-trusted-resume.sh — Issue #1769.
#
# `agent restart` of a freshly-started / idle Claude agent launched a
# FRESH session instead of resuming, because the post-kill re-validation
# rejected the re-injected (#981) session id: the #827 live-session
# shortcut needs an ALIVE pid, and after the SIGKILL the pid is dead while
# the only on-disk state is the `sessions/<pid>.json` record (no eligible
# `>0`-byte in-window transcript yet) — so the freshness scan returns rc=1,
# `bridge_normalize_agent_session_id` clears the id, and the relaunch drops
# `--resume`.
#
# Fix (option 2 of the issue's suggested fixes): a short-TTL trusted-resume
# marker. `run_restart`, having just validated the live session it kills,
# writes `state/agents/<a>/resume.trusted` with the snapshotted id; the
# resolver (`resolve-claude-resume-session-id.py`) accepts THAT EXACT id
# once even with a dead pid, then the marker is consumed (decision-site
# resolve) / expires. It never relaxes the gate for any other id.
#
# Test plan (bash helpers + the resolver/launch builder, no live tmux):
#   T1. WITHOUT a trusted marker, a dead-pid + no-transcript candidate is
#       still REJECTED (rc=1). Regression guard for the #827/#820 freshness
#       contract: the marker is additive, not a blanket bypass.
#   T2. WITH a valid trusted marker for that exact id, the resolver ACCEPTS
#       it (rc=0, same id) despite the dead pid + absent transcript.
#   T3. The marker is single-use: after a decision-site resolve consumes it
#       (BRIDGE_RESUME_TRUSTED_CONSUME=1), a second resolve REJECTS (rc=1).
#       Also: an EXPIRED marker (ttl already elapsed) is not honored.
#   T4. End-to-end — the static Claude launch builder emits `--resume <id>`
#       for a continue=1 agent whose only state is the dead-pid session
#       record plus a fresh trusted marker (the operator-visible symptom).
#
# Isolation: temp BRIDGE_HOME (v2 layout) via smoke_setup_bridge_home + a
# fixture HOME for the Claude config tree. Never touches the operator's
# live runtime or real ~/.claude.
#
# Footgun #11 (heredoc_write deadlock class): the fixture writes JSON via
# `python3 ... > "$tmp"` then `cp` into place (the same recipe as the #827
# smoke); no command-substitution feeds a heredoc-stdin into a bridge
# function, no `<<<` here-string into one.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash 3.2.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1769-restart-trusted-resume] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1769-restart-trusted-resume"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1769-restart-trusted-resume"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

for fn in \
  bridge_resolve_resume_session_id \
  bridge_agent_resume_trusted_marker_write \
  bridge_agent_resume_trusted_marker_write_if_live \
  bridge_agent_resume_trusted_marker_id \
  bridge_agent_resume_trusted_marker_clear \
  bridge_agent_resume_trusted_marker_path \
  bridge_build_static_claude_launch_cmd \
  bridge_reset_roster_maps; do
  if ! declare -F "$fn" >/dev/null; then
    smoke_fail "$fn not defined after sourcing bridge-lib.sh"
  fi
done

# Path to the resolver helper (for direct-probe tests that exercise argv
# ordering precisely, mirroring the codex-r1 quarantine probe).
RESOLVER_PY="$REPO_ROOT/scripts/python-helpers/resolve-claude-resume-session-id.py"
smoke_assert_file_exists "$RESOLVER_PY" "resolver helper present"

# A pid overwhelmingly likely to be unallocated (matches the #827 smoke).
DEAD_PID="999999"

guard_dead_pid_is_dead() {
  if kill -0 "$DEAD_PID" 2>/dev/null; then
    smoke_fail "guard: pid $DEAD_PID happens to be alive on this host; choose a different sentinel"
  fi
}

# Synthesize a fixture HOME with a dead-pid sessions/<pid>.json record and
# NO transcript jsonl — the exact "freshly-started / idle" on-disk shape
# from the issue. Echoes the session id on stdout.
make_fixture_home() {
  local fixture_home="$1"
  local pid="$2"
  local cwd="$3"

  local sid sessions_dir session_file body_tmp
  sid="$("$PY_BIN" -c 'import uuid; print(uuid.uuid4())')"
  sessions_dir="$fixture_home/.claude/sessions"
  mkdir -p "$sessions_dir"
  session_file="$sessions_dir/${pid}.json"

  body_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-1769-body.XXXXXX")"
  PID="$pid" SID="$sid" CWD="$cwd" \
    "$PY_BIN" -c '
import json
import os

print(
    json.dumps(
        {
            "pid": int(os.environ["PID"]),
            "sessionId": os.environ["SID"],
            "cwd": os.environ["CWD"],
            "name": "test",
            "status": "idle",
            "startedAt": 1778722000000,
        }
    )
)
' > "$body_tmp"
  cp "$body_tmp" "$session_file"
  rm -f "$body_tmp"

  printf '%s\n' "$sid"
}

# ---------------------------------------------------------------------------
# T1 — no marker: dead pid + no transcript is still rejected (rc=1).
# ---------------------------------------------------------------------------
test_no_marker_rejects() {
  local fixture_home tmp_cwd sid rc

  fixture_home="$SMOKE_TMP_ROOT/t1-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t1-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  guard_dead_pid_is_dead
  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$tmp_cwd")"

  # Ensure no marker is lying around for this agent name.
  bridge_agent_resume_trusted_marker_clear "agent-t1" 2>/dev/null || true

  set +e
  HOME="$fixture_home" bridge_resolve_resume_session_id claude agent-t1 "$tmp_cwd" "$sid" >/dev/null 2>/dev/null
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T1 resolve rejects dead-pid + no-transcript WITHOUT a trusted marker"
}

# ---------------------------------------------------------------------------
# T2 — valid trusted marker: the exact id is accepted (rc=0, same id).
# ---------------------------------------------------------------------------
test_marker_accepts() {
  local fixture_home tmp_cwd sid resolved rc marker

  fixture_home="$SMOKE_TMP_ROOT/t2-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t2-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  guard_dead_pid_is_dead
  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$tmp_cwd")"

  # run_restart writes the marker after validating the (now-killed) live id.
  bridge_agent_resume_trusted_marker_write "agent-t2" "$sid"
  marker="$(bridge_agent_resume_trusted_marker_path "agent-t2")"
  smoke_assert_file_exists "$marker" "T2 trusted marker written under state dir"

  # Marker mode is 0600 (controller-only). Canonical GNU-first order
  # (#1402): `stat -c '%a'` first — on GNU `stat -f` is FILESYSTEM mode
  # (exits 0 with a multi-line report), so a BSD-first order would never
  # fall through on Linux and the assertion would see a filesystem blob.
  local mode
  mode="$(stat -c '%a' "$marker" 2>/dev/null || stat -f '%Lp' "$marker" 2>/dev/null || true)"
  smoke_assert_eq "600" "$mode" "T2 trusted marker is mode 0600"

  # A non-consume (hydration-probe-style) resolve must accept but NOT burn
  # the marker, so the launch builder can still see it.
  resolved="$(HOME="$fixture_home" bridge_resolve_resume_session_id claude agent-t2 "$tmp_cwd" "$sid" 2>/dev/null)"
  rc=$?
  smoke_assert_eq "0" "$rc" "T2 resolve accepts the trusted id (rc=0)"
  smoke_assert_eq "$sid" "$resolved" "T2 resolve returns the same trusted id"
  smoke_assert_file_exists "$marker" "T2 non-consume resolve leaves the marker intact"

  # Guard: the marker only ever vouches for ITS id. A different candidate is
  # still gated by freshness (rc=1), even with the marker present.
  set +e
  HOME="$fixture_home" bridge_resolve_resume_session_id claude agent-t2 "$tmp_cwd" "some-other-id" >/dev/null 2>/dev/null
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T2 a non-matching candidate is NOT force-accepted by the marker"

  bridge_agent_resume_trusted_marker_clear "agent-t2" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# T3 — single-use: a decision-site consume burns the marker; the next
#      resolve rejects. Plus: an expired marker is not honored.
# ---------------------------------------------------------------------------
test_marker_single_use_and_expiry() {
  local fixture_home tmp_cwd sid resolved rc marker

  fixture_home="$SMOKE_TMP_ROOT/t3-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t3-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  guard_dead_pid_is_dead
  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$tmp_cwd")"

  bridge_agent_resume_trusted_marker_write "agent-t3" "$sid"
  marker="$(bridge_agent_resume_trusted_marker_path "agent-t3")"

  # Decision-site resolve (consume). Mirrors bridge_normalize_agent_session_id.
  resolved="$(HOME="$fixture_home" BRIDGE_RESUME_TRUSTED_CONSUME=1 \
    bridge_resolve_resume_session_id claude agent-t3 "$tmp_cwd" "$sid" 2>/dev/null)"
  rc=$?
  smoke_assert_eq "0" "$rc" "T3 decision-site resolve accepts (rc=0)"
  smoke_assert_eq "$sid" "$resolved" "T3 decision-site resolve returns the id"
  if [[ -f "$marker" ]]; then
    smoke_fail "T3 marker was not consumed by the decision-site resolve: $marker"
  fi

  # Second resolve: marker gone ⇒ back to the freshness gate ⇒ rc=1.
  set +e
  HOME="$fixture_home" bridge_resolve_resume_session_id claude agent-t3 "$tmp_cwd" "$sid" >/dev/null 2>/dev/null
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T3 second resolve after consume rejects (single-use)"

  # Expiry: a marker whose ttl has already elapsed is not honored even
  # before any consume. Write with ttl=0 so now >= started + ttl.
  bridge_agent_resume_trusted_marker_write "agent-t3" "$sid" 0
  smoke_assert_file_exists "$marker" "T3 expired-marker fixture written"
  if bridge_agent_resume_trusted_marker_id "agent-t3" >/dev/null 2>&1; then
    smoke_fail "T3 expired marker (ttl=0) was reported as in-window"
  fi
  set +e
  HOME="$fixture_home" bridge_resolve_resume_session_id claude agent-t3 "$tmp_cwd" "$sid" >/dev/null 2>/dev/null
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T3 expired marker is not honored (rc=1)"
  bridge_agent_resume_trusted_marker_clear "agent-t3" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# T4 — end-to-end: the static Claude launch builder emits `--resume <id>`
#      for a continue=1 agent whose only state is the dead-pid session
#      record + a fresh trusted marker. This is the operator-visible
#      symptom the issue describes ("restart starts over").
# ---------------------------------------------------------------------------
test_launch_builder_emits_resume() {
  local agent fixture_home workdir sid cmd

  agent="agent-t4"
  fixture_home="$SMOKE_TMP_ROOT/t4-home"
  workdir="$SMOKE_TMP_ROOT/t4-cwd"
  mkdir -p "$workdir"
  workdir="$(cd -P "$workdir" && pwd -P)"

  guard_dead_pid_is_dead
  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$workdir")"

  # Register a minimal static Claude agent (mirrors the #981 smoke seed).
  bridge_reset_roster_maps
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_HISTORY_KEY["$agent"]="$(bridge_history_key_for claude "$agent" "$workdir")"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]="$sid"
  BRIDGE_AGENT_LAUNCH_CMD["$agent"]="claude --dangerously-skip-permissions --name $agent"

  # Point the agent's Claude config tree at the fixture so the resolver
  # scans it (the resolver reads CLAUDE_CONFIG_DIR for unregistered/non-iso
  # agents via HOME). The builder runs in-process here, so pinning HOME is
  # what reaches the helper's session-record glob.
  export CLAUDE_CONFIG_DIR="$fixture_home/.claude"

  # run_restart's contract: validate live → snapshot → write marker → kill.
  bridge_agent_resume_trusted_marker_write "$agent" "$sid"

  cmd="$(HOME="$fixture_home" bridge_build_static_claude_launch_cmd "$agent" 2>/dev/null || true)"
  smoke_assert_contains "$cmd" "--resume $sid" \
    "T4 static launch builder emits --resume <id> with the trusted marker"

  # The builder routes through bridge_normalize_agent_session_id (the
  # decision/consume site), so the marker must have been consumed by the
  # real chain — proving the one-shot fires end-to-end, not just that a
  # lingering marker happened to be present.
  local marker
  marker="$(bridge_agent_resume_trusted_marker_path "$agent")"
  if [[ -f "$marker" ]]; then
    smoke_fail "T4 trusted marker was not consumed by the launch builder chain: $marker"
  fi

  unset CLAUDE_CONFIG_DIR
  bridge_agent_resume_trusted_marker_clear "$agent" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# T5 — accept-site (codex-r1 BLOCKING): a QUARANTINED id passed via the
#      trusted path must NOT be force-accepted. The trusted bypass relaxes
#      only the dead-pid/freshness piece, never the #820 quarantine set.
#      Direct resolver probe mirrors the codex repro: argv[5]=exclude_csv
#      contains the sid, argv[7]=trusted_id == sid.
# ---------------------------------------------------------------------------
test_quarantined_trusted_id_rejected() {
  local fixture_home tmp_cwd sid rc out

  fixture_home="$SMOKE_TMP_ROOT/t5-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t5-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  guard_dead_pid_is_dead
  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$tmp_cwd")"

  # Probe: workdir, candidate=sid, max_age=48, agent, exclude_csv=sid (the
  # id is quarantined), config_dir=fixture .claude, trusted_id=sid.
  set +e
  out="$(HOME="$fixture_home" "$PY_BIN" "$RESOLVER_PY" \
    "$tmp_cwd" "$sid" 48 agent-t5 "$sid" "$fixture_home/.claude" "$sid" 2>/dev/null)"
  rc=$?
  set -e
  # The trusted accept must NOT fire for a quarantined id. With no eligible
  # transcript either, the resolver rejects (rc=1, empty). The decisive
  # assertion is that it did NOT print the quarantined sid with rc=0.
  if [[ "$rc" == 0 && "$out" == "$sid" ]]; then
    smoke_fail "T5 trusted path force-accepted a QUARANTINED id (rc=$rc out=$out) — #820 bypass"
  fi
  smoke_assert_eq "1" "$rc" "T5 quarantined id + trusted marker → rejected (rc=1)"

  # Control: the SAME probe WITHOUT quarantine (empty exclude_csv) DOES
  # accept via the trusted path — proving the rejection above is the
  # quarantine guard, not a broken trusted path.
  set +e
  out="$(HOME="$fixture_home" "$PY_BIN" "$RESOLVER_PY" \
    "$tmp_cwd" "$sid" 48 agent-t5 "" "$fixture_home/.claude" "$sid" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T5 control: same id, NOT quarantined, trusted → accepted (rc=0)"
  smoke_assert_eq "$sid" "$out" "T5 control: trusted accept returns the id"
}

# ---------------------------------------------------------------------------
# T6 — write-site (codex-r1 BLOCKING): the marker is written ONLY when the
#      id is the CURRENT live session. bridge_agent_resume_trusted_marker_
#      write_if_live must:
#        (a) write the marker for a LIVE-pid, same-cwd, matching id, and
#        (b) refuse to write for an id ABSENT from the live-session record
#            (e.g. a dead-pid record only), even though it is the persisted
#            session id.
# ---------------------------------------------------------------------------
test_write_if_live_validates() {
  local agent fixture_home workdir live_sid dead_sid marker rc

  agent="agent-t6"
  fixture_home="$SMOKE_TMP_ROOT/t6-home"
  workdir="$SMOKE_TMP_ROOT/t6-cwd"
  mkdir -p "$workdir"
  workdir="$(cd -P "$workdir" && pwd -P)"

  # (a) live record: our own pid is alive, cwd matches.
  if ! kill -0 "$$" 2>/dev/null; then
    smoke_fail "T6 self pid $$ not alive — environment broken"
  fi
  live_sid="$(make_fixture_home "$fixture_home" "$$" "$workdir")"

  bridge_reset_roster_maps
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_HISTORY_KEY["$agent"]="$(bridge_history_key_for claude "$agent" "$workdir")"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]="$live_sid"

  export CLAUDE_CONFIG_DIR="$fixture_home/.claude"
  marker="$(bridge_agent_resume_trusted_marker_path "$agent")"

  set +e
  HOME="$fixture_home" bridge_agent_resume_trusted_marker_write_if_live "$agent" "$live_sid"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T6a write_if_live validates a LIVE id (rc=0)"
  smoke_assert_file_exists "$marker" "T6a marker written for the live session id"
  bridge_agent_resume_trusted_marker_clear "$agent" 2>/dev/null || true

  # (b) an id ABSENT from the live-session record (only a DEAD-pid record
  # carries a *different* id; the persisted id we pass is not live). No
  # marker must be written.
  guard_dead_pid_is_dead
  dead_sid="$("$PY_BIN" -c 'import uuid; print(uuid.uuid4())')"  # never in any record
  set +e
  HOME="$fixture_home" bridge_agent_resume_trusted_marker_write_if_live "$agent" "$dead_sid"
  rc=$?
  set -e
  if [[ "$rc" == 0 ]]; then
    smoke_fail "T6b write_if_live vouched for an id absent from the live-session record (rc=0)"
  fi
  if [[ -f "$marker" ]]; then
    smoke_fail "T6b marker was written for a non-live id: $marker"
  fi

  unset CLAUDE_CONFIG_DIR
  bridge_agent_resume_trusted_marker_clear "$agent" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# T7 — write-site quarantine hole (codex-r2 BLOCKING): a QUARANTINED id that
#      still has a LIVE sessions/<pid>.json must NOT be vouched for. Before
#      this fix the resolver's #827 live-session shortcut accepted a live
#      same-cwd candidate without consulting the quarantine set, so
#      _write_if_live (which trusts the resolver's rc=0) wrote a marker for a
#      quarantined-but-live id. Exercises BOTH defense layers: the resolver's
#      now-quarantine-aware #827 shortcut and the explicit up-front guard.
# ---------------------------------------------------------------------------
test_write_if_live_rejects_quarantined_live() {
  local agent fixture_home workdir live_sid marker rc

  agent="agent-t7"
  fixture_home="$SMOKE_TMP_ROOT/t7-home"
  workdir="$SMOKE_TMP_ROOT/t7-cwd"
  mkdir -p "$workdir"
  workdir="$(cd -P "$workdir" && pwd -P)"

  # Live record: our own pid is alive, cwd matches — the candidate IS the
  # live session (so the only thing that should block it is the quarantine).
  if ! kill -0 "$$" 2>/dev/null; then
    smoke_fail "T7 self pid $$ not alive — environment broken"
  fi
  live_sid="$(make_fixture_home "$fixture_home" "$$" "$workdir")"

  bridge_reset_roster_maps
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_HISTORY_KEY["$agent"]="$(bridge_history_key_for claude "$agent" "$workdir")"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]="$live_sid"

  export CLAUDE_CONFIG_DIR="$fixture_home/.claude"
  marker="$(bridge_agent_resume_trusted_marker_path "$agent")"

  # Control: WITHOUT quarantine the live id IS vouched (proves the rejection
  # below is the quarantine, not a broken live-validation path).
  set +e
  HOME="$fixture_home" bridge_agent_resume_trusted_marker_write_if_live "$agent" "$live_sid"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "T7 control: live, NOT quarantined → vouched (rc=0)"
  smoke_assert_file_exists "$marker" "T7 control: marker written for live non-quarantined id"
  bridge_agent_resume_trusted_marker_clear "$agent" 2>/dev/null || true

  # Now quarantine the SAME (still-live) id and assert the vouch is refused.
  if ! bridge_agent_resume_quarantine_add "$agent" "$live_sid" "smoke-quarantine" 2>/dev/null; then
    smoke_fail "T7 could not quarantine the live id (fixture setup failed)"
  fi
  # Sanity: the id is now in the quarantine set.
  smoke_assert_contains ",$(bridge_agent_resume_quarantine_ids "$agent")," ",$live_sid," \
    "T7 fixture: live id is quarantined"

  set +e
  HOME="$fixture_home" bridge_agent_resume_trusted_marker_write_if_live "$agent" "$live_sid"
  rc=$?
  set -e
  if [[ "$rc" == 0 ]]; then
    smoke_fail "T7 write_if_live vouched for a QUARANTINED live id (rc=0) — codex-r2 hole"
  fi
  if [[ -f "$marker" ]]; then
    smoke_fail "T7 marker was written for a quarantined live id: $marker"
  fi

  unset CLAUDE_CONFIG_DIR
  bridge_agent_resume_trusted_marker_clear "$agent" 2>/dev/null || true
}

smoke_run "T1 no marker → dead-pid + no-transcript rejected"   test_no_marker_rejects
smoke_run "T2 valid marker → trusted id accepted"              test_marker_accepts
smoke_run "T3 single-use + expiry"                             test_marker_single_use_and_expiry
smoke_run "T4 launch builder emits --resume <id>"              test_launch_builder_emits_resume
smoke_run "T5 quarantined id + marker → rejected"              test_quarantined_trusted_id_rejected
smoke_run "T6 write_if_live validates the live session"        test_write_if_live_validates
smoke_run "T7 write_if_live rejects a quarantined LIVE id"     test_write_if_live_rejects_quarantined_live

smoke_log "all checks passed"
