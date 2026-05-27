#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/D-beta4-daemon-lifecycle.sh —
# v0.15.0-beta4 Lane D — daemon singleton spawn guard (issue #1276).
#
# Background:
#   On patch's beta3 fresh install (cm-prod-AgentWorkflow-vm01) two
#   daemon processes were observed running simultaneously:
#     PID 140897    — installer-spawned, `daemon_started` audit emit OK
#     PID 1186715/1186719 — sudo-wrapped, audit emit ABSENT
#   Both polled state/tasks.db → duplicate `session_nudge_dropped` rows
#   for the same task, dedup cooldown stacked on top, operator-perceived
#   nudge latency was 5-10min. Root: daemon spawn entry single-point
#   guard absent; PID-file flock absent; `daemon_started` audit emit
#   not forced on every spawn path (sudo-wrapped `bridge-daemon.sh run`
#   bypassed cmd_start's emit entirely).
#
# Fix shape (this smoke pins):
#   - `bridge_daemon_ensure_singleton` (lib/bridge-daemon-control.sh):
#     flock-guarded singleton entry. NON-BLOCKING `flock -n` on
#     ${BRIDGE_DAEMON_PID_FILE}.lock, evicts stale-but-living
#     bridge-daemon (TERM + 10s + KILL), atomic PID-file write,
#     emits canonical `daemon_started` audit row with pid +
#     parent_pid + wrapper + sudo_self fields. r2: lock fd held for
#     the holder's process lifetime — competitors abort, never evict.
#   - cmd_run (bridge-daemon.sh) calls ensure_singleton at the very
#     top so EVERY spawn path crosses it (cmd_start fork, direct
#     `bridge-daemon.sh run`, sudo-wrapped, systemd ExecStart).
#   - cmd_start no longer emits `daemon_started` itself — that row is
#     now the canonical singleton-emit; cmd_start instead emits
#     `daemon_start_supervised` for back-compat operator tooling.
#   - `bridge_daemon_self_check` (lib/bridge-daemon-control.sh) called
#     from cmd_run's main loop on each heartbeat boundary — compares
#     $$ against the latest `daemon_started` audit pid; mismatch ->
#     `daemon_pid_mismatch` audit row + bridge_warn + HIGH-priority
#     operator alert task pushed to the admin agent via bridge-task.sh
#     (r2 BLOCKING #1 — audit-only was not operator-visible).
#
# Tests (host-agnostic — extract the helper into an isolated harness +
# drive with stubs; do NOT spawn the real bridge-daemon.sh, that needs
# the full roster/state ladder and would require a live tmux):
#
#   T1: first spawn — ensure_singleton acquires lock, writes PID file,
#       emits `daemon_started` audit row with pid + parent_pid + wrapper
#       + sudo_self fields.
#
#   T2: second spawn (concurrent, mid-critical-section) — second
#       ensure_singleton call returns non-zero, emits
#       `daemon_spawn_lock_busy` audit row with lock_mode=flock_n.
#
#   T2b (r2): second spawn AFTER first spawn completes + holder still
#       running — competitor must abort (process-lifetime lock hold).
#       PID file unchanged, healthy holder NOT evicted.
#
#   T2c (r2): proof of process-lifetime lock fd hold — after holder
#       returns from ensure_singleton, the lockfile is in the holder
#       process's open-fd set (/proc/<pid>/fd or lsof).
#
#   T3: first daemon dead (PID file stale) — second ensure_singleton on
#       a freed lock succeeds; no TERM/KILL sent (existing pid is dead).
#
#   T4: first daemon alive (hang scenario) — ensure_singleton with a
#       living pid in the file → TERM sent, wait, then PID-file claimed;
#       emits `daemon_spawn_replacing` audit row.
#
#   T5: bridge_daemon_self_check — self_pid != latest audit pid →
#       emits `daemon_pid_mismatch` audit row.
#
#   T6 (teeth): revert R1 fix — ensure_singleton helper neutered → T1
#       reproduces the issue #1276 audit-emit gap.
#
#   T7: all spawn sites route through ensure_singleton — static-source
#       grep against bridge-daemon.sh confirms cmd_run calls
#       bridge_daemon_ensure_singleton before the existing
#       `echo "$$" >$BRIDGE_DAEMON_PID_FILE` site.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses `grep -n` against the source files OR builds harness
# scripts with `printf '%s\n' >file` and runs them as external scripts.
# No `<<<` here-string or `<<EOF` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="D-beta4-daemon-lifecycle"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap (next line), not a direct call.
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"

[[ -f "$DAEMON_CONTROL_LIB" ]] || smoke_fail "missing $DAEMON_CONTROL_LIB"
[[ -f "$DAEMON_SH" ]]          || smoke_fail "missing $DAEMON_SH"

mkdir -p "$BRIDGE_HOME/state" "$BRIDGE_HOME/logs"
export BRIDGE_DAEMON_PID_FILE="$BRIDGE_HOME/state/daemon.pid"
export BRIDGE_AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"
: >"$BRIDGE_AUDIT_LOG"

# ---------------------------------------------------------------------
# Helper: extract bridge_daemon_ensure_singleton +
# bridge_daemon_self_check + internal helpers into an isolated harness
# script. Stubs `bridge_audit_log` to append a structured key=value
# JSON-ish line to the smoke audit log so the assertion grammar is
# stable regardless of the real bridge-audit.py shape.
# ---------------------------------------------------------------------
extract_singleton_lib() {
  local source="$DAEMON_CONTROL_LIB"
  local out="$SMOKE_TMP_ROOT/singleton-extract.sh"
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    # Stubs: bridge_warn, bridge_die, bridge_audit_log. The real audit
    # writer needs python3 + bridge-audit.py; the stub appends a single
    # JSON line keyed by --detail kv pairs so smoke assertions can grep
    # for action + detail fields directly.
    printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
    printf '%s\n' 'bridge_die() { printf "[die] %s\n" "$*" >&2; exit 1; }'
    printf '%s\n' 'bridge_audit_log() {'
    printf '%s\n' '  local actor="$1" action="$2" target="$3"'
    printf '%s\n' '  shift 3 || true'
    printf '%s\n' '  local detail_str="actor=$actor|action=$action|target=$target"'
    printf '%s\n' '  while (( $# > 0 )); do'
    printf '%s\n' '    if [[ "$1" == "--detail" ]]; then'
    printf '%s\n' '      detail_str+="|${2:-}"'
    printf '%s\n' '      shift 2'
    printf '%s\n' '    else'
    printf '%s\n' '      shift'
    printf '%s\n' '    fi'
    printf '%s\n' '  done'
    printf '%s\n' '  printf "%s\n" "$detail_str" >> "${BRIDGE_AUDIT_LOG:-/dev/null}"'
    printf '%s\n' '}'
    awk '/^_bridge_daemon_singleton_lock_path\(\) \{/,/^\}/' "$source"
    awk '/^_bridge_daemon_singleton_cmdline\(\) \{/,/^\}/' "$source"
    awk '/^bridge_daemon_ensure_singleton\(\) \{/,/^\}/' "$source"
    awk '/^bridge_daemon_self_check\(\) \{/,/^\}/' "$source"
  } >>"$out"
  chmod +x "$out"
  printf '%s\n' "$out"
}

SINGLETON_LIB="$(extract_singleton_lib)"

# ---------------------------------------------------------------------
# T1: first spawn — ensure_singleton emits `daemon_started` with pid +
# parent_pid + wrapper + sudo_self fields.
# ---------------------------------------------------------------------
smoke_log "T1: first ensure_singleton spawn emits daemon_started with pid + parent_pid + wrapper + sudo_self"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.lock"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
: >"$T1_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\npid=%s\n" "$rc" "$$"'
} >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_OUT="$(/usr/bin/env bash "$T1_DRIVER" 2>&1)"
T1_DRIVER_PID="$(printf '%s\n' "$T1_OUT" | awk -F= '/^pid=/ {print $2}')"
T1_RC="$(printf '%s\n' "$T1_OUT" | awk -F= '/^rc=/ {print $2}')"

if [[ "$T1_RC" != "0" ]]; then
  smoke_fail "T1: ensure_singleton returned rc=$T1_RC (expected 0). Out: $T1_OUT"
fi
if [[ ! -f "$BRIDGE_DAEMON_PID_FILE" ]]; then
  smoke_fail "T1: PID file $BRIDGE_DAEMON_PID_FILE was not written"
fi
T1_RECORDED_PID="$(cat "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"
if [[ "$T1_RECORDED_PID" != "$T1_DRIVER_PID" ]]; then
  smoke_fail "T1: PID file recorded $T1_RECORDED_PID, expected $T1_DRIVER_PID"
fi
if ! grep -q 'action=daemon_started' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T1: daemon_started audit row not emitted; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if ! grep -q "pid=$T1_DRIVER_PID" "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T1: daemon_started audit row missing pid=$T1_DRIVER_PID; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if ! grep -q 'parent_pid=' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T1: daemon_started audit row missing parent_pid field; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if ! grep -q 'wrapper=' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T1: daemon_started audit row missing wrapper field; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if ! grep -q 'sudo_self=' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T1: daemon_started audit row missing sudo_self field; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
smoke_log "T1 PASS — first ensure_singleton emits daemon_started with pid + parent_pid + wrapper + sudo_self"

# ---------------------------------------------------------------------
# T2: concurrent second spawn during the critical section → lock busy
# (in-flight ensure_singleton case).
#
# r2 semantics: the lock is non-blocking `flock -n` and held for the
# holder's process lifetime. To force a real contention window we
# pre-stage a living bridge-daemon-shaped process in the PID file. The
# holder enters ensure_singleton, hits the TERM-and-wait branch (which
# holds the lock for up to 10s while the fake daemon refuses to exit),
# and the competitor sees `daemon_spawn_lock_busy` immediately via
# `flock -n` (no wait). Note: lock_mode=flock_n on the audit row.
# ---------------------------------------------------------------------
smoke_log "T2: second concurrent ensure_singleton returns rc!=0 + emits daemon_spawn_lock_busy"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.lock"

# Stage a long-running sleeper that ignores SIGTERM so the holder must
# fall through to the 10s wait. PATH-shimmed `ps` reports it as
# bridge-daemon for the eviction branch.
T2_VICTIM_TRAP="$SMOKE_TMP_ROOT/t2-victim-trap.sh"
: >"$T2_VICTIM_TRAP"
{
  printf '%s\n' '#!/usr/bin/env bash'
  # Ignore SIGTERM so the holder's TERM has no effect → it has to wait
  # the full 10s before falling through to KILL. The lock stays held
  # for the duration.
  printf '%s\n' 'trap "" TERM'
  printf '%s\n' 'sleep 30'
} >>"$T2_VICTIM_TRAP"
chmod +x "$T2_VICTIM_TRAP"

/usr/bin/env bash "$T2_VICTIM_TRAP" &
T2_VICTIM_PID=$!
printf '%s\n' "$T2_VICTIM_PID" >"$BRIDGE_DAEMON_PID_FILE"

T2_SHIM="$SMOKE_TMP_ROOT/t2-shim"
mkdir -p "$T2_SHIM"
: >"$T2_SHIM/ps"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\n" "bridge-daemon.sh run"'
} >>"$T2_SHIM/ps"
chmod +x "$T2_SHIM/ps"

T2_HOLDER="$SMOKE_TMP_ROOT/t2-holder.sh"
: >"$T2_HOLDER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "export PATH=\"$T2_SHIM:\$PATH\""
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T2_HOLDER"
chmod +x "$T2_HOLDER"

T2_HOLDER_OUT_FILE="$SMOKE_TMP_ROOT/t2-holder.out"
/usr/bin/env bash "$T2_HOLDER" >"$T2_HOLDER_OUT_FILE" 2>&1 &
T2_HOLDER_PID=$!

# Give the holder a moment to acquire the lock and enter the TERM-wait.
sleep 1

T2_COMPETITOR="$SMOKE_TMP_ROOT/t2-competitor.sh"
: >"$T2_COMPETITOR"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  # r2: non-blocking `flock -n` — the competitor returns immediately
  # without waiting. No timeout env needed.
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T2_COMPETITOR"
chmod +x "$T2_COMPETITOR"

T2_OUT="$(/usr/bin/env bash "$T2_COMPETITOR" 2>&1)"
T2_RC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^rc=/ {print $2}')"

# Cleanup: kill the trap-ignoring victim hard, then wait for the holder
# to finish its KILL-fallback path and exit.
kill -KILL "$T2_VICTIM_PID" 2>/dev/null || true
wait "$T2_VICTIM_PID" 2>/dev/null || true
wait "$T2_HOLDER_PID" 2>/dev/null || true

if [[ "$T2_RC" == "0" ]]; then
  smoke_fail "T2: concurrent ensure_singleton returned rc=0 (expected non-zero — lock should have been busy). Out: $T2_OUT, holder out: $(cat "$T2_HOLDER_OUT_FILE" 2>/dev/null || true)"
fi
if ! grep -q 'action=daemon_spawn_lock_busy' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T2: daemon_spawn_lock_busy audit row not emitted; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
# r2 non-blocking marker: `lock_mode=flock_n` on flock backend (Linux),
# `lock_mode=non_blocking` on mkdir fallback (macOS dev hosts without
# util-linux flock). Either is a valid r2 contract proof.
if ! grep -qE 'lock_mode=(flock_n|non_blocking)' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T2: daemon_spawn_lock_busy audit row missing r2 non-blocking marker (lock_mode=flock_n or lock_mode=non_blocking); audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
smoke_log "T2 PASS — concurrent ensure_singleton during critical section refuses + emits daemon_spawn_lock_busy (r2 non-blocking marker present)"

# ---------------------------------------------------------------------
# T2b (r2 BLOCKING #2 — common case): first spawn COMPLETES + still
# running. Process-lifetime lock-hold means a second ensure_singleton
# while the first daemon process is alive must abort with
# `daemon_spawn_lock_busy` (does NOT evict the healthy first daemon).
#
# Shape: long-running holder script sources the singleton lib, calls
# ensure_singleton (completes normally), then sleeps to keep the lock
# fd open. While the holder is sleeping, a competitor invocation must
# see `flock -n` busy + emit `daemon_spawn_lock_busy`. PID file
# content must remain the holder's PID (no eviction).
# ---------------------------------------------------------------------
smoke_log "T2b: first spawn done + still running → competitor ensure_singleton aborts (process-lifetime lock)"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.lock"

T2B_HOLDER_DONE_MARK="$SMOKE_TMP_ROOT/t2b-holder-done.mark"
T2B_HOLDER_PID_RECORD="$SMOKE_TMP_ROOT/t2b-holder.pid"
rm -f "$T2B_HOLDER_DONE_MARK" "$T2B_HOLDER_PID_RECORD" 2>/dev/null || true

T2B_HOLDER="$SMOKE_TMP_ROOT/t2b-holder.sh"
: >"$T2B_HOLDER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' "printf '%s\\n' \"\$\$\" >\"$T2B_HOLDER_PID_RECORD\""
  printf '%s\n' "printf 'rc=%s\\n' \"\$rc\" >\"$T2B_HOLDER_DONE_MARK\""
  # Keep the process alive so the kernel keeps the flock held. Sleep
  # generously; the test cleanup kills it.
  printf '%s\n' 'sleep 60'
} >>"$T2B_HOLDER"
chmod +x "$T2B_HOLDER"

/usr/bin/env bash "$T2B_HOLDER" >/dev/null 2>&1 &
T2B_HOLDER_BG_PID=$!

# Wait for the holder to finish ensure_singleton (mark file present).
T2B_WAITED=0
while [[ ! -f "$T2B_HOLDER_DONE_MARK" ]] && (( T2B_WAITED < 10 )); do
  sleep 1
  T2B_WAITED=$(( T2B_WAITED + 1 ))
done
if [[ ! -f "$T2B_HOLDER_DONE_MARK" ]]; then
  kill -KILL "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  wait "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  smoke_fail "T2b: holder ensure_singleton did not complete within 10s"
fi
T2B_HOLDER_RC="$(awk -F= '/^rc=/ {print $2}' "$T2B_HOLDER_DONE_MARK")"
if [[ "$T2B_HOLDER_RC" != "0" ]]; then
  kill -KILL "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  wait "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  smoke_fail "T2b: holder ensure_singleton returned rc=$T2B_HOLDER_RC (expected 0)"
fi
T2B_HOLDER_PID="$(tr -dc '0-9' <"$T2B_HOLDER_PID_RECORD" 2>/dev/null || true)"
if [[ -z "$T2B_HOLDER_PID" ]]; then
  kill -KILL "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  wait "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  smoke_fail "T2b: could not read holder pid record"
fi
# Sanity: the PID file should now hold the holder's PID.
T2B_PIDFILE_VAL="$(cat "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"
if [[ "$T2B_PIDFILE_VAL" != "$T2B_HOLDER_PID" ]]; then
  kill -KILL "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  wait "$T2B_HOLDER_BG_PID" 2>/dev/null || true
  smoke_fail "T2b: PID file holds $T2B_PIDFILE_VAL but holder PID is $T2B_HOLDER_PID"
fi

# Now run a competitor — holder is sleeping, lock still held.
T2B_COMPETITOR="$SMOKE_TMP_ROOT/t2b-competitor.sh"
: >"$T2B_COMPETITOR"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T2B_COMPETITOR"
chmod +x "$T2B_COMPETITOR"

T2B_COMPETITOR_OUT="$(/usr/bin/env bash "$T2B_COMPETITOR" 2>&1)"
T2B_COMPETITOR_RC="$(printf '%s\n' "$T2B_COMPETITOR_OUT" | awk -F= '/^rc=/ {print $2}')"

# Verify holder is still alive and PID file unchanged (no eviction).
T2B_HOLDER_STILL_ALIVE=0
if kill -0 "$T2B_HOLDER_PID" 2>/dev/null; then
  T2B_HOLDER_STILL_ALIVE=1
fi
T2B_PIDFILE_AFTER="$(cat "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"

# Cleanup holder.
kill -KILL "$T2B_HOLDER_BG_PID" 2>/dev/null || true
wait "$T2B_HOLDER_BG_PID" 2>/dev/null || true

if [[ "$T2B_COMPETITOR_RC" == "0" ]]; then
  smoke_fail "T2b: competitor ensure_singleton returned rc=0 (expected non-zero — process-lifetime lock should be held). Out: $T2B_COMPETITOR_OUT"
fi
if (( T2B_HOLDER_STILL_ALIVE != 1 )); then
  smoke_fail "T2b: holder PID $T2B_HOLDER_PID died — competitor must NOT evict a healthy holder under r2 contract"
fi
if [[ "$T2B_PIDFILE_AFTER" != "$T2B_HOLDER_PID" ]]; then
  smoke_fail "T2b: PID file mutated from $T2B_HOLDER_PID to $T2B_PIDFILE_AFTER — competitor must not rewrite a healthy holder's PID slot"
fi
if ! grep -q 'action=daemon_spawn_lock_busy' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T2b: daemon_spawn_lock_busy audit row not emitted; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if ! grep -qE 'lock_mode=(flock_n|non_blocking)' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T2b: daemon_spawn_lock_busy missing r2 non-blocking marker (lock_mode=flock_n or non_blocking); audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
smoke_log "T2b PASS — common-case process-lifetime lock holds; competitor aborts cleanly without evicting healthy holder"

# ---------------------------------------------------------------------
# T2c (r2 BLOCKING #2 — process-lifetime lock verify): after a
# successful ensure_singleton, the holder process must keep the lock
# resource held. Backend-aware proof:
#   - flock backend (Linux + util-linux flock): lockfile fd in the
#     holder's open-fd set (/proc/<pid>/fd or lsof). We do not require
#     a specific fd number (the helper uses `exec {lock_fd}>` which
#     kernel-assigns).
#   - mkdir backend (macOS dev hosts without flock): the lockdir
#     ($LOCKFILE.d) must still exist (it is only removed on explicit
#     `_bridge_daemon_singleton_release_lock`, which we don't call on
#     the success path) AND owner.pid inside must match the holder.
# ---------------------------------------------------------------------
smoke_log "T2c: lock resource held for holder process lifetime (backend-aware)"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.lock"

T2C_HOLDER_DONE_MARK="$SMOKE_TMP_ROOT/t2c-holder-done.mark"
T2C_HOLDER_PID_RECORD="$SMOKE_TMP_ROOT/t2c-holder.pid"
rm -f "$T2C_HOLDER_DONE_MARK" "$T2C_HOLDER_PID_RECORD" 2>/dev/null || true

T2C_HOLDER="$SMOKE_TMP_ROOT/t2c-holder.sh"
: >"$T2C_HOLDER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' "printf '%s\\n' \"\$\$\" >\"$T2C_HOLDER_PID_RECORD\""
  printf '%s\n' "printf 'rc=%s\\n' \"\$rc\" >\"$T2C_HOLDER_DONE_MARK\""
  printf '%s\n' 'sleep 30'
} >>"$T2C_HOLDER"
chmod +x "$T2C_HOLDER"

/usr/bin/env bash "$T2C_HOLDER" >/dev/null 2>&1 &
T2C_HOLDER_BG_PID=$!

T2C_WAITED=0
while [[ ! -f "$T2C_HOLDER_DONE_MARK" ]] && (( T2C_WAITED < 10 )); do
  sleep 1
  T2C_WAITED=$(( T2C_WAITED + 1 ))
done
if [[ ! -f "$T2C_HOLDER_DONE_MARK" ]]; then
  kill -KILL "$T2C_HOLDER_BG_PID" 2>/dev/null || true
  wait "$T2C_HOLDER_BG_PID" 2>/dev/null || true
  smoke_fail "T2c: holder ensure_singleton did not complete within 10s"
fi
T2C_HOLDER_PID="$(tr -dc '0-9' <"$T2C_HOLDER_PID_RECORD" 2>/dev/null || true)"
if [[ -z "$T2C_HOLDER_PID" ]]; then
  kill -KILL "$T2C_HOLDER_BG_PID" 2>/dev/null || true
  wait "$T2C_HOLDER_BG_PID" 2>/dev/null || true
  smoke_fail "T2c: could not read holder pid record"
fi

# Backend-aware proof of process-lifetime lock hold.
LOCK_FILE_REAL="${BRIDGE_DAEMON_PID_FILE}.lock"
LOCK_DIR_REAL="${LOCK_FILE_REAL}.d"
LOCK_HELD=0
LOCK_PROBE_BACKEND=""

# Try flock backend proof first (fd-scan).
if command -v flock >/dev/null 2>&1; then
  if [[ -d "/proc/$T2C_HOLDER_PID/fd" ]]; then
    LOCK_PROBE_BACKEND="flock+proc"
    for fd_link in "/proc/$T2C_HOLDER_PID/fd"/*; do
      [[ -L "$fd_link" ]] || continue
      target="$(readlink -- "$fd_link" 2>/dev/null || true)"
      if [[ "$target" == "$LOCK_FILE_REAL" ]]; then
        LOCK_HELD=1
        break
      fi
    done
  elif command -v lsof >/dev/null 2>&1; then
    LOCK_PROBE_BACKEND="flock+lsof"
    if lsof -p "$T2C_HOLDER_PID" 2>/dev/null | awk '{print $NF}' | grep -Fxq -- "$LOCK_FILE_REAL"; then
      LOCK_HELD=1
    fi
  fi
fi

# If flock backend probe didn't find the fd, the install may have
# fallen back to mkdir-as-lock (macOS dev path). Verify the lockdir.
if (( LOCK_HELD != 1 )) && [[ -d "$LOCK_DIR_REAL" ]]; then
  LOCK_PROBE_BACKEND="${LOCK_PROBE_BACKEND:+$LOCK_PROBE_BACKEND,}mkdir"
  owner_pid_val=""
  if [[ -r "$LOCK_DIR_REAL/owner.pid" ]]; then
    owner_pid_val="$(tr -dc '0-9' <"$LOCK_DIR_REAL/owner.pid" 2>/dev/null || true)"
  fi
  if [[ "$owner_pid_val" == "$T2C_HOLDER_PID" ]]; then
    LOCK_HELD=1
  fi
fi

# Fallback: no /proc, no lsof, no lockdir — host-agnostic skip so we
# don't fail on barebones containers.
if (( LOCK_HELD != 1 )) && [[ -z "$LOCK_PROBE_BACKEND" ]]; then
  smoke_log "T2c: no /proc/<pid>/fd, no lsof, no lockdir — process-lifetime verify skipped on this host"
  LOCK_HELD=1
  LOCK_PROBE_BACKEND="skipped"
fi

# Cleanup holder.
kill -KILL "$T2C_HOLDER_BG_PID" 2>/dev/null || true
wait "$T2C_HOLDER_BG_PID" 2>/dev/null || true

if (( LOCK_HELD != 1 )); then
  smoke_fail "T2c: holder PID $T2C_HOLDER_PID did not retain lock resource (backend=$LOCK_PROBE_BACKEND, lock_file=$LOCK_FILE_REAL, lock_dir=$LOCK_DIR_REAL) — process-lifetime hold contract broken"
fi
smoke_log "T2c PASS — holder retained lock resource across return from ensure_singleton (backend=$LOCK_PROBE_BACKEND)"

# ---------------------------------------------------------------------
# T3: first daemon dead (stale PID file) → new ensure_singleton claims
# successfully without TERM/KILL.
# ---------------------------------------------------------------------
smoke_log "T3: dead-PID stale file → ensure_singleton succeeds, no replacing emit"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.lock"
# Write a definitely-dead PID into the file.
DEAD_PID=99999
while kill -0 "$DEAD_PID" 2>/dev/null; do
  DEAD_PID=$(( DEAD_PID + 1 ))
done
printf '%s\n' "$DEAD_PID" >"$BRIDGE_DAEMON_PID_FILE"

T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
: >"$T3_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\npid=%s\n" "$rc" "$$"'
} >>"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_OUT="$(/usr/bin/env bash "$T3_DRIVER" 2>&1)"
T3_RC="$(printf '%s\n' "$T3_OUT" | awk -F= '/^rc=/ {print $2}')"
T3_DRIVER_PID="$(printf '%s\n' "$T3_OUT" | awk -F= '/^pid=/ {print $2}')"

if [[ "$T3_RC" != "0" ]]; then
  smoke_fail "T3: ensure_singleton over stale PID returned rc=$T3_RC. Out: $T3_OUT"
fi
T3_RECORDED_PID="$(cat "$BRIDGE_DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"
if [[ "$T3_RECORDED_PID" != "$T3_DRIVER_PID" ]]; then
  smoke_fail "T3: PID file recorded $T3_RECORDED_PID, expected $T3_DRIVER_PID"
fi
if grep -q 'action=daemon_spawn_replacing' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T3: daemon_spawn_replacing audit row emitted on a dead PID — should be no-op replace"
fi
smoke_log "T3 PASS — stale dead PID claims succeed without replace-emit"

# ---------------------------------------------------------------------
# T4: living bridge-daemon-shaped process → ensure_singleton TERMs it +
# emits daemon_spawn_replacing. Use a fake `ps` shim so the helper sees
# the existing PID's cmdline as a bridge-daemon match.
# ---------------------------------------------------------------------
smoke_log "T4: living bridge-daemon-shaped process → ensure_singleton evicts + emits daemon_spawn_replacing"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE" "$BRIDGE_DAEMON_PID_FILE.lock"

# Background sleeper acts as the "existing daemon"; we lie about its
# cmdline via a PATH-shimmed `ps`.
T4_SLEEPER_FIFO="$SMOKE_TMP_ROOT/t4-sleeper.fifo"
mkfifo "$T4_SLEEPER_FIFO" 2>/dev/null || true
sleep 60 &
T4_EXISTING_PID=$!
printf '%s\n' "$T4_EXISTING_PID" >"$BRIDGE_DAEMON_PID_FILE"

# Build PS shim that reports the sleeper as `bridge-daemon.sh run`.
T4_SHIM="$SMOKE_TMP_ROOT/t4-shim"
mkdir -p "$T4_SHIM"
: >"$T4_SHIM/ps"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'while (( $# > 0 )); do'
  printf '%s\n' '  case "$1" in'
  printf '%s\n' '    -p) shift; QUERY_PID="$1"; shift ;;'
  printf '%s\n' '    -o) shift; QUERY_FMT="$1"; shift ;;'
  printf '%s\n' '    *) shift ;;'
  printf '%s\n' '  esac'
  printf '%s\n' 'done'
  printf '%s\n' 'printf "%s\n" "bridge-daemon.sh run"'
} >>"$T4_SHIM/ps"
chmod +x "$T4_SHIM/ps"

T4_DRIVER="$SMOKE_TMP_ROOT/t4-driver.sh"
: >"$T4_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "export PATH=\"$T4_SHIM:\$PATH\""
  printf '%s\n' "source \"$SINGLETON_LIB\""
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\npid=%s\n" "$rc" "$$"'
} >>"$T4_DRIVER"
chmod +x "$T4_DRIVER"

T4_OUT="$(/usr/bin/env bash "$T4_DRIVER" 2>&1)"
T4_RC="$(printf '%s\n' "$T4_OUT" | awk -F= '/^rc=/ {print $2}')"

# Reap the (now killed) sleeper.
wait "$T4_EXISTING_PID" 2>/dev/null || true

if [[ "$T4_RC" != "0" ]]; then
  smoke_fail "T4: ensure_singleton with living daemon returned rc=$T4_RC. Out: $T4_OUT"
fi
if ! grep -q 'action=daemon_spawn_replacing' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T4: daemon_spawn_replacing audit row not emitted; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if ! grep -q "existing_pid=$T4_EXISTING_PID" "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T4: daemon_spawn_replacing missing existing_pid=$T4_EXISTING_PID; audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
if kill -0 "$T4_EXISTING_PID" 2>/dev/null; then
  smoke_fail "T4: existing daemon PID $T4_EXISTING_PID still alive — ensure_singleton failed to evict"
fi
smoke_log "T4 PASS — living bridge-daemon-shaped process evicted + daemon_spawn_replacing emitted"

# ---------------------------------------------------------------------
# T5: bridge_daemon_self_check — self_pid != latest audit pid →
# daemon_pid_mismatch row.
# ---------------------------------------------------------------------
smoke_log "T5: bridge_daemon_self_check emits daemon_pid_mismatch on PID divergence"

: >"$BRIDGE_AUDIT_LOG"
# Pre-stage a daemon_started row with a known DIFFERENT pid.
DIFFERENT_PID=12345
printf 'actor=daemon|action=daemon_started|target=daemon|pid=%s|parent_pid=1|wrapper=direct|sudo_self=0\n' "$DIFFERENT_PID" \
  >>"$BRIDGE_AUDIT_LOG"
# Real bridge_daemon_self_check uses python3 to parse audit log JSON.
# Our stubbed audit log writer above emits key=value not JSON, so the
# self_check helper as-shipped wouldn't match. Build a JSON-shaped
# audit log for this test using printf so the helper's python3 reader
# can parse it.
: >"$BRIDGE_AUDIT_LOG"
printf '%s\n' '{"actor":"daemon","action":"daemon_started","target":"daemon","detail":{"pid":12345,"parent_pid":1,"wrapper":"direct","sudo_self":"0"}}' \
  >>"$BRIDGE_AUDIT_LOG"

T5_DRIVER="$SMOKE_TMP_ROOT/t5-driver.sh"
: >"$T5_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Use a DIFFERENT bridge_audit_log stub so the mismatch emit lands in
  # a separate file we can grep — the JSON-shaped pre-staged log above
  # is read by self_check; the helper's mismatch emit goes through
  # bridge_audit_log which writes to BRIDGE_AUDIT_LOG too. To keep the
  # assertions clean, set MISMATCH_LOG via the stub.
  printf '%s\n' 'export MISMATCH_LOG="$SMOKE_TMP_ROOT/t5-mismatch.log"'
  printf '%s\n' ': >"$MISMATCH_LOG"'
  printf '%s\n' "source \"$SINGLETON_LIB\""
  # Override the stub to write to the mismatch log instead, so we don't
  # clobber the pre-staged daemon_started row.
  printf '%s\n' 'bridge_audit_log() {'
  printf '%s\n' '  local actor="$1" action="$2" target="$3"'
  printf '%s\n' '  shift 3 || true'
  printf '%s\n' '  local detail_str="actor=$actor|action=$action|target=$target"'
  printf '%s\n' '  while (( $# > 0 )); do'
  printf '%s\n' '    if [[ "$1" == "--detail" ]]; then'
  printf '%s\n' '      detail_str+="|${2:-}"'
  printf '%s\n' '      shift 2'
  printf '%s\n' '    else'
  printf '%s\n' '      shift'
  printf '%s\n' '    fi'
  printf '%s\n' '  done'
  printf '%s\n' '  printf "%s\n" "$detail_str" >> "$MISMATCH_LOG"'
  printf '%s\n' '}'
  printf '%s\n' 'bridge_daemon_self_check; rc=$?'
  printf '%s\n' 'printf "rc=%s\npid=%s\n" "$rc" "$$"'
} >>"$T5_DRIVER"
chmod +x "$T5_DRIVER"

T5_OUT="$(SMOKE_TMP_ROOT="$SMOKE_TMP_ROOT" BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" /usr/bin/env bash "$T5_DRIVER" 2>&1)"
T5_RC="$(printf '%s\n' "$T5_OUT" | awk -F= '/^rc=/ {print $2}')"
T5_MISMATCH_LOG="$SMOKE_TMP_ROOT/t5-mismatch.log"

if [[ "$T5_RC" == "0" ]]; then
  smoke_fail "T5: self_check returned rc=0 (expected non-zero — PID mismatch). Out: $T5_OUT"
fi
if [[ ! -f "$T5_MISMATCH_LOG" ]]; then
  smoke_fail "T5: mismatch audit log $T5_MISMATCH_LOG was not written"
fi
if ! grep -q 'action=daemon_pid_mismatch' "$T5_MISMATCH_LOG"; then
  smoke_fail "T5: daemon_pid_mismatch row not emitted; mismatch log: $(cat "$T5_MISMATCH_LOG")"
fi
if ! grep -q 'recent_audit_pid=12345' "$T5_MISMATCH_LOG"; then
  smoke_fail "T5: daemon_pid_mismatch row missing recent_audit_pid=12345; mismatch log: $(cat "$T5_MISMATCH_LOG")"
fi
smoke_log "T5 PASS — self_check detects PID mismatch + emits daemon_pid_mismatch"

# ---------------------------------------------------------------------
# T6 (teeth): revert R1 fix — neuter ensure_singleton, assert T1
# behavior regresses (audit emit absent).
# ---------------------------------------------------------------------
smoke_log "T6 (teeth): revert ensure_singleton emit → T1 emit-check fails"

T6_NEUTERED="$SMOKE_TMP_ROOT/t6-neutered.sh"
: >"$T6_NEUTERED"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'bridge_warn() { :; }'
  printf '%s\n' 'bridge_audit_log() { :; }'
  # Neutered helper: just writes PID file, no audit emit. This is the
  # pre-Lane D shape — the issue #1276 root cause.
  printf '%s\n' 'bridge_daemon_ensure_singleton() {'
  printf '%s\n' '  echo "$$" >"$BRIDGE_DAEMON_PID_FILE"'
  printf '%s\n' '  return 0'
  printf '%s\n' '}'
  printf '%s\n' 'bridge_daemon_ensure_singleton; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T6_NEUTERED"
chmod +x "$T6_NEUTERED"

: >"$BRIDGE_AUDIT_LOG"
rm -f "$BRIDGE_DAEMON_PID_FILE"

T6_OUT="$(BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" BRIDGE_DAEMON_PID_FILE="$BRIDGE_DAEMON_PID_FILE" /usr/bin/env bash "$T6_NEUTERED" 2>&1)"
T6_RC="$(printf '%s\n' "$T6_OUT" | awk -F= '/^rc=/ {print $2}')"

# Teeth check: neutered helper returns 0 (claims success) BUT no
# daemon_started audit row. This is exactly the issue #1276 surface.
if [[ "$T6_RC" != "0" ]]; then
  smoke_fail "T6 (teeth): neutered helper unexpectedly failed; expected to reproduce silent-success. Out: $T6_OUT"
fi
if grep -q 'action=daemon_started' "$BRIDGE_AUDIT_LOG"; then
  smoke_fail "T6 (teeth): neutered helper emitted daemon_started — teeth check broken. Audit log: $(cat "$BRIDGE_AUDIT_LOG")"
fi
smoke_log "T6 PASS — teeth check confirms neutered helper reproduces issue #1276 (silent success + missing audit row)"

# ---------------------------------------------------------------------
# T7: static-source audit — bridge-daemon.sh's cmd_run calls
# bridge_daemon_ensure_singleton before any PID-file write, and
# bridge-daemon.sh references it (not just a stale echo). Also confirm
# cmd_start no longer emits daemon_started.
# ---------------------------------------------------------------------
smoke_log "T7: static-source audit — cmd_run routes through bridge_daemon_ensure_singleton; cmd_start no longer emits daemon_started"

if ! grep -q 'bridge_daemon_ensure_singleton' "$DAEMON_SH"; then
  smoke_fail "T7: bridge-daemon.sh does not invoke bridge_daemon_ensure_singleton — Lane D wiring missing"
fi
# Confirm cmd_run wires the helper as an actual invocation (not just a
# comment reference). The call-site grammar is `if ! bridge_daemon_ensure_singleton; then`
# or a bare `bridge_daemon_ensure_singleton` line; comments start with `#`.
CMD_RUN_LINE="$(grep -n '^cmd_run() {' "$DAEMON_SH" | head -n1 | awk -F: '{print $1}')"
# Find the FIRST actual call (not a comment / docstring reference) — line
# must contain ensure_singleton AND start with whitespace + non-`#`.
ENSURE_CALL_LINE="$(grep -nE '^[[:space:]]+(if[[:space:]]+!?[[:space:]]*)?bridge_daemon_ensure_singleton' "$DAEMON_SH" | head -n1 | awk -F: '{print $1}')"
ECHO_LINE="$(grep -n 'echo "\$\$" >"\$BRIDGE_DAEMON_PID_FILE"' "$DAEMON_SH" | head -n1 | awk -F: '{print $1}')"
if [[ -z "$ENSURE_CALL_LINE" ]]; then
  smoke_fail "T7: bridge_daemon_ensure_singleton call site (non-comment) not found in bridge-daemon.sh"
fi
if [[ -z "$CMD_RUN_LINE" ]]; then
  smoke_fail "T7: cmd_run() definition line not found in bridge-daemon.sh"
fi
if (( ENSURE_CALL_LINE <= CMD_RUN_LINE )); then
  smoke_fail "T7: bridge_daemon_ensure_singleton call (line $ENSURE_CALL_LINE) appears at or before cmd_run() definition (line $CMD_RUN_LINE) — wiring misplaced"
fi
# The legacy `echo "$$" >"$BRIDGE_DAEMON_PID_FILE"` site is now a
# fallback inside the `else` branch — confirm it stays AFTER the
# ensure_singleton call (post-Lane D ordering).
if [[ -n "$ECHO_LINE" && "$ECHO_LINE" -le "$ENSURE_CALL_LINE" ]]; then
  smoke_fail "T7: legacy 'echo \$\$ >PID' line (line $ECHO_LINE) appears before ensure_singleton call (line $ENSURE_CALL_LINE) — call order violates Lane D contract"
fi
# Confirm cmd_start no longer emits canonical `daemon_started` — its
# post-spawn emit is now `daemon_start_supervised`.
if ! grep -q 'daemon_start_supervised' "$DAEMON_SH"; then
  smoke_fail "T7: bridge-daemon.sh does not emit daemon_start_supervised in cmd_start — supervisor-emit contract missing"
fi

# Confirm the periodic self-check is wired into cmd_run's main loop.
if ! grep -q 'bridge_daemon_self_check' "$DAEMON_SH"; then
  smoke_fail "T7: bridge_daemon_self_check call site not found in bridge-daemon.sh — R3 visibility wiring missing"
fi
smoke_log "T7 PASS — cmd_run routes through ensure_singleton; cmd_start emits daemon_start_supervised; self_check wired"

# ---------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------
smoke_log "ALL TESTS PASSED — issue #1276 (daemon singleton spawn guard) regression coverage in place"
exit 0
