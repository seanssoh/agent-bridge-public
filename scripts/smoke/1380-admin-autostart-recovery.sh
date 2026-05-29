#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1380-admin-autostart-recovery.sh — admin liveness guard.
#
# Regression: after v0.15.0-beta5-4, the admin agent could remain down when
# daemon auto-start hit the resume gate with continue=1 and an empty/invalid
# session id. The daemon only recorded start-command-failed backoff, leaving
# the operator without the admin surface needed to repair the install.
#
# This smoke is static by design: it pins the daemon recovery contract without
# killing live tmux sessions. The live acceptance case is the daemon's normal
# always-on/on-demand path.

set -euo pipefail

SMOKE_NAME="1380-admin-autostart-recovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"
TMP_ROOT=""

cleanup() {
  [[ -z "$TMP_ROOT" ]] || rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

smoke_log "T1: bridge-daemon.sh is syntactically valid"
bash -n "$DAEMON_SH" || smoke_fail "bridge-daemon.sh failed bash -n"

smoke_log "T2: daemon has an admin-only recovery helper"
grep -q '^bridge_daemon_admin_autostart_recover()' "$DAEMON_SH" || \
  smoke_fail "missing bridge_daemon_admin_autostart_recover helper"
grep -q 'bridge_admin_agent_id' "$DAEMON_SH" || \
  smoke_fail "admin recovery helper is not gated on bridge_admin_agent_id"
grep -q 'admin_resume_state_repaired' "$DAEMON_SH" || \
  smoke_fail "admin recovery does not audit resume-state repair"
grep -q 'bridge_clear_persisted_session_id "$agent"' "$DAEMON_SH" || \
  smoke_fail "admin recovery does not clear invalid persisted session id"

smoke_log "T3: recovery tries fresh launch before safe mode"
grep -q 'start_args=("$agent" "--no-continue")' "$DAEMON_SH" || \
  smoke_fail "admin recovery does not attempt --no-continue"
grep -q 'start_args=("$agent" "--safe-mode" "--no-continue")' "$DAEMON_SH" || \
  smoke_fail "admin recovery does not attempt --safe-mode --no-continue"
grep -q 'admin_autostart_recovery_success' "$DAEMON_SH" || \
  smoke_fail "admin recovery success is not audited"

smoke_log "T4: always-on and on-demand starts use recovery wrapper"
if [[ "$(grep -c 'bridge_daemon_start_agent_with_recovery "$agent"' "$DAEMON_SH")" -lt 2 ]]; then
  smoke_fail "daemon start paths do not both use bridge_daemon_start_agent_with_recovery"
fi
grep -q 'bridge_daemon_start_agent_with_recovery "$agent" "always_on"' "$DAEMON_SH" || \
  smoke_fail "always-on start path bypasses admin recovery wrapper"
grep -q 'bridge_daemon_start_agent_with_recovery "$agent" "on_demand"' "$DAEMON_SH" || \
  smoke_fail "on-demand start path bypasses admin recovery wrapper"

smoke_log "T5: isolated dynamic check recovers admin with --no-continue"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-1380.XXXXXX")"
PARTIAL_DAEMON="$TMP_ROOT/daemon-defs.sh"
sed '/^while \[\[ \$# -gt 0 \]\]; do/,$d' "$DAEMON_SH" \
  | sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$SMOKE_REPO_ROOT\"|" \
  >"$PARTIAL_DAEMON"
cat >"$TMP_ROOT/bridge-start.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$START_LOG"
case " $* " in
  *" --no-continue "*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP_ROOT/bridge-start.sh"

# shellcheck disable=SC2030
(
  set -euo pipefail
  export BRIDGE_HOME="$TMP_ROOT/home"
  export START_LOG="$TMP_ROOT/start.log"
  mkdir -p "$BRIDGE_HOME"
  # Sourcing the daemon defs runs the v0.8.0 layout resolver. On Linux a
  # markerless fresh BRIDGE_HOME hard-dies with "requires isolation-v2"
  # (on macOS the resolver is a no-op, which is why this passed on the
  # dev host but failed on the Linux CI host). This test exercises the
  # admin recovery helper, not the layout resolver, so take the env-
  # override branch (bridge_layout_resolver_validate_env) by pinning a
  # valid v2 layout — same pattern as 1207/1067.
  export BRIDGE_LAYOUT="v2"
  export BRIDGE_DATA_ROOT="$TMP_ROOT/data"
  # shellcheck source=/dev/null
  source "$PARTIAL_DAEMON"
  SCRIPT_DIR="$TMP_ROOT"
  BRIDGE_BASH_BIN="$(command -v bash)"
  bridge_admin_agent_id() { printf '%s' "patch"; }
  bridge_agent_session() { printf '%s' "$1"; }
  bridge_agent_continue() { printf '%s' "1"; }
  bridge_agent_session_id() { printf '%s' ""; }
  bridge_clear_persisted_session_id() { printf '%s\n' "clear:$1" >>"$TMP_ROOT/events.log"; }
  bridge_audit_log() { printf '%s\n' "audit:$*" >>"$TMP_ROOT/events.log"; }
  daemon_info() { printf '%s\n' "info:$*" >>"$TMP_ROOT/events.log"; }
  bridge_tmux_session_exists() { return 0; }

  bridge_daemon_start_agent_with_recovery patch always_on
  grep -q '^patch$' "$START_LOG"
  grep -q '^patch --no-continue$' "$START_LOG"
  grep -q '^clear:patch$' "$TMP_ROOT/events.log"
  grep -q 'admin_autostart_recovery_success' "$TMP_ROOT/events.log"
)

smoke_log "T6: isolated dynamic check does not recover non-admin agents"
rm -f "$TMP_ROOT/start.log" "$TMP_ROOT/events.log"
# shellcheck disable=SC2031
(
  set -euo pipefail
  export BRIDGE_HOME="$TMP_ROOT/home2"
  export START_LOG="$TMP_ROOT/start.log"
  mkdir -p "$BRIDGE_HOME"
  # Pin a valid v2 layout so the resolver takes the env-override branch
  # instead of hard-dying on a markerless Linux home (see T5 note).
  export BRIDGE_LAYOUT="v2"
  export BRIDGE_DATA_ROOT="$TMP_ROOT/data2"
  # shellcheck source=/dev/null
  source "$PARTIAL_DAEMON"
  SCRIPT_DIR="$TMP_ROOT"
  BRIDGE_BASH_BIN="$(command -v bash)"
  bridge_admin_agent_id() { printf '%s' "patch"; }
  bridge_agent_session() { printf '%s' "$1"; }
  bridge_agent_continue() { printf '%s' "1"; }
  bridge_agent_session_id() { printf '%s' ""; }
  bridge_clear_persisted_session_id() { printf '%s\n' "clear:$1" >>"$TMP_ROOT/events.log"; }
  bridge_audit_log() { printf '%s\n' "audit:$*" >>"$TMP_ROOT/events.log"; }
  daemon_info() { printf '%s\n' "info:$*" >>"$TMP_ROOT/events.log"; }
  bridge_tmux_session_exists() { return 0; }

  if bridge_daemon_start_agent_with_recovery worker always_on; then
    smoke_fail "non-admin worker unexpectedly recovered"
  fi
  # Normalize the line count with arithmetic ($(( ... ))) so BSD/macOS `wc -l`
  # leading-space padding (e.g. "       1") does not false-fail the comparison.
  [[ "$(( $(wc -l <"$START_LOG") ))" -eq 1 ]] || smoke_fail "non-admin recovery invoked extra start attempts"
  [[ ! -f "$TMP_ROOT/events.log" ]] || smoke_fail "non-admin recovery emitted admin repair events"
  # Base warning parity: a non-admin start-command failure must surface the
  # exact base reason (`start-command-failed`) so the daemon call site warns
  # byte-equivalently to the pre-recovery path.
  [[ "$BRIDGE_DAEMON_START_FAILURE_REASON" == "start-command-failed" ]] || \
    smoke_fail "non-admin start failure reason drifted from base (got: $BRIDGE_DAEMON_START_FAILURE_REASON)"
)

smoke_log "T7: non-admin session-exited-quickly stays note-only (no recovery, base reason)"
rm -f "$TMP_ROOT/start.log" "$TMP_ROOT/events.log"
cat >"$TMP_ROOT/bridge-start.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$START_LOG"
exit 0
STUB
chmod +x "$TMP_ROOT/bridge-start.sh"
# shellcheck disable=SC2031
(
  set -euo pipefail
  export BRIDGE_HOME="$TMP_ROOT/home3"
  export START_LOG="$TMP_ROOT/start.log"
  mkdir -p "$BRIDGE_HOME"
  # Pin a valid v2 layout so the resolver takes the env-override branch
  # instead of hard-dying on a markerless Linux home (see T5 note).
  export BRIDGE_LAYOUT="v2"
  export BRIDGE_DATA_ROOT="$TMP_ROOT/data3"
  # shellcheck source=/dev/null
  source "$PARTIAL_DAEMON"
  SCRIPT_DIR="$TMP_ROOT"
  BRIDGE_BASH_BIN="$(command -v bash)"
  bridge_admin_agent_id() { printf '%s' "patch"; }
  bridge_agent_session() { printf '%s' "$1"; }
  bridge_agent_continue() { printf '%s' "1"; }
  bridge_agent_session_id() { printf '%s' ""; }
  bridge_clear_persisted_session_id() { printf '%s\n' "clear:$1" >>"$TMP_ROOT/events.log"; }
  bridge_audit_log() { printf '%s\n' "audit:$*" >>"$TMP_ROOT/events.log"; }
  daemon_info() { printf '%s\n' "info:$*" >>"$TMP_ROOT/events.log"; }
  # Start command succeeds but the session never comes up.
  bridge_tmux_session_exists() { return 1; }

  if bridge_daemon_start_agent_with_recovery worker on_demand; then
    smoke_fail "non-admin worker unexpectedly recovered on session-exited-quickly"
  fi
  # Normalize the line count with arithmetic ($(( ... ))) so BSD/macOS `wc -l`
  # leading-space padding (e.g. "       1") does not false-fail the comparison.
  [[ "$(( $(wc -l <"$START_LOG") ))" -eq 1 ]] || smoke_fail "non-admin session-exited-quickly invoked extra start attempts"
  [[ ! -f "$TMP_ROOT/events.log" ]] || smoke_fail "non-admin session-exited-quickly emitted admin repair events"
  # Base parity: reason is the transient note-only reason, so the call site
  # records the note WITHOUT a warning (matching the pre-recovery daemon).
  [[ "$BRIDGE_DAEMON_START_FAILURE_REASON" == "session-exited-quickly" ]] || \
    smoke_fail "non-admin session-exited-quickly reason drifted from base (got: $BRIDGE_DAEMON_START_FAILURE_REASON)"
)

smoke_log "ok: $SMOKE_NAME"
