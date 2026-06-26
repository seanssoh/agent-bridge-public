#!/usr/bin/env bash
# scripts/smoke/1563-pr7-tick-cadence.sh — unit + static smoke for the #1579
# (#1563 follow-up, rc2 PR-7) per-tick CADENCE GATE that fixes root cause 2 of
# the daemon slow-tick finding.
#
# THE PROBLEM (#1579 / bridge #10099, patch 2026-06-06): even with the watchdog
# scan disabled, the daemon tick_age oscillates to ~30-45s against the 5s tick
# interval — the tick itself is slow. cmd_sync_cycle runs ~33 passes SERIALLY
# and several iterate over EVERY agent every 5s tick (channel-health, plugin-
# liveness, the per-agent context-pressure / stall scans, the unclaimed sweeps).
# On a real roster that blows the 5s interval.
#
# THE FIX PR-7 ships (this smoke pins):
#   - bridge-daemon.sh: bridge_daemon_pass_due "<pass>" "<interval>" — a reusable
#     cadence gate (mirrors bridge_watchdog_due) backed by a per-pass last-run
#     stamp under $BRIDGE_STATE_DIR/daemon-pass-cadence/<pass>.ts. Returns 0
#     (run + stamp) when due OR on a fresh daemon (no stamp); returns 1 (skip,
#     leave stamp) within the interval.
#   - cmd_sync_cycle: the EXPENSIVE PERIODIC passes are wrapped in the gate (~30s
#     env-overridable) while the TIME-CRITICAL delivery/escalation passes stay
#     EVERY tick. The BRIDGE_DAEMON_LAST_STEP / _bridge_daemon_mark_progress
#     heartbeat mark stays BEFORE the due-check so a skipped gated pass still
#     refreshes the PR-2 supervisor heartbeat (never a false wedge).
#
# Assertions (teeth carried where a revert would silently regress):
#   G1 — fresh daemon (no stamp) → the gate RUNS (returns 0) and writes a stamp.
#   G2 — a second call WITHIN the interval → SKIPS (returns 1); the stamp from
#        G1 is UNCHANGED (the pass only advances state on a RUN).
#   G3 — after the interval elapses → RUNS again (returns 0) and the stamp
#        ADVANCES. TEETH: G2's no-advance + G3's advance prove the gate fires
#        exactly once per interval, not every tick and not never.
#   G4 — interval <= 0 / non-numeric → the gate is DISABLED (always returns 0,
#        runs every tick) — so an operator can opt a pass back to every-tick.
#   G5 — distinct pass keys keep INDEPENDENT stamps (gating one does not gate
#        another).
#   G6 — key sanitization: a pass name with path metacharacters cannot escape
#        the daemon-pass-cadence/ dir (no traversal stamp).
#   H1 — STATIC: every PERIODIC-EXPENSIVE pass IS wrapped in bridge_daemon_pass_due
#        inside cmd_sync_cycle.
#   H2 — STATIC TEETH: every TIME-CRITICAL pass is NOT gated — if the fixer
#        accidentally wrapped one in bridge_daemon_pass_due, this FAILS.
#   H3 — STATIC: the heartbeat mark (BRIDGE_DAEMON_LAST_STEP=/mark_progress) for
#        each gated pass appears BEFORE its bridge_daemon_pass_due call, so a
#        skipped tick refreshes the PR-2 heartbeat first (mark-before-due-check).
#   H4 — STATIC: the daemon_tick_slow diagnostic row is emitted (not an abort).
#
# Isolated: everything runs under a mktemp BRIDGE_HOME; no live bridge state is
# touched. Footgun #11: no heredoc-stdin to a subprocess capture.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
SKIPS=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
_skip() { TOTAL=$((TOTAL + 1)); SKIPS=$((SKIPS + 1)); printf '[skip] %s: %s\n' "$1" "$2"; }

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
if [[ ! -r "$DAEMON_SH" ]]; then
  printf '[FAIL] required source not found: %s\n' "$DAEMON_SH" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1563-pr7-smoke.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

export BRIDGE_HOME="$SMOKE_DIR/home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$BRIDGE_STATE_DIR"

CADENCE_DIR="$BRIDGE_STATE_DIR/daemon-pass-cadence"

# Source ONLY the shipped bridge_daemon_pass_due function from bridge-daemon.sh
# (extract its top-level body; we cannot source the whole daemon here). This is
# the REAL shipped function, not a copy — a revert of the gate fails the extract.
extract_fn() {  # extract a single top-level shell function body from a file
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$2"
}
PASS_DUE_BODY="$(extract_fn bridge_daemon_pass_due "$DAEMON_SH")"
if [[ -z "$PASS_DUE_BODY" ]]; then
  printf '[FAIL] could not extract bridge_daemon_pass_due from %s (PR-7 gate missing?)\n' "$DAEMON_SH" >&2
  exit 1
fi
eval "$PASS_DUE_BODY"
if ! command -v bridge_daemon_pass_due >/dev/null 2>&1; then
  printf '[FAIL] bridge_daemon_pass_due not defined after eval — PR-7 gate missing\n' >&2
  exit 1
fi

stamp_of() {  # read the integer stamp for a pass key, or empty if absent
  local key="$1"
  local f="$CADENCE_DIR/${key}.ts"
  [[ -f "$f" ]] || { printf '' ; return 0; }
  tr -dc '0-9' <"$f" 2>/dev/null | head -c 18
}

# ===========================================================================
# G1 — fresh daemon (no stamp) → the gate RUNS and writes a stamp.
# ===========================================================================
G1_RC=0
bridge_daemon_pass_due context_pressure_scan 30 || G1_RC=$?
G1_STAMP="$(stamp_of context_pressure_scan)"
if (( G1_RC == 0 )) && [[ "$G1_STAMP" =~ ^[0-9]+$ ]]; then
  _pass "G1 fresh daemon (no stamp) → gate RUNS (rc=0) and writes a last-run stamp ($G1_STAMP)"
else
  _fail "G1 fresh-run" "expected run+stamp on a fresh daemon (rc=$G1_RC, stamp='${G1_STAMP:-<none>}') — a fresh daemon must not be starved"
fi

# ===========================================================================
# G2 — second call WITHIN the interval → SKIPS; stamp UNCHANGED.
# ===========================================================================
G2_RC=0
bridge_daemon_pass_due context_pressure_scan 30 && G2_RC=0 || G2_RC=$?
G2_STAMP="$(stamp_of context_pressure_scan)"
if (( G2_RC == 1 )) && [[ "$G2_STAMP" == "$G1_STAMP" ]]; then
  _pass "G2 within-interval call → SKIPS (rc=1) and the last-run stamp is UNCHANGED ($G2_STAMP) — pass advances state only on a run"
else
  _fail "G2 within-interval-skip" "expected skip (rc=1) with unchanged stamp (rc=$G2_RC, stamp '$G1_STAMP' → '$G2_STAMP') — the gate is not throttling"
fi

# ===========================================================================
# G3 — after the interval elapses → RUNS again; stamp ADVANCES.
# ===========================================================================
# Rewind the stamp to (now - interval - 1) to simulate the interval having
# elapsed, without a real sleep. The gate reads the stamp file, so this is a
# faithful "the interval is up" signal.
NOW="$(date +%s)"
printf '%s\n' "$(( NOW - 31 ))" >"$CADENCE_DIR/context_pressure_scan.ts"
G3_RC=0
bridge_daemon_pass_due context_pressure_scan 30 || G3_RC=$?
G3_STAMP="$(stamp_of context_pressure_scan)"
if (( G3_RC == 0 )) && [[ "$G3_STAMP" =~ ^[0-9]+$ ]] && (( G3_STAMP >= NOW )); then
  _pass "G3 after the interval elapsed → gate RUNS again (rc=0) and the stamp ADVANCES ($G3_STAMP >= $NOW) — fires once per interval"
else
  _fail "G3 interval-elapsed-run" "expected run+advance after the interval (rc=$G3_RC, stamp=$G3_STAMP, now=$NOW)"
fi

# ===========================================================================
# G4 — interval <= 0 / non-numeric → gate DISABLED (always runs every tick).
#      (An UNSET or EMPTY interval is NOT a disable — it falls back to the 30s
#      default; G4b asserts that. Disable is reserved for an EXPLICIT 0 /
#      negative / garbage value so an operator can opt a pass back to every-tick
#      without accidentally disabling it by passing a blank.)
# ===========================================================================
G4_OK=1
for badint in 0 -5 abc; do
  rc=0
  bridge_daemon_pass_due "ungated_${badint}" "$badint" || rc=$?
  # Call twice in a row — a disabled gate runs BOTH times (no throttle).
  rc2=0
  bridge_daemon_pass_due "ungated_${badint}" "$badint" || rc2=$?
  if (( rc != 0 )) || (( rc2 != 0 )); then
    printf '[FAIL] G4: interval "%s" did NOT disable the gate (rc=%s, rc2=%s) — should run every tick\n' "$badint" "$rc" "$rc2" >&2
    G4_OK=0
  fi
done
if (( G4_OK == 1 )); then
  _pass "G4 interval ==0 / negative / non-numeric → gate DISABLED, runs EVERY tick (operator opt-back-to-every-tick)"
else
  _fail "G4 gate-disable" "an explicit 0/negative/non-numeric interval did not disable the gate"
fi

# G4b — an EMPTY interval falls back to the 30s default (NOT disabled): the
# second within-interval call must SKIP. This guards against a blank env var
# silently turning a periodic pass back into an every-tick hot pass.
bridge_daemon_pass_due empty_default_pass "" >/dev/null 2>&1 || true   # fresh → runs
G4B_RC=0
bridge_daemon_pass_due empty_default_pass "" || G4B_RC=$?              # within default → skips
if (( G4B_RC == 1 )); then
  _pass "G4b empty interval falls back to the default cadence (within-interval call SKIPS) — a blank env var does not silently un-gate a periodic pass"
else
  _fail "G4b empty-default" "empty interval did not fall back to a gating default (rc=$G4B_RC) — a blank env would make the pass every-tick"
fi

# ===========================================================================
# G5 — distinct pass keys keep INDEPENDENT stamps.
# ===========================================================================
bridge_daemon_pass_due pass_alpha 30 >/dev/null 2>&1 || true
ALPHA_STAMP="$(stamp_of pass_alpha)"
BETA_RC=0
bridge_daemon_pass_due pass_beta 30 || BETA_RC=$?   # beta is fresh → must run
BETA_STAMP="$(stamp_of pass_beta)"
if [[ "$ALPHA_STAMP" =~ ^[0-9]+$ ]] && (( BETA_RC == 0 )) && [[ "$BETA_STAMP" =~ ^[0-9]+$ ]]; then
  _pass "G5 distinct pass keys keep INDEPENDENT cadence stamps (alpha=$ALPHA_STAMP, beta ran fresh=$BETA_STAMP) — gating one does not gate another"
else
  _fail "G5 independent-keys" "pass keys are not independent (alpha='$ALPHA_STAMP', beta_rc=$BETA_RC, beta='$BETA_STAMP')"
fi

# ===========================================================================
# G6 — key sanitization: a path-metachar pass name cannot escape the dir.
# ===========================================================================
EVIL="../../escape"
bridge_daemon_pass_due "$EVIL" 30 >/dev/null 2>&1 || true
ESCAPED="$SMOKE_DIR/home/escape.ts"
# The sanitized stamp must live UNDER daemon-pass-cadence/, never above it.
SANITIZED_PRESENT=0
if compgen -G "$CADENCE_DIR/*.ts" >/dev/null 2>&1; then SANITIZED_PRESENT=1; fi
if [[ ! -e "$ESCAPED" ]] && (( SANITIZED_PRESENT == 1 )); then
  _pass "G6 key sanitization: a path-traversal pass name stamps UNDER daemon-pass-cadence/ (no '$ESCAPED' written)"
else
  _fail "G6 key-sanitize" "a path-metachar pass name escaped the cadence dir (escaped-file present=$([[ -e "$ESCAPED" ]] && echo yes || echo no))"
fi

# ===========================================================================
# H — STATIC gating discipline inside cmd_sync_cycle (the time-critical-vs-
#     periodic split — a wrongly-gated pass is a latency regression).
# ===========================================================================
# Extract the cmd_sync_cycle body so an occurrence elsewhere in the file cannot
# mask a missing/extra gate.
SYNC_BODY="$(awk '/^cmd_sync_cycle\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DAEMON_SH")"
if [[ -z "$SYNC_BODY" ]]; then
  printf '[FAIL] could not extract cmd_sync_cycle body from %s\n' "$DAEMON_SH" >&2
  exit 1
fi

# H1 — every PERIODIC-EXPENSIVE pass IS gated.
# #2036: the heavy un-gated steps that dominated the ~2-minute serial cycle and
# starved idle re-nudge are now cadence-gated too — bridge_sync (the canonical
# ≤30s site, with the post_sync second full sync REMOVED), l1_roster_reload,
# mcp_orphan_cleanup_early, cron_staging_apply, claude_token_recovery (outer
# throttle), daily_backup (outer gate), and context_pressure_scan (default
# raised 30→60). A revert of any of these gates fails H1.
GATED_PASSES="channel_health plugin_liveness memory_refresh stall_reports unclaimed_queue_escalation unclaimed_marker_sweep nudge_late_success_sweep context_pressure_scan crash_reports bridge_sync l1_roster_reload mcp_orphan_cleanup_early cron_staging_apply claude_token_recovery daily_backup"
H1_FAIL=0
for p in $GATED_PASSES; do
  # Pure-bash block-membership — NOT `printf '%s\n' "$SYNC_BODY" | grep -qE`.
  # `grep -q` closes the pipe on its FIRST match, so `printf` dies with SIGPIPE
  # (141); under this file's `set -o pipefail` the pipeline then returns 141
  # *even though it matched*, racing a false [FAIL]. The large SYNC_BODY loses
  # that race intermittently on Linux (and the failing-pass set varies per run)
  # while macOS pipe timing hid it. The trailing [^A-Za-z0-9_] preserves the
  # `\b` word boundary the grep used. $_gate_re is left UNQUOTED in =~ so it is
  # treated as a regex (the literal space matches the call-site space).
  _gate_re="bridge_daemon_pass_due ${p}[^A-Za-z0-9_]"
  if [[ ! "$SYNC_BODY" =~ $_gate_re ]]; then
    printf '[FAIL] H1: periodic pass "%s" is NOT cadence-gated in cmd_sync_cycle\n' "$p" >&2
    H1_FAIL=1
  fi
done
if (( H1_FAIL == 0 )); then
  _pass "H1 every PERIODIC-EXPENSIVE pass (channel_health/plugin_liveness/memory_refresh/stall_reports/unclaimed_*/nudge_late_success/context_pressure/crash_reports + #2036 bridge_sync/l1_roster_reload/mcp_orphan_cleanup_early/cron_staging_apply/claude_token_recovery/daily_backup) is cadence-gated"
else
  _fail "H1 periodic-gated" "see un-gated periodic pass lines above"
fi

# H2 — TEETH: every TIME-CRITICAL pass is NOT gated. A wrongly-gated delivery /
# escalation pass = a task-delivery / #1563-escalation latency regression.
TIME_CRITICAL_PASSES="queue_gateway attention_flush cron_dispatch_workers a2a_deliver_tick a2a_stuck_scan_tick a2a_receiver_supervise_tick nudge_scan nudge_agents admin_liveness_escalation mcp_liveness_giveup_recovery prompt_ready_reconcile heartbeats discord_relay permission_timeout_fanout queue_summary"
H2_FAIL=0
for p in $TIME_CRITICAL_PASSES; do
  # Pure-bash (see H1): avoid the `printf | grep -q` SIGPIPE-under-pipefail race.
  _gate_re="bridge_daemon_pass_due ${p}[^A-Za-z0-9_]"
  if [[ "$SYNC_BODY" =~ $_gate_re ]]; then
    printf '[FAIL] H2: TIME-CRITICAL pass "%s" was cadence-gated — a delivery/escalation latency regression\n' "$p" >&2
    H2_FAIL=1
  fi
done
if (( H2_FAIL == 0 )); then
  _pass "H2-teeth NO time-critical delivery/escalation pass is gated (queue_gateway/attention_flush/cron_dispatch/a2a_*/nudge_*/admin_liveness/mcp_giveup_recovery/prompt_ready/heartbeats/discord_relay/permission_timeout/queue_summary stay EVERY tick)"
else
  _fail "H2-teeth time-critical-gated" "see wrongly-gated time-critical pass lines above — latency regression"
fi

# H3 — mark-before-due-check: for each gated pass, the PR-2 PARENT-VISIBLE
# heartbeat refresh — _bridge_daemon_mark_progress (which calls
# bridge_daemon_tick_progress_touch, the file the supervisor watches) — must
# appear in the body BEFORE its bridge_daemon_pass_due call, so a tick that
# SKIPS the gated pass still pulses progress and is never a false wedge. NOTE
# (codex PR-7 r1): a bare `BRIDGE_DAEMON_LAST_STEP=` assignment does NOT pulse
# the parent-visible progress file — only _bridge_daemon_mark_progress does —
# so H3 requires the mark_progress form specifically, not the bare LAST_STEP.
# Pure-bash CHARACTER-OFFSET ordering over the body (NO pipe, NO `<<<`
# here-string, NO process-substitution): for each marker we compute the byte
# offset of its FIRST occurrence in SYNC_BODY via `${SYNC_BODY%%marker*}` prefix
# length. Offset ordering is equivalent to line ordering for "appears before".
# Avoids the SIGPIPE/pipefail interaction of `printf | grep` on the large body
# AND the heredoc-ban H3 ratchet that flags `mapfile <<<` / `< <(...)`.
_first_offset() { # $1=marker-substring → first 0-based char offset, or "" if absent
  local _m="$1" _prefix
  [[ "$SYNC_BODY" == *"$_m"* ]] || { printf ''; return 0; }
  _prefix="${SYNC_BODY%%"$_m"*}"
  printf '%s' "${#_prefix}"
}
_due_offset() { # $1=pass → first offset of its `bridge_daemon_pass_due <pass>` site, or ""
  local _p="$1" _marker _prefix
  # The pass token is always followed by a space in the daemon source
  # (`bridge_daemon_pass_due <pass> <interval>`), so anchor on the exact
  # "bridge_daemon_pass_due <pass> " literal — no glob class needed (SC1087-safe).
  _marker="bridge_daemon_pass_due ${_p} "
  [[ "$SYNC_BODY" == *"$_marker"* ]] || { printf ''; return 0; }
  _prefix="${SYNC_BODY%%"$_marker"*}"
  printf '%s' "${#_prefix}"
}
H3_FAIL=0
for p in $GATED_PASSES; do
  mark_line="$(_first_offset "_bridge_daemon_mark_progress \"${p}\"")"
  due_line="$(_due_offset "$p")"
  if [[ -z "$mark_line" || -z "$due_line" ]]; then
    printf '[FAIL] H3: gated pass "%s" missing a _bridge_daemon_mark_progress heartbeat pulse before its due-check (mark=%s due=%s) — a bare LAST_STEP= does NOT refresh the parent-visible progress file\n' "$p" "${mark_line:-?}" "${due_line:-?}" >&2
    H3_FAIL=1
    continue
  fi
  if (( mark_line >= due_line )); then
    printf '[FAIL] H3: pass "%s" mark_progress pulse (offset %s) is NOT before its due-check (offset %s) — a skipped tick would not refresh the PR-2 heartbeat\n' "$p" "$mark_line" "$due_line" >&2
    H3_FAIL=1
  fi
done
if (( H3_FAIL == 0 )); then
  _pass "H3 every gated pass calls _bridge_daemon_mark_progress (the PARENT-VISIBLE PR-2 heartbeat pulse, not a bare LAST_STEP=) BEFORE its due-check — a skipped gated tick still refreshes progress, never a false wedge"
else
  _fail "H3 mark-before-due" "see mark-after-due / missing-pulse lines above"
fi

# H4 — the daemon_tick_slow DIAGNOSTIC row exists (and is NOT an abort).
if [[ "$SYNC_BODY" == *daemon_tick_slow* ]]; then
  _pass "H4 daemon_tick_slow diagnostic audit row is emitted on a budget-exceeding tick (diagnostic only — PR-2 owns the abort)"
else
  _skip "H4 tick-slow-diagnostic" "no daemon_tick_slow row in cmd_sync_cycle (optional defense-in-depth)"
fi

# ===========================================================================
# G7 — #2036 FAIL-OPEN: the gate runs inside the serial daemon cycle under
# `set -euo pipefail`. A damaged cadence stamp or an unwritable cadence dir
# must degrade to "run now" (rc=0) — NEVER abort the daemon, and NEVER
# skip-forever (latch a step off). We exercise the REAL shipped function
# (eval'd above) under the same shell options the daemon runs with.
# ===========================================================================
# Run the fail-open probes under the daemon's strict shell options so a regression
# that aborts under set -e (e.g. a non-numeric `(( ))` operand) is caught here.
( set -euo pipefail
  # G7a — a CORRUPT / non-numeric stamp behaves as last=0 → due now (rc=0),
  # never skip-forever on a damaged stamp.
  mkdir -p "$CADENCE_DIR" 2>/dev/null || true
  printf 'not-a-number\xff\x00garbage\n' >"$CADENCE_DIR/g7_corrupt.ts" 2>/dev/null || true
  rc=0; bridge_daemon_pass_due g7_corrupt 30 || rc=$?
  [[ "$rc" == "0" ]]
) && _pass "G7a corrupt/non-numeric stamp → gate runs NOW (rc=0) under set -e, never skip-forever, never abort" \
  || _fail "G7a corrupt-stamp-fail-open" "a corrupt cadence stamp did not fail-open to run-now (or aborted under set -e)"

# G7a2 — DIGITS-THEN-GARBAGE skip-forever guard (codex #2036 review blocker). A
# naive `tr -dc '0-9'` salvage would turn `999999999999999999garbage` into a
# valid-looking FAR-FUTURE timestamp, and `(( now - last < interval ))` would
# then SKIP on EVERY tick forever. The shipped gate must require the WHOLE stamp
# line to be numeric (not salvage leading digits) AND reject a future stamp, so a
# digits-then-garbage or planted-future stamp behaves as last=0 → run-now.
( set -euo pipefail
  mkdir -p "$CADENCE_DIR" 2>/dev/null || true
  printf '999999999999999999garbage\n' >"$CADENCE_DIR/g7_digitsgarbage.ts" 2>/dev/null || true
  rc=0; bridge_daemon_pass_due g7_digitsgarbage 30 || rc=$?
  [[ "$rc" == "0" ]]
) && _pass "G7a2 digits-then-garbage stamp (999…garbage) → gate runs NOW (rc=0), NOT skip-forever — no tr-salvage into a far-future timestamp (codex #2036 blocker)" \
  || _fail "G7a2 digits-garbage-skip-forever" "a digits-then-garbage stamp was salvaged into a future timestamp and skip-forever'd (rc!=0) — the #2036 fail-open hole regressed"

# G7a3 — a plain FAR-FUTURE numeric stamp (clock skew / planted) must also be
# treated as last=0 → run-now, never skip-forever.
( set -euo pipefail
  mkdir -p "$CADENCE_DIR" 2>/dev/null || true
  printf '%s\n' "$(( $(date +%s) + 999999999 ))" >"$CADENCE_DIR/g7_future.ts" 2>/dev/null || true
  rc=0; bridge_daemon_pass_due g7_future 30 || rc=$?
  [[ "$rc" == "0" ]]
) && _pass "G7a3 far-future numeric stamp → gate runs NOW (rc=0), never skip-forever (clock-skew / planted-future guard)" \
  || _fail "G7a3 future-stamp-skip-forever" "a far-future stamp skip-forever'd (rc!=0) — future stamps must fall back to due-now"

# G7a4 — CONTROL: a VALID recent stamp must STILL throttle (rc=1) within its
# interval — proves the corrupt/future hardening did not make the gate run-now
# unconditionally (which would re-introduce the per-tick heavy-step starvation).
( set -euo pipefail
  mkdir -p "$CADENCE_DIR" 2>/dev/null || true
  printf '%s\n' "$(date +%s)" >"$CADENCE_DIR/g7_validrecent.ts" 2>/dev/null || true
  rc=0; bridge_daemon_pass_due g7_validrecent 3600 || rc=$?
  [[ "$rc" == "1" ]]
) && _pass "G7a4 CONTROL: a valid recent stamp still THROTTLES (rc=1) within interval — the corrupt/future hardening is not over-broad" \
  || _fail "G7a4 valid-stamp-still-throttles" "a valid recent stamp did not throttle (rc!=1) — the fail-open hardening regressed the gate into always-run"

# G7b — an UNREADABLE stamp (mode 000) must not abort and must run-now. (On a
# CI runner as root, chmod 000 is still readable; skip rather than false-pass.)
G7B_FILE="$CADENCE_DIR/g7_unreadable.ts"
mkdir -p "$CADENCE_DIR" 2>/dev/null || true
NOW="$(date +%s)"
printf '%s\n' "$NOW" >"$G7B_FILE" 2>/dev/null || true
chmod 000 "$G7B_FILE" 2>/dev/null || true
if [[ "$(id -u)" != "0" ]] && [[ ! -r "$G7B_FILE" ]]; then
  # The stamp is genuinely unreadable for this UID → exercise the fail-open path.
  # 2>/dev/null on the subshell: the gate's best-effort stamp write legitimately
  # fails here (that IS the path under test); we assert on rc, not on the
  # expected shell redirection-error noise.
  ( set -euo pipefail
    rc=0; bridge_daemon_pass_due g7_unreadable 30 || rc=$?
    [[ "$rc" == "0" ]]
  ) 2>/dev/null && _pass "G7b unreadable stamp (mode 000) → gate runs NOW (rc=0) under set -e, never skip-forever, never abort" \
    || _fail "G7b unreadable-stamp-fail-open" "an unreadable cadence stamp did not fail-open to run-now (or aborted under set -e)"
else
  _skip "G7b unreadable-stamp" "stamp still readable for this UID (root/permissive fs) — cannot exercise the unreadable path"
fi
chmod 644 "$G7B_FILE" 2>/dev/null || true

# G7c — an UNWRITABLE cadence DIR (mkdir/mktemp/write all fail) must STILL
# fail-open to run-now (rc=0) and never abort under set -e. Point the gate at a
# cadence dir whose PARENT is a read-only file so mkdir -p and mktemp both fail.
G7C_ROOT="$SMOKE_DIR/ro-state"
mkdir -p "$G7C_ROOT" 2>/dev/null || true
# Make the daemon-pass-cadence parent un-writable: create it as a regular FILE
# so `mkdir -p .../daemon-pass-cadence` cannot succeed.
printf 'blocker\n' >"$G7C_ROOT/daemon-pass-cadence" 2>/dev/null || true
if [[ -f "$G7C_ROOT/daemon-pass-cadence" ]]; then
  # 2>/dev/null: the gate's mkdir/mktemp/write all fail here by design (the path
  # under test); we assert on rc, not the expected shell redirection-error noise.
  ( set -euo pipefail
    export BRIDGE_STATE_DIR="$G7C_ROOT"
    rc=0; bridge_daemon_pass_due g7_nowrite 30 || rc=$?
    [[ "$rc" == "0" ]]
  ) 2>/dev/null && _pass "G7c unwritable cadence dir (mkdir/mktemp/write all fail) → gate runs NOW (rc=0) under set -e, never skip-forever, never abort" \
    || _fail "G7c unwritable-dir-fail-open" "an unwritable cadence dir did not fail-open to run-now (or aborted under set -e)"
else
  _skip "G7c unwritable-dir" "could not stage a file-as-cadence-dir blocker on this fs"
fi

# ===========================================================================
# H5 — STATIC bridge-sync DEDUPE: there must be exactly ONE raw bridge-sync.sh
# invocation in cmd_sync_cycle (the canonical cadence-gated early site). The
# #2036 fix REMOVED the second `post_sync` full bridge-sync; a revert that
# re-adds a second raw `bridge-sync.sh` call (or any second sync NOT sharing
# the bridge_sync cadence key) is the exact regression that re-bloats the cycle
# and re-starves idle nudge — fail loudly on it.
# ===========================================================================
# Count only EXECUTABLE invocations — exclude comment-only lines (the #2036
# comments mention bridge-sync.sh by name) so the dedupe assertion counts the
# real `bridge-sync.sh` call site(s), not the prose that documents the removal.
RAW_SYNC_COUNT="$(printf '%s\n' "$SYNC_BODY" \
  | grep -E 'bridge-sync\.sh' \
  | grep -vE '^[[:space:]]*#' \
  | grep -c . || true)"
[[ "$RAW_SYNC_COUNT" =~ ^[0-9]+$ ]] || RAW_SYNC_COUNT=0
# Count distinct bridge_sync cadence gates (must be exactly the single early site).
BRIDGE_SYNC_GATE_COUNT="$(printf '%s\n' "$SYNC_BODY" | grep -cE 'bridge_daemon_pass_due bridge_sync\b' || true)"
[[ "$BRIDGE_SYNC_GATE_COUNT" =~ ^[0-9]+$ ]] || BRIDGE_SYNC_GATE_COUNT=0
if (( RAW_SYNC_COUNT == 1 )) && (( BRIDGE_SYNC_GATE_COUNT == 1 )); then
  _pass "H5 bridge-sync DEDUPE: exactly ONE raw bridge-sync.sh invocation, guarded by exactly ONE bridge_sync cadence gate (the post_sync second full sync is removed — no double ≤9s sync per cycle)"
elif (( RAW_SYNC_COUNT > 1 )); then
  _fail "H5 bridge-sync-dedupe" "found $RAW_SYNC_COUNT raw bridge-sync.sh invocations in cmd_sync_cycle (expected 1) — the #2036 post_sync removal regressed; a second un-deduped ~9s sync re-bloats the cycle"
else
  _fail "H5 bridge-sync-dedupe" "raw bridge-sync.sh count=$RAW_SYNC_COUNT, bridge_sync gate count=$BRIDGE_SYNC_GATE_COUNT (expected 1 each) — bridge-sync is no longer the single cadence-gated site"
fi

# ===========================================================================
# Summary.
# ===========================================================================
printf '\n'
if (( FAILS == 0 )); then
  printf '[PASS] 1563-pr7-tick-cadence: %d checks (%d skipped) — periodic cadence gate + time-critical split verified\n' "$TOTAL" "$SKIPS"
  exit 0
fi
printf '[FAIL] 1563-pr7-tick-cadence: %d/%d checks failed\n' "$FAILS" "$TOTAL" >&2
exit 1
