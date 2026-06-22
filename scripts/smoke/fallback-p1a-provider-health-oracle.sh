#!/usr/bin/env bash
# scripts/smoke/fallback-p1a-provider-health-oracle.sh — issue #2066 (v0.17
# Anthropic-outage fallback feature, P1a: the provider-health outage oracle).
#
# Non-vacuous coverage of the DETECTION oracle. All synthetic-probe + DNS calls
# are STUBBED (zero live network, zero quota): the oracle's probe/DNS commands
# are injection seams (BRIDGE_FALLBACK_PROBE_CMD / BRIDGE_FALLBACK_DNS_CMD), so
# the smoke drives the full state machine deterministically with a frozen clock
# (BRIDGE_FALLBACK_CLOCK).
#
# Teeth (the bug each would catch if it regressed):
#   (a) first outage report + probe-outage + DNS-ok -> DOWN-scoped:<agent>
#       (regression: scoped-on-first lost → a low-traffic agent stranded).
#   (b) DNS-FAIL -> stays UP (regression: our-network outage falsely blames
#       Anthropic and strands the whole fleet on the Codex fallback).
#   (c) N-of-M distinct static agents -> DOWN-fleet
#       (regression: quorum lost → a single transient failure trips the fleet).
#   (d) probe-recovery + 2nd confirm -> UP
#       (regression: hysteresis lost → the oracle flaps DOWN/UP on a blip).
#   (e) a 429 / auth failure is NOT outage-class (regression: false DOWN on a
#       quota/auth error).
#   (f) STEADY STATE = ZERO PROBES: with no outage report, the probe-tick fires
#       NO synthetic probe (regression: a steady-state cost is reintroduced —
#       the whole point of "1 prober, N readers, ride real failures").
#   MUTATION — neuter the DNS guard: with the guard bypassed, a host-network
#       outage (DNS fail) FALSELY stamps DOWN. Proves tooth (b) is non-vacuous
#       (the guard is actually load-bearing).
#
# Footgun #11 self-audit: no <<EOF/<<'PY' heredoc-stdin captured into $().
# Stub probe/DNS commands are tiny standalone scripts run by argv.

set -uo pipefail

SMOKE_NAME="fallback-p1a-provider-health-oracle"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd python3

ORACLE="$REPO_ROOT/bridge-provider-health.py"
smoke_assert_file_exists "$ORACLE" "oracle source"
smoke_assert_file_exists "$REPO_ROOT/bridge-usage-probe.py" "usage-probe source (classifier)"
smoke_assert_file_exists "$REPO_ROOT/lib/bridge-provider-health.sh" "shell accessor source"

# The master gate must be ON so the oracle does work in the smoke. (Production
# default is OFF — asserted separately below.)
export BRIDGE_FALLBACK_ENABLED=1
export BRIDGE_FALLBACK_OUTAGE_QUORUM=2
export BRIDGE_FALLBACK_OUTAGE_WINDOW_S=120
export BRIDGE_FALLBACK_RECOVERY_CONFIRMS=2

STATE_FILE="$BRIDGE_STATE_DIR/daemon/provider-health"

# --- stub probe/DNS commands (injection seams) -----------------------------
STUB_DIR="$SMOKE_TMP_ROOT/stubs"
mkdir -p "$STUB_DIR"

PROBE_OK="$STUB_DIR/probe-ok.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PROBE_OK"          # reachable + ok (Anthropic up)
PROBE_OUTAGE="$STUB_DIR/probe-outage.sh"
printf '#!/usr/bin/env bash\necho outage-class\nexit 64\n' >"$PROBE_OUTAGE"  # outage-class
DNS_OK="$STUB_DIR/dns-ok.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$DNS_OK"            # internet ok
DNS_FAIL="$STUB_DIR/dns-fail.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$DNS_FAIL"          # our network down
# A counting probe stub: appends a line every time it is invoked, so a smoke can
# assert the probe fired EXACTLY zero/N times.
PROBE_COUNT="$STUB_DIR/probe-count.sh"
PROBE_CALLS="$SMOKE_TMP_ROOT/probe-calls.log"
printf '#!/usr/bin/env bash\nprintf "call\\n" >> %q\nexit 0\n' "$PROBE_CALLS" >"$PROBE_COUNT"
# Static-agent validation stub (codex d2): only alpha/beta/solo are "static";
# any other name (an invented quorum-padding name) is NOT static.
STATIC_CHECK="$STUB_DIR/static-check.sh"
printf '#!/usr/bin/env bash\ncase "$1" in alpha|beta|solo|agentX|agentY) exit 0;; *) exit 1;; esac\n' >"$STATIC_CHECK"
chmod +x "$PROBE_OK" "$PROBE_OUTAGE" "$DNS_OK" "$DNS_FAIL" "$PROBE_COUNT" "$STATIC_CHECK"
# Bind the fleet quorum to validated static agents for the whole smoke. The
# `{agent}` token is replaced by the reported agent name.
export BRIDGE_FALLBACK_STATIC_CHECK_CMD="$STATIC_CHECK {agent}"

reset_state() { rm -f "$STATE_FILE" 2>/dev/null || true; }

read_state_label() {
  python3 "$ORACLE" read 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])'
}

# ---------------------------------------------------------------------------
# (a) First outage report + probe-outage + DNS-ok -> DOWN-scoped:<agent>
# ---------------------------------------------------------------------------
reset_state
OUT_A="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=1000 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "HTTP 503 service unavailable")"
smoke_assert_contains "$OUT_A" '"action": "enter-down-scoped"' "(a) first failure enters scoped"
LABEL_A="$(read_state_label)"
smoke_assert_eq "DOWN-scoped:alpha" "$LABEL_A" "(a) state is DOWN-scoped for the triggering agent"
smoke_assert_file_exists "$STATE_FILE" "(a) state file written"
smoke_log "(a) PASS — first outage-class report + outage-probe + DNS-ok -> DOWN-scoped:alpha"

# The shell read accessor (N-readers path) must agree without invoking python.
SHELL_LABEL_A="$(env -u BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR bash -c '
  source "'"$REPO_ROOT"'/lib/bridge-provider-health.sh"; bridge_provider_health_state')"
smoke_assert_eq "DOWN-scoped:alpha" "$SHELL_LABEL_A" "(a) shell read accessor agrees with python state"
smoke_log "(a) PASS — shell read accessor reads DOWN-scoped:alpha directly"

# ---------------------------------------------------------------------------
# (b) DNS-FAIL -> stays UP (no false Anthropic blame)
# ---------------------------------------------------------------------------
reset_state
OUT_B="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_FAIL" BRIDGE_FALLBACK_CLOCK=2000 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "HTTP 503 service unavailable")"
smoke_assert_contains "$OUT_B" '"action": "dns-fail-stay-up"' "(b) DNS fail does not blame Anthropic"
LABEL_B="$(read_state_label)"
smoke_assert_eq "UP" "$LABEL_B" "(b) state stays UP when OUR network/DNS is down"
smoke_log "(b) PASS — DNS fail + outage-probe stays UP (our-network outage not blamed on Anthropic)"

# ---------------------------------------------------------------------------
# (c) N-of-M distinct static agents -> DOWN-fleet
# ---------------------------------------------------------------------------
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=3000 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
LABEL_C1="$(read_state_label)"
smoke_assert_eq "DOWN-scoped:alpha" "$LABEL_C1" "(c) first agent enters scoped (not fleet)"
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=3010 \
  python3 "$ORACLE" report-outage --agent beta --source cron --evidence "529 overloaded" >/dev/null
LABEL_C2="$(read_state_label)"
smoke_assert_eq "DOWN-fleet" "$LABEL_C2" "(c) quorum of 2 distinct agents promotes to DOWN-fleet"
smoke_log "(c) PASS — 2 distinct static agents within window -> DOWN-fleet"

# A SECOND report from the SAME agent must NOT reach quorum on its own.
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=3100 \
  python3 "$ORACLE" report-outage --agent solo --source cron --evidence "503" >/dev/null
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=3110 \
  python3 "$ORACLE" report-outage --agent solo --source cron --evidence "503" >/dev/null
LABEL_C3="$(read_state_label)"
smoke_assert_eq "DOWN-scoped:solo" "$LABEL_C3" "(c) same agent twice stays scoped (no false fleet promotion)"
smoke_log "(c) PASS — repeated reports from one agent do not reach the distinct-agent quorum"

# ---------------------------------------------------------------------------
# (d) probe-recovery + 2nd confirm -> UP (hysteresis)
# ---------------------------------------------------------------------------
reset_state
# Enter fleet at clock 4000 (backoff schedule starts at +30 -> next_probe 4030).
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=4000 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=4005 \
  python3 "$ORACLE" report-outage --agent beta --source cron --evidence "503" >/dev/null
smoke_assert_eq "DOWN-fleet" "$(read_state_label)" "(d) precondition: DOWN-fleet"

# Tick BEFORE the backoff window opens (4030): NO probe, NO recovery yet.
OUT_D0="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OK" BRIDGE_FALLBACK_CLOCK=4020 python3 "$ORACLE" probe-tick)"
smoke_assert_contains "$OUT_D0" '"action": "noop-backoff-wait"' "(d) tick before backoff window is a no-op"
smoke_assert_eq "DOWN-fleet" "$(read_state_label)" "(d) still DOWN before backoff window"

# 1st success (after window): recovery pending, NOT yet recovered (hysteresis).
OUT_D1="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OK" BRIDGE_FALLBACK_CLOCK=4040 python3 "$ORACLE" probe-tick)"
smoke_assert_contains "$OUT_D1" '"action": "recovery-pending"' "(d) one probe success does not recover"
smoke_assert_eq "DOWN-fleet" "$(read_state_label)" "(d) still DOWN after a single success (hysteresis holds)"

# 2nd success (after the short re-probe window): recover to UP.
OUT_D2="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OK" BRIDGE_FALLBACK_CLOCK=4080 python3 "$ORACLE" probe-tick)"
smoke_assert_contains "$OUT_D2" '"action": "recovered"' "(d) second confirmation recovers"
smoke_assert_eq "UP" "$(read_state_label)" "(d) state is UP after 2 confirmations"
smoke_log "(d) PASS — recovery requires probe-success + a 2nd confirm (no flap)"

# A still-outage probe mid-recovery must NOT recover.
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=4500 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
OUT_D3="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_CLOCK=4540 python3 "$ORACLE" probe-tick)"
smoke_assert_contains "$OUT_D3" '"action": "still-down"' "(d) an outage-class re-probe stays down"
smoke_assert_match "$(read_state_label)" '^DOWN-' "(d) still DOWN after an outage re-probe"
smoke_log "(d) PASS — an outage-class re-probe keeps the oracle DOWN and advances backoff"

# ---------------------------------------------------------------------------
# (e) a 429 / auth failure is NOT outage-class (no false DOWN)
# ---------------------------------------------------------------------------
# The shared classifier: 503/529/overloaded/econnreset = outage; 401/429/prompt
# = NOT. classify-text exits 0 (outage) / 1 (not).
classify_rc() {
  python3 "$ORACLE" classify-text --text "$1" >/dev/null 2>&1
  printf '%s' "$?"
}
smoke_assert_eq "0" "$(classify_rc 'Error: HTTP 503 Service Unavailable')" "(e) 503 IS outage-class"
smoke_assert_eq "0" "$(classify_rc 'overloaded_error: please retry')" "(e) overloaded_error IS outage-class"
smoke_assert_eq "0" "$(classify_rc 'read ECONNRESET')" "(e) connection reset IS outage-class"
smoke_assert_eq "1" "$(classify_rc '401 Unauthorized: invalid api key')" "(e) 401 is NOT outage-class"
smoke_assert_eq "1" "$(classify_rc '429 too many requests rate_limit_error')" "(e) 429 is NOT outage-class"
smoke_assert_eq "1" "$(classify_rc 'prompt too long: 250000 tokens exceeds limit')" "(e) bad-prompt is NOT outage-class"
smoke_assert_eq "1" "$(classify_rc 'tool finished (timeout 5m budget)')" "(e) tool-budget hint is NOT outage-class"
smoke_log "(e) PASS — 401/429/bad-prompt are NOT classified outage-class (no false DOWN)"

# An auth-failure report path: even if a caller mistakenly reports a 401-text as
# an outage, the synthetic probe (which says Anthropic is reachable+ok) keeps
# the oracle UP — the probe is the authoritative corroboration.
reset_state
OUT_E="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OK" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5000 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "401 unauthorized")"
smoke_assert_contains "$OUT_E" '"action": "probe-ok-stay-up"' "(e) a probe-ok report stays UP"
smoke_assert_eq "UP" "$(read_state_label)" "(e) state stays UP when the synthetic probe says Anthropic is fine"
smoke_log "(e) PASS — a probe-ok corroboration keeps the oracle UP (no false DOWN)"

# ---------------------------------------------------------------------------
# (e2) codex HIGH: an UNCONFIGURED probe is INCONCLUSIVE -> stays UP, NEVER a
# fabricated "Anthropic up". (Pre-fix, an empty probe command read as probe-ok,
# which silently fed a healthy reading; the real correctness teeth is that an
# unconfigured probe can neither enter DOWN nor declare Anthropic fine.)
# ---------------------------------------------------------------------------
reset_state
OUT_E2="$(env -u BRIDGE_FALLBACK_PROBE_CMD BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5200 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503")"
smoke_assert_contains "$OUT_E2" '"outcome": "inconclusive"' "(e2) an unconfigured probe is inconclusive"
smoke_assert_contains "$OUT_E2" '"action": "probe-inconclusive-stay-up"' "(e2) inconclusive stays UP"
smoke_assert_eq "UP" "$(read_state_label)" "(e2) unconfigured probe never enters DOWN"
RES_E2="$(python3 "$ORACLE" read | python3 -c 'import sys,json; print(json.load(sys.stdin)["last_probe_result"])')"
smoke_assert_contains "$RES_E2" "probe-unconfigured" "(e2) the audit reason names the unconfigured probe"
smoke_assert_not_contains "$RES_E2" "probe-ok" "(e2) an unconfigured probe must NOT read as probe-ok"
smoke_log "(e2) PASS — an unconfigured probe is inconclusive (never a fabricated healthy reading)"

# ---------------------------------------------------------------------------
# (e3) codex d2/BLOCKING: FLEET quorum binds to validated STATIC agents — two
# reports under INVENTED distinct names must NOT reach DOWN-fleet.
# ---------------------------------------------------------------------------
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5300 \
  python3 "$ORACLE" report-outage --agent fake-1 --source cron --evidence "503" >/dev/null
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5305 \
  python3 "$ORACLE" report-outage --agent fake-2 --source cron --evidence "503" >/dev/null
LABEL_E3="$(read_state_label)"
case "$LABEL_E3" in
  DOWN-fleet) smoke_fail "(e3) INVENTED names reached fleet quorum — static binding is vacuous (got '$LABEL_E3')" ;;
  *) smoke_log "(e3) PASS — invented distinct names do NOT reach DOWN-fleet (got '$LABEL_E3'; static binding holds)" ;;
esac
# Positive control: two VALIDATED static agents DO reach fleet.
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5320 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5325 \
  python3 "$ORACLE" report-outage --agent beta --source cron --evidence "503" >/dev/null
smoke_assert_eq "DOWN-fleet" "$(read_state_label)" "(e3) two VALIDATED static agents DO reach DOWN-fleet"
smoke_log "(e3) PASS — fleet quorum requires validated static agents (positive control holds)"

# ---------------------------------------------------------------------------
# (e4) codex MEDIUM: FEATURE GATE. A disabled install records nothing and reports
# UP even with a stale DOWN state file.
# ---------------------------------------------------------------------------
reset_state
OUT_E4="$(env -u BRIDGE_FALLBACK_ENABLED BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" \
  BRIDGE_FALLBACK_CLOCK=5400 python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503")"
smoke_assert_contains "$OUT_E4" '"action": "disabled-noop"' "(e4) disabled report is a no-op"
[[ -f "$STATE_FILE" ]] && smoke_fail "(e4) disabled report wrote a state file (must not)"
# Now write a real DOWN state (enabled), then confirm a disabled reader sees UP.
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5410 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
smoke_assert_eq "DOWN-scoped:alpha" "$(read_state_label)" "(e4) precondition: enabled reader sees DOWN"
DISABLED_LABEL="$(env -u BRIDGE_FALLBACK_ENABLED python3 "$ORACLE" read | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])')"
smoke_assert_eq "UP" "$DISABLED_LABEL" "(e4) disabled reader reports UP despite a stale DOWN file"
DISABLED_SHELL="$(env -u BRIDGE_PROVIDER_HEALTH_SCRIPT_DIR -u BRIDGE_FALLBACK_ENABLED bash -c '
  source "'"$REPO_ROOT"'/lib/bridge-provider-health.sh"; bridge_provider_health_state')"
smoke_assert_eq "UP" "$DISABLED_SHELL" "(e4) disabled shell reader reports UP despite a stale DOWN file"
smoke_log "(e4) PASS — feature gate: disabled install records nothing and never drives a DOWN decision"

# ---------------------------------------------------------------------------
# (e5) codex HIGH: CONCURRENT reports are serialized by the state lock — two
# concurrent distinct static reports both land (no last-writer-wins loss).
# ---------------------------------------------------------------------------
reset_state
PROBE_SLOW="$STUB_DIR/probe-slow.sh"
printf '#!/usr/bin/env bash\nsleep 0.3\nexit 64\n' >"$PROBE_SLOW"   # widen the race window
chmod +x "$PROBE_SLOW"
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_SLOW" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5500 \
  python3 "$ORACLE" report-outage --agent agentX --source cron --evidence "503" >/dev/null 2>&1 &
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_SLOW" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5500 \
  python3 "$ORACLE" report-outage --agent agentY --source cron --evidence "503" >/dev/null 2>&1 &
wait
N_REPORTS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reports"]))' "$STATE_FILE" 2>/dev/null || printf 'x')"
smoke_assert_eq "2" "$N_REPORTS" "(e5) both concurrent reports recorded (lock serialized; no lost write)"
smoke_assert_eq "DOWN-fleet" "$(read_state_label)" "(e5) two concurrent distinct static reports promote to fleet"
smoke_log "(e5) PASS — concurrent reports serialized by the state lock (no race-lost evidence)"

# ---------------------------------------------------------------------------
# (e6) codex r2/BLOCKING: the lock must NEVER degrade to UNLOCKED. Two teeth —
#   (i) WITHOUT fcntl (forced None via a shim), concurrent reports still
#       serialize via the portable O_EXCL lock (both land, no lost write).
#   (ii) a FRESH held lock (active holder) FAILS CLOSED — the report does not
#       write unserialized; it returns lock-unavailable.
# ---------------------------------------------------------------------------
reset_state
NOFCNTL="$STUB_DIR/nofcntl-shim.py"
printf '%s\n' \
  'import importlib.util, sys' \
  'spec = importlib.util.spec_from_file_location("ph", sys.argv[1])' \
  'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)' \
  'm.fcntl = None  # force the portable no-fcntl lock path' \
  'sys.exit(m.main(sys.argv[2:]))' \
  >"$NOFCNTL"
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_SLOW" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5600 \
  python3 "$NOFCNTL" "$ORACLE" report-outage --agent agentX --source cron --evidence "503" >/dev/null 2>&1 &
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_SLOW" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5600 \
  python3 "$NOFCNTL" "$ORACLE" report-outage --agent agentY --source cron --evidence "503" >/dev/null 2>&1 &
wait
N6="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reports"]))' "$STATE_FILE" 2>/dev/null || printf 'x')"
smoke_assert_eq "2" "$N6" "(e6) WITHOUT fcntl, concurrent reports still serialize (no unlocked degrade)"
# Lock leaf must be cleaned up after the holders exit.
[[ -e "$STATE_FILE.lock" ]] && smoke_fail "(e6) lock leaf was not cleaned up after release"
smoke_log "(e6) PASS — the portable O_EXCL lock serializes even without fcntl (no unlocked degrade path)"

# (ii) a fresh held lock → fail-closed (bounded spin, then lock-unavailable).
reset_state
# Shorten the spin so the smoke is fast; the production default is 10s.
printf 'held\n' >"$STATE_FILE.lock"   # a fresh regular-file lock = active holder
OUT_E6B="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=5700 \
  BRIDGE_PROVIDER_HEALTH_LOCK_SPIN_TIMEOUT=0 python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" 2>&1)"
smoke_assert_contains "$OUT_E6B" '"action": "lock-unavailable"' "(e6) a held lock fails CLOSED (no unserialized write)"
[[ -f "$STATE_FILE" ]] && smoke_fail "(e6) state was written while a fresh lock was held (must fail closed)"
rm -f "$STATE_FILE.lock"
smoke_log "(e6) PASS — a held lock fails closed; the oracle never writes unserialized state"

# (iii) codex r3/BLOCKING: the STALE-lock steal must be RACE-FREE — a planted
# STALE lock + many concurrent reports must lose NO writes (the atomic-rename
# eviction lets exactly one racer evict, then O_EXCL create picks one holder; no
# two writers ever overlap). Run without fcntl (the worst case) via the shim.
reset_state
mkdir -p "$(dirname "$STATE_FILE")"
printf 'stale\n' >"$STATE_FILE.lock"
# Backdate the lock so it is older than LOCK_STALE_SECONDS (30s).
touch -t 200001010000 "$STATE_FILE.lock" 2>/dev/null || true
N_PROC=12
for i in $(seq 1 "$N_PROC"); do
  BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=$((5800 + i)) \
    python3 "$NOFCNTL" "$ORACLE" report-outage --agent "stale-ag$i" --source cron --evidence "503" >/dev/null 2>&1 &
done
wait
N_STALE="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reports"]))' "$STATE_FILE" 2>/dev/null || printf 'x')"
smoke_assert_eq "$N_PROC" "$N_STALE" "(e6) race-free stale-steal: all $N_PROC concurrent reports landed (no lost write)"
# No graveyard/steal temp files left behind.
LEFTOVER="$(find "$(dirname "$STATE_FILE")" -name 'provider-health.lock.*' 2>/dev/null | wc -l | tr -d ' ')"
smoke_assert_eq "0" "$LEFTOVER" "(e6) no leftover lock graveyard temps after the steal"
smoke_log "(e6) PASS — the stale-lock steal is race-free (no lost writes under concurrent eviction, no fcntl)"

# (iv) codex r4/r5/BLOCKING: a SLOW probe must run UNLOCKED — the lock must NOT
# span the probe subprocess. NON-VACUOUS PROOF (codex r5): assert WALL-CLOCK
# CONCURRENCY. N reporters each run a PROBE_SLEEP-second probe. If the probe ran
# INSIDE the lock, the N reporters would serialize → total elapsed >= N*sleep. If
# the probe runs OUTSIDE the lock (correct), they overlap → total elapsed is well
# under N*sleep (only the sub-ms locked sections serialize). We assert elapsed <
# a CONCURRENCY_CEIL strictly between one probe and the serial sum, so the test
# FAILS if a regression re-wraps the probe in the lock. (We also still assert all
# reports land — no lost write / no eviction.)
reset_state
PROBE_SLEEP=2
N_SLOW=5
# Serial-if-locked lower bound = N_SLOW*PROBE_SLEEP = 10s. Concurrent upper bound
# we allow = 2*PROBE_SLEEP + slack = ~6s — comfortably above one overlapped probe
# wave, comfortably below the 10s serial floor. A locked-probe regression blows
# past this ceiling.
CONCURRENCY_CEIL=6
# Use a slow PROBE_OK (rc 0) so EVERY reporter stays UP and therefore EVERY
# reporter actually RUNS the probe concurrently — the property under test. (A
# slow OUTAGE probe would trip the first reporter into DOWN, after which the
# others short-circuit at the phase-1 DOWN gate WITHOUT probing, so they would
# not exercise the concurrent-probe path and the timing assertion would be
# vacuous — codex r5's exact point.)
SLOW_OK_PROBE="$STUB_DIR/probe-slow-ok.sh"
printf '#!/usr/bin/env bash\nsleep %s\nexit 0\n' "$PROBE_SLEEP" >"$SLOW_OK_PROBE"
chmod +x "$SLOW_OK_PROBE"
SLOW_START="$(date +%s)"
for i in $(seq 1 "$N_SLOW"); do
  BRIDGE_FALLBACK_PROBE_CMD="$SLOW_OK_PROBE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=$((5900 + i)) \
    python3 "$ORACLE" report-outage --agent "slow-ag$i" --source cron --evidence "401" >/dev/null 2>&1 &
done
wait
SLOW_ELAPSED=$(( $(date +%s) - SLOW_START ))
# All stayed UP (PROBE_OK) and all reports landed — no lost write, no eviction.
N_SLOWREP="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["reports"]))' "$STATE_FILE" 2>/dev/null || printf 'x')"
smoke_assert_eq "$N_SLOW" "$N_SLOWREP" "(e6) slow probe runs UNLOCKED: all $N_SLOW concurrent reports landed (no lost write)"
smoke_assert_eq "UP" "$(read_state_label)" "(e6) slow PROBE_OK reporters all stayed UP (each actually probed)"
# NON-VACUOUS timing: N concurrent PROBE_OK probes must OVERLAP (run unlocked).
# If the probe were held under the lock, the N probes would serialize and elapsed
# would be >= N*PROBE_SLEEP; here it must be well under the serial floor.
if (( SLOW_ELAPSED >= CONCURRENCY_CEIL )); then
  smoke_fail "(e6) probes were SERIALIZED: ${N_SLOW}x${PROBE_SLEEP}s probes took ${SLOW_ELAPSED}s (>= ${CONCURRENCY_CEIL}s) — the probe is running INSIDE the lock"
fi
smoke_log "(e6) PASS — ${N_SLOW} concurrent ${PROBE_SLEEP}s probes finished in ${SLOW_ELAPSED}s (< ${CONCURRENCY_CEIL}s; serial floor ${N_SLOW}x${PROBE_SLEEP}=$((N_SLOW*PROBE_SLEEP))s): the probe provably runs UNLOCKED"

# ---------------------------------------------------------------------------
# (f) STEADY STATE = ZERO PROBES
# ---------------------------------------------------------------------------
reset_state
: >"$PROBE_CALLS"
# UP, no reports: a probe-tick must fire NO synthetic probe.
OUT_F="$(BRIDGE_FALLBACK_PROBE_CMD="$PROBE_COUNT" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=6000 \
  python3 "$ORACLE" probe-tick)"
smoke_assert_contains "$OUT_F" '"action": "noop-up"' "(f) probe-tick is a no-op when UP with no reports"
PROBE_N="$(wc -l <"$PROBE_CALLS" 2>/dev/null | tr -d ' ')"
[[ "${PROBE_N:-0}" == "0" ]] || smoke_fail "(f) STEADY-STATE LEAK: probe fired $PROBE_N time(s) with no outage report"
# The cheap daemon gate (should-tick) must also say skip when UP/no-reports.
GATE_F="$(python3 "$ORACLE" should-tick)"
smoke_assert_contains "$GATE_F" '"decision": "skip"' "(f) should-tick says skip when UP with no reports"
smoke_log "(f) PASS — steady state fires ZERO probes (the cheap gate skips)"

# (f2) codex a2/MEDIUM: a stay-UP report (probe-ok / DNS-fail / inconclusive)
# must NOT leave should-tick returning `tick` forever. After the inline confirm,
# the gate goes QUIET — the reports are marked confirmed (last_confirm_ts).
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OK" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=6100 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "401" >/dev/null
smoke_assert_eq "UP" "$(read_state_label)" "(f2) precondition: a probe-ok report stayed UP"
GATE_F2="$(BRIDGE_FALLBACK_CLOCK=6101 python3 "$ORACLE" should-tick)"
smoke_assert_contains "$GATE_F2" '"decision": "skip"' "(f2) should-tick is QUIET after a stay-UP confirm (no busyloop)"
smoke_log "(f2) PASS — a stay-UP confirm returns the daemon to true zero-cost steady state"

# Master gate OFF (production default): should-tick must say skip even WITH a
# pending report, so a production install with the feature off pays nothing.
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=6500 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
GATE_OFF="$(env -u BRIDGE_FALLBACK_ENABLED python3 "$ORACLE" should-tick)"
smoke_assert_contains "$GATE_OFF" '"decision": "skip"' "(f) master gate OFF -> should-tick skips even with a pending report"
smoke_assert_contains "$GATE_OFF" '"reason": "disabled"' "(f) skip reason is the master gate"
smoke_log "(f) PASS — master gate OFF skips the tick entirely (zero production cost)"

# ---------------------------------------------------------------------------
# State-file hardening: mode 0644 + symlink-safe write
# ---------------------------------------------------------------------------
reset_state
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=7000 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null
MODE="$(stat -f '%Lp' "$STATE_FILE" 2>/dev/null || stat -c '%a' "$STATE_FILE" 2>/dev/null)"
smoke_assert_eq "644" "$MODE" "state file is mode 0644 (non-secret observational, iso-readable)"
# Plant a symlink at the leaf; the atomic O_NOFOLLOW replace must NOT follow it.
VICTIM="$SMOKE_TMP_ROOT/victim.txt"
printf 'PRISTINE\n' >"$VICTIM"
rm -f "$STATE_FILE"
ln -s "$VICTIM" "$STATE_FILE"
BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_OK" BRIDGE_FALLBACK_CLOCK=7010 \
  python3 "$ORACLE" report-outage --agent alpha --source cron --evidence "503" >/dev/null 2>&1 || true
VICTIM_CONTENT="$(cat "$VICTIM")"
smoke_assert_eq "PRISTINE" "$VICTIM_CONTENT" "symlink-safe write did not clobber the symlink target"
[[ -L "$STATE_FILE" ]] && smoke_fail "state leaf is still a symlink — the atomic replace did not swap it"
smoke_log "PASS — state file mode 0644 + symlink-safe atomic write (O_NOFOLLOW)"

# ---------------------------------------------------------------------------
# MUTATION — neuter the DNS guard, prove tooth (b) is non-vacuous.
# ---------------------------------------------------------------------------
# Mirror the oracle source, but strip the DNS-fail guard (the early `stay UP`
# branch). With the guard gone, a host-network outage (DNS fail) FALSELY stamps
# DOWN — which the real guard prevents. If the mutated copy does NOT trip DOWN,
# the guard is vacuous (it was not load-bearing) → fail the smoke.
MUTANT="$SMOKE_TMP_ROOT/mutant-oracle.py"
MUTATE_HELPER="$SCRIPT_DIR/fallback-p1a-provider-health-oracle-helper.py"
smoke_assert_file_exists "$MUTATE_HELPER" "mutation helper"
python3 "$MUTATE_HELPER" mutate-dns-guard "$ORACLE" "$MUTANT" \
  || smoke_fail "MUTATION: could not build the DNS-guard mutant (guard shape may have drifted)"
MUT_STATE_DIR="$SMOKE_TMP_ROOT/mut-state"
OUT_MUT="$(BRIDGE_STATE_DIR="$MUT_STATE_DIR" BRIDGE_FALLBACK_PROBE_CMD="$PROBE_OUTAGE" BRIDGE_FALLBACK_DNS_CMD="$DNS_FAIL" \
  BRIDGE_FALLBACK_CLOCK=8000 python3 "$MUTANT" report-outage --agent alpha --source cron --evidence "503")"
MUT_LABEL="$(BRIDGE_STATE_DIR="$MUT_STATE_DIR" python3 "$MUTANT" read 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])')"
case "$MUT_LABEL" in
  DOWN-*)
    smoke_log "MUTATION PASS — with the DNS guard neutered, a DNS-fail FALSELY stamps '$MUT_LABEL' (guard is load-bearing)"
    ;;
  *)
    smoke_fail "MUTATION VACUOUS: neutering the DNS guard did NOT change behavior (got '$MUT_LABEL') — tooth (b) does not actually exercise the guard"
    ;;
esac

smoke_log "ALL PASS — provider-health outage oracle (P1a) detects correctly with zero steady-state cost"
exit 0
