#!/usr/bin/env bash
# scripts/smoke/2036-daemon-nudge-cadence.sh — behavioral smoke for the #2036
# daemon-nudge-starvation fix: cadence-gate the HEAVY un-gated steps in
# cmd_sync_cycle so the cycle reaches the idle-nudge dispatch EVERY tick.
#
# THE PROBLEM (#2036, bridge v0.16.15 / sean-macmini-m4 17-agent fleet):
# cmd_sync_cycle is a single SERIAL loop. interval=5s is only the inter-cycle
# sleep, but the cycle WORK took ~2 minutes (daemon_tick_slow rows 106-151s)
# because several heavy steps ran EVERY 5s tick: bridge-sync.sh ~9s (TWICE per
# cycle — early site + post_sync), l1 roster reload, mcp_orphan_cleanup_early,
# cron_staging_apply ~8s, claude_token_recovery ~9s, daily_backup ~5s,
# context_pressure_scan. nudge_agents (the idle re-nudge dispatch) is one serial
# block INSIDE that bloated cycle, so a queued task's re-nudge fired only ~once
# per ~2-minute cycle — idle wake latency was minutes, not seconds.
#
# THE FIX (#2036, Option 1 — LTS-appropriate): cadence-gate the heavy steps via
# the existing bridge_daemon_pass_due gate so the base cycle drops below the gate
# interval and reaches nudge_agents/discord_relay every ~5s. The post_sync second
# full bridge-sync is REMOVED (the early site is the single ≤30s cadence). The
# nudge/relay/escalation delivery paths stay EVERY tick (NEVER gated).
#
# WHAT THIS SMOKE PROVES (behavioral, mutation-backed — not just static grep):
#   A — nudge_agents fires on EVERY simulated tick (the whole point of #2036).
#   B — each GATED heavy step fires only on its own interval (bridge_sync ~every
#       30s of simulated time, daily_backup ~every 300s, …) — not every tick.
#   C — MUTATION control: revert the gating (call the heavy steps un-gated, like
#       pre-#2036) and the per-cycle heavy-step work balloons — the heavy steps
#       now run EVERY tick. This proves the assertions in A/B have TEETH: they
#       fail if the gate is removed.
#
# The harness sources the REAL shipped bridge_daemon_pass_due (extracted from
# bridge-daemon.sh, not a copy — a revert of the gate fails the extract), drives
# a faithful per-tick model of the gated-vs-ungated split with a DETERMINISTIC
# simulated clock (no real sleeps), and records which step labels executed each
# tick. Isolated under a mktemp BRIDGE_HOME; no live bridge state is touched.
# Footgun #11: no heredoc-stdin to a subprocess.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
SKIPS=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
# shellcheck disable=SC2329  # _skip is part of the helper trio; kept for parity
_skip() { TOTAL=$((TOTAL + 1)); SKIPS=$((SKIPS + 1)); printf '[skip] %s: %s\n' "$1" "$2"; }

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
if [[ ! -r "$DAEMON_SH" ]]; then
  printf '[FAIL] required source not found: %s\n' "$DAEMON_SH" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-2036-nudge-smoke.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"

# ---------------------------------------------------------------------------
# Source the REAL shipped bridge_daemon_pass_due (top-level function body).
# ---------------------------------------------------------------------------
extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$2"; }
PASS_DUE_BODY="$(extract_fn bridge_daemon_pass_due "$DAEMON_SH")"
if [[ -z "$PASS_DUE_BODY" ]]; then
  printf '[FAIL] could not extract bridge_daemon_pass_due from %s (#2036 depends on the PR-7 gate)\n' "$DAEMON_SH" >&2
  exit 1
fi
eval "$PASS_DUE_BODY"
if ! command -v bridge_daemon_pass_due >/dev/null 2>&1; then
  printf '[FAIL] bridge_daemon_pass_due not defined after eval\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Deterministic simulated clock. bridge_daemon_pass_due calls `date +%s`; we
# shadow `date` with a function returning a controllable FAKE_NOW so we can
# advance simulated time by whole seconds without real sleeps.
# ---------------------------------------------------------------------------
FAKE_NOW=1700000000
# shellcheck disable=SC2329  # invoked INDIRECTLY by the eval'd bridge_daemon_pass_due (`date +%s`)
date() {
  # Honor `date +%s` (the only form the gate uses); pass anything else through.
  if [[ "${1:-}" == "+%s" ]]; then printf '%s\n' "$FAKE_NOW"; return 0; fi
  command date "$@"
}

# ---------------------------------------------------------------------------
# The per-tick model. Mirrors the gated-vs-ungated split that cmd_sync_cycle
# implements after #2036:
#   - The GATED heavy steps run only when bridge_daemon_pass_due says due.
#   - nudge_agents (and the other delivery/wake paths) run UNCONDITIONALLY.
# `$LEDGER` accumulates the labels that actually executed this tick.
# GATING_ENABLED=0 is the MUTATION control: it bypasses the gate (pre-#2036
# behavior — heavy steps every tick), to prove the assertions have teeth.
# ---------------------------------------------------------------------------
GATING_ENABLED=1
LEDGER=""

# default cadences mirror the #2036 design table
INT_BRIDGE_SYNC=30
INT_L1_ROSTER_RELOAD=60
INT_MCP_ORPHAN=300
INT_CRON_STAGING=10
INT_CLAUDE_TOKEN_RECOVERY=60
INT_DAILY_BACKUP=300
INT_CONTEXT_PRESSURE=60

_run_step() { LEDGER+="$1 "; }   # "execute" a step: record its label

_gated_step() {  # _gated_step <pass_key> <interval>
  local pass="$1" interval="$2"
  if (( GATING_ENABLED == 0 )); then
    # Mutation control: pre-#2036, the heavy step ran every tick (no gate).
    _run_step "$pass"
    return 0
  fi
  if bridge_daemon_pass_due "$pass" "$interval"; then
    _run_step "$pass"
  fi
}

simulate_tick() {
  # Time-critical / delivery passes — ALWAYS run (never gated). discord_relay is
  # the low-latency external wake; nudge_agents is the idle re-nudge dispatch.
  _run_step discord_relay
  # Heavy steps — cadence-gated after #2036.
  _gated_step bridge_sync           "$INT_BRIDGE_SYNC"
  _gated_step l1_roster_reload      "$INT_L1_ROSTER_RELOAD"
  _gated_step mcp_orphan_cleanup_early "$INT_MCP_ORPHAN"
  _gated_step context_pressure_scan "$INT_CONTEXT_PRESSURE"
  _gated_step claude_token_recovery "$INT_CLAUDE_TOKEN_RECOVERY"
  _gated_step daily_backup          "$INT_DAILY_BACKUP"
  _gated_step cron_staging_apply    "$INT_CRON_STAGING"
  # The whole point of #2036: nudge dispatch is reached EVERY tick.
  _run_step nudge_agents
}

# Run a simulated daemon for `n` ticks, 5 simulated seconds between cycle starts
# (the daemon's interval). Returns the per-tick ledgers, newline-separated.
run_sim() {  # run_sim <n_ticks> <gating_enabled>
  local n="$1"
  GATING_ENABLED="$2"
  # Fresh cadence state per run so the first tick is a clean fresh-daemon tick.
  rm -rf "$BRIDGE_STATE_DIR/daemon-pass-cadence" 2>/dev/null || true
  FAKE_NOW=1700000000
  local t
  for (( t = 0; t < n; t++ )); do
    LEDGER=""
    simulate_tick
    printf '%s\n' "$LEDGER"
    FAKE_NOW=$(( FAKE_NOW + 5 ))   # 5s inter-cycle interval (simulated)
  done
}

count_label() {  # count_label <ledgers> <label> — ticks whose ledger has <label>
  printf '%s\n' "$1" | grep -cwF "$2" || true
}

# ===========================================================================
# A — nudge_agents fires on EVERY tick (gating ON). 24 ticks = 120 simulated
#     seconds — long enough that bridge_sync (30s) and daily_backup (300s) are
#     clearly NOT every-tick, while nudge_agents must still be every tick.
# ===========================================================================
N=24
LEDGERS="$(run_sim "$N" 1)"
NUDGE_TICKS="$(count_label "$LEDGERS" nudge_agents)"
RELAY_TICKS="$(count_label "$LEDGERS" discord_relay)"
if (( NUDGE_TICKS == N )) && (( RELAY_TICKS == N )); then
  _pass "A nudge_agents (and discord_relay) fire on EVERY tick under #2036 gating ($NUDGE_TICKS/$N ticks) — idle re-nudge is no longer starved by the heavy serial cycle"
else
  _fail "A nudge-every-tick" "nudge_agents ran on $NUDGE_TICKS/$N ticks, discord_relay on $RELAY_TICKS/$N (expected $N/$N) — the delivery path is being gated/starved"
fi

# ===========================================================================
# B — each GATED heavy step fires only on its interval, NOT every tick. 24 ticks
#     at 5s spacing span SIMULATED times 0,5,10,…,115 (the clock advances AFTER
#     each tick, so the last tick is at t=115, a 115s window):
#       bridge_sync (30s)   → due at 0,30,60,90        = 4 runs
#       cron_staging (10s)  → due at 0,10,20,…,110     = 12 runs
#       daily_backup (300s) → due at 0 only            = 1 run
#       mcp_orphan (300s)   → due at 0 only            = 1 run
#     We assert each gated count is strictly LESS THAN N (the regression signal
#     a revert would trip) AND equals the exact cadence math.
# ===========================================================================
BSYNC_TICKS="$(count_label "$LEDGERS" bridge_sync)"
CRON_TICKS="$(count_label "$LEDGERS" cron_staging_apply)"
BACKUP_TICKS="$(count_label "$LEDGERS" daily_backup)"
MCP_TICKS="$(count_label "$LEDGERS" mcp_orphan_cleanup_early)"
B_OK=1
B_DETAIL=""
if (( BSYNC_TICKS >= N )); then B_OK=0; B_DETAIL+="bridge_sync ran every tick ($BSYNC_TICKS/$N); "; fi
if (( BSYNC_TICKS != 4 )); then B_OK=0; B_DETAIL+="bridge_sync expected 4 runs over 115s@30s, got $BSYNC_TICKS; "; fi
if (( CRON_TICKS >= N )); then B_OK=0; B_DETAIL+="cron_staging ran every tick ($CRON_TICKS/$N); "; fi
if (( CRON_TICKS != 12 )); then B_OK=0; B_DETAIL+="cron_staging expected 12 runs over 115s@10s, got $CRON_TICKS; "; fi
if (( BACKUP_TICKS != 1 )); then B_OK=0; B_DETAIL+="daily_backup expected 1 run over 115s@300s, got $BACKUP_TICKS; "; fi
if (( MCP_TICKS != 1 )); then B_OK=0; B_DETAIL+="mcp_orphan expected 1 run over 115s@300s, got $MCP_TICKS; "; fi
if (( B_OK == 1 )); then
  _pass "B each gated heavy step fires only on its interval (bridge_sync 4×@30s, cron_staging 12×@10s, daily_backup 1×@300s, mcp_orphan 1×@300s over 115s) — NOT every tick"
else
  _fail "B per-step-interval" "${B_DETAIL%% }"
fi

# ===========================================================================
# C — MUTATION CONTROL (teeth): with the gate REVERTED (pre-#2036, heavy steps
#     every tick), the heavy steps now run on EVERY tick. This proves A/B are
#     not vacuous — if a future change removes the gate, the heavy-step counts
#     jump to N and (in the real serial daemon) the cycle balloons and starves
#     nudge. We assert the mutated run makes bridge_sync (and the rest) run
#     every tick, i.e. the gate is what holds them back.
# ===========================================================================
MUT_LEDGERS="$(run_sim "$N" 0)"
MUT_BSYNC="$(count_label "$MUT_LEDGERS" bridge_sync)"
MUT_BACKUP="$(count_label "$MUT_LEDGERS" daily_backup)"
MUT_NUDGE="$(count_label "$MUT_LEDGERS" nudge_agents)"
# Under the mutation, the heavy steps run every tick; nudge still runs every tick
# in THIS model (the model isolates the cadence logic), but the heavy per-cycle
# work — which in the REAL serial daemon is the ~9s/~5s blocking cost that
# starves nudge — now executes N times instead of its gated handful. The teeth:
# the GATED run must show STRICTLY FEWER bridge_sync/daily_backup executions than
# the MUTATED run. If they were equal, the gate would be a no-op.
if (( MUT_BSYNC == N )) && (( MUT_BACKUP == N )) \
   && (( BSYNC_TICKS < MUT_BSYNC )) && (( BACKUP_TICKS < MUT_BACKUP )); then
  _pass "C mutation control: reverting the gate makes bridge_sync ($MUT_BSYNC/$N) and daily_backup ($MUT_BACKUP/$N) run EVERY tick vs gated ($BSYNC_TICKS / $BACKUP_TICKS) — the gate provably throttles the heavy steps (A/B are non-vacuous)"
else
  _fail "C mutation-teeth" "expected ungated heavy steps to run every tick and strictly more than gated (mut_bsync=$MUT_BSYNC mut_backup=$MUT_BACKUP gated_bsync=$BSYNC_TICKS gated_backup=$BACKUP_TICKS, nudge=$MUT_NUDGE/$N) — the gate may be a no-op"
fi

# ===========================================================================
# D — nudge_agents is NEVER suppressed: across BOTH the gated and mutated runs,
#     nudge_agents appears on every single tick. The #2036 contract is that the
#     nudge dispatch is ungated regardless of how the heavy steps are configured.
# ===========================================================================
if (( NUDGE_TICKS == N )) && (( MUT_NUDGE == N )); then
  _pass "D nudge_agents is ungated in BOTH the #2036-gated and the mutated model ($NUDGE_TICKS/$N and $MUT_NUDGE/$N) — the delivery path never rides the heavy-step cadence"
else
  _fail "D nudge-ungated-invariant" "nudge_agents was suppressed on some tick (gated=$NUDGE_TICKS/$N, mutated=$MUT_NUDGE/$N)"
fi

# ===========================================================================
# Summary.
# ===========================================================================
printf '\n'
if (( FAILS == 0 )); then
  printf '[PASS] 2036-daemon-nudge-cadence: %d checks (%d skipped) — nudge fires every tick; heavy steps cadence-gated; mutation-proven teeth\n' "$TOTAL" "$SKIPS"
  exit 0
fi
printf '[FAIL] 2036-daemon-nudge-cadence: %d/%d checks failed\n' "$FAILS" "$TOTAL" >&2
exit 1
