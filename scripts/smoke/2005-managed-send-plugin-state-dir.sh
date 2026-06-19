#!/usr/bin/env bash
# scripts/smoke/2005-managed-send-plugin-state-dir.sh — Issue #2005 regression
# guard for the generalized managed-send plugin-state-dir threading.
#
# Before #2005, the discord/telegram managed-send adapters in bridge-channels.py
# read per-agent credentials from `_agent_plugin_dir` =
# `<bridge_home>/agents/<agent>/.<plugin>`, but the bash SSOT
# (`bridge_agent_<plugin>_state_dir`, which bridge-setup.py also writes to)
# resolves `<workdir>/.<plugin>`. Those diverge for every iso-v2 /
# BRIDGE_AGENT_WORKDIR / BRIDGE_DATA_ROOT agent → the adapter read the wrong dir
# → `missing_credentials` → silent PreCompact-notify (#597) failure on the
# fleet. #2005 generalizes #1996's teams-only `--teams-state-dir` thread into a
# single `--plugin-state-dir` resolved in bash by `bridge_plugin_channel_state_dir`
# and consumed by all three adapters (discord/telegram/teams).
#
# This smoke proves:
#   P1 the bash wrapper (bridge_channel_send_managed_message) threads
#      --plugin-state-dir = the bridge_plugin_channel_state_dir SSOT value for
#      discord AND telegram (dry-run, no real network).
#   P2 the discord adapter reads its token from the passed --plugin-state-dir
#      (a token planted ONLY under <workdir>/.discord is found — the adapter
#      gets PAST missing_credentials), and that a stale token under the OLD
#      naive agents/<a>/.discord path is NOT what is used.
#   P3 the same for telegram.
#   P4 the empty-arg defensive fallback: with NO --plugin-state-dir, the
#      adapter falls back to <bridge_home>/agents/<agent>/.<plugin> and logs it.
#   P5 the two bridge-daemon.sh direct-argv send paths thread --plugin-state-dir.
#
# We cannot reach real Discord/Telegram, so P2/P3 assert the adapter advances
# past the credential lookup (it then fails at the HTTP/network step with a
# non-missing_credentials error) rather than asserting a real send.
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): no heredoc into a subprocess.

set -euo pipefail

SMOKE_NAME="2005-managed-send-plugin-state-dir"
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

AGENT="ch-bot"
CHANNEL_ID="123456789"
BODY="heads up: compacting now"

# A custom workdir that is NOT <bridge_home>/agents/<agent> — this is the shape
# (iso-v2 / explicit BRIDGE_AGENT_WORKDIR) where the old hardcoded read diverged
# from the bash SSOT. Plant credentials ONLY here.
WORKDIR="$SMOKE_TMP_ROOT/custom-workdir"
mkdir -p "$WORKDIR"
DISCORD_SSOT_DIR="$WORKDIR/.discord"
TELEGRAM_SSOT_DIR="$WORKDIR/.telegram"
mkdir -p "$DISCORD_SSOT_DIR" "$TELEGRAM_SSOT_DIR"
printf 'DISCORD_BOT_TOKEN=ssot-discord-token\n' >"$DISCORD_SSOT_DIR/.env"
printf 'TELEGRAM_BOT_TOKEN=ssot-telegram-token\n' >"$TELEGRAM_SSOT_DIR/.env"

# The OLD naive read path <bridge_home>/agents/<agent>/.<plugin>. Leave it
# EMPTY of credentials so the pre-#2005 read would have failed missing_credentials.
NAIVE_DISCORD_DIR="$BRIDGE_HOME/agents/$AGENT/.discord"
NAIVE_TELEGRAM_DIR="$BRIDGE_HOME/agents/$AGENT/.telegram"
mkdir -p "$NAIVE_DISCORD_DIR" "$NAIVE_TELEGRAM_DIR"

run_send() {
  # Run the python adapter directly with an explicit --plugin-state-dir.
  local plugin="$1" state_dir="$2" out="$3" err="$4"
  set +e
  "$PY_BIN" "$REPO_ROOT/bridge-channels.py" send-managed-message \
    --plugin "$plugin" \
    --agent "$AGENT" \
    --channel-id "$CHANNEL_ID" \
    --body "$BODY" \
    --bridge-home "$BRIDGE_HOME" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --plugin-state-dir "$state_dir" \
    --format json \
    >"$out" 2>"$err"
  local rc=$?
  set -e
  return "$rc"
}

run_send_no_state_dir() {
  # Run the python adapter WITHOUT --plugin-state-dir to exercise the fallback.
  local plugin="$1" out="$2" err="$3"
  set +e
  "$PY_BIN" "$REPO_ROOT/bridge-channels.py" send-managed-message \
    --plugin "$plugin" \
    --agent "$AGENT" \
    --channel-id "$CHANNEL_ID" \
    --body "$BODY" \
    --bridge-home "$BRIDGE_HOME" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --format json \
    >"$out" 2>"$err"
  local rc=$?
  set -e
  return "$rc"
}

# --- P1: the bash wrapper threads --plugin-state-dir = the bash SSOT ---------
# Drive bridge_channel_send_managed_message in dry-run and capture the argv it
# builds. We stub bridge_channels_python to echo its argv so we can assert the
# flag + value without a real send. The bash SSOT value for the custom workdir
# must be <workdir>/.<plugin>, so we register the agent workdir mapping.
P1_OUT="$SMOKE_TMP_ROOT/p1.out"
P1_RC=0
"${BASH:-bash}" -c '
  set -uo pipefail
  REPO="$1"; AGENT="$2"; WORKDIR="$3"
  source "$REPO/lib/bridge-core.sh"
  source "$REPO/lib/bridge-agents.sh"
  source "$REPO/lib/bridge-channels.sh"
  # Pin the agent workdir to the custom dir so bridge_agent_<plugin>_state_dir
  # resolves <workdir>/.<plugin> (the SSOT the adapter must read).
  bridge_agent_workdir() { printf "%s" "$WORKDIR"; }
  # Capture the argv the wrapper would hand to python.
  bridge_channels_python() { printf "%s\n" "$@"; }
  printf "=== discord ===\n"
  bridge_channel_send_managed_message discord "$AGENT" "chan" "" "body"
  printf "=== telegram ===\n"
  bridge_channel_send_managed_message telegram "$AGENT" "chan" "" "body"
' _ "$REPO_ROOT" "$AGENT" "$WORKDIR" >"$P1_OUT" 2>&1 || P1_RC=$?

[[ "$P1_RC" -eq 0 ]] || smoke_fail "P1 wrapper drive failed rc=$P1_RC; out=$(cat "$P1_OUT")"
P1_CONTENT="$(cat "$P1_OUT")"
smoke_assert_contains "$P1_CONTENT" "--plugin-state-dir" "P1 wrapper threads --plugin-state-dir"
smoke_assert_contains "$P1_CONTENT" "$WORKDIR/.discord" "P1 discord plugin-state-dir = <workdir>/.discord SSOT"
smoke_assert_contains "$P1_CONTENT" "$WORKDIR/.telegram" "P1 telegram plugin-state-dir = <workdir>/.telegram SSOT"
smoke_assert_not_contains "$P1_CONTENT" "--teams-state-dir" "P1 wrapper no longer emits the teams-specific flag"

smoke_log "P1 bash wrapper threads generic --plugin-state-dir for discord+telegram ok"

# --- P2: discord adapter reads the token from --plugin-state-dir -------------
# Token lives ONLY under <workdir>/.discord. With --plugin-state-dir pointing
# there, the adapter must get PAST missing_credentials (it then fails at the
# network step). The naive agents/<a>/.discord dir is empty, so a regression
# back to it would surface missing_credentials.
P2_OUT="$SMOKE_TMP_ROOT/p2.out"
P2_ERR="$SMOKE_TMP_ROOT/p2.err"
P2_RC=0
run_send discord "$DISCORD_SSOT_DIR" "$P2_OUT" "$P2_ERR" || P2_RC=$?
[[ "$P2_RC" -ne 0 ]] || smoke_fail "P2 expected a non-zero rc (no real network), got 0"
P2_ERR_TEXT="$(cat "$P2_ERR")"
smoke_assert_not_contains "$P2_ERR_TEXT" "missing_credentials" \
  "P2 discord finds the token under <workdir>/.discord (no missing_credentials)"

# Negative control: pointing at the empty naive dir DOES surface missing_credentials.
P2N_OUT="$SMOKE_TMP_ROOT/p2n.out"
P2N_ERR="$SMOKE_TMP_ROOT/p2n.err"
P2N_RC=0
run_send discord "$NAIVE_DISCORD_DIR" "$P2N_OUT" "$P2N_ERR" || P2N_RC=$?
smoke_assert_contains "$(cat "$P2N_ERR")" "missing_credentials" \
  "P2 control: empty dir → missing_credentials (proves the token gate is real)"

smoke_log "P2 discord adapter reads from the passed plugin-state-dir ok"

# --- P3: telegram adapter reads the token from --plugin-state-dir ------------
P3_OUT="$SMOKE_TMP_ROOT/p3.out"
P3_ERR="$SMOKE_TMP_ROOT/p3.err"
P3_RC=0
run_send telegram "$TELEGRAM_SSOT_DIR" "$P3_OUT" "$P3_ERR" || P3_RC=$?
[[ "$P3_RC" -ne 0 ]] || smoke_fail "P3 expected a non-zero rc (no real network), got 0"
smoke_assert_not_contains "$(cat "$P3_ERR")" "missing_credentials" \
  "P3 telegram finds the token under <workdir>/.telegram (no missing_credentials)"

smoke_log "P3 telegram adapter reads from the passed plugin-state-dir ok"

# --- P4: empty-arg defensive fallback warns + uses agents/<a>/.<plugin> ------
# Plant a token under the naive path so the fallback read can succeed; assert
# the warning is logged AND the adapter advances past missing_credentials.
printf 'DISCORD_BOT_TOKEN=fallback-discord-token\n' >"$NAIVE_DISCORD_DIR/.env"
P4_OUT="$SMOKE_TMP_ROOT/p4.out"
P4_ERR="$SMOKE_TMP_ROOT/p4.err"
P4_RC=0
run_send_no_state_dir discord "$P4_OUT" "$P4_ERR" || P4_RC=$?
P4_ERR_TEXT="$(cat "$P4_ERR")"
smoke_assert_contains "$P4_ERR_TEXT" "falling back" "P4 fallback warns when --plugin-state-dir absent"
smoke_assert_contains "$P4_ERR_TEXT" "$NAIVE_DISCORD_DIR" "P4 fallback path is <bridge_home>/agents/<agent>/.discord"
smoke_assert_not_contains "$P4_ERR_TEXT" "missing_credentials" \
  "P4 fallback still finds a token under the naive dir"
# Clean up the planted fallback token so it can't mask P2's negative control on reruns.
rm -f "$NAIVE_DISCORD_DIR/.env"

smoke_log "P4 empty-arg defensive fallback ok"

# --- P5: the daemon-side send call sites thread --plugin-state-dir -----------
# The PreCompact notice + followup paths in bridge-daemon.sh build the
# send-managed-message argv directly (bypassing
# bridge_channel_send_managed_message), so they MUST resolve the canonical
# per-agent plugin state dir themselves. Guard both inlined argv builders.
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
smoke_assert_file_exists "$DAEMON_SH" "P5 bridge-daemon.sh present"
DAEMON_HITS="$(grep -c -- '--plugin-state-dir "\$_plugin_state_dir"\|--plugin-state-dir "\$_fu_plugin_state_dir"' "$DAEMON_SH" || true)"
[[ "$DAEMON_HITS" -ge 2 ]] || smoke_fail \
  "P5 expected both daemon send paths (notice+followup) to thread --plugin-state-dir, found $DAEMON_HITS"

smoke_log "P5 daemon send paths thread --plugin-state-dir ok"

smoke_log "ok"
