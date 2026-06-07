#!/usr/bin/env bash
# scripts/smoke/1612-upgrade-restart-receiver.sh
#
# Issue #1612 — `agb upgrade --restart-daemon` must cycle the A2A handoff
# receiver (bridge-handoffd.py, managed via bridge-handoff-daemon.sh).
#
# Root cause: the RESTART_DAEMON branch in bridge-upgrade.sh restarted only
# the main daemon. The receiver runs on a SEPARATE lifecycle and is a
# long-lived Python process with no hot-reload, so after an upgrade that
# changed receiver-side code the receiver kept running the OLD in-memory code
# until a manual `bridge-handoff-daemon.sh restart`. Recurring footgun across
# rc2->rc3 and rc3->v0.16.0.
#
# Fix: bridge-upgrade.sh's RESTART_DAEMON block now, AFTER restarting the main
# daemon, restarts the A2A receiver through the standard
# `bridge-handoff-daemon.sh restart` path — but ONLY when the receiver is
# already running (it does not start one as an upgrade side effect), and never
# in --dry-run. Going through the normal restart path re-establishes the
# fail-closed bind preflight, HMAC, remote_addr/allowlist, and dedupe.
#
# Test seam: the receiver-restart block is extracted VERBATIM from
# bridge-upgrade.sh by literal markers (deleting/renaming it trips this test)
# and eval'd in a subshell against an isolated $TMP TARGET_ROOT holding a STUB
# bridge-handoff-daemon.sh that records its argv. Every assertion has teeth —
# pre-fix (no receiver-restart block) the running-case PASS check FAILS.
#
# Footgun #11: no heredoc-fed subprocess anywhere — printf only. Runs entirely
# under an isolated $TMP; never touches operator state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"

[[ -f "$UPGRADE_SH" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$UPGRADE_SH" >&2; exit 2; }

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-1612-upgrade-restart-receiver.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Extract the receiver-restart block from bridge-upgrade.sh by literal
# markers. `sed -n '/start/,/end/p'` is the standard bash range-extraction
# primitive — no temp pipe, no heredoc.
RECEIVER_BLOCK="$(sed -n '/^# BEGIN: Issue #1612 A2A receiver restart$/,/^# END: Issue #1612 A2A receiver restart$/p' "$UPGRADE_SH")"

if [[ -z "$RECEIVER_BLOCK" ]]; then
  printf 'FAIL (bootstrap): could not extract issue #1612 receiver-restart block — regression?\n' >&2
  exit 2
fi

# Security teeth: the extracted block must NOT smuggle a bind-proof bypass.
printf '== T0 — extracted block carries no bind-proof bypass ==\n'
step "block contains no --skip-companion-validate"
case "$RECEIVER_BLOCK" in
  *--skip-companion-validate*) err "found --skip-companion-validate in receiver-restart block" ;;
  *) ok ;;
esac
step "block contains no --allow-test-bind"
case "$RECEIVER_BLOCK" in
  *--allow-test-bind*) err "found --allow-test-bind in receiver-restart block" ;;
  *) ok ;;
esac
step "block restarts via the standard 'restart' subcommand"
case "$RECEIVER_BLOCK" in
  *'restart'*) ok ;;
  *) err "block does not invoke the receiver 'restart' subcommand" ;;
esac

# Build an isolated TARGET_ROOT with a stub bridge-handoff-daemon.sh that
# records every invocation's argv to $TMP/argv.log. `status` emits a line
# shaped like the real bridge_a2a_status() output; the reported state is
# controlled by $TMP/state ("running" or "stopped").
TARGET_ROOT="$TMP/target"
mkdir -p "$TARGET_ROOT"
STUB="$TARGET_ROOT/bridge-handoff-daemon.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >> "%s/argv.log"\n' "$TMP"
  printf 'case "${1:-}" in\n'
  printf '  status)\n'
  printf '    _st="$(cat "%s/state" 2>/dev/null || printf "stopped")"\n' "$TMP"
  printf '    if [[ "$_st" == "running" ]]; then\n'
  printf '      printf "receiver      : running (pid 4242)\\n"\n'
  printf '    else\n'
  printf '      printf "receiver      : stopped\\n"\n'
  printf '    fi\n'
  printf '    ;;\n'
  printf '  restart)\n'
  printf '    printf "[a2a] receiver stopped (pid 4242)\\n"\n'
  printf '    printf "[a2a] receiver started (pid 4343)\\n"\n'
  printf '    ;;\n'
  printf 'esac\n'
  printf 'exit 0\n'
} > "$STUB"
chmod +x "$STUB"

# Drive the extracted block in a subshell with the upgrade-block's required
# scalars set. The block references RESTART_DAEMON, DRY_RUN, TARGET_ROOT only.
run_block() {
  # $1=RESTART_DAEMON $2=DRY_RUN ; prints stderr to $TMP/block.err
  : >"$TMP/argv.log"
  (
    RESTART_DAEMON="$1"
    DRY_RUN="$2"
    TARGET_ROOT="$TARGET_ROOT"
    eval "$RECEIVER_BLOCK"
  ) >"$TMP/block.out" 2>"$TMP/block.err"
}

invoked_restart() {
  grep -q '^restart$' "$TMP/argv.log"
}

# ---------------------------------------------------------------------------
# T1 — receiver RUNNING + --restart-daemon: cycles it via `restart`.
# ---------------------------------------------------------------------------
printf '== T1 — running receiver is restarted on --restart-daemon ==\n'
printf 'running\n' > "$TMP/state"

run_block 1 0
step "stub 'restart' was invoked when status=running"
if invoked_restart; then ok; else err "restart not invoked (argv: $(tr '\n' '|' < "$TMP/argv.log"))"; fi

step "emits the operator stderr line on success"
case "$(cat "$TMP/block.err")" in
  *"A2A receiver restarted to apply upgraded code"*) ok ;;
  *) err "missing restart confirmation on stderr: $(cat "$TMP/block.err")" ;;
esac

step "stdout stays clean (no receiver chatter — keeps --json parseable)"
if [[ ! -s "$TMP/block.out" ]]; then ok; else err "stdout not empty: $(cat "$TMP/block.out")"; fi

# ---------------------------------------------------------------------------
# T2 — receiver NOT running: do NOT start one as an upgrade side effect.
# ---------------------------------------------------------------------------
printf '== T2 — stopped receiver is NOT started on --restart-daemon ==\n'
printf 'stopped\n' > "$TMP/state"

run_block 1 0
step "stub 'restart' NOT invoked when status=stopped"
if invoked_restart; then err "restart was invoked for a stopped receiver"; else ok; fi

step "no restart-confirmation line for a stopped receiver"
case "$(cat "$TMP/block.err")" in
  *"A2A receiver restarted"*) err "emitted restart line for a stopped receiver" ;;
  *) ok ;;
esac

# ---------------------------------------------------------------------------
# T3 — --dry-run never touches the receiver, even when running.
# ---------------------------------------------------------------------------
printf '== T3 — --dry-run is a no-op even with a running receiver ==\n'
printf 'running\n' > "$TMP/state"

run_block 1 1
step "stub NOT invoked at all under --dry-run (no status, no restart)"
if [[ -s "$TMP/argv.log" ]]; then err "stub was invoked under dry-run (argv: $(tr '\n' '|' < "$TMP/argv.log"))"; else ok; fi

# ---------------------------------------------------------------------------
# T4 — --no-restart-daemon (RESTART_DAEMON=0): receiver untouched.
# ---------------------------------------------------------------------------
printf '== T4 — RESTART_DAEMON=0 leaves the receiver untouched ==\n'
printf 'running\n' > "$TMP/state"

run_block 0 0
step "stub NOT invoked when --restart-daemon was not requested"
if [[ -s "$TMP/argv.log" ]]; then err "stub was invoked with RESTART_DAEMON=0 (argv: $(tr '\n' '|' < "$TMP/argv.log"))"; else ok; fi

# ---------------------------------------------------------------------------
# T5 — missing receiver script is a quiet no-op (never fail the upgrade).
# ---------------------------------------------------------------------------
printf '== T5 — missing bridge-handoff-daemon.sh is a quiet no-op ==\n'
MISSING_ROOT="$TMP/no-receiver"
mkdir -p "$MISSING_ROOT"
printf 'running\n' > "$TMP/state"
: >"$TMP/argv.log"
(
  RESTART_DAEMON=1
  DRY_RUN=0
  TARGET_ROOT="$MISSING_ROOT"
  eval "$RECEIVER_BLOCK"
) >"$TMP/block.out" 2>"$TMP/block.err"
_rc=$?
step "block exits 0 when the receiver script is absent"
if [[ "$_rc" -eq 0 ]]; then ok; else err "expected exit 0 with missing script, got $_rc"; fi

step "no stub invocation recorded (the stub lives in a different TARGET_ROOT)"
if [[ -s "$TMP/argv.log" ]]; then err "argv.log not empty for missing-script case"; else ok; fi

# ---------------------------------------------------------------------------
# T6 — a failing restart warns + prints the manual command, does NOT abort.
# ---------------------------------------------------------------------------
printf '== T6 — restart failure warns with a remediation hint, never aborts ==\n'
FAIL_ROOT="$TMP/fail-target"
mkdir -p "$FAIL_ROOT"
FAIL_STUB="$FAIL_ROOT/bridge-handoff-daemon.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "${1:-}" in\n'
  printf '  status) printf "receiver      : running (pid 4242)\\n" ;;\n'
  printf '  restart) exit 1 ;;\n'
  printf 'esac\n'
  printf 'exit 0\n'
} > "$FAIL_STUB"
chmod +x "$FAIL_STUB"

(
  RESTART_DAEMON=1
  DRY_RUN=0
  TARGET_ROOT="$FAIL_ROOT"
  eval "$RECEIVER_BLOCK"
) >"$TMP/block.out" 2>"$TMP/block.err"
_rc=$?
step "block still exits 0 when the restart subcommand fails"
if [[ "$_rc" -eq 0 ]]; then ok; else err "restart failure aborted the upgrade (rc=$_rc)"; fi

step "warns and prints the manual restart command on failure"
case "$(cat "$TMP/block.err")" in
  *"WARN"*"restart"*) ok ;;
  *) err "missing failure-path warning + restart hint: $(cat "$TMP/block.err")" ;;
esac

# ---------------------------------------------------------------------------
printf '\n== 1612-upgrade-restart-receiver: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
