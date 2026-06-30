#!/usr/bin/env bash
#
# scripts/smoke/2207-token-lifeline-out-of-process.sh — Issue #2207 (never-die
# wave Track C) smoke.
#
# Track C folds a bounded out-of-process token-lifeline tick into the OS-
# supervised liveness watcher (scripts/bridge-daemon-liveness.sh) so the token
# lifeline (recover-due quota recovery + periodic token-sync) survives a daemon-
# down window. V1 scope is recover-due + propagation ONLY — NO rotation. The
# watcher is a DRIVER: every credential mutation is delegated to bridge-auth.sh,
# which we replace with a RECORDING SHIM so the smoke can assert WHICH CLI calls
# fire (and in what order) without any real credentials.
#
# This smoke pins the §4 test oracle. Each case is mutation-backed — the brief
# names a one-line mutation that would make the assertion fail, so the smoke is
# non-vacuous:
#
#   T1 — fresh heartbeat ⇒ NO auth calls (recover-due/sync/sync-global absent).
#        Mutation: drop the staleness gate ⇒ this fails.
#   T2 — stale heartbeat, first poll ⇒ recover-due THEN sync (in order).
#        Mutation: drop the sync call ⇒ propagation-survival fails.
#   T3 — no due tokens still runs sync (sync is UNCONDITIONAL — periodic-sync
#        survival). Mutation: gate sync on sync_recommended ⇒ this fails.
#   T4 — active token recovered ⇒ sync writes (recover→propagate pairing).
#   T5 — global opt-in DISABLED ⇒ sync-global SKIPPED; ENABLED ⇒ sync-global
#        CALLED (the `global-auth-sync status --check` gate). Both directions.
#   T6 — registry-lock contention / CLI failure ⇒ bounded + audited (no hang,
#        attempt recorded, no hot-loop — the interval state file is written).
#   T7 — DRY_RUN=1 ⇒ would-run audit emitted, NO mutation (no real auth call).
#   T8 — rotation commands ABSENT (assert `claude-token rotate` is never
#        invoked — the v1-scope guard). Mutation: add a rotate call ⇒ this fails.
#   T9 — interval throttle: a stale host runs the lifeline at most once per
#        _INTERVAL_SECONDS (second poll within the interval is a no-op; after the
#        interval it runs again). Mutation: drop the state-file throttle ⇒ runs
#        every poll ⇒ fails.
#
# All runs use an isolated BRIDGE_HOME and never touch live runtime. The shim is
# written with printf (footgun #11: no heredoc-stdin into any subprocess).

set -euo pipefail

SMOKE_NAME="2207-token-lifeline-out-of-process"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd awk

LIVENESS_SRC="$SMOKE_REPO_ROOT/scripts/bridge-daemon-liveness.sh"
[[ -f "$LIVENESS_SRC" ]] || smoke_fail "source not found: $LIVENESS_SRC"

smoke_setup_bridge_home "$SMOKE_NAME"

# ---------------------------------------------------------------------------
# Recording bridge-auth.sh shim. Logs every invocation (one `cmd:` line per
# call with the full argv) to $AUTH_LOG so a test can assert which CLI verbs
# fired and in what order. Behavior knobs (read from the environment so each
# case can flip them without rewriting the shim):
#   AUTH_GLOBAL_CHECK_RC  — exit code for `global-auth-sync status --check`
#                           (0 = opt-in enabled → sync-global proceeds; non-0 =
#                           disabled → caller skips sync-global). Default 1.
#   AUTH_RECOVER_RC       — exit code for `recover-due` (default 0).
#   AUTH_SYNC_RC          — exit code for `sync` (default 0).
# ---------------------------------------------------------------------------
STUB_DIR="$SMOKE_TMP_ROOT/stub"
mkdir -p "$STUB_DIR"
AUTH_SHIM="$STUB_DIR/bridge-auth.sh"
AUTH_LOG="$SMOKE_TMP_ROOT/auth.log"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "cmd: %%s\\n" "$*" >>"%s"\n' "$AUTH_LOG"
  # Dispatch on the trailing verb shape so we can return per-verb rc / gate.
  printf 'case "$*" in\n'
  printf '  *"global-auth-sync status --check"*) exit "${AUTH_GLOBAL_CHECK_RC:-1}" ;;\n'
  printf '  *"recover-due"*) exit "${AUTH_RECOVER_RC:-0}" ;;\n'
  printf '  *"sync-global"*) exit "${AUTH_SYNC_GLOBAL_RC:-0}" ;;\n'
  printf '  *"claude-token sync "*|*"claude-token sync") exit "${AUTH_SYNC_RC:-0}" ;;\n'
  printf 'esac\n'
  printf 'exit 0\n'
} >"$AUTH_SHIM"
chmod +x "$AUTH_SHIM"

# Per-case state dir + a live-looking pid file (our own pid is alive).
LIFE_STATE_DIR=""
life_setup() {
  LIFE_STATE_DIR="$SMOKE_TMP_ROOT/life-state"
  rm -rf "$LIFE_STATE_DIR"
  mkdir -p "$LIFE_STATE_DIR"
  printf '%s\n' "$$" >"$LIFE_STATE_DIR/daemon.pid"
  : >"$AUTH_LOG"
}

# Run the REAL watcher with the auth shim wired in. $1 = heartbeat age seconds
# (0 = fresh, >threshold = stale). Extra env (AUTH_*_RC / DRY_RUN / interval) is
# passed through the caller's environment. The gateway status command is a fixed
# idle stub so the gateway-stall path never interferes with the heartbeat verdict.
# Back-date a heartbeat file to `now - hb_age` seconds, PORTABLY across BSD/mac
# and GNU/Linux. $1 = file, $2 = age seconds. The watcher reads the file's MTIME
# (via `stat`), so the heartbeat is only "stale" if the mtime actually moves back.
#
# Portability trap (the T12 Linux-red root cause): `date -r N` means two different
# things — BSD/mac: "interpret epoch N"; GNU/Linux: "use the mtime of FILE named
# N" (which fails for an integer). So we must try GNU `touch -d @epoch` (and
# `date -d @epoch` for the BSD `touch -t` stamp) explicitly, not via `date -r`.
# We then ASSERT the mtime took within tolerance — a silently-failed back-date
# would otherwise leave a FRESH heartbeat and make a "stale" case wrongly pass as
# fresh (exactly what made T12 green on mac, red on Linux).
set_heartbeat_mtime() {
  local hb_file="$1" hb_age="$2"
  local now mtime got
  now="$(date +%s)"
  mtime=$(( now - hb_age ))
  printf '%s\n' "$mtime" >"$hb_file"
  # GNU coreutils touch: -d @EPOCH. Try it first (Linux/CI path).
  if ! touch -d "@$mtime" "$hb_file" 2>/dev/null; then
    # BSD/mac touch: -t [[CC]YY]MMDDhhmm[.SS] from a BSD `date -r EPOCH`.
    touch -t "$(date -r "$mtime" +%Y%m%d%H%M.%S 2>/dev/null)" "$hb_file" 2>/dev/null || true
  fi
  # Verify the back-date actually took (within 5s) — fail loudly otherwise so a
  # platform where neither form works can never masquerade a fresh heartbeat as
  # stale (or vice-versa).
  # Read the mtime back PORTABLY. GNU coreutils: `stat -c %Y`; BSD/mac: `stat -f %m`.
  # (Order matters: `stat -f` on GNU means "filesystem status" and prints garbage,
  # so we MUST try the platform-correct form and sanitize the result to digits.)
  got="$(stat -c %Y "$hb_file" 2>/dev/null || stat -f %m "$hb_file" 2>/dev/null || true)"
  got="${got//[^0-9]/}"; [[ -n "$got" ]] || got=0
  local delta=$(( got - mtime )); (( delta < 0 )) && delta=$(( -delta ))
  (( delta <= 5 )) || smoke_fail "set_heartbeat_mtime: could not back-date $hb_file to age=${hb_age}s (wanted mtime=$mtime, got=$got) — heartbeat staleness would be wrong on this platform"
}

life_run() {
  local hb_age="$1"; shift || true
  local hb_file="$LIFE_STATE_DIR/daemon.heartbeat"
  # Deliberate test-fixture filename (the #1973 recovery-marker path the watcher
  # writes on a restart); not a real iso-helper boundary callsite.
  local renudge_file="$LIFE_STATE_DIR/recovery.env"  # noqa: iso-helper-boundary
  set_heartbeat_mtime "$hb_file" "$hb_age"
  env \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$LIFE_STATE_DIR" \
    BRIDGE_AUDIT_LOG="$LIFE_STATE_DIR/audit.jsonl" \
    BRIDGE_DAEMON_HEARTBEAT_FILE="$hb_file" \
    BRIDGE_DAEMON_PID_FILE="$LIFE_STATE_DIR/daemon.pid" \
    BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=600 \
    BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=0 \
    BRIDGE_DAEMON_GATEWAY_STALL_DISABLE="${BRIDGE_DAEMON_GATEWAY_STALL_DISABLE:-1}" \
    BRIDGE_DAEMON_GATEWAY_STALL_SECONDS="${BRIDGE_DAEMON_GATEWAY_STALL_SECONDS:-300}" \
    BRIDGE_DAEMON_GATEWAY_STATUS_CMD="${BRIDGE_DAEMON_GATEWAY_STATUS_CMD:-}" \
    BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE="$LIFE_STATE_DIR/gateway-stall.ts" \
    BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE="$renudge_file" \
    BRIDGE_DAEMON_LIVENESS_DRY_RUN="${BRIDGE_DAEMON_LIVENESS_DRY_RUN:-1}" \
    BRIDGE_AUTH_SH="$AUTH_SHIM" \
    BRIDGE_BASH_BIN="bash" \
    BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE="$LIFE_STATE_DIR/token-lifeline.ts" \
    BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS="${BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS:-300}" \
    "$@" \
    bash "$LIVENESS_SRC" >"$LIFE_STATE_DIR/liveness.out" 2>&1 || true
}

# Count how many times a verb appears in the auth shim log. We match on the
# distinctive trailing shape so `sync` does not also match `sync-global`.
# NOTE: `grep -c` prints 0 AND exits 1 on zero matches — capture into a var so a
# `|| printf 0` fallback cannot double-print "0\n0".
auth_count() {
  local pat="$1" n
  [[ -f "$AUTH_LOG" ]] || { printf '0'; return; }
  n="$(grep -c -- "$pat" "$AUTH_LOG" 2>/dev/null)" || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# The order index (1-based line number) of the FIRST match, or 0 if absent.
auth_first_line() {
  local pat="$1"
  [[ -f "$AUTH_LOG" ]] || { printf '0'; return; }
  local n
  n="$(grep -n -- "$pat" "$AUTH_LOG" 2>/dev/null | head -n1 | cut -d: -f1)"
  printf '%s' "${n:-0}"
}

# ===========================================================================
# T1 — fresh heartbeat ⇒ NO auth calls
# ===========================================================================
step_t1_fresh_no_calls() {
  smoke_log "T1: fresh heartbeat → NO token-lifeline auth calls"
  life_setup
  # DRY_RUN=0 so the shim IS invoked when the lifeline runs — otherwise the auth
  # log is empty regardless and the assertion could not catch a staleness-gate
  # regression (the lifeline firing on a fresh heartbeat).
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 0   # fresh (< 600 threshold)
  [[ "$(auth_count 'recover-due')" == "0" ]] \
    || smoke_fail "T1: recover-due ran on a FRESH heartbeat (staleness gate broken)"
  [[ "$(auth_count 'claude-token sync ')" == "0" ]] \
    || smoke_fail "T1: sync ran on a FRESH heartbeat (staleness gate broken)"
  [[ "$(auth_count 'sync-global')" == "0" ]] \
    || smoke_fail "T1: sync-global ran on a FRESH heartbeat (staleness gate broken)"
  smoke_log "T1: OK — daemon owns recovery while fresh"
}

# ===========================================================================
# T2 — stale heartbeat, first poll ⇒ recover-due THEN sync (in order)
# ===========================================================================
step_t2_stale_recover_then_sync() {
  smoke_log "T2: stale heartbeat → recover-due THEN sync (ordered)"
  life_setup
  # DRY_RUN=0 so the shim is actually invoked.
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "1" ]] \
    || smoke_fail "T2: recover-due did not run exactly once on a stale heartbeat (log: $(cat "$AUTH_LOG"))"
  [[ "$(auth_count 'claude-token sync ')" == "1" ]] \
    || smoke_fail "T2: sync did not run on a stale heartbeat (propagation pair incomplete; log: $(cat "$AUTH_LOG"))"
  local r s
  r="$(auth_first_line 'recover-due')"
  s="$(auth_first_line 'claude-token sync ')"
  (( r > 0 && s > 0 && r < s )) \
    || smoke_fail "T2: recover-due must run BEFORE sync (recover line=$r sync line=$s)"
  smoke_log "T2: OK — recover→sync pair completed in order"
}

# ===========================================================================
# T3 — no due tokens still runs sync (UNCONDITIONAL periodic-sync survival)
# ===========================================================================
step_t3_no_due_still_syncs() {
  smoke_log "T3: recover-due reports nothing due → sync STILL runs (unconditional)"
  life_setup
  # recover-due rc=0 (succeeds, no due tokens). sync MUST still fire — it is the
  # daemon's periodic-sync replacement, not conditional on a recovery happening.
  AUTH_RECOVER_RC=0 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'claude-token sync ')" == "1" ]] \
    || smoke_fail "T3: sync did NOT run when no tokens were due — it must be UNCONDITIONAL (log: $(cat "$AUTH_LOG"))"
  smoke_log "T3: OK — sync is unconditional"
}

# ===========================================================================
# T4 — active token recovered ⇒ sync writes (recover→propagate pairing)
# ===========================================================================
step_t4_recovered_syncs() {
  smoke_log "T4: recover-due succeeds (token recovered) → sync writes"
  life_setup
  AUTH_RECOVER_RC=0 AUTH_SYNC_RC=0 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "1" && "$(auth_count 'claude-token sync ')" == "1" ]] \
    || smoke_fail "T4: recover→sync pairing did not both fire (log: $(cat "$AUTH_LOG"))"
  smoke_log "T4: OK — recovered token is propagated by the paired sync"
}

# ===========================================================================
# T5 — global opt-in gate (DISABLED ⇒ skip; ENABLED ⇒ call)
# ===========================================================================
step_t5_global_gate_both_directions() {
  smoke_log "T5: global opt-in DISABLED → sync-global SKIPPED"
  life_setup
  # `global-auth-sync status --check` exits non-zero (opt-in OFF) → no sync-global.
  AUTH_GLOBAL_CHECK_RC=1 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'global-auth-sync status --check')" == "1" ]] \
    || smoke_fail "T5a: the opt-in gate probe must always run on a stale tick (log: $(cat "$AUTH_LOG"))"
  [[ "$(auth_count 'sync-global')" == "0" ]] \
    || smoke_fail "T5a: sync-global ran while the opt-in gate was DISABLED (gate broken; log: $(cat "$AUTH_LOG"))"

  smoke_log "T5: global opt-in ENABLED → sync-global CALLED"
  life_setup
  # gate exits 0 (opt-in ON) → sync-global proceeds.
  AUTH_GLOBAL_CHECK_RC=0 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'sync-global')" == "1" ]] \
    || smoke_fail "T5b: sync-global did NOT run while the opt-in gate was ENABLED (log: $(cat "$AUTH_LOG"))"
  smoke_log "T5: OK — global gate honored in both directions"
}

# ===========================================================================
# T6 — CLI failure ⇒ bounded + audited, attempt recorded (no hot-loop)
# ===========================================================================
step_t6_failure_bounded_audited() {
  smoke_log "T6: recover-due/sync FAIL → bounded, audited, attempt recorded (no hot-loop)"
  life_setup
  # Both recover-due AND sync fail (simulate registry-lock contention / auth err).
  AUTH_RECOVER_RC=1 AUTH_SYNC_RC=1 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  # The audit row must capture the failure status for each phase.
  grep -q 'daemon_liveness_token_lifeline' "$LIFE_STATE_DIR/audit.jsonl" \
    || smoke_fail "T6: no token-lifeline audit row written on failure (audit: $(cat "$LIFE_STATE_DIR/audit.jsonl" 2>/dev/null))"
  grep -q 'recover_due.*failed' "$LIFE_STATE_DIR/audit.jsonl" \
    || smoke_fail "T6: failed recover-due not reflected in the audit row"
  grep -q 'sync.*failed' "$LIFE_STATE_DIR/audit.jsonl" \
    || smoke_fail "T6: failed sync not reflected in the audit row"
  # The attempt-state file must be recorded EVEN ON FAILURE so a persistent error
  # does not hot-loop the lifeline every 60s poll.
  [[ -f "$LIFE_STATE_DIR/token-lifeline.ts" ]] \
    || smoke_fail "T6: attempt state file not written on failure — would hot-loop every poll"
  smoke_log "T6: OK — failure is bounded + audited + throttled"
}

# ===========================================================================
# T7 — DRY_RUN=1 ⇒ would-run audit, NO real auth call
# ===========================================================================
step_t7_dry_run_no_mutation() {
  smoke_log "T7: DRY_RUN=1 → would-run audit, NO real auth call"
  life_setup
  local state_file="$LIFE_STATE_DIR/token-lifeline.ts"
  # HERMETIC (codex r3 hypothesis B): explicitly clear the throttle state file so
  # the ONLY possible writer before the real tick below is the DRY_RUN tick
  # itself — no prior case's timestamp can leak in and throttle the real tick.
  rm -f "$state_file"
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 life_run 900
  # No shim invocation at all under DRY_RUN.
  if [[ -s "$AUTH_LOG" ]]; then
    smoke_fail "T7: DRY_RUN still invoked bridge-auth.sh (log: $(cat "$AUTH_LOG"))"
  fi
  grep -q 'daemon_liveness_token_lifeline' "$LIFE_STATE_DIR/audit.jsonl" \
    || smoke_fail "T7: DRY_RUN did not emit the would-run audit row"
  grep -q 'dry_run.*1' "$LIFE_STATE_DIR/audit.jsonl" \
    || smoke_fail "T7: DRY_RUN audit row missing the dry_run=1 marker"
  grep -q 'DRY_RUN .*token lifeline' "$LIFE_STATE_DIR/liveness.out" \
    || smoke_fail "T7: DRY_RUN did not log the would-run line"
  # codex r2 finding 3: DRY_RUN must mutate NOTHING — the throttle state file must
  # NOT be written, or a DRY_RUN tick would suppress the next REAL stale tick.
  if [[ -e "$state_file" ]]; then
    smoke_fail "T7: DRY_RUN wrote the throttle state file token-lifeline.ts — it would suppress the next real tick (codex r2 finding 3) [$(ls -la "$state_file" 2>&1)]"
  fi
  # CI-visible diagnostics (codex r3): record the throttle-witness state + the
  # watcher output right before the real tick so a CI failure shows WHETHER the
  # throttle came from the DRY_RUN tick or a leak. Logged unconditionally.
  smoke_log "T7 diag: pre-real-tick state_file=$([[ -e "$state_file" ]] && printf 'EXISTS[%s]' "$(ls -la "$state_file" 2>&1)" || printf ABSENT) now=$(date +%s)"
  # And prove it does NOT suppress a subsequent REAL tick: a real run right after
  # the DRY_RUN must actually invoke the auth shim (throttle was never armed).
  : >"$AUTH_LOG"   # isolate the real-tick auth calls from the (empty) DRY_RUN log
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  if [[ "$(auth_count 'recover-due')" != "1" ]]; then
    smoke_log "T7 diag FAIL-CTX: state_file=$([[ -e "$state_file" ]] && printf 'EXISTS[%s]' "$(cat "$state_file" 2>&1)" || printf ABSENT) auth_log=[$(cat "$AUTH_LOG")] liveness_out=[$(cat "$LIFE_STATE_DIR/liveness.out")]"
    smoke_fail "T7: a real tick after a DRY_RUN was throttled — DRY_RUN must not arm the throttle (recover-due count=$(auth_count 'recover-due'))"
  fi
  smoke_log "T7: OK — DRY_RUN audits but mutates nothing (state file absent; real tick not suppressed)"
}

# ===========================================================================
# T8 — rotation commands ABSENT (v1-scope guard)
# ===========================================================================
step_t8_no_rotation() {
  smoke_log "T8: rotation commands NEVER invoked (v1-scope guard)"
  life_setup
  AUTH_GLOBAL_CHECK_RC=0 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  if grep -q 'claude-token rotate' "$AUTH_LOG" 2>/dev/null; then
    smoke_fail "T8: the lifeline invoked claude-token rotate — V1 forbids rotation (log: $(cat "$AUTH_LOG"))"
  fi
  # Also assert the watcher SOURCE carries no rotate call (defense beyond runtime).
  if grep -q 'claude-token rotate' "$LIVENESS_SRC"; then
    smoke_fail "T8: bridge-daemon-liveness.sh source references claude-token rotate (v1-scope guard)"
  fi
  smoke_log "T8: OK — no rotation in v1"
}

# ===========================================================================
# T9 — interval throttle: at most once per _INTERVAL_SECONDS
# ===========================================================================
step_t9_interval_throttle() {
  smoke_log "T9: stale host runs the lifeline at most once per interval"
  life_setup
  # A LARGE interval so the second poll (immediately after) is throttled.
  BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS=3600 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "1" ]] \
    || smoke_fail "T9: first stale poll did not run the lifeline once (log: $(cat "$AUTH_LOG"))"
  # Second poll within the interval — must be a no-op (state file throttles it).
  BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS=3600 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "1" ]] \
    || smoke_fail "T9: second poll within the interval re-ran the lifeline (throttle broken; log: $(cat "$AUTH_LOG"))"

  # After the interval elapses (force the state file back beyond the interval),
  # it runs AGAIN — proving the throttle is an interval gate, not a permanent latch.
  local past
  past=$(( $(date +%s) - 7200 ))
  printf '%s\n' "$past" >"$LIFE_STATE_DIR/token-lifeline.ts"
  BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS=3600 BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "2" ]] \
    || smoke_fail "T9: lifeline did not re-run after the interval elapsed (interval is a latch, not a throttle; log: $(cat "$AUTH_LOG"))"
  smoke_log "T9: OK — one run per interval, re-runs after it elapses"
}

# A gateway-status stub that reports an OLD pending request (oldest age $1s) so
# the gateway-stall path trips when the daemon pid is alive across two polls.
gw_status_cmd() {
  local oldest="$1"
  printf 'printf %s' "'{\"pending\": 1, \"working\": 0, \"oldest_pending_age\": ${oldest}, \"oldest_working_age\": 0}'"
}

# ===========================================================================
# T10 — stale heartbeat + gateway-stall restart ⇒ token lifeline STILL runs
# ===========================================================================
# codex review #2207: maybe_restart_on_gateway_stall runs in main() BEFORE the
# heartbeat verdict and returns "handled" (main returns) even when the restart is
# refused/failed. A lifeline call placed AFTER it would be skipped on exactly the
# stale+gateway-stall window — when the daemon is NOT recovering tokens. The
# lifeline must therefore fire BEFORE the gateway-stall early-return. We drive a
# STALE heartbeat with old gateway requests across two polls (so the second poll
# triggers a gateway-stall restart) and assert the token lifeline still ran.
step_t10_stale_plus_gateway_stall() {
  smoke_log "T10: stale heartbeat + gateway-stall restart → token lifeline STILL runs (codex #2207)"
  life_setup
  local cmd
  cmd="$(gw_status_cmd 900)"   # oldest pending age 900s >> 300 stall threshold
  # DRY_RUN=0 so the auth shim records real calls. The daemon restart itself is
  # routed through bridge-daemon.sh restart; under this isolated BRIDGE_HOME it
  # will fail/refuse — which is precisely the "handled but restart did not take"
  # window the lifeline must survive.
  # Poll 1: first gateway observation (cross-poll witness) — no restart yet, but
  # the heartbeat is STALE so the lifeline must already fire here.
  BRIDGE_DAEMON_GATEWAY_STALL_DISABLE=0 BRIDGE_DAEMON_GATEWAY_STATUS_CMD="$cmd" \
    BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "1" && "$(auth_count 'claude-token sync ')" == "1" ]] \
    || smoke_fail "T10: lifeline did not run on poll 1 of a stale heartbeat with a gateway stall (log: $(cat "$AUTH_LOG"))"
  # Force the interval state file back so poll 2 is NOT throttled (we want to
  # prove the lifeline runs on the SAME poll the gateway-stall restart is handled).
  printf '%s\n' "$(( $(date +%s) - 7200 ))" >"$LIFE_STATE_DIR/token-lifeline.ts"
  # Poll 2: same old request → gateway-stall path fires a restart (refused/failed
  # under the isolated home) and returns "handled". The lifeline must have ALSO
  # run BEFORE that early-return.
  BRIDGE_DAEMON_GATEWAY_STALL_DISABLE=0 BRIDGE_DAEMON_GATEWAY_STATUS_CMD="$cmd" \
    BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  [[ "$(auth_count 'recover-due')" == "2" && "$(auth_count 'claude-token sync ')" == "2" ]] \
    || smoke_fail "T10: lifeline was SKIPPED on the stale+gateway-stall restart poll — it must run before the gateway-stall early-return (log: $(cat "$AUTH_LOG"))"
  smoke_log "T10: OK — lifeline runs before the gateway-stall early-return"
}

# ===========================================================================
# T11 — recover-due flag fidelity (--timeout / --retry-seconds from the envs)
# ===========================================================================
# codex r2 finding 1: the emergency tick's recover-due MUST carry the same
# --timeout/--retry-seconds the daemon passes (resolved from
# BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS / _CHECK_RETRY_SECONDS), or those
# overrides silently diverge while the daemon is down. We set both envs to
# non-default sentinels and assert the recorded recover-due argv carries them.
step_t11_recover_due_flag_fidelity() {
  smoke_log "T11: recover-due carries --timeout/--retry-seconds from the daemon's envs"
  life_setup
  BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS=37 \
  BRIDGE_CLAUDE_TOKEN_CHECK_RETRY_SECONDS=2400 \
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 life_run 900
  # The shim logs the full argv on a `cmd:` line; assert the recover-due line has
  # both flags with the sentinel values.
  grep -q 'recover-due .*--timeout 37' "$AUTH_LOG" \
    || smoke_fail "T11: recover-due is MISSING --timeout 37 from BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS (log: $(cat "$AUTH_LOG"))"
  grep -q 'recover-due .*--retry-seconds 2400' "$AUTH_LOG" \
    || smoke_fail "T11: recover-due is MISSING --retry-seconds 2400 from BRIDGE_CLAUDE_TOKEN_CHECK_RETRY_SECONDS (log: $(cat "$AUTH_LOG"))"
  smoke_log "T11: OK — recover-due flag fidelity matches the daemon"
}

# ===========================================================================
# T12 — bounded fail-closed when no timeout tool is on PATH
# ===========================================================================
# codex r2 finding 2: stock macOS ships NO timeout/gtimeout. The bounded-timeout
# helper must NOT exec unbounded — it must use a portable bound (perl) or, if even
# that is absent, FAIL CLOSED (skip the auth call, audit the phase as failed). We
# drive the watcher with a PATH that has NEITHER timeout/gtimeout NOR perl AND a
# SLOW auth shim (sleep 30); the tick must return promptly (bounded) and audit the
# phases as failed — never hang on the unbounded exec.
step_t12_bounded_fail_closed() {
  smoke_log "T12: no timeout tool + no perl → bounded fail-closed, NOT an unbounded exec"
  life_setup
  # A slow auth shim: every call sleeps 30s. If the helper ran it UNBOUNDED the
  # watcher would hang ~30s+; bounded fail-closed returns immediately.
  local slow_shim="$STUB_DIR/bridge-auth-slow.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "cmd: %%s\\n" "$*" >>"%s"\n' "$AUTH_LOG"
    printf 'sleep 30\n'
    printf 'exit 0\n'
  } >"$slow_shim"
  chmod +x "$slow_shim"
  # A minimal PATH that excludes timeout/gtimeout AND perl but keeps bash + the
  # coreutils the watcher needs (date/stat/etc come from /usr/bin and /bin).
  local minbin="$SMOKE_TMP_ROOT/minbin"
  rm -rf "$minbin"; mkdir -p "$minbin"
  local c src
  for c in bash sh env date stat tr head cut grep sed mkdir dirname printf cat rm sleep python3 command; do
    src="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "$minbin/$c" 2>/dev/null || true
  done
  # Sanity: neither timeout/gtimeout nor perl resolvable under this PATH.
  if PATH="$minbin" command -v timeout >/dev/null 2>&1 || PATH="$minbin" command -v gtimeout >/dev/null 2>&1; then
    smoke_skip "T12 setup: could not strip timeout/gtimeout from the test PATH" && return 0
  fi
  if PATH="$minbin" command -v perl >/dev/null 2>&1; then
    smoke_skip "T12 setup: could not strip perl from the test PATH" && return 0
  fi
  local hb_file="$LIFE_STATE_DIR/daemon.heartbeat"
  local start end
  # Use the PORTABLE back-dater (the inline `date -r` form here was the Linux-red
  # root cause: on GNU it stat'd a file named by the epoch, failed, and left the
  # heartbeat FRESH → main() returned daemon_liveness_ok and the lifeline never
  # ran → no fail-closed audit). set_heartbeat_mtime verifies the mtime took.
  set_heartbeat_mtime "$hb_file" 900
  start="$(date +%s)"
  PATH="$minbin" env \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$LIFE_STATE_DIR" \
    BRIDGE_AUDIT_LOG="$LIFE_STATE_DIR/audit.jsonl" \
    BRIDGE_DAEMON_HEARTBEAT_FILE="$hb_file" \
    BRIDGE_DAEMON_PID_FILE="$LIFE_STATE_DIR/daemon.pid" \
    BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=600 \
    BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=0 \
    BRIDGE_DAEMON_GATEWAY_STALL_DISABLE=1 \
    BRIDGE_DAEMON_LIVENESS_DRY_RUN=0 \
    BRIDGE_AUTH_SH="$slow_shim" \
    BRIDGE_BASH_BIN="bash" \
    BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE="$LIFE_STATE_DIR/token-lifeline.ts" \
    BRIDGE_DAEMON_TOKEN_LIFELINE_TIMEOUT_SECONDS=2 \
    bash "$LIVENESS_SRC" >"$LIFE_STATE_DIR/liveness.out" 2>&1 || true
  end="$(date +%s)"
  # Bounded: the whole tick (3 sleeping phases, each fail-closed at rc=124) must
  # finish WELL under the 30s-per-call unbounded floor. Allow generous slack.
  if (( end - start >= 25 )); then
    smoke_fail "T12: the tick ran UNBOUNDED ($(( end - start ))s) — the slow auth call was not bounded/fail-closed"
  fi
  # The audit row must mark the phases failed (fail-closed), not ok.
  grep -q 'recover_due.*failed' "$LIFE_STATE_DIR/audit.jsonl" \
    || smoke_fail "T12: fail-closed recover-due was not audited as failed (audit: $(cat "$LIFE_STATE_DIR/audit.jsonl" 2>/dev/null))"
  smoke_log "T12: OK — no-timeout-tool path is bounded + fail-closed (elapsed $(( end - start ))s)"
}

# ---------------------------------------------------------------------------
main() {
  step_t1_fresh_no_calls
  step_t2_stale_recover_then_sync
  step_t3_no_due_still_syncs
  step_t4_recovered_syncs
  step_t5_global_gate_both_directions
  step_t6_failure_bounded_audited
  step_t7_dry_run_no_mutation
  step_t8_no_rotation
  step_t9_interval_throttle
  step_t10_stale_plus_gateway_stall
  step_t11_recover_due_flag_fidelity
  step_t12_bounded_fail_closed
  smoke_log "PASS"
}

main "$@"
