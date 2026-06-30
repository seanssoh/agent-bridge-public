#!/usr/bin/env bash
# Regression smoke — bridge-watchdog-silence.py must ESCALATE a hung
# `restart --force` (rc 124, and any other non-0/non-2 failure) instead of
# failing open: a bare `restart_failed` + 300s cooldown leaves the daemon
# DOWN for the full window with no harder kill or OS-init re-arm.
#
# Background (issue #2208, 2026-06-30):
#   `attempt_restart` routes a wedged-daemon restart through
#   `run_daemon_command('restart','--force')` with RESTART_TIMEOUT. On a
#   hang it returns (124, '…timed out'). The rc==2 case is handled
#   distinctly (`restart_refused`, out-of-band launchd split — must stay
#   fail-closed); EVERY OTHER nonzero — including 124 — used to fall into
#   the generic `restart_failed` branch: emit an audit, write a 300s
#   cooldown, return. No SIGKILL of the wedged recorded pid, no OS-init
#   re-arm. The watchdog is the last automated recovery line, so a hung
#   restart defeated it for 5 minutes.
#
# The fix (#2208): on rc 124 / any non-0/non-2, `_escalate_hung_restart`
#   (a) SIGKILLs the recorded wedged daemon pid — non-launchd hosts only,
#       pid-alive + recorded-pid-provenance guarded (launchd's KeepAlive
#       owns the kill on macOS, so we skip the manual kill there and let
#       the kickstart re-arm own it), then
#   (b) drives ONE bounded `restart --force` re-arm (launchd kickstart /
#       Linux stop+start). On a live daemon it records a `restarted`
#       outcome via escalation; only when the re-arm ALSO fails does it
#       fall back to the existing 300s cooldown.
#
# Coverage:
#   C1 — POSITIVE: a stub `restart --force` that hangs past RESTART_TIMEOUT
#        on the first call (→ run_daemon_command returns 124) and succeeds
#        on the re-arm call (records a fresh, LIVE daemon pid). Asserts the
#        audit emits `daemon_silence_restart_escalated` /
#        `outcome=escalated_restarted`, the cooldown state records a
#        `restarted` (via=escalation) outcome with the fresh pid, and there
#        is NO bare `restart_failed` row. This is the mutation oracle:
#        revert the escalate call and C1 fails (the daemon stays "down" and
#        the state file shows restart_failed + 300s cooldown).
#   C2 — NEGATIVE CONTROL: rc==2 still yields `restart_refused` with NO
#        escalation and NO kill (the out-of-band launchd split must stay
#        fail-closed — escalating there would not help).

set -uo pipefail

SMOKE_NAME="2208-watchdog-hung-restart-escalate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  # Reap any live "daemon" stand-ins the stubs/probes spawned.
  local p
  for p in "${REARM_LIVE_PID:-}" "${VICTIM_PID:-}" "${LOOKALIKE_PID:-}" \
           "${RECYCLED_PID:-}" "${INNOCENT_PID:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd python3

# Strip operator-shell overrides that would steer the watchdog module's
# import-time defaults outside this smoke's temp bridge home (mirrors the
# #946 L3 smoke — defence-in-depth alongside the module-resolved path
# checks; an inherited override could (worse) write into the live state).
unset BRIDGE_DAEMON_SILENCE_COOLDOWN_FILE BRIDGE_DAEMON_SILENCE_PIDLOCK

# Keep RESTART_TIMEOUT at its floor (5s) so the "hung" first call resolves
# to 124 quickly; the stub sleeps just past it.
export BRIDGE_DAEMON_SILENCE_RESTART_TIMEOUT_SECONDS=5

WATCHDOG_SCRIPT="$REPO_ROOT/bridge-watchdog-silence.py"
smoke_assert_file_exists "$WATCHDOG_SCRIPT" "watchdog source"

DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"
export BRIDGE_DAEMON_PID_FILE="$DAEMON_PID_FILE"

# ---------------------------------------------------------------------------
# C1 — hung first restart → escalate (kill + re-arm), NOT a 300s cooldown
# ---------------------------------------------------------------------------
smoke_log "C1: hung 'restart --force' escalates to kill+re-arm (not restart_failed+300s)"

# A long-lived process whose pid the re-arm stub records as the "fresh
# daemon" pid, so the watchdog's rearm_ok liveness probe (pid_alive) passes
# on a genuinely live pid (not a synthetic one).
sleep 600 &
REARM_LIVE_PID=$!

CALL_COUNTER="$SMOKE_TMP_ROOT/restart-call-count"
printf '0' >"$CALL_COUNTER"

# Stub bridge-daemon.sh:
#   call #1 (the wedged restart)  → sleep past RESTART_TIMEOUT → 124
#   call #2 (the bounded re-arm)  → record a LIVE pid, exit 0
# Written via smoke_write_runtime_stub so a path-resolution regression can
# never clobber the live install (#1860 guard).
fake_daemon="$SMOKE_TMP_ROOT/fake-bridge-daemon.sh"
smoke_write_runtime_stub "$fake_daemon" '#!/usr/bin/env bash
# args: restart --force
counter_file="'"$CALL_COUNTER"'"
pid_file="'"$DAEMON_PID_FILE"'"
live_pid="'"$REARM_LIVE_PID"'"
n="$(cat "$counter_file" 2>/dev/null || printf 0)"
n=$((n + 1))
printf "%s" "$n" >"$counter_file"
if [[ "$n" -eq 1 ]]; then
  # Wedged restart: hang past RESTART_TIMEOUT (floor 5s) so
  # run_daemon_command times out and returns 124.
  sleep 8
  exit 0
fi
# Re-arm: record a fresh, LIVE daemon pid and succeed.
printf "%s\n" "$live_pid" >"$pid_file"
exit 0
'

c1_probe="$SMOKE_TMP_ROOT/c1-escalate.py"
cat >"$c1_probe" <<PROBE
import importlib.util
import json
import os
import sys
from pathlib import Path

os.environ["BRIDGE_DAEMON_SCRIPT"] = "$fake_daemon"

spec = importlib.util.spec_from_file_location("bws", "$WATCHDOG_SCRIPT")
mod = importlib.util.module_from_spec(spec)
sys.modules["bws"] = mod
spec.loader.exec_module(mod)

assert str(mod.DAEMON_SCRIPT) == "$fake_daemon", \
    f"DAEMON_SCRIPT resolution drifted: got {mod.DAEMON_SCRIPT!r}"
# Sanity: the timeout floor must be small so call #1 resolves to 124 fast.
assert mod.RESTART_TIMEOUT == 5, f"RESTART_TIMEOUT not pinned: {mod.RESTART_TIMEOUT}"

mod.attempt_restart({"age_seconds": 9999, "threshold_seconds": 600,
                     "last_tick_ts": "2026-06-30T00:00:00+00:00",
                     "daemon_pid": 1})

state_path = Path(mod.COOLDOWN_FILE)
if not state_path.exists():
    print(f"FAIL: state file not written at {state_path}")
    sys.exit(1)
payload = json.loads(state_path.read_text("utf-8"))
detail = payload.get("detail") or {}

errors = []
# The escalation must have produced a 'restarted' outcome via escalation —
# NOT a bare restart_failed. This is the mutation oracle: reverting the
# escalate call leaves outcome == 'restart_failed' here.
if detail.get("outcome") != "restarted":
    errors.append(f"  cooldown outcome: expected 'restarted', got {detail.get('outcome')!r}")
if detail.get("via") != "escalation":
    errors.append(f"  cooldown via: expected 'escalation', got {detail.get('via')!r}")
if detail.get("restart_exit") != 124:
    errors.append(f"  restart_exit: expected 124 (hung), got {detail.get('restart_exit')!r}")
# A fresh daemon pid must have been recorded by the re-arm.
new_pid = detail.get("new_pid")
if not isinstance(new_pid, int) or new_pid <= 0:
    errors.append(f"  new_pid: expected a positive recorded pid, got {new_pid!r}")

if errors:
    print("FAIL")
    for e in errors:
        print(e)
    print(f"  full detail: {detail!r}")
    sys.exit(1)

print("PASS")
print(f"  outcome={detail.get('outcome')!r} via={detail.get('via')!r} new_pid={new_pid!r}")
PROBE

c1_out="$(python3 "$c1_probe" 2>&1)"
c1_rc=$?
if (( c1_rc != 0 )); then
  smoke_log "C1 output:"; printf '%s\n' "$c1_out"
  smoke_fail "C1: hung restart did not escalate to kill+re-arm (fail-open regression #2208)"
fi
smoke_log "C1 PASS"
printf '%s\n' "$c1_out" | sed 's/^/  /'

# Audit-trail assertion: the escalation must have emitted a
# daemon_silence_restart_escalated row with outcome=escalated_restarted.
ESC_ROWS="$(grep -c '"action": *"daemon_silence_restart_escalated"' "$BRIDGE_AUDIT_LOG" 2>/dev/null || printf 0)"
if (( ESC_ROWS < 1 )); then
  smoke_log "audit log tail:"; tail -n 20 "$BRIDGE_AUDIT_LOG" 2>/dev/null | sed 's/^/  /'
  smoke_fail "C1: no daemon_silence_restart_escalated audit row emitted"
fi
if ! grep -q 'escalated_restarted' "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
  smoke_fail "C1: escalation audit row missing outcome=escalated_restarted"
fi
# And NO bare restart_failed row should have been written on this success.
if grep -q '"action": *"daemon_silence_restart_attempted".*restart_failed' "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
  smoke_fail "C1: a bare restart_failed row was emitted despite successful escalation (fail-open)"
fi
smoke_log "C1 audit assertions PASS (escalated_restarted, no restart_failed)"

# ---------------------------------------------------------------------------
# C2 — rc==2 negative control: restart_refused, NO escalation, NO kill
# ---------------------------------------------------------------------------
smoke_log "C2: rc==2 still yields restart_refused with no escalation/kill (out-of-band split fail-closed)"

# Fresh state + audit so the C1 escalation rows don't bleed into C2's
# assertions.
rm -f "$BRIDGE_STATE_DIR/silence-watchdog.json" "$BRIDGE_AUDIT_LOG" 2>/dev/null || true

refuse_daemon="$SMOKE_TMP_ROOT/fake-bridge-daemon-refuse.sh"
smoke_write_runtime_stub "$refuse_daemon" '#!/usr/bin/env bash
# Mimic the launchd out-of-band-split refusal: exit 2 immediately.
echo "daemon restart REFUSED — out-of-band launchd split" >&2
exit 2
'

c2_probe="$SMOKE_TMP_ROOT/c2-refused.py"
cat >"$c2_probe" <<PROBE
import importlib.util
import json
import os
import sys
from pathlib import Path

os.environ["BRIDGE_DAEMON_SCRIPT"] = "$refuse_daemon"

spec = importlib.util.spec_from_file_location("bws", "$WATCHDOG_SCRIPT")
mod = importlib.util.module_from_spec(spec)
sys.modules["bws"] = mod
spec.loader.exec_module(mod)

assert str(mod.DAEMON_SCRIPT) == "$refuse_daemon"

mod.attempt_restart({"age_seconds": 9999, "threshold_seconds": 600,
                     "last_tick_ts": "2026-06-30T00:00:00+00:00",
                     "daemon_pid": 1})

state_path = Path(mod.COOLDOWN_FILE)
payload = json.loads(state_path.read_text("utf-8"))
detail = payload.get("detail") or {}

errors = []
if detail.get("outcome") != "restart_refused":
    errors.append(f"  outcome: expected 'restart_refused', got {detail.get('outcome')!r}")
if detail.get("restart_exit") != 2:
    errors.append(f"  restart_exit: expected 2, got {detail.get('restart_exit')!r}")
# No escalation-via marker on the refused path.
if detail.get("via") == "escalation":
    errors.append("  refused path must NOT record via=escalation")

if errors:
    print("FAIL")
    for e in errors:
        print(e)
    print(f"  full detail: {detail!r}")
    sys.exit(1)

print("PASS")
print(f"  outcome={detail.get('outcome')!r} restart_exit={detail.get('restart_exit')!r}")
PROBE

c2_out="$(python3 "$c2_probe" 2>&1)"
c2_rc=$?
if (( c2_rc != 0 )); then
  smoke_log "C2 output:"; printf '%s\n' "$c2_out"
  smoke_fail "C2: rc==2 did not stay fail-closed as restart_refused"
fi
smoke_log "C2 PASS"
printf '%s\n' "$c2_out" | sed 's/^/  /'

# The refused path must NOT have escalated.
if grep -q 'daemon_silence_restart_escalated' "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
  smoke_fail "C2: rc==2 wrongly escalated (out-of-band split must stay fail-closed)"
fi
smoke_log "C2 audit assertions PASS (no escalation on rc==2)"

# ---------------------------------------------------------------------------
# C3 — non-launchd kill path: SIGKILL the wedged pid behind the STRICT
#      provenance proof (mirrors the daemon singleton evict-proof):
#      cmdline contains `bridge-daemon.sh run` AND the owner record's pid +
#      start_time match the live process generation. The launchd
#      determination is forced OFF (mod._daemon_is_launchd_managed -> False)
#      so the kill branch runs even on a macOS dev box. Sub-cases:
#        C3a — proven daemon generation (cmdline `bridge-daemon.sh run` +
#              owner record pid+start_time match) → SIGKILLed.
#        C3b — cmdline `bridge-daemon.sh restart` (look-alike, NOT the run
#              shape) → NOT killed.
#        C3c — cmdline `bridge-daemon.sh run` BUT owner-record start_time
#              mismatch (recycled-pid shape) → NOT killed.
#        C3d — plain non-daemon process (no daemon in cmdline) → NOT killed.
# ---------------------------------------------------------------------------
smoke_log "C3: non-launchd path SIGKILLs only a PROVEN daemon generation (strict provenance)"
rm -f "$BRIDGE_STATE_DIR/silence-watchdog.json" "$BRIDGE_AUDIT_LOG" "$DAEMON_PID_FILE.owner" 2>/dev/null || true

# A daemon-shaped victim: a stub at a path ending in bridge-daemon.sh, run
# WITH a `run` arg. The stub does NOT exec — it `sleep`s in the foreground —
# so the spawned bash pid ($!) keeps its own argv and `ps -p <pid> -o args=`
# shows `bash …/c3-bridge-daemon.sh run` (contains `bridge-daemon.sh run`).
daemon_stub="$SMOKE_TMP_ROOT/c3-bridge-daemon.sh"
smoke_write_runtime_stub "$daemon_stub" '#!/usr/bin/env bash
# Stand-in for a wedged daemon generation: alive, argv visible via ps.
sleep 600
'
bash "$daemon_stub" run &
VICTIM_PID=$!
# C3b look-alike: SAME stub but argv `restart` (not the run shape).
bash "$daemon_stub" restart &
LOOKALIKE_PID=$!
# C3c recycled shape: argv `run` (cmdline ok) but we will give it a
# MISMATCHED owner-record start_time below.
bash "$daemon_stub" run &
RECYCLED_PID=$!
# C3d plain non-daemon process.
sleep 600 &
INNOCENT_PID=$!
# Give ps a moment to see the spawned argv.
sleep 0.4

# Re-arm stub for C3: succeed (records a fresh live pid). The kill is what
# C3 asserts, not the re-arm shape.
c3_rearm="$SMOKE_TMP_ROOT/c3-rearm-bridge-daemon.sh"
smoke_write_runtime_stub "$c3_rearm" '#!/usr/bin/env bash
printf "%s\n" "'"$REARM_LIVE_PID"'" >"'"$DAEMON_PID_FILE"'"
exit 0
'

c3_probe="$SMOKE_TMP_ROOT/c3-kill.py"
cat >"$c3_probe" <<PROBE
import importlib.util
import os
import sys
import time as _t

os.environ["BRIDGE_DAEMON_SCRIPT"] = "$c3_rearm"

spec = importlib.util.spec_from_file_location("bws", "$WATCHDOG_SCRIPT")
mod = importlib.util.module_from_spec(spec)
sys.modules["bws"] = mod
spec.loader.exec_module(mod)

# Force the non-launchd kill branch on any host.
mod._daemon_is_launchd_managed = lambda: False

victim_pid = int("$VICTIM_PID")
lookalike_pid = int("$LOOKALIKE_PID")
recycled_pid = int("$RECYCLED_PID")
innocent_pid = int("$INNOCENT_PID")

owner_path = mod.Path(f"{mod.BRIDGE_DAEMON_PID_FILE}.owner")

def write_owner(pid, start_time):
    owner_path.write_text(
        f"pid={pid}\\ncmdline=bridge-daemon.sh run\\nstart_time={start_time}\\ngeneration=1\\n",
        encoding="utf-8",
    )

errors = []

# --- C3a: PROVEN daemon generation → must be SIGKILLed. ---
write_owner(victim_pid, mod._proc_start_time(victim_pid))
mod.BRIDGE_DAEMON_PID_FILE.write_text(f"{victim_pid}\\n", encoding="utf-8")
if not mod._recorded_daemon_pid_provenance_ok(victim_pid):
    errors.append("  C3a: provenance gate REJECTED a proven daemon generation")
mod._escalate_hung_restart(124, {"age_seconds": 1, "phase": "c3a"})
_t.sleep(0.3)
if mod.pid_alive(victim_pid):
    errors.append(f"  C3a: victim pid {victim_pid} still alive — SIGKILL did not fire on a proven generation")

# --- C3b: cmdline is 'bridge-daemon.sh restart' (look-alike) → NOT killed. ---
write_owner(lookalike_pid, mod._proc_start_time(lookalike_pid))
mod.BRIDGE_DAEMON_PID_FILE.write_text(f"{lookalike_pid}\\n", encoding="utf-8")
if mod._recorded_daemon_pid_provenance_ok(lookalike_pid):
    errors.append("  C3b: provenance gate ACCEPTED a non-run look-alike cmdline")
mod._escalate_hung_restart(124, {"age_seconds": 1, "phase": "c3b"})
_t.sleep(0.3)
if not mod.pid_alive(lookalike_pid):
    errors.append(f"  C3b: look-alike pid {lookalike_pid} was killed despite a non-run cmdline")

# --- C3c: cmdline 'bridge-daemon.sh run' but owner start_time MISMATCH
#          (recycled-pid shape) → NOT killed. ---
write_owner(recycled_pid, "Mon Jan  1 00:00:00 1970")
mod.BRIDGE_DAEMON_PID_FILE.write_text(f"{recycled_pid}\\n", encoding="utf-8")
if mod._recorded_daemon_pid_provenance_ok(recycled_pid):
    errors.append("  C3c: provenance gate ACCEPTED a start_time-mismatched (recycled) pid")
mod._escalate_hung_restart(124, {"age_seconds": 1, "phase": "c3c"})
_t.sleep(0.3)
if not mod.pid_alive(recycled_pid):
    errors.append(f"  C3c: recycled-shape pid {recycled_pid} was killed despite start_time mismatch")

# --- C3d: plain non-daemon process → NOT killed (and no owner record). ---
owner_path.unlink(missing_ok=True)
mod.BRIDGE_DAEMON_PID_FILE.write_text(f"{innocent_pid}\\n", encoding="utf-8")
if mod._recorded_daemon_pid_provenance_ok(innocent_pid):
    errors.append("  C3d: provenance gate ACCEPTED a plain non-daemon process")
mod._escalate_hung_restart(124, {"age_seconds": 1, "phase": "c3d"})
_t.sleep(0.3)
if not mod.pid_alive(innocent_pid):
    errors.append(f"  C3d: innocent pid {innocent_pid} was killed (no daemon cmdline, no owner record)")

if errors:
    print("FAIL")
    for e in errors:
        print(e)
    sys.exit(1)

print("PASS")
print("  C3a proven-gen SIGKILLed; C3b/C3c/C3d spared (look-alike / recycled / non-daemon)")
PROBE

c3_out="$(python3 "$c3_probe" 2>&1)"
c3_rc=$?
if (( c3_rc != 0 )); then
  smoke_log "C3 output:"; printf '%s\n' "$c3_out"
  smoke_fail "C3: non-launchd kill path / strict provenance guard regressed"
fi
# Reap survivors (C3b/C3c/C3d processes are expected to outlive the watchdog).
kill "$VICTIM_PID" "$LOOKALIKE_PID" "$RECYCLED_PID" "$INNOCENT_PID" 2>/dev/null || true
smoke_log "C3 PASS"
printf '%s\n' "$c3_out" | sed 's/^/  /'

smoke_log "PASS — bridge-watchdog-silence.py escalates a hung restart to kill+re-arm, guards the kill (strict daemon-generation provenance), and keeps rc==2 fail-closed (#2208)"
exit 0
