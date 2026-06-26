#!/usr/bin/env bash

set -uo pipefail

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
AGENT_BRIDGE="$BRIDGE_HOME/agent-bridge"
NOTIFY_PY="$BRIDGE_HOME/bridge-notify.py"
CONFIG_JSON="$BRIDGE_HOME/runtime/bridge-config.json"
AGENT_ID="${BRIDGE_RUNTIME_AGENT_ID:-shopify}"
AGENT_NAME="${BRIDGE_RUNTIME_AGENT_NAME:-$AGENT_ID}"
AGENT_HOME="${BRIDGE_RUNTIME_AGENT_HOME:-$BRIDGE_HOME/agents/$AGENT_ID}"
FAILURE_TARGET="${BRIDGE_RUNTIME_FAILURE_TARGET:-${BRIDGE_ADMIN_AGENT_ID:-}}"
CLAUDE_BIN="${BRIDGE_CLAUDE_BIN:-$(command -v claude 2>/dev/null || printf '%s' "$HOME/.local/bin/claude")}"
STATUS_FILE="$AGENT_HOME/.status"
LOG_DIR="$AGENT_HOME/logs"

mkdir -p "$LOG_DIR"

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DATE_KST="$(TZ=Asia/Seoul date +"%Y-%m-%d")"
LOG_FILE="$LOG_DIR/call-shopify-${DATE_KST}.log"
REQUEST=""
FROM_AGENT=""
DISCORD_CHANNEL=""
DISCORD_ACCOUNT="shopify"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      FROM_AGENT="$2"
      shift 2
      ;;
    --discord-channel)
      DISCORD_CHANNEL="$2"
      shift 2
      ;;
    --discord-account)
      DISCORD_ACCOUNT="$2"
      shift 2
      ;;
    *)
      REQUEST="${REQUEST:+$REQUEST }$1"
      shift
      ;;
  esac
done

REQUEST="${REQUEST:-안녕! 자기소개 해줘.}"
FROM_AGENT="${FROM_AGENT:-direct}"

send_result_task() {
  local target="$1"
  local title="$2"
  local body_file="$3"

  [[ -n "$target" ]] || return 0
  "$AGENT_BRIDGE" task create \
    --to "$target" \
    --from "$AGENT_ID" \
    --priority high \
    --title "$title" \
    --body-file "$body_file" >>"$LOG_FILE" 2>&1 || return 1
}

send_failure_task() {
  local exit_code="$1"
  local note_file

  note_file="$(mktemp)"
  {
    printf 'agent=%s\n' "$AGENT_ID"
    printf 'from=%s\n' "$FROM_AGENT"
    printf 'exit=%s\n' "$exit_code"
    printf 'time=%s\n' "$(TZ=Asia/Seoul date +"%Y-%m-%d %H:%M:%S %Z")"
    printf 'log=%s\n' "$LOG_FILE"
  } >"$note_file"
  [[ -n "$FAILURE_TARGET" ]] || {
    rm -f "$note_file"
    return 0
  }
  "$AGENT_BRIDGE" task create \
    --to "$FAILURE_TARGET" \
    --from "$AGENT_ID" \
    --priority urgent \
    --title "[${AGENT_ID}] CLI call failed" \
    --body-file "$note_file" >>"$LOG_FILE" 2>&1 || true
  rm -f "$note_file"
}

send_discord_result() {
  local report_text="$1"

  [[ -n "$DISCORD_CHANNEL" ]] || return 0
  python3 "$NOTIFY_PY" send \
    --agent "$AGENT_ID" \
    --kind discord \
    --target "$DISCORD_CHANNEL" \
    --account "$DISCORD_ACCOUNT" \
    --runtime-config "$CONFIG_JSON" \
    --title "$AGENT_NAME CLI result" \
    --message "$report_text" >>"$LOG_FILE" 2>&1 || return 1
}

if [[ -f "$STATUS_FILE" ]]; then
  prev="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "$STATUS_FILE" 2>/dev/null || echo "")"
  if [[ "$prev" == "running" ]]; then
    echo "[$TIMESTAMP] WARNING: Previous run still marked running. Resetting status." >>"$LOG_FILE"
  fi
fi

printf '{"state":"running","started":"%s","from":"%s","task":"%s"}\n' "$TIMESTAMP" "$FROM_AGENT" "$REQUEST" >"$STATUS_FILE"
echo "[$TIMESTAMP] ${AGENT_NAME} called (from=$FROM_AGENT): $REQUEST" >>"$LOG_FILE"

cleanup() {
  local code=$?
  local finished
  local report_file=""
  local report_text=""

  finished="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [[ "$code" -eq 0 ]]; then
    printf '{"state":"done","started":"%s","finished":"%s","from":"%s","exit":0}\n' "$TIMESTAMP" "$finished" "$FROM_AGENT" >"$STATUS_FILE"
  else
    printf '{"state":"failed","started":"%s","finished":"%s","from":"%s","exit":%d}\n' "$TIMESTAMP" "$finished" "$FROM_AGENT" "$code" >"$STATUS_FILE"
  fi
  echo "[$finished] ${AGENT_NAME} call finished (from=$FROM_AGENT, exit=$code)" >>"$LOG_FILE"

  if [[ -n "${CLI_OUTPUT_FILE:-}" && -f "${CLI_OUTPUT_FILE:-}" ]]; then
    report_file="$(mktemp)"
    tail -80 "$CLI_OUTPUT_FILE" | head -c 1900 >"$report_file"
    report_text="$(cat "$report_file")"
  fi

  if [[ "$FROM_AGENT" != "direct" && "$FROM_AGENT" != "cron" && -n "$report_file" ]]; then
    send_result_task "$FROM_AGENT" "[${AGENT_ID}] CLI result" "$report_file" || true
  fi
  if [[ -n "$report_text" ]]; then
    send_discord_result "$report_text" || true
  fi
  if [[ "$code" -ne 0 ]]; then
    send_failure_task "$code"
  fi

  [[ -n "$report_file" ]] && rm -f "$report_file"
  [[ -n "${CLI_OUTPUT_FILE:-}" ]] && rm -f "$CLI_OUTPUT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

unset CLAUDECODE OPENCLAW_GATEWAY_TOKEN OPENCLAW_GATEWAY_PORT \
  OPENCLAW_SERVICE_VERSION OPENCLAW_SYSTEMD_UNIT OPENCLAW_LAUNCHD_LABEL \
  OPENCLAW_SERVICE_KIND OPENCLAW_SERVICE_MARKER OPENCLAW_PATH_BOOTSTRAPPED \
  2>/dev/null || true

CONTEXT="From: $FROM_AGENT | Discord: ${DISCORD_CHANNEL:-none} | Time: $TIMESTAMP
Do the requested work, update local memory if needed, and print a concise final report to stdout.
Do not send notifications yourself. The wrapper delivers queue tasks and Discord notifications."

CLI_OUTPUT_FILE="$(mktemp /tmp/shopify-output.XXXXXX)"
AGENT_SESSION_DIR="$AGENT_HOME/sessions/$FROM_AGENT"
mkdir -p "$AGENT_SESSION_DIR"
[[ -f "$AGENT_SESSION_DIR/CLAUDE.md" ]] || ln -sf "$AGENT_HOME/CLAUDE.md" "$AGENT_SESSION_DIR/CLAUDE.md" 2>/dev/null || true

# #17957 path B: load the singleton-channel-off overlay before spawning the
# disposable `claude -c -p`. Fail closed if the shared helper is unreachable —
# spawning without it would let this child SIGTERM-steal the admin's live
# telegram/discord poller.
_singleton_suppress_lib=""
for _cand in \
  "$(dirname -- "${BASH_SOURCE[0]}")/lib/singleton-channel-suppression.sh" \
  "$(dirname -- "${BASH_SOURCE[0]}")/../../../scripts/lib/singleton-channel-suppression.sh" \
  "$BRIDGE_HOME/runtime/scripts/lib/singleton-channel-suppression.sh"; do
  [[ -r "$_cand" ]] && { _singleton_suppress_lib="$_cand"; break; }
done
if [[ -z "$_singleton_suppress_lib" ]]; then
  echo "[call-shopify][fatal] #17957 singleton-channel-suppression.sh not found; refusing to launch the disposable Claude child (would risk telegram/discord poller theft)" >&2
  exit 1
fi
# shellcheck source=runtime-templates/scripts/lib/singleton-channel-suppression.sh
source "$_singleton_suppress_lib"

cd "$AGENT_SESSION_DIR"
"$CLAUDE_BIN" -c -p \
  "${SINGLETON_CHANNEL_SUPPRESSION_ARGS[@]}" \
  --append-system-prompt "$CONTEXT" \
  --dangerously-skip-permissions \
  --model opus \
  --output-format text \
  "$REQUEST" 2>&1 | tee -a "$LOG_FILE" | tee "$CLI_OUTPUT_FILE"
exit "${PIPESTATUS[0]}"
