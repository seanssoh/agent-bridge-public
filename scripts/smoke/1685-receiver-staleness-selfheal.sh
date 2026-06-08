#!/usr/bin/env bash
# scripts/smoke/1685-receiver-staleness-selfheal.sh — destination-side A2A
# receiver staleness self-heal (bootstrap gap, #1612 follow-up).
#
# Issue #1685: #1612's receiver-restart-on-upgrade lives in the v0.16.1+
# (DESTINATION) upgrader, but an upgrade is RUN BY the source (old) upgrader, so
# a pre-v0.16.1 → v0.16.x FIRST upgrade never restarts bridge-handoffd.py → it
# keeps running STALE code (pre-#1623 backpressure) → A2A silently 429s. The fix
# is a destination-side, source-version-independent daemon-tick detector +
# guarded ONE-SHOT preflight-before-stop self-heal.
#
# This smoke has TEETH and runs WITHOUT a live daemon / receiver / systemd:
#   Part A — the decision brain (lib/daemon-helpers/a2a-receiver-staleness.py):
#     the full no-op-or-one-shot matrix + fail-safe on malformed input.
#   Part B — the daemon tick (process_a2a_receiver_staleness_tick, extracted
#     from bridge-daemon.sh) with EVERY external dependency stubbed: the receiver
#     liveness, the python preflight, the lifecycle restart, and systemctl. The
#     six required behaviors are asserted, including the load-bearing safety
#     invariant: a stale-but-working receiver is NEVER stopped without a passing
#     preflight.
#
# Pre-fix (no helper, no tick) every Part-B assertion FAILS.

set -euo pipefail

SMOKE_NAME="1685-receiver-staleness-selfheal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/lib/daemon-helpers/a2a-receiver-staleness.py"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"
WORK="$SMOKE_TMP_ROOT"

pass=0
check() {
  local desc="$1"; shift
  if "$@"; then
    smoke_log "PASS: $desc"
    pass=$((pass + 1))
  else
    smoke_fail "FAIL: $desc"
  fi
}

# Portable octal file-mode read. GNU `stat -c` FIRST, then BSD/macOS `stat -f`
# (canonical order, mirrors scripts/smoke/1383-iso-cron-result-json-group.sh).
# The reverse order silently succeeds-with-garbage on Linux because GNU
# `stat -f '%Lp'` is a *filesystem* stat that exits 0 (it never falls through to
# the BSD branch) — that is the Linux-CI bug this order fixes. `?` on neither.
stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}

# ---------------------------------------------------------------------------
# Part A — the decision brain.
# ---------------------------------------------------------------------------
smoke_log "Part A: a2a-receiver-staleness.py decision matrix"

[[ -f "$HELPER" ]] || smoke_fail "helper not found: $HELPER (pre-fix)"

A="$WORK/partA"
mkdir -p "$A"
# cutoff updated_at -> epoch 2000 (UTC).
printf '{"updated_at":"1970-01-01T00:33:20+00:00","source_head":"abc123","version":"0.16.2"}' \
  >"$A/last-upgrade.json"

decide_field() {
  # decide_field <field-1based> <args...>
  local f="$1"; shift
  python3 "$HELPER" decide "$@" | cut -f"$f"
}

# 1) running receiver, NO boot marker, last-upgrade present -> stale.
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/attempt.json" 1 4242)"
check "no boot marker + running -> stale" test "$d" = "stale"
r="$(decide_field 3 "$A/last-upgrade.json" "$A/none.json" "$A/attempt.json" 1 4242)"
check "no boot marker reason=stale_unknown_boot_marker" test "$r" = "stale_unknown_boot_marker"

# 2) fresh marker newer than cutoff -> noop (the #1612 fresh-post-upgrade case).
printf '{"pid":4242,"started_at_epoch":3000}' >"$A/boot-fresh.json"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/boot-fresh.json" "$A/attempt.json" 1 4242)"
check "fresh marker (>cutoff) -> noop (no double restart)" test "$d" = "noop"

# 3) stale marker older than cutoff -> stale.
printf '{"pid":4242,"started_at_epoch":1000}' >"$A/boot-stale.json"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/boot-stale.json" "$A/attempt.json" 1 4242)"
check "boot before cutoff -> stale" test "$d" = "stale"
r="$(decide_field 3 "$A/last-upgrade.json" "$A/boot-stale.json" "$A/attempt.json" 1 4242)"
check "stale reason=boot_before_upgrade_cutoff" test "$r" = "boot_before_upgrade_cutoff"

# 4) marker pid mismatch -> stale_unknown.
printf '{"pid":9999,"started_at_epoch":3000}' >"$A/boot-mismatch.json"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/boot-mismatch.json" "$A/attempt.json" 1 4242)"
check "pid mismatch -> stale" test "$d" = "stale"

# 5) receiver not running -> noop (normal supervision owns a down receiver).
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/attempt.json" 0 0)"
check "receiver not running -> noop" test "$d" = "noop"

# 6) no last-upgrade.json -> noop.
d="$(decide_field 1 "$A/none-lu.json" "$A/none.json" "$A/attempt.json" 1 4242)"
check "no last-upgrade -> noop" test "$d" = "noop"

# 7) malformed last-upgrade -> noop (FAIL-SAFE), exit 0.
printf 'NOT JSON{{{' >"$A/bad-lu.json"
d="$(decide_field 1 "$A/bad-lu.json" "$A/none.json" "$A/attempt.json" 1 4242)"
check "malformed last-upgrade -> noop (fail-safe)" test "$d" = "noop"
python3 "$HELPER" decide "$A/bad-lu.json" x y 1 4242 >/dev/null 2>&1
check "decide always exits 0 on bad input" test "$?" = "0"

# 8) record one-shot then re-decide same key -> already_attempted (NEVER loop).
key="$(decide_field 2 "$A/last-upgrade.json" "$A/none.json" "$A/attempt.json" 1 4242)"
python3 "$HELPER" record "$A/attempt.json" "$key" restarted "lifecycle"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/attempt.json" 1 4242)"
check "already-attempted key -> noop (one-shot, no second restart)" test "$d" = "noop"
r="$(decide_field 3 "$A/last-upgrade.json" "$A/none.json" "$A/attempt.json" 1 4242)"
check "already-attempted reason" test "$r" = "already_attempted"
# attempt-state perms (0600).
mode="$(stat_mode "$A/attempt.json")"
check "attempt-state file is mode 0600" test "$mode" = "600"
# status surface.
st="$(python3 "$HELPER" status "$A/attempt.json" | cut -f1)"
check "status surface reports last self-heal result" test "$st" = "restarted"

# 9) MALFORMED boot marker -> noop (codex r1: a corrupt receiver-boot.json must
#    NOT drive a restart of a possibly-working receiver). ABSENT marker is the
#    valid stale signal; malformed is ambiguous -> fail safe.
printf 'NOT JSON{{{' >"$A/boot-malformed.json"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/boot-malformed.json" "$A/none.json" 1 4242)"
check "malformed boot marker -> noop (fail-safe, no restart)" test "$d" = "noop"
r="$(decide_field 3 "$A/last-upgrade.json" "$A/boot-malformed.json" "$A/none.json" 1 4242)"
check "malformed boot marker reason" test "$r" = "boot_marker_malformed"

# 10) MALFORMED attempt-state -> the per-key claim LOCK is the authoritative
#     guard, so a corrupt status file does NOT block a fresh self-heal (codex r2:
#     avoid the permanent-block class). decide falls through to the boot-marker
#     check; with NO boot marker that means `stale`.
printf 'NOT JSON{{{' >"$A/att-malformed.json"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/att-malformed.json" 1 4242)"
check "malformed attempt-state -> still evaluable (claim lock is the real guard)" test "$d" = "stale"

# 11) Atomic claim (codex r1 concurrency fix): first claim wins, second loses on
#     the per-key LOCK (the lock is the concurrency serializer).
key2="$(decide_field 2 "$A/last-upgrade.json" "$A/none.json" "$A/none-claim.json" 1 4242)"
c1="$(python3 "$HELPER" claim "$A/claim.json" "$key2")"
check "first claim -> claimed" test "$c1" = "claimed"
c2="$(python3 "$HELPER" claim "$A/claim.json" "$key2")"
check "second claim (same key) -> not_claimed (lock serializer)" test "$c2" = "not_claimed"
cmode="$(stat_mode "$A/claim.json")"
check "claim status file is mode 0600" test "$cmode" = "600"
# A bare `claimed` (in-progress) status must NOT short decide (codex r3): only a
# TERMINAL record does. So decide after a claim-but-no-terminal still evaluates.
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/claim.json" 1 4242)"
check "decide after claim-only (no terminal) -> still evaluable (not already_attempted)" test "$d" = "stale"
# After a TERMINAL record, decide for the same key -> already_attempted (the
# permanent one-shot is the terminal status, not the lock).
python3 "$HELPER" record "$A/claim.json" "$key2" restarted "lifecycle"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/claim.json" 1 4242)"
check "decide after TERMINAL record (same key) -> already_attempted" test "$d" = "noop"
r="$(decide_field 3 "$A/last-upgrade.json" "$A/none.json" "$A/claim.json" 1 4242)"
check "terminal-record reason is already_attempted" test "$r" = "already_attempted"

# 11b) release removes the lock so the dir stays tidy; the terminal status still
#      gates decide.
python3 "$HELPER" release "$A/claim.json" "$key2"
d="$(decide_field 1 "$A/last-upgrade.json" "$A/none.json" "$A/claim.json" 1 4242)"
check "decide after release (terminal status remains) -> already_attempted" test "$d" = "noop"

# 11c) PER-KEY independence (codex r2 fix): a LATER upgrade key must be able to
#      claim even after an EARLIER key was claimed+recorded+released.
printf '{"updated_at":"1970-01-01T01:06:40+00:00","source_head":"newhead","version":"0.16.3"}' >"$A/last-upgrade-2.json"
key3="$(decide_field 2 "$A/last-upgrade-2.json" "$A/none.json" "$A/claim.json" 1 4242)"
check "later upgrade key differs from earlier" bash -c "[ '$key3' != '$key2' ]"
c3="$(python3 "$HELPER" claim "$A/claim.json" "$key3")"
check "later upgrade key -> claimed (NOT blocked by prior key)" test "$c3" = "claimed"

# 11d) STALE-LOCK reclaim (codex r3 fix): a claim lock left behind by a daemon
#      that DIED mid-action (no terminal record) is reclaimable once stale, so
#      the self-heal is retried instead of permanently skipped.
keyd="dead-daemon-key"
rm -f "$A/dead.json" "$A"/dead.*.lock
c4="$(BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS=0 python3 "$HELPER" claim "$A/dead.json" "$keyd")"
check "claim (simulated dead holder) -> claimed" test "$c4" = "claimed"
# With stale window 0, the lock is immediately reclaimable (no terminal record
# was written by the 'dead' holder) -> a fresh claim succeeds (retry path).
c5="$(BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS=0 python3 "$HELPER" claim "$A/dead.json" "$keyd")"
check "stale lock reclaimed -> re-claim succeeds (retry, not permanent skip)" test "$c5" = "claimed"
# With a LONG stale window, a fresh lock is NOT reclaimable (a live holder).
c6="$(BRIDGE_A2A_RECEIVER_STALENESS_CLAIM_STALE_SECONDS=99999 python3 "$HELPER" claim "$A/dead.json" "$keyd")"
check "fresh lock NOT reclaimed under long window (live holder protected)" test "$c6" = "not_claimed"

# 11e) RECLAIM RACE (codex r4 fix): N concurrent reclaimers of the SAME stale
#      lock must yield EXACTLY ONE `claimed` (the reclaim is serialized behind a
#      separate O_EXCL reclaim-lock; a loser cannot unlink the winner's fresh
#      lock). Seed an OLD lock (backdated mtime) so it is genuinely stale under a
#      realistic window, then fire many parallel claims. A freshly-created lock
#      (age ~0) is NOT stale under the window, so only ONE reclaimer wins.
keyr="race-key"
rm -f "$A/race.json" "$A"/race.*.lock "$A"/race.*.reclaiming
keyr_hash="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])" "$keyr")"
race_lock="$A/race.$keyr_hash.lock"
printf '%s\n0\n' "$keyr" >"$race_lock"          # seed an abandoned lock
touch -t 200001010000 "$race_lock"              # backdate mtime -> genuinely stale
race_out="$A/race-out"; rm -rf "$race_out"; mkdir -p "$race_out"
for i in $(seq 1 12); do
  ( python3 "$HELPER" claim "$A/race.json" "$keyr" >"$race_out/$i" 2>/dev/null ) &
done
wait
nclaimed="$(grep -rl '^claimed$' "$race_out"/* 2>/dev/null | wc -l | tr -d ' ')"
check "concurrent reclaimers of one stale lock -> EXACTLY one claimed (race-safe)" test "${nclaimed:-0}" -eq 1

# ---------------------------------------------------------------------------
# Part B — the daemon tick with all external deps stubbed.
# ---------------------------------------------------------------------------
smoke_log "Part B: process_a2a_receiver_staleness_tick (stubbed lifecycle/systemd)"

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
    capture { print }
    capture && /^}$/ { capture=0; exit }
  ' "$2"
}

TICK_BODY="$(extract_fn process_a2a_receiver_staleness_tick "$DAEMON_SH")"
ESC_BODY="$(extract_fn bridge_a2a_staleness_escalate "$DAEMON_SH")"
[[ -n "$TICK_BODY" ]] || smoke_fail "could not extract process_a2a_receiver_staleness_tick (pre-fix)"
[[ -n "$ESC_BODY" ]] || smoke_fail "could not extract bridge_a2a_staleness_escalate (pre-fix)"

# Build the shared shim bin dir + the runner script ONCE (the extracted tick
# bodies are large — write them to a file rather than passing via `bash -c`,
# which overflows ARG_MAX).
SHIM_BIN="$WORK/shimbin"
RUNNER="$WORK/run-tick.sh"
REAL_PY="$(command -v python3)"
# Use the SAME bash that is running this smoke (the daemon code needs bash 4+;
# macOS /bin/bash is 3.2). The shim `bash` and the runner both target it so a
# `bridge-handoff-daemon.sh restart` interception and the extracted tick body
# run under a 4+ interpreter.
REAL_BASH="${BASH:-$(command -v bash)}"
mkdir -p "$SHIM_BIN"

# NOTE: the shims use a DIRECT shebang at $REAL_BASH (not `#!/usr/bin/env bash`).
# Under a large inherited environment, an `env`-shebang exec can fail with
# "env: bash: Argument list too long" (the macOS exec env-size limit); a direct
# interpreter shebang sidesteps it.
cat >"$SHIM_BIN/python3" <<PYSHIM
#!$REAL_BASH
# preflight (bridge-handoffd.py preflight) -> record + honor STUB_PREFLIGHT_RC.
# the staleness helper + everything else -> delegate to real python3.
case "\$*" in
  *bridge-handoffd.py\ preflight*)
    printf 'action\tpreflight\n' >>"\$STUB_ACTIONS"
    exit "\${STUB_PREFLIGHT_RC:-0}"
    ;;
  *)
    exec "$REAL_PY" "\$@"
    ;;
esac
PYSHIM
chmod +x "$SHIM_BIN/python3"

cat >"$SHIM_BIN/bash" <<BASHSHIM
#!$REAL_BASH
# bridge-handoff-daemon.sh restart -> record + honor STUB_LIFECYCLE_RC.
case "\$*" in
  *bridge-handoff-daemon.sh\ restart*)
    printf 'action\tlifecycle_restart\n' >>"\$STUB_ACTIONS"
    exit "\${STUB_LIFECYCLE_RC:-0}"
    ;;
  *)
    exec "$REAL_BASH" "\$@"
    ;;
esac
BASHSHIM
chmod +x "$SHIM_BIN/bash"

cat >"$SHIM_BIN/systemctl" <<SDSHIM
#!$REAL_BASH
printf 'action\tsystemctl_restart\n' >>"\$STUB_ACTIONS"
exit "\${STUB_SYSTEMCTL_RC:-0}"
SDSHIM
chmod +x "$SHIM_BIN/systemctl"

# The runner script: stub the in-process deps, then the extracted bodies, then
# call the tick. SCRIPT_DIR/BRIDGE_* come from the environment per invocation.
{
  cat <<'HARNESS'
set -uo pipefail
daemon_warn() { :; }
daemon_log_event() { :; }
daemon_info() { :; }
bridge_audit_log() { printf 'audit\t%s\n' "$2" >>"$STUB_AUDIT"; }
bridge_with_timeout() { shift 2 || true; "$@"; }
bridge_a2a_receiver_running() { [[ "${STUB_RECEIVER_RUNNING:-0}" == "1" ]]; }
bridge_a2a_receiver_pid() { printf '%s' "${STUB_RECEIVER_PID:-}"; }
bridge_a2a_receiver_systemd_active() { [[ "${STUB_SYSTEMD_OWNER:-0}" == "1" ]]; }
bridge_a2a_staleness_escalate() { printf 'escalate\t%s\n' "$2" >>"$STUB_ACTIONS"; return 0; }
# Shadow `source` so the tick's `source lib/bridge-a2a.sh` is a no-op in this
# unit harness — otherwise the real lib would redefine the receiver-liveness /
# systemd stubs above and the tick would never reach the decision path. Any
# OTHER source target still loads normally.
source() { case "$1" in */lib/bridge-a2a.sh) return 0 ;; *) builtin source "$@" ;; esac; }
HARNESS
  printf '%s\n' "$ESC_BODY"
  printf '%s\n' "$TICK_BODY"
  cat <<'HARNESS'
rm -f "$BRIDGE_STATE_DIR/handoff/receiver-staleness-tick.env" 2>/dev/null || true
process_a2a_receiver_staleness_tick
HARNESS
} >"$RUNNER"

# run_tick <home> -> writes action log to $home/actions.log, audit to audit.log
run_tick() {
  local home="$1"
  : >"$home/actions.log"
  : >"$home/audit.log"
  PATH="$SHIM_BIN:$PATH" \
  SCRIPT_DIR="$REPO_ROOT" \
  BRIDGE_HOME="$home" \
  BRIDGE_STATE_DIR="$home/state" \
  BRIDGE_A2A_CONFIG="$home/handoff.local.json" \
  STUB_ACTIONS="$home/actions.log" \
  STUB_AUDIT="$home/audit.log" \
  STUB_RECEIVER_RUNNING="${STUB_RECEIVER_RUNNING:-0}" \
  STUB_RECEIVER_PID="${STUB_RECEIVER_PID:-}" \
  STUB_SYSTEMD_OWNER="${STUB_SYSTEMD_OWNER:-0}" \
  STUB_PREFLIGHT_RC="${STUB_PREFLIGHT_RC:-0}" \
  STUB_LIFECYCLE_RC="${STUB_LIFECYCLE_RC:-0}" \
  STUB_SYSTEMCTL_RC="${STUB_SYSTEMCTL_RC:-0}" \
  BRIDGE_A2A_RECEIVER_STALENESS_INTERVAL_SECONDS=1 \
  BRIDGE_ADMIN_AGENT_ID="" \
  "$REAL_BASH" "$RUNNER" || true
}

# Build a scenario home.
make_home() {
  local name="$1" started_epoch="$2"  # started_epoch="" => no boot marker
  local home="$WORK/$name"
  mkdir -p "$home/state/upgrade" "$home/state/handoff" "$home/logs"
  printf '{ "bridge_id": "b" }' >"$home/handoff.local.json"
  # last-upgrade updated_at -> a recent cutoff (now - 100).
  local cutoff_epoch=$(( $(date +%s) - 100 ))
  local cutoff_iso
  cutoff_iso="$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).isoformat())" "$cutoff_epoch")"
  printf '{"updated_at":"%s","source_head":"deadbeef","version":"0.16.2"}' "$cutoff_iso" \
    >"$home/state/upgrade/last-upgrade.json"
  if [[ -n "$started_epoch" ]]; then
    # boot marker pid=4242, started at the given epoch.
    printf '{"pid":4242,"started_at_epoch":%s}' "$started_epoch" \
      >"$home/state/handoff/receiver-boot.json"
  fi
  printf '%s' "$home"
}

action_count() { grep -c "^action	$2" "$1/actions.log" 2>/dev/null || true; }
has_action() { grep -q "^action	$2" "$1/actions.log" 2>/dev/null; }
has_audit() { grep -q "^audit	$2" "$1/audit.log" 2>/dev/null; }

# Scenario 1: running, NO boot marker, last-upgrade present -> exactly ONE
# restart attempted (preflight then lifecycle).
h="$(make_home s1-no-marker "")"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"
check "s1 detected (audit a2a_receiver_stale_code_detected)" has_audit "$h" a2a_receiver_stale_code_detected
check "s1 preflight ran BEFORE restart" has_action "$h" preflight
check "s1 lifecycle restart attempted exactly once" test "$(action_count "$h" lifecycle_restart)" = "1"
check "s1 restarted audit" has_audit "$h" a2a_receiver_stale_code_restarted

# Scenario 2: fresh marker newer than cutoff -> NO-OP (no double restart).
h="$(make_home s2-fresh "$(( $(date +%s) + 10 ))")"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"
check "s2 fresh marker -> NO detection" bash -c "! grep -q a2a_receiver_stale_code_detected '$h/audit.log'"
check "s2 fresh marker -> NO preflight" bash -c "! grep -q '^action	preflight' '$h/actions.log'"
check "s2 fresh marker -> NO restart" bash -c "! grep -q '^action	lifecycle_restart' '$h/actions.log'"

# Scenario 3: existing attempt marker for same upgrade key -> no second restart.
h="$(make_home s3-attempted "")"
key="$(python3 "$HELPER" decide "$h/state/upgrade/last-upgrade.json" "$h/state/handoff/none.json" "$h/state/handoff/receiver-staleness.json" 1 4242 | cut -f2)"
python3 "$HELPER" record "$h/state/handoff/receiver-staleness.json" "$key" restarted "lifecycle"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"
check "s3 already-attempted -> NO new restart" bash -c "! grep -q '^action	lifecycle_restart' '$h/actions.log'"
check "s3 already-attempted -> NO detection re-fire" bash -c "! grep -q a2a_receiver_stale_code_detected '$h/audit.log'"

# Scenario 4 (SAFETY CRUX): preflight FAILS -> stale receiver is NOT stopped.
h="$(make_home s4-preflight-fail "")"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 STUB_PREFLIGHT_RC=1 run_tick "$h"
check "s4 preflight ran" has_action "$h" preflight
check "s4 preflight fail -> receiver NOT stopped (NO lifecycle restart)" bash -c "! grep -q '^action	lifecycle_restart' '$h/actions.log'"
check "s4 preflight fail -> restart_failed audit" has_audit "$h" a2a_receiver_stale_code_restart_failed

# Scenario 5: #1612-style fresh post-upgrade receiver -> no double restart.
# (Equivalent to s2 — the marker is the fresh-post-restart marker > write-state.)
h="$(make_home s5-1612-fresh "$(( $(date +%s) + 5 ))")"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"
check "s5 #1612 fresh receiver -> NO restart (no double restart)" bash -c "! grep -q '^action	lifecycle_restart' '$h/actions.log'"

# Scenario 6: systemd-owner -> systemctl restart (NOT shell stop/start).
h="$(make_home s6-systemd "")"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 STUB_SYSTEMD_OWNER=1 run_tick "$h"
check "s6 systemd-owner preflight ran" has_action "$h" preflight
check "s6 systemd-owner -> systemctl restart" has_action "$h" systemctl_restart
check "s6 systemd-owner -> NO shell lifecycle restart" bash -c "! grep -q '^action	lifecycle_restart' '$h/actions.log'"
check "s6 systemd-owner restarted audit" has_audit "$h" a2a_receiver_stale_code_restarted

# Scenario 7 (codex r1 fail-safe): MALFORMED boot marker -> NO restart.
h="$(make_home s7-malformed-marker "")"
printf 'NOT JSON{{{' >"$h/state/handoff/receiver-boot.json"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"
check "s7 malformed marker -> NO detection" bash -c "! grep -q a2a_receiver_stale_code_detected '$h/audit.log'"
check "s7 malformed marker -> NO restart" bash -c "! grep -q '^action	lifecycle_restart' '$h/actions.log'"

# Scenario 8 (codex r1 concurrency): two sequential ticks for the SAME upgrade
# key -> the FIRST restarts, the SECOND no-ops (the persisted one-shot claim
# blocks it). This is the durable half of the race guard. (The atomic O_EXCL
# claim covers the truly-concurrent half, asserted in Part A scenario 11.)
h="$(make_home s8-race "")"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"   # tick A claims + restarts
check "s8 tick A -> exactly ONE lifecycle restart" test "$(action_count "$h" lifecycle_restart)" = "1"
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"   # tick B (log reset by run_tick)
check "s8 tick B (one-shot already claimed) -> NO restart" test "$(action_count "$h" lifecycle_restart)" = "0"
check "s8 tick B -> NO detection re-fire" bash -c "! grep -q a2a_receiver_stale_code_detected '$h/audit.log'"

# Scenario 9 (codex r2 per-key independence): after the s8 one-shot for upgrade A,
# a NEW upgrade (different last-upgrade.json identity) must self-heal AGAIN — the
# prior key's claim must NOT permanently block it.
new_cutoff=$(( $(date +%s) - 5 ))
new_iso="$(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).isoformat())" "$new_cutoff")"
printf '{"updated_at":"%s","source_head":"newhead2","version":"0.16.3"}' "$new_iso" \
  >"$h/state/upgrade/last-upgrade.json"   # NEW upgrade identity on the SAME home
STUB_RECEIVER_RUNNING=1 STUB_RECEIVER_PID=4242 run_tick "$h"
check "s9 new upgrade key -> self-heal restarts AGAIN (not blocked by prior key)" test "$(action_count "$h" lifecycle_restart)" = "1"
check "s9 new upgrade key -> detection re-fires" has_audit "$h" a2a_receiver_stale_code_detected

# ---------------------------------------------------------------------------
# Part C — the receiver-owned boot marker writer (bridge-handoffd.py).
# ---------------------------------------------------------------------------
smoke_log "Part C: write_receiver_boot_marker (atomic 0600, non-fatal on failure)"

BOOT_HELPER="$SCRIPT_DIR/1685-boot-marker-helper.py"
[[ -f "$BOOT_HELPER" ]] || smoke_fail "boot-marker helper not found: $BOOT_HELPER"

CH="$WORK/partC"
mkdir -p "$CH/state/handoff" "$CH/logs"
# Drive the writer in-process via the real module (file-as-argv helper; the
# module name has dashes so the helper loads it through importlib).
BRIDGE_HOME="$CH" BRIDGE_STATE_DIR="$CH/state" BRIDGE_LOG_DIR="$CH/logs" \
  python3 "$BOOT_HELPER" "$REPO_ROOT" "$CH/handoffd.pid" >/dev/null 2>&1 || true
marker="$CH/state/handoff/receiver-boot.json"
check "boot marker written" test -f "$marker"
mmode="$(stat_mode "$marker")"
check "boot marker is mode 0600" test "$mmode" = "600"
check "boot marker has started_at_epoch (int)" python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if isinstance(d.get('started_at_epoch'),int) else 1)" "$marker"
check "boot marker has pid (int)" python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if isinstance(d.get('pid'),int) else 1)" "$marker"

# Non-fatal on failure: an unwritable handoff path must NOT raise. Put a FILE
# where state/handoff should be a dir so mkdir of the marker parent fails.
CHRO="$WORK/partC-ro"
mkdir -p "$CHRO/state" "$CHRO/logs"
: >"$CHRO/state/handoff"
ro_rc=0
BRIDGE_HOME="$CHRO" BRIDGE_STATE_DIR="$CHRO/state" BRIDGE_LOG_DIR="$CHRO/logs" \
  python3 "$BOOT_HELPER" "$REPO_ROOT" "$CHRO/handoffd.pid" >/dev/null 2>&1 || ro_rc=$?
check "marker-write failure is non-fatal (helper still exits 0)" test "$ro_rc" = "0"

smoke_log "all assertions passed ($pass checks)"
