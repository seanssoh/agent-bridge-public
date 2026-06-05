#!/usr/bin/env bash
# scripts/smoke/1563-pr6-watchdog-scan-timeout.sh — unit smoke for the #1563
# PR-6 daemon WATCHDOG-SCAN WEDGE fix (rc2).
#
# THE WEDGE (confirmed, patch diagnosed live with `sample` 2026-06-06): in
# bridge-daemon.sh `process_watchdog_report` the report-file (markdown) scan
# was a BARE, UN-bounded call:
#     if ! "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-watchdog.sh" scan >"$report_file"; then
# It ran BEFORE the 30s-timeout-wrapped `scan --json` call. A hung
# `bridge-watchdog.py` directory-walk blocked the daemon main loop FOREVER
# here, never reaching the 30s ceiling. Killing the hung child resumed the
# tick instantly → the daemon was synchronously wedged on this one line.
#
# Compounding it: the scan chain is
#   <gate> → "$BRIDGE_BASH_BIN" bridge-watchdog.sh (exec→ python3
#   bridge-watchdog.py) → `agent-bridge agent registry --json` (grandchild),
# and bridge_with_timeout's GNU `timeout` / `subprocess.run(timeout=)` only
# kill the IMMEDIATE child — so even the wrapped --json path could orphan the
# agent-bridge grandchild + leave it spinning.
#
# THE FIX PR-6 ships (this smoke pins):
#   - bridge-daemon.sh: bridge_run_command_with_pgroup_timeout — bounds an
#     external command with a deadline AND a process-GROUP kill on expiry
#     (PR #952 monitor-mode + _bridge_kill_proc_tree negative-pid kill),
#     capturing stdout to a caller-supplied file. Returns 124 on timeout.
#   - process_watchdog_report routes BOTH the markdown scan AND the --json
#     scan through it; the bare un-bounded call is GONE.
#
# Everything driven here is EXTRACTED VERBATIM from the shipped
# bridge-daemon.sh (awk function-block extraction, the δ-1234 pattern), so a
# revert of the hardening fails this smoke.
#
# Assertions (teeth-carrying):
#   T1  — HANG → BOUNDED: a scan that hangs forever (and forks a child that
#         also hangs) returns 124 within ~ceiling+grace, NOT forever.
#         TEETH: a BARE (un-bounded) call to the same hang does NOT return
#         within the ceiling (we prove the wedge with a wall-clock alarm) —
#         so the helper's bound is load-bearing, not incidental.
#   T2  — HANG → NO ORPHAN: the hung child (a SIGTERM-IGNORING grandchild in
#         the wrapper's process group) is DEAD after the helper returns —
#         proving the GROUP kill + unconditional SIGKILL, not a direct-child-
#         only kill that would leave the python3/agent-bridge grandchild
#         spinning (the exact orphan patch's `sample` caught).
#   T3  — NORMAL FAST PATH (no regression): a fast scan that writes its
#         markdown/json to stdout completes with rc 0 and the captured
#         stdout_file holds the full output.
#   T4  — STATIC-ASSERT: process_watchdog_report no longer contains the bare
#         `scan >"$report_file"` un-timeout-wrapped call, and BOTH scans go
#         through bridge_run_command_with_pgroup_timeout.
#
# Isolated: everything runs under a mktemp dir; no live bridge state touched.
# Footgun #11: pipe/argv stdin only — no heredoc-stdin to a subprocess capture.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
if [[ ! -r "$DAEMON_SH" ]]; then
  printf '[FAIL] required source not found: %s\n' "$DAEMON_SH" >&2
  exit 1
fi
command -v awk >/dev/null 2>&1 || { printf '[FAIL] awk not available\n' >&2; exit 1; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1563-pr6-smoke.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
cleanup() { rm -rf "$SMOKE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Extract the three real shipped functions from bridge-daemon.sh.
# ---------------------------------------------------------------------------
HELPER_FUNCS="$SMOKE_DIR/pr6-funcs.sh"
{
  for fn in _bridge_enumerate_children _bridge_kill_proc_tree \
            bridge_run_command_with_pgroup_timeout; do
    awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$DAEMON_SH"
  done
} >"$HELPER_FUNCS"

for fn in _bridge_enumerate_children _bridge_kill_proc_tree \
          bridge_run_command_with_pgroup_timeout; do
  if ! grep -q "^${fn}() {" "$HELPER_FUNCS"; then
    _fail "extract $fn" "could not extract $fn from bridge-daemon.sh (renamed / removed?)"
  fi
done
if (( FAILS > 0 )); then
  printf '\n[1563-pr6] %d/%d failed (extraction)\n' "$FAILS" "$TOTAL" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T1 + T2: hang → bounded + group-killed (no orphan).
# ---------------------------------------------------------------------------
# A "hanging scan": prints its PID-tracking marker, forks a SIGTERM-IGNORING
# grandchild that sleeps "forever" (the orphan-risk process), records the
# grandchild pid, then the parent itself sleeps forever. Mirrors the real
# chain (bridge-watchdog.sh exec→ python3 → agent-bridge grandchild).
HANG_SCAN="$SMOKE_DIR/hang-scan.sh"
GRANDCHILD_PID_FILE="$SMOKE_DIR/grandchild.pid"
{
  printf '#!/usr/bin/env bash\n'
  # Grandchild: ignore TERM so only a GROUP SIGKILL can reap it — this is the
  # teeth that distinguish a real pgroup kill from a direct-child TERM.
  printf 'trap "" TERM\n'
  printf '( trap "" TERM; sleep 600 ) &\n'
  printf 'echo $! > "%s"\n' "$GRANDCHILD_PID_FILE"
  printf 'sleep 600\n'
} >"$HANG_SCAN"
chmod +x "$HANG_SCAN"

# Driver: source the extracted helpers, stub bridge_audit_log, run the hang
# under a 2s ceiling, print rc + elapsed.
T1_DRIVER="$SMOKE_DIR/t1-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'HANG_SCAN="$1"\n'
  printf 'STDOUT_FILE="$2"\n'
  # Stub the audit sink so the extracted helper does not pull in bridge-lib.
  printf 'bridge_audit_log() { :; }\n'
  printf 'source "%s"\n' "$HELPER_FUNCS"
  printf 'start=$(date +%%s)\n'
  printf 'bridge_run_command_with_pgroup_timeout 2 daemon_watchdog_scan_report "$STDOUT_FILE" bash "$HANG_SCAN"\n'
  printf 'rc=$?\n'
  printf 'end=$(date +%%s)\n'
  printf 'printf "RC=%%s ELAPSED=%%s\\n" "$rc" "$((end - start))"\n'
} >"$T1_DRIVER"

T1_OUT="$SMOKE_DIR/t1.out"
# Wall-clock alarm: the WHOLE driver must finish well under the bare-wedge
# horizon (the hang sleeps 600s). 20s is generous for a 2s ceiling + 0.5s
# grace + reap; if the driver itself blocks (helper bound not load-bearing)
# this `timeout` fires and rc!=124/rc-mismatch → T1 fails.
DRIVER_GUARD=""
DRIVER_GUARD="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
if [[ -n "$DRIVER_GUARD" ]]; then
  "$DRIVER_GUARD" 20 bash "$T1_DRIVER" "$HANG_SCAN" "$SMOKE_DIR/t1-stdout" >"$T1_OUT" 2>&1
  guard_rc=$?
else
  bash "$T1_DRIVER" "$HANG_SCAN" "$SMOKE_DIR/t1-stdout" >"$T1_OUT" 2>&1
  guard_rc=$?
fi

t1_rc="$(grep -oE 'RC=[0-9]+' "$T1_OUT" 2>/dev/null | head -1 | cut -d= -f2)"
t1_elapsed="$(grep -oE 'ELAPSED=[0-9]+' "$T1_OUT" 2>/dev/null | head -1 | cut -d= -f2)"

if [[ -n "$DRIVER_GUARD" && "$guard_rc" == "124" ]]; then
  _fail "T1 hang-bounded" "the driver itself blocked past 20s (bridge_run_command_with_pgroup_timeout did NOT bound the hang — the wedge is back)"
elif [[ "$t1_rc" == "124" ]]; then
  _pass "T1 hung scan → bridge_run_command_with_pgroup_timeout returned 124 (timeout) in ~${t1_elapsed:-?}s, NOT forever"
else
  _fail "T1 hang-bounded" "expected rc 124 from the helper, got rc='${t1_rc:-NONE}' (out: $(tr '\n' '|' <"$T1_OUT"))"
fi

if [[ -n "$t1_elapsed" ]] && (( t1_elapsed <= 10 )); then
  _pass "T1b elapsed ${t1_elapsed}s within the ceiling+grace window (<=10s for a 2s ceiling)"
elif [[ -n "$t1_elapsed" ]]; then
  _fail "T1b ceiling" "helper took ${t1_elapsed}s for a 2s ceiling — exceeds the grace window"
else
  _fail "T1b ceiling" "no ELAPSED captured (out: $(tr '\n' '|' <"$T1_OUT"))"
fi

# T2 — no orphan: the SIGTERM-ignoring grandchild must be DEAD now.
# Give the kernel a beat to finish reaping the group.
sleep 1
gc_pid="$(cat "$GRANDCHILD_PID_FILE" 2>/dev/null || true)"
if [[ -z "$gc_pid" || ! "$gc_pid" =~ ^[0-9]+$ ]]; then
  _fail "T2 no-orphan" "could not read grandchild pid (the hang stub never forked? out: $(tr '\n' '|' <"$T1_OUT"))"
elif kill -0 "$gc_pid" 2>/dev/null; then
  # Still alive → the group kill missed it. Clean it up so we don't leak.
  kill -KILL "$gc_pid" 2>/dev/null || true
  _fail "T2 no-orphan" "SIGTERM-ignoring grandchild pid=$gc_pid SURVIVED the timeout — a direct-child-only kill leaked it (the orphan the wedge fix must prevent)"
else
  _pass "T2 SIGTERM-ignoring grandchild (pid=$gc_pid) was GROUP-KILLED on timeout — no orphan left spinning"
fi

# ---------------------------------------------------------------------------
# T3: normal fast scan path (no regression).
# ---------------------------------------------------------------------------
FAST_SCAN="$SMOKE_DIR/fast-scan.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "# watchdog report\\nall good\\n"\n'
} >"$FAST_SCAN"
chmod +x "$FAST_SCAN"

T3_DRIVER="$SMOKE_DIR/t3-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'FAST_SCAN="$1"\n'
  printf 'STDOUT_FILE="$2"\n'
  printf 'bridge_audit_log() { :; }\n'
  printf 'source "%s"\n' "$HELPER_FUNCS"
  printf 'bridge_run_command_with_pgroup_timeout 30 daemon_watchdog_scan_report "$STDOUT_FILE" bash "$FAST_SCAN"\n'
  printf 'printf "RC=%%s\\n" "$?"\n'
} >"$T3_DRIVER"

T3_OUT="$SMOKE_DIR/t3.out"
T3_STDOUT="$SMOKE_DIR/t3-stdout"
bash "$T3_DRIVER" "$FAST_SCAN" "$T3_STDOUT" >"$T3_OUT" 2>&1
t3_rc="$(grep -oE 'RC=[0-9]+' "$T3_OUT" 2>/dev/null | head -1 | cut -d= -f2)"

if [[ "$t3_rc" == "0" ]]; then
  _pass "T3 fast scan → rc 0 (no false timeout on the healthy path)"
else
  _fail "T3 fast-path-rc" "expected rc 0, got '${t3_rc:-NONE}' (out: $(tr '\n' '|' <"$T3_OUT"))"
fi
if [[ -s "$T3_STDOUT" ]] && grep -q "all good" "$T3_STDOUT" 2>/dev/null; then
  _pass "T3b fast scan stdout captured to the report file (markdown body preserved)"
else
  _fail "T3b fast-path-capture" "report file missing/empty or wrong content (got: $(tr '\n' '|' <"$T3_STDOUT" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# T4: static-assert the wiring in process_watchdog_report.
# ---------------------------------------------------------------------------
GATE_BLOCK="$SMOKE_DIR/gate.sh"
awk '
  /^process_watchdog_report\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}[[:space:]]*$/ { capture=0 }
' "$DAEMON_SH" >"$GATE_BLOCK"

if [[ ! -s "$GATE_BLOCK" ]]; then
  _fail "T4 extract-gate" "could not extract process_watchdog_report from bridge-daemon.sh"
else
  # The bare un-bounded markdown scan must be GONE: a `scan >"$report_file"`
  # NOT preceded by a timeout wrapper on the same line. We assert the
  # hardened shape positively (both scans through the pgroup helper) and the
  # un-hardened shape negatively.
  bare_hits="$(grep -cE 'bridge-watchdog\.sh" scan >"\$report_file"' "$GATE_BLOCK" 2>/dev/null | tr -dc '0-9' | head -c 8)"
  : "${bare_hits:=0}"
  if (( bare_hits == 0 )); then
    _pass "T4 the bare un-timeout-wrapped 'scan >\$report_file' call is GONE from process_watchdog_report"
  else
    _fail "T4 bare-scan-present" "found $bare_hits bare un-bounded 'scan >\$report_file' call(s) — the wedge would return"
  fi

  pgroup_hits="$(grep -cE 'bridge_run_command_with_pgroup_timeout' "$GATE_BLOCK" 2>/dev/null | tr -dc '0-9' | head -c 8)"
  : "${pgroup_hits:=0}"
  if (( pgroup_hits >= 2 )); then
    _pass "T4b both scans (markdown + --json) route through bridge_run_command_with_pgroup_timeout ($pgroup_hits call sites)"
  else
    _fail "T4b pgroup-wiring" "expected >=2 bridge_run_command_with_pgroup_timeout call sites in the gate, found $pgroup_hits"
  fi
fi

# ---------------------------------------------------------------------------
# T5: flapping-monitor coupling (codex r1) — a healthy operator-RAISED
# watchdog scan ceiling must WIDEN the PR-2 self-abort deadline, never trip it.
# The watchdog scan ceiling (BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS) must be in
# the supervisor's resolved-max-step knob list, AND process_watchdog_report
# must pulse daemon progress BETWEEN the two back-to-back scans so each is its
# own bounded step within the freshness window.
# ---------------------------------------------------------------------------
CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
if [[ -r "$CONTROL_LIB" ]]; then
  raised_deadline="$(BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS=900 bash -c "source '$CONTROL_LIB'; bridge_daemon_tick_deadline_seconds" 2>/dev/null)"
  if [[ "$raised_deadline" =~ ^[0-9]+$ ]] && (( raised_deadline > 900 )); then
    _pass "T5 raised BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS=900 widens the T1 deadline to ${raised_deadline}s (>900) — no false-abort of a healthy raised watchdog scan"
  else
    _fail "T5 watchdog-ceiling-coupling" "expected deadline >900 with watchdog=900, got '${raised_deadline:-NONE}' — BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS not coupled into _BRIDGE_DAEMON_TICK_STEP_TIMEOUT_KNOBS (the PR-2 self-abort would kill a healthy raised scan)"
  fi
else
  _fail "T5 watchdog-ceiling-coupling" "lib/bridge-daemon-control.sh not readable at $CONTROL_LIB"
fi

# Progress pulse BETWEEN the two scans (so the worst-case progress gap is one
# scan, not 2x). Assert the mid-phase mark exists in the gate body.
if [[ -s "$GATE_BLOCK" ]]; then
  if grep -qE '_bridge_daemon_mark_progress "watchdog_scan_json"' "$GATE_BLOCK" 2>/dev/null; then
    _pass "T5b process_watchdog_report pulses progress BETWEEN the markdown and --json scans (each scan is its own bounded step)"
  else
    _fail "T5b mid-phase-progress" "no _bridge_daemon_mark_progress between the two scans — the 2x-ceiling progress gap could blow the PR-2 freshness window on a raised ceiling"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n[1563-pr6] %d/%d assertions passed\n' "$((TOTAL - FAILS))" "$TOTAL"
if (( FAILS > 0 )); then
  printf '[1563-pr6] %d FAILED\n' "$FAILS" >&2
  exit 1
fi
exit 0
