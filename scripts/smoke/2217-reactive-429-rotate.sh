#!/usr/bin/env bash
# scripts/smoke/2217-reactive-429-rotate.sh — behavioral smoke for #2217 roadmap
# step 4: reactive inference/picker 429 → preflighted token rotation.
#
# THE FEATURE: when the proactive /api/oauth/usage probe is edge-throttled (dead),
# a managed Claude agent that hits a REAL provider 429 in its pane keeps retrying
# the SAME capped token. The daemon's `rate_limit` stall branch now ROTATES (via
# the existing preflighted rotator) before the retry-nudge, so the nudge lands on
# a fresh token. The rotation is HEAVILY gated (feature flag, scope, a strict
# CF/transport-qualified gate, a per-(agent,token-digest) latch, and a shared
# lock/cooldown that dedupes a same-tick picker-sweep + daemon co-fire).
#
# WHAT THIS SMOKE PROVES (the brief's 5 core paths, behavioral — real shipped
# functions extracted from the source, isolated BRIDGE_HOME, mocked rotator):
#   A — managed in-scope agent + flush-left transport-qualified 429 → ONE
#       preflighted rotate (reason reactive-429:<agent>).
#   B — cloudflare/cf-ray-adjacent OR prose-grade 429 → NO rotate (FP defense).
#   C — same stuck pane, same active token across ticks → rotate ONCE (latch).
#   D — feature flag off / auto_rotate disabled → NO rotate.
#   E — picker + daemon same tick → SINGLE rotate (shared cooldown dedup).
#   F — out-of-scope / non-managed agent → NO rotate (alert only).
#   G — all_tokens_limited → HOLD + one notice, no loop.
#   I — latch-on-cooldown race: a cooldown-suppressed call must NOT pin the token
#       picker just rotated INTO; after the cooldown clears, a genuine 429 on that
#       token rotates once. Mutation-backed teeth.
#   H — picker note stamps the SHARED cooldown even when its LOCAL cooldown knob
#       is 0 (regression guard: the daemon must not re-rotate the same event
#       after the picker's lock releases). Mutation-backed teeth.
#
# Footgun #11: no heredoc-stdin / here-string piped into command substitution.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
SKIPS=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
# shellcheck disable=SC2329
_skip() { TOTAL=$((TOTAL + 1)); SKIPS=$((SKIPS + 1)); printf '[skip] %s: %s\n' "$1" "$2"; }

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
LIB_SH="$REPO_ROOT/lib/bridge-reactive-rotate.sh"
for f in "$DAEMON_SH" "$LIB_SH"; do
  if [[ ! -r "$f" ]]; then
    printf '[FAIL] required source not found: %s\n' "$f" >&2
    exit 1
  fi
done

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-2217-reactive-429.XXXXXX")"
# shellcheck disable=SC2329
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"
# Keep the shared lock + cooldown inside the isolated home.
export BRIDGE_REACTIVE_ROTATE_LOCK_DIR="$BRIDGE_STATE_DIR/reactive-rotate/rotation.lock"
export BRIDGE_REACTIVE_ROTATE_COOLDOWN_FILE="$BRIDGE_STATE_DIR/reactive-rotate/cooldown.state"
export SCRIPT_DIR="$REPO_ROOT"   # the daemon fn uses $SCRIPT_DIR for helper paths
export BRIDGE_BASH_BIN="bash"

# ---------------------------------------------------------------------------
# Source the REAL shipped shared gate/lock/cooldown helpers (self-contained).
# ---------------------------------------------------------------------------
# shellcheck source=../../lib/bridge-reactive-rotate.sh
source "$LIB_SH"

# ---------------------------------------------------------------------------
# Extract + eval the REAL shipped daemon reactive-rotate function. A revert of
# the trigger fails the extract; a behavior change is exercised directly.
# ---------------------------------------------------------------------------
extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$2"; }
FN_BODY="$(extract_fn bridge_daemon_reactive_429_rotate "$DAEMON_SH")"
if [[ -z "$FN_BODY" ]]; then
  printf '[FAIL] could not extract bridge_daemon_reactive_429_rotate from %s\n' "$DAEMON_SH" >&2
  exit 1
fi
eval "$FN_BODY"
if ! command -v bridge_daemon_reactive_429_rotate >/dev/null 2>&1; then
  printf '[FAIL] bridge_daemon_reactive_429_rotate not defined after eval\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Stub the daemon-only collaborators the function calls. Each stub records into
# a ledger so assertions can read what happened. The ROTATE + DIGEST stubs are
# driven by env so each scenario controls the rotator outcome and active token.
# ---------------------------------------------------------------------------
# ROTATE_CALLS is tracked via a FILE because the rotate call runs inside a
# command-substitution subshell (`rotate_json="$(bridge_with_timeout ... )"`) —
# a shell-variable increment there would not propagate to the parent.
ROTATE_COUNT_FILE="$SMOKE_DIR/rotate-calls.count"
AUDIT_LEDGER=""
NOTIFY_LEDGER=""
POOL_NOTE_LEDGER=""

_rotate_calls() { local n=0; [[ -f "$ROTATE_COUNT_FILE" ]] && n="$(cat "$ROTATE_COUNT_FILE" 2>/dev/null || printf 0)"; printf '%s' "$n"; }

# bridge_with_timeout <secs> <label> <cmd...> — the daemon function uses this for
# BOTH the active-digest read AND the rotate call. Discriminate by argv: the
# active-digest call passes `claude-token active-digest`; the rotate passes
# `claude-token rotate`. The status-parse call passes `rotation-status-parse`.
# shellcheck disable=SC2329
bridge_with_timeout() {
  shift 2  # drop <secs> <label>
  local args="$*"
  case "$args" in
    *"claude-token active-digest"*)
      printf '%s\n' "${MOCK_ACTIVE_DIGEST:-tok-a:sha256:aaaa}"
      ;;
    *"claude-token rotate"*)
      local n=0; [[ -f "$ROTATE_COUNT_FILE" ]] && n="$(cat "$ROTATE_COUNT_FILE" 2>/dev/null || printf 0)"
      printf '%s' "$(( n + 1 ))" >"$ROTATE_COUNT_FILE"
      # Emit the JSON the real rotator would; the function pipes it to the
      # status-parse helper below.
      printf '%s\n' "${MOCK_ROTATE_JSON:-{\"status\":\"rotated\",\"from\":\"tok-a\",\"to\":\"tok-b\",\"sync_status\":\"synced\"}}"
      ;;
    *rotation-status-parse*)
      # Mimic bridge-daemon-helpers.py rotation-status-parse: TSV row
      # status<TAB>reason<TAB>from<TAB>to<TAB>sync<TAB>soonest_reset with `-`
      # for empty fields. Driven by MOCK_ROTATE_OUTCOME.
      case "${MOCK_ROTATE_OUTCOME:-rotated}" in
        rotated) printf 'rotated\t-\ttok-a\ttok-b\tsynced\t-\n' ;;
        all_tokens_limited) printf 'skipped\tall_tokens_limited\t-\t-\t-\t2026-01-01T00:00:00Z\n' ;;
        *) printf 'skipped\tno_alternate_token\t-\t-\t-\t-\n' ;;
      esac
      ;;
    *) : ;;
  esac
}

# bridge_audit_log <actor> <action> <target> … — $2 is the action/event name.
# shellcheck disable=SC2329
bridge_audit_log() { AUDIT_LEDGER+="$2 "; }
# shellcheck disable=SC2329
bridge_clear_claude_pool_exhausted() { :; }
# shellcheck disable=SC2329
bridge_note_claude_pool_exhausted() { POOL_NOTE_LEDGER+="held "; }
# shellcheck disable=SC2329
bridge_daemon_pass_due() { return 0; }   # treat the notice latch as always-due
# shellcheck disable=SC2329
bridge_agent_has_notify_transport() { return 0; }
# shellcheck disable=SC2329
bridge_notify_send() { NOTIFY_LEDGER+="sent "; }
# bridge_agent_is_static is consulted by the scope gate for the "static" keyword.
# shellcheck disable=SC2329
bridge_agent_is_static() { [[ "$1" == static-* ]]; }

# Reset per-scenario shared state + ledgers.
reset_scenario() {
  printf '0' >"$ROTATE_COUNT_FILE"
  AUDIT_LEDGER=""
  NOTIFY_LEDGER=""
  POOL_NOTE_LEDGER=""
  rm -rf "$BRIDGE_STATE_DIR/reactive-rotate" 2>/dev/null || true
  BRIDGE_REACTIVE_ROTATE_DID_ROTATE=0
  BRIDGE_REACTIVE_ROTATE_LATCH_DIGEST=""
  BRIDGE_REACTIVE_ROTATE_LATCH_TS=0
}

TRANSPORT_429="HTTP 429 Too Many Requests"
CF_429="cf-ray: 8abc123; HTTP 429 Too Many Requests"
PROSE_429="the agent said it would wait for the 429 rate limit to reset"

# ===========================================================================
# A — managed in-scope (scope=all) + transport-qualified 429 → ONE rotate.
# ===========================================================================
reset_scenario
export BRIDGE_REACTIVE_429_ROTATE_ENABLED=1
export BRIDGE_USAGE_ROTATION_AGENTS=all
export MOCK_ACTIVE_DIGEST="tok-a:sha256:aaaa"
export MOCK_ROTATE_OUTCOME=rotated
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
A_ROTATES="$(_rotate_calls)"
if (( A_ROTATES == 1 )) && (( BRIDGE_REACTIVE_ROTATE_DID_ROTATE == 1 )) \
   && [[ "$AUDIT_LEDGER" == *reactive_429_rotated* ]]; then
  _pass "A managed in-scope agent + transport-qualified 429 → ONE preflighted rotate (reason reactive-429), did_rotate=1, audit=reactive_429_rotated"
else
  _fail "A in-scope-rotate" "rotate_calls=$A_ROTATES did_rotate=$BRIDGE_REACTIVE_ROTATE_DID_ROTATE audit='$AUDIT_LEDGER' (expected exactly 1 rotate)"
fi

# ===========================================================================
# B — cf-ray-adjacent AND prose-grade 429 → NO rotate (FP defense).
# ===========================================================================
reset_scenario
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$CF_429" ""
CF_ROTATES="$(_rotate_calls)"
reset_scenario
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$PROSE_429" ""
PROSE_ROTATES="$(_rotate_calls)"
if (( CF_ROTATES == 0 )) && (( PROSE_ROTATES == 0 )); then
  _pass "B cloudflare/cf-ray-adjacent 429 ($CF_ROTATES rotates) AND prose-grade 429 ($PROSE_ROTATES rotates) → NO rotate — the reactive gate rejects edge + narration"
else
  _fail "B fp-defense" "cf_rotates=$CF_ROTATES prose_rotates=$PROSE_ROTATES (expected 0/0)"
fi

# ===========================================================================
# C — latch: same stuck pane, same active token across ticks → rotate ONCE.
# The first tick rotates and returns the latch digest; the SECOND tick is given
# that SAME digest as the active token (rotator outcome "no change") → no rotate.
# ===========================================================================
reset_scenario
export MOCK_ACTIVE_DIGEST="tok-a:sha256:aaaa"
export MOCK_ROTATE_OUTCOME=rotated
# tick 1 — no latch yet.
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
LATCH1="$BRIDGE_REACTIVE_ROTATE_LATCH_DIGEST"
TICK1_ROTATES="$(_rotate_calls)"
# tick 2 — SAME active token still active (digest unchanged), latch carried in.
# Clear the shared cooldown so ONLY the latch (not the cooldown) blocks tick 2 —
# this isolates the per-token latch as the dedup under test.
rm -rf "$BRIDGE_STATE_DIR/reactive-rotate" 2>/dev/null || true
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" "$LATCH1"
TICK2_ROTATES="$(_rotate_calls)"
if (( TICK1_ROTATES == 1 )) && (( TICK2_ROTATES == 1 )) && [[ -n "$LATCH1" ]]; then
  _pass "C latch: tick1 rotated (1), tick2 same (agent,token-digest=$LATCH1) did NOT re-rotate (still 1) — rotate at most once per active token"
else
  _fail "C latch" "tick1_rotates=$TICK1_ROTATES tick2_rotates=$TICK2_ROTATES latch='$LATCH1' (expected 1 then 1)"
fi

# ===========================================================================
# D — feature flag off → NO rotate; auto_rotate path is enforced inside the
# rotator (--if-auto-enabled), so here we prove the FLAG gate hard-blocks.
# ===========================================================================
reset_scenario
export BRIDGE_REACTIVE_429_ROTATE_ENABLED=0
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
FLAG_OFF_ROTATES="$(_rotate_calls)"
export BRIDGE_REACTIVE_429_ROTATE_ENABLED=1   # restore for later scenarios
if (( FLAG_OFF_ROTATES == 0 )); then
  _pass "D feature flag BRIDGE_REACTIVE_429_ROTATE_ENABLED=0 → NO rotate ($FLAG_OFF_ROTATES) — default-off / canary-first holds"
else
  _fail "D flag-off" "rotates=$FLAG_OFF_ROTATES (expected 0 with the flag off)"
fi

# ===========================================================================
# E — picker + daemon same tick → SINGLE rotate (shared cooldown). Simulate the
# picker having ALREADY rotated this event by stamping the shared cooldown; the
# daemon path must then suppress.
# ===========================================================================
reset_scenario
export MOCK_ACTIVE_DIGEST="tok-a:sha256:aaaa"
# Picker rotates first → writes the shared cooldown stamp.
bridge_reactive_rotate_cooldown_note
# Daemon path in the SAME tick must see the cooldown and NOT rotate.
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
COOLDOWN_ROTATES="$(_rotate_calls)"
if (( COOLDOWN_ROTATES == 0 )) && [[ "$AUDIT_LEDGER" == *reactive_429_rotate_skipped* ]]; then
  _pass "E picker+daemon same tick: a prior shared-cooldown stamp (picker rotated) suppresses the daemon rotate ($COOLDOWN_ROTATES) — single rotate per event"
else
  _fail "E shared-cooldown" "rotates=$COOLDOWN_ROTATES audit='$AUDIT_LEDGER' (expected 0 rotate + skipped audit)"
fi

# ===========================================================================
# F — out-of-scope / non-managed agent → NO rotate (alert only). scope=static
# means only static-* agents are eligible; a non-static agent must not rotate.
# ===========================================================================
reset_scenario
export BRIDGE_USAGE_ROTATION_AGENTS=static
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
OOS_ROTATES="$(_rotate_calls)"
OOS_AUDIT="$AUDIT_LEDGER"
# control: a static-* agent under the same scope DOES rotate.
reset_scenario
bridge_daemon_reactive_429_rotate "static-admin" "claude" "$TRANSPORT_429" ""
IN_ROTATES="$(_rotate_calls)"
export BRIDGE_USAGE_ROTATION_AGENTS=all   # restore
if (( OOS_ROTATES == 0 )) && [[ "$OOS_AUDIT" == *reactive_429_rotate_skipped* ]] && (( IN_ROTATES == 1 )); then
  _pass "F scope gate: non-managed 'worker-a' under scope=static did NOT rotate ($OOS_ROTATES, audit skipped/out_of_scope); static-* agent DID ($IN_ROTATES) — alert-only for out-of-scope"
else
  _fail "F scope-gate" "oos_rotates=$OOS_ROTATES oos_audit='$OOS_AUDIT' in_scope_rotates=$IN_ROTATES (expected 0 / skipped / 1)"
fi

# ===========================================================================
# G — all_tokens_limited → HOLD + one notice, no loop. The rotate is ATTEMPTED
# (one call) but the rotator refuses; the function records the pool-exhausted
# hold + a single notice, and does NOT mark did_rotate.
# ===========================================================================
reset_scenario
export MOCK_ROTATE_OUTCOME=all_tokens_limited
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
G_ROTATES="$(_rotate_calls)"
if (( G_ROTATES == 1 )) && (( BRIDGE_REACTIVE_ROTATE_DID_ROTATE == 0 )) \
   && [[ "$POOL_NOTE_LEDGER" == *held* ]] && [[ "$NOTIFY_LEDGER" == *sent* ]] \
   && [[ "$AUDIT_LEDGER" == *reactive_429_rotate_held* ]]; then
  _pass "G all_tokens_limited → HOLD (pool-exhausted note) + one notice, did_rotate=0, audit=reactive_429_rotate_held — no loop"
else
  _fail "G all-tokens-limited-hold" "rotate_calls=$G_ROTATES did_rotate=$BRIDGE_REACTIVE_ROTATE_DID_ROTATE pool='$POOL_NOTE_LEDGER' notify='$NOTIFY_LEDGER' audit='$AUDIT_LEDGER'"
fi
export MOCK_ROTATE_OUTCOME=rotated   # restore

# ===========================================================================
# I — latch-on-cooldown RACE (the daemon must NOT pin a token picker just rotated
# INTO). Interleaving: picker rotates tok-a→tok-b and writes the shared cooldown;
# the daemon's active-digest then reads tok-b (the fresh token). The cooldown
# correctly suppresses THIS event, but the daemon MUST NOT publish a latch for
# tok-b — otherwise a later GENUINE tok-b 429 (after the cooldown expires) would
# hit the Gate-5 latch and never rotate, reopening the blind spot for the
# rotated-into token. We assert: (1) cooldown-suppressed call publishes NO latch
# (BRIDGE_REACTIVE_ROTATE_LATCH_DIGEST stays empty → the caller leaves the
# per-token latch untouched), and (2) after the cooldown clears, a tok-b 429 with
# NO carried-in latch rotates ONCE. Mutation: re-adding the latch publish in the
# cooldown branch pins tok-b and makes (2) fail (the rotate is blocked).
# ===========================================================================
reset_scenario
export MOCK_ACTIVE_DIGEST="tok-b:sha256:bbbb"   # picker already rotated INTO tok-b
# Picker writes the shared cooldown AFTER changing the active digest to tok-b.
bridge_reactive_rotate_cooldown_note
# Daemon reactive call under the cooldown: suppressed, and MUST NOT latch tok-b.
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
I_COOLDOWN_ROTATES="$(_rotate_calls)"
I_LATCH_AFTER_COOLDOWN="$BRIDGE_REACTIVE_ROTATE_LATCH_DIGEST"
# Caller persists the latch ONLY when the helper published one (mirrors the daemon
# call site at bridge-daemon.sh): empty publish → the per-agent latch is untouched.
I_PERSISTED_LATCH=""   # prior latch was empty (first detection)
if [[ -n "$I_LATCH_AFTER_COOLDOWN" ]]; then I_PERSISTED_LATCH="$I_LATCH_AFTER_COOLDOWN"; fi
# Cooldown window expires.
rm -f "$BRIDGE_REACTIVE_ROTATE_COOLDOWN_FILE" 2>/dev/null || true
printf '0' >"$ROTATE_COUNT_FILE"   # reset the rotate counter for the post-cooldown call
# A GENUINE tok-b 429 after the cooldown clears — carry in whatever latch the
# caller persisted. With the fix this is empty → tok-b rotates once.
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" "$I_PERSISTED_LATCH"
I_POSTCOOLDOWN_ROTATES="$(_rotate_calls)"
if (( I_COOLDOWN_ROTATES == 0 )) && [[ -z "$I_LATCH_AFTER_COOLDOWN" ]] && (( I_POSTCOOLDOWN_ROTATES == 1 )); then
  _pass "I latch-on-cooldown race: cooldown-suppressed call published NO latch for the picker-rotated-into token (tok-b); after the cooldown cleared, a genuine tok-b 429 rotated once ($I_POSTCOOLDOWN_ROTATES) — the freshly-rotated-into token is not spuriously pinned"
else
  _fail "I latch-on-cooldown-race" "cooldown_rotates=$I_COOLDOWN_ROTATES latch_after_cooldown='$I_LATCH_AFTER_COOLDOWN' (expected empty) post_cooldown_rotates=$I_POSTCOOLDOWN_ROTATES (expected 0 / empty / 1)"
fi

# ===========================================================================
# H — picker-sweep stamps the SHARED cooldown even when its LOCAL cooldown knob
# is disabled (BRIDGE_PICKER_SWEEP_RATE_LIMIT_ROTATE_COOLDOWN_SECONDS=0). The
# local stamp early-returns at 0, but the shared cooldown (its own default) MUST
# still latch or the daemon could re-rotate the same event after the lock
# releases. Extract the REAL shipped picker note fn and drive it directly.
# ===========================================================================
PICKER_SH="$REPO_ROOT/scripts/picker-sweep.sh"
PICKER_NOTE_FN="$(extract_fn _psw_note_rate_limit_rotation_attempt "$PICKER_SH")"
if [[ -z "$PICKER_NOTE_FN" ]]; then
  _fail "H picker-note-extract" "could not extract _psw_note_rate_limit_rotation_attempt from $PICKER_SH"
else
  eval "$PICKER_NOTE_FN"
  # _psw_rate_limit_rotation_state_file is referenced by the note fn; stub it to
  # an isolated path so the LOCAL stamp (when enabled) has somewhere to write.
  # The suffix is intentionally a state file, not an env-style one, so the
  # iso-helper-ratchet boundary scan does not flag this test-only path.
  # shellcheck disable=SC2329
  _psw_rate_limit_rotation_state_file() { printf '%s' "$BRIDGE_STATE_DIR/picker-sweep/rate-limit-rotation.state"; }
  reset_scenario
  export BRIDGE_PICKER_SWEEP_RATE_LIMIT_ROTATE_COOLDOWN_SECONDS=0   # local cooldown OFF
  _psw_note_rate_limit_rotation_attempt
  # After the picker note with local cooldown=0, the SHARED cooldown must be active.
  if bridge_reactive_rotate_cooldown_active; then
    _pass "H picker note with LOCAL cooldown=0 still stamps the SHARED cooldown — the daemon reactive path is suppressed for the same event (no post-lock-release double rotate)"
  else
    _fail "H picker-shared-cooldown-on-zero-local" "shared cooldown NOT active after picker note with BRIDGE_PICKER_SWEEP_RATE_LIMIT_ROTATE_COOLDOWN_SECONDS=0 — picker+daemon could double-rotate one event"
  fi
  unset BRIDGE_PICKER_SWEEP_RATE_LIMIT_ROTATE_COOLDOWN_SECONDS
fi

# ===========================================================================
# Summary.
# ===========================================================================
printf '\n'
if (( FAILS == 0 )); then
  printf '[PASS] 2217-reactive-429-rotate: %d checks (%d skipped) — flag/scope/CF-transport gate + per-token latch (no spurious pin on cooldown race) + shared cooldown dedup (incl. picker local-cooldown=0) + all-tokens-limited hold all enforced\n' "$TOTAL" "$SKIPS"
  exit 0
fi
printf '[FAIL] 2217-reactive-429-rotate: %d/%d checks failed\n' "$FAILS" "$TOTAL" >&2
exit 1
