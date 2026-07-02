#!/usr/bin/env bash
# scripts/smoke/2217-rotate-decision-chain.sh — cross-layer INTEGRATION smoke
# for #2217 roadmap step 5: the WHOLE auto-rotate decision chain routes
# correctly across the three layers
#
#   HUD stdin-tap  →  native usage-probe  →  inference/picker reactive-429
#
# This is the END-TO-END companion to scripts/smoke/2217-reactive-429-rotate.sh
# (step 4), which already pins the reactive-429 TRIGGER gate in ISOLATION (raw
# vs CF/prose 429, latch, flag/scope, shared-cooldown dedup, all-tokens HOLD).
# This smoke does NOT re-test those trigger units — its distinct value is the
# LAYER CROSSING: how a decision routes from the tap, through the native probe's
# edge classification, to the reactive backstop. The design contract (codex
# verdict) requires the chain to cover, especially, the **sean-mac failure mode**
#   stale/no tap  +  edge-throttled probe  +  a real inference 429  →  rotation.
#
# SIX mutation-backed scenarios:
#   1  active-tap-fresh → rotate VIA the tap; native probe NOT consulted (the
#      #2214 content-freshness gate short-circuits on a fresh `_written_at`).
#      Mutation: stale `_written_at` → the tap falls through to the probe layer.
#   2 ★stale/no tap + EDGE-BLOCKED probe + inference-picker 429 → rotate (the
#      sean-mac scenario). Both proactive layers are blind (the tap is content-
#      stale, the edge-blocked probe writes NO synthetic cache); the reactive
#      backstop fires precisely there. Mutation: an anthropic-ORIGIN 429 makes
#      the probe a #1468 signal (the proactive path is NOT blind) — proving the
#      backstop is the precise complement of a blind probe.
#   3  raw provider 429 (flush-left `Error: HTTP 429`) → reactive rotate.
#   4  quoted/prose/CF 429 → NO rotate (audit-only). Mutation built in (a raw
#      transport-429 control DOES rotate).
#   5  preflight all_tokens_limited → HOLD (one pool-exhausted notice, no loop).
#   6  concurrent detections (picker + daemon same tick) → rotate ONCE.
#
# The probe + tap layers are driven by the REAL shipped bridge-usage-probe.py /
# bridge-usage.py through scripts/smoke/2217-rotate-decision-chain-helper.py
# (offline; stubbed http_get; mock tokens). The reactive layer extracts + evals
# the REAL shipped bridge_daemon_reactive_429_rotate, exactly as the step-4
# smoke does. No live Claude/Codex engine is launched — the DECISION is asserted.
#
# Footgun #11: no heredoc-stdin / here-string piped into command substitution.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
LIB_SH="$REPO_ROOT/lib/bridge-reactive-rotate.sh"
HELPER="$SCRIPT_DIR/2217-rotate-decision-chain-helper.py"
for f in "$DAEMON_SH" "$LIB_SH" "$HELPER"; do
  if [[ ! -r "$f" ]]; then
    printf '[FAIL] required source not found: %s\n' "$f" >&2
    exit 1
  fi
done

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-2217-chain.XXXXXX")"
# shellcheck disable=SC2329
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"
export BRIDGE_REACTIVE_ROTATE_LOCK_DIR="$BRIDGE_STATE_DIR/reactive-rotate/rotation.lock"
export BRIDGE_REACTIVE_ROTATE_COOLDOWN_FILE="$BRIDGE_STATE_DIR/reactive-rotate/cooldown.state"
export SCRIPT_DIR="$REPO_ROOT"   # the daemon fn uses $SCRIPT_DIR for helper paths
export BRIDGE_BASH_BIN="bash"

# --- helper invocation for the probe+tap layers ------------------------------
# Each call returns ONE status token on stdout (tap-rotate / tap-fellthrough /
# probe-blind / probe-signal). Env prefixes drive the mutations.
chain_verdict() { python3 "$HELPER" verdict "$1" 2>/dev/null || printf 'helper-error\n'; }

# ---------------------------------------------------------------------------
# Reactive layer — source the REAL shared gate/lock/cooldown helpers + extract
# and eval the REAL shipped daemon reactive-rotate function (a revert of the
# trigger fails the extract; a behavior change is exercised directly).
# ---------------------------------------------------------------------------
# shellcheck source=../../lib/bridge-reactive-rotate.sh
source "$LIB_SH"

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

# --- Stub the daemon-only collaborators (mirrors the step-4 smoke) -----------
ROTATE_COUNT_FILE="$SMOKE_DIR/rotate-calls.count"
AUDIT_LEDGER=""
NOTIFY_LEDGER=""
POOL_NOTE_LEDGER=""

_rotate_calls() { local n=0; [[ -f "$ROTATE_COUNT_FILE" ]] && n="$(cat "$ROTATE_COUNT_FILE" 2>/dev/null || printf 0)"; printf '%s' "$n"; }

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
      printf '%s\n' "${MOCK_ROTATE_JSON:-{\"status\":\"rotated\",\"from\":\"tok-a\",\"to\":\"tok-b\",\"sync_status\":\"synced\"}}"
      ;;
    *rotation-status-parse*)
      case "${MOCK_ROTATE_OUTCOME:-rotated}" in
        rotated) printf 'rotated\t-\ttok-a\ttok-b\tsynced\t-\n' ;;
        all_tokens_limited) printf 'skipped\tall_tokens_limited\t-\t-\t-\t2026-01-01T00:00:00Z\n' ;;
        *) printf 'skipped\tno_alternate_token\t-\t-\t-\t-\n' ;;
      esac
      ;;
    *) : ;;
  esac
}

# shellcheck disable=SC2329
bridge_audit_log() { AUDIT_LEDGER+="$2 "; }
# shellcheck disable=SC2329
bridge_clear_claude_pool_exhausted() { :; }
# shellcheck disable=SC2329
bridge_note_claude_pool_exhausted() { POOL_NOTE_LEDGER+="held "; }
# shellcheck disable=SC2329
bridge_daemon_pass_due() { return 0; }
# shellcheck disable=SC2329
bridge_agent_has_notify_transport() { return 0; }
# shellcheck disable=SC2329
bridge_notify_send() { NOTIFY_LEDGER+="sent "; }
# shellcheck disable=SC2329
bridge_agent_is_static() { [[ "$1" == static-* ]]; }
# #21895 sub-PR 3: the reactive-429 rotate now routes through the shared lease
# swap-or-defer helper first. This chain smoke exercises the DISABLED/local-rotate
# path (no token-updater lease configured), so the stub returns `defer_local`
# (lease OFF) → the extracted reactive fn falls through to its EXISTING local
# rotate, byte-for-byte the pre-lease chain behavior under test.
# shellcheck disable=SC2329
bridge_daemon_lease_swap_route() {
  BRIDGE_LEASE_ROUTE_DECISION="defer_local"
  BRIDGE_LEASE_ROUTE_ENVELOPE=""
  return 0
}

reset_reactive() {
  printf '0' >"$ROTATE_COUNT_FILE"
  AUDIT_LEDGER=""
  NOTIFY_LEDGER=""
  POOL_NOTE_LEDGER=""
  rm -rf "$BRIDGE_STATE_DIR/reactive-rotate" 2>/dev/null || true
  BRIDGE_REACTIVE_ROTATE_DID_ROTATE=0
  BRIDGE_REACTIVE_ROTATE_LATCH_DIGEST=""
  BRIDGE_REACTIVE_ROTATE_LATCH_TS=0
  export BRIDGE_REACTIVE_429_ROTATE_ENABLED=1
  export BRIDGE_USAGE_ROTATION_AGENTS=all
  export MOCK_ACTIVE_DIGEST="tok-a:sha256:aaaa"
  export MOCK_ROTATE_OUTCOME=rotated
}

# Flush-left raw provider 429 (the transport-qualified reactive trigger); a
# CF-edge 429; and a prose/narration 429 (gate must reject the last two).
TRANSPORT_429="Error: HTTP 429 Too Many Requests"
CF_429="cf-ray: 8abc123; HTTP 429 Too Many Requests"
PROSE_429="the agent said it would wait for the 429 rate limit to reset"

# ===========================================================================
# 1 — active-tap-fresh → rotate VIA the tap; native probe NOT consulted.
#     Mutation: a stale `_written_at` tap falls through to the probe layer.
# ===========================================================================
S1="$(chain_verdict l1-tap-fresh)"
S1_MUT="$(CHAIN_TAP_CONTENT_AGE=100000 chain_verdict l1-tap-fresh)"
if [[ "$S1" == "tap-rotate" && "$S1_MUT" == "tap-fellthrough" ]]; then
  _pass "1 active-tap-fresh: a content-fresh at-cap stdin-tap stands the native probe down AND drives a proactive rotation candidate (rotate via the tap); MUTATION — a content-stale \`_written_at\` falls through to the probe layer (#2214 freshness gate has teeth)"
else
  _fail "1 active-tap-fresh" "verdict='$S1' (expected tap-rotate) mutation='$S1_MUT' (expected tap-fellthrough)"
fi

# ===========================================================================
# 2 ★stale/no tap + EDGE-BLOCKED probe + inference-picker 429 → rotate.
#     The sean-mac scenario: BOTH proactive layers go blind, then the reactive
#     backstop fires. We prove the chain end-to-end:
#       (a) the content-stale tap falls through to the probe (L1 → L2);
#       (b) the native probe edge-blocks → writes NO synthetic cache → the
#           monitor surfaces NO proactive candidate (L2 is blind);
#       (c) the SAME real inference 429 in the pane drives the reactive rotate.
#     Mutation: an anthropic-ORIGIN 429 makes the probe a #1468 signal (L2 is
#     NOT blind) — confirming the backstop is the precise complement of a blind
#     probe, not an unconditional second rotation lane.
# ===========================================================================
S2_TAP="$(CHAIN_TAP_CONTENT_AGE=100000 chain_verdict l1-tap-fresh)"   # (a)
S2_PROBE="$(chain_verdict l2-edge-blocked)"                            # (b) blind
S2_PROBE_MUT="$(CHAIN_PROBE_ORIGIN=1 chain_verdict l2-edge-blocked)"   # mutation: not blind
reset_reactive                                                        # (c)
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
S2_ROTATES="$(_rotate_calls)"
if [[ "$S2_TAP" == "tap-fellthrough" ]] && [[ "$S2_PROBE" == "probe-blind" ]] \
   && [[ "$S2_PROBE_MUT" == "probe-signal" ]] \
   && (( S2_ROTATES == 1 )) && (( BRIDGE_REACTIVE_ROTATE_DID_ROTATE == 1 )) \
   && [[ "$AUDIT_LEDGER" == *reactive_429_rotated* ]]; then
  _pass "2 ★sean-mac chain: stale tap fell through (L1→L2), the native probe edge-blocked with NO synthetic cache and NO proactive candidate (L2 blind), and the real inference 429 drove ONE reactive rotate (L3 backstop); MUTATION — an anthropic-origin 429 instead makes the probe a #1468 signal (L2 NOT blind), so the backstop is the exact complement of a blind probe"
else
  _fail "2 sean-mac-chain" "tap='$S2_TAP'(want tap-fellthrough) probe='$S2_PROBE'(want probe-blind) probe_mut='$S2_PROBE_MUT'(want probe-signal) reactive_rotates=$S2_ROTATES did_rotate=$BRIDGE_REACTIVE_ROTATE_DID_ROTATE audit='$AUDIT_LEDGER'"
fi

# ===========================================================================
# 3 — raw provider 429 (flush-left `Error: HTTP 429`) → reactive rotate.
#     Mutation: dropping the transport qualifier (a bare prose 429) → NO rotate.
# ===========================================================================
reset_reactive
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
S3_ROTATES="$(_rotate_calls)"
reset_reactive
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$PROSE_429" ""
S3_MUT_ROTATES="$(_rotate_calls)"
if (( S3_ROTATES == 1 )) && (( S3_MUT_ROTATES == 0 )); then
  _pass "3 raw provider 429: a flush-left transport-qualified \`Error: HTTP 429\` reactive-rotates once ($S3_ROTATES); MUTATION — the same line without the transport qualifier (prose) does NOT ($S3_MUT_ROTATES)"
else
  _fail "3 raw-429-rotate" "transport_rotates=$S3_ROTATES (want 1) prose_rotates=$S3_MUT_ROTATES (want 0)"
fi

# ===========================================================================
# 4 — quoted/prose/CF 429 → NO rotate (audit-only). The reactive gate rejects
#     edge/narration. Mutation built in: a raw transport-429 control DOES rotate.
# ===========================================================================
reset_reactive
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$CF_429" ""
S4_CF="$(_rotate_calls)"
reset_reactive
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$PROSE_429" ""
S4_PROSE="$(_rotate_calls)"
reset_reactive
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""   # control
S4_CTRL="$(_rotate_calls)"
if (( S4_CF == 0 )) && (( S4_PROSE == 0 )) && (( S4_CTRL == 1 )); then
  _pass "4 false-positive defense: a CF/cf-ray edge 429 ($S4_CF) and a prose/narration 429 ($S4_PROSE) are audit-only (NO rotate); the raw transport-429 control DOES rotate ($S4_CTRL) — the gate discriminates edge/prose from a real cap"
else
  _fail "4 fp-defense" "cf=$S4_CF prose=$S4_PROSE control=$S4_CTRL (want 0/0/1)"
fi

# ===========================================================================
# 5 — preflight all_tokens_limited → HOLD: a rotate is ATTEMPTED but the
#     preflighted rotator refuses (every candidate limited); the chain records
#     ONE pool-exhausted notice + audit hold, NOT did_rotate, and never loops.
#     Mutation: the default `rotated` outcome instead commits the rotation.
# ===========================================================================
reset_reactive
export MOCK_ROTATE_OUTCOME=all_tokens_limited
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
S5_ROTATES="$(_rotate_calls)"
S5_DID="$BRIDGE_REACTIVE_ROTATE_DID_ROTATE"
S5_POOL="$POOL_NOTE_LEDGER"
S5_NOTIFY="$NOTIFY_LEDGER"
S5_AUDIT="$AUDIT_LEDGER"
reset_reactive   # mutation control: a normal rotate commits
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
S5_CTRL_DID="$BRIDGE_REACTIVE_ROTATE_DID_ROTATE"
if (( S5_ROTATES == 1 )) && (( S5_DID == 0 )) && [[ "$S5_POOL" == *held* ]] \
   && [[ "$S5_NOTIFY" == *sent* ]] && [[ "$S5_AUDIT" == *reactive_429_rotate_held* ]] \
   && (( S5_CTRL_DID == 1 )); then
  _pass "5 preflight all_tokens_limited → HOLD: the rotate was attempted once but refused (did_rotate=0), with ONE pool-exhausted notice + reactive_429_rotate_held audit and no loop; MUTATION — the default \`rotated\` outcome commits (did_rotate=1)"
else
  _fail "5 all-tokens-limited-hold" "rotate_calls=$S5_ROTATES did_rotate=$S5_DID pool='$S5_POOL' notify='$S5_NOTIFY' audit='$S5_AUDIT' control_did=$S5_CTRL_DID"
fi

# ===========================================================================
# 6 — concurrent detections (picker + daemon same tick) → rotate ONCE. The
#     picker rotates first and stamps the SHARED cooldown; the daemon path in
#     the same tick must see the cooldown and suppress. Mutation: clearing the
#     shared cooldown first lets the daemon path rotate (proving the cooldown —
#     not some unrelated gate — is the single-rotation guard).
# ===========================================================================
reset_reactive
# Picker rotates first → writes the shared cooldown stamp.
bridge_reactive_rotate_cooldown_note
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
S6_ROTATES="$(_rotate_calls)"
S6_AUDIT="$AUDIT_LEDGER"
reset_reactive   # mutation: no prior picker stamp → the daemon path rotates
bridge_daemon_reactive_429_rotate "worker-a" "claude" "$TRANSPORT_429" ""
S6_MUT_ROTATES="$(_rotate_calls)"
if (( S6_ROTATES == 0 )) && [[ "$S6_AUDIT" == *reactive_429_rotate_skipped* ]] \
   && (( S6_MUT_ROTATES == 1 )); then
  _pass "6 concurrent detections: a prior shared-cooldown stamp (picker rotated this event) suppresses the daemon's same-tick rotate ($S6_ROTATES, skipped audit) — single rotation per event; MUTATION — with no prior stamp the daemon path rotates once ($S6_MUT_ROTATES)"
else
  _fail "6 concurrent-rotate-once" "with_cooldown_rotates=$S6_ROTATES audit='$S6_AUDIT' without_cooldown_rotates=$S6_MUT_ROTATES (want 0 / skipped / 1)"
fi

# ===========================================================================
# Summary.
# ===========================================================================
printf '\n'
if (( FAILS == 0 )); then
  printf '[PASS] 2217-rotate-decision-chain: %d checks — the auto-rotate decision chain (HUD stdin-tap → native usage-probe → inference/picker reactive-429) routes correctly across all three layers, including the sean-mac blind-probe backstop; every scenario mutation-proven\n' "$TOTAL"
  exit 0
fi
printf '[FAIL] 2217-rotate-decision-chain: %d/%d checks failed\n' "$FAILS" "$TOTAL" >&2
exit 1
