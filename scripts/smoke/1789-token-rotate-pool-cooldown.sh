#!/usr/bin/env bash
# scripts/smoke/1789-token-rotate-pool-cooldown.sh
#
# Issue #1789 (D2 — pool-level cooldown). PR #1790 already taught the rotator
# (bridge-auth.py) to SKIP a target token still inside its own 429 window and
# to return `skipped/all_tokens_limited` when every enabled token is saturated,
# and the daemon to coalesce the operator NOTIFICATION onto a cooldown latch.
# What that left unaddressed: the daemon's process_usage_monitor still FORKED
# the full `claude-token rotate --sync --agents …` subprocess on EVERY 300s
# monitor pass while the pool was saturated — the rotator just refused each
# time, but each refusal still cost a registry lock + per-agent sync fanout.
# That is the across-pass thrash (#1789 field data: 223 rotate events / 5 days,
# min inter-rotation gap 6 min ≈ one per monitor pass).
#
# This fix records the soonest token-reset after an `all_tokens_limited` result
# and SUPPRESSES the rotate attempt entirely on subsequent passes until a
# window actually clears. This smoke proves the suppression gate and that the
# usage-monitor loop is wired to it.
#
# It SOURCES bridge-daemon.sh (the #1679-style in-process seam: BASH_SOURCE !=
# $0 ⇒ no verb dispatch) so the new gate helpers run IN THIS SHELL against an
# isolated BRIDGE_HOME — never a live daemon, never live ~/.agent-bridge.
#
# Coverage:
#   G1 fresh state: no recorded window ⇒ NOT suppressed (rotate attempts).
#   G2 record + suppress: after note(all_tokens_limited, future reset) the gate
#      SUPPRESSES until the window; the state file carries the reset epoch.
#   G3 settle/non-vacuous: across many simulated passes the rotate attempt is
#      taken exactly ONCE (the all_tokens_limited pass), then suppressed — i.e.
#      the round-robin-thrash settles instead of firing every pass.
#   G4 expired window self-heals: a past `until` ⇒ NOT suppressed + the stale
#      stamp is removed (re-arms the rotate attempt once a window clears).
#   G5 clear re-arms: clear() drops the window ⇒ NOT suppressed.
#   G6 fail-open: a corrupt/garbled stamp degrades to NOT suppressed (a bad
#      stamp can never permanently strand rotation) and is removed.
#   G7 garbled reset floor: note() with an unparseable reset still records a
#      bounded floor window (never permanent), never strands the pool.
#   G8 max clamp: an absurd far-future reset is clamped to the max cap.
#   Wiring guards: process_usage_monitor consults the gate BEFORE the rotate
#      fork, records on all_tokens_limited, and clears on rotated / error.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3 child.

set -euo pipefail

SMOKE_NAME="1789-token-rotate-pool-cooldown"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# Source the daemon's functions into THIS shell (verb dispatch is gated on
# BASH_SOURCE == $0, false here). Brings in bridge_claude_pool_rotate_suppressed,
# bridge_note_claude_pool_exhausted, bridge_clear_claude_pool_exhausted,
# bridge_claude_pool_exhausted_state_file, bridge_claude_iso_to_epoch, and the
# daemon_source_state_file / daemon_warn helpers they depend on.
# shellcheck source=bridge-daemon.sh
source "$SMOKE_REPO_ROOT/bridge-daemon.sh"

STATE_FILE="$(bridge_claude_pool_exhausted_state_file)"
mkdir -p "$(dirname "$STATE_FILE")"

iso_in() {
  # ISO-8601 UTC stamp N seconds from now (portable GNU/BSD).
  local delta="$1"
  python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S+00:00"))' "$delta"
}

# --- G1: fresh state — nothing recorded ⇒ rotate attempts -------------------
rm -f "$STATE_FILE"
if bridge_claude_pool_rotate_suppressed; then
  smoke_fail "G1: a fresh install with no recorded window must NOT suppress the rotate attempt"
fi
smoke_log "G1 ok: no recorded window ⇒ not suppressed"

# --- G2: record a future window ⇒ suppressed --------------------------------
FUTURE_ISO="$(iso_in 1800)"   # 30 min out, inside the [60s, 6h] clamp
bridge_note_claude_pool_exhausted "$FUTURE_ISO"
smoke_assert_file_exists "$STATE_FILE" "G2: note() must persist the pool-exhausted window"
if ! bridge_claude_pool_rotate_suppressed; then
  smoke_fail "G2: an unexpired recorded window must SUPPRESS the rotate attempt"
fi
# The persisted UNTIL must equal the parsed reset epoch (within the clamp).
EXPECT_EPOCH="$(bridge_claude_iso_to_epoch "$FUTURE_ISO")"
# shellcheck disable=SC1090
source "$STATE_FILE"
smoke_assert_eq "$EXPECT_EPOCH" "${CLAUDE_POOL_EXHAUSTED_UNTIL_TS:-}" \
  "G2: the suppress-until epoch must equal the 429-derived reset"
smoke_log "G2 ok: future window recorded ⇒ suppressed until reset"

# --- G3: across-pass settle (the non-vacuous thrash proof) ------------------
# Simulate the daemon's per-pass decision: on each pass we ask the gate whether
# to attempt a rotate. The FIRST pass (cold) attempts and reports
# all_tokens_limited (records the window); the remaining passes must all be
# suppressed. A rotator that re-attempts every pass (the pre-fix thrash) would
# increment the counter on every pass.
rm -f "$STATE_FILE"
ATTEMPTS=0
SOONEST="$(iso_in 1800)"
for _pass in $(seq 1 12); do
  if bridge_claude_pool_rotate_suppressed; then
    continue
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  # The (stubbed) rotate refused: whole pool saturated this pass.
  bridge_note_claude_pool_exhausted "$SOONEST"
done
smoke_assert_eq "1" "$ATTEMPTS" \
  "G3: a saturated pool must be probed exactly ONCE then suppressed across passes (thrash settles)"
smoke_log "G3 ok: 12 passes ⇒ 1 rotate attempt (round-robin-thrash settled)"

# --- G4: expired window self-heals ------------------------------------------
rm -f "$STATE_FILE"
NOW_EPOCH="$(date +%s)"
PAST_EPOCH=$((NOW_EPOCH - 5))
cat >"$STATE_FILE" <<EOF
CLAUDE_POOL_EXHAUSTED_TS=$((NOW_EPOCH - 3600))
CLAUDE_POOL_EXHAUSTED_UNTIL_TS=$PAST_EPOCH
EOF
if bridge_claude_pool_rotate_suppressed; then
  smoke_fail "G4: an expired window must NOT suppress (the reset has elapsed)"
fi
[[ -e "$STATE_FILE" ]] \
  && smoke_fail "G4: an expired window stamp must be removed so the gate self-heals"
smoke_log "G4 ok: expired window ⇒ not suppressed + stamp removed"

# --- G5: clear() re-arms ----------------------------------------------------
bridge_note_claude_pool_exhausted "$(iso_in 1800)"
bridge_claude_pool_rotate_suppressed || smoke_fail "G5 precondition: window should suppress"
bridge_clear_claude_pool_exhausted
[[ -e "$STATE_FILE" ]] && smoke_fail "G5: clear() must remove the window file"
if bridge_claude_pool_rotate_suppressed; then
  smoke_fail "G5: after clear() the gate must NOT suppress (rotate re-armed)"
fi
smoke_log "G5 ok: clear() re-arms the rotate attempt"

# --- G6: fail-open on a corrupt stamp ---------------------------------------
rm -f "$STATE_FILE"
cat >"$STATE_FILE" <<'EOF'
CLAUDE_POOL_EXHAUSTED_UNTIL_TS=not-a-number
EOF
if bridge_claude_pool_rotate_suppressed; then
  smoke_fail "G6: a corrupt UNTIL stamp must FAIL-OPEN (not suppress) — a bad stamp cannot strand rotation"
fi
[[ -e "$STATE_FILE" ]] \
  && smoke_fail "G6: a corrupt stamp must be removed so it self-heals"
smoke_log "G6 ok: corrupt stamp ⇒ fail-open + removed"

# --- G6b: numeric-but-ABSURD persisted window self-heals on the READ path ---
# The writer clamps its inputs, but a corrupt-but-syntactically-valid state
# file (partial flush, clock skew, hand-edit) like UNTIL_TS=9999999999 would
# suppress rotation for centuries if the reader trusted any numeric value. The
# reader is the self-heal boundary: a window beyond now+max_cap is corrupt ⇒
# NOT suppressed + removed. (codex review #1789 — defense-in-depth.)
rm -f "$STATE_FILE"
NOW_EPOCH="$(date +%s)"
ABSURD_TS=$((NOW_EPOCH + 21600 + 100000))   # well past the 6h max cap
cat >"$STATE_FILE" <<EOF
CLAUDE_POOL_EXHAUSTED_TS=$NOW_EPOCH
CLAUDE_POOL_EXHAUSTED_UNTIL_TS=$ABSURD_TS
EOF
if bridge_claude_pool_rotate_suppressed; then
  smoke_fail "G6b: a numeric-but-absurd persisted window (> now+max_cap) must NOT suppress — the reader is the corruption self-heal boundary"
fi
[[ -e "$STATE_FILE" ]] \
  && smoke_fail "G6b: an absurd persisted window must be removed so the gate re-arms"
smoke_log "G6b ok: numeric-but-absurd persisted window ⇒ read-path self-heal"

# --- G7: garbled reset still records a BOUNDED floor (never permanent) ------
rm -f "$STATE_FILE"
bridge_note_claude_pool_exhausted "totally-not-a-timestamp"
smoke_assert_file_exists "$STATE_FILE" "G7: note() with a garbled reset still records a floor window"
# shellcheck disable=SC1090
source "$STATE_FILE"
NOW_EPOCH="$(date +%s)"
# Floor default is 60s; assert the window is in the future but bounded (<= now
# + max cap 21600). This proves a missing/garbled reset can never produce a
# permanent (or absurd) suppression.
[[ "${CLAUDE_POOL_EXHAUSTED_UNTIL_TS:-0}" =~ ^[0-9]+$ ]] \
  || smoke_fail "G7: floor window UNTIL must be numeric"
(( CLAUDE_POOL_EXHAUSTED_UNTIL_TS > NOW_EPOCH )) \
  || smoke_fail "G7: floor window must be in the future"
(( CLAUDE_POOL_EXHAUSTED_UNTIL_TS <= NOW_EPOCH + 21600 + 5 )) \
  || smoke_fail "G7: floor window must be bounded by the max cap (no permanent suppression)"
smoke_log "G7 ok: garbled reset ⇒ bounded floor window"

# --- G8: absurd far-future reset is clamped to the max cap ------------------
rm -f "$STATE_FILE"
bridge_note_claude_pool_exhausted "$(iso_in 999999999)"   # ~31 years out
# shellcheck disable=SC1090
source "$STATE_FILE"
NOW_EPOCH="$(date +%s)"
(( CLAUDE_POOL_EXHAUSTED_UNTIL_TS <= NOW_EPOCH + 21600 + 5 )) \
  || smoke_fail "G8: an absurd reset must be clamped to the max cap, never disable rotation indefinitely"
smoke_log "G8 ok: far-future reset clamped to max cap"

# --- Wiring guards (source-level; refactor tripwires) -----------------------
DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
# The rotate fork must be GATED on the suppression check.
grep -q 'if bridge_claude_pool_rotate_suppressed; then' "$DAEMON_SRC" \
  || smoke_fail "S1: process_usage_monitor no longer gates the rotate attempt on the pool-exhausted check"
# all_tokens_limited must RECORD the window.
grep -q 'bridge_note_claude_pool_exhausted "\$rotation_soonest_reset"' "$DAEMON_SRC" \
  || smoke_fail "S2: the all_tokens_limited branch no longer records the pool-exhausted window"
# A successful rotate must CLEAR the window so the gate re-arms.
grep -q 'bridge_clear_claude_pool_exhausted' "$DAEMON_SRC" \
  || smoke_fail "S3: no rotation outcome clears the pool-exhausted window (gate would never re-arm)"

# Ordering guard: the suppression gate must appear BEFORE the rotate fork in
# process_usage_monitor (a refactor that moves the fork above the gate re-opens
# the thrash). Compare line numbers of the two anchors.
GATE_LINE="$(grep -n 'if bridge_claude_pool_rotate_suppressed; then' "$DAEMON_SRC" | head -n1 | cut -d: -f1)"
FORK_LINE="$(grep -n 'claude-token rotate \\' "$DAEMON_SRC" | head -n1 | cut -d: -f1)"
[[ -n "$GATE_LINE" && -n "$FORK_LINE" ]] \
  || smoke_fail "S4: could not locate the gate / rotate-fork anchors"
(( GATE_LINE < FORK_LINE )) \
  || smoke_fail "S4: the suppression gate (line $GATE_LINE) must precede the rotate fork (line $FORK_LINE)"

smoke_log "PASS"
