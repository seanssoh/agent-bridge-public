#!/usr/bin/env bash
# scripts/smoke/teams-managed-send.sh — Issue #1996 regression guard for the
# teams managed-send adapter in bridge-channels.py.
#
# Before #1996, `bridge-channels.py send-managed-message --plugin teams` fell
# into the `_PLUGINS_TRACK_C_PENDING` branch and raised `track_c_pending`, so a
# Teams-channel agent could never be proactively pushed to from core. #1996
# adds `_adapter_teams`, which shells out to the bundled teams plugin CLI:
#
#   bun <bridge_home>/plugins/teams/server.ts send-managed \
#     --agent <a> --channel-id <c> --body <b> [--reply-to-message-id <id>]
#
# with BRIDGE_AGENT_ID + TEAMS_STATE_DIR exported. The canonical TEAMS_STATE_DIR
# is resolved in bash (bridge_agent_teams_state_dir) and threaded through as
# --teams-state-dir; the Python adapter must NOT re-derive the workdir.
#
# This smoke exercises the adapter WITHOUT a real bun/Teams backend: it puts a
# fake `bun` on PATH that asserts it received the expected argv + env, then
# echoes the success JSON (T1) or exits 3 / 2 to prove exit-code → error
# mapping (T2/T3). It also proves teams left _PLUGINS_TRACK_C_PENDING (T1 would
# have raised track_c_pending otherwise).
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): no heredoc into a subprocess. The
# fake bun is a stand-alone executable written with printf.

set -euo pipefail

SMOKE_NAME="teams-managed-send"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="teams-bot"
CHANNEL_ID="19:conv-abc123"
BODY="heads up: compacting now"
TEAMS_STATE_DIR="$BRIDGE_HOME/agents/$AGENT/.teams"
mkdir -p "$TEAMS_STATE_DIR"

# The adapter checks for plugins/teams/server.ts before spawning bun. A stub
# file is enough — the fake bun never reads it.
mkdir -p "$BRIDGE_HOME/plugins/teams"
: >"$BRIDGE_HOME/plugins/teams/server.ts"

# Fake bun on PATH. It records argv + the two env vars the adapter must export,
# asserts the send-managed contract, then behaves per FAKE_BUN_MODE.
FAKE_BIN_DIR="$SMOKE_TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN_DIR"
FAKE_BUN="$FAKE_BIN_DIR/bun"
ARGV_LOG="$SMOKE_TMP_ROOT/bun-argv.log"
ENV_LOG="$SMOKE_TMP_ROOT/bun-env.log"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': >"$ARGV_LOG"' \
  'for a in "$@"; do printf "%s\n" "$a" >>"$ARGV_LOG"; done' \
  '{' \
  '  printf "BRIDGE_AGENT_ID=%s\n" "${BRIDGE_AGENT_ID:-<unset>}"' \
  '  printf "TEAMS_STATE_DIR=%s\n" "${TEAMS_STATE_DIR:-<unset>}"' \
  '} >"$ENV_LOG"' \
  '# argv: <server.ts> send-managed --agent A --channel-id C --body B ...' \
  'if [[ "$2" != "send-managed" ]]; then' \
  '  printf "fake-bun: expected send-managed subcommand, got %s\n" "$2" >&2' \
  '  exit 99' \
  'fi' \
  '# Flag-loop like the real plugin (server.ts:2515) so the echoed channel_id' \
  '# is correct regardless of flag order.' \
  'fch=""' \
  'while [[ $# -gt 0 ]]; do' \
  '  if [[ "$1" == "--channel-id" ]]; then fch="${2:-}"; shift 2; continue; fi' \
  '  shift' \
  'done' \
  'case "${FAKE_BUN_MODE:-ok}" in' \
  '  ok)' \
  '    printf '"'"'{"status":"sent","plugin":"teams","channel_id":"%s","message_id":"msg-777","thread_id":null,"best_effort_threading":true}\n'"'"' "$fch" ;;' \
  '  refmiss)' \
  '    printf "teams send-managed: conversation reference not found\n" >&2; exit 3 ;;' \
  '  badargs)' \
  '    printf "teams send-managed: --channel-id and --body are required\n" >&2; exit 2 ;;' \
  'esac' \
  >"$FAKE_BUN"
chmod +x "$FAKE_BUN"

export ARGV_LOG ENV_LOG

run_adapter() {
  # Run bridge-channels.py with the fake bun first on PATH. Returns the rc and
  # writes stdout/stderr to the given files.
  local mode="$1" out="$2" err="$3"
  set +e
  FAKE_BUN_MODE="$mode" PATH="$FAKE_BIN_DIR:$PATH" \
    "$PY_BIN" "$REPO_ROOT/bridge-channels.py" send-managed-message \
      --plugin teams \
      --agent "$AGENT" \
      --channel-id "$CHANNEL_ID" \
      --body "$BODY" \
      --bridge-home "$BRIDGE_HOME" \
      --bridge-state-dir "$BRIDGE_STATE_DIR" \
      --teams-state-dir "$TEAMS_STATE_DIR" \
      --format json \
      >"$out" 2>"$err"
  local rc=$?
  set -e
  return "$rc"
}

# --- T1: success path -------------------------------------------------------
T1_OUT="$SMOKE_TMP_ROOT/t1.stdout"
T1_ERR="$SMOKE_TMP_ROOT/t1.stderr"
T1_RC=0
run_adapter ok "$T1_OUT" "$T1_ERR" || T1_RC=$?

[[ "$T1_RC" -eq 0 ]] || smoke_fail "T1 expected rc=0, got rc=$T1_RC; stderr=$(cat "$T1_ERR")"

T1_JSON="$(cat "$T1_OUT")"
smoke_assert_contains "$T1_JSON" '"CHANNEL_SEND_STATUS": "ok"' "T1 emits status ok"
smoke_assert_contains "$T1_JSON" '"CHANNEL_SEND_PLUGIN": "teams"' "T1 plugin is teams (left track-c-pending)"
smoke_assert_contains "$T1_JSON" '"CHANNEL_SEND_MESSAGE_ID": "msg-777"' "T1 parses plugin message_id"
smoke_assert_contains "$T1_JSON" "\"CHANNEL_SEND_CHANNEL_ID\": \"$CHANNEL_ID\"" "T1 echoes channel_id"
smoke_assert_not_contains "$T1_JSON" "track_c_pending" "T1 does not hit the track-c-pending stub"

# argv the fake bun saw: <server.ts> send-managed --agent A --channel-id C --body B
ARGV_CONTENT="$(cat "$ARGV_LOG")"
smoke_assert_contains "$ARGV_CONTENT" "send-managed" "T1 argv has send-managed"
smoke_assert_contains "$ARGV_CONTENT" "$AGENT" "T1 argv carries --agent value"
smoke_assert_contains "$ARGV_CONTENT" "$CHANNEL_ID" "T1 argv carries --channel-id value"
smoke_assert_contains "$ARGV_CONTENT" "$BODY" "T1 argv carries --body value verbatim (no shell split)"

ENV_CONTENT="$(cat "$ENV_LOG")"
smoke_assert_contains "$ENV_CONTENT" "BRIDGE_AGENT_ID=$AGENT" "T1 exports BRIDGE_AGENT_ID"
smoke_assert_contains "$ENV_CONTENT" "TEAMS_STATE_DIR=$TEAMS_STATE_DIR" "T1 exports the bash-resolved TEAMS_STATE_DIR"

smoke_log "T1 success-path adapter + argv/env contract ok"

# --- T2: ref-not-found (exit 3) maps to ref_not_found, rc 1 -----------------
T2_OUT="$SMOKE_TMP_ROOT/t2.stdout"
T2_ERR="$SMOKE_TMP_ROOT/t2.stderr"
T2_RC=0
run_adapter refmiss "$T2_OUT" "$T2_ERR" || T2_RC=$?

[[ "$T2_RC" -eq 1 ]] || smoke_fail "T2 expected rc=1 (adapter error), got rc=$T2_RC; stdout=$(cat "$T2_OUT")"
T2_ERR_TEXT="$(cat "$T2_ERR")"
smoke_assert_contains "$T2_ERR_TEXT" "ref_not_found" "T2 exit-3 maps to ref_not_found"
smoke_assert_not_contains "$(cat "$T2_OUT")" "CHANNEL_SEND_STATUS" "T2 emits no success payload"

smoke_log "T2 exit-3 → ref_not_found ok"

# --- T3: missing-args (exit 2) maps to missing_args, rc 1 -------------------
T3_OUT="$SMOKE_TMP_ROOT/t3.stdout"
T3_ERR="$SMOKE_TMP_ROOT/t3.stderr"
T3_RC=0
run_adapter badargs "$T3_OUT" "$T3_ERR" || T3_RC=$?

[[ "$T3_RC" -eq 1 ]] || smoke_fail "T3 expected rc=1 (adapter error), got rc=$T3_RC; stdout=$(cat "$T3_OUT")"
smoke_assert_contains "$(cat "$T3_ERR")" "missing_args" "T3 exit-2 maps to missing_args"

smoke_log "T3 exit-2 → missing_args ok"

# --- T4: missing-state-dir fallback warns but still resolves a path ---------
# When --teams-state-dir is omitted, the adapter falls back to
# <bridge_home>/agents/<agent>/.teams and logs a warning on stderr. Prove the
# fallback is taken (warning emitted) and the send still succeeds.
T4_OUT="$SMOKE_TMP_ROOT/t4.stdout"
T4_ERR="$SMOKE_TMP_ROOT/t4.stderr"
set +e
FAKE_BUN_MODE=ok PATH="$FAKE_BIN_DIR:$PATH" \
  "$PY_BIN" "$REPO_ROOT/bridge-channels.py" send-managed-message \
    --plugin teams \
    --agent "$AGENT" \
    --channel-id "$CHANNEL_ID" \
    --body "$BODY" \
    --bridge-home "$BRIDGE_HOME" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --format json \
    >"$T4_OUT" 2>"$T4_ERR"
T4_RC=$?
set -e
[[ "$T4_RC" -eq 0 ]] || smoke_fail "T4 expected rc=0 (fallback still sends), got rc=$T4_RC; stderr=$(cat "$T4_ERR")"
smoke_assert_contains "$(cat "$T4_ERR")" "falling back" "T4 warns when --teams-state-dir absent"
ENV_CONTENT4="$(cat "$ENV_LOG")"
smoke_assert_contains "$ENV_CONTENT4" "TEAMS_STATE_DIR=$BRIDGE_HOME/agents/$AGENT/.teams" "T4 fallback path is <bridge_home>/agents/<agent>/.teams"

smoke_log "T4 missing-state-dir fallback ok"

# --- T5: the daemon-side send call sites thread --teams-state-dir -----------
# The PreCompact notice + followup paths in bridge-daemon.sh build the
# send-managed-message argv directly (bypassing
# bridge_channel_send_managed_message), so they MUST resolve the canonical
# teams state dir themselves. Guard both inlined argv builders so a future
# refactor cannot silently drop the SSOT handoff and let the python adapter
# fall back to the naive <bridge_home>/agents/<agent>/.teams path under iso v2.
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
smoke_assert_file_exists "$DAEMON_SH" "T5 bridge-daemon.sh present"
DAEMON_TEAMS_HITS="$(grep -c -- '--teams-state-dir "\$_teams_state_dir"\|--teams-state-dir "\$_fu_teams_state_dir"' "$DAEMON_SH" || true)"
[[ "$DAEMON_TEAMS_HITS" -ge 2 ]] || smoke_fail \
  "T5 expected both daemon send paths (notice+followup) to thread --teams-state-dir, found $DAEMON_TEAMS_HITS"

smoke_log "T5 daemon send paths thread --teams-state-dir ok"

# --- T6: bridge_notify_send fails closed for a teams kind -------------------
# bridge_agent_notify_kind now resolves `teams`, but bridge-notify.py has no
# teams sender (account-token HTTP only). bridge_notify_send must short-circuit
# with a clear warning + non-zero rc rather than handing `--kind teams` to
# bridge-notify.py for a cryptic argparse "invalid choice" crash. Drive the
# real bridge_notify_send with stubbed kind/target resolvers and assert it
# returns 3 WITHOUT invoking bridge_notify_python.
T6_OUT="$SMOKE_TMP_ROOT/t6.out"
T6_RC=0
"${BASH:-bash}" -c '
  set -uo pipefail
  REPO="$1"
  source "$REPO/lib/bridge-core.sh"
  # Minimal stubs so bridge_notify_send reaches the teams short-circuit.
  bridge_require_python() { :; }
  bridge_audit_log() { :; }
  bridge_agent_notify_kind() { printf "teams"; }
  bridge_agent_notify_target() { printf "op-aad-111"; }
  bridge_agent_notify_account() { printf "default"; }
  bridge_compat_config_file() { printf "/dev/null"; }
  # Tripwire: if the short-circuit fails, this would run and we would see CALLED.
  bridge_notify_python() { printf "BRIDGE_NOTIFY_PYTHON_CALLED\n"; return 0; }
  source "$REPO/lib/bridge-notify.sh"
  bridge_notify_send teams-bot "t" "m" "" "normal" "0"
  printf "rc=%s\n" "$?"
' _ "$REPO_ROOT" >"$T6_OUT" 2>&1 || T6_RC=$?

smoke_assert_not_contains "$(cat "$T6_OUT")" "BRIDGE_NOTIFY_PYTHON_CALLED" "T6 teams kind never reaches bridge-notify.py"
smoke_assert_contains "$(cat "$T6_OUT")" "rc=3" "T6 bridge_notify_send returns 3 for teams kind"

smoke_log "T6 bridge_notify_send teams short-circuit ok"

smoke_log "ok"
