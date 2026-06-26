#!/usr/bin/env bash

set -uo pipefail

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
AGENT_BRIDGE="$BRIDGE_HOME/agent-bridge"
CLAUDE_BIN="${BRIDGE_CLAUDE_BIN:-$(command -v claude 2>/dev/null || printf '%s' "$HOME/.local/bin/claude")}"
PATCH_HOME="$BRIDGE_HOME/agents/patch"
SCRIPTS_DIR="$BRIDGE_HOME/runtime/scripts"
LOG_DIR="$PATCH_HOME/logs"
STATUS_FILE="$PATCH_HOME/.status"

mkdir -p "$LOG_DIR"

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DATE_KST="$(TZ=Asia/Seoul date +"%Y-%m-%d")"
LOG_FILE="$LOG_DIR/update-${DATE_KST}.log"

timeout_bin() {
  if command -v gtimeout >/dev/null 2>&1; then
    printf '%s' "$(command -v gtimeout)"
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    printf '%s' "$(command -v timeout)"
    return 0
  fi
  printf '%s' ""
}

send_main_task() {
  local priority="$1"
  local title="$2"
  local body_file="$3"
  "$AGENT_BRIDGE" task create \
    --to main \
    --from patch \
    --priority "$priority" \
    --title "$title" \
    --body-file "$body_file" >>"$LOG_FILE" 2>&1 || return 1
}

if [[ -f "$STATUS_FILE" ]]; then
  prev="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "$STATUS_FILE" 2>/dev/null || echo "")"
  if [[ "$prev" == "running" ]]; then
    echo "[$TIMESTAMP] WARNING: Previous run still marked running. Resetting status." >>"$LOG_FILE"
  fi
fi

printf '{"state":"running","started":"%s","task":"update-check"}\n' "$TIMESTAMP" >"$STATUS_FILE"
echo "[$TIMESTAMP] Update check started" >>"$LOG_FILE"

cleanup() {
  local code=$?
  local finished
  local report_file=""

  finished="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [[ "$code" -eq 0 ]]; then
    printf '{"state":"done","started":"%s","finished":"%s","exit":0}\n' "$TIMESTAMP" "$finished" >"$STATUS_FILE"
  else
    printf '{"state":"failed","started":"%s","finished":"%s","exit":%d}\n' "$TIMESTAMP" "$finished" "$code" >"$STATUS_FILE"
  fi
  echo "[$finished] Update check finished (exit=$code)" >>"$LOG_FILE"

  if [[ -n "${CLI_OUTPUT_FILE:-}" && -f "${CLI_OUTPUT_FILE:-}" ]]; then
    report_file="$(mktemp)"
    tail -80 "$CLI_OUTPUT_FILE" | head -c 2400 >"$report_file"
    if [[ "$code" -eq 0 ]]; then
      send_main_task high "[patch] update check result" "$report_file" || true
    else
      send_main_task urgent "[patch] update check failed" "$report_file" || true
    fi
  elif [[ "$code" -ne 0 ]]; then
    report_file="$(mktemp)"
    {
      printf 'patch update check failed without CLI output\n'
      printf 'time=%s\n' "$(TZ=Asia/Seoul date +"%Y-%m-%d %H:%M:%S %Z")"
      printf 'log=%s\n' "$LOG_FILE"
    } >"$report_file"
    send_main_task urgent "[patch] update check failed" "$report_file" || true
  fi

  [[ -n "$report_file" ]] && rm -f "$report_file"
}
trap cleanup EXIT

echo "[$TIMESTAMP] Running pre-update backup..." >>"$LOG_FILE"
bash "$SCRIPTS_DIR/git-backup.sh" >>"$LOG_FILE" 2>&1 || echo "[$TIMESTAMP] WARNING: Backup failed, continuing" >>"$LOG_FILE"

echo "[$TIMESTAMP] Gathering update status..." >>"$LOG_FILE"
bash "$SCRIPTS_DIR/gather-update-status.sh" >>"$LOG_FILE" 2>&1 || true
UPDATE_STATUS="$(cat /tmp/openclaw-update-status.json 2>/dev/null || echo '{}')"

SOUL="$(cat "$PATCH_HOME/SOUL.md" 2>/dev/null || echo "")"
MEMORY="$(cat "$PATCH_HOME/MEMORY.md" 2>/dev/null || echo "")"
UPDATE_CHECKLIST="$(cat "$PATCH_HOME/UPDATE-CHECKLIST.md" 2>/dev/null || echo "")"

CONTEXT="$SOUL

---
$MEMORY

---
$UPDATE_CHECKLIST

---
Current update status:
$UPDATE_STATUS

---
RULES:
- You are Patch running the periodic update check.
- Review the update status JSON and follow UPDATE-CHECKLIST.md.
- If updates are needed, execute them carefully and verify the result.
- If no updates are needed, report that clearly.
- Update MEMORY.md and relevant memory notes as needed.
- Print a concise final report to stdout only. The wrapper will enqueue it to main."

unset CLAUDECODE OPENCLAW_GATEWAY_TOKEN OPENCLAW_GATEWAY_PORT \
  OPENCLAW_SERVICE_VERSION OPENCLAW_SYSTEMD_UNIT OPENCLAW_LAUNCHD_LABEL \
  OPENCLAW_SERVICE_KIND OPENCLAW_SERVICE_MARKER OPENCLAW_PATH_BOOTSTRAPPED \
  2>/dev/null || true

# #17957 path B: load the singleton-channel-off overlay before spawning the
# disposable `claude -p`. Fail closed if the shared helper is unreachable —
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
  echo "[call-patch-update][fatal] #17957 singleton-channel-suppression.sh not found; refusing to launch the disposable Claude child (would risk telegram/discord poller theft)" >&2
  exit 1
fi
# shellcheck source=runtime-templates/scripts/lib/singleton-channel-suppression.sh
source "$_singleton_suppress_lib"

cd "$PATCH_HOME"
CLI_OUTPUT_FILE="$(mktemp /tmp/patch-update-output.XXXXXX)"
TIMEOUT_BIN="$(timeout_bin)"
if [[ -n "$TIMEOUT_BIN" ]]; then
  "$TIMEOUT_BIN" 900 "$CLAUDE_BIN" -p \
    "${SINGLETON_CHANNEL_SUPPRESSION_ARGS[@]}" \
    --no-session-persistence \
    --append-system-prompt "$CONTEXT" \
    --dangerously-skip-permissions \
    --model opus \
    --output-format text \
    "업데이트 상태를 확인하고, 필요한 업데이트가 있으면 진행해줘. 최종 결과는 stdout으로 간단히 정리해." \
    2>&1 | tee -a "$LOG_FILE" | tee "$CLI_OUTPUT_FILE"
else
  "$CLAUDE_BIN" -p \
    "${SINGLETON_CHANNEL_SUPPRESSION_ARGS[@]}" \
    --no-session-persistence \
    --append-system-prompt "$CONTEXT" \
    --dangerously-skip-permissions \
    --model opus \
    --output-format text \
    "업데이트 상태를 확인하고, 필요한 업데이트가 있으면 진행해줘. 최종 결과는 stdout으로 간단히 정리해." \
    2>&1 | tee -a "$LOG_FILE" | tee "$CLI_OUTPUT_FILE"
fi
exit "${PIPESTATUS[0]}"
