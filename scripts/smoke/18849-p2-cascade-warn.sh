#!/usr/bin/env bash
# scripts/smoke/18849-p2-cascade-warn.sh — #18849 Part 2 PR-2.
#
# Cascade to the next AVAILABLE token + warn-on-exhaustion. The rotator
# (bridge-auth.py cmd_rotate) now advances past EVERY unavailable candidate —
# inside a known limit window (#1789 limited_until / quota disabled_until) OR
# carrying a recent hard limit/auth last_check_status — to the next available
# token, refusing (all_tokens_limited) only when the whole ring is exhausted.
# Availability is judged from LIGHT registry signals (an inactive token has no
# live usage %), never a per-candidate usage probe in the rotate loop. The
# all_tokens_limited refusal feeds the daemon's existing #1789 D2 pool-exhausted
# suppression + latched operator notify (covered end-to-end by
# 1789-token-rotate-pool-cooldown); this smoke proves the rotator-side cascade,
# the exhaustion routing, the fail-safe, the no-probe contract, and the wiring.
#
# Footgun #11: no python3 heredoc-stdin / `<<` here-string at a python3 child —
# the registry seeding + envelope reads go through the argv-driven helper.

set -euo pipefail

SMOKE_NAME="18849-p2-cascade-warn"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AUTH_PY="$SMOKE_REPO_ROOT/bridge-auth.py"
DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"
HELPER="$SCRIPT_DIR/18849-p2-cascade-warn-helper.py"
REG="$SMOKE_TMP_ROOT/cascade-registry.json"

seed() { python3 "$HELPER" seed "$REG" "$1"; }
rotate() { python3 "$AUTH_PY" --registry "$REG" rotate --reason smoke-18849-p2 --json; }
field() { python3 "$HELPER" field "$1" "$2"; }

# --- (a) cascade advances past a recent-adverse candidate -------------------
seed cascade_past_adverse
J="$(rotate)"
smoke_assert_eq "rotated" "$(field "$J" status)" \
  "(a) cascade must rotate when an available token exists past an adverse candidate"
smoke_assert_eq "C" "$(field "$J" active_token_id)" \
  "(a) cascade must SKIP the recent auth_failed candidate B and land on C"
[[ -n "$(field "$J" fingerprint)" ]] \
  || smoke_fail "(a) a cascade rotation must still carry the rotated envelope the --sync/global-sync fanout consumes"
smoke_log "(a) ok: cascade skips a recent auth_failed candidate -> next available"

# read-only quota_limited check (enabled — `check` ran WITHOUT --disable-on-quota)
seed cascade_past_quota_check
J="$(rotate)"
smoke_assert_eq "C" "$(field "$J" active_token_id)" \
  "(a) cascade must skip a recent read-only quota_limited candidate -> next available"
smoke_log "(a) ok: cascade skips a recent read-only quota_limited candidate"

# --- (b) all-unavailable -> all_tokens_limited (feeds the latched warn) ------
# Mixed signals: one adverse-check + one window-limited alternate. The refusal
# carries the soonest WINDOW reset so the daemon can time its suppression.
seed exhausted_mixed
J="$(rotate)"
smoke_assert_eq "skipped" "$(field "$J" status)" \
  "(b) a fully-unavailable pool must refuse, not rotate"
smoke_assert_eq "all_tokens_limited" "$(field "$J" reason)" \
  "(b) exhaustion must route to all_tokens_limited (the daemon's latched warn input)"
smoke_assert_eq "A" "$(field "$J" active_token_id)" \
  "(b) an exhausted refusal must NOT mutate the active token"
[[ -n "$(field "$J" soonest_reset)" ]] \
  || smoke_fail "(b) a window-limited exhaustion must carry soonest_reset for the suppression cooldown"
smoke_log "(b) ok: mixed exhaustion -> all_tokens_limited + soonest_reset"

# Adverse-ONLY exhaustion (no window): still all_tokens_limited, but EMPTY
# soonest_reset, so the daemon falls back to its short floor cooldown. The warn
# still latches once per episode (no thrash) — bridge_note_claude_pool_exhausted
# floors a garbled/empty reset (proven in 1789-token-rotate-pool-cooldown G7).
seed exhausted_adverse_only
J="$(rotate)"
smoke_assert_eq "all_tokens_limited" "$(field "$J" reason)" \
  "(b) an adverse-only exhausted pool must also route to all_tokens_limited"
smoke_assert_eq "" "$(field "$J" soonest_reset)" \
  "(b) an adverse-only exhaustion carries no window reset (empty soonest_reset -> daemon floor)"
smoke_log "(b) ok: adverse-only exhaustion -> all_tokens_limited + empty soonest_reset"

# --- no rotation thrash: repeated passes on an exhausted pool stay put -------
for _pass in $(seq 1 5); do
  J="$(rotate)"
  smoke_assert_eq "all_tokens_limited" "$(field "$J" reason)" \
    "(b) repeated rotate on an exhausted pool must keep refusing (no thrash)"
  smoke_assert_eq "A" "$(field "$J" active_token_id)" \
    "(b) repeated refusals must never cycle the active token"
done
smoke_log "(b) ok: 5 passes on an exhausted pool -> 0 active-token mutations (no thrash)"

# --- fail-safe: a STALE adverse check never strands the pool -----------------
seed stale_adverse_available
J="$(rotate)"
smoke_assert_eq "rotated" "$(field "$J" status)" \
  "(fail-safe) a stale adverse check must NOT strand the candidate"
smoke_assert_eq "B" "$(field "$J" active_token_id)" \
  "(fail-safe) a stale auth_failed check is treated as available-but-unverified -> rotate into B"
smoke_log "(fail-safe) ok: stale adverse check => available, pool not stranded"

# fail-safe: a FUTURE-dated adverse check (clock skew / hand-edit) has a NEGATIVE
# age and must fail OPEN, not strand B until "future + window".
seed future_adverse_available
J="$(rotate)"
smoke_assert_eq "rotated" "$(field "$J" status)" \
  "(fail-safe) a future-dated adverse check must NOT strand the candidate"
smoke_assert_eq "B" "$(field "$J" active_token_id)" \
  "(fail-safe) a future-dated auth_failed stamp (negative age) is untrusted -> available -> rotate into B"
smoke_log "(fail-safe) ok: future-dated adverse stamp => available (negative age fails open)"

# --- (d) availability is judged from registry signals, NOT a hot-loop probe -
# The token-check binary is a recorder shim; a cascade rotation must NEVER fork
# it (a per-candidate usage probe in the rotate loop is the anti-pattern this
# guards against). bridge-auth.py reads `claude` via BRIDGE_CLAUDE_TOKEN_CHECK_BIN.
PROBE_SENTINEL="$SMOKE_TMP_ROOT/probe-invoked"
PROBE_BIN="$SMOKE_TMP_ROOT/recorder-claude"
cat >"$PROBE_BIN" <<EOF
#!/usr/bin/env bash
echo "probe-fired" >>"$PROBE_SENTINEL"
exit 0
EOF
chmod +x "$PROBE_BIN"
rm -f "$PROBE_SENTINEL"
seed no_probe
J="$(BRIDGE_CLAUDE_TOKEN_CHECK_BIN="$PROBE_BIN" rotate)"
smoke_assert_eq "rotated" "$(field "$J" status)" \
  "(d) a clean pool must rotate"
[[ ! -e "$PROBE_SENTINEL" ]] \
  || smoke_fail "(d) cascade selection forked a per-candidate usage probe — availability MUST come from registry signals only"
smoke_log "(d) ok: cascade judged availability from registry signals, never a hot-loop probe"

# --- wiring guards (source-level refactor tripwires) ------------------------
grep -q 'rotation_candidate_availability' "$AUTH_PY" \
  || smoke_fail "S1: cmd_rotate no longer selects via rotation_candidate_availability (cascade dropped)"
grep -q 'ROTATION_ADVERSE_CHECK_STATUSES' "$AUTH_PY" \
  || smoke_fail "S2: the adverse-check availability signal set is gone"
# The daemon must still route all_tokens_limited to the LATCHED operator warn +
# the #1789 D2 suppression (the warn-on-exhaustion plumbing this PR reuses).
grep -q 'skipped:all_tokens_limited)' "$DAEMON_SH" \
  || smoke_fail "S3: the daemon no longer handles the all_tokens_limited exhaustion outcome"
grep -q 'bridge_note_claude_pool_exhausted "\$rotation_soonest_reset"' "$DAEMON_SH" \
  || smoke_fail "S4: the daemon no longer records the pool-exhausted suppression window on exhaustion"
grep -q 'claude_pool_exhausted_notice' "$DAEMON_SH" \
  || smoke_fail "S5: the daemon no longer latches the operator pool-exhausted notification"

smoke_log "PASS"
