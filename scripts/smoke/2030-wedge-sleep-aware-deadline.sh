#!/usr/bin/env bash
# scripts/smoke/2030-wedge-sleep-aware-deadline.sh — unit smoke for the #2030
# SUSPEND-AWARE no-progress deadline in the #1563 daemon wedge supervisor.
#
# THE BUG (#2030): the #1563 PR-2 supervisor (bridge_daemon_run_tick_supervised
# in lib/bridge-daemon-control.sh) measures in-tick "no progress" with a
# WALL-CLOCK delta (now - last progress stamp). On a host that SLEEPS, system
# sleep freezes the daemon AND its progress-heartbeat mtime; on wake the wall
# clock has jumped forward by the whole sleep duration, so the supervisor reads
# e.g. "no progress for 910s >= deadline 720s" and false-aborts (exit 99)
# though nothing hung — a recurring outage on intermittently-on laptops.
#
# THE FIX (this smoke pins): the supervisor discriminates suspend-from-hang by
# the SHAPE of the wall-clock gap observed BETWEEN two consecutive polls:
#   - a SUSPEND is ONE huge inter-poll gap (the whole sleep span; the
#     supervisor itself was frozen) -> CREDIT that span, subtract from the
#     no-progress age, so the step RESUMES on wake (no wedge);
#   - a genuine HANG is MANY small per-poll gaps (each ~= the poll interval)
#     that accumulate to the deadline -> NEVER credited -> the wedge STILL
#     fires (exit 99). This is the must-not-neuter invariant.
#
# Everything sourced here is the REAL shipped lib (lib/bridge-daemon-control.sh),
# not a copy, so a revert of the #2030 guard fails this smoke.
#
# WHY pure-helper driving (not a live fork+sleep): reproducing a 910s OS
# suspend against the real fork+poll supervisor would require freezing the
# smoke for minutes. Instead we drive the EXTRACTED discrimination helpers
# (_bridge_daemon_tick_suspend_threshold / _bridge_daemon_tick_suspend_credit_
# gap) AND a reference simulator that mirrors the loop's `age - suspend_credit`
# deadline accounting byte-for-byte, then prove via a MUTATION (drop the
# credit) that case (a) would falsely wedge — the teeth.
#
# Assertions:
#   A  — SUSPEND (single huge gap) -> credited, no wedge (step resumes).
#   B  — HANG (many poll-sized gaps, no progress) -> NOT credited, wedge fires.
#   C  — MUTATION control: with the credit removed, case (A) DOES wedge -> the
#        guard is load-bearing (non-vacuous).
#   D  — threshold scales with the poll interval and floors on the absolute
#        minimum; sub-threshold gaps (jitter) are never credited.
#   E  — defense-in-depth: _bridge_daemon_restarter_present is defined and
#        returns non-zero (no restarter confirmable) under the isolated
#        BRIDGE_HOME, so the self-abort path's "no restarter" WARN is reachable.
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge state is
# touched. Footgun #11: no heredoc-stdin to a subprocess capture.

# SC2030/SC2031: the real-loop legs (G*/H) intentionally `export` the fast-
# deadline config INSIDE a `( … )` subshell so it is LOCAL to that leg and never
# leaks into the rest of the smoke — that subshell-local scoping is the design,
# not a bug. Disabled file-wide (info-severity; matches the isolation intent).
# shellcheck disable=SC2030,SC2031
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
if [[ ! -r "$CONTROL_LIB" ]]; then
  printf '[FAIL] required source not found: %s\n' "$CONTROL_LIB" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-2030-smoke.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"

# Stubs the sourced lib may call.
# shellcheck disable=SC2329  # invoked indirectly by the sourced control lib
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }

# Pin a known supervisor config so the math is deterministic.
export BRIDGE_DAEMON_TICK_POLL_SECONDS=2
export BRIDGE_DAEMON_TICK_SUSPEND_GAP_FLOOR_SECONDS=120
export BRIDGE_DAEMON_TICK_SUSPEND_GAP_POLL_MULT=10
POLL=2
DEADLINE=720   # the standalone reference deadline used by the simulator below

# shellcheck source=/dev/null
source "$CONTROL_LIB"

# Helper presence gate — a revert of the #2030 guard removes these.
for fn in _bridge_daemon_tick_suspend_threshold \
          _bridge_daemon_tick_suspend_credit_gap \
          _bridge_daemon_restarter_present \
          bridge_daemon_run_tick_supervised; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf '[FAIL] %s not defined after sourcing %s (#2030 guard missing?)\n' "$fn" "$CONTROL_LIB" >&2
    exit 1
  fi
done

# Reference simulator: replicate the supervisor loop's per-poll suspend-credit
# accounting against a SCRIPTED sequence of inter-poll wall-clock gaps and a
# raw (suspend-INCLUSIVE) no-progress age, then decide wedge-or-not exactly as
# the real loop does: age_effective = raw_age - suspend_credit; wedge iff
# age_effective >= deadline. $1 = "guarded" (use the credit, real behavior) or
# "mutated" (ignore the credit — the C control). Remaining args = the gap
# sequence. The raw age equals the SUM of all gaps (no progress stamped — the
# worst case, exactly the wedge candidate).
sim_wedges() {
  local mode="$1"; shift
  local raw_age=0 credit_total=0 g c
  for g in "$@"; do
    raw_age=$(( raw_age + g ))
    c="$(_bridge_daemon_tick_suspend_credit_gap "$g" "$POLL")"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    credit_total=$(( credit_total + c ))
  done
  local effective="$raw_age"
  if [[ "$mode" == "guarded" ]]; then
    effective=$(( raw_age - credit_total ))
    (( effective < 0 )) && effective=0
  fi
  if (( effective >= DEADLINE )); then
    printf 'WEDGE'
  else
    printf 'OK'
  fi
}

# ---------------------------------------------------------------------------
# A — SUSPEND: a single 910s inter-poll gap (the #2030 evidence: "no progress
# for 910s") with raw age 910 > deadline 720. Guarded -> credited -> OK.
# ---------------------------------------------------------------------------
A="$(sim_wedges guarded 910)"
if [[ "$A" == "OK" ]]; then
  _pass "A suspend (single 910s gap, raw age 910 >= deadline 720) is CREDITED -> NO wedge (step resumes on wake)"
else
  _fail "A suspend-credited" "expected OK (no wedge), got '$A' — a wake-from-sleep would false-abort"
fi

# ---------------------------------------------------------------------------
# B — HANG: a genuine in-tick hang advances the supervisor at its normal poll
# cadence: MANY poll-sized gaps with NO progress. 400 polls * 2s = 800s raw age
# > deadline 720, and NO single gap reaches the 120s suspend threshold -> zero
# credit -> the wedge STILL fires. (The must-not-neuter invariant.)
# ---------------------------------------------------------------------------
HANG_GAPS=()
for _i in $(seq 1 400); do HANG_GAPS+=("$POLL"); done
B="$(sim_wedges guarded "${HANG_GAPS[@]}")"
if [[ "$B" == "WEDGE" ]]; then
  _pass "B genuine hang (400 x ${POLL}s poll gaps, raw age 800 >= deadline 720, never credited) STILL WEDGES (exit 99) — supervisor not neutered"
else
  _fail "B hang-still-wedges" "expected WEDGE, got '$B' — the fix wrongly forgives a real hang"
fi

# B2 — mixed: a hang that ALSO straddles one short jitter spike still wedges, as
# long as no single gap crosses the suspend threshold (e.g. a 119s gap is below
# the 120s floor). Proves the threshold edge does not leak credit to a hang.
MIX_GAPS=(119)
for _i in $(seq 1 320); do MIX_GAPS+=("$POLL"); done   # 119 + 640 = 759 >= 720
B2="$(sim_wedges guarded "${MIX_GAPS[@]}")"
if [[ "$B2" == "WEDGE" ]]; then
  _pass "B2 hang with a sub-threshold 119s spike (below 120s floor) still WEDGES — no leaked credit at the threshold edge"
else
  _fail "B2 hang-edge-still-wedges" "expected WEDGE, got '$B2'"
fi

# ---------------------------------------------------------------------------
# C — MUTATION control: with the suspend credit REMOVED (mode=mutated), the
# same suspend gap from (A) DOES wedge. Proves the guard is load-bearing — a
# revert re-introduces the #2030 false-abort.
# ---------------------------------------------------------------------------
C="$(sim_wedges mutated 910)"
if [[ "$C" == "WEDGE" ]]; then
  _pass "C mutation control: without the suspend credit the 910s suspend FALSELY wedges -> the #2030 guard is non-vacuous"
else
  _fail "C mutation-control" "expected WEDGE without the credit, got '$C' — the smoke would pass even with the fix reverted (vacuous)"
fi

# ---------------------------------------------------------------------------
# D — threshold scaling + jitter immunity.
# ---------------------------------------------------------------------------
THR2="$(_bridge_daemon_tick_suspend_threshold 2)"     # max(120, 2*10) = 120
THR30="$(_bridge_daemon_tick_suspend_threshold 30)"   # max(120, 30*10) = 300
if [[ "$THR2" == "120" && "$THR30" == "300" ]]; then
  _pass "D1 suspend threshold = max(floor 120, poll*mult): poll2->120, poll30->300 (scales with operator-raised poll)"
else
  _fail "D1 threshold-scaling" "expected 120/300, got '$THR2'/'$THR30'"
fi
# A poll-jitter gap (3s, just above the 2s poll) must NOT be credited.
J="$(_bridge_daemon_tick_suspend_credit_gap 3 2)"
# A just-below-floor gap (119s) must NOT be credited; at-floor (120s) is.
JB="$(_bridge_daemon_tick_suspend_credit_gap 119 2)"
JF="$(_bridge_daemon_tick_suspend_credit_gap 120 2)"
if [[ "$J" == "0" && "$JB" == "0" && "$JF" == "118" ]]; then
  _pass "D2 jitter immunity: 3s->0 credit, 119s->0 credit, 120s->118 credit (gap-minus-one-poll) — only a true suspend is forgiven"
else
  _fail "D2 jitter-immunity" "expected 0/0/118, got '$J'/'$JB'/'$JF'"
fi

# ---------------------------------------------------------------------------
# E — defense-in-depth: the restarter-presence probe is wired and, under the
# isolated BRIDGE_HOME (no launchd label / no systemd unit), returns non-zero
# so the self-abort path's operator-visible "no restarter" WARN is reachable.
# (This is the permanent-outage amplifier from #2030.)
# ---------------------------------------------------------------------------
if _bridge_daemon_restarter_present; then
  # On a dev box with a real bridge LaunchAgent loaded this could legitimately
  # be true; treat that as a pass (the probe confirmed a restarter), but note
  # the env so the WARN-reachability claim is honest.
  _pass "E restarter probe returned PRESENT in this env (a confirmable restarter exists) — WARN path is the complement and remains wired"
else
  _pass "E restarter probe returns ABSENT under isolated BRIDGE_HOME -> the self-abort 'no restarter' WARN is reachable (#2030 outage amplifier covered)"
fi

# ---------------------------------------------------------------------------
# F — REAL-LOOP WIRING static-assert (closes the simulator-independence gap).
# The A/B/C assertions above drive the EXTRACTED helper + an independent
# simulator (sim_wedges); a regression in the REAL supervisor body would NOT
# fail them. Assert the shipped bridge_daemon_run_tick_supervised body actually
# wires the AGE-JUMP discriminator (the round-3-correct formulation):
#   F1 — feeds the credit helper from the age JUMP (_age_jump) and subtracts the
#        accumulated credit from the age (age = age - _suspend_credit).
#   F2 — resets the credit INSIDE the loop on an advancing progress stamp
#        (rounds 1/2: a stale credit must not bleed into a later interval).
#   F3 — on a fresh interval, the jump is the WHOLE new age (_age_jump="$age"),
#        so a child that PROGRESSED then the host SLEPT (round-3) is still
#        credited and NOT false-wedged.
# Use `declare -f` to read the in-memory function body (the actual sourced lib).
# ---------------------------------------------------------------------------
SUP_BODY="$(declare -f bridge_daemon_run_tick_supervised 2>/dev/null || printf '')"
SUP_LOOP="${SUP_BODY#*while true}"
if [[ -n "$SUP_BODY" ]] \
   && printf '%s' "$SUP_BODY" | grep -Eq '_credit="?\$\(_bridge_daemon_tick_suspend_credit_gap[[:space:]]+"?\$_age_jump' \
   && printf '%s' "$SUP_BODY" | grep -Eq 'age=\$\(\(\s*age\s*-\s*_suspend_credit\s*\)\)'; then
  _pass "F1 supervisor feeds the credit helper from the AGE JUMP (_age_jump) AND subtracts _suspend_credit from age — real-loop wiring, not just the simulator"
else
  _fail "F1 real-loop-credit-wiring" "bridge_daemon_run_tick_supervised does not feed _age_jump to the credit helper and subtract _suspend_credit from age — the age-jump discriminator may be mis-wired"
fi
# F2 — the credit RESET keyed on forward progress, INSIDE the loop (not the
# pre-loop initializer). Split the body at `while true` so the `_suspend_credit=0`
# initializer in the pre-loop `local` line cannot satisfy this alone.
if [[ -n "$SUP_BODY" ]] \
   && printf '%s' "$SUP_BODY" | grep -q '_bridge_daemon_tick_progress_ts' \
   && printf '%s' "$SUP_BODY" | grep -Eq '_cur_progress_ts[[:space:]]*>[[:space:]]*_last_progress_ts' \
   && printf '%s' "$SUP_LOOP" | grep -Eq '_suspend_credit=0'; then
  _pass "F2 supervisor resets the suspend credit INSIDE the loop on an advancing progress stamp (_cur > _last) — stale-credit-across-interval regression caught"
else
  _fail "F2 real-loop-credit-reset-wiring" "bridge_daemon_run_tick_supervised does not reset _suspend_credit inside the loop on an advancing progress stamp"
fi
# F3 — round-3 catch: on a fresh interval (progress advanced) the age JUMP fed to
# the credit helper must be the WHOLE NEW AGE (_age_jump="$age"), so a post-stamp
# suspend (child progressed, THEN the host slept) is credited and NOT false-
# wedged. Assert the progressed arm sets _age_jump="$age" (the non-progressed arm
# uses age - _prev_age). The teeth: a revert to "_age_jump=0 on progress" (the
# round-2 over-correction) would FAIL this.
SUP_PROGRESSED_ARM="${SUP_BODY#*_progressed == 1*then}"
SUP_PROGRESSED_ARM="${SUP_PROGRESSED_ARM%%else*}"
if [[ -n "$SUP_BODY" ]] \
   && printf '%s' "$SUP_BODY" | grep -Eq '_progressed[[:space:]]*==[[:space:]]*1' \
   && printf '%s' "$SUP_PROGRESSED_ARM" | grep -Eq '_age_jump="\$age"'; then
  _pass "F3 on a fresh interval the credit jump is the WHOLE new age (_age_jump=\"\$age\") — a progress-then-suspend is forgiven, not false-wedged (round-3 regression caught)"
else
  _fail "F3 real-loop-fresh-interval-jump" "the progressed arm does not set _age_jump=\"\$age\" — a child that progressed then the host slept would false-wedge (round-3 bug)"
fi
# F4 — round-4 catch: the supervisor must GUARD the no-baseline sentinel so it is
# never credited as suspend. Assert the loop compares age against the sentinel
# constant (a missing/unreadable progress file → 999999 → must wedge, not be
# forgiven). The teeth: removing this guard re-introduces the round-4 wedge-
# suppression on a deleted progress file (covered live by H).
if [[ -n "$SUP_BODY" ]] \
   && printf '%s' "$SUP_BODY" | grep -q 'BRIDGE_DAEMON_TICK_PROGRESS_AGE_SENTINEL' \
   && printf '%s' "$SUP_BODY" | grep -Eq 'age[[:space:]]*>=[[:space:]]*_sentinel'; then
  _pass "F4 supervisor guards the no-baseline sentinel (age >= sentinel skips crediting) — a missing/unreadable progress file wedges, the sentinel is not self-forgiven (round-4 regression caught)"
else
  _fail "F4 real-loop-sentinel-guard" "bridge_daemon_run_tick_supervised does not guard the progress-age sentinel before crediting — a missing progress file would suppress the wedge forever"
fi

# ---------------------------------------------------------------------------
# G — REAL-LOOP suspend -> resume -> genuine hang, driven through the ACTUAL
# bridge_daemon_run_tick_supervised with a scripted clock. The child re-stamps
# progress after a 1000s suspend, then genuinely HANGS; the post-resume hang
# must reach the deadline and WEDGE (rc 99) — NOT be masked by stale suspend
# credit. Two orderings are exercised:
#   G1 (sequential): the parent observes the huge gap on one poll (credits it),
#      THEN on a later poll sees the child's re-stamp (resets the credit).
#   G2 (same-poll interleave, the round-2 codex catch): the child re-stamps
#      DURING the huge-gap poll, so the parent observes the progress-advance
#      AND the huge age on the SAME poll — the later hang must still wedge.
#   G3 (progress-then-suspend, the round-3 codex catch): the child re-stamps,
#      THEN the host sleeps with NO subsequent hang — the post-progress suspend
#      must be FORGIVEN (rc 0), not false-wedged.
# All run the real loop (not the simulator). The leg runs in a SUBSHELL so the
# `date`/audit overrides + fast-deadline env never leak into the rest of the
# smoke. $1 = ordering ("sequential" | "interleave" | "progress_then_suspend").
# ---------------------------------------------------------------------------
G_PARENT_DIR="$(mktemp -d "$TMPDIR_BASE/agb-2030-G.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -rf '$G_PARENT_DIR' '$SMOKE_DIR' 2>/dev/null || true" EXIT INT TERM

run_real_loop_suspend_resume_hang() {
  local ordering="$1"
  local gdir; gdir="$(mktemp -d "$G_PARENT_DIR/case.XXXXXX")"
  local gaudit="$gdir/audit.log"; : >"$gaudit"
  local gclock="$gdir/clock"; printf '2000000000' >"$gclock"
  local gphase="$gdir/phase"
  local gout grc
  gout="$(
    (
      export BRIDGE_HOME="$gdir/home"; export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
      mkdir -p "$BRIDGE_STATE_DIR"
      export BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=3 BRIDGE_DAEMON_TICK_GRACE_SECONDS=1 BRIDGE_DAEMON_TICK_POLL_SECONDS=1
      export BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=1 BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS=1 \
             BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS=1 BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS=1 \
             BRIDGE_CRON_SYNC_TIMEOUT=1 BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS=1
      export BRIDGE_DAEMON_TICK_SUSPEND_GAP_FLOOR_SECONDS=5 BRIDGE_DAEMON_TICK_SUSPEND_GAP_POLL_MULT=3
      # shellcheck disable=SC2329
      bridge_warn() { :; }
      # shellcheck disable=SC2329
      bridge_audit_log() { printf '%s\n' "${2:-}" >>"$gaudit"; }
      # shellcheck source=/dev/null
      source "$CONTROL_LIB"
      # shellcheck disable=SC2329
      date() { if [[ "${1:-}" == "+%s" ]]; then cat "$gclock"; return 0; fi; command date "$@"; }
      # Child: re-stamp once when phase.resume appears, then hang until phase.done.
      # shellcheck disable=SC2329
      bridge_daemon_run_without_singleton_lock() {
        local resumed=0
        while true; do
          if [[ -f "$gphase.resume" && $resumed -eq 0 ]]; then
            bridge_daemon_tick_progress_touch step_after_resume
            resumed=1
          fi
          [[ -f "$gphase.done" ]] && return 0
          command sleep 0.1
        done
      }
      # Director: drive the scripted clock + resume signal per ordering.
      (
        command sleep 1; printf '2000000001' >"$gclock"          # normal poll
        if [[ "$ordering" == "progress_then_suspend" ]]; then
          # ROUND-3: the child PROGRESSES, then the host SLEEPS (no hang after).
          # Re-stamp first, give the child a beat to stamp, THEN jump the clock
          # +900s (the post-progress suspend), then let the child finish cleanly.
          # The post-stamp suspend must be CREDITED -> rc 0, NO false wedge.
          command sleep 1; touch "$gphase.resume"; command sleep 0.5; printf '2000000902' >"$gclock"
          command sleep 1; printf '2000000903' >"$gclock"
          command sleep 1; touch "$gphase.done"
        else
          if [[ "$ordering" == "interleave" ]]; then
            # SAME-poll: jump +1000s AND trigger the re-stamp together, then give
            # the child a beat to stamp BEFORE the parent's next poll runs.
            command sleep 1; touch "$gphase.resume"; printf '2000001001' >"$gclock"; command sleep 0.4
          else
            # SEQUENTIAL: parent sees the +1000s gap on one poll, re-stamp the next.
            command sleep 1; printf '2000001001' >"$gclock"      # +1000s suspend
            command sleep 1; touch "$gphase.resume"              # child re-stamps next poll
          fi
          command sleep 1; printf '2000001002' >"$gclock"
          command sleep 1; printf '2000001003' >"$gclock"
          command sleep 1; printf '2000001004' >"$gclock"
          command sleep 1; printf '2000001005' >"$gclock"        # age-from-resume >= deadline 4
          command sleep 3; touch "$gphase.done"
        fi
      ) &
      bridge_daemon_run_tick_supervised 99 bridge_daemon_run_without_singleton_lock
      printf 'RC=%s' "$?"
    )
  )" || true
  grc="${gout##*RC=}"
  [[ "$grc" =~ ^[0-9]+$ ]] || grc=-1
  local credited=0 wedged=0
  grep -q 'daemon_tick_suspend_credited' "$gaudit" 2>/dev/null && credited=1
  grep -q 'daemon_tick_deadline_exceeded' "$gaudit" 2>/dev/null && wedged=1
  # Emit "rc credited wedged" for the caller to assert.
  printf '%s %s %s' "$grc" "$credited" "$wedged"
}

# Capture "rc credited wedged" into positionals via word-splitting (no
# here-string / heredoc — footgun #11). The helper prints exactly three
# integer tokens.
# shellcheck disable=SC2046  # intentional word-split of the 3-token result
set -- $(run_real_loop_suspend_resume_hang sequential)
G1_RC="${1:--1}"; G1_CRED="${2:-0}"; G1_WEDGE="${3:-0}"
if [[ "$G1_RC" == "99" ]] && (( G1_WEDGE == 1 )) && (( G1_CRED == 1 )); then
  _pass "G1 real loop SEQUENTIAL: suspend credited -> child re-stamped a later poll (credit reset) -> genuine hang STILL WEDGES (rc 99) — stale credit not carried forward"
else
  _fail "G1 real-loop-sequential" "expected rc=99 credited=1 wedged=1, got rc=$G1_RC credited=$G1_CRED wedged=$G1_WEDGE — post-resume hang masked by stale credit"
fi

# shellcheck disable=SC2046  # intentional word-split of the 3-token result
set -- $(run_real_loop_suspend_resume_hang interleave)
G2_RC="${1:--1}"; G2_CRED="${2:-0}"; G2_WEDGE="${3:-0}"
if [[ "$G2_RC" == "99" ]] && (( G2_WEDGE == 1 )); then
  _pass "G2 real loop SAME-POLL INTERLEAVE: child re-stamped DURING the huge-gap poll -> later genuine hang STILL WEDGES (rc 99) — round-2 interleaving bug fixed"
else
  _fail "G2 real-loop-interleave" "expected rc=99 wedged=1, got rc=$G2_RC credited=$G2_CRED wedged=$G2_WEDGE — same-poll suspend+resume masked the hang"
fi

# G3 — ROUND-3: the child PROGRESSES, THEN the host SLEEPS (no hang after). The
# post-progress suspend must be CREDITED from the fresh interval's whole age, so
# this LEGITIMATE progress-then-sleep is FORGIVEN (rc 0, NO wedge) — not false-
# aborted. The round-2 over-correction (discard the gap on progress) would
# false-wedge here; this is the assertion that catches it.
# shellcheck disable=SC2046  # intentional word-split of the 3-token result
set -- $(run_real_loop_suspend_resume_hang progress_then_suspend)
G3_RC="${1:--1}"; G3_CRED="${2:-0}"; G3_WEDGE="${3:-0}"
if [[ "$G3_RC" == "0" ]] && (( G3_WEDGE == 0 )); then
  _pass "G3 real loop PROGRESS-THEN-SUSPEND: child progressed, THEN host slept 900s -> CREDITED, rc 0, NO false wedge — a legitimate post-progress sleep is forgiven (round-3 over-correction caught)"
else
  _fail "G3 real-loop-progress-then-suspend" "expected rc=0 wedged=0, got rc=$G3_RC credited=$G3_CRED wedged=$G3_WEDGE — a legitimate progress-then-sleep was FALSE-WEDGED (round-3 bug)"
fi

# ---------------------------------------------------------------------------
# H — SENTINEL GUARD (round-4 codex catch): a hung child whose progress file is
# MISSING/UNREADABLE makes _bridge_daemon_tick_progress_age return the fixed
# 999999 NO-BASELINE sentinel. That sentinel must NOT be fed into the suspend
# credit (else it forgives itself and suppresses the wedge forever). Drive the
# REAL loop with a child that DELETES its progress file then hangs; assert it
# STILL WEDGES (rc 99) and the sentinel is NOT credited. Also covers the latent
# set -u unbound-`last_ts` fix in _bridge_daemon_tick_progress_age (a missing
# file under `set -u` would otherwise abort the age read). No scripted clock —
# the genuine wall clock at normal poll cadence reaches the sentinel each poll.
# ---------------------------------------------------------------------------
H_DIR="$(mktemp -d "$G_PARENT_DIR/H.XXXXXX")"
H_AUDIT="$H_DIR/audit.log"; : >"$H_AUDIT"
H_RC=0
H_OUT="$(
  (
    export BRIDGE_HOME="$H_DIR/home"; export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
    mkdir -p "$BRIDGE_STATE_DIR"
    export BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS=3 BRIDGE_DAEMON_TICK_GRACE_SECONDS=1 BRIDGE_DAEMON_TICK_POLL_SECONDS=1
    export BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS=1 BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS=1 \
           BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS=1 BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS=1 \
           BRIDGE_CRON_SYNC_TIMEOUT=1 BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS=1
    export BRIDGE_DAEMON_TICK_SUSPEND_GAP_FLOOR_SECONDS=5 BRIDGE_DAEMON_TICK_SUSPEND_GAP_POLL_MULT=3
    # shellcheck disable=SC2329
    bridge_warn() { :; }
    # shellcheck disable=SC2329
    bridge_audit_log() { printf '%s\n' "${2:-}" >>"$H_AUDIT"; }
    # shellcheck source=/dev/null
    source "$CONTROL_LIB"
    _hpf="$(bridge_daemon_tick_progress_file)"
    # Child: delete the progress file (+.step) then hang (no further stamps).
    # shellcheck disable=SC2329
    bridge_daemon_run_without_singleton_lock() {
      rm -f "$_hpf" "$_hpf.step" 2>/dev/null
      while [[ ! -f "$H_DIR/done" ]]; do command sleep 0.2; done
      return 0
    }
    ( command sleep 10; touch "$H_DIR/done" ) &
    bridge_daemon_run_tick_supervised 99 bridge_daemon_run_without_singleton_lock
    printf 'RC=%s' "$?"
  )
)" || true
H_RC="${H_OUT##*RC=}"; [[ "$H_RC" =~ ^[0-9]+$ ]] || H_RC=-1
H_WEDGE=0; grep -q 'daemon_tick_deadline_exceeded' "$H_AUDIT" 2>/dev/null && H_WEDGE=1
H_CRED=0;  grep -q 'daemon_tick_suspend_credited' "$H_AUDIT" 2>/dev/null && H_CRED=1
if [[ "$H_RC" == "99" ]] && (( H_WEDGE == 1 )) && (( H_CRED == 0 )); then
  _pass "H sentinel guard: child DELETED its progress file then hung -> 999999 sentinel NOT credited -> STILL WEDGES (rc 99) — round-4 sentinel-leak + set -u unbound-last_ts both fixed"
else
  _fail "H sentinel-guard" "expected rc=99 wedged=1 credited=0, got rc=$H_RC wedged=$H_WEDGE credited=$H_CRED — the missing-progress-file sentinel was credited and suppressed the wedge (round-4 bug)"
fi

# ---------------------------------------------------------------------------
printf '\n[2030-smoke] %d assertions, %d failures\n' "$TOTAL" "$FAILS"
if (( FAILS > 0 )); then
  exit 1
fi
exit 0
